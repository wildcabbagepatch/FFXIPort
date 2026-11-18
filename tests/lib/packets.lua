-- Realistic incoming 0x017 chat packets, built exactly like LandSandBoat's
-- GP_SERV_COMMAND_CHAT_STD constructor (src/map/packets/s2c/0x017_chat_std.cpp):
--   header: id (9 bits) + size in 4-byte units (7 bits), u16 sync
--   0x04 Kind, 0x05 Attr, 0x06 Data (u16 zone), 0x08 sName[15], 0x17 Mes
--   Mes is truncated to 150 bytes; the packet is padded with zeros to a
--   multiple of 4 (so a message may have no terminating NUL).
-- printToPlayer(msg, channel) without a sender uses the RECEIVING player's
-- own name as sName (observed in-game: "from Tuna").
-- GPL-3.0-only, (C) 2026 wildthing.
local K = {}

K.MES_MAX = 150

local function u16le(n) return string.char(n % 256, math.floor(n / 256) % 256) end

function K.chat(kind, sender, message, opts)
    opts = opts or {}
    local mes  = string.sub(message, 1, K.MES_MAX)
    local name = string.sub(sender or '', 1, 15)
    name = name .. string.rep('\0', 15 - #name)

    local size = 4 + 1 + 1 + 2 + 15 + #mes
    size = math.ceil(size / 4) * 4

    local id     = 0x017
    local units  = size / 4
    local header = string.char(id % 256, (units * 2 + math.floor(id / 256)) % 256) .. u16le(opts.sync or 0x1234)
    local body   = header .. string.char(kind, opts.attr or 0) .. u16le(opts.zone or 230) .. name .. mes

    return body .. string.rep('\0', size - #body)
end

-- An Ashita-like packet_in event for a chat packet.
function K.event(kind, sender, message, opts)
    local data = K.chat(kind, sender, message, opts)
    return { id = 0x0017, size = #data, data = data, data_modified = data, blocked = false }
end

return K
