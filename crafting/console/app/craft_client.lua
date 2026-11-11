local Util = require("app.util")

local CraftClient = {}
CraftClient.__index = CraftClient

local TERMINAL = {
    DONE = true,
    FAILED = true,
    ERROR = true,
    CANCELLED = true,
    REJECTED = true,
}

function CraftClient:new(options)
    options = options or {}
    local config = options.config or {}

    return setmetatable({
        config = config,
        store = options.store,
        logger = options.logger,
        onAccepted = options.onAccepted,
        onRejected = options.onRejected,
        onTerminal = options.onTerminal,
        controllerId = tonumber(options.store.state.controllerId),
        modemNames = {},
        lastLookup = 0,
        lastPing = 0,
        lastPong = 0,
        queryDue = {},
        lastError = nil,
        workers = nil,
        stats = nil,
    }, self)
end

function CraftClient:setModems(names)
    self.modemNames = names or {}

    for _, name in ipairs(self.modemNames) do
        local isOpen = type(rednet.isOpen) == "function" and rednet.isOpen(name) or false
        if not isOpen then
            pcall(rednet.open, name)
        end
    end
end

function CraftClient:networkReady()
    for _, name in ipairs(self.modemNames) do
        if type(rednet.isOpen) ~= "function" or rednet.isOpen(name) then
            return true
        end
    end
    return false
end

function CraftClient:lookup(now)
    if not self:networkReady() then
        self.lastError = "modem missing"
        return nil
    end

    self.lastLookup = now
    local ok, controller = pcall(
        rednet.lookup,
        self.config.protocol,
        self.config.hostname
    )
    controller = ok and tonumber(controller) or nil

    if controller then
        self.controllerId = controller
        self.store.state.controllerId = controller
        self.store:save("controller discovered")
        self.lastError = nil
        return controller
    end

    self.lastError = "craft controller not found"
    return nil
end

function CraftClient:send(message)
    if not self.controllerId then
        return false, "controller unavailable"
    end

    local ok, sent = pcall(rednet.send, self.controllerId, message, self.config.protocol)
    if not ok or sent == false then
        return false, ok and "rednet.send returned false" or tostring(sent)
    end

    return true
end

function CraftClient:retryDelay(attempts)
    local initial = math.max(0.5, tonumber(self.config.retrySeconds) or 2)
    local maximum = math.max(initial, tonumber(self.config.retryMaxSeconds) or 30)
    local exponent = math.max(0, math.min(4, (tonumber(attempts) or 1) - 1))
    return math.min(maximum, initial * (2 ^ exponent))
end

function CraftClient:submit(draft)
    local now = Util.now()
    local job = {
        id = self.store:nextId(),
        slot = draft.slot,
        target = draft.name,
        displayName = draft.displayName,
        count = math.max(1, Util.integer(draft.quantity, 1)),
        sourceCount = draft.sourceCount,
        sourceNbt = draft.nbt,
        state = "PENDING",
        attempts = 0,
        createdAt = now,
        nextAttemptAt = now,
        nextQueryAt = now,
    }

    local saved, err = self.store:addJob(job)
    if not saved then
        return nil, err
    end

    Util.log(self.logger, "info", "craft.queued", {
        id = job.id,
        slot = job.slot,
        target = job.target,
        count = job.count,
    })

    return job
end

function CraftClient:sendCraft(job, now)
    job.attempts = (tonumber(job.attempts) or 0) + 1
    job.lastAttemptAt = now
    job.nextAttemptAt = now + self:retryDelay(job.attempts)

    local ok, err = self:send({
        type = "craft",
        id = job.id,
        target = job.target,
        count = job.count,
    })

    job.state = ok and "SENDING" or "PENDING"
    job.error = ok and nil or err
    self.store:updateJob(job, "craft attempt")

    if not ok then
        self.lastError = err
    end
end

function CraftClient:query(job, now)
    self.queryDue[job.id] = now + (tonumber(self.config.querySeconds) or 5)
    local ok, err = self:send({
        type = "query",
        id = job.id,
    })

    if not ok then
        job.error = err
    end
    -- Query deadlines are transient; no disk write for polling.
end

function CraftClient:tick(now)
    now = now or Util.now()
    if self.store.lastError then
        if not self.store:save("retry failed persistence") then return end
    end
    local lookupSeconds = tonumber(self.config.lookupSeconds) or 10
    local offlineSeconds = tonumber(self.config.offlineSeconds) or 15

    if not self.controllerId or self.lastPong == 0 or now - self.lastPong > offlineSeconds then
        if now - self.lastLookup >= lookupSeconds then
            self:lookup(now)
        end
    end

    if self.controllerId and now - self.lastPing >= (tonumber(self.config.pingSeconds) or 5) then
        self.lastPing = now
        self:send({type = "ping"})
    end

    for _, job in ipairs(self.store:jobs()) do
        if job.state == "PENDING" or job.state == "SENDING" then
            if now >= (tonumber(job.nextAttemptAt) or 0) then
                self:sendCraft(job, now)
            end
        elseif not TERMINAL[job.state] and now >= (self.queryDue[job.id] or tonumber(job.nextQueryAt) or 0) then
            self:query(job, now)
        end
    end
end

function CraftClient:handleMessage(sender, message, protocol)
    if protocol ~= self.config.protocol or type(message) ~= "table" then
        return false
    end

    if message.type == "pong" then
        self.controllerId = tonumber(sender)
        self.store.state.controllerId = self.controllerId
        self.lastPong = Util.now()
        self.workers = tonumber(message.workers)
        self.stats = message.stats
        self.lastError = nil
        return true
    end

    if tonumber(sender) ~= tonumber(self.controllerId) then
        return false
    end

    local id = tostring(message.id or "")
    local job = self.store.state.jobs[id]
    if not job then
        return false
    end

    if message.type == "accepted" then
        local firstAcceptance = job.acceptedAt == nil
        job.acceptedAt = job.acceptedAt or Util.now()
        job.state = tostring(message.state or "ACCEPTED")
        job.position = message.position
        job.error = nil
        job.nextQueryAt = Util.now() + (tonumber(self.config.querySeconds) or 5)
        self.store:updateJob(job, "craft accepted")

        if firstAcceptance and type(self.onAccepted) == "function" then
            self.onAccepted(job)
        end

        return true
    end

    if message.type == "rejected" then
        job.state = "REJECTED"
        job.error = tostring(message.error or "request rejected")
        job.code = message.code
        job.finishedAt = Util.now()
        self.store:finishJob(job)

        if type(self.onRejected) == "function" then
            self.onRejected(job)
        end

        return true
    end

    if message.type == "status" then
        if not job.acceptedAt then
            job.acceptedAt = Util.now()
            if type(self.onAccepted) == "function" then self.onAccepted(job) end
        end
        job.state = tostring(message.state or job.state or "ACCEPTED")
        job.craftedOutput = message.craftedOutput
        job.worker = message.worker
        job.failure = message.failure
        job.error = message.error

        if TERMINAL[job.state] then
            self.queryDue[job.id] = nil
            job.finishedAt = Util.now()
            self.store:finishJob(job)

            if type(self.onTerminal) == "function" then
                self.onTerminal(job)
            end
        else
            job.nextQueryAt = Util.now() + (tonumber(self.config.querySeconds) or 5)
            self.store:updateJob(job, "status received")
        end

        return true
    end

    return false
end

function CraftClient:online(now)
    now = now or Util.now()
    return self.controllerId ~= nil
        and self.lastPong > 0
        and now - self.lastPong <= (tonumber(self.config.offlineSeconds) or 15)
end

return CraftClient
