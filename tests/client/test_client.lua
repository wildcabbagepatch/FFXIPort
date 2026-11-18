-- Client tests for the FPX/1 client (fpx.lua) and the adapted integration
-- modules (sync, model, travel, echo, chatlog, config), run end-to-end
-- against the real server module (fpxport.lua) over a simulated chat
-- transport. GPL-3.0-only, (C) 2026 wildthing.
local root = arg and arg[1] or '.'
package.path = root .. '/tests/lib/?.lua;' .. package.path

local H = require('harness')
local L = require('lsb_mock')
local A = require('ashita_mock')
local K = require('packets')

-- Server module first (installs its own globals: xi, Module).
L.installGlobals()
dofile(root .. '/server/modules/custom/late/fpxport.lua')
local SRV = xi.fpxport
local CMD = xi.module.registered.fpx

A.install(root)

local fpx     = require('ffxiport.fpx')
local model   = require('ffxiport.model')
local syncctl = require('ffxiport.sync')
local travel  = require('ffxiport.travel')
local echo    = require('ffxiport.echo')
local chatlog = require('ffxiport.chatlog')
local catalog = require('ffxiport.catalog')
local config  = require('ffxiport.config')

catalog.load()
config.init(catalog)

-----------------------------------------------------------------------------
-- Test world
-----------------------------------------------------------------------------

local W = {}

local zone = { episode = false, zone = 230, zoning = false }
function zone.inProgress() return zone.episode end
function zone.current() return zone.zone end
function zone.isZoning() return zone.zoning end

local function setClock(ms)
    W.t = ms
    A.clockMs = ms
    SRV.now = function () return math.floor(W.t / 1000) end
end

fpx.clock = function () return W.t end
fpx.canSend = function () return not zone.inProgress() end
fpx.localServerId = function () return W.serverId end
fpx.localName = function () return W.localName end

syncctl.init(fpx, model, zone)
travel.init({ catalog = catalog, model = model, config = config, protocol = fpx, zone = zone })

