-- Generates client/FFXIPort/ffxiport/catalog_data.lua from LandSandBoat /
-- Phoenix sources plus tools/catalog_facts.lua. GPL-3.0-only, (C) 2026 wildthing.
--
-- Usage (from the repository root):
--   luajit tools/gen_catalog.lua <lsb_root> [out_file]
-- <lsb_root> is a LandSandBoat/Phoenix server tree. Files may also be given
-- flattened ('/' replaced by '__') in that folder. Reads only:
--   data/enums/zone.yaml                               zone ids and enum names
--   scripts/globals/homepoint.lua                      Home Points: index, group, zone, "#n", position
--   scripts/globals/teleports/survival_guide_map.lua   Survival Guides: menu id, zone, unlock bit
--   scripts/globals/teleports.lua                      teleport ids and destinations (Gate Crystals, Runic Portals)
--   scripts/enum/magic.lua                             Teleport spell ids
--   data/enums/key_item.yaml                           Gate Crystal key item ids
-- plus server/modules/custom/late/fpxport.lua (M.cityGroupOfZone, itself
-- generated from LSB by tools/gen_city_groups.lua) and tools/catalog_facts.lua.
-- It does not read any earlier FFXIPort server module, protocol or catalogue.
local lsb, outFile = arg[1], arg[2] or 'client/FFXIPort/ffxiport/catalog_data.lua'
assert(lsb, 'usage: gen_catalog.lua <lsb_root> [out_file]')

local function open(rel)
    for _, p in ipairs({ lsb .. '/' .. rel, lsb .. '/' .. rel:gsub('/', '__') }) do
        local f = io.open(p, 'r')
        if f then return f, p end
    end
    error('missing LSB file ' .. rel)
end

