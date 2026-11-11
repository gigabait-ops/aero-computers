-- The flight computer: its context (`ctx`) and the control cycle, plus the
-- one table (`E`) through which everything outside flies the ship: fc.lua's
-- loops, the screens, the glasses' remote and the host tests. Independent
-- of CC event loops so it can be host-tested.
--
-- The work is done by the modules under fc/ (see aero_fc/docs/architecture.md);
-- this file only wires one cycle together and publishes their functions
-- under the names the callers use (the API list at the bottom).
local Sn = require("fc.hw.sensors")
local L = require("fc.hw.link")
local Nd = require("fc.hw.nodes")
local G = require("fc.hw.ground")
local R = require("fc.hw.rlinks")
local I = require("fc.hw.input")
local K = require("fc.flight.controller")
local M = require("fc.flight.mixer")
local Nv = require("fc.flight.nav")
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local B = require("fc.flight.booster")
local Tr = require("fc.flight.trim")
local Sf = require("fc.flight.safety")
local Rc = require("fc.flight.recovery")
local Ro = require("fc.flight.route")
local Cx = require("fc.core.ctx")
local W = require("fc.data.waypoints")
local St = require("fc.data.settings")
local Rt = require("fc.data.routes")
local Op = require("fc.cmd.operator")
local V = require("fc.ui.view")
local Ky = require("fc.ui.keys")
local Ac = require("fc.ui.actions")

local E = {}

-- The package's version: major for a change the config or the nodes must
-- follow, minor for new behaviour, patch for fixes. Logged at every start.
E.VERSION = "3.12.2"

-- deps = {rednet, sublevel, parallel (CC API, optional), clock = function() -> seconds,
--         log = function(line)|nil, incident = function(why)|nil}
function E.new(cfg, cfg_err, deps)
    local ctx = {
        cfg = cfg,
        cfg_err = cfg_err,
        deps = deps,
        clock = deps.clock or os.clock,
        sensors = Sn.new(cfg, {sublevel = deps.sublevel, parallel = deps.parallel}),
        link = L.new(cfg, deps.rednet),
        k = K.new(cfg),
        running = true,
        report = {},
        task = nil,
        last_dt = 0,
        input = I.new(cfg),
        man = {v_f = 0, v_r = 0, ctl = Nv.speed_new(), hold = nil},   -- manual speed control
        prev_mode = "STANDBY",   -- controller mode after the last cycle (trim is saved on ARMED -> STANDBY)
        rlinks = R.new(),        -- redstone links (clutch, legs); sent by the link loop
        gsens = nil,             -- optical sensors: {dist, t, n}
        wp_sel = 1, set_sel = 1,
        edit = nil,              -- line being typed {kind, index, buffer, prompt, skip}
    }
    cfg.lateral = M.has_lateral(cfg.motors)
    if cfg_err then Cx.log(ctx, "config: " .. cfg_err .. " (using defaults)") end
    return ctx
end

-- Sensors and what the nodes reported, as one state for this cycle.
function E.read(ctx)
    local t = Cx.now(ctx)
    local dt = t - (ctx.last_t or t)
    ctx.last_t = t
    ctx.state, ctx.err = Sn.read(ctx.sensors, t)
    Nd.vector_counts(ctx)
    if ctx.state then
        ctx.state.mass, ctx.state.v_lift_max = ctx.mass, ctx.v_lift_max
        ctx.state.counts, ctx.state.vn = ctx.vcounts, ctx.vn
    end
    return ctx.state, t, dt
end

-- The ship's mass from Sable (fc.lua reads it every few seconds: the call
-- waits for a server tick); logged when it first comes and when it changes
-- by more than 2 % (cargo, fuel).
function E.mass_reading(ctx, m)
    if type(m) ~= "number" or m ~= m or m <= 0 then return end
    local was = ctx.mass_logged
    if not was or math.abs(m - was) > 0.02 * was then
        Cx.log(ctx, was and ("mass %.0f (was %.0f)"):format(m, was) or ("mass %.0f"):format(m))
        ctx.mass_logged = m
    end
    ctx.mass = m
end

-- The controller's own events (props stalled, ceiling, lift back) go to the
-- log; some are incidents for the black box.
local function controller_events(ctx)
    local k = ctx.k
    if k.event then
        Cx.log(ctx, k.event)
        if k.event:find("^props stalled") then Cx.incident(ctx, "props stalled") end
        k.event = nil
    end
    if k.mode == "DEGRADED" and ctx.prev_mode ~= "DEGRADED" then Cx.incident(ctx, "sensor lost") end
end

-- One control cycle: read, check safety, fly (a righting flip, the task or
-- the plain controller), send the targets, then the bookkeeping that
-- follows from what happened.
function E.cycle(ctx)
    Cx.fade_notice(ctx)
    local state, t, dt = E.read(ctx)
    local above = G.above(ctx)
    K.set_on_ground(ctx.k, state ~= nil and G.on_ground(ctx) or false, state ~= nil and G.on_ground(ctx, Tr.LOW) or false)
    Tr.learning(ctx, state, above)
    Sf.attitude(ctx, state)
    Mn.step(ctx, state, dt)
    B.limit(ctx, dt)
    Ro.step(ctx)
    K.set_vertical(ctx.k, T.vertical(ctx), state and state.pos and state.pos.y)
    local action = Rc.flip_step(ctx, state, t)
    if not action then
        if ctx.task then action = T.step(ctx, state, t, dt) else action = K.step(ctx.k, state, t, dt) end
    end
    Nd.send(ctx, action)
    Sf.lift_limit(ctx, state, t, action)
    ctx.last_dt = dt
    controller_events(ctx)
    Rc.auto_resume(ctx, state, t)
    Sf.resting(ctx, dt)
    local kk, st = ctx.k, ctx.state
    if ctx.prev_mode ~= "STANDBY" and kk.mode == "STANDBY" then Tr.keep(ctx); Tr.keep_hover(ctx) end
    if ctx.prev_mode ~= kk.mode then R.mode_changed(ctx, kk.mode) end
    R.decide(ctx.rlinks, ctx.cfg, {
        mode = kk.mode, task_kind = ctx.task and ctx.task.kind, vy = st and st.vel and st.vel.y,
        on_ground = st ~= nil and G.on_ground(ctx), now = t, above = above,
    })
    G.learn_zero(ctx, t)
    ctx.prev_mode = kk.mode
    return action
