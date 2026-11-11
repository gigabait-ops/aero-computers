-- Ship state from CC: Sable's `sublevel` API: pose (position + orientation)
-- every cycle. Linear velocity: with api_velocity from the physics
-- (getLinearVelocity, asked together with the pose so both land in one server
-- tick), else from pose differences over a short window. Those jumped by up
-- to half on a lagging server (34 b/s read between 70s, 290 between 190s,
-- 2026-10-15) and the speed loop and the booster followed every jump.
-- Rotation rates always come from pose differences (the attitude is tuned on them).
local A = require("fc.core.attitude")

local Sn = {}

local VEL_WINDOW = 0.4  -- seconds; poses may only change every other read

-- env = {sublevel = table|nil}
function Sn.new(cfg, env)
    env = env or {}
    return {
        cfg = cfg,
        axes = A.axes(cfg.forward),
        sublevel = env.sublevel,
        parallel = env.parallel,   -- CC's parallel API: several main-thread calls in one tick
        prev = nil,
        hist = {},   -- recent {t, pos} samples for the windowed velocity
    }
end

local function numbers(t, keys)
    if type(t) ~= "table" then return false end
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return false end
    end
    return true
end

local XYZ, XYZW = {"x", "y", "z"}, {"x", "y", "z", "w"}

-- pcall every function, side by side when the parallel API is there.
local function call_all(s, fns)
    local out, jobs = {}, {}
    for i, f in ipairs(fns) do jobs[i] = function() out[i] = {pcall(f)} end end
    if s.parallel and #jobs > 1 then s.parallel.waitForAll(table.unpack(jobs)) else for _, j in ipairs(jobs) do j() end end
    return out
end

local function read_sublevel(s)
    local sub = s.sublevel
    if not sub then return nil, "no sublevel api" end
    local want_vel = s.cfg.api_velocity and sub.getLinearVelocity ~= nil
    local res = call_all(s, want_vel and {sub.getLogicalPose, sub.getLinearVelocity} or {sub.getLogicalPose})
    local ok, pose = res[1][1], res[1][2]
    if not ok then return nil, tostring(pose) end
    if type(pose) ~= "table" or not numbers(pose.position, XYZ) then return nil, "sublevel pose malformed" end
    -- CC: Sable serialises Quaterniond as {a = w, v = {x, y, z}}; accept {x,y,z,w} too.
    local q = pose.orientation
    if type(q) == "table" and type(q.v) == "table" and q.a ~= nil then q = {x = q.v.x, y = q.v.y, z = q.v.z, w = q.a} end
    if not numbers(q, XYZW) then return nil, "sublevel orientation malformed" end
    if q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w < 1e-12 then return nil, "sublevel orientation is a zero quaternion" end
    pose = {position = pose.position, orientation = q}
    if not want_vel then return {pose = pose} end
    local okv, vel = res[2][1], res[2][2]
    if not okv or not numbers(vel, XYZ) then return nil, "sublevel velocity malformed: " .. tostring(vel) end
    return {pose = pose, vel = {x = vel.x, y = vel.y, z = vel.z}}
end

-- Returns state or nil, err.
function Sn.read(s, now)
    local sub, err = read_sublevel(s)
    if not sub then
        s.prev = nil
        return nil, "no sensor: " .. tostring(err)
    end
    local q = sub.pose.orientation
    local p1 = sub.pose.position
    local vel, omega = sub.vel, nil
    local prev = s.prev
    if not vel then
        -- Linear velocity over a window: the logical pose can repeat for a
        -- read or two, so a one-step difference alternates between 0 and 2x.
        local hist = s.hist
        hist[#hist + 1] = {t = now, pos = {x = p1.x, y = p1.y, z = p1.z}}
        while #hist > 1 and now - hist[1].t > VEL_WINDOW + 0.11 do table.remove(hist, 1) end
        local base
        for i = 1, #hist do
            if now - hist[i].t >= VEL_WINDOW - 1e-9 then base = hist[i] end
        end
        if base and now > base.t then
            local dtw = now - base.t
            vel = {x = (p1.x - base.pos.x) / dtw, y = (p1.y - base.pos.y) / dtw, z = (p1.z - base.pos.z) / dtw}
        elseif prev and prev.pos and now > prev.t then
            local dt = now - prev.t
            vel = {x = (p1.x - prev.pos.x) / dt, y = (p1.y - prev.pos.y) / dt, z = (p1.z - prev.pos.z) / dt}
        else
            vel = {x = 0, y = 0, z = 0}
        end
    end
    if prev and prev.q and now > prev.t then
        omega = A.angular_velocity(prev.q, q, now - prev.t)
    else
        omega = {x = 0, y = 0, z = 0}
    end
    local tilt = A.tilt(q, s.axes)
    local roll, pitch = A.angles(tilt)
    local heading = A.heading(q, s.axes)
    local h = math.rad(heading)
    local state = {
        source = "sublevel",
        q = q, pos = p1, vel = vel, omega = omega,
        tilt = tilt,
        rates = A.tilt_rates(q, omega, s.axes),
        heading = heading,
        yaw_rate = A.yaw_rate(q, omega, s.axes),
        roll_deg = roll, pitch_deg = pitch,
        -- velocity in the hull frame (blocks/s): ahead, to the right
        v_fwd = vel.x * -math.sin(h) + vel.z * math.cos(h),
        v_right = vel.x * -math.cos(h) + vel.z * -math.sin(h),
        t = now,
    }
    state.speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
    s.prev = state
    return state
end

return Sn
