-- How an item is made, from CC: Recipe Atlas (server mod, require("recipes")).
-- Used by PC107's craft module (app/craft.lua) and PC66's checklist; the two
-- copies (107/app and 66/app) stay identical (tests/colony107_routes_test.lua).
-- PC48 makes only what its workers can: a crafting turtle, or one of its
-- stations (slicer PC137, saw PC136, mechanical crafter PC134, basins PC150).
-- Without Recipe Atlas, or when it cannot tell, an item is "unknown" and PC48
-- decides. When the server cannot answer now (busy, reloading, call budget),
-- the item is "unknown" with later = true: ask again next time, do not send.
-- Answers are cached per item and dropped when the recipe snapshot changes.
local Routes = {}
Routes.__index = Routes

-- kind -> words for the screen and the activity feed
Routes.TEXT = {
    turtle = "crafting turtle", station = "PC48 station", furnace = "needs a furnace", machine = "needs a machine",
    colony = "made in a colony hut", special = "special recipe, not for turtles",
    none = "no crafting recipe", unknown = "unknown",
}

-- Errors that say "not now" rather than "no": the call is tried again later.
local LATER = {"rate_limited", "not_ready", "stale_snapshot", "stale_cursor", "search_budget_exhausted", "runtime_busy"}
local function isLater(err)
    err = tostring(err)
    for _, code in ipairs(LATER) do
        if err:sub(1, #code) == code or err:find(": " .. code, 1, true) then return true end
    end
    return false
end
Routes.isLater = isLater

function Routes.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Routes)
    local api = deps.recipes
    if api == nil then
        local ok, mod = pcall(require, "recipes")
        api = ok and mod or nil
    end
    self.api = type(api) == "table" and type(api.routes) == "function" and api or nil
    self.clock = deps.clock or function() return os.clock() end
    self.ttl = tonumber(deps.ttl) or 3600
    self.batch = nil       -- targets per routes() call, from capabilities()
    self.cache = {}        -- item -> {kind, detail, at}
    self.generation = nil
    return self
end

function Routes:available() return self.api ~= nil end

-- At most 16 targets per call, fewer if the server allows fewer.
function Routes:batchSize()
    if self.batch then return self.batch end
    local size = 16
    if type(self.api.capabilities) == "function" then
        local ok, caps = pcall(self.api.capabilities)
        local limit = ok and type(caps) == "table" and type(caps.limits) == "table" and tonumber(caps.limits.maximumBatchIds)
        if limit and limit >= 1 then size = math.min(size, math.floor(limit)) end
    end
    self.batch = size
    return size
end

-- meta() is free (no call budget). Drops every answer when the server
-- rebuilt its recipe snapshot. Returns false while the server cannot answer:
-- no snapshot yet, or this computer's call budget is used up.
function Routes:checkGeneration()
    if type(self.api.meta) ~= "function" then return true end
    local ok, meta = pcall(self.api.meta)
    if not ok or type(meta) ~= "table" then return true end
    if meta.ready == false then return false end
    local generation = meta.generation
    if generation ~= nil and generation ~= self.generation then
        self.generation = generation
        self.cache = {}
    end
    local budget = type(meta.callBudget) == "table" and tonumber(meta.callBudget.remaining)
    return not budget or budget >= 2
end

-- One routes() answer -> kind, detail.
--   turtle   a crafting-table recipe a turtle can lay out (PC48 can do it)
--   furnace / machine / colony / special: only other ways (detail = the
--            furnace, machine or hut id)
--   none     no recipe at all
--   unknown  the server cannot tell (routes cut short, recipe list incomplete)
-- Turtle recipes come only from the server's recipe list, so a complete
-- "minecraft:recipe_manager" source is enough to say "not for turtles" even
-- when another source (MineColonies definitions) is unavailable.
function Routes.classify(item, coverage)
    if type(item) ~= "table" then return "unknown" end
    local other, detail
    for _, route in ipairs(item.routes or {}) do
        local category = tostring(route.category or "")
        if category == "turtle" then return "turtle" end
        if not other then
            local req = type(route.requirements) == "table" and route.requirements or {}
            local executor = type(req.executors) == "table" and req.executors[1] or nil
            local id = (type(executor) == "table" and executor.id) or route.workbench
            if category == "machine" and (id == nil or id == "crafting_table") then
                other, detail = "special", nil
            elseif category == "furnace" or category == "machine" then
                other, detail = category, id
            elseif category == "colony" then
                local hut = req.hut
                other, detail = "colony", type(hut) == "table" and (hut.hutType or hut.id) or hut
            end
        end
    end
    if item.routesTruncated then return "unknown" end
    local manager = type(coverage) == "table" and coverage["minecraft:recipe_manager"] or nil
    local complete = item.status == "no_known_route"
        or (type(manager) == "table" and manager.state == "ready")
    if not complete then return "unknown" end
    if other then return other, detail end
    return "none"
