local AtomicStore = require("atomic_store")

local State = {}

function State.new()
    return {
        version = 1,
        controllerId = nil,
        active = nil,
        pendingResult = nil,
        completed = {},
        completedOrder = {},
    }
end

function State.normalize(value)
    local state = type(value) == "table" and value or State.new()
    state.version = 1
    state.controllerId = tonumber(state.controllerId) or state.controllerId
    state.completed = type(state.completed) == "table" and state.completed or {}
    state.completedOrder = type(state.completedOrder) == "table" and state.completedOrder or {}
    if type(state.active) ~= "table" or not state.active.assignment then
        state.active = nil
    end
    if type(state.pendingResult) ~= "table" or not state.pendingResult.assignment then
        state.pendingResult = nil
    end
    return state
end

function State.load(path, fsApi)
    local value, err = AtomicStore.load(path, fsApi)
    if not value then
        if err then
            return nil, err
        end
        return State.new()
    end
    return State.normalize(value)
end

function State.save(state, path, fsApi)
    return AtomicStore.save(path, State.normalize(state), fsApi)
end

function State.remember(state, result, limit)
    local key = tostring(result.assignment)
    if state.completed[key] then
        return state.completed[key]
    end
    state.completed[key] = result
    state.completedOrder[#state.completedOrder + 1] = key
    limit = math.max(8, math.floor(tonumber(limit) or 64))
    while #state.completedOrder > limit do
        state.completed[table.remove(state.completedOrder, 1)] = nil
    end
    return result
end

function State.acknowledge(state, assignment, limit)
    if state.pendingResult and tostring(state.pendingResult.assignment) == tostring(assignment) then
        State.remember(state, state.pendingResult, limit)
        state.pendingResult = nil
    end
    if state.active and tostring(state.active.assignment) == tostring(assignment) then
        state.active = nil
    end
end

return State
