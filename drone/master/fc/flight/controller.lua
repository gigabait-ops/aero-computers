-- Flight controller mode machine: STANDBY -> ARMED <-> DEGRADED.
-- Pure: K.step turns a sensor state into the targets to broadcast.
--   roll/pitch: PID on the hull tilt -> lift differential (the integrals are
--               the trim: they learn where the mass sits)
--   altitude:   PID on the height, reference ramped at limits.climb_rate -> collective
--   heading:    PID -> yaw demand (vector thrusters); A/D override while held
--   pilot.forward/side: thrust demands from the speed loop or the autopilot
local P = require("fc.core.pid")
local M = require("fc.flight.mixer")
local A = require("fc.core.attitude")

local K = {}

-- After a disarm STANDBY broadcasts idle for this many cycles, then goes silent.
K.IDLE_BURST = 20
-- The attitude trim learns only while the hull is within this tilt (sin 15 deg):
-- a big upset is corrected by P and D, not remembered as a mass shift.
K.TRIM_TILT = 0.26
-- The trim stays within TRIM_SWING rpm of the one it armed with: stuck in
-- trees on a slight tilt, the roll trim crept from -3 to -47 in four minutes
-- and rolled the ship over the moment it broke free (2026-10-15).
K.TRIM_SWING = 30
-- What is kept for the next flight is the trim averaged over TRIM_TAU s of
-- learning, not its last value: a landing that propped the ship on the edge
-- of a dock ran it to the swing limits in 30 s, and those were saved (2026-10-15).
K.TRIM_TAU = 10
-- Props stalled (see K.step): falling faster than STALL_ACCEL b/s^2 for
-- STALL_TIME s cuts the collective to STALL_CUT of what it was; another
-- cut only after STALL_WAIT s (the props need that to spin up again).
-- The cut holds STALL_HOLD s, then the cap rises STALL_RECOVER rpm/s until
-- it is gone: an overloaded network stalls again and is cut again, a false
-- alarm (a sink at speed) costs a few seconds.
-- STALL_ACCEL is near free fall (stopped props fell at -9.6 b/s^2): a ship
-- short of lift at speed sinks at about -2 and is slowed down instead.
K.STALL_ACCEL, K.STALL_TIME, K.STALL_CUT, K.STALL_WAIT = 7.5, 0.3, 0.8, 1.0
K.STALL_HOLD, K.STALL_RECOVER, K.STALL_KEEP = 5, 20, 0.92
-- A fall counts only after the lift has been high for STALL_SPIN s: the
-- props need that to spin up from low. A takeoff overshot by 9 blocks, the
-- loop cut the lift to 2/-8 rpm 15 blocks up, the ship dropped while the
-- props spun back up, that read as a stall at 132 and the cap held the
-- whole climb to 280 at the limit, the nose swinging +-15..22 deg (2026-11-08).
K.STALL_SPIN = 1.0
-- In the vertical phases (a takeoff, a goto's climb) clear of the ground
-- the collective keeps at least AIR_FLOOR of the hover: an overshoot is
-- braked by a sink, not by stopping the props in the air.
K.AIR_FLOOR = 0.5
-- The heading integral (the booster's steady yaw moment at speed) learns only
-- within YAW_I_ZONE deg: 15 deg held off while climbing over a dock wound it
-- up, and the nose then swung +-19 deg for 45 s over the dock (2026-10-15).
K.YAW_I_ZONE = 10

local function clamp(v, lo, hi)
    if v > hi then return hi elseif v < lo then return lo end
    return v
end

function K.new(cfg)
    local lim = cfg.limits
    return {
        cfg = cfg,
        mode = "STANDBY",
        warn = nil,
        alt_sp = nil,
        alt_ref = nil,        -- altitude reference: follows alt_sp at limits.climb_rate
        last_collective = nil,
        hdg_sp = nil,
        sensor_lost_since = nil,
        idle_cycles = 0,
        pilot = {forward = 0, climb = 0, turn = 0, side = 0}, -- thrust demands (+-thrust_max), climb b/s, turn deg/s
        yaw_override = nil,   -- manual turn: fixed yaw demand while held
        yaw_settle = nil,     -- time the turn key was released (braking phase)
        rate_f = {left = 0, fwd = 0, yaw = 0},   -- EMA-filtered rates for the D terms
        roll_pid = P.new(cfg.gains.tilt, -lim.max_speed, lim.max_speed),
        pitch_pid = P.new(cfg.gains.pitch, -lim.max_speed, lim.max_speed),
        alt_pid = P.new(cfg.gains.alt, -lim.max_speed, lim.max_speed),
        yaw_pid = P.new(cfg.gains.yaw, -lim.thrust_max, lim.thrust_max),
    }
end

-- Apply new gains to the live PIDs (tuning without a restart).
function K.set_gains(k, gains)
    local function apply(pid, g)
        pid.kp, pid.ki, pid.kd, pid.i_max = g.p or 0, g.i or 0, g.d or 0, g.i_max
    end
    apply(k.roll_pid, gains.tilt); apply(k.pitch_pid, gains.pitch)
    apply(k.alt_pid, gains.alt); apply(k.yaw_pid, gains.yaw)
end

local function reset_pids(k)
    P.reset(k.roll_pid); P.reset(k.pitch_pid); P.reset(k.alt_pid); P.reset(k.yaw_pid)
end

-- Clear the integrators (all loops, or one of tilt/pitch/alt/yaw).
function K.reset_integrals(k, loop)
    if loop == nil then reset_pids(k); return end
    local pid = ({tilt = k.roll_pid, pitch = k.pitch_pid, alt = k.alt_pid, yaw = k.yaw_pid})[loop]
    if pid then P.reset(pid) end
end

local function hold_setpoints(k, state)
    k.alt_sp = state.pos and state.pos.y or nil
    k.alt_ref = k.alt_sp
    k.hdg_sp = state.heading
end

-- Highest collective that still leaves `attitude_headroom` rpm (plus the
-- trim, which rides on top of the collective on one end) on the most scaled
-- lift motor for roll and pitch.
function K.collective_cap(cfg, trim)
    local scale = 1
    for _, m in pairs(cfg.motors) do
        if m.role == "lift" and (m.scale or 1) > scale then scale = m.scale end
    end
    trim = trim or cfg.trim or {}
    return (cfg.limits.max_speed - (cfg.attitude_headroom or 16) - math.abs(trim.pitch or 0) - math.abs(trim.roll or 0)) / scale
end

-- Nose up at speed (cfg.pitch_up {deg, from, full}): 0 below `from` b/s,
-- `deg` from `full` on. The flat hull then lifts instead of pressing down,
-- and the thrusters push a little upward: on Aero the props worked at 67
-- with the nose 13 deg up at 95 b/s and at 169 with it 7 deg down at 138,
-- where the network stopped them (2026-10-15). Returns sin(angle) for the
-- pitch loop.
function K.pitch_up(cfg, state, on_ground)
    local pu = cfg.pitch_up
    if not pu or pu.deg == 0 or on_ground then return 0 end
    local f = ((state.v_fwd or 0) - pu.from) / (pu.full - pu.from)
    f = math.max(0, math.min(1, f))
    return math.sin(math.rad(pu.deg * f))
end

-- True when the hull is turned past cut_tilt (60 deg), on its back included.
function K.overturned(cfg, state)
    local up = state and state.tilt and state.tilt.up
    return up ~= nil and up < math.sqrt(1 - cfg.arm_cut_tilt ^ 2)
end

function K.arm(k, state)
    if not state then return false, "no sensor state" end
    if K.overturned(k.cfg, state) then return false, "overturned" end
    hold_setpoints(k, state)
    reset_pids(k)
    local tr = k.cfg.trim or {}
    k.trim_base = {roll = tr.roll or 0, pitch = tr.pitch or 0}
    k.learn_t, k.upset = 0, false   -- s the trim has learned this flight; an upset (tilt abort) keeps it from being saved
    k.trim_kept = {roll = k.trim_base.roll, pitch = k.trim_base.pitch}
    K.set_trim(k, k.cfg.trim)
    k.rate_f = {left = 0, fwd = 0, yaw = 0}
    k.yaw_settle = nil
    k.mode = "ARMED"
    k.sensor_lost_since = nil
    k.warn = nil
    return true
end

-- STANDBY is passive: a freshly booted master must not touch nodes that
-- hold a fallback value. Only an explicit disarm sends idle, as a burst.
function K.disarm(k)
    k.mode = "STANDBY"
    k.sensor_lost_since = nil
    k.idle_cycles = K.IDLE_BURST
    k.pilot = {forward = 0, climb = 0, turn = 0, side = 0}
    k.yaw_override = nil
    k.yaw_settle = nil
    k.alt_ref = nil
    k.last_collective = nil
    k.stall_cap, k.stall_level = nil, nil   -- a props-stalled cap ends with the flight (the owner may fix the power on the ground)
end

-- Manual turn: a fixed yaw demand (positive = right) that bypasses the
-- heading PID while set; releasing captures the heading. nil clears.
function K.set_yaw_override(k, demand)
    k.yaw_override = demand
end

-- Pilot inputs: forward/side thrust demands, climb rate in blocks/s and turn
-- rate in deg/s. Missing fields keep their current value.
function K.set_pilot(k, inputs)
    for _, name in ipairs({"forward", "climb", "turn", "side"}) do
        if inputs[name] ~= nil then k.pilot[name] = inputs[name] end
    end
    return k.pilot
end

function K.idle_action(k)
    return {type = "idle", targets = M.idle(k.cfg.motors, k.cfg.idle)}
end

function K.rehold(k, state)
    if not state then return false, "no sensor state" end
    hold_setpoints(k, state)
    return true
end

-- Best current estimate of the hover collective: config value plus whatever
-- the altitude loop's integral has learned since arming.
function K.hover_estimate(k)
    return (k.hover_now or k.cfg.hover) + (k.alt_pid.integral or 0)
end

-- The vertical phases (a takeoff, a goto's climb to the flight height, a
-- landing: fc.flight.tasks T.vertical) fly the height loop with the hover by
-- height, the climb fed forward and the braked reference (altitude below);
-- everything else (cruise, hold, the keys) as before (owner 2026-10-23: not
-- globally, nothing that works in flight may change). Switching over moves
-- the difference between the two hovers through the integral, so the
-- collective does not jump.
function K.set_vertical(k, on, y)
    on = on and true or false
    if on == (k.vertical or false) then return end
    local delta = K.hover_at(k.cfg, y) - k.cfg.hover
    k.alt_pid.integral = (k.alt_pid.integral or 0) + (on and -delta or delta)
    k.vertical = on
end

-- Hover by height (owner 2026-10-23: the air thins, at 250 the props need
-- ~93 rpm against 48 near the ground, and the integral took a whole climb
-- to find that, braking it and overshooting the top by 9 blocks): the
-- collective a hover needs at height y, from cfg.hover_curve ({{y, c}, ...}
-- sorted by y, learned in steady holds, K.learn_hover), linear between the
-- points and flat beyond them; cfg.hover without a curve.
function K.hover_at(cfg, y)
    local c = cfg.hover_curve
    if type(c) ~= "table" or #c == 0 or not y then return cfg.hover end
    if y <= c[1].y then return c[1].c end
    for i = 2, #c do
        if y <= c[i].y then
            local a, b = c[i - 1], c[i]
            return a.c + (b.c - a.c) * (y - a.y) / (b.y - a.y)
        end
    end
    return c[#c].c
end

-- Learning the curve: holding still in the air (not near the ground, level,
-- the reference settled, no stall cut) for HOVER_LEARN_S, the hover found
-- (curve + integral) goes halfway into the point of its 25-block band, and
-- the integral gives up what the curve took on (the collective stays put).
K.HOVER_BAND, K.HOVER_LEARN_S = 25, 4
-- One hold moves the hover at most this share from what the curve says:
-- held up by a tree, a roof or a block the ship "hovers" on far less (y 100
-- learned 32.8 between 43 and 53; short of lift low down, it rolled over by
-- the dock, 2026-11-08). A real change still gets there over a few holds.
K.HOVER_STEP = 0.15
local function learn_hover(k, state, dt)
    local cfg = k.cfg
    local vy, tilt = state.vel and state.vel.y, state.tilt
    local still = vy and math.abs(vy) < 0.1 and (state.speed or 0) < 3 and k.alt_ref and k.alt_sp and k.alt_ref == k.alt_sp
        and math.abs(k.alt_sp - state.pos.y) < 0.5 and tilt and math.max(math.abs(tilt.left), math.abs(tilt.fwd)) < 0.05
        and not (k.on_ground or k.low or k.stall_cap or k.no_learn)
    if not still then k.hover_still = 0; return end
    k.hover_still = (k.hover_still or 0) + dt
    if k.hover_still < K.HOVER_LEARN_S then return end
    k.hover_still = 0
    local y = state.pos.y
    local before = K.hover_at(cfg, y)
    local found = K.hover_estimate(k)   -- this mode's base plus the integral: the hover the ship flies on
    found = clamp(found, before * (1 - K.HOVER_STEP), before * (1 + K.HOVER_STEP))
    local band = math.floor(y / K.HOVER_BAND + 0.5) * K.HOVER_BAND
    local curve = cfg.hover_curve or {}
    cfg.hover_curve = curve
    local pt
    for _, p in ipairs(curve) do if p.y == band then pt = p end end
    if not pt then
        pt = {y = band, c = found}
        curve[#curve + 1] = pt
        table.sort(curve, function(a, b) return a.y < b.y end)
    else
        pt.c = pt.c + 0.5 * (found - pt.c)
    end
    pt.c = math.floor(pt.c * 10 + 0.5) / 10
    if k.vertical then k.alt_pid.integral = (k.alt_pid.integral or 0) - (K.hover_at(cfg, y) - before) end
    k.hover_dirty = true
end

-- Attitude trim: the roll/pitch integrals (rpm of lift differential) learn
-- where the mass sits and follow it as cargo comes and goes. cfg.trim seeds
-- them at arm; the fallback carries the live values, so a silent master
-- leaves the nodes holding a level ship.
function K.trim_estimate(k)
    return {roll = k.roll_pid.integral or 0, pitch = k.pitch_pid.integral or 0}
end

function K.set_trim(k, trim)
    trim = trim or {}
    local base = k.trim_base or {}
    local function bound(pid, v, b)
        v = v or 0
        if pid.i_max then v = clamp(v, -pid.i_max, pid.i_max) end
        if b then v = clamp(v, b - K.TRIM_SWING, b + K.TRIM_SWING) end
        return v
    end
    k.roll_pid.integral = bound(k.roll_pid, trim.roll, base.roll)
    k.pitch_pid.integral = bound(k.pitch_pid, trim.pitch, base.pitch)
end

-- On the ground the attitude integrals hold: a slope is not a mass shift.
-- low: within a few blocks of the ground, where legs, trees or a dock may
-- hold the hull, so the integrals hold there too.
function K.set_on_ground(k, flag, low)
    k.on_ground = flag and true or false
    k.low = (flag or low) and true or false
end

-- Landing, docking and taking off the hull may touch the ground, a dock
-- or a tree anywhere, so the trim does not learn then (on = false).
function K.set_learning(k, on)
    k.no_learn = not on
end

-- The trim to keep for the next flight (TRIM_TAU average of the learning).
function K.kept_trim(k)
    return k.trim_kept or K.trim_estimate(k)
end

-- Hover collective plus the attitude trim: what nodes apply when the master goes quiet.
function K.fallback_targets(k)
    local cfg = k.cfg
    local tr = K.trim_estimate(k)
    return M.compute(cfg.motors, cfg.limits, {collective = K.hover_estimate(k), roll = tr.roll, pitch = tr.pitch, yaw = 0})
end

-- Props stalled: a Create kinetic network loaded past its stress capacity
-- stops every prop at once (four alternators on the engine shaft and 220
-- rpm on the front props: a 100 block fall, 2026-10-15). Falling like a
-- stone with the collective above the hover caps the collective (the
-- stress follows the summed rpm) below what it was, so the network starts
-- again; the cap eases off after STALL_HOLD s (see lift_cap).
local function watch_stall(k, state, now, dt)
    if state.vel and not k.on_ground then
        local vy = state.vel.y
        if k.prev_vy then k.fall_acc = (k.fall_acc or 0) + 0.5 * ((vy - k.prev_vy) / dt - (k.fall_acc or 0)) end
        k.prev_vy = vy
        local hover = K.hover_estimate(k)
        if (k.last_collective or 0) > hover * 1.2 then k.high_since = k.high_since or now else k.high_since = nil end
        if (k.fall_acc or 0) < -K.STALL_ACCEL and vy < -2 and k.high_since and now - k.high_since >= K.STALL_SPIN
            and now - (k.stall_t or -math.huge) >= K.STALL_WAIT then
            k.fall_since = k.fall_since or now
            if now - k.fall_since >= K.STALL_TIME then
                local was = k.last_collective
                k.stall_cap = math.max(hover * 1.1, was * K.STALL_CUT)
                k.stall_level = math.min(k.stall_level or math.huge, was)   -- where the props stopped this flight
                k.stall_t, k.fall_since = now, nil
                k.event = ("props stalled: falling with the lift at %.0f (kinetic network overloaded?), lift capped at %.0f"):format(was, k.stall_cap)
            end
        else
            k.fall_since = nil
        end
    else
        k.prev_vy, k.fall_acc, k.fall_since, k.high_since = nil, nil, nil, nil
    end
end

-- The most collective this cycle: lift to spare for roll and pitch, and a
-- stall cut easing off. Easing off goes no higher than STALL_KEEP of the
-- lowest collective the props stopped at this flight (on Aero they stopped
-- at 189-205 four times over, each time after the cap had eased back up,
-- 2026-10-15).
local function lift_cap(k, now, dt)
    local cap = K.collective_cap(k.cfg, K.trim_estimate(k))
    if k.stall_cap and now - k.stall_t > K.STALL_HOLD then
        local top = k.stall_level and K.STALL_KEEP * k.stall_level or math.huge
        k.stall_cap = math.min(k.stall_cap + K.STALL_RECOVER * dt, top)
        if k.stall_cap >= cap then k.stall_cap = nil; k.event = "lift cap lifted: full lift again" end
    end
    if k.stall_cap and k.stall_cap < cap then cap = k.stall_cap end
    return cap
end

-- Roll and pitch (lift differential). The attitude integrals (trim) learn
-- only in the air, near level and with lift to spare: at the collective
-- cap the motors cannot follow.
local function attitude(k, state, cap, dt)
    local cfg, rf = k.cfg, k.rate_f
    local freeze = k.on_ground or k.low or k.no_learn or math.max(math.abs(state.tilt.left), math.abs(state.tilt.fwd)) > K.TRIM_TILT
        or (k.last_collective ~= nil and k.last_collective >= cap - 0.5)
    local function step(pid, meas, rate, sp)
        if not freeze then return P.step(pid, sp or 0, meas, rate, dt) end
        local ki = pid.ki
        pid.ki = 0
        local out = P.step(pid, sp or 0, meas, rate, dt)
        pid.ki = ki
        return out
    end
    local roll = step(k.roll_pid, state.tilt.left, rf.left)
    k.pitch_sp = K.pitch_up(cfg, state, k.on_ground)
    local pitch = step(k.pitch_pid, state.tilt.fwd, rf.fwd, k.pitch_sp)
    if not freeze then
        k.learn_t = (k.learn_t or 0) + dt
        K.set_trim(k, K.trim_estimate(k))   -- keep it within the swing
        local tr, kept = K.trim_estimate(k), k.trim_kept
        if kept then
            local a = dt / (K.TRIM_TAU + dt)
            kept.roll, kept.pitch = kept.roll + a * (tr.roll - kept.roll), kept.pitch + a * (tr.pitch - kept.pitch)
        end
    end
    return roll, pitch
end

-- Height (collective): the reference follows the setpoint at no more than
-- limits.climb_rate and never runs far ahead of the hull: after a fall it
-- climbs back at climb_rate instead of full lift (which overloaded the
-- network again, 2026-10-15). Returns the collective above hover, or 0 and
-- a warning without a height.
--
-- The reference slows into the setpoint (climb.brake b/s^2: the top of a
-- climb is reached without overshoot) and its own speed is fed forward
-- (climb.ff rpm per b/s), and the D term damps the hull's speed against the
-- reference's, not against standing still: a climb is no longer braked by
-- its own damping (it crept from 5 to 8 b/s, 2026-10-23).
local function altitude(k, state, cap, hover, dt)
    local cfg = k.cfg
    if not (state.pos and state.vel and k.alt_sp) then return 0, "no altitude" end
    if not k.vertical then   -- cruise, hold, the keys: as it always flew
        local step = cfg.limits.climb_rate * dt
        if k.alt_ref == nil then k.alt_ref = state.pos.y end
        local lead = cfg.alt_ref_lead
        if k.alt_ref > state.pos.y + lead then k.alt_ref = state.pos.y + lead
        elseif k.alt_ref < state.pos.y - lead then k.alt_ref = state.pos.y - lead end
        local d = k.alt_sp - k.alt_ref
        if math.abs(d) <= step then k.alt_ref = k.alt_sp else k.alt_ref = k.alt_ref + (d > 0 and step or -step) end
        k.alt_pid.out_max = cap - hover   -- saturate (and stop integrating) at the cap
        return P.step(k.alt_pid, k.alt_ref, state.pos.y, state.vel.y, dt)
    end
    local climb = cfg.climb or {}
    local vmax = climb.rate or cfg.limits.climb_rate
    if k.alt_ref == nil then k.alt_ref = state.pos.y end
    local lead = cfg.alt_ref_lead
    if k.alt_ref > state.pos.y + lead then k.alt_ref = state.pos.y + lead
    elseif k.alt_ref < state.pos.y - lead then k.alt_ref = state.pos.y - lead end
    -- the speed the hull should have now: the climb rate, slowing as the
    -- HULL (not the reference, which got there first and the ship stopped 5
    -- short, 2026-10-23) nears the setpoint
    local dh = k.alt_sp - state.pos.y
    -- within the last blocks proportional (climb.near per s): the square
    -- root alone is infinitely steep at the top and the loop chattered there
    local v_want = math.min(vmax, (climb.brake or 0) > 0 and math.sqrt(2 * climb.brake * math.abs(dh)) or vmax,
        (climb.near or 0.5) * math.abs(dh))
    v_want = dh >= 0 and v_want or -v_want
    local d = k.alt_sp - k.alt_ref
    local step = math.abs(v_want) * dt
    if math.abs(d) <= step then k.alt_ref = k.alt_sp else k.alt_ref = k.alt_ref + (d > 0 and step or -step) end
    local ff = (climb.ff or 0) * v_want
    k.alt_pid.out_max = cap - hover - ff   -- saturate (and stop integrating) at the cap
    return P.step(k.alt_pid, k.alt_ref, state.pos.y, state.vel.y - v_want, dt) + ff
end

-- Heading (yaw demand on the vectors): a turn key held, the settle after
-- it, or heading hold. Returns the demand and the warning so far.
local function heading(k, state, now, dt, warn)
    local cfg, rf = k.cfg, k.rate_f
    local yaw = 0
    -- the vectors' authority: thrust_max per thruster on the thinnest corner
    local full = cfg.limits.thrust_max * (state.vn or 1)
    k.yaw_pid.out_min, k.yaw_pid.out_max = -full, full
    if k.yaw_override then
        yaw = k.yaw_override
        if state.heading then k.hdg_sp = state.heading end
        P.reset(k.yaw_pid)
        k.yaw_settle = now                 -- when released: brake first, then hold
    elseif k.yaw_settle and state.heading then
        -- Key released while the hull still turns: pure damping until it has
        -- stopped (or turn_settle_time), the target stays on the nose, so the
        -- ship holds the heading where it stopped instead of turning back.
        k.hdg_sp = state.heading
        yaw = clamp(-(cfg.turn_brake or 40) * rf.yaw, -full, full)
        if math.abs(rf.yaw) <= (cfg.turn_settle_rate or 1) or now - k.yaw_settle >= (cfg.turn_settle_time or 10) then
            k.yaw_settle = nil
            P.reset(k.yaw_pid)
        end
    elseif cfg.heading_hold then
        if state.heading and k.hdg_sp then
            local err = A.wrap180(k.hdg_sp - state.heading)
            local ki = k.yaw_pid.ki
            if math.abs(err) > K.YAW_I_ZONE then k.yaw_pid.ki = 0 end
            yaw = P.step(k.yaw_pid, 0, -err, rf.yaw, dt)
            k.yaw_pid.ki = ki
        else
            warn = warn and (warn .. "; no heading") or "no heading"
        end
    end
    return yaw, warn
end

-- Lift at its limit at speed: the props lose lift fast, and the Aero copy
-- (heavier tail) sank into the ground at 176 b/s while the ceiling below
-- lowered its height target (2026-10-15). Flagged for the engine, which
-- slows the ship down instead (not while a stall cut holds the lift down:
-- that sink is the stall, and blaming the speed slowed the Aero copy to 20
-- b/s). Ceiling: at the cap and still not climbing for ceiling_s seconds
-- with the target above the hull -> the target comes down to the hull, so
-- the attitude loops keep their headroom (thin air at 295 saturated the
-- front props and the nose dropped, 2026-10-15); only slow: at speed the
-- lift is short because of the speed. k.event carries the line for the log.
local function lift_limits(k, state, collective, cap, now)
    local cfg = k.cfg
    k.cap_now = cap
    k.lift_limited = (state.vel and not k.stall_cap and collective >= 0.85 * cap and state.vel.y < -0.5 and (state.speed or 0) > 20) and true or false
    if state.pos and state.vel and k.alt_sp and collective >= cap - 0.5 and state.vel.y < 0.3 and k.alt_sp > state.pos.y + 1
        and (state.speed or 0) < 20 then
        k.cap_since = k.cap_since or now
        if now - k.cap_since >= (cfg.ceiling_s or 3) then
            k.alt_sp, k.alt_ref = state.pos.y, state.pos.y
            k.event = ("ceiling: lift capped at %.0f and not climbing, height target lowered to %.1f"):format(cap, state.pos.y)
            k.cap_since = nil
        end
    else
        k.cap_since = nil
    end
end

-- A lift motor past 80 % of max_speed at speed counts as short of lift
-- too: the nose dropping at speed pressed the hull down and the front props
-- climbed to 210 before the network stopped them (Aero, 2026-10-15).
local function motors_near_top(k, state, targets)
    if k.lift_limited or k.stall_cap or (state.speed or 0) <= 20 then return end
    local cfg = k.cfg
    for id, m in pairs(cfg.motors) do
        if m.role == "lift" and math.abs(targets[id] or 0) >= 0.8 * cfg.limits.max_speed then k.lift_limited = true; break end
    end
end

-- One control step: the targets for every motor ({type = "set" | "idle" | "none", ...}).
function K.step(k, state, now, dt)
    local cfg = k.cfg
    dt = clamp(dt or 0, 0.01, 0.5)

    if k.mode == "STANDBY" then
        if k.idle_cycles > 0 then
            k.idle_cycles = k.idle_cycles - 1
            return K.idle_action(k)
        end
        return {type = "none"}
    end

    if state == nil then
        k.sensor_lost_since = k.sensor_lost_since or now
        if now - k.sensor_lost_since > cfg.sensor_timeout then
            k.mode = "DEGRADED"
            k.warn = "sensor lost: hover only"
        end
        local fb = K.fallback_targets(k)
        return {type = "set", targets = fb, fallback = fb}
    end
    if k.mode == "DEGRADED" then k.mode = "ARMED" end
    k.sensor_lost_since = nil

    if k.alt_sp and k.pilot.climb ~= 0 then k.alt_sp = k.alt_sp + k.pilot.climb * dt end
    if k.hdg_sp and k.pilot.turn ~= 0 then k.hdg_sp = A.wrap180(k.hdg_sp + k.pilot.turn * dt) end

    -- the rates for the D terms, low-pass filtered
    local a = cfg.rate_filter or 1
    local rf = k.rate_f
    rf.left = rf.left + a * (state.rates.left - rf.left)
    rf.fwd = rf.fwd + a * (state.rates.fwd - rf.fwd)
    rf.yaw = rf.yaw + a * ((state.yaw_rate or 0) - rf.yaw)

    watch_stall(k, state, now, dt)
    local cap = lift_cap(k, now, dt)
    local roll, pitch = attitude(k, state, cap, dt)
    local hover = k.vertical and K.hover_at(cfg, state.pos and state.pos.y) or cfg.hover
    k.hover_now = hover
    local alt_out, warn = altitude(k, state, cap, hover, dt)
    if state.pos then learn_hover(k, state, dt) end
    local yaw
    yaw, warn = heading(k, state, now, dt, warn)
    k.warn = warn

    local collective = hover + alt_out
    if k.vertical and not k.low and collective < K.AIR_FLOOR * hover then collective = K.AIR_FLOOR * hover end
    if collective > cap then collective = cap end
    k.last_collective = collective
    lift_limits(k, state, collective, cap, now)
    local targets = M.compute(cfg.motors, cfg.limits, {
        collective = collective, roll = roll, pitch = pitch, yaw = yaw, forward = k.pilot.forward, side = k.pilot.side or 0,
        booster_cap = k.booster_cap, counts = state.counts,
    })
    motors_near_top(k, state, targets)
    return {type = "set", targets = targets, fallback = K.fallback_targets(k)}
end

return K
