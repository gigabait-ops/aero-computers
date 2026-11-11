local Planner = require("autocrafter.planner")
local Supply = require("autocrafter.supply")
local OrderGate = require("autocrafter.order_gate")
local State = require("autocrafter.state")
local Executor = require("autocrafter.executor")
local View = require("autocrafter.view")
local Call = require("autocrafter.recipe_call")
local Delegate = require("autocrafter.delegate")
local Shipping = require("autocrafter.shipping")
local Notice = require("chat.notice")
local Util = require("fleet_util")

local Worker = {}
Worker.__index = Worker

local VERSION = "2026-11-10.1"
local PROTOCOL = Util.WORKER_PROTOCOL

local function computerId()
    return os and os.getComputerID and os.getComputerID() or nil
end

local function loadTurtleIO(value)
    if value then
        return value
    end
    local ok, module = pcall(require, "autocrafter.turtle_io")
    if ok then
        return module
    end
    return nil, module
end

local function createLogger(config, injected)
    if injected then
        return injected
    end
    local ok, module = pcall(require, "logger")
    if not ok or type(module.create) ~= "function" then
        return nil, ok and "logger.create unavailable" or module
    end
    local id = computerId() or "unknown"
    local log = module.create(config.logName or ("autocrafter-" .. tostring(id)), {
        file = config.logFile,
        level = config.logLevel,
        console = config.logConsole == true,
        max_bytes = tonumber(config.logMaxBytes) or 32768,
        max_files = tonumber(config.logMaxFiles) or 4,
    })
    if config.logging == false and log and type(log.setEnabled) == "function" then
        pcall(function()
            log:setEnabled(false)
        end)
    end
    return log
end

function Worker.new(options)
    options = options or {}
    local config = options.config or {}
    local devices = options.devices or {}
    local turtleIO, turtleError = loadTurtleIO(options.turtleIO)
    local log, loggerError = createLogger(config, options.logger)

    local self = setmetatable({
        config = config,
        devices = devices,
        computerId = computerId(),
        controllerId = nil,
        controllerHostname = config.controllerHostname or "autocrafter-controller",
        address = "crafting_" .. tostring(computerId()),
        -- The input barrel's wired name and its packager, found at boot.
        inputSide = devices.inputName,
        packager = devices.packager,
        shipAddress = config.shipAddress,
        stateFile = config.stateFile or "data/state.lua",
        fs = options.fs or fs,
        rednet = options.rednet or rednet,
        turtleIO = turtleIO,
        turtleError = turtleError,
        logger = log,
        loggerError = loggerError,
        view = options.view or View.new(),
        recipes = options.recipes,
        sleep = options.sleep,
    }, Worker)
    if self.recipes == nil then
        local ok, mod = pcall(require, "recipes")
        self.recipes = ok and mod or nil
    end

    if turtleIO then
        if config.orderGate ~= false and not options.supply then
            self.orderGate = options.orderGate or OrderGate.new({
                rednet = self.rednet,
                protocol = PROTOCOL,
                workerId = self.computerId,
                controllerId = function() return self.controllerId end,
                sleep = options.sleep,
                now = options.now,
            })
        end
        self.supply = options.supply or Supply.new({
            input = devices.inputStorage,
            stockTicker = devices.stockTicker,
            address = self.address,
            deliveryMaxTimeout = config.deliveryMaxTimeout,
            stockTickerDeliveryTimeout = config.stockTickerDeliveryTimeout,
            pollSeconds = config.deliveryPollSeconds,
            stallSeconds = config.deliveryStallSeconds,
            maxReorders = config.deliveryMaxReorders,
            gate = self.orderGate,
            logger = log,
            sleep = options.sleep,
            now = options.now,
        })
        self.planner = options.planner or Planner.new({
            tagCandidates = config.tagCandidates,
            reusableIngredients = config.reusableIngredients,
            blockedRecipes = config.blockedRecipes,
            avoidCandidates = config.avoidCandidates,
            maxDepth = config.maxDepth,
            maxNodes = config.maxNodes,
        })
        self.executor = options.executor or Executor.new({
            planner = self.planner,
            supply = self.supply,
            turtleIO = turtleIO,
            inputSide = self.inputSide,
            packager = self.packager,
            shipAddress = self.shipAddress,
            sleep = options.sleep,
            logger = log,
            resolveShadow = config.resolveShadow,
            blockedRecipes = config.blockedRecipes,
        })
    end
    return self
