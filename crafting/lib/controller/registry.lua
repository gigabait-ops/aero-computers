local Registry = {}
Registry.__index = Registry

function Registry.new(options)
    options = options or {}
    local timeoutSeconds = math.max(5, tonumber(options.timeoutSeconds) or 20)
    local self = setmetatable({
        timeoutSeconds = timeoutSeconds,
        busyTimeoutSeconds = math.max(timeoutSeconds, tonumber(options.busyTimeoutSeconds) or 180),
        workers = {},
    }, Registry)

    for key, worker in pairs(type(options.workers) == "table" and options.workers or {}) do
        -- A crafter announced capabilities or took work; an entry with neither
        -- is a gate-only client (PC46, PC107) that an older release registered.
        if type(worker) == "table" and (worker.capabilities ~= nil or worker.lastAssignedAt ~= nil
            or (tonumber(worker.assignments) or 0) > 0 or worker.assignment ~= nil) then
            local id = worker.id or tonumber(key) or key
            worker.id = id
            worker.assignments = math.max(0, math.floor(tonumber(worker.assignments) or 0))
            self.workers[tostring(id)] = worker
        end
    end
    return self
end

function Registry:get(id)
    return self.workers[tostring(id)]
end

function Registry:observe(id, message, now)
    local key = tostring(id)
    local worker = self.workers[key] or {
        id = tonumber(id) or id,
        state = "IDLE",
        assignments = 0,
    }
    worker.lastSeen = now
    worker.capabilities = message.capabilities or worker.capabilities
    -- The job kind it takes (stations poll with theirs; turtles send none).
    if message.type == "poll" then
        worker.kind = type(message.kinds) == "table" and message.kinds[1] or "turtle"
    end

    if message.type == "status" then
        worker.state = message.state or "BUSY"
        worker.assignment = message.assignment or worker.assignment
    elseif message.type == "progress" or message.type == "result" then
        worker.state = "BUSY"
        worker.assignment = message.assignment or worker.assignment
    elseif message.type == "poll" and message.active then
        worker.state = "BUSY"
        worker.assignment = message.active
    elseif message.type == "poll" and not worker.assignment then
        worker.state = "IDLE"
    end

    self.workers[key] = worker
    return worker
end

function Registry:markAssigned(id, assignmentId, now)
    local worker = self:get(id) or self:observe(id, {type = "poll"}, now)
    local isNewAssignment = tostring(worker.assignment or "") ~= tostring(assignmentId or "")
    worker.state = "BUSY"
    worker.assignment = assignmentId
    worker.lastAssignedAt = now
    if isNewAssignment then
        worker.assignments = (worker.assignments or 0) + 1
    end
    return worker
end

function Registry:release(id, now)
    local worker = self:get(id)
    if worker then
        worker.state = "IDLE"
        worker.assignment = nil
        worker.lastSeen = now or worker.lastSeen
    end
    return worker
end

function Registry:isOnline(worker, now)
    if not worker then
        return false
    end
    local timeout = worker.assignment and self.busyTimeoutSeconds or self.timeoutSeconds
    return (now - (tonumber(worker.lastSeen) or 0)) <= timeout
end

function Registry:available(now)
    local result = {}
    for _, worker in pairs(self.workers) do
        if self:isOnline(worker, now) and not worker.assignment and worker.state == "IDLE" then
            result[#result + 1] = worker
        end
    end
    table.sort(result, function(left, right)
        if left.assignments ~= right.assignments then
            return left.assignments < right.assignments
        end
        if (left.lastAssignedAt or 0) ~= (right.lastAssignedAt or 0) then
            return (left.lastAssignedAt or 0) < (right.lastAssignedAt or 0)
        end
        local leftNumber = tonumber(left.id)
        local rightNumber = tonumber(right.id)
        if leftNumber and rightNumber then
            return leftNumber < rightNumber
        end
        return tostring(left.id) < tostring(right.id)
    end)
    return result
end

-- A worker silent for an hour is gone (a rebuilt turtle gets a new ID);
-- it registers again with its next poll.
local FORGET_SECONDS = 3600

function Registry:snapshot(now)
    local result = {}
    for key, worker in pairs(self.workers) do
        if now - (tonumber(worker.lastSeen) or now) > FORGET_SECONDS and not worker.assignment then
            self.workers[key] = nil
        end
    end
    for _, worker in pairs(self.workers) do
        result[#result + 1] = {
            id = worker.id,
            kind = worker.kind,
            online = self:isOnline(worker, now),
            state = worker.state,
            assignment = worker.assignment,
            lastSeen = worker.lastSeen,
        }
    end
    table.sort(result, function(left, right)
        return tostring(left.id) < tostring(right.id)
    end)
    return result
end

function Registry:serialize()
    return self.workers
end

return Registry
