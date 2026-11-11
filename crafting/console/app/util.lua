local Util = {}

function Util.now()
    if os and type(os.epoch) == "function" then
        return os.epoch("utc") / 1000
    end

    return os and type(os.clock) == "function" and os.clock() or 0
end

function Util.integer(value, fallback)
    return math.floor(tonumber(value) or tonumber(fallback) or 0)
end

function Util.itemLabel(item)
    local displayName = type(item) == "table" and item.displayName or nil
    if type(displayName) == "string" and displayName ~= "" then
        return displayName
    end

    local name = type(item) == "table" and item.name or item
    local path = tostring(name or "-"):match("^[^:]+:(.+)$") or tostring(name or "-")
    return path:gsub("_", " "):upper()
end

-- Where a missing raw is made, by the rule of 46/app/route_hints.lua: the
-- PC46 rule that keeps the raw in stock names its station; otherwise the
-- Recipe Atlas routes PC48 sends with MISSING_RAW ({category, via, recipeId})
-- map to a station by recipe id prefix or by workbench/executor id.
-- config: routeHints from 66/config.lua (rules = station -> items).
function Util.routeHints(config)
    config = type(config) == "table" and config or {}
    local hints, names = {rules = {}, stations = {}}, {}
    for station, items in pairs(type(config.rules) == "table" and config.rules or {}) do
        if type(station) == "string" and station ~= "" and type(items) == "table" then names[#names + 1] = station end
    end
    table.sort(names)
    for _, station in ipairs(names) do
        for _, item in ipairs(config.rules[station]) do
            if type(item) == "string" and not hints.rules[item] then hints.rules[item] = station end
        end
    end
    for key, value in pairs(type(config.routeStations) == "table" and config.routeStations or {}) do
        if type(key) == "string" and type(value) == "string" and value ~= "" then hints.stations[key] = value end
    end
    return hints
end

-- Two-word colours first, so "light_blue" is not read as "blue".
local COLOURS = {"light_blue", "light_gray", "white", "orange", "magenta", "yellow", "lime", "pink",
    "gray", "cyan", "purple", "blue", "brown", "green", "red", "black"}

function Util.colour(id)
    local path = "_" .. (tostring(id or ""):match(":(.+)$") or tostring(id or "")) .. "_"
    for _, colour in ipairs(COLOURS) do
        if path:find("_" .. colour .. "_", 1, true) then
            return (colour:gsub("_", " "):gsub("(%a)(%a*)", function(first, rest) return first:upper() .. rest end))
        end
    end
    return nil
end

local function routeStation(hints, route, raw)
    local prefix = type(route.recipeId) == "string" and route.recipeId:match("^([^/]+)/") or nil
    local name = (prefix and hints.stations[prefix]) or hints.stations[tostring(route.via or "")]
    if name and name:find("<Colour>", 1, true) then
        local colour = Util.colour(raw)
        name = colour and (name:gsub("<Colour>", colour)) or nil
    end
    return name
end

-- The station for one missing raw, or the first route's kind and machine
-- ("machine SPOUT"); nil when nothing is known.
function Util.stationHint(hints, raw, routes)
    if type(hints) ~= "table" then return nil end
    local rule = hints.rules and hints.rules[tostring(raw or "")]
    if rule then return rule end
    routes = type(routes) == "table" and routes or {}
    for _, route in ipairs(routes) do
        local name = type(route) == "table" and routeStation(hints, route, raw) or nil
        if name then return name end
    end
    local first = routes[1]
    if type(first) == "table" and first.category then
        return tostring(first.category) .. (first.via and (" " .. Util.itemLabel({name = first.via})) or "")
    end
    return nil
end

-- A MISSING_RAW failure names the ingredient no turtle recipe can produce;
-- with hints (Util.routeHints) also the station that makes it.
function Util.rawShortage(job, hints)
    local failure = type(job) == "table" and job.failure or nil
    if type(failure) ~= "table" or failure.code ~= "MISSING_RAW" then return nil end
    local parsedRaw, parsedCount = tostring(failure.message or job.error or ""):match("missing (%S+) x(%d+)")
    local raw = failure.target or failure.candidate or failure.ingredient or parsedRaw
    if type(raw) ~= "string" or raw == "" then return nil end
    return {
        raw = raw,
        needed = math.max(1, math.floor(tonumber(failure.needed) or tonumber(parsedCount) or 1)),
        hint = Util.stationHint(hints, raw, failure.routes),
    }
end

function Util.log(logger, level, event, fields)
    if not logger or type(logger[level]) ~= "function" then
        return
    end

    pcall(logger[level], logger, event, fields or {})
end

return Util
