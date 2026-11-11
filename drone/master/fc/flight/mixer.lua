-- Mixer: one command -> a target per motor.
-- cmd = {collective, roll, pitch, yaw, forward, side}: positive roll raises
-- the left side, positive pitch raises the nose, positive yaw turns the nose
-- right, positive forward pushes ahead, positive side pushes right.
--
-- lift (RSC rpm): quad mix, clamped to limits.lift_min..max_speed, times
--   motor.scale (smaller props need more rpm) and motor.dir.
-- vector (Create Propulsion vector thruster, {thr = 0..1, vx = -1..1, vy}):
--   forward/yaw/side are scaled by thrust_max. Every thruster idles at
--   vector_base; the pair that pushes the wanted way (motor.push "fwd" =
--   nozzle aft) adds the forward demand while the idle of the opposing pair
--   fades out (it only ate thrust). Yaw and side are vectoring: side
--   deflects every nozzle the same way, yaw pushes the front nozzles right
--   and the rear ones left (nose right), with |side + yaw| * vector_side of
--   throttle per thruster; fore/aft parts cancel in pairs. A small throttle
--   couple (vector_yaw) adds to the yaw. motor.side flips a mirrored mount.
--   cmd.counts[id] thrusters on one corner (two since 2026-10-20) share it:
--   the corner's throttle is worked out in one thruster's units as above,
--   may go up to that many, and each gets its share, so a demand gives the
--   same force as with one and the most is that many times more.
-- booster ({thr}): a fixed thruster (ion thruster, ion cube) that only
--   pushes along motor.push; it joins above limits.booster_from of the
--   forward demand, up to limits.booster_gain at full demand, so station
--   keeping, docking and braking never feel it. motor.thr_max caps it.
local M = {}

local LIFT = {
    front_left  = {pitch =  1, roll =  1},
    front_right = {pitch =  1, roll = -1},
    rear_left   = {pitch = -1, roll =  1},
    rear_right  = {pitch = -1, roll = -1},
}
local SIDE = {front_left = 1, rear_left = 1, front_right = -1, rear_right = -1}
M.LIFT = LIFT   -- yaw couple: left side forward = nose right

local function clamp(v, lo, hi)
    if v > hi then return hi elseif v < lo then return lo end
    return v
end

local function lift(motor, limits, cmd, id)
    local m = LIFT[motor.pos]
    if not m then error(("motor %s: unknown lift pos %s"):format(tostring(id), tostring(motor.pos)), 3) end
    local v = (cmd.collective + m.pitch * (cmd.pitch or 0) + m.roll * (cmd.roll or 0)) * (motor.scale or 1)
    return math.floor(clamp(v, limits.lift_min, limits.max_speed) * (motor.dir or 1) + 0.5)
end

-- One vector corner in parts: its throttle without the vectoring (forward
-- demand, idle, yaw couple), the vectoring's own throttle and the nozzle.
local function vector_parts(motor, limits, cmd, id)
    local lr = SIDE[motor.pos]
    if not lr then error(("motor %s: unknown vector pos %s"):format(tostring(id), tostring(motor.pos)), 3) end
    local tm = limits.thrust_max
    local n = cmd.counts and cmd.counts[id] or 1
    local f, y, sd = (cmd.forward or 0) / tm, (cmd.yaw or 0) / tm, (cmd.side or 0) / tm
    local pushes_fwd = (motor.push or (motor.pos:find("rear") and "fwd" or "aft")) == "fwd"
    local base = limits.vector_base or 0.1
    local top = (motor.thr_max or 1) * n
    local thr, couple
    if pushes_fwd then
        thr = (f < 0) and math.max(0, base + f) or (base + f)
        couple = lr * y * (limits.vector_yaw or 0.5)
    else
        thr = (f > 0) and math.max(0, base - f) or (base - f)
        couple = -lr * y * (limits.vector_yaw or 0.5)
    end
    -- yaw first here too: a pair at full keeps room for the couple (braking
    -- hard at full the couple was clipped and the nose went 14-28 deg off,
    -- 2026-10-20)
    thr = math.min(thr, top - math.min(top, math.abs(couple))) + couple
    local fr = motor.pos:find("front") and 1 or -1
    -- yaw first: side gets only what the yaw leaves (at 90 b/s a saturated
    -- cross-track correction took all the vectoring and the nose drifted
    -- 40 deg, 2026-10-15)
    local yaw_part = clamp(y, -n, n)
    local room = n - math.abs(yaw_part)
    sd = clamp(sd, -room, room)
    local want = sd + fr * yaw_part               -- + = push this end to the right
    local vx, add, add_yaw = 0, 0, 0
    if math.abs(want) > (limits.side_deadband or 0.01) then
        vx = clamp((motor.side or 1) * (want > 0 and 1 or -1) * (motor.vmax or 1), -1, 1)
        add = math.min(n, math.abs(want)) * (limits.vector_side or 1)
        add_yaw = math.min(add, math.abs(yaw_part) * (limits.vector_side or 1))
    end
    -- what the corner would get with no forward demand: idle, couple, vectoring
    local idle = clamp(clamp(base + couple, 0, top) + add, 0, top)
    return {n = n, top = top, base = clamp(thr, 0, top), add = add, add_yaw = add_yaw, idle = idle, vx = vx}
