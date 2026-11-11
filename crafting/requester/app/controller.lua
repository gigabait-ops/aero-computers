local Config = require("app.config")
local Notice = require("chat.notice")
local Cleaning = require("app.cleaning")
local Requests = require("app.requests")
local RouteHints = require("app.route_hints")
local Screens = require("app.screens")
local Shipping = require("app.shipping")
local Sorting = require("app.sorting")
local UI = require("ui")
local Util = require("app.util")

local Controller = {}
Controller.__index = Controller

local function logEvent(logger, level, event, fields)
    if logger and type(logger[level]) == "function" then
        pcall(logger[level], logger, event, fields or {})
    end
end

local function isCraft(item)
    return item.job.mode == "turtle_crafter"
end

-- lastQueueSent: when each rule last sent ("job:<key>"), for the per-rule
-- delay between its batches.
local function throttleKey(item)
    return "job:" .. tostring(item.key or "")
end

local function configureLogger(logger, model)
    if not logger then
        return
    end

    if type(logger.setEnabled) == "function" then
        pcall(logger.setEnabled, logger, model:get("logging.enabled", true) ~= false)
    end
    if type(logger.setLevel) == "function" then
        pcall(logger.setLevel, logger, model:get("logging.level", "info"))
    end
    if type(logger.setConsole) == "function" then
        pcall(logger.setConsole, logger, model:get("logging.console", false) == true)
    end
end

-- The crafter turtles' order gate on PC48 (fleet ROM), shared with PC46's
-- shipments.
local function warehouseGate(orderer)
    if type(rednet) ~= "table" or not orderer then
        return nil
    end
    local ok, OrderGate = pcall(require, "autocrafter.order_gate")
    if not ok then return nil end
    return OrderGate.new({
        rednet = rednet,
        protocol = "gigabait.autocrafter.worker.v1",
        workerId = "pc" .. tostring(os.getComputerID and os.getComputerID() or "46"),
        controllerId = function()
            return (orderer:turtleController(rednet))
        end,
    })
end

function Controller:new(deps)
    local shipping = Shipping:new()
    shipping:useGate(warehouseGate(deps.orderer))
    return setmetatable({
        shipping = shipping,
        config = deps.config,
        configLoader = deps.configLoader,
        logger = deps.logger,
        bus = deps.bus,
        reader = deps.reader,
        orderer = deps.orderer,
        cleaning = Cleaning:new(deps.config, deps.logger),
        hints = RouteHints.new(deps.config),
        term = deps.term,
        version = deps.version,
        now = deps.now or Util.nowSeconds,
        lastOrders = {},
        lastOrderCounts = {},
        lastAction = nil,
        lastError = nil,
        orderQueue = {},
        queuedKeys = {},
        requestSequence = 0,
        lastQueueKey = nil,
        lastQueueSent = {},
        rawBackoff = {},
        rawStreak = {},
        lastDevices = nil,
        lastSnapshot = nil,
        -- The screens (common.ui App): results as toasts, one question per screen.
        ui = nil,
        model = nil,
        toasts = {},
        confirms = {},
        confirmSeq = 0,
        cooperativeUi = false
    }, self)
end

local function cloneCounts(counts)
    local result = {}

    for name, count in pairs(counts or {}) do
        result[name] = tonumber(count) or 0
    end

    return result
end

local function reserveRequests(counts, requests)
    if type(counts) ~= "table" or type(requests) ~= "table" then
        return
    end

    for _, request in ipairs(requests) do
        local name = request and request.name
        local count = tonumber(request and request.count) or 0

        if type(name) == "string" and name ~= "" and count > 0 then
            counts[name] = math.max(0, (tonumber(counts[name]) or 0) - count)
        end
    end
end

local function reserveQueuedRequests(counts, queue)
    for _, item in ipairs(queue or {}) do
        reserveRequests(counts, ((item or {}).job or {}).requests)
    end
end

function Controller:applyConfig(raw)
    local model = Config:new(raw or {})
    local queuedKeys = {}

    for _, item in ipairs(self.orderQueue) do
        if item.key then
            queuedKeys[item.key] = true
        end
    end

    self.config = model
    self.queuedKeys = queuedKeys
    configureLogger(self.logger, model)

    if self.bus then
        self.bus.config = model.raw
        if self.bus.forget then self.bus:forget() end
    end

    self.hints = RouteHints.new(model)

    if self.orderer and self.orderer.options then
        self.orderer.options.turtle = model:get("turtle", {})
    end

    self.cleaning:configure(model)

    return model
end

