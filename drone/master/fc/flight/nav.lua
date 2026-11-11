-- Navigation for a ship with vector thrusters (it can push sideways, so it
-- never has to turn to correct its position): 2-D station keeping, a speed
-- loop in the hull frame, the braking curve, the goto profile and docking.
-- Pure; the tasks apply the outputs to the controller.
local A = require("fc.core.attitude")

local Nv = {}

local function clamp(v, lo, hi)
    if v > hi then return hi elseif v < lo then return lo end
    return v
end

-- Minecraft yaw of the direction from `from` to `to`: +z -> 0, -x -> +90.
function Nv.bearing(from, to)
    return A.wrap180(math.deg(math.atan2(-(to.x - from.x), to.z - from.z)))
end

-- World offset (dx, dz) -> hull frame (ahead, right) for a heading.
local function hull(dx, dz, heading)
    local h = math.rad(heading or 0)
    return dx * -math.sin(h) + dz * math.cos(h), dx * -math.cos(h) + dz * -math.sin(h)
end
Nv.hull = hull

-- Braking -------------------------------------------------------------------
-- The ship stops with the front pair in reverse plus air drag:
-- a(v) = a0 + k*v + c*v^2 (speed.brake_a0, brake_k, brake_c, measured),
-- planned with speed.margin of it. A full stop from 191 b/s with two vectors
-- per corner (2026-10-20) fits a0 1.2, k 0.088, c 0: Sable's drag grows
-- with the speed, not its square (a0 + c v^2 promised 36 b/s^2 at 183 b/s,
-- it gave 16.5, and too little below 70). All are forces over the mass:
-- measured at speed.brake_mass, they scale with brake_mass / mass for the
-- live mass (cargo aboard, fuel burnt).
local function brake_params(cfg, mass)
    local sp = cfg.speed
    local m = sp.margin
    if sp.brake_mass > 0 and mass and mass > 0 then m = m * sp.brake_mass / mass end
    return sp.brake_a0 * m, (sp.brake_k or 0) * m, sp.brake_c * m
end

-- Stopping distance from v for a(v) = a0 + k v + c v^2: closed forms for
-- k = 0 or c = 0, Simpson's rule (v / a(v) over 0..v) when both are set.
local function distance(a0, k, c, v)
    if v <= 0 then return 0 end
    if k <= 1e-9 then
        if c <= 1e-9 then return v * v / (2 * a0) end
        return math.log(1 + c * v * v / a0) / (2 * c)
    end
    if c <= 1e-9 then return (v - a0 / k * math.log(1 + k * v / a0)) / k end
    local n, h, s = 32, v / 32, 0
    for i = 0, n do
        local u = i * h
        local w = (i == 0 or i == n) and 1 or (i % 2 == 1 and 4 or 2)
        s = s + w * u / (a0 + k * u + c * u * u)
    end
    return s * h / 3
end

function Nv.stop_distance(cfg, v, mass)
    local a0, k, c = brake_params(cfg, mass)
    return distance(a0, k, c, v)
end

-- Highest speed from which the ship still stops within d blocks.
function Nv.stop_speed(cfg, d, mass)
    if d <= 0 then return 0 end
    local a0, k, c = brake_params(cfg, mass)
    if k <= 1e-9 then
        if c <= 1e-9 then return math.sqrt(2 * a0 * d) end
        return math.sqrt((math.exp(math.min(60, 2 * c * d)) - 1) * a0 / c)
    end
    -- the distance grows with v: bisection (36 halvings of 0..2048 b/s)
    local lo, hi = 0, 2048
    if distance(a0, k, c, hi) <= d then return hi end
    for _ = 1, 36 do
        local mid = (lo + hi) / 2
        if distance(a0, k, c, mid) <= d then lo = mid else hi = mid end
    end
    return lo
end

-- Speed loop ------------------------------------------------------------------
-- PI per hull axis from wanted speeds (blocks/s) to thrust demands
-- (+-thrust_max times state.vn, the vectors per corner); `ctl` keeps the integrals ({f, r}), which only move while
-- the output is not saturated in the same direction (anti-windup).
function Nv.speed_new()
    return {f = 0, r = 0}
