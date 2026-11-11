local ItemMatcher = require("item_matcher")
local Util = require("fleet_util")
local ResolveShadow = require("autocrafter.resolve_shadow")
local Staging = require("autocrafter.staging")
local Shipping = require("autocrafter.shipping")
local Executor = {}
Executor.__index = Executor

local amount, fail, logEvent = Util.amount, Util.failure, Util.log

local function deliveryTimedOut(value)
    return type(value) == "table"
        and (value.code == "DELIVERY_TIMEOUT" or value.code == "DELIVERY_UNCERTAIN")
end

-- A step that failed on its inputs, or on the native recipe check, may
-- succeed with another recipe for the same item.
local function retryableRecipeFailure(value)
    if type(value) ~= "table" then
        return false
    end
    local message = tostring(value.error or value.message or ""):lower()
    return Staging.inputFailure(message) or message:find("recipe validation failed", 1, true) ~= nil
end

-- Drops the current plan and its delivery, so the next pass plans afresh.
-- The delivery window stays: callers that end it clear it themselves.
local function resetPlan(active, phase)
    active.plan, active.supply, active.deliveryPlan = nil, nil, nil
    active.nodeIndex, active.nodeCrafts = 1, 0
    active.current, active.waitingFor = nil, nil
    active.phase = phase
end

