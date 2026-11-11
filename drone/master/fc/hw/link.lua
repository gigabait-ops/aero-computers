-- Master side of the aero.fc.v1 rednet protocol: broadcasts targets,
-- tracks node hello/telemetry and the optical sensors' readings nodes send
-- ("ground", fw 1.8.0); every set carries the sensors' range (`gr`).
local L = {}

L.PROTOCOL = "aero.fc.v1"
L.TYPES = {SET = "set", IDLE = "idle", HELLO = "hello", TELEMETRY = "telemetry", GROUND = "ground"}

function L.new(cfg, rednet_api)
    rednet_api.open(cfg.modem)
    return {
        cfg = cfg,
        rn = rednet_api,
        protocol = cfg.protocol or L.PROTOCOL,
        nodes = {},
        unexpected = {},
        seq = 0,
    }
end

local function broadcast(lk, msg)
    lk.seq = lk.seq + 1
    msg.seq = lk.seq
    lk.rn.broadcast(msg, lk.protocol)
    return lk.seq
end

function L.broadcast_set(lk, targets, fallback)
    return broadcast(lk, {type = L.TYPES.SET, targets = targets, fallback = fallback, gr = lk.ground_range})
end

function L.broadcast_idle(lk, targets)
    return broadcast(lk, {type = L.TYPES.IDLE, targets = targets, gr = lk.ground_range})
end

-- Returns true when the message was a node hello/telemetry and was recorded.
function L.handle(lk, sender, msg, now)
    if type(msg) ~= "table" or type(sender) ~= "number" then return false end
    if msg.type == L.TYPES.GROUND then
        local n = lk.nodes[sender]
        if not n then return false end   -- a node says hello first
        local hits = {}
        for _, h in ipairs(type(msg.d) == "table" and msg.d or {}) do
            if type(h) == "table" and type(h.d) == "number" then hits[#hits + 1] = {name = sender .. ":" .. tostring(h.name), d = h.d} end
        end
        n.ground = {n = type(msg.n) == "number" and msg.n or #hits, d = hits, t = now}
        return true
    end
    if msg.type ~= L.TYPES.HELLO and msg.type ~= L.TYPES.TELEMETRY then return false end
    local n = lk.nodes[sender] or {mode = "idle"}
    n.last_seen = now
    if type(msg.count) == "number" then n.count = msg.count end   -- thrusters on the node's PC (fw 1.7.0)
    if msg.type == L.TYPES.HELLO then
        n.rsc = msg.rsc == true
        n.version = msg.version
    else
        n.rsc = msg.rsc_ok == true
        n.seq = msg.seq
        n.target = msg.target
        n.mode = msg.mode
        n.applied = msg.applied
        n.apply_pending = msg.apply_pending == true
        n.apply_err = msg.apply_err
        n.stress = type(msg.stress) == "table" and msg.stress or nil
        n.thrust = type(msg.thrust) == "table" and msg.thrust or nil
    end
    lk.nodes[sender] = n
    return true
end

-- The nodes' optical sensors read within max_age s: their hits
-- ({{name = "133:optical_sensor_4", d}, ...}) and how many sensors there are.
function L.ground(lk, now, max_age)
    local hits, n = {}, 0
    for _, node in pairs(lk.nodes) do
        local g = node.ground
        if g and now - g.t <= max_age then
            n = n + g.n
            for _, h in ipairs(g.d) do hits[#hits + 1] = h end
        end
    end
    return hits, n
end

-- Vector thrusters per corner as the nodes report them ({[id] = n}, 1 for a
-- node that does not say) and the fewest on any corner: the vector
-- authority is thrust_max times that, the same on every corner. The third
-- value is true once every vector node has said how many it has.
function L.vector_counts(lk, motors)
    local counts, low, known = {}, nil, true
    for id, m in pairs(motors) do
        if m.role == "vector" then
            local n = lk.nodes[id] and lk.nodes[id].count
            if type(n) ~= "number" then known = false end
            n = (type(n) == "number" and n >= 1) and math.min(4, math.floor(n)) or 1
            counts[id] = n
            if not low or n < low then low = n end
        end
    end
    return counts, low or 1, known
end

-- One row per configured motor id; also refreshes lk.unexpected (senders
-- that are not in the motor table).
function L.status(lk, now, motors, timeout)
    local st = {}
    for id in pairs(motors) do
        local n = lk.nodes[id]
        if n then
            local age = now - n.last_seen
            st[id] = {ok = age <= timeout and n.rsc == true, age = age, mode = n.mode, target = n.target, rsc = n.rsc,
                applied = n.applied, apply_pending = n.apply_pending, apply_err = n.apply_err, stress = n.stress, thrust = n.thrust,
                count = n.count}
        else
            st[id] = {ok = false}
        end
    end
    local unexpected = {}
    for id in pairs(lk.nodes) do
        if not motors[id] then unexpected[#unexpected + 1] = id end
    end
    table.sort(unexpected)
    lk.unexpected = unexpected
    return st
end

return L
