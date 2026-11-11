-- PC124: the TUF farm. Every second (and at once after a touch) it counts
-- its vault and PC11's report, decides which lines run (tuf.plan),
-- drives the Redstone Link bridge (tuf.links), sends items over their limit
-- to the warehouse (tuf.requester) and draws the pages on the monitor and
-- the terminal (tuf.ui). A touch on the monitor becomes a
-- settings command (tuf.settings), saved in /tuf/state.txt.
--
-- Three coroutines: work (peripheral calls, one tick each), receive
-- (PC11's reports) and screen (touches, keys, App timer). A main-thread
-- peripheral call drops other events of the coroutine that waits for it,
-- so messages and touches are received apart from the work.
local Lib = require("ui")
local config = require("tuf.config")
local P = require("tuf.plan")
local S = require("tuf.settings")
local L = require("tuf.links")
local R = require("tuf.requester")
local St = require("tuf.storage")
local V = require("tuf.view")
local Log = require("tuf.log")
local UI = require("tuf.ui")
local N = require("tuf.net")

local Farm = {}

Farm.STATE_FILE = "/tuf/state.txt"
Farm.LOG_FILE = "/tuf/log.txt"
Farm.TICK = 1

local clock = N.clock

-- ------------------------------------------------------------ commands

-- The command for a touched edit button, from the current view.
-- -> cmd or nil
function Farm.editCommand(view, e, button)
    local x, f = UI.target(view, e)
    if not x then return nil end
    if e.kind == "rule" then
        if button == "edit:rule:toggle" then
            return {op = "rule", id = x.id, enabled = not x.enabled, percent = x.percent}
        end
        local d = tonumber(button:match("^edit:pct:(%-?%d+)$"))
        if d then return {op = "rule", id = x.id, enabled = x.enabled, percent = math.max(1, math.min(100, x.percent + d))} end
        return nil
    end
    local function limit(value)
        value = math.max(0, value)
        if e.kind == "stage" then return {op = "limit", target = "stage", name = x.name, value = value} end
        if e.kind == "base" then return {op = "limit", target = "base", factory = f.name, value = value} end
        return {op = "limit", target = "res", factory = f.name, key = x.key, value = value}
    end
    local d = tonumber(button:match("^edit:delta:(%-?%d+)$"))
    if d then return limit((x.limit or 0) + d) end
    if button == "edit:nolimit" then return limit(0) end
    if e.kind ~= "stage" then return nil end
    if button == "edit:up" or button == "edit:down" then
        local names, at = {}, nil
        for i, s in ipairs(f.stages) do
            names[i] = s.name
            if s.name == x.name then at = i end
        end
        local other = at + (button == "edit:up" and -1 or 1)
        if other < 1 or other > #names then return nil end
        names[at], names[other] = names[other], names[at]
        return {op = "order", factory = f.name, names = names}
    end
    local m = button:match("^edit:manual:(.+)$")
    if m then return {op = "manual", name = x.name, signal = tonumber(m)} end
    return nil
end

-- A failed screen is logged once per new error.
local function screenErrors(app, log, seen)
    local errors = app.screenErrors and app:screenErrors() or {}
    for id, message in pairs(errors) do
        if seen[id] ~= message then
            seen[id] = message
            log:warn("screen " .. id .. ": " .. tostring(message))
        end
    end
    for id in pairs(seen) do
        if errors[id] == nil then seen[id] = nil end
    end
end

-- ------------------------------------------------------------ program

function Farm.run()
    local net = config.network
    local log = Log.new(Farm.LOG_FILE, 32000)
    local state = S.load(Farm.STATE_FILE)
    local links = L.new(config)
    local requester = R.new(config)
    local reports = {}
    local modems = N.open()
    local bridge = links:find()
    log:info(("start  bridge %s  others %d  modems %s  requester %s"):format(bridge or "NONE", #links.extras,
        #modems > 0 and table.concat(modems, ",") or "NONE", requester:find() or "NONE"))

    local st = {interval = Farm.TICK, log = log.lines, toasts = {}, edit = {}}
    local editSeq = 0
    local app

    local function toast(text, status)
        st.toasts = Lib.Feedback.Toasts.push(st.toasts, {text = text, status = status}, clock(), 4, 2)
    end

    local function command(cmd)
        if not cmd then return end
        local ok, err, value = S.apply(config, state, cmd)
        if not ok then
            log:warn("change refused: " .. tostring(err))
            toast("Not saved: " .. tostring(err), "bad")
        else
            S.save(Farm.STATE_FILE, state)
            log:info("change " .. textutils.serialize(cmd, {compact = true}))
            if cmd.op == "limit" and value and value < S.stackLimit(config, cmd.value) then
                toast("Cut to " .. UI.num(value) .. ": the vault would be full", "warn")
            end
        end
        os.queueEvent("tuf_wake")
    end

    local function editFor(key, page)
        local kind, a, b = key:match("^(%a+):([^:]+):?(.*)$")
        editSeq = editSeq + 1
        if kind == "stage" then return {kind = "stage", name = a, page = page, seq = editSeq} end
        if kind == "base" then return {kind = "base", factory = a, page = page, seq = editSeq} end
        if kind == "res" then return {kind = "res", factory = a, key = b, page = page, seq = editSeq} end
        if kind == "rule" then return {kind = "rule", id = key:sub(6), page = page, seq = editSeq} end
        return nil
    end

    local function onAction(action, _, info)
        local id, screen = tostring(action.id), info.screenId
        if not st.view or not st.view.factories then return end
        if action.type == "change" and (id == "stage" or id == "stock" or id == "rule") then
            st.edit[screen] = editFor(tostring(action.value), info.page)
        elseif id:match("^edit%d+$") then
            st.edit[screen] = nil
        elseif id:match("^edit:") and action.type == "activate" then
            local e = st.edit[screen]
            if e then command(Farm.editCommand(st.view, e, id)) end
        elseif id == "power" and action.type == "activate" then
            command({op = "power", mode = st.view.power.mode == "off" and "on" or "off"})
        elseif id:match("^mode:") and action.type == "activate" then
            local name = id:sub(6)
            for _, f in ipairs(st.view.factories) do
                if f.name == name then command({op = "mode", factory = name, mode = f.mode == "off" and "auto" or "off"}) end
            end
        end
    end

    local appError
    app, appError = Lib.App.new({pages = UI.pages(config), state = st, interval = 1,
        onAction = onAction, pointerFocus = false, adapters = {clock = clock}})
    if not app then
        log:error("screen: " .. tostring(appError))
        app = {render = function() return true end, handle = function() return false end}
    end
    local screenSeen = {}

    -- Each state is logged once when it changes: problems as WARN, the
    -- return to normal as INFO.
    local function note(key, problem, bad, good)
        log:once(key, problem and "WARN" or "INFO", problem and bad or good)
    end
    local startedAt = clock()
    local function notes(decision, storage, channels)
        log:once("power", "INFO", ({on = "power on", off = "power off (turned off here)",
            storage = "power stopped: storage full"})[decision.power.reason])
        note("held", channels[1].held, "power held at stop by another transmitter", "power channel free")
        note("bridge", not links.name, "NO BRIDGE: lines cannot be switched", "bridge " .. tostring(links.name))
        if clock() - startedAt > net.storageStale then
            note("remote", storage.remote == false, "PC11 storage report missing", "PC11 storage report ok")
        end
        local bad = {}
        for _, ch in ipairs(channels) do
            if not ch.ok and not ch.held then bad[#bad + 1] = ch.name end
        end
        note("links", #bad > 0, "channels not set: " .. table.concat(bad, " "), "all channels set")
        if requester.enabled then
            note("requester", not requester.name, "surplus: no redstone requester found",
                "surplus to " .. requester.address .. " by " .. tostring(requester.name))
            log:once("requesterError", "WARN", requester.err and ("surplus order failed: " .. requester.err) or nil)
        end
    end

    local function short(item) return (tostring(item):gsub("^[%w_]+:", ""):gsub("_", " ")) end
    local function sendSurplus(storage, now)
        requester:find()
        local list = P.surplus(config, state, storage.counts, requester.min)
        local lines = requester:step(list, now)
        if lines then
            local parts, at = {}, {}
            for _, l in ipairs(lines) do
                if at[l.name] then
                    parts[at[l.name]].count = parts[at[l.name]].count + l.count
                else
                    parts[#parts + 1] = {count = l.count, name = l.name}
                    at[l.name] = #parts
                end
            end
            for i, x in ipairs(parts) do parts[i] = x.count .. " " .. short(x.name) end
            log:info("sent to " .. requester.address .. ": " .. table.concat(parts, ", "))
        end
        return requester:view(list)
    end

    -- After a start the farm waits for every agent's first report (at most
    -- storageStale seconds) before it switches anything: until then the
    -- ingots in PC11's store would count as missing.
    local function agentsHeard(now)
        if now - startedAt > net.storageStale then return true end
        for _, id in ipairs(net.agents or {}) do
            if not reports[id] then return false end
        end
        return true
    end

    local cache = {}
    local function cycle()
        local now = clock()
        local before = links.name
        links:find()
        if links.name ~= before then log:info("bridge now " .. tostring(links.name)) end
        local storage = St.total(config, St.scan(config, nil, cache), reports, now)
        local decision = P.decide(config, state, storage)
        local channels = P.channels(config, decision)
        local hold = not agentsHeard(now)
        local surplus
        if not hold then
            links:clearExtras(channels)
            links:apply(channels, now)
            surplus = sendSurplus(storage, now)
        end
        st.view = V.build(config, decision, storage, channels, links.name, state)
        st.view.hold = hold or nil
        st.view.surplus = surplus
        st.updatedAt = now
        if not hold then notes(decision, storage, channels) end
        app:render(st)
        screenErrors(app, log, screenSeen)
    end

    local function work()
        while true do
            local ok, err = pcall(cycle)
            log:once("cycle", "ERROR", not ok and ("cycle failed: " .. tostring(err)) or nil)
            local timer = os.startTimer(Farm.TICK)
            while true do
                local event, id = os.pullEvent()
                if (event == "timer" and id == timer) or event == "tuf_wake" then break end
            end
        end
    end

    local function receive()
        while true do
            local _, sender, message, protocol = os.pullEvent("rednet_message")
            if protocol == net.storageProtocol then St.acceptPush(config, reports, sender, message, clock()) end
        end
    end

    local function screen()
        while true do
            app:handle(os.pullEvent())
            screenErrors(app, log, screenSeen)
        end
    end

    parallel.waitForAny(work, receive, screen)
end

return Farm
