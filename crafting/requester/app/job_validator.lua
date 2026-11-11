local Sections = require("app.sections")
local Util = require("app.util")

local Validator = {}
local isArray, sortedKeys = Util.isArray, Util.sortedKeys

local function hasText(value)
    return type(value) == "string" and value ~= ""
end

local function positive(value)
    local number = tonumber(value)
    return number and number > 0
end

-- An items entry: an item ID or {name = ID, ...}.
function Validator.itemName(entry)
    if type(entry) == "table" then
        return entry.name
    end

    return entry
end

local function validateRequestEntry(entry, path)
    if not hasText(Validator.itemName(entry)) then
        return false, path .. " request item name missing"
    end

    local count = type(entry) == "table" and entry.count or nil

    if count ~= nil and not positive(count) then
        return false, path .. " request item count must be > 0"
    end

    return true
end

local function validateRequests(source, path)
    if source == nil then
        return false, path .. " items missing"
    end

    if type(source) == "table" and isArray(source) then
        if #source == 0 then
            return false, path .. " items empty"
        end

        for index, entry in ipairs(source) do
            local ok, err = validateRequestEntry(entry, path .. ".items[" .. tostring(index) .. "]")

            if not ok then
                return false, err
            end
        end

        return true
    end

    return validateRequestEntry(source, path)
end

-- Each item of an overflow rule's items (one ID, a list or a map), in a
-- stable order: callback(key, entry).
function Validator.eachOverflowItem(items, callback)
    if type(items) == "string" then
        callback(1, items)
    elseif type(items) == "table" and isArray(items) then
        for index, entry in ipairs(items) do
            callback(index, entry)
        end
    elseif type(items) == "table" then
        for _, key in ipairs(sortedKeys(items)) do
            callback(key, items[key])
        end
    end
end

local function validateOverflowItems(source, path)
    if source == nil then
        return false, path .. " items missing"
    end

    local count = 0
    local errorMessage = nil

    Validator.eachOverflowItem(source, function(key, entry)
        count = count + 1

        if not errorMessage and not hasText(Validator.itemName(entry)) then
            errorMessage = path .. ".items[" .. tostring(key) .. "] item name missing"
        end
    end)

    if errorMessage then
        return false, errorMessage
    end

    if count == 0 then
        return false, path .. " items empty"
    end

    return true
end

-- Fields of the old requester and planner formats; a rule that still has
-- one is refused, so it never runs with a meaning it no longer has.
local OBSOLETE = {
    batchSize = "item counts follow from limit and outputPerCycle",
    check = "use target",
    configuration = "orders go through the Stock Ticker",
    mode = "the file decides how a rule runs",
    recipe = "the craft controller resolves recipes",
    requester = "orders go through the Stock Ticker",
    requesterItemLimit = "orders go through the Stock Ticker",
    sharedTarget = "rules may share a target; nothing to mark",
    stockTicker = "set devices.stockTicker in config.lua",
    worker = "the craft controller schedules workers",
    yield = "use outputPerCycle",
}

-- Fields a craft rule (turtle and station files) must not have: PC48 plans
-- the ingredients and delivers the output itself.
local CRAFT_FORBIDDEN = {"items", "request", "requests", "address", "ingredientAddress", "outputPerCycle",
    "multipleOf"}

-- always/from/keep: craft whenever there is something to make it from,
-- optionally only from these item IDs, leaving `keep` of each (craft rules only).
local function validateAlwaysFrom(job, path)
    if job.always ~= nil and type(job.always) ~= "boolean" then
        return false, path .. " always must be true or false"
    end

    if job.from ~= nil then
        if type(job.from) ~= "table" or #job.from == 0 then
            return false, path .. " from must be a list of item IDs"
        end
        for _, name in ipairs(job.from) do
            if not hasText(name) then return false, path .. " from must be a list of item IDs" end
        end
    end

    -- keep: how many of each `from` item an always rule leaves in stock.
    if job.keep ~= nil then
        if job.always ~= true or job.from == nil then
            return false, path .. " keep needs always = true and a from list"
        end
        if type(job.keep) ~= "number" or job.keep < 0 or job.keep % 1 ~= 0 then
            return false, path .. " keep must be a whole number of items, 0 or more"
        end
    end

    return true
end