local function resetWorld(opts)
    opts = opts or {}
    setClock(100000)
    fpx.reset()
    model.clear()
    syncctl.resetSession()
    travel.reset()
    echo.clear()
    for k in pairs(SRV.sessions) do SRV.sessions[k] = nil end
    zone.episode, zone.zone, zone.zoning = false, opts.zone or 230, false
    W.player = L.player(opts)
    W.serverId = W.player.id
    W.sent, W.events, W.travelEvents, W.reports = {}, {}, {}, {}
    W.deliver = true       -- deliver frames to the client
    -- RC5: frames reach the client as real 0x017 packets through fpx.onPacket,
    -- with the speaker LSB uses for printToPlayer: the receiving character.
    W.viaPackets = true
    W.localName = 'Tester'
    W.packetKind = 29
    W.packetSender = 'Tester'
    W.unblockedFrames = 0
    W.mutate = nil         -- function(frames) -> frames
    W.serverUp = true
    W.logs = {}
    SRV.log = function (t) W.logs[#W.logs + 1] = t end -- server log lines (incidents) kept per test
    fpx.handlers = {
        onSyncState = function (state, result)
            W.events[#W.events + 1] = state
            syncctl.onSyncState(state, result)
        end,
        onTravel = function (r) W.travelEvents[#W.travelEvents + 1] = r; travel.onResponse(r) end,
        onSent = function (tag, line, t) travel.onSent(tag, line, t) end,
        onSendFailed = function (tag, err) travel.onSendFailed(tag, err) end,
        onExpired = function (tag, line, t) travel.onExpired(tag, line, t) end,
        onBeforeDispatch = echo.onBeforeDispatch,
        onDispatchFailed = echo.onDispatchFailed,
        onWarn = function (t) W.warn = t end,
    }
    syncctl.isReady = function () return true end
    -- mirrors FFXIPort.lua: sync outcomes may lift an unknown-trip block
    syncctl.handlers.onReport = function (state, result, origin)
        local _, req = fpx.syncState()
        travel.onSyncReport(state, origin, req)
    end
    travel.handlers.onReport = function (text, bad) W.reports[#W.reports + 1] = { text = text, bad = bad } end
    travel.handlers.onNeedSync = function () if not fpx.isBusy() then syncctl.request('auto', W.t) end end
end

fpx.dispatch = function (line)
    W.sent[#W.sent + 1] = line
    if not W.serverUp then return end
    local body = assert(string.match(line, '^/say !fpx (.*)$'), 'dispatched line shape')
    CMD.onTrigger(W.player, body)
    local frames = {}
    for _, e in ipairs(W.player:takePrinted()) do
        if string.sub(e.msg, 1, 4) == '#fpx' then frames[#frames + 1] = e.msg end
    end
    if W.mutate then frames = W.mutate(frames) end
    W.pending = frames
end

-- Advances time in 100 ms ticks, delivering server frames one tick after send.
local function run(ms)
    local stop = W.t + (ms or 100)
    repeat
        setClock(W.t + 100)
        fpx.tick(W.t)
        if W.pending and W.deliver then
            local f = W.pending
            W.pending = nil
            for _, line in ipairs(f) do
                if W.viaPackets then
                    local e = K.event(W.packetKind, W.packetSender, line)
                    fpx.onPacket(e)
                    if not e.blocked then W.unblockedFrames = W.unblockedFrames + 1 end
                else
                    fpx.onFrameLine(line, W.t)
                end
            end
        end
        syncctl.tick(W.t)
        travel.tick(W.t)
    until W.t >= stop
end

local function lastEvent() return W.events[#W.events] end
local function rowOf(tab, id) return catalog.get(tab, id) end
local function gate(name)
    for _, r in ipairs(catalog.rows('sp')) do if r.crystal == name then return r end end
end

local function bodyOf(frames)
    local parts, total = {}, 0
    for _, f in ipairs(frames) do
        local seq, tot, data = f:match('^#fpx1 %x+ (%d+)/(%d+) (%S+)$')
        if tonumber(seq) > 0 then parts[tonumber(seq)] = data end
        total = tonumber(tot)
    end
    return table.concat(parts, '', 1, total)
end

H.before = function () resetWorld() end

-----------------------------------------------------------------------------

H.describe('codec', function ()
    H.it('adler32 reference value and offers/bitmap parsing', function ()
        H.eq(fpx.adler32('Wikipedia'), '11e60398')
        local o = fpx.parseOffers('g500+c50')
        H.eq(#o, 2); H.eq(o[2].cur, 'c'); H.eq(o[2].amount, 50)
        H.eq(fpx.parseOffers('f0+g5'), nil); H.eq(fpx.parseOffers('g5+g6'), nil); H.eq(fpx.parseOffers('x5'), nil)
        H.eq(fpx.parseOffers('f1'), nil)
        local set, n = fpx.parseBitmap('7:12')
        H.eq(n, 7); H.truthy(set[0]); H.truthy(set[5]); H.falsy(set[1])
        H.eq(fpx.parseBitmap('7:1'), nil, 'short')
        H.eq(fpx.parseBitmap('6:0c'), nil, 'padding bits set')
        H.truthy(fpx.parseBitmap('6:f3'), 'ids 0-5 set')
        H.eq(fpx.parseBitmap('4:F'), nil, 'uppercase')
    end)

    H.it('request lines match the server grammar', function ()
        H.eq(fpx.buildSync('0a1f', 'a1b2c3d4e5f6'), '!fpx 1 a1b2c3d4e5f6 0a1f SYNC')
        H.eq(fpx.buildGo('0a20', { cat = 'R', dest = 3, cur = 'i', amount = 200 }, 'a1b2c3d4e5f6'), '!fpx 1 a1b2c3d4e5f6 0a20 GO R 3 i 200')
        H.truthy(fpx.sessionId():match('^' .. string.rep('%x', 12) .. '$'), 'session id shape')
        local req = SRV.parseRequest((fpx.buildGo('0a20', { cat = 'R', dest = 3, cur = 'i', amount = 200 }):gsub('^!fpx ', '')))
        H.eq(req.op, 'GO'); H.eq(req.dest, 3); H.eq(req.amount, 200)
    end)

    H.it('body parsing rejects duplicate keys and wrong version', function ()
        H.eq(fpx.parseBody('v=1;a=1;a=2'), nil)
        H.eq(fpx.parseBody('v=2;a=1'), nil)
        H.truthy(fpx.parseBody('v=1;a=1;zz=x~y'))
    end)
end)

H.describe('startup synchronization', function ()
    H.it('one initial sync after readiness settles, committed atomically to the model', function ()
        resetWorld({ hp = { 9, 46 }, sg = { 6 }, ki = { 'MEA_GATE_CRYSTAL' }, runic = 2 ^ 3 })
        run(1500)
        H.eq(#W.sent, 0, 'waits for settle')
        run(2000)
        H.eq(#W.sent, 1, 'one request')
        H.truthy(W.sent[1]:match('^/say !fpx 1 ' .. string.rep('%x', 12) .. ' %x%x%x%x SYNC$'))
        run(300)
        H.eq(lastEvent(), 'ok')
        H.truthy(model.hasData())
        H.eq(model.isUnlocked('hp', rowOf('hp', 9)), true)
        H.eq(model.isUnlocked('hp', rowOf('hp', 0)), false)
        H.eq(model.isUnlocked('sg', rowOf('sg', 6)), true)
        H.eq(model.isUnlocked('sp', gate('Mea')), true)
        H.eq(model.isUnlocked('sp', gate('Holla')), false)
        H.eq(model.isUnlocked('rp', rowOf('rp', 3)), true)
        H.eq(model.balance('gil'), 100000); H.eq(model.balance('is'), 5000)
        H.eq(syncctl.status().startup, 'requested')
        run(10000)
        H.eq(#W.sent, 1, 'no further automatic requests')
    end)

    H.it('every catalogue row resolves to a protocol id', function ()
        for _, tab in ipairs({ 'hp', 'sg', 'sp', 'rp' }) do
            for _, row in ipairs(catalog.rows(tab)) do
                local cat, id = model.protocolId(tab, row)
                H.truthy(cat and id, tab .. ' ' .. tostring(row.id))
                -- The test server mocks only a subset of LSB's survival guide map;
                -- full SG coverage is checked by tools/verify_catalog_vs_lsb.lua.
                if tab ~= 'sg' then
                    H.truthy(SRV.destination(cat, id), 'server knows ' .. tab .. ' ' .. tostring(row.id))
                end
            end
        end
    end)

    H.it('catalogue zones agree with the server destinations', function ()
        local bad = {}
        for _, tab in ipairs({ 'hp', 'sg', 'sp', 'rp' }) do
            for _, row in ipairs(catalog.rows(tab)) do
                local cat, id = model.protocolId(tab, row)
                local d = SRV.destination(cat, id)
                -- survival guides are mocked on the server side in tests (subset)
                if d and tab ~= 'sg' and d[5] ~= row.zone then bad[#bad + 1] = tab .. ':' .. row.id end
            end
        end
        H.eq(#bad, 0, table.concat(bad, ','))
    end)
end)

H.describe('zone changes and character switching', function ()
    H.it('auto re-sync after a completed zone change once answered', function ()
        run(3000); run(300)
        H.eq(lastEvent(), 'ok')
        local n = #W.sent
        zone.episode = true
        syncctl.onZoneComplete({ logout = false, viaFallback = false }, W.t)
        run(500)
        H.eq(#W.sent, n, 'held while zoning')
        zone.episode = false
        run(1000)
        H.eq(#W.sent, n + 1, 're-sync sent after zoning')
    end)

    H.it('fallback-released zone episodes do not auto sync', function ()
        run(3500)
        local n = #W.sent
        syncctl.onZoneComplete({ logout = false, viaFallback = true }, W.t)
        run(2000)
        H.eq(#W.sent, n)
    end)

    H.it('snapshot for another character is rejected and previous data kept', function ()
        run(3500)
        H.truthy(model.hasData())
        local rev = model.revision()
        W.serverId = 999 -- client now logged in as someone else
        syncctl.request('manual', W.t)
        run(500)
        H.eq(lastEvent(), 'invalid')
        H.eq(model.revision(), rev, 'model untouched')
        H.truthy(table.concat(fpx.lastResult().reasons, ';'):find('another character'))
    end)

    H.it('session reset clears data and starts a new initial sync', function ()
        run(3500)
        fpx.reset(); model.clear(); syncctl.resetSession(); travel.reset()
        H.falsy(model.hasData())
        H.eq(syncctl.status().startup, 'pending')
        run(3000)
        H.eq(lastEvent(), 'ok')
    end)
end)

H.describe('invalid, stale and duplicate responses', function ()
    H.it('checksum failure is discarded; timeout and one retry follow; data never half-applied', function ()
        run(3500) -- valid baseline
        local rev = model.revision()
        W.mutate = function (frames)
            frames[2] = frames[2]:gsub('g=100000', 'g=100001', 1)
            return frames
        end
        syncctl.request('manual', W.t)
        run(5500)
        H.eq(lastEvent(), 'timeout')
        H.eq(model.revision(), rev)
        H.truthy(fpx.stats().checksum >= 1)
        W.mutate = nil
        run(6000)
        H.eq(lastEvent(), 'ok', 'retry succeeded')
        H.eq(syncctl.status().counts.retry, 1)
    end)

    H.it('a structurally valid but semantically invalid snapshot is refused', function ()
        run(3500)
        local rev = model.revision()
        W.mutate = function (frames)
            local body = bodyOf(frames):gsub(';uR=7:%x+', ';uR=7:zz')
            local rid = frames[1]:match('^#fpx1 (%x+)')
            return SRV.frame(rid, 'S', body)
        end
        syncctl.request('manual', W.t)
        run(500)
        H.eq(lastEvent(), 'invalid')
        H.eq(model.revision(), rev)
    end)

    H.it('out-of-order and duplicated frames still assemble', function ()
        W.mutate = function (frames)
            local out = {}
            for i = #frames, 1, -1 do out[#out + 1] = frames[i]; out[#out + 1] = frames[i] end
            return out
        end
        run(3500)
        H.eq(lastEvent(), 'ok')
        H.truthy(fpx.stats().duplicates >= 1)
    end)

    H.it('conflicting duplicate discards the response', function ()
        W.mutate = function (frames)
            local bad = frames[2]:sub(1, -2) .. (frames[2]:sub(-1) == 'X' and 'Y' or 'X')
            table.insert(frames, 2, bad)
            return frames
        end
        run(3500)
        H.truthy(fpx.stats().conflicts >= 1, 'conflict counted')
        H.falsy(model.hasData(), 'nothing committed from the conflicting response')
    end)

    H.it('a delayed reply to an old request id is ignored', function ()
        run(3500)
        W.deliver = false
        syncctl.request('manual', W.t)
        run(5500)
        H.eq(lastEvent(), 'timeout')
        local late = W.pending
        W.pending = nil
        W.deliver = true
        local rev = model.revision()
        for _, f in ipairs(late) do fpx.onFrameLine(f, W.t) end
        H.eq(model.revision(), rev, 'late reply not applied')
        H.truthy(fpx.stats().stale >= #late)
    end)

    H.it('no response at all: timeout, one retry, then give up', function ()
        W.serverUp = false
        local retries = syncctl.status().counts.retry -- counters are cumulative across sessions
        run(3000)
        run(5200)
        H.eq(lastEvent(), 'timeout')
        run(5000); run(5300)
        H.eq(lastEvent(), 'timeout')
        H.eq(syncctl.status().counts.retry - retries, 1)
        H.eq(#W.sent, 2, 'initial request plus exactly one retry')
        H.truthy(model.status().text:find('did not answer'))
        local n = #W.sent
        run(20000)
        H.eq(#W.sent, n, 'no endless retries')
    end)

    H.it('duplicate sync requests are refused while one is outstanding', function ()
        local ok1 = syncctl.request('manual', W.t)
        local ok2, why = syncctl.request('manual', W.t)
        H.truthy(ok1); H.falsy(ok2); H.eq(why, 'queued')
    end)
end)

H.describe('bounds', function ()
    H.it('oversize frame lines are dropped', function ()
        fpx.onFrameLine('#fpx1 0001 1/1 ' .. string.rep('a', 230), W.t)
        H.eq(fpx.stats().dropped, 1)
    end)

    H.it('too many frames, oversize bodies and bad numbering are rejected', function ()
        syncctl.request('manual', W.t)
        W.deliver = false
        run(200)
        local rid = W.sent[#W.sent]:match('!fpx 1 %x+ (%x+)')
        fpx.onFrameLine('#fpx1 ' .. rid .. ' 1/17 abc', W.t)
        H.eq(fpx.slotCount(), 0)
        fpx.onFrameLine('#fpx1 ' .. rid .. ' 0/1 S,4000,00000000', W.t)
        fpx.onFrameLine('#fpx1 ' .. rid .. ' 1/1 v=1', W.t)
        H.eq(fpx.slotCount(), 0)
        H.truthy(fpx.stats().malformed >= 2)
    end)

    H.it('server frames never exceed the 150-byte LSB chat message field', function ()
        resetWorld({ hp = { 0, 5, 9, 14, 17, 39, 59, 121 }, sg = { 0, 6, 11, 40, 97 }, runic = 126 })
        syncctl.request('manual', W.t)
        W.deliver = false
        run(200)
        H.truthy(#W.pending >= 2, 'a multi-frame snapshot')
        for _, f in ipairs(W.pending) do H.truthy(#f <= 150, 'frame length ' .. #f) end
        W.deliver = true
        run(300)
        H.eq(lastEvent(), 'ok')
    end)
end)

-----------------------------------------------------------------------------
-- RC5: live 0x017 reception (in-game finding: speaker = own character name)
-----------------------------------------------------------------------------

-- Frames of one server response for the current outstanding sync, unsent.
local function pendingSyncFrames()
    W.deliver = false
    syncctl.request('manual', W.t)
    run(200)
    local frames = W.pending
    W.pending = nil
    W.deliver = true
    return frames
end

local function deliverPackets(frames, kind, sender)
    local blocked = 0
    for _, line in ipairs(frames) do
        local e = K.event(kind, sender, line)
        if fpx.onPacket(e) and e.blocked then blocked = blocked + 1 end
    end
    return blocked
end

H.describe('live 0x017 reception', function ()
    H.it('fixture matches the observed packet: own name as sender, mode 29, frame text at 0x17', function ()
        local e = K.event(29, 'Tuna', '#fpx1 00aa 0/1 S,3,00000000')
        local mode, name, msg = fpx.readChat(e.data)
        H.eq(mode, 29); H.eq(name, 'Tuna'); H.eq(msg, '#fpx1 00aa 0/1 S,3,00000000')
        H.eq(e.data:byte(1), 0x17); H.eq(#e.data % 4, 0)
    end)

    H.it('reads a 150-byte message that has no terminating NUL', function ()
        local text = '#fpx1 00aa 1/1 ' .. string.rep('x', 135)
        H.eq(#text, 150)
        local data = K.chat(29, 'Tester', text)
        H.eq(#data, 4 + 4 + 15 + 150 + 3)
        local _, _, msg = fpx.readChat(data)
        H.eq(msg, text)
    end)

    H.it('full startup sync through the packet handler with the local name as sender; frames hidden', function ()
        W.localName, W.packetSender = 'Tuna', 'Tuna'
        run(3500)
        H.eq(lastEvent(), 'ok'); H.truthy(model.hasData())
        H.eq(W.unblockedFrames, 0, 'every accepted frame is blocked from the chat log')
        local s = fpx.stats()
        H.eq(s.foreign, 0); H.truthy(s.frames >= 2); H.eq(s.responses, 1)
    end)

    H.it('the in-game failure: RC4 rejected own-name frames (regression)', function ()
        W.localName, W.packetSender = 'Tuna', 'Tuna'
        local frames = pendingSyncFrames()
        H.eq(deliverPackets(frames, 29, 'Tuna'), #frames, 'all frames accepted and blocked')
        H.eq(lastEvent(), 'ok'); H.eq(fpx.stats().foreign, 0)
    end)

    H.it('empty-sender frames are still accepted', function ()
        local frames = pendingSyncFrames()
        H.eq(deliverPackets(frames, 29, ''), #frames)
        H.eq(lastEvent(), 'ok')
    end)

    H.it('wrong sender: not trusted, not blocked, counted as foreign', function ()
        local frames = pendingSyncFrames()
        H.eq(deliverPackets(frames, 29, 'Mallory'), 0)
        H.eq(fpx.stats().foreign, #frames); H.eq(fpx.lastForeign().reason, 'sender')
        H.falsy(model.hasData())
        run(5200)
        H.eq(lastEvent(), 'timeout')
    end)

    H.it('a sender that differs only in case is not trusted', function ()
        W.localName = 'Tuna'
        local frames = pendingSyncFrames()
        H.eq(deliverPackets(frames, 29, 'tuna'), 0)
        H.eq(fpx.lastForeign().reason, 'sender')
    end)

    H.it('wrong channel: own say, tell or party lines are never protocol frames', function ()
        local frames = pendingSyncFrames()
        for _, kind in ipairs({ 0, 1, 3, 4, 5, 6, 7, 13, 26, 30 }) do
            H.eq(deliverPackets(frames, kind, 'Tester'), 0, 'kind ' .. kind)
        end
        H.eq(fpx.lastForeign().reason, 'mode'); H.falsy(model.hasData())
    end)

    H.it('unknown local name: own-name frames are not trusted (no guessing)', function ()
        W.localName = nil
        local frames = pendingSyncFrames()
        H.eq(deliverPackets(frames, 29, 'Tester'), 0)
        H.eq(fpx.lastForeign().reason, 'sender-unknown')
    end)

    H.it('out-of-order and duplicated packets assemble once', function ()
        local frames = pendingSyncFrames()
        local shuffled = {}
        for i = #frames, 1, -1 do shuffled[#shuffled + 1] = frames[i]; shuffled[#shuffled + 1] = frames[i] end
        deliverPackets(shuffled, 29, 'Tester')
        H.eq(lastEvent(), 'ok'); H.eq(fpx.stats().responses, 1); H.truthy(fpx.stats().duplicates >= 1)
    end)

    H.it('wrong request id: hidden protocol noise, never applied', function ()
        local frames = pendingSyncFrames()
        local forged = {}
        for i, f in ipairs(frames) do forged[i] = (f:gsub('^#fpx1 %x%x%x%x', '#fpx1 beef')) end
        H.eq(deliverPackets(forged, 29, 'Tester'), #forged, 'trusted channel: blocked')
        H.falsy(model.hasData()); H.truthy(fpx.stats().stale >= #forged)
    end)

    H.it('bad checksum on the trusted channel is rejected (no partial apply)', function ()
        local frames = pendingSyncFrames()
        frames[2] = frames[2]:gsub('g=100000', 'g=100001', 1)
        deliverPackets(frames, 29, 'Tester')
        H.falsy(model.hasData()); H.eq(fpx.stats().checksum, 1)
    end)

    H.it('malformed or forged-looking frame text is blocked as noise and changes nothing', function ()
        local bad = { '#fpx1 zzzz 0/1 S,3,00000000', '#fpx1 0001 0/99 x', '#fpxX', '#fpx1 0001 1/1 has space inside' }
        for _, line in ipairs(bad) do
            local e = K.event(29, 'Tester', line)
            fpx.onPacket(e)
            H.truthy(e.blocked, line)
        end
        H.falsy(model.hasData())
    end)

    H.it('ordinary chat is never blocked: other players, own say, server notices', function ()
        local cases = {
            { 0, 'Bob', 'hello there' },
            { 0, 'Tester', 'my own say line' },
            { 3, 'Alice', '#fpx is a strange word' },
            { 29, 'Tester', 'FFXIPort: travel failed on the server; your payment was refunded.' },
            { 29, '', 'Server maintenance in 10 minutes.' },
            { 0, 'Mallory', '#fpx1 0001 0/1 S,3,00000000' },
        }
        for _, c in ipairs(cases) do
            local e = K.event(c[1], c[2], c[3])
            H.falsy(fpx.onPacket(e), c[3]); H.falsy(e.blocked, c[3])
        end
    end)

    H.it('travel works end to end through the packet handler with the own-name sender', function ()
        resetWorld({ hp = { 9 } })
        W.localName, W.packetSender = 'Tuna', 'Tuna'
        if not A.settings.logged_in then A.settings.switch('Tester') end
        run(3500)
        H.eq(lastEvent(), 'ok')
        local ok = travel.go('hp', 9, 'gil')
        H.truthy(ok)
        run(400)
        H.eq(travel.state(), 'accepted'); H.eq(W.player.gil, 99000); H.eq(W.unblockedFrames, 0)
    end)
end)

H.describe('version mismatch', function ()
    H.it('a frame of another version stops automatic sync', function ()
        syncctl.request('manual', W.t)
        W.deliver = false
        run(200)
        fpx.onFrameLine('#fpx2 0001 0/1 S,3,00000000', W.t)
        H.truthy(fpx.versionMismatch())
        H.eq(lastEvent(), 'invalid')
        H.truthy(W.warn and W.warn:find('mismatch'))
        local n = #W.sent
        syncctl.onZoneComplete({ logout = false }, W.t)
        run(5000)
        H.eq(#W.sent, n, 'no automatic requests')
        local ok, why = syncctl.request('manual', W.t)
        H.falsy(ok); H.eq(why, 'version mismatch')
    end)

    H.it('server E VERSION is handled the same way', function ()
        W.mutate = function (frames)
            local rid = frames[1]:match('^#fpx1 (%x+)')
            local k, b = SRV.buildError('VERSION')
            return SRV.frame(rid, k, b)
        end
        run(3500)
        H.truthy(fpx.versionMismatch())
        H.eq(fpx.versionMismatch().server, '1')
    end)
end)

-----------------------------------------------------------------------------
-- Travel
-----------------------------------------------------------------------------

local function synced(opts)
    resetWorld(opts)
    config_login()
    run(3500)
    assert(lastEvent() == 'ok', 'baseline sync')
end

function config_login()
    if not A.settings.logged_in then A.settings.switch('Tester') end
end

local function goAndWait(tab, row, method)
    local ok, why = travel.go(tab, row.id, method)
    H.truthy(ok, 'go queued: ' .. tostring(why))
    run(400)
    return W.travelEvents[#W.travelEvents]
end

H.describe('travel: all categories and payment methods', function ()
    H.it('Home Point with gil and with CP; price text from server offers', function ()
        synced({ hp = { 9, 55 }, zone = 230 })
        local q = travel.quote('hp', rowOf('hp', 9), 230, 'gil')
        H.eq(travel.priceText(q), '1,000 gil')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 55), 230, 'cp')), '100 CP')
        local r = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r.kind, 'T'); H.eq(travel.state(), 'accepted')
        H.eq(W.player.gil, 99000); H.eq(model.balance('gil'), 99000)
        H.eq(W.player.moved[5], 234)
        zone.episode = true; run(200); zone.episode = false; run(200)
        H.eq(travel.state(), 'idle')
        H.eq(W.reports[#W.reports].text, 'Travel complete (zone change finished).')
        run(6000)
        W.player.zone = 230
        local r2 = goAndWait('hp', rowOf('hp', 55), 'cp')
        H.eq(r2.kind, 'T'); H.eq(W.player.cp, 4900)
    end)

    H.it('free Home Point inside the city group sends f 0', function ()
        synced({ hp = { 5 }, zone = 230 })
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 5), 230, 'cp')), 'Free')
        local r = goAndWait('hp', rowOf('hp', 5), 'cp')
        H.eq(r.kind, 'T'); H.eq(r.fields.pay, 'f0'); H.eq(W.player.gil, 100000); H.eq(W.player.cp, 5000)
        H.truthy(W.sent[#W.sent]:match('GO H 5 f 0$'))
    end)

    H.it('Survival Guide with CP', function ()
        synced({ sg = { 6 } })
        local r = goAndWait('sg', rowOf('sg', 6), 'cp')
        H.eq(r.kind, 'T'); H.eq(W.player.cp, 4900); H.eq(W.player.moved[5], 100)
    end)

    H.it('Gate Crystal with gil (protocol id from crystal name)', function ()
        synced({ ki = { 'VAHZL_GATE_CRYSTAL' } })
        local r = goAndWait('sp', gate('Vahzl'), 'gil')
        H.eq(r.kind, 'T'); H.truthy(W.sent[#W.sent]:match('GO G 3 g 1000$')); H.eq(W.player.moved[5], 112)
    end)

    H.it('Runic Portal with Imperial Standing and with gil', function ()
        synced({ runic = 2 ^ 6 + 2 ^ 1 })
        H.eq(travel.priceText(travel.quote('rp', rowOf('rp', 6), 230, 'is')), '100 IS')
        local r = goAndWait('rp', rowOf('rp', 6), 'is')
        H.eq(r.kind, 'T'); H.eq(W.player.is, 4900); H.eq(model.balance('is'), 4900)
        zone.episode = true; run(200); zone.episode = false; run(6000)
        local r2 = goAndWait('rp', rowOf('rp', 1), 'gil')
        H.eq(r2.kind, 'T'); H.eq(W.player.gil, 99000)
    end)
end)

H.describe('travel: refusals and currency safety', function ()
    H.it('insufficient funds: refused, nothing charged, balance shown', function ()
        synced({ hp = { 9 }, gil = 400 })
        local r = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r.kind, 'E'); H.eq(r.fields.e, 'FUNDS')
        H.eq(W.player.gil, 400); H.eq(travel.state(), 'idle')
        H.truthy(W.reports[#W.reports].text:find('1,000 gil or 100 CP'), 'current price shown')
        H.truthy(W.reports[#W.reports].bad)
        H.truthy(W.reports[#W.reports].text:find('Not enough funds'))
    end)

    H.it('price changed on the server: PRICE refusal, nothing charged, prices refreshed', function ()
        synced({ hp = { 9 } })
        SRV.config.prices.H[1].amount = 1200 -- server-side price change after the sync
        SRV.applyConfig()                     -- as on a module reload
        local n = #W.sent
        local r = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r.fields.e, 'PRICE'); H.eq(W.player.gil, 100000)
        run(1500)
        H.truthy(#W.sent >= n + 2, 'refresh sync requested')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 9), 230, 'gil')), '1,200 gil')
        SRV.config.prices.H[1].amount = 1000
        SRV.applyConfig()
    end)

    H.it('state refusal (engaged) charges nothing', function ()
        synced({ hp = { 9 } })
        W.player.engaged = true
        local r = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r.fields.e, 'STATE'); H.eq(W.player.gil, 100000)
    end)

    H.it('locked destinations cannot be submitted locally', function ()
        synced({})
        local ok, why = travel.go('hp', 9, 'gil')
        H.falsy(ok); H.truthy(why:find('not been registered'))
        H.eq(#W.travelEvents, 0)
    end)

    H.it('a second trip while one is outstanding is refused locally', function ()
        synced({ hp = { 9, 14 } })
        W.deliver = false
        H.truthy(travel.go('hp', 9, 'gil'))
        local ok, why = travel.go('hp', 14, 'gil')
        H.falsy(ok); H.truthy(why)
        local ok2 = fpx.requestGo({ cat = 'H', dest = 14, cur = 'g', amount = 500 }, 'x', W.t + 1000)
        H.falsy(ok2)
    end)
end)

H.describe('travel: failed or interrupted', function ()
    H.it('no answer: unknown outcome, never retried, refresh sync lifts the block', function ()
        synced({ hp = { 9 } })
        W.deliver = false
        H.truthy(travel.go('hp', 9, 'gil'))
        local gos = 0
        run(8600)
        for _, l in ipairs(W.sent) do if l:find(' GO ') then gos = gos + 1 end end
        H.eq(gos, 1, 'GO never re-sent')
        H.eq(W.travelEvents[#W.travelEvents].status, 'timeout')
        H.eq(travel.state(), 'unknown')
        W.deliver = true
        run(1500)
        H.eq(lastEvent(), 'ok')
        run(200)
        H.eq(travel.state(), 'idle')
    end)

    H.it('zone change before the answer: unknown, a later reply is not applied', function ()
        synced({ hp = { 9 } })
        W.deliver = false
        H.truthy(travel.go('hp', 9, 'gil'))
        run(200)
        zone.episode = true
        run(200)
        H.eq(travel.state(), 'unknown')
        local balance = model.balance('gil')
        local late = W.pending
        W.pending = nil
        for _, f in ipairs(late) do fpx.onFrameLine(f, W.t) end
        H.eq(travel.state(), 'unknown', 'still unknown')
        H.eq(model.balance('gil'), balance, 'balances not applied from the unmatched reply')
    end)

    H.it('queued trip is cancelled when a zone change starts before sending', function ()
        synced({ hp = { 9 } })
        zone.episode = true
        H.falsy(travel.go('hp', 9, 'gil'), 'zoning blocks submit')
        zone.episode = false
        H.truthy(travel.go('hp', 9, 'gil'))
        zone.episode = true
        travel.tick(W.t)
        H.eq(travel.state(), 'idle')
        H.eq(fpx.queueLength(), 0)
        H.truthy(W.reports[#W.reports].text:find('Nothing was requested'))
    end)

    H.it('server-side move failure: correction E INTERNAL ends the accepted trip as failed + refunded', function ()
        synced({ hp = { 9 } })
        W.player.moveError = true
        goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(W.player.gil, 100000, 'refunded on server')
        H.eq(travel.state(), 'idle')
        local last = W.reports[#W.reports]
        H.truthy(last.bad); H.truthy(last.text:find('refund confirmed'))
        H.eq(model.balance('gil'), 100000, 'model shows the refunded balance')
        run(9000)
        for _, rep in ipairs(W.reports) do H.falsy(rep.text:find('Travel complete'), 'never reported complete') end
    end)
end)

-----------------------------------------------------------------------------
-- RC3: final outcome and correction (PROTOCOL-FPX1.md §4.6)
-----------------------------------------------------------------------------

local function noSuccessReported()
    for _, rep in ipairs(W.reports) do
        H.falsy(rep.text:find('Travel complete'), 'success never reported: ' .. rep.text)
        H.falsy(rep.text:find('refund confirmed'), 'refund never claimed: ' .. rep.text)
    end
end

H.describe('travel: final outcome and corrections', function ()
    H.it('correction E UNSURE: uncertain outcome, reconciliation required, never success or refund', function ()
        synced({ hp = { 9 } })
        W.player.faults.setPos = function () return 'before' end
        W.player.faults.addGil = function () return 'before' end
        goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(travel.state(), 'unknown')
        local st = travel.status()
        H.truthy(st.reconcile, 'reconcile record'); H.truthy(st.reconcile.rid)
        H.truthy(W.reports[#W.reports].text:find('UNCERTAIN'))
        run(9000)
        noSuccessReported()
        H.truthy(travel.status().reconcile, 'reconcile record kept after the refresh')
    end)

    H.it('E UNSURE without a prior T (debit outcome unknown): uncertain, reconciliation required', function ()
        synced({ hp = { 9 } })
        W.player.faults.delGil = function (self) self.debited = true; return 'after' end
        W.player.faults.getGil = function (self) if self.debited then return 'before' end end
        local r = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r.fields.e, 'UNSURE'); H.eq(travel.state(), 'unknown'); H.truthy(travel.status().reconcile)
        noSuccessReported()
    end)

    H.it('an unreadable correction makes the outcome uncertain, not successful', function ()
        synced({ hp = { 9 } })
        W.player.moveError = true
        W.mutate = function (frames)
            if #frames > 2 then frames[#frames] = frames[#frames]:gsub('e=INTERNAL', 'e=INTERNAM') end
            return frames
        end
        goAndWait('hp', rowOf('hp', 9), 'gil')
        W.mutate = nil
        H.eq(travel.state(), 'unknown'); H.truthy(travel.status().reconcile)
        noSuccessReported()
    end)

    H.it('a lost correction for a cross-zone trip is never reported as success', function ()
        synced({ hp = { 9 } })
        W.player.moveError = true
        W.mutate = function (frames)
            local keep = {}
            for _, f in ipairs(frames) do if f:find(' 0/') and f:find(' E,') then break end; keep[#keep + 1] = f end
            return keep -- T only: the correction E is lost in transit
        end
        goAndWait('hp', rowOf('hp', 9), 'gil')
        W.mutate = nil
        H.eq(travel.state(), 'accepted')
        run(9000)
        H.eq(travel.state() == 'unknown' or travel.status().reconcile ~= nil, true)
        H.truthy(travel.status().reconcile, 'expected zone change missing -> reconcile')
        noSuccessReported()
    end)

    H.it('same-zone destination completes after the correction window without a zone change', function ()
        synced({ hp = { 59, 60 }, zone = 130 }) -- Ru'Aun Gardens #1 -> #3, both zone 130
        local r = goAndWait('hp', rowOf('hp', 60), 'gil')
        H.eq(r.kind, 'T'); H.eq(travel.state(), 'accepted')
        run(5000)
        H.eq(travel.state(), 'accepted', 'not complete while the correction window is open')
        run(4000)
        H.eq(travel.state(), 'idle')
        H.eq(W.reports[#W.reports].text, 'Travel complete (move within the same zone).')
        H.eq(travel.status().reconcile, nil)
    end)

    H.it('a duplicate T inside the correction window changes nothing', function ()
        synced({ hp = { 9 } })
        local frames
        W.mutate = function (f) frames = f; return f end
        goAndWait('hp', rowOf('hp', 9), 'gil')
        W.mutate = nil
        for _, f in ipairs(frames) do fpx.onFrameLine(f, W.t) end
        H.eq(travel.state(), 'accepted'); H.eq(W.player.gil, 99000)
        zone.episode = true; run(200); zone.episode = false; run(200)
        H.eq(travel.state(), 'idle'); H.eq(travel.status().reconcile, nil)
    end)

    H.it('a correction arriving after the zone change started is ignored (window closed)', function ()
        synced({ hp = { 9 } })
        goAndWait('hp', rowOf('hp', 9), 'gil')
        zone.episode = true; run(200)
        H.falsy(fpx.correctionOpen())
        local rid = travel.status().trip.rid
        local k, b = SRV.buildError('INTERNAL')
        for _, f in ipairs(SRV.frame(rid, k, b)) do fpx.onFrameLine(f, W.t) end
        zone.episode = false; run(200)
        H.eq(W.reports[#W.reports].text, 'Travel complete (zone change finished).')
    end)
end)

-----------------------------------------------------------------------------
-- RC4: rapid addon reloads must not collide with server replay entries
-----------------------------------------------------------------------------

-- Loads a fresh copy of ffxiport.fpx as an addon reload does (new Lua
-- state), at the given client clock and with os.time() frozen.
local function freshLoad(clockMs, frozenTime)
    local savedTime, savedLoaded = os.time, package.loaded['ffxiport.fpx']
    os.time = function () return frozenTime end
    A.clockMs = clockMs
    package.loaded['ffxiport.fpx'] = nil
    local mod = require('ffxiport.fpx')
    package.loaded['ffxiport.fpx'] = savedLoaded
    os.time = savedTime
    return mod
end

local function lastRid() return W.sent[#W.sent]:match('!fpx 1 %x+ (%x+)') end
local function lastSid() return W.sent[#W.sent]:match('!fpx 1 (%x+) ') end

-- Simulates "/addon reload" for the modules under test: new FPX session id,
-- all client state dropped. forcedRid makes the next request id repeat.
local function reloadClient(forcedRidCounter)
    fpx.reset(); model.clear(); syncctl.resetSession(); travel.reset(); echo.clear()
    if forcedRidCounter then fpx._setRidCounter(forcedRidCounter) end
end

H.describe('rapid addon reload (request id reuse)', function ()
    H.it('two fresh loads in the same second get different session ids', function ()
        local a = freshLoad(5000000, 1800000000)
        local b = freshLoad(5000017, 1800000000) -- 17 ms later, same os.time() second
        H.truthy(a.sessionId() ~= b.sessionId(), a.sessionId() .. ' vs ' .. b.sessionId())
        local c = freshLoad(5000017 + 4294967296, 1800000000) -- clock wrapped: random part still decides
        H.truthy(c.sessionId():match('^' .. string.rep('%x', 12) .. '$'))
    end)

    H.it('a session reset within one load also gets a new session id', function ()
        local before = fpx.sessionId()
        fpx.reset()
        H.truthy(fpx.sessionId() ~= before)
    end)

    H.it('SYNC: reloaded client reusing a request id gets the current balances, not the old replay', function ()
        synced({ hp = { 9 } })
        local rid, sid = lastRid(), lastSid()
        H.eq(model.balance('gil'), 100000)
        W.player.gil = 61234 -- balance changes between the two loads
        reloadClient(tonumber(rid, 16) - 1) -- the next request id repeats the old one
        run(3500)
        H.eq(lastRid(), rid, 'request id really repeats'); H.truthy(lastSid() ~= sid, 'session id differs')
        H.eq(lastEvent(), 'ok'); H.eq(model.balance('gil'), 61234)
    end)

    H.it('GO: reloaded client reusing a request id travels as a new trip and is charged once for it', function ()
        synced({ hp = { 9, 14 } })
        local r1 = goAndWait('hp', rowOf('hp', 9), 'gil')
        H.eq(r1.kind, 'T'); H.eq(W.player.gil, 99000)
        local goRid, goSid = lastRid(), lastSid()
        zone.episode = true; run(200); zone.episode = false; run(200)
        -- reload a few seconds later (inside the server's 30 s replay window)
        W.player.zone, W.player.moved, zone.zone = 230, nil, 230
        W.player.gil = 50000
        reloadClient()
        run(3500) -- initial sync of the new session
        H.eq(lastEvent(), 'ok'); H.eq(model.balance('gil'), 50000)
        run(2000) -- past the per-character 5 s cooldown, still inside the 30 s replay window
        fpx._setRidCounter(tonumber(goRid, 16) - 1) -- the trip reuses the old request id
        local r2 = goAndWait('hp', rowOf('hp', 14), 'gil')
        H.eq(lastRid(), goRid, 'request id really repeats'); H.truthy(lastSid() ~= goSid)
        H.eq(r2.fields.e, nil, 'refusal: ' .. tostring(r2.fields.e)); H.eq(r2.kind, 'T'); H.eq(r2.fields.d, '14', 'answer belongs to the new trip')
        H.eq(W.player.gil, 49000, 'charged exactly once for the new trip'); H.eq(W.player.moved[5], 236)
        H.eq(model.balance('gil'), 49000)
    end)

    H.it('a genuine retransmission in the same session is still replayed (no double charge)', function ()
        synced({ hp = { 9 } })
        goAndWait('hp', rowOf('hp', 9), 'gil')
        local line = W.sent[#W.sent]:gsub('^/say !fpx ', '')
        W.player.zone, W.player.moved = 230, nil
        CMD.onTrigger(W.player, line) -- the same request arrives again
        H.eq(W.player.gil, 99000); H.eq(W.player.moved, nil)
        W.player:takePrinted()
    end)
end)
H.describe('pricing in the client', function ()
    H.it('client quotes equal the server offers for every catalogue destination', function ()
        synced({ zone = 230 })
        local snap = fpx.committed()
        local cur = { gil = 'g', cp = 'c', is = 'i' }
        for _, tab in ipairs({ 'hp', 'sp', 'rp' }) do
            for _, row in ipairs(catalog.rows(tab)) do
                local cat, id = model.protocolId(tab, row)
                local server = SRV.offers(W.player, cat, id, {})
                for _, m in ipairs(travel.methodsFor(tab)) do
                    local q = travel.quote(tab, row, 230, m)
                    if server[1].cur == 'f' then
                        H.truthy(q.free, tab .. ' ' .. row.id .. ' free')
                    else
                        local want
                        for _, o in ipairs(server) do if o.cur == cur[m] then want = o.amount end end
                        H.eq(q.amount, want, tab .. ' ' .. row.id .. ' ' .. m)
                    end
                end
            end
        end
        H.truthy(snap)
    end)

    H.it('confirmed prices are displayed; same-city destinations show Free', function ()
        synced({ zone = 230 })
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 9), 230, 'gil')), '1,000 gil')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 9), 230, 'cp')), '100 CP')
        H.eq(travel.priceText(travel.quote('sp', gate('Holla'), 230, 'cp')), '100 CP')
        H.eq(travel.priceText(travel.quote('rp', rowOf('rp', 1), 230, 'gil')), '1,000 gil')
        H.eq(travel.priceText(travel.quote('rp', rowOf('rp', 1), 230, 'is')), '100 IS')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 5), 230, 'gil')), 'Free')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 0), 230, 'cp')), 'Free')
        H.eq(travel.priceText(travel.quote('sg', rowOf('sg', 0), 230, 'gil')), 'Free')
    end)

    H.it('custom server prices reach the client preview and are what the client sends', function ()
        SRV.config.prices.S = { { cur = 'g', amount = 2500 }, { cur = 'c', amount = 40 } }
        SRV.applyConfig()
        synced({ sg = { 6 }, zone = 230 })
        H.eq(travel.priceText(travel.quote('sg', rowOf('sg', 6), 230, 'gil')), '2,500 gil')
        H.eq(travel.priceText(travel.quote('sg', rowOf('sg', 6), 230, 'cp')), '40 CP')
        local r = goAndWait('sg', rowOf('sg', 6), 'cp')
        H.eq(r.kind, 'T'); H.truthy(W.sent[#W.sent]:match('GO S 6 c 40$')); H.eq(W.player.cp, 4960)
        SRV.config.prices.S = { { cur = 'g', amount = 1000 }, { cur = 'c', amount = 100 } }
        SRV.applyConfig()
    end)

    H.it("from Chateau d'Oraguille (no Home Point) San d'Oria is free and other cities are paid", function ()
        synced({ hp = { 0, 9 }, zone = 233, gil = 0, cp = 0 })
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 0), 233, 'gil')), 'Free')
        H.eq(travel.priceText(travel.quote('hp', rowOf('hp', 9), 233, 'gil')), '1,000 gil')
        local r = goAndWait('hp', rowOf('hp', 0), 'gil')
        H.eq(r.kind, 'T'); H.eq(r.fields.pay, 'f0'); H.eq(W.player.gil, 0); H.eq(W.player.cp, 0)
        H.truthy(W.sent[#W.sent]:match('GO H 0 f 0$'))
    end)
end)

-----------------------------------------------------------------------------
-- Echo suppression, quiet chat, favourites
-----------------------------------------------------------------------------

H.describe('quiet chat and echo suppression', function ()
    H.it('own FPX request echoes are hidden in quiet only', function ()
        run(3200)
        local line = W.sent[1]:gsub('^/say ', '')
        H.truthy(echo.isOwnCommand('sync', line))
        -- simulate a fresh dispatch expectation
        echo.onBeforeDispatch('sync', line, W.t)
        local hide = echo.filter({ 'Tester : ' .. line }, 'Tester', 'quiet', W.t)
        H.truthy(hide)
        echo.onBeforeDispatch('sync', line, W.t)
        local hide2, entry = echo.filter({ 'Tester : ' .. line }, 'Tester', 'normal', W.t)
        H.falsy(hide2); H.truthy(entry)
        H.falsy(echo.isOwnCommand('sync', '!ffxip sync'), 'old shape not recognised')
        H.falsy(echo.isOwnCommand('go#1', '!fpx 1 a1b2c3d4e5f6 0001 GO H 9 g 500 extra'))
        H.truthy(echo.isOwnCommand('go#1', '!fpx 1 a1b2c3d4e5f6 00af GO R 6 i 100'))
        H.falsy(echo.isOwnCommand('go#1', '!fpx 1 00af GO R 6 i 100'), 'RC3 shape without sid')
    end)

    H.it('frames never reach chat; protocol info only in debug', function ()
        H.falsy(chatlog.shows('protocol.info', 'quiet'))
        H.falsy(chatlog.shows('protocol.info', 'normal'))
        H.truthy(chatlog.shows('protocol.info', 'debug'))
        H.truthy(chatlog.shows('travel.accepted', 'quiet'))
        H.truthy(chatlog.shows('travel.problem', 'quiet'))
        H.truthy(chatlog.shows('protocol.warn', 'quiet'), 'version mismatch visible')
    end)
end)

H.describe('favourites and per-character settings', function ()
    H.it('favourites and payment method persist per character', function ()
        A.settings.switch('Alpha')
        H.truthy(config.setFavourite('hp', 9, true))
        H.truthy(travel.setMethod('rp', 'is'))
        A.settings.switch('Beta')
        H.falsy(config.isFavourite('hp', 9))
        H.eq(travel.method('rp'), 'gil')
        A.settings.switch('Alpha')
        H.truthy(config.isFavourite('hp', 9))
        H.eq(travel.method('rp'), 'is')
        H.falsy(config.setFavourite('hp', 67, true), 'unknown destination refused')
    end)
end)

local ok = H.report('client')
os.exit(ok and 0 or 1)
