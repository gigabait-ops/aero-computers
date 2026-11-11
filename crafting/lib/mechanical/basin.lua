-- The basin machine (PC150, 2026-10-28): Create basins on lava-fed blaze
-- burners, one under a mechanical mixer (mixing, heated mixing, Slice &
-- Dice cooking) and one under a press (compacting). The computer puts a
-- batch's items and fluids (from the station's tanks) into the basin whose
-- machine the recipe names; Create runs it and the outputs are taken out.
-- Which basin sits under which machine cannot be read: the first batch
-- tries a basin, and one that does not start gives everything back and the
-- other one gets it. What is learned is kept in data/basins.lua.
local Util = require("fleet_util")
local AtomicStore = require("atomic_store")
local Recipe = require("mechanical.recipe")
local Devices = require("mechanical.devices")

local amount, failure = Util.amount, Util.failure

local Basin = {}
Basin.KIND = "basin"
Basin.TITLE = "Basin Station"
Basin.NO_RECIPE = "NO_BASIN_RECIPE"
Basin.TYPES = {"create:mixing", "create:compacting"}
local ROLE = {["create:mechanical_mixer"] = "mixer", ["create:mechanical_press"] = "press"}
local INPUT_SLOTS = 9
local TANK_MB = 1000

-- Never the target itself (a tag input can hold it, see recipe.lua).
local function ids(input, target)
    local out = {}
    for _, alt in ipairs(type(input) == "table" and input.alternatives or {}) do
        if type(alt) == "table" and type(alt.id) == "string" and alt.id ~= target then out[#out + 1] = alt.id end
    end
    return out
end

-- A placeable basin recipe: item cells (one per item), fluids {names, amount},
-- the machine role and perCraft of the target; nil and why otherwise.
function Basin.recipe(id, record, target)
    local machine = type(record) == "table" and record.machine
    if type(machine) ~= "table" then return nil, "no machine data" end
    local executor = machine.executors and machine.executors[1] and machine.executors[1].id
    local role = ROLE[executor]
    if not role then return nil, "machine " .. tostring(executor) end
    for _, need in ipairs(machine.requirements or {}) do
        if need.id == "create:heat" and need.condition == "superheated" then return nil, "needs superheat" end
    end
    local cells, fluids = {}, {}
    for _, input in ipairs(machine.inputs or {}) do
        if input.kind == "fluid" then
            fluids[#fluids + 1] = {names = ids(input), amount = amount(input.quantity)}
        else
            local accepts = ids(input, target)
            if #accepts == 0 then return nil, "an input has no items" end
            for _ = 1, math.max(1, amount(input.quantity)) do
                cells[#cells + 1] = {row = 0, column = #cells, accepts = accepts}
            end
        end
    end
    -- A chance output (diamonds from coal blocks, 30%) counts at its average.
    local perCraft, chance = 0, false
    for _, output in ipairs(machine.outputs or {}) do
        if output.kind == "item" and output.id == target then
            if output.mode == "guaranteed" then
                perCraft = perCraft + amount(output.quantity)
            else
                local p = tonumber(output.chance or output.probability) or 1
                perCraft, chance = perCraft + math.max(1, amount(output.quantity)) * p, true
            end
        end
    end
    if perCraft <= 0 then return nil, "does not make " .. tostring(target) end
    return {id = id, target = target, width = #cells, height = 1, cells = cells, fluids = fluids,
        role = role, perCraft = perCraft, chance = chance or nil, remainders = {}}
end

function Basin.find(station, target, blocked)
    return Recipe.find(station.recipes, target, blocked, Basin.TYPES, Basin.recipe, true)
end

-- At most nine kinds of items fit a basin's input slots.
function Basin.fits(_, recipe)
    return #Recipe.groups(recipe) <= INPUT_SLOTS
end

-- Basins ---------------------------------------------------------------------

-- Every fluid source on the cable that is not a basin: Create tanks, and a
-- Sophisticated barrel or backpack with a tank upgrade (crude oil).
local function fluidSources(station)
    local found = {}
    for _, name in ipairs(station.peripheral.getNames()) do
        if not name:find("^create:basin_") then
            local ok, yes = pcall(station.peripheral.hasType, name, "fluid_storage")
            if ok and yes then found[#found + 1] = name end
        end
    end
    table.sort(found)
    return found
end

local function rolesFile(station) return station.config.basinsFile or "data/basins.lua" end

local function roles(station)
    if not station.basinRoles then
        local saved = AtomicStore.load(rolesFile(station), station.fs)
        station.basinRoles = type(saved) == "table" and saved or {}
    end
    return station.basinRoles
end

local function learn(station, name, role)
    local known = roles(station)
    known[name] = role
    -- With two basins, the other one is the other machine's.
    local names = Devices.named(station.peripheral, "create:basin")
    if #names == 2 then
        local other = names[1] == name and names[2] or names[1]
        known[other] = role == "mixer" and "press" or "mixer"
    end
    AtomicStore.save(rolesFile(station), known, station.fs)
    station:log("basin.learned", {basin = name, role = role})
end

-- The basin for a role: a known one, else one not known to be another's.
local function pick(station, role, tried)
    local known, unknown = roles(station), nil
    for _, name in ipairs(Devices.named(station.peripheral, "create:basin")) do
        if known[name] == role then return name, true end
        if not known[name] and not tried[name] then unknown = unknown or name end
    end
    return unknown, false
end

local function inputCount(device)
    local total = 0
    for slot, item in pairs(device.list() or {}) do
        if slot <= INPUT_SLOTS then total = total + amount(item.count) end
    end
    return total
end

-- The input slot (1-9) for an item: the one holding it (a basin keeps
-- each kind in one slot), else an empty one.
local function inputSlot(device, name)
    local items, free = device.list() or {}, nil
    for slot = 1, INPUT_SLOTS do
        local stack = items[slot]
        if stack and stack.name == name then return slot end
        if not stack then free = free or slot end
    end
    return free
end

local function outputCount(device, target)
    local total = 0
    for slot, item in pairs(device.list() or {}) do
        if slot > INPUT_SLOTS and item.name == target then total = total + amount(item.count) end
    end
    return total
end

local function fluidCount(device)
    local total = 0
    local ok, tanks = pcall(device.tanks)
    for _, tank in pairs(ok and tanks or {}) do total = total + amount(tank.amount) end
    return total
end

-- Outputs (and anything else) out of the basin into the chest; with `all`
-- the inputs too, and its fluids back into the tanks.
local function empty(station, name, all)
    local device = station:wrap(name)
    for slot, item in pairs(device.list() or {}) do
        if all or slot > INPUT_SLOTS then device.pushItems(station.chestName, slot, item.count) end
    end
    if all then
        for _, tank in ipairs(fluidSources(station)) do
            pcall(device.pushFluid, tank)
        end
    end
end

function Basin.clear(station)
    for _, name in ipairs(Devices.named(station.peripheral, "create:basin")) do empty(station, name, true) end
    return 0
end

-- Pours `mb` of one of `names` from the station's fluid sources into a basin.
local function pour(station, basin, names, mb)
    local left = mb
    -- What the basin still holds counts: a leftover the full tanks could not
    -- take back left no room for a whole pour (pulp, PC150 2026-11-07).
    local ok, held = pcall(station:wrap(basin).tanks)
    for _, content in pairs(ok and held or {}) do
        for _, wanted in ipairs(names) do
            if content.name == wanted then left = left - amount(content.amount) end
        end
    end
    for _, tankName in ipairs(fluidSources(station)) do
        local tank = station:wrap(tankName)
        local ok, tanks = pcall(tank.tanks)
        for _, content in pairs(ok and tanks or {}) do
            for _, wanted in ipairs(names) do
                if left > 0 and content.name == wanted then
                    left = left - (select(2, pcall(tank.pushFluid, basin, left, wanted)) or 0)
                end
            end
        end
    end
    return left <= 0
end

-- Puts `crafts` crafts' items and fluids into a basin. Returns true, or nil
-- and a failure.
local function load(station, name, recipe, crafts)
    local device = station:wrap(name)
    -- The basin's filter picks the recipe when the load fits several (the
    -- Advanced Peripherals filter API, as on the saws).
    if device.setFilter then pcall(device.setFilter, {type = "item", item = {name = recipe.target}}) end
    local take = Recipe.allocate(recipe, crafts, station:chestCounts())
    if not take then return nil, failure("INGREDIENT_LOST", "the batch is no longer in the chest") end
    for item, count in pairs(take) do
        local left = count
        for slot, stack in pairs(station:chest().list() or {}) do
            local inStack = stack.name == item and amount(stack.count) or 0
            -- Into its input slot (a basin also accepts items in its output
            -- slots, so the slot is always named).
            while left > 0 and inStack > 0 do
                local to = inputSlot(device, item)
                local moved = to and device.pullItems(station.chestName, slot, math.min(left, inStack), to) or 0
                if moved <= 0 then break end
                left, inStack = left - moved, inStack - moved
            end
            if left <= 0 then break end
        end
        if left > 0 then return nil, failure("INGREDIENT_LOST", "could not put " .. item .. " into " .. name) end
    end
    for _, fluid in ipairs(recipe.fluids) do
        if not pour(station, name, fluid.names, fluid.amount * crafts) then
            return nil, failure("FLUID_MISSING", "not enough " .. tostring(fluid.names[1]) .. " in the tanks",
                {target = fluid.names[1], needed = fluid.amount * crafts})
        end
    end
    station:log("basin.loaded", {basin = name, crafts = crafts, items = inputCount(device), fluid = fluidCount(device)})
    return true
end

-- Waits for loaded basins together. A basin runs when the target comes out
-- (a chance recipe: when its input goes down, the slots having been filled
-- exactly) and is done when its input is used up or nothing moves for
-- stallSeconds. Returns name -> "done" | "stalled".
local function watch(station, names, recipe)
    local state, open = {}, #names
    for _, name in ipairs(names) do
        state[name] = {device = station:wrap(name), ran = false, movedAt = station.now()}
        state[name].last = inputCount(state[name].device)
    end
    local result = {}
    while open > 0 do
        station.sleep(station.config.craftPollSeconds or 0.5)
        station:beat("CRAFTING")
        for name, st in pairs(state) do
            if not result[name] then
                if outputCount(st.device, recipe.target) > 0 then
                    st.ran, st.movedAt = true, station.now()
                    empty(station, name, false)
                end
                local left = inputCount(st.device)
                if recipe.chance and left < st.last then st.ran, st.movedAt = true, station.now() end
                st.last = left
                if st.ran and left + fluidCount(st.device) == 0 then
                    result[name], open = "done", open - 1
                elseif station.now() - st.movedAt >= (station.config.stallSeconds or 15) then
                    result[name], open = st.ran and "done" or "stalled", open - 1
                end
            end
        end
    end
    return result
end

-- The basins known to be under the recipe's machine.
local function basinsFor(station, role)
    local list = {}
    for _, name in ipairs(Devices.named(station.peripheral, "create:basin")) do
        if roles(station)[name] == role then list[#list + 1] = name end
    end
    return list
end

-- One stack of each input and 1000 mB per fluid fit one basin.
function Basin.perLoad(recipe)
    local best = 64
    for _, fluid in ipairs(recipe.fluids) do
        if fluid.amount > 0 then best = math.min(best, math.floor(TANK_MB / fluid.amount)) end
    end
    for _, group in ipairs(Recipe.groups(recipe)) do
        best = math.min(best, math.floor(64 / math.max(1, group.perCraft)))
    end
    return math.max(1, best)
end

-- Crafts one batch can take: a load for every basin under the recipe's
-- machine (one load while none is known yet). A basin keeps each kind of
-- item in one slot only (seen on PC150 2026-10-28), hence one stack each.
function Basin.maxBatch(station, recipe)
    return Basin.perLoad(recipe) * math.max(1, #basinsFor(station, recipe.role))
end

-- A batch over every basin of the recipe's machine at once; while none is
-- known, one basin after another is tried and the one that runs is learned.
function Basin.batch(station, recipe, batch)
    local before = (station:chestCounts())[recipe.target] or 0
    local basins = basinsFor(station, recipe.role)
    local function fail(names, err)
        for _, name in ipairs(names) do empty(station, name, true) end
        return nil, err
    end
    if #basins > 0 then
        local loaded, left = {}, batch
        local share = math.min(Basin.perLoad(recipe), math.ceil(batch / #basins))
        for _, name in ipairs(basins) do
            if left <= 0 then break end
            local crafts = math.min(share, left)
            local ok, err = load(station, name, recipe, crafts)
            if not ok then return fail(loaded, err) end
            loaded[#loaded + 1], left = name, left - crafts
        end
        station:show("crafting", {target = recipe.target, index = 0, total = batch})
        local result = watch(station, loaded, recipe)
        for _, name in ipairs(loaded) do
            -- Anything left (a part that did not run) goes back too.
            empty(station, name, true)
            if result[name] == "stalled" then
                station:log("basin.stalled", {basin = name, role = recipe.role, known = true})
                return nil, failure("CRAFT_TIMEOUT", name .. " did not start " .. recipe.target .. " (no heat?)")
            end
        end
    else
        local tried = {}
        while true do
            local name = pick(station, recipe.role, tried)
            if not name then
                return nil, failure("CRAFT_TIMEOUT", "no basin runs this " .. recipe.role .. " recipe (no heat?)")
            end
            local ok, err = load(station, name, recipe, batch)
            if not ok then return fail({name}, err) end
            local result = watch(station, {name}, recipe)[name]
            empty(station, name, true)
            if result == "done" then learn(station, name, recipe.role); break end
            station:log("basin.stalled", {basin = name, role = recipe.role, known = false})
            tried[name] = true
        end
    end
    local made = ((station:chestCounts())[recipe.target] or 0) - before
    -- A chance output may well give nothing from one load.
    if made <= 0 and not recipe.chance then
        return nil, failure("CRAFT_TIMEOUT", "no " .. recipe.target .. " came out of the basin")
    end
    return math.max(0, made)
end

return Basin