function Controller:refreshConfig()
    local now = self.now()
    if now < (self.nextConfigCheck or 0) then return nil end
    self.nextConfigCheck = now + 10
    if not self.configLoader or type(self.configLoader.refreshLocal) ~= "function" then
        return nil
    end

    local result = self.configLoader:refreshLocal()

    if not result or result.ok == false then
        self.lastError = "config: " .. tostring(result and result.error or "reload failed")
        return result
    end

    if result.changed and result.raw then
        self:applyConfig(result.raw)
        self.lastAction = "config reloaded"
        logEvent(self.logger, "info", "config.reloaded", {
            queued = #self.orderQueue
        })
    end

    return result
end

function Controller:refreshUiSnapshot(now)
    if not self.lastSnapshot then
        return false
    end

    now = now or self.now()

    for _, row in ipairs(self.lastSnapshot.rows or {}) do
        if row.status == "WAIT" and row.cooldownEndsAt then
            local remaining = math.max(0, math.ceil((tonumber(row.cooldownEndsAt) or now) - now))
            row.reason = "cooldown " .. tostring(remaining) .. "s"
        end
    end

    self.lastSnapshot.queueCount = #self.orderQueue
    self.lastSnapshot.lastAction = self.lastAction
    self.lastSnapshot.lastError = self.lastError

    return self:render()
end

-- Screens --------------------------------------------------------------------------

local TOAST_SECONDS = 8
local QUESTION_SECONDS = 15

-- The screens show a new model at the UI loop's next tick.
function Controller:render()
    self.screensDirty = true
    return true
end

local function count(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end

-- What the screens draw (Screens.model turns it into records).
function Controller:screenSnapshot(now)
    local snapshot = self.lastSnapshot or {}
    local orderer = self.orderer or {}
    return {
        rows = snapshot.rows,
        stock = snapshot.stock,
        devices = self.lastDevices or snapshot.devices,
        cleaning = self.cleaning:snapshot(now),
        queueCount = #self.orderQueue,
        controller = {
            id = orderer.cachedController,
            open = count(orderer.pendingControllerCommands),
            hostname = self.config:get("turtle.controllerHostname", "craft-controller"),
            monitors = Screens.monitors(self.ui),
        },
        lastAction = self.lastAction,
        lastError = self.lastError,
        toasts = self.toasts,
        confirms = self.confirms,
        -- How long a rule waits for missing material, and its usual retry.
        pauseSeconds = self.config:rawPauseMaxSeconds(),
        retrySeconds = tonumber(self.config:get("turtle.cooldown", 300)) or 300,
        computerId = os and os.getComputerID and os.getComputerID() or nil,
        version = self.version,
        -- The footer's "updated" age is the last warehouse scan, expected
        -- every tick plus however long a scan takes.
        updatedAt = self.lastStepAt,
        interval = self.config:tickSeconds() + (self.lastStepSeconds or 0),
    }
end

-- The kit's App on the terminal and every monitor it finds (touch, text
-- scale 0.5); monitors follow the terminal's tab.
function Controller:openScreens(now)
    self.screensRetryAt = now + 5
    local ok, ui, err = pcall(UI.App.new, {
        pages = Screens.pages(),
        state = self.model,
        adapters = {
            clock = self.now,
            current = self.term and function() return self.term end or nil,
        },
        onAction = function(action, model, info)
            self:onUiAction(action, model, info)
        end,
    })
    if not ok or not ui then
        logEvent(self.logger, "error", "screens.failed", {error = tostring(ok and err or ui)})
        ui = nil
    end
    self.ui = ui
end

-- In the UI loop: drops lapsed questions, (re)opens the screens and paints
-- a fresh model when something changed or a second went by.
function Controller:paintScreens(now)
    for screenId, question in pairs(self.confirms) do
        if now > question.expiresAt then
            self.confirms[screenId] = nil
            self.screensDirty = true
        end
    end
    if self.ui and self.ui.closed then
        logEvent(self.logger, "error", "screens.closed", {error = tostring(self.ui.error)})
        self.ui = nil
    end
    local stale = now - (self.modelAt or -math.huge) >= self.config:uiRefreshSeconds()
    if stale then self:refreshUiSnapshot(now) end
    if not self.screensDirty and self.model then return end
    self.screensDirty = false
    self.modelAt = now
    self.model = Screens.model(self:screenSnapshot(now))
    if not self.ui and now >= (self.screensRetryAt or 0) then
        self:openScreens(now)
    end
    if self.ui then
        self.ui:render(self.model)
        self.cleaning:setActive(Screens.shown(self.ui)[Screens.CLEANING] == true)
    end
end

