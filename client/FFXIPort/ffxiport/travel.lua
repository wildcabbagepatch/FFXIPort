--[[
* FFXIPort (independent frontend) - travel rules and trip state machine
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Milestone 8: adapted to FPX/1 (docs/PROTOCOL-FPX1.md).
*   - payment methods shown: hp/sg/sp gil|cp, rp gil|is (unchanged UI);
*   - prices and "free" come only from the server's synced offers
*     (model.offer). A trip request carries the price the player saw; the
*     server refuses (PRICE) instead of charging anything different;
*   - TR.go() is the ONLY send path. One trip at a time; states:
*       idle -> queued -> sent -> accepted -> (zone change / same-zone settle) idle
*                              |          \-> corrected E INTERNAL -> idle (refund confirmed)
*                              |          \-> corrected E UNSURE, unreadable correction,
*                              |              or no expected zone change -> unknown + reconcile
*                              \-> refused (E)  -> idle
*                              \-> E UNSURE -> unknown + reconcile
*                              \-> unknown (timeout / invalid / zoning while
*                                  sent) -> idle after a fresh valid sync or 60 s
*     RC3 (PROTOCOL-FPX1.md §4.6): T is provisional; "complete" is reported
*     only after a zone change, or after the correction window for a
*     same-zone destination. An uncertain outcome is never shown as success
*     or refund.
*   - replies are matched by request id in fpx.lua; a delayed reply to an
*     older request is dropped there and can never be applied here.
*   - nothing is ever re-sent automatically.
--]]

local TR = {}

TR.METHODS = {
    hp = { 'gil', 'cp' },
    sg = { 'gil', 'cp' },
    sp = { 'gil', 'cp' },
    rp = { 'gil', 'is' },
}

TR.METHOD_LABEL = { gil = 'Gil', cp = 'Conquest Points', is = 'Imperial Standing' }
TR.CURRENCY     = { gil = 'gil', cp = 'CP', is = 'IS' }
TR.CUR          = { gil = 'g', cp = 'c', is = 'i' }
TR.CUR_NAME     = { g = 'gil', c = 'CP', i = 'IS' }

TR.MAX_ID = { hp = 999, sg = 999, sp = 999, rp = 99 }

-- Refusal codes (PROTOCOL-FPX1.md §6) -> player text.
TR.REFUSAL = {
    VERSION  = 'The server speaks a different FFXIPort protocol version.',
    BADREQ   = 'The server could not read the request.',
    BADDEST  = 'The server does not know this destination.',
    LOCKED   = 'This destination is not unlocked for this character.',
    PAYMENT  = 'That payment method is not accepted for this destination.',
    PRICE    = 'The price has changed. Prices were refreshed; check and try again.',
    FUNDS    = 'Not enough funds.',
    STATE    = 'You cannot travel right now (combat, event, mount or similar).',
    ZONE     = 'Travel is not possible from this area.',
    HERE     = 'You are already at this destination.',
    BUSY     = 'Please wait a moment before travelling again.',
    INTERNAL = 'The server could not complete the trip; nothing was charged.',
    UNSURE   = 'The trip failed on the server and the payment status could not be confirmed.',
}

TR.RECONCILE_TEXT = 'Payment/travel outcome UNCERTAIN: check your gil, CP and IS. The server logged a currency incident for the operator.'

local D = {} -- catalog, model, config, protocol, zone

function TR.init(deps)
    D = deps
end

function TR.methodsFor(tab)
    return TR.METHODS[tab]
end

local function allowed(tab, method)
    for _, m in ipairs(TR.METHODS[tab] or {}) do
        if m == method then
            return true
        end
    end

    return false
end

function TR.settingKey(tab)
    if tab == 'rp' then
        return 'pay_method_rp'
    end

    return 'pay_method'
end

function TR.method(tab)
    local m = D.config.get(TR.settingKey(tab))

    if allowed(tab, m) then
        return m
    end

    return 'gil'
end

function TR.setMethod(tab, method)
    if not allowed(tab, method) then
        return false
    end

    return D.config.set(TR.settingKey(tab), method)
end

-- True when the server's current offer for this destination is free.
function TR.isFree(tab, row)
    local o = D.model.offer(tab, row)
    return o ~= nil and o[1].cur == 'f'
end

