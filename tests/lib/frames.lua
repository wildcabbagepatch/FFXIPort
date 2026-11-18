-- Test-only reference reassembler for FPX/1 frames (independent of the
-- client implementation, used to check server output). GPL-3.0-only, (C) 2026 wildthing.
local F = {}

local function adler(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return string.format('%04x%04x', b, a)
end

-- printed: list of { msg = ..., channel = ... }; returns list of responses
-- { rid, kind, body, fields } in order of completion.
function F.decode(printed)
    local asm, out = {}, {}
    for _, e in ipairs(printed) do
        local ver, rid, seq, total, data = e.msg:match('^#fpx(%d+) (%x%x%x%x) (%d+)/(%d+) (%S+)$')
        assert(ver == '1', 'bad frame: ' .. e.msg)
        assert(#e.msg <= 220, 'frame too long')
        local a = asm[rid] or { parts = {} }
        asm[rid] = a
        a.total = tonumber(total)
        a.parts[tonumber(seq)] = data
        local complete = a.parts[0] ~= nil
        for i = 1, a.total do complete = complete and a.parts[i] ~= nil end
        if complete then
            local kind, len, sum = a.parts[0]:match('^([STE]),(%d+),(%x+)$')
            local body = table.concat(a.parts, '', 1, a.total)
            assert(#body == tonumber(len), 'length mismatch')
            assert(adler(body) == sum, 'checksum mismatch')
            local fields = {}
            for k, v in body:gmatch('([^;=]+)=([^;]*)') do fields[k] = v end
            out[#out + 1] = { rid = rid, kind = kind, body = body, fields = fields }
            asm[rid] = nil
        end
    end
    return out
end

function F.bitSet(bitmap, id)
    local count, hex = bitmap:match('^(%d+):(%x*)$')
    count = tonumber(count)
    if id >= count then return false end
    local d = tonumber(hex:sub(math.floor(id / 4) + 1, math.floor(id / 4) + 1), 16)
    return math.floor(d / 2 ^ (id % 4)) % 2 == 1
end

return F
