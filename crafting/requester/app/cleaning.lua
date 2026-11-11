local Bus = require("app.bus")
local Shipping = require("app.shipping")

-- The Cleaning tab: sends every used item of one kind (configured filters,
-- backpacks with contents or settings) to the station that resets it.
-- 2026-10-26: replaces the Filters tab. Each order now carries one item
-- variant set of at most nine stacks (one package): configured filters do not
-- stack, so one order of hundreds of them made Create drop it silently.
-- Leaving the tab no longer cancels a send in progress.
local Cleaning = {}
Cleaning.__index = Cleaning

local SLOTS = 9
-- Packages per order for one-per-package items: PC48's warehouse permit
-- budget (orderBacklogBudget), below Create's silent drop limit of 10.
local PACKAGES = 8

Cleaning.KINDS = {
    {
        key = "filters", label = "Filters", button = "CLEAN FILTERS",
        addressKey = "filterCleaningAddress", defaultAddress = "Filters Cleaner",
        -- Only items with verified one-item clearing recipes in the installed mods.
        types = {
            {name = "create:filter", label = "Filter"},
            {name = "create:attribute_filter", label = "Attribute Filter"},
            {name = "create:package_filter", label = "Package Filter"},
            {name = "createshufflefilter:shuffle_filter", label = "Shuffle Filter"},
            {name = "createshufflefilter:weighted_shuffle_filter", label = "Weighted Shuffle Filter"},
        },
    },
    {
        key = "backpacks", label = "Backpacks", button = "UNLOAD BACKPACKS",
        -- Every backpack goes, with or without data (owner 2026-10-26).
        all = true,
        -- Create packs an item that cannot go inside containers (backpacks,
        -- shulker boxes: Item.canFitInsideContainerItems() == false) alone in
        -- its own package, so each backpack is one package.
        onePerPackage = true,
        addressKey = "backpackUnloadAddress", defaultAddress = "Backpack Unloader",
        types = {
            {name = "sophisticatedbackpacks:backpack", label = "Backpack"},
            {name = "sophisticatedbackpacks:copper_backpack", label = "Copper Backpack"},
            {name = "sophisticatedbackpacks:iron_backpack", label = "Iron Backpack"},
            {name = "sophisticatedbackpacks:gold_backpack", label = "Gold Backpack"},
            {name = "sophisticatedbackpacks:diamond_backpack", label = "Diamond Backpack"},
            {name = "sophisticatedbackpacks:netherite_backpack", label = "Netherite Backpack"},
        },
    },
}

local function kindByKey(key)
    for _, kind in ipairs(Cleaning.KINDS) do
        if kind.key == key then return kind end
    end
    return Cleaning.KINDS[1]
end

local function trim(text) return (tostring(text or ""):match("^%s*(.-)%s*$")) end
local function amount(value) return math.max(0, math.floor(tonumber(value) or 0)) end

-- A used item carries data: a configured filter, a backpack that was opened.
-- A clean one has none and stays in the warehouse.
local function used(item, kind)
    return kind.all == true or (type(item.nbt) == "string" and item.nbt ~= "")
end

function Cleaning:new(config, logger)
    local instance = setmetatable({
        active = false, generation = 0, busy = false, kind = Cleaning.KINDS[1].key,
        rows = {}, total = 0, used = 0, loaded = false, pendingRead = false,
        nextSend = 0, logger = logger,
    }, self)
    instance:configure(config)
    return instance
end

function Cleaning:addressOf(kind)
    kind = kind or kindByKey(self.kind)
    return trim(self.config:get(kind.addressKey, kind.defaultAddress))
end

function Cleaning:reset(read)
    self.generation = self.generation + 1
    self.rows, self.total, self.used = {}, 0, 0
    self.loaded = false
    self.pendingRead = read and self.active
    self.error, self.message = nil, nil
end

function Cleaning:configure(config)
    self.config = config
    local address = self:addressOf()
    if address ~= self.address then
        self.address = address
        if not self.sending then self:reset(true) end
    end
end

