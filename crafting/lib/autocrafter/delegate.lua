-- A worker's line to PC48 (request protocol, like PC46's requests): craft an
-- item it cannot make and wait for the job (the output goes to the
-- warehouse), or (2026-10-28) ask for items the warehouse lacks: PC48 has
-- them made by turtles or another station and sends them to the worker.
local OrderGate = require("autocrafter.order_gate")
local Util = require("fleet_util")

local Delegate = {}
Delegate.__index = Delegate

Delegate.REQUEST_PROTOCOL = Util.REQUEST_PROTOCOL
Delegate.WORKER_PROTOCOL = Util.WORKER_PROTOCOL

local amount = Util.amount

function Delegate.new(options)
    options = options or {}
    return setmetatable({
        rednet = options.rednet or rednet,
        sleep = options.sleep or sleep,
        now = options.now or function() return os.epoch("utc") / 1000 end,
        logger = options.logger,
        idPrefix = options.idPrefix or "w",
        heartbeat = options.heartbeat or function() end,
        hostname = options.hostname or "craft-controller",
        waitSeconds = tonumber(options.waitSeconds) or 1800,
        pollSeconds = tonumber(options.pollSeconds) or 5,
        sequence = 0,
    }, Delegate)
end

function Delegate:controller()
    local ok, id = pcall(self.rednet.lookup, Delegate.REQUEST_PROTOCOL, self.hostname)
    return ok and id and (tonumber(id) or id) or nil
end

local function log(self, event, fields) Util.log(self.logger, event, fields) end

function Delegate:nextId()
    self.sequence = self.sequence + 1
    return self.idPrefix .. "-" .. tostring(math.floor(self.now() * 1000)) .. "-" .. self.sequence
end

-- One question to PC48 and its answer (same id), asked again every
-- pollSeconds until `done(reply)` or `seconds` pass. Returns the reply or nil
-- and a failure.
function Delegate:ask(message, seconds, done, phase)
    local controller = self:controller()
    if not controller then return nil, Util.failure("CONTROLLER_UNAVAILABLE", "no craft controller") end
    local started, lastAsk = self.now(), -math.huge
    while self.now() - started < seconds do
        if self.now() - lastAsk >= self.pollSeconds then
            lastAsk = self.now()
            pcall(self.rednet.send, controller, message, Delegate.REQUEST_PROTOCOL)
        end
        local sender, reply = self.rednet.receive(Delegate.REQUEST_PROTOCOL, 1)
        if sender == controller and type(reply) == "table" and reply.id == message.id
            and reply.type == message.type and done(reply) then
            return reply
        end
        self.heartbeat(phase)
    end
    return nil, Util.failure("CONTROLLER_TIMEOUT", "PC48 gave no answer to " .. message.type)
end

-- Has PC48 send `items` ({name, count, nbt?, optional?}) to `address`.
-- options.craft: an item short in stock is made first (never by `exclude`,
-- the asker's own kind). Waits until PC48 has sent everything (not until it
-- arrives). Returns {sent = name -> count}, or nil and a failure (MISSING_RAW
-- with target/needed when the warehouse lacks something nobody can make).
function Delegate:supply(items, address, options)
    options = options or {}
    -- options.id: the same for the same need (assignment and item), so a
    -- worker restarted mid-job asks again under it and PC48 takes up the
    -- craft it already queued instead of queueing another.
    local message = {type = "supply", id = options.id or self:nextId(), address = address, items = items,
        craft = options.craft, exclude = options.exclude}
    local last
    local reply, err = self:ask(message, self.waitSeconds, function(r)
        last = r
        return r.state == "SENT" or r.state == "MISSING" or r.state == "ERROR"
    end, options.phase or "SUPPLY")
    if not reply then
        log(self, "supply.timeout", {id = message.id, state = last and last.state})
        return nil, err
    end
    log(self, "supply." .. reply.state:lower(), {id = message.id, address = address, items = #items})
    if reply.state == "MISSING" then
        local first = (reply.missing or {})[1] or {}
        return nil, Util.failure("MISSING_RAW", "missing " .. tostring(first.name) .. " x" .. tostring(first.count)
            .. "; unavailable in stock", {target = first.name, needed = first.count, severity = "WARN",
            missing = reply.missing})
    elseif reply.state == "ERROR" then
        return nil, type(reply.failure) == "table" and reply.failure
            or Util.failure("SUPPLY_FAILED", tostring(reply.failure))
    end
    return {sent = reply.sent or {}}
end

-- Asks PC48 for `quantity` of `item` and waits for the job's end.
-- Returns true, or nil and a failure table.
function Delegate:craft(item, quantity, reason)
    local controller = self:controller()
    if not controller then return nil, {code = "CONTROLLER_UNAVAILABLE", message = "no craft controller for " .. item} end
    local id = self:nextId()
    local request = {type = "craft", id = id, target = item, count = math.max(1, amount(quantity)), reason = reason}
    log(self, "delegate.request", {id = id, item = item, count = request.count, reason = reason})
    local started, lastAsk, accepted = self.now(), -math.huge, false
    while self.now() - started < self.waitSeconds do
        if self.now() - lastAsk >= self.pollSeconds then
            lastAsk = self.now()
            pcall(self.rednet.send, controller, accepted and {type = "status", id = id} or request,
                Delegate.REQUEST_PROTOCOL)
        end
        local sender, reply = self.rednet.receive(Delegate.REQUEST_PROTOCOL, 1)
        if sender == controller and type(reply) == "table" and tostring(reply.id) == id then
            if reply.type == "rejected" then
                log(self, "delegate.rejected", {id = id, error = reply.error})
                return nil, {code = "DELEGATE_REJECTED", message = item .. ": " .. tostring(reply.error)}
            end
            accepted = true
            if reply.state == "DONE" then
                log(self, "delegate.done", {id = id, item = item, crafted = reply.craftedOutput,
                    waited = math.floor(self.now() - started)})
                return true
            elseif reply.state == "ERROR" then
                local failure = type(reply.failure) == "table" and reply.failure or {}
                log(self, "delegate.failed", {id = id, item = item, error = reply.error})
                return nil, {code = failure.code or "DELEGATE_FAILED",
                    message = item .. ": " .. tostring(reply.error or failure.message or "craft failed"),
                    target = failure.target, needed = failure.needed, severity = failure.severity}
            end
        end
        self.heartbeat("WAITING_" .. item)
    end
    log(self, "delegate.timeout", {id = id, item = item})
    return nil, {code = "DELEGATE_TIMEOUT", message = item .. " not crafted in " .. self.waitSeconds .. " s"}
end

-- The warehouse ordering permit PC48 hands out (see autocrafter.order_gate).
function Delegate:orderLock(controllerId, packages)
    if controllerId == nil then return nil end
    self.gate = self.gate or OrderGate.new({
        rednet = self.rednet, protocol = Delegate.WORKER_PROTOCOL,
        controllerId = function() return self.gateController end,
        workerId = self.idPrefix, now = self.now, sleep = self.sleep,
    })
    self.gateController = controllerId
    return (self.gate:acquire(packages))
end

function Delegate:orderRelease(controllerId, token, packages)
    if not token or not self.gate then return end
    self.gateController = controllerId
    self.gate:release(token, packages)
end

return Delegate
