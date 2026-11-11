-- A turtle's blocks (owner 2026-10-28: turtles find everything themselves).
-- Next to the turtle: its frogport (it names it "crafting_<id>"), its
-- workbench and modems. On the shared cable: one Stock Ticker and every
-- turtle's barrel and packager, which cannot be told apart by name. So a
-- turtle seen for the first time orders marker items to its own address, a
-- count no other turtle uses (id % 50 + 1): the barrel that gains exactly
-- that many is its input, and the packager that lists them is its packager
-- (a packager lists its barrel, verified on PC139). Turtles booting
-- together do not mix up their markers. The pair is kept in
-- data/peripherals.lua and checked at every boot; cleanup ships the markers.
local AtomicStore = require("atomic_store")
local Util = require("fleet_util")
local Devices = require("mechanical.devices")

local PeripheralsBoot = {}
PeripheralsBoot.__index = PeripheralsBoot

local STATE_VERSION = 2
local SIDES = {"top", "bottom", "left", "right", "front", "back"}

local function hasType(name, wanted)
    local ok, yes = pcall(peripheral.hasType, name, wanted)
    return ok and yes == true
end

function PeripheralsBoot.new(options)
    options = options or {}
    local id = options.computerId or os.getComputerID()
    return setmetatable({
        computerId = id,
        address = "crafting_" .. tostring(id),
        stateFile = options.stateFile or "data/peripherals.lua",
        markerCount = id % 50 + 1,
        findSeconds = options.findSeconds or 90,
        sleep = options.sleep or os.sleep,
        clock = options.clock or os.clock,
        logger = options.logger,
    }, PeripheralsBoot)
end

function PeripheralsBoot:log(event, fields) Util.log(self.logger, event, fields) end

-- Names of `ccType`: next to the turtle (sides) or on the cable.
function PeripheralsBoot:find(ccType, onSide)
    local found = {}
    if onSide then
        for _, side in ipairs(SIDES) do
            if hasType(side, ccType) then found[#found + 1] = side end
        end
    else
        for _, name in ipairs(peripheral.getNames()) do
            if name:find("_%d+$") and hasType(name, ccType) then found[#found + 1] = name end
        end
        table.sort(found)
    end
    return found
end

function PeripheralsBoot:run()
    local issues = {}
    local function need(value, message)
        if not value then issues[#issues + 1] = message end
        return value
    end

    local opened = 0
    for _, side in ipairs(self:find("modem", true)) do
        if pcall(rednet.open, side) then opened = opened + 1 end
    end
    need(opened > 0, "no modem")
    local ticker = need(self:find("Create_StockTicker")[1], "no stock ticker on the cable")
    need(self:find("workbench", true)[1], "no workbench")
    local frogport = need(self:find("Create_Frogport", true)[1], "no frogport next to the turtle")
    if frogport then pcall(peripheral.call, frogport, "setAddress", self.address) end

    local state = AtomicStore.load(self.stateFile, fs)
    local input, packager
    if type(state) == "table" and state.version == STATE_VERSION and state.computerId == self.computerId
        and peripheral.isPresent(state.input or "") and peripheral.isPresent(state.packager or "") then
        input, packager = state.input, state.packager
    elseif ticker and frogport then
        local second
        input, second = Devices.locate(peripheral, {
            ticker = peripheral.wrap(ticker), address = self.address, count = self.markerCount,
            seconds = self.findSeconds, sleep = self.sleep, clock = self.clock,
            log = function(event, fields) self:log(event, fields) end,
        })
        if input then
            packager = second
            AtomicStore.save(self.stateFile, {version = STATE_VERSION, computerId = self.computerId,
                input = input, packager = packager}, fs)
        else
            issues[#issues + 1] = second
        end
    end

    local ready = #issues == 0
    local errorMessage = ready and nil or table.concat(issues, "; ")
    self:log("peripherals.ready", {ready = ready, input = input, packager = packager, ticker = ticker,
        frogport = frogport, address = self.address, error = errorMessage})
    return {
        ready = ready,
        error = errorMessage,
        address = self.address,
        inputName = input,
        inputStorage = input and peripheral.wrap(input),
        packager = packager and peripheral.wrap(packager),
        stockTicker = ticker and peripheral.wrap(ticker),
    }
end

return PeripheralsBoot
