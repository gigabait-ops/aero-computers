-- Colony Supply: send what the colony has too much of to Create storage.
--
-- Rules are the `max` lines of /rules/keep.lua: {item = "minecraft:cobblestone",
-- max = 256} keeps 256 in the colony and sends the rest. `match = "_log"`
-- instead of `item` covers every item whose id contains the text. What the
-- colony is asking for right now, and the rule's `min`, always stay. So does
-- what the computer ordered for the colony in the last `hold` seconds, counted
-- again from its delivery (the request closes before the courier takes it;
-- builders' deliveries stay `hold_builder`, a builder may be on another stage
-- of its plan). The notes are saved, a reboot keeps them.
-- `variants = true` also counts and sends stacks with nbt (worn or dyed
-- armour and tools); other lines leave such stacks alone. `from = 1` sends
-- once that many are extra instead of config send.min.
--
-- Two ways out:
--   ticker: the colony ticker orders the items to Create storage's address
--           (its packager sits on the warehouse hut)
--   chest:  the computer moves them from the warehouse hut into the outbox
--           chest; its packager ships the chest to Create storage
-- Pure: views, ticker, outbox and clock are injected.
local Send = {}
Send.__index = Send

function Send.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Send)
    self.loader = assert(deps.loader, "send needs loader() -> rules, err")
    self.view = deps.view                 -- what the colony holds: list()
    self.by = deps.by                     -- "ticker", "chest" or nil (not linked)
    self.ticker = deps.ticker             -- colony ticker ("ticker")
    self.warehouse = deps.warehouse       -- warehouse hut peripheral ("chest")
    self.outboxName = deps.outboxName     -- outbox peripheral name ("chest")
    self.clock = deps.clock or function() return os.clock() end
    self.log = deps.log or {info = function() end, warn = function() end, error = function() end}
    local c = deps.config or {}
    self.config = {to = c.to or "Storage", every = tonumber(c.every) or 30, min = tonumber(c.min) or 64,
        max = tonumber(c.max) or 576, wait = tonumber(c.wait) or 60, per_check = tonumber(c.per_check) or 2,
        hold = tonumber(c.hold) or 3600, hold_builder = tonumber(c.hold_builder) or 21600}
    self.rules, self.error = {}, nil
    self.sentAt = {}      -- item -> time of the last send
    self.store = deps.store               -- optional {load, save}: the notes below survive a reboot
    local saved = self.store and self.store.load and self.store.load() or nil
    -- {name, count, at, hold}: brought to the colony recently, stays for its hold
    self.ordered = type(saved) == "table" and type(saved.ordered) == "table" and saved.ordered or {}
    self.lastAt = nil
    self.last = {rows = {}, rules = 0}
    return self
end

-- only lines with a `max` are about sending
local function validRule(rule)
    if type(rule) ~= "table" or tonumber(rule.max) == nil or tonumber(rule.max) < 0 then return false end
    local item, match = rule.item, rule.match
    return (type(item) == "string" and item ~= "") or (type(match) == "string" and match ~= "")
end

function Send:reload()
    local rules, err = self.loader()
    if rules ~= nil and rules == self.source then return end   -- the file did not change
    if type(rules) ~= "table" then
        if err ~= self.error then self.log.warn("SEND_RULES", tostring(err)) end
        self.error = err or "invalid rules"
        return
    end
    local clean = {}
    for _, rule in ipairs(rules) do
        if validRule(rule) then
            clean[#clean + 1] = {item = rule.item, match = rule.match, max = math.floor(tonumber(rule.max)),
                min = math.floor(tonumber(rule.min) or 0), name = rule.name, variants = rule.variants == true,
                from = tonumber(rule.from) and math.max(1, math.floor(tonumber(rule.from))) or nil}
        end
    end
    if #clean ~= #self.rules or self.error then self.log.info("SEND_RULES", #clean, "max rules loaded") end
    self.rules, self.error, self.source, self.ruleCache = clean, nil, rules, {}
end

-- item -> count in the colony. Only plain stacks count: a variant block
-- (Domum Ornamentum, enchanted gear...) is never sent, the builder may need
-- exactly that one. The second map counts every stack, for `variants` lines.
local function totals(view)
    local ok, slots = pcall(view.list)
    if not ok or type(slots) ~= "table" then return nil, tostring(slots) end
    local plain, all = {}, {}
    for _, stack in pairs(slots) do
        if type(stack) == "table" and type(stack.name) == "string" then
            local n = tonumber(stack.count) or 0
            all[stack.name] = (all[stack.name] or 0) + n
            if stack.nbt == nil then plain[stack.name] = (plain[stack.name] or 0) + n end
        end
    end
    return plain, all
end

function Send:save()
    if self.store and self.store.save then pcall(self.store.save, {ordered = self.ordered}) end
    self.dirty = false
end

-- The notes of one scan are written once, at its end.
function Send:flush()
    if self.dirty then self:save() end
end

-- The computer ordered `count` of `name` for the colony just now.

-- `forBuilder`: a builder asked for it, it stays hold_builder
function Send:noteOrdered(name, count, forBuilder)
    if type(name) ~= "string" then return end
    self.ordered[#self.ordered + 1] = {name = name, count = tonumber(count) or 0, at = self.clock(),
        hold = forBuilder and self.config.hold_builder or self.config.hold}
    self.dirty = true
end

