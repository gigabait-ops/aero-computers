-- Where a material that no turtle can craft comes from, for the NEEDS
-- hints. A PC46 rule that keeps the material in stock names its station
-- (the rule's address). Otherwise the Recipe Atlas routes that PC48 attaches
-- to MISSING_RAW (failure.routes = {{category, via, recipeId}, ...}) map to
-- a station through `routeStations` in 46/config.lua: by recipe id prefix
-- ("create:cutting" matches "create:cutting/...") or by the route's
-- workbench or first executor id ("minecraft:furnace"). "<Colour>" in a
-- station name becomes the item's dye colour ("Dye <Colour>" -> "Dye Red").
local RouteHints = {}
RouteHints.__index = RouteHints

-- Two-word colours first, so "light_blue" is not read as "blue".
local COLOURS = {"light_blue", "light_gray", "white", "orange", "magenta", "yellow", "lime", "pink",
    "gray", "cyan", "purple", "blue", "brown", "green", "red", "black"}

function RouteHints.colour(id)
    local path = "_" .. (tostring(id or ""):match(":(.+)$") or tostring(id or "")) .. "_"
    for _, colour in ipairs(COLOURS) do
        if path:find("_" .. colour .. "_", 1, true) then
            return (colour:gsub("_", " "):gsub("(%a)(%a*)", function(first, rest) return first:upper() .. rest end))
        end
    end
    return nil
end

-- config: the PC46 Config model (its rules and routeStations).
function RouteHints.new(config)
    local self = setmetatable({rules = {}, stations = {}}, RouteHints)
    if not config or type(config.get) ~= "function" or type(config.jobs) ~= "function" then return self end
    for key, value in pairs(config:get("routeStations", {}) or {}) do
        if type(key) == "string" and type(value) == "string" and value ~= "" then self.stations[key] = value end
    end
    for _, job in ipairs(config:jobs()) do
        if job.enabled ~= false and job.mode ~= "turtle_crafter" and not job.exportAvailable and not job.overflow
            and type(job.address) == "string" and job.address ~= "" and type(job.target) == "string"
            and not self.rules[job.target] then
            self.rules[job.target] = {key = job.key, address = job.address}
        end
    end
    return self
end

function RouteHints:station(route, raw)
    local prefix = type(route.recipeId) == "string" and route.recipeId:match("^([^/]+)/") or nil
    local name = (prefix and self.stations[prefix]) or self.stations[tostring(route.via or "")]
    if name and name:find("<Colour>", 1, true) then
        local colour = RouteHints.colour(raw)
        name = colour and (name:gsub("<Colour>", colour)) or nil
    end
    return name
end

-- The hint for one missing raw: the station's address (or the first
-- route's kind and machine) and where that came from; nil when nothing
-- is known.
function RouteHints:describe(raw, routes)
    local rule = self.rules[tostring(raw or "")]
    if rule then return rule.address, "PC46 rule " .. tostring(rule.key) end
    routes = type(routes) == "table" and routes or {}
    for _, route in ipairs(routes) do
        local name = type(route) == "table" and self:station(route, raw) or nil
        if name then return name, tostring(route.category or "route") .. " route" end
    end
    local first = routes[1]
    if type(first) == "table" and first.category then
        return tostring(first.category) .. (first.via and (" " .. tostring(first.via)) or ""), "Recipe Atlas route"
    end
    return nil
end

return RouteHints
