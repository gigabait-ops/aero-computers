-- Native recipe evaluation of a concrete allocation, never a recipe/API fallback.
local Recipes = require("recipes")
local Grid = {}
Grid.__index = Grid
-- The turtle slots of the 3x3 crafting grid, and slot -> grid position (1-9).
local ORDER = {1, 2, 3, 5, 6, 7, 9, 10, 11}
local POSITION = {}
for i, slot in ipairs(ORDER) do POSITION[slot] = i end
Grid.ORDER, Grid.POSITION = ORDER, POSITION

-- One key per item variant: id plus component hash.
local function identity(item)
    return tostring(item.name) .. "\0" .. tostring(item.nbt or "")
end
Grid.identity = identity

local busy = require("autocrafter.recipe_call").transient

-- Only admission failures are retried. Missing/unsupported data is never invented.
local function admitted(call, pause)
    for attempt = 1, 8 do
        local ok, value = pcall(call)
        if ok then return value end
        if not busy(value) or attempt == 8 then return nil, tostring(value) end
        pause(math.min(1, attempt * 0.25))
    end
end

local function exact(read, expected, pause)
    local expectedIdentity = expected and identity(expected)
    for attempt = 1, 8 do
        local ok, detail = pcall(read)
        if not ok then return nil, tostring(detail) end
        if not detail or (expectedIdentity and identity(detail) ~= expectedIdentity) then
            return nil, "staging changed: exact input identity changed"
        end
        local stack = detail.recipes
        if type(stack) == "table" and stack.status == "ok"
            and stack.scope == "actual_stack" and stack.id == detail.name
            and type(stack.componentsJson) == "string"
            and tonumber(stack.maxCount) and stack.maxCount >= 1 then
            return stack, nil, detail
        end
        local reason = stack and stack.reason or "exact stack details unavailable"
        if not busy(reason) or attempt == 8 then return nil, tostring(reason) end
        pause(math.min(1, attempt * 0.25))
    end
end

function Grid.new(plan, turtleDetail, pause)
    return setmetatable({
        plan = plan, turtleDetail = turtleDetail,
        pause = pause, rejected = {}, evaluations = 0,
    }, Grid)
end

-- One check result: the failing ingredient index, an error, or nothing.
local function verdict(check)
    if check.status == "ok" and check.matches == false then return check.ingredientIndex end
    if check.status ~= "ok" and check.status ~= "unsupported" then
        return nil, "ingredient check " .. tostring(check.status) .. ": "
            .. tostring(check.reason or "incomplete evaluation")
    end
end

