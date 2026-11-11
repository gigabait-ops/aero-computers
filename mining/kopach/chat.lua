-- The remote's own chat (owner 2026-11-05): kopach/news.lua's keys said in
-- Ukrainian through the Chat Box on the remote's computer, in the
-- warehouse's style: a coloured mark, names in aqua, a gold [Копачі].
-- To the wearer only (the nearest player by the Player Detector; without
-- one, players within C.RANGE blocks). One message a call of C.tick (once a
-- second); a refused one (the box's cooldown, another program on the same
-- box) goes again next time. Never waits in the caller.
local News = package.loaded["kopach.news"] or require("kopach.news")

local C = {}

C.LOCALE = "uk"
C.LIMIT = 512   -- the Chat Box's message limit (the JSON's length)
C.QUEUE = 20
C.RANGE = 16
C.COLORS = {ok = "green", info = "gray", warn = "yellow", error = "red"}
C.MARKS = {ok = "✔ ", info = "• ", warn = "⚠ ", error = "✖ "}

-- box: a Chat Box peripheral (nil: nothing is said), detector: a Player
-- Detector (optional), clock(): seconds
function C.new(box, detector, clock)
    return {box = box, detector = detector, clock = clock or os.clock, queue = {}, said = {}}
end

-- "{x}" a parameter, "{x:name}" a name; the key itself when no template
function C.parts(key, params, locale)
    local template = News[locale or C.LOCALE][key] or News.en[key]
    if type(template) ~= "string" then return {{text = tostring(key)}} end
    params = params or {}
    local out, pos = {}, 1
    while true do
        local a, b, name, kind = template:find("{([%w_]+):?([%w_]*)}", pos)
        if not a then break end
        if a > pos then out[#out + 1] = {text = template:sub(pos, a - 1)} end
        local v = params[name]
        out[#out + 1] = {text = v == nil and "?" or tostring(v), name = kind == "name" or nil}
        pos = b + 1
    end
    if pos <= #template then out[#out + 1] = {text = template:sub(pos)} end
    return out
end

function C.text(key, params, locale)
    local s = {}
    for i, p in ipairs(C.parts(key, params, locale)) do s[i] = p.text end
    return table.concat(s)
end

-- JSON as the Chat Box takes it with utf8 = true: UTF-8 as it is (\u
-- escapes would triple the Cyrillic against the 512 limit)
local function encode(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(ch)
            if ch == '"' or ch == "\\" then return "\\" .. ch end
            return ("\\u%04x"):format(ch:byte())
        end) .. '"'
    end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "null" end
    local out = {}
    if v[1] ~= nil then
        for i, x in ipairs(v) do out[i] = encode(x) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x) end
    table.sort(out)
    return "{" .. table.concat(out, ",") .. "}"
end
C.encode = encode

function C.line(level, parts)
    local out = {"", {text = C.MARKS[level] or "", color = C.COLORS[level] or "white"}}
    for _, p in ipairs(parts) do out[#out + 1] = p.name and {text = p.text, color = "aqua"} or p.text end
    return out
end

-- A key and its params: queued when it has a rule and was not said within
-- the rule's `once` (for the same params[by]).
function C.emit(c, key, params)
    local rule = News.rules[key]
    if not (c and rule) then return end
    if rule.once then
        local id = key .. ":" .. tostring(rule.by and (params or {})[rule.by] or "")
        local now = c.clock()
        if c.said[id] and now - c.said[id] < rule.once then return end
        c.said[id] = now
    end
    c.queue[#c.queue + 1] = {line = C.line(rule.level, C.parts(key, params)), text = C.text(key, params),
        prefix = rule.prefix or "Копачі"}
    while #c.queue > C.QUEUE do table.remove(c.queue, 1) end
end

-- the wearer: the nearest player the detector sees within 3 blocks
local function wearer(c)
    local d = c.detector
    if not (d and type(d.getPlayersInRange) == "function") then return nil end
    local ok, names = pcall(d.getPlayersInRange, 3)
    if ok and type(names) == "table" and type(names[1]) == "string" then return names[1] end
    return nil
end

local function send(c, e)
    local box = c.box
    local opts = {utf8 = true, brackets = "[]", bracketsColor = "&6"}
    local who = wearer(c)
    if who then opts.player = who else opts.range = C.RANGE end
    if type(box.sendFormattedMessage) == "function" then
        local json = encode(e.line)
        if #json <= C.LIMIT then
            opts.prefix = encode({text = e.prefix, color = "gold"})
            local ok, res = pcall(box.sendFormattedMessage, json, opts)
            return ok and res ~= false
        end
    end
    opts.prefix = e.prefix
    local ok, res = pcall(box.sendMessage, e.text, opts)
    return ok and res ~= false
end

-- one queued message per call; with no box the queue just waits
function C.tick(c)
    if c and c.box and c.queue[1] and send(c, c.queue[1]) then table.remove(c.queue, 1) end
end

return C
