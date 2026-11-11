-- Teleport pads. Each pad's computer (tp_pad.lua) listens on rednet protocol
-- gigabait.tp for its own name and pulses its redstone output. The pocket
-- broadcasts the name (GO); a pad answers {type = "tp_done"} when it fired
-- and {type = "tp_pong", name} to a {type = "tp_ping"}, so the list shows
-- which pads are there and fills itself. Pads on the first firmware fire but
-- never answer. The names are kept in the pocket's settings (tp.names).
local T = {}

T.PROTOCOL = "gigabait.tp"
T.STORE = "tp.names"
T.ANSWER = 2      -- seconds a ping or a GO waits for the pads
T.REPING = 30     -- seconds between pings while the tab is open
T.SHOW = 10       -- seconds a GO's result stays on its pad's row

function T.valid(name)
    return type(name) == "string" and #name > 0 and #name <= 32 and name:match("^[A-Za-z0-9_-]+$") ~= nil
end

-- deps: send(msg) broadcasts on T.PROTOCOL; clock(); settings (CC's API).
function T.new(deps)
    local m = {deps = deps, names = {}, pads = {}, sel = 1, ping_t = nil, sent = nil, info = nil, confirm = nil}
    local saved = deps.settings and deps.settings.get(T.STORE, {"home"}) or {"home"}
    for _, name in ipairs(type(saved) == "table" and saved or {}) do
        if T.valid(name) then m.names[#m.names + 1] = name end
    end
    return m
end

local function save(m)
    local s = m.deps.settings
    if not s then return end
    s.set(T.STORE, m.names)
    s.save()
end

local function index_of(m, name)
    for i, n in ipairs(m.names) do
        if n == name then return i end
    end
end

function T.selected(m) return m.names[math.max(1, math.min(m.sel, #m.names))] end

function T.pick(m, name)
    local i = index_of(m, name)
    if i then m.sel, m.picked = i, true; m.confirm = nil end
end

function T.ping(m)
    m.ping_t = m.deps.clock()
    m.deps.send({type = "tp_ping"})
end

-- Ping again when the last one is old (the tab is open).
function T.tick(m)
    local now = m.deps.clock()
    if not m.ping_t or now - m.ping_t >= T.REPING then T.ping(m) end
end

function T.go(m)
    local name = T.selected(m)
    if not name then return end
    m.confirm = nil
    m.sent = {name = name, t = m.deps.clock(), ids = {}}
    m.deps.send(name)
end

function T.add(m, name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return false end
    if not T.valid(name) then m.info = "letters, digits, _ and - only"; return false end
    if index_of(m, name) then m.info = name .. " is already there"; return false end
    m.names[#m.names + 1] = name
    m.sel = #m.names
    save(m)
    m.info = nil
    return true
end

-- DEL asks once (SURE?), the second press deletes.
function T.delete(m)
    local name = T.selected(m)
    if not name then return end
    if m.confirm ~= name then m.confirm = name; return end
    table.remove(m.names, index_of(m, name))
    m.pads[name] = nil
    m.confirm = nil
    m.sel = math.max(1, math.min(m.sel, #m.names))
    save(m)
end

function T.on_message(m, sender, msg)
    if type(msg) ~= "table" or not T.valid(msg.name) then return false end
    local now = m.deps.clock()
    if msg.type == "tp_pong" then
        local pad = m.pads[msg.name] or {ids = {}}
        pad.ids[sender] = now
        m.pads[msg.name] = pad
        if not index_of(m, msg.name) then m.names[#m.names + 1] = msg.name; save(m) end
        return true
    elseif msg.type == "tp_done" and m.sent and m.sent.name == msg.name then
        m.sent.ids[sender] = true
        return true
    end
    return false
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

-- How many pads answered the last ping under this name (nil: still waiting).
function T.answered(m, name)
    local pad = m.pads[name]
    local n = 0
    for _, t in pairs(pad and pad.ids or {}) do
        if m.ping_t and t >= m.ping_t then n = n + 1 end
    end
    if n == 0 and m.ping_t and m.deps.clock() - m.ping_t < T.ANSWER then return nil end
    return n
end

-- The last GO: name, pads that fired, whether it is still waiting, and
-- whether it is recent enough to show (T.SHOW s).
function T.result(m)
    local s = m.sent
    if not s then return nil end
    local age = m.deps.clock() - s.t
    return {name = s.name, fired = count(s.ids), waiting = age < T.ANSWER, recent = age < T.SHOW}
end

return T