-- After no_match: which ingredient rejects its staged stack. Recipe Atlas's
-- matchesIngredients takes four checks per call (same runtime tokens, fewer
-- calls); without it, one matchesIngredient per slot.
function Grid:failingIngredient(grid)
    local checks = {}
    for _, entry in ipairs(self.plan.slots) do
        checks[#checks + 1] = {ingredientIndex = entry.ingredientIndex, stack = grid[POSITION[entry.slot]]}
    end
    local options = {expectedGeneration = self.plan.generation}
    if not self.plan.batchChecks then
        for _, check in ipairs(checks) do
            local reply, err = admitted(function()
                return Recipes.matchesIngredient(self.plan.recipe, check.ingredientIndex, check.stack, options)
            end, self.pause)
            if not reply then return nil, err end
            reply.ingredientIndex = reply.ingredientIndex or check.ingredientIndex
            local failed, failure = verdict(reply)
            if failed or failure then return failed, failure end
        end
        return nil
    end
    local index, stalls = 1, 0
    while index <= #checks do
        local batch = {}
        for i = index, math.min(#checks, index + self.plan.batchChecks - 1) do batch[#batch + 1] = checks[i] end
        local reply, err = admitted(function()
            return Recipes.matchesIngredients(self.plan.recipe, batch, options)
        end, self.pause)
        if not reply then return nil, err end
        for _, item in ipairs(reply.items or {}) do
            local failed, failure = verdict(item)
            if failed or failure then return failed, failure end
        end
        if reply.complete then
            index = index + #batch
        else
            -- Admission ran out part way: resume at the first unchecked entry.
            local done = math.max(0, (tonumber(reply.nextIndex) or 1) - 1)
            stalls = done == 0 and stalls + 1 or 0
            if stalls >= 8 then return nil, "ingredient check runtime_busy: " .. tostring(reply.reason) end
            index = index + done
            self.pause(0.25)
        end
    end
    return nil
end

function Grid:preview(grid)
    if self.evaluations >= 16 then return nil, "recipe input combination limit reached" end
    self.evaluations = self.evaluations + 1
    local result, err = admitted(function()
        return Recipes.preview(self.plan.recipe, grid, {
            limit = 64, expectedGeneration = self.plan.generation,
        })
    end, self.pause)
    if not result then return nil, err end
    if result.status == "no_match" then return false end
    if result.status ~= "ok" then
        return nil, "recipe preview " .. tostring(result.status) .. ": "
            .. tostring(result.reason or result.error or "incomplete evaluation")
    end
    if result.generation ~= self.plan.generation then return nil, "stale_snapshot" end
    local output = result.result or {}
    if output.id ~= self.plan.result.id or output.count ~= self.plan.result.count then
        return nil, "recipe validation failed: actual result differs from requested target/count"
    end
    if not tonumber(output.maxCount) or output.maxCount < 1
        or output.maxCount % 1 ~= 0 then return nil, "recipe result maxCount unavailable" end
    return result
end

-- Allocation uses lightweight identities/counts only. Upgraded input inventories
-- may legally exceed vanilla stack limits and cannot supply runtime descriptors.
function Grid:accept(assigned, crafts, kinds, totals)
    local expected = {}
    local parts = {tostring(crafts), tostring(self.preloadCrafts)}
    for _, entry in ipairs(self.plan.slots) do
        local key = assigned[entry.slot]
        expected[entry.slot] = identity(kinds[key])
        parts[#parts + 1] = tostring(entry.slot) .. ":" .. expected[entry.slot]
            .. ":" .. tostring((totals or {})[key]) .. ":" .. tostring(kinds[key].maxCount)
    end
    local allocation = table.concat(parts, "\1")
    if self.rejected[allocation] then return false end
    self.expected, self.allocation = expected, allocation
    return true, nil, crafts
end

function Grid:validate(crafts)
    local basic, occupied, survivors = {}, 0, 0
    for slot = 1, 16 do
        local detail = self.turtleDetail(slot, false)
        if detail then
            basic[slot] = detail
            occupied = occupied + 1
            if (tonumber(detail.count) or 0) > 1 then survivors = survivors + 1 end
        end
    end
    for _, entry in ipairs(self.plan.slots) do
        local item = basic[entry.slot]
        if not item or identity(item) ~= (self.expected or {})[entry.slot]
            or item.count < crafts then
            return nil, "staging changed: prepared grid differs from native allocation"
        end
    end
    local identities = {}
    for _, entry in ipairs(self.plan.slots) do
        identities[#identities + 1] = tostring(entry.slot) .. ":" .. identity(basic[entry.slot])
    end
    local proofKey = table.concat(identities, "\1")
    local proof = self.proof
    if self.plan.outputMode ~= "static" or not proof
        or self.proofKey ~= proofKey or (proof.batch or {}).status ~= "bounded" then
        local grid = {}
        for _, entry in ipairs(self.plan.slots) do
            local stack, err = exact(function()
                return self.turtleDetail(entry.slot, true)
            end, basic[entry.slot], self.pause)
            if not stack then return nil, err end
            if stack.count ~= basic[entry.slot].count then
                return nil, "staging changed: input count changed during exact read"
            end
            grid[POSITION[entry.slot]] = {
                id = stack.id, count = stack.count, componentsJson = stack.componentsJson,
            }
        end
        local err
        proof, err = self:preview(grid)
        if proof == false then
            local failedIndex, checkErr = self:failingIngredient(grid)
            if checkErr then return nil, checkErr end
            -- Reject this allocation AND its quantity/stock context, not the item.
            -- Count-sensitive predicates may accept a smaller subsequent batch.
            self.rejected[self.allocation] = true
            return nil, "recipe validation failed: no_match"
                .. (failedIndex and (" at ingredient " .. tostring(failedIndex)) or ""), true
        end
        if not proof then return nil, err end
    end
    local bounded = (proof.batch or {}).status == "bounded"
    local hasRemainder = false
    for _, slot in ipairs(proof.slots or {}) do
        if (slot.remainder or {}).id then hasRemainder = true end
    end
    -- Recipe Atlas bounds template recipes too (a Sophisticated tier upgrade
    -- copies the input chest's data). Only custom whole-recipe predicates and
    -- returned remainders stay unbounded: those craft one at a time.
    if not bounded then crafts = 1 end
    local needed = math.ceil(crafts * proof.result.count / proof.result.maxCount)
    if not bounded then
        for _, slot in ipairs(proof.slots or {}) do
            local remainder = slot.remainder or {}
            if remainder.id then
                if not tonumber(remainder.maxCount) or remainder.maxCount < 1
                    or not tonumber(remainder.count) then return nil, "invalid recipe remainder" end
                needed = needed + math.ceil(remainder.count / remainder.maxCount)
            end
        end
    end
    local available = 16 - (bounded and occupied or survivors)
    if needed > available then return nil, "recipe outputs and remainders exceed turtle capacity" end
    self.proof, self.proofKey, self.prepared = proof, proofKey, basic
    return proof, nil, crafts
end

-- Preview yields to the server. Recheck the complete inventory immediately before
-- the physical craft, including counts used by custom whole-recipe predicates.
function Grid:unchanged()
    for slot = 1, 16 do
        local before = (self.prepared or {})[slot]
        local after = self.turtleDetail(slot, false)
        if (before == nil) ~= (after == nil) then return false end
        if before and (identity(before) ~= identity(after) or before.count ~= after.count) then
            return false
        end
    end
    return true
end

return Grid
