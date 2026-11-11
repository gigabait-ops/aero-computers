local Peripherals = require("app.peripherals")

local Bus = {}
Bus.__index = Bus

local function add(list, name)
    table.insert(list, {name = name, device = Peripherals.wrap(name)})
end

-- The configured device by name, or the first one found ("auto").
local function selectDevice(list, configured)
    if configured and configured ~= "auto" then
        for _, entry in ipairs(list or {}) do
            if entry.name == configured then
                return entry
            end
        end

        return nil
    end

    return (list or {})[1]
end

-- The registry's Stock Ticker entry {name, device}, or nil. Only peripherals
-- of type Create_StockTicker are candidates, never a plain inventory.
function Bus.ticker(registry)
    registry = registry or {}
    if registry.stockTicker ~= nil then
        return registry.stockTicker or nil
    end
    return (registry.stockTickerList or {})[1]
end

function Bus:new(config)
    return setmetatable({
        config = config or {},
        inspections = {},
        generation = 0,
        registry = nil
    }, self)
end

function Bus:forget(name)
    self.inspections[tostring(name or "")] = nil
    self.generation = self.generation + 1
    self.registry = nil
end

function Bus:scan()
    if self.registry then return self.registry end
    local generation = self.generation
    local registry = {stockTickerList = {}}

    local attached = {}
    for _, name in ipairs(Peripherals.names()) do
        attached[name] = true
        local inspection = self.inspections[name]
        if not inspection then
            inspection = Peripherals.inspect(name)
            self.inspections[name] = inspection
        end

        if Peripherals.hasType(name, "Create_StockTicker", inspection) then
            add(registry.stockTickerList, name)
        end
    end

    for name in pairs(self.inspections) do
        if not attached[name] then
            self.inspections[name] = nil
        end
    end

    local devices = self.config.devices or {}
    -- The one Stock Ticker every PC46 order goes through (shared with PC48 on
    -- the wired network): devices.stockTicker by name, or the first one.
    registry.stockTicker = selectDevice(registry.stockTickerList, devices.stockTicker) or false
    registry.generation = generation
    if generation == self.generation then self.registry = registry end
    return registry
end

return Bus
