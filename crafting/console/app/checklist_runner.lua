-- The checklist's work on PC66 (moved from PC46's controller 2026-11-08):
-- binds the clipboard and the Stock Ticker the peripheral scan found, reads
-- the list and the stock when due, and sends what app.checklist plans, one
-- order per pass. It runs in its own loop (app.lua), so a ticker order that
-- waits for PC48's order gate never holds up the screens or manual crafts.
--   sends: one ticker order of up to nine items of one session to one
--     address, paced by app.shipping (as PC46's queue did);
--   crafts: PC48's craft protocol (as PC46 spoke it, 46/app/orderer.lua)
--     over app.craft_client's link; kept in memory only, so a new session or
--     a restart forgets them (PC48 keeps crafting what it accepted).
local Checklist = require("app.checklist")
local Shipping = require("app.shipping")
local StockTicker = require("app.stock_ticker")
local Util = require("app.util")

local Runner = {}
Runner.__index = Runner

local TERMINAL = {DONE = true, FAILED = true, ERROR = true, CANCELLED = true, REJECTED = true}

-- PC48's warehouse order gate (fleet ROM), the permit the crafter turtles
-- and PC46 take before a ticker order.
local function warehouseGate(client)
    if type(rednet) ~= "table" then return nil end
    local ok, OrderGate = pcall(require, "autocrafter.order_gate")
    if not ok then return nil end
    return OrderGate.new({
        rednet = rednet,
        protocol = "gigabait.autocrafter.worker.v1",
        workerId = "pc" .. tostring(os.getComputerID and os.getComputerID() or "66"),
        controllerId = function() return client.controllerId end,
    })
end

-- options: config (the checklist table of 66/config.lua), client
-- (app.craft_client), logger, hints, computerId, now, gate (false: none).
function Runner:new(options)
    options = options or {}
    local shipping = Shipping:new()
    if options.gate ~= false then shipping:useGate(options.gate or warehouseGate(options.client)) end
    return setmetatable({
        client = options.client,
        logger = options.logger,
        now = options.now or Util.now,
        shipping = shipping,
        checklist = Checklist:new({
            config = options.config,
            shipping = shipping,
            logger = options.logger,
            hints = options.hints,
            computerId = options.computerId,
        }),
        devices = {},
        stock = nil,
        nextStockAt = 0,
        queue = {},
        queuedKeys = {},
        pending = {},
        reloadRecipes = false,
    }, self)
end

function Runner:get(key, fallback)
    return self.checklist:get(key, fallback)
end

-- The checklist loop's pause: short while a clipboard is placed.
function Runner:pollSeconds()
    if self.checklist:connected() then return math.max(0.05, tonumber(self:get("pollSeconds", 0.25)) or 0.25) end
    return 1
end

-- One pass: the list and the stock, then one order, then due resends.
-- devices: the peripheral scan's snapshot (clipboard, ticker: {name, device}).
function Runner:step(devices, now)
    now = now or self.now()
    self.devices = devices or {}
    if self.reloadRecipes then
        self.reloadRecipes = false
        self.checklist:recipesReloaded()
    end
    self:sync(now)
    self:dispatch(now)
    self:retry(now)
end

-- A session that ended (clipboard taken away or replaced, list changed)
-- takes its queued orders and its unanswered crafts with it.
function Runner:activate(event, previousToken)
    if previousToken then self:cancel(previousToken) end
    if event then self.nextStockAt = 0 end
end

function Runner:cancel(token)
    local remaining = {}
    for _, item in ipairs(self.queue) do
        if item.checklist and item.checklist.token == token then
            self.queuedKeys[item.key] = nil
        else
            remaining[#remaining + 1] = item
        end
    end
    self.queue = remaining
    local prefix = tostring(token) .. ":"
    for id in pairs(self.pending) do
        if id:sub(1, #prefix) == prefix then self.pending[id] = nil end
    end
end

function Runner:isCurrent(id)
    local token = self.checklist.sessionToken
    local prefix = token and (token .. ":")
    return prefix ~= nil and tostring(id or ""):sub(1, #prefix) == prefix
end

-- The clipboard (read at most every readSeconds) and, every stockSeconds,
-- the stock; a fresh stock read checks a few recipes and queues the
-- deliveries of crafts that landed.
function Runner:sync(now)
    local c = self.checklist
    local event, previousToken = c:bind(self.devices.clipboard, now)
    self:activate(event, previousToken)
    if not c:connected() then return end

    local refreshEvent, refreshToken = c:refresh(now, event == "attached" or event == "replaced")
    if not c:connected() then return end
    self:activate(refreshEvent, refreshToken)

    if now < self.nextStockAt then return end
    self.nextStockAt = now + math.max(0.5, tonumber(self:get("stockSeconds", 2)) or 2)
    local revision = c:beginStockRead()
    local stock = StockTicker.read(self.devices.ticker)
    self.stock = stock
    -- No ticker (or it failed): the list is only shown, nothing is planned
    -- from an old stock read.
    if not stock.ok then
        c.stockReady = false
        return
    end
    self.shipping:observe(stock.metadata)
    if not c:connected() or not c:updateStock(stock.counts, revision) then return end
    c:checkRecipes(self:get("recipeChecksPerScan", 16))
    self:enqueue(c:deliveryOrders())
end

function Runner:enqueue(orders)
    local added = 0
    for _, item in ipairs(orders or {}) do
        if item.key and not self.queuedKeys[item.key] then
            self.queue[#self.queue + 1] = item
            self.queuedKeys[item.key] = true
            added = added + 1
        end
    end
    return added
end

local function isCraft(item)
    return item.job.mode == "turtle_crafter"
end

function Runner:remove(item)
    for index, queued in ipairs(self.queue) do
        if queued == item then
            table.remove(self.queue, index)
            break
        end
    end
    self.queuedKeys[item.key] = nil
end

-- The first order that can go now: a craft always, a shipment once the
-- shipping slot is free and its stack limits are known.
function Runner:nextItem(now)
    for _, item in ipairs(self.queue) do
        if isCraft(item) then return item end
        if self.shipping:ready(now) then
            local packages, err = self.shipping:estimate(item.job)
            if packages then
                item.shippingError = nil
                return item
            elseif item.shippingError ~= err then
                item.shippingError = err
                Util.log(self.logger, "warn", "shipping.waiting", {key = item.key, reason = err})
            end
        end
    end
    return nil
end

function Runner:dispatch(now)
    local item = self:nextItem(now)
    if not item then return false end
    if isCraft(item) then
        self:sendCraft(item, now)
    else
        self:ship(item)
    end
    return true
end

-- Sends of one session to one address go out together: one ticker order
-- of up to nine different items.
local function batchFor(queue, first, shipping)
    local batch, requests, seen = {}, {}, {}
    local function add(item)
        local meta, job = item.checklist, item.job
        if #batch >= 9 or not meta or not job.checklistShipment
            or meta.token ~= first.checklist.token or job.address ~= first.job.address
            or seen[meta.name] then return end
        local count = math.min(meta.count, 256, shipping:batchLimit(meta.name))
        if count <= 0 then return end
        seen[meta.name] = true
        batch[#batch + 1] = item
        requests[#requests + 1] = {name = meta.name, count = count}
    end
    add(first)
    for _, item in ipairs(queue) do add(item) end
    local job = {}
    for key, value in pairs(first.job) do job[key] = value end
    job.requests = requests
    return batch, job
end

function Runner:ship(first)
    local c = self.checklist
    local batch, job = batchFor(self.queue, first, self.shipping)
    local token, address = first.checklist.token, first.job.address
    job.canDispatch = function()
        return c:connected() and c.sessionToken == token and c:address() == address
    end
    local packages = assert(self.shipping:estimate(job))
    self.shipping:begin(packages, "checklist")
    -- A ticker order changes the stock the checklist counts on.
    c:beginStockDispatch()
    local called, ok, err, requested, summary, submitted = pcall(StockTicker.order, self.devices.ticker, job, self.logger)
    self.shipping:finish(self.now())
    local gate = self.shipping.lastGate or {}
    Util.log(self.logger, "info", "shipping.paced", {
        key = first.key, packages = packages, delay = packages * 2,
        gate = gate.gate, gateReason = gate.reason, waited = gate.waited,
    })
    if not called then
        ok, err = false, tostring(ok or "order failed")
    end

    for _, item in ipairs(batch) do
        self:remove(item)
        if ok then
            c:onOrderResult(item.checklist, true, submitted and (submitted[item.checklist.name] or 0) or requested)
        else
            c:onOrderResult(item.checklist, false, nil, err)
        end
    end
    if not ok then
        Util.log(self.logger, "error", "request.order_failed", {
            key = first.key, address = address, items = #batch, error = tostring(err),
        })
        -- Stop the undispatched chunks of each failed item as well. Otherwise
        -- a later successful chunk could clear the error and replay an
        -- earlier request whose outcome is unknown.
        local failedNames = {}
        for _, member in ipairs(batch) do failedNames[member.checklist.name] = true end
        for index = #self.queue, 1, -1 do
            local queued = self.queue[index]
            if queued.checklist and queued.checklist.token == token
                and queued.checklist.kind ~= "craft" and failedNames[queued.checklist.name] then
                table.remove(self.queue, index)
                self.queuedKeys[queued.key] = nil
                c:onOrderResult(queued.checklist, false, nil, err)
            end
        end
    else
        Util.log(self.logger, "info", "checklist.sent", {key = first.key, address = address, summary = summary})
    end
    c:endStockDispatch()
end

-- PC48 crafts ---------------------------------------------------------------------

function Runner:querySeconds()
    return tonumber(self.client.config.querySeconds) or 5
end

function Runner:sendCraft(item, now)
    self:remove(item)
    local ok, err = self:command(item.job, now)
    self.checklist:onOrderResult(item.checklist, ok, ok and item.job.outputCount or nil, err)
    if not ok then
        Util.log(self.logger, "error", "request.order_failed", {
            key = item.key, target = item.job.target, error = tostring(err),
        })
    end
end

-- A craft for PC48 under the checklist's request id; resent until PC48
-- answers, then asked about every querySeconds until it ends.
function Runner:command(job, now)
    local client = self.client
    if not client.controllerId then
        return false, "craft controller " .. tostring(client.config.hostname or "craft-controller") .. " not found"
    end
    if type(job.target) ~= "string" or job.target == "" then return false, "turtle target missing" end
    local id = tostring(job.requestId or "")
    if id == "" then return false, "turtle request id missing" end
    if not self:isCurrent(id) then return false, "clipboard session expired" end

    local entry = {
        id = id,
        message = {type = "craft", id = id, target = job.target,
            count = math.max(1, math.floor(tonumber(job.outputCount) or 1))},
        attempts = 0,
    }
    self.pending[id] = entry
    self:send(entry, now, "initial")
    return true
end

function Runner:send(entry, now, reason)
    if not self:isCurrent(entry.id) then
        self.pending[entry.id] = nil
        return false
    end
    entry.attempts = entry.attempts + 1
    entry.nextRetryAt = now + (entry.accepted and self:querySeconds() or self.client:retryDelay(entry.attempts))
    entry.controller = self.client.controllerId or entry.controller
    local ok, err = self.client:send(entry.accepted and {type = "query", id = entry.id} or entry.message)
    if not ok then
        Util.log(self.logger, "warn", "checklist.craft_retry", {requestId = entry.id, attempts = entry.attempts, error = err})
    elseif not entry.accepted and reason == "initial" then
        Util.log(self.logger, "info", "checklist.craft_sent", {requestId = entry.id, controller = entry.controller,
            target = entry.message.target, count = entry.message.count})
    end
    return ok
end

function Runner:retry(now)
    local ids = {}
    for id, entry in pairs(self.pending) do
        if now >= (entry.nextRetryAt or 0) then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry = self.pending[id]
        if entry then self:send(entry, now, "ack timeout") end
    end
end

-- PC48's answer about a checklist craft (the craft client ignores these ids).
function Runner:handleMessage(sender, message, protocol)
    if protocol ~= self.client.config.protocol or type(message) ~= "table" then return false end
    local id = tostring(message.id or "")
    local entry = self.pending[id]
    if not entry or tonumber(sender) ~= tonumber(entry.controller) then return false end

    local state, detail, failure
    if message.type == "accepted" then
        entry.accepted = true
        entry.nextRetryAt = self.now() + self:querySeconds()
        state, detail = "accepted", id
    elseif message.type == "rejected" then
        self.pending[id] = nil
        state, detail = "rejected", tostring(message.error or "controller rejected request")
    elseif message.type == "status" then
        if not TERMINAL[tostring(message.state)] then
            entry.accepted = true
            entry.nextRetryAt = self.now() + self:querySeconds()
            state, detail = "accepted", id
        else
            self.pending[id] = nil
            if message.state == "DONE" and message.ok ~= false then
                state, detail = "completed", id
            else
                failure = type(message.failure) == "table" and message.failure or nil
                state = "rejected"
                detail = tostring(message.error or (failure and failure.message) or message.state or "craft failed")
            end
        end
    else
        return false
    end

    if state ~= "accepted" then
        Util.log(self.logger, state == "completed" and "info" or "warn", "checklist.craft_" .. state, {
            requestId = id, target = entry.message.target, error = state == "rejected" and detail or nil,
        })
    end
    self.checklist:onControllerState(id, state, detail, failure)
    return true
end

-- Actions (a confirmed question) ---------------------------------------------------

-- action: send | craft | both; name: one row, or nil for the whole list.
-- Returns the number of orders queued, or nil and why.
function Runner:act(action, name)
    local c = self.checklist
    local orders, err
    if action == "send" then
        orders, err = c:sendAvailable(name)
    elseif action == "craft" then
        orders, err = c:craftMissing(name, false)
    elseif action == "both" then
        orders, err = c:craftAndSend(name)
    else
        return nil, "unknown action"
    end
    if not orders then return nil, err end
    return self:enqueue(orders)
end

-- A clipboard taken away: its session ends at once.
function Runner:detach(name)
    local event, previousToken = self.checklist:detach(name, self.now())
    self:activate(event, previousToken)
end

-- For the screens: the checklist's rows plus what PC66 is connected to.
function Runner:snapshot()
    local snapshot = self.checklist:snapshot()
    snapshot.enabled = self.checklist:enabled()
    snapshot.clipboard = (self.devices.clipboard or {}).name
    snapshot.ticker = (self.devices.ticker or {}).name
    snapshot.stockError = self.stock and not self.stock.ok and self.stock.error or nil
    snapshot.queueCount = #self.queue
    return snapshot
end

return Runner
