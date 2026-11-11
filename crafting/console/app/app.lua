local ChecklistRunner = require("app.checklist_runner")
local CraftClient = require("app.craft_client")
local Notice = require("chat.notice")
local Logger = require("logger")
local Peripherals = require("app.peripherals")
local Screens = require("app.screens")
local Selector = require("app.requester_selector")
local StateStore = require("app.state_store")
local UI = require("ui")
local Util = require("app.util")

local VERSION = "2026-11-10.1"
local WAKE = "manual_craft_wake"
local TOAST_SECONDS = 8
local CONFIRM_SECONDS = 15

local App = {}
App.__index = App

local DEFAULTS = {
    timing = {
        tickSeconds = 0.5,
        peripheralScanSeconds = 2,
    },
    controller = {
        hostname = "craft-controller",
        protocol = "gigabait.craft.request.v1",
        retrySeconds = 2,
        retryMaxSeconds = 30,
        querySeconds = 5,
        pingSeconds = 5,
        lookupSeconds = 10,
        offlineSeconds = 15,
    },
    state = {path = "/data/state.lua", maxHistory = 100},
    -- The Create clipboard checklist (66/config.lua explains each value).
    checklist = {
        enabled = true,
        address = "",
        readSeconds = 2,
        stockSeconds = 2,
        recipeChecksPerScan = 16,
        rawPauseSeconds = 600,
        pollSeconds = 0.25,
    },
    logging = {
        enabled = true,
        name = "manual-craft",
        level = "info",
        console = false,
        maxBytes = 32768,
        maxFiles = 4,
    },
}

local function merge(defaults, values)
    local result = {}

    for key, value in pairs(defaults or {}) do
        result[key] = type(value) == "table" and merge(value, {}) or value
    end

    for key, value in pairs(values or {}) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = merge(result[key], value)
        else
            result[key] = value
        end
    end

    return result
end

local function loadConfig()
    local ok, values = pcall(dofile, "/config.lua")
    return merge(DEFAULTS, ok and type(values) == "table" and values or {})
end

local function createLogger(config)
    local logging = config.logging or {}
    return Logger.create(logging.name or "manual-craft", {
        enabled = logging.enabled ~= false,
        level = logging.level or "info",
        console = logging.console == true,
        max_bytes = tonumber(logging.maxBytes) or 32768,
        max_files = tonumber(logging.maxFiles) or 4,
    })
end

function App:new()
    local config = loadConfig()
    local logger = createLogger(config)
    local store = StateStore:new(config.state.path, config.state.maxHistory, logger)

    local instance = setmetatable({
        config = config,
        logger = logger,
        store = store,
        hints = Util.routeHints(config.routeHints),
        peripherals = Peripherals:new(logger),
        selector = Selector:new(logger),
        lastPeripheralScan = 0,
        toasts = {},
        confirms = {},
        confirmSeq = 0,
        intents = {},
        lastError = nil,
    }, self)

    instance.client = CraftClient:new({
        config = config.controller,
        store = store,
        logger = logger,
        onAccepted = function(job)
            instance:onAccepted(job)
        end,
        onRejected = function(job)
            instance:onRejected(job)
        end,
        onTerminal = function(job)
            instance:onTerminal(job)
        end,
    })

    instance.runner = ChecklistRunner:new({
        config = config.checklist,
        client = instance.client,
        logger = logger,
        hints = instance.hints,
        computerId = os.getComputerID(),
    })

    Util.log(logger, "info", "app.boot", {
        computer = os.getComputerID(),
        version = VERSION,
    })

    return instance
end

