-- PC48 screens on the shared CC UI kit (`require("ui")`, Tensa Aeronautics
-- ROM), in the fleet's PC107 style (docs/screen-style.md): sections, rows
-- with a pretty name, a progress bar, muted numbers and a dot with a state
-- word. The kit's App owns the terminal and every monitor it finds: tabs,
-- footer, palette, touch and scrolling. S.model turns the controller's
-- snapshot into records; the pages only lay them out.
local UI = require("ui")
local Rows, Text = UI.Rows, UI.Text

local S = {}

-- State word -> theme colour; the word is always shown next to it.
local TONE = {
    idle = "ok", done = "ok", completed = "ok",
    planning = "info", planned = "info", booting = "info", assigned = "info", queued = "info",
    crafting = "busy", active = "busy", cleaning = "busy",
    shipping = "busy",
    ordering = "warn", receiving = "warn", ["in line"] = "warn", pending = "warn",
    waiting = "warn", queue = "warn", warning = "warn", supply = "warn", tool = "warn",
    offline = "bad", stalled = "bad", failed = "bad", error = "bad",
}
function S.tone(word) return TONE[tostring(word)] or "text" end

-- Worker phases and job states as plain lowercase words.
local WORDS = {
    REQUESTING = "ordering", ORDER_WAIT = "in line", WAIT_DELIVERY = "receiving",
    CLEANING_INPUT = "cleaning", WAIT_CONTROLLER = "waiting",
    -- Stations (mechanical.station).
    WAITING_DELIVERY = "receiving", WAITING_TOOL = "tool", WAITING_SUPPLY = "supply",
    WAITING_STATION = "supply", WAITING_MECHANICAL = "supply",
}
local CHIP = 14 -- dot, space, the longest word ("receiving", "planning") and a gap
local function word(value)
    value = tostring(value or "idle")
    return WORDS[value] or (value:lower():gsub("_", " "))
end
S.word = word

local function pretty(name)
    if name == nil or name == "" then return "-" end
    return Text.pretty(tostring(name))
end

-- The controller's own state word: errors first, then work.
local function overall(snapshot)
    local stats = snapshot.stats or {}
    if snapshot.lastError then return "error" end
    if snapshot.lastWarning then return "warning" end
    if (tonumber(stats.assigned) or 0) > 0 then return "active" end
    if (tonumber(stats.queued) or 0) > 0 then return "queue" end
    return "idle"
end

local function phaseOf(worker)
    if not worker.online then return "offline" end
    local job = worker.job
    if job and job.status == "STALLED" then return "stalled" end
    return word(job and job.phase or worker.state)
end

-- Model --------------------------------------------------------------------------

-- A worker's row label: what it is, its computer ID beside it.
local KIND_LABEL = {turtle = "Turtle", mechanical = "Crafter", saw = "Saw", slicer = "Slicer", basin = "Basin",
    compact = "Compacting"}

local function workerRecords(workers)
    local records = {}
    for index, worker in ipairs(workers or {}) do
        local job = worker.job
        local current, waiting = job and job.current, job and job.waitingFor
        records[index] = {
            name = "PC" .. tostring(worker.id),
            label = KIND_LABEL[worker.kind] or "Worker",
            id = tostring(worker.id),
            phase = phaseOf(worker),
            target = job and pretty(current and current.target or job.target) or nil,
            count = tonumber(job and job.count),
            step = tonumber(current and current.step),
            steps = tonumber(current and current.steps),
            waiting = waiting and waiting.name and (pretty(waiting.name) .. " x" .. tostring(waiting.missing or "?")) or nil,
        }
    end
    return records
end

local function jobRecords(jobs)
    local records = {}
    for index, job in ipairs(jobs or {}) do
        records[index] = {
            status = word(job.status),
            target = pretty(job.target),
            count = tonumber(job.count) or 0,
            done = tonumber(job.completedOutput) or 0,
            turtles = tonumber(job.activeAssignments) or 0,
        }
    end
    return records
end

-- snapshot: Controller:snapshot(); extra: monitors, version, clock, budget.
function S.model(snapshot, _, extra)
    extra = extra or {}
    return {
        state = overall(snapshot),
        workers = workerRecords(snapshot.workers),
        jobs = jobRecords(snapshot.jobs),
        controllerId = snapshot.controllerId,
        network = snapshot.network,
        modems = snapshot.modems,
        monitors = extra.monitors or {},
        onlineWorkers = snapshot.onlineWorkers or 0,
        totalWorkers = snapshot.totalWorkers or 0,
        stats = snapshot.stats or {},
        gate = snapshot.orderGate or {},
        supplies = snapshot.supplies or 0,
        backlogBudget = extra.backlogBudget,
        lastStatus = snapshot.lastStatus,
        lastWarning = snapshot.lastWarning,
        lastError = snapshot.lastError,
        version = extra.version,
        updatedAt = extra.now,
        interval = extra.interval,
    }