end

function Nv.speed_step(cfg, ctl, v_des_f, v_des_r, state, dt)
    local sp, tm = cfg.speed, cfg.limits.thrust_max * (state and state.vn or 1)
    local function axis(key, vd, v)
        local e = vd - v
        local raw = sp.kp * e + ctl[key]
        if math.abs(raw) < tm or raw * e < 0 then ctl[key] = clamp(ctl[key] + sp.ki * e * (dt or 0), -tm, tm) end
        return clamp(sp.kp * e + ctl[key], -tm, tm)
    end
    return axis("f", v_des_f, state.v_fwd or 0), axis("r", v_des_r, state.v_right or 0)
end

-- The speed the ship should cruise at: an explicit one, else the SETTINGS
-- speed (ap.speed), 0 meaning as fast as it goes (speed.max when measured).
function Nv.cruise_speed(cfg, explicit)
    local v = explicit
    if not v or v <= 0 then v = (cfg.ap and cfg.ap.speed) or 0 end
    if v <= 0 then v = cfg.speed.max end
    if v <= 0 then v = math.huge end
    if cfg.speed.max > 0 and v > cfg.speed.max then v = cfg.speed.max end
    return v
end

-- Station keeping -------------------------------------------------------------
-- No turning: the position error in the hull frame drives forward and side
-- thrust (velocity loop per axis). Returns {forward, side, dist, e_fwd, e_right}.
function Nv.hold2d(cfg, state, target)
    local pos = state.pos
    local dx, dz = target.x - pos.x, target.z - pos.z
    local e_f, e_r = hull(dx, dz, state.heading)
    local v_f, v_r = state.v_fwd or 0, state.v_right or 0
    local vk, vmax, gain, cap = cfg.hold_vk, cfg.hold_vmax, cfg.hold_a, cfg.hold_max
    local dead = cfg.hold2d_deadband
    local function axis(e, v)
        local vd = clamp(vk * e, -vmax, vmax)
        if math.abs(e) < dead then vd = 0 end
        return clamp(gain * (vd - v), -cap, cap)
    end
    return {mode = "hold2d", forward = axis(e_f, v_f), side = axis(e_r, v_r), dist = math.sqrt(dx * dx + dz * dz), e_fwd = e_f, e_right = e_r}
end

-- Goto --------------------------------------------------------------------------