function App:scanPeripherals(now, force)
    local interval = tonumber(self.config.timing.peripheralScanSeconds) or 2
    if not force and now - self.lastPeripheralScan < interval then
        return
    end

    self.lastPeripheralScan = now
    local devices, changed = self.peripherals:scan()
    self.selector:setDevice(devices.requester, devices.requesterName)
    self.client:setModems(devices.modemNames)

    if changed then
        self:toast("info", "Peripherals: requester " .. tostring(devices.requesterName or "missing")
            .. ", modems " .. (#devices.modemNames > 0 and table.concat(devices.modemNames, ",") or "missing"))
    end
end

-- Results for the screens (kit toasts, newest last).
function App:toast(status, text)
    self.toasts = UI.Feedback.Toasts.push(self.toasts, {text = text, status = status}, Util.now(), TOAST_SECONDS)
end

function App:syncSelector()
    local changed, err = self.selector:syncDrafts(self.store.state.drafts)

    if changed then
        self.store:save("selector synchronized")
    end

    if err then
        self.lastError = err
    elseif self.lastError == "redstone requester missing"
        or self.lastError == "requester returned invalid data"
    then
        self.lastError = nil
    end
end

function App:selectedCount()
    local count = 0
    for _ in pairs(self.store.state.drafts) do
        count = count + 1
    end
    return count
end

function App:submit(slot)
    local draft = self.store.state.drafts[tostring(slot)]
    if not draft or draft.jobId then
        return false
    end

    local job, err = self.client:submit(draft)
    if not job then
        self.lastError = tostring(err)
        return false
    end

    draft.jobId = job.id
    draft.jobState = job.state
    -- Draft ownership was committed together with the outbox job.
    return true
end

function App:submitAll()
    local ok, result = self.store:batch(function()
        local submitted = 0
        for slot = 1, 9 do
            if self:submit(slot) then submitted = submitted + 1 end
        end
        return submitted
    end)
    if not ok then
        self.lastError = tostring(result)
        self:toast("bad", "Requests not saved: " .. self.lastError)
        return false
    end
    self:toast("ok", "Queued " .. tostring(result) .. " requests")
    return true
end

function App:historyJob(jobId)
    for _, job in ipairs(self.store.state.history) do
        if tostring(job.id) == tostring(jobId) then
            return job
        end
    end
    return nil
end

function App:repeatHistory(jobId)
    local source = self:historyJob(jobId)

    if not source or type(source.target) ~= "string" or source.target == "" then
        self.lastError = "history request unavailable"
        self:toast("bad", "History request unavailable")
        return false
    end

    local job, err = self.client:submit({
        name = source.target,
        displayName = source.displayName,
        quantity = source.count,
        sourceCount = source.sourceCount,
    })
    if not job then
        self.lastError = tostring(err)
        self:toast("bad", "Repeat failed: " .. self.lastError)
        return false
    end

    self.lastError = nil
    self:toast("ok", "Queued again " .. Util.itemLabel(source) .. " x" .. tostring(source.count))
    return true
end

function App:onAccepted(job)
    local key = tostring(job.slot)
    local draft = self.store.state.drafts[key]

    if draft and draft.jobId == job.id then
        local cleared, err = self.selector:clearSlot(job.slot, job.target, job.sourceCount or job.count, job.sourceNbt)
        if cleared then
            self.store.state.drafts[key] = nil
            self:toast("info", "Accepted " .. Util.itemLabel(job) .. " x" .. tostring(job.count))
        else
            draft.jobState = "CLEAR ERROR"
            self.lastError = tostring(err)
        end
        self.store:save("accepted selection handled")
    end
end

function App:onRejected(job)
    local draft = self.store.state.drafts[tostring(job.slot)]
    if draft and draft.jobId == job.id then
        draft.jobId = nil
        draft.jobState = nil
    end
    self.store:save("rejected selection unlocked")
    self.lastError = Notice.failureText(job.failure, job.error or "request rejected")
    self:toast("bad", "Rejected " .. Util.itemLabel(job) .. ": " .. self.lastError)
end

function App:onTerminal(job)
    local shortage = Util.rawShortage(job, self.hints)
    if shortage then
        self:toast("warn", "Needs " .. UI.Text.pretty(shortage.raw) .. " x" .. tostring(shortage.needed)
            .. " for " .. Util.itemLabel(job) .. ": " .. (Screens.howMade(shortage.hint)))
    elseif job.state == "DONE" then
        self:toast("ok", "Done " .. Util.itemLabel(job) .. " x" .. tostring(job.count))
    else
        self:toast("bad", Util.itemLabel(job) .. " x" .. tostring(job.count) .. ": "
            .. Notice.failureText(job.failure, job.error or job.state))
    end
    if job.state ~= "DONE" then
        self.lastError = Notice.failureText(job.failure, job.error or job.state)
    end
end

-- Questions -----------------------------------------------------------------------

-- A question for one screen (CRAFT / Cancel); it lapses after a while.
-- Choice buttons (a checklist row) get ids that carry the question's
-- number, so an old answer never acts.
function App:ask(screenId, question, now)
    self.confirmSeq = self.confirmSeq + 1
    question.seq = self.confirmSeq
    question.screenId = screenId
    question.expiresAt = now + CONFIRM_SECONDS
    for _, choice in ipairs(question.choices or {}) do
        choice.id = ("confirm%d_%s"):format(question.seq, choice.action)
    end
    self.confirms[screenId] = question
end

function App:askCraft(screenId, slot, now)
    local draft = slot and self.store.state.drafts[tostring(slot)]
    if not draft then
        self:toast("info", "Slot " .. tostring(slot) .. " is empty: pick an item in the requester")
    elseif draft.jobId then
        self:toast("warn", "Slot " .. tostring(slot) .. " is " .. (Screens.word(draft.jobState or "PENDING")) .. " already")
    else
        self:ask(screenId, {kind = "craft", slot = slot, name = draft.name, quantity = draft.quantity,
            title = "Craft slot " .. tostring(slot) .. "?",
            message = Util.itemLabel(draft) .. " x" .. tostring(draft.quantity), submitLabel = "CRAFT"}, now)
    end
end

function App:askCraftAll(screenId, now)
    local ready = 0
    for _, draft in pairs(self.store.state.drafts) do
        if not draft.jobId then ready = ready + 1 end
    end
    if ready > 0 then
        self:ask(screenId, {kind = "craft_all", title = "Craft all ready slots?",
            message = tostring(ready) .. " requests go to the controller", submitLabel = "CRAFT ALL"}, now)
    end
end

function App:askRepeat(screenId, jobId, now)
    local source = self:historyJob(jobId)
    if not source then
        self:toast("bad", "History request unavailable")
        return
    end
    local shortage = Util.rawShortage(source, self.hints)
    local again = source.state == "DONE" and not shortage
    local title = again and "Repeat this request?" or "Retry this request?"
    local note, noteTone
    if shortage then
        title = "Retry? It needs " .. UI.Text.pretty(shortage.raw) .. " x" .. tostring(shortage.needed)
        note, noteTone = Screens.howMade(shortage.hint)
        note = note:sub(1, 1):upper() .. note:sub(2)
    end
    self:ask(screenId, {kind = "repeat", jobId = tostring(source.id), title = title,
        message = Util.itemLabel(source) .. " x" .. tostring(source.count),
        note = note, noteTone = noteTone, submitLabel = again and "REPEAT" or "RETRY"}, now)
end

function App:askClearHistory(screenId, now)
    local count = #self.store.state.history
    if count > 0 then
        self:ask(screenId, {kind = "clear_history", title = "Clear the history?",
            message = "All " .. tostring(count) .. " entries are deleted", submitLabel = "CLEAR"}, now)
    end
end

-- A touch on a checklist row: send what is in stock, craft what is
-- missing, or both (crafts are then delivered too).
function App:askChecklistRow(screenId, name, now)
    local checklist = self.runner.checklist
    for _, row in ipairs(checklist:snapshot().rows or {}) do
        if row.name == name then
            local stock, remaining, missing = tonumber(row.stock) or 0, tonumber(row.remaining) or 0, tonumber(row.missing) or 0
            local choices = {}
            if row.canSend then
                choices[#choices + 1] = {action = "send", label = "SEND " .. math.min(stock, remaining), color = "ok"}
            end
            if row.canCraft then
                choices[#choices + 1] = {action = "craft", label = "CRAFT " .. missing}
                if checklist:address() ~= "" then
                    choices[#choices + 1] = {action = "both", label = "CRAFT + SEND", color = "warn"}
                end
            end
            if #choices == 0 then
                return self:toast("info", Util.itemLabel(row) .. ": nothing to send or craft")
            end
            return self:ask(screenId, {kind = "checklist", name = row.name, label = Util.itemLabel(row),
                choices = choices, submitLabel = "Cancel",
                width = 60, title = Util.itemLabel(row) .. ": " .. tostring(row.needed or 0) .. " required",
                message = ("%d in stock, %d missing"):format(stock, missing)}, now)
        end
    end
end

local BULK = {
    cl_send_all = function(address)
        return {action = "send", title = "Send the list to " .. address .. "?",
            message = "Everything in stock goes now", submitLabel = "SEND"}
    end,
    cl_craft_all = function()
        return {action = "craft", title = "Craft every missing item?",
            message = "Rows marked NEEDS are skipped", submitLabel = "CRAFT"}
    end,
    cl_craft_send_all = function(address)
        return {action = "both", title = "Craft the missing items and send all?",
            message = "Stock goes now, crafts follow to " .. address, submitLabel = "CRAFT + SEND"}
    end,
}

function App:askChecklistBulk(screenId, id, now)
    local question = BULK[id](self.runner.checklist:address())
    question.kind = "checklist"
    self:ask(screenId, question, now)
end

-- The kit's actions, inside its input handling. Questions open and close at
-- once; whatever writes state or talks to PC48 runs in the worker loop.
function App:onUiAction(action, model, info)
    local id = tostring(action.id or "")
    local screenId = info and info.screenId or "terminal"
    local now = Util.now()

    if id == "slots" and action.type == "change" then
        self:askCraft(screenId, tonumber(action.value), now)
    elseif id == "craft_all" and action.type == "activate" then
        self:askCraftAll(screenId, now)
    elseif id == "history" and action.type == "change" then
        self:askRepeat(screenId, action.value, now)
    elseif id == "clear_history" and action.type == "activate" then
        self:askClearHistory(screenId, now)
    elseif id == "checklist" and action.type == "change" then
        self:askChecklistRow(screenId, action.value, now)
    elseif BULK[id] and action.type == "activate" then
        self:askChecklistBulk(screenId, id, now)
    elseif id:match("^confirm%d+_%a+$") and action.type == "activate" then
        local question = self.confirms[screenId]
        local seq, choice = id:match("^confirm(%d+)_(%a+)$")
        if question and tonumber(seq) == question.seq then
            self.confirms[screenId] = nil
            self.intents[#self.intents + 1] = {kind = question.kind, name = question.name, label = question.label,
                action = choice}
            os.queueEvent(WAKE)
        end
    elseif id:match("^confirm%d+$") and (action.type == "submit" or action.type == "cancel") then
        local question = self.confirms[screenId]
        if question and id == "confirm" .. tostring(question.seq) then
            self.confirms[screenId] = nil
            -- A question with choices has only Cancel besides them.
            if action.type == "submit" and not question.choices then
                self.intents[#self.intents + 1] = question
                os.queueEvent(WAKE)
            end
        end
    end

    model.toasts = self.toasts
end

-- A confirmed question, in the worker loop.
function App:answer(question)
    if question.kind == "craft" then
        local draft = self.store.state.drafts[tostring(question.slot)]
        if not draft or draft.jobId or draft.name ~= question.name or draft.quantity ~= question.quantity then
            self:toast("warn", "Slot " .. tostring(question.slot) .. " changed meanwhile: nothing sent")
        elseif self:submit(question.slot) then
            self:toast("ok", "Queued " .. Util.itemLabel(draft) .. " x" .. tostring(draft.quantity))
        else
            self:toast("bad", "Not queued: " .. tostring(self.lastError))
        end
    elseif question.kind == "craft_all" then
        self:submitAll()
    elseif question.kind == "repeat" then
        self:repeatHistory(question.jobId)
    elseif question.kind == "clear_history" then
        local ok = self.store:clearHistory()
        self:toast(ok and "ok" or "bad", ok and "History cleared" or "History not cleared")
    elseif question.kind == "checklist" then
        local added, err = self.runner:act(question.action, question.name)
        if added then
            self:toast("ok", "Queued " .. tostring(added) .. (question.label and (" for " .. question.label)
                or (added == 1 and " order" or " orders")))
        else
            self:toast("bad", "Not queued: " .. tostring(err))
        end
    end
end

-- Screens -------------------------------------------------------------------------

function App:snapshot(now)
    local client = self.client

    return {
        now = now,
        drafts = self.store.state.drafts,
        selectedCount = self:selectedCount(),
        history = self.store:history(),
        hints = self.hints,
        controller = {online = client:online(now)},
        -- What is wrong right now (one line on Craft).
        problem = self.store.lastError or self.client.lastError or self.selector.lastError,
        checklist = self.runner:snapshot(),
        toasts = self.toasts,
        confirms = self.confirms,
        computerId = os.getComputerID(),
        version = VERSION,
        -- The footer's "updated" age is the controller's last answer.
        updatedAt = client.lastPong > 0 and client.lastPong or nil,
        interval = tonumber(self.config.controller.pingSeconds) or 5,
    }
end

-- The kit's App on the terminal and every monitor it finds (touch, text
-- scale 0.5); a monitor follows the terminal's tab.
function App:openScreens(now)
    self.screensRetryAt = now + 5
    local ui, err = UI.App.new({
        pages = Screens.pages(),
        state = self.model,
        adapters = {clock = Util.now},
        onAction = function(action, model, info)
            self:onUiAction(action, model, info)
        end,
    })
    if not ui then
        Util.log(self.logger, "error", "screens.failed", {error = tostring(err)})
    end
    self.ui = ui
end

-- A new model for the screens from the current state, then a repaint.
function App:refresh(now)
    self.model = Screens.model(self:snapshot(now))
    if self.ui and self.ui.closed then
        Util.log(self.logger, "error", "screens.closed", {error = tostring(self.ui.error)})
        self.ui = nil
    end
    if not self.ui and now >= (self.screensRetryAt or 0) then
        self:openScreens(now)
    end
    if self.ui then
        self.ui:render(self.model)
    end
end

function App:tick(force)
    local now = Util.now()
    self:scanPeripherals(now, force)
    self:syncSelector()
    self.client:tick(now)

    for key, draft in pairs(self.store.state.drafts) do
        if draft.jobId then
            local job = self.store.state.jobs[draft.jobId]
            draft.jobState = job and job.state or draft.jobState
        end
    end

    for screenId, question in pairs(self.confirms) do
        if now > question.expiresAt then
            self.confirms[screenId] = nil
        end
    end

    self:refresh(now)
end

function App:run()
    local messages, head = {}, 1

    local function wait(seconds)
        local timer = os.startTimer(seconds)
        while true do
            local name, id = os.pullEvent()
            if name == WAKE then
                os.cancelTimer(timer)
                return
            elseif name == "timer" and id == timer then
                return
            end
        end
    end

    local function workerLoop()
        self:tick(true)
        while true do
            local processed = 0
            while messages[head] and processed < 32 do
                local event = messages[head]
                messages[head], head = false, head + 1
                processed = processed + 1
                if not self.client:handleMessage(event[2], event[3], event[4]) then
                    self.runner:handleMessage(event[2], event[3], event[4])
                end
            end
            if head > #messages then messages, head = {}, 1 end
            while #self.intents > 0 do
                self:answer(table.remove(self.intents, 1))
            end
            self:tick(false)
            wait(tonumber(self.config.timing.tickSeconds) or 0.5)
        end
    end

    -- The checklist: the clipboard, the stock and one order per pass (a
    -- ticker order may wait for PC48's order gate, so it has a loop of its own).
    local function checklistLoop()
        while true do
            local ok, err = pcall(self.runner.step, self.runner, self.peripherals.snapshot, Util.now())
            if not ok and tostring(err) ~= self.checklistError then
                Util.log(self.logger, "error", "checklist.failed", {error = tostring(err)})
            end
            self.checklistError = not ok and tostring(err) or nil
            local timer = os.startTimer(self.runner:pollSeconds())
            repeat local _, id = os.pullEvent("timer") until id == timer
        end
    end

    -- Every event but PC48's messages goes to the kit (keys, touches, its
    -- own repaint timer, monitors coming and going).
    local function inputLoop()
        while true do
            local event = table.pack(os.pullEvent())
            local name = event[1]
            if name == "rednet_message" then
                messages[#messages + 1] = event
            elseif name ~= WAKE then
                if name == "peripheral" or name == "peripheral_detach" then
                    self.peripherals:invalidate()
                    self.lastPeripheralScan = -math.huge
                end
                if name == "peripheral_detach" then
                    -- The checklist must not bind a clipboard that is gone
                    -- before the next scan.
                    local devices = self.peripherals.snapshot
                    for _, key in ipairs({"clipboard", "ticker"}) do
                        if devices[key] and devices[key].name == event[2] then devices[key] = nil end
                    end
                    self.runner:detach(event[2])
                end
                if name == "recipes_reloaded" then self.runner.reloadRecipes = true end
                local ui = self.ui
                if ui and not ui.closed then
                    ui:handle(table.unpack(event, 1, event.n))
                    if (name == "monitor_touch" or name == "mouse_click") and not ui.closed then
                        Screens.unfocus(ui, name == "monitor_touch" and event[2] or "terminal")
                        ui:render()
                    end
                end
            end
        end
    end

    self.model = Screens.model(self:snapshot(Util.now()))
    self:openScreens(Util.now())
    local ok, err = pcall(parallel.waitForAny, workerLoop, inputLoop, checklistLoop)
    if self.ui then
        self.ui:close()
    end
    if not ok then
        error(err, 0)
    end
end

function App:crash(errorMessage)
    Util.log(self.logger, "error", "app.crash", {error = tostring(errorMessage)})
    self.store:save("crash")
end

return App
