-- The slicer machine (PC137, 2026-10-27): Slice & Dice slicers run Farmer's
-- Delight cutting recipes (sliceanddice:cutting) on the depot under them,
-- with the recipe's tool in the slicer (axe for logs -> stripped log + tree
-- bark, knife for fish and meat, shears for leather goods; shears are in the
-- sliceanddice:allowed_tools tag since 2026-10-28). Every slicer and depot on
-- the network is used (owner 2026-10-28): each slicer gets a tool, every
-- depot gets input, and a depot whose input is not cut (its slicer has no
-- tool) gets it back. Tools wear down; a broken one is replaced from the chest.
local Util = require("fleet_util")
local Recipe = require("mechanical.recipe")
local JobKind = require("controller.job_kind")
local Devices = require("mechanical.devices")
local Feed = require("mechanical.feed")

local amount, failure = Util.amount, Util.failure

local Slicer = {}
Slicer.KIND = "slicer"
Slicer.TITLE = "Slicer Station"
Slicer.NO_RECIPE = "NO_SLICER_RECIPE"

-- Tool kind per Farmer's Delight cutting recipe (generated, see the file).
local toolKinds
local function toolKind(recipeId)
    if not toolKinds then
        toolKinds = {}
        local ok, data = pcall(require, "mechanical.slicer_tools")
        for kind, list in pairs(ok and type(data) == "table" and data or {}) do
            for id in tostring(list):gmatch("%S+") do toolKinds[id] = kind end
        end
    end
    -- sliceanddice:cutting/farmersdelight/cutting/oak_log -> farmersdelight:cutting/oak_log
    local ns, path = tostring(recipeId):match("^sliceanddice:cutting/([^/]+)/(.+)$")
    return ns and toolKinds[ns .. ":" .. path]
end
Slicer.toolKind = toolKind

-- Does an item fit a tool kind (by its ID: iron_axe, iron_knife, ...)?
local PATTERNS = {axe = "_axe$", knife = "knife", shovel = "_shovel$", pickaxe = "_pickaxe$",
    shears = "shears$", hoe = "_hoe$", sword = "_sword$"}
function Slicer.toolFits(kind, name)
    local pattern = PATTERNS[kind]
    if not pattern or type(name) ~= "string" then return false end
    if kind == "axe" and name:find("_pickaxe$") then return false end
    return name:find(pattern) ~= nil
end

-- The tool the station uses: exactly config.tools[kind] when set (owner
-- 2026-10-27: diamond tools only), else any tool of that kind.
local function usable(station, kind, name)
    local wanted = (station.config.tools or {})[kind]
    if wanted then return name == wanted end
    return Slicer.toolFits(kind, name)
end

