--[[
* FFXIPort (independent frontend) - main window (read-only)
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Window "FFXIPort" with a header (Refresh, search, Clear, "Only what I can
* use", status line) and exactly four tabs. Rows come from ui/rows.lua.
*
* Balance rules: Begin() is always followed by End(); every other Begin*
* whose call returned true is closed by its End* through rows.guarded(),
* which runs the body under pcall, closes, then re-raises. The theme token
* is popped after End(). A render error therefore unwinds every scope,
* closes the window, and is reported once per distinct message; protocol,
* zone and sync keep running (they tick before render() in FFXIPort.lua).
*
* Milestone 5A: rows are selectable (one session-only selection per tab) and
* a footer shows the selection, "Pay with" (saved per character), balances
* and a Teleport button with the server-provided price.
* Milestone 5B: the Teleport button calls travel.go() (the only send path),
* which revalidates at click time; while a trip is queued, sent, accepted
* or unknown the button is disabled with the trip's reason.
* Milestone 6A: a fifth "Favorites" tab lists the starred destinations of
* all four categories. Its selection is '<tab>:<id>' and the footer resolves
* it to the real category, so methods, price, unlock checks and travel are
* exactly those of the destination's own tab.
--]]

local imgui = require('imgui')

local W = {}

W.TABS = {
    { 'hp', 'Home Points' },
    { 'sg', 'Survival Guides' },
    { 'sp', 'Gate Crystals' },
    { 'rp', 'Runic Portals' },
    { 'fav', 'Favorites' }, -- Milestone 6A: favourites of all four categories
}

W.FAV_EMPTY = 'No favourites yet. Click the * next to a destination.'

W.FORCE_FRAMES = 5 -- frames to keep asking ImGui to select a tab

local D = {} -- catalog, model, config, syncctl, protocol, zone, theme, rows, travel

local S = {
    open        = { false },
    search      = { '' },
    only        = { false },
    forceTab    = nil,
    forceFrames = 0,
    reported    = {},
    note        = nil, -- { text, at }: short message after a refused Refresh
    selected    = {},  -- [tab] = row id (session only)
    activeTab   = nil, -- tab shown this frame
    activeList  = nil, -- its filtered list
}

W.handlers = {} -- onError(text)

function W.init(deps)
    D = deps
end

-----------------------------------------------------------------------------
-- Selection (session only; cleared on logout / character change / unload)
-----------------------------------------------------------------------------

function W.select(tab, id)
    S.selected[tab] = id
end

function W.selection(tab)
    return S.selected[tab]
end

function W.resetSelection()
    S.selected   = {}
    S.activeTab  = nil
    S.activeList = nil
end

-- Matches on BOTH category and id (ids collide across categories, which
-- matters on the mixed Favorites list).
local function findItem(list, tab, id)
    if id == nil or list == nil then
        return nil
    end

    for _, item in ipairs(list) do
        if item.row.tab == tab and item.row.id == id then
            return item
        end
    end

    return nil
end

-- The real (category, id) of a tab's selection. On 'fav' the selection is
-- the composite key '<tab>:<id>'; elsewhere it is the row id of that tab.
function W.resolveSelection(tab)
    local sel = S.selected[tab]

    if sel == nil then
        return nil, nil
    end

    if tab == 'fav' then
        local realTab, idText = string.match(tostring(sel), '^(%a%a):(%d+)$')

        if realTab == nil then
            return nil, nil
        end

        return realTab, tonumber(idText)
    end

    return tab, sel
end

-- Everything the footer shows for a tab, from its selection and the
-- currently visible (filtered) list. No side effects. On 'fav' everything
-- (methods, price, unlock, command, travel) uses the real category.
function W.footerModel(tab, list)
    local realTab, id = W.resolveSelection(tab)
    local row  = (realTab ~= nil) and D.catalog.get(realTab, id) or nil
    local item = findItem(list, realTab, id)

    if realTab == nil then
        realTab = (tab ~= 'fav') and tab or nil
    end

    -- `item and item.unlocked` keeps false as false (locked) and gives nil
    -- only when the row is not visible.
    local unlocked = nil

    if item ~= nil then
        unlocked = item.unlocked
    end

    local zoneId = D.zone.current()
    local here   = row ~= nil and zoneId ~= nil and row.zone == zoneId
    -- realTab is nil only on 'fav' with nothing selected: canSubmit then
    -- reports "Select a destination." (row is nil) and nothing is priced.
    local method = D.travel.method(realTab)
    local quote  = D.travel.quote(realTab, row, zoneId, method)

    local blocked = D.travel.isBlocked()
    local ok, reason = D.travel.canSubmit(realTab, row, unlocked, {
        visible = item ~= nil,
        here    = here,
        zoning  = D.zone.inProgress(),
        busy    = D.protocol.isBusy(),
        pending = blocked,
    })

    if not ok and blocked and row ~= nil and item ~= nil and unlocked == true then
        reason = D.travel.blockReason() or reason
    end

    local command = nil

    if ok then
        command = D.travel.commandFor(realTab, row, method)

        if command == nil then
            ok, reason = false, D.travel.commandProblem(realTab, row, method) or 'This destination is not valid.'
        end
    end

    return {
        tab      = realTab, -- the real category (never 'fav')
        view     = tab,     -- the window tab the footer belongs to
        row      = row,
        unlocked = unlocked,
        method   = method,
        quote    = quote,
        price    = D.travel.priceText(quote),
        low      = ok and D.travel.lowBalance(quote) or false,
        ok       = ok,
        reason   = reason,
        command  = command,
    }
end

function W.isOpen()
    return S.open[1] == true
end

-- Opens the window, optionally on a tab (also saved as the last tab).
function W.open(tab)
    if tab ~= nil then
        D.config.set('tab', tab) -- refused before login; the tab still opens
    end

    S.forceTab    = tab or D.config.get('tab')
    S.forceFrames = W.FORCE_FRAMES
    S.open[1]     = true
end

function W.close()
    S.open[1] = false
end

function W.toggle()
    if W.isOpen() then
        W.close()
    else
        W.open()
    end
end

-----------------------------------------------------------------------------
-- Header
-----------------------------------------------------------------------------

W.NOTE_MS = 5000

local function statusLine(now)
    local c = D.theme.colors

    if D.zone.inProgress() then
        return 'Zone change in progress...', c.muted
    end

    if D.protocol.isBusy() then
        return 'Synchronizing...', c.muted
    end

    if S.note ~= nil and (now - S.note.at) < W.NOTE_MS then
        return S.note.text, c.muted
    end

    local st = D.model.status()

    if st.text ~= nil then
        return st.text, st.bad and c.bad or c.ok
    end

    if not D.model.hasData() then
        return 'Waiting for sync. Press Refresh.', c.muted
    end

    return 'Synchronized.', c.ok
end

local function drawHeader(now)
    local busy = D.protocol.isBusy()

    -- Refresh = manual sync through the existing controller (disabled while
    -- a sync is queued, sent or arriving).
    imgui.BeginDisabled(busy)
    D.rows.guarded(true, function ()
        if imgui.Button('Refresh') and not busy then
            local ok, why = D.syncctl.request('manual', now)

            if ok then
                S.note = nil
            else
                S.note = { text = 'A sync is already in progress (' .. tostring(why) .. ').', at = now }
            end
        end
    end, imgui.EndDisabled)

    imgui.SameLine()
    imgui.SetNextItemWidth(D.theme.s(220))
    imgui.InputTextWithHint('##ffxiport_search', 'Search all tabs', S.search, 64)

    if S.search[1] ~= '' then
        imgui.SameLine()

        if imgui.Button('Clear') then
            S.search[1] = ''
        end
    end

    imgui.SameLine()
    S.only[1] = D.config.get('only_usable') == true

    if imgui.Checkbox('Only what I can use', S.only) then
        D.config.set('only_usable', S.only[1] == true)
    end

    local text, color = statusLine(now)
    imgui.TextColored(color, text)
    imgui.Separator()
end

-----------------------------------------------------------------------------
-- Tabs
-----------------------------------------------------------------------------

-- Height reserved below the table: separator, selection line, Pay-with
-- line, Teleport line.
function W.footerHeight()
    return imgui.GetTextLineHeightWithSpacing() + 2 * imgui.GetFrameHeightWithSpacing() + D.theme.s(8)
end

local function drawTabs(now)
    local query     = S.search[1] or ''
    local filtering = D.catalog.normalize(query) ~= ''
    local only      = D.config.get('only_usable') == true
    local footer    = W.footerHeight()

    S.activeTab, S.activeList = nil, nil

    D.rows.guarded(imgui.BeginTabBar('##ffxiport_tabs'), function ()
        for _, t in ipairs(W.TABS) do
            local tab, label = t[1], t[2]
            local list = D.rows.list(tab, query, only, now)

            if filtering then
                label = string.format('%s (%d)', label, #list)
            end

            local flags = 0

            if S.forceTab == tab then
                flags = ImGuiTabItemFlags_SetSelected
            end

            local selected = imgui.BeginTabItem(label .. '###ffxiport_tab_' .. tab, nil, flags)

            D.rows.guarded(selected, function ()
                if S.forceTab == tab then
                    S.forceTab = nil -- the requested tab is now shown
                elseif S.forceTab == nil and D.config.get('tab') ~= tab then
                    D.config.set('tab', tab) -- user picked a tab; saved once
                end

                S.activeTab, S.activeList = tab, list

                local emptyText = nil

                if tab == 'fav' and #D.config.favourites() == 0 then
                    emptyText = W.FAV_EMPTY
                end

                local clicked, starRow = D.rows.draw(tab, list, footer, S.selected[tab], emptyText)

                if starRow ~= nil then
                    -- Star toggle (config validates; refused before login).
                    D.config.setFavourite(starRow.tab, starRow.id, not D.config.isFavourite(starRow.tab, starRow.id))
                elseif clicked ~= nil then
                    S.selected[tab] = clicked
                end
            end, imgui.EndTabItem)
        end
    end, imgui.EndTabBar)

    if S.forceTab ~= nil then
        S.forceFrames = S.forceFrames - 1

        if S.forceFrames <= 0 then
            S.forceTab = nil
        end
    end

end

-----------------------------------------------------------------------------
-- Footer (Milestone 5A: preview only)
-----------------------------------------------------------------------------

local function brighter(col, f)
    return { math.min(col[1] * f, 1), math.min(col[2] * f, 1), math.min(col[3] * f, 1), col[4] }
end

local DARK_TEXT = { 0.10, 0.08, 0.05, 1.0 }

local function contentWidth()
    local ok, w = pcall(imgui.GetContentRegionAvail)

    if ok and type(w) == 'table' then
        w = w[1] or w.x
    end

    return (ok and type(w) == 'number') and w or nil
end

local function drawFooter(now)
    local c = D.theme.colors

    imgui.Separator()

    local tab = S.activeTab

    if tab == nil then
        imgui.TextDisabled('Select a destination.')
        return
    end

    local f = W.footerModel(tab, S.activeList)

    -- Line 1: selection
    if f.row ~= nil then
        local text = 'Selected: ' .. D.rows.displayName(f.row)
        local secondary = D.rows.secondaryText(f.row, tab == 'fav')

        if secondary ~= nil then
            text = text .. '  ' .. secondary
        end

        imgui.Text(D.rows.fitText(text, contentWidth()))
    else
        imgui.TextDisabled('Select a destination.')
    end

    -- Line 2: Pay with + balances
    imgui.AlignTextToFramePadding()
    imgui.Text('Pay with:')

    local balances = {}
    local payTab   = f.tab -- the real category (Favorites resolve to it)

    if payTab == nil then
        imgui.SameLine()
        imgui.TextDisabled('select a destination')
    else
        for _, m in ipairs(D.travel.methodsFor(payTab)) do
            imgui.SameLine()

            if imgui.RadioButton(D.travel.METHOD_LABEL[m] .. '##ffxiport_pay_' .. tab .. '_' .. m, f.method == m) then
                D.travel.setMethod(payTab, m)
            end

            balances[#balances + 1] = D.travel.balanceText(m) .. ' ' .. D.travel.CURRENCY[m]
        end
    end

    if #balances > 0 then
        imgui.SameLine()
        imgui.TextDisabled('You have: ' .. table.concat(balances, ' / '))
    end

    -- Line 3: Teleport
    local label = 'Teleport'

    if f.price ~= nil then
        label = label .. '  -  ' .. f.price
    end

    local colors

    if f.low then
        -- P4: dimmed but still clickable; the server re-checks the balance.
        colors = { { ImGuiCol_Button, c.button }, { ImGuiCol_ButtonHovered, brighter(c.button, 1.25) },
                   { ImGuiCol_ButtonActive, brighter(c.button, 1.40) }, { ImGuiCol_Text, c.muted } }
    else
        colors = { { ImGuiCol_Button, c.goGold }, { ImGuiCol_ButtonHovered, brighter(c.goGold, 1.15) },
                   { ImGuiCol_ButtonActive, brighter(c.goGold, 1.25) }, { ImGuiCol_Text, DARK_TEXT } }
    end

    imgui.BeginDisabled(not f.ok)
    D.rows.guarded(true, function ()
        D.rows.withColors(colors, function ()
            if imgui.Button(label .. '###ffxiport_teleport') and f.ok and f.command ~= nil then
                -- Explicit user action: the only place a trip is requested.
                local sent, why = D.travel.go(f.tab, f.row.id, f.method)

                if not sent then
                    S.note = { text = tostring(why), at = now }
                end
            end
        end)

        if f.low and imgui.IsItemHovered() then
            imgui.SetTooltip('Your last known balance looks too low; the server checks again.')
        end
    end, imgui.EndDisabled)

    imgui.SameLine()

    if not f.ok and f.reason ~= nil then
        imgui.TextColored(c.muted, f.reason)
    else
        imgui.TextColored(c.muted, 'The server checks the unlock and your balance.')
    end
end

-----------------------------------------------------------------------------
-- Render
-----------------------------------------------------------------------------

local function report(err)
    local text = tostring(err)

    if S.reported[text] then
        return
    end

    S.reported[text] = true

    if type(W.handlers.onError) == 'function' then
        pcall(W.handlers.onError, text)
    end
end

-- Error unwinding (every step is reached whatever fails before it):
--   1. theme push, window setup, Begin() and the body run under one pcall;
--      `began` is set only after Begin() returned;
--   2. End() runs (under pcall) exactly when Begin() returned - also when
--      the body failed - and never after a failed Begin();
--   3. the theme token is popped (under pcall) whenever a token exists;
--   4. any failure closes the window and is reported once.
function W.render(now)
    if not S.open[1] then
        return
    end

    local token = nil
    local began = false

    local ok, err = pcall(function ()
        local s = D.theme.s

        token = D.theme.push()

        if not token.ok then
            error('theme push failed', 0)
        end

        imgui.SetNextWindowSize({ s(660), s(480) }, ImGuiCond_FirstUseEver)
        imgui.SetNextWindowSizeConstraints({ s(480), s(300) }, { FLT_MAX, FLT_MAX })

        local visible = imgui.Begin('FFXIPort', S.open, ImGuiWindowFlags_None)
        began = true

        if visible then
            drawHeader(now)
            drawTabs(now)
            drawFooter(now)
        end
    end)

    if began then
        local okEnd, errEnd = pcall(imgui.End)

        if not okEnd and ok then
            ok, err = false, errEnd
        end
    end

    if token ~= nil then
        local okPop, errPop = pcall(D.theme.pop, token)

        if not okPop and ok then
            ok, err = false, errPop
        end
    end

    if not ok then
        S.open[1] = false
        report(err)
    end
end

return W