-- { free = true } | { amount = n, method = m } | { unavailable = true } | { unknown = true }
-- currentZone is accepted for compatibility; pricing is server-authoritative.
function TR.quote(tab, row, currentZone, method)
    if row == nil or not allowed(tab, method) then
        return { unknown = true }
    end

    local offers = D.model.offer(tab, row)

    if offers == nil then
        return { unknown = true }
    end

    if offers[1].cur == 'f' then
        return { free = true }
    end

    local cur = TR.CUR[method]

    for _, o in ipairs(offers) do
        if o.cur == cur then
            return { amount = o.amount, method = method }
        end
    end

    return { unavailable = true }
end

local function thousands(n)
    local s = tostring(math.floor(n))
    local out = string.reverse(s):gsub('(%d%d%d)', '%1,'):reverse()

    return (string.gsub(out, '^,', ''))
end

TR.thousands = thousands

-- 'Free', '1,000 gil', '100 CP', '100 IS', or nil when unknown/unavailable.
function TR.priceText(q)
    if q == nil or q.unknown or q.unavailable then
        return nil
    end

    if q.free then
        return 'Free'
    end

    return thousands(q.amount) .. ' ' .. TR.CURRENCY[q.method]
end

function TR.balanceText(method)
    local v = D.model.balance(method)

    if v == nil then
        return '?'
    elseif v < 0 then
        return 'unreadable'
    end

    return thousands(v)
end

function TR.lowBalance(q)
    if q == nil or q.amount == nil then
        return false
    end

    local v = D.model.balance(q.method)

    return type(v) == 'number' and v >= 0 and v < q.amount
end

local LOCKED_REASON = {
    hp = 'This Home Point has not been registered yet.',
    sg = 'This Survival Guide has not been registered yet.',
    sp = 'You do not hold this Gate Crystal key item.',
    rp = 'This Runic Portal has not been attuned yet.',
}

-- unlocked: true / false / nil (model). ctx: { visible, here, zoning, busy, pending }
function TR.canSubmit(tab, row, unlocked, ctx)
    ctx = ctx or {}

    if row == nil then
        return false, 'Select a destination.'
    end

    if not ctx.visible then
        return false, 'The selected destination is hidden by the current search or filter.'
    end

    if unlocked == nil then
        return false, 'Waiting for sync.'
    end

    if unlocked == false then
        return false, LOCKED_REASON[tab] or 'This destination is locked.'
    end

    if tab == 'sg' and ctx.here then
        return false, 'You are already in this zone.'
    end

    if ctx.zoning then
        return false, 'Zone change in progress.'
    end

    if ctx.busy then
        return false, 'Synchronizing...'
    end

    if ctx.pending then
        return false, 'Waiting for the last trip\'s answer.'
    end

    return true, nil
end

-- FPX/1 trip request for the selection, or nil + reason.
function TR.requestFor(tab, row, method)
    if TR.METHODS[tab] == nil or row == nil or not allowed(tab, method) then
        return nil, 'This destination is not valid.'
    end

    if D.catalog.get(tab, row.id) == nil then
        return nil, 'This destination is not valid.'
    end

    local cat, id = D.model.protocolId(tab, row)

    if cat == nil or type(id) ~= 'number' or id ~= math.floor(id) or id < 0 or id > TR.MAX_ID[tab] then
        return nil, 'This destination is not valid.'
    end

    local q = TR.quote(tab, row, nil, method)

    if q.unknown then
        return nil, 'Waiting for sync.'
    elseif q.unavailable then
        return nil, 'That payment method is not accepted for this destination.'
    end

    if q.free then
        return { cat = cat, dest = id, cur = 'f', amount = 0 }
    end

    return { cat = cat, dest = id, cur = TR.CUR[method], amount = q.amount }
end

-- Display form of the request (diagnostics); nil when not valid.
function TR.commandFor(tab, row, method)
    local req = TR.requestFor(tab, row, method)

    if req == nil then
        return nil
    end

    return string.format('GO %s %d %s %d', req.cat, req.dest, req.cur, req.amount)
end

-- Why commandFor returned nil.
function TR.commandProblem(tab, row, method)
    local _, why = TR.requestFor(tab, row, method)
    return why
end

-----------------------------------------------------------------------------
-- Trip state machine
-----------------------------------------------------------------------------