end

function Worker:loadState()
    if self.state then return self.state end
    local state, err = State.load(self.stateFile, self.fs)
    if not state then
        return nil, err
    end
    self.state = state
    return state
end

-- Without a job the turtle is emptied into the input chest and the chest is
-- shipped to the warehouse; late deliveries leave the same way.
function Worker:cleanupIdleInput(state)
    if state and (state.active or state.pendingResult) then
        return true, {skipped = true}
    end
    return Shipping.clean(self.turtleIO, self.packager, self.inputSide,
        {address = self.shipAddress, logger = self.logger, sleep = self.sleep})
end

function Worker:prepareInputForAssignment(state, assignment)
    if state and state.active then
        if tostring(state.active.assignment) == tostring(assignment) then
            return true, {resumed = true}
        end
        return false, {error = "another assignment is already active"}
    end
    if state and state.pendingResult then
        return false, {error = "previous assignment result is not acknowledged"}
    end
    return self:cleanupIdleInput({})
end

function Worker:lookupController()
    if not self.rednet or type(self.rednet.lookup) ~= "function" then
        return nil
    end
    local ok, id = pcall(self.rednet.lookup, PROTOCOL, self.controllerHostname)
    if ok and id ~= nil then
        return tonumber(id) or id
    end
    return nil
end

function Worker:bindController(state, controllerId)
    if controllerId == nil then
        return false
    end
    controllerId = tonumber(controllerId) or controllerId
    self.controllerId = controllerId
    if state.controllerId ~= controllerId then
        state.controllerId = controllerId
        local saved, saveError = State.save(state, self.stateFile, self.fs)
        if not saved then
            return false, saveError
        end
    end
    return true
end

function Worker:discoverController(state)
    if self.controllerId ~= nil and state.controllerId ~= nil
        and tostring(self.controllerId) == tostring(state.controllerId)
    then
        return true
    end
    if state.controllerId ~= nil then
        return self:bindController(state, state.controllerId)
    end

    local discovered = self:lookupController()
    if discovered ~= nil then
        if (state.active or state.pendingResult) and state.controllerId
            and tostring(state.controllerId) ~= tostring(discovered)
        then
            return self:bindController(state, state.controllerId)
        end
        return self:bindController(state, discovered)
    end
    if state.controllerId ~= nil then
        return self:bindController(state, state.controllerId)
    end
    self.controllerId = nil
    return false, "controller not found"
end

function Worker:draw(state, errorValue)
    local active = state and state.active
    local errorMessage = type(errorValue) == "table"
        and Notice.failureText(errorValue, errorValue.message) or errorValue
    local errorSeverity = type(errorValue) == "table" and errorValue.severity or nil
    self.view:draw({
        computerId = self.computerId,
        controllerId = self.controllerId,
        address = self.address,
        inputSide = self.inputSide,
        shipAddress = self.shipAddress,
        state = active and active.phase or (self.cleanupBlocked and "CLEANING_INPUT")
            or (self.controllerId and "IDLE" or "WAIT_CONTROLLER"),
        assignment = active and active.assignment,
        target = active and active.target,
        requestedOutput = active and active.requestedOutput,
        current = active and active.current,
        waitingFor = active and active.waitingFor,
        error = errorMessage,
        errorSeverity = errorSeverity,
    })
end

