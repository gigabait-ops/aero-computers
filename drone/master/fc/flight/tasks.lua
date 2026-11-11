-- Flight tasks: takeoff, goto, station keeping, landing and docking. Each
-- control cycle the engine runs the task (T.step) instead of the plain
-- controller; a task ends itself (arrived, landed, docked) or is aborted.
local K = require("fc.flight.controller")
local Nv = require("fc.flight.nav")
local A = require("fc.core.attitude")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")
local R = require("fc.hw.rlinks")

local T = {}

-- Landing descent rates (blocks/s) by height above the remembered ground.
-- Props lose thrust when they sink fast into their own air (the ship rocked
-- +-10 deg descending at 6 b/s, 2026-10-15), so nothing descends faster than 2.
T.LAND_RATES = {{above = 30, rate = 2}, {above = 6, rate = 1.5}, {above = -math.huge, rate = 0.5}}
-- A landing's height target stays within LAND_LEAD s of the descent (plus a
-- block) below the hull: run 32 blocks ahead, it was under the ground when
-- the curve asked to slow down and the ship touched down at 8 b/s (2026-10-23).
T.LAND_LEAD = 1.5

local FLIGHT = {["goto"] = true, hold = true, land = true, takeoff = true, dock = true}

function T.end_task(ctx, line)
    local task = ctx.task
    ctx.task = nil
    Cx.log(ctx, line)
    if FLIGHT[task.kind] then K.set_pilot(ctx.k, {forward = 0, climb = 0, turn = 0, side = 0}) end
    if task.restore == "ARMED" and ctx.k.mode ~= "STANDBY" then
        K.rehold(ctx.k, ctx.state)
    else
        K.disarm(ctx.k)
    end
end

function T.abort_task(ctx, why)
    if ctx.task then T.end_task(ctx, ctx.task.kind .. " aborted: " .. tostring(why)) end
end

local function sensor_ok(state, need_heading)
    return state and state.pos and (not need_heading or state.heading)
end

-- Controlled descent holding the position; motors off at touchdown
-- (opts.keep_armed: they keep running, the ship rests on the ground armed).
function T.start_land(ctx, rate, opts)
    if ctx.task and ctx.task.kind ~= "hold" and ctx.task.kind ~= "goto" and ctx.task.kind ~= "dock" then
        return false, "task already running: " .. ctx.task.kind
    end
    if ctx.k.mode ~= "ARMED" then return false, "land needs ARMED" end
    if not sensor_ok(ctx.state) then return false, "land needs the sublevel position" end
    local hold_target = (ctx.task and ctx.task.target) or {x = ctx.state.pos.x, z = ctx.state.pos.z}
    local p = ctx.state.pos
    if (hold_target.x - p.x) ^ 2 + (hold_target.z - p.z) ^ 2 > 15 * 15 then hold_target = {x = p.x, z = p.z} end   -- far from the leg's point: land here
    local name = ctx.task and ctx.task.name
    ctx.task = nil
    -- restore = ARMED: an aborted landing keeps flying; only a touchdown disarms.
    ctx.task = {kind = "land", rate = tonumber(rate) and math.abs(tonumber(rate)) or nil, started = Cx.now(ctx), still = 0, descended = 0,
        start_y = ctx.state.pos.y, restore = "ARMED", target = {x = hold_target.x, z = hold_target.z}, name = name,
        keep_armed = opts and opts.keep_armed or nil}
    Cx.log(ctx, ("land start: holding (%.0f, %.0f)%s"):format(hold_target.x, hold_target.z,
        ctx.ground_y and (", ground %.1f"):format(ctx.ground_y) or ", ground unknown"))
    return true
end

