-- Isolated mocks of the Phoenix/LandSandBoat Lua API surface used by
-- server/modules/custom/late/fpxport.lua. Signatures follow LSB
-- scripts/specs/core/CBaseEntity.lua. GPL-3.0-only, (C) 2026 wildthing.
local L = {}

function L.installGlobals()
    _G.Module = {
        new = function(_, name)
            local m = { name = name, overrides = {} }
            function m:addOverride(target, fn) self.overrides[target] = fn end
            return m
        end,
    }
    package.loaded['modules/module_utils'] = true

    _G.xi = {
        module = {
            registered = {},
            registerCommand = function(name, cmd) _G.xi.module.registered[name] = cmd end,
        },
        teleport = {
            type = { RUNIC_PORTAL = 3, HOMEPOINT = 9, SURVIVAL = 10 },
            id = { DEM = 1, HOLLA = 2, YHOAT = 3, VAHZL = 4, MEA = 5, ALTEP = 6,
                   AZOUPH_SP = 35, MAMOOL_SP = 36, HALVUNG_SP = 37, DVUCCA_SP = 38, ILRUSI_SP = 39, NYZUL_SP = 40 },
            destination = {
                [1] = { 220.000, 19.104, 300.000, 0, 108 },
                [2] = { 420.000, 19.104, 20.000, 0, 102 },
                [3] = { -280.942, 0.596, -144.156, 0, 124 },
                [4] = { 150.258, -21.048, -37.256, 94, 112 },
                [5] = { 100.000, 35.151, 340.000, 0, 117 },
                [6] = { -61.942, 3.949, 224.900, 0, 114 },
                [35] = { 522.730, -28.009, -502.621, 161, 79 },
                [36] = { -210.291, -11.500, -818.056, 255, 52 },
                [37] = { 688.994, -23.960, 351.496, 191, 61 },
                [38] = { -265.632, -6.000, -29.472, 94, 79 },
                [39] = { 17.540, -7.250, 627.968, 254, 54 },
                [40] = { 222.798, -0.500, 19.872, 0, 72 },
            },
        },
        keyItem = {
            HOLLA_GATE_CRYSTAL = 101, DEM_GATE_CRYSTAL = 102, MEA_GATE_CRYSTAL = 103,
            VAHZL_GATE_CRYSTAL = 104, YHOATOR_GATE_CRYSTAL = 105, ALTEPA_GATE_CRYSTAL = 106,
            RHAPSODY_IN_WHITE = 200, CAPTAIN_WILDCAT_BADGE = 201,
        },
        effect = { BATTLEFIELD = 254 },
        zone = { MORDION_GAOL = 131 },
        animation = { CHOCOBO = 5, MOUNT = 85 },
    }

    -- Subset of LSB survival_guide_map.lua entries (menu id -> guide)
    package.loaded['scripts/globals/teleports/survival_guide_map'] = {
        survivalGuides = {
            [0]  = { zoneId = 231, group = 1, groupIndex = 25, posX = 1, posY = 0, posZ = 1, posRot = 0 },
            [6]  = { zoneId = 100, group = 1, groupIndex = 1, posX = -451.4, posY = -19.75, posZ = -218, posRot = 128 },
            [11] = { zoneId = 103, group = 1, groupIndex = 2, posX = 137.9, posY = -7.5, posZ = 97, posRot = 162 },
            [40] = { zoneId = 50,  group = 2, groupIndex = 3, posX = 1, posY = 2, posZ = 3, posRot = 0 },
            [97] = { zoneId = 257, group = 4, groupIndex = 1, posX = 4, posY = 5, posZ = 6, posRot = 0 },
        },
    }
end

