local JobValidator = require("app.job_validator")
local Requests = require("app.requests")
local Sections = require("app.sections")
local Util = require("app.util")

local Config = {}
Config.__index = Config

function Config:new(raw)
    return setmetatable({
        raw = raw or {},
        cachedJobs = nil
    }, self)
end

function Config:get(path, fallback)
    local current = self.raw

    for part in tostring(path):gmatch("[^.]+") do
        if type(current) ~= "table" then
            return fallback
        end

        current = current[part]
    end

    if current == nil then
        return fallback
    end

    return current
end

local function cleanKey(value)
    local text = tostring(value or "item")
    text = text:match("^[^:]+:(.+)$") or text
    text = text:gsub("[^%w_]+", "_"):gsub("^_+", ""):gsub("_+$", "")

    return text ~= "" and text or "item"
end

-- An overflow rule is one job per item: key <rule>.<item>, the item's own
-- fields over the rule's.
local function expandOverflowJobs(key, job)
    local result = {}

    JobValidator.eachOverflowItem(job.items, function(itemKey, entry)
        local name = JobValidator.itemName(entry)

        if type(name) ~= "string" or name == "" then
            return
        end

        local expanded = Util.clone(job)
        expanded.items = nil
        expanded.target = name

        if type(entry) == "table" then
            for field, value in pairs(entry) do
                if field ~= "name" then
                    expanded[field] = value
                end
            end
        end

        local suffix = type(itemKey) == "number" and cleanKey(name) or cleanKey(itemKey)

        table.insert(result, {
            key = tostring(key) .. "." .. suffix,
            job = expanded
        })
    end)

    return result
end

-- The rule fields a job keeps (the validator refuses obsolete ones).
local ALLOWED = {
    address = true,
    cooldown = true,
    enabled = true,
    items = true,
    limit = true,
    multipleOf = true,
    orderLimit = true,
    -- Craft rules (2026-10-27): craft whenever there is something to make it
    -- from (always), optionally only from these items (from).
    always = true,
    from = true,
    keep = true,
    target = true,
    outputPerCycle = true
}

-- section: a key of app.sections.
function Config:job(key, job, section)
    local def = Sections.get(section) or Sections.get("request")
    local normalized = {cooldown = self.raw.cooldown}
    local explicitCooldown = type(job) == "table" and job.cooldown ~= nil

    for field, value in pairs(job or {}) do
        if ALLOWED[field] then
            normalized[field] = value
        end
    end

    -- check: the item whose stock the rule keeps.
    normalized.target = normalized.target or ""
    normalized.check = normalized.target
    normalized.key = key
    -- A station rule runs as a turtle rule (PC48 picks the station) and
    -- shows on its own tab.
    normalized.section = def.craft and "turtle" or def.key
    normalized.station = def.station
    normalized.label = Util.labelFromKey(normalized.target ~= "" and normalized.target or normalized.key)
    normalized.enabled = normalized.enabled ~= false
    normalized.exportAvailable = def.key == "export"
    normalized.overflow = def.key == "overflow"
    normalized.limit = tonumber(normalized.limit) or 0
    normalized.outputPerCycle = normalized.outputPerCycle ~= nil and tonumber(normalized.outputPerCycle) or nil
    normalized.multipleOf = normalized.multipleOf ~= nil and tonumber(normalized.multipleOf) or nil
    normalized.cooldown = tonumber(normalized.cooldown) or 0

    if def.craft then
        local turtleConfig = self.raw.turtle or {}
        normalized.mode = "turtle_crafter"
        normalized.controllerHostname = turtleConfig.controllerHostname or "craft-controller"
        normalized.address = normalized.controllerHostname
        normalized.cooldown = explicitCooldown and (tonumber(job.cooldown) or 0) or (tonumber(turtleConfig.cooldown) or 300)
        normalized.outputPerCycle = nil
        normalized.items = nil
        normalized.requests = {}
    else
        normalized.mode = "stock_ticker"
        if normalized.overflow then
            normalized.requests = {{
                name = normalized.check,
                count = 0
            }}
        elseif normalized.exportAvailable then
            normalized.requests = Requests.normalizeAvailable(normalized)
        else
            normalized.requests = Requests.normalize(normalized)
            -- A recipe of several entries ships whole or not at all: the
            -- orderer checks the stock right before the order.
            normalized.strict = #normalized.requests > 1
        end
    end

    if #normalized.requests > 0 then
        normalized.request = normalized.requests[1].name
        normalized.amount = normalized.requests[1].count
        normalized.requestLabel = Requests.summary(normalized.requests)
    else
        normalized.request = normalized.check
        normalized.requestLabel = tostring(normalized.request or "-")
    end

    return normalized
end

function Config:jobs()
    if self.cachedJobs then
        return self.cachedJobs
    end

    local result = {}

    local function add(key, job, section)
        if not JobValidator.validateJob(key, job, section) then
            return
        end
        if section == "overflow" then
            for _, expanded in ipairs(expandOverflowJobs(key, job)) do
                table.insert(result, self:job(expanded.key, expanded.job, section))
            end
        else
            table.insert(result, self:job(key, job, section))
        end
    end

    for _, def in ipairs(Sections) do
        JobValidator.eachJob(self.raw[def.raw] or {}, function(key, job)
            add(key, job, def.key)
        end)
    end

    self.cachedJobs = result
    return result
end

function Config:maxOrdersPerTick()
    return tonumber(self:get("maxOrdersPerTick", 8)) or 8
end

function Config:queuePollSeconds()
    local value = tonumber(self:get("queue.pollSeconds", 0.25)) or 0.25

    return math.max(0.05, value)
end

function Config:queueMaxBatchesPerPoll()
    local value = tonumber(self:get("queue.maxBatchesPerPoll", 1)) or 1

    return math.max(1, math.floor(value))
end

function Config:queuePerJobDelaySeconds()
    local value = tonumber(self:get("queue.perJobDelaySeconds", 0)) or 0

    return math.max(0, value)
end

function Config:uiRefreshSeconds()
    local value = tonumber(self:get("timing.uiRefreshSeconds", 1)) or 1

    return math.max(0, value)
end

function Config:sorting()
    local value = self:get("sorting")

    if type(value) ~= "table" then
        return {
            stockMode = "count"
        }
    end

    return value
end

-- The pause after a raw-material shortage of a craft rule:
-- turtle.rawShortageSeconds after the first shortage, doubled
-- for each one in a row (streak), at most turtle.rawShortageMaxSeconds.
function Config:rawPauseSeconds(streak)
    local base = tonumber(self:get("turtle.rawShortageSeconds", 600)) or 600
    return math.min(self:rawPauseMaxSeconds(), base * 2 ^ math.max(0, (tonumber(streak) or 1) - 1))
end

function Config:rawPauseMaxSeconds()
    local base = tonumber(self:get("turtle.rawShortageSeconds", 600)) or 600
    return math.max(base, tonumber(self:get("turtle.rawShortageMaxSeconds", 7200)) or 7200)
end

function Config:tickSeconds()
    return tonumber(self:get("timing.tickSeconds", 2)) or 2
end

return Config
