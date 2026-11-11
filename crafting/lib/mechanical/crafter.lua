-- The mechanical crafter machine (PC134, 2026-10-26): Create's mechanical
-- crafting on a grid of crafters. Per craft the computer puts one item into
-- each cell's crafter and starts it with a redstone pulse (`trigger`, a side
-- of the computer touching a crafter); the output crafter drops into the
-- chest. Where each crafter sits cannot be read from the network, so the
-- grid stays in settings.lua.
local Util = require("fleet_util")
local Recipe = require("mechanical.recipe")

local amount, failure = Util.amount, Util.failure

local Crafter = {}
Crafter.KIND = "mechanical"
Crafter.TITLE = "Mechanical Crafter"
Crafter.NO_RECIPE = "NO_MECHANICAL_RECIPE"

-- Grid names, row 0 at the top, column 0 at the left seen from the front.
local function crafterAt(station, row, column)
    local line = station.config.grid[row + 1]
    local id = line and line[column + 1]
    if id == nil then return nil end
    return type(id) == "number" and ("create:mechanical_crafter_" .. id) or id
end

local function gridSize(station)
    local rows, columns = #station.config.grid, 0
    for _, line in ipairs(station.config.grid) do columns = math.max(columns, #line) end
    return rows, columns
end

function Crafter.find(station, target, blocked)
    return Recipe.find(station.recipes, target, blocked)
end

function Crafter.fits(station, recipe)
    return Recipe.fits(recipe, gridSize(station))
end

-- Moves anything left in a crafter back to the chest. Returns the leftovers.
function Crafter.clear(station)
    local chest, left = station:chest(), 0
    for row = 0, #station.config.grid - 1 do
        for column = 0, #station.config.grid[row + 1] - 1 do
            local name = crafterAt(station, row, column)
            local ok, items = pcall(station.peripheral.call, name, "list")
            for slot, item in pairs(ok and type(items) == "table" and items or {}) do
                local moved = chest.pullItems(name, slot) or 0
                left = left + math.max(0, amount(item.count) - moved)
            end
        end
    end
    return left
end

-- Chest slot of an item one of `accepts`, nil when none.
local function findSlot(list, accepts)
    for _, name in ipairs(accepts) do
        for slot, item in pairs(list) do
            if item.name == name and amount(item.count) > 0 then return slot, item end
        end
    end
    return nil
end

local function pulse(station)
    local trigger = station.config.trigger
    local device = trigger.peripheral and station:wrap(trigger.peripheral) or station.redstone or redstone
    device.setOutput(trigger.side, true)
    station.sleep(station.config.pulseSeconds or 0.3)
    device.setOutput(trigger.side, false)
end

-- One craft: one item into each cell's crafter, a pulse, then wait for the
-- output in the chest.
local function craftOnce(station, recipe)
    local chest = station:chest()
    local list = chest.list() or {}
    local before = (station:chestCounts())[recipe.target] or 0
    local cells = {table.unpack(recipe.cells)}
    table.sort(cells, function(a, b)
        if #a.accepts ~= #b.accepts then return #a.accepts < #b.accepts end
        if a.row ~= b.row then return a.row < b.row end
        return a.column < b.column
    end)
    for _, cell in ipairs(cells) do
        local slot, item = findSlot(list, cell.accepts)
        if not slot then
            Crafter.clear(station)
            return nil, failure("INGREDIENT_LOST", "no " .. cell.accepts[1] .. " left in the chest for row "
                .. (cell.row + 1) .. " column " .. (cell.column + 1))
        end
        local crafter = crafterAt(station, cell.row, cell.column)
        local moved = chest.pushItems(crafter, slot, 1) or 0
        if moved < 1 then
            Crafter.clear(station)
            return nil, failure("CRAFTER_REFUSED", crafter .. " took no " .. item.name)
        end
        item.count = item.count - 1
        if item.count <= 0 then list[slot] = nil end
    end
    pulse(station)
    local deadline = station.now() + (station.config.craftTimeout or 60)
    while station.now() < deadline do
        station.sleep(station.config.craftPollSeconds or 0.5)
        station:beat("CRAFTING")
        local now = (station:chestCounts())[recipe.target] or 0
        if now >= before + recipe.perCraft then return now - before end
    end
    local left = Crafter.clear(station)
    return nil, failure("CRAFT_TIMEOUT", "no " .. recipe.target .. " after "
        .. tostring(station.config.craftTimeout or 60) .. " s (crafters not moving or recipe not matched)",
        {leftInCrafters = left})
end

-- `batch` crafts one after another. Returns what it made and an error if it stopped.
function Crafter.batch(station, recipe, batch)
    local made, left = 0, station.active.count - amount(station.active.crafted)
    for index = 1, batch do
        station:show("crafting", {target = recipe.target, index = index, total = batch})
        local one, err = craftOnce(station, recipe)
        if not one then return made > 0 and made or nil, err end
        made = made + one
        if made >= left then break end
    end
    return made
end

return Crafter
