-- fc: flight controller for the master PC (startup.lua runs `fc run`).
-- While it runs, the server admin (aero_fc/tools/cmd.sh) can drive it by writing
-- one command per line to /fc_cmd (a service channel for tests; the owner
-- flies with the screens and the typewriter):
--   arm | disarm | rehold | abort | quit | nodes | land | hold [x z] | goto x y z [b/s]
--   home | home set [x y z [hdg]] | wp add|del|fly|home|list | speed <fwd b/s> [side]
--   route list|fly <name> [from]|stop
--   set <field> <v> | save | baseline | log on|off | link [clutch|gear on|off|auto]
-- Logging is off unless `log on` (testing): then events and a status line
-- (every 5 s, every second when armed) go to /fc.log. Always: the black box
-- keeps the last minutes in memory and writes them to /fc_incident.log only
-- when something goes wrong.
local program_dir = fs.getDir(shell.getRunningProgram())
local base = program_dir == "" and "" or ("/" .. program_dir)
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local C = require("fc.core.config")
local E = require("fc.engine")
-- The screens need the CC UI kit from the Tensa Aeronautics ROM; without it
-- the controller still flies (typewriter and the service channel), screenless.
local ui_ok, Sc = pcall(require, "fc.ui.screens")
local UI = ui_ok and require("ui") or nil
local SL = require("fc.ui.statusline")
local R = require("fc.hw.rlinks")
local BB = require("fc.core.blackbox")
local Rm = require("fc.cmd.remote")

local LOG_PATH = "/fc.log"
local CMD_PATH = "/fc_cmd"
local INCIDENT_PATH = "/fc_incident.log"
local LOG_LIMIT = 128 * 1024   -- the computer disk is 1 MB; two files of this size stay well below

-- Logging must never take the controller down ("Out of space" did once).
local function file_log(line)
    pcall(function()
        if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > LOG_LIMIT then
            if fs.exists(LOG_PATH .. ".1") then fs.delete(LOG_PATH .. ".1") end
            fs.move(LOG_PATH, LOG_PATH .. ".1")
        end
        local h = fs.open(LOG_PATH, "a")
        if h then
            h.writeLine(("%s %s"):format(os.date("%H:%M:%S"), line))
            h.close()
        end
    end)
end

-- Incidents append; past the limit the old ones go.
local function incident_write(lines)
    pcall(function()
        if fs.exists(INCIDENT_PATH) and fs.getSize(INCIDENT_PATH) > LOG_LIMIT / 2 then fs.delete(INCIDENT_PATH) end
        local h = fs.open(INCIDENT_PATH, "a")
        if h then
            for _, l in ipairs(lines) do h.writeLine(l) end
            h.close()
        end
    end)
end

local function setup()
    local cfg, cfg_err = C.load(E.CONFIG_PATH)
    if cfg_err then printError("config: " .. cfg_err) end
    if peripheral.getType(cfg.modem) ~= "modem" then
        -- another build: use any attached modem, a wireless one first (the nodes are wireless)
        local found
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                local ok, wireless = pcall(peripheral.call, name, "isWireless")
                if ok and wireless then found = name; break end
                found = found or name
            end
        end
        if not found then printError("no modem attached"); return nil end
        cfg.modem = found
    end
    -- everything said goes to the black box (240 lines: 4 min armed); to
    -- /fc.log only while logging is on
    local bb = BB.new(240, incident_write)
    local function record(line)
        BB.add(bb, os.date("%H:%M:%S") .. " " .. line, os.clock())
        if cfg.log then file_log(line) end
    end
    local ctx = E.new(cfg, cfg_err, {rednet = rednet, sublevel = _G.sublevel, parallel = parallel, clock = os.clock, log = record,
        incident = function(why) BB.trip(bb, os.date("%H:%M:%S") .. " " .. why, os.clock()) end})
    ctx.record = record
    return ctx
end

-- Loops ---------------------------------------------------------------------

-- Run one iteration of a loop body; an error is logged and the loop goes on.
local function guarded(ctx, name, fn)
    local ok, err = pcall(fn)
    if not ok then
        E.log(ctx, name .. " error: " .. tostring(err))
        sleep(1)
    end
