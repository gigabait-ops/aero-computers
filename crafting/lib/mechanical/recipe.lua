-- Station recipes from Recipe Atlas (mechanical crafting, stonecutting,
-- Create cutting, Slice & Dice cutting) and what a batch of them needs.
local Producers = require("autocrafter.producers")
local Util = require("fleet_util")

local Recipe = {}

Recipe.TYPE = "create:mechanical_crafting"

local amount = Util.amount

-- Item IDs an input row accepts, in Recipe Atlas's order, never the target: a
-- tag input can hold it (Create's stone_types/deepslate makes polished cut
-- deepslate from itself too), and the station fed its own output back to the
-- saws (owner 2026-11-07).
local function alternatives(input, target)
    local out, seen = {}, {[target or ""] = true}
    for _, alt in ipairs(type(input) == "table" and input.alternatives or {}) do
        local id = type(alt) == "table" and alt.id or alt
        if type(id) == "string" and not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    if #out == 0 and type(input) == "table" and type(input.id) == "string" and input.id ~= target then out[1] = input.id end
    return out
end

-- {id, width, height, cells = {{row, column, accepts = {ids}}}, output, perCraft}
-- from a getDetails record; nil and a reason when it cannot be placed.
function Recipe.fromRecord(id, record, target)
    local machine = type(record) == "table" and record.machine
    if type(machine) ~= "table" or type(machine.layout) ~= "table" then return nil, "no layout" end
    local layout = machine.layout
    local width, height = amount(layout.width), amount(layout.height)
    if width < 1 or height < 1 then return nil, "empty layout" end
    local cells = {}
    for index, cell in ipairs(layout.cells or {}) do
        local input = type(cell) == "table" and cell.input and machine.inputs[cell.input]
        if input then
            local accepts = alternatives(input, target)
            if #accepts == 0 then return nil, "input " .. tostring(cell.input) .. " has no items" end
            if amount(input.quantity) > 1 then return nil, "input " .. tostring(cell.input) .. " needs more than one item" end
            cells[#cells + 1] = {row = math.floor((index - 1) / width), column = (index - 1) % width, accepts = accepts}
        end
    end
    if #cells == 0 then return nil, "no inputs" end
    local perCraft, remainders = 0, {}
    for _, output in ipairs(machine.outputs or {}) do
        if output.kind ~= "fluid" and output.mode == "guaranteed" then
            if output.id == target then perCraft = perCraft + amount(output.quantity)
            else remainders[#remainders + 1] = output.id end
        end
    end
    if perCraft < 1 then return nil, "does not make " .. tostring(target) end
    return {id = id, target = target, width = width, height = height, cells = cells,
        perCraft = perCraft, remainders = remainders}
end

-- A one-input machine recipe (saw, slicer): one "cell" taking any of the
-- input's items, perCraft = the target's output count.
function Recipe.fromMachine(id, record, target)
    local machine = type(record) == "table" and record.machine
    if type(machine) ~= "table" or type(machine.inputs) ~= "table" then return nil, "no machine data" end
    if #machine.inputs ~= 1 then return nil, tostring(#machine.inputs) .. " inputs" end
    local accepts = alternatives(machine.inputs[1], target)
    if #accepts == 0 then return nil, "input has no items" end
    local perInput = math.max(1, amount(machine.inputs[1].quantity))
    local perCraft = 0
    for _, output in ipairs(machine.outputs or {}) do
        if output.id == target and output.mode == "guaranteed" then perCraft = perCraft + amount(output.quantity) end
    end
    if perCraft < 1 then return nil, "does not make " .. tostring(target) end
    local cells = {}
    for i = 1, perInput do cells[i] = {row = 0, column = i - 1, accepts = accepts} end
    return {id = id, target = target, width = perInput, height = 1, cells = cells,
        perCraft = perCraft, remainders = {}}
end

-- Recipes of `recipeType` (a type or a list; default: mechanical crafting) for a target,
-- skipping blocked ones; `build` turns a record into a placeable recipe.
-- `byOutput`: also machine recipes where the target is a later guaranteed
-- output (a slicer stripping a log drops tree bark too). One producers()
-- list and one getMany() per call (Recipe Atlas).
function Recipe.find(api, target, blocked, recipeType, build, byOutput)
    build = build or Recipe.fromRecord
    if type(api) ~= "table" or type(api.producers) ~= "function" then return nil, "RECIPES_UNAVAILABLE" end
    local rows, err = Producers.rows(api, target)
    if not rows then return nil, "recipe lookup failed: " .. tostring(err) end
    local ids = {}
    local types = type(recipeType) == "table" and recipeType or {recipeType or Recipe.TYPE}
    for _, id in ipairs(Producers.ids(rows, types, {byOutput = byOutput})) do
        if not (blocked and blocked[id]) then ids[#ids + 1] = id end
    end
    local records, detailsErr = Producers.details(api, ids)
    if not records then return nil, "recipe lookup failed: " .. tostring(detailsErr) end
    local found, reasons = {}, {}
    for _, id in ipairs(ids) do
        local recipe, why
        if records[id] then recipe, why = build(id, records[id], target)
        else why = "not_found" end
        if recipe then found[#found + 1] = recipe else reasons[#reasons + 1] = id .. ": " .. tostring(why) end
    end
    if #found == 0 then
        return nil, #reasons > 0 and table.concat(reasons, "; ") or "no recipe"
    end
    return found
end

-- Fits a recipe into the station grid: top-left corner, row 0 at the top.
function Recipe.fits(recipe, gridRows, gridColumns)
    return recipe.height <= gridRows and recipe.width <= gridColumns
end

-- Cells grouped by what they accept: {key, accepts, perCraft}. Groups with
-- fewer choices come first, so shared items go to the strict cells first.
function Recipe.groups(recipe)
    local byKey, list = {}, {}
    for _, cell in ipairs(recipe.cells) do
        local sorted = {table.unpack(cell.accepts)}
        table.sort(sorted)
        local key = table.concat(sorted, "|")
        local group = byKey[key]
        if not group then
            group = {key = key, accepts = cell.accepts, perCraft = 0}
            byKey[key] = group
            list[#list + 1] = group
        end
        group.perCraft = group.perCraft + 1
    end
    table.sort(list, function(a, b)
        if #a.accepts ~= #b.accepts then return #a.accepts < #b.accepts end
        return a.key < b.key
    end)
    return list
end

-- What `crafts` crafts take from `available` (item -> count, already in the
-- chest plus warehouse stock). Returns take (item -> count) or nil and the
-- shortage {item, needed, have, accepts} of the first group that runs out.
function Recipe.allocate(recipe, crafts, available)
    local left = {}
    for name, count in pairs(available or {}) do left[name] = amount(count) end
    local take = {}
    for _, group in ipairs(Recipe.groups(recipe)) do
        local need = group.perCraft * crafts
        local order = {table.unpack(group.accepts)}
        table.sort(order, function(a, b)
            if (left[a] or 0) ~= (left[b] or 0) then return (left[a] or 0) > (left[b] or 0) end
            return a < b
        end)
        for _, name in ipairs(order) do
            if need <= 0 then break end
            local use = math.min(need, left[name] or 0)
            if use > 0 then
                left[name] = left[name] - use
                take[name] = (take[name] or 0) + use
                need = need - use
            end
        end
        if need > 0 then
            local have = group.perCraft * crafts - need
            return nil, {item = order[1], needed = group.perCraft * crafts, have = have,
                missing = need, accepts = group.accepts}
        end
    end
    return take
end

-- Everything `crafts` crafts lack in `available`, per group:
-- {{item, missing, accepts}}; empty when nothing is short.
function Recipe.shortages(recipe, crafts, available)
    local left, list = {}, {}
    for name, count in pairs(available or {}) do left[name] = amount(count) end
    for _, group in ipairs(Recipe.groups(recipe)) do
        local need = group.perCraft * crafts
        for _, name in ipairs(group.accepts) do
            local use = math.min(need, left[name] or 0)
            left[name], need = (left[name] or 0) - use, need - use
        end
        if need > 0 then list[#list + 1] = {item = group.accepts[1], missing = need, accepts = group.accepts} end
    end
    return list
end

-- The most crafts available stock allows, up to `limit` (0 when none).
function Recipe.maxCrafts(recipe, available, limit)
    local low, high = 0, math.max(0, amount(limit))
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if Recipe.allocate(recipe, mid, available) then low = mid else high = mid - 1 end
    end
    return low
end

return Recipe
