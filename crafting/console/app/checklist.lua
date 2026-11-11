-- The Create clipboard checklist (moved here from PC46 on 2026-11-08):
-- its missing materials (getMissingItems, read at most every readSeconds)
-- against the warehouse stock of PC66's Stock Ticker. Per row or for the
-- whole list it plans what to send from stock to the checklist address,
-- what to craft at PC48 (turtle or station, app.craft_routes) and, for
-- CRAFT + SEND, the delivery of crafts once they land in stock. It only
-- plans: app.checklist_runner queues and sends the orders and reports back
-- (onOrderResult, onControllerState). A clipboard placed again, or a list
-- that changed, is a new session (a new token in every key and request id,
-- checklist:66:<time>:<n>:...); what an old session queued is dropped.
local Routes = require("app.craft_routes")
local Shipping = require("app.shipping")
local Util = require("app.util")

local Checklist = {}
Checklist.__index = Checklist

local function logEvent(logger, level, event, fields)
    Util.log(logger, level, event, fields)
end

local function positiveInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function normalizeItems(raw)
    local grouped = {}

    for _, value in pairs(type(raw) == "table" and raw or {}) do
        local name = type(value) == "table" and (value.name or value.item or value.id) or nil
        local count = type(value) == "table" and positiveInteger(value.count) or 0

        if type(name) == "string" and name ~= "" and name ~= "minecraft:air" and count > 0 then
            local item = grouped[name]
            if not item then
                item = {
                    name = name,
                    displayName = value.displayName,
                    count = 0,
                }
                grouped[name] = item
            end
            item.count = item.count + count
        end
    end

    local items = {}
    for _, item in pairs(grouped) do
        items[#items + 1] = item
    end

    table.sort(items, function(left, right)
        local leftLabel = tostring(left.displayName or left.name):lower()
        local rightLabel = tostring(right.displayName or right.name):lower()
        return leftLabel == rightLabel and left.name < right.name or leftLabel < rightLabel
    end)

    return items
end

local function nowSeconds()
    return os and os.epoch and os.epoch("utc") / 1000 or 0
end

local function fingerprint(items)
    local values = {}
    for _, item in ipairs(items or {}) do
        values[#values + 1] = item.name .. "=" .. tostring(item.count)
    end
    table.sort(values)
    return table.concat(values, "|")
end

-- options: config (the checklist table of 66/config.lua), shipping, logger,
-- hints (Util.routeHints: where a missing raw is made), computerId.
function Checklist:new(options)
    options = options or {}

    return setmetatable({
        config = options.config,
        shipping = options.shipping or Shipping:new(),
        logger = options.logger,
        hints = options.hints,
        routes = options.routes or Routes.new({recipes = options.recipes, clock = nowSeconds}),
        computerId = tonumber(options.computerId) or (os and os.getComputerID and os.getComputerID()) or 0,
        device = nil,
        deviceName = nil,
        loaded = false,
        generation = 0,
        sequence = 0,
        sessionToken = nil,
        items = {},
        itemFingerprint = nil,
        stock = {},
        waiting = {},
        requestToItem = {},
        queuedOutgoing = {},
        sendRemaining = {},
        sendErrors = {},
        pendingCrafts = {},
        stockRevision = 0,
        stockDispatches = 0,
        stockReady = false,
        sent = {},
        outboundUnobserved = {},
        recipeGeneration = nil,
        recipeCache = {},
        recipeQueue = {},
        recipeQueueIndex = 1,
        recipeQueued = {},
        recipeLibraryError = nil,
        itemStates = {},
        -- Survives clipboard sessions: re-attaching must not resend a craft
        -- that is known to need hand-made or missing raw material.
        rawShortages = {},
        nextReadAt = 0,
        lastError = nil,
    }, self)
end

function Checklist:get(key, fallback)
    local value = type(self.config) == "table" and self.config[key] or nil
    if value == nil then return fallback end
    return value
end

function Checklist:enabled()
    return self:get("enabled", true) ~= false
end

function Checklist:address()
    return tostring(self:get("address", "") or "")
end

function Checklist:connected()
    return self.device ~= nil and self.deviceName ~= nil
end

function Checklist:visible()
    return self.loaded == true and self:connected()
end

function Checklist:matches(name)
    return self.deviceName ~= nil and tostring(name or "") == tostring(self.deviceName)
end

function Checklist:resetSession()
    self.generation = (self.generation or 0) + 1
    self.sequence = 0
    self.items = {}
    self.itemFingerprint = nil
    self.stock = {}
    self.waiting = {}
    self.requestToItem = {}
    self.queuedOutgoing = {}
    self.sendRemaining = {}
    self.sendErrors = {}
    self.pendingCrafts = {}
    self.stockRevision = self.stockRevision + 1
    self.stockReady = false
    self.sent = {}
    self.outboundUnobserved = {}
    self.recipeGeneration = nil
    self.recipeCache = {}
    self.recipeQueue = {}
    self.recipeQueueIndex = 1
    self.recipeQueued = {}
    self.recipeLibraryError = nil
    self.itemStates = {}
    self.nextReadAt = 0
    self.loaded = false
    self.lastError = nil
end

function Checklist:newSessionToken()
    self.generation = self.generation + 1
    self.sessionToken = table.concat({
        "checklist",
        tostring(self.computerId),
        tostring(os.epoch("utc")),
        tostring(self.generation),
    }, ":")
    return self.sessionToken
end

function Checklist:bind(entry, now)
    if not self:enabled() then
        entry = nil
    end

    local name = entry and entry.name or nil
    local device = entry and entry.device or nil
    now = tonumber(now) or 0

    if name == self.deviceName and ((device ~= nil) == (self.device ~= nil)) then
        if device then
            self.device = device
        end
        return nil
    end

    local previousToken = self.sessionToken
    local previousName = self.deviceName
    local hadSession = previousName ~= nil
    self:resetSession()
    self.device = device
    self.deviceName = name
    self.sessionToken = nil

    if device and name then
        self:newSessionToken()
        self.nextReadAt = now
        logEvent(self.logger, "info", "checklist.attached", {
            peripheral = name,
            session = self.sessionToken,
        })
        return hadSession and "replaced" or "attached", previousToken
    end

    if hadSession then
        logEvent(self.logger, "info", "checklist.detached", {
            peripheral = previousName,
            session = previousToken,
        })
        return "detached", previousToken
    end

    return nil, previousToken
end

function Checklist:detach(name, now)
    if not self:matches(name) then
        return nil
    end
    return self:bind(nil, now)
end

function Checklist:replaceItems(items)
    local nextFingerprint = fingerprint(items)
    local previousFingerprint = self.itemFingerprint
    local previousToken = self.sessionToken

    if previousFingerprint ~= nil and previousFingerprint ~= nextFingerprint then
        self:resetSession()
        self:newSessionToken()
    end

    self.items = items
    self.itemFingerprint = nextFingerprint
    self.loaded = true
    local session = self.sessionToken
    self:syncRecipeGeneration()
    if session ~= self.sessionToken then return nil end
    self:queueRecipeChecks()
    self.lastError = nil

    if previousFingerprint ~= nil and previousFingerprint ~= nextFingerprint then
        logEvent(self.logger, "info", "checklist.changed", {
            items = #items,
            session = self.sessionToken,
        })
        return "changed", previousToken
    elseif previousFingerprint == nil then
        logEvent(self.logger, "info", "checklist.loaded", {
            items = #items,
            session = self.sessionToken,
        })
    end

    return previousFingerprint == nil and "loaded" or nil
end

function Checklist:refresh(now, force)
    if not self:connected() then
        return nil
    end

    now = tonumber(now) or 0
    if not force and now < (tonumber(self.nextReadAt) or 0) then
        return nil
    end

    local interval = math.max(0.5, tonumber(self:get("readSeconds", 2)) or 2)
    self.nextReadAt = now + interval

    if type(self.device.getMissingItems) ~= "function" then
        self.lastError = "getMissingItems unavailable"
        return "error"
    end

    local device, generation = self.device, self.generation
    local ok, result = pcall(device.getMissingItems)
    if self.device ~= device or self.generation ~= generation then return nil end
    if not ok or type(result) ~= "table" then
        self.lastError = ok and "invalid checklist data" or tostring(result)
        return "error"
    end

    return self:replaceItems(normalizeItems(result))
end

-- A scan may yield while the queue dispatches. Only a subsequent, unambiguous
-- Stock Ticker snapshot can retire local outgoing reservations. A count drop
-- cannot prove this: newly crafted items may arrive during the same interval.
function Checklist:beginStockRead()
    return self.stockRevision
end

function Checklist:beginStockDispatch()
    self.stockRevision = self.stockRevision + 1
    self.stockDispatches = self.stockDispatches + 1
end

function Checklist:endStockDispatch()
    self.stockRevision = self.stockRevision + 1
    self.stockDispatches = math.max(0, self.stockDispatches - 1)
end

function Checklist:updateStock(counts, revision)
    if self.stockDispatches > 0 or (revision ~= nil and revision ~= self.stockRevision) then
        return false
    end
    self.stockReady = true
    self.outboundUnobserved = {}
    counts = type(counts) == "table" and counts or {}
    self.lastCounts = counts
    local wanted = {}

    for _, item in ipairs(self.items) do
        wanted[item.name] = true
    end
    for name in pairs(self.waiting) do
        wanted[name] = true
    end

    local now = nowSeconds()
    -- How long a craft known to lack a raw stays skipped by bulk CRAFT.
    local ttl = math.max(1, tonumber(self:get("rawPauseSeconds", 600)) or 600)
    for name, shortage in pairs(self.rawShortages) do
        local rawCount = positiveInteger(counts[shortage.raw])
        shortage.baseStock = shortage.baseStock or rawCount
        if rawCount >= shortage.baseStock + shortage.needed or now - (shortage.at or now) >= ttl then
            self.rawShortages[name] = nil
            logEvent(self.logger, "info", "checklist.needs_cleared", {
                item = name, raw = shortage.raw, needed = shortage.needed, stock = rawCount,
            })
        end
    end

    for name in pairs(wanted) do
        local count = positiveInteger(counts[name])
        self.stock[name] = count
        local operation = self.waiting[name]
        if operation and count < operation.baseline then
            operation.baseline = count
        end

        if operation and not operation.autoDeliver and operation.state ~= "QUEUE"
            and operation.state ~= "ERROR" and operation.state ~= "DONE"
        then
            local appeared = math.max(0, count - positiveInteger(operation.baseline))
            operation.remaining = math.max(0, positiveInteger(operation.requested) - appeared)
            if operation.remaining == 0 then
                operation.state = "DONE"
                self.itemStates[name] = "DONE"
            end
        end
    end
    return true
end

function Checklist:availableStock(name)
    return math.max(0,
        positiveInteger(self.stock[name])
        - positiveInteger(self.queuedOutgoing[name])
        - positiveInteger(self.outboundUnobserved[name])
        - positiveInteger((self.waiting[name] or {}).deliveryQueued))
end

function Checklist:autoDeliveryReserved(name)
    local operation = self.waiting[name]
    if operation and operation.autoDeliver then
        return positiveInteger(operation.remaining)
    end
    return 0
end

function Checklist:remainingUnplanned(item)
    return math.max(0,
        positiveInteger(item.count)
        - positiveInteger(self.sent[item.name])
        - positiveInteger(self.sendRemaining[item.name])
        - self:autoDeliveryReserved(item.name))
end

function Checklist:combinedMissing(item)
    return math.max(0,
        positiveInteger(item.count)
        - positiveInteger(self.sent[item.name])
        - positiveInteger(self.queuedOutgoing[item.name])
        - self:availableStock(item.name)
        - self:autoDeliveryReserved(item.name))
end

function Checklist:craftOnlyMissing(item)
    return math.max(0, positiveInteger(item.count) - self:availableStock(item.name))
end

function Checklist:queueRecipeChecks()
    self.recipeQueue = {}
    self.recipeQueueIndex = 1
    self.recipeQueued = {}

    for _, item in ipairs(self.items or {}) do
        if not self.recipeCache[item.name] and not self.recipeQueued[item.name] then
            self.recipeQueue[#self.recipeQueue + 1] = item.name
            self.recipeQueued[item.name] = true
        end
    end
end

-- meta() costs no call budget. A new recipe snapshot drops what was known.
function Checklist:syncRecipeGeneration()
    if not self:connected() then return false end
    if not self.routes:available() then
        self.recipeLibraryError = "no recipes API (Recipe Atlas)"
        return false
    end
    local ok, meta = pcall(self.routes.api.meta)
    if not ok or type(meta) ~= "table" or meta.ready ~= true then
        self.recipeLibraryError = ok and "not_ready" or tostring(meta)
        return false
    end

    local generation = tonumber(meta.generation) or 0
    if self.recipeGeneration ~= generation then
        if self.recipeGeneration ~= nil then self.rawShortages = {} end
        self.recipeGeneration = generation
        self.recipeCache = {}
        self.recipeLibraryError = nil
        if self.loaded then
            self:queueRecipeChecks()
        end
    end
    return true
end

function Checklist:recipesReloaded()
    if not self:connected() then return end
    self.recipeGeneration = nil
    self.recipeCache = {}
    self.recipeLibraryError = nil
    self:syncRecipeGeneration()
    self:queueRecipeChecks()
end

-- Up to `limit` items in one routes() call (+ one producers() call per
-- item that is not for a turtle). Busy server: the rest waits for the next scan.
function Checklist:checkRecipes(limit)
    if not self:connected() or not self.loaded
        or self.recipeQueueIndex > #self.recipeQueue
        or not self:syncRecipeGeneration() then
        return 0
    end

    local session = self.sessionToken
    local names = {}
    local last = math.min(#self.recipeQueue, self.recipeQueueIndex + math.max(1, positiveInteger(limit)) - 1)
    for i = self.recipeQueueIndex, last do names[#names + 1] = self.recipeQueue[i] end
    local ok, found = pcall(self.routes.lookup, self.routes, names)
    if session ~= self.sessionToken then return 0 end
    if not ok then
        self.recipeLibraryError = tostring(found)
        return 0
    end

    local checked = 0
    for _, name in ipairs(names) do
        local entry = found[name]
        if not entry or entry.later then
            self.recipeLibraryError = "recipe server busy"
            break
        end
        self.recipeCache[name] = {craftable = Routes.craftable(entry), kind = entry.kind, detail = entry.detail}
        self.recipeQueued[name] = nil
        self.recipeQueueIndex = self.recipeQueueIndex + 1
        checked = checked + 1
    end

    if self.recipeQueueIndex > #self.recipeQueue then
        self.recipeLibraryError = nil
    end
    return checked
end

function Checklist:recipeInfo(name)
    return self.recipeCache[tostring(name or "")]
end

function Checklist:nextKey(kind)
    self.sequence = self.sequence + 1
    return table.concat({
        tostring(self.sessionToken or "checklist"),
        tostring(kind),
        tostring(self.sequence),
    }, ":")
end

function Checklist:descriptor(kind, name, count, job, extra)
    local key = self:nextKey(kind)
    job = job or {}
    job.key = job.key or key
    local metadata = {
        token = self.sessionToken,
        kind = kind,
        name = name,
        count = count,
        key = key,
    }

    for field, value in pairs(extra or {}) do
        metadata[field] = value
    end

    return {
        key = key,
        label = "CHECKLIST " .. string.upper(kind),
        job = job,
        checklist = metadata,
    }
end

function Checklist:shipmentLimit(name)
    return math.min(256, self.shipping:batchLimit(name))
end

function Checklist:stockDescriptor(kind, name, count, extra)
    -- A ticker order; the orderer checks the stock right before it and
    -- ships only what is there (app.orderer).
    return self:descriptor(kind, name, count, {
        mode = "stock_ticker",
        checklistShipment = true,
        address = self:address(),
        requests = {{name = name, count = count}},
    }, extra)
end

function Checklist:sendAvailable(selectedName)
    if not self:connected() then
        return nil, "clipboard disconnected"
    end
    if self:address() == "" then
        return nil, "checklist address missing"
    end

    if not self.stockReady then return nil, "waiting for stock snapshot" end
    local orders = {}
    for _, item in ipairs(self.items) do
        if not selectedName or item.name == selectedName then
            self.sendErrors[item.name] = nil
            local remaining = self:remainingUnplanned(item)
            local batchLimit = self:shipmentLimit(item.name)
            local available = batchLimit > 0 and math.min(remaining, self:availableStock(item.name)) or 0

            while available > 0 do
                local count = math.min(batchLimit, available)
                orders[#orders + 1] = self:stockDescriptor("send", item.name, count)
                self.sendRemaining[item.name] = positiveInteger(self.sendRemaining[item.name]) + count
                self.queuedOutgoing[item.name] = positiveInteger(self.queuedOutgoing[item.name]) + count
                available = available - count
            end

            if positiveInteger(self.queuedOutgoing[item.name]) > 0 then
                self.itemStates[item.name] = "QUEUE"
            end
        end
    end

    self.lastError = nil
    return orders
end

function Checklist:craftMissing(selectedName, autoDeliver)
    if not self:connected() then
        return nil, "clipboard disconnected"
    end
    if not self.stockReady then return nil, "waiting for stock snapshot" end
    autoDeliver = autoDeliver == true
    if autoDeliver and self:address() == "" then
        return nil, "checklist address missing"
    end

    local orders = {}
    for _, item in ipairs(self.items) do
        if not selectedName or item.name == selectedName then
            local operation = self.waiting[item.name]
            if operation and (operation.state == "ERROR" or operation.state == "DONE" or operation.state == "SENT") then
                self.requestToItem[operation.requestId] = nil
                self.waiting[item.name] = nil
                operation = nil
            elseif operation and autoDeliver then
                operation.autoDeliver = true
            end

            local recipe = self:recipeInfo(item.name)
            if selectedName then
                -- An explicit row CRAFT retries a known shortage.
                self.rawShortages[item.name] = nil
            end
            local blocked = self.rawShortages[item.name] ~= nil and not operation
            if blocked then
                -- Bulk actions skip crafts known to need material no turtle can make.
                self.pendingCrafts[item.name] = nil
            elseif not operation and not recipe then
                local missing = autoDeliver and self:combinedMissing(item) or self:craftOnlyMissing(item)
                if missing > 0 then
                    local pending = self.pendingCrafts[item.name]
                    self.pendingCrafts[item.name] = {
                        autoDeliver = autoDeliver or (pending and pending.autoDeliver) or false,
                    }
                end
            else
                self.pendingCrafts[item.name] = nil
            end
            if not operation and not blocked and recipe and recipe.craftable then
                local currentStock = self:availableStock(item.name)
                local missing = autoDeliver and self:combinedMissing(item) or self:craftOnlyMissing(item)

                if missing > 0 then
                    local key = self:nextKey("craft")
                    local requestId = key .. ":request"
                    self.waiting[item.name] = {
                        name = item.name,
                        requested = missing,
                        remaining = missing,
                        baseline = currentStock,
                        deliveryQueued = 0,
                        requestId = requestId,
                        autoDeliver = autoDeliver,
                        state = "QUEUE",
                    }
                    self.requestToItem[requestId] = item.name
                    self.itemStates[item.name] = "QUEUE"
                    orders[#orders + 1] = {
                        key = key,
                        label = "CHECKLIST CRAFT",
                        job = {
                            key = key,
                            mode = "turtle_crafter",
                            target = item.name,
                            outputCount = missing,
                            requestId = requestId,
                        },
                        checklist = {
                            token = self.sessionToken,
                            kind = "craft",
                            name = item.name,
                            count = missing,
                            key = key,
                            requestId = requestId,
                        },
                    }
                end
            end
        end
    end

    self.lastError = nil
    return orders
end

function Checklist:craftAndSend(selectedName)
    if self:address() == "" then
        return nil, "checklist address missing"
    end

    local sendOrders, sendError = self:sendAvailable(selectedName)
    if not sendOrders then
        return nil, sendError
    end

    local craftOrders, craftError = self:craftMissing(selectedName, true)
    if not craftOrders then
        return nil, craftError
    end

    for _, order in ipairs(craftOrders) do
        sendOrders[#sendOrders + 1] = order
    end
    return sendOrders
end

function Checklist:deliveryOrders()
    if not self:connected() or self:address() == "" then
        return {}
    end

    local orders = {}
    -- Resume the user's one-shot action as recipe checks finish. Never repeat
    -- accepted crafts, and never convert craft-only requests into deliveries.
    for _, item in ipairs(self.items) do
        local pending = self.pendingCrafts[item.name]
        if pending and self:recipeInfo(item.name) then
            local deferred = self:craftMissing(item.name, pending.autoDeliver)
            for _, order in ipairs(deferred or {}) do orders[#orders + 1] = order end
        end
        local remaining = math.max(0, positiveInteger(self.sendRemaining[item.name])
            - positiveInteger(self.queuedOutgoing[item.name]))
        local batchLimit = self:shipmentLimit(item.name)
        local available = (self.sendErrors[item.name] or batchLimit == 0) and 0
            or math.min(remaining, self:availableStock(item.name))
        while available > 0 do
            local count = math.min(batchLimit, available)
            orders[#orders + 1] = self:stockDescriptor("send", item.name, count)
            self.queuedOutgoing[item.name] = positiveInteger(self.queuedOutgoing[item.name]) + count
            available = available - count
        end
    end
    local names = {}
    for name in pairs(self.waiting) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local operation = self.waiting[name]
        if operation and operation.autoDeliver and operation.state ~= "QUEUE" and operation.state ~= "ERROR" then
            local initialPending = math.max(0, positiveInteger(self.sendRemaining[name])
                - positiveInteger(self.queuedOutgoing[name]))
            local appeared = math.max(0, self:availableStock(name)
                - positiveInteger(operation.baseline) - initialPending)
            local batchLimit = self:shipmentLimit(name)
            local ready = batchLimit > 0 and math.max(0,
                math.min(positiveInteger(operation.remaining) - positiveInteger(operation.deliveryQueued), appeared)) or 0

            while ready > 0 do
                local count = math.min(batchLimit, ready)
                orders[#orders + 1] = self:stockDescriptor("deliver", name, count, {
                    requestId = operation.requestId,
                    observedStock = positiveInteger(self.stock[name]),
                })
                operation.deliveryQueued = positiveInteger(operation.deliveryQueued) + count
                ready = ready - count
            end

            if operation.deliveryQueued > 0 then
                operation.state = "DELIVERY"
                self.itemStates[name] = "DELIVERY"
            end
        end
    end

    return orders
end

local function movedCount(result, expected)
    local moved = tonumber(result)
    if moved == nil then
        moved = 0
    end
    return math.max(0, math.min(positiveInteger(expected), positiveInteger(moved)))
end

function Checklist:onOrderResult(metadata, ok, result, err)
    if type(metadata) ~= "table" or metadata.token ~= self.sessionToken then
        return false
    end

    local name = metadata.name
    local expected = positiveInteger(metadata.count)

    if metadata.kind == "craft" then
        local operation = self.waiting[name]
        if operation and operation.requestId == metadata.requestId then
            if operation.state ~= "SENT" and operation.state ~= "DONE" then
                operation.state = ok and "CRAFTING" or "ERROR"
            end
            operation.error = ok and nil or tostring(err or "craft dispatch failed")
            self.itemStates[name] = operation.state
        end
    elseif metadata.kind == "send" then
        self.queuedOutgoing[name] = math.max(0, positiveInteger(self.queuedOutgoing[name]) - expected)
        if ok then
            local moved = movedCount(result, expected)
            self.sendRemaining[name] = math.max(0, positiveInteger(self.sendRemaining[name]) - moved)
            self.sendErrors[name] = nil
            self.sent[name] = positiveInteger(self.sent[name]) + moved
            self.outboundUnobserved[name] = positiveInteger(self.outboundUnobserved[name]) + moved
            local operation = self.waiting[name]
            if operation then
                operation.baseline = math.max(0, positiveInteger(operation.baseline) - moved)
            end
            self.itemStates[name] = moved >= expected and "SENT" or "PARTIAL"
        else
            self.sendErrors[name] = tostring(err or "send failed")
            self.itemStates[name] = "ERROR"
        end
    elseif metadata.kind == "deliver" then
        local operation = self.waiting[name]
        if operation and operation.requestId == metadata.requestId then
            operation.deliveryQueued = math.max(0, positiveInteger(operation.deliveryQueued) - expected)
            if ok then
                local moved = movedCount(result, expected)
                self.sent[name] = positiveInteger(self.sent[name]) + moved
                self.outboundUnobserved[name] = positiveInteger(self.outboundUnobserved[name]) + moved
                operation.baseline = math.max(0, positiveInteger(operation.baseline) - moved)
                operation.remaining = math.max(0, positiveInteger(operation.remaining) - moved)
                operation.state = operation.remaining == 0 and "SENT" or "WAITING"
                self.itemStates[name] = operation.state
            else
                -- A failed peripheral call may already have triggered a request.
                -- Do not automatically replay an outcome we cannot confirm.
                operation.state = "ERROR"
                operation.error = tostring(err or "delivery failed")
                self.itemStates[name] = "ERROR"
            end
        end
    end

    logEvent(self.logger, ok and "info" or "error", "checklist.order_result", {
        session = self.sessionToken, key = metadata.key, kind = metadata.kind, item = name,
        expected = expected, reported = result, sent = positiveInteger(self.sent[name]),
        sendRemaining = positiveInteger(self.sendRemaining[name]),
        craftRemaining = positiveInteger((self.waiting[name] or {}).remaining),
        error = not ok and tostring(err) or nil,
    })
    if not ok then
        self.lastError = tostring(err or "checklist order failed")
    else
        self.lastError = nil
    end
    return true
end

function Checklist:onControllerState(requestId, state, detail, failure)
    local name = self.requestToItem[tostring(requestId or "")]
    local operation = name and self.waiting[name] or nil
    if not operation then
        return false
    end
    local shortage = state == "rejected" and Util.rawShortage({failure = failure, error = detail}, self.hints) or nil
    if shortage then
        shortage.at = nowSeconds()
        -- `needed` is the deficit beyond the stock the failed plan already used.
        shortage.baseStock = positiveInteger((self.lastCounts or {})[shortage.raw])
        self.rawShortages[name] = shortage
        logEvent(self.logger, "info", "checklist.needs_raw", {
            item = name, raw = shortage.raw, needed = shortage.needed, hint = shortage.hint,
        })
    end

    if state == "accepted" or state == "completed" then
        if operation.remaining == 0 then
            operation.state = operation.autoDeliver and "SENT" or "DONE"
        elseif operation.state ~= "SENT" and operation.state ~= "DONE" then
            operation.state = "WAITING"
        end
        operation.error = nil
        self.itemStates[name] = operation.state
        self.lastError = nil
    elseif state == "rejected" then
        operation.state = "ERROR"
        operation.error = tostring(detail or "craft rejected")
        self.itemStates[name] = "ERROR"
        self.lastError = operation.error
    end
    return true
end

function Checklist:snapshot()
    local rows = {}
    local anySend = false
    local anyCraft = false
    local checkingCount = 0
    local needs, needsByRaw = {}, {}
    for _, item in ipairs(self.items) do
        local stock = self:availableStock(item.name)
        local sent = positiveInteger(self.sent[item.name])
        local operation = self.waiting[item.name]
        local missing = self:combinedMissing(item)
        local craftMissing = self:craftOnlyMissing(item)
        local queued = positiveInteger(self.queuedOutgoing[item.name])
        local recipe = self:recipeInfo(item.name)
        local craftable = recipe and recipe.craftable == true
        local busy = operation and operation.state ~= "ERROR" and operation.state ~= "DONE"
            and operation.state ~= "SENT"
        local state
        local note
        local shortage = not busy and craftMissing > 0 and self.rawShortages[item.name] or nil

        if shortage then
            state = "NEEDS"
            note = shortage.raw == item.name and "no turtle recipe"
                or ("needs " .. shortage.raw .. " x" .. shortage.needed)
            local entry = needsByRaw[shortage.raw]
            if not entry then
                entry = {name = shortage.raw, count = 0, hint = shortage.hint}
                needsByRaw[shortage.raw] = entry
                needs[#needs + 1] = entry
            end
            entry.count = entry.count + shortage.needed
        elseif operation and operation.state == "ERROR" then
            state = "ERROR"
            note = tostring(operation.error or "craft failed")
        elseif busy then
            state = operation.state
            note = "waiting " .. tostring(operation.remaining)
        elseif self.itemStates[item.name] == "ERROR" then
            state = "ERROR"
            note = tostring(self.lastError or "send failed")
        elseif queued > 0 then
            state = "QUEUE"
            note = "queued " .. tostring(queued)
        elseif sent >= positiveInteger(item.count) then
            state = "SENT"
            note = "complete"
        elseif craftMissing > 0 and recipe and recipe.error then
            state = "CHECK_ERROR"
            note = tostring(recipe.error)
        elseif craftMissing > 0 and recipe and not craftable then
            state = "NO_RECIPE"
            note = recipe.kind and Routes.describe(recipe) or "no turtle recipe"
        elseif craftMissing > 0 and not recipe then
            state = "CHECKING"
            note = "checking recipe"
            checkingCount = checkingCount + 1
        elseif missing == 0 then
            state = sent >= positiveInteger(item.count) and "SENT" or "READY"
            note = "complete"
        elseif stock > 0 or sent > 0 then
            state = "PARTIAL"
            note = "remaining " .. tostring(missing)
        else
            state = "MISSING"
            note = "remaining " .. tostring(missing)
        end

        if state == "SENT" then
            state, note = "REQUESTED", "request submitted; receipt not confirmed"
        elseif stock > 0 and self:shipmentLimit(item.name) == 0 and not busy then
            state, note = "STACK_INFO", "waiting for actual stack limit"
        end
        local canSend = self:connected() and self.stockReady and self:address() ~= ""
            and self:shipmentLimit(item.name) > 0
            and (self:remainingUnplanned(item) > 0 or self.sendErrors[item.name] ~= nil) and stock > 0
        local canCraft = self:connected() and self.stockReady and craftable == true and craftMissing > 0 and not busy
        anySend = anySend or canSend
        anyCraft = anyCraft or (canCraft and not shortage)

        rows[#rows + 1] = {
            name = item.name,
            displayName = item.displayName,
            needed = item.count,
            stock = stock,
            remaining = missing,
            missing = craftMissing,
            state = state,
            note = note,
            canSend = canSend,
            canCraft = canCraft,
            needs = shortage and shortage.raw or nil,
        }
    end
    table.sort(needs, function(left, right) return left.name < right.name end)

    return {
        visible = self:visible(),
        address = self:address(),
        rows = rows,
        checkingCount = checkingCount,
        needs = needs,
        error = self.lastError,
        recipeError = self.recipeLibraryError,
        sendEnabled = self:connected() and self:address() ~= "" and anySend,
        craftEnabled = self:connected() and anyCraft,
        craftSendEnabled = self:connected() and self:address() ~= "" and (anySend or anyCraft),
    }
end

return Checklist

