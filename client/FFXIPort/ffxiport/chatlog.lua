--[[
* FFXIPort (independent frontend) - chat output policy and read-only trace
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Milestone 6B. Every chat line FFXIPort itself prints goes through
* CL.emit(category, style, text). The per-character level (config key
* chat_level: quiet | normal | debug) decides whether it is shown.
*
* Safety rules:
*   - unknown categories are SHOWN (fail open: nothing is hidden by mistake);
*   - errors, travel problems (refusals, failures after acceptance with
*     refunds, unknown outcomes, cancellations), warnings and protocol
*     warnings are shown at every level;
*   - CL.explicit(fn) shows EVERYTHING printed inside fn (used for commands
*     the user typed: /port status, /port catalog, /port raw, /port chat).
*
* The trace (/port chat trace on) is session-only and READ-ONLY: it never
* sets or changes e.blocked or any message/packet field. It records chat
* lines seen within TRACE_WINDOW_MS after FFXIPort really sent a command,
* at most TRACE_MAX lines per window, each cut to TRACE_TEXT chars, and
* ignores FFXIPort's own output (no recursion). While tracing is on, up to
* TRACE_PRE_MAX lines from the last TRACE_PRE_MS are held so an echo that
* appears just before the send notification is not missed; held lines are
* shown only if a send follows, and are discarded otherwise.
--]]

local CL = {}

CL.LEVELS = { quiet = 1, normal = 2, debug = 3 }
CL.DEFAULT_LEVEL = 'quiet'

-- Minimum level at which a category is shown.
CL.POLICY = {
    ['explicit']        = 1, -- user-typed diagnostics / command feedback
    ['error']           = 1, -- sync invalid/timeout/send failure, render/tick errors
    ['travel.problem']  = 1, -- refused, failed + refund, unknown, cancelled, send failed
    ['travel.accepted'] = 1, -- ONE line per successful trip (server text incl. payment)
    ['warning']         = 1, -- zone fallback, request held, already in progress
    ['protocol.warn']   = 1, -- protocol.onWarn: shown in quiet (cannot tell benign from critical)
    ['sync.manual_ok']  = 1, -- one line after /port sync while the window is closed
    ['travel.complete'] = 2,
    ['sync.auto_ok']    = 2,
    ['session']         = 2,
    ['envelope.other']  = 2,
    ['travel.progress'] = 3,
    ['sync.progress']   = 3,
    ['sync.detail']     = 3,
    ['protocol.info']   = 3, -- protocol.onInfo, e.g. the reply message offset (not a warning)
}

CL.TRACE_WINDOW_MS = 5000
CL.TRACE_MAX       = 20
CL.TRACE_TEXT      = 80
CL.TRACE_PREFIX    = 'trace: '
-- An echo may appear synchronously inside QueueCommand, i.e. just BEFORE
-- the "sent" notification opens the window. While tracing is on, the last
-- few lines (at most TRACE_PRE_MAX, kept TRACE_PRE_MS) are held and shown
-- only if a send follows within that time; otherwise they are discarded.
CL.TRACE_PRE_MS    = 1000
CL.TRACE_PRE_MAX   = 5

local S = {
    getLevel = nil,  -- function () -> level name
    printers = {},   -- style -> function (text)
    explicit = 0,    -- depth of CL.explicit scopes
    printing = false,
    trace    = { on = false, untilAt = nil, count = 0, dropped = 0, pre = {} },
}

function CL.init(getLevel, printers)
    S.getLevel = getLevel
    S.printers = printers or {}
end

function CL.level()
    local ok, v = pcall(S.getLevel or function () return nil end)

    if ok and CL.LEVELS[v] ~= nil then
        return v
    end

    return CL.DEFAULT_LEVEL
end

-- Pure policy: is `category` shown at `level`? Unknown categories: yes.
function CL.shows(category, level)
    local need = CL.POLICY[category]
    local have = CL.LEVELS[level] or CL.LEVELS[CL.DEFAULT_LEVEL]

    if need == nil then
        return true
    end

    return have >= need
end

local function print_(style, text)
    local fn = S.printers[style] or S.printers.out

    if type(fn) ~= 'function' then
        return
    end

    S.printing = true
    pcall(fn, text)
    S.printing = false
end

-- Prints text in `style` (out | good | bad | note) if the category is shown.
-- Returns true when printed.
function CL.emit(category, style, text)
    if S.explicit > 0 or CL.shows(category, CL.level()) then
        print_(style, text)
        return true
    end

    return false
end

