--[[
* FFXIPort (independent frontend) - destination rows (read-only)
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Builds the filtered row list of a tab (via catalog.filter, cached) and
* draws it as a scrolling table: star, destination, expansion, status.
* 1.2.0: expansion filter in R.list; drawn favourite star (ui/widgets.lua);
* row selection colour from the theme.
* Availability comes only from model.lua (true / false / nil); the current
* zone is used only for the Home Point "(here)" marker and the Survival
* Guide "Here" status wording (Milestone 4.1).
* No travel controls: nothing here can send a request.
--]]

local imgui = require('imgui')
local WG    = require('ffxiport.ui.widgets')

local R = {}

R.CACHE_MS = 1000

local D = {}     -- catalog, model, zone, theme, config
local cache = {} -- [tab] = { key, at, list }

-- Categories in Favorites order (Milestone 6A).
R.CATEGORIES = { 'hp', 'sg', 'sp', 'rp' }
R.CATEGORY_LABEL = { hp = 'Home Point', sg = 'Survival Guide', sp = 'Gate Crystal', rp = 'Runic Portal' }

-- Selection / favourite key of a row: '<tab>:<id>'.
function R.key(row)
    return tostring(row.tab) .. ':' .. tostring(row.id)
end

function R.init(deps)
    D = deps
end

-- Calls body only when opened is true, then close(), then re-raises any
-- error from body: every Begin*/End* pair stays balanced.
function R.guarded(opened, body, close)
    if not opened then
        return
    end

    local ok, err = pcall(body)
    close()

    if not ok then
        error(err, 0)
    end
end