function Worker:execute(request, hooks)
    hooks = hooks or {}
    if not self.executor then
        return nil, {
            code = "RUNTIME_UNAVAILABLE",
            message = tostring(self.turtleError or "executor unavailable"),
        }
    end
    local state, loadError = self:loadState()
    if loadError then
        return nil, {code = "STATE_LOAD_FAILED", message = tostring(loadError)}
    end
    local assignment = tostring(request.assignment or ("manual-" .. tostring(os.clock())))
    local completed = state.completed and state.completed[assignment]
    if completed then return completed end
    if state.pendingResult and tostring(state.pendingResult.assignment) == assignment then
        return state.pendingResult
    end
    local prepared, preparation = self:prepareInputForAssignment(state, assignment)
    if not prepared then
        return nil, {
            code = "INPUT_PREPARATION_FAILED",
            message = "cannot prepare input for assignment: " ..
                tostring(preparation and preparation.error or "unknown cleanup failure"),
            cleanup = preparation,
        }
    end
    state.active = state.active and tostring(state.active.assignment) == assignment
        and state.active or {
            assignment = assignment,
            target = request.target,
            requestedOutput = request.count or request.requestedOutput,
            -- all (2026-10-27): make what the stock allows, then stop.
            all = request.all == true or nil,
            -- deliverTo (2026-10-28): the output goes to this address.
            deliverTo = request.deliverTo,
            -- keep (2026-10-28): an all job leaves this many of each `from` item.
            from = request.keep and request.from or nil,
            keep = request.keep,
            phase = "PLANNING",
        }

    local checkpointFailed
    local function checkpoint(active)
        state.active = active
        local ok, err = State.save(state, self.stateFile, self.fs)
        if not ok then
            checkpointFailed = tostring(err)
            error("state save failed: " .. tostring(err), 0)
        end
        self:draw(state)
    end

    -- An all job's reserve: the plan sees `keep` fewer of each `from` item.
    if self.supply then
        local reserve = {}
        for _, name in ipairs(state.active.keep and state.active.from or {}) do reserve[name] = state.active.keep end
        self.supply.reserve = reserve
    end
    local ok, result, executeError = pcall(function()
        -- Persist ownership before planning can yield, fail or be restarted.
        checkpoint(state.active)
        if hooks.onHeartbeat then hooks.onHeartbeat(state.active) end
        return self:executeDelegating(state.active, checkpoint, hooks)
    end)
    if not ok then
        executeError = {code = "WORKER_EXCEPTION", message = tostring(result)}
        result = nil
    end
    if checkpointFailed then
        return nil, {code = "STATE_SAVE_FAILED_AFTER_CRAFT", message = "checkpoint failed; worker stopped: " .. checkpointFailed}
    end
    if not result then
        self:draw(state, executeError)
        return nil, executeError
    end

    -- The output straight to the asker when the job names an address.
    local deliveredTo
    if state.active.deliverTo and self.packager and (result.craftedOutput or 0) > 0 then
        local delivered = Shipping.deliver(self.turtleIO, self.packager, self.inputSide, state.active.target,
            state.active.deliverTo, {address = self.shipAddress, logger = self.logger, sleep = self.sleep})
        deliveredTo = delivered and state.active.deliverTo or nil
    end
    local response = {
        type = "result",
        assignment = assignment,
        ok = true,
        deliveredTo = deliveredTo,
        target = state.active.target,
        requestedOutput = state.active.requestedOutput,
        craftedOutput = result.craftedOutput,
        recipeId = result.recipeId,
        steps = result.steps,
    }
    state.pendingResult = response
    local saved, saveError = State.save(state, self.stateFile, self.fs)
    if not saved then
        local message = "crafted output completed but result state was not persisted: " ..
            tostring(saveError or "state save failed")
        self:draw(state, message)
        return nil, {
            code = "STATE_SAVE_FAILED_AFTER_CRAFT",
            message = message,
            completedResult = response,
        }
    end
    self:draw(state)
    return response
end