-- The input chest slots a plan needs at its peak (every output stays in the
-- chest), the chest size, and the node to probe for an unknown stack limit.
-- wholeStacks: count items as whole stacks, ignoring the chest's own stacks
-- (the delivery projection in planDelivery).
local function bufferReservation(plan, snapshot, turtleIO, wholeStacks)
    local limits, known, counts, metadata = {}, {}, {}, {}
    local generatedLimits = {}
    for _, node in ipairs(plan.nodes or {}) do
        local limit = tonumber(node.outputMaxCount)
        if node.outputMode ~= "static" or not limit or limit < 1 then
            generatedLimits[node.target] = false
        elseif generatedLimits[node.target] ~= false then
            generatedLimits[node.target] = math.min(
                generatedLimits[node.target] or 64, math.floor(limit))
        end
    end
    local function stackLimit(name)
        if limits[name] then return limits[name] end
        local limit = 64
        local observed = false
        for _, metadata in ipairs({
            (snapshot.localMetadata or {})[name] or {},
            (snapshot.stockMetadata or {})[name] or {},
            {maxCount = (snapshot.learnedStackLimits or {})[name]},
            {maxCount = generatedLimits[name]},
        }) do
            local value = tonumber(metadata.maxCount)
            if value and value >= 1 then
                limit = math.min(limit, math.floor(value))
                observed = true
            end
        end
        local learned = turtleIO.outputStackLimit(name)
        if learned and learned >= 1 then
            limit = math.min(limit, math.floor(learned))
            observed = true
        end
        known[name] = observed
        limits[name] = observed and limit or 1
        return limits[name]
    end

    local function add(name, count)
        counts[name] = amount(counts[name]) + amount(count)
        if not metadata[name] then
            local item = {name = name, tags = {}}
            for _, source in ipairs({
                (snapshot.localMetadata or {})[name] or {},
                (snapshot.stockMetadata or {})[name] or {},
            }) do
                item.hasNbt = item.hasNbt or source.hasNbt
                for tag, enabled in pairs(source.tags or {}) do
                    if enabled then item.tags[tag] = true end
                end
            end
            metadata[name] = item
        end
    end
    local physical, slotCounts = {}, {}
    if not wholeStacks then
        for _, item in pairs(snapshot.localStacks or {}) do
            if type(item) == "table" and item.name and amount(item.count) > 0 then
                local entry = physical[item.name] or {count = 0, slots = 0}
                entry.count = entry.count + amount(item.count)
                entry.slots = entry.slots + 1
                physical[item.name] = entry
            end
        end
    end
    local function storageLimit(name)
        local limit = stackLimit(name)
        -- Aggregated IDs do not prove that different component variants merge.
        if ((snapshot.localMetadata or {})[name] or {}).hasNbt
            or ((snapshot.stockMetadata or {})[name] or {}).hasNbt then
            return 1
        end
        return limit
    end
    local localSlots = 0
    for name, count in pairs(plan.baselineLocal or {}) do
        count = amount(count)
        local observed = physical[name]
        local slots
        if observed then
            -- Existing upgraded stacks already occupy these physical slots.
            -- Never expand them into imaginary native stacks or merge variants.
            slots = math.min(observed.slots, count)
                + math.ceil(math.max(0, count - observed.count) / storageLimit(name))
        else
            slots = math.ceil(count / storageLimit(name))
        end
        slotCounts[name] = slots
        localSlots = localSlots + slots
        add(name, count)
    end
    local reserved = math.max(localSlots, amount(snapshot.occupiedSlots))
    for _, item in ipairs(plan.requests or {}) do
        local slots = math.ceil(amount(item.count) / storageLimit(item.name))
        reserved = reserved + slots
        slotCounts[item.name] = amount(slotCounts[item.name]) + slots
        add(item.name, item.count)
    end
    local function recipeInputs(node)
        local used = {}
        for _, entry in ipairs(node.slots or {}) do
            local only, ambiguous
            for name, count in pairs(counts) do
                if count > 0 and ItemMatcher.matchesIngredient(metadata[name], entry.ingredient) then
                    if only then ambiguous = true; break end
                    only = name
                end
            end
            -- Only credit consumption which every possible physical selection
            -- must perform. Ambiguous alternatives retain their storage reserve.
            if only and not ambiguous then used[only] = amount(used[only]) + 1 end
        end
        return used
    end

    local capacity = amount(snapshot.inputSlots)
    if reserved > capacity then return reserved, capacity end
    local fragmentation = math.max(0, amount(snapshot.occupiedSlots) - localSlots)
    local function occupied(used, cycles, target, perCycle, limit)
        local slots = fragmentation
        for name, count in pairs(counts) do
            -- Retain the worst-case physical fragmentation after consumption.
            -- An ID alone cannot identify which component variant is pulled.
            local left = math.max(0, count - amount(used[name]) * cycles)
            if name == target then left = count end
            slots = slots + math.min(amount(slotCounts[name]), left)
        end
        if target then slots = slots + math.ceil(perCycle * cycles / limit) end
        return slots
    end
    local peak = reserved
    for index, node in ipairs(plan.nodes or {}) do
        local used = recipeInputs(node)
        local cycles = amount(node.crafts)
        -- Every output, the final one too, stays in the chest until the
        -- packager ships it, so each one reserves its slots.
        local nativeLimit = stackLimit(node.target)
        -- Static recipes have fixed components. Dynamic outputs may
        -- differ even when their native maxCount is known.
        local outputLimit = node.outputMode == "static" and nativeLimit or 1
        local perCycle = math.max(1, amount(node.outputPerCycle))
        if not known[node.target] then
            -- Unknown recipe remainders may replace consumed inputs.
            -- Keep their storage reserved until a fresh physical snapshot.
            peak = math.max(peak, occupied({}, 1, node.target, perCycle, 1))
            return peak, capacity, index
        end
        local cycle, checks = 1, 0
        while cycle <= cycles do
            peak = math.max(peak,
                occupied(used, cycle, node.target, perCycle, outputLimit))
            if peak > capacity then return peak, capacity end
            local outputSlots = math.ceil(cycle * perCycle / outputLimit)
            cycle = math.floor(outputSlots * outputLimit / perCycle) + 1
            checks = checks + 1
            if checks % 64 == 0 and type(sleep) == "function" then sleep(0) end
        end
        for name, perCycle in pairs(used) do
            counts[name] = math.max(0, amount(counts[name]) - perCycle * cycles)
            slotCounts[name] = math.min(amount(slotCounts[name]), counts[name])
        end
        add(node.target, node.outputCount)
        slotCounts[node.target] = amount(slotCounts[node.target])
            + math.ceil(amount(node.outputCount) / outputLimit)
        peak = math.max(peak, occupied({}, 0))
        if peak > capacity then return peak, capacity end
    end
    return peak, capacity
end

function Executor.new(options)
    options = options or {}
    return setmetatable({
        planner = assert(options.planner, "planner required"),
        supply = assert(options.supply, "supply required"),
        turtleIO = assert(options.turtleIO, "turtleIO required"),
        inputSide = options.inputSide,
        -- The packager on top ships the input chest when cleaning.
        packager = options.packager,
        shipAddress = options.shipAddress,
        sleep = options.sleep,
        logger = options.logger,
        resolveShadow = options.resolveShadow == true,
        blockedRecipes = options.blockedRecipes,
    }, Executor)
