-- Minimal test harness (no external dependencies). GPL-3.0-only, (C) 2026 wildthing.
local H = { results = {}, current = nil }

local function fmt(v)
    if type(v) == 'string' then return string.format('%q', v) end
    return tostring(v)
end

function H.describe(name, fn)
    local prev = H.current
    H.current = (prev and (prev .. ' > ') or '') .. name
    fn()
    H.current = prev
end

function H.it(name, fn)
    local full = (H.current and (H.current .. ' > ') or '') .. name
    if H.before then H.before() end
    local ok, err = xpcall(fn, debug.traceback)
    H.results[#H.results + 1] = { name = full, ok = ok, err = err }
end

function H.eq(a, b, msg)
    if a ~= b then
        error((msg and (msg .. ': ') or '') .. 'expected ' .. fmt(b) .. ', got ' .. fmt(a), 2)
    end
end

function H.truthy(v, msg)
    if not v then error((msg or 'expected truthy') .. ', got ' .. fmt(v), 2) end
end

function H.falsy(v, msg)
    if v then error((msg or 'expected falsy') .. ', got ' .. fmt(v), 2) end
end

function H.report(label)
    local pass, fail = 0, 0
    for _, r in ipairs(H.results) do
        if r.ok then
            pass = pass + 1
            print('PASS  ' .. r.name)
        else
            fail = fail + 1
            print('FAIL  ' .. r.name .. '\n      ' .. tostring(r.err):gsub('\n', '\n      '))
        end
    end
    print(string.format('%s: %d passed, %d failed, %d total', label or 'tests', pass, fail, pass + fail))
    return fail == 0
end

return H
