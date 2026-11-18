--[[
* FFXIPort (independent frontend) - UI themes and scaling
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* 1.2.0: three themes (Classic = the original brown/gold look and the
* default, Squad = dark navy with restrained gold, Crimson = dark with muted
* burgundy accents) and UI scaling from 70 % to 200 %.
*
* Everything is pushed per window and popped afterwards (push() returns a
* token; pop(token) pops exactly what was pushed), so other addons' windows
* and Ashita's global ImGui style are never changed.
*
* Scaling: Ashita v4 ships Dear ImGui 1.92.x, whose PushFont(font, size)
* sets the font size for the following items (SetWindowFontScale no longer
* exists). push() therefore pushes the current font at base size * scale, and
* all of FFXIPort's own pixel values go through TH.s(px). Frame heights, row
* heights and text measure from the font, so they follow automatically. If the
* font push is unavailable at runtime, sizes still scale and TH.fontScaling
* reports false (shown in /port status) instead of raising an error.
--]]

local imgui = require('imgui')

local TH = {} -- not named T: that is common's T{} constructor

local function rgba(r, g, b, a)
    return { r, g, b, a or 1.0 }
end

local function times(c, f)
    return { math.min(c[1] * f, 1.0), math.min(c[2] * f, 1.0), math.min(c[3] * f, 1.0), c[4] }
end

TH.times = times

TH.ORDER = { 'classic', 'squad', 'crimson' }
TH.NAMES = { classic = 'Classic', squad = 'Squad', crimson = 'Crimson' }

-- Colour keys used by the UI:
--   window, panel, header, button, border    backgrounds / frames
--   text, secondary, muted                    text levels
--   gold                                      headings, "(here)", star, accents
--   tabSel, rowSel                            selected tab / selected row
--   goGold, goText                            Teleport button and its text
--   ok, bad                                   status colours
--   dot                                       this theme's selector dot
--   title, titleActive (optional)             window title bar; nil = Ashita's own
TH.THEMES = {
    -- Classic: the 1.1.0 colours unchanged (features.md V1). No title-bar
    -- colours and no rounding/border changes, so upgrading users see the same
    -- window as before.
    classic = {
        window    = rgba(0.105, 0.095, 0.082),
        panel     = rgba(0.105, 0.095, 0.082),
        header    = rgba(0.23, 0.18, 0.10),
        button    = rgba(0.24, 0.19, 0.10),
        border    = times(rgba(0.23, 0.18, 0.10), 1.25),
        text      = rgba(0.91, 0.89, 0.80),
        gold      = rgba(0.82, 0.63, 0.22),
        tabSel    = rgba(0.53, 0.42, 0.09),
        rowSel    = rgba(0.53, 0.42, 0.09),
        muted     = rgba(0.47, 0.44, 0.36),
        secondary = rgba(0.64, 0.60, 0.50),
        goGold    = rgba(0.82, 0.62, 0.10),
        goText    = rgba(0.10, 0.08, 0.05),
        ok        = rgba(0.55, 0.80, 0.45),
        bad       = rgba(0.90, 0.35, 0.30),
        dot       = rgba(0.86, 0.67, 0.22),
        rounding  = nil,
        frameBorder = nil,
    },

    -- Squad: dark navy / blue-grey with restrained gold, after the
    -- XI: Forever Offline Squad window (reference screenshots).
    squad = {
        window    = rgba(0.067, 0.075, 0.106),       -- #11131B
        panel     = rgba(0.110, 0.118, 0.161),       -- #1C1E29
        header    = rgba(0.150, 0.165, 0.220),
        button    = rgba(0.169, 0.188, 0.255),       -- #2B3041
        border    = rgba(0.300, 0.320, 0.400, 0.55),
        text      = rgba(0.902, 0.922, 0.949),       -- #E6EBF2
        gold      = rgba(0.890, 0.741, 0.400),       -- #E3BD66
        tabSel    = rgba(0.600, 0.470, 0.190),       -- gold-filled active tab
        rowSel    = rgba(0.215, 0.255, 0.360),
        muted     = rgba(0.459, 0.490, 0.549),       -- #757D8C
        secondary = rgba(0.580, 0.612, 0.678),       -- #949CAD
        goGold    = rgba(0.780, 0.620, 0.260),
        goText    = rgba(0.075, 0.075, 0.095),
        ok        = rgba(0.450, 0.780, 0.500),
        bad       = rgba(0.900, 0.420, 0.400),
        dot       = rgba(0.360, 0.560, 0.880),
        title       = rgba(0.080, 0.090, 0.125),
        titleActive = rgba(0.110, 0.125, 0.175),
        rounding  = { window = 6, child = 5, frame = 4, tab = 4 },
        frameBorder = 1,
    },

    -- Crimson: dark warm grey with muted burgundy accents.
    crimson = {
        window    = rgba(0.090, 0.068, 0.074),
        panel     = rgba(0.125, 0.090, 0.100),
        header    = rgba(0.215, 0.110, 0.130),
        button    = rgba(0.285, 0.130, 0.155),
        border    = rgba(0.420, 0.220, 0.250, 0.60),
        text      = rgba(0.930, 0.895, 0.885),
        gold      = rgba(0.900, 0.620, 0.580),       -- rose accent for headings and stars
        tabSel    = rgba(0.500, 0.165, 0.205),
        rowSel    = rgba(0.360, 0.140, 0.175),
        muted     = rgba(0.560, 0.470, 0.480),
        secondary = rgba(0.700, 0.610, 0.610),
        goGold    = rgba(0.640, 0.215, 0.255),
        goText    = rgba(0.985, 0.935, 0.925),
        ok        = rgba(0.560, 0.800, 0.520),
        bad       = rgba(0.990, 0.520, 0.440),
        dot       = rgba(0.820, 0.270, 0.370),
        title       = rgba(0.250, 0.085, 0.105),
        titleActive = rgba(0.340, 0.115, 0.140),
        rounding  = { window = 6, child = 5, frame = 4, tab = 4 },
        frameBorder = 1,
    },
}

