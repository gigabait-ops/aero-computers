local Bus = require("app.bus")
local Peripherals = require("app.peripherals")
local Requests = require("app.requests")
local Util = require("app.util")

local Orderer = {}
Orderer.__index = Orderer

local function logEvent(logger, level, event, fields)
    if logger and type(logger[level]) == "function" then
        pcall(logger[level], logger, event, fields or {})
    end
end

local cachedModems
local function openRednet(rednetApi)
    rednetApi = rednetApi or rednet

    if not rednetApi or type(rednetApi.send) ~= "function" then
        return nil, "rednet missing"
    end

    if type(rednetApi.open) ~= "function" then
        return rednetApi, nil, {}
    end

    local modems = {}
    local names = cachedModems or Peripherals.names()
    for _, name in ipairs(names) do
        if cachedModems or Peripherals.hasType(name, "modem") or Peripherals.hasMethod(name, "transmit") then
            local okOpen, isOpen = pcall(function()
                return type(rednetApi.isOpen) == "function" and rednetApi.isOpen(name) or false
            end)

            if not (okOpen and isOpen) then
                pcall(rednetApi.open, name)
            end

            local verified = type(rednetApi.isOpen) ~= "function"
            if not verified then
                local okVerify, open = pcall(rednetApi.isOpen, name)
                verified = okVerify and open == true
            end

            if verified then
                table.insert(modems, name)
            end
        end
    end

    cachedModems = modems
    if #modems == 0 then
        return nil, "modem missing"
    end

    return rednetApi, nil, modems
end

function Orderer:new(options)
    cachedModems = nil
    return setmetatable({
        options = options or {},
        pendingControllerCommands = {}
    }, self)
end

function Orderer:now()
    return type(self.options.now) == "function" and self.options.now() or Util.nowSeconds()
end

function Orderer:controllerRetryDelay(attempts)
    local turtleConfig = self.options.turtle or {}
    local initial = math.max(0.25, tonumber(turtleConfig.controllerRetrySeconds) or 2)
    local maximum = math.max(initial, tonumber(turtleConfig.controllerRetryMaxSeconds) or 30)
    local exponent = math.max(0, math.min(4, (tonumber(attempts) or 1) - 1))

    return math.min(maximum, initial * (2 ^ exponent))
end

function Orderer:sendPendingControllerCommand(entry, reason)
    entry.attempts = (tonumber(entry.attempts) or 0) + 1
    entry.lastAttemptAt = self:now()
    entry.nextRetryAt = entry.lastAttemptAt + (entry.accepted and 5 or self:controllerRetryDelay(entry.attempts))
    local rednetApi, rednetErr, modems = openRednet(self.options.rednet)

    if not rednetApi then
        return false, rednetErr
    end

    local controller = self:turtleController(rednetApi)
    if controller then
        entry.controller = controller
    elseif not entry.controller then
        return false, "craft controller not found"
    end

    local message = entry.accepted and {type = "query", id = entry.id} or entry.message
    local ok, sent = pcall(rednetApi.send, entry.controller, message, entry.protocol)
    local delivered = ok and sent ~= false
    local fields = {
        requestId = entry.id,
        controller = entry.controller,
        target = entry.message.target,
        count = entry.message.count,
        attempts = entry.attempts,
        modems = table.concat(modems or {}, ","),
        hostname = entry.hostname,
        reason = reason or "send"
    }

    if delivered then
        -- An accepted request is only asked about every 5 s: not logged, it
        -- filled the log in 3 minutes (owner 2026-11-08).
        if not entry.accepted then logEvent(self.options.logger, "info", "controller.command_sent", fields) end
        return true
    end

    fields.error = ok and "rednet.send returned false" or tostring(sent)
    logEvent(self.options.logger, "error", "controller.command_retry", fields)
    return false, fields.error
end

function Orderer:retryPendingControllerCommands(now)
    now = tonumber(now) or self:now()
    local retried = 0

    for _, id in ipairs(Util.sortedKeys(self.pendingControllerCommands)) do
        local entry = self.pendingControllerCommands[id]

        if entry and now >= (tonumber(entry.nextRetryAt) or 0) then
            self:sendPendingControllerCommand(entry, "ack timeout")
            retried = retried + 1
        end
    end

    return retried
