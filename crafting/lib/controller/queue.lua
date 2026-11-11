local Queue = {}
Queue.__index = Queue

local TERMINAL = {
    DONE = true,
    ERROR = true,
}

local function requestKey(sender, clientId)
    local id = tostring(clientId or "")
    return tostring(sender or "") .. ":" .. tostring(#id) .. ":" .. id
end

local function tableCount(values)
    local count = 0
    for _ in pairs(type(values) == "table" and values or {}) do
        count = count + 1
    end
    return count
end

local function normalizeJob(job)
    job.id = tostring(job.id)
    job.clientId = tostring(job.clientId or job.id)
    job.count = math.max(1, math.floor(tonumber(job.count) or 1))
    job.completedOutput = math.max(0, math.floor(tonumber(job.completedOutput) or 0))
    job.completedSteps = math.max(0, math.floor(tonumber(job.completedSteps) or 0))
    job.status = job.status or "QUEUED"
    job.attempts = math.max(0, math.floor(tonumber(job.attempts) or 0))
    job.assignments = type(job.assignments) == "table" and job.assignments or {}
    if job.status == "ASSIGNED" and type(job.assignment) == "table" and job.assignment.id then
        local legacy = job.assignment
        legacy.worker = legacy.worker or job.worker
        legacy.phase = legacy.phase or job.phase
        legacy.current = legacy.current or job.current
        legacy.waitingFor = legacy.waitingFor or job.waitingFor
        legacy.progressCrafts = legacy.progressCrafts or job.progressCrafts
        legacy.progressOutput = legacy.progressOutput or job.progressOutput
        job.assignments[tostring(legacy.id)] = legacy
    end
    job.assignment = nil
    job.worker = nil
    job.phase = nil
    job.current = nil
    job.waitingFor = nil
    job.progressCrafts = nil
    job.progressOutput = nil
    if TERMINAL[job.status] then
        job.assignments = {}
    elseif tableCount(job.assignments) > 0 then
        job.status = "ASSIGNED"
    else
        job.status = "QUEUED"
    end
    return job
end

function Queue.new(data)
    data = type(data) == "table" and data or {}
    local self = setmetatable({
        version = 2,
        sequence = math.max(0, math.floor(tonumber(data.sequence) or 0)),
        jobs = {},
        byRequest = {},
    }, Queue)

    for _, job in ipairs(type(data.jobs) == "table" and data.jobs or {}) do
        if type(job) == "table" and job.id ~= nil and job.sender ~= nil then
            normalizeJob(job)
            self.jobs[#self.jobs + 1] = job
            self.byRequest[requestKey(job.sender, job.clientId)] = job
        end
    end
    return self
end

function Queue:nextId(controllerId)
    self.sequence = self.sequence + 1
    return "craft-" .. tostring(controllerId or "controller") .. "-" .. tostring(self.sequence)
end

function Queue:observeAssignment(assignmentId, controllerId)
    if assignmentId == nil then
        return false
    end

    local owner, sequence = tostring(assignmentId):match("^craft%-([^%-:]+)%-(%d+):%d+$")
    if owner ~= tostring(controllerId) then
        return false
    end

    self.sequence = math.max(self.sequence, tonumber(sequence) or 0)
    return true
end

function Queue:findRequest(sender, clientId)
    if clientId == nil then
        return nil
    end
    return self.byRequest[requestKey(sender, clientId)]
end

function Queue:find(id)
    for _, job in ipairs(self.jobs) do
        if job.id == tostring(id) then return job end
    end
    return nil
end

function Queue:findAssignment(assignmentId)
    if assignmentId == nil then
        return nil
    end
    local wanted = tostring(assignmentId)
    for _, job in ipairs(self.jobs) do
        local assignment = job.assignments and job.assignments[wanted]
        if assignment then
            return job, assignment
        end
    end
    return nil
end

function Queue:assignedTo(workerId)
    for _, job in ipairs(self.jobs) do
        for _, assignment in pairs(job.assignments or {}) do
            if tostring(assignment.worker) == tostring(workerId) then
                return job, assignment
            end
        end
    end
    return nil
end

function Queue:enqueue(request, id, now, controllerId)
    local existing = self:findRequest(request.sender, request.clientId)
    if existing then
        return existing, false
    end

    local job = {
        id = tostring(id),
        clientId = tostring(request.clientId),
        sender = request.sender,
        controller = controllerId,
        target = request.target,
        count = request.count,
        recipeId = request.recipeId,
        kind = request.kind,
        all = request.all,
        from = request.from,
        keep = request.keep,
        internal = request.internal,
        deliverTo = request.deliverTo,
        supplyKey = request.supplyKey,
        status = "QUEUED",
        createdAt = now,
        attempts = 0,
        assignments = {},
    }
    self.jobs[#self.jobs + 1] = job
    self.byRequest[requestKey(job.sender, job.clientId)] = job
    return job, true
end

function Queue:remove(job)
    for index, current in ipairs(self.jobs) do
        if current == job then
            table.remove(self.jobs, index)
            self.byRequest[requestKey(job.sender, job.clientId)] = nil
            return true
        end
    end
    return false
end

function Queue:assignmentCount(job)
    return tableCount(job and job.assignments)
end

function Queue:reservedOutput(job)
    local reserved = 0
    for _, assignment in pairs(job and job.assignments or {}) do
        reserved = reserved + math.max(0, math.floor(tonumber(assignment.count) or 0))
    end
    return reserved
end

function Queue:unassignedOutput(job)
    if not job or job.failurePending or job.allExhausted then
        return 0
    end
    return math.max(0, self:remaining(job) - self:reservedOutput(job))
end

function Queue:canAssign(job, maxParallel)
    if not job or self:terminal(job) or job.failurePending then
        return false
    end
    local limit = math.max(1, math.floor(tonumber(maxParallel) or 1))
    return self:assignmentCount(job) < limit and self:unassignedOutput(job) > 0
end

-- kinds: the job kinds the polling worker takes ({turtle = true} by default);
-- a job without a kind is a turtle job.
function Queue:nextPending(maxParallel, kinds)
    kinds = kinds or {turtle = true}
    for _, job in ipairs(self.jobs) do
        if kinds[job.kind or "turtle"] and self:canAssign(job, maxParallel) then
            return job
        end
    end
    return nil
end

function Queue:position(job, maxParallel)
    local position = 0
    for _, current in ipairs(self.jobs) do
        if self:canAssign(current, maxParallel) then
            position = position + 1
        end
        if current == job then
            return position
        end
    end
    return nil
end

function Queue:remaining(job)
    return math.max(0, job.count - (job.completedOutput or 0))
end

function Queue:moveToBack(job)
    for index, current in ipairs(self.jobs) do
        if current == job then
            table.remove(self.jobs, index)
            self.jobs[#self.jobs + 1] = job
            return true
        end
    end
    return false
end

function Queue:assign(job, workerId, assignmentId, now, assignmentOutput)
    local availableOutput = self:unassignedOutput(job)
    local requestedOutput = math.max(1, math.floor(tonumber(assignmentOutput) or availableOutput))
    requestedOutput = math.min(requestedOutput, availableOutput)
    job.attempts = job.attempts + 1
    job.status = "ASSIGNED"
    job.startedAt = job.startedAt or now
    local assignment = {
        id = tostring(assignmentId),
        worker = workerId,
        assignedAt = now,
        lastHeardAt = now,
        count = requestedOutput,
    }
    job.assignments[assignment.id] = assignment
    self:moveToBack(job)
    return assignment
end

function Queue:release(job, assignmentId)
    if assignmentId ~= nil then
        job.assignments[tostring(assignmentId)] = nil
    end
    job.status = self:assignmentCount(job) > 0 and "ASSIGNED" or "QUEUED"
end

function Queue:heartbeat(job, message, now)
    local assignment = job and job.assignments and job.assignments[tostring(message.assignment)]
    if not assignment then
        return false
    end
    assignment.lastHeardAt = now
    assignment.phase = message.state or assignment.phase
    assignment.current = message.current or assignment.current
    if message.type == "status" or message.state then
        assignment.waitingFor = message.waitingFor
    end
    if message.crafts ~= nil then
        assignment.progressCrafts = math.max(0, math.floor(tonumber(message.crafts) or 0))
    end
    if message.output ~= nil then
        assignment.progressOutput = math.max(0, math.floor(tonumber(message.output) or 0))
    end
    return true
end

function Queue:complete(job, message, now)
    local assignmentId = tostring(message.assignment or "")
    local assignment = job.assignments and job.assignments[assignmentId]
    if not assignment then
        return nil
    end
    local craftedOutput = math.max(0, math.floor(tonumber(message.craftedOutput) or 0))
    -- A job with an address whose output still went to the warehouse.
    if job.deliverTo and message.ok ~= false and message.deliveredTo == nil then
        job.undeliveredOutput = (job.undeliveredOutput or 0) + craftedOutput
    end
    local requestedOutput = tonumber(assignment.count) or self:remaining(job)
    requestedOutput = math.max(1, math.floor(requestedOutput or job.count))
    local completedOutput = (job.completedOutput or 0) + craftedOutput
    local completedSteps = (job.completedSteps or 0)
        + math.max(0, math.floor(tonumber(message.steps) or 0))
    local success = message.ok ~= false
    local failure = message.failure
    local errorMessage = message.error

    if success and craftedOutput < requestedOutput and job.all then
        -- "All" jobs make what there is something to make it from: fewer than
        -- asked is their normal end, not an error (2026-10-27).
        job.allExhausted = true
    elseif success and craftedOutput < requestedOutput then
        success = false
        failure = {
            code = "INCOMPLETE_OUTPUT",
            message = "worker returned fewer items than requested",
            requestedOutput = requestedOutput,
            craftedOutput = craftedOutput,
        }
        errorMessage = failure.message
    elseif not success and type(failure) ~= "table" then
        failure = {
            code = "CRAFT_FAILED",
            message = tostring(errorMessage or "autocrafter failed"),
        }
    end
    if not success then
        errorMessage = tostring(errorMessage or (failure and failure.message) or "autocrafter failed")
    else
        errorMessage = nil
    end

    job.assignments[assignmentId] = nil
    job.completedOutput = completedOutput
    job.completedSteps = completedSteps
    if not success and not job.failurePending then
        job.failurePending = {
            failure = failure,
            error = errorMessage,
            recipeId = message.recipeId,
        }
    end

    local activeAssignments = self:assignmentCount(job)
    if activeAssignments > 0 then
        job.status = "ASSIGNED"
        return {
            ok = success,
            complete = false,
            craftedOutput = completedOutput,
            assignmentOutput = craftedOutput,
            requestedOutput = job.count,
            activeAssignments = activeAssignments,
        }
    end

    local terminalFailure = job.failurePending
    if not terminalFailure and completedOutput < job.count and not job.allExhausted then
        job.status = "QUEUED"
        job.result = nil
        job.notified = nil
        return {
            ok = true,
            complete = false,
            craftedOutput = completedOutput,
            assignmentOutput = craftedOutput,
            requestedOutput = job.count,
            activeAssignments = 0,
        }
    end

    job.status = terminalFailure and "ERROR" or "DONE"
    job.completedAt = now
    job.result = {
        ok = terminalFailure == nil,
        complete = true,
        craftedOutput = completedOutput,
        recipeId = terminalFailure and terminalFailure.recipeId or message.recipeId,
        steps = completedSteps,
        failure = terminalFailure and terminalFailure.failure or nil,
        error = terminalFailure and terminalFailure.error or nil,
    }
    job.failurePending = nil
    job.notified = false
    return job.result
end

function Queue:terminal(job)
    return job and TERMINAL[job.status] == true
end

function Queue:prune(historyLimit)
    historyLimit = math.max(16, math.floor(tonumber(historyLimit) or 256))
    local terminalCount = 0
    for _, job in ipairs(self.jobs) do
        if self:terminal(job) then
            terminalCount = terminalCount + 1
        end
    end

    local removed = 0
    local index = 1
    while terminalCount > historyLimit and index <= #self.jobs do
        local job = self.jobs[index]
        if self:terminal(job) and job.notified then
            table.remove(self.jobs, index)
            self.byRequest[requestKey(job.sender, job.clientId)] = nil
            terminalCount = terminalCount - 1
            removed = removed + 1
        else
            index = index + 1
        end
    end
    return removed
end

function Queue:stats()
    local stats = {queued = 0, assigned = 0, done = 0, errors = 0}
    for _, job in ipairs(self.jobs) do
        if not self:terminal(job) and not job.failurePending and self:unassignedOutput(job) > 0 then
            stats.queued = stats.queued + 1
        end
        stats.assigned = stats.assigned + self:assignmentCount(job)
        if job.status == "DONE" then
            stats.done = stats.done + 1
        elseif job.status == "ERROR" then
            stats.errors = stats.errors + 1
        end
    end
    return stats
end

function Queue:serialize()
    return {
        version = self.version,
        sequence = self.sequence,
        jobs = self.jobs,
    }
end

return Queue