TH.current     = 'classic'
TH.colors      = TH.THEMES.classic
TH.scale       = 1.0
TH.fontScaling = nil -- nil = not tried yet, true = font pushed, false = unavailable
TH.fontError   = nil

-- Selects a theme by name; anything unknown selects Classic.
function TH.use(name)
    if TH.THEMES[name] == nil then
        name = 'classic'
    end

    TH.current = name
    TH.colors  = TH.THEMES[name]
    return name
end

-- Sets the UI scale from a percentage (clamped to 70..200).
function TH.setScale(percent)
    local p = tonumber(percent) or 100

    if p ~= p then
        p = 100
    end

    p = math.max(70, math.min(200, p))
    TH.scale = p / 100
    return p
end

function TH.s(px)
    return px * TH.scale
end

-- Unscaled base font size: ImGuiStyle.FontSizeBase (ImGui 1.92), else the
-- current size divided by the global main scale, else 13.
function TH.baseFontSize()
    local ok, v = pcall(function ()
        local st = imgui.GetStyle()
        local base = st and st.FontSizeBase

        if type(base) == 'number' and base > 0 then
            return base
        end

        local size = imgui.GetFontSize()
        local main = (st and type(st.FontScaleMain) == 'number' and st.FontScaleMain > 0) and st.FontScaleMain or 1

        return size / main
    end)

    if ok and type(v) == 'number' and v > 0 then
        return v
    end

    return 13
end

local function pushList(token, list, styleVars)
    for _, item in ipairs(list) do
        if item[1] ~= nil and item[2] ~= nil then
            imgui.PushStyleColor(item[1], item[2])
            token.colors = token.colors + 1
        end
    end

    for _, item in ipairs(styleVars) do
        if item[1] ~= nil and item[2] ~= nil then
            imgui.PushStyleVar(item[1], item[2])
            token.vars = token.vars + 1
        end
    end
end