-- It arrived: the hold of its note starts again now (a note is added when
-- the order was placed before this computer kept notes).
function Send:noteDelivered(name, count, forBuilder)
    if type(name) ~= "string" then return end
    for i = #self.ordered, 1, -1 do
        local o = self.ordered[i]
        if o.name == name and o.count == (tonumber(count) or 0) then
            o.at = self.clock()
            if forBuilder then o.hold = self.config.hold_builder end
            self.dirty = true
            return
        end
    end
    self:noteOrdered(name, count, forBuilder)
end

-- item -> count within its hold; older notes are dropped
function Send:held(now)
    local held, keep = {}, {}
    for _, o in ipairs(self.ordered) do
        if now - (tonumber(o.at) or 0) < (tonumber(o.hold) or self.config.hold) then
            keep[#keep + 1] = o
            held[o.name] = (held[o.name] or 0) + (tonumber(o.count) or 0)
        end
    end
    local changed = #keep ~= #self.ordered
    self.ordered = keep
    if changed then self:save() end
    return held
end

-- The rule for an item: an exact `item` rule wins over a `match` rule.
function Send:ruleFor(name)
    self.ruleCache = self.ruleCache or {}
    local cached = self.ruleCache[name]
    if cached ~= nil then return cached or nil end
    local found = self:findRule(name)
    self.ruleCache[name] = found or false
    return found
end

function Send:findRule(name)
    local found
    for _, rule in ipairs(self.rules) do
        if rule.item == name then return rule end
        if not found and rule.match and name:find(rule.match, 1, true) then found = rule end
    end
    return found
end

-- Move `count` of `name` from the warehouse hut into the outbox chest.
function Send:toChest(name, count, variants)
    local ok, slots = pcall(self.warehouse.list)
    if not ok or type(slots) ~= "table" then return 0, tostring(slots) end
    local moved = 0
    for slot, stack in pairs(slots) do
        if moved >= count then break end
        if type(stack) == "table" and stack.name == name and (variants or stack.nbt == nil) then
            local okPush, n = pcall(self.warehouse.pushItems, self.outboxName, slot, math.min(count - moved, stack.count))
            if not okPush then return moved, tostring(n) end
            if type(n) ~= "number" or n <= 0 then break end   -- outbox full
            moved = moved + n
        end
    end
    return moved
end

function Send:toStorage(name, count, variants)
    if self.by == "ticker" then
        -- plain items only (no component patch), like the count above
        local filter = {_op = "all", value = {{name = name}, {_op = "not", value = {nbt = {_op = "type", value = "string"}}}},
            _requestCount = count}
        if variants then filter = {name = name, _requestCount = count} end
        local ok, accepted = pcall(self.ticker.requestFiltered, self.config.to, filter)
        if not ok then return 0, tostring(accepted) end
        return tonumber(accepted) or 0
    end
    return self:toChest(name, count, variants)
end

-- One check, at most every `every` seconds. `asked` maps item -> count the
-- colony is asking for (open requests, builder needs); `keepMin` maps item ->
-- the `min` of the item's own line. Returns the items sent in this check.
function Send:check(asked, keepMin)
    local now = self.clock()
    if self.lastAt and now - self.lastAt < self.config.every then return {} end
    self.lastAt = now
    self:reload()
    local sent = {}
    local rows = {}
    self.last = {rows = rows, rules = #self.rules, error = self.error}
    if #self.rules == 0 or not self.view then return sent end
    local have, haveAll = totals(self.view)   -- nil, error when the colony storage cannot be read
    if not have then
        self.last.error = "colony storage: " .. tostring(haveAll)
        return sent
    end
    -- every item a rule covers, with what stays and what may go
    local names = {}
    for _, rule in ipairs(self.rules) do
        if rule.item then names[rule.item] = true end
    end
    for name in pairs(haveAll) do
        if not names[name] and self:ruleFor(name) then names[name] = true end
    end
    local held = self:held(now)
    local list = {}
    for name in pairs(names) do list[#list + 1] = name end
    table.sort(list)
    for _, name in ipairs(list) do
        local rule = self:ruleFor(name)
        local count = (rule.variants and haveAll[name]) or have[name] or 0
        local stays = math.max(rule.max, rule.min, (keepMin and keepMin[name]) or 0)
            + math.max((asked and asked[name]) or 0, held[name] or 0)
        local extra = count - stays
        -- a `match` line's name ("Everything else") is not the item's name
        local r = {item = name, name = rule.item == name and rule.name or nil, have = count, max = rule.max,
            stays = stays, extra = math.max(0, extra),
            sentAt = self.sentAt[name]}
        rows[#rows + 1] = r
        local from = rule.from or self.config.min
        if not self.by then
            r.state = extra >= from and "not linked" or "ok"
        elseif extra < from then
            r.state = extra > 0 and "small" or "ok"   -- small: extra, but less than one send
        elseif self.sentAt[name] and now - self.sentAt[name] < self.config.wait then
            r.state = "sent"
        elseif #sent >= self.config.per_check then
            r.state = "next"
        else
            local amount = math.min(extra, self.config.max)
            local n, sendErr = self:toStorage(name, amount, rule.variants)
            if n > 0 then
                self.sentAt[name], r.sentAt, r.state, r.sent = now, now, "sent", n
                sent[#sent + 1] = {name = name, count = n}
                self.log.info("SENT", name, n, "->", self.by == "ticker" and self.config.to or self.outboxName)
            else
                r.state = sendErr and "error" or "stuck"   -- outbox full / nothing packed
                if sendErr then self.log.error("SEND_FAILED", name, amount, sendErr) end
            end
        end
    end
    return sent
end

return Send
