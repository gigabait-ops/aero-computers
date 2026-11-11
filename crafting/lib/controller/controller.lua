local Protocol = require("controller.protocol")
local OrderGate = require("controller.order_gate")
local RecipePolicy = require("controller.recipe_policy")
local JobKind = require("controller.job_kind")
local Notice = require("chat.notice")
local Queue = require("controller.queue")
local Registry = require("controller.registry")
local Store = require("controller.store")
local Screens = require("controller.screens")
local Supplier = require("controller.supplier")
local Defaults = require("controller.defaults")
local UI = require("ui")

local Controller = {}
Controller.__index = Controller
local RELEASE = "2026-11-10.2"

local function mergedConfig(config)
    local result = {}
    for key, value in pairs(Defaults) do result[key] = value end
    for key, value in pairs(config or {}) do result[key] = value end
    return result
end

local function nowSeconds()
    if os and type(os.epoch) == "function" then
        return os.epoch("utc") / 1000
    end
    return os and os.clock and os.clock() or 0
end

local function computerId()
    return os and os.getComputerID and os.getComputerID() or "unknown"
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return result
end

local function isModem(peripheralApi, name)
    if not peripheralApi then
        return false
    end
    if type(peripheralApi.hasType) == "function" then
        local ok, matched = pcall(peripheralApi.hasType, name, "modem")
        if ok and matched then
            return true
        end
    end
    if type(peripheralApi.getType) == "function" then
        local values = {pcall(peripheralApi.getType, name)}
        if values[1] then
            for index = 2, #values do
                if values[index] == "modem" then
                    return true
                end
            end
        end
    end
    if type(peripheralApi.getMethods) == "function" then
        local ok, methods = pcall(peripheralApi.getMethods, name)
        if ok then
            for _, method in ipairs(methods or {}) do
                if method == "transmit" or method == "isWireless" then
                    return true
                end
            end
        end
    end
    return false
end

function Controller.new(options)
    options = options or {}
    local config = mergedConfig(options.config)
    local controllerId = computerId()
    local store = options.store or Store.new({
        path = config.queueFile,
        fs = options.fs or fs,
    })
    local persisted, loadError = store:load()
    local queue = Queue.new(persisted and persisted.queue)
    local registry = Registry.new({
        timeoutSeconds = config.workerTimeoutSeconds,
        busyTimeoutSeconds = math.max(
            tonumber(config.workerBusyTimeoutSeconds) or Defaults.workerBusyTimeoutSeconds,
            tonumber(config.stalledAfterSeconds) or Defaults.stalledAfterSeconds
        ),
        workers = persisted and persisted.workers,
    })

    for _, worker in pairs(persisted and persisted.workers or {}) do
        queue:observeAssignment(worker.assignment, controllerId)
    end

    local self = setmetatable({
        config = config,
        controllerId = controllerId,
        fs = options.fs or fs,
        peripheral = options.peripheral or peripheral,
        rednet = options.rednet or rednet,
        sleep = options.sleep or (os and os.sleep),
        now = options.now or nowSeconds,
        protocol = options.protocol or Protocol.new(config),
        queue = queue,
        registry = registry,
        orderGate = options.orderGate or OrderGate.new({
            leaseSeconds = config.orderLeaseSeconds,
            waiterTimeout = config.orderWaiterTimeout,
            budget = config.orderBacklogBudget,
            drainPerSecond = config.orderDrainPerSecond,
        }),
        store = store,
        recipePolicy = options.recipePolicy,
        recipesApi = options.recipes,
        term = options.term or term,
        logger = options.logger,
        network = false,
        modems = {},
        peripheralCount = 0,
        hosted = false,
        saved = loadError == nil,
        fatalError = not persisted and loadError or nil,
        lastError = loadError,
        lastWarning = nil,
        lastStatus = loadError and "queue recovery required" or "starting",
    }, Controller)

    self.supplier = options.supplier or Supplier.new(self, {ticker = config.ticker})
    for _, job in ipairs(queue.jobs) do
        for _, assignment in pairs(job.assignments or {}) do
            local worker = registry:get(assignment.worker)
            if not worker then
                worker = registry:observe(assignment.worker, {type = "poll"}, 0)
            end
            worker.assignment = assignment.id
            worker.state = "BUSY"
        end
    end
    return self
