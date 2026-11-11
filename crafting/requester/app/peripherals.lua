local Peripherals = {}

function Peripherals.names()
    if not peripheral or type(peripheral.getNames) ~= "function" then
        return {}
    end

    local result = peripheral.getNames()
    table.sort(result)
    return result
end

function Peripherals.wrap(name)
    if not peripheral or type(peripheral.wrap) ~= "function" then
        return nil
    end

    local ok, device = pcall(peripheral.wrap, name)
    return ok and device or nil
end

function Peripherals.methods(name)
    if not peripheral or type(peripheral.getMethods) ~= "function" then
        return {}
    end

    local ok, result = pcall(peripheral.getMethods, name)
    return ok and result or {}
end

function Peripherals.inspect(name)
    local inspection = {
        methods = {},
        types = {},
    }

    for _, method in ipairs(Peripherals.methods(name)) do
        inspection.methods[method] = true
    end

    if peripheral and type(peripheral.getType) == "function" then
        local values = {pcall(peripheral.getType, name)}
        if values[1] then
            for index = 2, #values do
                if type(values[index]) == "string" then
                    inspection.types[values[index]] = true
                end
            end
        end
    end

    return inspection
end

function Peripherals.hasMethod(name, method)
    for _, current in ipairs(Peripherals.methods(name)) do
        if current == method then
            return true
        end
    end

    return false
end

-- inspection: Peripherals.inspect(name), the bus's cached look at a
-- peripheral (its types, else the methods a ticker has);
-- without it the peripheral API is asked for the type itself.
function Peripherals.hasType(name, wanted, inspection)
    if inspection then
        local methods = inspection.methods
        if inspection.types[wanted] then
            return true
        end
        if wanted == "Create_StockTicker" then
            return methods.stock == true and methods.requestFiltered == true
        end
        return false
    end

    if peripheral and type(peripheral.hasType) == "function" then
        local ok, matched = pcall(peripheral.hasType, name, wanted)

        if ok and matched then
            return true
        end
    end

    if peripheral and type(peripheral.getType) == "function" then
        local ok, first, second, third = pcall(peripheral.getType, name)

        if ok then
            for _, value in ipairs({first, second, third}) do
                if value == wanted then
                    return true
                end
            end
        end
    end

    return false
end

return Peripherals
