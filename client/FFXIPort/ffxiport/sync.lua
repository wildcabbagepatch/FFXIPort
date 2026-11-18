--[[
* FFXIPort (independent frontend) - synchronisation controller
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Decides WHEN to ask for a sync and what to do with the outcome:
*   - manual requests (/port sync)
*   - Milestone 7A: ONE automatic initial ('startup') request per character
*     session, once the owner's readiness check (C.isReady: logged in, zone
*     known, not zoning) has held for STARTUP_SETTLE_MS outside any zone
*     episode. Any other request queued first in the session replaces it.
*   - one automatic re-sync after each completed zone change, once the
*     server has answered a sync this session (features T5)
*   - one retry 5 s after a timeout, then "The server did not answer"
*     (features T6); no other automatic retries
*   - commits a validated sync to the model; invalid/incomplete/timeout
*     results only change the status line, never the model's data
* It never sends while a zone change is in progress (zone.inProgress()).
*
* Handler: onReport(state, result, origin) for every sync state change.
--]]

local C = {}

C.RETRY_DELAY_MS     = 5000
C.STARTUP_SETTLE_MS  = 2000 -- readiness must hold this long before the initial request
C.STARTUP_RECHECK_MS = 1000 -- after a refused initial request: wait, never retry every frame

C.handlers = {}

-- Milestone 7A: readiness check set by the owner; returns true when a
-- character is logged in and in a known zone. nil = never ready.
C.isReady = nil

local protocol, model, zone -- set by C.init

local S = {
    origin     = nil,   -- 'manual' | 'auto' | 'retry' | 'startup' of the request in progress
    startup    = 'pending', -- 7A: 'pending' -> 'requested' | 'covered' (per session)
    readySince = nil,   -- 7A: readiness held continuously since
    startupNextAt = nil, -- 7A: earliest next attempt after a refusal
    answered   = false, -- the server answered a sync since load/login
    want       = false, -- a completed zone change still needs a re-sync
    wantSince  = nil,
    retryAt    = nil,
    retryUsed  = false,
    lastAction = 'none',
    counts     = { manual = 0, auto = 0, retry = 0, startup = 0, ok = 0, invalid = 0, timeout = 0, skipped = 0, fallback = 0 },
}

local function emit(name, ...)
    local fn = C.handlers[name]

    if type(fn) == 'function' then
        pcall(fn, ...)
    end
end

function C.init(p, m, z)
    protocol, model, zone = p, m, z
end

-- origin: 'manual' | 'auto' | 'retry' | 'startup'. Returns ok, reason.
function C.request(origin, t)
    if origin ~= 'manual' and zone.inProgress() then
        return false, 'zoning'
    end

    local ok, state = protocol.requestSync()

    if not ok then
        return false, state
    end

    S.origin = origin
    S.counts[origin] = (S.counts[origin] or 0) + 1
    S.retryAt = nil

    if origin ~= 'retry' then
        S.retryUsed = false
    end

    -- Any request queued now is sent after the current zone change (sends
    -- are held while zoning), so it covers a pending zone re-sync.
    S.want = false

    -- 7A: the first request queued in a session, of any origin, is the
    -- session's initial sync; no separate startup request follows it.
    if S.startup == 'pending' then
        S.startup = (origin == 'startup') and 'requested' or 'covered'
    end

    S.lastAction = origin .. ' request queued'
    return true
end

-- protocol.handlers.onSyncState is routed here.
function C.onSyncState(state, result)
    local t      = protocol.now()
    local origin = S.origin or 'server'

    -- Only a request SENT after the zone change completed describes the
    -- post-zone state. A reply that merely arrives later may still hold
    -- pre-zone data, so it must not cancel the pending zone re-sync.
    if (state == 'ok' or state == 'invalid') and S.want and S.wantSince ~= nil then
        local _, req = protocol.syncState()

        if type(req) == 'table' and type(req.sentAt) == 'number' and req.sentAt >= S.wantSince then
            S.want = false
        end
    end

    if state == 'ok' then
        S.answered = true
        S.counts.ok = S.counts.ok + 1

        if model.commitSync(protocol.committed(), t) then
            model.setStatus('Synchronized.', false, t)
        else
            model.setStatus('Sync was valid but could not be stored.', true, t)
        end
    elseif state == 'invalid' then
        S.answered = true
        S.counts.invalid = S.counts.invalid + 1
        model.setStatus('The last sync reply was invalid; showing the previous data.', true, t)
    elseif state == 'timeout' then
        S.counts.timeout = S.counts.timeout + 1

        if S.want then
            -- Sent before a zone change completed; the pending zone re-sync
            -- replaces it, so the retry is not used here.
            S.lastAction = 'timeout ignored (zone re-sync pending)'
        elseif not S.retryUsed then
            S.retryUsed = true
            S.retryAt   = t + C.RETRY_DELAY_MS
            S.lastAction = 'timeout, one retry scheduled'
            model.setStatus('No answer yet; retrying once.', true, t)
        else
            S.lastAction = 'timeout after retry, giving up'
            model.setStatus('The server did not answer. Use /port sync to try again.', true, t)
        end
    elseif state == 'send_failed' then
        model.setStatus('The sync request could not be sent.', true, t)
    end

    emit('onReport', state, result, origin)

    if state == 'ok' or state == 'invalid' or state == 'timeout' or state == 'send_failed' then
        S.origin = nil
    end