-- opts (a route's legs, fc.flight.route):
--   cruise_y  this leg's flight height instead of ap.cruise_y
--   pass = {v = b/s, r = blocks}  fly over the point without stopping: no
--             near phase, the speed planned down to v at r blocks before the
--             point, where the next leg takes over (Nv.pass_lead)
--   ctl       the speed loop's integrals carried over from the leg before
--   cruising  already up and moving: no climb-first
function Nv.new(cfg, target, speed, start_y, opts)
    opts = opts or {}
    return {
        cfg = cfg,
        target = {x = target.x, y = target.y, z = target.z},
        speed = speed,             -- explicit b/s, or nil: the SETTINGS speed applies live
        start_y = start_y,
        ctl = opts.ctl or Nv.speed_new(),
        cruise_y = opts.cruise_y,
        pass = opts.pass,
        cruise = opts.cruising or nil,
    }
end

-- Flying over a point (a route's "pass"). Measured on Aero (2026-10-20, at
-- 300 high): the hull turns at most 2.5-3.7 deg/s at any speed (its
-- gyroscopes), and the track follows the nose late (the vectors kill little
-- side speed, the drag the rest in about 11 s); with the old rule (a second
-- of the speed ahead, 99 b/s over a 20 deg turn) it ran 320 blocks past the
-- next point. Now a turn of `turn` deg at v b/s is an arc of radius
-- v / CRUISE_TURN: the next leg takes over the arc's lead before the point
-- plus up to SIDE_LAG s of the speed for the track to follow, and the arc
-- passes at most PASS_CUT blocks inside the corner. Up to PASS_STRAIGHT deg
-- the cross-track loop does it at any speed; another turn at most
-- PASS_TURN_V (the hull weathervanes above ~80 b/s); beyond PASS_TURN deg,
-- or slower than PASS_MIN_V, it stops there instead.
Nv.CRUISE_TURN = 2.5    -- deg/s
Nv.SIDE_LAG = 4         -- s, at a PASS_TURN turn (less for a gentler one)
Nv.PASS_CUT = 40        -- blocks
Nv.PASS_STRAIGHT = 5    -- deg
Nv.PASS_TURN = 45       -- deg
Nv.PASS_TURN_V = 50     -- b/s
Nv.PASS_MIN_V = 15      -- b/s

-- Seconds of the speed the next leg takes over before the point.
local function lead_time(turn)
    turn = math.abs(turn)
    return math.tan(math.rad(turn / 2)) / math.rad(Nv.CRUISE_TURN) + Nv.SIDE_LAG * math.min(1, turn / Nv.PASS_TURN)
end

-- How far before the point the next leg takes over, at v b/s over `turn` deg.
function Nv.pass_lead(cfg, v, turn)
    return math.max(cfg.goto_radius, v * lead_time(turn))
end

-- The most speed over a pass point: `cruise` the legs' own, `turn` there
-- (deg), `room` the most lead there is (blocks, nil: any). nil: stop there.
function Nv.pass_speed(cruise, turn, room)
    turn = math.abs(turn)
    if turn > Nv.PASS_TURN then return nil end
    local v = cruise
    if turn > Nv.PASS_STRAIGHT then
        local cut = 1 / math.cos(math.rad(turn / 2)) - 1
        v = math.min(v, Nv.PASS_TURN_V, Nv.PASS_CUT * math.rad(Nv.CRUISE_TURN) / cut)
    end
    local t = lead_time(turn)
    if room and t > 0 then v = math.min(v, room / t) end
    if v < Nv.PASS_MIN_V then return nil end
    return v
end

-- Straight at a point in 2-D (no turning): the wanted velocity points at it,
-- at most `vmax` and never faster than the ship can stop before it.
function Nv.approach2d(cfg, ctl, state, target, vmax, dt)
    local dx, dz = target.x - state.pos.x, target.z - state.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 1e-6 then return Nv.speed_step(cfg, ctl, 0, 0, state, dt) end
    local v = math.min(vmax, Nv.stop_speed(cfg, dist - (state.speed or 0) * cfg.speed.lead, state.mass))
    local e_f, e_r = hull(dx, dz, state.heading)
    return Nv.speed_step(cfg, ctl, v * e_f / dist, v * e_r / dist, state, dt)
end

-- Altitude: between points fly at the flight height (ap.cruise_y, or the
-- leg's own) when it is above the point, down to it too when the leg
-- started higher (the owner set 250 and a leg begun at 305 stayed at 302,
-- where the thin air held the speed at 20 b/s, 2026-10-21); with no flight
-- height never more than goto_min_alt below where the leg started (terrain
-- is unknown). Over the point descend to its height.
-- A short leg (goto_local) keeps the point's height; latched with
-- hysteresis so a ship drifting around the line does not climb and
-- descend every lap. Sets out.alt_sp (ramped) and out.target_y.
local function leg_height(g, state, out, dist, near, alt_sp_now, dt)
    local cfg, pos = g.cfg, state.pos
    local ap = cfg.ap or {}
    local cruise_y = g.cruise_y or ap.cruise_y
    local target_y = g.target.y
    local lim = cfg.goto_local
    if g.local_leg == nil then g.local_leg = dist <= lim
    elseif g.local_leg and dist > 2 * lim then g.local_leg = false
    elseif not g.local_leg and dist <= lim then g.local_leg = true end
    if not near and not g.local_leg then
        if cruise_y then target_y = math.max(target_y, cruise_y)
        else target_y = math.max(target_y, g.start_y - cfg.goto_min_alt) end
    end
    local cur = alt_sp_now or pos.y
    -- climbing to the flight height first (not yet cruising): the vertical phase's rate
    local up = cfg.goto_climb_up
    if not g.cruise and cfg.climb and cfg.climb.rate then up = math.max(up, cfg.climb.rate) end
    local step = ((target_y > cur) and up or cfg.goto_climb) * dt
    if math.abs(target_y - cur) <= step then out.alt_sp = target_y else out.alt_sp = cur + (target_y > cur and step or -step) end
    out.target_y = target_y
    return target_y
end

-- Near the target: straight at it in 2-D without turning (forward, back or
-- sideways, braking by the curve), the last 3 blocks station keeping;
-- arrival also needs the descent to the point's height done and the ship
-- slow. An overshoot is no problem: it comes back the same way.
local function near_phase(g, state, out, dist, radius, dt)
    local cfg, pos = g.cfg, state.pos
    -- the cruise loop's integrals must not carry into the approach (a
    -- wound-up forward integral flew the drone through the point at
    -- 8.6 b/s and it circled the dock, 2026-10-15)
    if not g.was_near then g.ctl.f, g.ctl.r = 0, 0; g.was_near = true end
    g.final_hdg = g.final_hdg or state.heading
    -- on the way into a dock the nose turns to the dock heading here, at
    -- the dock's turn rate, instead of over the point afterwards (a 78
    -- deg turn up there took 21 s, 2026-10-20)
    if g.dock_hdg and g.final_hdg and (cfg.dock.turn_early or 0) ~= 0 then
        local diff = A.wrap180(g.dock_hdg - g.final_hdg)
        local step = cfg.dock.turn_rate * (dt or 0)
        g.final_hdg = math.abs(diff) <= step and g.dock_hdg or A.wrap180(g.final_hdg + (diff > 0 and step or -step))
    end
    out.hdg_sp = g.final_hdg   -- otherwise the nose stays where it was (see the final approach in Nv.step)
    local alt_ok = math.abs(pos.y - g.target.y) <= cfg.goto_alt_tol
    out.descending = not alt_ok
    if alt_ok then g.near_since = (g.near_since or 0) + dt end
    if dist > 3 then
        out.forward, out.side = Nv.approach2d(cfg, g.ctl, state, g.target, cfg.speed.near_speed, dt)
        out.v_des = math.min(cfg.speed.near_speed, Nv.stop_speed(cfg, dist, state.mass))
    else
        local h = Nv.hold2d(cfg, state, g.target)
        out.forward, out.side = h.forward, h.side
        g.ctl.f, g.ctl.r = 0, 0
    end
    if dist <= radius and (state.speed or 0) < 1 then
        g.inside_since = alt_ok and ((g.inside_since or 0) + dt) or nil
        if g.inside_since and g.inside_since >= 2 then out.arrived = true end
    else
        g.inside_since = nil
    end
    if (g.near_since or 0) >= cfg.goto_near_timeout then out.arrived = true end
    return out