end

-- Pages --------------------------------------------------------------------------

local function seg(text, fg) return Rows.segment(tostring(text), fg) end
local function fit(text, width, right) return Text.fit(tostring(text), width, right) end
local function wide(context) return context.rect.width >= 70 end
-- Column width as a share of the screen, so a wide monitor is used fully.
local function share(context, part, least, most)
    return math.max(least, math.min(most, math.floor(context.rect.width * part)))
end
local function color(t, w) return t[S.tone(w)] or t.text end
local function blank(L) L[#L + 1] = {segs = {}} end

local function gateLine(gate)
    if gate.holder then
        return ("PC%s ordering, %d waiting"):format(tostring(gate.holder), tonumber(gate.waiting) or 0)
    end
    return (tonumber(gate.waiting) or 0) > 0 and (tostring(gate.waiting) .. " waiting") or "free"
end

local function problems(L, m, t)
    if m.lastError then
        L[#L + 1] = Rows.status("Error", tostring(m.lastError), t.bad, t)
    elseif m.lastWarning then
        L[#L + 1] = Rows.status("Warning", tostring(m.lastWarning), t.warn, t)
    end
end

-- Workers: one row each; the bar shows the step of the recipe chain.
local function workersPage(m, context)
    local t, L = context.theme, {}
    problems(L, m, t)
    L[#L + 1] = Rows.status("Workers", ("%d of %d online"):format(m.onlineWorkers, m.totalWorkers),
        m.onlineWorkers < m.totalWorkers and t.warn or t.ok, t)
    L[#L + 1] = Rows.status("Requests", ("%s waiting, %s crafting"):format(tostring(m.stats.queued or 0),
        tostring(m.stats.assigned or 0)), t.info, t)
    L[#L + 1] = Rows.status("Warehouse", gateLine(m.gate), m.gate.holder and t.busy or t.ok, t)
    blank(L)
    L[#L + 1] = Rows.section("Workers", nil, t)
    if #m.workers == 0 then
        L[#L + 1] = {segs = {seg("No workers found yet; they find PC48 over rednet", t.muted)}}
        return L
    end
    local nameWidth = wide(context) and share(context, 0.3, 26, 44) or math.max(8, context.rect.width - 14 - CHIP - 1)
    local barWidth = share(context, 0.14, 8, 24)
    for _, w in ipairs(m.workers) do
        local c = color(t, w.phase)
        local name = w.target or ""
        if wide(context) and w.target and w.count then name = name .. " x" .. tostring(w.count) end
        local row = {seg(w.label .. " ", t.text), seg(fit("(" .. w.id .. ")", 13 - #w.label), t.muted),
            Rows.chip(w.phase, c, CHIP), seg(fit(name, nameWidth), t.text)}
        if wide(context) then
            if w.steps and w.steps > 0 then
                local lit, dim = Rows.bar(w.step or 0, w.steps, barWidth, c, t)
                row[#row + 1] = lit
                row[#row + 1] = dim
                row[#row + 1] = seg(fit(("step %d/%d"):format(w.step or 0, w.steps), 11, true) .. "  ", t.muted)
            elseif w.waiting then
                row[#row + 1] = seg(fit("", barWidth + 13), t.muted)
            end
            if w.waiting then row[#row + 1] = seg(w.waiting .. " on the way", t.info) end
        end
        L[#L + 1] = {segs = row}
    end
    return L
end

-- Queue: every open request with how much of it is done.
local function queuePage(m, context)
    local t, L = context.theme, {}
    local stats = m.stats
    L[#L + 1] = Rows.section("Requests", ("%s waiting, %s crafting, %s done"):format(tostring(stats.queued or 0),
        tostring(stats.assigned or 0), tostring(stats.done or 0)), t)
    if #m.jobs == 0 then
        L[#L + 1] = {segs = {seg("Nothing to craft. PC46 and PC66 send requests here.", t.muted)}}
        return L
    end
    local nameWidth = wide(context) and share(context, 0.35, 30, 48) or math.max(8, context.rect.width - 1 - 10 - 9 - 12)
    local barWidth = wide(context) and share(context, 0.2, 10, 30) or 10
    for _, job in ipairs(m.jobs) do
        local c = color(t, job.status)
        local lit, dim = Rows.bar(job.done, math.max(1, job.count), barWidth, c, t)
        local row = {seg(fit(job.target, nameWidth), t.text), lit, dim,
            seg(fit(("%d/%d"):format(job.done, job.count), 8, true) .. " ", t.muted), Rows.chip(job.status, c, CHIP)}
        if wide(context) and job.turtles > 0 then
            row[#row + 1] = seg(("%d turtle%s"):format(job.turtles, job.turtles == 1 and "" or "s"), t.muted)
        end
        L[#L + 1] = {segs = row}
    end
    return L
end

-- The warehouse order gate (one order at a time, paced by backlog) and the
-- supplies PC48 is making and sending (controller.supplier).
local function ordersPage(m, context)
    local t, gate, L = context.theme, m.gate, {}
    L[#L + 1] = Rows.section("Warehouse orders", "one order at a time", t)
    L[#L + 1] = Rows.status("Now", gateLine(gate), gate.holder and t.busy or t.ok, t)
    local budget, backlog = tonumber(m.backlogBudget), tonumber(gate.backlog) or 0
    if budget then
        local c = backlog >= budget and t.warn or t.ok
        local lit, dim = Rows.bar(backlog, budget, 12, c, t)
        L[#L + 1] = {segs = {seg(string.char(7) .. " ", c), seg(fit("Packages", 10), t.muted), lit, dim,
            seg(("  %s of %d queued"):format(tostring(backlog), budget), t.text)}}
    end
    L[#L + 1] = Rows.status("Granted", tostring(gate.grants or 0) .. " orders", t.info, t)
    L[#L + 1] = Rows.status("Expired", tostring(gate.expired or 0) .. " lost turns",
        (tonumber(gate.expired) or 0) > 0 and t.warn or t.ok, t)
    L[#L + 1] = Rows.status("Supplies", tostring(m.supplies) .. " open",
        m.supplies > 0 and t.busy or t.ok, t)
    return L
end

local function statusPage(m, context)
    local t, L = context.theme, {}
    local stats = m.stats
    L[#L + 1] = Rows.section(("Autocraft controller #%s"):format(tostring(m.controllerId or "?")), m.version, t)
    L[#L + 1] = Rows.status("State", m.state, color(t, m.state), t)
    L[#L + 1] = Rows.status("Network", m.network and ("modems " .. tostring(m.modems)) or "down", m.network and t.ok or t.bad, t)
    L[#L + 1] = Rows.status("Monitors", #m.monitors > 0 and table.concat(m.monitors, ", ") or "none",
        #m.monitors > 0 and t.ok or t.muted, t)
    L[#L + 1] = Rows.status("Workers", ("%d of %d online"):format(m.onlineWorkers, m.totalWorkers),
        m.onlineWorkers < m.totalWorkers and t.warn or t.ok, t)
    L[#L + 1] = Rows.status("Finished", ("%s done, %s errors"):format(tostring(stats.done or 0), tostring(stats.errors or 0)),
        (tonumber(stats.errors) or 0) > 0 and t.warn or t.ok, t)
    L[#L + 1] = Rows.status("Activity", tostring(m.lastStatus or "idle"), t.muted, t)
    L[#L + 1] = Rows.status("Warning", tostring(m.lastWarning or "none"), m.lastWarning and t.warn or t.ok, t)
    L[#L + 1] = Rows.status("Error", tostring(m.lastError or "none"), m.lastError and t.bad or t.ok, t)
    return L
end

function S.pages()
    return {
        {name = "Workers", page = workersPage},
        {name = "Queue", page = queuePage},
        {name = "Orders", page = ordersPage},
        {name = "Status", page = statusPage},
    }
end

-- Monitor IDs attached to the App (every screen but the terminal).
function S.monitors(app)
    local names = {}
    for id in pairs(app and app.screens or {}) do
        if id ~= "terminal" then names[#names + 1] = tostring(id) end
    end
    table.sort(names)
    return names
end

-- A touch or click is not keyboard focus: no focus line stays under what
-- was pressed (as on PC66 and the drone screens).
function S.unfocus(app, screenId)
    local screen = app.screens[screenId]
    local current = screen and screen.pages[screen.active]
    if current and current.focus and not current.focus.modalId then current.focus.focusedId = nil end
end

return S