-- A MISSING_RAW item to ask PC48 for (it knows who makes what: a station,
-- a machine without a computer): the first one not yet asked for in this
-- job, with the count.
function Worker:stationShortage(err, asked)
    if type(err) ~= "table" or err.code ~= "MISSING_RAW" then return nil end
    local candidates = {{err.target, err.needed}, {err.candidate, err.needed}}
    if type(err.ingredient) == "string" and err.ingredient:sub(1, 1) ~= "#" then
        candidates[#candidates + 1] = {err.ingredient, err.needed}
    end
    for _, other in ipairs(err.alternatives or {}) do candidates[#candidates + 1] = {other.target, other.needed} end
    for _, candidate in ipairs(candidates) do
        local item = candidate[1]
        if type(item) == "string" and item:sub(1, 1) ~= "#" and not asked[item] then
            return item, math.max(1, math.floor(tonumber(candidate[2]) or 1))
        end
    end
    return nil
end

-- A missing raw is asked from PC48 (2026-10-28), which has a station or a
-- machine make it and sends it straight to this turtle's chest; the turtle
-- plans again once it is there (the plan counts the chest too). One nobody
-- makes (PC48: MISSING) moves on to the next candidate.
function Worker:executeDelegating(active, checkpoint, hooks)
    local lastBeat = 0
    self.delegate = self.delegate or Delegate.new({
        rednet = self.rednet, logger = self.logger,
        idPrefix = "w" .. tostring(self.computerId),
        waitSeconds = self.config.mechanicalWaitSeconds,
    })
    self.delegate.heartbeat = function()
        local now = os.epoch and os.epoch("utc") / 1000 or 0
        if hooks.onHeartbeat and now - lastBeat >= 10 then lastBeat = now; hooks.onHeartbeat(active) end
    end
    local asked, settles = {}, 0
    while true do
        local result, err = self.executor:execute({
            target = active.target,
            count = active.requestedOutput,
        }, active, checkpoint, hooks)
        if result then return result end
        if active.all and type(err) == "table" and err.code == "MISSING_RAW" then
            -- An "all" job ends at the first missing raw with what it made.
            return {ok = true, craftedOutput = math.max(0, math.floor(tonumber(active.batchCompletedOutput) or 0)),
                requestedOutput = active.requestedOutput, steps = active.batchCompletedSteps}
        end
        local item, needed = self:stationShortage(err, asked)
        local sent = false
        while item and not sent do
            asked[item] = "asking"
            active.phase, active.waitingFor = "WAITING_STATION", {name = item, missing = needed}
            checkpoint(active)
            if hooks.onHeartbeat then hooks.onHeartbeat(active) end
            Util.log(self.logger, "worker.station_delegate", {assignment = active.assignment,
                target = active.target, item = item, count = needed})
            -- A later ask for the same item has its own id: PC48 answers an
            -- id it knows with its old reply.
            local asks = (active.supplyAsks or {})[item] or 1
            local ok, delegateError = self.delegate:supply({{name = item, count = needed}}, self.address,
                {craft = true, exclude = "turtle", phase = "WAITING_STATION",
                    id = tostring(active.assignment) .. (asks > 1 and (":" .. asks) or "") .. ":" .. item})
            active.waitingFor = nil
            if ok then
                asked[item], sent = "sent", true
            elseif type(delegateError) == "table" and delegateError.code == "MISSING_RAW" then
                asked[item] = "missing"
                item, needed = self:stationShortage(err, asked)
            else
                err.message = tostring(err.message) .. "; station: "
                    .. tostring(type(delegateError) == "table" and delegateError.message or delegateError)
                return nil, err
            end
        end
        if sent then
            os.sleep(self.config.mechanicalSettleSeconds or 15)
        else
            -- Just sent by PC48: its packages may still be on the way.
            local waiting = type(err) == "table" and err.code == "MISSING_RAW"
                and asked[err.target or err.candidate or err.ingredient] == "sent"
            settles = settles + 1
            if not waiting then return nil, err end
            if settles > (self.config.mechanicalSettleTries or 4) then
                -- Everything sent came and it is still short (the plan wants
                -- more than it asked for: 5 industrial iron blocks short in
                -- 26099 dark metal blocks, 2026-11-08): ask again, twice at most.
                local short = err.target or err.candidate or err.ingredient
                active.supplyAsks = active.supplyAsks or {}
                local asks = active.supplyAsks[short] or 1
                if asks >= 3 then return nil, err end
                active.supplyAsks[short], asked[short], settles = asks + 1, nil, 0
                checkpoint(active)
            else
                os.sleep(self.config.mechanicalSettleSeconds or 15)
            end
        end
    end
end

function Worker:failureResult(message, err, state)
    local active = state and state.active
    if active and tostring(active.assignment) ~= tostring(message.assignment) then active = nil end
    local output = active and math.max(0, math.floor(tonumber(active.batchCompletedOutput) or 0)) or 0
    local plan = active and active.plan
    local root = plan and (plan.nodes or {})[plan.rootIndex]
    if root and active.phase ~= "DONE" then
        local index = math.max(1, math.floor(tonumber(active.nodeIndex) or 1))
        if index > plan.rootIndex then
            output = output + math.max(0, math.floor(tonumber(root.outputCount) or 0))
        elseif index == plan.rootIndex then
            output = output + math.max(0, math.floor(tonumber(active.nodeCrafts) or 0))
                * math.max(1, math.floor(tonumber(root.outputPerCycle) or 1))
        end
    end
    return {
        type = "result", assignment = message.assignment, ok = false,
        target = message.target, craftedOutput = output,
        requestedOutput = active and active.requestedOutput or message.count or message.requestedOutput,
        failure = err, error = err and err.message or "autocrafter failed",
    }
end

-- Recipe rules PC48 sends with each job (its /recipe_policy.lua). A job
-- without them leaves the rules the worker already has.
function Worker:applyRecipePolicy(policy)
    if type(policy) ~= "table" then return false end
    if self.planner and type(self.planner.setPolicy) == "function" then self.planner:setPolicy(policy) end
    if self.executor then self.executor.blockedRecipes = policy.blockedRecipes end
    return true
end

-- The "status" message PC48 shows for a running job.
local function statusMessage(active)
    return {
        type = "status", assignment = active.assignment,
        state = active.phase, current = active.current, waitingFor = active.waitingFor,
    }
end

function Worker:send(message)
    if not self.controllerId or not self.rednet or type(self.rednet.send) ~= "function" then
        return false
    end
    local ok, sent = pcall(self.rednet.send, self.controllerId, message, PROTOCOL)
    return ok and sent ~= false
end

function Worker:workLoop()
    Util.log(self.logger, "fleet.release", {version = VERSION, input = self.inputSide, shipAddress = self.shipAddress})
    local state, stateError = self:loadState()
    self:draw(state, stateError)
    if not state then
        return false, tostring(stateError or "state unavailable")
    end
    if not self.executor then
        return false, tostring(self.turtleError or "executor unavailable")
    end

    if self.rednet and type(self.rednet.host) == "function" then
        pcall(self.rednet.host, PROTOCOL, "autocrafter-" .. tostring(self.computerId))
    end
    -- The input chest must be reachable by its wired name.
    local ready, route = self.turtleIO.prepareInput(self.inputSide)
    if not ready then
        self:draw(state, route)
        return false, route
    end
    Util.log(self.logger, "worker.input_route", route)
    -- booted with the server: the recipe list is still being built, and an
    -- order resumed now would fail
    local recipes = self.recipes
    if type(recipes) == "table" and type(recipes.meta) == "function"
        and not Call.waitReady(recipes, 1, function() end) then
        self:draw(state, {message = "waiting for the server's recipe list", severity = "WARN"})
        local ready = Call.waitReady(recipes, tonumber(self.config.recipesReadySeconds) or 60, self.sleep)
        Util.log(self.logger, "worker.recipes_ready", {ready = ready})
        self:draw(state)
    end
    local announcedController = nil
    local missedReplies = 0
    local nextIdleCleanupAt = 0

    while true do
        state, stateError = self:loadState()
        if not state then
            self:draw(nil, stateError)
            return false, tostring(stateError or "state unavailable")
        end

        local now = os and os.epoch and os.epoch("utc") / 1000
            or (os and os.clock and os.clock()) or 0
        if not state.active and not state.pendingResult and now >= nextIdleCleanupAt then
            nextIdleCleanupAt = now + math.max(1, tonumber(self.config.idleCleanupSeconds) or 10)
            local cleaned, cleanup = self:cleanupIdleInput(state)
            self.cleanupBlocked = not cleaned
            if not cleaned then
                self:draw(state, "idle input cleanup failed: " ..
                    tostring(cleanup and cleanup.error or "unknown cleanup failure"))
            else
                self:draw(state)
            end
        end

        local found = self:discoverController(state)
        if not found then
            announcedController = nil
            self:draw(state)
        else
            if tostring(announcedController) ~= tostring(self.controllerId) then
                self:send({
                    type = "hello",
                    worker = self.computerId,
                    capabilities = {
                        autonomous = true,
                        recursive = true,
                        multipleRecipes = true,
                    },
                })
                announcedController = self.controllerId
            end

            if state.pendingResult then
                self:send(state.pendingResult)
            elseif self.cleanupBlocked then
                -- Keep the controller informed, but do not request another job.
                self:send({type = "status", state = "CLEANING_INPUT"})
            else
                self:send({
                    type = "poll",
                    worker = self.computerId,
                    active = state.active and state.active.assignment,
                })
            end

            local sender, message, protocol = self.rednet.receive(PROTOCOL, self.config.pollTimeout or 5)
            if sender == self.controllerId and protocol == PROTOCOL and type(message) == "table" then
                missedReplies = 0
                if message.type == "ack" and state.pendingResult
                    and tostring(message.assignment) == tostring(state.pendingResult.assignment)
                then
                    State.acknowledge(state, message.assignment, self.config.completedLimit)
                    nextIdleCleanupAt = 0
                    local saved, saveError = State.save(state, self.stateFile, self.fs)
                    if not saved then
                        return false, "result acknowledgement not persisted: " .. tostring(saveError)
                    end
                    self:draw(state)
                elseif message.type == "job" and message.assignment and message.target then
                    self:applyRecipePolicy(message.recipePolicy)
                    local result, err = self:execute(message, {
                        onHeartbeat = function(active)
                            self:send(statusMessage(active))
                        end,
                        onProgress = function(crafts, output)
                            self:send({
                                type = "progress",
                                assignment = message.assignment,
                                crafts = crafts,
                                output = output,
                            })
                        end,
                    })
                    if result then self:send(result) end
                    if not result then
                        if err and err.code == "STATE_SAVE_FAILED_AFTER_CRAFT" then
                            return false, err.message
                        end
                        local reloaded, reloadError = self:loadState()
                        if not reloaded then
                            return false, "cannot persist failed result: " ..
                                tostring(reloadError or "state unavailable")
                        end
                        state = reloaded
                        state.pendingResult = self:failureResult(message, err, state)
                        local saved, saveError = State.save(state, self.stateFile, self.fs)
                        if not saved then
                            return false, "failed result was not persisted: " ..
                                tostring(saveError or "state save failed")
                        end
                    end
                end
            elseif sender == nil then
                missedReplies = missedReplies + 1
                local missLimit = math.max(1, tonumber(self.config.controllerMissLimit) or 3)
                if missedReplies >= missLimit and not state.active and not state.pendingResult then
                    state.controllerId = nil
                    self.controllerId = nil
                    announcedController = nil
                    State.save(state, self.stateFile, self.fs)
                    missedReplies = 0
                end
            end
        end
        if os and os.sleep then
            os.sleep(self.controllerId and (self.config.pollSeconds or 1)
                or (self.config.controllerDiscoverySeconds or 5))
        end
    end
end

function Worker:heartbeat()
    local state = self.state
    local active = state and state.active
    if active and not state.pendingResult then
        self:send(statusMessage(active))
    end
end

function Worker:start()
    if not parallel or type(parallel.waitForAny) ~= "function" then return self:workLoop() end
    local result, err
    parallel.waitForAny(function()
        result, err = self:workLoop()
    end, function()
        while true do
            local event = os.pullEvent()
            if event == "peripheral" or event == "peripheral_detach" then
                if self.turtleIO and self.turtleIO.invalidatePeripherals then self.turtleIO.invalidatePeripherals() end
            end
        end
    end, function()
        while true do
            os.sleep(2)
            self:heartbeat()
        end
    end)
    return result, err
end

Worker.PROTOCOL = PROTOCOL
Worker.VERSION = VERSION

return Worker
