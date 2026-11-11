-- aero.fc.v1 node firmware: applies the master's targets to the actuator
-- next to this PC and falls back when the master goes quiet. Two kinds:
--   rsc      a Create Rotation Speed Controller driving a propeller: the
--            target is an rpm number, the fallback the last hover value
--   thruster Create Propulsion thrusters (vector_thruster, thruster, ...):
--            the target is {thr = 0..1, vx = , vy = } (throttle and vector),
--            the fallback is throttle 0. Every thruster on the PC gets the
--            same target (two vectors on one corner, 2026-10-20), applied
--            side by side: their set calls wait for a server tick each
--            (mainThread), so one after the other would double the lag.
--            Thrusters placed or removed later are picked up (peripheral
--            events); telemetry counts them, the master shares the throttle.
-- Deployed byte-identically to every node by tools/deploy.sh nodes. The
-- peripheral calls run in their own coroutine so a slow or stuck call never
-- silences telemetry; only problems (no modem or actuator, a failed apply,
-- the watchdog, a crash) go to /node.log. `startup probe` prints
-- the actuator's methods and the clamp limits of its vector/throttle.
-- Optical sensors (Create Simulated) on the PC's network are the master's
-- ground sensors too (fw 1.8.0, the rear pair on PC 133, 2026-10-24): set to
-- the range the master sends with every set (`gr`), read in their own
-- coroutine and sent four times a second as a "ground" message.
local N = {}

N.VERSION = "1.8.0"
N.PROTOCOL = "aero.fc.v1"
N.TYPES = {SET = "set", IDLE = "idle", HELLO = "hello", TELEMETRY = "telemetry", GROUND = "ground"}
N.OPTICAL_TYPE = "optical_sensor"
N.MODEM_SIDE = "bottom"
N.RSC_SIDE = "back"
N.RSC_TYPE = "Create_RotationSpeedController"
N.THRUSTER_TYPES = {vector_thruster = true, liquid_vector_thruster = true, creative_vector_thruster = true,
                    thruster = true, solid_fuel_thruster = true, ion_thruster = true, creative_thruster = true}
N.LOG_PATH = "/node.log"
N.LOG_LIMIT = 32 * 1024

function N.new(id, opts)
    opts = opts or {}
    return {
        id = id,
        timeout = opts.timeout or 1.0,
        mode = "idle",       -- idle | live | fallback
        target = nil,
        fallback = nil,
        seq = nil,
        last_set = nil,
        rsc_ok = false,           -- an actuator (RSC or thruster) is attached
        kind = "rsc",             -- rsc | thruster (see N.THRUSTER_TYPES)
        vector = false,           -- thruster with a steerable vector
        count = 0,                -- thrusters on this PC
        applied = nil,            -- last value the RSC accepted
        apply_pending_since = nil, -- os.clock() when a setTargetSpeed call started
        apply_err = nil,
    }
end

-- The RSC block keeps its target speed across a PC reboot. Read it at boot so
-- telemetry's `applied` says what the motor really does before the first
-- command: a master that boots to running lift motors takes over (auto-resume).
function N.boot_rpm(rsc)
    if not rsc or not rsc.getTargetSpeed then return nil end
    local ok, rpm = pcall(rsc.getTargetSpeed)
    if ok and type(rpm) == "number" then return rpm end
    return nil
end

-- A thruster target is {thr, vx, vy}; a bare number means throttle only
-- (idle sends 0 for every id).
local function thruster_target(v)
    if type(v) == "number" then return {thr = math.max(0, math.min(1, v)), vx = 0, vy = 0} end
    if type(v) ~= "table" then return nil end
    return {thr = math.max(0, math.min(1, tonumber(v.thr) or 0)), vx = tonumber(v.vx) or 0, vy = tonumber(v.vy) or 0}
end

