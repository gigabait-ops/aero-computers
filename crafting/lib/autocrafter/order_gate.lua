-- Fleet-wide ordering permit, granted by the controller one worker at a time.
--
-- Create drops a whole package request without telling the caller when a
-- source packager already queues 10 or more packages (Stock Ticker
-- orders), and the Stock Ticker answers from a one-tick stock
-- cache. Serialising orders through the controller keeps the warehouse
-- packagers below those limits and makes every answer reflect earlier orders.
-- Without a controller reply the worker orders ungated, as before.
local OrderGate = {}
OrderGate.__index = OrderGate

local function amount(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

function OrderGate.new(options)
    options = options or {}
    return setmetatable({
        rednet = options.rednet,
        protocol = assert(options.protocol, "protocol required"),
        controllerId = options.controllerId or function() return nil end,
        workerId = options.workerId,
        now = options.now or function()
            return os and os.epoch and os.epoch("utc") / 1000 or os.clock()
        end,
        sleep = options.sleep or (os and os.sleep),
        -- An old controller never answers; do not stall ordering on it.
        replySeconds = tonumber(options.replySeconds) or 4,
        -- A paced controller keeps answering "wait"; give up only after this.
        waitSeconds = tonumber(options.waitSeconds) or 120,
        resendSeconds = tonumber(options.resendSeconds) or 3,
        jitterSeconds = tonumber(options.jitterSeconds) or 1.5,
        random = options.random or math.random,
        sequence = 0,
    }, OrderGate)
end

function OrderGate:send(controller, message)
    local ok, sent = pcall(self.rednet.send, controller, message, self.protocol)
    return ok and sent ~= false
end

-- Returns token (or nil when ungated) and details for logging.
function OrderGate:acquire(packages)
    local controller = self.controllerId()
    if controller == nil or not self.rednet or type(self.rednet.send) ~= "function"
        or type(self.rednet.receive) ~= "function" then
        return self:ungated("no_controller")
    end
    self.sequence = self.sequence + 1
    local token = tostring(self.workerId or "?") .. ":" .. tostring(self.sequence)
        .. ":" .. tostring(math.floor(self.now() * 1000))
    local request = {type = "order_lock", token = token, packages = math.max(1, amount(packages))}
    local started = self.now()
    local lastSent = started
    local replied = false
    local position
    self:send(controller, request)
    while true do
        local sender, message = self.rednet.receive(self.protocol, 1)
        local now = self.now()
        if sender ~= nil and tostring(sender) == tostring(controller) and type(message) == "table"
            and message.token == token then
            if message.type == "order_grant" then
                return token, {gate = "granted", waited = now - started, position = position}
            elseif message.type == "order_wait" then
                replied = true
                position = message.position
            end
        end
        if not replied and now - started >= self.replySeconds then
            return self:ungated("gate_unsupported")
        end
        if now - started >= self.waitSeconds then
            -- Our queue entry expires on its own once we stop refreshing it.
            return self:ungated("gate_timeout", now - started)
        end
        if now - lastSent >= self.resendSeconds then
            -- Refreshes the waiter lease and recovers a lost grant.
            self:send(controller, request)
            lastSent = now
        end
    end
end

function OrderGate:ungated(reason, waited)
    -- Spread independent ungated orders across server ticks.
    if self.sleep and self.jitterSeconds > 0 then
        self.sleep(self.random() * self.jitterSeconds)
    end
    return nil, {gate = "ungated", reason = reason, waited = waited or 0}
end

function OrderGate:release(token, packages)
    if not token then return false end
    local controller = self.controllerId()
    if controller == nil then return false end
    return self:send(controller, {
        type = "order_release", token = token, packages = amount(packages),
    })
end

return OrderGate
