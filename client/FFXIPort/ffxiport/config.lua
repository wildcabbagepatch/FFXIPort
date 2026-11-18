--[[
* FFXIPort (independent frontend) - per-character settings
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Built on Ashita's settings library (Ashita/addons/libs/settings.lua) with
* its own file alias C.ALIAS = 'ffxiport_independent', used for EVERY
* library call (register, load, save):
*   - file: <Ashita>/config/addons/FFXIPort/<Name>_<ServerId>/ffxiport_independent.lua
*     (before login the library uses .../FFXIPort/defaults/ffxiport_independent.lua);
*   - the legacy frontend's settings.lua in the same folder is never read
*     or written by this module (it never uses the default alias);
*   - settings.load(defaults, alias) returns the live table, which is kept;
*   - on login/logout/character change the library saves the old table,
*     loads the new character's file and calls our registered callback with
*     the new table.
*
* The library itself writes the file whenever it loads it (on addon load and
* on every login/logout/character switch), even when nothing changed.
* This module adds writes only when validation corrected a loaded value or
* set*() really changed one, and never while no character is logged in.
* All set*() calls are refused before login, so the shared defaults table
* is never mutated and cannot be persisted later by a character switch.
*
* Two library details shape this module:
*   - table merge copies a missing table-valued default BY REFERENCE, so
*     DEFAULTS holds scalars only; favourites are created per character
*     here, never shared through the defaults table;
*   - merge would also fail on a file holding a non-table where the default
*     is a table; with scalar defaults that cannot happen.
*
* Only preferences are stored. Unlocks, balances and server replies never
* are. Nothing is written per frame.
--]]

require('common')

local settings = require('settings')

local C = {}

-- Dedicated settings file alias (never the library default 'settings',
-- which belongs to the legacy frontend). Lower case: the library lowercases
-- aliases in register().
C.ALIAS = 'ffxiport_independent'
C.FILE  = C.ALIAS .. '.lua'

-- Load-time and set-time limits for the optional button position.
C.POS_MIN = -1000
C.POS_MAX = 16384

-- T{} (from common): the settings library calls defaults:copy(true) and
-- :merge(), which are T-table methods.
C.DEFAULTS = T{
    tab                = 'hp',    -- hp | sg | sp | rp | fav
    only_usable        = false,
    group_by_expansion = false,   -- setting only; feature in a later milestone
    pay_method         = 'gil',   -- hp/sg/sp: gil | cp
    pay_method_rp      = 'gil',   -- rp: gil | is
    scale              = 100,     -- 70..200, steps of 10
    button             = false,   -- floating button (later milestone)
    chat_level         = 'quiet', -- Milestone 6B: quiet | normal | debug
    theme              = 'classic', -- 1.2.0: classic | squad | crimson
    expansion          = 'all',   -- 1.2.0: all | base | roz | cop | toau (list filter)
    -- favourites = { ['hp:12'] = true, ... }   created per character, not here
    -- button_x, button_y                       optional, validated when present
}

-- Destination categories: the only valid favourite-key prefixes.
local TABS = { hp = true, sg = true, sp = true, rp = true }

-- Window tabs that may be remembered as the last tab (Milestone 6A adds the
-- Favorites tab). Deliberately separate from TABS, so 'fav:<id>' can never
-- become a favourite key.
local WINDOW_TABS = { hp = true, sg = true, sp = true, rp = true, fav = true }

local S = {
    live      = nil,  -- the library's live settings table
    catalog   = nil,
    lastCheck = { fixed = 0, pruned = 0, at = 'never' },
    switches  = 0,
    listeners = {},
    saves     = 0,
}

-----------------------------------------------------------------------------
-- Validation
-----------------------------------------------------------------------------

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

-- One rule for load-time validation and setButtonPos().
local function validPos(x, y)
    return finite(x) and finite(y)
        and x >= C.POS_MIN and x <= C.POS_MAX
        and y >= C.POS_MIN and y <= C.POS_MAX
