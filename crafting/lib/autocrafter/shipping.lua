-- The turtle's own packager (found at boot, autocrafter.peripherals), on
-- its input barrel. Every craft result, intermediate or final, goes back
-- into the barrel; cleaning empties the turtle into it and packs the whole
-- barrel to the warehouse (`shipAddress`, "Storage").
local Util = require("fleet_util")
local NetworkInput = require("autocrafter.network_input")

local Shipping = {}

-- Packs the input chest until it is empty. Returns true, or false and why.
function Shipping.ship(packager, turtleIO, inputSide, options)
    options = options or {}
    local sleep = options.sleep or (os and os.sleep) or function() end
    local shipped = 0
    for _ = 1, options.maxPackages or 64 do
        local diagnostics = turtleIO.inputDiagnostics(inputSide)
        if not diagnostics.ok then return false, {error = diagnostics.error or "input inventory unavailable"} end
        if diagnostics.stacks <= 0 then return true, {shipped = shipped} end
        pcall(packager.setAddress, options.address or "Storage")
        local ok, made = pcall(packager.makePackage)
        -- Nothing packed: the packager is still busy with the last one.
        if ok and made ~= false then shipped = shipped + 1 end
        sleep(options.gapSeconds or 1.5)
    end
    return false, {error = "the chest did not empty through the packager", shipped = shipped}
end

-- Cleaning the input: the turtle's slots go into the input chest, then the
-- chest is shipped. Returns true, or false and why; the summary carries the
-- moved stacks and items and the packages made.
function Shipping.clean(turtleIO, packager, inputSide, options)
    options = options or {}
    if not packager then
        return false, {error = "no packager found", inputSide = inputSide}
    end
    if not turtleIO or type(turtleIO.emptyIntoInput) ~= "function" then
        return false, {error = "turtle input cleanup unavailable", inputSide = inputSide}
    end
    local emptied, info = turtleIO.emptyIntoInput({inputSide = inputSide})
    if not emptied then return false, info end
    local shipped, result = Shipping.ship(packager, turtleIO, inputSide, options)
    if not shipped or (result.shipped or 0) > 0 then
        Util.log(options.logger, "worker.shipped", {ok = shipped, packages = result.shipped, error = result.error})
    end
    result.inputSide = inputSide
    result.movedStacks, result.movedItems = info.movedStacks, info.movedItems
    return shipped, result
end

-- A job with a delivery address (2026-10-28: the asker named one, e.g. the
-- colony): the finished `target` goes there and everything else in the
-- barrel to Storage. The smaller of the two sets waits in the turtle's 16
-- slots while the other ships. Returns true when the target went to the
-- address; false (all to Storage) when neither set fits the turtle.
function Shipping.deliver(turtleIO, packager, inputSide, target, address, options)
    options = options or {}
    local emptied, info = turtleIO.emptyIntoInput({inputSide = inputSide})
    if not emptied then return false, info end
    local wanted, other = {}, {}
    for slot, item in pairs(peripheral.call(inputSide, "list") or {}) do
        local list = item.name == target and wanted or other
        list[#list + 1] = {slot = slot, item = item}
    end
    if #wanted == 0 then return false, {error = "no " .. tostring(target) .. " to deliver"} end
    local holdTarget = #wanted <= #other
    local hold = holdTarget and wanted or other
    if #hold > 16 then return false, {error = "the output and the leftovers both exceed the turtle's slots"} end
    for index, entry in ipairs(hold) do
        local moved, err = NetworkInput.push(inputSide, entry.slot, index, entry.item.count, entry.item)
        if not moved then
            turtleIO.emptyIntoInput({inputSide = inputSide})
            return false, {error = tostring(err)}
        end
    end
    local first = holdTarget and (options.address or "Storage") or address
    local second = holdTarget and address or (options.address or "Storage")
    local ok, result = Shipping.ship(packager, turtleIO, inputSide, {address = first, sleep = options.sleep})
    if ok then
        turtleIO.emptyIntoInput({inputSide = inputSide})
        ok, result = Shipping.ship(packager, turtleIO, inputSide, {address = second, sleep = options.sleep})
    end
    Util.log(options.logger, "worker.delivered", {target = target, address = address, ok = ok,
        error = result and result.error})
    return ok, result
end

return Shipping
