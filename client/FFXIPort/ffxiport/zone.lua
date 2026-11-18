--[[
* FFXIPort (independent frontend) - zone change tracking
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Turns the several zone signals into ONE "zone episode" per zone change:
*   - packet 0x000B Zone Leave (byte 0x04 == 1 means logout)
*   - packet 0x000A Zone Enter (zone id u16 at 0x30, or 0x42 when 0;
*     character name at 0x84)            -- stock blucheck, logincmd, settings lib
*   - IPlayer:GetIsZoning() rising/falling edges, polled
*   - IParty:GetMemberZone(0) changing, polled
* An episode is complete when the client has arrived (0x000A, zoning flag
* fell, or zone id changed), is not zoning, and no new signal came for
* SETTLE_MS. A non-logout episode that never sees an arrival signal
* completes after FALLBACK_MS once the client is not zoning, so it cannot
* stay open forever. While an episode is open, inProgress() is true and the
* owner must not send anything.
*
* Handlers: onComplete(info), onLogout(), onCharacter(name).
--]]

local Z = {}

Z.SETTLE_MS   = 3000
Z.FALLBACK_MS = 60000
Z.POLL_MS     = 100

Z.handlers = {}

local S = {
    zone          = nil,   -- last polled zone id
    zoning        = false, -- last polled zoning flag
    episode       = nil,
    completed     = 0,
    last          = nil,   -- info of the last completed episode
    character     = nil,
    lastPollAt    = nil,
    warned        = {},
}

local function emit(name, ...)
    local fn = Z.handlers[name]

    if type(fn) == 'function' then
        local ok, err = pcall(fn, ...)

        if not ok and type(Z.handlers.onWarn) == 'function' and not S.warned[name] then
            S.warned[name] = true
            pcall(Z.handlers.onWarn, 'zone handler ' .. name .. ' failed: ' .. tostring(err))
        end
    end
end

local function readZoning()
    local ok, z = pcall(function ()
        return AshitaCore:GetMemoryManager():GetPlayer():GetIsZoning()
    end)

    if ok and type(z) == 'number' then
        return z ~= 0
    end

    return nil
end

local function readZone()
    local ok, z = pcall(function ()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    end)

    if ok and type(z) == 'number' then
        return z
    end

    return nil
end

local function startEpisode(t, cause)
    if S.episode == nil then
        S.episode = {
            startedAt    = t,
            lastSignalAt = t,
            fromZone     = S.zone,
            toZone       = nil,
            arrived      = false,
            logout       = false,
            causes       = cause,
        }
    else
        S.episode.lastSignalAt = t

        if not string.find(S.episode.causes, cause, 1, true) then
            S.episode.causes = S.episode.causes .. ',' .. cause
        end
    end

    return S.episode
end

local function arrive(t, cause, zoneId)
    local ep = startEpisode(t, cause)
    ep.arrived = true

    if type(zoneId) == 'number' and zoneId > 0 then
        ep.toZone = zoneId
    end
end

local function trimName(s)
    if type(s) ~= 'string' then
        return ''
    end

    local nul = string.find(s, '\0', 1, true)

    if nul ~= nil then
        s = string.sub(s, 1, nul - 1)
    end

    return s
end

-- Feed every packet_in event; only 0x000A / 0x000B are looked at. Never blocks.
function Z.onPacket(e, t)
    if e == nil or (e.id ~= 0x000A and e.id ~= 0x000B) then
        return
    end

    local ok, err = pcall(function ()
        local data = e.data

        if e.id == 0x000B then
            local kind = (type(data) == 'string' and #data > 0x04) and struct.unpack('b', data, 0x04 + 1) or nil
            local ep   = startEpisode(t, 'leave')

            if kind == 1 then
                ep.logout   = true
                S.character = nil
                emit('onLogout')
            end

            return
        end

        -- 0x000A Zone Enter
        local zoneId, name = nil, ''

        if type(data) == 'string' and #data >= 0x84 + 16 then
            zoneId = struct.unpack('H', data, 0x30 + 1)

            if zoneId == 0 then
                zoneId = struct.unpack('H', data, 0x42 + 1)
            end

            name = trimName(struct.unpack('c16', data, 0x84 + 1))
        end

        arrive(t, 'enter', zoneId)

        if name ~= '' then
            if S.character ~= nil and S.character ~= name then
                emit('onCharacter', name)
            end

            S.character = name
        end
    end)

    if not ok and not S.warned.packet then
        S.warned.packet = true
        emit('onWarn', 'zone packet read error: ' .. tostring(err))
    end
end

local function complete(t, viaFallback)
    local ep = S.episode
    S.episode = nil
    S.completed = S.completed + 1
    S.last = {
        at          = t,
        fromZone    = ep.fromZone,
        toZone      = S.zone or ep.toZone,
        duration    = t - ep.startedAt,
        logout      = ep.logout,
        viaFallback = viaFallback,
        causes      = ep.causes,
    }
    emit('onComplete', S.last)
end

function Z.tick(t)
    if S.lastPollAt ~= nil and (t - S.lastPollAt) < Z.POLL_MS then
        return
    end

    S.lastPollAt = t

    local zoning = readZoning()
    local zoneId = readZone()

    if zoning ~= nil then
        if zoning and not S.zoning then
            startEpisode(t, 'zoning')
        elseif not zoning and S.zoning and S.episode ~= nil then
            arrive(t, 'zoned', zoneId)
        end

        S.zoning = zoning
    end

    if zoneId ~= nil and zoneId > 0 then
        if S.zone ~= nil and zoneId ~= S.zone then
            arrive(t, 'zoneid', zoneId)
        end

        S.zone = zoneId
    end

    local ep = S.episode

    if ep == nil or S.zoning then
        return
    end

    if ep.arrived and (t - ep.lastSignalAt) >= Z.SETTLE_MS then
        complete(t, false)
    elseif not ep.arrived and not ep.logout and (t - ep.startedAt) >= Z.FALLBACK_MS then
        complete(t, true)
    end
end

function Z.inProgress() return S.episode ~= nil end
function Z.current()    return S.zone end
function Z.isZoning()   return S.zoning end

-- Snapshot for /port status.
function Z.status()
    return {
        zone      = S.zone,
        zoning    = S.zoning,
        episode   = S.episode,
        completed = S.completed,
        last      = S.last,
        character = S.character,
    }
end

function Z.reset()
    S.episode    = nil
    S.completed  = 0
    S.last       = nil
    S.lastPollAt = nil
    S.warned     = {}
    -- zone, zoning and character are re-read from the client/packets.
end

return Z
