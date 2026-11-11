-- Colony Supply: the screens. The pages are app/ui.lua; drawing, tabs,
-- monitors and touch are the server's shared UI library (common.ui from the
-- Tensa Aeronautics datapack, `require("ui")`). Also the plain text shown
-- while something stops the program.
local Screen = {}

-- The shared library, fresh; nil and why when the server's is too old.
function Screen.library()
    for name in pairs(package.loaded) do
        if name == "ui" or name:find("^common%.ui") then package.loaded[name] = nil end
    end
    local ok, lib = pcall(require, "ui")
    if ok and type(lib) == "table" and type(lib.App) == "table" and type(lib.Rows) == "table"
        and type(lib.Text) == "table" and type(lib.Theme) == "table" then
        return lib
    end
    return nil, ok and "the server's UI library has no App yet" or tostring(lib)
end

-- Plain text on the computer; the program starts again when `changed()` says so.
function Screen.hold(title, lines, changed)
    term.redirect(term.native())
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print(title)
    term.setTextColor(colors.white)
    for _, text in ipairs(lines) do print(text) end
    term.setTextColor(colors.lightGray)
    print()
    print("The program starts again by itself.")
    repeat sleep(2) until changed()
    return "restart"
end

-- Is `name` the monitor the config wants? ("auto" = any monitor)
local function wanted(screen, name)
    if screen.monitor == false or name == nil then return false end
    if screen.monitor == nil or screen.monitor == "auto" then
        return peripheral.hasType(name, "monitor") == true
    end
    return name == screen.monitor
end

-- The App on the terminal and every wanted monitor (all on the same tab),
-- with draw() and input() that log screen errors once each.
function Screen.open(Lib, pages, st, cfg, log, clock)
    local scale = tonumber(cfg.screen.scale) or 0.5
    local function wrap(name)
        local mon = peripheral.wrap(name)
        if type(mon) ~= "table" or type(mon.setTextScale) ~= "function" then return mon end
        -- App sets text scale 0.5 on touch screens; keep screen.scale
        return setmetatable({setTextScale = function() return mon.setTextScale(scale) end}, {__index = mon})
    end
    local app, appError = Lib.App.new({pages = pages, state = st, palette = cfg.screen.palette ~= false,
        interval = 1, adapters = {clock = clock, wrap = wrap,
            isMonitor = function(name) return wanted(cfg.screen, name) end}})
    if not app then
        -- no screen, but the colony is still supplied
        log.error("screen", tostring(appError))
        printError("Screen unavailable: " .. tostring(appError))
        app = {render = function() return true end, handle = function() return false end,
            close = function() return true end}
    end

    local self = {app = app, monitors = {}}
    for _, id in ipairs(app.order or {}) do
        if id ~= "terminal" then self.monitors[#self.monitors + 1] = id end
    end

    local lastError, failures = nil, {}
    local function noteErrors()
        local errors = app.screenErrors and app:screenErrors() or {}
        for id, message in pairs(errors) do
            if failures[id] ~= message then
                failures[id] = message
                log.error("screen", id, tostring(message))
            end
        end
        for id in pairs(failures) do
            if errors[id] == nil then failures[id] = nil end
        end
    end

    function self.draw()
        local ok, err = app:render(st)
        if not ok and err ~= lastError then log.error("screen", tostring(err)) end
        lastError = not ok and err or nil
        noteErrors()
    end

    -- Keys, clicks, touches, monitors and App's own 1 s timer; Ctrl+T still
    -- ends the program (os.pullEvent raises "Terminated").
    function self.input()
        while true do
            local event = {os.pullEvent()}
            local name = event[2]
            local had = app.screens and app.screens[name] ~= nil
            local _, err = app:handle(table.unpack(event))
            if event[1] == "peripheral" and not had and app.screens and app.screens[name] then
                log.info("monitor", name, "attached")
            elseif event[1] == "peripheral_detach" and had then
                log.info("monitor", name, "detached")
            end
            noteErrors()
            if err and err ~= lastError then
                log.error("screen", tostring(err))
                lastError = err
            end
        end
    end

    function self.close() app:close() end   -- restores the palettes
    return self
end

return Screen
