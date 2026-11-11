-- Colony Supply: OPTIONAL chat messages, through an Advanced Peripherals
-- Chat Box on this computer or, with chat.relay = true, as finished lines
-- over rednet to a chat relay that owns the Chat Box (protocol
-- gigabait.chat.v1, {line = components, prefix, from, at}). With neither
-- the module is simply off.
--
-- Messages are keys with parameters, like Laravel's lang files: the words
-- are in app/lang/<locale>.lua, what happens to each key (at once, once an
-- hour, in a summary) in /rules/chat.lua. Item and building names are
-- translation keys, so every player reads them in their own language.
--
--   chat:emit("supply.missing", {item = "minecraft:gold_ingot", count = 64, target = "builder L5"})
local Chat = {}
Chat.__index = Chat
Chat.LIMIT = 512        -- AP's default chatBoxMessageSize
Chat.QUEUE = 40
Chat.PROTOCOL = "gigabait.chat.v1"

-- Buildings whose translation key differs from their type.
local HUT_KEYS = {residence = "citizen"}

local function escape(text)
    return (tostring(text):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        return string.format("\\u%04x", c:byte())
    end))
end

-- JSON by hand: the Chat Box takes UTF-8 as it is (utf8 = true), and
-- \uXXXX escapes would triple the length of Cyrillic text.
local function encode(value)
    local kind = type(value)
    if kind == "string" then return '"' .. escape(value) .. '"' end
    if kind == "number" then return tostring(math.floor(value)) end
    if kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "null" end
    if value[1] ~= nil or next(value) == nil then
        local parts = {}
        for i, item in ipairs(value) do parts[i] = encode(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = '"' .. escape(key) .. '":' .. encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
Chat.encode = encode

local function pretty(id)
    local path = tostring(id):match(":(.+)$") or tostring(id)
    path = path:gsub("[_/]", " ")
    return path:sub(1, 1):upper() .. path:sub(2)
end

-- An item by its ID: the item's name key, else the block's (block items),
-- else a readable English name; the ID on hover.
function Chat.item(raw, count)
    local id = tostring(raw or "?"):match("^([%w_%-%.]+:[%w_%-%./]+)")
    if not id then return {text = tostring(raw or "?"), color = "aqua"} end
    local ns, path = id:match("^([^:]+):(.+)$")
    path = path:gsub("/", ".")
    local name = {translate = "item." .. ns .. "." .. path, fallback = "%s",
        with = {{translate = "block." .. ns .. "." .. path, fallback = pretty(id)}},
        color = "aqua", hoverEvent = {action = "show_text", contents = {text = id, color = "gray"}}}
    if count and tonumber(count) and tonumber(count) > 0 then name.extra = {" ×" .. math.floor(tonumber(count))} end
    return name
end

-- A building: "builder L5" -> the hut's name + " 5"; any other text as it is.
function Chat.hut(value)
    local text = tostring(value or "?")
    local kind, level = text:match("^([%a_]+) L(%d+)$")
    kind = kind or text:match("^([%a_]+)$")
    if not kind then return {text = text, color = "gold"} end
    local name = {translate = "block.minecolonies.blockhut" .. (HUT_KEYS[kind] or kind),
        fallback = pretty(kind), color = "gold"}
    if level then name.extra = {" " .. level} end
    return name
end

function Chat.new(deps)
    deps = deps or {}
    local config = deps.config or {}
    local self = setmetatable({}, Chat)
    self.box = deps.box
    -- relay: function(message) that broadcasts a finished line (rednet)
    self.relay = deps.relay
    self.clock = deps.clock or function() return os.epoch("utc") / 1000 end
    self.log = deps.log
    self.locale = config.locale or "uk"
    self.range = tonumber(config.range) or 128
    self.prefix = config.prefix or "Колонія"
    self.summaryEvery = tonumber(config.summary_every) or 600
    self.rules = deps.rules or {}
    self.langs = {}
    self.loadLang = deps.loadLang or function(locale)
        local ok, value = pcall(dofile, "/app/lang/" .. tostring(locale) .. ".lua")
        return ok and type(value) == "table" and value or nil
    end
    self.queue, self.buckets, self.lastSaid = {}, {}, {}
    self.sent, self.dropped = 0, 0
    self.nextSummary = self.clock() + self.summaryEvery
    return self
end

function Chat:lang(locale)
    if self.langs[locale] == nil then self.langs[locale] = self.loadLang(locale) or false end
    return self.langs[locale] or {}
end

-- The template for a key: the locale's, else English, else nil.
function Chat:template(key)
    local entry = self:lang(self.locale)[key]
    if entry == nil then entry = self:lang("en")[key] end
    return entry
end

-- A template as text components: "{x:item}" an item, "{x:hut}" a building,
-- "{x}" plain text.
function Chat:render(key, params)
    params = params or {}
    local template = self:template(key)
    if type(template) ~= "string" then return {key} end
    local out, position = {}, 1
    local function add(part)
        if type(part) == "string" and type(out[#out]) == "string" then out[#out] = out[#out] .. part
        else out[#out + 1] = part end
    end
    while true do
        local first, last, name, kind = template:find("{([%w_]+):?([%w_]*)}", position)
        if not first then break end
        if first > position then add(template:sub(position, first - 1)) end
        local value = params[name]
        if kind == "item" then add(Chat.item(value, params[name .. "_count"]))
        elseif kind == "hut" then add(Chat.hut(value))
        else add(value == nil and "?" or tostring(value)) end
        position = last + 1
    end
    if position <= #template then add(template:sub(position)) end
    return out
end

local COLORS = {ok = "green", info = "gray", warn = "yellow", error = "red"}
local MARKS = {ok = "✔ ", info = "• ", warn = "⚠ ", error = "✖ "}

function Chat:line(level, parts)
    local out = {"", {text = MARKS[level] or "", color = COLORS[level] or "white"}}
    for _, part in ipairs(parts) do out[#out + 1] = part end
    return out
end

function Chat:say(level, key, params)
    self.queue[#self.queue + 1] = self:line(level, self:render(key, params))
    while #self.queue > Chat.QUEUE do table.remove(self.queue, 1); self.dropped = self.dropped + 1 end
end

-- An event. rules/chat.lua decides: off, now, once (per `by` for `every`
-- seconds) or summary (counted per `by`, said every summary_every).
function Chat:emit(key, params)
    if not self.box and not self.relay then return end   -- nobody to tell: nothing piles up
    params = params or {}
    local rule = self.rules[key] or {}
    if rule.off then return end
    local level = rule.level or "info"
    local mode = rule.mode or "now"
    local group = rule.by and params[rule.by]
    if mode == "summary" then
        if group == nil then return end
        local bucket = self.buckets[key] or {order = {}, sums = {}}
        self.buckets[key] = bucket
        if not bucket.sums[group] then bucket.order[#bucket.order + 1] = group end
        bucket.sums[group] = (bucket.sums[group] or 0) + (tonumber(params[rule.sum or "count"]) or 1)
        return
    end
    if mode == "once" then
        local now, seen = self.clock(), key .. ":" .. tostring(group or "")
        local every = tonumber(rule.every) or 3600
        if self.lastSaid[seen] and now - self.lastSaid[seen] < every then return end
        self.lastSaid[seen] = now
    end
    self:say(level, key, params)
end

-- Each summary key: its header, then as many items per line as fit.
function Chat:summarize()
    local limit = 8
    for key, bucket in pairs(self.buckets) do
        local rule = self.rules[key] or {}
        local level = rule.level or "ok"
        local parts = self:render(rule.header or key, {minutes = math.floor(self.summaryEvery / 60 + 0.5)})
        parts[#parts + 1] = " "
        local count = 0
        for index, group in ipairs(bucket.order) do
            if index > limit then break end
            local candidate = {table.unpack(parts)}
            if count > 0 then candidate[#candidate + 1] = ", " end
            candidate[#candidate + 1] = Chat.item(group, bucket.sums[group])
            if count > 0 and #encode(self:line(level, candidate)) > Chat.LIMIT then
                self.queue[#self.queue + 1] = self:line(level, parts)
                parts, count = {Chat.item(group, bucket.sums[group])}, 1
            else
                parts, count = candidate, count + 1
            end
        end
        self.queue[#self.queue + 1] = self:line(level, parts)
        if #bucket.order > limit then self:say(level, "summary.more", {count = #bucket.order - limit}) end
    end
    self.buckets = {}
end

-- Item names without hover, for a line over the limit; nil when none is left.
local function lighter(line)
    for index, part in ipairs(line) do
        if type(part) == "table" and part.hoverEvent then
            local out = {table.unpack(line)}
            local plain = {}
            for k, v in pairs(part) do if k ~= "hoverEvent" then plain[k] = v end end
            out[index] = plain
            return out
        end
    end
    return nil
end

function Chat:send(line)
    local json = encode(line)
    while #json > Chat.LIMIT do
        local next = lighter(line)
        if not next then break end
        line, json = next, encode(next)
    end
    if #json > Chat.LIMIT then self.dropped = self.dropped + 1; return true end
    if self.relay then
        -- fire and forget: the relay says it, paced by its own Chat Box
        local ok = pcall(self.relay, {line = line, prefix = self.prefix,
            from = os.getComputerID and os.getComputerID() or nil, at = os.epoch and os.epoch("utc") or nil})
        if ok then self.sent = self.sent + 1 end
        return true
    end
    if not self.box then return true end
    local prefix = encode({text = self.prefix, color = "gold"})
    -- AP 0.8 takes an options table; older versions take the arguments one by one.
    local ok, result = pcall(self.box.sendFormattedMessage, json, {
        utf8 = true, prefix = prefix, brackets = "[]", bracketsColor = "&6", range = self.range})
    if not ok then
        ok, result = pcall(self.box.sendFormattedMessage, json, self.prefix, "[]", "&6", self.range, true)
    end
    if ok and result then
        self.sent = self.sent + 1
        return true
    end
    if not ok then
        -- the Chat Box was taken away: look for one again, drop what waits
        if self.log then self.log.warn("chat", "Chat Box gone", tostring(result)) end
        self.box, self.queue = nil, {}
        return true
    end
    return false   -- the Chat Box is busy (one message a second): try again
end

-- A Chat Box placed while the program runs is used without a restart.
-- `find` returns the Chat Box or nil; looked for every `every` seconds.
function Chat:watch(find, every)
    if self.box or self.relay then return false end
    local now = self.clock()
    if self.lookedAt and now - self.lookedAt < (every or 5) then return false end
    self.lookedAt = now
    local box = find()
    if not box then return false end
    self.box = box
    self:emit("system.started", {})
    return true
end

-- One message per call; summaries on their period.
function Chat:tick()
    local now = self.clock()
    if now >= self.nextSummary then
        self.nextSummary = now + self.summaryEvery
        self:summarize()
    end
    if self.queue[1] and self:send(self.queue[1]) then table.remove(self.queue, 1) end
end

return Chat
