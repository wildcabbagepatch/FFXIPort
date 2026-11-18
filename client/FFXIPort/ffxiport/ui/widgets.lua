--[[
* FFXIPort (independent frontend) - small drawn controls (1.2.0)
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Controls drawn with the window draw list on top of an InvisibleButton
* (the button provides hover, click and the item rectangle), so no icon font
* or external asset is needed:
*   star(id, size, on)      favourite star: outline (off) / filled (on)
*   dot(id, size, col, on)  theme selector dot; `on` draws a ring
* All sizes are already-scaled pixels (callers use theme.s()).
--]]

local imgui = require('imgui')

local WG = {}

local TH -- theme module (set by init)

function WG.init(theme)
    TH = theme
end

-- ImVec2 results may arrive as a table ({x, y} or {x=, y=}) or as two numbers.
function WG.vec(a, b)
    if type(a) == 'table' then
        return a[1] or a.x or 0, a[2] or a.y or 0
    end

    return a or 0, b or 0
end

-- The five outer and five inner points of a star centred at (cx, cy).
function WG.starPoints(cx, cy, r)
    local pts = {}
    local inner = r * 0.45

    for k = 0, 9 do
        local radius = (k % 2 == 0) and r or inner
        local angle  = -math.pi / 2 + k * math.pi / 5
        pts[#pts + 1] = { cx + radius * math.cos(angle), cy + radius * math.sin(angle) }
    end

    return pts
end

-- Favourite star. Returns clicked, hovered.
function WG.star(id, size, on)
    local c = TH.colors
    local clicked = imgui.InvisibleButton(id, { size, size }) == true
    local hovered = imgui.IsItemHovered() == true
    local x, y = WG.vec(imgui.GetItemRectMin())
    local dl = imgui.GetWindowDrawList()

    local cx, cy = x + size / 2, y + size / 2
    local r = size * 0.45
    local pts = WG.starPoints(cx, cy, r)

    local fill = c.gold
    local edge = on and c.gold or (hovered and c.text or c.muted)

    if hovered then
        fill = TH.times(c.gold, 1.2)
        -- subtle hover backdrop
        dl:AddRectFilled({ x, y }, { x + size, y + size }, TH.u32({ c.button[1], c.button[2], c.button[3], 0.85 }), size * 0.2)
    end

    if on then
        local fc = TH.u32(fill)

        for k = 1, 10 do
            local a = pts[k]
            local b = pts[(k % 10) + 1]
            dl:AddTriangleFilled({ cx, cy }, a, b, fc)
        end
    elseif hovered then
        -- preview of the filled state, translucent
        local fc = TH.u32({ fill[1], fill[2], fill[3], 0.35 })

        for k = 1, 10 do
            dl:AddTriangleFilled({ cx, cy }, pts[k], pts[(k % 10) + 1], fc)
        end
    end

    local ec = TH.u32(edge)
    local thickness = math.max(1, size / 12)

    for k = 1, 10 do
        dl:AddLine(pts[k], pts[(k % 10) + 1], ec, thickness)
    end

    return clicked, hovered
end

-- Theme selector dot. Returns clicked, hovered.
function WG.dot(id, size, col, on)
    local c = TH.colors
    local clicked = imgui.InvisibleButton(id, { size, size }) == true
    local hovered = imgui.IsItemHovered() == true
    local x, y = WG.vec(imgui.GetItemRectMin())
    local dl = imgui.GetWindowDrawList()
    local cx, cy = x + size / 2, y + size / 2
    local r = size * 0.30

    if hovered then
        r = size * 0.34
    end

    dl:AddCircleFilled({ cx, cy }, r, TH.u32(col))

    if on then
        dl:AddCircle({ cx, cy }, size * 0.46, TH.u32(c.text), 0, math.max(1, size / 10))
    end

    return clicked, hovered
end

return WG
