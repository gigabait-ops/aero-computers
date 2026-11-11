if term and type(term.clear) == "function" then
    term.clear()
    term.setCursorPos(1, 1)
end

package.path = "/?.lua;/?/init.lua;./?.lua;./?/init.lua;./?/?.lua;" .. package.path

local GlobalConfig = require("config")
local Defaults = require("controller.defaults")
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

local ControllerPackage = require("controller")
local controller = ControllerPackage.new({
    config = settings,
    logger = logger,
})
local okRun, runError = pcall(controller.start, controller)
if not okRun then
    logger:error("startup.crashed", {error = runError})
    print("CONTROLLER ERROR")
    print(tostring(runError))
end
