--[[
* FFXIPort (independent frontend) - client state model
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Holds the last VALIDATED travel picture: unlocks per category, the
* server's offers (payment methods and prices per destination) and
* balances. Its only data input is a snapshot the FPX/1 layer has fully
* validated (fpx.committed()), plus balances from validated travel
* responses. A failed, invalid or incomplete reply can never replace data
* held by the model.
*
* Milestone 8: adapted to FPX/1 (unlock sets keyed by protocol id, per-
* destination offers). The public functions used by the UI are unchanged
* except that price(tab) now returns the category's default offer list and
* offer(tab, row) returns the destination's own offer list.
--]]

local fpx = require('ffxiport.fpx')

local M = {}

local S = {
    data        = nil, -- { protocol, ch, zone, unlock = {H={},S={},G={},R={}}, counts, offers, travelBlock }
    balances    = nil, -- { gil, is, cp }
    balancesAt  = nil,
    committedAt = nil,
    revision    = 0,   -- bumps on every change; UI caches key off it
    status      = { text = nil, bad = false, at = nil },
}

local function copy(t)
    if type(t) ~= 'table' then
        return t
    end

    local out = {}

    for k, v in pairs(t) do
        out[k] = copy(v)
    end

    return out
end

-- Protocol category and id of a catalogue row, or nil.
function M.protocolId(tab, row)
    local cat = fpx.TAB_TO_CAT[tab]

    if cat == nil or type(row) ~= 'table' then
        return nil, nil
    end

    if tab == 'sp' then
        return cat, fpx.GATE_INDEX[row.crystal]
    end

    if type(row.id) ~= 'number' then
        return cat, nil
    end

    return cat, row.id
end

-- Takes a validated snapshot (fpx.committed()). Returns true when stored.
function M.commitSync(c, t)
    if type(c) ~= 'table' or type(c.unlock) ~= 'table' or type(c.offers) ~= 'table' or type(c.balances) ~= 'table' then
        return false
    end

    for _, cat in ipairs({ 'H', 'S', 'G', 'R' }) do
        if type(c.unlock[cat]) ~= 'table' or type(c.offers[cat]) ~= 'table' then
            return false
        end
    end

    local data = {
        protocol    = c.protocol,
        ch          = c.ch,
        zone        = c.zone,
        unlock      = copy(c.unlock),
        counts      = copy(c.counts),
        offers      = copy(c.offers),
        travelBlock = c.travelBlock,
    }

    -- single assignment: the model switches to the new snapshot atomically
    S.data        = data
    S.balances    = copy(c.balances)
    S.balancesAt  = t
    S.committedAt = t
    S.revision    = S.revision + 1
    return true
end

-- Balances from a validated travel response.
function M.applyBalances(b, t)
    if type(b) ~= 'table' or type(b.gil) ~= 'number' or type(b.is) ~= 'number' or type(b.cp) ~= 'number' then
        return false
    end

    S.balances   = { gil = b.gil, is = b.is, cp = b.cp }
    S.balancesAt = t
    S.revision   = S.revision + 1
    return true
end

-- Drops everything (logout / character change).
function M.clear()
    S.data        = nil
    S.balances    = nil
    S.balancesAt  = nil
    S.committedAt = nil
    S.revision    = S.revision + 1
    S.status      = { text = nil, bad = false, at = nil }
end

function M.hasData()     return S.data ~= nil end
function M.revision()    return S.revision end
function M.committedAt() return S.committedAt end
function M.catalog()     return S.data and S.data.protocol or nil end -- kept for diagnostics callers
function M.character()   return S.data and S.data.ch or nil end
function M.travelBlock() return S.data and S.data.travelBlock or nil end

-- Unlock state of one destination: true / false, or nil before the first
-- validated sync ("waiting for sync", not "locked").
function M.isUnlocked(tab, row)
    local d = S.data

    if d == nil or type(row) ~= 'table' then
        return nil
    end

    local cat, id = M.protocolId(tab, row)

    if cat == nil or id == nil then
        return false
    end

    return d.unlock[cat][id] == true
end

-- The destination's offer list ({ {cur, amount}, ... }) or nil before a sync.
function M.offer(tab, row)
    local d = S.data

    if d == nil then
        return nil
    end

    local cat, id = M.protocolId(tab, row)

    if cat == nil or id == nil then
        return nil
    end

    local o = d.offers[cat]
    return o.over[id] or o.default
end

-- Default offer list of a category (diagnostics), or nil.
function M.price(tab)
    local cat = fpx.TAB_TO_CAT[tab]
    return S.data and cat and S.data.offers[cat].default or nil
end

-- Balance for 'gil' | 'is' | 'cp': a number or nil (unknown).
function M.balance(method)
    return S.balances and S.balances[method] or nil
end

function M.balancesAt() return S.balancesAt end

-- Counts for diagnostics.
function M.counts()
    local d = S.data

    if d == nil then
        return nil
    end

    local function n(set)
        local k = 0

        for _ in pairs(set) do
            k = k + 1
        end

        return k
    end

    return {
        hp = n(d.unlock.H), sg = n(d.unlock.S),
        sp = n(d.unlock.G), spTotal = d.counts.G or 0,
        rp = n(d.unlock.R), rpTotal = 6,
    }
end

-- Unlocked server destinations that have no row in the given catalogue
-- (e.g. destinations in later-expansion zones). Diagnostics only:
-- { H = { ids... }, S = {...}, G = {...}, R = {...} } or nil before a sync.
function M.uncatalogued(catalog)
    local d = S.data

    if d == nil or catalog == nil then
        return nil
    end

    local known = { H = {}, S = {}, G = {}, R = {} }

    for _, tab in ipairs({ 'hp', 'sg', 'sp', 'rp' }) do
        for _, row in ipairs(catalog.rows(tab)) do
            local cat, id = M.protocolId(tab, row)

            if cat ~= nil and id ~= nil then
                known[cat][id] = true
            end
        end
    end

    local out = { H = {}, S = {}, G = {}, R = {} }

    for cat, set in pairs(d.unlock) do
        for id in pairs(set) do
            if not known[cat][id] then
                out[cat][#out[cat] + 1] = id
            end
        end

        table.sort(out[cat])
    end

    return out
end

-- Status line for the window; bad = shown in red.
function M.setStatus(text, bad, t)
    S.status = { text = text, bad = bad and true or false, at = t }
end

function M.status() return S.status end

return M