-- Runs fn with every emit inside it shown (user-requested diagnostics).
function CL.explicit(fn, ...)
    S.explicit = S.explicit + 1

    local ok, err = pcall(fn, ...)

    S.explicit = S.explicit - 1

    if not ok then
        error(err, 0)
    end
end

-----------------------------------------------------------------------------
-- Category helpers (pure)
-----------------------------------------------------------------------------

-- Travel report -> category, from the report's bad flag and the travel
-- state at report time (travel.lua sets the state before reporting).
function CL.travelCategory(bad, state)
    if bad then
        return 'travel.problem'
    elseif state == 'queued' or state == 'sent' then
        return 'travel.progress'
    elseif state == 'accepted' then
        return 'travel.accepted'
    elseif state == 'idle' then
        return 'travel.complete'
    end

    return 'travel.problem' -- anything unexpected stays visible
end

-- Sync state report -> categories for its parts:
--   main    (the one summary line), reasons (failure reasons),
--   detail  (unlock/price/balance details, "Response complete and checksummed.").
-- nil = that part is not printed at all for this state.
function CL.syncPlan(state, origin, windowOpen)
    -- 'startup' (7A, the session's initial sync) is automatic like a zone re-sync.
    local automatic = (origin == 'auto' or origin == 'retry' or origin == 'startup' or origin == 'server')

    if state == 'queued' or state == 'sent' then
        if automatic then
            return {}
        end

        return { main = 'sync.progress' }
    elseif state == 'ok' then
        if automatic then
            return { main = 'sync.auto_ok', detail = 'sync.detail' }
        end

        -- Manual: the window's status line already shows success.
        return { main = windowOpen and 'sync.detail' or 'sync.manual_ok', detail = 'sync.detail' }
    elseif state == 'invalid' then
        return { main = 'error', reasons = 'error', detail = 'sync.detail' }
    elseif state == 'timeout' or state == 'send_failed' then
        return { main = 'error', reasons = 'error' }
    end

    return {}
end

-----------------------------------------------------------------------------
-- Read-only trace (session only)
-----------------------------------------------------------------------------

function CL.setTrace(on)
    S.trace = { on = on == true, untilAt = nil, count = 0, dropped = 0, pre = {} }
end

function CL.traceStatus()
    return S.trace
end

local function cut(text)
    text = tostring(text or '')
    text = string.gsub(text, '%c', ' ')

    if #text > CL.TRACE_TEXT then
        text = string.sub(text, 1, CL.TRACE_TEXT) .. '...'
    end

    return text
end

local function traceLine(text)
    print_('note', CL.TRACE_PREFIX .. text)
end

-- An FFXIPort command really left (travel onSent / sync 'sent').
function CL.traceSent(line, t)
    local tr = S.trace

    if not tr.on then
        return
    end

    if tr.dropped > 0 then
        traceLine(string.format('(%d further line(s) in the previous window not shown)', tr.dropped))
    end

    tr.untilAt = t + CL.TRACE_WINDOW_MS
    tr.count   = 0
    tr.dropped = 0
    traceLine('sent "' .. cut(line) .. '"')

    -- Lines seen just before the send (e.g. a synchronous echo).
    local pre = tr.pre
    tr.pre = {}

    for _, p in ipairs(pre) do
        if (t - p.t) <= CL.TRACE_PRE_MS and tr.count < CL.TRACE_MAX then
            tr.count = tr.count + 1
            traceLine(string.format('%s %s "%s" (%d ms before the send)', p.source, p.detail, p.text, t - p.t))
        end
    end
end

-- A chat line observed by a read-only hook. source: 'text_in' | 'text_out'
-- | 'packet'. Never modifies anything; returns true when printed.
function CL.traceSeen(source, detail, text, t)
    local tr = S.trace

    if not tr.on then
        return false
    end

    if S.printing then
        return false -- our own print re-entering through text_in
    end

    text = tostring(text or '')

    if string.find(text, 'FFXIPort', 1, true) or string.find(text, CL.TRACE_PREFIX, 1, true) then
        return false -- FFXIPort's own output (header or trace lines)
    end

    source, detail = tostring(source), tostring(detail or '')

    -- Outside a window: hold briefly in case a send follows (bounded).
    if tr.untilAt == nil or t > tr.untilAt then
        tr.pre[#tr.pre + 1] = { source = source, detail = detail, text = cut(text), t = t }

        while #tr.pre > CL.TRACE_PRE_MAX do
            table.remove(tr.pre, 1)
        end

        return false
    end

    if tr.count >= CL.TRACE_MAX then
        tr.dropped = tr.dropped + 1
        return false
    end

    tr.count = tr.count + 1
    traceLine(string.format('%s %s "%s"', source, detail, cut(text)))
    return true
end

return CL
