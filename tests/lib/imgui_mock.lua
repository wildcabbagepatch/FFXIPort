-- Recording mock of the Ashita v4 / Dear ImGui 1.92 Lua API surface used by
-- FFXIPort's UI (ui/window.lua, ui/rows.lua, ui/theme.lua, ui/widgets.lua).
-- It does NOT render anything. It records calls, tracks the colour / style /
-- font stacks, simulates a simple line layout (item positions and widths)
-- and lets tests script clicks, hovers and drags.
-- GPL-3.0-only, (C) 2026 wildthing.
local M = {}

local BASE_FONT = 13
local CHAR_W    = 7 -- text width per character at BASE_FONT

-- ImGui enum globals: unique values per name. Flag enums (names containing
-- "Flags_") get distinct powers of two so they can be combined with bit.bor
-- and tested; all other enums (colours, style vars, conditions) get distinct
-- small integers.
local enumCache, nextFlag, nextIndex = {}, 0, 0
local function enumValue(name)
    if enumCache[name] == nil then
        if name:find('Flags_', 1, true) then
            enumCache[name] = 2 ^ nextFlag
            nextFlag = nextFlag + 1
        else
            nextIndex = nextIndex + 1
            enumCache[name] = nextIndex
        end
    end
    return enumCache[name]
end

function M.installGlobals()
    setmetatable(_G, { __index = function (_, k)
        if type(k) == 'string' and k:match('^ImGui') then return enumValue(k) end
        return nil
    end })
    _G.FLT_MAX = 3.4e38
    if rawget(_G, 'bit') == nil then
        _G.bit = { bor = function (...)
            local r = 0
            for _, v in ipairs({ ... }) do r = r + v end
            return r
        end, band = function (a, b) return a == b and a or 0 end }
    end
end