-- Player mock. opts: gil, cp, is, zone, id, hp = {idx...}, sg = {menuId...}, ki = {name...}, runic = mask
function L.player(opts)
    opts = opts or {}
    local p = {
        id = opts.id or 21828, gil = opts.gil or 100000, cp = opts.cp or 5000, is = opts.is or 5000,
        zone = opts.zone or 230, pos = opts.pos or { 0, 0, 0 },
        hp = {}, sg = {}, ki = {}, runic = opts.runic or 0,
        dead = false, event = false, engaged = false, enmity = false, anim = 0, instance = nil,
        effects = {}, localVars = {}, printed = {}, moved = nil, moveError = false,
    }
    for _, i in ipairs(opts.hp or {}) do p.hp[i] = true end
    for _, n in ipairs(opts.ki or {}) do p.ki[_G.xi.keyItem[n]] = true end
    local map = package.loaded['scripts/globals/teleports/survival_guide_map'].survivalGuides
    for _, menu in ipairs(opts.sg or {}) do
        local g = map[menu]
        p.sg[(g.group - 1) * 32 + (g.groupIndex - 1)] = true
    end

    function p:getID() return self.id end
    function p:getZoneID() return self.zone end
    function p:hasTeleport(t, bit, set)
        if t == 9 then return self.hp[(set or 0) * 32 + bit] == true end
        if t == 10 then return self.sg[(set or 0) * 32 + bit] == true end
        return false
    end
    function p:getTeleport(t) if t == 3 then return self.runic end return 0 end
    function p:hasKeyItem(k) return self.ki[k] == true end
    function p:getGil() return self.gil end
    function p:delGil(n) self.gil = self.gil - n end
    function p:addGil(n) self.gil = self.gil + n end
    function p:getCP() return self.cp end
    function p:delCP(n) self.cp = self.cp - n end
    function p:addCP(n) self.cp = self.cp + n end
    function p:getCurrency(name) if name == 'imperial_standing' then return self.is end return 0 end
    function p:delCurrency(name, n) if name == 'imperial_standing' then self.is = self.is - n end end
    function p:addCurrency(name, n) if name == 'imperial_standing' then self.is = self.is + n end end
    function p:getInstance() return self.instance end
    function p:hasStatusEffect(e) return self.effects[e] == true end
    function p:isDead() return self.dead end
    function p:isInEvent() return self.event end
    function p:isEngaged() return self.engaged end
    function p:hasEnmity() return self.enmity end
    function p:getAnimation() return self.anim end
    function p:getLocalVar(k) return self.localVars[k] or 0 end
    function p:checkDistance(x, y, z)
        local dx, dy, dz = self.pos[1] - x, self.pos[2] - y, self.pos[3] - z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    function p:setPos(x, y, z, rot, zone)
        if self.moveError then error('setPos failed') end
        self.moved = { x, y, z, rot, zone }
        self.zone = zone
        self.pos = { x, y, z }
    end
    -- getZone(true): destination zone while zoning (the mock moves instantly,
    -- so it is always the current zone unless a test sets zoningTo).
    function p:getZone(dest)
        local id = (dest and self.zoningTo) or self.zone
        return { getID = function () return id end }
    end
    function p:printToPlayer(msg, channel) self.printed[#self.printed + 1] = { msg = msg, channel = channel } end
    function p:takePrinted()
        local out = {}
        for i, e in ipairs(self.printed) do out[i] = e end
        self.printed = {}
        return out
    end

    -- Fault injection: p.faults[method] = function (self, ...) -> 'before' | 'after' | nil
    --   'before': raise without calling the real method (no effect)
    --   'after' : call the real method (effect happens), then raise
    p.faults = {}
    p.calls  = {}
    local unpackf = table.unpack or unpack
    for name, fn in pairs(p) do
        if type(fn) == 'function' and name ~= 'takePrinted' then
            p[name] = function (self, ...)
                self.calls[name] = (self.calls[name] or 0) + 1
                local f = self.faults[name]
                local when = f and f(self, ...)
                if when == 'before' then error('injected fault before ' .. name) end
                local r = { fn(self, ...) }
                if when == 'after' then error('injected fault after ' .. name) end
                return unpackf(r)
            end
        end
    end
    return p
end

return L
