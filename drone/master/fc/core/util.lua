-- Small helpers shared by the flight computer's modules.
local U = {}

function U.clamp(v, lo, hi)
    if v > hi then return hi elseif v < lo then return lo end
    return v
end

-- Rounded to a tenth (coordinates and trims as they are saved).
function U.tenth(v)
    return math.floor(v * 10 + 0.5) / 10
end

-- "goto 1 2 3" -> {"goto", "1", "2", "3"}; nil for a blank line.
function U.words(line)
    local words = {}
    for word in tostring(line or ""):gmatch("%S+") do words[#words + 1] = word end
    if #words == 0 then return nil end
    return words
end

-- A field of a nested table by its path ({"ap", "speed"}); nil when missing.
function U.get_path(t, path)
    local v = t
    for _, key in ipairs(path) do
        if type(v) ~= "table" then return nil end
        v = v[key]
    end
    return v
end

-- Sets a field by its path, making the tables on the way.
function U.set_path(t, path, value)
    local parent = t
    for i = 1, #path - 1 do
        if type(parent[path[i]]) ~= "table" then parent[path[i]] = {} end
        parent = parent[path[i]]
    end
    parent[path[#path]] = value
end

return U
