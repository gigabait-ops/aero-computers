-- Worker turtle screen on the shared CC UI kit (`require("ui")`, Tensa
-- Aeronautics ROM): one status page drawn by the kit's App on the turtle's
-- terminal. The turtle takes no input; draw() only shows what the worker
-- reports. The API (View.new, view:draw(snapshot)) is unchanged for the
-- per-PC startup.lua files.
local UI = require("ui")
local Rows = UI.Rows

local View = {}
View.__index = View

local DOT = string.char(7)

local TONE = {
    IDLE = "ok", DONE = "ok",
    BOOTING = "info", PLANNING = "info", PLANNED = "info",
    REQUESTING = "warn", ORDER_WAIT = "warn", WAIT_DELIVERY = "warn", WAIT_CONTROLLER = "warn",
    PERIPHERALS = "warn",
    CRAFTING = "busy", CLEANING_INPUT = "busy",
    FAILED = "bad", ERROR = "bad", CRASHED = "bad",
}
-- The worker's phase as a plain word, the same words PC48 shows.
local WORDS = {
    REQUESTING = "ordering", ORDER_WAIT = "in line", WAIT_DELIVERY = "receiving",
    CLEANING_INPUT = "cleaning", WAIT_CONTROLLER = "finding PC48", PERIPHERALS = "checking devices",
}
local function word(state)
    return WORDS[state] or (state:lower():gsub("_", " "))
end

local function dash(value)
    if value == nil or value == "" then return "-" end
    return tostring(value)
end

local function pretty(name)
    if name == nil or name == "" then return "-" end
    return UI.Text.pretty(tostring(name))
end

-- The snapshot the worker reports -> the lines of the status page.
function View.lines(snapshot)
    local state = dash(snapshot.state)
    local job = "-"
    if snapshot.target then
        job = pretty(snapshot.target) .. (snapshot.requestedOutput and (" x" .. tostring(snapshot.requestedOutput)) or "")
    end
    local current, waiting = snapshot.current, snapshot.waitingFor
    local step = current and (tostring(current.step or "?") .. "/" .. tostring(current.steps or "?")
        .. " " .. pretty(current.target)) or "-"
    local waitText = "-"
    if waiting then
        waitText = pretty(waiting.name or waiting.item)
        local missing = waiting.missing or waiting.count
        if missing then waitText = waitText .. " x" .. tostring(missing) end
    end
    local lines = {
        {"State", word(state), TONE[state] or "text"},
        {"Control", snapshot.controllerId and ("PC" .. tostring(snapshot.controllerId)) or "searching",
            snapshot.controllerId and "ok" or "warn"},
        {"Job", job, "text"},
        {"Step", step, current and "info" or "muted"},
        {"Waiting", waitText, waiting and "warn" or "muted"},
        -- The input chest, shipped by the packager on top to the warehouse.
        {"Route", dash(snapshot.inputSide) .. " > packager > " .. dash(snapshot.shipAddress), "muted"},
        {"Assigned", dash(snapshot.assignment), "muted"},
    }
    local problem
    if snapshot.error then
        local warning = snapshot.errorSeverity == "WARN"
        problem = {warning and "warn" or "bad", (warning and "WARN " or "ERROR ") .. tostring(snapshot.error)}
    end
    return lines, problem
end

local function statusPage(model, context)
    local t = context.theme
    local rows = {Rows.section("Autocrafter #" .. dash(model.computerId), dash(model.address), t)}
    local lines, problem = View.lines(model)
    for _, line in ipairs(lines) do
        rows[#rows + 1] = Rows.status(line[1], line[2], t[line[3]] or t.text, t)
    end
    if problem then
        rows[#rows + 1] = {segs = {Rows.segment(DOT .. " ", t[problem[1]]), Rows.segment(problem[2], t[problem[1]])}}
    end
    return rows
end

function View.new(options)
    options = options or {}
    return setmetatable({target = options.target or term, now = options.now}, View)
end

-- The App is opened on the first draw and again after a terminal failure.
-- No freshness age in the footer: the worker redraws only when its state changes.
function View:open(snapshot)
    local ok, app = pcall(UI.App.new, {
        pages = {{name = "Status", page = statusPage}},
        state = snapshot,
        adapters = {
            current = function() return self.target end,
            isMonitor = function() return false end,
            getNames = function() return {} end,
            clock = self.now,
        },
    })
    self.app = ok and app or nil
    return self.app
end

function View:draw(snapshot)
    snapshot = snapshot or {}
    if not self.target then return false end
    if self.app and self.app.closed then self.app = nil end
    if not self.app and not self:open(snapshot) then return false end
    local ok = self.app:render(snapshot)
    return ok == true
end

return View