local function lines(rel)
    local f = open(rel)
    local out = {}
    for l in f:lines() do out[#out + 1] = l end
    f:close()
    return out
end

local facts = dofile('tools/catalog_facts.lua')

-- zones ------------------------------------------------------------------
local zoneByName, zoneEnum = {}, {}
for _, l in ipairs(lines('data/enums/zone.yaml')) do
    local name, id = l:match('^%s+([%w_]+):%s+(%d+)')
    if name then
        zoneByName[name:upper()] = tonumber(id)
        zoneEnum[tonumber(id)] = name:upper()
    end
end

local function inScope(zone)
    local exp = facts.zoneExpansion[zone]
    assert(exp ~= nil, 'catalog_facts.lua: no expansion for zone ' .. tostring(zone) .. ' ' .. tostring(zoneEnum[zone]))
    return facts.scope[exp] == true
end

-- Home Points (homepoint.lua) ----------------------------------------------
local hp = {}
for _, l in ipairs(lines('scripts/globals/homepoint.lua')) do
    local idx, g, rest, zn, comment = l:match('^%s+%[%s*(%d+)%] = { group = (%d+), fee = %d+, dest = {(.-), xi%.zone%.([%w_]+)%s*} },?%s*%-%-(.*)$')
    if idx then
        local nums = {}
        for v in rest:gmatch('[-%d%.]+') do nums[#nums + 1] = tonumber(v) end
        local zone = assert(zoneByName[zn], 'unknown zone ' .. zn)
        local num  = tonumber(comment:match('#(%d+)'))
        local exists = not (nums[1] == 0 and nums[2] == 0 and nums[3] == 0) -- LSB marks missing Home Points with 0,0,0
        if exists and inScope(zone) then
            hp[#hp + 1] = { id = tonumber(idx), zone = zone, num = assert(num, 'no #n for Home Point ' .. idx), group = tonumber(g) }
        end
    end
end
table.sort(hp, function (a, b) return a.id < b.id end)

-- Survival Guides (survival_guide_map.lua) ---------------------------------
_G.xi = { zone = setmetatable({}, { __index = function (_, k) return assert(zoneByName[k], 'unknown zone ' .. k) end }) }
local _, sgPath = open('scripts/globals/teleports/survival_guide_map.lua')
local survival = dofile(sgPath)
local sg = {}
for id, g in pairs(survival.survivalGuides) do
    if inScope(g.zoneId) then
        sg[#sg + 1] = { id = id, zone = g.zoneId, sgGroup = g.group, sgIndex = g.groupIndex }
    end
end
table.sort(sg, function (a, b) return a.id < b.id end)

-- Teleport destinations (teleports.lua) -------------------------------------
local teleId, teleDest = {}, {}
for _, l in ipairs(lines('scripts/globals/teleports.lua')) do
    local name, id = l:match('^%s+([%u_]+)%s*=%s*(%d+),')
    if name and teleId[name] == nil then teleId[name] = tonumber(id) end
    local dname, rest = l:match('^%s+%[ids%.([%w_]+)%]%s*=%s*{(.-)}')
    if dname then
        local n = {}
        for v in rest:gmatch('[-%d%.]+') do n[#n + 1] = tonumber(v) end
        teleDest[dname] = n
    end
end

-- Spells (magic.lua) and key items (key_item.yaml) -------------------------
local spell = {}
for _, l in ipairs(lines('scripts/enum/magic.lua')) do
    local name, id = l:match('^%s+(TELEPORT_[%u]+)%s*=%s*(%d+)')
    if name then spell[name] = tonumber(id) end
end

local keyItem = {}
for _, l in ipairs(lines('data/enums/key_item.yaml')) do
    local name, id = l:match('^%s+([%w_]+):%s+(%d+)')
    if name then keyItem[name] = tonumber(id) end
end

local sp = {}
for _, c in ipairs(facts.gateCrystals) do
    local d = assert(teleDest[c.tele], 'no destination for ' .. c.tele)
    sp[#sp + 1] = { id = assert(spell[c.spell], c.spell), zone = d[5], keyItem = assert(keyItem[c.keyItem], c.keyItem), crystal = c.crystal }
end

local rp = {}
for id = 1, 6 do
    local r = facts.runicPortals[id]
    local d = assert(teleDest[r.tele], 'no destination for ' .. r.tele)
    rp[#rp + 1] = { id = id, zone = d[5], label = r.label }
end

-- City groups (server module, LSB-derived) ----------------------------------
_G.Module = { new = function () return { addOverride = function () end } end }
package.loaded['modules/module_utils'] = true
_G.xi = { module = { registerCommand = function () end } }
dofile('server/modules/custom/late/fpxport.lua')
local city = xi.fpxport.cityGroupOfZone

-- Zones referenced by rows -------------------------------------------------
local zones = {}
for _, list in ipairs({ hp, sg, sp, rp }) do
    for _, r in ipairs(list) do
        zones[r.zone] = { exp = facts.zoneExpansion[r.zone], enum = zoneEnum[r.zone] }
        assert(facts.scope[zones[r.zone].exp], 'out-of-scope zone ' .. r.zone)
    end
end

-- Output ---------------------------------------------------------------------
local out = {}
local function w(s) out[#out + 1] = s end
local function sortedKeys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end

w('-- FFXIPort - GENERATED destination catalogue. Do not edit by hand.')
w('-- Generator: tools/gen_catalog.lua (FFXIPort 1.1.0); provenance: docs/CATALOGUE.md')
w('-- Inputs: LandSandBoat/Phoenix data/enums/zone.yaml, scripts/globals/homepoint.lua,')
w('--   scripts/globals/teleports/survival_guide_map.lua, scripts/globals/teleports.lua,')
w('--   scripts/enum/magic.lua, data/enums/key_item.yaml (GPL-3.0, (c) LandSandBoat / Darkstar Dev Teams);')
w('--   server/modules/custom/late/fpxport.lua cityGroupOfZone (generated from LSB by tools/gen_city_groups.lua);')
w('--   tools/catalog_facts.lua (hand-maintained: catalogue scope, zone expansions, Gate Crystal order,')
w('--   Runic Portal labels). No earlier FFXIPort server module, protocol or catalogue is an input.')
w('-- Display names come from the client at runtime; enum names are a fallback only.')
w('return {')
w('    version = 7,')
w(string.format('    counts  = { hp = %d, sg = %d, sp = %d, rp = %d },', #hp, #sg, #sp, #rp))
w('')
w('    -- zone id -> { exp = base|roz|cop|toau, enum = xi.zone name }')
w('    zones = {')
for _, z in ipairs(sortedKeys(zones)) do
    w(string.format("        [%d] = { exp = '%s', enum = '%s' },", z, zones[z].exp, zones[z].enum))
end
w('    },')
w('')
w('    -- zone id -> same-city group (fpxport.lua cityGroupOfZone; LSB-derived)')
w('    city = {')
for _, z in ipairs(sortedKeys(city)) do
    w(string.format('        [%d] = %d,', z, city[z]))
end
w('    },')
w('')
w('    -- id = homepointData index, num = the "#n" of that Home Point in its zone')
w('    hp = {')
for _, r in ipairs(hp) do
    w(string.format('        { id = %d, zone = %d, num = %d, group = %d },', r.id, r.zone, r.num, r.group))
end
w('    },')
w('')
w('    -- id = survival guide menu id; unlock bit = word sgGroup - 1, bit sgIndex - 1')
w('    sg = {')
for _, r in ipairs(sg) do
    w(string.format('        { id = %d, zone = %d, sgGroup = %d, sgIndex = %d },', r.id, r.zone, r.sgGroup, r.sgIndex))
end
w('    },')
w('')
w('    -- id = Teleport spell id (row id only; no spell is needed);')
w('    -- keyItem = the Gate Crystal key item (the only requirement)')
w('    sp = {')
for _, r in ipairs(sp) do
    w(string.format("        { id = %d, zone = %d, keyItem = %d, crystal = '%s' },", r.id, r.zone, r.keyItem, r.crystal))
end
w('    },')
w('')
w('    -- id = xi.teleport.runic_portal (attunement bit); label = staging point')
w('    rp = {')
for _, r in ipairs(rp) do
    w(string.format("        { id = %d, zone = %d, label = '%s' },", r.id, r.zone, r.label))
end
w('    },')
w('}')

local f = assert(io.open(outFile, 'wb'))
f:write(table.concat(out, '\n') .. '\n')
f:close()
print(string.format('wrote %s: hp %d, sg %d, sp %d, rp %d, zones %d, city %d', outFile, #hp, #sg, #sp, #rp, #sortedKeys(zones), #sortedKeys(city)))
