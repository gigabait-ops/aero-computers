local Util = {}

function Util.clone(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}

    for key, item in pairs(value) do
        result[key] = Util.clone(item)
    end

    return result
end

function Util.isArray(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0

    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end

        count = count + 1
    end

    return count == #value
end

-- Keys of one type sort by value, mixed ones by their text.
function Util.sortedKeys(value)
    local keys = {}

    for key in pairs(value or {}) do
        table.insert(keys, key)
    end

    table.sort(keys, function(left, right)
        if type(left) == type(right) then return left < right end
        return tostring(left) < tostring(right)
    end)
    return keys
end

function Util.labelFromKey(key)
    local text = tostring(key or "-")
    local clean = text:match("^[^:]+:(.+)$") or text
    clean = clean:gsub("[_%-%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    return string.upper(clean ~= "" and clean or text)
end

-- MISSING_RAW names the ingredient no turtle recipe in the plan can produce:
-- stonecutter parts, stripped logs, or plain raw materials. `hint` is the
-- station that makes it (the controller adds it, see app.route_hints).
function Util.rawShortage(failure, detail)
    if type(failure) ~= "table" or failure.code ~= "MISSING_RAW" then return nil end
    local message = tostring(failure.message or detail or "")
    local parsedRaw, parsedCount = message:match("missing (%S+) x(%d+)")
    local raw = failure.target or failure.candidate or failure.ingredient or parsedRaw
    local needed = tonumber(failure.needed) or tonumber(parsedCount)
    if type(raw) ~= "string" or raw == "" then return nil end
    return {raw = raw, needed = math.max(1, math.floor(needed or 1)),
        hint = type(failure.hint) == "string" and failure.hint or nil,
        hintSource = type(failure.hintSource) == "string" and failure.hintSource or nil}
end

function Util.nowSeconds()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")

        if ok and value then
            return value / 1000
        end
    end

    return os.clock()
end

return Util
