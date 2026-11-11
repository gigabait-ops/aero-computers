-- Exact planning preferences, not warehouse reservations or execution proofs.
local Recipes = require("recipes")
local ItemMatcher = require("item_matcher")
local Preflight = {}
Preflight.__index = Preflight
local Grid = require("autocrafter.recipe_grid")
local POSITION = Grid.POSITION

local busy = require("autocrafter.recipe_call").transient

local function pause(attempt)
    if type(sleep) == "function" then sleep(math.min(1, attempt * 0.25)) end
end

local function descriptor(stack)
    if type(stack) ~= "table" or type(stack.id) ~= "string"
        or type(stack.componentsJson) ~= "string"
        or not tonumber(stack.maxCount) or stack.maxCount < 1 then return nil end
    return {id = stack.id, count = 1, maxCount = stack.maxCount,
        componentsJson = stack.componentsJson}
end

local identity = Grid.identity

function Preflight.new(snapshot, generation)
    return setmetatable({
        snapshot = snapshot, generation = generation,
        reads = {}, previews = {}, nodes = {}, evaluations = 0, detailReads = 0,
    }, Preflight)
end

function Preflight:read(source)
    if self.reads[source] ~= nil then return self.reads[source] or nil end
    local detail = source.item
    for attempt = 1, 2 do
        local stack = detail and detail.recipes
        if detail and identity(detail) == identity(source.item)
            and (tonumber(detail.count) or 0) > 0
            and type(stack) == "table" and stack.status == "ok"
            and stack.scope == "actual_stack" and stack.id == detail.name then
            local value = descriptor(stack)
            if value then self.reads[source] = value; return value end
        end
        if not source.read or attempt == 2 or self.detailReads >= 64 then break end
        if detail and identity(detail) ~= identity(source.item) then break end
        if stack and stack.status ~= "ok" and not busy(stack.reason) then break end
        if attempt > 1 then pause(attempt - 1) end
        self.detailReads = self.detailReads + 1
        local ok, value = pcall(source.read)
        if not ok or not value then break end
        detail = value
    end
    self.reads[source] = false
    return nil
end

function Preflight:candidates(ingredient, nodes, upto)
    local found, seen, unknown = {}, {}, false
    local function add(stack)
        local value = descriptor(stack)
        if not value then unknown = true; return end
        local key = value.id .. "\0" .. value.componentsJson
        if not seen[key] then
            seen[key] = true
            if #found < 8 then found[#found + 1] = value else unknown = true end
        end
    end
    local function matches(name)
        local metadata = (self.snapshot.localMetadata or {})[name]
            or (self.snapshot.stockMetadata or {})[name] or {name = name}
        return ItemMatcher.matchesIngredient(metadata, ingredient)
    end
    for _, source in ipairs(self.snapshot.recipeSources or {}) do
        if source.item and matches(source.item.name)
            and (tonumber(source.item.count) or 0) > 0 then
            add(self:read(source))
        end
    end
    -- Predict earlier outputs only via a full native preview of exact inputs.
    -- A result template or default item catalog entry is not an actual stack.
    for index = 1, upto do
        local node = nodes[index]
        if matches(node.target) then
            if node.previewResult then
                add(node.previewResult)
            else
                local cached = self.nodes[node]
                if not cached then
                    local status, result = self:evaluate({
                        recipe = node.recipeId, result = {id = node.target, count = node.outputPerCycle},
                        slots = node.slots,
                    }, nodes, index - 1)
                    cached = {status = status, result = result}
                    self.nodes[node] = cached
                end
                if cached.status == "ok" then add(cached.result) else unknown = true end
            end
        end
    end
    if #found == 0 then unknown = true end
    return found, unknown
end

function Preflight:preview(plan, grid)
    local parts = {plan.recipe}
    for slot = 1, 9 do
        local stack = grid[slot]
        parts[#parts + 1] = stack and (stack.id .. "\0" .. stack.componentsJson) or ""
    end
    local key = table.concat(parts, "\1")
    local cached = self.previews[key]
    if cached then return cached.status, cached.result end
    if self.evaluations >= 32 then return "unknown" end
    self.evaluations = self.evaluations + 1
    for attempt = 1, 2 do
        local ok, reply = pcall(Recipes.preview, plan.recipe, grid, {
            expectedGeneration = self.generation, limit = 1,
        })
        if ok then
            local result = type(reply) == "table" and reply.result or nil
            local status = "unknown"
            if type(reply) == "table" and reply.generation == self.generation then
                if reply.status == "no_match" then
                    status = "no_match"
                elseif reply.status == "ok" and descriptor(result)
                    and result.id == plan.result.id and result.count == plan.result.count then
                    status = "ok"
                end
            end
            self.previews[key] = {status = status, result = status == "ok" and result or nil}
            return status, status == "ok" and result or nil
        end
        if not busy(reply) or attempt == 2 then return "unknown" end
        pause(attempt)
    end
    return "unknown"
end

function Preflight:evaluate(plan, nodes, upto)
    if not self.snapshot.recipeSources or self.evaluations >= 32 then return "unknown" end
    local choices, grouped, unknown = {}, {}, false
    for index, entry in ipairs(plan.slots or {}) do
        if not POSITION[entry.slot] then return "unknown" end
        local key = ItemMatcher.ingredientText(entry.ingredient)
        local group = grouped[key]
        if not group then
            local variants, incomplete = self:candidates(entry.ingredient, nodes, upto)
            group = {variants = variants, incomplete = incomplete}
            grouped[key] = group
        end
        if #group.variants == 0 then return "unknown" end
        choices[index] = group.variants
        unknown = unknown or group.incomplete
    end
    if #choices == 0 then return "unknown" end
    local grid, attempts = {}, 0
    local function visit(index)
        if attempts >= 16 then unknown = true; return nil end
        if index > #choices then
            attempts = attempts + 1
            local status, result = self:preview(plan, grid)
            if status == "ok" then return result end
            unknown = unknown or status == "unknown"
            return nil
        end
        local slot = POSITION[plan.slots[index].slot]
        for _, stack in ipairs(choices[index]) do
            grid[slot] = {id = stack.id, count = 1, componentsJson = stack.componentsJson}
            local result = visit(index + 1)
            if result then return result end
            if attempts >= 16 then unknown = true; break end
        end
        grid[slot] = nil
        return nil
    end
    local result = visit(1)
    if result then return "ok", result end
    return unknown and "unknown" or "no_match"
end

return Preflight
