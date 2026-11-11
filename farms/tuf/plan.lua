-- Which line of the TUF farm runs: pure decisions from the config, the
-- saved settings and the item counts (no peripherals, no files).
--
-- Rules (kept from the 2026 chain.lua):
--  * a factory that is off stops every line;
--  * a factory with fewer input nuggets than its base limit stops every line;
--  * otherwise the first line by priority that is under its limit runs and
--    the others wait (a line at its limit is full; limit 0 = no limit);
--  * a parallel factory (brass) runs every line under its limit, each only
--    while its provider factory is full ("needs"), and a running line keeps
--    the provider's ingot line running to feed it;
--  * a manual signal on a line wins over all of that;
--  * the power channel stops the whole farm when it is turned off here or a
--    storage stop rule is reached.
-- Settings shape (124/tuf/state.txt, unchanged from the old program):
--   state[stage] = {limit?, priority?, debugSignal?}
--   state.factories[factory] = {mode?, baseLimit?, resourceLimits?}
--   state.mainPower = "on" | "off"
--   state.settings.storageStop.rules[id] = {enabled, percent}
local P = {}

P.RUN, P.STOP = 0, 15

local function factoryState(state, name)
    return (state.factories or {})[name] or {}
end

function P.mode(factory, state)
    local mode = factoryState(state, factory.name).mode or factory.mode
    return (mode == "off" or mode == "pause") and "off" or "auto"
end

function P.baseLimit(factory, state)
    local saved = factoryState(state, factory.name).baseLimit
    return tonumber(saved) or (factory.base and factory.base.limit) or 0
end

function P.factory(config, name)
    for _, f in ipairs(config.factories) do
        if f.name == name then return f end
    end
    return nil
end

function P.resource(factory, key)
    for _, r in ipairs(factory.resources or {}) do
        if r.key == key then return r end
    end
    return nil
end

-- A resource limit: saved, else the provider factory's base limit (from),
-- else the config.
function P.resourceLimit(config, factory, resource, state)
    if resource.from then
        local provider = P.factory(config, resource.from)
        return provider and P.baseLimit(provider, state) or 0
    end
    local saved = (factoryState(state, factory.name).resourceLimits or {})[resource.key]
    return tonumber(saved) or resource.limit or 0
end

-- The lines of a factory with their limits and priorities resolved, in
-- priority order (ties keep the config order).
function P.stages(config, factory, state)
    local list = {}
    for order, s in ipairs(factory.stages) do
        local saved = state[s.name] or {}
        -- a line that shares a resource's limit (brass) always follows it
        local limit = tonumber(saved.limit)
        if s.limitFrom then
            local r = P.resource(factory, s.limitFrom)
            limit = r and P.resourceLimit(config, factory, r, state) or 0
        end
        list[#list + 1] = {name = s.name, label = s.label, item = s.item, freq1 = s.freq1, freq2 = s.freq2,
            needs = s.needs, factory = factory.name, order = order,
            limit = limit or s.limit or 0, priority = tonumber(saved.priority) or s.priority or order,
            manual = tonumber(saved.debugSignal)}
    end
    table.sort(list, function(a, b)
        if a.priority == b.priority then return a.order < b.order end
        return a.priority < b.priority
    end)
    return list
end

