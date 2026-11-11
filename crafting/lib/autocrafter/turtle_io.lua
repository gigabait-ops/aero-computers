local ItemMatcher = require("item_matcher")
local Recipes = require("recipes")
local Staging = require("autocrafter.staging")
local NetworkInput = require("autocrafter.network_input")
local RecipeGrid = require("autocrafter.recipe_grid")
local ItemFacts = require("autocrafter.item_facts")
local Call = require("autocrafter.recipe_call")

local Util = require("fleet_util")

-- The turtle's input chest is `inputSide`, a wired network name
-- (autocrafter.network_input); the packager on top ships it.
local TurtleIO = {}
local inputMetadata, outputStackLimits = {}, {}
local recipeGeneration, recipeCapabilities
local recipePlans = {}

local GRID_ORDER = RecipeGrid.ORDER
local CRAFT_SLOTS = RecipeGrid.POSITION
local NON_CRAFT_SLOTS = {4, 8, 12, 13, 14, 15, 16}
local MAX_STAGE_ATTEMPTS = 3

local logInfo = Util.log
local identity = RecipeGrid.identity
local matches = ItemMatcher.matchesIngredient
local cloneTags = ItemMatcher.cloneTags
local addInferredTags = ItemMatcher.addInferredTags
local ingredientText = ItemMatcher.ingredientText

local function logEnabled(logger)
    return logger and type(logger.info) == "function"
end

local function slotSummary(plan)
    local entries = {}
    for _, entry in ipairs((plan or {}).slots or {}) do
        local slot = entry.slot
        local ingredient = entry.ingredient
        table.insert(entries, {
            slot = tonumber(slot) or slot,
            text = tostring(slot) .. "=" .. ingredientText(ingredient)
        })
    end
    table.sort(entries, function(left, right)
        return tostring(left.slot) < tostring(right.slot)
    end)

    local parts = {}
    for _, entry in ipairs(entries) do
        table.insert(parts, entry.text)
    end
    return table.concat(parts, ",")
end

-- Boot check: the wired route to the input chest, or why there is none.
function TurtleIO.prepareInput(side)
    local route, err = NetworkInput.describe(side)
    return route ~= nil, route or err
end

-- turtle.craft, or why it cannot run (a turtle without a workbench).
local function craft(limit)
    if type(turtle.craft) ~= "function" then return false, "turtle.craft unavailable" end
    return turtle.craft(limit)
end

local function selectSlot(slot)
    return turtle.select(slot)
end

local function getCount(slot)
    return turtle.getItemCount(slot) or 0
end

local function getSpace(slot)
    return turtle.getItemSpace(slot) or 0
end

-- dropTo(side, count): the selected slot into the input chest.
local dropTo = NetworkInput.drop

local function getTurtleDetail(slot)
    local ok, detail = pcall(turtle.getItemDetail, slot)
    if not ok or type(detail) ~= "table" then return nil end
    local key = identity(detail)
    local metadata = inputMetadata[key]
    if not metadata and detail.nbt == nil then
        local fact = ItemFacts.shared():get(detail.name)
        if fact then
            metadata = {maxCount = fact.maxCount, tags = fact.tags, known = true}
            inputMetadata[key] = metadata
        end
    end
    if not metadata then
        local detailOk, value = pcall(turtle.getItemDetail, slot, true)
        if detailOk and type(value) == "table" and value.name == detail.name
            and value.nbt == detail.nbt then
            detail = value
            metadata = {maxCount = value.maxCount, tags = value.tags}
            inputMetadata[key] = metadata
        end
    end
    if metadata then detail.maxCount, detail.tags = metadata.maxCount, metadata.tags end
    detail._turtleSlot = slot
    -- Real tags from the snapshot need no guessing from the item name.
    if metadata and metadata.known then return detail end
    return addInferredTags(detail)
end

local bindingOwner, inputBindings = nil, {}
function TurtleIO.invalidatePeripherals()
    NetworkInput.invalidate()
    bindingOwner, inputBindings = peripheral, {}
    inputMetadata = {}
end

local function inputInventory(side)
    if bindingOwner ~= peripheral then TurtleIO.invalidatePeripherals() end
    if not inputBindings[side] then inputBindings[side] = peripheral.wrap(side) end
    return inputBindings[side]
end

