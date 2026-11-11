-- Runs a batch through every machine of a station at once (saws, slicer
-- depots): each one gets a chunk of the input from the chest, its outputs go
-- back to the chest as they come, and the next chunk follows when the inputs
-- are gone. A machine whose input stops going down (a slicer without a tool
-- over that depot, a stuck saw) gets its input back and sits out the rest of
-- the batch; the others carry on.
local Util = require("fleet_util")

local amount, failure = Util.amount, Util.failure

local Feed = {}

-- Moves up to `want` items any of `accepts` from the chest into `device`
-- (its slot `toSlot`). Returns how many moved.
function Feed.give(station, device, accepts, want, toSlot)
    local moved = 0
    for slot, item in pairs(station:chest().list() or {}) do
        if moved >= want then break end
        for _, name in ipairs(accepts) do
            if item.name == name then
                moved = moved + (device.pullItems(station.chestName, slot, want - moved, toSlot) or 0)
                break
            end
        end
    end
    return moved
end

-- Moves every slot of `device` (or those `keep(slot, item)` rejects) to the
-- chest. Returns what stayed.
function Feed.empty(station, device, keep)
    local left = 0
    for slot, item in pairs(device.list() or {}) do
        if not (keep and keep(slot, item)) then
            local moved = device.pushItems(station.chestName, slot, item.count) or 0
            left = left + math.max(0, amount(item.count) - moved)
        end
    end
    return left
end

-- units: machines {device, name, ...}. hooks:
--   input(unit) -> count of input still in it
--   collect(unit): its outputs to the chest
--   giveBack(unit): everything in it to the chest
--   feed(unit, want) -> moved
--   tend(unit) (optional): called while waiting (a slicer refits a broken tool)
--   stallSeconds (optional): how long an input may stay the same
-- Returns the inputs fed through, or nil and a failure.
function Feed.run(station, units, inputs, recipe, hooks)
    local chunk = math.max(1, amount(station.config.chunk or 16))
    local stallSeconds = hooks.stallSeconds or station.config.stallSeconds or 15
    local live, fed = {}, 0
    for _, unit in ipairs(units) do
        unit.lastInput, unit.movedAt = hooks.input(unit), station.now()
        unit.fedTotal, unit.feeds = 0, 0
        live[#live + 1] = unit
    end
    -- Every machine is refilled as soon as its input is gone, not when the
    -- last one is done (owner 2026-11-06: a saw takes one item at a time, so
    -- eleven saws waited for the twelfth on every item).
    while true do
        local busy, kept, now = false, {}, station.now()
        for index, unit in ipairs(live) do
            if hooks.tend then hooks.tend(unit) end
            hooks.collect(unit)
            local left = hooks.input(unit)
            if left == 0 and fed < inputs then
                -- An even share of what is left for every machine, at most `chunk`.
                local share = math.min(chunk, math.ceil((inputs - fed) / (#live - index + 1 + #kept)))
                local moved = hooks.feed(unit, math.min(share, inputs - fed))
                fed, left = fed + moved, moved
                unit.fedTotal, unit.feeds = unit.fedTotal + moved, unit.feeds + (moved > 0 and 1 or 0)
                unit.lastInput, unit.movedAt = moved, now
            end
            if left < unit.lastInput then unit.lastInput, unit.movedAt = left, now end
            if left > 0 and now - unit.movedAt >= stallSeconds then
                hooks.giveBack(unit)
                fed = fed - left
                station:log("station.machine_stalled", {machine = unit.name, input = left})
            else
                kept[#kept + 1] = unit
                busy = busy or left > 0
            end
        end
        live = kept
        if #live == 0 then
            return nil, failure(hooks.stallCode or "CRAFT_TIMEOUT", hooks.stallMessage or "no machine is working")
        end
        station:show("crafting", {target = recipe.target, index = fed, total = inputs})
        if not busy then
            -- How the batch spread over the machines: fed/feeds for each.
            local spread = {}
            for _, unit in ipairs(units) do
                spread[#spread + 1] = unit.fedTotal .. "/" .. unit.feeds
            end
            station:log("station.spread", {inputs = inputs, fed = fed, machines = table.concat(spread, " ")})
            if fed >= inputs then return fed end
            return nil, failure("INGREDIENT_LOST", "no " .. recipe.cells[1].accepts[1] .. " left in the chest")
        end
        station.sleep(station.config.craftPollSeconds or 0.5)
        station:beat("CRAFTING")
    end
end

return Feed
