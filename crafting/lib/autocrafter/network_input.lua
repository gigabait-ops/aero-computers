-- The turtle's input chest, reached by its wired network name (`inputSide`,
-- e.g. "sophisticatedstorage:chest_9"); never another inventory.
local Network = {}
local sides = {"front", "back", "left", "right", "top", "bottom"}
local physical = {}
for _, side in ipairs(sides) do physical[side] = true end
local owner, bindings = nil, {}

-- A wired network name, not a physical side.
function Network.isRemote(name)
    return type(name) == "string" and name ~= "" and name ~= "auto" and not physical[name]
end

function Network.invalidate()
    owner, bindings = peripheral, {}
end

local function binding(name)
    if owner ~= peripheral then Network.invalidate() end
    if bindings[name] then return bindings[name] end
    if not Network.isRemote(name) then
        return nil, "inputSide must be a wired chest name, not " .. tostring(name)
    end
    local route
    for _, side in ipairs(sides) do
        local wrapped, modem = pcall(peripheral.wrap, side)
        if wrapped and modem and type(modem.getNameLocal) == "function"
            and type(modem.isPresentRemote) == "function" and type(modem.callRemote) == "function"
        then
            local localOK, target = pcall(modem.getNameLocal)
            local presentOK, present = pcall(modem.isPresentRemote, name)
            if localOK and type(target) == "string" and target ~= "" and presentOK and present then
                if route and route.target ~= target then
                    return nil, "ambiguous wired turtle identity for " .. name
                end
                route = route or {modem = modem, side = side, target = target, input = name}
            end
        end
    end
    if not route then return nil, "no enabled wired route to configured input " .. name end
    local ok, methods = pcall(route.modem.getMethodsRemote, name)
    if not ok or type(methods) ~= "table" then return nil, "network input methods unavailable: " .. name end
    local available = {}
    for _, method in ipairs(methods) do available[method] = true end
    for _, method in ipairs({"list", "size", "getItemDetail", "pushItems", "pullItems"}) do
        if not available[method] then return nil, "network input lacks " .. method .. ": " .. name end
    end
    bindings[name] = route
    return route
end

local function remote(route, method, ...)
    local ok, result = pcall(route.modem.callRemote, route.input, method, ...)
    if not ok then
        bindings[route.input] = nil
        return nil, "network input " .. method .. " failed: " .. tostring(result)
    end
    return result
end

function Network.describe(name)
    local route, err = binding(name)
    if not route then return nil, err end
    return {mode = "wired", input = name, modem = route.side, target = route.target}
end

local function same(a, b)
    return a and b and a.name == b.name and tostring(a.nbt or "") == tostring(b.nbt or "")
end

function Network.drop(name, count)
    local route, err = binding(name)
    if not route then return false, err end
    local slot = turtle.getSelectedSlot()
    local before = turtle.getItemCount(slot)
    if before == 0 then return false, "selected turtle slot is empty" end
    local amount = math.min(before, math.max(1, math.floor(tonumber(count) or before)))
    local _, moveError = remote(route, "pullItems", route.target, slot, amount)
    local moved = before - turtle.getItemCount(slot)
    if moved > 0 then return true end
    return false, moveError or "network input cannot accept items"
end

-- Pushes chest slot `source` into turtle slot `target`; `expected` is the
-- listed stack, so a changed source is returned to the chest.
function Network.push(name, source, target, count, expected)
    local route, err = binding(name)
    if not route then return nil, err, true end
    local before = turtle.getItemCount(target)
    if before > 0 and not same(turtle.getItemDetail(target), expected) then
        return nil, "network target contains a different item", true
    end
    turtle.select(target)
    local _, moveError = remote(route, "pushItems", route.target, source,
        math.max(1, math.floor(tonumber(count) or 1)), target)
    -- Reported transfer counts alone do not prove physical movement.
    local moved = turtle.getItemCount(target) - before
    if moved <= 0 then return nil, moveError or "network input made no progress", moveError ~= nil end
    if not same(turtle.getItemDetail(target), expected) then
        local returned, returnError = Network.drop(name, moved)
        if not returned or turtle.getItemCount(target) ~= before then
            return nil, returnError or "network input blocked returning changed source", true
        end
        return nil, "source identity changed during network transfer"
    end
    return moved
end

return Network
