--[[
* FFXIPort (independent frontend) - FPX/1 protocol client
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Milestone 8 clean-room replacement of the former protocol module. Written
* only from docs/PROTOCOL-FPX1.md; the former module was not available and
* was not consulted.
*
* Responsibilities:
*   - build requests ("!fpx 1 <sid> <rid> SYNC" / "!fpx 1 <sid> <rid> GO c d m a";
*     <sid> = session id, new on every load and session reset, RC4),
*     queue them, and dispatch at most one line per SEND_GAP_MS while
*     canSend() allows it (never during a zone change);
*   - read server frames from incoming chat packets (0x017, SYSTEM_3,
*     no speaker), block them from the chat log, and reassemble responses
*     per request id: fragmented, out-of-order and duplicate frames are
*     handled; conflicting, malformed, oversize or mis-checksummed
*     responses are discarded; frames for ids that are not outstanding
*     (delayed / stale) are dropped without buffering;
*   - validate a snapshot completely before exposing it (committed());
*   - time out SYNC (5 s) and GO (8 s); GO is never retried here.
*
* Handlers (all optional):
*   onSyncState(state, result)    queued | sent | receiving | ok | invalid | timeout | send_failed
*   onTravel(result)              { status = ok|invalid|timeout, tag, rid, kind, fields, reasons }
*   onSent(tag, line, t) / onSendFailed(tag, err) / onExpired(tag, line, t)
*   onBeforeDispatch(tag, line, t) / onDispatchFailed(tag, line, t)   (echo suppression)
*   onWarn(text) / onInfo(kind, text) / onRecord(frameLine)
--]]

local P = {}

P.VERSION         = 1
P.NAME            = 'FPX/1'
P.ACCEPT_MODES    = { [29] = true } -- LSB xi.msg.channel.SYSTEM_3
P.SYNC_TIMEOUT_MS = 5000
P.GO_TIMEOUT_MS   = 8000
P.CORRECTION_MS   = 6000 -- §4.6: a T stays open this long for a correcting E
P.SEND_GAP_MS     = 750
P.MAX_SLOTS       = 4
P.MAX_FRAMES      = 16
P.MAX_MES         = 150 -- LSB 0x017 Mes[150]: longer messages are truncated by the server core
P.MAX_FRAME_LINE  = 150
P.MAX_BODY        = 2048
P.MAX_CHUNK       = 128 -- 17-byte prefix + 128 = 145 <= 150 (RC5)
P.MAX_COUNT       = 256
P.MAX_OVERRIDES   = 128
P.SLOT_TTL_MS     = 10000
P.MAX_AMOUNT      = 999999999

