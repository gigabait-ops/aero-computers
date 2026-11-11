package.path = "/?.lua;/?/init.lua;./?.lua;./?/init.lua;./?/?.lua;" .. package.path

local GlobalConfig = require("config")
local Defaults = require("mechanical.defaults")
local settings, configError = GlobalConfig.load("/settings.lua", Defaults)
if configError then
    error("settings.lua: " .. tostring(configError), 0)
end

local Logger = require("logger")
local logger = Logger.create(tostring(settings.kind) .. "-" .. tostring(os.getComputerID()), {
    file = settings.logFile,
    level = settings.logLevel,
    console = settings.logConsole == true,
    max_bytes = settings.logMaxBytes,
    max_files = settings.logMaxFiles,
})
logger:setEnabled(settings.logging ~= false)

peripheral.find("modem", function(name) rednet.open(name) end)

local Mechanical = require("mechanical")
local station = Mechanical.new({config = settings, logger = logger})
local ok, err = pcall(station.start, station)
if not ok then
    logger:error("startup.crashed", {error = tostring(err)})
    printError(tostring(err))
end
