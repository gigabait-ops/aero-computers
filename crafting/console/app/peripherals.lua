local Util = require("app.util")

local Peripherals = {}
Peripherals.__index = Peripherals

local function methodSet(name)
    local methods = peripheral and type(peripheral.getMethods) == "function"
        and peripheral.getMethods(name) or {}
    local result = {}

    for _, method in ipairs(methods or {}) do
        result[method] = true
    end

    return result
end

local function wraps(name)
    local ok, device = pcall(peripheral.wrap, name)
    return ok and device or nil
end

local function hasType(name, kind)
    if not peripheral or type(peripheral.hasType) ~= "function" then return false end
    local ok, value = pcall(peripheral.hasType, name, kind)
    return ok and value == true
end

local function signature(snapshot)
    return table.concat({
        tostring(snapshot.requesterName or "-"),
        table.concat(snapshot.modemNames or {}, ","),
        tostring((snapshot.clipboard or {}).name or "-"),
        tostring((snapshot.ticker or {}).name or "-"),
    }, "|")
end

function Peripherals:new(logger)
    return setmetatable({
        logger = logger,
        snapshot = {
            requester = nil,
            requesterName = nil,
            modemNames = {},
            clipboard = nil,
            ticker = nil,
            signature = "",
        },
    }, self)
end

function Peripherals:invalidate()
    self.scanned = false
    self.revision = (self.revision or 0) + 1
end

function Peripherals:scan()
    if self.scanned then return self.snapshot, false end
    local revision = self.revision
    local names = peripheral and type(peripheral.getNames) == "function"
        and peripheral.getNames() or {}
    table.sort(names)

    -- clipboard, ticker: the checklist's Create clipboard and Stock Ticker
    -- on the wired network ({name, device}), the first of each.
    local result = {
        requester = nil,
        requesterName = nil,
        modemNames = {},
        clipboard = nil,
        ticker = nil,
    }

    for _, name in ipairs(names) do
        local methods = methodSet(name)

        if not result.requester and methods.getRequest and methods.setRequest then
            result.requester = wraps(name)
            result.requesterName = result.requester and name or nil
        end

        if not result.clipboard and ((methods.getMissingItems and methods.getItemEntries)
            or hasType(name, "Create_ClipboardChecklist")) then
            local device = wraps(name)
            result.clipboard = device and {name = name, device = device} or nil
        end

        if not result.ticker and ((methods.stock and methods.requestFiltered) or hasType(name, "Create_StockTicker")) then
            local device = wraps(name)
            result.ticker = device and {name = name, device = device} or nil
        end

        local isModem = methods.transmit and (methods.isWireless or methods.open or methods.close)
        if not isModem then isModem = hasType(name, "modem") end

        if isModem then
            result.modemNames[#result.modemNames + 1] = name
        end
    end

    result.signature = signature(result)
    local changed = result.signature ~= self.snapshot.signature
    self.snapshot = result
    self.scanned = self.revision == revision

    if changed then
        Util.log(self.logger, "info", "peripherals.changed", {
            requester = result.requesterName or "missing",
            modems = table.concat(result.modemNames, ","),
            clipboard = (result.clipboard or {}).name or "none",
            ticker = (result.ticker or {}).name or "none",
        })
    end

    return result, changed
end

return Peripherals
