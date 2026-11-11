-- Colony Supply: what the builders still need for their claimed work orders.
--
-- getWorkOrderResources(id) returns the builder's full resource list for the
-- order (the "Resources" tab of the hut); `item` is an item table
-- {name, nbt, components, ...}. Shortfalls become request-like entries for
-- Supply so the warehouse is stocked before the builder asks. They are
-- prestock only: never crafted (the builder's real request does that).
-- Variant blocks keep their `nbt`, so Supply orders exactly that variant.

local Builder = {}
Builder.__index = Builder

local WANT = {DONT_HAVE = true, NEED_MORE = true}

function Builder.new(deps)
    deps = deps or {}
    assert(type(deps.integrator) == "table", "builder needs an integrator")
    local self = setmetatable({}, Builder)
    self.integrator = deps.integrator
    self.inventories = deps.inventories or {}   -- colony warehouse hut, inbox...
    self.log = deps.log or {warn = function() end, info = function() end}
    self.clock = deps.clock or function() return os.clock() end
    self.config = {
        max_items = tonumber(deps.config and deps.config.max_items) or 64,
        reorder_after = tonumber(deps.config and deps.config.reorder_after) or 10800,
        -- work orders and their resource lists change slowly; re-read them
        -- at most this often (each list is one large peripheral call)
        refresh_every = tonumber(deps.config and deps.config.refresh_every) or 60,
    }
    self.cachedAt = nil
    self.cached = nil
    self.queue = {}        -- every work order, in the order builders take them
    self.last = {workOrders = 0, entries = 0, total = 0}
    return self
end

local function itemName(item)
    if type(item) == "table" then return item.name end
    return item
end

-- name -> count already sitting in the inventories we can see
function Builder:have()
    local totals = {}
    for _, inv in ipairs(self.inventories) do
        local ok, slots = pcall(inv.list)
        if ok and type(slots) == "table" then
            for _, stack in pairs(slots) do
                if type(stack) == "table" and type(stack.name) == "string" then
                    totals[stack.name] = (totals[stack.name] or 0) + (tonumber(stack.count) or 0)
                end
            end
        end
    end
    return totals
end

-- {order, resources} for every claimed work order, cached refresh_every s.
function Builder:resources()
    local now = self.clock()
    if self.cached and self.cachedAt and now - self.cachedAt < self.config.refresh_every then
        return self.cached
    end
    local ok, orders = pcall(self.integrator.getWorkOrders)
    if not ok or type(orders) ~= "table" then
        return nil, "work orders: " .. tostring(orders)
    end
    local list, queue = {}, {}
    for _, order in pairs(orders) do
        if type(order) == "table" and order.id ~= nil then
            local home = type(order.builderHome) == "table" and order.builderHome or nil
            queue[#queue + 1] = {
                id = order.id, type = order.type, name = order.displayName, level = order.level,
                targetLevel = order.targetLevel, stage = order.stage, priority = tonumber(order.priority) or 0,
                claimed = order.isClaimed == true, builderLevel = home and home.level or nil, pos = order.pos,
            }
            if order.isClaimed then
                local okRes, resources = pcall(self.integrator.getWorkOrderResources, order.id)
                if okRes and type(resources) == "table" then
                    list[#list + 1] = {order = order, resources = resources}
                end
            end
        end
    end
    -- builders take higher priority first, then the oldest order
    table.sort(queue, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    self.queue = queue
    self.cached, self.cachedAt = list, now
    return list
end

-- item -> how many the builders still need from the colony warehouse for
-- their claimed orders (needs - in the builder's hut - on the way). What
-- already lies in the warehouse counts too, so Send never ships it away.
function Builder:needs()
    local out = {}
    for _, c in ipairs(self.cached or {}) do
        for _, res in pairs(c.resources or {}) do
            local name = type(res) == "table" and itemName(res.item) or nil
            if type(name) == "string" then
                local left = (tonumber(res.needs) or 0) - (tonumber(res.available) or 0) - (tonumber(res.delivering) or 0)
                if left > 0 then out[name] = (out[name] or 0) + left end
            end
        end
    end
    return out
end

function Builder:entries()
    local claimed, err = self:resources()
    if not claimed then return nil, err end   -- unknown this time
    local have = self:have()
    local entries, workOrders, total = {}, 0, 0
    local materials = {}   -- order id -> {items, missing}
    for _, c in ipairs(claimed) do
        local order, resources = c.order, c.resources
        local summary = {items = 0, missing = 0}
        materials[tostring(order.id)] = summary
        for _, res in pairs(resources) do
            if type(res) == "table" then
                summary.items = summary.items + 1
                if WANT[tostring(res.status)] then summary.missing = summary.missing + 1 end
            end
        end
        do
            do
                workOrders = workOrders + 1
                for _, res in pairs(resources) do
                    local name = type(res) == "table" and itemName(res.item) or nil
                    if type(name) == "string" and WANT[tostring(res.status)] then
                        local needs = tonumber(res.needs) or 0
                        local available = tonumber(res.available) or 0
                        local delivering = tonumber(res.delivering) or 0
                        local shortfall = needs - available - delivering
                        if shortfall > 0 then total = total + 1 end
                        local nbt = type(res.item) == "table" and res.item.nbt or nil
                        do
                            if nbt == nil then shortfall = shortfall - (have[name] or 0) end
                            if shortfall > 0 then
                                table.insert(entries, {
                                    id = "wo:" .. tostring(order.id) .. ":" .. name,
                                    state = "IN_PROGRESS",
                                    count = shortfall,
                                    target = "builder: " .. tostring(order.displayName or order.id),
                                    displayName = res.displayName or name,
                                    items = {{name = name, nbt = nbt, count = shortfall,
                                        maxStackSize = type(res.item) == "table" and res.item.maxStackSize or nil}},
                                    dedupeByName = true,
                                    -- plain vanilla blocks may go to the crafter ahead of
                                    -- time (owner 2026-11-07); mod blocks and variants not
                                    noCraft = nbt ~= nil or name:sub(1, 10) ~= "minecraft:",
                                    reorder_after = self.config.reorder_after,
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.id < b.id end)
    while #entries > self.config.max_items do table.remove(entries) end
    self.last = {workOrders = workOrders, entries = #entries, total = total,
        materials = materials}
    return entries
end

return Builder