end

local function roundScale(v)
    if not finite(v) then
        return nil
    end

    v = math.floor(v / 10 + 0.5) * 10

    if v < 70 then v = 70 end
    if v > 200 then v = 200 end

    return v
end

-- Returns the cleaned value for key k, or nil when v is unusable.
local function clean(k, v)
    if k == 'tab' then
        return (type(v) == 'string' and WINDOW_TABS[v]) and v or nil
    elseif k == 'only_usable' or k == 'group_by_expansion' or k == 'button' then
        if type(v) == 'boolean' then
            return v
        end

        return nil
    elseif k == 'pay_method' then
        return (v == 'gil' or v == 'cp') and v or nil
    elseif k == 'pay_method_rp' then
        return (v == 'gil' or v == 'is') and v or nil
    elseif k == 'chat_level' then
        return (v == 'quiet' or v == 'normal' or v == 'debug') and v or nil
    elseif k == 'theme' then
        return (v == 'classic' or v == 'squad' or v == 'crimson') and v or nil
    elseif k == 'expansion' then
        return (v == 'all' or v == 'base' or v == 'roz' or v == 'cop' or v == 'toau') and v or nil
    elseif k == 'scale' then
        return roundScale(v)
    end

    return nil
end

local function validKey(key)
    if type(key) ~= 'string' then
        return false
    end

    local tab, idText = string.match(key, '^(%a%a):(%d+)$')
    local id = tonumber(idText)

    if tab == nil or not TABS[tab] or id == nil then
        return false
    end

    -- Without a loaded catalog only the shape can be checked.
    if S.catalog == nil or not S.catalog.loaded() then
        return true
    end

    return S.catalog.get(tab, id) ~= nil
end

-- Fixes the live table in place. Unknown keys are left untouched (the
-- library keeps them on disk). Returns number of fixed values, pruned
-- favourites.
local function validate(s)
    local fixed, pruned = 0, 0

    for k, def in pairs(C.DEFAULTS) do
        local v = clean(k, rawget(s, k))

        if v == nil then
            v = def
        end

        if rawget(s, k) ~= v then
            s[k] = v
            fixed = fixed + 1
        end
    end

    -- Favourites: rebuilt as a fresh table owned by this character.
    local fav = rawget(s, 'favourites')
    local out = {}

    if type(fav) == 'table' then
        for key, on in pairs(fav) do
            if on == true and validKey(key) then
                out[key] = true
            else
                pruned = pruned + 1
            end
        end
    elseif fav ~= nil then
        fixed = fixed + 1
    end

    s.favourites = out

    -- Optional floating button position: both finite numbers in a sane
    -- range, otherwise both removed.
    local x, y = rawget(s, 'button_x'), rawget(s, 'button_y')

    if x ~= nil or y ~= nil then
        if not validPos(x, y) then
            s.button_x = nil
            s.button_y = nil
            fixed = fixed + 1
        end
    end

    return fixed, pruned
end

-----------------------------------------------------------------------------
-- Persistence
-----------------------------------------------------------------------------

-- True when a character is logged in, so saves go to that character's file.
function C.persistable()
    return settings.logged_in == true
end

local function save()
    if not C.persistable() or S.live == nil then
        return false
    end

    local ok = pcall(settings.save, C.ALIAS)

    if ok then
        S.saves = S.saves + 1
    end

    return ok
end

local function adopt(s, reason)
    if type(s) ~= 'table' then
        return
    end

    S.live = s

    local fixed, pruned = validate(s)

    S.lastCheck = { fixed = fixed, pruned = pruned, at = reason }

    if fixed > 0 or pruned > 0 then
        save()
    end

    for _, fn in ipairs(S.listeners) do
        pcall(fn, reason)
    end
end