end

-- Climb first: while the ship is more than goto_climb_gate below the
-- height it should fly at, it only climbs (holding still, nose onto the
-- bearing). If it stops gaining height for goto_climb_stall seconds (its
-- ceiling) the flight goes on at the height it has. Once it got there the
-- leg cruises: a sag at speed is the altitude loop's job (a 3.4 block sag
-- at 135 b/s braked at full reverse, the nose dropped and the lift props
-- overloaded the kinetic network, 2026-10-15). Sets out.climbing / out.ceiling.
local function climb_first(g, state, out, target_y, dt)
    local cfg, pos = g.cfg, state.pos
    if target_y - pos.y <= cfg.goto_climb_gate then g.cruise = true end
    if not g.cruise and target_y - pos.y > cfg.goto_climb_gate and not g.ceiling then
        local vy = state.vel and state.vel.y or 0
        if vy < 0.3 then g.stall = (g.stall or 0) + dt else g.stall = 0 end
        if g.stall >= cfg.goto_climb_stall then
            g.ceiling = pos.y
            out.ceiling = pos.y
        else
            out.climbing = true
        end
    end
end

-- The speed wanted along the leg: never faster than the ship can stop
-- before the point. With the nose off the bearing it stops speeding up
-- (5..20 deg) and holds the speed it has; only a big turn (beyond 60 deg)
-- brakes. A 20 deg gate once threw away 95 b/s over a 25 deg drift
-- (2026-10-15). Returns the wanted speed and the most allowed.
local function leg_speed(g, state, out, err, dist, radius)
    local cfg = g.cfg
    local aerr = math.abs(err)
    local v_now = math.max(0, state.v_fwd or 0)
    local cruise = Nv.cruise_speed(cfg, g.speed)
    local room = dist - radius - v_now * cfg.speed.lead
    if g.pass then room = dist - (g.pass.r or radius) - v_now * cfg.speed.lead + Nv.stop_distance(cfg, g.pass.v, state.mass) end
    local stop_v = Nv.stop_speed(cfg, room, state.mass)
    local v_max = math.min(cruise, stop_v)
    out.braking = stop_v < cruise and stop_v < v_now + 10   -- riding the braking curve: no booster
    if state.v_lift_max then v_max = math.min(v_max, state.v_lift_max) end   -- the props' lift ran short at speed
    local gate = 1
    if aerr > 5 then gate = math.max(0, (20 - aerr) / 15) end
    local v_des = math.min(v_max, v_now + (v_max - v_now) * gate)
    -- the nose drifting off at speed (the hull turns itself sideways above
    -- ~80 b/s and the vectors lose): beyond 10 deg it only holds the speed
    -- it has (so the booster rests and the vectors bring the nose back),
    -- beyond 30 it slows down. Slowing at 10 deg made the cruise pump
    -- between 35 and 115 b/s (2026-10-15).
    if aerr > 10 and v_now > 30 then v_des = math.min(v_des, aerr > 30 and v_now * 0.85 or v_now) end
    if aerr > 60 then v_des = 0 end
    out.gate = gate
    return v_des, v_max
