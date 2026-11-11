local ItemMatcher = require("item_matcher")
local Recipes = require("recipes")
local Preflight = require("autocrafter.preflight")
local Call = require("autocrafter.recipe_call")
local Util = require("fleet_util")

local Planner = {}
Planner.__index = Planner

local amount = Util.amount

local lastYieldAt = 0
local function cooperativeYield(index)
    if index % 64 ~= 0 or type(sleep) ~= "function" then return end
    local now = os.epoch and os.epoch("utc") or os.clock() * 1000
    -- A yield costs a server tick. Fast table copies must not sleep every 64
    -- entries, while sustained CPU work must still let status/render tasks run.
    if now - lastYieldAt >= 25 or now < lastYieldAt then
        sleep(0)
        lastYieldAt = os.epoch and os.epoch("utc") or os.clock() * 1000
    end
end

local function copy(value, seen, progress)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    progress = progress or {count = 0}
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        progress.count = progress.count + 1
        cooperativeYield(progress.count)
        result[copy(key, seen, progress)] = copy(item, seen, progress)
    end
    return result
end

-- Fields are deep-copied, so a failure never shares tables with a planning branch.
local function failure(code, message, fields)
    local result = copy(fields or {})
    result.code = code
    result.message = message
    return result
end

local RESOURCE_FAILURE_CODES = {
    MISSING_RAW = true,
    NO_TURTLE_RECIPE = true,
    RECIPE_CYCLE = true,
}

local function isResourceFailure(value)
    return type(value) == "table" and RESOURCE_FAILURE_CODES[value.code] == true
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function ingredientKey(ingredient)
    return ItemMatcher.ingredientText(ingredient)
end

local function concreteAlternatives(ingredient, output)
    output = output or {}
    if type(ingredient) == "table" then
        for _, name in ipairs(ingredient.items or {}) do
            output[name] = true
        end
    end
    return output
end

local function nameSet(list)
    local set = {}
    for _, name in ipairs(list or {}) do set[name] = true end
    return set
end

-- An ingredient whose every alternative is returned by the craft (a tool such
-- as the Structurize build wand) is needed once per step, not once per craft.
-- Such recipes craft one at a time, so the returned item is staged again.
local function reusableIngredient(reusable, ingredient)
    local items = type(ingredient) == "table" and ingredient.items or nil
    if type(items) ~= "table" or #items == 0 then return false end
    for _, name in ipairs(items) do
        if not reusable[name] then return false end
    end
    return true
end

-- Recipe Atlas plan slots carry remainderHint; reuse "same_input" means the craft
-- hands that exact item back. Without a hint only the config says so.
local function returnedUnchanged(hint)
    local alternatives = type(hint) == "table" and hint.alternatives or nil
    if type(alternatives) ~= "table" or #alternatives == 0 or hint.truncated ~= false then
        return false
    end
    for _, alternative in ipairs(alternatives) do
        if type(alternative) ~= "table" or alternative.reuse ~= "same_input" then return false end
    end
    return true
end

local function metadataFor(snapshot, name)
    return (snapshot.localMetadata or {})[name]
        or (snapshot.stockMetadata or {})[name]
        or {name = name}
end





local function copyMap(source)
    local result = {}
    local index = 0
    for key, value in pairs(source or {}) do
        index = index + 1
        cooperativeYield(index)
        result[key] = value
    end
    return result
end

local function copyList(source)
    local result = {}
    for index, value in ipairs(source or {}) do
        cooperativeYield(index)
        result[index] = value
    end
    return result
end

local function copyBranch(branch)
    return {
        localCounts = copyMap(branch.localCounts),
        stockCounts = copyMap(branch.stockCounts),
        requests = copyMap(branch.requests),
        localUsed = copyMap(branch.localUsed),
        nodes = copyList(branch.nodes),
        recipeOrder = copyList(branch.recipeOrder),
        excludedRecipes = copyMap(branch.excludedRecipes),
        preference = amount(branch.preference),
        reciprocalConversions = amount(branch.reciprocalConversions),
    }
end

local function newBranch(snapshot, excludedRecipes)
    return {
        localCounts = copyMap(snapshot.localCounts),
        stockCounts = copyMap(snapshot.stockCounts),
        requests = {},
        localUsed = {},
        nodes = {},
        recipeOrder = {},
        excludedRecipes = copyMap(excludedRecipes),
        preference = 0,
        reciprocalConversions = 0,
    }