end

-- Empties the turtle into the input chest and ships the chest to the
-- warehouse (autocrafter.shipping).
function Executor:cleanInput()
    return Shipping.clean(self.turtleIO, self.packager, self.inputSide,
        {address = self.shipAddress, logger = self.logger, sleep = self.sleep})
end

function Executor:planBatch(request, snapshot, excludedRecipes, quiet)
    local function planFor(count)
        return self.planner:plan({
            target = request.target,
            count = count,
            excludedRecipes = excludedRecipes,
        }, snapshot)
    end
    local requested = amount(request.count or request.requestedOutput)
    local plan, planError = planFor(requested)
    if not plan and type(planError) == "table" and planError.code == "MISSING_RAW" and requested > 1 then
        -- Short of a raw: the most the stock allows now, then the shortage
        -- (2026-10-20: 165 sugar cane made no books; each turtle planned 64).
        local low, high = 1, requested - 1
        while low <= high do
            local count = math.floor((low + high) / 2)
            local candidate = planFor(count)
            if candidate then
                plan, low = candidate, count + 1
            else
                high = count - 1
            end
        end
        if plan then
            plan.shortage = planError
            if not quiet then logEvent(self.logger, "worker.partial_plan", {
                target = request.target, requestedOutput = requested, plannedOutput = plan.plannedOutput,
                missing = planError.target or planError.ingredient, needed = planError.needed,
            }) end
        end
    end
    if not plan then return nil, planError end

    local reserved, slots, probe = bufferReservation(plan, snapshot, self.turtleIO)
    plan.probeNodeIndex = probe
    if reserved <= slots then
        if not quiet then
            logEvent(self.logger, "worker.buffer_plan", {
                target = request.target, requestedOutput = requested,
                batchOutput = plan.plannedOutput, peakSlots = reserved, inputSlots = slots,
                probeTarget = probe and plan.nodes[probe].target or nil,
            })
        end
        return plan
    end

    local root = plan.nodes[plan.rootIndex]
    local yield = math.max(1, amount(root.outputPerCycle))
    local low, high = 1, amount(root.crafts) - 1
    local best, bestReserved
    local smallestReserved = reserved
    while low <= high do
        local cycles = math.floor((low + high) / 2)
        local candidate, candidateError = planFor(cycles * yield)
        if not candidate then
            return nil, candidateError
        end
        local needed, _, candidateProbe = bufferReservation(candidate, snapshot, self.turtleIO)
        candidate.probeNodeIndex = candidateProbe
        smallestReserved = math.min(smallestReserved, needed)
        if needed <= slots then
            best, bestReserved = candidate, needed
            low = cycles + 1
        else
            high = cycles - 1
        end
    end
    if not best then
        return nil, fail("INPUT_BUFFER_TOO_SMALL",
            "input or turtle staging buffer cannot hold one complete dependency batch", {
                target = request.target,
                inputSlots = slots,
                reservedSlots = smallestReserved,
                severity = "WARN",
            })
    end
    if not quiet then logEvent(self.logger, "worker.buffer_batch", {
        target = request.target,
        requestedOutput = requested,
        batchOutput = best.plannedOutput,
        inputSlots = slots,
        reservedSlots = bestReserved,
    }) end
    best.shortage = plan.shortage
    return best
end

