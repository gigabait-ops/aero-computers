-- Default item facts from Recipe Atlas's recipes snapshot (itemInfo): stack limit
-- and real tags of any registered item, in stock or not. Cached per recipe generation, so a worker reads each item once instead
-- of calling getItemDetail on every slot or asking for detailed ticker stock.
-- The facts describe the default stack; callers keep a detail read for stacks
-- with components when the exact stack matters.
local Recipes = require("recipes")
local Call = require("autocrafter.recipe_call")

local Facts = {}
Facts.__index = Facts

function Facts.new(recipes)
    return setmetatable({recipes = recipes or Recipes, cache = {}}, Facts)
end

function Facts:ready()
    if self.available == nil then
        local ok, capabilities = Call.pcall(self.recipes.capabilities)
        if not ok then return false end
        local features = type(capabilities) == "table" and capabilities.features or {}
        self.available = features.itemInfo and true or false
        self.batch = math.max(1, math.floor(tonumber((capabilities.limits or {}).maximumBatchIds) or 100))
    end
    if not self.available then return false end
    local ok, meta = Call.pcall(self.recipes.meta)
    if not ok or type(meta) ~= "table" or meta.ready ~= true then return false end
    if meta.generation ~= self.generation then
        self.generation, self.cache = meta.generation, {}
    end
    return true
end

local function fact(item)
    local maximum = tonumber(item.maxCount)
    if type(item.id) ~= "string" or not maximum or maximum < 1
        or (item.status ~= nil and item.status ~= "ok") then return nil end
    local tags = {}
    for _, tag in ipairs(item.tags or {}) do tags[tag] = true end
    return {maxCount = math.floor(maximum), tags = tags, damageable = item.damageable == true}
end

-- names: list of item IDs. Returns {[name] = {maxCount, tags = {[tag] = true},
-- damageable}} for the names the snapshot knows, or nil when itemInfo is
-- unavailable or refused (the caller then reads details as before).
function Facts:lookup(names)
    if not self:ready() then return nil end
    local wanted, seen = {}, {}
    for _, name in ipairs(names or {}) do
        if type(name) == "string" and self.cache[name] == nil and not seen[name] then
            seen[name] = true
            wanted[#wanted + 1] = name
        end
    end
    for first = 1, #wanted, self.batch do
        local chunk = {}
        for index = first, math.min(#wanted, first + self.batch - 1) do chunk[#chunk + 1] = wanted[index] end
        local ok, reply = Call.pcall(self.recipes.itemInfo, chunk, {expectedGeneration = self.generation})
        if not ok or type(reply) ~= "table" or type(reply.items) ~= "table" then return nil end
        for _, name in ipairs(chunk) do self.cache[name] = false end
        for _, item in ipairs(reply.items) do
            local value = fact(item)
            if value then self.cache[item.id] = value end
        end
    end
    local found = {}
    for _, name in ipairs(names or {}) do
        if self.cache[name] then found[name] = self.cache[name] end
    end
    return found
end

function Facts:get(name)
    local found = self:lookup({name})
    return found and found[name] or nil
end

local shared
function Facts.shared()
    shared = shared or Facts.new()
    return shared
end

return Facts
