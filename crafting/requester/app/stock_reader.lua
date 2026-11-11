-- The warehouse stock: one detailed read of every Stock Ticker on the
-- network (counts per item, plus the metadata the row sorting and the
-- shipping pacing need). There is no other stock source.
local StockReader = {}
StockReader.__index = StockReader

local Sorting = require("app.sorting")
local Shipping = require("app.shipping")

function StockReader:new()
    return setmetatable({}, self)
end

function StockReader:readTicker(source, counts, metadata)
    local device = source.device

    if not device or type(device.stock) ~= "function" then
        return nil, "stock api missing"
    end

    local ok, stock = pcall(device.stock, true)

    if not ok then
        return nil, tostring(stock)
    end

    local used = 0

    for _, item in pairs(type(stock) == "table" and stock or {}) do
        if type(item) == "table" and type(item.name) == "string" then
            local count = tonumber(item.count) or 0
            counts[item.name] = (counts[item.name] or 0) + count
            used = used + count
            Sorting.mergeMetadata(metadata, item)
            Shipping.record(metadata, item)
        end
    end

    return {name = source.name, used = used}
end

-- registry: Bus:scan()'s registry.
function StockReader:read(registry)
    local counts, metadata, sources, errors = {}, {}, {}, {}

    for _, source in ipairs((registry or {}).stockTickerList or {}) do
        local report, err = self:readTicker(source, counts, metadata)

        if report then
            table.insert(sources, report)
        else
            table.insert(errors, tostring(source.name) .. ": " .. err)
        end
    end

    local used = 0

    for _, source in ipairs(sources) do
        used = used + source.used
    end

    return {
        ok = #sources > 0,
        error = #sources == 0 and (errors[1] or "no stock ticker found") or nil,
        counts = counts,
        metadata = metadata,
        sources = sources,
        used = used
    }
end

return StockReader