-- A delivery window may span several safe execution batches. Simulate those
-- batches using only delivered stock before committing a larger remote order.
function Executor:planDelivery(request, snapshot, excludedRecipes)
    local base, err = self:planBatch(request, snapshot, excludedRecipes)
    if not base then return nil, err end
    local requested = amount(request.count or request.requestedOutput)
    if base.plannedOutput >= requested or base.probeNodeIndex or base.shortage then return base end

    local checks = 0
    local function candidate(count)
        local delivery = self.planner:plan({
            target = request.target, count = count, excludedRecipes = excludedRecipes,
        }, snapshot)
        if not delivery or amount(delivery.plannedOutput) <= amount(base.plannedOutput) then
            return nil
        end
        local projected = {
            localCounts = {}, localMetadata = {}, stockCounts = {},
            stockMetadata = snapshot.stockMetadata,
            learnedStackLimits = snapshot.learnedStackLimits,
            planningSearch = snapshot.planningSearch,
            inputSlots = snapshot.inputSlots, occupiedSlots = 0,
        }
        for name, value in pairs(snapshot.localCounts or {}) do
            projected.localCounts[name] = amount(value)
            projected.localMetadata[name] = (snapshot.localMetadata or {})[name]
        end
        for _, item in ipairs(delivery.requests or {}) do
            local name = item.name
            projected.localCounts[name] = amount(projected.localCounts[name]) + amount(item.count)
            local metadata = {name = name, tags = {}}
            for _, source in ipairs({
                (snapshot.localMetadata or {})[name] or {},
                (snapshot.stockMetadata or {})[name] or {},
            }) do
                local maximum = tonumber(source.maxCount)
                if maximum and maximum >= 1 then
                    metadata.maxCount = math.min(metadata.maxCount or 64, math.floor(maximum), 64)
                end
                metadata.hasNbt = metadata.hasNbt or source.hasNbt
                for tag, enabled in pairs(source.tags or {}) do
                    if enabled then metadata.tags[tag] = true end
                end
            end
            projected.localMetadata[name] = metadata
        end
        local occupied = bufferReservation({
            baselineLocal = snapshot.localCounts, requests = delivery.requests,
        }, snapshot, self.turtleIO, true)
        local function wholeSlots()
            projected.occupiedSlots = 0
            return bufferReservation({baselineLocal = projected.localCounts},
                projected, self.turtleIO, true)
        end
        -- Keep existing fragmentation reserved, while releasing ingredients
        -- consumed by completed batches and retaining rounded intermediate surplus.
        local whole = wholeSlots()
        local fragmentation = math.max(0, occupied - whole)
        projected.occupiedSlots = whole + fragmentation
        local remaining, first = amount(delivery.plannedOutput), nil
        while remaining > 0 do
            checks = checks + 1
            if checks > 128 then return nil end
            if checks % 8 == 0 and type(sleep) == "function" then sleep(0) end
            local batch = self:planBatch({
                target = request.target, count = remaining,
            }, projected, excludedRecipes, true)
            if not batch or batch.probeNodeIndex or #(batch.requests or {}) > 0
                or type(batch.localUsed) ~= "table"
                or amount(batch.plannedOutput) == 0 then return nil end
            first = first or batch
            for index, node in ipairs(batch.nodes or {}) do
                if index ~= batch.rootIndex then
                    projected.localCounts[node.target] = amount(projected.localCounts[node.target])
                        + amount(node.outputCount)
                end
            end
            for name, used in pairs(batch.localUsed) do
                local left = amount(projected.localCounts[name]) - amount(used)
                if left < 0 then return nil end
                projected.localCounts[name] = left > 0 and left or nil
            end
            projected.occupiedSlots = wholeSlots() + fragmentation
            remaining = remaining - amount(batch.plannedOutput)
        end
        return first, delivery
    end

    local best, delivery = candidate(requested)
    if not best then
        local low, high = amount(base.plannedOutput) + 1, requested - 1
        while low <= high and checks <= 128 do
            local count = math.floor((low + high) / 2)
            local execution, plannedDelivery = candidate(count)
            if execution then
                best, delivery = execution, plannedDelivery
                low = count + 1
            else
                high = count - 1
            end
        end
    end
    if not best then return base end
    logEvent(self.logger, "worker.delivery_window", {
        target = request.target, requestedOutput = requested,
        deliveryOutput = delivery.plannedOutput, batchOutput = best.plannedOutput,
        planningChecks = checks,
    })
    return best, nil, {
        requests = delivery.requests, baselineLocal = delivery.baselineLocal,
    }, delivery.plannedOutput
end