end

function Orderer:nextControllerRetryAt()
    local nextRetry = nil

    for _, entry in pairs(self.pendingControllerCommands or {}) do
        local at = tonumber(entry.nextRetryAt) or 0
        nextRetry = nextRetry and math.min(nextRetry, at) or at
    end

    return nextRetry
end

function Orderer:handleControllerMessage(sender, message, protocol)
    if type(message) ~= "table" then
        return false
    end

    local id = tostring(message.id or "")
    local pending = self.pendingControllerCommands[id]

    if not pending or tonumber(sender) ~= tonumber(pending.controller) or protocol ~= pending.protocol then
        return false
    end

    if message.type == "accepted" then
        pending.accepted = true
        pending.nextRetryAt = self:now() + 5
        logEvent(self.options.logger, "info", "controller.command_accepted", {
            requestId = id,
            controller = pending.controller,
            target = pending.message.target,
            count = pending.message.count,
            attempts = pending.attempts
        })
        return true, "accepted", id, id
    end

    if message.type == "rejected" then
        self.pendingControllerCommands[id] = nil
        local err = tostring(message.error or "controller rejected request")
        logEvent(self.options.logger, "error", "controller.command_rejected", {
            requestId = id,
            controller = pending.controller,
            target = pending.message.target,
            error = err
        })
        return true, "rejected", err, id
    end

    if message.type == "status" then
        if message.state ~= "DONE" and message.state ~= "FAILED" and message.state ~= "ERROR"
            and message.state ~= "CANCELLED" and message.state ~= "REJECTED" then
            pending.accepted = true
            pending.nextRetryAt = self:now() + 5
            return true, "accepted", id, id
        end
        self.pendingControllerCommands[id] = nil
        if message.state == "DONE" and message.ok ~= false then
            return true, "completed", id, id, nil, pending.message.target
        end
        local failure = type(message.failure) == "table" and message.failure or nil
        return true, "rejected", tostring(message.error or (failure and failure.message)
            or message.state or "craft failed"), id, failure, pending.message.target,
            tonumber(message.craftedOutput) or 0
    end

    return false
end

function Orderer:turtleController(rednetApi)
    local turtleConfig = self.options.turtle or {}
    local protocol = turtleConfig.protocol or "gigabait.craft.request.v1"
    local hostname = turtleConfig.controllerHostname or "craft-controller"

    if not rednetApi or type(rednetApi.lookup) ~= "function" then
        return nil, turtleConfig, "rednet.lookup missing"
    end

    local now = self:now()
    if self.controllerLookupAt and now < self.controllerLookupAt then
        return self.cachedController, turtleConfig, "craft controller not found"
    end
    self.controllerLookupAt = now + 10
    local ok, controller = pcall(rednetApi.lookup, protocol, hostname)
    controller = ok and tonumber(controller) or nil
    self.cachedController = controller
    if not controller then
        return nil, turtleConfig, "craft controller " .. tostring(hostname) .. " not found"
    end

    return controller, turtleConfig
end

function Orderer:sendTurtleCommand(job)
    local rednetApi, rednetErr = openRednet(self.options.rednet)

    if not rednetApi then
        return false, rednetErr
    end

    local controller, turtleConfig, controllerError = self:turtleController(rednetApi)

    if not controller then
        return false, controllerError
    end

    if type(job.target) ~= "string" or job.target == "" then
        return false, "turtle target missing"
    end

    local outputCount = Requests.requestCount(job.outputCount)
    local message = {
        type = "craft",
        id = job.requestId,
        target = job.target,
        count = outputCount,
        -- A rule from a station file goes to that station (mechanical, saw,
        -- slicer); always: as much as there is something to make it from.
        kind = job.station,
        all = job.always == true or nil,
        from = job.from,
        keep = job.keep,
    }

    local protocol = turtleConfig.protocol or "gigabait.craft.request.v1"
    local hostname = turtleConfig.controllerHostname or "craft-controller"
    local id = tostring(message.id or "")

    if id == "" then
        return false, "turtle request id missing"
    end

    local entry = {
        id = id,
        controller = controller,
        hostname = hostname,
        protocol = protocol,
        message = message,
        attempts = 0,
        nextRetryAt = self:now()
    }
    self.pendingControllerCommands[id] = entry
    self:sendPendingControllerCommand(entry, "initial")

    return true, nil, controller, outputCount
