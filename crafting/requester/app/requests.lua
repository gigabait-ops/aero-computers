local Util = require("app.util")

local Requests = {}

local MAX_REQUEST_ITEMS = 9
local MAX_REQUEST_COUNT = 256

function Requests.clampCount(value)
    return math.max(1, math.min(MAX_REQUEST_COUNT, math.floor(tonumber(value) or 1)))
end

-- A whole count of at least 1 (an item count or a number of cycles).
function Requests.requestCount(value)
    return math.max(1, math.floor(tonumber(value) or 1))
end

function Requests.limit(job)
    job = job or {}

    return tonumber(job.limit) or 0
end

function Requests.missing(job, currentCount)
    return math.max(0, math.ceil(Requests.limit(job) - (tonumber(currentCount) or 0)))
end

local function maxRequestCount(requests)
    local result = 1

    for _, item in ipairs(requests or {}) do
        if type(item) == "table" then
            result = math.max(result, Requests.requestCount(item.count))
        end
    end

    return result
end

function Requests.producedCount(job, requests)
    job = job or {}

    if job.outputPerCycle ~= nil then
        local number = tonumber(job.outputPerCycle)
        return number and number > 0 and number or 1
    end

    return maxRequestCount(requests)
end

function Requests.orderCount(job, currentCount, requests)
    local missing = Requests.missing(job, currentCount)
    local producedCount = Requests.producedCount(job, requests)

    return Requests.requestCount(math.ceil(missing / producedCount))
end

-- A rule's items entry: an item ID (one per cycle) or {name = ID, count = n}.
function Requests.normalizeEntry(entry)
    if type(entry) == "string" then
        return {
            name = entry,
            count = 1
        }
    end

    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return nil
    end

    return {
        name = entry.name,
        count = Requests.clampCount(entry.count)
    }
end

function Requests.normalize(job)
    local result = {}
    local source = job.items

    if source == nil then
        source = job.target
    end

    if type(source) == "table" and Util.isArray(source) then
        for _, entry in ipairs(source) do
            local item = Requests.normalizeEntry(entry)

            if item then
                table.insert(result, item)
            end
        end
    else
        local item = Requests.normalizeEntry(source)

        if item then
            table.insert(result, item)
        end
    end

    return result
end

function Requests.normalizeAvailable(job)
    local result = {}
    local source = (job or {}).items

    local function add(entry)
        local name
        local count = "all"

        if type(entry) == "string" then
            name = entry
        elseif type(entry) == "table" then
            name = entry.name
            count = entry.count or "all"
        end

        if type(name) == "string" and name ~= "" then
            table.insert(result, {
                name = name,
                count = count
            })
        end
    end

    if type(source) == "table" and Util.isArray(source) then
        for _, entry in ipairs(source) do
            add(entry)
        end
    else
        add(source)
    end

    return result
end