-- Keys, touches, the kit's own timer and monitors coming and going.
function Controller:handleScreens(event)
    local ui = self.ui
    if not ui or ui.closed then return end
    ui:handle(table.unpack(event, 1, event.n))
    local name = event[1]
    if (name == "monitor_touch" or name == "mouse_click") and not ui.closed then
        Screens.unfocus(ui, name == "monitor_touch" and event[2] or "terminal")
        ui:render()
    end
    self.cleaning:setActive(Screens.shown(ui)[Screens.CLEANING] == true)
end

-- The station that makes a missing raw (app.route_hints), on the failure
-- itself, so the rule row keeps it.
function Controller:annotateShortage(failure, detail)
    local shortage = Util.rawShortage(failure, detail)
    if not shortage or not self.hints then return end
    failure.hint, failure.hintSource = self.hints:describe(shortage.raw, failure.routes)
end

function Controller:toast(status, text)
    self.toasts = UI.Feedback.Toasts.push(self.toasts, {text = text, status = status}, self.now(), TOAST_SECONDS)
    self:render()
end

-- A question for one screen; it lapses after a while.
function Controller:ask(screenId, question, now, seconds, page)
    self.confirmSeq = self.confirmSeq + 1
    question.page = page
    question.seq = self.confirmSeq
    question.expiresAt = now + (seconds or QUESTION_SECONDS)
    self.confirms[screenId] = question
end

function Controller:askCleaning(screenId, now)
    local c = self.cleaning:snapshot(now)
    local what = tostring(c.kindLabel or "items"):lower()
    return self:ask(screenId, {kind = "confirm", title = "Send all " .. (c.all and "" or "used ") .. what .. " to " .. tostring(c.address) .. "?",
        message = tostring(c.used or 0) .. " " .. what .. " leave the warehouse", submitLabel = "SEND",
        action = "cleaning"}, now, nil, Screens.CLEANING)
end

-- A confirmed question: the cleaning send it asked about.
function Controller:answer(question, action)
    if action == "cleaning" then
        local sent = self.cleaning:requestSend(self.now())
        local what = tostring(self.cleaning:snapshot(self.now()).kindLabel or "Items")
        return self:toast(sent and "ok" or "warn", what .. (sent and ": preparing delivery" or ": not ready to send"))
    end
end

-- The kit's actions, inside its input handling.
function Controller:onUiAction(action, model, info)
    local id = tostring(action.id or "")
    local screenId = info and info.screenId or "terminal"
    local now = self.now()
    local question = self.confirms[screenId]

    if id == "clean_send" and action.type == "activate" then
        self:askCleaning(screenId, now)
    elseif id:match("^cleaning_kind:") and action.type == "activate" then
        self.cleaning:setKind(id:match("^cleaning_kind:(.+)$"))
    elseif question and id == "q" .. tostring(question.seq) and (action.type == "submit" or action.type == "cancel") then
        self.confirms[screenId] = nil
        if action.type == "submit" and question.action then
            self:answer(question, question.action)
        end
    end

    model.toasts = self.toasts
    self:render()
end

function Controller:handleEvent(event, first, second, third)
    if event == "peripheral" or event == "peripheral_detach" then
        if self.bus.forget then self.bus:forget(first) end
        if self.orderer and self.orderer.invalidateNetwork then self.orderer:invalidateNetwork() end
        return true
    end

    if event == "rednet_message" and self.orderer and
        type(self.orderer.handleControllerMessage) == "function" then
        local handled, state, detail, requestId, failure, target, crafted =
            self.orderer:handleControllerMessage(first, second, third)

        if handled then
            self:annotateShortage(failure, detail)
            self:recordRawShortage(requestId, state, detail, failure, target, crafted)

            if state == "accepted" then
                self.lastAction = "controller accepted " .. tostring(detail)
                self.lastError = nil
            elseif state == "completed" then
                self.lastAction = "controller completed " .. tostring(detail)
                self.lastError = nil
            elseif state == "rejected" and Util.rawShortage(failure, detail) then
                -- A known shortage, shown as waiting for material, not an error.
                self.lastAction = "waiting for material: " .. tostring(detail)
            elseif state == "rejected" then
                self.lastError = "controller: " .. Notice.failureText(failure, detail, target)
            end

            self:refreshUiSnapshot(self.now())
        end

        return handled
    end

    return false
end

function Controller:retryControllerCommands(now)
    if not self.orderer or type(self.orderer.retryPendingControllerCommands) ~= "function" then
        return 0
    end

    local ok, result = pcall(self.orderer.retryPendingControllerCommands, self.orderer, now or self.now())

    if not ok then
        self.lastError = "controller retry: " .. tostring(result)
        return 0
    end

    return tonumber(result) or 0
end

function Controller:nextControllerRetryAt()
    if not self.orderer or type(self.orderer.nextControllerRetryAt) ~= "function" then
        return nil
    end

    local ok, result = pcall(self.orderer.nextControllerRetryAt, self.orderer)
    return ok and tonumber(result) or nil
