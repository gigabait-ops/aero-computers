package.path = "/?.lua;/?/init.lua;./?.lua;./?/init.lua;./?/?.lua;" .. package.path

local GlobalConfig = require("config")
local Defaults = require("autocrafter.defaults")
local settings, configError = GlobalConfig.load("/settings.lua", Defaults)
if configError then
    error("settings.lua: " .. tostring(configError), 0)
end

local Logger = require("logger")
local logger = Logger.create(settings.logName .. "-" .. tostring(os.getComputerID()), {
    file = settings.logFile,
    level = settings.logLevel,
    console = settings.logConsole == true,
    max_bytes = settings.logMaxBytes,
    max_files = settings.logMaxFiles,
})
logger:setEnabled(settings.logging ~= false)

local View = require("autocrafter.view")
local computerId = os.getComputerID()
local address = "crafting_" .. tostring(computerId)
local view = View.new()
local inputName

local function draw(state, errorMessage)
    view:draw({
        computerId = computerId,
        address = address,
        inputSide = inputName,
        shipAddress = settings.shipAddress,
        state = state,
        error = errorMessage,
    })
end

local function main()
    draw("BOOTING")

    local PeripheralsBoot = require("autocrafter.peripherals")
    local devices = PeripheralsBoot.new({
        computerId = computerId,
        stateFile = settings.peripheralStateFile,
        logger = logger,
    }):run()
    inputName = devices.inputName

    if not devices.ready then
        logger:error("startup.peripherals_not_ready", {error = devices.error})
        draw("PERIPHERALS", devices.error)
        return false, devices.error
    end

    local Autocrafter = require("autocrafter")
    local worker = Autocrafter.new({
        config = settings,
        devices = devices,
        logger = logger,
        view = view,
    })
    return worker:start()
end

local ok, result, runError = pcall(main)
if not ok then
    logger:error("startup.crashed", {error = result})
    draw("CRASHED", tostring(result))
end
if result == false and runError then
    logger:error("startup.stopped", {error = runError})
    draw("ERROR", tostring(runError))
end