end

function Planner.new(options)
    options = options or {}
    return setmetatable({
        tagCandidates = options.tagCandidates or {},
        reusable = nameSet(options.reusableIngredients),
        blocked = nameSet(options.blockedRecipes),
        avoid = (function()
            local map = {}
            for recipe, names in pairs(options.avoidCandidates or {}) do map[recipe] = nameSet(names) end
            return map
        end)(),
        maxDepth = math.max(1, amount(options.maxDepth or 16)),
        maxNodes = math.max(1, amount(options.maxNodes or 256)),
        maxSearchSteps = math.max(1, amount(options.maxSearchSteps or 8192)),
        recipeGeneration = nil,
        recipeCache = {},
        reciprocalConversionCache = {},
    }, Planner)
end

-- Recipe rules from PC48 (blockedRecipes, avoidCandidates); they apply to the
-- next plan. Without them the worker keeps the rules it already has.
function Planner:setPolicy(policy)
    if type(policy) ~= "table" then return end
    self.blocked = nameSet(policy.blockedRecipes)
    local avoid = {}
    for recipe, names in pairs(policy.avoidCandidates or {}) do avoid[recipe] = nameSet(names) end
    self.avoid = avoid
end

-- One budget covers failed branches, native lookups and quantity simulations.
function Planner:spend()
    local search = self.search
    if not search then return end
    search.steps = search.steps + 1
    if search.steps > self.maxSearchSteps then
        error(failure("PLANNING_LIMIT",
            "recipe search budget exhausted for " .. search.target, {
                target = search.target, searchSteps = search.steps, severity = "WARN",
            }), 0)
    end
    cooperativeYield(search.steps)
end

function Planner:candidates(ingredient, snapshot, branch)
    local found = concreteAlternatives(ingredient)
    local preferred = {}

    local scanIndex = 0
    -- The native API already enumerates concrete alternatives.
    if next(found) == nil then
        for _, counts in ipairs({branch.localCounts or {}, branch.stockCounts or {}}) do
            for name in pairs(counts) do
                scanIndex = scanIndex + 1
                cooperativeYield(scanIndex)
                if ItemMatcher.matchesIngredient(metadataFor(snapshot, name), ingredient) then
                    found[name] = true
                end
            end
        end
    end

    for _, tag in ipairs((ingredient or {}).tags or {}) do
        tag = tostring(tag or ""):gsub("^#", "")
        local configured = self.tagCandidates[tag] or self.tagCandidates["#" .. tag] or {}
        for index, name in ipairs(configured) do
            found[name] = true
            preferred[name] = math.min(preferred[name] or math.huge, index)
        end
    end

    -- avoidCandidates: items that make this recipe's grid match another
    -- recipe the game prefers (Create Encased shaft + oak planks -> oak shaft).
    local avoid = self.avoid[branch.recipe or ""] or {}
    local candidates = {}
    local foundIndex = 0
    for name in pairs(found) do
        foundIndex = foundIndex + 1
        cooperativeYield(foundIndex)
        local metadata = metadataFor(snapshot, name)
        if not avoid[name] and ItemMatcher.matchesIngredient(metadata, ingredient) then
            candidates[#candidates + 1] = {
                name = name,
                available = amount(branch.localCounts[name]) + amount(branch.stockCounts[name]),
                preference = preferred[name] or math.huge,
            }
        end
    end

    table.sort(candidates, function(left, right)
        if left.available ~= right.available then
            return left.available > right.available
        end
        if left.preference ~= right.preference then
            return left.preference < right.preference
        end
        return left.name < right.name
    end)
    return candidates
end

local function consumeAvailable(branch, name, needed)
    local remaining = needed
    local localTake = math.min(amount(branch.localCounts[name]), remaining)
    if localTake > 0 then
        branch.localCounts[name] = amount(branch.localCounts[name]) - localTake
        branch.localUsed[name] = amount(branch.localUsed[name]) + localTake
        remaining = remaining - localTake
    end

    local stockBefore = amount(branch.stockCounts[name])
    local stockTake = math.min(stockBefore, remaining)
    if stockTake > 0 then
        branch.stockCounts[name] = stockBefore - stockTake
        branch.requests[name] = amount(branch.requests[name]) + stockTake
        branch.preference = branch.preference + (stockTake * math.max(1, stockBefore))
        remaining = remaining - stockTake
    end
    return remaining