end

-- The API -------------------------------------------------------------------------
-- What fc.lua, the screens (fc.ui.screens), the glasses (fc.cmd.remote) and
-- the tests call. New callers use these names; inside fc/ the modules call
-- each other directly.

-- context, log, nodes
E.CONFIG_PATH, E.NOTICE_FOR = Cx.CONFIG_PATH, Cx.NOTICE_FOR
E.now, E.log, E.incident = Cx.now, Cx.log, Cx.incident
E.send, E.handle_message, E.status = Nd.send, Nd.handle_message, Nd.status
E.power_status, E.nodes_lines, E.watch_power, E.vector_counts = Nd.power_status, Nd.lines, Nd.watch_power, Nd.vector_counts
-- ground and links
E.ground_reading, E.above, E.ground_range, E.learn_ground_zero = G.reading, G.above, G.range, G.learn_zero
E.on_ground, E.resting, E.GROUND_FRESH = G.on_ground, G.resting, G.FRESH
-- the nodes' optical sensors (fw 1.8.0): fresh hits and how many there are; the range every set carries
function E.node_ground(ctx) return L.ground(ctx.link, Cx.now(ctx), G.FRESH * 0.6) end
function E.set_node_ground_range(ctx, range) ctx.link.ground_range = range end
E.link_set, E.engine_off, E.ENGINE_OFF = R.set_by_hand, R.engine_off, R.ENGINE_OFF
-- flight
E.abort_task, E.start_land, E.start_hold = T.abort_task, T.start_land, T.start_hold
E.start_goto, E.start_takeoff, E.start_dock = T.start_goto, T.start_takeoff, T.start_dock
E.manual_reset, E.fly_to, E.goto_coords, E.REVERSE_MAX = Mn.reset, Mn.fly_to, Mn.goto_coords, Mn.REVERSE_MAX
E.booster_limit = B.limit
E.keep_trim, E.TRIM_LOW, E.TRIM_LEARN, E.TRIM_NEAR = Tr.keep, Tr.LOW, Tr.LEARN, Tr.NEAR
E.auto_resume, E.flip_step = Rc.auto_resume, Rc.flip_step
E.RESUME_FALL, E.RESUME_SETTLE, E.RESUME_TRIM = Rc.RESUME_FALL, Rc.RESUME_SETTLE, Rc.RESUME_TRIM
E.FLIP_MIN, E.FLIP_TOTAL, E.FLIP_DONE, E.FLIP_KEYS = Rc.FLIP_MIN, Rc.FLIP_TOTAL, Rc.FLIP_DONE, Rc.FLIP_KEYS
-- routes
E.route_start, E.route_stop, E.route_describe = Ro.start, Ro.stop, Ro.describe
E.routes, E.route_get, E.route_add, E.route_delete = Rt.list, Rt.get, Rt.add, Rt.delete
E.route_laps, E.route_finish, E.route_tail = Rt.adjust_laps, Rt.cycle_finish, Rt.tail
E.point_add, E.point_edit, E.point_delete, E.point_move = Rt.point_add, Rt.point_edit, Rt.point_delete, Rt.point_move
E.point_adjust, E.point_act, E.point_text, E.point_summary = Rt.point_adjust, Rt.point_cycle_act, Rt.point_text, Rt.point_summary
-- waypoints and settings
E.waypoints, E.waypoint_rows, E.waypoint_index, E.capital = W.list, W.rows, W.index, W.capital
E.waypoint_add, E.waypoint_text, E.waypoint_update, E.waypoint_edit_text = W.add, W.text, W.update, W.edit_text
E.waypoint_delete, E.waypoint_set_home, E.DELETE_HOLD = W.delete, W.set_home, W.DELETE_HOLD
E.SETTINGS, E.setting_set, E.setting_adjust, E.setting_rows, E.reset = St.SETTINGS, St.set, St.adjust, St.rows, St.reset
-- commands, keys, buttons, the view
E.parse_command, E.operator, E.quit = Op.parse, Op.run, Op.quit
E.manual, E.manual_turn, E.manual_strafe, E.power = Ky.handle, Ky.turn, Ky.strafe, Ky.power
-- the key bridge (fc.hw.input): a source says what it holds; the flight reads them all
function E.key_source(ctx, source, keys) return I.feed(ctx.input, source, keys, Cx.now(ctx)) end
function E.held_keys(ctx) return I.held_codes(ctx.input, Cx.now(ctx)) end
E.ACTIONS, E.action, E.REPEAT_GUARD = Ac.ACTIONS, Ac.run, Ac.REPEAT_GUARD
E.edit_begin, E.edit_commit, E.edit_submit, E.parse_coords = Ac.edit_begin, Ac.edit_commit, Ac.edit_submit, Ac.parse_coords
E.ACT_COLOR, E.activity, E.power_label, E.recent, E.view = V.ACT_COLOR, V.activity, V.power_label, V.recent, V.view

return E
