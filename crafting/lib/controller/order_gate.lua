-- Grants one warehouse order at a time and paces them by an estimated
-- packager backlog. Create packagers emit one package per 20 ticks and drop a
-- whole request once their exit queue reaches 10 packages (Stock Ticker
-- orders), so the budget stays below that.
-- State is volatile: after a restart workers simply ask again.
local OrderGate = {}
OrderGate.__index = OrderGate

local function amount(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

function OrderGate.new(options)
    options = options or {}
    return setmetatable({
        leaseSeconds = tonumber(options.leaseSeconds) or 10,
        waiterTimeout = tonumber(options.waiterTimeout) or 10,
        budget = math.max(1, tonumber(options.budget) or 8),
        drainPerSecond = math.max(0.05, tonumber(options.drainPerSecond) or 1),
        holder = nil,
        waiters = {},
        backlog = 0,
        backlogAt = 0,
        grants = 0,
        expired = 0,
    }, OrderGate)
end

function OrderGate:currentBacklog(now)
    local drained = math.max(0, now - self.backlogAt) * self.drainPerSecond
    return math.max(0, self.backlog - drained)
end

function OrderGate:allows(packages, now)
    local backlog = self:currentBacklog(now)
    return backlog <= 0 or backlog + packages <= self.budget
end

function OrderGate:waiterIndex(worker)
    for index, waiter in ipairs(self.waiters) do
        if tostring(waiter.worker) == tostring(worker) then return index end
    end
    return nil
end

-- Returns grants that became possible; each must be sent to its worker.
function OrderGate:evaluate(now)
    local granted = {}
    if self.holder and now >= self.holder.leaseUntil then
        -- A crashed worker cannot block the fleet; count its order as sent.
        self.expired = self.expired + 1
        self.backlog = self:currentBacklog(now) + self.holder.packages
        self.backlogAt = now
        granted.expiredHolder = self.holder
        self.holder = nil
    end
    local index = 1
    while index <= #self.waiters do
        if now - self.waiters[index].seenAt > self.waiterTimeout then
            table.remove(self.waiters, index)
        else
            index = index + 1
        end
    end
    local first = self.waiters[1]
    if not self.holder and first and self:allows(first.packages, now) then
        table.remove(self.waiters, 1)
        self.holder = {
            worker = first.worker, token = first.token, packages = first.packages,
            grantedAt = now, leaseUntil = now + self.leaseSeconds,
            waited = now - first.queuedAt,
        }
        self.grants = self.grants + 1
        granted[#granted + 1] = self.holder
    end
    return granted
end

-- Returns "grant" or "wait", the waiter position and any grants to send.
function OrderGate:request(worker, token, packages, now)
    packages = math.max(1, amount(packages))
    if self.holder and tostring(self.holder.worker) == tostring(worker) then
        if self.holder.token == token then
            -- Our grant was lost in transit; repeat it.
            return "grant", 0, {}
        end
        -- The worker restarted while holding the permit.
        self.backlog = self:currentBacklog(now) + self.holder.packages
        self.backlogAt = now
        self.holder = nil
    end
    local index = self:waiterIndex(worker)
    if index then
        local waiter = self.waiters[index]
        waiter.token, waiter.packages, waiter.seenAt = token, packages, now
    else
        self.waiters[#self.waiters + 1] = {
            worker = worker, token = token, packages = packages,
            queuedAt = now, seenAt = now,
        }
    end
    local grants = self:evaluate(now)
    if self.holder and self.holder.token == token then
        return "grant", 0, grants
    end
    return "wait", self:waiterIndex(worker), grants
end

function OrderGate:release(worker, token, packages, now)
    if not self.holder or self.holder.token ~= token
        or tostring(self.holder.worker) ~= tostring(worker) then
        return false, self:evaluate(now)
    end
    local sent = packages ~= nil and amount(packages) or self.holder.packages
    self.backlog = self:currentBacklog(now) + sent
    self.backlogAt = now
    self.holder = nil
    return true, self:evaluate(now)
end

function OrderGate:snapshot(now)
    return {
        holder = self.holder and self.holder.worker or nil,
        waiting = #self.waiters,
        backlog = math.floor(self:currentBacklog(now) * 10 + 0.5) / 10,
        grants = self.grants,
        expired = self.expired,
    }
end

return OrderGate
