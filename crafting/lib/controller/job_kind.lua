-- Which kind of worker can make a target. A stonecutting target goes to
-- the saws; any other with a crafting-table recipe stays with the turtles;
-- otherwise the station whose machine makes
-- it: the mechanical crafter (PC134), the saws (PC136, stonecutting and
-- Create cutting), the slicers (PC137, Slice & Dice cutting) or the basins
-- (PC150); else a Create machine without a computer (owner 2026-11-02: a
-- fan, crushing wheels, a press), listed with its address in PC48's
-- settings `machines`: PC48 sends it the inputs and waits for the output in
-- the warehouse (controller.supplier). What makes a target comes from one
-- Recipe Atlas producers() list per target and recipe generation. Without
-- the module, or on any recipe error, a job stays a turtle job.
local Compacting = require("mechanical.compacting")
local Producers = require("autocrafter.producers")
local DyeFan = require("controller.dye_fan")

local JobKind = {}
JobKind.__index = JobKind

JobKind.TURTLE = "turtle"
JobKind.MACHINE = "machine"
JobKind.MECHANICAL = "mechanical"
JobKind.MECHANICAL_TYPE = "create:mechanical_crafting"
JobKind.SAW = "saw"
JobKind.SAW_TYPES = {"minecraft:stonecutting", "create:cutting"}
-- Slice & Dice slicers (PC137): Farmer's Delight cutting, by any output
-- (tree bark is the second output of stripping a log).
JobKind.SLICER = "slicer"
JobKind.SLICER_TYPE = "sliceanddice:cutting"
-- Create basins (PC150): mixing (with Slice & Dice cooking) and compacting.
JobKind.BASIN = "basin"
JobKind.BASIN_TYPES = {"create:mixing", "create:compacting"}
-- The compacting chest (PC191, owner 2026-11-07): one item into a 2x2,
-- 3x3 or ring crafting recipe (mechanical.compacting), before everything
-- else, while such a station polls PC48.
JobKind.COMPACT = "compact"