end

-- PC48's stations, by recipe type (as fleet controller/job_kind.lua routes them)
Routes.STATIONS = {
    {type = "create:mechanical_crafting", name = "mechanical crafter"},
    {type = "minecraft:stonecutting", name = "saw"},
    {type = "create:cutting", name = "saw"},
    {type = "sliceanddice:cutting", name = "slicer"},
    -- basins PC150 (2026-10-28): Create mixing (with Slice & Dice's cooking-pot food) and compacting
    {type = "create:mixing", name = "basin"},
    {type = "create:compacting", name = "basin"},
}
local STATION = {}
for i, s in ipairs(Routes.STATIONS) do STATION[s.type] = {name = s.name, order = i} end

-- The PC48 station that makes `id`, or nil; raises the server's error.
-- producers() lists every recipe output row that makes the item, 100 rows a
-- call. A station counts its recipe's main output; a slicer also a sure
-- second output (tree bark from stripping a log).
function Routes:station(id)
    if type(self.api.producers) ~= "function" then return nil end
    local best, cursor, pages = nil, nil, 0
    repeat
        local page = self.api.producers(id, {limit = 100, cursor = cursor, expectedGeneration = self.generation})
        for _, row in ipairs(type(page) == "table" and page.items or {}) do
            local s = STATION[row.type]
            local main = row.role == "primary"
                or (row.type == "sliceanddice:cutting" and row.mode == "guaranteed")
            if s and main and (not best or s.order < best.order) then best = s end
        end
        cursor = type(page) == "table" and page.next_cursor or nil
        pages = pages + 1
    until best or not cursor or pages >= 5
    return best and best.name or nil
end

-- kind, detail for each name in `names` (one routes() call per 16 unknown
-- names, one producers() call per item that is not for a turtle). The API
-- missing or failing for good: "unknown". Not now: "unknown" + later.
function Routes:lookup(names)
    local now, out, todo = self.clock(), {}, {}
    if not self.api then
        for _, name in ipairs(names) do out[name] = {kind = "unknown"} end
        return out
    end
    local ready = self:checkGeneration()
    for _, name in ipairs(names) do
        local hit = self.cache[name]
        if hit and now - hit.at < self.ttl then out[name] = hit else todo[#todo + 1] = name end
    end
    local size = self:batchSize()
    for first = 1, #todo, size do
        local batch, ids = {}, {}
        for i = first, math.min(#todo, first + size - 1) do
            batch[#batch + 1] = todo[i]
            ids[#ids + 1] = (tostring(todo[i]):gsub("#.*$", ""))   -- "name#nbt" variants: ask for the item
        end
        local ok, reply = false, "rate_limited"
        if ready then ok, reply = pcall(self.api.routes, ids, {limit = 16, expectedGeneration = self.generation}) end
        local later = not ok and isLater(reply)
        if later then ready = false end   -- the rest waits for the next lookup
        local items = ok and type(reply) == "table" and reply.items or nil
        local coverage = ok and type(reply) == "table" and reply.sourceCoverage or nil
        for i, name in ipairs(batch) do
            local entry = {kind = "unknown", at = now, later = later or nil}
            local item = type(items) == "table" and items[i] or nil
            local target = type(item) == "table" and item.target
            local targetId = type(target) == "table" and target.id or target
            if item and (targetId == nil or targetId == ids[i]) then
                entry.kind, entry.detail = Routes.classify(item, coverage)
            end
            if entry.kind ~= "turtle" and entry.kind ~= "unknown" then
                local sok, station = false, "rate_limited"
                if ready then sok, station = pcall(self.station, self, ids[i]) end
                if sok and station then
                    entry.kind, entry.detail = "station", station
                elseif not sok and isLater(station) then
                    entry = {kind = "unknown", at = now, later = true}
                    ready = false
                end
            end
            -- only real answers are cached; "unknown" from an error is asked again
            if ok and items and not entry.later then self.cache[name] = entry end
            out[name] = entry
        end
    end
    return out
end

-- Can PC48 be asked for this item (turtle or station)? Unknown = yes,
-- except "not now" (later): that one waits for the next answer.
function Routes.craftable(entry)
    if entry == nil then return true end
    if entry.later then return false end
    return entry.kind == "turtle" or entry.kind == "station" or entry.kind == "unknown"
end

function Routes.describe(entry)
    if type(entry) ~= "table" then return Routes.TEXT.unknown end
    local text = Routes.TEXT[entry.kind] or tostring(entry.kind)
    if entry.detail and entry.kind ~= "turtle" then text = text .. " (" .. tostring(entry.detail) .. ")" end
    return text
end

return Routes