local function inputItems(side)
    local inventory = inputInventory(side)
    local result = {}

    if not inventory or type(inventory.list) ~= "function" then
        return result
    end

    local ok, listed = pcall(inventory.list)
    if not ok or type(listed) ~= "table" then
        return result
    end

    local names = {}
    for _, item in pairs(listed) do
        if type(item) == "table" and type(item.name) == "string" and item.nbt == nil
            and not inputMetadata[identity(item)] then names[#names + 1] = item.name end
    end
    local known = #names > 0 and ItemFacts.shared():lookup(names) or nil
    for name, fact in pairs(known or {}) do
        inputMetadata[identity({name = name})] = {maxCount = fact.maxCount, tags = fact.tags, known = true}
    end

    for slot, item in pairs(listed) do
        if type(item) == "table" and type(item.name) == "string" and (tonumber(item.count) or 0) > 0 then
            local detail = item
            local key = identity(item)
            local metadata = inputMetadata[key]
            if not metadata and type(inventory.getItemDetail) == "function" then
                local detailOk, detailed = pcall(inventory.getItemDetail, slot)
                if detailOk and type(detailed) == "table" and detailed.name == item.name
                    and detailed.nbt == item.nbt
                then
                    metadata = {maxCount = detailed.maxCount, tags = detailed.tags}
                    inputMetadata[key] = metadata
                end
            end
            if metadata then
                detail = {name = item.name, count = item.count, nbt = item.nbt,
                    maxCount = metadata.maxCount, tags = metadata.tags}
            end

            local rawTags = detail.tags or item.tags
            local entry = {
                slot = slot,
                name = detail.name or item.name,
                count = tonumber(detail.count or item.count) or 0,
                nbt = detail.nbt or item.nbt,
                maxCount = detail.maxCount or item.maxCount,
                tags = type(rawTags) == "table" and cloneTags(rawTags) or nil
            }
            if not (metadata and metadata.known) then addInferredTags(entry) end
            table.insert(result, entry)
        end
    end

    table.sort(result, function(left, right)
        local leftSlot = tonumber(left.slot)
        local rightSlot = tonumber(right.slot)
        if leftSlot and rightSlot and leftSlot ~= rightSlot then
            return leftSlot < rightSlot
        end
        return tostring(left.slot) < tostring(right.slot)
    end)

    return result
end

-- Stacks and items in the input chest, for logs and the shipping loop.
function TurtleIO.inputDiagnostics(side)
    local function failed(err)
        return {ok = false, side = side, stacks = 0, items = 0, error = err}
    end
    local inventory = inputInventory(side)
    if not inventory or type(inventory.list) ~= "function" then
        return failed("input vault has no list")
    end

    local ok, listed = pcall(inventory.list)
    if not ok or type(listed) ~= "table" then
        return failed("input vault list failed")
    end

    local stacks = 0
    local items = 0
    local signatureParts = {}
    for slot, item in pairs(listed) do
        local count = type(item) == "table" and tonumber(item.count) or 0
        if count and count > 0 then
            stacks = stacks + 1
            items = items + count
            table.insert(signatureParts, tostring(slot) .. ":" .. tostring(item.name or "?") .. ":" .. tostring(count))
        end
    end
    table.sort(signatureParts)

    return {
        ok = true,
        side = side,
        stacks = stacks,
        items = items,
        signature = table.concat(signatureParts, "|")
    }
end

local function recipeSlots(plan)
    local result = {}
    for _, entry in ipairs((plan or {}).slots or {}) do
        if entry.ingredient ~= nil then
            result[#result + 1] = {
                slot = tonumber(entry.slot),
                ingredient = entry.ingredient,
                ingredientIndex = entry.ingredientIndex,
            }
        end
    end
    table.sort(result, function(left, right)
        return left.slot < right.slot
    end)
    return result
end

local function recipeSlotMap(plan)
    local result = {}
    for _, entry in ipairs(recipeSlots(plan)) do
        result[entry.slot] = entry.ingredient
    end
    return result
end

local clearCraftSlot
local clearSlotToInput

local function prepareCraftGrid(plan, job)
    local recipe = recipeSlotMap(plan)

    for slot = 1, 16 do
        if getCount(slot) > 0 then
            local detail = getTurtleDetail(slot)
            local ingredient = recipe[slot]
            local keep = ingredient and detail and matches(detail, ingredient)

            if CRAFT_SLOTS[slot] and not keep then
                local cleared, clearErr = clearCraftSlot(job, slot, nil, "prepare craft grid")
                if not cleared then
                    return false, clearErr or "input blocked clearing turtle"
                end
            elseif not CRAFT_SLOTS[slot] then
                local cleared, clearErr = clearSlotToInput(job, slot)
                if not cleared then
                    return false, clearErr or "cleanup blocked clearing turtle"
                end
            end
        end
    end

    return true
end

local function outputCapacityLimitedCrafts(plan, outputPerCycle)
    local perCycle = math.max(1, math.floor(tonumber(outputPerCycle) or 1))
    local stackLimit = tonumber((plan.result or {}).maxCount)
        or outputStackLimits[(plan.result or {}).id]
    local outputSlots = 16 - #recipeSlots(plan)
    -- An unknown result may be unstackable: reserve one slot per item.
    -- Probe once only when even one recipe output exceeds that bound.
    local capacity = math.floor(outputSlots * (stackLimit or 1) / perCycle)
    if not stackLimit then capacity = math.max(1, capacity) end
    return math.max(0, math.min(64, capacity))
end

function TurtleIO.outputStackLimit(target)
    return outputStackLimits[target]
end

local function inventorySnapshot()
    local parts = {}
    for slot = 1, 16 do
        local detail = getTurtleDetail(slot)
        if detail and getCount(slot) > 0 then
            table.insert(parts, tostring(slot) .. "=" .. tostring(detail.name) .. "x" .. tostring(getCount(slot)))
        end
    end
    return table.concat(parts, ",")
end

local function returnAllRawInputs(job, target)
    for slot = 1, 16 do
        selectSlot(slot)
        while getCount(slot) > 0 do
            local detail = getTurtleDetail(slot)
            if target and detail and detail.name == target then
                break
            end

            local cleared, clearErr = clearSlotToInput(job, slot)
            if not cleared then
                return false, clearErr or "cleanup blocked clearing turtle"
            end
        end
    end

    return true
end

clearSlotToInput = function(job, slot, logger, reason)
    selectSlot(slot)
    while getCount(slot) > 0 do
        local before = getCount(slot)
        if not dropTo(job.inputSide, getCount(slot)) then
            return false, "cleanup blocked clearing slot"
        end

        if getCount(slot) >= before then
            return false, "cleanup did not move item"
        end

        logInfo(logger, "worker.cleanup_slot", {
            slot = slot,
            movedTo = "input",
            reason = reason
        })
    end
    return true
end

local function bufferSlotFor(detail, sourceSlot)
    if detail then
        for _, slot in ipairs(NON_CRAFT_SLOTS) do
            if slot ~= sourceSlot and getCount(slot) > 0 and getSpace(slot) > 0 then
                local existing = getTurtleDetail(slot)
                if existing and existing.name == detail.name then
                    return slot
                end
            end
        end
    end

    for _, slot in ipairs(NON_CRAFT_SLOTS) do
        if slot ~= sourceSlot and getCount(slot) == 0 then
            return slot
        end
    end

    return nil
end

local function moveSlotToBuffer(slot)
    local detail = getTurtleDetail(slot)
    while getCount(slot) > 0 do
        local targetSlot = bufferSlotFor(detail, slot)
        if not targetSlot then
            return false, "no buffer slot clearing turtle"
        end

        local amount = math.min(getCount(slot), getSpace(targetSlot))
        if amount <= 0 then
            return false, "no buffer slot clearing turtle"
        end

        selectSlot(slot)
        local before = getCount(slot)
        local ok, err = turtle.transferTo(targetSlot, amount)
        if not ok or getCount(slot) >= before then
            return false, err or "buffer transfer failed"
        end
    end

    return true
end

clearCraftSlot = function(job, slot, logger, reason)
    local cleared, clearErr = clearSlotToInput(job, slot, logger, reason)
    if cleared then
        return true
    end

    local buffered, bufferErr = moveSlotToBuffer(slot)
    if not buffered then
        return false, bufferErr or clearErr or "cleanup blocked clearing turtle"
    end
    logInfo(logger, "worker.stage_clear_slot", {
        recipeSlot = slot,
        movedTo = "buffer",
        reason = reason
    })
    return true
end

-- Pushes each recipe slot's stacks straight from the input chest
-- (autocrafter.staging chooses the stacks and amounts).
local function stageInputsEven(plan, job, crafts, logger, grid)
    local side = job.inputSide
    local ok, err, count = Staging.stage(recipeSlots(plan), crafts, {
        preloadCrafts = job.requestedCrafts,
        accept = function(assigned, count, kinds, totals)
            return grid:accept(assigned, count, kinds, totals)
        end,
        count = getCount,
        detail = getTurtleDetail,
        matches = matches,
        transfer = function(from, to, amount)
            selectSlot(from)
            local before = getCount(to)
            local moved = turtle.transferTo(to, amount)
            return moved and getCount(to) - before == amount
        end,
        yield = os and os.sleep and function() os.sleep(0) end or nil,
        pause = os and os.sleep and function() os.sleep(0.1) end or nil,
        resync = function(reason, attempt)
            if attempt == 1 or attempt == 32 then
                logInfo(logger, "worker.stage_resync", {reason = reason, attempt = attempt})
            end
        end,
        list = function()
            return inputItems(side)
        end,
        push = function(item, target, amount)
            local moved, pushErr, fatal = NetworkInput.push(side, item.slot, target, amount, item)
            if moved and not matches(getTurtleDetail(target), {items = {item.name}}) then
                local before = getCount(target)
                dropTo(side, moved)
                return nil, "input source ingredient changed", getCount(target) ~= before - moved
            end
            return moved, pushErr, fatal
        end,
        drop = function(slot, amount)
            if amount <= 0 then return true end
            selectSlot(slot)
            local before = getCount(slot)
            local dropped = dropTo(side, amount)
            return dropped and before - getCount(slot) == amount
        end,
    })
    logInfo(logger, "worker.stage_direct", {crafts = count, error = err})
    return ok, err, count
end

local function validateStagedGrid(plan, crafts)
    local recipe = recipeSlotMap(plan)

    for slot, ingredient in pairs(recipe) do
        local detail = getTurtleDetail(slot)
        if not detail or getCount(slot) <= 0 then
            return false, "missing staged recipe slot " .. tostring(slot)
        end
        if not matches(detail, ingredient) then
            return false, "wrong item in recipe slot " .. tostring(slot), slot
        end
        if getCount(slot) < crafts then
            return false, "recipe slot " .. tostring(slot) .. " count " .. tostring(getCount(slot)) ..
                " expected " .. tostring(crafts)
        end
    end

    for _, slot in ipairs(GRID_ORDER) do
        if not recipe[slot] and getCount(slot) > 0 then
            return false, "unexpected item in non-recipe slot " .. tostring(slot), slot
        end
    end

    return true
end

local function freeOutputSlot()
    for _, slot in ipairs(NON_CRAFT_SLOTS) do
        if getCount(slot) == 0 then
            return slot
        end
    end

    for slot = 1, 16 do
        if not CRAFT_SLOTS[slot] and getSpace(slot) > 0 then
            return slot
        end
    end

    return nil
end

-- Every craft result, intermediate or final, goes back into the input chest.
local function dropCraftedOutput(job, target)
    local side = job.inputSide
    local pending = 0

    for slot = 1, 16 do
        local detail = getTurtleDetail(slot)
        if detail and detail.name == target and getCount(slot) > 0 then
            pending = pending + getCount(slot)
            selectSlot(slot)
            while getCount(slot) > 0 do
                if not dropTo(side, getCount(slot)) then
                    return false, pending
                end
            end
        end
    end

    return true, pending
end


local function validateTurtlePlanSlots(plan)
    local seen = {}
    local slots = {}

    for _, entry in ipairs((plan or {}).slots or {}) do
        local numberSlot = tonumber(entry.slot)
        if not numberSlot or numberSlot < 1 or numberSlot > 16 or numberSlot % 1 ~= 0 then
            return false, "invalid recipe slot " .. tostring(entry.slot)
        end
        if not tonumber(entry.ingredientIndex) or entry.ingredientIndex < 1
            or entry.ingredientIndex % 1 ~= 0 then
            return false, "native ingredientIndex missing for recipe slot " .. tostring(numberSlot)
        end
        if type(entry.ingredient) ~= "table" then
            return false, "missing native ingredient for recipe slot " .. tostring(numberSlot)
        end
        table.insert(slots, numberSlot)
    end

    table.sort(slots)

    for _, numberSlot in ipairs(slots) do
        if not CRAFT_SLOTS[numberSlot] then
            return false, "non-turtle recipe slot " .. tostring(numberSlot) ..
                " from recipes.plan; expected turtle inventory slots 1,2,3,5,6,7,9,10,11"
        end
        if seen[numberSlot] then
            return false, "duplicate recipe slot " .. tostring(numberSlot)
        end
        seen[numberSlot] = true
    end

    return true
end

-- After a datapack reload keep the cached recipes whose snapshot fingerprint is
-- unchanged (validateRecords), so a worker does not read them again. The grid
-- is still previewed under the new generation before every craft.
local function keepUnchanged(plans, fingerprints, generation)
    if not fingerprints then return {} end
    local refs = {}
    for id, cached in pairs(plans) do
        if type(cached.record.fingerprint) == "table" then
            refs[#refs + 1] = {id = id, fingerprint = cached.record.fingerprint}
        end
    end
    if #refs == 0 then return {} end
    local ok, checked = Call.pcall(Recipes.validateRecords, refs, {expectedGeneration = generation})
    local kept = {}
    for _, item in ipairs(ok and type(checked) == "table" and checked.items or {}) do
        if item.status == "unchanged" and plans[item.id] then kept[item.id] = plans[item.id] end
    end
    return kept
end

TurtleIO._keepUnchanged = keepUnchanged -- host tests

local function loadPlan(job)
    if type(job.recipeId) ~= "string" or job.recipeId == "" then
        return nil, "invalid recipe id"
    end
    if type(job.target) ~= "string" or job.target == "" then
        return nil, "invalid recipe target"
    end

    local outputPerCycle = tonumber(job.outputPerCycle)
    if not outputPerCycle or outputPerCycle <= 0 then
        return nil, "invalid recipe output count"
    end

    if not recipeCapabilities then
        local ok, capabilities = Call.pcall(Recipes.capabilities)
        local features = ok and type(capabilities) == "table" and capabilities.features or {}
        if not ok or type(capabilities) ~= "table" or capabilities.api_version ~= 2
            or not features.getDetails or not features.resultMaxCount
            or not features.projection or not features.expectedGeneration
            or not features.stackDetails or not features.planIngredientIndex
            or not features.preview or not features.matchesIngredient then
            return nil, "recipes (Recipe Atlas) exact-stack/runtime features required"
        end
        recipeCapabilities = capabilities
    end
    local metaOk, meta = Call.pcall(Recipes.meta)
    if not metaOk or type(meta) ~= "table" or not meta.ready then
        return nil, "native recipes snapshot is not ready"
    end
    local features = recipeCapabilities.features or {}
    local fingerprints = features.recordFingerprint and features.validateRecords
    if recipeGeneration ~= meta.generation then
        recipeGeneration = meta.generation
        recipePlans, outputStackLimits = keepUnchanged(recipePlans, fingerprints, recipeGeneration), {}
    end
    local cached = recipePlans[job.recipeId]
    if not cached then
        local ok, record, detailError = Call.pcall(Recipes.getDetails, job.recipeId, {
            fields = fingerprints and {"results", "fingerprint"} or {"results"},
            includeRaw = false, expectedGeneration = recipeGeneration,
        })
        if not ok then return nil, tostring(record) end
        if type(record) ~= "table" then return nil, tostring(detailError or "recipe not found") end
        local planOk, placement, planError = Call.pcall(Recipes.plan, job.recipeId, {
            align = "top_left", expectedGeneration = recipeGeneration,
        })
        if not planOk then return nil, tostring(placement) end
        if type(placement) ~= "table" then return nil, tostring(planError or "turtle plan not found") end
        cached = {record = record, slots = placement.slots}
        recipePlans[job.recipeId] = cached
    end
    local result
    for _, item in ipairs(cached.record.results or {}) do
        if item.id == job.target then result = item; break end
    end
    if not result then return nil, "recipe target mismatch" end
    if tonumber(result.count) ~= outputPerCycle then return nil, "recipe output count changed" end
    local maximum
    if cached.record.output_mode == "static" then
        maximum = tonumber(result.maxCount)
        if not maximum or maximum < 1 or maximum ~= math.floor(maximum) then
            return nil, "static recipe output maxCount unavailable"
        end
    end
    local plan = {
        recipe = job.recipeId,
        generation = recipeGeneration,
        outputMode = cached.record.output_mode,
        result = {id = job.target, count = outputPerCycle, maxCount = maximum},
        slots = cached.slots,
        -- matchesIngredients: checks per call for the no-match diagnosis.
        batchChecks = features.matchesIngredients
            and math.max(1, math.floor(tonumber((recipeCapabilities.limits or {}).maximumIngredientChecks) or 4))
            or nil,
    }
    local validSlots, slotErr = validateTurtlePlanSlots(plan)
    if not validSlots then
        return nil, slotErr
    end

    return plan
end

local function shallowCopyJob(job, requestedCrafts)
    local copy = {}
    for key, value in pairs(job or {}) do
        copy[key] = value
    end
    copy.requestedCrafts = requestedCrafts
    return copy
end

-- A craft that stopped before making anything.
local function stopped(state, err)
    return {state = state, error = err, craftedCrafts = 0, craftedOutput = 0}
end

local function isInputShortage(result)
    return type(result) == "table" and result.state == "WAITING" and Staging.inputFailure(result.error)
end

function TurtleIO.returnInputs(job)
    return returnAllRawInputs(job, job.target)
end

function TurtleIO.craftJob(job, logger, hooks)
    hooks = hooks or {}
    inputMetadata = {}
    local plan, planErr = loadPlan(job or {})
    if not plan then
        logInfo(logger, "worker.plan_error", {
            recipeId = job and job.recipeId,
            target = job and job.target,
            error = planErr
        })
        return false, stopped("ERROR", planErr)
    end

    if logEnabled(logger) then
        logInfo(logger, "worker.plan", {
            assignment = job.assignment,
            recipeId = job.recipeId,
            target = job.target,
            result = plan.result and plan.result.id,
            outputPerCycle = plan.result and plan.result.count,
            requestedCrafts = job.requestedCrafts,
            slots = slotSummary(plan)
        })

        logInfo(logger, "worker.input", TurtleIO.inputDiagnostics(job.inputSide))
    end

    local grid = RecipeGrid.new(plan,
        function(slot, detailed) return turtle.getItemDetail(slot, detailed) end,
        function(seconds) os.sleep(seconds) end)

    local target = job.target or (plan.result or {}).id
    local outputOk, pendingOutput = dropCraftedOutput(job, target)
    if not outputOk then
        logInfo(logger, "worker.output_blocked", {
            target = target,
            pendingOutput = pendingOutput
        })
        return false, stopped("WAITING", "output blocked")
    end

    local perCycle = math.max(1, tonumber((plan.result or {}).count) or tonumber(job.outputPerCycle) or 1)
    if (pendingOutput or 0) > 0 and job.resume == true then
        logInfo(logger, "worker.output_flushed", {
            target = target,
            craftedOutput = pendingOutput
        })
        return true, {
            craftedCrafts = math.floor(pendingOutput / perCycle),
            craftedOutput = pendingOutput
        }
    end

    local function attemptCraft(batchJob, attempt)
        grid.preloadCrafts = batchJob.requestedCrafts
        local cleared, clearErr = prepareCraftGrid(plan, batchJob)
        if not cleared then
            if logEnabled(logger) then
                logInfo(logger, "worker.clear_error", {
                    error = clearErr,
                    inventory = inventorySnapshot()
                })
            end
            return false, stopped("WAITING", clearErr)
        end

        local crafts = math.min(64, math.max(0, tonumber(batchJob.requestedCrafts) or 0),
            outputCapacityLimitedCrafts(plan, (plan.result or {}).count))
        logInfo(logger, "worker.max_craftable", {
            assignment = batchJob.assignment,
            recipeId = batchJob.recipeId,
            requestedCrafts = batchJob.requestedCrafts,
            crafts = crafts,
            attempt = attempt
        })
        if crafts <= 0 then
            return false, stopped("WAITING", "missing input")
        end

        local staged, stageErr, stagedCrafts = stageInputsEven(plan, batchJob, crafts, logger, grid)
        if not staged then
            if logEnabled(logger) then
                logInfo(logger, "worker.stage_retry", {
                    assignment = batchJob.assignment,
                    recipeId = batchJob.recipeId,
                    error = stageErr,
                    attempt = attempt,
                    inventory = inventorySnapshot()
                })
            end
            return nil, stopped("WAITING", stageErr)
        end
        if stagedCrafts and stagedCrafts < crafts then
            logInfo(logger, "worker.crafts_adjusted", {
                assignment = batchJob.assignment,
                recipeId = batchJob.recipeId,
                before = crafts,
                after = stagedCrafts,
                reason = "staged inputs rebalanced",
                attempt = attempt
            })
            crafts = stagedCrafts
        end

        local validGrid, gridErr, badSlot = validateStagedGrid(plan, crafts)
        if not validGrid then
            if logEnabled(logger) then
                logInfo(logger, "worker.stage_invalid", {
                    assignment = batchJob.assignment,
                    recipeId = batchJob.recipeId,
                    error = gridErr,
                    badSlot = badSlot,
                    inventory = inventorySnapshot()
                })
            end
            if badSlot then
                clearSlotToInput(batchJob, badSlot)
            else
                returnAllRawInputs(batchJob)
            end
            return nil, stopped("WAITING", "staging changed: " .. tostring(gridErr))
        end

        if logEnabled(logger) then
            logInfo(logger, "worker.craft_validate", {
                assignment = batchJob.assignment,
                recipeId = batchJob.recipeId,
                crafts = crafts,
                inventory = inventorySnapshot(),
                attempt = attempt
            })
        end
        -- A /reload in progress: wait for its recipe generation instead of
        -- failing the preview with stale_snapshot, then carry the plan over
        -- (loadPlan keeps a recipe whose fingerprint is unchanged).
        local fresh = Call.waitFresh(Recipes, 15)
        if fresh and fresh.ready == true and fresh.generation ~= plan.generation then
            local reloaded = loadPlan(job)
            if reloaded then
                plan.generation, plan.slots, plan.outputMode, plan.result =
                    reloaded.generation, reloaded.slots, reloaded.outputMode, reloaded.result
                grid.proof = nil
                logInfo(logger, "worker.recipes_refreshed", {recipeId = plan.recipe, generation = plan.generation})
            end
        end
        local preview, previewError, allowed = grid:validate(crafts)
        if not preview then
            local returned, returnError = returnAllRawInputs(batchJob)
            if returned and allowed == true then
                local result = stopped("WAITING", previewError)
                result.nativeNoMatch = true
                return nil, result
            end
            return false, stopped("ERROR", returned and previewError or
                (tostring(previewError) .. "; input return failed: " .. tostring(returnError)))
        end
        crafts = math.min(crafts, tonumber(allowed) or crafts)
        logInfo(logger, "worker.recipe_preview", {
            recipeId = plan.recipe, generation = plan.generation,
            outputMaxCount = preview.result.maxCount, batch = (preview.batch or {}).status,
        })
        local validRecipe, validateErr = craft(0)
        if not validRecipe then
            if logEnabled(logger) then
                logInfo(logger, "worker.craft_invalid", {
                    assignment = batchJob.assignment,
                    recipeId = batchJob.recipeId,
                    error = validateErr or "recipe validation failed",
                    inventory = inventorySnapshot()
                })
            end
            returnAllRawInputs(batchJob, target)
            return false, stopped("ERROR", "recipe validation failed: " .. tostring(validateErr or "No matching recipes"))
        end

        local outputSlot = freeOutputSlot()
        if not outputSlot then
            returnAllRawInputs(batchJob, target)
            return false, stopped("WAITING", "no output slot")
        end

        selectSlot(outputSlot)
        logInfo(logger, "worker.craft_start", {
            assignment = batchJob.assignment,
            crafts = crafts,
            outputSlot = outputSlot,
            attempt = attempt
        })
        local metaOk, currentMeta = Call.pcall(Recipes.meta)
        if not metaOk or type(currentMeta) ~= "table" or not currentMeta.ready
            or currentMeta.generation ~= plan.generation then
            local returned, returnError = returnAllRawInputs(batchJob, target)
            return false, stopped("ERROR", returned and "stale_snapshot: recipes changed before craft"
                or ("stale_snapshot; input return failed: " .. tostring(returnError)))
        end
        if not grid:unchanged() then
            local returned, returnError = returnAllRawInputs(batchJob)
            return nil, stopped("WAITING", returned and "staging changed after native preview" or returnError)
        end
        local crafted, craftErr = craft(crafts)
        if not crafted then
            if logEnabled(logger) then
                logInfo(logger, "worker.craft_error", {
                    assignment = batchJob.assignment,
                    error = craftErr or "craft failed",
                    inventory = inventorySnapshot()
                })
            end
            returnAllRawInputs(batchJob, target)
            return false, stopped("ERROR", craftErr or "craft failed")
        end

        local expectedTarget = batchJob.target or (plan.result or {}).id
        local actualDetail = getTurtleDetail(outputSlot)
        local actualOutput = actualDetail and actualDetail.name or nil
        local actualOutputCount = getCount(outputSlot)

        if not actualOutput or actualOutputCount <= 0 then
            logInfo(logger, "worker.craft_output_missing", {
                assignment = batchJob.assignment,
                recipeId = batchJob.recipeId,
                expectedTarget = expectedTarget,
                outputSlot = outputSlot
            })
            return false, stopped("ERROR", "craft produced no output")
        end

        if actualOutput ~= expectedTarget then
            logInfo(logger, "worker.craft_output_mismatch", {
                assignment = batchJob.assignment,
                recipeId = batchJob.recipeId,
                expectedTarget = expectedTarget,
                actualOutput = actualOutput,
                actualOutputCount = actualOutputCount
            })
            return false, stopped("ERROR", "recipe output mismatch: expected " .. tostring(expectedTarget) ..
                ", got " .. tostring(actualOutput))
        end

        outputStackLimits[expectedTarget] = tonumber(actualDetail.maxCount)
            or (actualOutputCount + getSpace(outputSlot))
        local outputOk, routedOutput = dropCraftedOutput(batchJob, expectedTarget)
        if not outputOk then
            logInfo(logger, "worker.output_blocked", {
                target = expectedTarget,
                actualOutput = actualOutput,
                pendingOutput = routedOutput
            })
            return false, stopped("WAITING", "output blocked")
        end

        local completedCrafts = math.floor(routedOutput / perCycle)
        if completedCrafts <= 0 or completedCrafts > crafts or routedOutput % perCycle ~= 0 then
            return false, {state = "ERROR", error = "craft output count mismatch",
                craftedCrafts = 0, craftedOutput = routedOutput}
        end
        logInfo(logger, "worker.craft_done", {
            assignment = batchJob.assignment,
            craftedCrafts = completedCrafts,
            craftedOutput = routedOutput,
            actualOutput = actualOutput,
            expectedTarget = expectedTarget,
            attempt = attempt
        })
        return true, {
            craftedCrafts = completedCrafts,
            craftedOutput = routedOutput
        }
    end

    local function runBatch(batchJob)
        grid.evaluations, grid.rejected = 0, {}
        local lastRetryResult, stagingAttempts = nil, 0
        for attempt = 1, 16 do
            local ok, result = attemptCraft(batchJob, attempt)
            if ok ~= nil then
                return ok, result
            end
            lastRetryResult = result
            if not result or not result.nativeNoMatch then
                stagingAttempts = stagingAttempts + 1
                if stagingAttempts >= MAX_STAGE_ATTEMPTS then break end
            end
        end

        return false, lastRetryResult or stopped("WAITING", "staging changed too often")
    end

    local requestedCrafts = math.max(0, math.floor(tonumber(job.requestedCrafts) or 0))
    local totalCraftedCrafts = 0
    local totalCraftedOutput = 0

    while totalCraftedCrafts < requestedCrafts do
        if type(hooks.beforeBatch) == "function" then
            local proceed, reason = hooks.beforeBatch(totalCraftedCrafts, totalCraftedOutput)
            if proceed == false then
                return false, {
                    state = "WAITING",
                    error = reason or "assignment lease unavailable",
                    craftedCrafts = totalCraftedCrafts,
                    craftedOutput = totalCraftedOutput
                }
            end
        end

        local remainingCrafts = requestedCrafts - totalCraftedCrafts
        local batchCrafts = math.min(64, remainingCrafts)
        local batchOk, batchResult = runBatch(shallowCopyJob(job, batchCrafts))

        if not batchOk then
            if isInputShortage(batchResult) then
                if totalCraftedCrafts <= 0 and totalCraftedOutput <= 0 then
                    return false, stopped("WAITING", batchResult and batchResult.error or "missing input")
                end

                return true, {
                    craftedCrafts = totalCraftedCrafts,
                    craftedOutput = totalCraftedOutput,
                    error = batchResult and batchResult.error or "missing input"
                }
            end

            if type(batchResult) == "table" then
                batchResult.craftedCrafts = totalCraftedCrafts
                batchResult.craftedOutput = totalCraftedOutput
            end
            return false, batchResult
        end

        local craftedCrafts = math.max(0, math.floor(tonumber(batchResult and batchResult.craftedCrafts) or 0))
        local craftedOutput = math.max(0, math.floor(tonumber(batchResult and batchResult.craftedOutput) or 0))
        totalCraftedCrafts = totalCraftedCrafts + craftedCrafts
        totalCraftedOutput = totalCraftedOutput + craftedOutput

        if craftedCrafts > 0 and type(hooks.onProgress) == "function" then
            local progressOk, accepted, progressErr = pcall(hooks.onProgress, totalCraftedCrafts, totalCraftedOutput)
            if not progressOk or accepted == false then
                return false, {
                    state = "WAITING",
                    error = "progress checkpoint failed: " .. tostring(progressOk and progressErr or accepted),
                    craftedCrafts = totalCraftedCrafts,
                    craftedOutput = totalCraftedOutput
                }
            end
        end

        if craftedCrafts <= 0 then
            break
        end
    end

    local returned, returnErr = returnAllRawInputs(job, target)
    if not returned then
        return false, {state = "WAITING", error = returnErr or "input blocked returning staged surplus",
            craftedCrafts = totalCraftedCrafts, craftedOutput = totalCraftedOutput}
    end
    return true, {
        craftedCrafts = totalCraftedCrafts,
        craftedOutput = totalCraftedOutput
    }
end

-- Empties every turtle slot into the input chest (cleaning before a job, when
-- idle and after a delivery timeout); the caller then ships the chest
-- (autocrafter.shipping). Items already staged inside the turtle count too:
-- a free turtle slot never means the cleanup finished.
function TurtleIO.emptyIntoInput(command)
    local inputSide = command.inputSide
    local movedStacks, movedItems = 0, 0
    for slot = 1, 16 do
        local hadItems = getCount(slot) > 0
        selectSlot(slot)
        while getCount(slot) > 0 do
            local before = getCount(slot)
            local dropped = dropTo(inputSide, before)
            local after = getCount(slot)
            movedItems = movedItems + math.max(0, before - after)
            if not dropped or after >= before then
                return false, {
                    error = "input blocked clearing turtle slot " .. tostring(slot),
                    inputSide = inputSide,
                    movedStacks = movedStacks, movedItems = movedItems,
                    remainingSlot = slot, remainingItems = after,
                }
            end
        end
        if hadItems then movedStacks = movedStacks + 1 end
    end
    return true, {inputSide = inputSide, movedStacks = movedStacks, movedItems = movedItems}
end

return TurtleIO
