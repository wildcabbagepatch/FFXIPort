-- Cross-checks the client catalogue (catalog_data.lua) against the server
-- module and a LandSandBoat / Phoenix source tree.
-- Usage: luajit tools/verify_catalog_vs_lsb.lua <repo_root> <lsb_root>
--   <lsb_root> must contain scripts/globals/teleports/survival_guide_map.lua
--   and data/enums/zone.yaml (as in LandSandBoat 'base') or
--   scripts/enum/zone.lua / zone.codegen.lua (older trees).
-- GPL-3.0-only, (C) 2026 wildthing.
local root, lsb = arg[1] or '.', arg[2]
assert(lsb, 'usage: verify_catalog_vs_lsb.lua <repo_root> <lsb_root>')

local function exists(p) local f = io.open(p, 'r'); if f then f:close() return true end return false end
local function path(rel)
    local a = lsb .. '/' .. rel
    if exists(a) then return a end
    local b = lsb .. '/' .. rel:gsub('/', '__') -- flattened copies
    if exists(b) then return b end
    return nil
end

-- zone enum
local zones = {}
local zy = path('data/enums/zone.yaml')
if zy then
    for line in io.lines(zy) do
        local name, id = line:match('^%s+([%w_]+):%s+(%d+)')
        if name then zones[name:upper()] = tonumber(id) end
    end
end

xi = { zone = setmetatable({}, { __index = function (_, k)
    local v = zones[k]
    if v == nil then error('unknown zone enum ' .. tostring(k)) end
    return v
end }) }

local sgPath = assert(path('scripts/globals/teleports/survival_guide_map.lua'), 'survival_guide_map.lua not found')
local survival = dofile(sgPath)

-- server module (for H/G/R destinations)
Module = { new = function () return { addOverride = function () end } end }
package.loaded['modules/module_utils'] = true
xi.module = { registerCommand = function () end }
xi.teleport = {
    id = { DEM = 1, HOLLA = 2, YHOAT = 3, VAHZL = 4, MEA = 5, ALTEP = 6,
           AZOUPH_SP = 35, MAMOOL_SP = 36, HALVUNG_SP = 37, DVUCCA_SP = 38, ILRUSI_SP = 39, NYZUL_SP = 40 },
}
local tp = path('scripts/globals/teleports.lua')
if tp then
    -- read xi.teleport.destination rows "[ids.NAME] = { x, y, z, rot, zone }"
    xi.teleport.destination = {}
    for line in io.lines(tp) do
        local name, rest = line:match('^%s+%[ids%.([%w_]+)%]%s*=%s*{(.-)}')
        if name and xi.teleport.id[name] then
            local n = {}
            for v in rest:gmatch('[-%d%.]+') do n[#n + 1] = tonumber(v) end
            xi.teleport.destination[xi.teleport.id[name]] = n
        end
    end
end
package.loaded['scripts/globals/teleports/survival_guide_map'] = survival
dofile(root .. '/server/modules/custom/late/fpxport.lua')
local SRV = xi.fpxport

local cat = dofile(root .. '/client/FFXIPort/ffxiport/catalog_data.lua')
local GATE = { Holla = 0, Dem = 1, Mea = 2, Vahzl = 3, Yhoat = 4, Altep = 5 }
local problems, checked = {}, 0
local function bad(s) problems[#problems + 1] = s end

for _, r in ipairs(cat.hp) do
    checked = checked + 1
    local d = SRV.destination('H', r.id)
    if not d then bad('hp ' .. r.id .. ': no server destination')
    elseif d[5] ~= r.zone then bad(('hp %d: zone %d vs server %d'):format(r.id, r.zone, d[5])) end
    local h = SRV.homePoints[r.id]
    if h and h[1] ~= r.group then bad(('hp %d: group %d vs server %d'):format(r.id, r.group, h[1])) end
end

for _, r in ipairs(cat.sg) do
    checked = checked + 1
    local g = survival.survivalGuides[r.id]
    if not g then bad('sg ' .. r.id .. ': no LSB guide')
    else
        if g.zoneId ~= r.zone then bad(('sg %d: zone %d vs LSB %d'):format(r.id, r.zone, g.zoneId)) end
        if g.group ~= r.sgGroup or g.groupIndex ~= r.sgIndex then
            bad(('sg %d: bit %d:%d vs LSB %d:%d'):format(r.id, r.sgGroup, r.sgIndex, g.group, g.groupIndex))
        end
        if not SRV.destination('S', r.id) then bad('sg ' .. r.id .. ': server has no destination') end
    end
end

for _, r in ipairs(cat.sp) do
    checked = checked + 1
    local d = SRV.destination('G', GATE[r.crystal])
    if not d then bad('sp ' .. r.crystal .. ': no server destination')
    elseif d[5] ~= r.zone then bad(('sp %s: zone %d vs server %d'):format(r.crystal, r.zone, d[5])) end
end

for _, r in ipairs(cat.rp) do
    checked = checked + 1
    local d = SRV.destination('R', r.id)
    if not d then bad('rp ' .. r.id .. ': no server destination')
    elseif d[5] ~= r.zone then bad(('rp %d: zone %d vs server %d'):format(r.id, r.zone, d[5])) end
end

for _, p in ipairs(problems) do print('MISMATCH ' .. p) end
print(('catalog rows checked: %d, mismatches: %d'):format(checked, #problems))
os.exit(#problems == 0 and 0 or 1)
