-- Shadow comparison with Recipe Atlas's resolver. After the fleet planner made a
-- plan, ask recipes.resolve once for the same target, count and stock and
-- return log fields for both. Read-only and best effort: a refused call
-- (1/s per computer, 4/s per server) is reported as skipped and never retried.
-- It decides nothing; the logs show whether the resolver can take over.
local Recipes = require("recipes")
local Util = require("fleet_util")

local Shadow = {}
local MAX_QUANTITY = 1000000

local amount = Util.amount

local function available(recipes)
    local ok, capabilities = pcall(recipes.capabilities)
    if not ok or type(capabilities) ~= "table" then return false end
    return ((capabilities.features or {}).resolve and true or false),
        amount((capabilities.limits or {}).resolveStockEntries) > 0
            and amount(capabilities.limits.resolveStockEntries) or 256
end

-- Component-free stock of every item the plan touched: requests, slot
-- alternatives and the local buffer, at most `limit` entries.
local function stockFor(plan, snapshot, limit)
    local names, seen = {}, {}
    local function add(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for _, entry in ipairs(plan.requests or {}) do add(entry.name) end
    for name in pairs(plan.baselineLocal or {}) do add(name) end
    for _, node in ipairs(plan.nodes or {}) do
        for _, slot in ipairs(node.slots or {}) do
            for _, name in ipairs(((slot.ingredient or {}).items) or {}) do add(name) end
        end
    end
    table.sort(names)
    local stock = {}
    for _, name in ipairs(names) do
        local metadata = (snapshot.stockMetadata or {})[name] or (snapshot.localMetadata or {})[name] or {}
        local count = amount((snapshot.stockCounts or {})[name]) + amount((snapshot.localCounts or {})[name])
        if count > 0 and not metadata.hasNbt then
            if #stock >= limit then break end
            stock[#stock + 1] = {id = name, quantity = math.min(count, MAX_QUANTITY), default = true}
        end
    end
    return stock
end

local function steps(list, idKey)
    local rows = {}
    for _, step in ipairs(list or {}) do
        rows[#rows + 1] = tostring(step[idKey]) .. " x" .. tostring(step.crafts)
    end
    table.sort(rows)
    return table.concat(rows, ",")
end

-- Returns the fields of one worker.resolve_shadow log line.
function Shadow.compare(target, count, plan, snapshot, options)
    options = options or {}
    local recipes = options.recipes or Recipes
    local fields = {target = target, count = count, planner = steps(plan.nodes, "recipeId")}
    local enabled, limit = available(recipes)
    if not enabled then
        fields.skipped = "resolve unavailable"
        return fields
    end
    local clock = options.clock or (os and os.epoch and function() return os.epoch("utc") end) or os.clock
    local started = clock()
    local ok, result = pcall(recipes.resolve, {
        target = {id = target}, count = math.min(amount(count), MAX_QUANTITY),
        stock = stockFor(plan, snapshot, limit), blocked = options.blocked,
    })
    fields.ms = clock() - started
    if not ok then
        fields.skipped = tostring(result)
        return fields
    end
    fields.status = result.status
    fields.resolver = steps(result.steps, "entryId")
    fields.same = fields.resolver == fields.planner
    fields.missing = #(result.missing or {})
    local reasons = {}
    for _, row in ipairs(result.validationRequired or {}) do
        reasons[#reasons + 1] = tostring(row.reason)
        if #reasons == 3 then break end
    end
    fields.validation = table.concat(reasons, ",")
    fields.searchMs = (result.search or {}).elapsedMs
    return fields
end

return Shadow