-- catalog: the loaded catalog module (used to prune favourites).
-- Order matters: Ashita's settings.load() raises the alias's registered
-- callbacks itself. Loading first and registering afterwards means the
-- initial table is adopted exactly once (here), and the callback only runs
-- for real login/logout/character switches. If the addon loads while a
-- character is already logged in, the library has already switched to that
-- character when it was required, so load() returns that character's file.
function C.init(catalog)
    S.catalog = catalog

    local s = settings.load(C.DEFAULTS, C.ALIAS)
    adopt(s, 'load')

    settings.register(C.ALIAS, 'ffxiport_config', function (s2)
        S.switches = S.switches + 1
        adopt(s2, 'character switch')
    end)
end

-- fn(reason) after load and after every character switch.
function C.onChange(fn)
    S.listeners[#S.listeners + 1] = fn
end

-----------------------------------------------------------------------------
-- Preferences
-----------------------------------------------------------------------------

function C.get(key)
    if S.live == nil then
        return C.DEFAULTS[key]
    end

    local v = rawget(S.live, key)

    if v == nil then
        return C.DEFAULTS[key]
    end

    return v
end

-- Persistent changes need a logged-in character; before login the live
-- table belongs to the shared defaults file and is left untouched.
local function writable()
    return S.live ~= nil and C.persistable()
end

-- Validates and stores one preference; saves only when it changed.
-- Returns true when the stored value changed; false when invalid,
-- unchanged, or no character is logged in.
function C.set(key, value)
    if not writable() or C.DEFAULTS[key] == nil then
        return false
    end

    local v = clean(key, value)

    if v == nil or rawget(S.live, key) == v then
        return false
    end

    S.live[key] = v
    save()
    return true
end

function C.isFavourite(tab, id)
    local fav = S.live and rawget(S.live, 'favourites')
    return type(fav) == 'table' and fav[tab .. ':' .. tostring(id)] == true
end

-- For later milestones; validated against the catalog.
function C.setFavourite(tab, id, on)
    if not writable() then
        return false
    end

    local key = tostring(tab) .. ':' .. tostring(id)

    if on and not validKey(key) then
        return false
    end

    local fav = S.live.favourites
    local was = fav[key] == true

    if was == (on and true or false) then
        return false
    end

    fav[key] = on and true or nil
    save()
    return true
end

function C.favourites()
    local out = {}

    for key in pairs((S.live and S.live.favourites) or {}) do
        out[#out + 1] = key
    end

    table.sort(out)
    return out
end

-- Floating button position (1.2.0): x, y or nil (nil = default position).
function C.buttonPos()
    if S.live == nil or rawget(S.live, 'button_x') == nil then
        return nil
    end

    return S.live.button_x, S.live.button_y
end

function C.setButtonPos(x, y)
    -- The ORIGINAL values must satisfy the load-time limits (16384.4 or
    -- -1000.4 are rejected, not rounded into range). Rounding a value inside
    -- the integer limits cannot leave them.
    if not writable() or not validPos(x, y) then
        return false
    end

    x, y = math.floor(x + 0.5), math.floor(y + 0.5)

    if S.live.button_x == x and S.live.button_y == y then
        return false
    end

    S.live.button_x, S.live.button_y = x, y
    save()
    return true
end

-- 1.2.0: forget the saved floating-button position (back to the default).
function C.resetButtonPos()
    if not writable() or rawget(S.live, 'button_x') == nil then
        return false
    end

    S.live.button_x, S.live.button_y = nil, nil
    save()
    return true
end

-- Diagnostics for /port status.
function C.status()
    local path = '?'
    local ok, p = pcall(settings.settings_path)

    if ok and type(p) == 'string' then
        path = p .. C.FILE
    end

    return {
        path       = path,
        loggedIn   = C.persistable(),
        lastCheck  = S.lastCheck,
        switches   = S.switches,
        saves      = S.saves,
        favourites = #C.favourites(),
    }
end

return C