end

function Controller:cooperativeYield()
    if self.cooperativeUi and os and type(os.sleep) == "function" then
        os.sleep(0)
    end
end

function Controller:processQueuedWork()
    if #self.orderQueue == 0 or not self.lastDevices or not self.lastSnapshot then
        return 0
    end

    local processed = self:processOrderQueue(
        self.lastDevices,
        self.lastSnapshot.rows or {},
        self.now(),
        self.config:queueMaxBatchesPerPoll()
    )

    if processed > 0 then
        self:refreshUiSnapshot(self.now())
    end

    return processed
end

function Controller:safeProcessQueuedWork()
    local ok, result = pcall(function()
        return self:processQueuedWork()
    end)

    if ok then
        return result
    end

    self.lastError = "queue: " .. tostring(result)

    if self.lastSnapshot then
        self.lastSnapshot.lastError = self.lastError
        self:render()
    end

    return 0
end

-- A craft request's id for PC48 (<key>:<time>:<sequence>), kept on its job.
function Controller:ensureRequestId(item, now)
    if not isCraft(item) then
        return
    end

    if not item.job.requestId then
        self.requestSequence = self.requestSequence + 1
        item.job.requestId = table.concat({tostring(item.key or "job"),
            tostring(math.floor(tonumber(now) or self.now())), tostring(self.requestSequence)}, ":")
    end

    item.requestId = item.job.requestId
end

function Controller:queueCountFor(key)
    local count = 0

    for _, item in ipairs(self.orderQueue) do
        if item.key == key then
            count = count + 1
        end
    end

    return count
end

function Controller:dropQueuedKey(key)
    local remaining = {}

    for _, item in ipairs(self.orderQueue) do
        if item.key ~= key then
            table.insert(remaining, item)
        end
    end

    self.orderQueue = remaining
    self.queuedKeys[key] = nil
    self.lastOrders[key] = nil
    self.lastOrderCounts[key] = nil
end

function Controller:markQueued(row)
    local count = self:queueCountFor(row.key)

    row.status = "QUEUE"
    row.reason = "queued " .. tostring(count)
    row.shouldOrder = false
end

function Controller:clearStaleQueuedKey(key)
    if not self.queuedKeys[key] then
        return false
    end

    if self:queueCountFor(key) > 0 then
        return false
    end

    self.queuedKeys[key] = nil
    self.lastOrders[key] = nil
    self.lastOrderCounts[key] = nil

    return true
end

function Controller:enqueueOrder(job, row, now)
    if self.queuedKeys[job.key] then
        return 0
    end

    local added = 0

    local function push(orderJob)
        table.insert(self.orderQueue, {
            key = job.key,
            label = row.label or row.key,
            job = orderJob
        })

        added = added + 1
    end

    if job.mode == "turtle_crafter" then
        local orderJob = Util.clone(job)
        orderJob.requests = {}
        orderJob.requestBatches = nil
        orderJob.outputCount = row.outputCount
        push(orderJob)
    elseif type(row.requestBatches) == "table" and #row.requestBatches > 0 then
        -- One queue item (one ticker order) per planned batch.
        for _, batch in ipairs(row.requestBatches) do
            local orderJob = Util.clone(job)
            orderJob.requests = Util.clone(batch)
            orderJob.requestBatches = {Util.clone(batch)}
            push(orderJob)
        end
    else
        local orderJob = Util.clone(job)
        orderJob.requests = Util.clone(row.requests)
        push(orderJob)
    end

    if added > 0 then
        self.queuedKeys[job.key] = true
        self.lastOrders[job.key] = now
        self.lastOrderCounts[job.key] = tonumber(row.count) or 0

        logEvent(self.logger, "info", "request.plan", {
            key = job.key,
            mode = job.mode,
            target = job.target,
            address = job.address,
            current = tonumber(row.count) or 0,
            limit = tonumber(row.limit) or 0,
            cycles = tonumber(row.plannedCycles) or tonumber(row.craftCount),
            batches = type(row.requestBatches) == "table" and #row.requestBatches or 1,
            items = Requests.details(row.requests),
            totals = Requests.aggregateDetails(row.requests)
        })
    end

    return added
end

function Controller:rowForKey(rows, key)
    for _, row in ipairs(rows or {}) do
        if row.key == key then
            return row
        end
    end

    return nil
end

function Controller:queueKeys()
    local result = {}
    local seen = {}

    for _, item in ipairs(self.orderQueue) do
        if item.key and not seen[item.key] then
            seen[item.key] = true
            table.insert(result, item.key)
        end
    end

    return result
end