end

function Controller:log(event, fields)
    if self.logger and type(self.logger.info) == "function" then
        pcall(function()
            self.logger:info(event, fields or {})
        end)
    end
end

function Controller:save(reason)
    self.queue:prune(self.config.historyLimit)
    local ok, saveError = self.store:save({
        version = 1,
        controllerId = self.controllerId,
        savedAt = self.now(),
        queue = self.queue:serialize(),
        workers = self.registry:serialize(),
    })
    self.saved = ok == true
    if not ok then
        self.lastError = tostring(saveError or "queue save failed")
        self:log("queue.save_failed", {reason = reason, error = self.lastError})
        return false, saveError
    end
    self:log("queue.saved", {reason = reason})
    return true
end

function Controller:ensureNetwork()
    local names = {}
    if self.peripheral and type(self.peripheral.getNames) == "function" then
        local ok, result = pcall(self.peripheral.getNames)
        if ok and type(result) == "table" then
            names = result
        end
    end
    table.sort(names)
    self.peripheralCount = #names

    local opened = {}
    for _, name in ipairs(names) do
        if isModem(self.peripheral, name) then
            local isOpen = false
            if self.rednet and type(self.rednet.isOpen) == "function" then
                local ok, value = pcall(self.rednet.isOpen, name)
                isOpen = ok and value == true
            end
            if not isOpen and self.rednet and type(self.rednet.open) == "function" then
                local ok = pcall(self.rednet.open, name)
                isOpen = ok
            end
            if isOpen then
                opened[#opened + 1] = name
            end
        end
    end

    self.modems = opened
    self.network = #opened > 0
    if self.network and not self.hosted and self.rednet and type(self.rednet.host) == "function" then
        pcall(self.rednet.host, self.protocol.requestProtocol, self.config.requestHostname or "craft-controller")
        pcall(self.rednet.host, self.protocol.workerProtocol, self.config.workerHostname or "autocrafter-controller")
        self.hosted = true
    end
    return self.network
end

function Controller:send(id, message, protocol)
    if not self.network or not self.rednet or type(self.rednet.send) ~= "function" then
        return false
    end
    local ok, sent = pcall(self.rednet.send, id, message, protocol)
    return ok and sent ~= false
end

function Controller:replyFor(job)
    if self.queue:terminal(job) then
        return self.protocol:status(job)
    end
    return self.protocol:accepted(job, self.queue:position(job, self.config.maxParallelAssignments))
end

function Controller:handleRequest(sender, message)
    if type(message) ~= "table" then
        self:send(sender, self.protocol:rejected(nil, "message must be a table"), self.protocol.requestProtocol)
        return
    end

    if message.type == "ping" then
        self:send(sender, {
            type = "pong",
            controller = self.controllerId,
            workers = #self.registry:available(self.now()),
            stats = self.queue:stats(),
        }, self.protocol.requestProtocol)
        return
    end

    if message.type == "status" or message.type == "query" then
        local clientId = message.id or message.requestId
        local job = self.queue:findRequest(sender, clientId)
        local reply = job and self.protocol:status(job)
            or self.protocol:rejected(clientId, "request not found", "NOT_FOUND")
        self:send(sender, reply, self.protocol.requestProtocol)
        return
    end

    -- The warehouse service (controller.supplier): items a worker lacks.
    if message.type == "supply" then
        self:send(sender, self.supplier:supply(sender, message), self.protocol.requestProtocol)
        return
    end

    if self.fatalError then
        self:send(sender, self.protocol:rejected(
            message.id or message.requestId,
            "controller queue unavailable: " .. tostring(self.fatalError),
            "QUEUE_UNAVAILABLE"
        ), self.protocol.requestProtocol)
        return
    end

    local generatedId = self.queue:nextId(self.controllerId)
    local request, parseError = self.protocol:parseCraft(message, sender, generatedId)
    if not request then
        self:send(sender, self.protocol:rejected(
            message.id or message.requestId,
            parseError
        ), self.protocol.requestProtocol)
        return
    end

    local existing = self.queue:findRequest(sender, request.clientId)
    if existing then
        self:send(sender, self:replyFor(existing), self.protocol.requestProtocol)
        return
    end
    -- Station-only targets wait for their station; a requester that names
    -- the station (a PC46 station rule) is followed.
    local kind = request.kind
    if not kind then
        -- A raw drop nobody makes (mutton, salmon) is refused at once instead
        -- of failing on a turtle.
        if self:kinds():makeable(request.target) == false then
            self:send(sender, self.protocol:rejected(request.clientId,
                "no recipe makes " .. request.target .. "; it only comes from the world", "NO_RECIPE"),
                self.protocol.requestProtocol)
            return
        end
        kind = self:kinds():classify(request.target)
    end
    request.kind = kind ~= JobKind.TURTLE and kind or nil

    local job = self.queue:enqueue(request, generatedId, self.now(), self.controllerId)
    local saved, saveError = self:save("request accepted")
    if not saved then
        self.queue:remove(job)
        self:send(sender, self.protocol:rejected(
            request.clientId,
            "request not persisted: " .. tostring(saveError),
            "QUEUE_SAVE_FAILED"
        ), self.protocol.requestProtocol)
        return
    end

    self.lastStatus = "accepted " .. tostring(job.clientId)
    self:log("request.accepted", {
        id = job.clientId,
        sender = sender,
        target = job.target,
        count = job.count,
        kind = job.kind,
    })
    self:send(sender, self.protocol:accepted(
        job,
        self.queue:position(job, self.config.maxParallelAssignments)
    ), self.protocol.requestProtocol)
end

-- A craft job PC48 queues itself (a supply's missing item); the worker ships
-- its output to `deliverTo`. Returns its id, or nil when it could not be saved.
function Controller:enqueueInternal(target, count, kind, reason, deliverTo, supplyKey)
    local id = self.queue:nextId(self.controllerId)
    local job = self.queue:enqueue({
        sender = self.controllerId, clientId = id, target = target, count = count,
        kind = kind ~= JobKind.TURTLE and kind or nil, internal = true,
        deliverTo = deliverTo, supplyKey = supplyKey,
    }, id, self.now(), self.controllerId)
    if not self:save("internal job") then
        self.queue:remove(job)
        return nil
    end
    self:log("request.accepted", {id = job.clientId, sender = "PC48", target = target, count = count,
        kind = job.kind, reason = reason})
    return job.id
end

-- A turtle job whose target the turtles cannot make at all goes back in
-- the queue for the station that makes it (2026-11-06: PC121 asked for cut
-- deepslate bricks, a saw item, and every turtle failed on it). Once.
function Controller:reroute(job)
    local failure = job.status == "ERROR" and job.result and job.result.failure
    if job.kind or job.rerouted or type(failure) ~= "table" or failure.code ~= "MISSING_RAW"
        or failure.ingredient ~= job.target then
        return false
    end
    local kind = self:kinds():stationFor(job.target)
    if not kind then return false end
    job.kind, job.rerouted, job.status = kind, true, "QUEUED"
    job.result, job.notified, job.completedAt = nil, nil, nil
    self:save("job rerouted")
    self:log("job.rerouted", {id = job.clientId, target = job.target, kind = kind})
    return true
end

-- A station of `kind` polled PC48 within the registry's timeout.
function Controller:kindOnline(kind)
    local now = self.now()
    for _, worker in pairs(self.registry and self.registry.workers or {}) do
        if worker.kind == kind and self.registry:isOnline(worker, now) then return true end
    end
    return false
end

-- Who makes what (controller.job_kind), with the machines from settings.
function Controller:kinds()
    self.jobKind = self.jobKind or JobKind.new({recipes = self.recipesApi, machines = self.config.machines,
        dyeFans = self.config.dyeFans,
        online = function(kind) return self:kindOnline(kind) end})
    return self.jobKind
end

-- Recipe rules from PC48's /recipe_policy.lua, re-read when the file changes.
function Controller:currentRecipePolicy()
    if not self.recipePolicy then
        self.recipePolicy = RecipePolicy.new({
            path = self.config.recipePolicyFile,
            fs = self.fs,
            log = function(event, fields) self:log(event, fields) end,
        })
    end
    return self.recipePolicy:get()
end

function Controller:sendJob(job, assignment)
    return self:send(
        assignment.worker,
        self.protocol:workerJob(job, assignment, self:currentRecipePolicy()),
        self.protocol.workerProtocol
    )
end

function Controller:handlePoll(sender, message)
    local now = self.now()
    local active = message.active
    if active then
        local job, assignment = self.queue:findAssignment(active)
        if job and assignment and not self.queue:terminal(job)
            and tostring(assignment.worker) == tostring(sender)
        then
            self.registry:markAssigned(sender, assignment.id, now)
            assignment.lastHeardAt = now
            self:sendJob(job, assignment)
        elseif self.queue:observeAssignment(active, self.controllerId) then
            self.registry:markAssigned(sender, active, now)
            self.lastError = nil
            self.lastStatus = "recovering orphan assignment from W" .. tostring(sender)
            self:log("worker.orphan_assignment", {
                worker = sender,
                assignment = active,
            })
            local saved, saveError = self:save("orphan worker observed")
            if not saved then
                self.lastError = "orphan worker state not persisted: " .. tostring(saveError)
            end
        else
            self.lastError = "W" .. tostring(sender) .. " reports unknown " .. tostring(active)
        end
        return
    end

    local assigned, existingAssignment = self.queue:assignedTo(sender)
    if assigned and existingAssignment then
        self.registry:markAssigned(sender, existingAssignment.id, now)
        existingAssignment.lastHeardAt = now
        self:sendJob(assigned, existingAssignment)
        return
    end

    self.registry:release(sender, now)
    local parallelLimit = math.max(
        1,
        math.floor(tonumber(self.config.maxParallelAssignments) or Defaults.maxParallelAssignments)
    )
    local job = self.queue:nextPending(parallelLimit, JobKind.workerKinds(message))
    if not job then
        self:send(sender, self.protocol:workerIdle(), self.protocol.workerProtocol)
        return
    end
    local assignmentId = tostring(job.id) .. ":" .. tostring(job.attempts + 1)
    -- A station takes the whole job (owner 2026-11-06: twelve saws got 32
    -- at a time); it orders in batches its chest holds and shares them out.
    local limit = job.kind and (self.config.maxStationOutput or Defaults.maxStationOutput)
        or self.config.maxAssignmentOutput or Defaults.maxAssignmentOutput
    local byKind = job.kind and (self.config.stationOutput or Defaults.stationOutput)[job.kind]
    if byKind ~= nil then limit = byKind or 2 ^ 31 end
    local assignmentOutput = math.min(self.queue:unassignedOutput(job), math.max(1, math.floor(tonumber(limit) or 64)))
    local assignment = self.queue:assign(job, sender, assignmentId, now, assignmentOutput)
    -- Its turn taken: what is left of a big job waits behind the others.
    if byKind and self.queue:unassignedOutput(job) > 0 then self.queue:moveToBack(job) end
    self.registry:markAssigned(sender, assignmentId, now)
    local saved, saveError = self:save("job assigned")
    if not saved then
        self.queue:release(job, assignmentId)
        self.registry:release(sender, now)
        self.lastError = "assignment not persisted: " .. tostring(saveError)
        return
    end

    self.lastStatus = "assigned " .. tostring(job.clientId) .. " -> W" .. tostring(sender)
    self:log("job.assigned", {
        id = job.clientId,
        assignment = assignmentId,
        worker = sender,
        count = assignmentOutput,
        completedOutput = job.completedOutput,
        requestedOutput = job.count,
    })
    self:sendJob(job, assignment)
end

function Controller:handleHeartbeat(sender, message)
    local job, assignment = self.queue:findAssignment(message.assignment)
    if not job and self.queue:observeAssignment(message.assignment, self.controllerId) then
        self.registry:markAssigned(sender, message.assignment, self.now())
        self.lastError = nil
        self.lastStatus = "recovering orphan progress from W" .. tostring(sender)
        local saved, saveError = self:save("orphan worker progress")
        if not saved then
            self.lastError = "orphan progress not persisted: " .. tostring(saveError)
        end
        return
    end
    if not job or not assignment or self.queue:terminal(job)
        or tostring(assignment.worker) ~= tostring(sender)
    then
        self.lastError = "unknown heartbeat from W" .. tostring(sender)
        return
    end
    self.queue:heartbeat(job, message, self.now())
    -- Heartbeats update RAM; ownership transitions are still saved durably.
end

function Controller:notify(job)
    if not self.queue:terminal(job) or job.notified then
        return false
    end
    if job.internal then
        -- PC48's own job (controller.supplier reads it from the queue).
        job.notified = true
        return true
    end
    local sent = self:send(job.sender, self.protocol:status(job), self.protocol.requestProtocol)
    if sent then
        job.notified = true
        self:save("client notified")
    end
    return sent
end

function Controller:handleResult(sender, message)
    local job, assignment = self.queue:findAssignment(message.assignment)
    if not job and self.queue:observeAssignment(message.assignment, self.controllerId) then
        local worker = self.registry:get(sender)
        if worker and worker.assignment
            and tostring(worker.assignment) ~= tostring(message.assignment)
        then
            self.lastError = "result assignment mismatch from W" .. tostring(sender)
            return
        end

        self.registry:release(sender, self.now())
        self.lastError = nil
        self.lastStatus = "recovered orphan result from W" .. tostring(sender)
        self:log("worker.orphan_result", {
            worker = sender,
            assignment = message.assignment,
            ok = message.ok ~= false,
            target = message.target,
            craftedOutput = message.craftedOutput,
        })
        local saved, saveError = self:save("orphan result acknowledged")
        if not saved then
            self.lastError = "orphan result not persisted: " .. tostring(saveError)
            return
        end

        self:send(
            sender,
            self.protocol:workerAck(message.assignment),
            self.protocol.workerProtocol
        )
        return
    end
    if not job or not assignment or tostring(assignment.worker) ~= tostring(sender) then
        self.lastError = "unknown result from W" .. tostring(sender)
        return
    end

    if self.queue:terminal(job) then
        self:send(sender, self.protocol:workerAck(message.assignment), self.protocol.workerProtocol)
        self:notify(job)
        return
    end

    local worker = self.registry:get(sender)
    local previousJob = deepCopy(job)
    local previousJobs = {}
    for index, queuedJob in ipairs(self.queue.jobs) do
        previousJobs[index] = queuedJob
    end
    local previousWorker = worker and {
        state = worker.state,
        assignment = worker.assignment,
        lastSeen = worker.lastSeen,
    } or nil

    local outcome = self.queue:complete(job, message, self.now())
    self.registry:release(sender, self.now())
    local saved = self:save("worker result")
    if not saved then
        for key in pairs(job) do
            job[key] = nil
        end
        for key, value in pairs(previousJob) do
            job[key] = value
        end
        self.queue.jobs = previousJobs
        if worker and previousWorker then
            worker.state = previousWorker.state
            worker.assignment = previousWorker.assignment
            worker.lastSeen = previousWorker.lastSeen
        end
        return
    end

    self:send(sender, self.protocol:workerAck(message.assignment), self.protocol.workerProtocol)
    if self:reroute(job) then return end
    if not self.queue:terminal(job) then
        self.lastStatus = "partial " .. tostring(job.clientId) .. " "
            .. tostring(job.completedOutput) .. "/" .. tostring(job.count)
        self.lastError = nil
        self.lastWarning = nil
        self:log("job.chunk_completed", {
            id = job.clientId,
            worker = sender,
            assignment = message.assignment,
            assignmentOutput = outcome and outcome.assignmentOutput,
            completedOutput = job.completedOutput,
            requestedOutput = job.count,
        })
        return
    end

    local pruned = self.queue:prune(self.config.historyLimit)
    if pruned > 0 then
        self:save("history pruned")
    end
    self:notify(job)
    local chatOk, screenText = pcall(self.chatJob, self, job)
    screenText = chatOk and screenText or nil
    self.lastStatus = tostring(job.status) .. " " .. tostring(job.clientId)
    local failure = job.result and job.result.failure
    local warning = job.status == "ERROR" and type(failure) == "table"
        and tostring(failure.severity or ""):upper() == "WARN"
    -- The same words as the chat (chat.notice keys, English on screens).
    self.lastWarning = warning
        and (screenText or job.result.error or failure.message or "craft unavailable") or nil
    self.lastError = job.status == "ERROR" and not warning
        and (screenText or job.result and job.result.error or "craft failed") or nil
    self:log("job.completed", {
        id = job.clientId,
        worker = sender,
        status = job.status,
        craftedOutput = job.result and job.result.craftedOutput,
        error = job.result and job.result.error,
    })
end

-- Chat events (chat.notice, fire and forget): who asked, by PC.
local SOURCES = {[46] = "auto", [66] = "manual", [107] = "colony"}

function Controller:chatJob(job)
    local result = job.result or {}
    local failure = type(result.failure) == "table" and result.failure or {}
    local params = {
        target = job.target, requested = job.count,
        crafted = result.craftedOutput or job.completedOutput or 0,
        source = SOURCES[tonumber(job.sender)] or "other", jobKind = job.kind,
    }
    if job.status == "DONE" then
        return Notice.emit("craft.done", params, self.rednet)
    end
    local message = tostring(result.error or failure.message or "")
    local raw = failure.target or failure.candidate or failure.ingredient
    local parsedRaw, parsedNeeded = message:match("missing (%S+) x(%d+)")
    if failure.code == "MISSING_RAW" and (raw or parsedRaw) then
        params.raw, params.needed = raw or parsedRaw, tonumber(failure.needed) or tonumber(parsedNeeded)
        params.hint = failure.hint
        return Notice.emit("craft.missing", params, self.rednet)
    end
    params.code, params.error = failure.code or "ERROR", message
    return Notice.emit("craft.failed", params, self.rednet)
end

-- A worker seen online in this run that stops answering, and its return.
function Controller:watchWorkers(now)
    self.workerOnline = self.workerOnline or {}
    for _, worker in pairs(self.registry.workers) do
        local key = tostring(worker.id)
        local online = self.registry:isOnline(worker, now)
        local was = self.workerOnline[key]
        if was ~= nil and was ~= online then
            Notice.emit(online and "worker.online" or "worker.offline", {id = worker.id}, self.rednet)
        end
        if online or was ~= nil then self.workerOnline[key] = online end
    end
end

function Controller:sendOrderGrants(grants)
    if grants.expiredHolder then
        self:log("order_gate.lease_expired", {
            worker = grants.expiredHolder.worker, packages = grants.expiredHolder.packages,
        })
    end
    for _, grant in ipairs(grants) do
        if grant.waited >= 1 then
            self:log("order_gate.granted", {
                worker = grant.worker, packages = grant.packages,
                waited = math.floor(grant.waited * 10 + 0.5) / 10,
                backlog = self.orderGate:snapshot(self.now()).backlog,
            })
        end
        self:send(grant.worker, {type = "order_grant", token = grant.token}, self.protocol.workerProtocol)
    end
end

function Controller:handleOrderLock(sender, message)
    if message.token == nil then return end
    local decision, position, grants = self.orderGate:request(
        sender, message.token, message.packages, self.now())
    if decision == "wait" then
        self:send(sender, {type = "order_wait", token = message.token, position = position},
            self.protocol.workerProtocol)
    elseif not grants[1] or grants[1].token ~= message.token then
        -- Repeat a grant whose delivery was lost.
        self:send(sender, {type = "order_grant", token = message.token}, self.protocol.workerProtocol)
    end
    self:sendOrderGrants(grants)
end

function Controller:handleWorker(sender, message)
    if type(message) ~= "table" then
        return
    end
    local now = self.now()
    -- PC46 and PC107 share the order gate but are not crafters: a gate
    -- message refreshes a known worker and never registers a new one.
    local gateMessage = message.type == "order_lock" or message.type == "order_release"
    if not gateMessage or self.registry:get(sender) then
        self.registry:observe(sender, message, now)
    end

    if message.type == "order_lock" then
        self:handleOrderLock(sender, message)
    elseif message.type == "order_release" then
        local _, grants = self.orderGate:release(sender, message.token, message.packages, now)
        self:sendOrderGrants(grants)
    elseif message.type == "hello" then
        self.lastStatus = "W" .. tostring(sender) .. " online"
        self:save("worker discovered")
    elseif message.type == "poll" then
        self:handlePoll(sender, message)
    elseif message.type == "status" or message.type == "progress" then
        self:handleHeartbeat(sender, message)
    elseif message.type == "result" then
        self:handleResult(sender, message)
    end
end

function Controller:notifyPending()
    for _, job in ipairs(self.queue.jobs) do
        if self.queue:terminal(job) and not job.notified then
            self:notify(job)
            return
        end
    end
end

function Controller:snapshot()
    local now = self.now()
    local workers = self.registry:snapshot(now)
    local online = 0
    for _, worker in ipairs(workers) do
        if worker.online then
            online = online + 1
        end
    end

    local jobs = {}
    local jobsByWorker = {}
    for _, job in ipairs(self.queue.jobs) do
        if not self.queue:terminal(job) then
            local displayed = {
                id = job.id,
                status = job.status,
                target = job.target,
                count = job.count,
                completedOutput = job.completedOutput,
                activeAssignments = self.queue:assignmentCount(job),
            }
            jobs[#jobs + 1] = displayed
            for _, assignment in pairs(job.assignments or {}) do
                local status = "ASSIGNED"
                if now - (assignment.lastHeardAt or now) >= self.config.stalledAfterSeconds then
                    status = "STALLED"
                end
                jobsByWorker[tostring(assignment.worker)] = {
                    id = job.id,
                    status = status,
                    target = job.target,
                    count = assignment.count,
                    worker = assignment.worker,
                    phase = assignment.phase,
                    current = assignment.current,
                    waitingFor = assignment.waitingFor,
                }
            end
        end
    end
    for _, worker in ipairs(workers) do
        worker.job = jobsByWorker[tostring(worker.id)]
    end

    return {
        controllerId = self.controllerId,
        network = self.network,
        modems = #self.modems > 0 and table.concat(self.modems, ",") or "-",
        peripheralCount = self.peripheralCount,
        workers = workers,
        onlineWorkers = online,
        totalWorkers = #workers,
        stats = self.queue:stats(),
        jobs = jobs,
        saved = self.saved,
        lastStatus = self.lastStatus,
        lastError = self.lastError,
        lastWarning = self.lastWarning,
        orderGate = self.orderGate:snapshot(now),
        supplies = self.supplier:open(),
    }
end

-- The shared CC UI kit's App on the terminal and every monitor it finds
-- (touch, text scale 0.5); monitors follow the terminal's tab.
function Controller:openScreens(now)
    self.screensRetryAt = now + 5
    local api = self.peripheral or {}
    local ok, ui, err = pcall(UI.App.new, {
        pages = Screens.pages(),
        state = self.model,
        adapters = {
            clock = self.now,
            current = function() return self.term end,
            getNames = api.getNames and function() return api.getNames() end or nil,
            isMonitor = api.hasType and function(name) return api.hasType(name, "monitor") == true end or nil,
            wrap = api.wrap and function(name) return api.wrap(name) end or nil,
        },
    })
    if not ok or not ui then
        self:log("screens.failed", {error = tostring(ok and err or ui)})
        ui = nil
    end
    self.ui = ui
end

function Controller:render()
    if self.config.render == false or not self.term then
        return
    end
    local now = self.now()
    if self.ui and self.ui.closed then
        self:log("screens.closed", {error = tostring(self.ui.error)})
        self.ui = nil
    end
    self.model = Screens.model(self:snapshot(), self.model, {
        monitors = Screens.monitors(self.ui), version = RELEASE, now = now,
        interval = self.config.tickSeconds, backlogBudget = self.config.orderBacklogBudget,
    })
    if not self.ui and now >= (self.screensRetryAt or 0) then
        self:openScreens(now)
    end
    if self.ui then
        self.ui:render(self.model)
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
end

function Controller:start()
    self:log("fleet.release", {version = RELEASE})
    self:ensureNetwork()
    -- Which Stock Ticker supplies go through (or why none), in the log at boot.
    local _, tickerError = self.supplier:ticker()
    if tickerError then self:log("supplier.ticker_unavailable", {error = tickerError.message}) end
    Notice.emit("system.started", {name = "PC48", version = RELEASE}, self.rednet)
    self:render()
    local function networkLoop()
        local timer = os.startTimer(self.config.tickSeconds)
        local tickAt = self.now()
        local function tick()
            self:sendOrderGrants(self.orderGate:evaluate(self.now()))
            local tickOk, tickError = pcall(self.supplier.tick, self.supplier)
            if not tickOk and tostring(tickError) ~= self.lastTickError then
                self.lastTickError = tostring(tickError)
                self:log("supplier.tick_failed", {error = self.lastTickError})
            end
            self:notifyPending()
            pcall(self.watchWorkers, self, self.now())
            tickAt = self.now()
            timer = os.startTimer(self.config.tickSeconds)
        end
        while true do
            local raw = table.pack(os.pullEvent())
            local event, a, b, c = raw[1], raw[2], raw[3], raw[4]
            if event == "rednet_message" then
                if c == self.protocol.requestProtocol then self:handleRequest(a, b)
                elseif c == self.protocol.workerProtocol then self:handleWorker(a, b) end
            elseif event == "timer" and a == timer then
                tick()
            else
                if event == "peripheral" or event == "peripheral_detach" then
                    self:ensureNetwork()
                end
                self:handleScreens(raw)
            end
            -- CC drops other events while a peripheral call waits (the
            -- ticker during a supply): a lost timer event would stop the
            -- ticks for good (2026-11-03: supplies hung in ORDERING).
            if self.now() - tickAt > 3 * self.config.tickSeconds then
                self:log("controller.tick_restarted", {late = math.floor(self.now() - tickAt)})
                tick()
            end
        end
    end
    local function renderLoop()
        while true do self:render(); os.sleep(0.25) end
    end
    parallel.waitForAny(networkLoop, renderLoop)
end

return Controller