function Executor:executeBatch(request, active, checkpoint, hooks)
    hooks = hooks or {}
    active.phase = active.phase or "PLANNING"

    if not active.plan then
        active.phase = "PLANNING"
        active.current, active.waitingFor = nil, nil
        checkpoint(active)
        if hooks.onHeartbeat then hooks.onHeartbeat(active) end
        local planningStarted = os.clock()
        logEvent(self.logger, "worker.planning_started", {
            assignment = active.assignment, target = request.target,
            requestedOutput = request.count or request.requestedOutput,
        })
        local windowRemaining = math.max(0,
            amount(active.deliveryWindow and active.deliveryWindow.untilOutput)
                - amount(active.batchCompletedOutput))
        if windowRemaining == 0 then active.deliveryWindow = nil end
        local snapshot, snapshotError = self.supply:snapshot(windowRemaining > 0)
        if not snapshot then
            return nil, snapshotError
        end
        snapshot.learnedStackLimits = active.stackLimits
        local plan, planError, deliveryPlan, deliveryOutput
        if windowRemaining > 0 then
            plan, planError = self:planBatch({
                target = request.target,
                count = math.min(amount(request.count or request.requestedOutput), windowRemaining),
            }, snapshot, active.excludedRecipes)
        else
            plan, planError, deliveryPlan, deliveryOutput =
                self:planDelivery(request, snapshot, active.excludedRecipes)
        end
        logEvent(self.logger, "worker.planning_finished", {
            assignment = active.assignment, target = request.target,
            seconds = os.clock() - planningStarted,
            searchSteps = snapshot.planningSearch and snapshot.planningSearch.steps,
            code = planError and planError.code, message = planError and planError.message,
            nodes = plan and #plan.nodes,
        })
        if plan and self.resolveShadow then
            logEvent(self.logger, "worker.resolve_shadow", ResolveShadow.compare(
                request.target, plan.plannedOutput, plan, snapshot, {blocked = self.blockedRecipes}))
        end
        if not plan then
            if active.lastRecipeFailure and planError
                and planError.code ~= "INPUT_BUFFER_TOO_SMALL" then
                return nil, fail(
                    "RECIPE_ALTERNATIVES_EXHAUSTED",
                    "all usable recipes failed for " .. tostring(request.target),
                    {
                        target = request.target,
                        failedRecipes = active.excludedRecipes,
                        lastFailure = active.lastRecipeFailure,
                        planningFailure = planError,
                    }
                )
            end
            return nil, planError
        end
        local probe = plan.probeNodeIndex and plan.nodes[plan.probeNodeIndex]
        if probe and (active.stackLimitProbes or {})[probe.target] then
            return nil, fail("OUTPUT_STACK_LIMIT_UNAVAILABLE",
                "native stack limit unavailable after crafting " .. tostring(probe.target) ..
                    "; refusing to repeat discovery", {
                    target = probe.target, recipeId = probe.recipeId,
                })
        end
        active.plan = plan
        active.deliveryPlan = deliveryPlan
        if deliveryPlan then
            active.deliveryWindow = {
                untilOutput = amount(active.batchCompletedOutput) + amount(deliveryOutput),
            }
        end
        active.nodeIndex = 1
        active.nodeCrafts = 0
        active.phase = "PLANNED"
        checkpoint(active)
    end

    if not active.supply or not active.supply.complete then
        local supplied, supplyError = self.supply:deliver(
            active.deliveryPlan or active.plan,
            active,
            checkpoint,
            hooks.onHeartbeat
        )
        if not supplied then
            if type(supplyError) == "table" and supplyError.code == "STOCK_CHANGED" then
                active.supplyReplans = amount(active.supplyReplans) + 1
                logEvent(self.logger, "worker.supply_replan", {
                    assignment = active.assignment, name = supplyError.name,
                    requested = supplyError.requested, accepted = supplyError.accepted,
                    attempt = active.supplyReplans,
                })
                if active.supplyReplans > 3 then
                    return nil, fail("STOCK_CONTENTION",
                        "stock changed repeatedly while ordering; accepted deliveries have arrived",
                        {lastFailure = supplyError})
                end
                -- Replan only after the accepted shipment arrives, not while
                -- items are in transit. Preserve inputs and completed output.
                resetPlan(active, "REPLANNING")
                active.deliveryWindow = nil
                checkpoint(active)
                return self:executeBatch(request, active, checkpoint, hooks)
            end
            if deliveryTimedOut(supplyError) then
                active.phase = "CLEANING_INPUT"
                active.waitingFor = nil
                checkpoint(active)
                if hooks.onHeartbeat then
                    hooks.onHeartbeat(active)
                end

                local cleaned, cleanup = self:cleanInput()
                supplyError.cleanup = cleanup
                if not cleaned then
                    supplyError.code = "DELIVERY_CLEANUP_FAILED"
                    supplyError.message = "delivery timed out and input cleanup failed: " ..
                        tostring(cleanup and cleanup.error or "unknown cleanup failure")
                end
                active.phase = "FAILED"
                active.failure = supplyError
                checkpoint(active)
            end
            return nil, supplyError
        end
    end

    if not active.deliveryWindow then
        -- All ingredients for this batch have physically arrived. Discovery
        -- must finish this funded amount, not reorder the whole assignment.
        active.deliveryWindow = {
            untilOutput = amount(active.batchCompletedOutput) + amount(active.plan.plannedOutput),
        }
        checkpoint(active)
    end
    if active.deliveryPlan then
        active.deliveryPlan = nil
        checkpoint(active)
    end

    for index = active.nodeIndex or 1, #(active.plan.nodes or {}) do
        local node = active.plan.nodes[index]
        local completed = index == active.nodeIndex and amount(active.nodeCrafts) or 0
        local probe = index == active.plan.probeNodeIndex
        local expectedCrafts = probe and 1 or amount(node.crafts)
        local remaining = math.max(0, expectedCrafts - completed)
        active.waitingFor = nil
        active.phase = "CRAFTING"
        active.nodeIndex = index
        active.nodeCrafts = completed
        active.current = {
            target = node.target,
            recipeId = node.recipeId,
            step = index,
            steps = #active.plan.nodes,
        }
        checkpoint(active)

        if remaining > 0 then
            local final = index == active.plan.rootIndex
            local job = {
                assignment = active.assignment .. ":batch-" ..
                    tostring(active.batchIndex or 1) .. ":" .. tostring(index),
                target = node.target,
                recipeId = node.recipeId,
                requestedCrafts = remaining,
                outputPerCycle = node.outputPerCycle,
                inputSide = self.inputSide,
                resume = completed > 0,
            }
            local ok, result = self.turtleIO.craftJob(job, self.logger, {
                onProgress = function(crafts, output)
                    active.nodeCrafts = completed + amount(crafts)
                    local maximum = tonumber(self.turtleIO.outputStackLimit(node.target))
                    if maximum and maximum >= 1 then
                        active.stackLimits = active.stackLimits or {}
                        active.stackLimits[node.target] = math.min(
                            active.stackLimits[node.target] or 64, math.floor(maximum), 64)
                    end
                    if probe and active.nodeCrafts > 0 then
                        active.stackLimitProbes = active.stackLimitProbes or {}
                        active.stackLimitProbes[node.target] = true
                    end
                    checkpoint(active)
                    if final and hooks.onProgress then
                        hooks.onProgress(
                            active.nodeCrafts,
                            active.nodeCrafts * amount(node.outputPerCycle)
                        )
                    end
                    return true
                end,
            })
            local crafted = amount(result and result.craftedCrafts)
            active.nodeCrafts = completed + crafted
            checkpoint(active)
            if not ok or active.nodeCrafts < expectedCrafts then
                local message = result and result.error or "craft step failed"
                local recipeId = tostring(node.recipeId or "")
                local canFallback = active.nodeCrafts <= 0
                    and recipeId ~= ""
                    and retryableRecipeFailure(result)
                    and not ((active.excludedRecipes or {})[recipeId])
                if canFallback then
                    active.excludedRecipes = active.excludedRecipes or {}
                    active.excludedRecipes[recipeId] = true
                    active.lastRecipeFailure = {
                        target = node.target,
                        recipeId = recipeId,
                        step = index,
                        message = tostring(message),
                    }
                    resetPlan(active, "REPLANNING")
                    active.deliveryWindow = nil
                    checkpoint(active)
                    logEvent(self.logger, "worker.recipe_fallback", {
                        assignment = active.assignment,
                        target = node.target,
                        failedRecipeId = recipeId,
                        reason = tostring(message),
                    })
                    if hooks.onHeartbeat then
                        hooks.onHeartbeat(active)
                    end
                    return self:executeBatch(request, active, checkpoint, hooks)
                end
                return nil, fail(
                    ok and "MISSING_AFTER_DELIVERY" or "CRAFT_STEP_FAILED",
                    tostring(message),
                    {
                        target = node.target,
                        recipeId = node.recipeId,
                        step = index,
                        crafted = active.nodeCrafts,
                        expected = expectedCrafts,
                    }
                )
            end
        end

        if probe then
            active.stackLimitProbes = active.stackLimitProbes or {}
            active.stackLimitProbes[node.target] = true
            -- On a restart the output checkpoint can precede returning raw
            -- surplus. Return it before taking a fresh planning snapshot.
            if completed > 0 then
                local returned, err = self.turtleIO.returnInputs({
                    target = node.target, inputSide = self.inputSide,
                })
                if not returned then return nil, fail("INPUT_RETURN_FAILED", tostring(err)) end
            end
            logEvent(self.logger, "worker.stack_limit_learned", {
                target = node.target, completedCrafts = active.nodeCrafts,
                maxCount = (active.stackLimits or {})[node.target]
                    or self.turtleIO.outputStackLimit(node.target),
            })
            -- A probed target is this batch's output; planning it again
            -- from scratch would ask for the inputs it just used
            -- (2026-10-29: a diamond chest made, then "missing diamond x9").
            if index == active.plan.rootIndex then
                node.crafts = active.nodeCrafts
                node.outputCount = active.nodeCrafts * amount(node.outputPerCycle)
                active.plan.plannedOutput = node.outputCount
                break
            end
            resetPlan(active, "PLANNING")
            checkpoint(active)
            if hooks.onHeartbeat then hooks.onHeartbeat(active) end
            return self:executeBatch(request, active, checkpoint, hooks)
        end
        active.nodeIndex = index + 1
        active.nodeCrafts = 0
        checkpoint(active)
        if hooks.onHeartbeat then
            hooks.onHeartbeat(active)
        end
    end

    active.waitingFor = nil
    active.phase = "BATCH_DONE"
    checkpoint(active)
    local root = active.plan.nodes[active.plan.rootIndex]
    return {
        ok = true,
        craftedOutput = root and root.outputCount or active.plan.plannedOutput,
        requestedOutput = active.plan.requestedOutput,
        recipeId = root and root.recipeId,
        steps = #active.plan.nodes,
    }
