-- Finds a station's blocks on its wired network (owner 2026-10-28: stations
-- find their machines themselves and use all of them). A wired modem names
-- a block "<block id>_<n>" (create:saw_3); a peripheral with a CC type of
-- its own (Create_StockTicker) is found by that type. Anything else on the
-- cable (a hopper, a stray chest) is ignored.
local Util = require("fleet_util")

local Devices = {}

local function names(api)
    local ok, list = pcall(api.getNames)
    return ok and type(list) == "table" and list or {}
end

-- Every "<blockId>_<n>" on the network, by n.
function Devices.named(api, blockId)
    local found = {}
    local prefix = blockId .. "_"
    for _, name in ipairs(names(api)) do
        local n = name:sub(1, #prefix) == prefix and tonumber(name:sub(#prefix + 1))
        if n then found[#found + 1] = {name = name, n = n} end
    end
    table.sort(found, function(a, b) return a.n < b.n end)
    local out = {}
    for index, entry in ipairs(found) do out[index] = entry.name end
    return out
end

local function hasType(api, name, ccType)
    if type(api.hasType) == "function" then
        local ok, yes = pcall(api.hasType, name, ccType)
        if ok then return yes == true end
    end
    local ok, value = pcall(api.getType, name)
    return ok and value == ccType
end

-- The peripheral of a CC type: the configured name, else the first found.
-- One block on two modems shows under two names (a ticker, a double chest),
-- so several names are not an error. Returns the name, or nil and a failure.
function Devices.one(api, configured, ccType)
    if configured then return configured end
    local found = {}
    for _, name in ipairs(names(api)) do
        if hasType(api, name, ccType) then found[#found + 1] = name end
    end
    table.sort(found)
    if #found == 0 then return nil, Util.failure("PERIPHERAL_MISSING", "no " .. ccType .. " on the network") end
    return found[1]
end

-- Barrels and chests on the cable (not machines, turtles or packagers).
function Devices.storages(api)
    local found = {}
    for _, name in ipairs(names(api)) do
        if name:find("^sophisticatedstorage:") or name:find("^minecraft:barrel_") or name:find("^minecraft:chest_") then
            found[#found + 1] = name
        end
    end
    table.sort(found)
    return found
end

local function count(api, name, item)
    local ok, list = pcall(api.call, name, "list")
    local total = 0
    for _, stack in pairs(ok and type(list) == "table" and list or {}) do
        if stack.name == item then total = total + Util.amount(stack.count) end
    end
    return total
end

-- Which storage and packager are this worker's, when several share a cable
-- and none can be told apart by name (owner 2026-10-28: workers find their
-- blocks themselves). Orders `o.count` of `o.marker` to `o.address`, a count
-- no other worker uses: the storage that gains exactly that many (or a
-- multiple, after a repeated order) is the one deliveries land in, and the
-- packager listing them is the one on it (a packager lists its inventory).
-- o: ticker, address, count, marker?, seconds?, sleep, clock, log?.
-- Returns storage, packager, or nil and why.
function Devices.locate(api, o)
    local watch = Devices.storages(api)
    local packagers = {}
    for _, name in ipairs(names(api)) do
        if hasType(api, name, "Create_Packager") then packagers[name] = true; watch[#watch + 1] = name end
    end
    local marker = o.marker or "minecraft:cobblestone"
    local before = {}
    for _, name in ipairs(watch) do before[name] = count(api, name, marker) end
    local deadline, nextOrder = o.clock() + (o.seconds or 90), 0
    while o.clock() < deadline do
        if o.clock() >= nextOrder then
            pcall(o.ticker.requestFiltered, o.address, {name = marker, _requestCount = o.count})
            nextOrder = o.clock() + 30
            if o.log then o.log("devices.locating", {address = o.address, marker = marker, count = o.count}) end
        end
        o.sleep(2)
        local storage, packager
        for _, name in ipairs(watch) do
            local gained = count(api, name, marker) - before[name]
            if gained > 0 and gained % o.count == 0 then
                if packagers[name] then packager = packager or name else storage = storage or name end
            end
        end
        if storage and packager then return storage, packager end
    end
    return nil, "the marker never reached a storage and packager at " .. tostring(o.address)
end

return Devices
