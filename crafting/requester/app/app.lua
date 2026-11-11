local App = {}
App.__index = App

local Bus = require("app.bus")
local Config = require("app.config")
local ConfigLoader = require("app.config_loader")
local Controller = require("app.controller")
local Logger = require("logger")
local Orderer = require("app.orderer")
local StockReader = require("app.stock_reader")

local APP_VERSION = "2026-11-08.1"

local function createLogger(model)
    return Logger.create(model:get("logging.name", "requester"), {
        enabled = model:get("logging.enabled", true) ~= false,
        level = model:get("logging.level", "info"),
        console = model:get("logging.console", false) == true,
        max_bytes = tonumber(model:get("logging.maxBytes", 32768)) or 32768,
        max_files = tonumber(model:get("logging.maxFiles", 4)) or 4
    })
end

-- PC46 from /config.lua and /requests/*.lua; rules that do not load leave
-- it empty until a valid edit (the controller reloads them). Tests pass a
-- raw config (never reloaded) and options.logger / options.term.
function App:new(config, options)
    options = options or {}
    local loader = nil

    if config == nil then
        loader = ConfigLoader:new()
        local loaded = loader:refreshLocal()
        config = loaded.ok and loaded.raw or {}
    end

    local model = Config:new(config)
    local log = options.logger or createLogger(model)

    pcall(log.info, log, "app.boot", {
        version = APP_VERSION,
        queuePollSeconds = model:queuePollSeconds()
    })

    return setmetatable({
        controller = Controller:new({
            config = model,
            configLoader = loader,
            logger = log,
            bus = Bus:new(model.raw),
            reader = StockReader:new(),
            orderer = Orderer:new({
                turtle = model:get("turtle", {}),
                logger = log
            }),
            term = options.term or (term and term.current and term.current()) or nil,
            version = APP_VERSION
        })
    }, self)
end

function App:run()
    self.controller:run()
end

App.Bus = Bus
App.Config = Config
App.ConfigLoader = ConfigLoader
App.Controller = Controller
App.Orderer = Orderer
App.StockReader = StockReader

return App
