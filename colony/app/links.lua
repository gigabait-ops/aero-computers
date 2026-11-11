-- Colony Supply: what is connected and how. Finds the colony integrator, the
-- Create storage ticker, the optional colony ticker, the colony warehouse and
-- the chests, and describes each link as a row for the Home tab.
--
-- Two ways to wire a colony, freely mixed:
--   cable   - wired modems on the warehouse hut, the inbox and outbox chests
--   tickers - one ticker on the Create storage network (always needed) and an
--             optional one on the colony's own network, whose packager sits on
--             the warehouse hut: it shows what the colony holds and ships the
--             extra to Create storage
-- Pure: the peripheral API is injected.
local Links = {}

local TICKER = "Create_StockTicker"
local WAREHOUSE = "minecolonies:warehouse"

local function named(api, setting, ptype)
    if setting == false or setting == nil then return nil end
    if setting ~= "auto" then
        local p = api.wrap(setting)
        if p == nil then return nil, setting end
        return p, setting
    end
    local p = api.find(ptype)
    if p == nil then return nil end
    return p, api.getName(p)
end

local function tickers(api)
    local list = {}
    for _, name in ipairs(api.getNames()) do
        if api.hasType(name, TICKER) then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

-- what a ticker sees: its kinds, a fingerprint (two tickers on one Create
-- network see the same stock) and the item names
local function look(api, name)
    local ok, list = pcall(api.call or function(n, m) return api.wrap(n)[m]() end, name, "stock")
    local seen = {name = name, kinds = 0, total = 0, names = {}}
    if not ok or type(list) ~= "table" then return seen end
    for _, e in pairs(list) do
        if type(e) == "table" and e.name then
            if not seen.names[e.name] then seen.kinds = seen.kinds + 1 end
            seen.names[e.name] = true
            seen.total = seen.total + (tonumber(e.count) or 0)
        end
    end
    seen.print = seen.kinds .. ":" .. seen.total
    return seen
end

-- How much of the warehouse hut a ticker sees (the colony's packager sits on
-- it): nil without a cable, else the share of the hut's kinds, 0..1
local function share(warehouse, seen)
    if not warehouse or type(warehouse.list) ~= "function" then return nil end
    local ok, slots = pcall(warehouse.list)
    if not ok or type(slots) ~= "table" then return nil end
    local all, hit, counted = 0, 0, {}
    for _, e in pairs(slots) do
        if type(e) == "table" and e.name and not counted[e.name] then
            counted[e.name] = true
            all = all + 1
            if seen.names[e.name] then hit = hit + 1 end
        end
    end
    if all == 0 then return 1 end
    return hit / all
end

-- "Create_StockTicker_15" -> "ticker 15", "sophisticatedstorage:chest_0" -> "chest 0"
function Links.short(name)
    name = tostring(name or "")
    local kind, number = name:match("([%a]+)_(%d+)$")
    if kind == "StockTicker" then return "ticker " .. number end
    if kind and number then return kind:lower() .. " " .. number end
    return name
end