TR.QUEUE_CAP_MS     = 30000 -- click -> must be sent within this, else cancelled
TR.RESPONSE_MS      = 12000 -- backstop; fpx.lua times out GO after 8 s
TR.ACCEPT_HOLD_MS   = 8000  -- accepted, no zone change started -> settle
TR.STATUS_GRACE_MS  = 5000  -- after settling, new trips wait (matches the server cooldown)
TR.UNKNOWN_BLOCK_MS = 60000 -- unknown outcome blocks new trips this long (or until a fresh sync)

TR.handlers = {} -- onReport(text, bad), onNeedSync(reason)

local ST = {
    state      = 'idle', -- idle | queued | sent | accepted | unknown
    trip       = nil,    -- { tag, gen, rid, tab, id, method, request, clickedAt, sentAt, acceptedAt, zoneStarted }
    hold       = nil,
    gen        = 1,
    counter    = 0,
    unknownAt  = nil,
    syncAfterUnknown = false,
    lateRisk   = false,  -- kept for diagnostics; request ids make late replies harmless
    last       = nil,
    reconcile  = nil,    -- { rid, tag, at, text }: last trip whose outcome needs reconciliation
}

local function now()
    return D.protocol.now()
end

local function report(text, bad)
    ST.last = text

    if D.model ~= nil and D.model.setStatus ~= nil then
        D.model.setStatus(text, bad, now())
    end

    if type(TR.handlers.onReport) == 'function' then
        pcall(TR.handlers.onReport, text, bad)
    end
end

local function needSync(reason)
    if type(TR.handlers.onNeedSync) == 'function' then
        pcall(TR.handlers.onNeedSync, reason)
    end
end

local function toIdle()
    ST.state = 'idle'
    ST.trip  = nil
end

local function toUnknown(text)
    ST.state            = 'unknown'
    ST.unknownAt        = now()
    ST.syncAfterUnknown = false
    report(text, true)
    needSync('unknown trip outcome')
end

-- The final outcome could not be established (§4.6): never shown as success
-- or refund; kept for /port status until the session ends.
local function toReconcile(text)
    local trip = ST.trip
    ST.reconcile = {
        rid  = trip and trip.rid,
        tag  = trip and trip.tag,
        at   = now(),
        text = text,
    }
    toUnknown(text .. ' ' .. TR.RECONCILE_TEXT)
end

local function applyBalances(fields)
    local b = D.protocol.balances(fields or {})

    if b ~= nil then
        D.model.applyBalances(b, now())
        return true
    end

    return false
end

function TR.state()   return ST.state end
function TR.current() return ST.trip end

local function holdActive()
    return ST.hold ~= nil and ST.hold.gen == ST.gen and now() <= ST.hold.untilAt
end

function TR.isBlocked()
    return ST.state ~= 'idle' or holdActive()
end

function TR.blockReason()
    if ST.state == 'idle' and holdActive() then
        return 'The last trip is still settling.'
    elseif ST.state == 'queued' then
        return 'Sending the trip request...'
    elseif ST.state == 'sent' then
        return 'Waiting for the server\'s answer.'
    elseif ST.state == 'accepted' then
        return 'Travelling...'
    elseif ST.state == 'unknown' then
        return 'Last trip\'s result is unknown. Press Refresh.'
    end

    return nil
end

-- The ONLY travel send path. Revalidates everything at click time.
function TR.go(tab, id, method)
    if TR.isBlocked() then
        return false, TR.blockReason()
    end

    local row = D.catalog.get(tab, id)

    if row == nil then
        return false, 'This destination is not valid.'
    end

    local zoneId = D.zone.current()
    local ok, reason = TR.canSubmit(tab, row, D.model.isUnlocked(tab, row), {
        visible = true,
        here    = zoneId ~= nil and row.zone == zoneId,
        zoning  = D.zone.inProgress(),
        busy    = D.protocol.isBusy(),
        pending = false,
    })

    if not ok then
        return false, reason
    end

    if not allowed(tab, method) then
        return false, 'That payment method is not available here.'
    end

    local req, why = TR.requestFor(tab, row, method)

    if req == nil then
        return false, why
    end

    ST.counter = ST.counter + 1

    local tag       = 'go#' .. ST.counter
    local clickedAt = now()
    local queued, rid = D.protocol.requestGo(req, tag, clickedAt + TR.QUEUE_CAP_MS)

    if not queued then
        return false, 'The trip request could not be queued (' .. tostring(rid) .. ').'
    end

    ST.state = 'queued'
    ST.hold  = nil
    ST.trip  = {
        tag = tag, gen = ST.gen, rid = rid, tab = tab, id = id, method = method, request = req,
        command = TR.commandFor(tab, row, method),
        fromZone = zoneId, destZone = row.zone,
        clickedAt = clickedAt, sentAt = nil, acceptedAt = nil, zoneStarted = false,
    }

    report('Sending the trip request...', false)
    return true
