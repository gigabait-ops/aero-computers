local Protocol = {}
Protocol.__index = Protocol

Protocol.REQUEST_PROTOCOL = "gigabait.craft.request.v1"
Protocol.WORKER_PROTOCOL = "gigabait.autocrafter.worker.v1"

local function itemName(value)
    if type(value) == "string" and value ~= "" and value ~= "minecraft:air" then
        return value
    end
    if type(value) == "table" then
        return itemName(value.name or value.item or value.id or value.target or value.request)
    end
    return nil
end

local function positiveInteger(value, label)
    local number = math.floor(tonumber(value) or 0)
    if number < 1 then
        return nil, tostring(label) .. " must be > 0"
    end
    return number
end

function Protocol.new(options)
    options = options or {}
    return setmetatable({
        requestProtocol = options.requestProtocol or Protocol.REQUEST_PROTOCOL,
        workerProtocol = options.workerProtocol or Protocol.WORKER_PROTOCOL,
    }, Protocol)
end

function Protocol:parseCraft(message, sender, generatedId)
    if type(message) ~= "table" or (message.type ~= nil and message.type ~= "craft") then
        return nil, "message type must be craft"
    end

    local target = itemName(message.target)
    if not target then
        return nil, "target item missing"
    end

    local count, countError = positiveInteger(
        message.count or message.limit or message.expectedOutput,
        "output count"
    )
    if not count then
        return nil, countError
    end

    local clientId = message.id or message.requestId or generatedId
    if clientId == nil then
        return nil, "request id unavailable"
    end

    -- kind: a requester names the station (PC46 station rule files);
    -- all: as much as there is something to make it from; from: only these inputs.
    local kinds = {mechanical = true, saw = true, slicer = true, basin = true, compact = true, turtle = true}
    local from
    if type(message.from) == "table" then
        from = {}
        for _, name in ipairs(message.from) do if type(name) == "string" then from[#from + 1] = name end end
    end
    return {
        clientId = tostring(clientId),
        sender = sender,
        target = target,
        count = count,
        recipeId = message.recipeId,
        kind = kinds[message.kind] and message.kind or nil,
        all = message.all == true or nil,
        from = from,
        -- keep: how many of each `from` item an all job leaves in stock.
        keep = from and tonumber(message.keep) and math.max(0, math.floor(tonumber(message.keep))) or nil,
        -- The output goes straight to this address (a turtle's or station's
        -- packager), not into the warehouse.
        deliverTo = type(message.deliverTo) == "string" and message.deliverTo ~= "" and message.deliverTo or nil,
    }
end

function Protocol:accepted(job, position)
    return {
        type = "accepted",
        id = job.clientId,
        queued = job.status == "QUEUED",
        state = job.status,
        position = position,
        immediateCrafts = 0,
        remainingOutput = job.status == "DONE" and 0 or job.count,
        controller = job.controller,
    }
end

function Protocol:rejected(id, errorMessage, code)
    return {
        type = "rejected",
        id = id,
        code = code or "INVALID_REQUEST",
        error = tostring(errorMessage or "request rejected"),
    }
end

function Protocol:status(job)
    if not job then
        return nil
    end

    local result = job.result or {}
    return {
        type = "status",
        id = job.clientId,
        state = job.status,
        ok = job.status == "DONE",
        target = job.target,
        requestedOutput = job.count,
        craftedOutput = result.craftedOutput or job.completedOutput,
        -- With deliverTo: how much still went to the warehouse instead.
        undeliveredOutput = job.deliverTo and (job.undeliveredOutput or 0) or nil,
        worker = job.worker,
        assignment = job.assignment and job.assignment.id or nil,
        failure = result.failure,
        error = result.error,
    }
end

function Protocol:workerJob(job, assignment, recipePolicy)
    local requestedOutput = assignment and assignment.count or job.count
    return {
        type = "job",
        assignment = assignment.id,
        target = job.target,
        count = requestedOutput,
        requestedOutput = requestedOutput,
        recipeId = job.recipeId,
        recipePolicy = recipePolicy,
        all = job.all,
        from = job.from,
        keep = job.keep,
        -- A station ships the output straight to this address (a supply's
        -- asker) instead of the warehouse.
        deliverTo = job.deliverTo,
    }
end

function Protocol:workerAck(assignment)
    return {
        type = "ack",
        assignment = assignment,
    }
end

function Protocol:workerIdle()
    return {
        type = "idle",
    }
end

return Protocol