-- Returns the value to apply (rpm number, or a thruster table), or nil when
-- the message changes nothing.
function N.handle(st, msg, now)
    if type(msg) ~= "table" or type(msg.targets) ~= "table" then return nil end
    if type(msg.gr) == "number" then st.ground_range = msg.gr end   -- the optical sensors' range the master wants
    local target = msg.targets[st.id]
    if st.kind == "thruster" then
        target = thruster_target(target)
        if target == nil then return nil end
    elseif type(target) ~= "number" then
        return nil
    end
    if msg.type == N.TYPES.SET then
        st.target = target
        if st.kind == "thruster" then
            st.fallback = {thr = 0, vx = 0, vy = 0}   -- a quiet master: thrust off
        elseif type(msg.fallback) == "table" and type(msg.fallback[st.id]) == "number" then
            st.fallback = msg.fallback[st.id]
        end
        st.last_set = now
        st.seq = msg.seq
        st.mode = "live"
        return target
    elseif msg.type == N.TYPES.IDLE then
        st.target = target
        st.last_set = nil
        st.seq = msg.seq
        st.mode = "idle"
        return target
    end
    return nil
end

-- Watchdog: once per silence, drop to the fallback value.
function N.tick(st, now)
    if st.mode == "live" and st.last_set and now - st.last_set > st.timeout then
        st.mode = "fallback"
        if st.fallback ~= nil then          -- rsc: hover rpm; thruster: {thr = 0}
            st.target = st.fallback
            return st.fallback
        end
    end
    return nil
end

local function fmt_target(v)
    if type(v) == "table" then return ("thr %.2f vx %.2f vy %.2f"):format(v.thr or 0, v.vx or 0, v.vy or 0) end
    return v
end

function N.telemetry(st)
    return {
        type = N.TYPES.TELEMETRY, id = st.id, seq = st.seq, target = fmt_target(st.target),
        rsc_ok = st.rsc_ok, kind = st.kind, vector = st.vector, count = st.count, mode = st.mode,
        applied = fmt_target(st.applied), apply_pending = st.apply_pending_since ~= nil, apply_err = st.apply_err,
        stress = st.stress,   -- {su, cap, over} from a Create Stressometer next to this PC, if any
        thrust = st.thrust,   -- thruster: {kn, vx, vy} as the thrusters report them (kn summed)
        limits = st.limits,   -- thruster: vector clamp limits found at boot
    }
end