-- Hover at a world point (2-D station keeping) until another command.
function T.start_hold(ctx, x, z)
    if ctx.k.mode ~= "ARMED" then return false, "hold needs ARMED" end
    if not sensor_ok(ctx.state, true) then return false, "hold needs position and heading" end
    if ctx.task and ctx.task.kind ~= "hold" and ctx.task.kind ~= "goto" and ctx.task.kind ~= "dock" then return false, "task already running: " .. ctx.task.kind end
    x, z = tonumber(x), tonumber(z)
    if (x == nil) ~= (z == nil) then return false, "usage: hold [x z]" end
    local target = {x = x or ctx.state.pos.x, z = z or ctx.state.pos.z}
    ctx.task = {kind = "hold", target = target, restore = "ARMED"}
    K.set_pilot(ctx.k, {forward = 0, side = 0, climb = 0, turn = 0})
    Cx.log(ctx, ("hold at (%.0f, %.0f)"):format(target.x, target.z))
    return true
end

-- Fly to a world point; speed in blocks/s (nil: the SETTINGS speed, live).
-- opts: the leg options of Nv.new (a route's legs: height, pass, ...).
function T.start_goto(ctx, x, y, z, speed, opts)
    x, y, z, speed = tonumber(x), tonumber(y), tonumber(z), tonumber(speed)
    if not (x and y and z) then return false, "usage: goto x y z [speed b/s]" end
    if ctx.task and ctx.task.kind == "hold" then ctx.task = nil end -- a new destination replaces station keeping
    if ctx.task then return false, "task already running: " .. ctx.task.kind end
    if ctx.k.mode ~= "ARMED" then return false, "goto needs ARMED" end
    if not sensor_ok(ctx.state, true) then return false, "goto needs position and heading" end
    local target = {x = x, y = y, z = z}
    ctx.task = {kind = "goto", target = target, restore = "ARMED", nav = Nv.new(ctx.cfg, target, speed, ctx.state.pos.y, opts)}
    K.set_pilot(ctx.k, {forward = 0, side = 0, climb = 0, turn = 0})
    -- the altitude ramp starts from where the ship is, not from a stale manual setpoint
    if not ctx.k.alt_sp or math.abs(ctx.k.alt_sp - ctx.state.pos.y) > 10 then ctx.k.alt_sp = ctx.state.pos.y end
    local dist = math.sqrt((x - ctx.state.pos.x) ^ 2 + (z - ctx.state.pos.z) ^ 2)
    local v = Nv.cruise_speed(ctx.cfg, speed)
    Cx.log(ctx, ("goto start: (%.0f, %.0f, %.0f) dist %.0f, speed %s"):format(x, y, z, dist, v == math.huge and "max" or ("%.0f b/s"):format(v)))
    return true
end

-- Arm on the ground and climb ap.takeoff blocks; then run `after(ctx)`.
function T.start_takeoff(ctx, after)
    if ctx.task then return false, "task already running: " .. ctx.task.kind end
    if ctx.k.mode ~= "STANDBY" then return false, "takeoff needs STANDBY (already flying?)" end
    if not sensor_ok(ctx.state) then return false, "takeoff needs the sublevel position" end
    local ok, err = K.arm(ctx.k, ctx.state)
    if not ok then return false, "cannot arm: " .. tostring(err) end
    R.start_engine(ctx)
    ctx.notice = nil
    ctx.ground_y = ctx.state.pos.y
    ctx.task = {kind = "takeoff", target_y = ctx.state.pos.y + ctx.cfg.ap.takeoff, started = Cx.now(ctx), restore = "ARMED", after = after}
    K.set_pilot(ctx.k, {forward = 0, side = 0, climb = 0, turn = 0})
    ctx.k.alt_sp = ctx.task.target_y
    Cx.log(ctx, ("takeoff: armed at %.1f, climbing to %.1f"):format(ctx.state.pos.y, ctx.task.target_y))
    return true
end

-- Docking: fly to the point over the dock at the align height (the flight
-- height, Nv.dock_align_y), turn to face it up there, then come straight
-- down over it (Nv.dock_descent) and settle the last creep_lift blocks. The
-- old way in, low along the dock axis, hit the owner's building (2026-10-15).
-- hooks (a route): {owner, on_docked = function(ctx)} go with every task of the docking.
function T.start_dock(ctx, wp, hooks)
    local dock = {x = wp.x, y = wp.y, z = wp.z, hdg = wp.hdg, name = wp.name}
    -- already over it and below the align height (a retry off the point):
    -- line up and come down right here, no climb to the flight height
    local pos = ctx.state and ctx.state.pos
    if pos and ctx.k.mode == "ARMED" and not ctx.task
        and math.sqrt((pos.x - dock.x) ^ 2 + (pos.z - dock.z) ^ 2) <= ctx.cfg.dock.approach_radius
        and pos.y < Nv.dock_align_y(ctx.cfg, dock) then
        T.begin_dock(ctx, dock, hooks)
        return true
    end
    local y = Nv.dock_align_y(ctx.cfg, dock)
    local ok, err = T.start_goto(ctx, dock.x, y, dock.z, nil)
    if not ok then return false, err end
    ctx.task.name = wp.name
    ctx.task.nav.radius = ctx.cfg.dock.approach_radius
    ctx.task.nav.dock_hdg = wp.hdg   -- the last blocks in already turn to it
    ctx.task.after = function(c) T.begin_dock(c, dock, hooks) end
    if hooks then ctx.task.owner = hooks.owner end
    Cx.log(ctx, ("dock %s: over it at height %.0f, then straight down facing %.0f"):format(tostring(wp.name), y, wp.hdg))
    return true
end

function T.begin_dock(ctx, dock, hooks)
    ctx.task = {kind = "dock", dock = dock, name = dock.name, restore = "ARMED", target = {x = dock.x, y = dock.y, z = dock.z},
        owner = hooks and hooks.owner, on_docked = hooks and hooks.on_docked}
    K.set_pilot(ctx.k, {forward = 0, side = 0, climb = 0, turn = 0})
    K.reset_integrals(ctx.k, "yaw")   -- no booster here: what the heading integral holds is a wind-up
    ctx.k.alt_sp = math.max(ctx.state and ctx.state.pos and ctx.state.pos.y or 0, dock.y + ctx.cfg.dock.creep_lift)
    Cx.log(ctx, ("dock %s: over it, facing %.0f and coming straight down"):format(tostring(dock.name), dock.hdg))
end

local function lost(ctx, state, t, dt, need_heading)
    if sensor_ok(state, need_heading) then return nil end
    T.abort_task(ctx, "sensor lost")
    return K.step(ctx.k, state, t, dt)
end

local STEP = {}

STEP.takeoff = function(ctx, task, state, t, dt)
    local r = lost(ctx, state, t, dt); if r then return r end
    ctx.k.alt_sp = task.target_y
    if state.pos.y >= task.target_y - 1 then
        ctx.task = nil
        Cx.log(ctx, ("takeoff done at %.1f"):format(state.pos.y))
        if task.after then task.after(ctx) end
    elseif t - task.started > ctx.cfg.takeoff_timeout then
        T.abort_task(ctx, "timeout below the takeoff height (hovering)")
    end
    return K.step(ctx.k, state, t, dt)
end

STEP.hold = function(ctx, task, state, t, dt)
    local r = lost(ctx, state, t, dt, true); if r then return r end
    local h = Nv.hold2d(ctx.cfg, state, task.target)
    task.last = h
    K.set_pilot(ctx.k, {forward = h.forward, side = h.side})
    return K.step(ctx.k, state, t, dt)
end

STEP["goto"] = function(ctx, task, state, t, dt)
    local r = lost(ctx, state, t, dt, true); if r then return r end
    local out = Nv.step(task.nav, state, ctx.k.alt_sp, dt)
    task.last = out
    if out.ceiling then Cx.log(ctx, ("goto: cannot climb past %.0f (ceiling), flying on at this height"):format(out.ceiling)) end
    if out.hdg_sp then ctx.k.hdg_sp = out.hdg_sp end
    ctx.k.alt_sp = out.alt_sp
    -- terrain: en route never closer than terrain_clear above the ground under the ship
    -- only on a long leg's cruise: a dock's entry and approach legs fly low on purpose
    local above = G.above(ctx)
    local cruising = not task.nav.local_leg and out.dist > math.max(ctx.cfg.speed.near, 3 * (task.nav.radius or ctx.cfg.goto_radius))
    if above and cruising and not out.descending and above < ctx.cfg.terrain_clear then
        local need = state.pos.y + (ctx.cfg.terrain_clear - above)
        if need > ctx.k.alt_sp then
            ctx.k.alt_sp = need
            if not task.terrain_logged then task.terrain_logged = true; Cx.log(ctx, ("goto: ground %.1f below, climbing to keep %d"):format(above, ctx.cfg.terrain_clear)) end
        end
    else
        task.terrain_logged = nil
    end
    K.set_pilot(ctx.k, {forward = out.forward, side = out.side})
    -- Down on the ground mid-flight (it fell): stop the leg and land, instead
    -- of the cube pushing the ship along the ground at full (Aero, 2026-10-15).
    if not task.after then
        local above = G.above(ctx)
        if above and above > 5 then task.airborne = true end
        if task.airborne and not out.descending and G.on_ground(ctx) then
            task.down_t = (task.down_t or 0) + dt
            if task.down_t >= 2 then
                ctx.task = nil
                K.set_pilot(ctx.k, {forward = 0, side = 0})
                Cx.log(ctx, ("goto aborted: on the ground %.0f blocks before %s: landing"):format(out.dist, task.name or "the point"))
                local okL, errL = T.start_land(ctx)
                if not okL then Cx.log(ctx, "land refused: " .. tostring(errL)) end
                return K.step(ctx.k, state, t, dt)
            end
        else
            task.down_t = nil
        end
    end
    -- The point lies under the ground there (an old point's height, a hill):
    -- over it the ship sits on the ground still trying to go down, and the
    -- height never comes (it stood on its legs with the motors pushing down,
    -- 2026-10-15). On the ground over the point for 1.5 s = arrived: land.
    if out.descending and not task.after and out.dist <= (task.nav.radius or ctx.cfg.goto_radius) + 2
        and G.on_ground(ctx) and math.abs(state.vel.y) < 0.2 then
        task.ground_t = (task.ground_t or 0) + dt
        if task.ground_t >= 1.5 then
            ctx.task = nil
            K.set_pilot(ctx.k, {forward = 0, side = 0})
            Cx.log(ctx, ("arrived at %s(%.0f, %.0f, %.0f) on the ground, %.1f above the point: landing"):format(
                task.name and (task.name .. " ") or "", task.target.x, task.target.y, task.target.z, state.pos.y - task.target.y))
            local okL, errL = T.start_land(ctx)
            if not okL then Cx.log(ctx, "land on arrival refused: " .. tostring(errL)) end
            return K.step(ctx.k, state, t, dt)
        end
    else
        task.ground_t = nil
    end
    if out.arrived then
        ctx.task = nil
        if out.passed then   -- flown over without stopping: the next leg takes the speed on
            Cx.log(ctx, ("passed %s(%.0f, %.0f) at %.0f b/s"):format(task.name and (task.name .. " ") or "",
                task.target.x, task.target.z, math.max(0, state.v_fwd or 0)))
        else
            K.set_pilot(ctx.k, {forward = 0, side = 0})
            Cx.log(ctx, ("arrived at %s(%.0f, %.0f, %.0f), dist %.1f"):format(
                task.name and (task.name .. " ") or "", task.target.x, task.target.y, task.target.z, out.dist))
        end
        if task.after then
            task.after(ctx)   -- e.g. the next docking leg
        elseif task.on_arrive then
            task.on_arrive(ctx, task)   -- a route's next step (fc.flight.route)
        else
            -- final point: hold there, or land there (ap.arrive)
            T.start_hold(ctx, task.target.x, task.target.z)
            if ctx.task then ctx.task.name = task.name end
            if ctx.cfg.ap.arrive == "land" then
                local okL, errL = T.start_land(ctx)
                if not okL then Cx.log(ctx, "land on arrival refused: " .. tostring(errL)) end
            end
        end
    end
    return K.step(ctx.k, state, t, dt)
end

-- Final docking: hold over the dock facing it, come straight down to
-- creep_lift above it (Nv.dock_descent); once there and within tolerance
-- in the plane, settle down at settle_rate (the legs / docking
-- connectors are out by now and lock when aligned) until something holds
-- the ship up: the height target a block below the hull and no vertical
-- motion for off_after seconds (or resting) -> motors off. A ship 3 blocks
-- above the ground once counted as "on the ground" and dropped (2026-10-15).
STEP.dock = function(ctx, task, state, t, dt)
    local r = lost(ctx, state, t, dt, true); if r then return r end
    local dc = ctx.cfg.dock
    local d = Nv.dock_step(ctx.cfg, state, task.dock, task, dt)
    task.last = d
    -- turn to the dock heading at turn_rate deg/s: turned at once (137 deg)
    -- the yaw took every thruster and the ship drifted 23 blocks off the dock
    local diff = A.wrap180(d.hdg_sp - (task.hdg_cmd or state.heading or d.hdg_sp))
    local step = dc.turn_rate * dt
    task.hdg_cmd = math.abs(diff) <= step and d.hdg_sp or A.wrap180((task.hdg_cmd or state.heading) + (diff > 0 and step or -step))
    ctx.k.hdg_sp = task.hdg_cmd
    K.set_pilot(ctx.k, {forward = d.forward, side = d.side_cmd})
    local top = task.dock.y + dc.creep_lift
    -- aligned high up is not docked yet, and nor is a tilted hull (all legs at once)
    d.docked = d.docked and state.pos.y <= top + 0.5
        and math.abs(state.tilt.fwd) <= dc.tol_level and math.abs(state.tilt.left) <= dc.tol_level
    -- the last blocks only while right over the dock: sinking unwatched it
    -- sat down 0.76 past the dock and the connector did not take (2026-10-17)
    local over = math.abs(d.along) <= dc.tol_along and math.abs(d.side) <= dc.tol_side
    local gone = math.abs(d.along) > 1.75 * dc.tol_along or math.abs(d.side) > 1.5 * dc.tol_side
    if task.settling and gone then
        -- well off the point on the way down: back up to creep_lift, line up in free air
        task.settling, task.docked_logged, task.docked_t = false, false, 0
        ctx.k.alt_sp = top
        Cx.log(ctx, ("dock %s: %.2f along, %.2f side off the point, lifting to line up again"):format(tostring(task.name), d.along, d.side))
        return K.step(ctx.k, state, t, dt)
    end
    if d.docked or task.settling then
        if not task.settling then ctx.k.alt_sp = math.min(ctx.k.alt_sp or top, state.pos.y) end   -- already sitting lower: settle from there
        task.settling = true
        local floor = math.min(task.dock.y, ctx.ground_y or task.dock.y) - 2
        if over then ctx.k.alt_sp = math.max(floor, (ctx.k.alt_sp or top) - dc.settle_rate * dt)
        else ctx.k.alt_sp = math.max(ctx.k.alt_sp or top, state.pos.y) end   -- a little off: stop sinking until it is over again
    else
        ctx.k.alt_sp = Nv.dock_descent(ctx.cfg, task, d, ctx.k.alt_sp or state.pos.y, state.pos.y, top, dt)
    end
    if d.docked and not task.docked_logged then
        task.docked_logged, task.was_docked = true, true
        Cx.log(ctx, ("DOCKED at %s: along %.2f side %.2f heading err %.1f, settling"):format(tostring(task.name), d.along, d.side, d.hdg_err))
    end
    -- docked once, then lifting to line up again and the hull does not move
    -- at all: the docking connector holds it -> motors off as docked (it
    -- pulled the ship 0.40 off the point and the lift wound up from 47 to
    -- 160 rpm for 2 min, 2026-10-24)
    if task.was_docked and not task.settling and ctx.k.alt_sp and ctx.k.alt_sp - state.pos.y >= 0.8
        and math.abs(state.vel.y) < 0.05 and (state.speed or 0) < 0.05 then
        task.locked_t = (task.locked_t or 0) + dt
        if task.locked_t >= dc.locked_after and G.may_cut(ctx, task) then
            ctx.ground_y = state.pos.y
            task.restore = "STANDBY"
            T.end_task(ctx, ("DOCKED at %s: held by the docking connector %.2f along, %.2f side off the point: motors off"):format(tostring(task.name), d.along, d.side))
            R.stop_engine(ctx, task.name)
            if task.on_docked then task.on_docked(ctx) end
            return K.step(ctx.k, state, t, dt)
        end
    else
        task.locked_t = 0
    end
    local held_up = ctx.k.alt_sp and state.pos.y - ctx.k.alt_sp >= 0.8 and math.abs(state.vel.y) < 0.1
    if task.settling and (held_up or G.resting(ctx)) and not over then
        -- sitting on the dock off its point: lift back to creep_lift and line up again
        task.settling, task.docked_logged, task.docked_t = false, false, 0
        ctx.k.alt_sp = top
        Cx.log(ctx, ("dock %s: down %.2f along, %.2f side off the point, lifting to line up again"):format(tostring(task.name), d.along, d.side))
        return K.step(ctx.k, state, t, dt)
    end
    if task.settling and dc.auto_off ~= 0 and (held_up or G.resting(ctx)) then
        task.docked_t = (task.docked_t or 0) + dt
        if task.docked_t >= dc.off_after and G.may_cut(ctx, task) then
            ctx.ground_y = state.pos.y
            task.restore = "STANDBY"
            T.end_task(ctx, ("DOCKED at %s on the ground: motors off"):format(tostring(task.name)))
            R.stop_engine(ctx, task.name)
            if task.on_docked then task.on_docked(ctx) end
            return K.step(ctx.k, state, t, dt)
        end
    else
        task.docked_t = 0
    end
    return K.step(ctx.k, state, t, dt)
end

STEP.land = function(ctx, task, state, t, dt)
    local r = lost(ctx, state, t, dt); if r then return r end
    local rate = task.rate
    local above = ctx.ground_y and (state.pos.y - ctx.ground_y) or nil
    if not rate then
        local f = ctx.cfg.land_fast
        local range = ctx.cfg.ground_range or 0
        if above and ctx.ground_src == "sensor" and f and f.max > 0 then
            -- the ground is seen (sensors up to ground_range, 64 on Aero since
            -- 2026-10-23): a braking curve down to it, as a dock's descent
            rate = math.max(f.min, math.min(f.max, math.sqrt(2 * f.brake * math.max(0, above))))
        elseif f and f.max > 0 and range > f.margin and (not above or above > range) then
            -- nothing seen and nothing remembered within the sensors' reach:
            -- the ground is farther than ground_range, so as fast as still
            -- stops in ground_range - margin once it comes into view (owner)
            rate = math.max(f.min, math.min(f.max, math.sqrt(2 * f.brake * (range - f.margin))))
        else
            rate = T.LAND_RATES[#T.LAND_RATES].rate
            if above then
                for _, band in ipairs(T.LAND_RATES) do
                    if above > band.above then rate = band.rate; break end
                end
            end
        end
    end
    task.last = {above = above, rate = rate}
    local forward, side = 0, 0
    if state.heading then
        local h = Nv.hold2d(ctx.cfg, state, task.target)
        forward, side = h.forward, h.side
    end
    K.set_pilot(ctx.k, {climb = -rate, forward = forward, side = side})
    -- never ask for altitude far below the remembered ground, nor far below the hull
    if ctx.ground_y and ctx.k.alt_sp and ctx.k.alt_sp < ctx.ground_y - 2 then ctx.k.alt_sp = ctx.ground_y - 2 end
    local floor = state.pos.y - (rate * T.LAND_LEAD + 1)
    if ctx.k.alt_sp and ctx.k.alt_sp < floor then ctx.k.alt_sp = floor end
    -- Touchdown: still (|vy| <= 0.15 for 1.2 s) after a real descent of at
    -- least 1 block near the remembered ground; a landing started on the
    -- ground needs 2 s of stillness. Without a ground memory it must also be
    -- truly at rest: no horizontal speed, level, 3 s.
    task.descended = math.max(task.descended, task.start_y - state.pos.y)
    if math.abs(state.vel.y) <= 0.15 then task.still = task.still + dt else task.still = 0 end
    local landed
    if ctx.ground_y then
        local near_ground = state.pos.y <= ctx.ground_y + 3
        local started_on_ground = task.start_y <= ctx.ground_y + 3
        landed = near_ground and ((started_on_ground and task.still >= 2) or (task.descended >= 1 and task.still >= 1.2))
    else
        local tilt = math.max(math.abs(state.tilt.left), math.abs(state.tilt.fwd))
        landed = task.descended >= 1 and task.still >= 3 and (state.speed or 0) < 1 and tilt < 0.17
    end
    if landed and not task.keep_armed and not G.may_cut(ctx, task) then landed = false end
    if landed then
        ctx.ground_y = state.pos.y
        if not task.keep_armed then task.restore = "STANDBY" end
        T.end_task(ctx, ("landed at alt %.1f%s"):format(state.pos.y, task.keep_armed and ", motors kept running" or ""))
        if task.on_landed then task.on_landed(ctx) end
    end
    return K.step(ctx.k, state, t, dt)
end

-- The vertical phases (fc.flight.controller K.set_vertical): a takeoff, a
-- goto while it climbs to the flight height first, and a goto straight up
-- or down (the point over the ship: no forward flight at all; such a goto
-- never climbs first, it is near the point from the start). Not a landing:
-- with the hover known only high up it rocked down in 50 s and stopped 2.5
-- above the ground; the plain loop lands in 41 s from 250 (2026-10-23).
function T.vertical(ctx)
    local task = ctx.task
    local k, st = ctx.k, ctx.state
    -- (staying vertical through the hold until settled rocked the ship:
    -- pitch +-13, props 35..154, 2026-10-23; the hand-over sags a little instead)
    if not task then return false end
    if task.kind == "takeoff" then return true end
    if task.kind ~= "goto" or not task.last then return false end
    if task.last.climbing == true then return true end
    local pos = ctx.state and ctx.state.pos
    local last = task.last
    -- straight up only: coming down to a point in the air it rocked +-3
    -- blocks, pitch +-10, rear props to -8 rpm, never within 0.5 so never
    -- arrived (Rimlyanin at 140 from 250, 2026-10-23); down goes the plain
    -- loop like a landing
    return pos ~= nil and last.dist ~= nil and last.target_y ~= nil and last.dist <= ctx.cfg.goto_radius
        and last.target_y - pos.y > 0.5   -- to the very top: handed back 3 short it crept 25 s (2026-10-23)
end

function T.step(ctx, state, t, dt)
    local task = ctx.task
    local f = STEP[task.kind]
    if not f then
        T.abort_task(ctx, "unknown task")
        return K.step(ctx.k, state, t, dt)
    end
    return f(ctx, task, state, t, dt)
end

return T