-- Also recipes where the target is a later output (tree bark from a log).
function Slicer.find(station, target, blocked)
    local list, why = Recipe.find(station.recipes, target, blocked, JobKind.SLICER_TYPE, Recipe.fromMachine, true)
    if not list then return nil, why end
    local known = {}
    for _, recipe in ipairs(list) do
        recipe.tool = toolKind(recipe.id)
        if recipe.tool then known[#known + 1] = recipe end
    end
    if #known == 0 then return nil, "no slicer recipe with a known tool" end
    return known
end

function Slicer.fits() return true end

local function wrapAll(station, names)
    local list = {}
    for _, name in ipairs(names) do
        local ok, device = pcall(station.wrap, station, name)
        if ok and device then list[#list + 1] = {name = name, device = device} end
    end
    return list
end

-- The slicers and depots on the network now.
local function machines(station)
    local slicers = wrapAll(station, station.config.slicers or Devices.named(station.peripheral, "sliceanddice:slicer"))
    local depots = wrapAll(station, station.config.depots or Devices.named(station.peripheral, "create:depot"))
    if #slicers == 0 or #depots == 0 then
        error(failure("PERIPHERAL_MISSING", "no slicer and depot on the network"), 0)
    end
    return slicers, depots
end

local function toolIn(slicer) return (slicer.device.list() or {})[1] end

-- A `kind` tool from the chest into a slicer (its other tool goes to the
-- chest). True when it holds one now. A tool the slicer refuses goes back,
-- and so does the old one.
local function fitTool(station, slicer, kind)
    local tool = toolIn(slicer)
    if tool and usable(station, kind, tool.name) then return true end
    local chestName = station.chestName
    for slot, item in pairs(station:chest().list() or {}) do
        if usable(station, kind, item.name) then
            if tool then slicer.device.pushItems(chestName, 1) end
            if (slicer.device.pullItems(chestName, slot, 1, 1) or 0) == 1 then return true end
            if tool then
                for back, other in pairs(station:chest().list() or {}) do
                    if other.name == tool.name then slicer.device.pullItems(chestName, back, 1, 1); break end
                end
            end
            station:log("slicer.tool_refused", {tool = item.name, slicer = slicer.name})
            return false
        end
    end
    return false
end

-- How good a stocked tool is: its enchantments (Unbreaking counts most)
-- and how much durability it has left.
local function toolScore(detail)
    local score = 0
    for _, e in pairs(type(detail) == "table" and detail.enchantments or {}) do
        local level = tonumber(e.level) or 1
        score = score + level * (tostring(e.name):find("unbreaking") and 3 or 1)
    end
    local maxDamage = tonumber(detail and detail.maxDamage) or 0
    if maxDamage > 0 then score = score + 2 * (1 - (tonumber(detail.damage) or 0) / maxDamage) end
    return score
end

local function chestHas(station, kind)
    local count = 0
    for _, item in pairs(station:chest().list() or {}) do
        if usable(station, kind, item.name) then count = count + amount(item.count) end
    end
    return count
end

-- Orders up to `count` of the best stocked variants of `item` (enchanted
-- and worn ones count, owner 2026-10-27) and waits for them in the chest.
-- Returns how many arrived.
local function orderStockedTools(station, item, kind, count)
    local ticker = station:ticker()
    local ok, list = pcall(ticker.stock, true)
    if not ok or type(list) ~= "table" then return 0 end
    local ranked = {}
    for slot, entry in pairs(list) do
        if type(entry) == "table" and entry.name == item and amount(entry.count) > 0 then
            local detail = type(ticker.getStockItemDetail) == "function"
                and select(2, pcall(ticker.getStockItemDetail, slot)) or nil
            ranked[#ranked + 1] = {entry = entry, score = toolScore(detail)}
        end
    end
    if #ranked == 0 then return 0 end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    local before, wanted = chestHas(station, kind), 0
    for _, candidate in ipairs(ranked) do
        if wanted >= count then break end
        local take = math.min(count - wanted, amount(candidate.entry.count))
        local filter = {name = item, nbt = candidate.entry.nbt, _requestCount = take}
        local sent = select(2, pcall(ticker.requestFiltered, station.config.address, filter))
        station:log("slicer.tool_ordered", {item = item, nbt = candidate.entry.nbt, score = candidate.score,
            count = take, accepted = sent})
        wanted = wanted + take
    end
    local deadline = station.now() + (station.config.deliveryTimeout or 300)
    while station.now() < deadline do
        if chestHas(station, kind) - before >= wanted then break end
        station:beat("WAITING_TOOL")
        station.sleep(station.config.deliveryPollSeconds or 2)
    end
    return chestHas(station, kind) - before
end

-- What the station needs besides the ingredients: a tool of the recipe's
-- kind for every slicer. The best stocked ones are fetched here; with none
-- anywhere, one is asked for (PC48 has it made).
function Slicer.extraNeed(station, recipe)
    local slicers = machines(station)
    local have = chestHas(station, recipe.tool)
    for _, slicer in ipairs(slicers) do
        local tool = toolIn(slicer)
        if tool and usable(station, recipe.tool, tool.name) then have = have + 1 end
    end
    if have >= #slicers then return {} end
    local item = (station.config.tools or {})[recipe.tool]
    if not item then
        if have > 0 then return {} end
        return nil, failure("TOOL_MISSING", "no " .. tostring(recipe.tool) .. " for the slicer")
    end
    have = have + orderStockedTools(station, item, recipe.tool, #slicers - have)
    if have > 0 then return {} end
    return {[item] = 1}
end

local function isInput(recipe, name)
    for _, accepted in ipairs(recipe.cells[1].accepts) do
        if accepted == name then return true end
    end
    return false
end

function Slicer.clear(station)
    local left = 0
    local ok, _, depots = pcall(machines, station)
    for _, depot in ipairs(ok and depots or {}) do left = left + Feed.empty(station, depot.device) end
    return left
end

-- `batch` cuts over every depot. Returns the target count that reached the chest.
function Slicer.batch(station, recipe, batch)
    local slicers, depots = machines(station)
    local fitted = 0
    for _, slicer in ipairs(slicers) do
        if fitTool(station, slicer, recipe.tool) then fitted = fitted + 1 end
    end
    if fitted == 0 then
        return nil, failure("TOOL_MISSING", "no " .. tostring(recipe.tool) .. " left for the slicer")
    end
    local before = (station:chestCounts())[recipe.target] or 0
    local accepts = recipe.cells[1].accepts
    local function inputLeft(depot)
        local count = 0
        for _, item in pairs(depot.device.list() or {}) do
            if isInput(recipe, item.name) then count = count + amount(item.count) end
        end
        return count
    end
    local fed, err = Feed.run(station, depots, batch * #recipe.cells, recipe, {
        stallCode = "TOOL_MISSING",
        stallMessage = "no slicer cut " .. accepts[1] .. " (no " .. tostring(recipe.tool) .. " left?)",
        input = inputLeft,
        -- The depot keeps the first output in slot 1 (seen 2026-10-27).
        collect = function(depot)
            Feed.empty(station, depot.device, function(_, item) return isInput(recipe, item.name) end)
        end,
        giveBack = function(depot) Feed.empty(station, depot.device) end,
        feed = function(depot, want) return Feed.give(station, depot.device, accepts, want, 1) end,
        -- A tool that broke mid-way: fit a spare.
        tend = function()
            for _, slicer in ipairs(slicers) do
                if not toolIn(slicer) then fitTool(station, slicer, recipe.tool) end
            end
        end,
    })
    if not fed then
        Slicer.clear(station)
        return nil, err
    end
    local made = ((station:chestCounts())[recipe.target] or 0) - before
    if made <= 0 then
        return nil, failure("CRAFT_TIMEOUT", "no " .. recipe.target .. " came out of the slicer")
    end
    return made
end

return Slicer