-- Filtered list for a tab: { { row, unlocked }, ... }. Rebuilt when the
-- query, the switch or the model revision changes, and at most once per
-- CACHE_MS otherwise (client names may resolve late). The "(here)" markers
-- are computed while drawing, so zone changes need no rebuild.
--
-- tab 'fav' (Milestone 6A): the favourite rows of all four categories, in
-- category order, each filtered exactly like its own tab (search and "Only
-- what I can use" via catalog.filter). Its cache key also contains the
-- favourites, so starring/unstarring refreshes it at once.
--
-- 1.2.0: expansion ('all' or nil = no filter; else base|roz|cop|toau) keeps
-- only rows of that expansion, in their existing order, on every tab
-- (including Favorites). It combines with search and "Only what I can use"
-- as a further AND condition; unlocks and favourites are not touched.
function R.list(tab, query, onlyUsable, now, expansion)
    local hasData = D.model.hasData()
    local exp = (expansion ~= nil and expansion ~= 'all') and expansion or nil
    local parts = { query or '', tostring(onlyUsable and hasData), tostring(D.model.revision()), tostring(exp) }

    if tab == 'fav' then
        parts[#parts + 1] = table.concat(D.config.favourites(), ',')
    end

    local key = table.concat(parts, '\1')
    local c = cache[tab]

    if c ~= nil and c.key == key and (now - c.at) < R.CACHE_MS then
        return c.list
    end

    local opts = {
        text       = query,
        onlyUsable = onlyUsable and hasData,
        model      = hasData and D.model or nil,
    }
    local list

    if tab == 'fav' then
        list = {}

        for _, cat in ipairs(R.CATEGORIES) do
            for _, item in ipairs(D.catalog.filter(cat, opts)) do
                if D.config.isFavourite(cat, item.row.id) then
                    list[#list + 1] = item
                end
            end
        end
    else
        list = D.catalog.filter(tab, opts)
    end

    if exp ~= nil then
        local kept = {}

        for _, item in ipairs(list) do
            if item.row.exp == exp then
                kept[#kept + 1] = item
            end
        end

        list = kept
    end

    cache[tab] = { key = key, at = now, list = list }
    return list
end

function R.clearCache()
    cache = {}
end

local LOCKED_HINT = {
    hp = 'This Home Point has not been registered yet.',
    sg = 'This Survival Guide has not been registered yet.',
    rp = 'Use the Runic Portal at this staging point once to attune it.',
}

local function lockedHint(row)
    if row.tab == 'sp' then
        return 'Requires the key item: ' .. tostring(D.catalog.requirement(row))
    end

    return LOCKED_HINT[row.tab] or 'Not available.'
end

-- Status labels. color = theme colour key, nil = disabled (muted) text.
R.STATUS = {
    available = { text = 'Available',        color = 'ok' },
    here      = { text = 'Here',             color = 'gold', tip = 'You are in this zone.' },
    locked    = { text = 'Locked',           color = 'bad' },
    waiting   = { text = 'Waiting for sync', color = nil },
}

-- Display status of a row. Availability is the model's value unchanged:
-- "Here" only rewords an UNLOCKED Survival Guide in the current zone; a
-- locked or unsynced one still shows Locked / Waiting for sync. Home Points
-- keep their "(here)" marker next to the name (features W7).
function R.statusOf(row, unlocked, here)
    if unlocked == true then
        if here and row.tab == 'sg' then
            return R.STATUS.here
        end

        return R.STATUS.available
    elseif unlocked == false then
        return R.STATUS.locked
    end

    return R.STATUS.waiting
end

local EXPANSION_KEYS = { 'base', 'roz', 'cop', 'toau' }

local function textWidth(text)
    local ok, w = pcall(imgui.CalcTextSize, text)

    if ok and type(w) == 'table' then
        w = w[1] or w.x
    end

    if ok and type(w) == 'number' then
        return w
    end

    return #text * 7
end

-- Verified Home Point location designations (generated by
-- tools/gen_hp_suffix.ps1; E = entrance/exit, A = Auction House, M = Mog
-- House). Loaded once; a missing or broken file means "no suffixes".
local HP_SUFFIX = nil

local function hpSuffixes()
    if HP_SUFFIX == nil then
        local ok, data = pcall(require, 'ffxiport.homepoint_suffix_data')
        HP_SUFFIX = (ok and type(data) == 'table') and data or {}
    end

    return HP_SUFFIX
end

-- Displayed row name (presentation only; catalog names and search keys are
-- unchanged): Gate Crystals read "Teleport - <crystal>"; Home Points with a
-- verified designation read "<zone> #<n> (E|A|M)".
function R.displayName(row)
    local name = D.catalog.name(row)

    if row.tab == 'sp' then
        return 'Teleport - ' .. name
    elseif row.tab == 'hp' then
        local s = hpSuffixes()[row.id]

        if s == 'E' or s == 'A' or s == 'M' then
            return name .. ' (' .. s .. ')'
        end
    end

    return name
end

-- Secondary line under the name, or nil. Gate Crystals show only the
-- destination zone; the required key item stays in the Locked tooltip.
-- fav = true (Favorites tab): the line also names the category, e.g.
-- "Home Point" or "Gate Crystal - to Eastern Altepa Desert".
function R.secondaryText(row, fav)
    local base = nil

    if row.tab == 'sp' then
        base = 'to ' .. D.catalog.destination(row)
    elseif row.tab == 'rp' then
        base = 'in ' .. D.catalog.destination(row)
    end

    if fav then
        local label = R.CATEGORY_LABEL[row.tab] or '?'

        if base ~= nil then
            return label .. ' - ' .. base
        end

        return label
    end

    return base
end

-- Shortens text with "..." so it fits maxW pixels (byte-wise; catalog
-- names are ASCII). Returns text unchanged when it fits or maxW is unknown.
-- The table also clips each cell, so this only makes the cut readable.
function R.fitText(text, maxW)
    if type(maxW) ~= 'number' or maxW <= 0 or textWidth(text) <= maxW then
        return text
    end

    local n = #text

    while n > 0 and textWidth(string.sub(text, 1, n) .. '...') > maxW do
        n = n - 1
    end

    if n <= 0 then
        return '...'
    end

    return string.sub(text, 1, n) .. '...'
end

local function availWidth()
    local ok, w = pcall(imgui.GetContentRegionAvail)

    if ok and type(w) == 'table' then
        w = w[1] or w.x
    end

    if ok and type(w) == 'number' then
        return w
    end

    return nil
end

-- Fixed widths of the Expansion and Status columns, measured from the
-- longest label each can show (same for all four tabs). Destination
-- stretches over the remaining width.
function R.columnWidths()
    local pad = D.theme.s(16)
    local expW, statusW = 0, 0

    for _, key in ipairs(EXPANSION_KEYS) do
        expW = math.max(expW, textWidth(D.catalog.expansionLabel(key)))
    end

    for _, st in pairs(R.STATUS) do
        statusW = math.max(statusW, textWidth(st.text))
    end

    return expW + pad, statusW + pad
end

-- Pushes colours, runs body, pops exactly what was pushed (also on error),
-- then re-raises.
function R.withColors(list, body)
    local n = 0
    local ok, err = pcall(function ()
        for _, item in ipairs(list) do
            imgui.PushStyleColor(item[1], item[2])
            n = n + 1
        end

        body()
    end)

    if n > 0 then
        imgui.PopStyleColor(n)
    end

    if not ok then
        error(err, 0)
    end
end

-- Hidden, unique selectable id for a row (the visible part is the name).
function R.selectableId(row)
    return '##ffxiport_sel_' .. tostring(row.tab) .. '_' .. tostring(row.id)
end

-- Height of a row's destination cell: one text line, or two when a
-- secondary line is shown.
function R.rowHeight(row, fav)
    local line = imgui.GetTextLineHeight()

    if R.secondaryText(row, fav) ~= nil then
        return imgui.GetTextLineHeightWithSpacing() + line
    end

    return line
end

-- Star control id (hidden, unique per category and id).
function R.starId(row)
    return '##ffxiport_fav_' .. tostring(row.tab) .. '_' .. tostring(row.id)
end

-- Star size: one text line, so it follows the UI scale with the font.
function R.starSize()
    local ok, h = pcall(imgui.GetTextLineHeight)
    return (ok and type(h) == 'number' and h > 0) and h or D.theme.s(14)
end

-- Draws one row; returns clicked (row selected), starred (star toggled).
-- Columns: 0 star, 1 destination, 2 expansion, 3 status.
-- The destination name IS the selectable's visible label (with a hidden
-- unique id). The selectable spans all columns (row highlight) and is as
-- tall as the cell, so the whole row is one click target; the "(here)"
-- marker and the secondary line are drawn on top of it (AllowOverlap) at
-- fixed positions inside the cell. The star is drawn LAST, back in column
-- 0, so it is the later overlapping item and takes the hover/click; a star
-- click never also selects the row.
-- selectedKey: the row id (category tabs) or '<tab>:<id>' (fav = true).
local function drawRow(item, currentZone, selectedKey, fav)
    local row   = item.row
    local c     = D.theme.colors
    local here  = currentZone ~= nil and row.zone == currentZone
    local name  = R.displayName(row)
    local secondary = R.secondaryText(row, fav)
    local mine  = row.id

    if fav then
        mine = R.key(row)
    end

    imgui.TableNextRow()

    -- Destination (selectable row)
    imgui.TableSetColumnIndex(1)

    local x0, y0 = imgui.GetCursorPosX(), imgui.GetCursorPosY()
    local clicked = imgui.Selectable(name .. R.selectableId(row), selectedKey ~= nil and selectedKey == mine,
        bit.bor(ImGuiSelectableFlags_SpanAllColumns, ImGuiSelectableFlags_AllowOverlap), { 0, R.rowHeight(row, fav) })

    -- Overlay items are positioned so the LAST one ends exactly at the
    -- selectable's bottom edge (one-line rows: "(here)" on line 1; two-line
    -- rows: the secondary line on line 2). The cursor therefore ends where
    -- it would after the selectable alone, with a real item submitted after
    -- every SetCursorPos (no bare cursor moves at the end of a cell).
    if row.tab == 'hp' and here then
        imgui.SetCursorPos({ x0 + textWidth(name) + D.theme.s(6), y0 })
        imgui.TextColored(c.gold, '(here)')
    end

    if secondary ~= nil then
        imgui.SetCursorPos({ x0, y0 + imgui.GetTextLineHeightWithSpacing() })

        if row.tab == 'sp' or fav then
            -- Truncate within the Destination column when narrowed.
            secondary = R.fitText(secondary, availWidth())
        end

        imgui.TextColored(c.secondary, secondary)
    end

    -- Expansion
    imgui.TableNextColumn()
    imgui.TextDisabled(D.catalog.expansionLabel(row.exp))

    -- Status (server-derived only)
    imgui.TableNextColumn()

    local st = R.statusOf(row, item.unlocked, here)

    if st.color ~= nil then
        imgui.TextColored(c[st.color], st.text)
    else
        imgui.TextDisabled(st.text)
    end

    if imgui.IsItemHovered() then
        if st == R.STATUS.locked then
            imgui.SetTooltip(lockedHint(row))
        elseif st.tip ~= nil then
            imgui.SetTooltip(st.tip)
        end
    end

    -- Favourite star (column 0), drawn last: see above.
    imgui.TableSetColumnIndex(0)

    local isFav   = D.config.isFavourite(row.tab, row.id)
    local starred, hovered = WG.star(R.starId(row), R.starSize(), isFav)

    if hovered then
        imgui.SetTooltip(isFav and 'Remove from favourites' or 'Add to favourites')
    end

    if starred then
        clicked = false -- a star click never selects the row
    end

    return clicked == true, starred
end

-- Draws the table of one tab. footer: height to leave below the table.
-- selectedKey: the tab's selection (row id; '<tab>:<id>' on 'fav').
-- emptyText: shown instead of the table when the list is empty.
-- Returns clickedKey (same form as selectedKey) or nil, and the row whose
-- star was clicked this frame (or nil). Toggling is up to the caller.
function R.draw(tab, list, footer, selectedKey, emptyText)
    if #list == 0 then
        imgui.TextDisabled(emptyText or 'No destinations match.')
        return nil, nil
    end

    local fav = (tab == 'fav')
    local currentZone = D.zone.current()
    local expW, statusW = R.columnWidths()
    local flags = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_ScrollY, ImGuiTableFlags_SizingStretchProp)
    local c = D.theme.colors
    local clickedKey, starRow = nil, nil

    -- Selected row: the theme's row-selection colour (Classic: the 1.1.0
    -- gold-brown); hover slightly lighter. Scoped to this table and popped
    -- even on errors.
    R.withColors({
        { ImGuiCol_Header,        c.rowSel },
        { ImGuiCol_HeaderHovered, c.button },
        { ImGuiCol_HeaderActive,  c.rowSel },
    }, function ()
        R.guarded(imgui.BeginTable('##ffxiport_rows_' .. tab, 4, flags, { 0, -(footer or 0) }), function ()
            imgui.TableSetupScrollFreeze(0, 1)
            imgui.TableSetupColumn('##ffxiport_star', ImGuiTableColumnFlags_WidthFixed, R.starSize() + D.theme.s(6))
            imgui.TableSetupColumn('Destination', ImGuiTableColumnFlags_WidthStretch)
            imgui.TableSetupColumn('Expansion', ImGuiTableColumnFlags_WidthFixed, expW)
            imgui.TableSetupColumn('Status', ImGuiTableColumnFlags_WidthFixed, statusW)
            imgui.TableHeadersRow()

            for _, item in ipairs(list) do
                local clicked, starred = drawRow(item, currentZone, selectedKey, fav)

                if starred then
                    starRow = item.row
                elseif clicked then
                    if fav then
                        clickedKey = R.key(item.row)
                    else
                        clickedKey = item.row.id
                    end
                end
            end
        end, imgui.EndTable)
    end)

    return clickedKey, starRow
end

return R
