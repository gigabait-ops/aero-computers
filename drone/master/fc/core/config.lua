-- Flight controller configuration: defaults, validation, load/merge, atomic save.
-- The ship: four lift props on rotation speed controllers (role "lift"),
-- four Create Propulsion vector thrusters at the corners (role "vector") and
-- any number of fixed boosters (role "booster", e.g. an ion thruster cube).
local C = {}

local FORWARD = {["+z"] = true, ["-z"] = true, ["+x"] = true, ["-x"] = true}
local CORNERS = {front_left = true, front_right = true, rear_left = true, rear_right = true}
local POS = {
    lift = CORNERS,
    vector = CORNERS,
    booster = {rear = true, front = true, center = true},
}

function C.defaults()
    return {
        protocol = "aero.fc.v1",
        modem = "bottom",          -- any modem is found when this one is missing
        forward = "+z",
        motors = {},               -- from fc_config.lua: [id] = {role, pos, dir|push/side}
        limits = {
            max_speed = 256, lift_min = -128,   -- lift RSC rpm range
            thrust_max = 200,                   -- scale of the forward/side/yaw commands (full vector throttle)
            climb_rate = 6,                     -- blocks/s the altitude reference may move
            vector_base = 0.1, vector_yaw = 0.5, vector_side = 1,   -- vector thrusters: idle throttle, yaw couple, throttle per side demand
            vector_prop = 1,                    -- 1: nozzles turn in proportion to the side force wanted; 0: always the whole 30 deg
            booster_from = 0.5, booster_gain = 1.0,                 -- boosters: join above this forward demand, full demand = this throttle
            booster_sustain = 0.3, booster_low = 0.25,              -- below booster_low of its energy a booster is held at the throttle its supply sustains
            booster_min_v = 40, booster_band = 6, booster_slew = 0.3,  -- boosters only for a cruise this fast (b/s), never near a point, landing or docking;
                                                                    -- they fade out over the last booster_band b/s below the wanted speed
        },
        hover = 0, idle = 0,
        trim = {roll = 0, pitch = 0},   -- learned lift differential (rpm; + raises the left side / the nose), saved when the ship leaves ARMED
        pitch_up = {deg = 8, from = 30, full = 90},   -- nose up at speed (b/s): the hull lifts instead of pressing down
        alt_ref_lead = 10,       -- blocks the height reference may run ahead of the hull (a fall climbs back gently)
        attitude_headroom = 16,  -- rpm kept free above the trim for roll/pitch (collective cap); the mixer gives the
                                 -- collective way beyond that (48 left the front at 216 and the rear at 126 of 256
                                 -- when the Aero copy ran short of lift, 2026-10-15)
        rest_margin = 25,        -- "resting": still with the lift this far below hover -> on the ground
        ceiling_s = 3,           -- at the collective cap and not climbing this long -> height target lowered to the hull
        arm_abort_tilt = 0.5,    -- sin(30 deg): ARMED zeroes pilot inputs and lands beyond this tilt
        arm_cut_tilt = 0.87,     -- sin(60 deg): motors cut beyond this tilt
        -- the height loop: the reference's speed fed forward (rpm per b/s) and
        -- its slowing into the setpoint (b/s^2); hover_curve: the hover
        -- collective by height, learned in steady holds ({{y, c}}, fc.flight.controller)
        climb = {ff = 3, brake = 1.0, rate = 14, near = 0.5},   -- rate: b/s the vertical phases may climb (limits.climb_rate stays for the rest)
        hover_curve = {},
        gains = {
            tilt  = {p = 45,  i = 10,  d = 30, i_max = 150},  -- roll; i learns the trim, bounded by i_max rpm (it scales
            pitch = {p = 60,  i = 15,  d = 90, i_max = 150},  -- with the thrust: a nose-heavy ship at height needs 60+)
            alt   = {p = 4,   i = 0.3, d = 8},
            yaw   = {p = 5,   i = 1,   d = 14, i_max = 100},   -- i: the steady yaw moment of the booster at speed
        },
        rate_filter = 0.5,       -- EMA factor for the D-term rates (1 = unfiltered)
        loop_hz = 20, telemetry_timeout = 3.0,   -- (each node falls back to its fallback after 1 s without a set)
        sensor_timeout = 0.5,
        heading_hold = true,
        api_velocity = true,     -- linear velocity from the physics (smooth); false: from pose differences
        -- speed control (blocks/s): PI on the velocity in the hull frame
        speed = {
            kp = 100, ki = 10,           -- thrust per b/s of error, per b/s*s (40 braked at a third and overshot 20 blocks)
            lead = 1.0,                  -- s: the braking curve is planned this much ahead (the motors' lag)
            near = 30, near_speed = 6,   -- the last `near` blocks: straight at the point in 2-D (no turning), at most near_speed b/s
            max = 0,                     -- fastest the ship flies (b/s); 0 = no limit (full thrust)
            brake_a0 = 1.7, brake_c = 0.00095,  -- braking: a = a0 + k*v + c*v^2 b/s^2 (front pair in reverse + drag); measured 2026-10-15 with six engines aboard: 150 -> 52 b/s in 10 s, 52 -> 21.5 in 10 s, 21.5 -> 9.6 in 6 s
            brake_k = 0,                 -- the drag term that grows with the speed (Aero 2026-10-20: a0 1.2, k 0.088, c 0)
            margin = 0.7,                -- plan with this share of the braking deceleration
            brake_mass = 0,              -- the ship's mass (Sable) when brake_a0/brake_c were measured: the braking
                                         -- then follows the live mass (cargo, fuel); 0 = not scaled
        },
        -- station keeping (2-D, no turning)
        hold_vk = 0.3, hold_vmax = 0.8, hold_a = 80, hold_max = 200, hold2d_deadband = 0.2,
        -- autopilot
        ap = {speed = 0, cruise_y = -30, arrive = "hold", takeoff = 6},   -- speed in b/s (0 = as fast as it goes), flight height
        waypoints = {},          -- {name, x, y, z[, hdg]}; hdg = a dock there facing it
        routes = {},             -- {name, laps, finish, points = {{name, x, y, z[, hdg], height, speed, wait, act}}} (fc.data.routes)
        ui = {buttons = "plain"},   -- the screens' button style, the glasses too (fc.ui.kitpage P.STYLES)
        ground_detectors = false,   -- distance_detector readings count for the height above the ground (after a check: fc.lua)
        goto_radius = 5, goto_near_timeout = 45, goto_alt_tol = 2,
        goto_climb = 2.5, goto_climb_up = 4, goto_climb_gate = 3, goto_climb_stall = 8, goto_min_alt = 3,
        goto_local = 64,         -- legs shorter than this keep the point's height (no climb to the flight height)
        takeoff_timeout = 40,
        -- docking: over the dock at the flight height (at least align_lift above it), turned to face it at
        -- turn_rate deg/s, then braking at descend_brake b/s^2
        -- straight down at up to descend_rate b/s (descend_min near it) while within descend_tol blocks and
        -- descend_hdg deg of it, the height target descend_lead s of that rate below the hull; the last
        -- creep_lift blocks settle at settle_rate. turn_early 1: the last blocks of the way in already
        -- turn to the dock heading (at turn_rate), so it is lined up on arrival
        dock = {approach_radius = 3, align_lift = 20, turn_rate = 15, descend_rate = 6, descend_brake = 0.3, descend_min = 0.5, descend_tol = 1, descend_hdg = 10,
                descend_lead = 1, turn_early = 1,
                creep_lift = 4, settle_rate = 0.5,
                tol_along = 0.2, tol_side = 0.3, tol_hdg = 3, fine_tol = 0.1, push_min = 30,   -- over the dock: off by more than fine_tol, push at least push_min
                tol_level = 0.035,   -- sin 2 deg: the settle starts only this level (nose up 5 deg it sat on its rear legs)
                auto_off = 1, off_after = 1.5,   -- settled onto the dock (held up, still) this long -> motors off
                locked_after = 4},   -- docked once, then lifting and not moving at all this long: the connector holds it -> motors off
        -- manual flight (linked typewriter)
        input_speed_step = 2,    -- W/S: b/s per tap (held keys repeat and accelerate)
        input_speed_lead = 60,   -- W never sets more than this above the speed the ship has (above booster_min_v
                                 -- from a standstill: 20 kept the cube off and the vectors alone crawl)
        input_side_speed = 3,    -- arrows held: sideways b/s
        input_alt_step = 1, input_alt_lead = 30,
        input_repeat_delay = 0.4, input_repeat = 0.25, input_accel_max = 5,
        input_turn_min = 40,     -- A/D: yaw demand at the first moment; held, it grows to full thrust over
        input_turn_ramp = 2,     -- this many seconds (a long press = a hard turn), the turn kept under
        input_turn_rate = 45,    -- this many degrees per second
        turn_brake = 40, turn_settle_rate = 1, turn_settle_time = 10,
        -- redstone links through a CC Redstone Link Bridge: two item ids per
        -- frequency, BOTH filled (the bridge silently sends nothing on a
        -- frequency with an empty slot: the engine link never worked, 2026-10-15)
        links = {},   -- e.g. clutch = {"<item id>", "<item id>"}, gear = {...} (see fc_config.lua)
        gear_height = 10,
        -- optical sensors pointing down (height above the ground)
        ground_zero = -1,        -- their reading on the legs (learned on the ground; -1 = not yet): the lowest
        ground_zeros = {},       -- each sensor's own ({["133:optical_sensor_4"] = 1.2, ...}; learned with ground_zero)
        ground_range = 15,       -- their range in blocks near the ground (the server's optical_sensor_max_range caps it;
                                 -- high in the air they are cut to 1 block: the beam cannot be switched off)
        terrain_clear = 8,       -- en route: never closer than this above the ground under the ship
        -- landing while a sensor sees the ground: a braking curve down to it
        -- (b/s = sqrt(2 * brake * height)), between min and max b/s; higher up
        -- (nothing seen, and nothing remembered within ground_range) as fast as
        -- still stops within ground_range - margin once the ground comes into
        -- view; else the slow steps of fc.flight.tasks (T.LAND_RATES).
        -- Flown 2026-10-23: 60 blocks in 18 s at max 6 (21 s at 4, ~45 before).
        land_fast = {max = 6, brake = 0.3, min = 0.5, margin = 10},
        monitor_enabled = true,
        log = false,             -- /fc.log while testing (`log on`); the black box works either way
        remote = {ids = {}, key = ""},   -- the owner's pocket computer(s) and their shared key (fc.remote)
    }
end

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep_copy(x) end
    return out
end

-- Nested tables merge per key; these are replaced wholesale so an entry
-- removed from the file disappears instead of resurrecting from defaults.
local WHOLE = {motors = true, waypoints = true, routes = true, links = true, home = true, input_keys = true, baseline = true, remote = true,
    hover_curve = true, ground_zeros = true}

-- A route point's action and what a route does after its last lap (fc.data.routes).
C.ROUTE_ACTS = {stop = true, pass = true, land = true, dock = true}
C.ROUTE_FINISH = {hold = true, land = true, home = true}
C.BUTTON_STYLES = {"plain", "plain-white", "plain-dim", "paren", "brace", "bar", "dot", "angle", "chevron", "tonal-cap", "tint", "frame"}   -- as fc.ui.kitpage P.STYLES: the label centred (owner 2026-10-23)
local function merge(base, over)
    local out = deep_copy(base)
    for k, v in pairs(over) do
        if WHOLE[k] then
            out[k] = deep_copy(v)
        elseif type(v) == "table" and type(out[k]) == "table" then
            out[k] = merge(out[k], v)
        else
            out[k] = deep_copy(v)
        end
    end
    return out
end

local function is_num(v) return type(v) == "number" and v == v end

-- Numbers that must be present (defaults always provide them).
local NUMBERS = {"hover", "idle", "alt_ref_lead", "attitude_headroom", "rest_margin", "ceiling_s", "arm_abort_tilt", "arm_cut_tilt",
    "telemetry_timeout", "sensor_timeout",
    "hold_vk", "hold_vmax", "hold_a", "hold_max", "hold2d_deadband",
    "goto_radius", "goto_near_timeout", "goto_alt_tol", "goto_climb", "goto_climb_up", "goto_climb_gate", "goto_climb_stall", "goto_min_alt",
    "goto_local", "takeoff_timeout",
    "input_speed_step", "input_speed_lead", "input_side_speed", "input_alt_step", "input_alt_lead", "input_repeat_delay", "input_repeat", "input_accel_max",
    "input_turn_min", "input_turn_ramp", "input_turn_rate", "turn_brake", "turn_settle_rate", "turn_settle_time", "gear_height", "ground_zero", "ground_range", "terrain_clear"}

function C.validate(cfg)
    if type(cfg) ~= "table" then return nil, "config must be a table" end
    if not FORWARD[cfg.forward] then return nil, "forward must be one of +z, -z, +x, -x" end
    if type(cfg.protocol) ~= "string" or type(cfg.modem) ~= "string" then return nil, "protocol and modem must be strings" end
    if type(cfg.motors) ~= "table" then return nil, "motors must be a table" end
    local rm = cfg.remote
    if type(rm) ~= "table" or type(rm.ids) ~= "table" or type(rm.key) ~= "string" then return nil, "remote must be {ids = {...}, key = \"...\"}" end
    for _, id in ipairs(rm.ids) do
        if type(id) ~= "number" then return nil, "remote ids must be computer ids" end
    end
    local seen, lift = {lift = {}, vector = {}}, 0
    for id, m in pairs(cfg.motors) do
        if type(id) ~= "number" then return nil, "motor id must be a number" end
        if type(m) ~= "table" then return nil, "motor " .. id .. " must be a table" end
        local allowed = POS[m.role]
        if not allowed then return nil, "motor " .. id .. ": role must be lift, vector or booster" end
        if not allowed[m.pos] then return nil, "motor " .. id .. ": invalid pos " .. tostring(m.pos) end
        if m.role == "lift" then
            lift = lift + 1
            if m.dir ~= 1 and m.dir ~= -1 then return nil, "motor " .. id .. ": dir must be 1 or -1" end
            if m.scale ~= nil and (not is_num(m.scale) or m.scale <= 0) then return nil, "motor " .. id .. ": scale must be a positive number" end
        else
            if m.push ~= nil and m.push ~= "fwd" and m.push ~= "aft" then return nil, "motor " .. id .. ": push must be fwd or aft" end
            if m.side ~= nil and m.side ~= 1 and m.side ~= -1 then return nil, "motor " .. id .. ": side must be 1 or -1" end
            if m.thr_max ~= nil and (not is_num(m.thr_max) or m.thr_max < 0 or m.thr_max > 1) then return nil, "motor " .. id .. ": thr_max must be 0..1" end
        end
        if seen[m.role] then
            if seen[m.role][m.pos] then return nil, ("motors %d and %d share pos %s"):format(seen[m.role][m.pos], id, m.pos) end
            seen[m.role][m.pos] = id
        end
    end
    if lift == 0 then return nil, "motors: no lift motor configured (fc_config.lua)" end
    for _, name in ipairs(NUMBERS) do
        if not is_num(cfg[name]) then return nil, name .. " must be a number" end
    end
    if not is_num(cfg.loop_hz) or cfg.loop_hz < 1 then return nil, "loop_hz must be >= 1" end
    if type(cfg.limits) ~= "table" then return nil, "limits must be a table" end
    for _, name in ipairs({"max_speed", "lift_min", "thrust_max", "climb_rate", "vector_base", "vector_yaw", "vector_side", "vector_prop", "booster_from", "booster_gain", "booster_sustain", "booster_low", "booster_min_v", "booster_band", "booster_slew"}) do
        if not is_num(cfg.limits[name]) then return nil, "limits." .. name .. " must be a number" end
    end
    if cfg.limits.climb_rate <= 0 then return nil, "limits.climb_rate must be positive" end
    if cfg.limits.booster_from < 0 or cfg.limits.booster_from >= 1 then return nil, "limits.booster_from must be 0..0.99" end
    if cfg.limits.booster_gain < 0 or cfg.limits.booster_gain > 1 then return nil, "limits.booster_gain must be 0..1" end
    if type(cfg.gains) ~= "table" then return nil, "gains must be a table" end
    for _, loop in ipairs({"tilt", "pitch", "alt", "yaw"}) do
        local g = cfg.gains[loop]
        if type(g) ~= "table" or not is_num(g.p) or not is_num(g.i) or not is_num(g.d) then return nil, "gains." .. loop .. " must be {p, i, d}" end
    end
    local pu = cfg.pitch_up
    if type(pu) ~= "table" or not is_num(pu.deg) or not is_num(pu.from) or not is_num(pu.full) or pu.full <= pu.from or pu.deg < 0 or pu.deg > 20 then
        return nil, "pitch_up must be {deg 0..20, from, full > from}"
    end
    if type(cfg.speed) ~= "table" then return nil, "speed must be a table" end
    for _, name in ipairs({"kp", "ki", "max", "brake_a0", "brake_c", "brake_k", "margin", "lead", "near", "near_speed", "brake_mass"}) do
        if not is_num(cfg.speed[name]) then return nil, "speed." .. name .. " must be a number" end
    end
    if cfg.speed.brake_a0 <= 0 then return nil, "speed.brake_a0 must be positive" end
    if cfg.speed.brake_k < 0 or cfg.speed.brake_c < 0 then return nil, "speed.brake_k and brake_c must not be negative" end
    if type(cfg.trim) ~= "table" or not is_num(cfg.trim.roll) or not is_num(cfg.trim.pitch) then return nil, "trim must be {roll, pitch}" end
    if cfg.trim.coll ~= nil and not (is_num(cfg.trim.coll) and cfg.trim.coll > 0) then return nil, "trim.coll must be a positive number" end
    if type(cfg.api_velocity) ~= "boolean" then return nil, "api_velocity must be true or false" end
    if type(cfg.heading_hold) ~= "boolean" then return nil, "heading_hold must be true or false" end
    if type(cfg.monitor_enabled) ~= "boolean" then return nil, "monitor_enabled must be true or false" end
    if type(cfg.log) ~= "boolean" then return nil, "log must be true or false" end
    if not is_num(cfg.rate_filter) or cfg.rate_filter <= 0 or cfg.rate_filter > 1 then return nil, "rate_filter must be in (0, 1]" end
    if cfg.input_keys ~= nil then
        if type(cfg.input_keys) ~= "table" then return nil, "input_keys must be a table" end
        for action, code in pairs(cfg.input_keys) do
            if not is_num(code) then return nil, "input_keys." .. tostring(action) .. " must be a key code" end
        end
    end
    if type(cfg.links) ~= "table" then return nil, "links must be a table" end
    for name, spec in pairs(cfg.links) do
        if type(spec) ~= "table" or type(spec[1]) ~= "string" or type(spec[2]) ~= "string" then
            return nil, "links." .. tostring(name) .. " must be {item id, item id}"
        end
        if spec[1] == "" or spec[2] == "" then
            return nil, "links." .. tostring(name) .. ": both slots need an item (the link bridge cannot send with an empty slot)"
        end
        if spec.invert ~= nil and type(spec.invert) ~= "boolean" then return nil, "links." .. tostring(name) .. ".invert must be true or false" end
    end
    if cfg.baseline ~= nil then   -- what RESET goes back to: {hover, trim = {roll, pitch}}
        local b = cfg.baseline
        if type(b) ~= "table" or not is_num(b.hover) or type(b.trim) ~= "table" or not is_num(b.trim.roll) or not is_num(b.trim.pitch) then
            return nil, "baseline must be {hover, trim = {roll, pitch}} numbers"
        end
    end
    if cfg.home ~= nil then
        local h = cfg.home
        if type(h) ~= "table" or not is_num(h.x) or not is_num(h.y) or not is_num(h.z) then return nil, "home must be {x, y, z} numbers" end
        if h.hdg ~= nil and not is_num(h.hdg) then return nil, "home.hdg must be a number" end
    end
    local ap = cfg.ap
    if type(ap) ~= "table" or not is_num(ap.speed) or not is_num(ap.cruise_y) or not is_num(ap.takeoff) then
        return nil, "ap must be {speed, cruise_y, takeoff, arrive}"
    end
    if ap.speed < 0 then return nil, "ap.speed must be >= 0 (0 = as fast as it goes)" end
    if ap.arrive ~= "hold" and ap.arrive ~= "land" then return nil, "ap.arrive must be hold or land" end
    if type(cfg.dock) ~= "table" then return nil, "dock must be a table" end
    for k, v in pairs(cfg.dock) do if not is_num(v) then return nil, "dock." .. tostring(k) .. " must be a number" end end
    if type(cfg.waypoints) ~= "table" then return nil, "waypoints must be a list" end
    for i, wp in ipairs(cfg.waypoints) do
        if type(wp) ~= "table" or type(wp.name) ~= "string" or not is_num(wp.x) or not is_num(wp.y) or not is_num(wp.z) then
            return nil, "waypoint " .. i .. " must be {name, x, y, z}"
        end
        if wp.hdg ~= nil and not is_num(wp.hdg) then return nil, "waypoint " .. i .. ": hdg must be a number" end
    end
    local cl = cfg.climb
    if type(cl) ~= "table" or not (is_num(cl.ff) and is_num(cl.brake) and is_num(cl.rate)) or cl.ff < 0 or cl.brake < 0 or cl.rate <= 0 then
        return nil, "climb must be {ff >= 0, brake >= 0, rate > 0}"
    end
    if type(cfg.ground_zeros) ~= "table" then return nil, "ground_zeros must be a table" end
    for name, z in pairs(cfg.ground_zeros) do
        if type(name) ~= "string" or not is_num(z) then return nil, "ground_zeros: a sensor name and its zero" end
    end
    if type(cfg.hover_curve) ~= "table" then return nil, "hover_curve must be a list" end
    for i, p in ipairs(cfg.hover_curve) do
        if type(p) ~= "table" or not is_num(p.y) or not is_num(p.c) or p.c <= 0 then return nil, "hover_curve point " .. i .. " must be {y, c > 0}" end
        if i > 1 and p.y <= cfg.hover_curve[i - 1].y then return nil, "hover_curve must go up in y" end
    end
    local lf = cfg.land_fast
    if type(lf) ~= "table" or not (is_num(lf.max) and is_num(lf.brake) and is_num(lf.min) and is_num(lf.margin)) or lf.brake <= 0 or lf.min <= 0 or lf.max < 0 then
        return nil, "land_fast must be {max >= 0 (0 = off), brake > 0, min > 0, margin}"
    end
    local style_ok = false
    for _, st in ipairs(C.BUTTON_STYLES) do if cfg.ui and cfg.ui.buttons == st then style_ok = true end end
    if not style_ok then return nil, "ui.buttons must be one of " .. table.concat(C.BUTTON_STYLES, ", ") end
    if type(cfg.routes) ~= "table" then return nil, "routes must be a list" end
    for i, r in ipairs(cfg.routes) do
        if type(r) ~= "table" or type(r.name) ~= "string" or type(r.points) ~= "table" then return nil, "route " .. i .. " must be {name, points}" end
        if r.laps ~= nil and not (is_num(r.laps) and r.laps >= 0) then return nil, "route " .. r.name .. ": laps must be 0 (loop) or more" end
        if r.finish ~= nil and not C.ROUTE_FINISH[r.finish] then return nil, "route " .. r.name .. ": finish must be hold, land or home" end
        for j, pt in ipairs(r.points) do
            if type(pt) ~= "table" or type(pt.name) ~= "string" or not is_num(pt.x) or not is_num(pt.y) or not is_num(pt.z) then
                return nil, ("route %s point %d must be {name, x, y, z}"):format(r.name, j)
            end
            for _, f in ipairs({"hdg", "height", "speed", "wait"}) do
                if pt[f] ~= nil and not is_num(pt[f]) then return nil, ("route %s point %d: %s must be a number"):format(r.name, j, f) end
            end
            if pt.act ~= nil and not C.ROUTE_ACTS[pt.act] then return nil, ("route %s point %d: act must be stop, pass, land or dock"):format(r.name, j) end
            if pt.act == "dock" and pt.hdg == nil then return nil, ("route %s point %d: a dock needs a heading"):format(r.name, j) end
        end
    end
    return true
end

-- Older configs: the cruise speed was a thrust in rpm (up to 256); speeds
-- are blocks/s now (the setting goes up to 200), so more than that means
-- "as fast as it goes".
local function migrate(user)
    if type(user.ap) == "table" and is_num(user.ap.speed) and user.ap.speed > 200 then user.ap.speed = 0 end
    -- a button style no longer offered (filled, tonal: 2026-10-23) is plain again
    if type(user.ui) == "table" and user.ui.buttons ~= nil then
        local known = false
        for _, st in ipairs(C.BUTTON_STYLES) do if user.ui.buttons == st then known = true end end
        if not known then user.ui.buttons = "plain" end
    end
    -- point names start with a capital letter (owner, 2026-10-15)
    if type(user.waypoints) == "table" then
        for _, wp in ipairs(user.waypoints) do
            if type(wp) == "table" and type(wp.name) == "string" then wp.name = wp.name:sub(1, 1):upper() .. wp.name:sub(2) end
        end
    end
    -- a link frequency with one empty slot: the bridge cannot send on it, the
    -- other item fills it (put the same item in the link's empty slot)
    if type(user.links) == "table" then
        for _, spec in pairs(user.links) do
            if type(spec) == "table" and type(spec[1]) == "string" and type(spec[2]) == "string" then
                if spec[1] == "" then spec[1] = spec[2] elseif spec[2] == "" then spec[2] = spec[1] end
            end
        end
    end
    if type(user.motors) == "table" then
        for _, m in pairs(user.motors) do
            if type(m) == "table" and m.role == "thrust" then return "role thrust is gone (old ship): use vector or booster" end
        end
    end
    return nil
end

-- Returns cfg, err. Missing file -> defaults + "no motors" error. Any problem -> defaults, message.
function C.load(path)
    local d = C.defaults()
    local user = {}
    if fs.exists(path) then
        local h = fs.open(path, "r")
        if not h then return d, "cannot open " .. path end
        local text = h.readAll() or ""
        h.close()
        local chunk, perr = load(text, path, "t", {})
        if not chunk then return d, "config syntax: " .. tostring(perr) end
        local ok, u = pcall(chunk)
        if not ok then return d, "config error: " .. tostring(u) end
        if type(u) ~= "table" then return d, "config must return a table" end
        user = u
    end
    local merr = migrate(user)
    if merr then return d, "config invalid: " .. merr end
    local cfg = merge(d, user)
    local valid, verr = C.validate(cfg)
    if not valid then return d, "config invalid: " .. verr end
    return cfg, nil
end

-- Only what differs from the defaults is saved, so a code update's new
-- defaults apply unless a field was set on purpose. Unknown keys are dropped;
-- the WHOLE tables are always written whole.
local function diff(cur, def)
    local out = {}
    for k, v in pairs(cur) do
        if WHOLE[k] then
            out[k] = deep_copy(v)
        elseif def[k] == nil then
            -- stale key from an older version: drop
        elseif type(v) == "table" and type(def[k]) == "table" then
            local sub = diff(v, def[k])
            if next(sub) ~= nil then out[k] = sub end
        elseif v ~= def[k] then
            out[k] = deep_copy(v)
        end
    end
    return out
end

function C.diff(cfg)
    return diff(cfg, C.defaults())
end

function C.save(path, cfg)
    local tmp = path .. ".tmp"
    local h, err = fs.open(tmp, "w")
    if not h then return nil, err or ("cannot write " .. tmp) end
    h.write("-- Aero flight controller config: only values that differ from the fc/config.lua defaults.\n"
        .. "-- Written by the master on every change; edit by hand only while `fc run` is stopped.\n"
        .. "return " .. textutils.serialize(C.diff(cfg)))
    h.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

C.deep_copy = deep_copy
return C