end

-- One step toward the target. Returns {dist, bearing, hdg_err, hdg_sp|nil,
-- alt_sp, target_y, forward, side, v_des, arrived, climbing, descending, ceiling}.
function Nv.step(g, state, alt_sp_now, dt)
    local cfg, pos = g.cfg, state.pos
    if g.start_y == nil then g.start_y = pos.y end
    local dx, dz = g.target.x - pos.x, g.target.z - pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local brg = Nv.bearing(pos, g.target)
    local err = A.wrap180(brg - (state.heading or brg))
    local out = {dist = dist, bearing = brg, hdg_err = err, arrived = false, forward = 0, side = 0}
    local radius = g.radius or cfg.goto_radius   -- g.radius: a tighter one for a dock approach point
    -- the near phase holds until the ship is three times as far out: an
    -- overshoot comes back in 2-D at near_speed instead of turning round in
    -- the far phase and running in again (it circled the point that way
    -- with 70-90 block loops, 2026-10-15)
    local near_r = math.max(3 * radius, cfg.speed.near)
    local near = not g.pass and (dist <= near_r or (g.was_near and dist <= 3 * near_r))
    local target_y = leg_height(g, state, out, dist, near, alt_sp_now, dt)
    if near then return near_phase(g, state, out, dist, radius, dt) end

    g.near_since, g.inside_since = nil, nil
    if g.was_near then g.ctl.f, g.ctl.r = 0, 0; g.was_near = false end
    -- The last 3 x near blocks: straight at the point in 2-D with the nose
    -- held where it was. Steering to the bearing there turned the nose 14 deg
    -- as the bearing swung with a 6 block side offset, the turn took every
    -- nozzle, nothing was left to brake and it ran 42 blocks past the dock
    -- (2026-10-15).
    local final = not g.pass and dist <= 3 * cfg.speed.near
    if final then
        if not g.final_hdg then g.final_hdg = state.heading or brg; g.ctl.f, g.ctl.r = 0, 0 end
        out.hdg_sp = g.final_hdg
    else
        g.final_hdg = nil
        out.hdg_sp = brg
    end

    climb_first(g, state, out, target_y, dt)
    local v_des, v_max = 0, 0
    if not out.climbing then v_des, v_max = leg_speed(g, state, out, err, dist, radius) end
    out.v_des = v_des
    if final and not out.climbing then
        out.v_des = v_max
        out.forward, out.side = Nv.approach2d(cfg, g.ctl, state, g.target, v_max, dt)
        return out
    end
    out.forward, out.side = Nv.speed_step(cfg, g.ctl, v_des, 0, state, dt)
    if g.pass and dist <= (g.pass.r or radius) then out.arrived, out.passed = true, true end
    -- the cross-track correction gets half the side authority (yaw comes first anyway)
    local cap = cfg.limits.thrust_max * (state.vn or 1) * 0.5
    if out.side > cap then out.side = cap elseif out.side < -cap then out.side = -cap end
    return out
