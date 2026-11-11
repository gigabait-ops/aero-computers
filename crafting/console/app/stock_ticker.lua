-- The checklist's warehouse: a Create Stock Ticker on PC66's wired network
-- (as PC46's, 46/app/stock_reader.lua and 46/app/orderer.lua): one detailed
-- stock read for the counts and the stack limits app.shipping needs, and
-- the ticker orders that send what is in stock to the checklist address.
local Shipping = require("app.shipping")
local Util = require("app.util")

local StockTicker = {}

local function requestCount(value)
    return math.max(1, math.floor(tonumber(value) or 1))
end

-- source: {name, device}. Returns {ok, counts, metadata, used, error}.
function StockTicker.read(source)
    local device = source and source.device
    if not device or type(device.stock) ~= "function" then
        return {ok = false, error = "no stock ticker found", counts = {}, metadata = {}}
    end

    local ok, stock = pcall(device.stock, true)
    if not ok then
        return {ok = false, error = tostring(stock), counts = {}, metadata = {}}
    end

    local counts, metadata, used = {}, {}, 0
    for _, item in pairs(type(stock) == "table" and stock or {}) do
        if type(item) == "table" and type(item.name) == "string" then
            local count = tonumber(item.count) or 0
            counts[item.name] = (counts[item.name] or 0) + count
            used = used + count
            Shipping.record(metadata, item)
        end
    end

    return {ok = true, counts = counts, metadata = metadata, used = used}
end

-- One fresh stock read: item -> count over all its variants.
local function stockCounts(ticker)
    local ok, stock = pcall(ticker.stock, false)
    if not ok then return nil, tostring(stock) end
    if type(stock) ~= "table" then return nil, "invalid stock snapshot" end
    local counts = {}
    for _, stack in pairs(stock) do
        if type(stack) == "table" and type(stack.name) == "string" then
            local count = tonumber(stack.count)
            if count and count >= 0 and count < math.huge then
                counts[stack.name] = (counts[stack.name] or 0) + math.floor(count)
            end
        end
    end
    return counts
end

-- The ticker orders what it finds, so the stock is checked right before
-- it: each entry is bounded to what is in stock, one that is not there is
-- left out.
local function boundedRequests(ticker, requests)
    local counts, err = stockCounts(ticker)
    if not counts then return nil, err end
    local needed, order = {}, {}
    for _, entry in ipairs(requests) do
        if not needed[entry.name] then order[#order + 1] = entry.name end
        needed[entry.name] = (needed[entry.name] or 0) + requestCount(entry.count)
    end
    local bounded = {}
    for _, name in ipairs(order) do
        local count = math.min(needed[name], counts[name] or 0)
        if count > 0 then bounded[#bounded + 1] = {name = name, count = count} end
    end
    return bounded
end

-- One filter per item (a filter by name takes any variant of it, as the
-- schematicannon does).
local function filters(requests)
    local list, byName, total = {}, {}, 0
    for _, item in ipairs(requests) do
        local count = requestCount(item.count)
        local filter = byName[item.name]
        if filter then
            filter._requestCount = filter._requestCount + count
        else
            filter = {name = item.name, _requestCount = count}
            byName[item.name] = filter
            list[#list + 1] = filter
        end
        total = total + count
    end
    return list, total
end

local function details(requests)
    local parts = {}
    for _, item in ipairs(requests or {}) do parts[#parts + 1] = tostring(item.name) .. " x" .. tostring(item.count) end
    return #parts > 0 and table.concat(parts, ", ") or "-"
end

-- A checklist shipment: one requestFiltered call. job: {address, requests,
-- canDispatch}; canDispatch() false (the clipboard session ended meanwhile)
-- ships nothing. Returns ok, err, accepted, summary and per item what went
-- out: all of it when the ticker took the whole order, otherwise the
-- accepted total in list order (it does not say which).
function StockTicker.order(source, job, logger)
    local ticker = source and source.device
    if not ticker or type(ticker.requestFiltered) ~= "function" or type(ticker.stock) ~= "function" then
        return false, "stock ticker missing"
    end

    local requests, why = boundedRequests(ticker, job.requests or {})
    if not requests then return false, why end
    if #requests == 0 then return true, nil, 0, "waiting for stock", {} end

    local list, total = filters(requests)
    if type(job.canDispatch) ~= "function" or not job.canDispatch() then
        return false, "clipboard session ended before dispatch"
    end

    local ok, accepted = pcall(ticker.requestFiltered, job.address or "", table.unpack(list))
    if not ok then
        return false, tostring(accepted)
    end
    if type(accepted) ~= "number" or accepted < 0 or accepted > total or accepted ~= math.floor(accepted) then
        return false, "invalid Stock Ticker request count"
    end

    local submitted, left = {}, accepted
    for _, filter in ipairs(list) do
        local count = math.min(filter._requestCount, left)
        submitted[filter.name] = (submitted[filter.name] or 0) + count
        left = left - count
    end

    Util.log(logger, accepted < total and "warn" or "info", "ticker.order_sent", {
        key = job.key, address = job.address, ticker = source.name, filters = #list,
        requested = total, accepted = accepted, items = details(requests),
    })

    return true, nil, accepted, details(requests), submitted
end

return StockTicker
