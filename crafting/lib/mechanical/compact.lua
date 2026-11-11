-- The compacting chest (PC191, owner 2026-11-07): a Sophisticated chest
-- with the compacting upgrade on "Compact Anything". What is delivered into
-- it is compacted at once (mechanical.compacting says which targets it
-- makes), so the ingredients never show in the chest: a batch is done when
-- the target has grown by what was ordered.
local Util = require("fleet_util")
local Compacting = require("mechanical.compacting")

local amount, failure = Util.amount, Util.failure

local Compact = {}
Compact.KIND = "compact"
Compact.TITLE = "Compacting Chest"
Compact.NO_RECIPE = "NO_COMPACT_RECIPE"

-- Sources per target, forgotten when Recipe Atlas publishes a new generation.
function Compact.find(station, target)
    local api = station.recipes
    local okMeta, meta = pcall(api and api.meta or error)
    local generation = okMeta and type(meta) == "table" and meta.generation or nil
    if generation ~= station.compactGeneration then station.compactCache, station.compactGeneration = {}, generation end
    station.compactCache = station.compactCache or {}
    if station.compactCache[target] == nil then
        local sources, why = Compacting.sources(api, target)
        if not sources and why and why:find("lookup failed", 1, true) then return nil, why end
        station.compactCache[target] = sources or why or false
    end
    local cached = station.compactCache[target]
    if type(cached) ~= "table" then return nil, tostring(cached) end
    return cached
end

function Compact.fits() return true end
function Compact.clear() return 0 end

-- Waits until the chest holds `want` of the target; returns what it holds.
local function waitTarget(station, target, want)
    local deadline = station.now() + (station.config.deliveryTimeout or 300)
    while true do
        local have = (station:chestCounts())[target] or 0
        if have >= want or station.now() >= deadline then return have end
        station.active.waitingFor = {name = target, missing = want - have}
        station:show("waiting_delivery", {item = target, have = have, need = want})
        station:beat("WAITING_DELIVERY")
        station.sleep(station.config.deliveryPollSeconds or 2)
    end
end

-- Asks PC48 for `count` of an ingredient (made elsewhere, sent here). A
-- second ask in the same job gets its own id: PC48 answers an id it knows
-- with its old reply, and nothing came (coal for diamonds, 2026-11-07).
local function supply(station, item, count)
    station:show("waiting_supply", {item = item, count = count})
    local active = station.active
    active.supplies = (active.supplies or 0) + 1
    local id = tostring(active.assignment) .. (active.supplies > 1 and (":" .. active.supplies) or "") .. ":" .. item
    local ok, err = station.delegate:supply({{name = item, count = count}}, station.config.address,
        {craft = true, exclude = Compact.KIND, phase = "WAITING_SUPPLY", id = id})
    station:log("station.supply", {item = item, count = count, ok = ok ~= nil, error = err and err.message})
    return ok, err
end

function Compact.runJob(station, job)
    local sources, why = Compact.find(station, job.target)
    if not sources then return nil, failure(Compact.NO_RECIPE, tostring(job.target) .. ": " .. tostring(why)) end
    if type(job.from) == "table" and #job.from > 0 then
        local only, kept = {}, {}
        for _, name in ipairs(job.from) do only[name] = true end
        for _, source in ipairs(sources) do if only[source.item] then kept[#kept + 1] = source end end
        if #kept == 0 then
            station:log("station.nothing", {why = "no recipe takes the from list", from = job.from})
            return {ok = true, craftedOutput = 0}
        end
        sources = kept
    end
    local active = station.active
    local target = job.target
    active.recipeId = sources[1].recipeId
    while amount(active.crafted) < active.count do
        local available, _, maxCounts = station:available(job.all, job.from, job.keep)
        local remaining = active.count - amount(active.crafted)
        local stacksLeft = station.config.batchStacks or 45
        local need, outputs = {}, 0
        for _, source in ipairs(sources) do
            local crafts = math.ceil((remaining - outputs) / source.perCraft)
            local max = math.max(1, maxCounts[source.item] or 64)
            crafts = math.min(crafts, math.floor((available[source.item] or 0) / source.cells),
                math.floor(stacksLeft * max / source.cells))
            if crafts > 0 then
                need[source.item] = crafts * source.cells
                outputs = outputs + crafts * source.perCraft
                stacksLeft = stacksLeft - math.ceil(crafts * source.cells / max)
            end
            if outputs >= remaining or stacksLeft <= 0 then break end
        end
        local before = (station:chestCounts())[target] or 0
        -- A full batch: what is left, up to what one batch holds.
        local source = sources[1]
        local fullCrafts = math.min(math.ceil(remaining / source.perCraft),
            math.max(1, math.floor((station.config.batchStacks or 45) * 64 / source.cells)))
        local full = math.min(remaining, fullCrafts * source.perCraft)
        local supplied
        if outputs > 0 and outputs < full and not job.all and not active.noSupply then
            -- Short of a full batch: PC48 has the rest made instead of the
            -- chest compacting the few in stock a handful at a time (iron
            -- ingots never made from the nuggets, owner 2026-11-08). When
            -- nobody can, what is in stock is used and nothing more asked.
            local crafts = math.ceil((full - outputs) / source.perCraft)
            local ok, err = supply(station, source.item, crafts * source.cells)
            if ok then
                supplied = crafts * source.perCraft
            else
                active.noSupply = true
                station:log("station.supply_short", {outputs = outputs, full = full, error = err and err.message})
            end
        end
        if supplied then
            outputs = supplied
        elseif outputs == 0 then
            if job.all then
                if amount(active.crafted) == 0 then
                    local seen = {}
                    for _, source in ipairs(sources) do seen[#seen + 1] = source.item .. "=" .. (available[source.item] or 0) end
                    station:log("station.nothing", {why = "none in stock", accepts = table.concat(seen, " ")})
                end
                break
            end
            -- All it needs at once, as much as one batch holds: each ask is a
            -- trip round the machines that make it.
            local ok, err = supply(station, source.item, fullCrafts * source.cells)
            if not ok then return nil, err end
            outputs = fullCrafts * source.perCraft
        else
            active.phase = "ORDERING"
            station:show("ordering", {crafts = outputs, target = target})
            local ordered, orderError = station:order(need, maxCounts)
            if not ordered then return nil, orderError end
        end
        local have = waitTarget(station, target, before + outputs)
        local made = math.max(0, have - before)
        if made > 0 then
            active.crafted = amount(active.crafted) + made
            station:save()
        end
        station:log("compact.batch", {target = target, expected = outputs, made = made})
        if made < outputs then
            local counts = station:chestCounts()
            local stuck = {}
            for _, source in ipairs(sources) do
                if (counts[source.item] or 0) >= source.cells then stuck[#stuck + 1] = source.item .. " x" .. counts[source.item] end
            end
            station:ship("failure")
            if #stuck > 0 then
                return nil, failure("COMPACT_FAILED", "the chest did not compact " .. table.concat(stuck, ", ")
                    .. " (the upgrade must be on Compact Anything)")
            end
            return nil, failure("DELIVERY_TIMEOUT", "waited for " .. target .. ": " .. made .. "/" .. outputs,
                {target = target, needed = outputs - made})
        end
        local shipped, shipError = active.depth and true or station:ship("batch")
        if not shipped then station:log("station.output_waiting", {reason = shipError}) end
    end
    return {ok = true, craftedOutput = amount(active.crafted), recipeId = active.recipeId}
end

return Compact