function Controller:isQueueItemReady(item, now)
    if not isCraft(item) then
        if not self.shipping:ready(now) then return false end
        local packages, err = self.shipping:estimate(item.job)
        if not packages then
            if item.shippingError ~= err then
                item.shippingError = err
                logEvent(self.logger, "warn", "shipping.waiting", {key = item.key, reason = err})
            end
            return false
        end
        item.shippingError = nil
    end
    local delay = self.config:queuePerJobDelaySeconds()
    local last = self.lastQueueSent[throttleKey(item)]

    return delay <= 0 or last == nil or (now - last) >= delay
end

-- The first queued item of a rule.
function Controller:firstQueued(key)
    for _, item in ipairs(self.orderQueue) do
        if item.key == key then
            return item
        end
    end

    return nil
end

function Controller:nextQueueKey(now)
    local keys = self:queueKeys()

    if #keys == 0 then
        return nil
    end

    local start = 1

    if self.lastQueueKey then
        for index, key in ipairs(keys) do
            if key == self.lastQueueKey then
                start = (index % #keys) + 1
                break
            end
        end
    end

    for offset = 0, #keys - 1 do
        local index = ((start + offset - 1) % #keys) + 1
        local key = keys[index]

        if self:isQueueItemReady(self:firstQueued(key), now) then
            return key
        end
    end

    return nil
end

function Controller:processOrderQueue(devices, rows, now, limitOverride)
    local limit = tonumber(limitOverride) or self.config:queueMaxBatchesPerPoll()
    local processed = 0
    now = now or self.now()

    while processed < limit and #self.orderQueue > 0 do
        -- The item stays queued while it is sent (see below).
        local key = self:nextQueueKey(now)
        local item = key and self:firstQueued(key)

        if not item then
            break
        end

        self:ensureRequestId(item, now)

        logEvent(self.logger, "info", "request.dispatch", {
            key = item.key,
            mode = item.job.mode,
            target = item.job.target,
            address = item.job.address,
            queuedRemaining = math.max(0, #self.orderQueue - 1)
        })

        local shipping = not isCraft(item)
        local packages = shipping and assert(self.shipping:estimate(item.job)) or nil
        if shipping then self.shipping:begin(packages, "queue") end
        self.dispatchingKey = item.key
        local called, ok, err, requested, summary = pcall(self.orderer.order, self.orderer, item.job, devices)
        self.dispatchingKey = nil
        if shipping then
            self.shipping:finish(self.now())
            local gate = self.shipping.lastGate or {}
            logEvent(self.logger, "info", "shipping.paced", {
                key = item.key, packages = packages, delay = packages * 2,
                gate = gate.gate, gateReason = gate.reason, waited = gate.waited,
            })
        end
        if not called then
            local thrown = ok
            ok = false
            err = tostring(thrown or "order failed")
        end

        processed = processed + 1
        -- A recipe whose stock went short since it was planned: planned
        -- again at the next scan, not an error.
        local waiting = not ok and tostring(err or ""):match("^waiting for stock") ~= nil
        -- Retain the item while yielding in peripheral/network calls so a scan
        -- cannot mistake it for a stale queued key and enqueue a duplicate.
        for index, queued in ipairs(self.orderQueue) do
            if queued == item then
                table.remove(self.orderQueue, index)
                break
            end
        end
        local row = self:rowForKey(rows, item.key)

        self.lastQueueKey = item.key

        if ok then
            self.lastQueueSent[throttleKey(item)] = now
            local remaining = self:queueCountFor(item.key)

            if remaining == 0 then
                self.queuedKeys[item.key] = nil
            end

            if row then
                if remaining > 0 then
                    row.status = "QUEUE"
                    row.reason = "queued " .. tostring(remaining)
                else
                    row.status = "REQUESTED"
                    row.reason = "ordered " .. tostring(summary or requested or item.job.amount)
                end

                row.shouldOrder = false
            end

            self.lastAction = tostring(item.label or item.key) .. " -> " ..
                tostring(summary or item.job.requestLabel or item.job.request)
            self.lastError = nil
        else
            self:dropQueuedKey(item.key)

            logEvent(self.logger, waiting and "info" or "error", "request.order_failed", {
                key = item.key,
                mode = item.job.mode,
                target = item.job.target,
                address = item.job.address,
                error = tostring(err or "order failed")
            })

            if row then
                row.status = waiting and "NO_STOCK" or "ERROR"
                row.reason = tostring(err or "order failed")
                row.shouldOrder = false
            end

            if not waiting then
                self.lastError = tostring(item.label or item.key) .. ": " .. tostring(err or "order failed")
            end
        end
    end

    return processed
end

-- A rule whose craft needs material no turtle can make (or the warehouse
-- lacks) pauses until that material is stocked instead of failing every cooldown.
-- Each shortage in a row doubles the pause (Config:rawPauseSeconds);
-- a craft that made something, or a finished one, starts over (2026-10-22:
-- wood rules with no logs in stock failed about 100 times in 13 hours).
function Controller:recordRawShortage(requestId, state, detail, failure, target, crafted)
    if type(target) ~= "string" then return end
    if state == "completed" then self.rawStreak[target] = nil end
    if state ~= "rejected" then return end
    local shortage = Util.rawShortage(failure, detail)
    if not shortage then return end
    local streak = (tonumber(crafted) or 0) > 0 and 1 or (self.rawStreak[target] or 0) + 1
    self.rawStreak[target] = streak
    shortage.streak = streak
    shortage.at = self.now()
    -- `needed` is the deficit beyond the stock the failed plan already used.
    shortage.baseStock = tonumber((self.lastStockCounts or {})[shortage.raw]) or 0
    self.rawBackoff[target] = shortage
    logEvent(self.logger, "info", "request.needs_raw", {
        target = target, raw = shortage.raw, needed = shortage.needed, hint = shortage.hint,
        pause = self.config:rawPauseSeconds(streak),
    })
end

function Controller:activeRawShortage(target, counts, now)
    local shortage = self.rawBackoff[target]
    if not shortage then return nil end
    local ttl = self.config:rawPauseSeconds(shortage.streak)
    local stock = tonumber(counts[shortage.raw]) or 0
    shortage.baseStock = shortage.baseStock or stock
    if stock >= shortage.baseStock + shortage.needed or now - (shortage.at or now) >= ttl then
        self.rawBackoff[target] = nil
        logEvent(self.logger, "info", "request.needs_cleared", {
            target = target, raw = shortage.raw, needed = shortage.needed, stock = stock,
        })
        return nil
    end
    return shortage
end

-- One rule against the stock: its row (state, reason, the planned orders)
-- and whether to queue it. availableCounts: the stock minus what earlier
-- rules and the queue already planned to use.
function Controller:evaluateJob(job, counts, now, availableCounts)
    self:clearStaleQueuedKey(job.key)

    local count = tonumber(counts[job.check] or 0) or 0
    local planningCounts = availableCounts or counts
    local limit = Requests.limit(job)
    local missingAmount = Requests.missing(job, count)
    -- always: craft whenever there is something to make it from; the limit is
    -- then the most one request asks for, not a stock level.
    if job.always and job.mode == "turtle_crafter" then missingAmount = math.max(1, limit) end
    local lastOrderCount = tonumber(self.lastOrderCounts[job.key])
    local recipeSlots = type(job.requests) == "table" and #job.requests or 0
    local stockDropCanBypassCooldown = recipeSlots <= 1 and job.mode ~= "turtle_crafter"
    local stockDroppedAfterOrder = stockDropCanBypassCooldown and lastOrderCount ~= nil and count < lastOrderCount
    local remaining = 0

    if not stockDroppedAfterOrder then
        remaining = math.max(0, math.ceil((job.cooldown or 0) - (now - (self.lastOrders[job.key] or 0))))
    end
    local craftCount = nil
    local overflowAmount = 0
    local orderRequests = job.requests
    local requestBatches = nil
    local exportTotal = nil
    local normalCycleCount = nil
    local partialCycleCount = nil
    local planError = nil

    if job.exportAvailable then
        orderRequests, requestBatches, exportTotal = Requests.availablePlan(job.requests, counts, job.multipleOf)
        count = exportTotal or 0
    elseif job.overflow then
        overflowAmount = math.max(0, math.floor(count - limit))
        -- multipleOf: only whole batches of the excess leave (a composter rule
        -- sent 1-4 items every few seconds, each holding PC48's warehouse gate).
        if (job.multipleOf or 1) > 1 then
            overflowAmount = math.floor(overflowAmount / job.multipleOf) * job.multipleOf
        end
        -- orderLimit: the excess leaves in pieces, one per cooldown (surplus
        -- logs flooded the blast-smelting fan, 2026-10-27).
        if job.orderLimit then overflowAmount = math.min(overflowAmount, tonumber(job.orderLimit)) end
        orderRequests, requestBatches = Requests.itemPlan(job.target, overflowAmount)
    elseif job.mode == "turtle_crafter" then
        craftCount = missingAmount
        if job.orderLimit then craftCount = math.min(craftCount, tonumber(job.orderLimit)) end
        orderRequests = {}
    elseif missingAmount > 0 then
        normalCycleCount = Requests.orderCount(job, count, job.requests)
        local planErr
        orderRequests, requestBatches, planErr = Requests.autoPlan(job.requests, normalCycleCount, job.orderLimit)

        if not orderRequests then
            orderRequests = {}
            planError = planErr or "request plan"
        end
    end

    local missingRequest = nil

    if planError then
        missingRequest = {
            name = planError,
            available = 0,
            needed = 1
        }
    elseif not job.exportAvailable and not job.overflow and job.mode ~= "turtle_crafter" then
        missingRequest = Requests.firstMissing(planningCounts, orderRequests)
    end

    -- Not enough for the whole deficit: as many whole cycles as the stock allows.
    if missingRequest and not planError then
        local desiredCycles = normalCycleCount or Requests.orderCount(job, count, job.requests)
        local affordableCycles = Requests.affordableCycles(job.requests, planningCounts, desiredCycles)

        if affordableCycles > 0 then
            local planRequests, planBatches = Requests.autoPlan(job.requests, affordableCycles, job.orderLimit)

            if planRequests then
                orderRequests = planRequests
                requestBatches = planBatches
                missingRequest = nil
                partialCycleCount = affordableCycles
            end
        end
    end

    local row = {
        key = job.key,
        label = job.label,
        check = job.check,
        request = job.request,
        requests = orderRequests,
        requestBatches = requestBatches,
        craftCount = craftCount,
        outputCount = job.mode == "turtle_crafter" and craftCount or nil,
        count = count,
        limit = limit,
        partialCycles = partialCycleCount,
        plannedCycles = partialCycleCount or normalCycleCount or craftCount,
        cooldownEndsAt = remaining > 0 and ((self.lastOrders[job.key] or 0) + (job.cooldown or 0)) or nil,
        section = job.section,
        status = "OK",
        reason = "enough",
        resource = job,
        shouldOrder = false
    }

    if self.dispatchingKey == job.key then
        row.status = "QUEUE"
        row.reason = "sending"
        return row
    end

    if job.enabled == false then
        row.status = "OFF"
        row.reason = "disabled"
    elseif job.exportAvailable or job.overflow then
        -- What leaves: every listed item in stock, or the excess over the limit.
        local leaving = job.exportAvailable and count or overflowAmount
        if leaving <= 0 then
            if self.queuedKeys[job.key] then
                self:dropQueuedKey(job.key)
            end

            row.status = "OK"
            row.reason = job.exportAvailable and "empty" or "kept"
        elseif self.queuedKeys[job.key] then
            self:markQueued(row)
        elseif remaining > 0 then
            row.status = "WAIT"
            row.reason = "cooldown " .. tostring(remaining) .. "s"
        else
            row.status = "LOW"
            row.reason = (job.exportAvailable and "export " or "overflow ") .. tostring(leaving)
            row.shouldOrder = true
        end
    elseif count >= limit and not job.always then
        if self.queuedKeys[job.key] then
            self:dropQueuedKey(job.key)
        end

        row.status = "OK"
        row.reason = "enough"
    elseif self.queuedKeys[job.key] then
        self:markQueued(row)
    elseif job.mode == "turtle_crafter" then
        local shortage = self:activeRawShortage(job.target, counts, now)
        if self.orderer.hasActiveTarget and self.orderer:hasActiveTarget(job.target) then
            row.status = "WAIT"
            row.reason = "craft in progress"
        elseif shortage then
            row.status = "NEEDS"
            row.reason = shortage.raw == job.target and "no turtle recipe"
                or ("needs " .. shortage.raw .. " x" .. tostring(shortage.needed))
            row.needs = {raw = shortage.raw, needed = shortage.needed, hint = shortage.hint}
        elseif remaining > 0 then
            row.status = "WAIT"
            row.reason = "cooldown " .. tostring(remaining) .. "s"
        else
            row.status = "LOW"
            row.reason = "delegate " .. tostring(craftCount or 0)
            row.shouldOrder = true
        end
    elseif missingRequest then
        row.status = "NO_STOCK"
        row.reason = "missing " .. tostring(missingRequest.name) ..
            " " .. tostring(missingRequest.available) .. "/" .. tostring(missingRequest.needed)
        row.missingRequest = missingRequest
    elseif remaining > 0 then
        row.status = "WAIT"
        row.reason = "cooldown " .. tostring(remaining) .. "s"
    else
        row.status = "LOW"
        row.reason = partialCycleCount and ("order partial " .. tostring(partialCycleCount)) or
            ("order " .. tostring(job.requestLabel or job.request))
        row.shouldOrder = true
    end

    return row
end

function Controller:step()
    local now = self.now()
    self.stepStartedAt = now
    self:refreshConfig()
    self:cooperativeYield()

    local devices = self.bus:scan()
    self:cooperativeYield()

    local stock = self.reader:read(devices)
    if stock.ok then
        self.shipping:observe(stock.metadata)
        self.lastStockCounts = stock.counts
    end
    self:cooperativeYield()
    if devices.generation ~= nil and devices.generation ~= self.bus.generation then devices = self.bus:scan() end

    local rows = {}
    local enqueued = 0
    local jobs = self.config:jobs()
    local availableCounts = cloneCounts(stock.counts or {})
    reserveQueuedRequests(availableCounts, self.orderQueue)

    for index, job in ipairs(jobs) do
        local row = self:evaluateJob(job, stock.counts or {}, now, availableCounts)
        table.insert(rows, row)

        if row.shouldOrder and enqueued < self.config:maxOrdersPerTick() then
            local added = self:enqueueOrder(job, row, now)

            if added > 0 then
                reserveRequests(availableCounts, row.requests)
                enqueued = enqueued + 1
                self:markQueued(row)
            end
        end

        -- Let the screens and the queue run every few rules.
        if index % 8 == 0 then
            self:cooperativeYield()
        end
    end

    Sorting.sortRows(rows, stock.metadata or {}, self.config:sorting())
    self:cooperativeYield()

    local snapshot = {
        devices = devices,
        stock = stock,
        rows = rows,
        queueCount = #self.orderQueue,
        lastAction = self.lastAction,
        lastError = self.lastError
    }

    self.lastDevices = devices
    self.lastSnapshot = snapshot
    self.lastStepAt = now
    self.lastStepSeconds = math.max(0, self.now() - now)
    self:render()

    return snapshot
end

function Controller:safeStep()
    local ok, err = pcall(function()
        self:step()
    end)

    if ok then
        self.lastStepError = nil
        return true
    end

    if tostring(err) ~= self.lastStepError then
        logEvent(self.logger, "error", "step.failed", {error = tostring(err)})
    end
    self.lastStepError = tostring(err)
    self.lastError = tostring(err)
    self:render()

    return false
end

-- The scan runs every tick; the queue loop (runQueueLoop) sends the orders
-- meanwhile, so a long scan never holds them up.
function Controller:waitBetweenSteps()
    local start = self.now()
    local deadline = math.max(start, (self.stepStartedAt or start) + self.config:tickSeconds())
    os.sleep(math.max(0.05, deadline - start))
end

function Controller:pollQueuedWork()
    -- A cleaning send keeps going with its tab closed; it alternates with the
    -- rule queue for the shipping slot.
    local cleaningFirst = self.cleaning.sending and self.shipping.lastOwner ~= "cleaning"
    if cleaningFirst then
        self.cleaning:poll(self.bus, self.now(), self.shipping)
    end
    self:safeProcessQueuedWork()
    local now = self.now()
    local retryAt = self:nextControllerRetryAt()
    if retryAt and now >= retryAt then self:retryControllerCommands(now) end
    if (self.cleaning.active or self.cleaning.sending) and not cleaningFirst then
        self.cleaning:poll(self.bus, self.now(), self.shipping)
    end
end

function Controller:runQueueLoop()
    logEvent(self.logger, "info", "queue.scheduler_started", {
        version = self.version,
        pollSeconds = self.config:queuePollSeconds()
    })
    while true do
        self:pollQueuedWork()
        os.sleep(math.max(0.05, self.config:queuePollSeconds()))
    end
end

function Controller:runMainLoop()
    while true do
        self:safeStep()
        self:waitBetweenSteps()
    end
end

-- The screens' loop: PC48's answers and peripheral events go to the
-- controller, everything else (keys, touches, the kit's own repaint timer,
-- monitors coming and going) to the kit; a fresh model at most every 0.25 s.
function Controller:runEventLoop()
    local timer = os.startTimer(0.25)
    while true do
        local event = table.pack(os.pullEvent())
        if event[1] == "timer" and event[2] == timer then
            self:paintScreens(self.now())
            timer = os.startTimer(0.25)
        else
            self:handleEvent(table.unpack(event, 1, event.n))
            if event[1] ~= "rednet_message" then
                self:handleScreens(event)
            end
        end
    end
end

-- Three loops side by side: the warehouse scan, the screens and events,
-- and the order queue.
function Controller:run()
    assert(parallel and os and type(os.pullEvent) == "function" and type(os.sleep) == "function",
        "PC46 runs on a CraftOS computer (parallel, os.pullEvent, os.sleep)")
    self.cooperativeUi = true
    self:paintScreens(self.now())
    local ok, err = pcall(parallel.waitForAny, function()
        self:runMainLoop()
    end, function()
        self:runEventLoop()
    end, function()
        self:runQueueLoop()
    end)
    if self.ui then
        self.ui:close()
    end
    if not ok then
        error(err, 0)
    end
end

return Controller

