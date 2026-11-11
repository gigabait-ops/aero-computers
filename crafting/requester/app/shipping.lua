local Requests = require("app.requests")
local Shipping = {}
Shipping.__index = Shipping

local SLOTS = 9
local SECONDS_PER_PACKAGE = 2

local function integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

-- CC's base detailed maxCount is the actual stack limit. Mixed component
-- variants are budgeted as unmergeable items, not assumed to share one stack.
function Shipping.record(metadata, item)
    if type(item) ~= "table" or type(item.name) ~= "string" then return end
    local entry = metadata[item.name] or {}
    metadata[item.name] = entry
    entry.shippingVariants = (entry.shippingVariants or 0) + 1
    local count = tonumber(item.maxCount)
    if not integer(count) then
        entry.shippingUnknown = true
    elseif not entry.shippingMaxCount or count < entry.shippingMaxCount then
        entry.shippingMaxCount = count
    end
end

function Shipping:new()
    return setmetatable({metadata = {}, nextAt = 0, busy = false}, self)
end

function Shipping:observe(metadata)
    self.metadata = metadata or {}
end

function Shipping:stackLimit(name)
    local entry = self.metadata[name]
    if not entry or entry.shippingUnknown or not integer(entry.shippingMaxCount) then return nil end
    if (entry.shippingVariants or 0) > 1 then return 1 end
    -- Package ItemStackHandler slots have a capacity of 64 even for larger stacks.
    return math.min(64, entry.shippingMaxCount)
end

function Shipping:packageCount(items)
    local totals, slots = {}, 0
    for _, item in ipairs(items or {}) do
        local count = tonumber(item.count)
        if not integer(count) or type(item.name) ~= "string" then return nil, "invalid shipping item" end
        totals[item.name] = (totals[item.name] or 0) + count
    end
    for name, count in pairs(totals) do
        local limit = self:stackLimit(name)
        if not limit then return nil, "stack limit unavailable: " .. name end
        slots = slots + math.ceil(count / limit)
    end
    if slots == 0 then return nil, "empty shipping batch" end
    return math.ceil(slots / SLOTS)
end

-- The packages one queued order makes: all its entries go in one ticker
-- order, packed nine stacks to a package. A craft ships nothing from here.
function Shipping:estimate(job)
    if job.mode == "turtle_crafter" then return 0 end
    return self:packageCount(job.requests or Requests.normalize(job))
end

function Shipping:ready(now)
    return not self.busy and now >= self.nextAt
end

-- PC48's warehouse order gate, the permit the crafter turtles use: a
-- shipment waits its turn, so the shared warehouse packager stays under
-- Create's silent drop limit (a ticker order is dropped whole when the
-- packager already has 10 queued packages). Without an answer from PC48 the
-- shipment goes ungated.
function Shipping:useGate(gate)
    self.gate = gate
end

function Shipping:begin(packages, owner)
    assert(integer(packages), "invalid package budget")
    self.busy, self.packages, self.owner = true, packages, owner
    self.token, self.gateInfo = nil, nil
    if self.gate then
        local ok, token, info = pcall(self.gate.acquire, self.gate, packages)
        self.token = ok and token or nil
        self.gateInfo = ok and info or {gate = "error", reason = tostring(token)}
    end
end

function Shipping:finish(now)
    if self.gate and self.token then pcall(self.gate.release, self.gate, self.token, self.packages) end
    self.nextAt = now + SECONDS_PER_PACKAGE * self.packages
    self.lastOwner, self.lastGate = self.owner, self.gateInfo
    self.busy, self.packages, self.owner, self.token = false, nil, nil, nil
end

return Shipping