-- Showing the tab reads the stock once; hiding it keeps a send going.
function Cleaning:setActive(active)
    active = active == true
    if self.active == active then return end
    self.active = active
    if active and not self.sending then self:reset(true) end
end

function Cleaning:setKind(key)
    local kind = kindByKey(key)
    if kind.key == self.kind or self.sending then return false end
    self.kind = kind.key
    self.address = self:addressOf(kind)
    self:reset(true)
    return true
end

function Cleaning:snapshot(now)
    local kind = kindByKey(self.kind)
    local kinds = {}
    for index, item in ipairs(Cleaning.KINDS) do kinds[index] = {key = item.key, label = item.label} end
    return {
        kind = kind.key, kindLabel = kind.label, button = kind.button, kinds = kinds, all = kind.all == true,
        rows = self.rows, total = self.total, used = self.used,
        address = self.address, addressKey = kind.addressKey, loaded = self.loaded,
        busy = self.busy or self.sending == true, sending = self.sending == true,
        error = self.error, message = self.message,
        canSend = self.active and not self.busy and not self.sending
            and not self.error and self.address ~= "" and self.loaded and self.used > 0
            and (tonumber(now) or 0) >= self.nextSend,
    }
end

function Cleaning:requestSend(now)
    if not self:snapshot(now).canSend then return false end
    self.sending, self.sendQueue, self.requested, self.queuedCount = true, nil, 0, 0
    self.sendKind, self.sendAddress = self.kind, self.address
    self.error, self.message = nil, "PREPARING DELIVERY"
    return true
end

-- The warehouse Stock Ticker (app.bus), shared with the rule orders.
local function stockTicker(bus)
    local devices = bus:scan()
    local source = Bus.ticker(devices)
    return source and source.device, devices
end

-- Every used variant of the kind's items, with its own stack size.
local function usedVariants(stock, kind)
    local allowed = {}
    for _, item in ipairs(kind.types) do allowed[item.name] = true end
    local variants = {}
    for _, item in pairs(stock) do
        if type(item) == "table" and allowed[item.name] and used(item, kind) and amount(item.count) > 0 then
            local maximum = amount(item.maxCount)
            variants[#variants + 1] = {name = item.name, nbt = item.nbt, count = amount(item.count),
                maxCount = maximum > 0 and maximum or 1}
        end
    end
    table.sort(variants, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.nbt or "") < tostring(b.nbt or "")
    end)
    return variants
end