end

local function recipeRequirements(plan)
    local grouped = {}
    for _, entry in ipairs((plan or {}).slots or {}) do
        local ingredient = entry.ingredient
        local key = ingredientKey(ingredient)
        grouped[key] = grouped[key] or {ingredient = ingredient, count = 0, returned = true}
        grouped[key].count = grouped[key].count + 1
        grouped[key].returned = grouped[key].returned and returnedUnchanged(entry.remainderHint)
    end
    return grouped
end

function Planner:refreshRecipes()
    if not self.recipePageSize then
        local ok, capabilities = Call.pcall(Recipes.capabilities)
        local features = ok and type(capabilities) == "table" and capabilities.features or {}
        local pageSize = ok and type(capabilities) == "table"
            and tonumber((capabilities.limits or {}).maximumPageSize)
        if not ok or type(capabilities) ~= "table" or capabilities.api_version ~= 2 or not features.resultMaxCount
            or not features.projection or not features.expectedGeneration
            or not pageSize or pageSize < 1 then
            return nil, failure("RECIPES_UNAVAILABLE", ok and "recipes API v2 snapshot features required"
                or tostring(capabilities), {})
        end
        self.recipePageSize = math.floor(pageSize)
        self.features = features
    end
    local ok, meta, metaError = Call.pcall(Recipes.meta)
    if ok and type(meta) == "table" and meta.ready == true and meta.refreshPending == true then
        -- Plan on the generation a /reload is about to publish, not the old one.
        meta = Call.waitFresh(Recipes, 15) or meta
    end
    if not ok then
        return nil, failure("RECIPES_UNAVAILABLE", tostring(meta), {})
    end
    if type(meta) ~= "table" then
        return nil, failure("RECIPES_UNAVAILABLE", tostring(metaError or "recipes.meta returned no snapshot"), {})
    end
    if meta.ready ~= true then
        return nil, failure("RECIPES_NOT_READY", "native recipes snapshot is not ready", {
            generation = meta.generation,
        })
    end
    if self.recipeGeneration ~= meta.generation then
        self.recipeGeneration = meta.generation
        self.recipeCache = {}
        self.reciprocalConversionCache = {}
    end
    return meta
end

local function resultFor(recipe, target)
    for _, result in ipairs((recipe or {}).results or {}) do
        if result.id == target then
            return result
        end
    end
    return nil
end