-- section: a key of app.sections ("request" when nil).
function Validator.validateJob(key, job, section)
    local def = Sections.get(section or "request") or Sections.get("request")

    if type(job) ~= "table" then
        return false, "invalid jobs: " .. tostring(key) .. " must be a table"
    end

    if job.enabled == false then
        return true
    end

    local path = "invalid jobs: " .. tostring(key)

    for _, field in ipairs(sortedKeys(OBSOLETE)) do
        if job[field] ~= nil then
            return false, path .. " " .. field .. " is obsolete; " .. OBSOLETE[field]
        end
    end

    if def.craft then
        for _, field in ipairs(CRAFT_FORBIDDEN) do
            if job[field] ~= nil then
                return false, path .. " " .. field .. " is not supported; craft rules are target/limit/always/from/keep/orderLimit only"
            end
        end

        -- orderLimit: at most this many made per request (a stock level far
        -- off, netherite scrap 100000, owner 2026-11-07).
        if job.orderLimit ~= nil and not (positive(job.orderLimit) and tonumber(job.orderLimit) % 1 == 0) then
            return false, path .. " orderLimit must be a positive integer"
        end

        if not positive(job.limit) then
            return false, path .. " limit must be > 0"
        end

        if not hasText(job.target) then
            return false, path .. " target missing"
        end

        return validateAlwaysFrom(job, path)
    end

    if job.always ~= nil or job.from ~= nil or job.keep ~= nil then
        return false, path .. " always/from/keep are supported only for craft rules"
    end

    if job.multipleOf ~= nil then
        if def.key ~= "export" and def.key ~= "overflow" then
            return false, path .. " multipleOf is supported only for export and overflow"
        end
        local multiple = tonumber(job.multipleOf)
        if not multiple or multiple < 1 or multiple > 256 or multiple ~= math.floor(multiple) then
            return false, path .. " multipleOf must be an integer from 1 to 256"
        end
    end

    if job.orderLimit ~= nil then
        local limit = tonumber(job.orderLimit)
        if def.key ~= "request" and def.key ~= "overflow" then
            return false, path .. " orderLimit is supported only for station requests and overflow"
        end
        if not limit or limit < 1 or limit ~= math.floor(limit) then
            return false, path .. " orderLimit must be a positive integer"
        end
    end

    if def.key == "export" then
        return validateRequests(job.items, path)
    end

    if not positive(job.limit) then
        return false, path .. " limit must be > 0"
    end

    if def.key == "overflow" then
        return validateOverflowItems(job.items, path)
    end

    if not hasText(job.target) then
        return false, path .. " target missing"
    end

    if job.outputPerCycle ~= nil and not positive(job.outputPerCycle) then
        return false, path .. " outputPerCycle must be > 0"
    end

    return validateRequests(job.items, path)
end

-- Each rule of a section table (a list or a map), in a stable order:
-- callback(key, job); a listed rule's key is its key field or its index.
function Validator.eachJob(jobs, callback)
    if isArray(jobs) then
        for index, job in ipairs(jobs) do
            callback(type(job) == "table" and job.key or tostring(index), job)
        end
    else
        for _, key in ipairs(sortedKeys(jobs)) do
            callback(key, jobs[key])
        end
    end
end

function Validator.validateJobs(jobs, section)
    if type(jobs) ~= "table" then
        return false, "invalid jobs: jobs must be a table"
    end

    if next(jobs) == nil then
        return false, "invalid jobs: jobs empty"
    end

    local firstError = nil
    Validator.eachJob(jobs, function(key, job)
        if firstError then return end
        local ok, err = Validator.validateJob(key, job, section)
        if not ok then firstError = err end
    end)

    if firstError then
        return false, firstError
    end

    return true
end

-- One key names one rule across all rule files; the first key used twice.
local function duplicateJobKey(raw)
    local seen = {}
    local message = nil

    for _, def in ipairs(Sections) do
        if type(raw[def.raw]) == "table" then
            Validator.eachJob(raw[def.raw], function(key)
                local identity = tostring(key)
                local path = def.raw .. "." .. identity

                if seen[identity] then
                    message = message or ("duplicate job key " .. identity .. " in " .. seen[identity] .. " and " .. path)
                else
                    seen[identity] = path
                end
            end)
        end
    end

    return message
end

function Validator.validateRaw(raw)
    if type(raw) ~= "table" then
        return false, "invalid jobs: config must return a table"
    end

    local hasAny = false

    for _, def in ipairs(Sections) do
        local jobs = raw[def.raw]

        if type(jobs) == "table" and next(jobs) ~= nil then
            hasAny = true
            local ok, err = Validator.validateJobs(jobs, def.key)

            if not ok then
                return false, err
            end
        elseif jobs ~= nil and type(jobs) ~= "table" then
            return false, "invalid jobs: section must be a table"
        end
    end

    if not hasAny then
        return false, "invalid jobs: jobs empty"
    end

    local duplicate = duplicateJobKey(raw)
    if duplicate then
        return false, duplicate
    end

    return true
end

return Validator