end

local function control_loop(ctx)
    local period = 1 / ctx.cfg.loop_hz
    while ctx.running do
        local started = os.clock()
        guarded(ctx, "control_loop", function() E.cycle(ctx) end)
        local remaining = period - (os.clock() - started)
        sleep(remaining > 0 and remaining or 0)
    end
end

local function receive_loop(ctx)
    while ctx.running do
        local sender, msg = rednet.receive(ctx.link.protocol, 0.5)
        if sender then E.handle_message(ctx, sender, msg) end
    end
end

-- The owner's pocket computer (fc.remote): its polls and buttons, each answered with the status.
local function remote_loop(ctx)
    while ctx.running do
        local sender, msg = rednet.receive(Rm.PROTOCOL, 1)
        if sender then
            guarded(ctx, "remote_loop", function()
                local reply = Rm.handle(E, ctx, sender, msg)
                if reply then rednet.send(sender, reply, Rm.PROTOCOL) end
            end)
        end
    end
end

local function command_loop(ctx)
    while ctx.running do
        if fs.exists(CMD_PATH) then
            local h = fs.open(CMD_PATH, "r")
            local text = h and h.readAll() or ""
            if h then h.close() end
            fs.delete(CMD_PATH)
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local words = E.parse_command(line)
                if words then
                    E.log(ctx, "cmd: " .. table.concat(words, " "))
                    E.operator(ctx, words)
                end
            end
        end
        sleep(0.5)
    end
end

-- Manual flight: poll the linked typewriter (any one on the network).
local function input_loop(ctx)
    local tw, last_find = nil, -math.huge
    while ctx.running do
        guarded(ctx, "input_loop", function()
            local now = os.clock()
            if not tw and now - last_find >= 5 then
                tw = peripheral.find("linked_typewriter")
                last_find = now
                if tw then
                    ctx.typewriter_name = peripheral.getName(tw)
                    E.log(ctx, "typewriter attached: " .. tostring(ctx.typewriter_name))
                end
            end
            local codes = {}
            if tw then
                local ok, res = pcall(tw.getPressedKeyCodes)
                if ok and type(res) == "table" then codes = res else tw = nil; ctx.typewriter_name = nil; E.log(ctx, "typewriter lost") end
            end
            -- the key bridge: the typewriter is one source, the glasses another (fc.remote)
            E.key_source(ctx, "typewriter", codes)
            E.manual(ctx, E.held_keys(ctx))
        end)
        sleep(0.1)
    end
end

