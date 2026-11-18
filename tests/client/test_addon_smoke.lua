-- Smoke test of the addon entry point (client/FFXIPort/FFXIPort.lua) with
-- Ashita stubs: loads the addon, drives its registered events (load,
-- packet_in, d3d_present, command, text_in) against the real server module,
-- and checks the user-visible output. ImGui rendering is stubbed (no UI check).
-- GPL-3.0-only, (C) 2026 wildthing.
local root = arg and arg[1] or '.'
package.path = root .. '/tests/lib/?.lua;' .. package.path

local H = require('harness')
local L = require('lsb_mock')
local A = require('ashita_mock')
local K = require('packets')

L.installGlobals()
dofile(root .. '/server/modules/custom/late/fpxport.lua')
local SRV, CMD = xi.fpxport, xi.module.registered.fpx
SRV.log = function () end

A.install(root)

-- Ashita / addon environment ---------------------------------------------------
local handlers, printed, queued = {}, {}, {}
local realPrint = print
_G.addon = {}
_G.ashita.events = { register = function (ev, name, fn) handlers[ev] = handlers[ev] or {}; handlers[ev][name] = fn end }
_G.print = function (s) printed[#printed + 1] = tostring(s) end

local function chain(text) return { append = function (self, more) return { text = (self.text or '') .. more } end, text = text } end
package.loaded['chat'] = {
    header = function (n) return chain('[' .. n .. '] ') end,
    message = function (t) return t end, success = function (t) return t end,
    error = function (t) return t end, warning = function (t) return t end,
}
_G.print = function (s) printed[#printed + 1] = type(s) == 'table' and s.text or tostring(s) end
package.loaded['imgui'] = setmetatable({}, { __index = function () return function () return false end end })

local W = { name = 'Tuna', zone = 230, serverUp = true }
local player = L.player({ hp = { 9 }, sg = { 6 }, zone = 230 })
player.hp[44] = true -- Western Adoulin #1: a server destination outside the catalogue's scope
player.hp[112] = true -- Leafallia #1: also outside scope

_G.AshitaCore = {
    GetResourceManager = function () return { GetString = function () return nil end } end,
    GetChatManager = function ()
        return { QueueCommand = function (_, mode, line)
            queued[#queued + 1] = line
            if not W.serverUp then return end
            CMD.onTrigger(player, (assert(line:match('^/say !fpx (.*)$'))))
            W.pending = player:takePrinted()
        end }
    end,
    GetMemoryManager = function ()
        return {
            GetParty = function () return {
                GetMemberServerId = function () return player.id end,
                GetMemberZone = function () return W.zone end,
                GetMemberName = function () return W.name end,
            } end,
            GetPlayer = function () return {
                GetLoginStatus = function () return 2 end,
                GetIsZoning = function () return 0 end,
            } end,
        }
    end,
}

A.settings.switch('Tuna')

local function fire(ev, e)
    for _, fn in pairs(handlers[ev] or {}) do fn(e) end
end

local t = 1000
local function tick(ms)
    local stop = t + ms
    repeat
        t = t + 100
        A.clockMs = t
        SRV.now = function () return math.floor(t / 1000) end
        fire('d3d_present', {})
        if W.pending then
            local p = W.pending
            W.pending = nil
            for _, m in ipairs(p) do
                local e = K.event(m.channel or 29, W.name, m.msg)
                fire('packet_in', e)
                W.lastBlocked = (W.lastBlocked or 0) + (e.blocked and 1 or 0)
                W.lastSeen = (W.lastSeen or 0) + 1
            end
        end
    until t >= stop
end

local function command(text)
    -- Ashita passes e.command as a string with an :args() method (from 'common').
    local args = {}
    for w in text:gmatch('%S+') do args[#args + 1] = w end
    local e = { command = { args = function () return args end }, blocked = false }
    fire('command', e)
    return e.blocked
end

local function output(from)
    return table.concat(printed, '\n', from or 1)
end

-- Load the real addon entry point.
local ok, err = pcall(dofile, root .. '/client/FFXIPort/FFXIPort.lua')
H.it('addon entry point loads with Ashita stubs', function ()
    H.truthy(ok, tostring(err))
    H.eq(addon.name, 'FFXIPort')
    H.truthy(addon.version:match('^1%.1%.0'))
end)

if not ok then
    _G.print = realPrint
    H.report('addon smoke')
    os.exit(1)
end

fire('load', {})

H.describe('addon flow', function ()
    H.it('automatic initial sync over 0x017 packets; frames hidden from chat', function ()
        tick(4000)
        H.truthy(#queued >= 1, 'a request was queued')
        H.truthy(queued[1]:match('^/say !fpx 1 %x+ %x%x%x%x SYNC$'), queued[1])
        H.truthy((W.lastSeen or 0) >= 2, 'frames delivered')
        H.eq(W.lastBlocked, W.lastSeen, 'every frame blocked from the chat log')
    end)

    H.it('/port status explains the counts and reports uncatalogued unlocked destinations', function ()
        local from = #printed + 1
        H.truthy(command('/port status'), 'command blocked from chat')
        local s = output(from)
        H.truthy(s:find('Home Points: 3 unlocked on the server; catalogue lists 104 %(server id range 122%)'), s)
        H.truthy(s:find('Survival Guides: 1 unlocked on the server; catalogue lists 77 %(server id range 98%)'), s)
        H.truthy(s:find('Runic Portals: 0 unlocked on the server; catalogue lists 6 %(server id range 7%)'), s)
        H.truthy(s:find('Home Points unlocked but not in this catalogue %(outside its Original%-ToAU scope%): ids 44,112'), s)
        H.truthy(s:find('foreign: 0', 1, true), 'no foreign frames')
    end)

    H.it('the once-per-session scope notice was shown after the first sync', function ()
        H.truthy(output():find('2 unlocked destination%(s%) are outside this catalogue'), 'scope notice')
    end)

    H.it('/port catalog verifies the regenerated catalogue', function ()
        local from = #printed + 1
        command('/port catalog')
        local s = output(from)
        H.truthy(s:find('Catalog version 7: verify OK.', 1, true), s)
        H.truthy(s:find('hp 104', 1, true) and s:find('sg 77', 1, true) and s:find('sp 6', 1, true) and s:find('rp 6', 1, true), s)
    end)

    H.it('/port sync after a gil change shows the new balance in the model', function ()
        player.gil = 54321
        command('/port sync')
        tick(1500)
        local from = #printed + 1
        command('/port status')
        H.truthy(output(from):find('gil 54321', 1, true), output(from))
    end)

    H.it('other commands still respond', function ()
        for _, c in ipairs({ '/port chat', '/port chat quiet', '/port raw off', '/port catalog find jeuno', '/ffxiport status', '/port nonsense' }) do
            local from = #printed + 1
            H.truthy(command(c), c .. ' blocked')
            H.truthy(#printed >= from, c .. ' printed something')
        end
    end)

    H.it('ordinary chat packets are not blocked', function ()
        local e = K.event(0, 'Bob', 'hello')
        fire('packet_in', e)
        H.falsy(e.blocked)
    end)

    H.it('unload runs cleanly', function ()
        local okU, errU = pcall(fire, 'unload', {})
        H.truthy(okU, tostring(errU))
    end)
end)

_G.print = realPrint
local good = H.report('addon smoke')
os.exit(good and 0 or 1)
