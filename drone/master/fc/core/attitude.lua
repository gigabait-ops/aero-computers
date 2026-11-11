-- Attitude math for the flight controller: quaternion helpers, body axes,
-- tilt of the world "up" vector in the body frame, tilt rates, heading.
-- Vectors are {x,y,z}; quaternions {x,y,z,w} rotate body -> world.
local A = {}

local function vec(x, y, z) return {x = x, y = y, z = z} end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b)
    return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

local FORWARD = {
    ["+z"] = vec(0, 0, 1), ["-z"] = vec(0, 0, -1),
    ["+x"] = vec(1, 0, 0), ["-x"] = vec(-1, 0, 0),
}
local UP = vec(0, 1, 0)

function A.axes(forward)
    local f = FORWARD[forward]
    if not f then
        error(("unknown forward axis %s (use +z, -z, +x or -x)"):format(tostring(forward)), 2)
    end
    return {up = UP, forward = f, left = cross(UP, f)}
end

function A.normalize(q)
    local n = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    if n == 0 then error("zero quaternion", 2) end
    return {x = q.x / n, y = q.y / n, z = q.z / n, w = q.w / n}
end

function A.conjugate(q)
    return {x = -q.x, y = -q.y, z = -q.z, w = q.w}
end

-- v' = v + 2w (qv x v) + 2 qv x (qv x v)
function A.rotate(q, v)
    local qv = vec(q.x, q.y, q.z)
    local t = cross(qv, v)
    t = vec(2 * t.x, 2 * t.y, 2 * t.z)
    local u = cross(qv, t)
    return vec(v.x + q.w * t.x + u.x, v.y + q.w * t.y + u.y, v.z + q.w * t.z + u.z)
end

local function world_up_in_body(q)
    return A.rotate(A.conjugate(q), UP)
end

-- Components of the world up vector in the body frame.
-- left > 0: left side is high; fwd > 0: nose is high; up ~ 1 when level.
function A.tilt(q, axes)
    local u = world_up_in_body(A.normalize(q))
    return {left = dot(u, axes.left), fwd = dot(u, axes.forward), up = dot(u, axes.up)}
end

-- d/dt of tilt components from the world-frame angular velocity (rad/s).
-- u = R^T up  =>  du/dt = -(omega_body x u)
function A.tilt_rates(q, omega_world, axes)
    q = A.normalize(q)
    local qc = A.conjugate(q)
    local u = A.rotate(qc, UP)
    local wb = A.rotate(qc, omega_world)
    local c = cross(wb, u)
    local udot = vec(-c.x, -c.y, -c.z)
    return {left = dot(udot, axes.left), fwd = dot(udot, axes.forward)}
end

-- Minecraft-style yaw in degrees: 0 faces +z, turning right increases it.
function A.heading(q, axes)
    local f = A.rotate(A.normalize(q), axes.forward)
    return math.deg(math.atan2(-f.x, f.z))
end

-- Heading rate in deg/s, positive when turning right.
function A.yaw_rate(q, omega_world, axes)
    local wb = A.rotate(A.conjugate(A.normalize(q)), omega_world)
    return -math.deg(dot(wb, axes.up))
end

local function qmul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

-- World-frame angular velocity (rad/s) that takes q_prev to q_now in dt:
-- dq = q_now * conj(q_prev), omega ~= 2 * vec(dq) / dt (sign-normalised).
function A.angular_velocity(q_prev, q_now, dt)
    if not dt or dt <= 0 then return vec(0, 0, 0) end
    local dq = qmul(A.normalize(q_now), A.conjugate(A.normalize(q_prev)))
    if dq.w < 0 then dq = {x = -dq.x, y = -dq.y, z = -dq.z, w = -dq.w} end
    local s = math.sqrt(dq.x * dq.x + dq.y * dq.y + dq.z * dq.z)
    if s < 1e-12 then return vec(0, 0, 0) end
    local angle = 2 * math.atan2(s, dq.w)
    local k = angle / s / dt
    return vec(dq.x * k, dq.y * k, dq.z * k)
end

-- Wrap an angle in degrees into (-180, 180].
function A.wrap180(deg)
    local r = deg % 360
    if r > 180 then r = r - 360 end
    return r
end

-- roll_deg, pitch_deg for display (aviation sign: positive roll = left high,
-- positive pitch = nose high).
function A.angles(tilt)
    return math.deg(math.atan2(tilt.left, tilt.up)), math.deg(math.atan2(tilt.fwd, tilt.up))
end

return A
