local AtomicStore = require("atomic_store")
local Util = require("app.util")

local StateStore = {}
StateStore.__index = StateStore

local function defaultState()
    return {
        version = 1,
        sequence = 0,
        controllerId = nil,
        drafts = {},
        jobs = {},
        history = {},
        ui = {
            page = "selector",
        },
    }
end

local function normalize(value)
    local state = type(value) == "table" and value or defaultState()
    state.version = 1
    state.sequence = math.max(0, Util.integer(state.sequence, 0))
    state.drafts = type(state.drafts) == "table" and state.drafts or {}
    state.jobs = type(state.jobs) == "table" and state.jobs or {}
    state.history = type(state.history) == "table" and state.history or {}
    state.ui = type(state.ui) == "table" and state.ui or {}
    state.ui.page = state.ui.page or "selector"
    state.ui.stepIndex = nil
    return state
end

function StateStore:new(path, maxHistory, logger)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    local loaded, recovery = AtomicStore.load(path, fs)
    local instance = setmetatable({
        path = path,
        maxHistory = math.max(1, Util.integer(maxHistory, 100)),
        logger = logger,
        state = normalize(loaded),
        lastError = nil,
    }, self)

    if recovery then
        Util.log(logger, "warn", "state.recovered", {source = recovery})
    end

    return instance
end

function StateStore:save(reason)
    if self.batching then return true end
    while #self.state.history > self.maxHistory do
        table.remove(self.state.history, 1)
    end

    local ok, err = AtomicStore.save(self.path, self.state, fs)
    self.lastError = not ok and tostring(err) or nil

    if not ok then
        Util.log(self.logger, "error", "state.save_failed", {
            reason = reason or "update",
            error = self.lastError,
        })
    end

    return ok, err
end

function StateStore:nextId()
    self.state.sequence = self.state.sequence + 1
    return table.concat({
        "manual",
        tostring(os.getComputerID()),
        tostring(self.state.sequence),
    }, ":")
end

function StateStore:addJob(job)
    local previous = self.state.jobs[job.id]
    local draft = job.slot and self.state.drafts[tostring(job.slot)]
    local oldId, oldState = draft and draft.jobId, draft and draft.jobState
    self.state.jobs[job.id] = job
    if draft then draft.jobId, draft.jobState = job.id, job.state end
    local ok, err = self:save("job added")
    if not ok then
        self.state.jobs[job.id] = previous
        if draft then draft.jobId, draft.jobState = oldId, oldState end
    end
    return ok, err
end

function StateStore:updateJob(job, reason)
    self.state.jobs[job.id] = job
    return self:save(reason or "job updated")
end

function StateStore:finishJob(job)
    self.state.jobs[job.id] = nil
    self.state.history[#self.state.history + 1] = job
    return self:save("job finished")
end

function StateStore:jobs()
    local result = {}

    for _, job in pairs(self.state.jobs) do
        result[#result + 1] = job
    end

    table.sort(result, function(left, right)
        return (tonumber(left.createdAt) or 0) < (tonumber(right.createdAt) or 0)
    end)

    return result
end

function StateStore:history()
    local result = {}

    for index = #self.state.history, 1, -1 do
        result[#result + 1] = self.state.history[index]
    end

    return result
end

function StateStore:clearHistory()
    local previous = self.state.history
    if #previous == 0 then return true end

    self.state.history = {}
    local ok, err = self:save("history cleared")
    if not ok then
        self.state.history = previous
        return false, err
    end

    Util.log(self.logger, "info", "history.cleared", {count = #previous})
    return true
end

function StateStore:batch(action)
    local before = assert(AtomicStore.decode(AtomicStore.encode(self.state)))
    self.batching = true
    local called, result = pcall(action)
    self.batching = false
    if not called then self.state = before; return false, tostring(result) end
    local saved, err = self:save("batch submitted")
    if not saved then self.state = before; return false, err end
    return true, result
end

return StateStore