-- Thruster telemetry: current thrust (summed) and the first one's vector
-- (every second, pcall'd; the getters do not wait for a tick).
function N.read_thrusters(st, devs)
    if not devs or #devs == 0 then return end
    local kn, fe, cap, vx, vy
    for i, d in ipairs(devs) do
        local dev = d.dev
        local getT = dev.getThrust or dev.getCurrentThrustKN
        local okk, k = pcall(getT or error, 1)
        if okk and type(k) == "number" then kn = (kn or 0) + k end
        if i == 1 then
            local getX, getY = dev.getVectorX or dev.getCurrentVectorX, dev.getVectorY or dev.getCurrentVectorY
            local okx, x = pcall(getX or error, 1)
            local oky, y = pcall(getY or error, 1)
            vx, vy = okx and x or nil, oky and y or nil
        end
        if dev.getEnergyAmountFe then   -- ion thrusters: the energy buffer (a cube holds 4000 FE per block)
            local oke, e = pcall(dev.getEnergyAmountFe)
            local okc, c = pcall(dev.getEnergyCapacityFe or error)
            if oke and type(e) == "number" then fe = (fe or 0) + e end
            if okc and type(c) == "number" then cap = (cap or 0) + c end
        end
    end
    st.thrust = {kn = kn, vx = vx, vy = vy, fe = fe, fe_cap = cap}
end

-- A Create Stressometer attached to this PC reports the kinetic network's
-- stress (the master shows power loss: twice the ship fell with full lift
-- commanded, 2026-10-08). Looked up every 5 s until found; read every second.
N.STRESS_TYPE = "Create_Stressometer"
function N.read_stress(st, now)
    local per = _G.peripheral
    if not per then st.stress = nil; return end
    if not st.stressometer and now - (st.stress_find or -math.huge) >= 5 then
        st.stress_find = now
        local ok, sm = pcall(per.find, N.STRESS_TYPE)
        if ok and sm then st.stressometer = sm end
    end
    local sm = st.stressometer
    if not sm then st.stress = nil; return end
    local ok1, su = pcall(sm.getStress)
    local ok2, cap = pcall(sm.getStressCapacity)
    local ok3, over = pcall(sm.getOverstressed)
    if ok1 and ok2 then
        st.stress = {su = su, cap = cap, over = (ok3 and over == true) or (type(su) == "number" and type(cap) == "number" and su > cap)}
    else
        st.stressometer = nil; st.stress = nil
    end
end

function N.hello(st)
    return {type = N.TYPES.HELLO, id = st.id, rsc = st.rsc_ok, kind = st.kind, vector = st.vector, count = st.count, version = N.VERSION}
end

-- Apply one thruster target: throttle 0..1 (setThrottleNormalized, else
-- setPower 0..15) and, for vector thrusters, the vector.
-- The owner's Vector Thrusters (Create Propulsion 2026-10) expose
-- setPowerNormalized(0..1), setPower(0..15), setVector(x, y) with x, y in
-- -1..1, getThrust, getVectorX/Y; other variants may only have the older names.
function N.apply_thruster(dev, v)
    if dev.setPowerNormalized then dev.setPowerNormalized(v.thr)
    elseif dev.setThrottleNormalized then dev.setThrottleNormalized(v.thr)
    elseif dev.setPower then dev.setPower(math.floor(v.thr * 15 + 0.5)) end
    if dev.setVector then dev.setVector(v.vx, v.vy)
    elseif dev.setVectorCoordinates then dev.setVectorCoordinates(v.vx, v.vy)
    elseif dev.setVectorX then dev.setVectorX(v.vx); if dev.setVectorY then dev.setVectorY(v.vy) end end
end

-- Every thruster on the PC: {{dev, name, type}, ...} in peripheral.getNames order.
function N.find_thrusters(per)
    local out = {}
    for _, name in ipairs(per.getNames()) do
        local t = per.getType(name)
        if N.THRUSTER_TYPES[t] then out[#out + 1] = {dev = per.wrap(name), name = name, type = t} end
    end
    return out
end

-- Every optical sensor on the PC: {{dev, name}, ...}.
function N.find_optical(per)
    local out = {}
    for _, name in ipairs(per.getNames()) do
        if per.getType(name) == N.OPTICAL_TYPE then out[#out + 1] = {dev = per.wrap(name), name = name} end
    end
    return out
end

-- Their hits: {{name, d}, ...} (a sensor that sees nothing is left out).
function N.read_optical(sensors)
    local out = {}
    for _, s in ipairs(sensors) do
        local okh, hit = pcall(s.dev.hasHit)
        if okh and hit then
            local okd, d = pcall(s.dev.getDistance)
            if okd and type(d) == "number" then out[#out + 1] = {name = s.name, d = d} end
        end
    end
    return out
end

-- n: the sensors on the PC (seeing something or not), d: their hits.
function N.ground_msg(st, n, hits)
    return {type = N.TYPES.GROUND, id = st.id, n = n, d = hits}
end

-- The node's thruster facts from the list: kind, vector, count, name line.
function N.set_thrusters(st, devs)
    st.count = #devs
    st.vector = false
    local names = {}
    for _, d in ipairs(devs) do
        if d.type:find("vector") then st.vector = true end
        names[#names + 1] = d.name .. " (" .. d.type .. ")"
    end
    if #devs > 0 then st.kind = "thruster" end
    return table.concat(names, ", ")
end

-- One target to every thruster, side by side (`run` = parallel.waitForAll):
-- each set call waits for a server tick. A failing one does not stop the
-- others; the first error is raised after all were tried.
function N.apply_all(devs, v, run)
    if #devs == 1 then return N.apply_thruster(devs[1].dev, v) end
    local errs, fns = {}, {}
    for i, d in ipairs(devs) do
        fns[i] = function()
            local ok, err = pcall(N.apply_thruster, d.dev, v)
            if not ok then errs[#errs + 1] = d.name .. ": " .. tostring(err) end
        end
    end
    if #fns > 0 then (run or parallel.waitForAll)(table.unpack(fns)) end
    if #errs > 0 then error(errs[1], 0) end
end

-- `startup probe`: what the actuator is and the limits it clamps to.
local function probe()
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        local t = peripheral.getType(name)
        print(name .. ": " .. tostring(t))
        if N.THRUSTER_TYPES[t] then
            local dev = peripheral.wrap(name)
            local ms = peripheral.getMethods(name)
            table.sort(ms)
            print("  methods: " .. table.concat(ms, " "))
            local function try(label, f, ...) local ok, r = pcall(f, ...); print(("  %s -> %s"):format(label, ok and tostring(r) or ("ERR " .. tostring(r)))) end
            if dev.setVectorX and dev.getTargetVectorX then
                try("setVectorX(1e6)", dev.setVectorX, 1e6); try("getTargetVectorX", dev.getTargetVectorX)
                try("setVectorX(-1e6)", dev.setVectorX, -1e6); try("getTargetVectorX", dev.getTargetVectorX)
                try("setVectorX(0)", dev.setVectorX, 0)
            end
            if dev.setVectorY and dev.getTargetVectorY then
                try("setVectorY(1e6)", dev.setVectorY, 1e6); try("getTargetVectorY", dev.getTargetVectorY)
                try("setVectorY(0)", dev.setVectorY, 0)
            end
            if dev.setThrottleNormalized then try("setThrottleNormalized(0.2)", dev.setThrottleNormalized, 0.2) end
            if dev.getThrottle then try("getThrottle", dev.getThrottle) end
            if dev.getPower then try("getPower", dev.getPower) end
            if dev.getCurrentThrustKN then try("getCurrentThrustKN", dev.getCurrentThrustKN) end
            if dev.getObstruction then try("getObstruction", dev.getObstruction) end
            if dev.setThrottleNormalized then try("setThrottleNormalized(0)", dev.setThrottleNormalized, 0) end
        end
    end
end

local function log(line)
    pcall(function()
        if fs.exists(N.LOG_PATH) and fs.getSize(N.LOG_PATH) > N.LOG_LIMIT then fs.delete(N.LOG_PATH) end
        local h = fs.open(N.LOG_PATH, "a")
        if h then
            h.writeLine(("%s %.1f %s"):format(os.date("%H:%M:%S"), os.clock(), line))
            h.close()
        end
    end)
end

-- The owner's ships put the modem below and the RSC behind the PC; on a
-- different build fall back to whatever modem / RSC is attached.
local function find_ports()
    if peripheral.getType(N.MODEM_SIDE) ~= "modem" then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then N.MODEM_SIDE = name; break end
        end
    end
    if peripheral.getType(N.RSC_SIDE) ~= N.RSC_TYPE then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == N.RSC_TYPE then N.RSC_SIDE = name; break end
        end
    end
end

-- The actuator: an RSC, else every thruster on the PC (zeroed, the vector's
-- clamp limits read once: a brief nozzle twitch at zero thrust).
-- Returns rsc, devs.
local function open_actuators(st)
    local rsc, devs = nil, {}
    if peripheral.getType(N.RSC_SIDE) == N.RSC_TYPE then
        rsc = peripheral.wrap(N.RSC_SIDE)
    else
        devs = N.find_thrusters(peripheral)
        N.set_thrusters(st, devs)
    end
    local thruster = devs[1] and devs[1].dev
    if thruster then
        pcall(function()
            local lim = {}
            if thruster.setVectorX and thruster.getTargetVectorX then
                thruster.setVectorX(1e6); lim.xmax = thruster.getTargetVectorX()
                thruster.setVectorX(-1e6); lim.xmin = thruster.getTargetVectorX()
                thruster.setVectorX(0)
            end
            if thruster.setVectorY and thruster.getTargetVectorY then
                thruster.setVectorY(1e6); lim.ymax = thruster.getTargetVectorY()
                thruster.setVectorY(-1e6); lim.ymin = thruster.getTargetVectorY()
                thruster.setVectorY(0)
            end
            st.limits = lim
        end)
        pcall(N.apply_all, devs, {thr = 0, vx = 0, vy = 0})
    end
    st.rsc_ok = (rsc or thruster) ~= nil
    return rsc, devs
end

-- The node's own screen.
local function draw(st)
    term.clear()
    term.setCursorPos(1, 1)
    print(("FC node %d  v%s"):format(st.id, N.VERSION))
    print("mode:    " .. st.mode)
    print("target:  " .. tostring(st.target))
    print("applied: " .. tostring(st.applied) .. (st.apply_pending_since and " (pending)" or ""))
    print("seq:     " .. tostring(st.seq))
    print(st.kind .. (st.count > 1 and (" x" .. st.count) or "") .. ":  " .. (st.rsc_ok and "ok" or "MISSING"))
    if st.apply_err then print("err: " .. st.apply_err) end
end

local function main(args)
    if args[1] == "probe" then probe(); return end
    local id = os.getComputerID()
    local st = N.new(id, {timeout = 1.0})
    os.setComputerLabel("FC" .. id)

    find_ports()
    local ok, err = pcall(rednet.open, N.MODEM_SIDE)
    if not ok then
        log("no modem on " .. N.MODEM_SIDE .. ": " .. tostring(err))
        printError("no modem on " .. N.MODEM_SIDE .. ": " .. tostring(err))
        return
    end
    local rsc, devs = open_actuators(st)
    -- thrusters placed or broken while it runs: found again, given the current target
    local function rescan()
        if rsc then return false end
        local found = N.find_thrusters(peripheral)
        local was = #devs
        for i = #devs, 1, -1 do devs[i] = nil end
        for i, d in ipairs(found) do devs[i] = d end
        N.set_thrusters(st, devs)
        st.rsc_ok = #devs > 0
        return #devs ~= was
    end
    if rsc then st.applied = N.boot_rpm(rsc) end
    if not (rsc or devs[1]) then log("no actuator: nothing on " .. N.RSC_SIDE .. " and no thruster attached") end
    local sensors = N.find_optical(peripheral)

    local pending -- latest requested value, consumed by apply_loop
    local function request(v)
        pending = v
        os.queueEvent("fc_apply")
    end

    local function apply_loop()
        while true do
            os.pullEvent("fc_apply")
            while pending ~= nil do
                local v = pending
                pending = nil
                if rsc or #devs > 0 then
                    st.apply_pending_since = os.clock()
                    local okc, errc
                    if rsc then okc, errc = pcall(rsc.setTargetSpeed, math.floor(v + 0.5))
                    else okc, errc = pcall(N.apply_all, devs, v) end
                    st.apply_pending_since = nil
                    if okc then
                        st.applied = v
                        st.apply_err = nil
                    else
                        st.apply_err = tostring(errc)
                        log(("apply %s failed: %s"):format(tostring(fmt_target(v)), tostring(errc)))
                    end
                    draw(st)
                end
            end
        end
    end

    local function net_loop()
        local got_master = false
        local last_hello, last_telemetry = -math.huge, -math.huge
        draw(st)
        local timer = os.startTimer(0.25)
        while true do
            local ev, a, b, c = os.pullEvent()
            if ev == "rednet_message" then
                local sender, msg, proto = a, b, c
                if proto == N.PROTOCOL then
                    local v = N.handle(st, msg, os.clock())
                    if v ~= nil then
                        got_master = true
                        request(v)
                        draw(st)
                    end
                end
            elseif (ev == "peripheral" or ev == "peripheral_detach") then
                sensors = N.find_optical(peripheral)
                if rescan() then
                    -- a thruster more or less: the same target on every one now
                    if st.target ~= nil then request(st.target) end
                    rednet.broadcast(N.hello(st), N.PROTOCOL)
                    draw(st)
                end
            elseif ev == "timer" and a == timer then
                local now = os.clock()
                local v = N.tick(st, now)
                if v ~= nil then
                    log("watchdog: fallback " .. tostring(fmt_target(v)))
                    request(v)
                    draw(st)
                end
                if not got_master and now - last_hello >= 5 then
                    rednet.broadcast(N.hello(st), N.PROTOCOL)
                    last_hello = now
                end
                if now - last_telemetry >= 1 then
                    pcall(N.read_stress, st, now)
                    if #devs > 0 then pcall(N.read_thrusters, st, devs) end
                    rednet.broadcast(N.telemetry(st), N.PROTOCOL)
                    last_telemetry = now
                end
                timer = os.startTimer(0.25)
            end
        end
    end

    -- the optical sensors: setRange waits for a tick, so not in net_loop
    local function ground_loop()
        local range
        while true do
            if #sensors > 0 then
                local want = st.ground_range
                if want and want ~= range then
                    for _, s in ipairs(sensors) do pcall(s.dev.setRange, want) end
                    range = want
                end
                local hits = (range or 2) > 1 and N.read_optical(sensors) or {}
                rednet.broadcast(N.ground_msg(st, #sensors, hits), N.PROTOCOL)
            end
            sleep(0.25)
        end
    end

    local okm, errm = pcall(parallel.waitForAny, net_loop, apply_loop, ground_loop)
    if not okm then
        log("CRASH: " .. tostring(errm))
        printError(tostring(errm))
    end
end

if _G.FC_NODE_TEST then return N end
main({...})