end

-- The vectoring throttle (side, yaw) goes on every corner alike so its fore
-- and aft parts cancel in pairs. A pair at full (braking, full ahead) has no
-- room for it: then the side part gets no more than that room on any
-- corner, or the other pair alone pushes against the full one (braking from
-- 70 b/s the rear pair pushed ahead at 5-36 % throughout, 2026-10-20). The
-- yaw part always goes on (yaw first: without it the nose went 14-28 deg
-- off braking hard and 20 deg off at 12 b/s). The nozzles still deflect, so
-- a pair at full steers with its own thrust too.
-- A nozzle turns up to 30 deg: its thrust then points along the mount axis
-- plus tan 30 * vx sideways (Create Propulsion VectorThrusterBlockEntity).
local SIN30, TAN30 = 0.5, math.tan(math.rad(30))

local function vectors(motors, limits, cmd, targets)
    local parts, room = {}, math.huge
    for id, motor in pairs(motors) do
        if motor.role == "vector" then
            local p = vector_parts(motor, limits, cmd, id)
            parts[id] = p
            room = math.min(room, p.top - p.base)
        end
    end
    for id, p in pairs(parts) do
        local thr = clamp(p.base + math.max(p.add_yaw, math.min(p.add, room)), 0, p.top)
        -- limits.vector_prop 1: the nozzle turns only as far as the side force
        -- this demand gets with no forward demand needs (the whole 30 deg
        -- then, as before);
        -- thrust well above that (braking, full ahead) turns it less. Turned
        -- the whole way at any thrust, a tiny correction at full threw half
        -- the corner's thrust sideways: the nose swung +-4 deg and the hull
        -- slid +-10 b/s at 190 b/s (2026-10-20).
        local vx = p.vx
        if vx ~= 0 and (limits.vector_prop or 0) ~= 0 and thr > 0 then
            local s = p.idle * SIN30 / thr
            if s < SIN30 then vx = vx * math.tan(math.asin(s)) / TAN30 end
        end
        targets[id] = {thr = thr / p.n, vx = vx, vy = 0}
    end
end

local function booster(motor, limits, cmd)
    local f = (cmd.forward or 0) / limits.thrust_max
    if (motor.push or "fwd") == "aft" then f = -f end
    local from = limits.booster_from or 0.5
    local thr = 0
    if f > from then thr = (math.min(f, 1) - from) / (1 - from) * (limits.booster_gain or 0.1) end
    -- cmd.booster_cap: the engine's limit (energy running low, heading lost)
    thr = math.min(thr, cmd.booster_cap or 1)
    return {thr = clamp(thr, 0, motor.thr_max or 1), vx = 0, vy = 0}
end

-- Attitude before collective: when a lift motor would run past max_speed
-- (or below lift_min), the collective gives way so every motor keeps its
-- roll/pitch difference instead of one clipping (a clipped front motor let
-- the nose drop). Returns the cmd with the collective that fits.
local function desaturate(motors, limits, cmd)
    local c = cmd.collective
    local hi, lo = c, c
    for _, motor in pairs(motors) do
        local m = motor.role == "lift" and LIFT[motor.pos]
        if m then
            local s = motor.scale or 1
            local diff = m.pitch * (cmd.pitch or 0) + m.roll * (cmd.roll or 0)
            hi = math.min(hi, limits.max_speed / s - diff)
            lo = math.max(lo, limits.lift_min / s - diff)
        end
    end
    if c > hi then c = hi elseif c < lo then c = lo end
    if c == cmd.collective then return cmd end
    local out = {}
    for k, v in pairs(cmd) do out[k] = v end
    out.collective = c
    return out
end

function M.compute(motors, limits, cmd)
    local targets = {}
    cmd = desaturate(motors, limits, cmd)
    for id, motor in pairs(motors) do
        if motor.role == "lift" then targets[id] = lift(motor, limits, cmd, id)
        elseif motor.role == "vector" then -- below, all corners together
        elseif motor.role == "booster" then targets[id] = booster(motor, limits, cmd)
        else error(("motor %s: unknown role %s"):format(tostring(id), tostring(motor.role)), 2) end
    end
    vectors(motors, limits, cmd, targets)
    return targets
end

-- True when any motor is a vector thruster (the ship can move sideways).
function M.has_lateral(motors)
    for _, m in pairs(motors) do if m.role == "vector" then return true end end
    return false
end

-- Lift motors at idle_rpm (dir applied), every thruster off.
function M.idle(motors, idle_rpm)
    local targets = {}
    for id, motor in pairs(motors) do
        if motor.role == "lift" then targets[id] = math.floor((idle_rpm or 0) * (motor.dir or 1) + 0.5) else targets[id] = 0 end
    end
    return targets
end

return M