end

function Executor:execute(request, active, checkpoint, hooks)
    hooks = hooks or {}
    local requested = amount(request.count or request.requestedOutput)
    if requested <= 0 then
        return nil, fail("INVALID_REQUEST", "requested output must be positive")
    end

    while amount(active.batchCompletedOutput) < requested do
        local outputBefore = amount(active.batchCompletedOutput)
        local craftsBefore = amount(active.batchCompletedCrafts)
        local result, err = self:executeBatch({
            target = request.target,
            count = requested - outputBefore,
        }, active, checkpoint, {
            onHeartbeat = hooks.onHeartbeat,
            onProgress = function(crafts, output)
                if hooks.onProgress then
                    hooks.onProgress(craftsBefore + amount(crafts),
                        outputBefore + amount(output))
                end
            end,
        })
        if not result then
            if type(err) == "table" then
                err.completedBatchOutput = outputBefore
            end
            return nil, err
        end
        if amount(result.craftedOutput) == 0 then
            return nil, fail("NO_CRAFT_PROGRESS", "craft batch produced no output")
        end

        local root = active.plan.nodes[active.plan.rootIndex]
        local shortage = active.plan.shortage
        active.batchCompletedOutput = outputBefore + amount(result.craftedOutput)
        active.batchCompletedCrafts = craftsBefore + amount(root.crafts)
        active.batchCompletedSteps = amount(active.batchCompletedSteps) + amount(result.steps)
        if active.deliveryWindow
            and active.batchCompletedOutput >= amount(active.deliveryWindow.untilOutput) then
            active.deliveryWindow = nil
        end
        active.batchLastRecipeId = result.recipeId
        active.lastRecipeFailure = nil
        active.supplyReplans = nil
        if active.batchCompletedOutput < requested then
            resetPlan(active, "PLANNING")
            active.batchIndex = amount(active.batchIndex or 1) + 1
        else
            active.deliveryPlan, active.current, active.waitingFor = nil, nil, nil
            active.phase = "DONE"
        end
        -- Commit the completed output and next batch together, before any new
        -- delivery. Restarting must not replay an already completed batch.
        checkpoint(active)
        if hooks.onHeartbeat then hooks.onHeartbeat(active) end
        -- A batch cut short by a missing raw used what the stock had: report
        -- the shortage now rather than trickle tiny batches as it refills.
        if shortage and active.batchCompletedOutput < requested then
            shortage.completedBatchOutput = active.batchCompletedOutput
            return nil, shortage
        end
    end

    return {
        ok = true,
        craftedOutput = amount(active.batchCompletedOutput),
        requestedOutput = requested,
        recipeId = active.batchLastRecipeId,
        steps = amount(active.batchCompletedSteps),
    }
end

return Executor
