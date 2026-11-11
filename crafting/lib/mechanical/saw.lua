-- The saw machine (PC136, 2026-10-27): Create's mechanical saws run
-- stonecutting and Create cutting recipes one item at a time. Every saw on
-- the station's network is used (found as create:saw_<n>, or `saws` in
-- settings). Per batch each saw's filter is set to the target (the Advanced
-- Peripherals filter API), so it picks that one of the input's outputs. The
-- saws drop their outputs on the chest; its magnet upgrade picks them up.
local Util = require("fleet_util")
local Recipe = require("mechanical.recipe")
local JobKind = require("controller.job_kind")
local Devices = require("mechanical.devices")
local Feed = require("mechanical.feed")

local failure = Util.failure

local Saw = {}
Saw.KIND = "saw"
Saw.TITLE = "Saw Station"
Saw.NO_RECIPE = "NO_SAW_RECIPE"

function Saw.find(station, target, blocked)
    return Recipe.find(station.recipes, target, blocked, JobKind.SAW_TYPES, Recipe.fromMachine)
end

function Saw.fits() return true end

-- The saws present now; a saw being rebuilt is skipped.
local function saws(station)
    local list = {}
    for _, name in ipairs(station.config.saws or Devices.named(station.peripheral, "create:saw")) do
        local ok, device = pcall(station.wrap, station, name)
        if ok and device then list[#list + 1] = {name = name, device = device} end
    end
    if #list == 0 then error(failure("PERIPHERAL_MISSING", "no saw on the network"), 0) end
    return list
end

function Saw.clear(station)
    local left = 0
    for _, saw in ipairs(saws(station)) do left = left + Feed.empty(station, saw.device) end
    return left
end

-- The filter, in Advanced Peripherals' form (verified on PC136 2026-10-27).
local function setFilter(list, target)
    for _, saw in ipairs(list) do
        local ok, set = pcall(saw.device.setFilter, {type = "item", item = {name = target}})
        if not ok or set == false then return false end
    end
    return true
end

-- `batch` crafts over every saw. Returns the target count that reached the chest.
function Saw.batch(station, recipe, batch)
    local list = saws(station)
    if not setFilter(list, recipe.target) then
        return nil, failure("FILTER_FAILED", "the saw's filter cannot be set")
    end
    local before = (station:chestCounts())[recipe.target] or 0
    local inputs = batch * #recipe.cells
    local accepts = recipe.cells[1].accepts
    local fed, err = Feed.run(station, list, inputs, recipe, {
        stallMessage = "no saw cut " .. accepts[1],
        -- With bulkCutting a saw cuts its whole stack at once: the count
        -- stays the same until it is done (64 take 13 times one item).
        stallSeconds = station.config.sawStallSeconds or 120,
        input = function(saw)
            local item = (saw.device.list() or {})[1]
            return item and Util.amount(item.count) or 0
        end,
        -- Slot 1 is the input; the rest are outputs.
        collect = function(saw) Feed.empty(station, saw.device, function(slot) return slot == 1 end) end,
        giveBack = function(saw) Feed.empty(station, saw.device) end,
        feed = function(saw, want) return Feed.give(station, saw.device, accepts, want, 1) end,
    })
    if not fed then
        Saw.clear(station)
        return nil, err
    end
    -- The magnet picks up the last drops within a moment.
    local expected = before + fed / #recipe.cells * recipe.perCraft
    for _ = 1, math.max(1, math.floor((station.config.dropSettleSeconds or 30) / 0.5)) do
        if ((station:chestCounts())[recipe.target] or 0) >= expected then break end
        station.sleep(0.5)
    end
    local made = ((station:chestCounts())[recipe.target] or 0) - before
    if made <= 0 then
        return nil, failure("CRAFT_TIMEOUT", "no " .. recipe.target .. " came out of the saw")
    end
    return made
end

return Saw