-- Sum of all item limits, each item once (the brass lines share one limit,
-- the brass nugget inputs are the provider's base). 0 = no limit adds 0.
function P.totalLimit(config, state)
    local byItem = {}
    for _, f in ipairs(config.factories) do
        if f.base then byItem[f.base.item] = P.baseLimit(f, state) end
        for _, s in ipairs(P.stages(config, f, state)) do byItem[s.item] = s.limit end
    end
    local total = 0
    for _, limit in pairs(byItem) do total = total + limit end
    return total
end

-- Items over their limit -> {{item, count}}, most first. Nuggets (the
-- factories' base items) are never surplus; lines without a limit neither.
function P.surplus(config, state, counts, min)
    local limits, nuggets = {}, {}
    for _, f in ipairs(config.factories) do
        if f.base then nuggets[f.base.item] = true end
        for _, s in ipairs(P.stages(config, f, state)) do limits[s.item] = s.limit end
    end
    local list = {}
    for item, limit in pairs(limits) do
        local over = (tonumber(counts[item]) or 0) - limit
        if not nuggets[item] and limit > 0 and over >= (min or 1) then list[#list + 1] = {item = item, count = over} end
    end
    table.sort(list, function(a, b)
        if a.count == b.count then return a.item < b.item end
        return a.count > b.count
    end)
    return list
end

local function count(counts, item) return tonumber(counts[item]) or 0 end

local function full(stage, counts)
    return stage.limit > 0 and count(counts, stage.item) >= stage.limit
end

-- A provider is ready when it is on and every line of it is full.
local function providerReady(config, state, counts, name)
    local f = P.factory(config, name)
    if not f or P.mode(f, state) == "off" then return false, f end
    for _, s in ipairs(P.stages(config, f, state)) do
        if s.limit > 0 and count(counts, s.item) < s.limit then return false, f end
    end
    return true, f
end

local function decideFactory(config, state, counts, f)
    local stages = P.stages(config, f, state)
    local out = {mode = P.mode(f, state), stages = stages}
    local function set(s, st) s.state = st; s.signal = st == "run" and P.RUN or P.STOP end
    if out.mode == "off" then
        for _, s in ipairs(stages) do set(s, "off") end
        return out
    end
    if f.base then
        local limit = P.baseLimit(f, state)
        if limit > 0 and count(counts, f.base.item) < limit then
            for _, s in ipairs(stages) do set(s, "base") end
            return out
        end
    end
    if f.parallel then
        for _, s in ipairs(stages) do
            if full(s, counts) then set(s, "full")
            elseif s.needs and not providerReady(config, state, counts, s.needs.factory) then
                set(s, "api")
                local p = P.factory(config, s.needs.factory)
                s.need = p and p.label or s.needs.factory
            else set(s, "run") end
        end
        return out
    end
    local target
    for _, s in ipairs(stages) do
        if not full(s, counts) then target = s; break end
    end
    for _, s in ipairs(stages) do
        if full(s, counts) then set(s, "full")
        elseif s == target then
            if s.needs and not providerReady(config, state, counts, s.needs.factory) then
                set(s, "api")
                local p = P.factory(config, s.needs.factory)
                s.need = p and p.label or s.needs.factory
            else set(s, "run") end
        else set(s, "wait") end
    end
    return out
end

-- ------------------------------------------------------------ storage stop

local function clampPercent(value, fallback)
    local n = tonumber(value) or tonumber(fallback) or 98
    if n < 1 then return 1 end
    if n > 100 then return 100 end
    return math.floor(n)
end

-- Saved rules, else the old single-rule fields, else the config default.
function P.stopRules(config, state)
    local default = config.storageStop or {enabled = true, percent = 98}
    local saved = ((state.settings or {}).storageStop) or {}
    local rules = {}
    if type(saved.rules) == "table" and next(saved.rules) then
        for id, r in pairs(saved.rules) do
            if type(r) == "table" then
                rules[tostring(id)] = {enabled = r.enabled == true, percent = clampPercent(r.percent, default.percent)}
            end
        end
    elseif saved.enabled ~= nil or saved.percent ~= nil then
        rules[tostring(saved.storageId or "ALL")] = {enabled = saved.enabled == true,
            percent = clampPercent(saved.percent, default.percent)}
    else
        rules.ALL = {enabled = default.enabled ~= false, percent = clampPercent(default.percent)}
    end
    return rules
end

function P.stopRule(config, state, id)
    local rules = P.stopRules(config, state)
    local default = config.storageStop or {}
    return rules[id] or {enabled = default.enabled ~= false and id == "ALL", percent = clampPercent(default.percent)}
end

-- One status per rule: all storage first, then each source.
function P.stops(config, state, storage)
    local list = {}
    local function add(id, label, used, max)
        local r = P.stopRule(config, state, id)
        used, max = tonumber(used) or 0, tonumber(max) or 0
        local threshold = math.max(1, math.floor(max * r.percent / 100))
        list[#list + 1] = {id = id, label = label, enabled = r.enabled, percent = r.percent, used = used, max = max,
            stopping = r.enabled and max > 0 and used >= threshold}
    end
    add("ALL", "All storage", storage.used, storage.max)
    for _, s in ipairs(storage.sources or {}) do add(s.id, s.label or s.id, s.used, s.max) end
    return list
end

-- ------------------------------------------------------------ the plan

-- -> {factories = {{factory, mode, stages}}, power = {mode, reason, signal}, stops}
function P.decide(config, state, storage)
    state = state or {}
    local counts = storage.counts or {}
    local result = {factories = {}, byStage = {}}
    for _, f in ipairs(config.factories) do
        local d = decideFactory(config, state, counts, f)
        d.factory = f
        result.factories[#result.factories + 1] = d
        for _, s in ipairs(d.stages) do
            s.count = count(counts, s.item)
            result.byStage[s.name] = s
        end
    end
    -- a running line that needs a provider keeps the provider's line running
    for _, d in ipairs(result.factories) do
        for _, s in ipairs(d.stages) do
            local target = s.needs and s.state == "run" and result.byStage[s.needs.stage]
            if target and (target.state == "full" or target.state == "wait") then
                target.state, target.signal, target.feeds = "run", P.RUN, d.factory.label
            end
        end
    end
    -- manual signals win
    for _, s in pairs(result.byStage) do
        if s.manual then s.signal = math.max(0, math.min(15, math.floor(s.manual))) end
    end
    result.stops = P.stops(config, state, storage)
    local mode = state.mainPower == "off" and "off" or "on"
    local reason = "on"
    if mode == "off" then reason = "off"
    else
        for _, r in ipairs(result.stops) do
            if r.stopping then reason = "storage"; break end
        end
    end
    result.power = {mode = mode, reason = reason, signal = reason == "on" and P.RUN or P.STOP}
    return result
end

-- Every channel PC13 drives: power first, then each line.
function P.channels(config, decision)
    local list = {{name = config.power.name, label = config.power.label, freq1 = config.power.freq1,
        freq2 = config.power.freq2, want = decision.power.signal}}
    for _, d in ipairs(decision.factories) do
        for _, s in ipairs(d.factory.stages) do
            local st = decision.byStage[s.name]
            list[#list + 1] = {name = s.name, label = s.label or nil, item = s.item, freq1 = s.freq1,
                freq2 = s.freq2, want = st.signal}
        end
    end
    return list
end

return P
