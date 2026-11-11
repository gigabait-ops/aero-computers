-- The glasses' chat service (Chat Box, Advanced Peripherals pocket upgrade,
-- peripheral "chat_box"), as the warehouse's chat relay (2026-11-02): news
-- comes in as keys (pda/notice.lua), the caller gets the English text for
-- its screen back at once, and the service says it in Ukrainian to the
-- wearer only, by pda/chat_rules.lua: a coloured mark, names in aqua, a gold
-- [Дрон]. One message per tick (C.tick), never waiting in the caller.
-- The news: the drone's notable events, and players coming near and going
-- (Player Detector; not tied to the drone). No commands from chat: on Aero a
-- "$" line shows in chat for everyone (owner 2026-10-18).
local D = require("pda.drone")
local N = require("pda.notice")

local C = {}

C.LOCALE = "uk"
C.PREFIX = "Дрон"
C.GONE = 15     -- seconds out of the detector's range before "left"
C.LIMIT = 512   -- the Chat Box's message limit (the JSON's length)
C.QUEUE = 20
C.COLORS = {ok = "green", info = "gray", warn = "yellow", error = "red"}
C.MARKS = {ok = "✔ ", info = "• ", warn = "⚠ ", error = "✖ "}

-- `allow(key)`: whether that news is wanted now (the Settings tab).
function C.new(box, owner, rules, allow)
    if type(box) ~= "table" or type(box.sendMessage) ~= "function" then return nil end
    return {box = box, owner = owner, rules = rules or require("pda.chat_rules"), allow = allow,
        queue = {}, said = {}, last = nil, lost = false}
end

-- JSON as the Chat Box takes it with utf8 = true: UTF-8 as it is (\u
-- escapes would triple the Cyrillic against the 512 limit).
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

-- One chat line: the mark, then the text, names in aqua.
function C.line(level, parts)
    local out = {"", {text = C.MARKS[level] or "", color = C.COLORS[level] or "white"}}
    for _, p in ipairs(parts) do out[#out + 1] = p.name and {text = p.text, color = "aqua"} or p.text end
    return out
end

-- A key and its params: the English text back for a screen; queued for the
-- chat when a rule says so (and not said within its `once`).
function C.emit(c, key, params, now)
    local text = N.text(key, params)
    local rule = c and c.rules[key]
    if not rule or (c.allow and not c.allow(key)) then return text end
    if rule.once then
        local id = key .. ":" .. tostring(rule.by and (params or {})[rule.by] or "")
        now = now or os.clock()
        if c.said[id] and now - c.said[id] < rule.once then return text end
        c.said[id] = now
    end
    c.queue[#c.queue + 1] = {line = C.line(rule.level, N.parts(key, params, C.LOCALE)),
        text = N.text(key, params, C.LOCALE), prefix = rule.prefix or C.PREFIX}
    while #c.queue > C.QUEUE do table.remove(c.queue, 1) end
    return text
end

-- To the wearer only (no owner known: players within 16 blocks).
local function send(c, e)
    local box = c.box
    local opts = {utf8 = true, brackets = "[]", bracketsColor = "&6"}
    if c.owner then opts.player = c.owner else opts.range = 16 end
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

-- One queued message per call; a refused one (the box's cooldown) next time.
function C.tick(c)
    if c and c.queue[1] and send(c, c.queue[1]) then table.remove(c.queue, 1) end
end

-- The players near (the detector's names, the wearer left out), every look:
-- news when one comes, and when one has been gone C.GONE s.
function C.players(c, near, now)
    if not c then return end
    c.near = c.near or {}
    for _, n in ipairs(near or {}) do
        if not c.near[n] then C.emit(c, "player.near", {player = n}, now) end
        c.near[n] = now
    end
    for n, t in pairs(c.near) do
        if now - t > C.GONE then c.near[n] = nil; C.emit(c, "player.left", {player = n}, now) end
    end
end

-- After each status from the drone: its new news; the link lost in flight
-- and back (a drone parked out of reach is not news).
function C.notify(c, m)
    if not c then return end
    local s = m.status
    local link = D.link(m)
    local airborne = s and s.mode ~= "STANDBY" and s.activity ~= "ON THE GROUND"
    if link == "lost" and airborne and not c.lost then c.lost = true; C.emit(c, "link.lost")
    elseif link == "ok" and c.lost then c.lost = false; C.emit(c, "link.back", {activity = s.activity}) end
    local recent = s and s.recent or {}
    if not recent[1] or link ~= "ok" then return end
    if c.last == nil then c.last = recent[1][2]; return end   -- what happened before the glasses started
    if recent[1][2] == c.last then return end
    -- everything newer than the last one seen (a "legs down" right after
    -- "arrived" hid it, 2026-10-18), oldest first
    local new = {}
    for _, e in ipairs(recent) do
        if e[2] == c.last then break end
        table.insert(new, 1, e)
    end
    c.last = recent[1][2]
    for _, e in ipairs(new) do
        if type(e[3]) == "string" then C.emit(c, e[3], e[4]) end
    end
end

return C