end

-- Docking --------------------------------------------------------------------
-- A point saved with a heading is a dock: the ship must end at (x, z) facing
-- hdg. along = signed distance ahead of the dock point along the dock
-- heading (negative = still behind it), side = signed distance to the right.
function Nv.dock_frame(dock, pos)
    local along, side = hull(pos.x - dock.x, pos.z - dock.z, dock.hdg)
    return {along = along, side = side}
end

-- The height the ship lines up over a dock at: the flight height, and at
-- least dock.align_lift above the dock (clear of the buildings around it).
function Nv.dock_align_y(cfg, dock)
    local y = dock.y + cfg.dock.align_lift
    local cruise = cfg.ap and cfg.ap.cruise_y
    if cruise and cruise > y then y = cruise end
    return y
end

-- Height target for the straight descent onto a dock from `sp` (the current
-- target) towards `top`: descend_rate b/s high up, then a braking curve of
-- descend_brake b/s^2 down to descend_min, the target never more than 1 s of
-- that rate below the hull (easing linearly it still came in at 6 b/s 15
-- blocks up and sat down 4 blocks short of the creep height, 2026-10-15); it
-- waits (keeps sp) while the ship is not over the dock and facing it (d from
-- Nv.dock_step; g.down latches within twice the tolerance).
function Nv.dock_descent(cfg, g, d, sp, y, top, dt)
    local dc = cfg.dock
    local tol, hdg = dc.descend_tol, dc.descend_hdg
    if g.down then tol, hdg = 2 * tol, 2 * hdg end
    g.down = math.abs(d.along) <= tol and math.abs(d.side) <= tol and math.abs(d.hdg_err) <= hdg
    if sp <= top then return top end
    if not g.down then return sp end
    local rate = math.max(dc.descend_min, math.min(dc.descend_rate, math.sqrt(2 * dc.descend_brake * math.max(0, y - top))))
    return math.max(top, sp - rate * dt, math.min(sp, y - rate * (dc.descend_lead or 1)))
end

-- Final docking: hold the dock point (2-D) facing dock.hdg. Docked once the
-- ship is still and within the along/side/heading tolerances.
-- Returns {along, side, hdg_err, hdg_sp, forward, side_cmd, docked}.
function Nv.dock_step(cfg, state, dock, g, dt)
    local dc = cfg.dock
    local f = Nv.dock_frame(dock, state.pos)
    local hdg_err = A.wrap180(dock.hdg - (state.heading or dock.hdg))
    local h = Nv.hold2d(cfg, state, {x = dock.x, z = dock.z})
    -- the last tenths: station keeping asks a few % of thrust for them, less
    -- than the legs' friction on the dock (it stayed 0.32 off, 2026-10-17);
    -- off by more than fine_tol and nearly still, push with at least push_min
    local function floor(cmd, e, v)
        if math.abs(e) > dc.fine_tol and math.abs(v) < 0.2 and math.abs(cmd) < dc.push_min then
            return e > 0 and dc.push_min or -dc.push_min
        end
        return cmd
    end
    local fwd, side = floor(h.forward, h.e_fwd, state.v_fwd or 0), floor(h.side, h.e_right, state.v_right or 0)
    local still = (state.speed or 0) < 0.05 and math.abs(f.along) <= dc.tol_along
    g.hold_since = still and ((g.hold_since or 0) + dt) or 0
    return {along = f.along, side = f.side, hdg_err = hdg_err, hdg_sp = dock.hdg, forward = fwd, side_cmd = side,
        docked = still and math.abs(f.side) <= dc.tol_side and math.abs(hdg_err) <= dc.tol_hdg}
end

return Nv
