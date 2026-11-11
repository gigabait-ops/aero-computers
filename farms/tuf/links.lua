-- The Redstone Link bridge (mod cc-redstone-link-bridge). One bridge keeps
-- a transmitter channel per frequency pair, so a single bridge drives the
-- whole farm. Every call is a main-thread call (one game tick), so:
--  * a channel is written only when its wanted signal changes;
--  * all channels are read back every `recheck` seconds, and a channel that
--    lost our value is written again then, not every cycle;
--  * a channel read higher than we send is held by another transmitter on
--    the same frequency (the owner's lever on the power channel): it is
--    reported, not fought.
-- Other bridges get every channel set to 0 once, so channels they kept from
-- an older layout cannot hold a line at stop.
local L = {}
L.__index = L

-- "redstone_link_bridge_9" before "redstone_link_bridge_10"
local function natural(a, b)
    local pa, na = a:match("^(.-)(%d+)$")
    local pb, nb = b:match("^(.-)(%d+)$")
    if pa and pb and pa == pb then return tonumber(na) < tonumber(nb) end
    return a < b
end

function L.new(config, api)
    api = api or peripheral
    return setmetatable({type = (config.bridge or {}).type or "redstone_link_bridge",
        recheck = (config.bridge or {}).recheck or 5, api = api, last = {}, read = {}, checkedAt = -1e9,
        cleared = {}}, L)
end

-- -> name of the bridge in use (nil when none), list of the others
function L:find()
    local found = {}
    for _, name in ipairs(self.api.getNames()) do
        if self.api.hasType(name, self.type) then found[#found + 1] = name end
    end
    table.sort(found, natural)
    local main = found[1]
    if main ~= self.name then self.last, self.read, self.checkedAt = {}, {}, -1e9 end
    self.name = main
    if main then self.cleared[main] = nil end
    self.extras = {table.unpack(found, 2)}
    return main, self.extras
end

local function call(api, name, method, ...)
    return pcall(api.call, name, method, ...)
end

-- Zero the farm's channels on the other bridges (once per bridge).
function L:clearExtras(channels)
    for _, name in ipairs(self.extras or {}) do
        if not self.cleared[name] then
            for _, ch in ipairs(channels) do call(self.api, name, "sendLinkSignal", ch.freq1, ch.freq2, 0) end
            self.cleared[name] = true
        end
    end
end

-- Drive the channels {name, freq1, freq2, want}; fills ch.read, ch.ok,
-- ch.held and ch.err. -> number of writes
function L:apply(channels, now)
    local writes = 0
    if not self.name then
        for _, ch in ipairs(channels) do ch.err, ch.ok = "no bridge", false end
        return 0
    end
    local recheck = now - self.checkedAt >= self.recheck
    if recheck then self.checkedAt = now end
    for _, ch in ipairs(channels) do
        local key = ch.name
        local write = self.last[key] ~= ch.want
        if not write and recheck then
            local ok, value = call(self.api, self.name, "getLinkSignal", ch.freq1, ch.freq2)
            if ok then
                self.read[key] = tonumber(value) or 0
                -- lower than we send: our transmitter lost it, send again
                if self.read[key] < ch.want then write = true end
            else
                ch.err = tostring(value)
            end
        end
        if write then
            local ok, err = call(self.api, self.name, "sendLinkSignal", ch.freq1, ch.freq2, ch.want)
            if ok then
                self.last[key] = ch.want
                writes = writes + 1
                local rok, value = call(self.api, self.name, "getLinkSignal", ch.freq1, ch.freq2)
                if rok then self.read[key] = tonumber(value) or 0 end
            else
                self.last[key] = nil
                ch.err = tostring(err)
            end
        end
        ch.read = self.read[key]
        ch.ok = ch.err == nil and ch.read == ch.want
        ch.held = ch.err == nil and ch.read ~= nil and ch.read > ch.want
    end
    return writes
end

return L
