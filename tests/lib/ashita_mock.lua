-- Minimal Ashita v4 environment for loading the FFXIPort client modules
-- outside the game. GPL-3.0-only, (C) 2026 wildthing.
local A = { clockMs = 0 }

function A.install(root)
    package.path = root .. '/client/FFXIPort/?.lua;' .. package.path
    package.loaded['common'] = true
    _G.T = function (t) return t end

    _G.ashita = { time = { clock = function () return { ms = A.clockMs } end } }
    _G.AshitaCore = {
        GetResourceManager = function () return { GetString = function () return nil end } end,
        GetMemoryManager = function ()
            return { GetParty = function () return { GetMemberServerId = function () return A.serverId end } end }
        end,
    }

    -- Ashita settings library mock: per-character files, login switch callbacks.
    local store, current, callbacks = {}, nil, {}
    local settings = { logged_in = false }

    local function deepcopy(t)
        if type(t) ~= 'table' then return t end
        local o = {}
        for k, v in pairs(t) do o[k] = deepcopy(v) end
        return o
    end

    function settings.load(defaults, alias)
        settings.defaults = defaults
        local key = current or '__defaults'
        store[key] = store[key] or deepcopy(defaults)
        return store[key]
    end
    function settings.register(alias, name, fn) callbacks[name] = fn end
    function settings.save() settings.saved = (settings.saved or 0) + 1 end
    function settings.settings_path() return 'mock/' .. tostring(current) end
    -- test helper: switch character (nil = logout)
    function settings.switch(name)
        current = name
        settings.logged_in = name ~= nil
        local key = name or '__defaults'
        store[key] = store[key] or deepcopy(settings.defaults)
        for _, fn in pairs(callbacks) do fn(store[key]) end
    end
    function settings.file(name) return store[name] end

    package.loaded['settings'] = settings
    A.settings = settings
end

return A