end

function Orderer:orderWithTurtleCrafter(job)
    local ok, err, controller, outputCount = self:sendTurtleCommand(job)

    if not ok then
        return false, err
    end

    return true, nil, outputCount, "controller " .. tostring(controller) .. " craft " .. tostring(outputCount)
end

-- One fresh stock read: item -> count over all its variants.
local function stockCounts(ticker)
    local ok, stock = pcall(ticker.stock, false)
    if not ok then return nil, tostring(stock) end
    if type(stock) ~= "table" then return nil, "invalid stock snapshot" end
    local counts = {}
    for _, stack in pairs(stock) do
        if type(stack) == "table" and type(stack.name) == "string" then
            local count = tonumber(stack.count)
            if count and count >= 0 and count < math.huge then
                counts[stack.name] = (counts[stack.name] or 0) + math.floor(count)
            end
        end
    end
    return counts
end

-- A strict order ships whole or not at all; the ticker has no such mode
-- (it orders what it finds), so the stock is checked right before it: a
-- recipe waits until every entry is there.
-- Returns the requests to order, or nil and why it waits.
local function strictRequests(ticker, requests)
    local counts, err = stockCounts(ticker)
    if not counts then return nil, err end
    local needed, order = {}, {}
    for _, entry in ipairs(requests) do
        if not needed[entry.name] then order[#order + 1] = entry.name end
        needed[entry.name] = (needed[entry.name] or 0) + Requests.requestCount(entry.count)
    end
    for _, name in ipairs(order) do
        if (counts[name] or 0) < needed[name] then
            return nil, "waiting for stock: " .. name .. " " .. tostring(counts[name] or 0)
                .. "/" .. tostring(needed[name])
        end
    end
    return requests
end

-- Every PC46 order: one requestFiltered call on the shared Stock Ticker.
-- The ticker answers with what it accepted from a one-tick stock summary;
-- whether Create then drops the order (10 or more packages already queued
-- at the source packager) it never says, hence PC48's order gate (app.shipping).
function Orderer:orderWithStockTicker(job, registry)
    local source = Bus.ticker(registry)
    local ticker = source and source.device

    if not ticker or type(ticker.requestFiltered) ~= "function" then
        return false, "stock ticker missing"
    end

    local requests = job.requests or Requests.normalize(job)

    if job.strict then
        if type(ticker.stock) ~= "function" then return false, "stock ticker missing" end
        local checked, why = strictRequests(ticker, requests)
        if not checked then return false, why end
        requests = checked
    end

    local filters, buildErr, total = Requests.tickerFilters(requests)

    if not filters then
        return false, buildErr
    end

    local ok, accepted = pcall(ticker.requestFiltered, job.address or "", table.unpack(filters))

    if not ok then
        return false, tostring(accepted)
    end

    if type(accepted) ~= "number" or accepted < 0 or accepted > total or accepted ~= math.floor(accepted) then
        return false, "invalid Stock Ticker request count"
    end

    logEvent(self.options.logger, accepted < total and "warn" or "info", "ticker.order_sent", {
        key = job.key, address = job.address, ticker = source.name, filters = #filters,
        requested = total, accepted = accepted, items = Requests.details(requests),
    })

    return true, nil, accepted, Requests.details(requests)
end

-- A craft rule goes to PC48; everything else is a Stock Ticker order.
function Orderer:order(job, registry)
    if job.mode == "turtle_crafter" then
        return self:orderWithTurtleCrafter(job)
    end

    return self:orderWithStockTicker(job, registry or {})
end

function Orderer:invalidateNetwork()
    cachedModems = nil
    self.controllerLookupAt = nil
end

function Orderer:hasActiveTarget(target)
    for _, entry in pairs(self.pendingControllerCommands) do
        if entry.message.target == target then return true end
    end
    return false
end

return Orderer

