-- The farm settings PC13 keeps in /tuf/state.txt (limits, priorities,
-- modes, power, storage stop rules, manual signals) and the commands that
-- change them. Every command carries the final value, never a step, so a
-- command repeated after a lost answer or a restart changes nothing more.
local P = require("tuf.plan")

local S = {}

function S.load(path)
    -- a save cut between its delete and move left only the new file
    if not fs.exists(path) and fs.exists(path .. ".new") then path = path .. ".new" end
    if not fs.exists(path) then return {} end
    local f = fs.open(path, "r")
    if not f then return {} end
    local text = f.readAll()
    f.close()
    local ok, value = pcall(textutils.unserialize, text)
    return ok and type(value) == "table" and value or {}
end

-- Written to a side file first, so a crash never leaves half a file.
function S.save(path, state)
    local tmp = path .. ".new"
    local f = fs.open(tmp, "w")
    if not f then return false end
    f.write(textutils.serialize(state))
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

-- Limits are whole stacks, rounded up (0 = no limit).
function S.stackLimit(config, value)
    value = math.floor(tonumber(value) or 0)
    if value <= 0 then return 0 end
    local stack = config.stack or 64
    return math.ceil(value / stack) * stack
end

local function stageOf(config, name)
    for _, f in ipairs(config.factories) do
        for _, s in ipairs(f.stages) do
            if s.name == name then return s, f end
        end
    end
    return nil
end

local function factoryEntry(state, name)
    state.factories = state.factories or {}
    state.factories[name] = state.factories[name] or {}
    return state.factories[name]
end

local function stageEntry(state, name)
    state[name] = state[name] or {}
    return state[name]
end

local function tidy(state, name)
    if type(state[name]) == "table" and next(state[name]) == nil then state[name] = nil end
end

local handlers = {}

function handlers.power(config, state, cmd)
    if cmd.mode ~= "on" and cmd.mode ~= "off" then return false, "power must be on or off" end
    state.mainPower = cmd.mode
    return true
end

function handlers.mode(config, state, cmd)
    if not P.factory(config, cmd.factory) then return false, "no factory " .. tostring(cmd.factory) end
    if cmd.mode ~= "auto" and cmd.mode ~= "off" then return false, "mode must be auto or off" end
    factoryEntry(state, cmd.factory).mode = cmd.mode
    return true
end

-- {target = "stage", name, value} | {target = "base", factory, value} |
-- {target = "res", factory, key, value}
local function setLimit(config, state, cmd, value)
    if cmd.target == "stage" then
        local s, f = stageOf(config, cmd.name)
        if not s then return false, "no line " .. tostring(cmd.name) end
        if s.limitFrom then
            factoryEntry(state, f.name).resourceLimits = factoryEntry(state, f.name).resourceLimits or {}
            factoryEntry(state, f.name).resourceLimits[s.limitFrom] = value
        else
            stageEntry(state, s.name).limit = value
        end
        return true, nil, value
    end
    local f = P.factory(config, cmd.factory)
    if not f then return false, "no factory " .. tostring(cmd.factory) end
    if cmd.target == "base" then
        if not f.base then return false, "no input limit on " .. f.name end
        factoryEntry(state, f.name).baseLimit = value
        return true, nil, value
    end
    if cmd.target == "res" then
        local r = P.resource(f, cmd.key)
        if not r or not r.editable then return false, "cannot set " .. tostring(cmd.key) end
        local entry = factoryEntry(state, f.name)
        entry.resourceLimits = entry.resourceLimits or {}
        entry.resourceLimits[r.key] = value
        return true, nil, value
    end
    return false, "unknown limit target"
end

-- A raise that would take all limits past config.limitBudget is cut to
-- what still fits (whole stacks, at least one stack); lowering is never cut.
function handlers.limit(config, state, cmd)
    local budget = config.limitBudget
    local before = budget and P.totalLimit(config, state)
    local ok, err, value = setLimit(config, state, cmd, S.stackLimit(config, cmd.value))
    if not ok or not budget or value == 0 then return ok, err, value end
    local after = P.totalLimit(config, state)
    local over = math.min(after - budget, after - before)
    if over <= 0 then return ok, err, value end
    local stack = config.stack or 64
    return setLimit(config, state, cmd, math.max(stack, value - math.ceil(over / stack) * stack))
end

-- {factory, names = {stage, ...}}: the new priority order of all lines
function handlers.order(config, state, cmd)
    local f = P.factory(config, cmd.factory)
    if not f then return false, "no factory " .. tostring(cmd.factory) end
    local known, seen = {}, {}
    for _, s in ipairs(f.stages) do known[s.name] = true end
    if type(cmd.names) ~= "table" or #cmd.names ~= #f.stages then return false, "order must list every line" end
    for _, name in ipairs(cmd.names) do
        if not known[name] or seen[name] then return false, "bad line " .. tostring(name) end
        seen[name] = true
    end
    for rank, name in ipairs(cmd.names) do stageEntry(state, name).priority = rank end
    return true
end

-- {name, signal = 0..15 | nil}: nil goes back to automatic
function handlers.manual(config, state, cmd)
    if not stageOf(config, cmd.name) then return false, "no line " .. tostring(cmd.name) end
    local signal = tonumber(cmd.signal)
    if signal then signal = math.max(0, math.min(15, math.floor(signal))) end
    stageEntry(state, cmd.name).debugSignal = signal
    tidy(state, cmd.name)
    return true
end

-- {id, enabled, percent}
function handlers.rule(config, state, cmd)
    if type(cmd.id) ~= "string" then return false, "no storage id" end
    state.settings = state.settings or {}
    local stop = state.settings.storageStop or {}
    state.settings.storageStop = stop
    -- the first change writes every rule out, as the old program did
    stop.rules = P.stopRules(config, state)
    stop.enabled, stop.storageId, stop.percent = nil, nil, nil
    local current = stop.rules[cmd.id] or P.stopRule(config, state, cmd.id)
    local percent = math.max(1, math.min(100, math.floor(tonumber(cmd.percent) or current.percent)))
    local enabled = current.enabled
    if cmd.enabled ~= nil then enabled = cmd.enabled == true end
    stop.rules[cmd.id] = {enabled = enabled, percent = percent}
    return true
end

-- -> ok, error, value
function S.apply(config, state, cmd)
    local h = type(cmd) == "table" and handlers[cmd.op]
    if not h then return false, "unknown command " .. tostring(type(cmd) == "table" and cmd.op) end
    return h(config, state, cmd)
end

return S
