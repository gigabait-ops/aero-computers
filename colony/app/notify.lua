-- Colony Supply: what is worth a chat line, found by comparing what the
-- program sees now with what it saw before. Used only with app/chat.lua.
-- The first look after a boot only remembers: nothing old is announced.
local Notify = {}
Notify.__index = Notify

local function posKey(pos)
    if type(pos) ~= "table" then return nil end
    return string.format("%s,%s,%s", tostring(pos.x), tostring(pos.y), tostring(pos.z))
end

function Notify.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Notify)
    self.chat = assert(deps.chat, "notify needs a chat")
    self.integrator = deps.integrator
    self.clock = deps.clock or function() return os.epoch("utc") / 1000 end
    self.every = tonumber(deps.every) or 60     -- seconds between colony looks
    self.hungry = tonumber(deps.hungry) or 3    -- saturation below this is hungry
    self.lookedAt = nil
    self.seen = nil
    self.levels = nil
    return self
end

local function call(integrator, name, ...)
    if type(integrator) ~= "table" or type(integrator[name]) ~= "function" then return nil end
    local ok, value = pcall(integrator[name], ...)
    if ok then return value end
    return nil
end

-- Attacks, graves, citizens coming and the colony being full or hungry.
function Notify:colony(now)
    if self.lookedAt and now - self.lookedAt < self.every then return end
    self.lookedAt = now
    local it = self.integrator
    if call(it, "isInColony") == false then return end
    local seen = {
        attack = call(it, "isUnderAttack") == true,
        raid = call(it, "isUnderRaid") == true,
        graves = tonumber(call(it, "getGraveCount")),
        count = tonumber(call(it, "getCitizenCount")),
        limit = tonumber(call(it, "getCitizenLimit")),
    }
    local citizens = call(it, "getCitizens")
    local names, hungry = {}, 0
    if type(citizens) == "table" then
        for _, c in pairs(citizens) do
            if type(c) == "table" then
                if c.id ~= nil then names[c.id] = tostring(c.name or c.id) end
                local food = tonumber(c.saturation)
                if food and food < self.hungry then hungry = hungry + 1 end
            end
        end
        seen.names = names
    end
    local was = self.seen
    self.seen = seen
    if seen.raid then self.chat:emit("colony.raid", {})
    elseif seen.attack then self.chat:emit("colony.attack", {}) end
    if was == nil then return end
    if seen.graves and was.graves and seen.graves > was.graves then
        self.chat:emit("colony.grave", {count = seen.graves})
    end
    if seen.names and was.names then
        for id, name in pairs(seen.names) do
            if was.names[id] == nil then
                self.chat:emit("colony.citizen_new", {name = name, count = seen.count or "?", limit = seen.limit or "?"})
            end
        end
    end
    if seen.count and seen.limit and seen.limit > 0 and seen.count >= seen.limit then
        self.chat:emit("colony.full", {count = seen.count, limit = seen.limit})
    end
    if hungry > 0 then self.chat:emit("colony.hungry", {count = hungry}) end
end

-- A hut built or upgraded since the last list.
function Notify:buildings(list)
    if type(list) ~= "table" or #list == 0 then return end
    local levels = {}
    for _, b in ipairs(list) do
        local key = posKey(b.pos)
        if key and b.built ~= false then levels[key] = {type = b.type, level = tonumber(b.level) or 0} end
    end
    local was = self.levels
    self.levels = levels
    if was == nil then return end
    for key, now in pairs(levels) do
        local before = was[key]
        if before == nil and now.level > 0 then
            self.chat:emit("building.built", {hut = now.type, level = now.level})
        elseif before and now.level > before.level then
            self.chat:emit("building.upgraded", {hut = now.type, level = now.level})
        end
    end
end

-- One supply cycle: what Create storage lacks and what was delivered.
-- `crafting(name)` is true while the craft module has it in hand.
-- "builder L5" -> the key with a hut; anything else (a stock rule, a
-- builder's plan) -> the key's "_stock" / "_build" variant without one.
local function byTarget(key, target)
    target = tostring(target or "")
    if target == "stock rule" then return key .. "_stock" end
    if target:find("^builder: ") then return key .. "_build" end
    return key
end

-- One supply cycle: what the craft controller was asked to make, what was ordered from
-- Create storage, what is missing (not what is being crafted) and what the
-- colony took. Runs after the craft step, so a craft asked this cycle is
-- said as a craft, not as missing.
function Notify:cycle(result, crafting)
    if type(result) ~= "table" then return end
    local asked = {}
    for _, c in ipairs(result.craftAsked or {}) do
        asked[c.name] = true
        self.chat:emit(byTarget("supply.crafting", c.target), {item = c.name, item_count = c.count, target = c.target})
    end
    for _, o in ipairs(result.ordered or {}) do
        self.chat:emit("supply.ordered", {item = o.name, count = o.count})
    end
    for _, m in ipairs(result.missing or {}) do
        if not asked[m.name] and not (crafting and crafting(m.name)) then
            self.chat:emit(byTarget("supply.missing", m.target), {item = m.name, item_count = m.count, target = m.target})
        end
    end
    for _, c in ipairs(result.completed or {}) do
        self.chat:emit("supply.delivered", {item = c.name, count = c.count})
    end
end

return Notify
