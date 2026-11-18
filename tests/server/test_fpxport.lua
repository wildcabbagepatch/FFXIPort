-- Server module tests for fpxport.lua against isolated LSB API mocks.
-- GPL-3.0-only, (C) 2026 wildthing.
--
-- Mock world (tests/lib/lsb_mock.lua): the player starts in zone 230
-- (Southern San d'Oria, city group 1) with 100,000 gil, 5,000 CP, 5,000 IS.
-- Home Points used: 5 = Northern San d'Oria (231, same city), 9 = Bastok
-- Mines (234, other city), 0 = Southern San d'Oria (230), 17 = Windurst
-- Waters (238), 39 = Kazham (250, no city), 65 = Aht Urhgan Whitegate (50).
-- Survival Guides: 0 = Northern San d'Oria (231), 6 = West Ronfaure (100).
local root = arg and arg[1] or '.'
package.path = root .. '/tests/lib/?.lua;' .. package.path

local H    = require('harness')
local L    = require('lsb_mock')
local F    = require('frames')

local S, clock
local function load()
    L.installGlobals()
    local m = dofile(root .. '/server/modules/custom/late/fpxport.lua')
    S = xi.fpxport
    clock = 1000000
    S.now = function() return clock end
    S.log = function() end
    return m
end

-- Frames only; plain-text notices are returned separately.
local function split(p)
    local frames, notices = {}, {}
    for _, e in ipairs(p:takePrinted()) do
        if e.msg:sub(1, 4) == '#fpx' then frames[#frames + 1] = e else notices[#notices + 1] = e.msg end
    end
    return F.decode(frames), notices
end

-- Default client session id. Request lines written as "<ver> <rid> ..." get
-- it inserted ("<ver> <sid> <rid> ..."); runRaw sends a line unchanged.
local SID = 'a1b2c3d4e5f6'
local function withSid(line, sid)
    if type(line) ~= 'string' then return line end
    local ver, rid, rest = line:match('^(%d+) (%x%x%x%x) (.*)$')
    if ver == nil then return line end
    return ver .. ' ' .. (sid or SID) .. ' ' .. rid .. ' ' .. rest
end

local function runRaw(p, line)
    local ok, err = pcall(xi.module.registered.fpx.onTrigger, p, line)
    H.truthy(ok, 'command handler raised: ' .. tostring(err))
    return split(p)
end

-- Runs one command; the command handler itself must never raise.
local function run(p, line, sid)
    line = withSid(line, sid)
    local ok, err = pcall(xi.module.registered.fpx.onTrigger, p, line)
    H.truthy(ok, 'command handler raised: ' .. tostring(err))
    return split(p)
end

local function one(p, line, sid)
    local r = run(p, line, sid)
    H.eq(#r, 1, 'responses')
    return r[1]
end

-- The final outcome stored in the replay cache for a request id.
local function final(p, rid)
    local e = S.sessions[p.id].replay[S.replayKey(SID, rid)]
    H.truthy(e, 'cached outcome for ' .. rid)
    local frames = {}
    for _, f in ipairs(e.frames) do frames[#frames + 1] = { msg = f } end
    return F.decode(frames)[1]
end

local function always(when) return function() return when end end

local function offersOf(f, cat)
    local t = { default = f['p' .. cat] }
    for id, o in (f['x' .. cat] or ''):gmatch('(%d+)~([%w+]+)') do t[tonumber(id)] = o end
    return function(id) return t[id] or t.default end
end

local function hasText(list, pattern)
    for _, s in ipairs(list) do if s:find(pattern) then return true end end
    return false
end

H.before = function() load() end

-----------------------------------------------------------------------------
H.describe('registration', function()
    H.it('registers !fpx with permission 0 and a whole-line parameter', function()
        local cmd = xi.module.registered.fpx
        H.truthy(cmd, 'command registered')
        H.eq(cmd.cmdprops.permission, 0)
        H.eq(cmd.cmdprops.parameters, 's')
    end)

    H.it('falls back to xi.commands when registerCommand is absent', function()
        L.installGlobals()
        xi.module.registerCommand = nil
        dofile(root .. '/server/modules/custom/late/fpxport.lua')
        H.truthy(xi.commands and xi.commands.fpx, 'xi.commands.fpx')
    end)

    H.it('declares onGameIn override that resets session on login only', function()
        local m = load()
        local fn = m.overrides['xi.player.onGameIn']
        H.truthy(fn, 'override')
        local p = L.player({ hp = { 0 } })
        run(p, '1 0001 SYNC')
        H.truthy(S.sessions[p.id], 'session exists')
        -- LSB's applyOverride injects `super` through setfenv (Lua 5.1/LuaJIT).
        -- A temporary global works on both LuaJIT and Lua 5.4 for this test.
        local superCalls = 0
        _G.super = function() superCalls = superCalls + 1 end
        fn(p, false, true)
        H.truthy(S.sessions[p.id], 'kept on zoning')
        fn(p, false, false)
        _G.super = nil
        H.eq(S.sessions[p.id], nil, 'cleared on login')
        H.eq(superCalls, 2, 'original onGameIn always called')
    end)
end)

-----------------------------------------------------------------------------
H.describe('SYNC', function()
    H.it('returns a complete, checksummed snapshot on SYSTEM_3', function()
        local p = L.player({ hp = { 0, 5, 121 }, sg = { 6, 97 }, ki = { 'HOLLA_GATE_CRYSTAL', 'ALTEPA_GATE_CRYSTAL' }, runic = 2 + 64 })
        local r, _ = run(p, '1 00a1 SYNC')
        H.eq(#r, 1)
        r = r[1]
        H.eq(r.rid, '00a1'); H.eq(r.kind, 'S')
        local f = r.fields
        H.eq(f.v, '1'); H.eq(f.ch, '21828'); H.eq(f.z, '230')
        H.eq(f.g, '100000'); H.eq(f.cp, '5000'); H.eq(f.is, '5000')
        H.eq(f.uH:match('^(%d+):'), '122')
        H.truthy(F.bitSet(f.uH, 0)); H.truthy(F.bitSet(f.uH, 5)); H.truthy(F.bitSet(f.uH, 121)); H.falsy(F.bitSet(f.uH, 1))
        H.truthy(F.bitSet(f.uS, 6)); H.truthy(F.bitSet(f.uS, 97)); H.falsy(F.bitSet(f.uS, 11))
        H.truthy(F.bitSet(f.uG, 0)); H.truthy(F.bitSet(f.uG, 5)); H.falsy(F.bitSet(f.uG, 1))
        H.truthy(F.bitSet(f.uR, 1)); H.truthy(F.bitSet(f.uR, 6)); H.falsy(F.bitSet(f.uR, 2))
        H.eq(f.ok, '1')
    end)

    H.it('frames are sent on SYSTEM_3 (channel 29)', function()
        local p = L.player()
        xi.module.registered.fpx.onTrigger(p, withSid('1 00a2 SYNC'))
        for _, e in ipairs(p:takePrinted()) do H.eq(e.channel, 29, 'channel') end
    end)

    H.it('reports a travel block in ok', function()
        local p = L.player(); p.engaged = true
        H.eq(one(p, '1 0005 SYNC').fields.ok, '0.STATE')
        p.engaged = false; p.instance = {}
        H.eq(one(p, '1 0006 SYNC').fields.ok, '0.ZONE')
    end)

    H.it('body fits protocol limits even with everything unlocked', function()
        local hp = {}
        for i = 0, 121 do hp[#hp + 1] = i end
        local p = L.player({ hp = hp, sg = { 0, 6, 11, 40, 97 }, runic = 126 })
        H.truthy(#one(p, '1 0007 SYNC').body <= 2048, 'body <= 2048')
    end)

    H.it('rate-limits SYNC to 6 per 10 s', function()
        local p = L.player()
        for i = 1, 6 do H.eq(one(p, string.format('1 %04x SYNC', 0x10 + i)).kind, 'S') end
        local r = one(p, '1 0020 SYNC')
        H.eq(r.kind, 'E'); H.eq(r.fields.e, 'BUSY')
        clock = clock + 11
        H.eq(one(p, '1 0021 SYNC').kind, 'S')
    end)
end)

-----------------------------------------------------------------------------
H.describe('final pricing (owner-confirmed)', function()
    H.it('category defaults: 1,000 gil / 100 CP (H, S, G) and 1,000 gil / 100 IS (R)', function()
        local p = L.player({ zone = 100 }) -- West Ronfaure: no city, nothing free
        local f = one(p, '1 0101 SYNC').fields
        H.eq(f.pH, 'g1000+c100'); H.eq(f.pS, 'g1000+c100'); H.eq(f.pG, 'g1000+c100'); H.eq(f.pR, 'g1000+i100')
        H.eq(f.xH, nil, 'no Home Point override outside a city'); H.eq(f.xG, nil); H.eq(f.xR, nil)
    end)

    H.it('the same price applies to every eligible Home Point (no fee multipliers)', function()
        local p = L.player({ zone = 100 })
        local price = offersOf(one(p, '1 0102 SYNC').fields, 'H')
        for _, id in ipairs({ 0, 9, 39, 46, 59, 71, 85, 121 }) do
            H.eq(price(id), 'g1000+c100', 'Home Point ' .. id)
        end
    end)

    H.it('key items no longer change prices (no Rhapsody discount, no Captain free portals)', function()
        local p = L.player({ zone = 100, ki = { 'RHAPSODY_IN_WHITE', 'CAPTAIN_WILDCAT_BADGE' } })
        local f = one(p, '1 0103 SYNC').fields
        H.eq(f.pH, 'g1000+c100'); H.eq(f.pS, 'g1000+c100'); H.eq(f.pR, 'g1000+i100')
    end)

    H.it('each category charges the exact confirmed price in each currency', function()
        local cases = {
            { 'H 9', 'g 1000', 'gil', 1000 }, { 'H 9', 'c 100', 'cp', 100 },
            { 'S 6', 'g 1000', 'gil', 1000 }, { 'S 6', 'c 100', 'cp', 100 },
            { 'G 2', 'g 1000', 'gil', 1000 }, { 'G 2', 'c 100', 'cp', 100 },
            { 'R 3', 'g 1000', 'gil', 1000 }, { 'R 3', 'i 100', 'is', 100 },
        }
        local field = { gil = 'gil', cp = 'cp', is = 'is' }
        for i, c in ipairs(cases) do
            load()
            local p = L.player({ hp = { 9 }, sg = { 6 }, ki = { 'MEA_GATE_CRYSTAL' }, runic = 2 ^ 3 })
            local before = { gil = p.gil, cp = p.cp, is = p.is }
            local r = one(p, string.format('1 %04x GO %s %s', 0x110 + i, c[1], c[2]))
            H.eq(r.kind, 'T', c[1] .. ' ' .. c[2])
            for k in pairs(field) do
                local expect = before[k] - ((k == c[3]) and c[4] or 0)
                H.eq(p[k], expect, c[1] .. ' ' .. c[2] .. ' ' .. k)
            end
            H.truthy(p.moved, 'moved')
        end
    end)

    H.it('wrong payment method for a category is refused without charge', function()
        local cases = { { 'H 9', 'i 100' }, { 'S 6', 'i 100' }, { 'G 2', 'i 100' }, { 'R 3', 'c 100' } }
        for i, c in ipairs(cases) do
            load()
            local p = L.player({ hp = { 9 }, sg = { 6 }, ki = { 'MEA_GATE_CRYSTAL' }, runic = 2 ^ 3 })
            local r = one(p, string.format('1 %04x GO %s %s', 0x120 + i, c[1], c[2]))
            H.eq(r.fields.e, 'PAYMENT', c[1]); H.eq(p.gil, 100000); H.eq(p.cp, 5000); H.eq(p.is, 5000); H.eq(p.moved, nil)
        end
    end)

    H.it('expected-price mismatch is refused with the current offer', function()
        local p = L.player({ hp = { 9 } })
        local r = one(p, '1 0131 GO H 9 g 500')
        H.eq(r.fields.e, 'PRICE'); H.eq(r.fields.need, 'g1000+c100'); H.eq(p.gil, 100000)
    end)
end)

-----------------------------------------------------------------------------
H.describe('same-city free travel', function()
    H.it('city table: four nation cities, Chateau and Heavens Tower included, Al Zahbi not', function()
        H.eq(S.cityOf(230), 1); H.eq(S.cityOf(233), 1, "Chateau d'Oraguille")
        H.eq(S.cityOf(242), 3, 'Heavens Tower'); H.eq(S.cityOf(237), 2); H.eq(S.cityOf(246), 4)
        H.eq(S.cityOf(48), nil, 'Al Zahbi: LSB Home Point group 0'); H.eq(S.cityOf(250), nil, 'Kazham')
        H.eq(S.cityOf(100), nil, 'West Ronfaure')
    end)

    H.it('snapshot offers f0 for same-city destinations and the fixed price elsewhere', function()
        local p = L.player({ zone = 230 })
        local f = one(p, '1 0201 SYNC').fields
        local hp, sg = offersOf(f, 'H'), offersOf(f, 'S')
        H.eq(hp(0), 'f0'); H.eq(hp(5), 'f0'); H.eq(hp(97), 'f0'); H.eq(hp(98), 'f0')
        H.eq(hp(9), 'g1000+c100', 'other city'); H.eq(hp(17), 'g1000+c100', 'other city')
        H.eq(hp(39), 'g1000+c100', 'town outside any city group')
        H.eq(hp(59), 'g1000+c100', 'outside destination')
        H.eq(sg(0), 'f0', 'Survival Guide in the same city'); H.eq(sg(6), 'g1000+c100', 'outside')
        H.eq(f.pG, 'g1000+c100'); H.eq(f.pR, 'g1000+i100')
    end)

    H.it('free trip charges nothing and needs no funds', function()
        local p = L.player({ hp = { 5 }, zone = 230, gil = 0, cp = 0, is = 0 })
        local r = one(p, '1 0202 GO H 5 f 0')
        H.eq(r.kind, 'T'); H.eq(r.fields.pay, 'f0')
        H.eq(p.gil, 0); H.eq(p.cp, 0); H.eq(p.is, 0); H.eq(p.moved[5], 231)
        H.eq(p.calls.delGil, nil); H.eq(p.calls.delCP, nil); H.eq(p.calls.delCurrency, nil)
    end)

    H.it('a city zone without a Home Point qualifies as origin (Chateau, Heavens Tower)', function()
        local p = L.player({ hp = { 0 }, zone = 233 })
        H.eq(one(p, '1 0203 GO H 0 f 0').fields.pay, 'f0'); H.eq(p.gil, 100000)
        load()
        local q = L.player({ hp = { 17 }, zone = 242 })
        H.eq(one(q, '1 0204 GO H 17 f 0').fields.pay, 'f0'); H.eq(q.gil, 100000)
    end)

    H.it('free Survival Guide inside the city', function()
        local p = L.player({ sg = { 0 }, zone = 230 })
        H.eq(one(p, '1 0205 GO S 0 f 0').fields.pay, 'f0'); H.eq(p.moved[5], 231); H.eq(p.gil, 100000)
    end)

    H.it('travel between different cities and from a city to outside stays paid', function()
        local p = L.player({ hp = { 9, 39 }, zone = 230 })
        H.eq(one(p, '1 0206 GO H 9 f 0').fields.e, 'PRICE', 'different city cannot be free')
        H.eq(p.gil, 100000)
        H.eq(one(p, '1 0207 GO H 39 g 1000').kind, 'T'); H.eq(p.gil, 99000)
        load()
        local q = L.player({ hp = { 65 }, zone = 48 }) -- Al Zahbi -> Whitegate
        H.eq(one(q, '1 0208 GO H 65 g 1000').kind, 'T'); H.eq(q.gil, 99000)
        load()
        local w = L.player({ hp = { 0 }, zone = 242 }) -- Heavens Tower -> San d'Oria
        H.eq(one(w, '1 0209 GO H 0 f 0').fields.e, 'PRICE')
    end)

    H.it('paying for a free trip is refused (PRICE), nothing charged', function()
        local p = L.player({ hp = { 5 }, zone = 230 })
        local r = one(p, '1 020a GO H 5 g 1000')
        H.eq(r.fields.e, 'PRICE'); H.eq(r.fields.need, 'f0'); H.eq(p.gil, 100000); H.eq(p.moved, nil)
    end)

    H.it('unlock and state checks still apply to free trips', function()
        local p = L.player({ zone = 230 })
        H.eq(one(p, '1 020b GO H 5 f 0').fields.e, 'LOCKED')
        local q = L.player({ hp = { 5 }, zone = 230 }); q.dead = true
        H.eq(one(q, '1 020c GO H 5 f 0').fields.e, 'STATE')
    end)
end)

-----------------------------------------------------------------------------
H.describe('request validation', function()
    H.it('version mismatch answers E VERSION with sv=1', function()
        local r = one(L.player(), '2 0abc SYNC')
        H.eq(r.rid, '0abc'); H.eq(r.fields.e, 'VERSION'); H.eq(r.fields.sv, '1')
    end)

    H.it('unparseable RID answers with rid 0000 BADREQ', function()
        local r = one(L.player(), '1 XYZ SYNC')
        H.eq(r.rid, '0000'); H.eq(r.fields.e, 'BADREQ')
    end)

    H.it('rejects malformed GO arguments', function()
        local bad = { '1 0001 GO', '1 0001 GO H x g 500', '1 0001 GO Q 1 g 500', '1 0001 GO H 1 z 500',
                      '1 0001 GO H 1 f 5', '1 0001 GO H 1 g -5', '1 0001 FLY', '1 0001 SYNC extra',
                      '1 0001 GO H 1 g 500 1 2', string.rep('a', 97), '1 0001 GO H 1 g 1234567890' }
        for i, line in ipairs(bad) do
            local p = L.player()
            local r = run(p, line)
            H.eq(#r, 1, 'case ' .. i)
            H.eq(r[1].fields.e, 'BADREQ', 'case ' .. i .. ' ' .. line)
            H.eq(p.gil, 100000)
        end
    end)

    H.it('rejects control characters and a nil line', function()
        H.eq(one(L.player(), '1 0001 SY\1NC').fields.e, 'BADREQ')
        H.eq(one(L.player(), nil).fields.e, 'BADREQ')
    end)
end)

-----------------------------------------------------------------------------
H.describe('refusals never cost currency', function()
    local function refused(p, line, code)
        local before = { p.gil, p.cp, p.is }
        local r = one(p, line)
        H.eq(r.kind, 'E', line); H.eq(r.fields.e, code, line)
        H.eq(p.gil, before[1]); H.eq(p.cp, before[2]); H.eq(p.is, before[3])
        H.eq(p.moved, nil, 'not moved')
        return r
    end

    H.it('unknown destination', function()
        refused(L.player(), '1 0301 GO H 67 g 1000', 'BADDEST')
        refused(L.player(), '1 0302 GO H 999 g 1000', 'BADDEST')
        refused(L.player(), '1 0303 GO S 7 g 1000', 'BADDEST')
        refused(L.player(), '1 0304 GO G 6 g 1000', 'BADDEST')
        refused(L.player(), '1 0305 GO R 0 i 100', 'BADDEST')
    end)

    H.it('locked destination', function()
        refused(L.player(), '1 0311 GO H 9 g 1000', 'LOCKED')
        refused(L.player(), '1 0312 GO S 6 g 1000', 'LOCKED')
        refused(L.player(), '1 0313 GO G 0 g 1000', 'LOCKED')
        refused(L.player(), '1 0314 GO R 1 i 100', 'LOCKED')
    end)

    H.it('insufficient funds for every currency', function()
        local r = refused(L.player({ hp = { 9 }, gil = 999 }), '1 0321 GO H 9 g 1000', 'FUNDS')
        H.eq(r.fields.need, 'g1000+c100'); H.eq(r.fields.g, '999')
        refused(L.player({ sg = { 6 }, cp = 99 }), '1 0322 GO S 6 c 100', 'FUNDS')
        refused(L.player({ ki = { 'DEM_GATE_CRYSTAL' }, cp = 0 }), '1 0323 GO G 1 c 100', 'FUNDS')
        refused(L.player({ runic = 2, is = 99 }), '1 0324 GO R 1 i 100', 'FUNDS')
    end)

    H.it('character state and zone restrictions', function()
        local cases = {
            { function(p) p.dead = true end, 'STATE' },
            { function(p) p.event = true end, 'STATE' },
            { function(p) p.engaged = true end, 'STATE' },
            { function(p) p.enmity = true end, 'STATE' },
            { function(p) p.anim = 5 end, 'STATE' },
            { function(p) p.localVars.ZoningIn = 1 end, 'STATE' },
            { function(p) p.instance = {} end, 'ZONE' },
            { function(p) p.effects[254] = true end, 'ZONE' },
            { function(p) p.zone = 131 end, 'ZONE' },
        }
        for i, c in ipairs(cases) do
            local p = L.player({ hp = { 9 } })
            c[1](p)
            refused(p, string.format('1 %04x GO H 9 g 1000', 0x330 + i), c[2])
        end
    end)

    H.it('already at destination', function()
        refused(L.player({ hp = { 9 }, zone = 234, pos = { 39, 0, -43 } }), '1 0341 GO H 9 f 0', 'HERE')
    end)

    H.it('cooldown after accepted travel', function()
        local p = L.player({ hp = { 9, 14 }, zone = 100 })
        H.eq(one(p, '1 0351 GO H 9 g 1000').kind, 'T')
        p.zone = 100
        local before = p.gil
        H.eq(one(p, '1 0352 GO H 14 g 1000').fields.e, 'BUSY'); H.eq(p.gil, before)
        clock = clock + 5
        H.eq(one(p, '1 0353 GO H 14 g 1000').kind, 'T')
    end)
end)

-----------------------------------------------------------------------------
H.describe('duplicates and replay', function()
    H.it('repeated successful GO replays T without charging or moving again', function()
        local p = L.player({ hp = { 9 } })
        local a = one(p, '1 0401 GO H 9 g 1000')
        p.zone = 230; p.moved = nil
        local b = one(p, '1 0401 GO H 9 g 1000')
        H.eq(a.body, b.body); H.eq(p.gil, 99000); H.eq(p.moved, nil)
    end)

    H.it('repeated SYNC with the same RID replays the identical snapshot', function()
        local p = L.player({ hp = { 1 } })
        local a = one(p, '1 0402 SYNC')
        p.gil = 1
        H.eq(one(p, '1 0402 SYNC').body, a.body)
    end)

    H.it('replay entries expire after 30 s and the cache is bounded to 8 RIDs', function()
        local p = L.player({ hp = { 1 } })
        one(p, '1 0403 SYNC')
        p.gil = 7
        clock = clock + 31
        H.eq(one(p, '1 0403 SYNC').fields.g, '7')
        for i = 1, 10 do clock = clock + 2; one(p, string.format('1 %04x SYNC', 0x500 + i)) end
        local n = 0
        for _ in pairs(S.sessions[p.id].replay) do n = n + 1 end
        H.eq(n, 8)
    end)

    H.it('separate characters have separate sessions', function()
        local a, b = L.player({ id = 1, hp = { 9 } }), L.player({ id = 2, hp = { 9 } })
        H.eq(one(a, '1 0601 GO H 9 g 1000').kind, 'T')
        H.eq(one(b, '1 0601 GO H 9 g 1000').kind, 'T')
        H.eq(b.gil, 99000)
    end)
end)

-----------------------------------------------------------------------------
-- RC4: client session id (rapid addon reloads reuse request ids)
-----------------------------------------------------------------------------
H.describe('client session id and replay scope', function()
    local OTHER = '0f0e0d0c0b0a' -- the session after a reload

    H.it('requests without a valid session id are refused', function()
        local p = L.player({ hp = { 9 } })
        H.eq(runRaw(p, '1 0a01 SYNC')[1].fields.e, 'BADREQ', 'RC3 shape without sid')
        H.eq(runRaw(p, '1 A1B2C3D4E5F6 0a02 SYNC')[1].fields.e, 'BADREQ', 'uppercase sid')
        H.eq(runRaw(p, '1 a1b2c3d4e5 0a03 SYNC')[1].fields.e, 'BADREQ', 'short sid')
        local r = runRaw(p, '1 a1b2c3d4e5f6 0a04 GO H 9 g')
        H.eq(r[1].fields.e, 'BADREQ'); H.eq(r[1].rid, '0a04'); H.eq(p.gil, 100000)
    end)

    H.it('SYNC: same request id from a reloaded session gets a fresh snapshot', function()
        local p = L.player({ hp = { 9 } })
        H.eq(one(p, '1 0b01 SYNC').fields.g, '100000')
        p.gil = 54321 -- balance changed between the two loads
        H.eq(one(p, '1 0b01 SYNC', OTHER).fields.g, '54321', 'new session is not answered from the old entry')
        H.eq(one(p, '1 0b01 SYNC').fields.g, '100000', 'the old session still replays its own entry')
    end)

    H.it('GO: same request id from a reloaded session is executed as a new trip, not replayed', function()
        local p = L.player({ hp = { 9, 14 } })
        local a = one(p, '1 0b02 GO H 9 g 1000')
        H.eq(a.kind, 'T'); H.eq(p.gil, 99000); H.eq(p.moved[5], 234)
        p.zone, p.moved = 230, nil
        -- reload within the cooldown: refused as BUSY by the per-character cooldown,
        -- not answered with the earlier session's T
        local b = one(p, '1 0b02 GO H 14 g 1000', OTHER)
        H.eq(b.fields.e, 'BUSY'); H.eq(p.gil, 99000); H.eq(p.moved, nil)
        clock = clock + 6 -- still inside the 30 s replay window
        local c = one(p, '1 0b03 GO H 14 g 1000', OTHER)
        H.eq(c.kind, 'T'); H.eq(c.fields.d, '14'); H.eq(p.gil, 98000); H.eq(p.moved[5], 236)
    end)

    H.it('GO: colliding request id, new session, different destination after the cooldown', function()
        local p = L.player({ hp = { 9, 14 }, gil = 5000 })
        H.eq(one(p, '1 0b04 GO H 9 g 1000').kind, 'T'); H.eq(p.gil, 4000)
        p.zone, p.moved = 230, nil
        clock = clock + 6
        p.gil = 3500 -- balance changed meanwhile
        local r = one(p, '1 0b04 GO H 14 g 1000', OTHER)
        H.eq(r.kind, 'T'); H.eq(r.fields.d, '14', 'answer belongs to the new request'); H.eq(r.fields.g, '2500')
        H.eq(p.gil, 2500); H.eq(p.moved[5], 236)
    end)

    H.it('intentional replay (same session, same id) still never charges twice', function()
        local p = L.player({ hp = { 9 } })
        local a = one(p, '1 0b05 GO H 9 g 1000')
        p.zone, p.moved = 230, nil
        clock = clock + 6
        local b = one(p, '1 0b05 GO H 9 g 1000')
        H.eq(b.body, a.body); H.eq(p.gil, 99000); H.eq(p.moved, nil)
    end)

    H.it('rate limit and cooldown are shared by all sessions of a character', function()
        local p = L.player()
        for i = 1, 6 do one(p, string.format('1 %04x SYNC', 0x0c00 + i), i % 2 == 0 and OTHER or nil) end
        H.eq(one(p, '1 0c10 SYNC', '123456789abc').fields.e, 'BUSY')
    end)
end)
-----------------------------------------------------------------------------
H.describe('transaction outcomes', function()
    H.it('normal paid trip: one final T, charged once, moved', function()
        local p = L.player({ hp = { 9 } })
        local r, notices = run(p, '1 0701 GO H 9 g 1000')
        H.eq(#r, 1); H.eq(r[1].kind, 'T'); H.eq(r[1].fields.pay, 'g1000'); H.eq(r[1].fields.g, '99000')
        H.eq(p.gil, 99000); H.eq(p.moved[5], 234); H.eq(#notices, 0); H.eq(#S.incidents, 0)
        H.eq(final(p, '0701').kind, 'T')
    end)

    H.it('normal free trip: one final T with pay=f0', function()
        local p = L.player({ hp = { 5 } })
        local r = run(p, '1 0702 GO H 5 f 0')
        H.eq(#r, 1); H.eq(r[1].fields.pay, 'f0'); H.eq(final(p, '0702').kind, 'T')
    end)

    H.it('failure before deduction (validation raises): INTERNAL, no debit attempted', function()
        local p = L.player({ hp = { 9 } })
        p.faults.isDead = always('before')
        local r = run(p, '1 0703 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(p.moved, nil); H.eq(p.calls.delGil, nil)
    end)

    H.it('currency API raises before taking currency: INTERNAL, nothing charged', function()
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = always('before')
        local r, notices = run(p, '1 0704 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(p.moved, nil); H.eq(#S.incidents, 0)
        H.truthy(hasText(notices, 'nothing was charged'))
    end)

    H.it('currency API raises after taking currency: refund confirmed, INTERNAL', function()
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = always('after')
        local r, notices = run(p, '1 0705 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(p.moved, nil); H.eq(#S.incidents, 0)
        H.truthy(hasText(notices, 'refunded'))
    end)

    H.it('currency API raises after taking currency and the refund fails: UNSURE + incident, no "refunded" notice', function()
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = always('after')
        p.faults.addGil = always('before')
        local r, notices = run(p, '1 0706 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'UNSURE'); H.eq(p.moved, nil); H.eq(p.gil, 99000)
        H.eq(#S.incidents, 1); H.eq(S.incidents[1].stage, 'debit'); H.eq(S.incidents[1].observed, 99000)
        H.falsy(hasText(notices, 'refunded')); H.truthy(hasText(notices, 'could not be confirmed'))
    end)

    H.it('currency API raises and the balance is unreadable: UNSURE + incident with context, no guessed refund', function()
        local logs = {}
        S.log = function(t) logs[#logs + 1] = t end
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = function(self) self.debited = true; return 'after' end
        p.faults.getGil = function(self) if self.debited then return 'before' end end
        local r = run(p, '1 0707 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'UNSURE'); H.eq(p.moved, nil); H.eq(p.gil, 99000, 'no guessed refund')
        local inc = S.incidents[1]
        H.eq(inc.char, p.id); H.eq(inc.rid, '0707'); H.eq(inc.cat, 'H'); H.eq(inc.dest, 9); H.eq(inc.zone, 234)
        H.eq(inc.cur, 'g'); H.eq(inc.price, 1000); H.eq(inc.before, 100000); H.truthy(inc.err)
        H.truthy(hasText(logs, 'CURRENCY INCIDENT char=21828 rid=0707 sid=a1b2c3d4e5f6 stage=debit'))
        H.eq(inc.sid, SID)
    end)

    H.it('reading post-charge balances fails: trip completes, charged once, derived balance in T', function()
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = function(self) self.debited = true end
        p.faults.getGil = function(self) if self.debited then return 'before' end end
        local r = run(p, '1 0708 GO H 9 g 1000')
        H.eq(#r, 1); H.eq(r[1].kind, 'T'); H.eq(r[1].fields.g, '99000')
        H.eq(p.gil, 99000); H.eq(p.moved[5], 234)
    end)

    H.it('sending the accepted response fails: trip completes, replay does not recharge', function()
        local p = L.player({ hp = { 9 } })
        p.faults.printToPlayer = always('before')
        run(p, '1 0709 GO H 9 g 1000')
        H.eq(p.gil, 99000); H.eq(p.moved[5], 234); H.eq(#S.incidents, 0)
        p.faults.printToPlayer = nil
        p.zone, p.moved = 230, nil
        local r = run(p, '1 0709 GO H 9 g 1000')
        H.eq(r[1].kind, 'T'); H.eq(p.gil, 99000); H.eq(p.moved, nil)
    end)

    H.it('setPos fails before moving: T, then correction E INTERNAL for the same rid, refund confirmed', function()
        local p = L.player({ hp = { 9, 14 } })
        p.faults.setPos = always('before')
        local r, notices = run(p, '1 070a GO H 9 g 1000')
        H.eq(#r, 2); H.eq(r[1].kind, 'T'); H.eq(r[2].kind, 'E'); H.eq(r[2].fields.e, 'INTERNAL')
        H.eq(r[1].rid, '070a'); H.eq(r[2].rid, '070a')
        H.eq(p.gil, 100000); H.eq(#S.incidents, 0)
        H.truthy(hasText(notices, 'your payment was refunded'))
        H.eq(final(p, '070a').fields.e, 'INTERNAL', 'cache holds the final outcome')
        p.faults.setPos = nil
        H.eq(one(p, '1 070b GO H 14 g 1000').kind, 'T', 'no cooldown after a confirmed refund')
    end)

    H.it('setPos raises after the move took effect: T stands, charged once, no refund', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = always('after')
        local r = run(p, '1 070c GO H 9 g 1000')
        H.eq(#r, 1); H.eq(r[1].kind, 'T'); H.eq(p.gil, 99000); H.eq(p.moved[5], 234); H.eq(#S.incidents, 0)
    end)

    H.it('setPos raises while zoning to the destination has started: T stands', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = function(self) self.zoningTo = 234; return 'before' end
        local r = run(p, '1 070d GO H 9 g 1000')
        H.eq(#r, 1); H.eq(r[1].kind, 'T'); H.eq(p.gil, 99000); H.eq(#S.incidents, 0)
    end)

    H.it('setPos raises and the move state is unreadable: T then E UNSURE, incident, no refund', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = function(self) self.broken = true; return 'before' end
        p.faults.getZone = function(self) if self.broken then return 'before' end end
        local r, notices = run(p, '1 070e GO H 9 g 1000')
        H.eq(r[#r].fields.e, 'UNSURE'); H.eq(p.gil, 99000)
        H.eq(#S.incidents, 1); H.eq(S.incidents[1].stage, 'move')
        H.falsy(hasText(notices, 'refunded')); H.eq(final(p, '070e').fields.e, 'UNSURE')
    end)

    H.it('setPos fails and the refund raises: E UNSURE, incident, never "payment refunded"', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = always('before')
        p.faults.addGil = always('before')
        local r, notices = run(p, '1 070f GO H 9 g 1000')
        H.eq(r[#r].fields.e, 'UNSURE'); H.eq(p.gil, 99000); H.eq(p.moved, nil)
        H.eq(#S.incidents, 1); H.eq(S.incidents[1].stage, 'refund'); H.eq(S.incidents[1].observed, 99000)
        H.falsy(hasText(notices, 'refunded')); H.truthy(hasText(notices, 'could not be confirmed'))
    end)

    H.it('setPos fails and the refund cannot be verified (balance unreadable): E UNSURE', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = always('before')
        p.faults.addGil = function(self) self.refunding = true end
        p.faults.getGil = function(self) if self.refunding then return 'before' end end
        local r, notices = run(p, '1 0710 GO H 9 g 1000')
        H.eq(r[#r].fields.e, 'UNSURE'); H.eq(#S.incidents, 1)
        H.falsy(hasText(notices, 'refunded'))
    end)

    H.it('refund call raises after crediting: the balance proves it, E INTERNAL', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = always('before')
        p.faults.addGil = always('after')
        local r = run(p, '1 0711 GO H 9 g 1000')
        H.eq(r[#r].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(#S.incidents, 0)
    end)

    H.it('free trip whose setPos fails: E INTERNAL, nothing charged, no incident', function()
        local p = L.player({ hp = { 5 } })
        p.faults.setPos = always('before')
        local r, notices = run(p, '1 0712 GO H 5 f 0')
        H.eq(r[#r].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(#S.incidents, 0)
        H.truthy(hasText(notices, 'nothing was charged'))
    end)

    H.it('replay of a corrected request returns only the final E, never re-executes', function()
        local p = L.player({ hp = { 9 } })
        p.faults.setPos = always('before')
        run(p, '1 0713 GO H 9 g 1000')
        p.faults.setPos = nil
        local r = run(p, '1 0713 GO H 9 g 1000')
        H.eq(#r, 1); H.eq(r[1].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(p.moved, nil)
    end)

    H.it('replay of a failed pre-charge request never executes it later', function()
        local p = L.player({ hp = { 9 } })
        p.faults.delGil = always('before')
        run(p, '1 0714 GO H 9 g 1000')
        p.faults.delGil = nil
        local r = run(p, '1 0714 GO H 9 g 1000')
        H.eq(r[1].fields.e, 'INTERNAL'); H.eq(p.gil, 100000); H.eq(p.moved, nil)
    end)

    H.it('CP and Imperial Standing debits and refunds follow the same rules', function()
        local p = L.player({ sg = { 6 } })
        p.faults.delCP = always('after')
        H.eq(run(p, '1 0715 GO S 6 c 100')[1].fields.e, 'INTERNAL'); H.eq(p.cp, 5000)
        load()
        local q = L.player({ runic = 2 })
        q.faults.setPos = always('before')
        local r = run(q, '1 0716 GO R 1 i 100')
        H.eq(r[#r].fields.e, 'INTERNAL'); H.eq(q.is, 5000)
        load()
        local w = L.player({ runic = 2 })
        w.faults.setPos = always('before')
        w.faults.addCurrency = always('before')
        local r2 = run(w, '1 0717 GO R 1 i 100')
        H.eq(r2[#r2].fields.e, 'UNSURE'); H.eq(#S.incidents, 1); H.eq(S.incidents[1].cur, 'i')
    end)

    H.it('fault matrix: consistent final outcome, no unpaid travel, no unreported loss', function()
        local methods = { 'getGil', 'delGil', 'addGil', 'getCP', 'getCurrency', 'printToPlayer', 'setPos', 'getZone',
                          'getID', 'getZoneID', 'checkDistance', 'hasTeleport', 'hasKeyItem', 'isEngaged' }
        local n = 0
        for _, m in ipairs(methods) do
            for _, when in ipairs({ 'before', 'after' }) do
                load()
                n = n + 1
                local rid = string.format('%04x', 0x900 + n)
                local p = L.player({ hp = { 9 } })
                p.faults[m] = always(when)
                run(p, '1 ' .. rid .. ' GO H 9 g 1000')
                local charged = 100000 - p.gil
                local label = m .. '/' .. when
                local sess = S.sessions[p.id]
                local fin = sess and sess.replay[S.replayKey(SID, rid)] and final(p, rid) or nil
                H.truthy(charged >= 0, label .. ': never credits extra')
                if p.moved then
                    H.eq(charged, 1000, label .. ': moved must cost exactly the price')
                    H.eq(fin and fin.kind, 'T', label .. ': final outcome of a move is T')
                elseif charged > 0 then
                    H.truthy(#S.incidents > 0, label .. ': unmoved charge must be reported')
                    if fin then H.eq(fin.fields.e, 'UNSURE', label .. ': final outcome is UNSURE') end
                elseif fin then
                    H.eq(fin.kind, 'E', label .. ': no move means a final E')
                    H.truthy(fin.fields.e ~= 'UNSURE' or #S.incidents > 0, label)
                end
            end
        end
    end)
end)

-----------------------------------------------------------------------------
-- 1.2.0: server-configurable prices (M.config.prices, validated by applyConfig)
-----------------------------------------------------------------------------
H.describe('configurable prices', function()
    local logs
    local function configure(prices, sameCityFree)
        logs = {}
        S.log = function(t) logs[#logs + 1] = t end
        for cat, list in pairs(prices or {}) do S.config.prices[cat] = list end
        if sameCityFree ~= nil then S.config.sameCityFree = sameCityFree end
        return S.applyConfig()
    end

    H.it('the shipped configuration is valid and equals the owner-approved defaults', function()
        H.eq(configure(), 0)
        for _, cat in ipairs({ 'H', 'S', 'G', 'R' }) do
            H.eq(S.encodeOffers(S.active.prices[cat]), S.encodeOffers(S.DEFAULT_PRICES[cat]), cat)
        end
        H.eq(S.active.sameCityFree, true)
    end)

    H.it('custom prices are synchronised and charged', function()
        H.eq(configure({ H = { { cur = 'g', amount = 2500 }, { cur = 'c', amount = 250 } } }), 0)
        local p = L.player({ hp = { 9 }, zone = 100 })
        H.eq(one(p, '1 0e01 SYNC').fields.pH, 'g2500+c250')
        H.eq(one(p, '1 0e02 GO H 9 c 250').kind, 'T'); H.eq(p.cp, 4750); H.eq(p.gil, 100000)
    end)

    H.it('a client with the old price is refused (PRICE) and nothing is charged', function()
        configure({ H = { { cur = 'g', amount = 2500 }, { cur = 'c', amount = 250 } } })
        local p = L.player({ hp = { 9 } })
        local r = one(p, '1 0e03 GO H 9 g 1000')
        H.eq(r.fields.e, 'PRICE'); H.eq(r.fields.need, 'g2500+c250'); H.eq(p.gil, 100000)
    end)

    H.it('a currency can be removed from a category', function()
        configure({ R = { { cur = 'g', amount = 500 } } })
        local p = L.player({ runic = 2 })
        H.eq(one(p, '1 0e04 SYNC').fields.pR, 'g500')
        H.eq(one(p, '1 0e05 GO R 1 i 100').fields.e, 'PAYMENT'); H.eq(p.is, 5000)
        H.eq(one(p, '1 0e06 GO R 1 g 500').kind, 'T'); H.eq(p.gil, 99500)
    end)

    H.it('all amounts 0 makes a category free; no funds needed, nothing charged', function()
        configure({ G = { { cur = 'g', amount = 0 }, { cur = 'c', amount = 0 } } })
        local p = L.player({ ki = { 'MEA_GATE_CRYSTAL' }, gil = 0, cp = 0 })
        H.eq(one(p, '1 0e07 SYNC').fields.pG, 'f0')
        H.eq(one(p, '1 0e08 GO G 2 f 0').fields.pay, 'f0'); H.eq(p.calls.delGil, nil); H.eq(p.calls.delCP, nil)
        H.eq(one(L.player({ id = 777, ki = { 'MEA_GATE_CRYSTAL' } }), '1 0e09 GO G 2 g 1000').fields.e, 'PRICE')
    end)

    H.it('same-city free travel can be switched off by the server', function()
        configure(nil, false)
        local p = L.player({ hp = { 5 }, zone = 230 })
        H.eq(offersOf(one(p, '1 0e0a SYNC').fields, 'H')(5), 'g1000+c100')
        H.eq(one(p, '1 0e0b GO H 5 f 0').fields.e, 'PRICE'); H.eq(p.gil, 100000)
        H.eq(one(p, '1 0e0c GO H 5 g 1000').kind, 'T'); H.eq(p.gil, 99000)
    end)

    H.it('invalid entries are rejected, logged, and fall back to that category default', function()
        local bad = {
            { H = { { cur = 'g', amount = -1 } } },
            { H = { { cur = 'g', amount = 10.5 } } },
            { H = { { cur = 'g', amount = 1000000000 } } },
            { H = { { cur = 'g', amount = 0 / 0 } } },
            { H = { { cur = 'g', amount = '1000' } } },
            { H = { { cur = 'i', amount = 100 } } },          -- IS not allowed for Home Points
            { R = { { cur = 'c', amount = 100 } } },          -- CP not allowed for Runic Portals
            { H = { { cur = 'g', amount = 1 }, { cur = 'g', amount = 2 } } },
            { H = { } },
            { H = 'free' },
            { H = { { cur = 'g', amount = 0 }, { cur = 'c', amount = 100 } } }, -- mixed free and paid
            { H = { 1000 } },
        }
        for i, b in ipairs(bad) do
            load()
            local errors = configure(b)
            H.eq(errors, 1, 'case ' .. i)
            H.truthy(logs[1] and logs[1]:find('CONFIG ERROR prices.', 1, true), 'logged, case ' .. i)
            local cat = next(b)
            H.eq(S.encodeOffers(S.active.prices[cat]), S.encodeOffers(S.DEFAULT_PRICES[cat]), 'default kept, case ' .. i)
        end
    end)

    H.it('one invalid category does not affect the valid ones', function()
        local errors = configure({ H = { { cur = 'g', amount = -5 } }, S = { { cur = 'g', amount = 3000 } } })
        H.eq(errors, 1)
        H.eq(S.encodeOffers(S.active.prices.H), 'g1000+c100')
        H.eq(S.encodeOffers(S.active.prices.S), 'g3000')
    end)

    H.it('invalid sameCityFree is rejected and stays true', function()
        local errors = configure(nil, 'yes')
        H.eq(errors, 1); H.eq(S.active.sameCityFree, true)
        H.truthy(logs[1]:find('sameCityFree', 1, true))
    end)

    H.it('the shipped file validates without errors at load', function()
        load()
        H.eq(S.applyConfig(), 0)
    end)
end)

-----------------------------------------------------------------------------
H.describe('framing', function()
    H.it('splits long bodies into <=128 byte chunks with header (fits LSB Mes[150])', function()
        local frames = S.frame('abcd', 'S', string.rep('x', 400))
        H.eq(#frames, 5)
        H.eq(frames[1], '#fpx1 abcd 0/4 S,400,' .. S.hex8(S.adler32(string.rep('x', 400))))
        H.truthy(frames[2]:match('^#fpx1 abcd 1/4 ' .. string.rep('x', 128) .. '$'))
        for _, f in ipairs(frames) do H.truthy(#f <= 150) end
    end)

    H.it('a maximum-size body (2048) needs exactly 16 frames of at most 150 bytes', function()
        local frames = S.frame('abcd', 'S', string.rep('y', 2048))
        H.eq(#frames, 17)
        for _, f in ipairs(frames) do H.truthy(#f <= 150, 'frame length ' .. #f) end
    end)

    H.it('every frame of a fully unlocked snapshot fits the 150-byte chat field', function()
        local hp = {}
        for i = 0, 121 do hp[#hp + 1] = i end
        local p = L.player({ hp = hp, sg = { 0, 6, 11, 40, 97 }, runic = 126, ki = { 'HOLLA_GATE_CRYSTAL' } })
        xi.module.registered.fpx.onTrigger(p, withSid('1 0d01 SYNC'))
        for _, e in ipairs(p:takePrinted()) do H.truthy(#e.msg <= 150, 'frame length ' .. #e.msg) end
    end)

    H.it('adler32 matches the published reference value', function()
        H.eq(S.hex8(S.adler32('Wikipedia')), '11e60398')
    end)

    H.it('bitmap encoding', function()
        H.eq(S.encodeBitmap({ [0] = true, [5] = true }, 7), '7:12')
        H.eq(S.encodeBitmap({}, 6), '6:00')
    end)
end)

local ok = H.report('server')
os.exit(ok and 0 or 1)