end

-- zone.handlers.onComplete is routed here.
function C.onZoneComplete(info, t)
    if info.logout then
        S.lastAction = 'login completed; the initial sync follows once ready'
        return
    end

    -- A fallback only releases a stuck episode; it is no proof of arrival,
    -- so it never triggers an automatic sync (/port sync still works).
    if info.viaFallback then
        S.counts.fallback = S.counts.fallback + 1
        S.lastAction = 'zone change released by fallback (no confirmed arrival); no auto re-sync'
        return
    end

    if not S.answered then
        -- 7A: the session's first request was already SENT before this zone
        -- change completed: its reply may describe the old zone, so one
        -- re-sync follows it (the usual "sent after wantSince" rule).
        local st = protocol.syncState()

        if S.startup ~= 'pending' and (st == 'sent' or st == 'receiving') then
            S.want      = true
            S.wantSince = t
            S.lastAction = 'zone change during the first sync: re-sync wanted'
            return
        end

        S.counts.skipped = S.counts.skipped + 1
        S.lastAction = 'zone change: no auto re-sync (no sync answered yet this session)'
        return
    end

    -- A request queued but not yet sent goes out after this zone change
    -- anyway, so it already covers it.
    if protocol.syncState() == 'queued' then
        S.lastAction = 'zone change: queued request covers it'
        return
    end

    S.want      = true
    S.wantSince = t
    S.lastAction = 'zone change: auto re-sync wanted'
end

-- Logout or character switch: the old character's state must go.
function C.resetSession()
    S.origin    = nil
    S.answered  = false
    S.want      = false
    S.wantSince = nil
    S.retryAt   = nil
    S.retryUsed = false
    S.startup   = 'pending' -- 7A: the new character gets its own initial sync
    S.readySince    = nil
    S.startupNextAt = nil
    S.lastAction = 'session reset'
end

-- 7A: the readiness check; any error counts as "not ready".
local function ready()
    if type(C.isReady) ~= 'function' then
        return false
    end

    local ok, v = pcall(C.isReady)
    return ok and v == true
end

-- 7A: one initial request per session, once readiness has held for
-- STARTUP_SETTLE_MS. Called only when no zone episode is open and no sync
-- is queued, sent or arriving.
local function startupStep(t)
    if not ready() then
        S.readySince = nil
        return
    end

    if S.readySince == nil then
        S.readySince = t
        S.lastAction = 'ready; initial sync in ' .. (C.STARTUP_SETTLE_MS / 1000) .. ' s'
        return
    end

    if (t - S.readySince) < C.STARTUP_SETTLE_MS then
        return
    end

    if S.startupNextAt ~= nil and t < S.startupNextAt then
        return
    end

    local ok, why = C.request('startup', t)

    if not ok then
        S.startupNextAt = t + C.STARTUP_RECHECK_MS
        S.lastAction = 'initial sync not possible yet: ' .. tostring(why)
    end
end

function C.tick(t)
    if zone.inProgress() then
        S.readySince = nil -- readiness must hold AFTER the zone episode
        return
    end

    if protocol.isBusy() then
        return
    end

    -- Milestone 8: after a protocol version mismatch nothing is requested
    -- automatically (PROTOCOL-FPX1.md §8.1); /port sync still reports it.
    if type(protocol.versionMismatch) == 'function' and protocol.versionMismatch() then
        S.want    = false
        S.retryAt = nil
        return
    end

    if S.startup == 'pending' then
        startupStep(t)

        if protocol.isBusy() then
            return -- the initial request was just queued
        end
    end

    if S.want then
        local ok, why = C.request('auto', t)

        if not ok then
            S.lastAction = 'auto re-sync not possible: ' .. tostring(why)
            S.want = false -- never spin; the next zone change or /port sync recovers
        end

        return
    end

    if S.retryAt ~= nil and t >= S.retryAt then
        S.retryAt = nil

        local ok, why = C.request('retry', t)

        if not ok then
            S.lastAction = 'retry not possible: ' .. tostring(why)
        end
    end
end

function C.status()
    return {
        origin     = S.origin,
        startup    = S.startup,
        readySince = S.readySince,
        answered   = S.answered,
        want       = S.want,
        wantSince  = S.wantSince,
        retryAt    = S.retryAt,
        retryUsed  = S.retryUsed,
        lastAction = S.lastAction,
        counts     = S.counts,
    }
end

return C