-- Ground sensors pointing down (height above the ground), read ten times a
-- second (the getters return cached values and cost nothing):
--   optical_sensor (Create Simulated): range follows E.ground_range, the full
--     ground_range near the ground, 1 block high in the air (set only when it
--     changes: each call waits for a tick);
--   distance_detector (Advanced Peripherals, up to 64 blocks): set up once
--     (blocks only, its whole range, measuring by itself), -1 = no hit. It
--     casts from where the block really is, so on a Sable ship it may see
--     only the ship's plot (nothing, or the ship itself): its readings are
--     only logged until cfg.ground_detectors is set (after a check that they
--     follow the height), then they count like an optical sensor's.
local function ground_loop(ctx)
    local sensors, detectors, last_find, range = {}, {}, -math.huge, nil
    local function set_range(want)
        for _, s in ipairs(sensors) do pcall(s.setRange, want) end
        range = want
        E.set_node_ground_range(ctx, want)   -- the nodes' sensors follow with the next set
    end
    local function set_up(d)
        pcall(d.setDetectionMode, "block")
        pcall(d.setMaxRange, 64)
        pcall(d.setShowLaser, false)
        pcall(d.setCalculatePeriodically, true)
    end
    while ctx.running do
        guarded(ctx, "ground_loop", function()
            local now = os.clock()
            if now - last_find >= 10 then
                last_find = now
                local found = {peripheral.find("optical_sensor")}
                local dfound = {peripheral.find("distance_detector")}
                if #found ~= #sensors or #dfound ~= #detectors then
                    sensors, detectors = found, dfound
                    set_range(E.ground_range(ctx))
                    for _, d in ipairs(detectors) do set_up(d) end
                    local names = {}
                    for _, s in ipairs(sensors) do
                        local ok, r = pcall(s.getRange)
                        names[#names + 1] = peripheral.getName(s) .. (ok and (" range " .. tostring(r)) or "")
                    end
                    for _, d in ipairs(detectors) do
                        local ok, r = pcall(d.getMaxRange)
                        names[#names + 1] = peripheral.getName(d) .. (ok and (" range " .. tostring(r)) or "")
                    end
                    E.log(ctx, #names > 0 and ("ground sensors: " .. table.concat(names, ", ")) or "no ground sensor (optical_sensor, distance_detector)")
                end
            end
            local want = E.ground_range(ctx)
            if want ~= range then
                set_range(want)
                if #sensors > 0 then E.log(ctx, want > 1 and ("ground sensors on (range %d)"):format(want) or "ground sensors off (high in the air)") end
            end
            local dists = {}
            if range and range > 1 then
                for _, s in ipairs(sensors) do
                    local okh, hit = pcall(s.hasHit)
                    if okh and hit then
                        local okd, d = pcall(s.getDistance)
                        if okd and type(d) == "number" then dists[#dists + 1] = {name = peripheral.getName(s), d = d} end
                    end
                end
            end
            local seen = {}
            for _, det in ipairs(detectors) do
                local okd, d = pcall(det.getDistance)
                seen[#seen + 1] = okd and type(d) == "number" and ("%.1f"):format(d) or "?"
                if ctx.cfg.ground_detectors and okd and type(d) == "number" and d >= 0 then dists[#dists + 1] = {name = peripheral.getName(det), d = d} end
            end
            local sig = table.concat(seen, " ")
            if #seen > 0 and sig ~= (ctx.det_sig or "") and now - (ctx.det_logged or -math.huge) >= 5 then
                ctx.det_sig, ctx.det_logged = sig, now
                E.log(ctx, ("distance detectors: %s (-1 = nothing; %s)"):format(sig, ctx.cfg.ground_detectors and "used" or "logged only"))
            end
            -- and the nodes' sensors (the rear pair on PC 133)
            local nhits, nn = E.node_ground(ctx)
            for _, h in ipairs(nhits) do dists[#dists + 1] = h end
            E.ground_reading(ctx, dists, now, #sensors + (ctx.cfg.ground_detectors and #detectors or 0) + nn)
        end)
        sleep(0.1)
    end
end

-- The ship's mass (Sable) every 2 s: the braking plan follows it.
local function mass_loop(ctx)
    while ctx.running do
        if _G.sublevel and _G.sublevel.getMass then
            local ok, m = pcall(_G.sublevel.getMass)
            if ok then E.mass_reading(ctx, m) end
        end
        sleep(2)
    end
end

-- Redstone links through a CC Redstone Link Bridge (re-detected every 5 s):
-- sends what fc.rlinks decided; peripheral calls wait for a server tick, so
-- they live here and not in the control loop.
local function links_loop(ctx)
    local bridge, last_find = nil, -math.huge
    while ctx.running do
        guarded(ctx, "links_loop", function()
            local now = os.clock()
            if not bridge and now - last_find >= 5 then
                last_find = now
                bridge = peripheral.find("redstone_link_bridge")
                ctx.link_bridge = bridge and peripheral.getName(bridge) or nil
                if bridge then
                    E.log(ctx, "link bridge attached: " .. ctx.link_bridge)
                    local line = R.sync(ctx.rlinks, bridge, ctx.cfg.links)
                    if line then E.log(ctx, line) end
                end
            end
            if bridge then
                for _, line in ipairs(R.apply(ctx.rlinks, bridge, ctx.cfg.links, now)) do E.log(ctx, line) end
                if not peripheral.isPresent(ctx.link_bridge) then
                    E.log(ctx, "link bridge lost"); bridge = nil; ctx.link_bridge = nil
                end
            end
        end)
        sleep(0.25)
    end
end

-- Screens: the UI kit's App on the terminal and every monitor (a monitor
-- follows the terminal's tab); it owns their keys, clicks and touches. The
-- monitors are attached here (the kit's own discovery would set them to
-- text scale 0.5): scale 1, or 0.5 when that leaves fewer than 26 columns.
local function add_monitor(ctx, app, name)
    if not ctx.cfg.monitor_enabled or peripheral.getType(name) ~= "monitor" then return end
    local mon = peripheral.wrap(name)
    pcall(mon.setTextScale, 1)
    local scale = mon.getSize() < 26 and 0.5 or 1
    if app:addScreen(name, Sc.tall(mon), {textScale = scale}) then
        E.log(ctx, ("monitor attached: %s (%dx%d)"):format(name, mon.getSize()))
    end
end

local function new_app(ctx)
    if not (UI and UI.App) then return nil end
    local app, err = UI.App.new{pages = Sc.pages(E), state = ctx, onAction = Sc.on_action(E), interval = 0.25,
        adapters = {getNames = function() return {} end, current = function() return Sc.tall(term.current()) end}}
    if not app then E.log(ctx, "screens failed: " .. tostring(err)); return nil end
    for _, name in ipairs(peripheral.getNames()) do add_monitor(ctx, app, name) end
    Sc.apply_style(app, ctx.cfg.ui and ctx.cfg.ui.buttons)
    app:render()
    return app
end

local function screen_loop(ctx)
    if not (UI and UI.App) then
        E.log(ctx, "no screens: the CC UI kit is missing (" .. tostring(not ui_ok and Sc or "ui.App") .. ")")
        while ctx.running do sleep(60) end
        return
    end
    ctx.app = new_app(ctx)
    while ctx.running do
        local ev = table.pack(os.pullEvent())
        local app = ctx.app
        if not app then
            sleep(5); ctx.app = new_app(ctx)
        elseif ev[1] == "peripheral" then
            add_monitor(ctx, app, ev[2]); app:render()
        else
            Sc.handle(app, table.unpack(ev, 1, ev.n))
            Sc.apply_style(app, ctx.cfg.ui and ctx.cfg.ui.buttons)   -- SETTINGS "Buttons" changed it
            if app.closed then   -- the kit closes itself after an error: start it again
                E.log(ctx, "screens restarted: " .. tostring(app.error))
                ctx.app = new_app(ctx)
            end
        end
    end
end

-- Power watch and the status line (black box, /fc.log while logging is on).
local function status_loop(ctx)
    local last_log = -math.huge
    while ctx.running do
        guarded(ctx, "status_loop", function()
            E.watch_power(ctx)
            local now = E.now(ctx)
            if now - last_log >= (ctx.k.mode == "STANDBY" and 5 or 1) then
                ctx.record(SL.line(E.view(ctx)))
                last_log = now
            end
        end)
        sleep(0.25)
    end
end

local function run(ctx)
    E.log(ctx, ("fc %s run started (passive STANDBY)"):format(E.VERSION))
    term.clear()
    local ok, err = pcall(parallel.waitForAny,
        function() control_loop(ctx) end,
        function() receive_loop(ctx) end,
        function() remote_loop(ctx) end,
        function() command_loop(ctx) end,
        function() input_loop(ctx) end,
        function() ground_loop(ctx) end,
        function() mass_loop(ctx) end,
        function() links_loop(ctx) end,
        function() screen_loop(ctx) end,
        function() status_loop(ctx) end)
    if ctx.app then ctx.app:close() end   -- the kit puts every palette back
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    term.clear(); term.setCursorPos(1, 1)
    if not ok then
        E.log(ctx, "CRASH: " .. tostring(err))
        E.incident(ctx, "crash")
        printError(tostring(err))
        -- keep the nodes on their fallback (no idle burst) and come back up
        sleep(2)
        os.reboot()
    end
    print("fc: stopped")
end

local args = {...}
if (args[1] or "run") ~= "run" then
    printError("usage: fc [run]  (commands go to /fc_cmd while it runs)")
    return
end
local ctx = setup()
if ctx then run(ctx) end
