local ItemFacts = require("autocrafter.item_facts")
local Util = require("fleet_util")

local Supply = {}
Supply.__index = Supply

local amount, failure = Util.amount, Util.failure

local function mergeItem(counts, metadata, item)
    if type(item) ~= "table" or type(item.name) ~= "string" then
        return
    end
    counts[item.name] = amount(counts[item.name]) + amount(item.count or item.amount or item.quantity)
    metadata[item.name] = metadata[item.name] or {name = item.name, tags = {}}
    local maximum = tonumber(item.maxCount)
    if maximum and maximum >= 1 then
        metadata[item.name].maxCount = math.min(
            metadata[item.name].maxCount or maximum, maximum)
    end
    if item.nbt then metadata[item.name].hasNbt = true end
    if type(item.tags) == "table" then
        metadata[item.name] = metadata[item.name] or {name = item.name, tags = {}}
        for tag, enabled in pairs(item.tags) do
            if enabled then
                metadata[item.name].tags[tag] = true
            end
        end
    end
end

local function itemNames(items)
    local names = {}
    for _, item in pairs(items) do
        if type(item) == "table" and type(item.name) == "string" then names[#names + 1] = item.name end
    end
    return names
end

-- A listed stack plus the default facts of its item (stack limit, tags).
local function withFact(item, fact)
    return {name = item.name, count = item.count, nbt = item.nbt,
        maxCount = fact.maxCount, tags = fact.tags}
end

local function readInventory(device, countsOnly, facts)
    local counts = {}
    local metadata = {}
    local occupied = 0
    local sources = {}
    if not device or type(device.list) ~= "function" then
        return counts, metadata, "input inventory unavailable"
    end
    local ok, items = pcall(device.list)
    if not ok or type(items) ~= "table" then
        return counts, metadata, tostring(items)
    end
    local known = not countsOnly and facts and facts:lookup(itemNames(items)) or nil
    for slot, item in pairs(items) do
        if type(item) == "table" and amount(item.count) > 0 then
            occupied = occupied + 1
        end
        local detail = item
        -- Stacks with components keep their own detail read: their limit may differ.
        local fact = known and type(item) == "table" and item.nbt == nil and known[item.name]
        if fact then
            detail = withFact(item, fact)
        elseif not countsOnly and type(device.getItemDetail) == "function" then
            local detailOk, value = pcall(device.getItemDetail, slot)
            if detailOk and type(value) == "table" then
                detail = value
            end
        end
        mergeItem(counts, metadata, detail)
        sources[slot] = detail
    end
    return counts, metadata, nil, occupied, sources
end

local function readStock(device, facts)
    local counts = {}
    local metadata = {}
    if not device or type(device.stock) ~= "function" then
        return counts, metadata, "stock ticker unavailable"
    end
    -- The plain summary plus cached item facts replaces a detailed read of
    -- every stocked item; detailed stock is the fallback without facts.
    local ok, items = false, nil
    local known
    if facts and facts:ready() then
        ok, items = pcall(device.stock)
        known = ok and type(items) == "table" and facts:lookup(itemNames(items)) or nil
    end
    if not known then
        ok, items = pcall(device.stock, true)
        if not ok or type(items) ~= "table" then
            ok, items = pcall(device.stock)
        end
    end
    if not ok or type(items) ~= "table" then
        return counts, metadata, tostring(items)
    end
    for _, item in pairs(items) do
        local fact = known and type(item) == "table" and known[item.name]
        mergeItem(counts, metadata, fact and withFact(item, fact) or item)
    end
    return counts, metadata, nil, items
end

local function splitRequests(requests, maxEntries, maxCount)
    local pulses, batch, names = {}, {}, {}
    local function flush()
        if #batch > 0 then pulses[#pulses + 1] = batch; batch, names = {}, {} end
    end
    for _, request in ipairs(requests or {}) do
        local remaining = amount(request.count)
        while remaining > 0 do
            if #batch >= maxEntries or names[request.name] then flush() end
            local count = math.min(maxCount, remaining)
            batch[#batch + 1] = {name = request.name, count = count}
            names[request.name] = true
            remaining = remaining - count
        end
    end
    flush()
    return pulses
end

local function cumulativePulsePlan(plan, pulses, lastPulse)
    local totals = {}
    local names = {}
    for pulseIndex = 1, lastPulse do
        for _, request in ipairs(pulses[pulseIndex] or {}) do
            if totals[request.name] == nil then
                totals[request.name] = 0
                names[#names + 1] = request.name
            end
            totals[request.name] = totals[request.name] + amount(request.count)
        end
    end
    local requests = {}
    for _, name in ipairs(names) do
        requests[#requests + 1] = {name = name, count = totals[name]}
    end
    return {
        requests = requests,
        baselineLocal = plan.baselineLocal or {},
    }
end

local function describe(entries)
    local parts = {}
    for _, entry in ipairs(entries or {}) do
        parts[#parts + 1] = tostring(entry.name) .. " x" .. tostring(amount(entry.count))
    end
    return table.concat(parts, ", ")
end

-- Create packs one order into packages of nine stacks.
local function estimatePackages(entries)
    local stacks = 0
    for _, entry in ipairs(entries) do
        stacks = stacks + math.max(1, math.ceil(amount(entry.count) / 64))
    end
    return #entries > 0 and math.ceil(stacks / 9) or 0
end

function Supply.new(options)
    options = options or {}
    return setmetatable({
        input = options.input,
        stockTicker = options.stockTicker,
        -- The frogport address of this worker ("crafting_<id>").
        address = assert(options.address, "delivery address required"),
        maxEntries = math.max(1, amount(options.maxEntries or 9)),
        maxCount = math.max(1, amount(options.maxCount or 256)),
        deliveryMaxTimeout = tonumber(options.deliveryMaxTimeout) or 300,
        -- Seconds without a new item arriving before an order counts as lost.
        stockTickerDeliveryTimeout = tonumber(options.stockTickerDeliveryTimeout) or 300,
        pollSeconds = tonumber(options.pollSeconds) or 2,
        gate = options.gate,
        logger = options.logger,
        stallSeconds = math.max(1, tonumber(options.stallSeconds) or 30),
        maxReorders = math.max(0, amount(options.maxReorders or 2)),
        sleep = options.sleep or (os and os.sleep),
        -- false disables item facts (detail reads only); tests inject a fake.
        facts = options.facts == nil and ItemFacts.shared() or options.facts or nil,
        now = options.now or function()
            return os and os.epoch and os.epoch("utc") / 1000 or os.clock()
        end,
    }, Supply)
end

function Supply:log(event, fields)
    Util.log(self.logger, event, fields)
end

function Supply:tickerUsable()
    return self.stockTicker ~= nil and type(self.stockTicker.requestFiltered) == "function"
end

-- What the warehouse holds of one item right now (all variants and the
-- component-free ones), for the delivery timeout log: stock there means the
-- order was dropped or went astray, none means another consumer took it.
function Supply:stockOf(name)
    if not self.stockTicker or type(self.stockTicker.stock) ~= "function" then return nil end
    local ok, items = pcall(self.stockTicker.stock)
    if not ok or type(items) ~= "table" then return nil end
    local total, plain = 0, 0
    for _, item in pairs(items) do
        if type(item) == "table" and item.name == name then
            total = total + amount(item.count)
            if item.nbt == nil then plain = plain + amount(item.count) end
        end
    end
    return total, plain
end

function Supply:snapshot(localOnly)
    local localCounts, localMetadata, localError, occupied, localItems = readInventory(self.input, false, self.facts)
    local stockCounts, stockMetadata, stockError, stockItems = {}, {}, nil, {}
    if not localOnly then
        stockCounts, stockMetadata, stockError, stockItems = readStock(self.stockTicker, self.facts)
    end
    if localError then
        return nil, failure("INPUT_UNAVAILABLE", localError)
    end
    if stockError then
        return nil, failure("STOCK_UNAVAILABLE", stockError)
    end
    for name, count in pairs(self.reserve or {}) do
        if stockCounts[name] then stockCounts[name] = math.max(0, stockCounts[name] - count) end
    end
    local sizeOk, inputSlots = pcall(self.input.size)
    if not sizeOk or amount(inputSlots) <= 0 then
        return nil, failure("INPUT_UNAVAILABLE", "input inventory size unavailable")
    end
    for name, count in pairs(localCounts) do
        stockCounts[name] = math.max(0, amount(stockCounts[name]) - amount(count))
    end
    local sources = {}
    for slot, item in pairs(localItems or {}) do
        local sourceSlot = slot
        sources[#sources + 1] = {
            item = item,
            read = function() return self.input.getItemDetail(sourceSlot) end,
        }
    end
    for slot, item in pairs(stockItems or {}) do
        local sourceSlot = slot
        sources[#sources + 1] = {
            item = item,
            read = type(self.stockTicker.getStockItemDetail) == "function"
                and function() return self.stockTicker.getStockItemDetail(sourceSlot) end or nil,
        }
    end
    return {
        recipeSources = sources,
        localCounts = localCounts,
        localMetadata = localMetadata,
        localStacks = localItems,
        stockCounts = stockCounts,
        stockMetadata = stockMetadata,
        inputSlots = amount(inputSlots),
        occupiedSlots = occupied,
    }
end

-- One Stock Ticker order for a whole pulse (2026-10-26: the requester is
-- retired). Filters in one call form one order, so Create packs them into
-- shared packages of nine stacks. requestFiltered answers one total from its
-- one-tick stock cache; when it is short, the stock read just after splits it
-- per item. Arrival tracking catches anything else (and a dropped order).
function Supply:sendTicker(entries)
    local filters, wanted = {}, 0
    for index, entry in ipairs(entries) do
        filters[index] = {name = entry.name, _requestCount = amount(entry.count)}
        wanted = wanted + amount(entry.count)
    end
    local ok, result = pcall(self.stockTicker.requestFiltered, self.address, table.unpack(filters))
    if not ok or type(result) ~= "number" or result < 0 or result % 1 ~= 0 or result > wanted then
        return nil, failure("STOCK_TICKER_REQUEST_FAILED",
            ok and "requestFiltered returned an invalid accepted count" or tostring(result))
    end
    local accepted = {}
    if result == wanted then
        for index, entry in ipairs(entries) do accepted[index] = amount(entry.count) end
        return accepted
    end
    -- Short: the ticker took what its stock summary had of each item. The
    -- items stay in storage until packed, so a read now still shows that.
    local stock = {}
    local readOk, items = pcall(self.stockTicker.stock)
    for _, item in pairs(readOk and type(items) == "table" and items or {}) do
        if type(item) == "table" and type(item.name) == "string" then
            stock[item.name] = amount(stock[item.name]) + amount(item.count)
        end
    end
    local left = result
    for index, entry in ipairs(entries) do
        local taken = math.min(amount(entry.count), left)
        if readOk then
            taken = math.min(taken, amount(stock[entry.name]))
            stock[entry.name] = amount(stock[entry.name]) - taken
        end
        accepted[index] = taken
        left = left - taken
    end
    for index, entry in ipairs(entries) do
        if left <= 0 then break end
        local more = math.min(left, amount(entry.count) - accepted[index])
        accepted[index], left = accepted[index] + more, left - more
    end
    return accepted
end

-- Returns accepted counts aligned with entries.
function Supply:dispatch(entries, active, reason)
    if not self:tickerUsable() then
        return nil, failure("STOCK_TICKER_UNAVAILABLE", "stock ticker unavailable")
    end
    local packages = estimatePackages(entries)
    local token, gateInfo
    if self.gate then
        if active then
            active.phase = "ORDER_WAIT"
            active.waitingFor = nil
        end
        token, gateInfo = self.gate:acquire(packages)
    end
    local accepted, sendError = self:sendTicker(entries)
    if self.gate then self.gate:release(token, sendError and 0 or packages) end

    local short = {}
    for index, entry in ipairs(accepted or {}) do
        if entry < amount(entries[index].count) then
            short[#short + 1] = tostring(entries[index].name) .. " " .. entry .. "/" .. amount(entries[index].count)
        end
    end
    self:log("worker.order", {
        assignment = active and active.assignment, reason = reason,
        ticker = describe(entries),
        short = #short > 0 and table.concat(short, ", ") or nil,
        packages = packages,
        gate = gateInfo and gateInfo.gate or nil,
        gateReason = gateInfo and gateInfo.reason or nil,
        waited = gateInfo and gateInfo.waited and math.floor(gateInfo.waited * 10 + 0.5) / 10 or nil,
        error = sendError and sendError.message or nil,
    })
    if not accepted then return nil, sendError end
    return accepted
end

local function deliveryStatus(plan, current)
    local receivedTotal = 0
    local expectedTotal = 0
    local missingName
    local missingCount
    for _, request in ipairs(plan.requests or {}) do
        local baseline = amount((plan.baselineLocal or {})[request.name])
        local requested = amount(request.count)
        local available = amount(current[request.name])
        local received = math.max(0, math.min(requested, available - baseline))
        receivedTotal = receivedTotal + received
        expectedTotal = expectedTotal + requested
        if not missingName and available < baseline + requested then
            missingName = request.name
            missingCount = baseline + requested - available
        end
    end
    return missingName == nil, missingName, missingCount, receivedTotal, expectedTotal
end

-- Ingredients of a plan with nothing received yet. Create drops a whole
-- request when a source packager is too busy, so a lost order shows up as an
-- ingredient that never started arriving; slow queued packages arrive partially.
local function untouchedItems(plan, current)
    local missing = {}
    for _, request in ipairs(plan.requests or {}) do
        local baseline = amount((plan.baselineLocal or {})[request.name])
        local requested = amount(request.count)
        if requested > 0 and amount(current[request.name]) <= baseline then
            missing[#missing + 1] = {name = request.name, count = requested}
        end
    end
    return missing
end

local function rounded(value)
    return math.floor((tonumber(value) or 0) * 10 + 0.5) / 10
end

-- Orders again what never started arriving. Returns false when nothing qualifies.
function Supply:reorder(plan, counts, active, checkpoint)
    local missing = untouchedItems(plan, counts)
    if #missing == 0 then return false end
    active.supply.reorders = amount(active.supply.reorders) + 1
    self:log("worker.delivery_stall", {
        assignment = active.assignment, missing = describe(missing),
        reorder = active.supply.reorders,
    })
    active.supply.uncertain = true
    checkpoint(active)
    local accepted = self:dispatch(missing, active, "reorder")
    active.supply.uncertain = false
    active.phase = "WAIT_DELIVERY"
    if accepted then
        for index, entry in ipairs(missing) do
            local shortfall = entry.count - accepted[index]
            if shortfall > 0 then
                -- The warehouse no longer holds it: replan once the rest arrived.
                active.supply.shortRequest = active.supply.shortRequest or {
                    name = entry.name, requested = entry.count, accepted = accepted[index],
                }
                for _, request in ipairs(plan.requests) do
                    if request.name == entry.name then
                        request.count = math.max(0, amount(request.count) - shortfall)
                        break
                    end
                end
            end
        end
    end
    -- A failed dispatch is not fatal here; the regular timeouts still apply.
    checkpoint(active)
    return true
end

function Supply:waitForDelivery(plan, active, checkpoint, heartbeat)
    active.supply = active.supply or {}
    local idleTimeout = self.stockTickerDeliveryTimeout
    local maximumTimeout = math.max(idleTimeout, self.deliveryMaxTimeout)
    local started = self.now()
    local orderedAt = started
    local lastProgressAt = started
    local bestReceived = -1
    while true do
        local observedAt = self.now()
        local counts, _, err = readInventory(self.input, true)
        if err then
            return nil, failure("INPUT_UNAVAILABLE", err)
        end
        local complete, name, missing, received, expected = deliveryStatus(plan, counts)
        if complete then
            active.waitingFor = nil
            self:log("worker.delivery", {
                assignment = active.assignment, seconds = rounded(observedAt - started),
                items = expected, reorders = active.supply.reorders,
            })
            return true
        end
        if received > bestReceived then
            bestReceived = received
            lastProgressAt = observedAt
        end
        local changed = active.phase ~= "WAIT_DELIVERY" or not active.waitingFor
            or active.waitingFor.name ~= name or active.waitingFor.missing ~= missing
        active.phase = "WAIT_DELIVERY"
        active.waitingFor = {name = name, missing = missing}
        if changed then checkpoint(active) end
        if heartbeat then
            heartbeat(active)
        end

        local stalled = observedAt - math.max(lastProgressAt, orderedAt) >= self.stallSeconds
        if stalled and amount(active.supply.reorders) < self.maxReorders
            and self:reorder(plan, counts, active, checkpoint) then
            orderedAt = self.now()
            lastProgressAt = orderedAt
        else
            local elapsed = observedAt - orderedAt
            local timeoutReason
            if elapsed >= maximumTimeout then
                timeoutReason = "maximum"
            elseif observedAt - lastProgressAt >= idleTimeout + (self.pollSeconds * 2) then
                timeoutReason = "idle"
            end
            if timeoutReason then
                local code = active.supply.uncertain and "DELIVERY_UNCERTAIN" or "DELIVERY_TIMEOUT"
                local inStock, plainInStock = self:stockOf(name)
                self:log("worker.delivery_timeout", {
                    assignment = active.assignment, name = name, missing = missing,
                    received = received, expected = expected, elapsed = rounded(elapsed),
                    reason = timeoutReason, reorders = active.supply.reorders,
                    inStock = inStock, plainInStock = plainInStock,
                })
                return nil, failure(code, "delivery did not reach input before timeout: missing "
                    .. tostring(name) .. " x" .. tostring(missing), {
                    waitingFor = active.waitingFor,
                    received = received,
                    expected = expected,
                    elapsed = elapsed,
                    timeoutReason = timeoutReason,
                    reorders = amount(active.supply.reorders),
                })
            end
        end
        if not self.sleep then
            break
        end
        self.sleep(self.pollSeconds)
    end
    local code = active.supply.uncertain and "DELIVERY_UNCERTAIN" or "DELIVERY_TIMEOUT"
    return nil, failure(code, "delivery did not reach input before timeout", {
        waitingFor = active.waitingFor,
        timeoutReason = "no_sleep",
    })
end

function Supply:deliver(plan, active, checkpoint, heartbeat)
    if #(plan.requests or {}) == 0 then
        return true
    end
    active.supply = active.supply or {nextPulse = 1, uncertain = false}
    local pulses = splitRequests(plan.requests, self.maxEntries, self.maxCount)

    local function shortRequestError()
        local short = active.supply.shortRequest
        if not short then return nil end
        return failure("STOCK_CHANGED", "stock changed before dispatch: " .. short.name, {
            name = short.name, requested = short.requested, accepted = short.accepted,
        })
    end

    local function waitForPendingPulse()
        local pendingPlan = active.supply.pendingPlan
        if not pendingPlan then
            local err = shortRequestError()
            if err then return nil, err end
            return true
        end
        local arrived, arrivalError = self:waitForDelivery(
            pendingPlan, active, checkpoint, heartbeat)
        if not arrived then
            return nil, arrivalError
        end
        active.supply.nextPulse = amount(active.supply.currentPulse) + 1
        active.supply.currentPulse = nil
        active.supply.pendingPlan = nil
        active.supply.uncertain = false
        active.supply.reorders = nil
        checkpoint(active)
        local err = shortRequestError()
        if err then return nil, err end
        return true
    end

    local pendingComplete, pendingError = waitForPendingPulse()
    if not pendingComplete then
        return nil, pendingError
    end

    for index = active.supply.nextPulse, #pulses do
        active.phase = "REQUESTING"
        active.supply.currentPulse = index
        active.supply.pendingPlan = cumulativePulsePlan(plan, pulses, index)
        active.supply.uncertain = true
        checkpoint(active)

        local accepted, sendError = self:dispatch(pulses[index], active,
            index == 1 and "initial" or "pulse")
        if not accepted then
            return nil, sendError
        end
        for entryIndex, taken in ipairs(accepted) do
            local requested = pulses[index][entryIndex]
            local missing = amount(requested.count) - amount(taken)
            if missing > 0 then
                active.supply.shortRequest = active.supply.shortRequest or {
                    name = requested.name, requested = requested.count, accepted = taken,
                }
                for _, entry in ipairs(active.supply.pendingPlan.requests) do
                    if entry.name == requested.name then
                        entry.count = math.max(0, entry.count - missing)
                        break
                    end
                end
            end
        end

        active.supply.uncertain = false
        checkpoint(active)
        if heartbeat then
            heartbeat(active)
        end

        pendingComplete, pendingError = waitForPendingPulse()
        if not pendingComplete then
            return nil, pendingError
        end
    end

    active.supply.complete = true
    active.supply.uncertain = false
    active.phase = "SUPPLIED"
    checkpoint(active)
    return true
end

Supply.splitRequests = splitRequests

return Supply