-- Machines without a computer: recipe types -> the address PC48 sends the
-- inputs to (PC48's settings.lua `machines` replaces this list). Order is
-- precedence: smoking comes before smelting, so food is smoked, not burnt.
JobKind.MACHINES = {}   -- set them in the controller's settings.lua `machines`

function JobKind.new(options)
    options = options or {}
    local machines = {}
    for _, entry in ipairs(options.machines or JobKind.MACHINES) do
        if type(entry) == "table" and type(entry.types) == "table" and type(entry.address) == "string" then
            -- A machine counts for any of its outputs, chance ones too
            -- (netherite scrap from crushing nether bricks, 2026-11-07).
            local copy = {anyOutput = true}
            for k, v in pairs(entry) do copy[k] = v end
            machines[#machines + 1] = copy
        end
    end
    return setmetatable({
        api = options.recipes,
        machines = machines,
        -- the dyeing fans' address, "Dye %s"; false: none
        dyeFans = options.dyeFans == nil and "Dye %s" or options.dyeFans,
        dyeCache = {},
        -- online(kind): a station of that kind polls PC48 now.
        online = options.online,
        cache = {},
        compactCache = {},
        generation = nil,
    }, JobKind)
end

function JobKind:recipes()
    if self.api == nil then
        local ok, api = pcall(require, "recipes")
        self.api = ok and type(api) == "table" and api or false
    end
    return self.api or nil
end

-- Station kinds in order of precedence with their recipe types; `byOutput`
-- also counts later outputs (tree bark is a slicer's second output).
local STATIONS = {
    {kind = JobKind.MECHANICAL, types = {JobKind.MECHANICAL_TYPE}},
    {kind = JobKind.SAW, types = JobKind.SAW_TYPES},
    {kind = JobKind.SLICER, types = {JobKind.SLICER_TYPE}, byOutput = true},
    {kind = JobKind.BASIN, types = JobKind.BASIN_TYPES},
}

-- The recipe types of a station kind, or nil.
function JobKind.stationTypes(kind)
    for _, entry in ipairs(STATIONS) do
        if entry.kind == kind then return entry.types end
    end
end

-- What makes the target (Producers.rows), kept per recipe generation; an
-- error is not kept, so the next ask tries again.
function JobKind:rows(api, target)
    self.rowsCache = self.rowsCache or {}
    if self.rowsCache[target] then return self.rowsCache[target] end
    local rows, err = Producers.rows(api, target)
    if not rows then return nil, err end
    self.rowsCache[target] = rows
    return rows
end

-- The first entry of `list` whose recipe types make the target, or nil.
-- An entry's `byOutput`/`anyOutput` widen the outputs that count.
local function first(rows, list)
    for _, entry in ipairs(list) do
        if #Producers.ids(rows, entry.types, entry) > 0 then return entry end
    end
    return nil
end

-- A station kind, else "machine", else nil (and an error when Recipe Atlas
-- does not answer).
function JobKind:station(api, target)
    local rows, err = self:rows(api, target)
    if not rows then return nil, err end
    local station = first(rows, STATIONS)
    if station then return station.kind end
    return first(rows, self.machines) and JobKind.MACHINE or nil
end

local function usable(api, target)
    return api and type(api.producers) == "function" and type(target) == "string"
end

-- "turtle", a station kind or "machine": stonecutting, then a
-- crafting-table recipe, then the stations, then the machines, each in the order above.
function JobKind:classify(target)
    local api = self:recipes()
    if not usable(api, target) then return JobKind.TURTLE end
    -- A /reload publishes a new recipe generation: forget what was decided.
    local okMeta, meta = pcall(api.meta or error)
    local generation = okMeta and type(meta) == "table" and meta.generation or nil
    if generation ~= nil and generation ~= self.generation then
        self.cache, self.compactCache, self.makersCache, self.dyeCache, self.rowsCache, self.generation =
            {}, {}, {}, {}, {}, generation
    end
    -- A dyeing fan first (owner 2026-11-08): one item into one, no dye spent.
    if #self:dyeFanRecipes(target) > 0 then return JobKind.MACHINE end
    if self:compacts(api, target) then return JobKind.COMPACT end
    if self.cache[target] then return self.cache[target] end
    local kind, err = self:station(api, target)
    if err ~= nil then return JobKind.TURTLE, err end
    local rows = self:rows(api, target)
    -- A stonecutting recipe goes to the saw even with a crafting-table one
    -- (owner 2026-11-06): it gives as much or more (stairs 1 -> 1, not
    -- 6 -> 4), and the turtles' recipes for cut stone can go round in circles.
    local cut = kind == JobKind.SAW and #Producers.ids(rows, {"minecraft:stonecutting"}) > 0
    if kind and not cut and Producers.crafting(rows) then kind = nil end
    self.cache[target] = kind or JobKind.TURTLE
    return self.cache[target]
end

-- Every kind that can make the target, the one `classify` picks first, then
-- the turtles (a crafting-table recipe), the compacting chest, the stations
-- and the machines in their order (PC48's supplier tries them in turn,
-- owner 2026-11-08).
function JobKind:makers(target)
    local first_ = self:classify(target)
    self.makersCache = self.makersCache or {}
    local cached = self.makersCache[target]
    if cached and cached[1] == first_ then return cached end
    local list, seen = {}, {}
    local function add(kind)
        if kind and not seen[kind] then seen[kind], list[#list + 1] = true, kind end
    end
    add(first_)
    local api = self:recipes()
    if not usable(api, target) then return list end
    -- a lookup error is not kept: the next ask tries again
    local rows = self:rows(api, target)
    if not rows then return list end
    if Producers.crafting(rows) then add(JobKind.TURTLE) end
    if self:compacts(api, target) then add(JobKind.COMPACT) end
    for _, entry in ipairs(STATIONS) do
        if first(rows, {entry}) then add(entry.kind) end
    end
    if first(rows, self.machines) then add(JobKind.MACHINE) end
    -- kept per recipe generation, while the first choice stays the same
    self.makersCache[target] = list
    return list
end

-- The dyeing fans that make the target (controller.dye_fan), kept per
-- recipe generation; a lookup error is not remembered.
function JobKind:dyeFanRecipes(target)
    if not self.dyeFans or type(target) ~= "string" then return {} end
    self.dyeCache = self.dyeCache or {}
    if self.dyeCache[target] == nil then
        local list = DyeFan.recipes(self:recipes(), target, self.dyeFans)
        if not list then return {} end
        self.dyeCache[target] = list
    end
    return self.dyeCache[target]
end

-- Does the compacting chest make the target? Only asked while one polls;
-- a lookup error is not remembered.
function JobKind:compacts(api, target)
    if not (self.online and self.online(JobKind.COMPACT)) or type(api.compactions) ~= "function" then return false end
    if self.compactCache[target] == nil then
        local sources, why = Compacting.sources(api, target)
        if not sources and tostring(why):find("lookup failed", 1, true) then return false end
        self.compactCache[target] = sources ~= nil
    end
    return self.compactCache[target]
end

-- The station for a target the turtles could not make at all (its only
-- crafting-table recipes go round through itself: Create's cut deepslate
-- bricks), remembered for later requests; nil when no station makes it.
function JobKind:stationFor(target)
    local api = self:recipes()
    if not usable(api, target) then return nil end
    local kind = self:station(api, target)
    if not kind or kind == JobKind.MACHINE then return nil end
    self.cache[target] = kind
    return kind
end

-- Can anyone make the target (a crafting-table recipe or a workbench's)?
-- false for a raw drop (mutton, salmon); nil when Recipe Atlas cannot tell.
function JobKind:makeable(target)
    local api = self:recipes()
    if not usable(api, target) then return nil end
    local kind, err = self:station(api, target)
    if err ~= nil then return nil end
    if kind then return true end
    return Producers.crafting(self:rows(api, target))
end

-- Does a turtle (a crafting-table recipe) make the target? false on a lookup error.
function JobKind:crafted(target)
    local api = self:recipes()
    if not usable(api, target) then return false end
    return Producers.crafting(self:rows(api, target))
end

-- The kinds a worker takes, from its poll message; turtles send none.
function JobKind.workerKinds(message)
    local kinds = {}
    for _, kind in ipairs(type(message) == "table" and type(message.kinds) == "table" and message.kinds or {}) do
        if type(kind) == "string" then kinds[kind] = true end
    end
    if next(kinds) == nil then kinds[JobKind.TURTLE] = true end
    return kinds
end

function JobKind.of(job)
    return job and job.kind or JobKind.TURTLE
end

return JobKind