-- row levels: ok (green), off (grey, optional and not used), warn, bad
local function row(list, label, level, value)
    list[#list + 1] = {label = label, level = level, value = value}
end

-- Finds every link from the settings. Returns a table with the wrapped
-- peripherals, their names, the chosen ways and the Home rows; `fatal` is set
-- when the program cannot run at all (no integrator or no Create ticker).
function Links.find(cfg, api)
    local L = {rows = {}}
    local colony, create, send = cfg.colony, cfg.create, cfg.send

    L.integrator, L.integratorName = named(api, colony.integrator, "colony_integrator")
    if not L.integrator then
        L.fatal = "Colony Integrator not found: place it next to the computer, inside the colony"
    end

    -- the colony warehouse on a cable
    if colony.warehouse ~= false then
        L.warehouse, L.warehouseName = named(api, colony.warehouse, WAREHOUSE)
    end

    -- tickers. A name that is gone (the computer moved, a modem placed again)
    -- is found again by what the ticker sees, so a restart always takes the
    -- tickers that are really there:
    --   Create storage - the ticker that sees the most
    --   colony ticker  - another network (not the storage's stock) that sees
    --                    the warehouse hut's items when the hut is on a cable
    local all, seen = tickers(api), {}
    local function of(name)
        seen[name] = seen[name] or look(api, name)
        return seen[name]
    end
    local function isName(name) return type(name) == "string" and name ~= "auto" end
    local function exists(name) return isName(name) and api.wrap(name) ~= nil end
    -- one name gone means the ids moved: the other name may now belong to
    -- the wrong ticker, so both are found again
    local stale = (isName(create.ticker) and not exists(create.ticker))
        or (isName(colony.ticker) and not exists(colony.ticker))
    local wantColony = colony.ticker ~= false and colony.ticker ~= nil
    if not stale and exists(colony.ticker) then L.colonyTickerName = colony.ticker end
    if not stale and exists(create.ticker) then
        L.tickerName = create.ticker
    else
        local most = -1
        for _, name in ipairs(all) do
            if name ~= L.colonyTickerName and of(name).kinds > most then L.tickerName, most = name, of(name).kinds end
        end
        if isName(create.ticker) and L.tickerName ~= create.ticker then L.tickerFound = create.ticker end
    end
    if wantColony and not L.colonyTickerName and L.tickerName then
        local best, bestShare, many = nil, -1, 0
        for _, name in ipairs(all) do
            if name ~= L.tickerName and of(name).print ~= of(L.tickerName).print then
                local s = share(L.warehouse, of(name))
                if s == nil or s >= 0.5 then
                    many = many + 1
                    if (s or 0) > bestShare then best, bestShare = name, s or 0 end
                end
            end
        end
        -- without a cable to compare with, two candidates are a guess: take none
        if many == 1 or (many > 1 and L.warehouse) then
            L.colonyTickerName = best
            if isName(colony.ticker) and best ~= colony.ticker then L.colonyTickerFound = colony.ticker end
        end
    end
    L.ticker = L.tickerName and api.wrap(L.tickerName) or nil
    L.colonyTicker = L.colonyTickerName and api.wrap(L.colonyTickerName) or nil
    local spare = #all - (L.ticker and 1 or 0) - (L.colonyTicker and 1 or 0)

    if not L.ticker then
        L.fatal = L.fatal or "Create storage ticker not found: connect it with a wired modem"
        row(L.rows, "Create storage", "bad", "no ticker")
    elseif L.tickerFound then
        row(L.rows, "Create storage", "warn", Links.short(L.tickerName) .. " (was " .. Links.short(L.tickerFound) .. ")")
    elseif create.ticker == "auto" and spare > 0 then
        row(L.rows, "Create storage", "warn", Links.short(L.tickerName) .. ", " .. #all .. " tickers: set sklad.tiker")
    else
        row(L.rows, "Create storage", "ok", Links.short(L.tickerName))
    end
    if wantColony and not L.colonyTicker then
        row(L.rows, "Colony ticker", "bad", colony.ticker ~= "auto" and ("not found: " .. tostring(colony.ticker))
            or "not found")
    elseif L.colonyTickerFound then
        row(L.rows, "Colony ticker", "warn", Links.short(L.colonyTickerName) .. " (was "
            .. Links.short(L.colonyTickerFound) .. ")")
    elseif L.colonyTicker then
        row(L.rows, "Colony ticker", "ok", Links.short(L.colonyTickerName))
    else
        row(L.rows, "Colony ticker", "off", "none (optional)")
    end
    if L.warehouse then
        row(L.rows, "Colony storage", "ok", "cable")
        L.colonyView = "cable"
    elseif L.colonyTicker then
        row(L.rows, "Colony storage", "ok", "seen by the colony ticker")
        L.colonyView = "ticker"
    else
        row(L.rows, "Colony storage", "warn", "not seen: Keep, Build and Send are off")
    end

    -- deliveries: straight into the warehouse, or an inbox chest the computer empties
    L.delivery = colony.delivery == "direct" and "direct" or "chest"
    if L.delivery == "direct" then
        row(L.rows, "Delivery", "ok", "straight to the warehouse")
    elseif not colony.inbox then
        row(L.rows, "Delivery", "bad", "no inbox chest set")
    else
        L.inbox = api.wrap(colony.inbox)
        L.inboxName = L.inbox and colony.inbox or nil
        if not L.inbox then
            row(L.rows, "Delivery", "bad", "inbox not found: " .. tostring(colony.inbox))
        elseif not L.warehouse then
            row(L.rows, "Delivery", "bad", "inbox, but no cable to the warehouse")
        else
            row(L.rows, "Delivery", "ok", "into " .. Links.short(colony.inbox))
        end
    end

    -- sending extra items to Create storage
    if not send.enabled then
        row(L.rows, "Send out", "off", "off")
    else
        local by = send.by
        if by == "auto" then by = L.colonyTicker and "ticker" or (send.outbox and "chest" or nil) end
        if by == "ticker" then
            if L.colonyTicker then
                L.sendBy = "ticker"
                row(L.rows, "Send out", "ok", "by the colony ticker to " .. tostring(send.to))
            else
                row(L.rows, "Send out", "bad", "needs the colony ticker")
            end
        elseif by == "chest" then
            L.outbox = send.outbox and api.wrap(send.outbox) or nil
            L.outboxName = L.outbox and send.outbox or nil
            if not L.outbox then
                row(L.rows, "Send out", "bad", send.outbox and ("outbox not found: " .. tostring(send.outbox))
                    or "no outbox chest set")
            elseif not L.warehouse then
                row(L.rows, "Send out", "bad", "outbox, but no cable to the warehouse")
            else
                L.sendBy = "chest"
                row(L.rows, "Send out", "ok", "into " .. Links.short(send.outbox))
            end
        else
            row(L.rows, "Send out", "off", "not linked (optional)")
        end
    end
    return L
end

-- What the colony holds, as an inventory-like view with list(): the warehouse
-- hut on a cable (exact), else the colony ticker's network stock.
function Links.colonyView(L, cached)
    if L.warehouse then return cached(L.warehouse) end
    if L.colonyTicker then
        local ticker = L.colonyTicker
        return cached({list = function() return ticker.stock() end})
    end
    return nil
end

return Links