function Requests.summary(requests)
    if type(requests) ~= "table" or #requests == 0 then
        return "-"
    end

    if #requests == 1 then
        return requests[1].name
    end

    return tostring(#requests) .. " items"
end

function Requests.details(requests)
    if type(requests) ~= "table" or #requests == 0 then
        return "-"
    end

    local parts = {}

    for _, item in ipairs(requests) do
        table.insert(parts, tostring(item.name) .. " x" .. tostring(item.count or 1))
    end

    return table.concat(parts, ", ")
end

local function aggregate(requests)
    local totals = {}

    for _, item in ipairs(requests or {}) do
        local name = item and item.name
        local count = tonumber(item and item.count)

        if type(name) == "string" and name ~= "" and count and count > 0 then
            totals[name] = (totals[name] or 0) + count
        end
    end

    return totals
end

function Requests.aggregateDetails(requests)
    local totals = aggregate(requests)
    local names = {}

    for name in pairs(totals) do
        table.insert(names, name)
    end

    table.sort(names)

    local parts = {}
    for _, name in ipairs(names) do
        table.insert(parts, name .. " x" .. tostring(totals[name]))
    end

    return #parts > 0 and table.concat(parts, ", ") or "-"
end

local function splitRequestBatches(requests)
    local batches = {}
    local batch = {}

    for _, item in ipairs(requests or {}) do
        table.insert(batch, {
            name = item.name,
            count = item.count
        })

        if #batch >= MAX_REQUEST_ITEMS then
            table.insert(batches, batch)
            batch = {}
        end
    end

    if #batch > 0 then
        table.insert(batches, batch)
    end

    return batches
end

-- How many cycles fit when one entry of an order carries at most 256 items.
local function maxCyclesPerEntry(requests)
    local result = nil

    for _, item in ipairs(requests or {}) do
        if type(item.name) == "string" and item.name ~= "" then
            local count = Requests.requestCount(item.count)
            local cycles = math.floor(MAX_REQUEST_COUNT / count)

            if cycles < 1 then
                return nil, "request item count exceeds " .. tostring(MAX_REQUEST_COUNT) .. ": " .. tostring(item.name)
            end

            result = result and math.min(result, cycles) or cycles
        end
    end

    return result or 1
end

function Requests.affordableCycles(requests, counts, desiredCycles)
    local totals = {}

    for _, item in ipairs(requests or {}) do
        if type(item.name) == "string" and item.name ~= "" then
            totals[item.name] = (totals[item.name] or 0) + Requests.requestCount(item.count)
        end
    end

    local desired = Requests.requestCount(desiredCycles)
    local result = desired

    for name, perCycle in pairs(totals) do
        local available = math.max(0, math.floor(tonumber((counts or {})[name]) or 0))
        result = math.min(result, math.floor(available / perCycle))
    end

    return math.max(0, result)
end

-- The orders (batches) for cycleCount cycles of a rule's items: each order
-- has at most nine entries of at most 256 items and whole cycles only.
-- orderLimit (optional): at most this many items in one order, so one order
-- is one package a small inventory (a depot holds one stack) can take
-- whole; Create unpacks a package only when all of it fits (2026-10-27).
function Requests.autoPlan(requests, cycleCount, orderLimit)
    local normalized = {}

    for _, item in ipairs(requests or {}) do
        if type(item.name) == "string" and item.name ~= "" then
            table.insert(normalized, {
                name = item.name,
                count = Requests.requestCount(item.count)
            })
        end
    end

    if #normalized == 0 then
        return {}, {}
    end

    local cycles = Requests.requestCount(cycleCount)
    local scaled = {}

    for _, item in ipairs(normalized) do
        table.insert(scaled, {
            name = item.name,
            count = item.count * cycles
        })
    end

    local batchRecipe = normalized

    -- One entry per item ID for a recipe of several entries, so every order
    -- carries whole cycles of the recipe ratio.
    if #normalized > 1 then
        local indexByName = {}
        batchRecipe = {}

        for _, item in ipairs(normalized) do
            local index = indexByName[item.name]
            if index then
                batchRecipe[index].count = batchRecipe[index].count + item.count
            else
                indexByName[item.name] = #batchRecipe + 1
                table.insert(batchRecipe, {
                    name = item.name,
                    count = item.count
                })
            end
        end
    end

    if #batchRecipe > MAX_REQUEST_ITEMS then
        return nil, nil, "too many request items: max " .. tostring(MAX_REQUEST_ITEMS)
    end

    local cyclesPerCopy, capacityErr = maxCyclesPerEntry(batchRecipe)
    if not cyclesPerCopy then
        return nil, nil, capacityErr
    end
    local perOrder = tonumber(orderLimit)
    if perOrder and perOrder >= 1 then
        local perCycle = 0
        for _, item in ipairs(batchRecipe) do perCycle = perCycle + item.count end
        cyclesPerCopy = math.max(1, math.min(cyclesPerCopy, math.floor(perOrder / perCycle)))
    end

    if #normalized > 1 then
        local batches = {}
        local remaining = cycles

        while remaining > 0 do
            local batch = {}
            local batchCycles = math.min(remaining, cyclesPerCopy)

            for _, item in ipairs(batchRecipe) do
                table.insert(batch, {
                    name = item.name,
                    count = item.count * batchCycles
                })
            end

            table.insert(batches, batch)
            remaining = remaining - batchCycles
        end

        return scaled, batches
    end

    local copiesPerBatch = (perOrder and perOrder >= 1) and 1
        or math.max(1, math.floor(MAX_REQUEST_ITEMS / #normalized))
    local cyclesPerBatch = cyclesPerCopy * copiesPerBatch
    local batches = {}
    local remaining = cycles

    while remaining > 0 do
        local batch = {}
        local batchCycles = math.min(remaining, cyclesPerBatch)
        local unassigned = batchCycles

        for _ = 1, copiesPerBatch do
            if unassigned <= 0 then break end
            local copyCycles = math.min(unassigned, cyclesPerCopy)

            for _, item in ipairs(normalized) do
                table.insert(batch, {
                    name = item.name,
                    count = item.count * copyCycles
                })
            end
            unassigned = unassigned - copyCycles
        end

        table.insert(batches, batch)
        remaining = remaining - batchCycles
    end

    return scaled, batches
end

function Requests.availablePlan(requests, counts, multipleOf)
    local multiple = multipleOf == nil and 1 or tonumber(multipleOf)
    assert(multiple and multiple >= 1 and multiple <= MAX_REQUEST_COUNT
        and multiple == math.floor(multiple),
        "export multipleOf must be an integer from 1 to " .. tostring(MAX_REQUEST_COUNT))
    local slotLimit = math.floor(MAX_REQUEST_COUNT / multiple) * multiple
    local result = {}
    local remainingByName = {}
    local requestedByName = {}
    local names = {}
    local total = 0

    for _, item in ipairs(requests or {}) do
        local name = item.name

        if type(name) == "string" and name ~= "" then
            if remainingByName[name] == nil then
                remainingByName[name] = math.max(0, math.floor(tonumber((counts or {})[name]) or 0))
                requestedByName[name] = 0
                table.insert(names, name)
            end

            local requested = item.count == "all" and remainingByName[name] or Requests.requestCount(item.count)
            local count = math.min(requested, remainingByName[name])
            remainingByName[name] = remainingByName[name] - count
            requestedByName[name] = requestedByName[name] + count
        end
    end

    for _, name in ipairs(names) do
        local count = math.floor(requestedByName[name] / multiple) * multiple
        while count > 0 do
            local chunk = math.min(slotLimit, count)
            table.insert(result, {
                name = name,
                count = chunk
            })
            total = total + chunk
            count = count - chunk
        end
    end

    return result, splitRequestBatches(result), total
end

function Requests.itemPlan(name, count)
    if type(name) ~= "string" or name == "" then
        return {}, {}, 0
    end

    local amount = math.max(0, math.floor(tonumber(count) or 0))
    local result = {}
    local remaining = amount

    while remaining > 0 do
        local chunk = math.min(MAX_REQUEST_COUNT, remaining)
        table.insert(result, {
            name = name,
            count = chunk
        })
        remaining = remaining - chunk
    end

    if #result == 0 then
        table.insert(result, {
            name = name,
            count = 0
        })
    end

    return result, splitRequestBatches(result), amount
end

-- The Stock Ticker filters of one order: one per item (and variant, by its
-- nbt hash) with the summed count; every filter of one requestFiltered call
-- is one order, packed in packages of nine stacks.
function Requests.tickerFilters(requests)
    if type(requests) ~= "table" or #requests == 0 then
        return nil, "request list empty"
    end

    local filters, byKey, total = {}, {}, 0

    for _, item in ipairs(requests) do
        local name = item.name
        local count = Requests.requestCount(item.count)

        if type(name) ~= "string" or name == "" then
            return nil, "request item name missing"
        end

        local key = name .. "\0" .. tostring(item.nbt or "")
        local filter = byKey[key]

        if filter then
            filter._requestCount = filter._requestCount + count
        else
            filter = {name = name, nbt = item.nbt, _requestCount = count}
            byKey[key] = filter
            table.insert(filters, filter)
        end

        total = total + count
    end

    return filters, nil, total
end

function Requests.firstMissing(counts, requests)
    local neededByName = {}
    local order = {}

    for _, item in ipairs(requests or {}) do
        local name = item.name
        local needed = Requests.requestCount(item.count)

        if type(name) == "string" and name ~= "" and needed > 0 then
            if neededByName[name] == nil then
                table.insert(order, name)
                neededByName[name] = 0
            end

            neededByName[name] = neededByName[name] + needed
        end
    end

    for _, name in ipairs(order) do
        local needed = neededByName[name] or 0
        local available = tonumber((counts or {})[name] or 0) or 0

        if available < needed then
            return {
                name = name,
                available = available,
                needed = needed
            }
        end
    end

    return nil
end

return Requests
