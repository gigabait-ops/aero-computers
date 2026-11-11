-- Surplus to the warehouse: the Create Redstone Requester on PC124's wired
-- network orders items over their limit (tuf.plan surplus) to the address
-- in config.surplus. The requester takes them from the stock network it is
-- linked to, so they leave the farm vault in packages.
--
-- Create drops a whole requester order without a word when a packager has
-- 20 packages waiting, and request() answers nothing; so an ordered item
-- counts as gone for `settle` seconds and is ordered again after that if it
-- is still over its limit.
local R = {}
R.__index = R

R.TYPE = "Create_RedstoneRequester"
R.ENTRIES = 9   -- order lines per request
R.MAX = 256     -- items per order line

local function natural(a, b)
    local pa, na = a:match("^(.-)(%d+)$")
    local pb, nb = b:match("^(.-)(%d+)$")
    if pa and pb and pa == pb then return tonumber(na) < tonumber(nb) end
    return a < b
end

function R.new(config, api)
    local cfg = config.surplus or {}
    return setmetatable({api = api or peripheral, enabled = cfg.enabled == true, address = cfg.address or "Storage",
        every = cfg.every or 15, settle = cfg.settle or 30, min = cfg.min or 64,
        inflight = {}, lastAt = -1e9, last = nil, err = nil}, R)
end

-- -> name of the requester in use, or nil
function R:find()
    local found = {}
    for _, name in ipairs(self.api.getNames()) do
        if self.api.hasType(name, R.TYPE) then found[#found + 1] = name end
    end
    table.sort(found, natural)
    self.name = found[1]
    return self.name
end

-- The order lines for this surplus list, less what is still on its way.
function R:entries(list, now)
    for item, f in pairs(self.inflight) do
        if now - f.at >= self.settle then self.inflight[item] = nil end
    end
    local out = {}
    for _, x in ipairs(list) do
        local left = x.count - (self.inflight[x.item] and self.inflight[x.item].count or 0)
        while left >= self.min and #out < R.ENTRIES do
            local n = math.min(R.MAX, left)
            out[#out + 1] = {name = x.item, count = n}
            left = left - n
        end
        if #out >= R.ENTRIES then break end
    end
    return out
end

-- Order the surplus if it is time. -> the order lines sent (nil = none)
function R:step(list, now)
    if not self.enabled or not self.name then return nil end
    if now - self.lastAt < self.every then return nil end
    local lines = self:entries(list, now)
    if #lines == 0 then return nil end
    self.lastAt = now
    local api, name = self.api, self.name
    local ok, err = pcall(api.call, name, "setAddress", self.address)
    if ok then ok, err = pcall(api.call, name, "setConfiguration", "allow_partial") end
    if ok then ok, err = pcall(api.call, name, "setRequest", table.unpack(lines)) end
    if ok then ok, err = pcall(api.call, name, "request") end
    if not ok then
        self.err = tostring(err)
        return nil
    end
    self.err = nil
    for _, l in ipairs(lines) do
        local f = self.inflight[l.name] or {count = 0}
        f.count, f.at = f.count + l.count, now
        self.inflight[l.name] = f
    end
    self.last = {at = now, lines = lines}
    return lines
end

-- What the pages show.
function R:view(list)
    local state = not self.enabled and "off" or not self.name and "missing" or self.err and "error" or "on"
    local over = {}
    for i = 1, math.min(#list, 6) do over[i] = {item = list[i].item, count = list[i].count} end
    return {state = state, address = self.address, requester = self.name, err = self.err, over = over,
        last = self.last}
end

return R