function Planner:plansFor(target)
    self:spend()
    if self.recipeCache[target] then
        return self.recipeCache[target]
    end

    local records = {}
    local cursor = nil
    repeat
        self:spend()
        local ok, page = Call.pcall(Recipes.craftingFor, target, {
            limit = self.recipePageSize,
            cursor = cursor,
            includeRaw = false,
            fields = {"workbench", "results", "support"},
            expectedGeneration = self.recipeGeneration,
        })
        if not ok then
            return nil, failure("RECIPE_LOOKUP_FAILED", tostring(page), {target = target})
        end
        if type(page) ~= "table" or type(page.items) ~= "table" then
            return nil, failure("RECIPE_LOOKUP_FAILED", "recipes.craftingFor returned an invalid page", {
                target = target,
            })
        end
        for _, recipe in ipairs(page.items) do
            records[#records + 1] = recipe
        end
        cursor = page.next_cursor
    until cursor == nil

    local plans = {}
    for index, recipe in ipairs(records) do
        self:spend()
        cooperativeYield(index)
        local result = resultFor(recipe, target)
        -- support.turtleLayout = false: no turtle layout, so no plan call.
        if recipe.workbench == "crafting_table" and result
            and (type(recipe.support) ~= "table" or recipe.support.turtleLayout ~= false) then
            local ok, placement = Call.pcall(Recipes.plan, recipe.id, {
                align = "top_left", expectedGeneration = self.recipeGeneration,
            })
            if not ok and tostring(placement):find("stale_snapshot", 1, true) then
                return nil, failure("RECIPE_LOOKUP_FAILED", tostring(placement), {target = target})
            end
            if ok and type(placement) == "table" and type(placement.slots) == "table" then
                plans[#plans + 1] = {
                    recipe = recipe.id,
                    result = result,
                    outputMode = recipe.output_mode,
                    slots = placement.slots,
                }
            end
        end
    end
    table.sort(plans, function(left, right)
        return tostring(left.recipe or "") < tostring(right.recipe or "")
    end)
    self.recipeCache[target] = plans
    return plans
end

local function alternativeCount(alternatives)
    local count = 0
    for _ in pairs(alternatives or {}) do
        count = count + 1
    end
    return count
end

local function planConsumes(plan, target, exactOnly)
    for _, entry in ipairs((plan or {}).slots or {}) do
        local ingredient = entry.ingredient
        local alternatives = concreteAlternatives(ingredient)
        if alternatives[target] and (not exactOnly or alternativeCount(alternatives) == 1) then
            return true
        end
    end
    return false
end

local function planConsumesExact(plan, target)
    return planConsumes(plan, target, true)
end

local function planConsumesAlternative(plan, target)
    return planConsumes(plan, target, false)
end

function Planner:isReciprocalConversion(target, plan)
    self:spend()
    local cacheKey = tostring(target) .. "\0" .. tostring(plan.recipe or plan)
    local cached = self.reciprocalConversionCache[cacheKey]
    if cached ~= nil then
        return cached
    end

    for _, entry in ipairs((plan or {}).slots or {}) do
        local ingredient = entry.ingredient
        for candidate in pairs(concreteAlternatives(ingredient)) do
            if candidate ~= target then
                local reversePlans = self:plansFor(candidate)
                for _, reversePlan in ipairs(reversePlans or {}) do
                    if (reversePlan.result or {}).id == candidate
                        and planConsumesAlternative(reversePlan, target) then
                        self.reciprocalConversionCache[cacheKey] = true
                        return true
                    end
                end
            end
        end
    end
    self.reciprocalConversionCache[cacheKey] = false
    return false
end

function Planner:isExactReciprocalConversion(target, plan)
    self:spend()
    for _, entry in ipairs((plan or {}).slots or {}) do
        local alternatives = concreteAlternatives(entry.ingredient)
        if alternativeCount(alternatives) == 1 then
            for candidate in pairs(alternatives) do
                if candidate ~= target then
                    local reversePlans = self:plansFor(candidate)
                    for _, reversePlan in ipairs(reversePlans or {}) do
                        if (reversePlan.result or {}).id == candidate
                            and planConsumesExact(reversePlan, target) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

function Planner:eligiblePlans(target, plans, excludedRecipes)
    local independent = {}
    local broadConversions = {}
    local exactReciprocal = {}

    for planIndex, plan in ipairs(plans or {}) do
        cooperativeYield(planIndex)
        if self:isReciprocalConversion(target, plan) then
            if self:isExactReciprocalConversion(target, plan) then
                exactReciprocal[#exactReciprocal + 1] = plan
            else
                broadConversions[#broadConversions + 1] = plan
            end
        else
            independent[#independent + 1] = plan
        end
    end

    local ordered = {}
    local function appendAvailable(source)
        for _, plan in ipairs(source) do
            local recipeId = tostring(plan.recipe or "")
            if not (excludedRecipes or {})[recipeId] and not self.blocked[recipeId] then
                ordered[#ordered + 1] = plan
            end
        end
    end

    appendAvailable(independent)
    appendAvailable(broadConversions)
    if #independent == 0 then
        appendAvailable(exactReciprocal)
    end
    return ordered
end

function Planner:hasIndependentPlan(target)
    local plans = self:plansFor(target)
    for _, plan in ipairs(plans or {}) do
        if (plan.result or {}).id == target
            and type(plan.slots) == "table"
            and not self:isReciprocalConversion(target, plan)
        then
            return true
        end
    end
    return false
end

function Planner:resolveRequirement(branch, ingredient, needed, snapshot, path, depth)
    self:spend()
    local candidates = self:candidates(ingredient, snapshot, branch)
    if #candidates == 0 then
        return nil, failure("UNKNOWN_TAG_CANDIDATES",
            "no proven candidate for " .. ingredientKey(ingredient), {
            ingredient = ingredientKey(ingredient),
            needed = needed,
            path = copy(path),
            severity = "WARN",
        })
    end

    local parentTarget = path[#path]
    local usableCandidates = {}
    for _, candidate in ipairs(candidates) do
        if #candidates == 1 or candidate.name ~= parentTarget then
            usableCandidates[#usableCandidates + 1] = candidate
        end
    end
    if #usableCandidates == 0 then
        return nil, failure("RECIPE_CYCLE",
            "ingredient resolves only to the item currently being produced: " ..
                ingredientKey(ingredient), {
            ingredient = ingredientKey(ingredient),
            target = parentTarget,
            needed = needed,
            path = copy(path),
        })
    end

    local remaining = needed
    for candidateIndex, candidate in ipairs(usableCandidates) do
        cooperativeYield(candidateIndex)
        if remaining <= 0 then
            break
        end
        remaining = consumeAvailable(branch, candidate.name, remaining)
    end
    if remaining <= 0 then
        return branch
    end

    local independentCandidates = {}
    local conversionCandidates = {}
    for _, candidate in ipairs(usableCandidates) do
        if self:hasIndependentPlan(candidate.name) then
            independentCandidates[#independentCandidates + 1] = candidate
        else
            conversionCandidates[#conversionCandidates + 1] = candidate
        end
    end
    local productionCandidates = {}
    for _, candidate in ipairs(independentCandidates) do
        productionCandidates[#productionCandidates + 1] = candidate
    end
    if #usableCandidates == 1 then
        for _, candidate in ipairs(conversionCandidates) do
            productionCandidates[#productionCandidates + 1] = candidate
        end
    end

    local bestError = nil
    local resourceError = nil
    for candidateIndex, candidate in ipairs(productionCandidates) do
        cooperativeYield(candidateIndex)
        local trial = copyBranch(branch)
        local planned, producedOrError = self:planItem(candidate.name, remaining, snapshot, trial, path, depth + 1)
        if planned then
            local produced = producedOrError
            trial = planned
            trial.localCounts[candidate.name] = amount(trial.localCounts[candidate.name]) + produced
            local after = consumeAvailable(trial, candidate.name, remaining)
            if after <= 0 then
                return trial
            end
        else
            if isResourceFailure(producedOrError) then
                resourceError = resourceError or producedOrError
            else
                bestError = bestError or producedOrError
            end
        end
    end

    if bestError then
        return nil, bestError
    end
    if resourceError and resourceError.code == "MISSING_RAW" then
        return nil, resourceError
    end

    local key = ingredientKey(ingredient)
    return nil, failure("MISSING_RAW",
        "missing " .. key .. " x" .. tostring(remaining) ..
            "; unavailable in stock and no non-cyclic turtle recipe can produce it", {
        ingredient = key,
        needed = remaining,
        path = copy(path),
        severity = "WARN",
        cause = resourceError and resourceError.code or nil,
        candidate = #usableCandidates == 1 and usableCandidates[1].name or nil,
        candidateCount = #usableCandidates,
    })
end

-- Every recipe of an item stopped on a missing raw: the smallest shortfall
-- leads and the others become `alternatives` (at most three). The first
-- failure used to lead, and recipe order is no preference: 1302 books said
-- "tree bark x576" (3 bark -> 1 paper) when sugar cane x192 had run out.
local function shortfallName(err)
    return err.target or err.ingredient
end

local function leadingShortfall(errors)
    local byName, names = {}, {}
    local function add(name, needed, err)
        if not name then return end
        if not byName[name] then
            names[#names + 1] = name
        elseif byName[name].needed <= needed then
            return
        end
        byName[name] = {needed = needed, err = err}
    end
    for _, err in ipairs(errors) do
        add(shortfallName(err), amount(err.needed), err)
        for _, other in ipairs(err.alternatives or {}) do
            add(other.target, amount(other.needed), nil)
        end
    end
    table.sort(names, function(left, right)
        local a, b = byName[left].needed, byName[right].needed
        if a ~= b then return a < b end
        return left < right
    end)
    local lead = names[1]
    local result = copy(byName[lead].err or errors[1])
    result.alternatives = nil
    for index = 2, math.min(#names, 4) do
        result.alternatives = result.alternatives or {}
        result.alternatives[#result.alternatives + 1] = {target = names[index], needed = byName[names[index]].needed}
    end
    return result
end

local function withAlternatives(err)
    if type(err) == "table" and type(err.alternatives) == "table" and #err.alternatives > 0 then
        local words = {}
        for index, other in ipairs(err.alternatives) do
            words[index] = tostring(other.target) .. " x" .. tostring(other.needed)
        end
        err.message = tostring(err.message) .. "; or " .. table.concat(words, ", ")
    end
    return err
end

function Planner:planItem(target, requestedOutput, snapshot, branch, path, depth)
    self:spend()
    if depth > self.maxDepth then
        return nil, failure("MAX_DEPTH", "dependency depth exceeded", {
            target = target,
            path = copy(path),
        })
    end
    if path[target] then
        local cycle = copy(path)
        cycle[#cycle + 1] = target
        return nil, failure("RECIPE_CYCLE", "recipe dependency cycle at " .. target, {
            target = target,
            path = cycle,
        })
    end
    if #(branch.nodes or {}) >= self.maxNodes then
        return nil, failure("MAX_NODES", "craft plan node limit exceeded", {target = target})
    end

    local plans, plansError = self:plansFor(target)
    if not plans then
        return nil, plansError
    end
    if #plans == 0 then
        return nil, failure("MISSING_RAW",
            "missing " .. target .. " x" .. tostring(requestedOutput) ..
                "; unavailable in stock and has no turtle recipe", {
            target = target,
            needed = requestedOutput,
            path = copy(path),
            severity = "WARN",
        })
    end
    plans = self:eligiblePlans(target, plans, branch.excludedRecipes)

    local nextPath = copy(path)
    nextPath[target] = true
    nextPath[#nextPath + 1] = target
    local bestError = nil
    local missing = {}
    local rejected, rejectedOutput

    for planIndex, plan in ipairs(plans) do
        self:spend()
        cooperativeYield(planIndex)
        local result = plan.result or {}
        local yield = math.max(1, amount(result.count or 1))
        local recipeId = tostring(plan.recipe or "")
        if not branch.excludedRecipes[recipeId]
            and result.id == target and type(plan.slots) == "table"
        then
            local trial = copyBranch(branch)
            local cycles = math.max(1, math.ceil(requestedOutput / yield))
            local requirements = recipeRequirements(plan)
            local valid = true

            for requirementIndex, key in ipairs(sortedKeys(requirements)) do
                cooperativeYield(requirementIndex)
                local requirement = requirements[key]
                local uses = (requirement.returned
                    or reusableIngredient(self.reusable, requirement.ingredient)) and 1 or cycles
                trial.recipe = recipeId
                local resolved, resolveError = self:resolveRequirement(
                    trial,
                    requirement.ingredient,
                    requirement.count * uses,
                    snapshot,
                    nextPath,
                    depth
                )
                if not resolved then
                    valid = false
                    if not bestError or bestError.code == "RECIPE_CYCLE" then
                        bestError = resolveError
                    end
                    if type(resolveError) == "table" and resolveError.code == "MISSING_RAW" then
                        missing[#missing + 1] = resolveError
                    end
                    break
                end
                trial = resolved
            end

            if valid and #trial.nodes < self.maxNodes then
                if self:isReciprocalConversion(target, plan) then
                    trial.reciprocalConversions = amount(trial.reciprocalConversions) + 1
                end
                trial.nodes[#trial.nodes + 1] = {
                    id = "step-" .. tostring(#trial.nodes + 1),
                    target = target,
                    recipeId = plan.recipe,
                    crafts = cycles,
                    outputPerCycle = yield,
                    outputCount = cycles * yield,
                    outputMode = plan.outputMode,
                    outputMaxCount = plan.result.maxCount,
                    slots = copy(plan.slots),
                }
                trial.recipeOrder[#trial.recipeOrder + 1] = tostring(plan.recipe or "")
                -- Native whole-recipe constraints are not represented by item IDs.
                -- Rank exact one-craft previews, but never globally blacklist an
                -- ID on a sample, missing data, a busy runtime, or a count predicate.
                local status, preview = "ok", nil
                if plan.outputMode ~= "static" then
                    status, preview = self.preflight:evaluate(plan, trial.nodes, #trial.nodes - 1)
                end
                if status == "ok" then
                    trial.nodes[#trial.nodes].previewResult = preview
                    return trial, cycles * yield
                elseif status == "unknown" then
                    -- Missing exact data or exhausted admission cannot rank more
                    -- branches. Execution still validates the actual prepared grid.
                    return trial, cycles * yield
                elseif status == "no_match" and not rejected then
                    rejected, rejectedOutput = trial, cycles * yield
                end
            end
        end
    end

    if rejected then return rejected, rejectedOutput end
    if bestError and bestError.code == "MISSING_RAW" and #missing > 1 then
        return nil, leadingShortfall(missing)
    end
    return nil, bestError or failure("NO_TURTLE_RECIPE",
        "no usable turtle recipe for " .. target, {target = target, path = copy(path)})
end

-- How the recipes snapshot says a missing item is made (furnace, machine,
-- colony), added to a MISSING_RAW failure as `routes` and to its message.
-- An explanation only: it proves no machine, stock or colony recipe.
function Planner:annotateRoutes(err)
    if type(err) ~= "table" or err.code ~= "MISSING_RAW" or type(err.target) ~= "string"
        or not (self.features or {}).routes then
        return err
    end
    local ok, reply = Call.pcall(Recipes.routes, {err.target}, {
        limit = 4, expectedGeneration = self.recipeGeneration,
    })
    local item = ok and type(reply) == "table" and type(reply.items) == "table" and reply.items[1] or nil
    if type(item) ~= "table" then return err end
    local routes, words = {}, {}
    for _, route in ipairs(item.routes or {}) do
        if type(route) == "table" and route.category ~= "turtle" and #routes < 3 then
            local executor = ((route.requirements or {}).executors or {})[1]
            local via = route.workbench or (type(executor) == "table" and executor.id) or nil
            routes[#routes + 1] = {category = route.category, via = via, recipeId = route.recipeId}
            words[#words + 1] = tostring(route.category) .. (via and (" " .. tostring(via)) or "")
        end
    end
    if #routes > 0 then
        err.routes = routes
        err.message = tostring(err.message) .. "; made by " .. table.concat(words, ", ")
    end
    return err
end

local function requestEntries(requests)
    local result = {}
    for _, name in ipairs(sortedKeys(requests)) do
        local count = amount(requests[name])
        if count > 0 then
            result[#result + 1] = {name = name, count = count}
        end
    end
    return result
end

function Planner:plan(request, snapshot)
    request = request or {}
    snapshot = snapshot or {}
    local target = request.target
    local requestedOutput = amount(request.count or request.requestedOutput)
    if type(target) ~= "string" or target == "" then
        return nil, failure("INVALID_REQUEST", "target missing")
    end
    if requestedOutput <= 0 then
        return nil, failure("INVALID_REQUEST", "requested output must be positive", {target = target})
    end

    local _, recipeError = self:refreshRecipes()
    if recipeError then
        return nil, recipeError
    end

    if not snapshot.recipePreflight
        or snapshot.recipePreflight.generation ~= self.recipeGeneration then
        snapshot.recipePreflight = Preflight.new(snapshot, self.recipeGeneration)
    end
    self.preflight = snapshot.recipePreflight

    local search = snapshot.planningSearch
    if not search or search.generation ~= self.recipeGeneration then
        search = {target = target, generation = self.recipeGeneration,
            steps = 0}
        snapshot.planningSearch = search
    end
    self.search = search
    local ok, planned, producedOrError = pcall(self.planItem, self,
        target, requestedOutput, snapshot,
        newBranch(snapshot, request.excludedRecipes), {}, 1)
    self.search = nil
    if not ok then
        if type(planned) == "table" and planned.code == "PLANNING_LIMIT" then
            return nil, planned
        end
        error(planned, 0)
    end
    if not planned then
        return nil, withAlternatives(self:annotateRoutes(producedOrError))
    end

    local requests = requestEntries(planned.requests)
    return {
        target = target,
        requestedOutput = requestedOutput,
        plannedOutput = producedOrError,
        nodes = planned.nodes,
        rootIndex = #planned.nodes,
        requests = requests,
        baselineLocal = copy(snapshot.localCounts or {}),
        localUsed = planned.localUsed,
        recipeOrder = planned.recipeOrder,
        reciprocalConversions = amount(planned.reciprocalConversions),
    }
end

return Planner