end

function TR.onSent(tag, line, t)
    local trip = ST.trip

    if ST.state == 'queued' and trip ~= nil and trip.tag == tag then
        ST.state    = 'sent'
        trip.sentAt = t
        report('Waiting for the server\'s answer...', false)
    end
end

function TR.onExpired(tag, line, t)
    local trip = ST.trip

    if ST.state == 'queued' and trip ~= nil and trip.tag == tag then
        toIdle()
        report('Trip request cancelled before it was sent: it could not be sent within '
            .. (TR.QUEUE_CAP_MS / 1000) .. ' s. Nothing was requested.', true)
    end
end

function TR.onSendFailed(tag, err)
    local trip = ST.trip

    if ST.state == 'queued' and trip ~= nil and trip.tag == tag then
        toIdle()
        report('The trip request could not be sent. Nothing was requested.', true)
    end
end

local function paidText(pay)
    local cur, amt = string.match(pay or '', '^([fgci])(%d+)$')

    if cur == nil then
        return '?'
    elseif cur == 'f' then
        return 'free'
    end

    return 'paid ' .. thousands(tonumber(amt)) .. ' ' .. TR.CUR_NAME[cur]
end

local function needText(need)
    local parts = {}

    for cur, amt in string.gmatch(need or '', '([gci])(%d+)') do
        parts[#parts + 1] = thousands(tonumber(amt)) .. ' ' .. TR.CUR_NAME[cur]
    end

    if string.match(need or '', '^f0$') then
        return 'free'
    end

    return table.concat(parts, ' or ')
end

-- §4.6 correction of an accepted trip (an E, or an unreadable response, for
-- the same request id after T). Only ever moves away from "accepted".
local function onCorrection(result)
    local f = result.fields or {}

    if result.status == 'ok' and f.e == 'INTERNAL' then
        applyBalances(f)
        toIdle()
        report('Travel failed on the server after it was accepted; nothing remains charged (refund confirmed by the server).', true)
        needSync('correction INTERNAL')
        return true
    end

    if result.status == 'ok' and f.e == 'UNSURE' then
        applyBalances(f)
        toReconcile('Travel failed on the server after it was accepted.')
        return true
    end

    -- Unreadable correction or an unexpected code: the outcome is not known.
    toReconcile('The server sent an unreadable or unexpected correction for the accepted trip ('
        .. tostring(f.e or (result.reasons or {})[1]) .. ').')
    return true
end

-- fpx.handlers.onTravel. result: { status, tag, rid, kind, fields, reasons, correction }
-- Returns true when applied to the current trip.
function TR.onResponse(result)
    local trip = ST.trip

    if type(result) ~= 'table' or trip == nil or trip.tag ~= result.tag or trip.gen ~= ST.gen then
        return false
    end

    if result.correction then
        if ST.state ~= 'accepted' then
            return false
        end

        return onCorrection(result)
    end

    if ST.state ~= 'sent' then
        return false
    end

    if result.status == 'timeout' then
        toUnknown('No answer to the trip request. The trip may or may not have happened; refreshing.')
        return true
    end

    if result.status ~= 'ok' then
        toUnknown('The server\'s answer to the trip request was invalid (' .. tostring((result.reasons or {})[1]) .. '); refreshing.')
        return true
    end

    local f = result.fields or {}

    if result.kind == 'T' then
        applyBalances(f)
        ST.state         = 'accepted'
        trip.acceptedAt  = now()
        trip.zoneStarted = false
        report('Accepted - travelling (' .. paidText(f.pay) .. ').', false)
        return true
    end

    if f.e == 'UNSURE' then
        applyBalances(f)
        toReconcile(TR.REFUSAL.UNSURE)
        return true
    end

    -- Refused: nothing remains charged (server invariant, §6).
    applyBalances(f)
    toIdle()

    local text = TR.REFUSAL[f.e] or ('Travel refused (' .. tostring(f.e) .. ').')

    if (f.e == 'FUNDS' or f.e == 'PRICE') and f.need then
        text = text .. ' Current price: ' .. needText(f.need) .. '.'
    end

    report('Travel refused: ' .. text, true)

    if f.e == 'PRICE' or f.e == 'LOCKED' or f.e == 'BADDEST' then
        needSync('refusal ' .. tostring(f.e))
    end

    return true
end

-- Sync outcome; lifts the "unknown" block early only for a locally requested
-- sync that was queued after the outcome became unknown and actually sent.
local LOCAL_SYNC = { manual = true, auto = true, retry = true }

function TR.onSyncReport(state, origin, req)
    if state ~= 'ok' or not LOCAL_SYNC[origin] then
        return false
    end

    if ST.state ~= 'unknown' or type(ST.unknownAt) ~= 'number' then
        return false
    end

    if type(req) ~= 'table' or type(req.queuedAt) ~= 'number' or type(req.sentAt) ~= 'number' then
        return false
    end

    if req.queuedAt < ST.unknownAt or req.sentAt < req.queuedAt then
        return false
    end

    ST.syncAfterUnknown = true
    return true
end

function TR.tick(t)
    local trip = ST.trip

    if ST.state == 'queued' and trip ~= nil then
        local why = nil

        if (t - trip.clickedAt) > TR.QUEUE_CAP_MS then
            why = 'it could not be sent within ' .. (TR.QUEUE_CAP_MS / 1000) .. ' s'
        elseif D.zone.inProgress() then
            why = 'a zone change started'
        end

        if why ~= nil then
            local removed = D.protocol.cancel(trip.tag)

            if removed > 0 then
                toIdle()
                report('Trip request cancelled before it was sent: ' .. why .. '. Nothing was requested.', true)
            else
                toUnknown('Trip request state is unclear (' .. why .. '). Press Refresh.')
            end
        end
    elseif ST.state == 'sent' and trip ~= nil then
        if trip.sentAt ~= nil and (t - trip.sentAt) > TR.RESPONSE_MS then
            toUnknown('No answer to the trip request. The trip may or may not have happened; refreshing.')
        elseif D.zone.inProgress() then
            toUnknown('A zone change started before the server answered. The result will be checked after arrival.')
        end
    elseif ST.state == 'accepted' and trip ~= nil then
        local zoning = D.zone.inProgress()

        if zoning then
            if not trip.zoneStarted then
                -- The server never corrects a trip once the character moves (§4.6).
                pcall(D.protocol.closeCorrection, trip.tag)
            end

            trip.zoneStarted = true
        elseif trip.zoneStarted then
            ST.hold = { tag = trip.tag, gen = ST.gen, untilAt = t + TR.STATUS_GRACE_MS }
            toIdle()
            report('Travel complete (zone change finished).', false)
        elseif (t - trip.acceptedAt) > TR.ACCEPT_HOLD_MS and not D.protocol.correctionOpen(trip.tag) then
            if trip.destZone ~= nil and trip.fromZone ~= nil and trip.destZone == trip.fromZone then
                -- Same-zone destination: no zone change is expected; the
                -- correction window closed without a correction.
                ST.hold = { tag = trip.tag, gen = ST.gen, untilAt = t + TR.STATUS_GRACE_MS }
                toIdle()
                report('Travel complete (move within the same zone).', false)
                needSync('same-zone move')
            else
                -- A zone change was expected but did not happen: never claim success.
                toReconcile('Travel was accepted but the expected zone change did not happen.')
            end
        end
    elseif ST.state == 'unknown' then
        if ST.syncAfterUnknown or (ST.unknownAt ~= nil and (t - ST.unknownAt) > TR.UNKNOWN_BLOCK_MS) then
            toIdle()
        end
    end

    if ST.hold ~= nil and t > ST.hold.untilAt then
        ST.hold = nil
    end
end

function TR.reset()
    if ST.trip ~= nil and ST.state == 'queued' then
        pcall(D.protocol.cancel, ST.trip.tag)
    end

    ST.gen       = ST.gen + 1
    ST.counter   = 0
    ST.hold      = nil
    ST.unknownAt = nil
    ST.syncAfterUnknown = false
    ST.lateRisk  = false
    ST.reconcile = nil
    toIdle()
end

function TR.status()
    return {
        state     = ST.state,
        trip      = ST.trip,
        gen       = ST.gen,
        lateRisk  = ST.lateRisk,
        hold      = ST.hold,
        last      = ST.last,
        reconcile = ST.reconcile,
    }
end

return TR
