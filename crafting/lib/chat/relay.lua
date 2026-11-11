-- The chat relay (PC135, 2026-10-26): takes keyed events (chat.notice) and
-- writes them in Ukrainian to the players near its Chat Box. What happens to
-- a key (at once, in a periodic summary, once an hour) is in chat.rules;
-- the words are in chat.lang.uk. A computer that words its own messages
-- (PC107, the colony, 2026-10-30) sends finished lines instead: {line =
-- text components, prefix = "Колонія"}, said as they come.
local Notice = require("chat.notice")
local Format = require("chat.format")
local Util = require("fleet_util")

local Relay = {}
Relay.__index = Relay
Relay.RELEASE = "2026-10-30.2"
Relay.LIMIT = 512 -- chatBoxMessageSize on Aero

local amount = Util.amount

local function matches(params, wanted)
    if type(wanted) ~= "table" then return false end
    for key, value in pairs(wanted) do
        if params[key] ~= value then return false end
    end
    return true
end

function Relay.new(options)
    options = options or {}
    local config = options.config or {}
    return setmetatable({
        box = options.chatBox,
        now = options.now or function() return os.epoch("utc") / 1000 end,
        logger = options.logger,
        rules = options.rules or require("chat.rules"),
        locale = config.locale or "uk",
        range = tonumber(config.range) or 128,
        prefix = config.prefix or "Склад",
        summarySeconds = tonumber(config.summarySeconds) or 300,
        repeatSeconds = tonumber(config.repeatSeconds) or 3600,
        summaryItems = tonumber(config.summaryItems) or 8,
        queue = {}, buckets = {}, lastSaid = {}, sent = 0, dropped = 0,
    }, Relay)
end

function Relay:log(event, fields) Util.log(self.logger, event, fields) end

-- Queues one line; `prefix` replaces the relay's own ([Склад]).
function Relay:push(line, prefix)
    self.queue[#self.queue + 1] = {line = line, prefix = prefix}
end

function Relay:say(level, key, params)
    self:push(Format.line(level, Format.render(Notice, key, params, self.locale)))
end

function Relay:handle(event)
    if type(event) ~= "table" then return end
    if event.key == nil and type(event.line) == "table" then
        return self:push(event.line, type(event.prefix) == "string" and event.prefix or nil)
    end
    if type(event.key) ~= "string" then return end
    local key, params = event.key, type(event.params) == "table" and event.params or {}
    local rule = self.rules[key] or {level = "info", mode = "now"}
    local mode = matches(params, rule.now) and "now" or (rule.mode or "now")
    local dedupe = key .. ":" .. tostring(rule.by and params[rule.by] or "")
    if rule.clears then
        local paired = rule.clears .. ":" .. tostring(rule.by and params[rule.by] or "")
        local was = self.lastSaid[paired]
        self.lastSaid[paired] = nil
        if rule.onlyIfCleared and not was then return end
    end
    if mode == "summary" then
        local bucket = self.buckets[key] or {order = {}, sums = {}}
        self.buckets[key] = bucket
        local group = params[rule.by]
        -- An "always" craft that found nothing to make (crafted 0) is no news.
        if group == nil or amount(params[rule.sum]) == 0 then return end
        if not bucket.sums[group] then bucket.order[#bucket.order + 1] = group end
        bucket.sums[group] = (bucket.sums[group] or 0) + amount(params[rule.sum])
        return
    end
    if mode == "once" then
        local now = self.now()
        if self.lastSaid[dedupe] and now - self.lastSaid[dedupe] < self.repeatSeconds then return end
        self.lastSaid[dedupe] = now
        if rule.as and not matches(params, rule.now) then
            return self:say(rule.asLevel or rule.level, rule.as, params)
        end
    end
    self:say(rule.level or "info", key, params)
end

-- Each summary key: its header, then the items two per line (the Chat Box
-- message limit fits about two item names with their hover).
function Relay:summarize()
    for key, bucket in pairs(self.buckets) do
        local rule = self.rules[key] or {}
        if #bucket.order > 0 then
            local items = {}
            for index, group in ipairs(bucket.order) do
                if index > self.summaryItems then break end
                items[#items + 1] = Format.item(group, bucket.sums[group])
            end
            local header = Format.render(Notice, rule.header or key,
                {minutes = math.floor(self.summarySeconds / 60 + 0.5)}, self.locale)
            -- As many items per line as fit the Chat Box limit (usually two).
            local parts = header
            parts[#parts + 1] = " "
            local count = 0
            for _, item in ipairs(items) do
                local candidate = {table.unpack(parts)}
                if count > 0 then candidate[#candidate + 1] = ", " end
                candidate[#candidate + 1] = item
                if count > 0 and #Format.encode(Format.line(rule.level or "ok", candidate)) > Relay.LIMIT then
                    self:push(Format.line(rule.level or "ok", parts))
                    parts, count = {item}, 1
                else
                    parts, count = candidate, count + 1
                end
            end
            self:push(Format.line(rule.level or "ok", parts))
            if #bucket.order > self.summaryItems then
                self:say(rule.level or "ok", "summary.more", {count = #bucket.order - self.summaryItems})
            end
        end
    end
    self.buckets = {}
end

function Relay:send(entry)
    if not self.box then return false end
    local line = Format.clickable(entry.line)
    local json = Format.encode(line)
    -- Over the limit: drop the hover from item names one at a time.
    while #json > Relay.LIMIT do
        local lighter = Format.plain(line, 1)
        if lighter == nil then break end
        line, json = lighter, Format.encode(lighter)
    end
    if #json > Relay.LIMIT then
        self.dropped = self.dropped + 1
        self:log("chat.too_long", {length = #json, text = json:sub(1, 120)})
        return true
    end
    local ok, result, err = pcall(self.box.sendFormattedMessage, json, {
        utf8 = true, prefix = Format.encode({text = entry.prefix or self.prefix, color = "gold"}),
        brackets = "[]", bracketsColor = "&6", range = self.range,
    })
    if not ok or not result then
        self:log("chat.send_failed", {error = tostring(ok and err or result)})
        return false
    end
    self.sent = self.sent + 1
    return true
end

-- One message per tick at most; a refused one is tried again next tick.
function Relay:tick()
    local now = self.now()
    self.nextSummary = self.nextSummary or (now + self.summarySeconds)
    if now >= self.nextSummary then
        self.nextSummary = now + self.summarySeconds
        self:summarize()
    end
    if self.queue[1] and self:send(self.queue[1]) then table.remove(self.queue, 1) end
    while #self.queue > 50 do table.remove(self.queue, 1); self.dropped = self.dropped + 1 end
end

function Relay:draw()
    if not term then return end
    term.clear(); term.setCursorPos(1, 1)
    print("Chat relay PC" .. tostring(os.getComputerID()) .. "  " .. Relay.RELEASE)
    print("sent " .. self.sent .. "  queued " .. #self.queue .. "  dropped " .. self.dropped)
end

function Relay:start()
    self:log("fleet.release", {version = Relay.RELEASE})
    self:draw()
    local timer = os.startTimer(0.6)
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "rednet_message" and c == Notice.PROTOCOL then
            local ok, err = pcall(self.handle, self, b)
            if not ok then self:log("chat.event_failed", {error = tostring(err)}) end
        elseif event == "timer" and a == timer then
            local ok, err = pcall(self.tick, self)
            if not ok then self:log("chat.tick_failed", {error = tostring(err)}) end
            self:draw()
            timer = os.startTimer(0.6)
        end
    end
end

return Relay