function M.new()
    local S = {
        calls = {}, colors = {}, vars = {}, fonts = {}, windows = {},
        clicks = {}, hovers = {}, active = {}, dragDelta = { 0, 0 },
        windowWidth = 660, popupOpen = {}, items = {}, drawn = {},
        tabs = {}, comboOpen = {},
    }
    local im = {}
    M.state = S

    local function log(name, a) S.calls[#S.calls + 1] = { name = name, a = a } end
    local function fontSize() return S.fonts[#S.fonts] and S.fonts[#S.fonts].size or BASE_FONT end
    local function scaleF() return fontSize() / BASE_FONT end
    local function var(name, default)
        for i = #S.vars, 1, -1 do if S.vars[i].idx == enumValue(name) then return S.vars[i].value end end
        return default
    end
    local function padX() local v = var('ImGuiStyleVar_WindowPadding', { 8, 8 }) return v[1] end
    local function framePad() return var('ImGuiStyleVar_FramePadding', { 4, 3 }) end
    local function spacingX() return var('ImGuiStyleVar_ItemSpacing', { 8, 4 })[1] end

    -- simple layout ---------------------------------------------------------
    local L = { x = 0, lastEnd = 0, sameLine = false, line = 0, nextWidth = nil, pendingX = nil }
    local function contentRight() return S.windowWidth - padX() end
    local function place(id, w)
        if L.pendingX ~= nil then
            L.x = L.pendingX
            L.pendingX = nil
        elseif not L.sameLine then
            L.line = L.line + 1
            L.x = padX()
        end
        local item = { id = id, x = L.x, w = w, line = L.line, window = S.current }
        S.items[#S.items + 1] = item
        S.last = item
        L.lastEnd = L.x + w
        L.x = L.lastEnd
        L.sameLine = false
        return item
    end
    function im.SameLine(offset, spacing)
        L.sameLine = true
        if offset ~= nil and offset > 0 then
            L.pendingX = offset
        else
            L.pendingX = L.lastEnd + (spacing ~= nil and spacing >= 0 and spacing or spacingX())
        end
    end
    function im.NewLine() L.sameLine = false; L.pendingX = nil end
    function im.GetCursorPosX() return L.pendingX or (L.sameLine and L.x) or padX() end
    function im.GetCursorPosY() return L.line * 20 end
    function im.SetCursorPosX(x) L.pendingX = x; L.sameLine = true end
    function im.SetCursorPos(p) L.pendingX = p[1]; L.sameLine = true end
    function im.GetContentRegionAvail()
        local x = L.pendingX or (L.sameLine and L.x) or padX()
        return { contentRight() - x, 300 }
    end
    function im.SetNextItemWidth(w) L.nextWidth = w end

    -- text metrics -------------------------------------------------------------
    function im.CalcTextSize(text) return { #(text:gsub('##.*$', '')) * CHAR_W * scaleF(), fontSize() } end
    function im.GetFontSize() return fontSize() end
    function im.GetTextLineHeight() return fontSize() end
    function im.GetTextLineHeightWithSpacing() return fontSize() + var('ImGuiStyleVar_ItemSpacing', { 8, 4 })[2] end
    function im.GetFrameHeight() return fontSize() + 2 * framePad()[2] end
    function im.GetFrameHeightWithSpacing() return im.GetFrameHeight() + var('ImGuiStyleVar_ItemSpacing', { 8, 4 })[2] end
    function im.GetStyle() return { FontSizeBase = BASE_FONT, FontScaleMain = 1 } end
    function im.GetFont() return S.fontObject or 'default-font' end
    function im.AlignTextToFramePadding() end
    local function textW(s) return im.CalcTextSize(s)[1] end

    -- stacks -------------------------------------------------------------------
    function im.PushStyleColor(idx, col) log('PushStyleColor', { idx, col }); S.colors[#S.colors + 1] = { idx = idx, col = col } end
    function im.PopStyleColor(n) for _ = 1, n or 1 do assert(#S.colors > 0, 'PopStyleColor underflow'); S.colors[#S.colors] = nil end end
    function im.PushStyleVar(idx, v) S.vars[#S.vars + 1] = { idx = idx, value = v } end
    function im.PopStyleVar(n) for _ = 1, n or 1 do assert(#S.vars > 0, 'PopStyleVar underflow'); S.vars[#S.vars] = nil end end
    function im.PushFont(font, size)
        if S.failFont then error('PushFont not available') end
        log('PushFont', { font, size })
        S.fonts[#S.fonts + 1] = { font = font, size = size }
    end
    function im.PopFont() assert(#S.fonts > 0, 'PopFont underflow'); S.fonts[#S.fonts] = nil end
    function im.GetColorU32(col) return { u32 = col } end
    function M.colorPushed(name)
        for i = #S.colors, 1, -1 do if S.colors[i].idx == enumValue(name) then return S.colors[i].col end end
        return nil
    end

    -- windows ------------------------------------------------------------------
    function im.SetNextWindowSize(sz, cond) log('SetNextWindowSize', sz) end
    function im.SetNextWindowSizeConstraints(a, b) log('SetNextWindowSizeConstraints', { a, b }) end
    function im.SetNextWindowPos(p, cond) log('SetNextWindowPos', p); S.nextPos = p end
    function im.Begin(name, open, flags)
        log('Begin', { name, flags })
        S.windows[#S.windows + 1] = { name = name, flags = flags, pos = S.nextPos, colorsAtBegin = {}, varsAtBegin = {} }
        for i, c in ipairs(S.colors) do S.windows[#S.windows].colorsAtBegin[i] = c end
        for i, v in ipairs(S.vars) do S.windows[#S.windows].varsAtBegin[i] = v end
        S.current = name
        S.nextPos = nil
        L.line, L.x, L.sameLine, L.pendingX = 0, 0, false, nil
        if S.failIn == name then error('injected render failure') end
        return true
    end
    function im.End() log('End'); S.current = nil end

    -- draw list ----------------------------------------------------------------
    local dl = {}
    for _, fn in ipairs({ 'AddLine', 'AddTriangleFilled', 'AddCircleFilled', 'AddCircle', 'AddRectFilled' }) do
        dl[fn] = function (self, ...) S.drawn[#S.drawn + 1] = { fn = fn, args = { ... } } end
    end
    function im.GetWindowDrawList() return dl end

    -- interaction helpers --------------------------------------------------------
    local function key(label) return (label:match('##(.*)$') or label:match('###(.*)$') or label) end
    local function takeClick(label)
        local k = key(label)
        if S.clicks[k] then S.clicks[k] = nil return true end
        if S.clicks[label] then S.clicks[label] = nil return true end
        return false
    end
    function im.IsItemHovered() return S.last ~= nil and (S.hovers[S.last.id] == true) end
    function im.IsItemActive() return S.last ~= nil and (S.active[S.last.id] == true) end
    function im.GetItemRectMin() return { S.last and S.last.x or 0, 10 } end
    function im.GetMouseDragDelta() return { S.dragDelta[1], S.dragDelta[2] } end
    function im.SetTooltip(t) log('SetTooltip', t) end

    -- widgets ------------------------------------------------------------------
    function im.Button(label, size)
        local w = (size and size[1]) or (textW(label) + 2 * framePad()[1])
        place(key(label), w)
        log('Button', label)
        return takeClick(label)
    end
    function im.SmallButton(label)
        place(key(label), textW(label) + 2 * framePad()[1])
        log('SmallButton', label)
        return takeClick(label)
    end
    function im.InvisibleButton(id, size)
        place(key(id), size[1])
        log('InvisibleButton', { id, size })
        return takeClick(id)
    end
    function im.Text(t) place('text', textW(t)); log('Text', t) end
    function im.TextDisabled(t) place('text', textW(t)); log('TextDisabled', t) end
    function im.TextColored(c, t) place('text', textW(t)); log('TextColored', { c, t }) end
    function im.Separator() L.sameLine = false; L.pendingX = nil end
    function im.InputTextWithHint(id, hint, buf, n) place(key(id), L.nextWidth or 200); L.nextWidth = nil end
    function im.Checkbox(label, buf)
        place(key(label), im.GetFrameHeight() + spacingX() + textW(label))
        if takeClick(label) then buf[1] = not buf[1] return true end
        return false
    end
    function im.RadioButton(label, on) place(key(label), im.GetFrameHeight() + textW(label)); return takeClick(label) end
    function im.BeginDisabled() end
    function im.EndDisabled() end
    function im.Selectable(label, selected, flags, size)
        place(key(label), 100)
        log('Selectable', label)
        return takeClick(label)
    end
    function im.OpenPopup(id) S.popupOpen[key(id)] = true; log('OpenPopup', id) end
    function im.BeginPopup(id) return S.popupOpen[key(id)] == true end
    function im.EndPopup() end
    function im.BeginCombo(id, preview)
        place(key(id), L.nextWidth or 120)
        L.nextWidth = nil
        log('BeginCombo', { id, preview })
        return S.comboOpen[key(id)] == true
    end
    function im.EndCombo() end

    -- tabs / tables --------------------------------------------------------------
    function im.BeginTabBar() return true end
    function im.EndTabBar() end
    function im.BeginTabItem(label, open, flags)
        log('BeginTabItem', label)
        local k = label:match('###ffxiport_tab_(%w+)$')
        return S.activeTab == nil and k == 'hp' or S.activeTab == k
    end
    function im.EndTabItem() end
    function im.BeginTable() return true end
    function im.EndTable() end
    function im.TableSetupScrollFreeze() end
    function im.TableSetupColumn(name, flags, w) log('TableSetupColumn', { name, w }) end
    function im.TableHeadersRow() end
    function im.TableNextRow() L.sameLine = false end
    function im.TableSetColumnIndex() L.sameLine = false end
    function im.TableNextColumn() L.sameLine = false end

    M.im = im
    return im, S
end

-- helpers for tests -------------------------------------------------------------
function M.reset(keepWidth)
    local S = M.state
    S.calls, S.items, S.drawn, S.windows = {}, {}, {}, {}
end

function M.calls(name)
    local out = {}
    for _, c in ipairs(M.state.calls) do if c.name == name then out[#out + 1] = c.a end end
    return out
end

function M.window(namePart)
    for _, w in ipairs(M.state.windows) do if w.name:find(namePart, 1, true) then return w end end
    return nil
end

-- Colour pushed for an ImGuiCol_* index when a window began.
function M.colorAtBegin(window, colName)
    for i = #window.colorsAtBegin, 1, -1 do
        local c = window.colorsAtBegin[i]
        if c.idx == enumValue(colName) then return c.col end
    end
    return nil
end

-- Style var pushed for an ImGuiStyleVar_* index when a window began.
function M.varAtBegin(window, varName)
    for i = #window.varsAtBegin, 1, -1 do
        local v = window.varsAtBegin[i]
        if v.idx == enumValue(varName) then return v.value end
    end
    return nil
end

-- True when a flag enum is set in a window's flags.
function M.hasFlag(window, flagName)
    local v = enumValue(flagName)
    return math.floor((window.flags or 0) / v) % 2 == 1
end

M.enumValue = enumValue

return M