P.handlers = {}
P.canSend  = nil -- function () -> bool (owner: not while zoning)
P.localServerId = nil -- function () -> number|nil (owner: the logged-in character's id)
P.localName     = nil -- function () -> string|nil (owner: the logged-in character's name; RC5)

-- Category mapping between the client catalogue tabs and FPX/1.
P.TAB_TO_CAT = { hp = 'H', sg = 'S', sp = 'G', rp = 'R' }
P.CAT_TO_TAB = { H = 'hp', S = 'sg', G = 'sp', R = 'rp' }
-- Gate Crystal protocol ids (PROTOCOL-FPX1.md §5.4), keyed by catalogue crystal name.
P.GATE_INDEX = { Holla = 0, Dem = 1, Mea = 2, Vahzl = 3, Yhoat = 4, Altep = 5 }
P.METHOD_TO_CUR = { gil = 'g', cp = 'c', is = 'i' }
P.CUR_TO_METHOD = { g = 'gil', c = 'cp', i = 'is' }

-- Dispatch and clock (replaceable in tests).
function P.dispatch(line)
    AshitaCore:GetChatManager():QueueCommand(1, line)
end

function P.clock()
    local ok, c = pcall(function () return ashita.time.clock() end)

    if ok and type(c) == 'table' and type(c.ms) == 'number' then
        return c.ms
    end

    return math.floor(os.clock() * 1000)
end

function P.now() return P.clock() end

-----------------------------------------------------------------------------
-- State
-----------------------------------------------------------------------------

local S

-- Client session id (RC4, PROTOCOL-FPX1.md §3): 12 lowercase hex digits,
-- new on every addon load and every session reset. The first 8 digits are
-- the low 32 bits of the client's millisecond clock, so two loads in the
-- same process (an addon reload) differ unless they happen within the same
-- millisecond. The last 4 digits are random and change if the clock part
-- repeats. The server keys its replay cache by sid + rid, so a new session
-- can never be answered from an earlier session's replay entry.
do
    local seed = os.time()

    pcall(function ()
        seed = seed + math.floor(os.clock() * 1000000) % 1000000 + math.floor(P.clock()) % 1000000
    end)

    math.randomseed(seed % 2147483647)
end

local function makeSid(previous)
    local ms = math.floor(P.clock()) % 4294967296
    local hi, lo = math.floor(ms / 65536), ms % 65536
    local r = math.random(0, 65535)
    local sid = string.format('%04x%04x%04x', hi, lo, r)

    if sid == previous then
        sid = string.format('%04x%04x%04x', hi, lo, (r + 1) % 65536)
    end

    return sid, (ms + r) % 65535
end

local function fresh(ridCounter, previousSid)
    local sid, seed = makeSid(previousSid)

    return {
        sid        = sid,
        ridCounter = ridCounter or seed,
        queue      = {},
        lastSendAt = nil,
        sync       = nil, -- { rid, state, queuedAt, sentAt, deadline, frames, problems }
        go         = nil, -- { rid, tag, state, queuedAt, sentAt, deadline, problems }
        watch      = nil, -- { rid, tag, untilAt }  T received: open for a correcting E (§4.6)
        slots      = {},  -- rid -> { parts, total, firstAt, count }
        nslots     = 0,
        committed  = nil,
        lastResult = nil,
        mismatch   = nil, -- { server = n }
        stats      = { packets = 0, frames = 0, responses = 0, stale = 0, malformed = 0, duplicates = 0,
                       conflicts = 0, checksum = 0, dropped = 0, foreign = 0 },
    }
end

-- P.clock is defined above; fresh() runs at load time.
S = fresh()

function P.sessionId() return S.sid end

-- Test hook: forces the next request ids (to reproduce id collisions).
function P._setRidCounter(n) S.ridCounter = n end

local function emit(name, ...)
    local fn = P.handlers[name]

    if type(fn) == 'function' then
        local ok, err = pcall(fn, ...)

        if not ok and name ~= 'onWarn' and type(P.handlers.onWarn) == 'function' then
            pcall(P.handlers.onWarn, 'FPX handler ' .. name .. ' failed: ' .. tostring(err))
        end
    end
end

local function warn(text) emit('onWarn', text) end
local function info(kind, text) emit('onInfo', kind, text) end

-----------------------------------------------------------------------------
-- Codec (pure)
-----------------------------------------------------------------------------

function P.adler32(s)
    local a, b = 1, 0

    for i = 1, #s do
        a = (a + string.byte(s, i)) % 65521
        b = (b + a) % 65521
    end

    return string.format('%04x%04x', b, a)
end

-- '0012' style request id from the counter.
local function nextRid()
    S.ridCounter = (S.ridCounter % 65535) + 1
    return string.format('%04x', S.ridCounter)
end

function P.buildSync(rid, sid)
    return string.format('!fpx %d %s %s SYNC', P.VERSION, sid or S.sid, rid)
end

function P.buildGo(rid, req, sid)
    return string.format('!fpx %d %s %s GO %s %d %s %d', P.VERSION, sid or S.sid, rid, req.cat, req.dest, req.cur, req.amount)
end

local function isDecimal(s, maxLen)
    return type(s) == 'string' and #s >= 1 and #s <= (maxLen or 10) and string.match(s, '^%d+$') ~= nil
end

-- "g500+c50" -> { {cur='g', amount=500}, ... } or nil, why
function P.parseOffers(s)
    if type(s) ~= 'string' or s == '' or #s > 64 then
        return nil, 'offer list'
    end

    local out, seen = {}, {}

    for part in string.gmatch(s .. '+', '([^+]*)%+') do
        local cur, amt = string.match(part, '^([fgcin])(%d+)$')

        if cur == nil or #amt > 9 or seen[cur] then
            return nil, 'offer "' .. part .. '"'
        end

        amt = tonumber(amt)

        if (cur == 'f' or cur == 'n') and amt ~= 0 then
            return nil, 'offer "' .. part .. '"'
        end

        seen[cur] = true
        out[#out + 1] = { cur = cur, amount = amt }
    end

    if #out == 0 or ((seen.f or seen.n) and #out > 1) then
        return nil, 'offer list "' .. s .. '"'
    end

    return out
end

-- "7:12" -> set, count  or nil, why
function P.parseBitmap(s)
    local count, hex = string.match(s or '', '^(%d+):(%x*)$')

    if count == nil or #count > 3 then
        return nil, nil, 'bitmap syntax'
    end

    count = tonumber(count)

    if count > P.MAX_COUNT or #hex ~= math.ceil(count / 4) or string.find(hex, '%u') then
        return nil, nil, 'bitmap length'
    end

    local set = {}

    for j = 0, #hex - 1 do
        local d = tonumber(string.sub(hex, j + 1, j + 1), 16)

        for k = 0, 3 do
            if math.floor(d / 2 ^ k) % 2 == 1 then
                local id = 4 * j + k

                if id >= count then
                    return nil, nil, 'bitmap padding'
                end

                set[id] = true
            end
        end
    end

    return set, count
end

-- Body -> fields or nil, why
function P.parseBody(body)
    local fields, n = {}, 0

    for pair in string.gmatch(body .. ';', '([^;]*);') do
        local k, v = string.match(pair, '^(%w+)=([^=]*)$')

        if k == nil or #k > 8 then
            return nil, 'body field "' .. string.sub(pair, 1, 20) .. '"'
        end

        if fields[k] ~= nil then
            return nil, 'duplicate key ' .. k
        end

        fields[k] = v
        n = n + 1
    end

    if fields.v ~= tostring(P.VERSION) then
        return nil, 'body version'
    end

    return fields
end

local function balanceOf(fields, key, reasons)
    local v = fields[key]

    if not isDecimal(v, 10) or tonumber(v) > 2147483647 then
        reasons[#reasons + 1] = 'balance ' .. key .. ' missing or invalid'
        return nil
    end

    return tonumber(v)
end

-- Optional balances (g/cp/is) from an E or T body; nil unless all three are valid.
function P.balances(fields)
    local r = {}
    local b = { gil = balanceOf(fields, 'g', r), cp = balanceOf(fields, 'cp', r), is = balanceOf(fields, 'is', r) }

    if #r > 0 then
        return nil
    end

    return b
end

-- Full validation of a snapshot body. Returns staged table or nil, reasons.
function P.validateSnapshot(fields, expectedChar)
    local reasons = {}
    local st = { unlock = {}, counts = {}, offers = {}, protocol = P.NAME }

    if not isDecimal(fields.ch, 10) then
        reasons[#reasons + 1] = 'character id missing'
    else
        st.ch = tonumber(fields.ch)

        if expectedChar ~= nil and st.ch ~= expectedChar then
            reasons[#reasons + 1] = 'snapshot belongs to another character'
        end
    end

    if not isDecimal(fields.z, 5) then
        reasons[#reasons + 1] = 'zone missing'
    else
        st.zone = tonumber(fields.z)
    end

    st.balances = { gil = balanceOf(fields, 'g', reasons), cp = balanceOf(fields, 'cp', reasons), is = balanceOf(fields, 'is', reasons) }

    for _, cat in ipairs({ 'H', 'S', 'G', 'R' }) do
        local set, count, why = P.parseBitmap(fields['u' .. cat])

        if set == nil then
            reasons[#reasons + 1] = 'u' .. cat .. ': ' .. tostring(why)
        else
            st.unlock[cat] = set
            st.counts[cat] = count
        end

        local def, why2 = P.parseOffers(fields['p' .. cat])

        if def == nil then
            reasons[#reasons + 1] = 'p' .. cat .. ': ' .. tostring(why2)
        end

        local over = {}
        local x = fields['x' .. cat]

        if x ~= nil then
            local n = 0

            for entry in string.gmatch(x .. '.', '([^.]*)%.') do
                local id, offers = string.match(entry, '^(%d+)~([%w+]+)$')
                local list = id and P.parseOffers(offers)

                n = n + 1

                if list == nil or #id > 3 or n > P.MAX_OVERRIDES then
                    reasons[#reasons + 1] = 'x' .. cat .. ': bad entry "' .. string.sub(entry, 1, 16) .. '"'
                    break
                end

                id = tonumber(id)

                if over[id] ~= nil or (count ~= nil and id >= count) then
                    reasons[#reasons + 1] = 'x' .. cat .. ': id ' .. id
                    break
                end

                over[id] = list
            end
        end

        st.offers[cat] = { default = def, over = over }
    end

    local ok = fields.ok

    if ok == '1' then
        st.travelBlock = nil
    elseif type(ok) == 'string' and string.match(ok, '^0%.%u+$') then
        st.travelBlock = string.sub(ok, 3)
    else
        reasons[#reasons + 1] = 'ok flag'
    end

    if #reasons > 0 then
        return nil, reasons
    end

    return st
end

-----------------------------------------------------------------------------
-- Requests
-----------------------------------------------------------------------------

local function enqueue(entry)
    S.queue[#S.queue + 1] = entry
end

local function syncActive()
    local s = S.sync
    return s ~= nil and (s.state == 'queued' or s.state == 'sent' or s.state == 'receiving')
end

function P.isBusy() return syncActive() end

function P.syncState()
    local s = S.sync

    if s == nil then
        return 'idle', nil
    end

    return s.state, { rid = s.rid, queuedAt = s.queuedAt, sentAt = s.sentAt }
end

function P.versionMismatch() return S.mismatch end

-- Returns true, or false + reason.
function P.requestSync()
    if S.mismatch then
        return false, 'version mismatch'
    end

    if syncActive() then
        return false, S.sync.state
    end

    local t   = P.now()
    local rid = nextRid()

    S.sync = { rid = rid, state = 'queued', queuedAt = t, problems = {}, frames = 0 }
    enqueue({ kind = 'sync', tag = 'sync', rid = rid, line = P.buildSync(rid), queuedAt = t })
    emit('onSyncState', 'queued', nil)
    return true
end

-- req = { cat, dest, cur, amount }. Returns true, rid or false, reason.
function P.requestGo(req, tag, deadline)
    if S.mismatch then
        return false, 'version mismatch'
    end

    if S.go ~= nil then
        return false, 'a trip request is outstanding'
    end

    if type(req) ~= 'table' or not string.match(tostring(req.cat), '^[HSGR]$')
        or type(req.dest) ~= 'number' or req.dest < 0 or req.dest > 999 or req.dest ~= math.floor(req.dest)
        or not string.match(tostring(req.cur), '^[gcif]$')
        or type(req.amount) ~= 'number' or req.amount < 0 or req.amount > P.MAX_AMOUNT or req.amount ~= math.floor(req.amount)
        or (req.cur == 'f' and req.amount ~= 0) then
        return false, 'invalid trip request'
    end

    local t   = P.now()
    local rid = nextRid()

    S.go = { rid = rid, tag = tag, state = 'queued', queuedAt = t, problems = {} }
    enqueue({ kind = 'go', tag = tag, rid = rid, line = P.buildGo(rid, req), queuedAt = t, deadline = deadline })
    return true, rid
end

-- Removes queued (unsent) lines with this tag. Returns the number removed.
function P.cancel(tag)
    local n = 0

    for i = #S.queue, 1, -1 do
        if S.queue[i].tag == tag then
            local e = table.remove(S.queue, i)
            n = n + 1

            if e.kind == 'go' and S.go ~= nil and S.go.rid == e.rid then
                S.go = nil
            end
        end
    end

    return n
end

function P.queueLength() return #S.queue end

-----------------------------------------------------------------------------
-- Results
-----------------------------------------------------------------------------

local function finishSync(status, result)
    local s = S.sync

    if s == nil then
        return
    end

    result = result or {}
    result.status  = status
    result.rid     = s.rid
    result.frames  = s.frames
    result.elapsed = s.sentAt and (P.now() - s.sentAt) or nil
    result.reasons = result.reasons or {}

    for _, p in ipairs(s.problems) do
        result.reasons[#result.reasons + 1] = p
    end

    s.state = status
    S.lastResult = result
    emit('onSyncState', status, result)
end

local function finishGo(result)
    local g = S.go

    if g == nil then
        return
    end

    S.go = nil
    result.tag = g.tag
    result.rid = g.rid
    result.reasons = result.reasons or {}

    for _, p in ipairs(g.problems) do
        result.reasons[#result.reasons + 1] = p
    end

    -- §4.6: a T stays open for a correcting E with the same request id.
    if result.status == 'ok' and result.kind == 'T' then
        S.watch = { rid = g.rid, tag = g.tag, untilAt = P.now() + P.CORRECTION_MS }
    end

    emit('onTravel', result)
end

-- Ends the correction window for a trip (owner: the zone change started,
-- after which the server never sends a correction).
function P.closeCorrection(tag)
    if S.watch ~= nil and (tag == nil or S.watch.tag == tag) then
        S.watch = nil
    end
end

function P.correctionOpen(tag)
    return S.watch ~= nil and (tag == nil or S.watch.tag == tag)
end

local function setMismatch(server)
    if S.mismatch == nil then
        S.mismatch = { server = server }
        warn(string.format('Server protocol version mismatch: this addon speaks %s, the server reports version %s. Automatic sync stopped; update the client or the server module.',
            P.NAME, tostring(server)))
    end

    if syncActive() then
        finishSync('invalid', { reasons = { 'protocol version mismatch' }, mismatch = true })
    end

    if S.go ~= nil and S.go.state ~= 'queued' then
        finishGo({ status = 'invalid', reasons = { 'protocol version mismatch' } })
    end
end

local function outstanding(rid)
    if S.sync ~= nil and S.sync.rid == rid and (S.sync.state == 'sent' or S.sync.state == 'receiving') then
        return 'sync'
    end

    if S.go ~= nil and S.go.rid == rid and S.go.state == 'sent' then
        return 'go'
    end

    if S.watch ~= nil and S.watch.rid == rid and P.now() <= S.watch.untilAt then
        return 'watch'
    end

    if rid == '0000' then
        return 'none'
    end

    return nil
end

local function problem(op, text)
    S.stats.malformed = S.stats.malformed + 1

    local rec = (op == 'sync' and S.sync) or (op == 'go' and S.go) or nil

    if rec ~= nil and #rec.problems < 8 then
        rec.problems[#rec.problems + 1] = text
    end

    info('frame', 'FPX: discarded response: ' .. text)

    -- A damaged response for a trip in its correction window may have been a
    -- correction: the trip's final outcome is then not known (§4.6).
    if op == 'watch' and S.watch ~= nil then
        local w = S.watch
        S.watch = nil
        emit('onTravel', { status = 'invalid', correction = true, tag = w.tag, rid = w.rid, reasons = { text } })
    end
end

local function dropSlot(rid)
    if S.slots[rid] ~= nil then
        S.slots[rid] = nil
        S.nslots = S.nslots - 1
    end
end

local function complete(rid, slot, op)
    dropSlot(rid)

    local kind, len, sum = string.match(slot.parts[0], '^([STE]),(%d+),(%x+)$')

    if kind == nil or #sum ~= 8 or string.find(sum, '%u') then
        return problem(op, 'header')
    end

    len = tonumber(len)

    if len < 1 or len > P.MAX_BODY then
        return problem(op, 'body length')
    end

    local body = table.concat(slot.parts, '', 1, slot.total)

    if #body ~= len then
        return problem(op, 'length mismatch')
    end

    if P.adler32(body) ~= sum then
        S.stats.checksum = S.stats.checksum + 1
        return problem(op, 'checksum mismatch')
    end

    local fields, why = P.parseBody(body)

    if fields == nil then
        return problem(op, tostring(why))
    end

    S.stats.responses = S.stats.responses + 1

    if kind == 'E' and fields.e == 'VERSION' then
        return setMismatch(fields.sv or '?')
    end

    if op == 'none' then
        warn('The server could not read an FFXIPort request (' .. tostring(fields.e) .. ').')
        return
    end

    if op == 'sync' then
        if kind == 'S' then
            local expected = nil

            if type(P.localServerId) == 'function' then
                local ok, v = pcall(P.localServerId)

                if ok and type(v) == 'number' and v > 0 then
                    expected = v
                end
            end

            local staged, reasons = P.validateSnapshot(fields, expected)

            if staged == nil then
                return finishSync('invalid', { reasons = reasons, fields = fields })
            end

            if expected == nil then
                info('character', 'FPX: character id unknown locally; snapshot accepted without the character check.')
            end

            S.committed = staged -- one assignment: the whole snapshot or nothing
            return finishSync('ok', { staged = staged, fields = fields })
        elseif kind == 'E' then
            return finishSync('invalid', { reasons = { 'server refused the sync: ' .. tostring(fields.e) }, fields = fields, code = fields.e })
        end

        return finishSync('invalid', { reasons = { 'unexpected response kind ' .. kind } })
    end

    if op == 'watch' then
        -- §4.6: a correcting E supersedes the provisional T; a repeated T
        -- (server replay of the same id) changes nothing.
        local w = S.watch

        if kind == 'E' and w ~= nil then
            S.watch = nil
            emit('onTravel', { status = 'ok', kind = 'E', correction = true, tag = w.tag, rid = w.rid, fields = fields, reasons = {} })
        else
            S.stats.duplicates = S.stats.duplicates + 1
        end

        return
    end

    -- op == 'go'
    if kind == 'T' or kind == 'E' then
        return finishGo({ status = 'ok', kind = kind, fields = fields })
    end

    return finishGo({ status = 'invalid', reasons = { 'unexpected response kind ' .. kind } })
end

-----------------------------------------------------------------------------
-- Frames
-----------------------------------------------------------------------------

-- One frame line from the server. Returns true when it was an FPX frame.
function P.onFrameLine(line, t)
    if type(line) ~= 'string' or string.sub(line, 1, 4) ~= '#fpx' then
        return false
    end

    S.stats.frames = S.stats.frames + 1
    emit('onRecord', line)

    if #line > P.MAX_FRAME_LINE then
        S.stats.dropped = S.stats.dropped + 1
        info('frame', 'FPX: frame over length limit dropped')
        return true
    end

    local ver = string.match(line, '^#fpx(%d+) ')

    if ver ~= nil and tonumber(ver) ~= P.VERSION then
        setMismatch(ver)
        return true
    end

    local rid, seq, total, data = string.match(line, '^#fpx%d+ (%x%x%x%x) (%d%d?)/(%d%d?) (%S+)$')

    if rid == nil or string.find(rid, '%u') then
        S.stats.malformed = S.stats.malformed + 1
        info('frame', 'FPX: malformed frame dropped')
        return true
    end

    seq, total = tonumber(seq), tonumber(total)

    local op = outstanding(rid)

    if op == nil then
        S.stats.stale = S.stats.stale + 1
        info('stale', 'FPX: frame for request ' .. rid .. ' ignored (not outstanding).')
        return true
    end

    if total < 1 or total > P.MAX_FRAMES or seq > total or (seq > 0 and #data > P.MAX_CHUNK) then
        problem(op, 'frame numbering')
        dropSlot(rid)
        return true
    end

    local slot = S.slots[rid]

    if slot == nil then
        if S.nslots >= P.MAX_SLOTS then
            -- evict the oldest assembly
            local oldest, at = nil, nil

            for r, sl in pairs(S.slots) do
                if at == nil or sl.firstAt < at then
                    oldest, at = r, sl.firstAt
                end
            end

            dropSlot(oldest)
        end

        slot = { parts = {}, total = total, firstAt = t, count = 0 }
        S.slots[rid] = slot
        S.nslots = S.nslots + 1

        if op == 'sync' and S.sync.state == 'sent' then
            S.sync.state = 'receiving'
            emit('onSyncState', 'receiving', nil)
        end
    end

    if op == 'sync' then
        S.sync.frames = S.sync.frames + 1
    end

    if slot.total ~= total then
        S.stats.conflicts = S.stats.conflicts + 1
        problem(op, 'conflicting frame count')
        dropSlot(rid)
        return true
    end

    local prev = slot.parts[seq]

    if prev ~= nil then
        if prev == data then
            S.stats.duplicates = S.stats.duplicates + 1
            return true
        end

        S.stats.conflicts = S.stats.conflicts + 1
        problem(op, 'conflicting duplicate frame')
        dropSlot(rid)
        return true
    end

    slot.parts[seq] = data
    slot.count = slot.count + 1

    if slot.count == total + 1 then
        complete(rid, slot, op)
    end

    return true
end

-- Reads mode, speaker and text of an incoming 0x017 chat packet.
-- Layout (LSB GP_SERV_COMMAND_CHAT_STD, src/map/packets/s2c/0x017_chat_std.h):
--   0x00 header (id, size, sync), 0x04 Kind (u8), 0x05 Attr, 0x06 Data (u16),
--   0x08 sName[15], 0x17 Mes[<=150] (no terminator guaranteed; padding is 0).
-- Pure Lua: no dependency on the struct library.
function P.readChat(data)
    if type(data) ~= 'string' or #data < 0x17 then
        return nil
    end

    local mode = string.byte(data, 0x04 + 1)
    local name = string.sub(data, 0x08 + 1, 0x08 + 15)
    local msg  = string.sub(data, 0x17 + 1, 0x17 + P.MAX_MES)

    local nul = string.find(name, '\0', 1, true)
    if nul ~= nil then
        name = string.sub(name, 1, nul - 1)
    end

    nul = string.find(msg, '\0', 1, true)
    if nul ~= nil then
        msg = string.sub(msg, 1, nul - 1)
    end

    return mode, name, msg
end

local function localNameNow()
    if type(P.localName) ~= 'function' then
        return nil
    end

    local ok, v = pcall(P.localName)
    if ok and type(v) == 'string' and v ~= '' then
        return v
    end

    return nil
end

-- Why a '#fpx' chat packet is not a trusted server frame, or nil if it is.
-- Trusted: Kind == SYSTEM_3 (29) and a speaker that is empty or exactly the
-- local character's name. LSB's printToPlayer without a sender fills the
-- speaker field with the RECEIVING character's own name; other players' chat
-- carries their own name and a chat Kind (say, shout, tell, ...), never 29.
function P.rejectReason(mode, name)
    if not P.ACCEPT_MODES[mode] then
        return 'mode'
    end

    if name == '' then
        return nil
    end

    local me = localNameNow()
    if me == nil then
        return 'sender-unknown'
    end

    if name ~= me then
        return 'sender'
    end

    return nil
end

-- packet_in hook. Returns true when the packet was an FPX frame (then blocked).
function P.onPacket(e)
    if e == nil or e.id ~= 0x0017 then
        return false
    end

    S.stats.packets = S.stats.packets + 1

    local ok, mode, name, msg = pcall(P.readChat, e.data)

    if not ok or type(msg) ~= 'string' or string.sub(msg, 1, 4) ~= '#fpx' then
        return false
    end

    local why = P.rejectReason(mode, name)

    if why ~= nil then
        -- Looks like a frame but is not from the server channel: not trusted,
        -- not blocked (it stays visible as ordinary chat).
        S.stats.foreign = S.stats.foreign + 1
        S.lastForeign = { mode = mode, sender = name, reason = why }
        info('foreign', string.format('FPX: frame-like chat ignored (%s; mode %s, sender "%s").', why, tostring(mode), tostring(name)))
        return false
    end

    e.blocked = true
    P.onFrameLine(msg, P.now())
    return true
end

function P.lastForeign() return S.lastForeign end

-----------------------------------------------------------------------------
-- Tick: deadlines, dispatch, timeouts
-----------------------------------------------------------------------------

local function sendable()
    if type(P.canSend) ~= 'function' then
        return true
    end

    local ok, v = pcall(P.canSend)
    return ok and v == true
end

function P.tick(t)
    -- queued trip lines past their deadline are dropped unsent
    for i = #S.queue, 1, -1 do
        local e = S.queue[i]

        if e.deadline ~= nil and t > e.deadline then
            table.remove(S.queue, i)

            if e.kind == 'go' and S.go ~= nil and S.go.rid == e.rid then
                S.go = nil
            end

            emit('onExpired', e.tag, e.line, t)
        end
    end

    if #S.queue > 0 and sendable() and (S.lastSendAt == nil or (t - S.lastSendAt) >= P.SEND_GAP_MS) then
        local e = table.remove(S.queue, 1)

        emit('onBeforeDispatch', e.tag, e.line, t)

        local ok, err = pcall(P.dispatch, '/say ' .. e.line)

        if ok then
            S.lastSendAt = t

            if e.kind == 'sync' and S.sync ~= nil and S.sync.rid == e.rid then
                S.sync.state    = 'sent'
                S.sync.sentAt   = t
                S.sync.deadline = t + P.SYNC_TIMEOUT_MS
                emit('onSyncState', 'sent', nil)
            elseif e.kind == 'go' and S.go ~= nil and S.go.rid == e.rid then
                S.go.state    = 'sent'
                S.go.sentAt   = t
                S.go.deadline = t + P.GO_TIMEOUT_MS
            end

            emit('onSent', e.tag, e.line, t)
        else
            emit('onDispatchFailed', e.tag, e.line, t)

            if e.kind == 'sync' and S.sync ~= nil and S.sync.rid == e.rid then
                finishSync('send_failed', { reasons = { tostring(err) } })
            elseif e.kind == 'go' and S.go ~= nil and S.go.rid == e.rid then
                S.go = nil
                emit('onSendFailed', e.tag, err)
            end
        end
    end

    local s = S.sync

    if s ~= nil and (s.state == 'sent' or s.state == 'receiving') and t > s.deadline then
        dropSlot(s.rid)
        finishSync('timeout', nil)
    end

    local g = S.go

    if g ~= nil and g.state == 'sent' and t > g.deadline then
        dropSlot(g.rid)
        finishGo({ status = 'timeout' })
    end

    if S.watch ~= nil and t > S.watch.untilAt then
        S.watch = nil
    end

    for rid, slot in pairs(S.slots) do
        if (t - slot.firstAt) > P.SLOT_TTL_MS then
            dropSlot(rid)
        end
    end
end

-----------------------------------------------------------------------------
-- Diagnostics / lifecycle
-----------------------------------------------------------------------------

function P.committed()  return S.committed end
function P.lastResult() return S.lastResult end
function P.stats()      return S.stats end
function P.slotCount()  return S.nslots end

-- Logout, character change, load/unload. Request ids keep counting so an old
-- reply can never match a new request.
function P.reset()
    S = fresh(S.ridCounter, S.sid) -- new session id; request ids keep counting
end

return P