-- The next order and its package count: whole variants up to nine stacks
-- (one package), or up to eight items that each travel alone.
local function nextOrder(queue, onePerPackage)
    local filters, stacks, parts = {}, 0, {}
    local limit = onePerPackage and PACKAGES or SLOTS
    for index, variant in ipairs(queue) do
        local room = limit - stacks
        if room <= 0 then break end
        local perStack = onePerPackage and 1 or variant.maxCount
        local count = math.min(variant.count, room * perStack)
        if count <= 0 then break end
        filters[#filters + 1] = {name = variant.name, nbt = variant.nbt, _requestCount = count}
        parts[#parts + 1] = {index = index, count = count}
        stacks = stacks + math.ceil(count / perStack)
    end
    return filters, parts, onePerPackage and stacks or (stacks > 0 and 1 or 0)
end
Cleaning._nextOrder = nextOrder

function Cleaning:readStock(bus)
    local kind = kindByKey(self.kind)
    local token = self.generation
    local device, devices = stockTicker(bus)
    if not device or type(device.stock) ~= "function" then error("STOCK TICKER UNAVAILABLE", 0) end
    local stock = device.stock(true)
    if token ~= self.generation then return end
    if type(stock) ~= "table" then error("INVALID STOCK RESPONSE", 0) end
    local totals, usedCounts, visited = {}, {}, 0
    for _, item in pairs(stock) do
        if type(item) == "table" and item.name then
            local count = amount(item.count)
            totals[item.name] = (totals[item.name] or 0) + count
            if used(item, kind) then usedCounts[item.name] = (usedCounts[item.name] or 0) + count end
        end
        visited = visited + 1
        if visited % 256 == 0 and os and os.sleep then os.sleep(0) end
    end
    if devices.generation ~= nil and devices.generation ~= bus.generation then
        error("PERIPHERALS CHANGED; OPEN TAB AGAIN", 0)
    end
    local rows, total, usedTotal = {}, 0, 0
    for _, item in ipairs(kind.types) do
        local count, usedCount = totals[item.name] or 0, usedCounts[item.name] or 0
        rows[#rows + 1] = {name = item.name, label = item.label, count = count, used = usedCount}
        total, usedTotal = total + count, usedTotal + usedCount
    end
    if token ~= self.generation then return end
    self.rows, self.total, self.used, self.loaded = rows, total, usedTotal, true
end

function Cleaning:sendNext(bus, shipping)
    local kind, address = kindByKey(self.sendKind), self.sendAddress
    local device = stockTicker(bus)
    if not device or type(device.requestFiltered) ~= "function" then error("STOCK TICKER UNAVAILABLE", 0) end
    if address == "" then error("SET " .. kind.addressKey .. " IN CONFIG", 0) end
    if not self.sendQueue then
        -- One stock snapshot per click; the queue is finite.
        local stock = device.stock(true)
        if type(stock) ~= "table" then error("INVALID STOCK RESPONSE", 0) end
        self.sendQueue = usedVariants(stock, kind)
        local queued = 0
        for _, variant in ipairs(self.sendQueue) do queued = queued + variant.count end
        self.queuedCount = queued
    end
    local filters, parts, packages = nextOrder(self.sendQueue, kind.onePerPackage)
    if #filters == 0 then return 0, false end
    -- The package count paces the next order and takes PC48's permit.
    shipping:begin(packages, "cleaning")
    local called, result = pcall(device.requestFiltered, address, table.unpack(filters))
    shipping:finish(os.epoch and os.epoch("utc") / 1000 or 0)
    if not called then error(result, 0) end
    if type(result) ~= "number" or result < 0 or result ~= math.floor(result) then
        error("INVALID DELIVERY RESPONSE", 0)
    end
    for index = #parts, 1, -1 do
        local part = parts[index]
        local variant = self.sendQueue[part.index]
        variant.count = variant.count - part.count
        if variant.count <= 0 then table.remove(self.sendQueue, part.index) end
    end
    self.requested = (self.requested or 0) + result
    return result, true
end

function Cleaning:poll(bus, now, shipping)
    if self.busy then return end
    local sending = self.sending == true
    if sending then
        if not shipping:ready(now) then return end
    elseif not (self.active and self.pendingRead) then
        return
    end
    self.busy, self.pendingRead = true, false
    local attempted, requested = false, nil
    local ok, err = pcall(function()
        if sending then
            requested, attempted = self:sendNext(bus, shipping)
        else
            self:readStock(bus)
        end
    end)
    self.busy = false
    if sending and self.logger and type(self.logger.info) == "function" then
        pcall(self.logger.info, self.logger, "cleaning.delivery_requested", {
            kind = self.sendKind, address = self.sendAddress, requested = requested,
            attempted = attempted, ok = ok, error = not ok and tostring(err) or nil,
            left = self.sendQueue and #self.sendQueue or nil,
        })
    end
    if not ok then
        -- Never automatically repeat a delivery with an uncertain outcome.
        self.sending, self.sendQueue = false, nil
        self.error = attempted and ("DELIVERY RESULT UNKNOWN; CHECK DESTINATION: " .. tostring(err)) or tostring(err)
        self.message = nil
        self.nextSend = now + 2
        return
    end
    self.error = nil
    if sending then
        self.nextSend = shipping.nextAt
        local more = self.sendQueue and #self.sendQueue > 0
        self.sending = more or false
        self.message = "REQUESTED " .. tostring(self.requested or 0) .. " OF " .. tostring(self.queuedCount or 0)
            .. " TO " .. tostring(self.sendAddress) .. (more and " (SENDING)" or "")
        if not more then
            self.sendQueue = nil
            -- Read again so the tab shows what is left.
            self.loaded, self.pendingRead = false, true
            self.generation = self.generation + 1
        end
    end
end

return Cleaning
