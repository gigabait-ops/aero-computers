-- Colony Supply: minimum-stock rules for the colony warehouse hut.
--
-- Rules come from /rules/keep.lua ({item, min, name}) and are reloaded
-- every `reload_every` seconds. Each shortfall becomes a request-like entry
-- for Supply (same shape as a colony request), so the ordering, crafting and
-- delivery path is shared. Pure: inventories, loader and clock are injected.

local Stock = {}
Stock.__index = Stock

function Stock.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Stock)
    self.warehouse = deps.warehouse          -- inventory peripheral (may be nil)
    self.inbox = deps.inbox                  -- inventory peripheral (may be nil)
    self.loader = assert(deps.loader, "stock needs loader() -> rules, err")
    self.clock = deps.clock or function() return os.clock() end
    self.log = deps.log or {warn = function() end, info = function() end}
    self.config = {
        reload_every = tonumber(deps.config and deps.config.reload_every) or 10,
        reorder_after = tonumber(deps.config and deps.config.reorder_after) or 600,
    }
    self.rules = {}
    self.loadedAt = nil
    self.error = nil
    self.last = {levels = {}, short = 0, rules = 0}
    return self
end

local function validRule(rule)
    return type(rule) == "table" and type(rule.item) == "string" and rule.item ~= ""
        and (tonumber(rule.min) or 0) > 0
end

function Stock:reload(now)
    if self.loadedAt ~= nil and now - self.loadedAt < self.config.reload_every then return end
    self.loadedAt = now
    local rules, err = self.loader()
    if type(rules) ~= "table" then
        if err ~= self.error then self.log.warn("STOCK_RULES", tostring(err)) end
        self.error = err or "invalid rules"
        return
    end
    local clean = {}
    for _, rule in ipairs(rules) do
        if validRule(rule) then
            clean[#clean + 1] = {item = rule.item, min = math.floor(tonumber(rule.min)), name = rule.name or rule.item,
                plain = rule.plain == true, group = rule.group}
        end
    end
    if #clean ~= #self.rules or self.error then
        self.log.info("STOCK_RULES", #clean, "rules loaded")
    end
    self.rules = clean
    self.error = nil
end

-- totals[name] counts every stack, totals[name .. "#plain"] only stacks
-- without a component patch (no enchantments, no damage)
local function countIn(inventory, totals)
    if inventory == nil then return false end
    local ok, slots = pcall(inventory.list)
    if not ok or type(slots) ~= "table" then return false end
    for _, stack in pairs(slots) do
        if type(stack) == "table" and type(stack.name) == "string" then
            local n = tonumber(stack.count) or 0
            totals[stack.name] = (totals[stack.name] or 0) + n
            if stack.nbt == nil then
                totals[stack.name .. "#plain"] = (totals[stack.name .. "#plain"] or 0) + n
            end
        end
    end
    return true
end

-- Request-like entries for every rule below its minimum.
function Stock:entries()
    local now = self.clock()
    self:reload(now)
    local have = {}
    local okWarehouse = countIn(self.warehouse, have)
    countIn(self.inbox, have)
    local entries, levels, short = {}, {}, 0
    for _, rule in ipairs(self.rules) do
        local level
        if rule.plain then level = have[rule.item .. "#plain"] or 0 else level = have[rule.item] or 0 end
        levels[rule.item] = level
        local shortfall = rule.min - level
        if okWarehouse and shortfall > 0 then
            short = short + 1
            entries[#entries + 1] = {
                id = "stock:" .. rule.item,
                state = "IN_PROGRESS",
                count = shortfall,
                target = "stock rule",
                displayName = rule.name,
                items = {{name = rule.item, count = shortfall}},
                plain = rule.plain,
                noPad = true,
                dedupeByName = true,
                reorder_after = self.config.reorder_after,
            }
        end
    end
    self.last = {levels = levels, short = short, rules = #self.rules, warehouseOk = okWarehouse}
    if not okWarehouse then return nil end   -- unknown: the warehouse could not be read
    return entries
end

return Stock
