--[[
* FFXIPort (independent frontend) - UI theme
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Colours from docs/ffxiport-independent/features.md V1. The window title
* bar keeps Ashita's native colours (W1): no TitleBg* colour is pushed.
* No fonts are bundled (V2).
*
* Every push returns a token; pop(token) pops exactly what was pushed, so
* nothing leaks into other addons' windows (V4). Callers pop in the same
* function, after End(), even when rendering failed.
*
* Scaling (V3) is prepared via TH.s(px) but fixed at 100 % in this milestone;
* font scaling is not implemented yet (the installed ImGui exposes
* PushFont(font, size); SetWindowFontScale is not in the annotations).
--]]

local imgui = require('imgui')

local TH = {} -- not named T: that is common's T{} constructor

local function rgba(r, g, b, a)
    return { r, g, b, a or 1.0 }
end

local function times(c, f)
    return { math.min(c[1] * f, 1.0), math.min(c[2] * f, 1.0), math.min(c[3] * f, 1.0), c[4] }
end

-- features.md V1
TH.colors = {
    window   = rgba(0.105, 0.095, 0.082),
    header   = rgba(0.23, 0.18, 0.10),
    button   = rgba(0.24, 0.19, 0.10),
    text     = rgba(0.91, 0.89, 0.80),
    gold     = rgba(0.82, 0.63, 0.22),
    tabSel   = rgba(0.53, 0.42, 0.09),
    muted    = rgba(0.47, 0.44, 0.36),
    -- secondary row text (Gate Crystal / Runic Portal details): brighter
    -- than muted, dimmer than text, same warm hue (Milestone 4.1)
    secondary = rgba(0.64, 0.60, 0.50),
    goGold   = rgba(0.82, 0.62, 0.10),
    -- status colours (W3: green = ok, red = error)
    ok       = rgba(0.55, 0.80, 0.45),
    bad      = rgba(0.90, 0.35, 0.30),
}

TH.scale = 1.0 -- fixed at 100 % in this milestone

function TH.s(px)
    return px * TH.scale
end

-- Pushes the FFXIPort colours and spacing. Returns a token for pop().
function TH.push()
    local c = TH.colors
    local list = {
        { ImGuiCol_WindowBg,          c.window },
        { ImGuiCol_ChildBg,           c.window },
        { ImGuiCol_PopupBg,           c.window },
        { ImGuiCol_Text,              c.text },
        { ImGuiCol_TextDisabled,      c.muted },
        { ImGuiCol_Border,            times(c.header, 1.25) },
        { ImGuiCol_Separator,         c.header },
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
        { ImGuiCol_ScrollbarGrab,     c.button },
        { ImGuiCol_TableHeaderBg,     c.header },
        { ImGuiCol_TableBorderStrong, c.header },
        { ImGuiCol_TableBorderLight,  c.header },
        { ImGuiCol_TableRowBg,        { 0, 0, 0, 0 } },
        { ImGuiCol_TableRowBgAlt,     { 1, 1, 1, 0.03 } },
    }

    local styleVars = {
        { ImGuiStyleVar_WindowPadding, { TH.s(10), TH.s(8) } },
        { ImGuiStyleVar_FramePadding,  { TH.s(6), TH.s(3) } },
        { ImGuiStyleVar_ItemSpacing,   { TH.s(8), TH.s(5) } },
    }

    -- Counted one by one, so even a failing push returns a token that pops
    -- exactly what was pushed.
    local token = { colors = 0, vars = 0, ok = true }

    token.ok = pcall(function ()
        for _, item in ipairs(list) do
            if item[1] ~= nil then
                imgui.PushStyleColor(item[1], item[2])
                token.colors = token.colors + 1
            end
        end

        for _, item in ipairs(styleVars) do
            if item[1] ~= nil then
                imgui.PushStyleVar(item[1], item[2])
                token.vars = token.vars + 1
            end
        end
    end)

    return token
end

-- Pops what push() pushed. Each pop is attempted even if the other fails;
-- the first error is re-raised afterwards.
function TH.pop(token)
    if token == nil then
        return
    end

    local okVars, errVars, okColors, errColors = true, nil, true, nil

    if token.vars > 0 then
        okVars, errVars = pcall(imgui.PopStyleVar, token.vars)
    end

    if token.colors > 0 then
        okColors, errColors = pcall(imgui.PopStyleColor, token.colors)
    end

    if not okVars then
        error(errVars, 0)
    end

    if not okColors then
        error(errColors, 0)
    end
end

return TH