-- Pushes the selected theme, spacing and font size. Returns a token for pop().
-- opts.font = false skips the font push (used by tests and callers that
-- already pushed one).
function TH.push(opts)
    local c = TH.colors
    local s = TH.s
    local list = {
        { ImGuiCol_WindowBg,          c.window },
        { ImGuiCol_ChildBg,           c.panel },
        { ImGuiCol_PopupBg,           c.window },
        { ImGuiCol_Text,              c.text },
        { ImGuiCol_TextDisabled,      c.muted },
        { ImGuiCol_Border,            c.border },
        { ImGuiCol_Separator,         c.border },
        { ImGuiCol_FrameBg,           c.header },
        { ImGuiCol_FrameBgHovered,    times(c.header, 1.25) },
        { ImGuiCol_FrameBgActive,     times(c.header, 1.40) },
        { ImGuiCol_Button,            c.button },
        { ImGuiCol_ButtonHovered,     times(c.button, 1.25) },
        { ImGuiCol_ButtonActive,      times(c.button, 1.40) },
        { ImGuiCol_Header,            c.header },
        { ImGuiCol_HeaderHovered,     times(c.header, 1.25) },
        { ImGuiCol_HeaderActive,      times(c.header, 1.40) },
        { ImGuiCol_Tab,               c.header },
        { ImGuiCol_TabHovered,        times(c.tabSel, 1.25) },
        { ImGuiCol_TabSelected,       c.tabSel },
        { ImGuiCol_CheckMark,         c.gold },
        { ImGuiCol_SliderGrab,        c.gold },
        { ImGuiCol_ScrollbarGrab,     c.button },
        { ImGuiCol_TableHeaderBg,     c.header },
        { ImGuiCol_TableBorderStrong, c.header },
        { ImGuiCol_TableBorderLight,  c.header },
        { ImGuiCol_TableRowBg,        { 0, 0, 0, 0 } },
        { ImGuiCol_TableRowBgAlt,     { 1, 1, 1, 0.03 } },
        { ImGuiCol_TitleBg,           c.title },
        { ImGuiCol_TitleBgActive,     c.titleActive },
        { ImGuiCol_TitleBgCollapsed,  c.title },
    }

    local styleVars = {
        { ImGuiStyleVar_WindowPadding, { s(10), s(8) } },
        { ImGuiStyleVar_FramePadding,  { s(6), s(3) } },
        { ImGuiStyleVar_ItemSpacing,   { s(8), s(5) } },
        { ImGuiStyleVar_CellPadding,   { s(4), s(2) } },
    }

    if c.rounding ~= nil then
        styleVars[#styleVars + 1] = { ImGuiStyleVar_WindowRounding, s(c.rounding.window) }
        styleVars[#styleVars + 1] = { ImGuiStyleVar_ChildRounding,  s(c.rounding.child) }
        styleVars[#styleVars + 1] = { ImGuiStyleVar_FrameRounding,  s(c.rounding.frame) }
        styleVars[#styleVars + 1] = { ImGuiStyleVar_TabRounding,    s(c.rounding.tab) }
        styleVars[#styleVars + 1] = { ImGuiStyleVar_PopupRounding,  s(c.rounding.frame) }
    end

    if c.frameBorder ~= nil then
        styleVars[#styleVars + 1] = { ImGuiStyleVar_FrameBorderSize, c.frameBorder }
    end

    -- Counted one by one, so even a failing push returns a token that pops
    -- exactly what was pushed.
    local token = { colors = 0, vars = 0, font = false, ok = true }

    token.ok = pcall(pushList, token, list, styleVars)

    if token.ok and not (opts and opts.font == false) then
        local okFont, err = pcall(function ()
            imgui.PushFont(imgui.GetFont(), TH.baseFontSize() * TH.scale)
        end)

        token.font     = okFont
        TH.fontScaling = okFont

        if not okFont then
            TH.fontError = tostring(err)
        end
    end

    return token
end

-- Pops what push() pushed. Each pop is attempted even if another fails;
-- the first error is re-raised afterwards.
function TH.pop(token)
    if token == nil then
        return
    end

    local okFont, errFont, okVars, errVars, okColors, errColors = true, nil, true, nil, true, nil

    if token.font then
        okFont, errFont = pcall(imgui.PopFont)
        token.font = false
    end

    if token.vars > 0 then
        okVars, errVars = pcall(imgui.PopStyleVar, token.vars)
    end

    if token.colors > 0 then
        okColors, errColors = pcall(imgui.PopStyleColor, token.colors)
    end

    if not okFont then
        error(errFont, 0)
    end

    if not okVars then
        error(errVars, 0)
    end

    if not okColors then
        error(errColors, 0)
    end
end

-- Packs a colour for the draw list.
function TH.u32(col)
    local ok, v = pcall(imgui.GetColorU32, col)

    if ok and type(v) == 'number' then
        return v
    end

    -- ABGR packing as ImGui does (fallback only).
    local function b(x) return math.floor(math.max(0, math.min(1, x or 1)) * 255 + 0.5) end
    return ((b(col[4]) * 256 + b(col[3])) * 256 + b(col[2])) * 256 + b(col[1])
end

return TH
