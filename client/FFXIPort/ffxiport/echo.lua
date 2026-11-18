--[[
* FFXIPort (independent frontend) - Milestone 6B.1: command echo suppression
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* In game, every command FFXIPort sends is echoed back as an incoming chat
* line "<Name> : <command>" (seen in text_in by the 6B trace). This module
* lets the owner hide exactly those echoes, and nothing else:
*
*   - An expectation is created ONLY by protocol.handlers.onBeforeDispatch,
*     i.e. for a line FFXIPort is handing to QueueCommand right now. It is
*     created before the call, so a synchronous echo is covered. Expired and
*     cancelled queued lines never reach that hook.
*   - Only the two command shapes FFXIPort generates are accepted, with
*     their tags (Milestone 8, FPX/1): "sync" -> "!fpx 1 <sid> <rid> SYNC",
*     "go#<n>" -> "!fpx 1 <sid> <rid> GO <cat> <dest> <cur> <amount>".
*     Anything else creates no expectation.
*   - A line matches only when, after removing colour/control codes, it is
*     EXACTLY "<local character name> : <command>". No substring matching.
*     Without a valid local name nothing matches (the line stays visible).
*   - Each expectation is consumed by at most one line, expires after
*     WINDOW_MS, is withdrawn when QueueCommand fails, and all are cleared on
*     a session change and on unload. At most MAX_PENDING are kept.
*
* This module never touches an event: filter() only returns a decision; the
* owner sets e.blocked. It prints nothing and keeps no persistent state.
* Reversible: set E.enabled = false (nothing is ever expected or hidden).
--]]

local E = {}

E.enabled     = true
E.WINDOW_MS   = 3000
E.MAX_PENDING = 4

local S = {
    pending = {},
    stats   = { expected = 0, matched = 0, hidden = 0, expired = 0, withdrawn = 0, cleared = 0, refused = 0 },
}

-- True only for the exact FPX/1 command shapes FFXIPort itself generates
-- (Milestone 8: "!fpx 1 <sid> <rid> SYNC" and "!fpx 1 <sid> <rid> GO <cat> <dest> <cur> <amount>").
function E.isOwnCommand(tag, line)
    if type(tag) ~= 'string' or type(line) ~= 'string' then
        return false
    end

    local SID = string.rep('%x', 12)

    if tag == 'sync' then
        return string.match(line, '^!fpx 1 ' .. SID .. ' %x%x%x%x SYNC$') ~= nil
    end

    if not string.match(tag, '^go#%d+$') then
        return false
    end

    local dest, amount = string.match(line, '^!fpx 1 ' .. SID .. ' %x%x%x%x GO [HSGR] (%d+) [gcif] (%d+)$')

    return dest ~= nil and #dest <= 3 and #amount <= 9
end

-- Drops expectations older than WINDOW_MS.
local function prune(t)
    for i = #S.pending, 1, -1 do
        if (t - S.pending[i].at) > E.WINDOW_MS then
            table.remove(S.pending, i)
            S.stats.expired = S.stats.expired + 1
        end
    end
end

-- protocol.handlers.onBeforeDispatch
function E.onBeforeDispatch(tag, line, t)
    if not E.enabled or type(t) ~= 'number' or not E.isOwnCommand(tag, line) then
        S.stats.refused = S.stats.refused + 1
        return false
    end

    prune(t)

    while #S.pending >= E.MAX_PENDING do
        table.remove(S.pending, 1)
        S.stats.expired = S.stats.expired + 1
    end

    S.pending[#S.pending + 1] = { tag = tag, line = line, at = t }
    S.stats.expected = S.stats.expected + 1
    return true
end

-- protocol.handlers.onDispatchFailed: the client call raised, no echo follows.
function E.onDispatchFailed(tag, line, t)
    for i = #S.pending, 1, -1 do
        local p = S.pending[i]

        if p.tag == tag and p.line == line then
            table.remove(S.pending, i)
            S.stats.withdrawn = S.stats.withdrawn + 1
            return true
        end
    end

    return false
end

-- Removes FFXI colour codes (0x1E/0x1F + one byte), 0x7F + one byte
-- markers, other control characters at both ends, and trailing spaces.
-- Inner text is not changed.
function E.normalize(text)
    if type(text) ~= 'string' then
        return nil
    end

    text = string.gsub(text, '[\30\31\127].', '')
    text = string.gsub(text, '^%c+', '')
    text = string.gsub(text, '[%c%s]+$', '')
    return text
end

local function validName(name)
    return type(name) == 'string' and #name >= 3 and #name <= 15 and string.match(name, '^%a+$') ~= nil
end

-- Consumes and returns the oldest expectation whose echo is exactly `text`.
local function consume(text, name, t)
    local norm = E.normalize(text)

    if norm == nil then
        return nil
    end

    for i, p in ipairs(S.pending) do
        if norm == name .. ' : ' .. p.line then
            table.remove(S.pending, i)
            S.stats.matched = S.stats.matched + 1
            return p
        end
    end

    return nil
end

-- Decision for one text_in event. texts: the candidate strings of the event
-- (original message first, then the modified one). Returns hide, entry:
-- entry is the consumed expectation (or nil); hide is true only when it
-- matched AND the chat level is quiet. Never modifies anything but this
-- module's own expectations.
function E.filter(texts, name, level, t)
    if not E.enabled or #S.pending == 0 or type(t) ~= 'number' then
        return false, nil
    end

    prune(t)

    if not validName(name) then
        return false, nil
    end

    for _, text in ipairs(texts or {}) do
        local entry = consume(text, name, t)

        if entry ~= nil then
            local hide = (level == 'quiet')

            if hide then
                S.stats.hidden = S.stats.hidden + 1
            end

            return hide, entry
        end
    end

    return false, nil
end

function E.clear()
    if #S.pending > 0 then
        S.stats.cleared = S.stats.cleared + #S.pending
    end

    S.pending = {}
end

function E.pendingCount() return #S.pending end
function E.stats()        return S.stats end

return E
