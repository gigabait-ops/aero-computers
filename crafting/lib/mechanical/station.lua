-- A station: a worker of PC48 that takes the jobs of its machine kind
-- (mechanical crafter grid PC134, saws PC136, slicers PC137). Per job it
-- reads the warehouse through its own Stock Ticker and orders the
-- ingredients into its chest (under PC48's order gate); what the warehouse
-- lacks it asks PC48 for, and PC48 has it made and sent here (owner
-- 2026-10-28). The machine module does the crafting; the packager ships the
-- chest to the warehouse. The station finds its blocks on its network
-- itself (mechanical.devices): machines by name, its chest and packager by
-- a marker delivery to its address; settings.lua names only what it cannot
-- find (kind, address, the crafter grid, the slicer tools).
local AtomicStore = require("atomic_store")
local Util = require("fleet_util")
local Recipe = require("mechanical.recipe")
local Devices = require("mechanical.devices")
local Delegate = require("autocrafter.delegate")
local Notice = require("chat.notice")

local amount, failure = Util.amount, Util.failure

local Station = {}
Station.__index = Station
Station.RELEASE = "2026-11-11.1"

Station.MACHINES = {
    mechanical = "mechanical.crafter",
    saw = "mechanical.saw",
    slicer = "mechanical.slicer",
    basin = "mechanical.basin",
    compact = "mechanical.compact",
}

function Station.new(options)
    options = options or {}
    local config = options.config or {}
    local machine = Station.MACHINES[config.kind]
    assert(machine, "settings.lua: kind must be mechanical, saw, slicer, basin or compact")
    local self = setmetatable({
        config = config,
        kind = config.kind,
        machine = require(machine),
        peripheral = options.peripheral or peripheral,
        rednet = options.rednet or rednet,
        recipes = options.recipes,
        fs = options.fs or fs,
        sleep = options.sleep or sleep,
        now = options.now or function() return os.epoch("utc") / 1000 end,
        logger = options.logger,
        term = options.term or term,
        computerId = options.computerId or (os.getComputerID and os.getComputerID()) or 0,
        status = "STARTING",
        lastBeat = 0,
    }, Station)
    if self.recipes == nil then
        local ok, api = pcall(require, "recipes")
        self.recipes = ok and api or nil
    end
    self.delegate = options.delegate or Delegate.new({
        rednet = self.rednet, sleep = self.sleep, now = self.now, logger = self.logger,
        idPrefix = "m" .. tostring(self.computerId),
        heartbeat = function(phase) self:beat(phase) end,
        hostname = config.requestHostname,
        waitSeconds = config.delegateWaitSeconds,
    })
    return self
end

function Station:log(event, fields) Util.log(self.logger, event, fields) end

-- The screen: a status key (chat.notice, "station.<key>") and its params,
-- or a free text line under it.
function Station:show(key, params, detail)
    self.status, self.detail = key, detail
    local t = self.term
    if not t or not t.clear then return end
    t.clear(); t.setCursorPos(1, 1)
    print(self.machine.TITLE .. "  PC" .. tostring(self.computerId) .. "  " .. Station.RELEASE)
    print(("-"):rep(40))
    print(Notice.text("station." .. key, params))
    if detail then print(detail) end
    if self.active then
        print()
        print("Job: " .. tostring(self.active.target) .. " x" .. tostring(self.active.count))
        print("Made: " .. tostring(self.active.crafted or 0))
    end
end

-- Devices ---------------------------------------------------------------

function Station:wrap(name)
    local device = name and self.peripheral.wrap(name)
    if not device then error(failure("PERIPHERAL_MISSING", "peripheral missing: " .. tostring(name)), 0) end
    return device
end

function Station:ticker()
    local name, err = Devices.one(self.peripheral, self.config.ticker, "Create_StockTicker")
    if not name then error(err, 0) end
    return self:wrap(name)
end

-- The chest deliveries to this station land in and the packager on it:
-- kept in data/devices.lua, found again by a marker delivery when one is
-- gone (Devices.locate; the count id % 50 + 1 is this computer's own).
function Station:bind()
    local api = self.peripheral
    local file = self.config.devicesFile or "data/devices.lua"
    local saved = AtomicStore.load(file, self.fs)
    if type(saved) == "table" and saved.chest and saved.packager
        and api.isPresent(saved.chest) and api.isPresent(saved.packager) then
        self.chestName, self.packagerName = saved.chest, saved.packager
        return true
    end
    self:show("locating")
    local chest, packager = Devices.locate(api, {
        ticker = self:ticker(), address = self.config.address, count = self.computerId % 50 + 1,
        marker = self.config.marker,
        sleep = self.sleep, clock = self.now, log = function(event, fields) self:log(event, fields) end,
    })
    if not chest then error(failure("PERIPHERAL_MISSING", packager), 0) end
    self.chestName, self.packagerName = chest, packager
    AtomicStore.save(file, {chest = chest, packager = packager}, self.fs)
    self:log("station.located", {chest = chest, packager = packager})
    return true
end

-- The frogport deliveries come to gets the station's address (owner
-- 2026-10-28: no address signs). Returns its name, or nil when the cable has
-- none (a sign then names it).
function Station:nameFrogport()
    local name = Devices.one(self.peripheral, self.config.frogport, "Create_Frogport")
    if not name then return nil end
    pcall(self.peripheral.call, name, "setAddress", self.config.address)
    return name
end

function Station:chest() return self:wrap(self.chestName) end
function Station:packager() return self:wrap(self.packagerName) end

-- item -> count in the chest, and the used slots.
function Station:chestCounts()
    local counts, slots = {}, 0
    for _, item in pairs(self:chest().list() or {}) do
        counts[item.name] = (counts[item.name] or 0) + amount(item.count)
        slots = slots + 1
    end
    return counts, slots
end

-- Warehouse stock, item -> count. Orders go by name, so only stacks
-- without data count, unless `variants` (an "all" job takes enchanted and
-- worn items too).
function Station:stock(variants)
    local list = self:ticker().stock(true)
    if type(list) ~= "table" then error(failure("STOCK_UNAVAILABLE", "stock ticker gave no stock"), 0) end
    local counts, maxCounts = {}, {}
    for _, item in pairs(list) do
        if type(item) == "table" and item.name and (variants or item.nbt == nil or item.nbt == "") then
            counts[item.name] = (counts[item.name] or 0) + amount(item.count)
            maxCounts[item.name] = amount(item.maxCount) > 0 and amount(item.maxCount) or maxCounts[item.name]
        end
    end
    return counts, maxCounts
end

-- Heartbeat to PC48 while a job runs (at most every beatSeconds), in the
-- shape PC48's screen reads: current = {target}, waitingFor = {name, missing}.
function Station:beat(phase)
    local now = self.now()
    if self.active then self.active.phase = phase or self.active.phase end
    if now - self.lastBeat < (self.config.beatSeconds or 10) then return end
    self.lastBeat = now
    if self.controllerId and self.active then
        pcall(self.rednet.send, self.controllerId, {
            type = "status", assignment = self.active.assignment, state = self.active.phase,
            current = {target = self.active.target}, waitingFor = self.active.waitingFor,
        }, Util.WORKER_PROTOCOL)
    end
end

-- Shipping ----------------------------------------------------------------

-- Packs the chest until it is empty (the packager gets the warehouse
-- address first). Returns true, or false and why.
function Station:ship(reason)
    local _, slots = self:chestCounts()
    if slots == 0 then return true end
    local ok, packager = pcall(self.packager, self)
    if not ok then return false, "SHIP_UNCONFIGURED" end
    self:show("shipping", {stacks = slots})
    for _ = 1, math.ceil(slots / 9) + (self.config.shipRetries or 4) do
        pcall(packager.setAddress, self.shipTo or self.config.shipAddress or "Storage")
        pcall(packager.makePackage)
        self.sleep(self.config.shipGapSeconds or 1.5)
        self:beat("SHIPPING")
        local _, left = self:chestCounts()
        if left == 0 then
            self:log("station.shipped", {stacks = slots, reason = reason})
            return true
        end
    end
    local _, left = self:chestCounts()
    self:log("station.ship_incomplete", {stacks = slots, left = left, reason = reason})
    Notice.emit("station.ship_incomplete", {left = left}, self.rednet)
    return false, "SHIP_INCOMPLETE"
end

function Station:clearMachine()
    return self.machine.clear(self)
end

-- Ordering --------------------------------------------------------------------

local function stacksOf(take, maxCounts)
    local stacks = 0
    for name, count in pairs(take) do stacks = stacks + math.ceil(count / math.max(1, maxCounts[name] or 64)) end
    return stacks
end

-- Orders `need` (item -> count) into the chest through the station's ticker.
function Station:order(need, maxCounts)
    local filters, stacks = {}, stacksOf(need, maxCounts)
    for name, count in pairs(need) do
        if count > 0 then filters[#filters + 1] = {name = name, _requestCount = count} end
    end
    if #filters == 0 then return true end
    table.sort(filters, function(a, b) return a.name < b.name end)
    local packages = math.max(1, math.ceil(stacks / 9))
    local token = self.delegate:orderLock(self.controllerId, packages)
    local ok, result = pcall(self:ticker().requestFiltered, self.config.address, table.unpack(filters))
    self.delegate:orderRelease(self.controllerId, token, ok and packages or 0)
    if not ok then return nil, failure("ORDER_FAILED", "stock ticker: " .. tostring(result)) end
    self:log("station.ordered", {items = #filters, stacks = stacks, requested = result})
    return true
end

-- Waits until the chest holds `want` (item -> count). `reorder` (the order
-- just placed: need, maxCounts, and the chest before it) orders again what
-- never started arriving: Create drops a whole order when a packager is too
-- busy and the ticker still says yes (zinc for the crafter, 0 of 18, while
-- the netherite chain kept the packagers busy, 2026-11-11).
function Station:waitDelivery(want, reorder)
    local deadline = self.now() + (self.config.deliveryTimeout or 300)
    local every = self.config.reorderSeconds or 60
    local nextReorder, reorders = self.now() + every, 0
    while true do
        local counts = self:chestCounts()
        if reorder and self.now() >= nextReorder and reorders < (self.config.maxReorders or 2) then
            nextReorder = self.now() + every
            local again = {}
            for name, count in pairs(reorder.need) do
                if count > 0 and (counts[name] or 0) <= (reorder.before[name] or 0) then again[name] = count end
            end
            if next(again) then
                reorders = reorders + 1
                local list = {}
                for name, count in pairs(again) do list[#list + 1] = name .. " x" .. count end
                table.sort(list)
                self:log("station.reorder", {missing = table.concat(list, ", "), reorder = reorders})
                local ok, orderError = self:order(again, reorder.maxCounts)
                if not ok then return nil, orderError end
                deadline = self.now() + (self.config.deliveryTimeout or 300)
            end
        end
        local missing
        for name, count in pairs(want) do
            if (counts[name] or 0) < count then missing = {name = name, need = count, have = counts[name] or 0}; break end
        end
        if not missing then
            self.active.waitingFor = nil
            return true
        end
        if self.now() >= deadline then
            return nil, failure("DELIVERY_TIMEOUT", "waited for " .. missing.name .. ": " .. missing.have
                .. "/" .. missing.need .. " in the chest", {target = missing.name, needed = missing.need - missing.have})
        end
        self.active.waitingFor = {name = missing.name, missing = missing.need - missing.have}
        self:show("waiting_delivery", {item = missing.name, have = missing.have, need = missing.need})
        self:beat("WAITING_DELIVERY")
        self.sleep(self.config.deliveryPollSeconds or 2)
    end
end

-- An ingredient this station's own machine makes (tomato sauce for a
-- basin dish): made here first, as a job inside the job, its output kept in
-- the chest. Returns true, or nil and why. At most three levels deep.
-- Each item is tried once per job: decor families cut into each other
-- (blackstone -> cut blackstone -> blackstone), and without this the search
-- tried every path through them, a minute each (2026-11-06).
function Station:makeHere(name, count)
    local outer = self.active
    if (outer.depth or 0) >= 3 then return nil, failure("TOO_DEEP", name .. ": ingredients nested too deep") end
    local recipes = self.machine.find(self, name, {})
    if not recipes then return nil end
    local tried = outer.tried or {[outer.target] = true}
    outer.tried = tried
    if tried[name] then return nil, failure("MISSING_RAW", name .. ": already tried in this job") end
    -- Never from what it is made for: cut netherrack cut from netherrack, for
    -- netherrack, went round 16 at a time (2026-11-08).
    local chain = {[outer.target] = true}
    for item in pairs(outer.chain or {}) do chain[item] = true end
    local usable = false
    for _, recipe in ipairs(recipes) do
        local round = false
        for _, cell in ipairs(type(recipe) == "table" and recipe.cells or {}) do
            local all = #(cell.accepts or {}) > 0
            for _, item in ipairs(cell.accepts or {}) do if not chain[item] then all = false end end
            if all then round = true end
        end
        if not round then usable = true end
    end
    if not usable then return nil, failure("MISSING_RAW", name .. ": made only from " .. tostring(outer.target)) end
    tried[name] = true
    self:log("station.make_here", {item = name, count = count, depth = (outer.depth or 0) + 1})
    self.active = {assignment = outer.assignment, target = name, count = count, crafted = 0,
        phase = "PLANNING", depth = (outer.depth or 0) + 1, tried = tried, supplies = outer.supplies, chain = chain}
    local ok, value, err = pcall(self.runJob, self, {target = name})
    outer.supplies = self.active.supplies
    self.active = outer
    if not ok then return nil, failure("STATION_EXCEPTION", tostring(value)) end
    if value ~= nil then tried[name] = nil end
    return value ~= nil or nil, err
end

-- What the warehouse lacks: made here when this station's machine makes it,
-- else PC48 has it made (turtles or another station) and sends it here; the
-- station waits for it in the chest. An item with alternatives tries them in
-- turn. Anything nobody can make is the job's MISSING_RAW.
function Station:requestMissing(shortages)
    local inChest = self:chestCounts()
    local want, lastError = {}, nil
    for _, shortage in ipairs(shortages) do
        local got
        for _, name in ipairs(shortage.accepts or {shortage.item}) do
            local made, hereError = self:makeHere(name, shortage.missing)
            if made then got = true; break end
            if hereError then
                -- This station makes it but cannot now: PC48 would not either.
                lastError = hereError
            else
                self:show("waiting_supply", {item = name, count = shortage.missing})
                -- A later ask in the same job gets its own id: PC48 answers
                -- an id it knows with its old reply (2026-11-07).
                local active = self.active
                active.supplies = (active.supplies or 0) + 1
                local id = tostring(active.assignment) .. (active.supplies > 1 and (":" .. active.supplies) or "")
                    .. ":" .. name
                local ok, err = self.delegate:supply({{name = name, count = shortage.missing}}, self.config.address,
                    {craft = true, exclude = self.kind, phase = "WAITING_SUPPLY", id = id})
                self:log("station.supply", {item = name, count = shortage.missing, ok = ok ~= nil,
                    error = err and err.message})
                if ok then
                    want[name] = (want[name] or inChest[name] or 0) + shortage.missing
                    got = true
                    break
                end
                lastError = err
            end
        end
        if not got then return nil, lastError end
    end
    return self:waitDelivery(want)
end

-- Jobs ----------------------------------------------------------------------

local function blockedSet(policy)
    local set = {}
    for _, id in ipairs(type(policy) == "table" and policy.blockedRecipes or {}) do set[id] = true end
    return set
end

-- What the chest has plus what the warehouse has; `keep` of each `from`
-- item is left in the warehouse (an "always" rule's reserve).
function Station:available(variants, from, keep)
    local stock, maxCounts = self:stock(variants)
    local inChest = self:chestCounts()
    local all = {}
    for name, count in pairs(stock) do all[name] = count end
    for name, count in pairs(inChest) do all[name] = (all[name] or 0) + count end
    for _, name in ipairs(keep and from or {}) do all[name] = math.max(0, (all[name] or 0) - keep) end
    return all, inChest, maxCounts
end

-- The recipes this station can run for the job: placeable ones, with each
-- input narrowed to the job's `from` list (a PC46 rule's inputs).
function Station:usableRecipes(job)
    local recipes, why = self.machine.find(self, job.target, blockedSet(job.recipePolicy))
    if not recipes then return nil, failure(self.machine.NO_RECIPE, tostring(job.target) .. ": " .. tostring(why)) end
    local only
    if type(job.from) == "table" and #job.from > 0 then
        only = {}
        for _, name in ipairs(job.from) do only[name] = true end
    end
    local usable = {}
    for _, recipe in ipairs(recipes) do
        local keep = self.machine.fits(self, recipe)
        if keep and only then
            for _, cell in ipairs(recipe.cells) do
                local accepts = {}
                for _, name in ipairs(cell.accepts) do if only[name] then accepts[#accepts + 1] = name end end
                if #accepts == 0 then keep = false; break end
                cell.accepts = accepts
            end
        end
        if keep then usable[#usable + 1] = recipe end
    end
    if #usable == 0 and not only then
        return nil, failure("GRID_TOO_SMALL", job.target .. " needs " .. recipes[1].width .. "x" .. recipes[1].height)
    end
    return usable
end

function Station:runJob(job)
    -- A machine with its own way of running a job (the compacting chest).
    if self.machine.runJob then return self.machine.runJob(self, job) end
    local usable, err = self:usableRecipes(job)
    if not usable then return nil, err end
    -- Nothing on the `from` list has a recipe here: done, nothing to make.
    if #usable == 0 then
        self:log("station.nothing", {why = "no recipe takes the from list", from = job.from})
        return {ok = true, craftedOutput = 0}
    end
    local active = self.active
    local maxStacks = self.config.batchStacks or 45
    while amount(active.crafted) < active.count do
        local available, inChest, maxCounts = self:available(job.all, job.from, job.keep)
        local remaining = active.count - amount(active.crafted)
        -- The first recipe the stock fully covers, else the one going furthest.
        local recipe, crafts = usable[1], 0
        for _, candidate in ipairs(usable) do
            local n = Recipe.maxCrafts(candidate, available, math.ceil(remaining / candidate.perCraft))
            if n > crafts then recipe, crafts = candidate, n end
        end
        -- A full batch: what is left, up to what one batch holds.
        local perCraft = 0
        for _, group in ipairs(Recipe.groups(recipe)) do perCraft = perCraft + group.perCraft end
        local full = math.max(1, math.min(math.ceil(remaining / recipe.perCraft),
            math.floor(maxStacks * 64 / math.max(1, perCraft))))
        -- The last ask brought no more: decor cut into other decor the recipe
        -- takes as well (stairs for dark metal blocks, one at a time for
        -- hours, 2026-11-08). What there is gets cut, nothing more asked.
        if active.askedAt and crafts <= active.askedAt and not job.all then
            active.askedAt = nil
            if crafts == 0 then
                return nil, failure("MISSING_RAW", recipe.target .. ": asking for more brought none",
                    {target = recipe.target})
            end
            active.noSupply = true
            self:log("station.supply_short", {crafts = crafts, full = full, error = "the ask brought no more"})
        end
        if crafts == 0 and job.all then
            -- "All": made what there was something to make it from.
            if amount(active.crafted) == 0 then
                local seen = {}
                for _, candidate in ipairs(usable) do
                    for _, cell in ipairs(candidate.cells or {}) do
                        for _, name in ipairs(cell.accepts) do seen[#seen + 1] = name .. "=" .. (available[name] or 0) end
                    end
                end
                self:log("station.nothing", {why = "none in stock", recipes = #usable, accepts = table.concat(seen, " ")})
            end
            break
        elseif crafts == 0 or (not job.all and not active.noSupply and crafts < full) then
            -- Short of a full batch: PC48 has the rest made (iron ingots from
            -- nuggets) instead of the station cutting the few in stock, a
            -- handful at a time for an hour (owner 2026-11-08). When nobody
            -- can make it, what is in stock is used and nothing more asked.
            local ok, supplyError = self:requestMissing(Recipe.shortages(recipe, full, available))
            active.askedAt = ok and crafts or nil
            if not ok and crafts == 0 then return nil, supplyError end
            if not ok then
                active.noSupply = true
                self:log("station.supply_short", {crafts = crafts, full = full, error = supplyError and supplyError.message})
            end
        else
            -- A batch the chest and one order of packages can hold.
            -- What one load of the machine holds (a basin: nine stacks, 1000 mB).
            local batch = self.machine.maxBatch and math.min(crafts, self.machine.maxBatch(self, recipe)) or crafts
            while batch > 1 do
                if stacksOf(Recipe.allocate(recipe, batch, available), maxCounts) <= maxStacks then break end
                batch = math.max(1, math.floor(batch / 2))
            end
            local take = Recipe.allocate(recipe, batch, available)
            local need = {}
            for name, count in pairs(take) do need[name] = math.max(0, count - (inChest[name] or 0)) end
            -- What the machine needs besides the ingredients (the slicers' tools).
            if self.machine.extraNeed then
                local extra, extraError = self.machine.extraNeed(self, recipe)
                if not extra then return nil, extraError end
                for name, count in pairs(extra) do
                    local ok, supplyError = self:requestMissing({{item = name, missing = count, accepts = {name}}})
                    if not ok then return nil, supplyError end
                end
            end
            active.recipeId, active.phase = recipe.id, "ORDERING"
            self:show("ordering", {crafts = batch, target = recipe.target})
            local ordered, orderError = self:order(need, maxCounts)
            if not ordered then return nil, orderError end
            local arrived, deliveryError = self:waitDelivery(take,
                {need = need, maxCounts = maxCounts, before = inChest})
            if not arrived then return nil, deliveryError end
            local made, craftError = self.machine.batch(self, recipe, batch)
            active.askedAt = nil
            if made and made > 0 then
                active.crafted = amount(active.crafted) + made
                self:save()
            end
            if craftError then
                self:ship("failure")
                return nil, craftError
            end
            -- A job inside a job keeps its output in the chest for the outer one.
            local shipped, shipError = active.depth and true or self:ship("batch")
            if not shipped then
                -- The output is made; it waits in the chest until shipping works.
                self:log("station.output_waiting", {reason = shipError})
            end
        end
    end
    return {ok = true, craftedOutput = amount(active.crafted), recipeId = active.recipeId}
end

-- State and the PC48 loop -----------------------------------------------------

function Station:save()
    local ok, err = AtomicStore.save(self.config.stateFile or "data/state.lua",
        {active = self.active, pendingResult = self.pendingResult, controllerId = self.controllerId}, self.fs)
    if not ok then self:log("station.state_save_failed", {error = tostring(err)}) end
    return ok
end

function Station:load()
    local value = AtomicStore.load(self.config.stateFile or "data/state.lua", self.fs)
    if type(value) == "table" then
        self.active, self.pendingResult, self.controllerId = value.active, value.pendingResult, value.controllerId
    end
end

function Station:result(job, ok, value)
    local result = {
        type = "result", assignment = job.assignment, ok = ok, target = job.target,
        requestedOutput = job.count, craftedOutput = amount(job.crafted), recipeId = job.recipeId,
    }
    if not ok then
        result.failure = value
        result.error = type(value) == "table" and value.message or tostring(value)
    end
    return result
end

-- Shortages that end an "always" job without an error (owner 2026-10-28).
local SHORT = {MISSING_RAW = true, TOOL_MISSING = true, INGREDIENT_LOST = true, DELIVERY_TIMEOUT = true}

function Station:execute(message)
    self.active = {
        assignment = message.assignment, target = message.target,
        count = amount(message.count), crafted = 0, phase = "PLANNING",
    }
    -- A supply's craft: the output goes straight to whoever asked PC48.
    self.shipTo = message.deliverTo
    self:save()
    self:log("station.job", {assignment = message.assignment, target = message.target, count = self.active.count,
        deliverTo = message.deliverTo})
    local ok, value, err = pcall(self.runJob, self, {target = message.target, recipePolicy = message.recipePolicy,
        all = message.all, from = message.from, keep = message.keep})
    if not ok then
        -- A failure table raised by a device lookup keeps its code and words.
        err = type(value) == "table" and value.code and value or failure("STATION_EXCEPTION", tostring(value))
        value = nil
    end
    if message.all and not value and type(err) == "table" and SHORT[err.code] then
        self:log("station.all_stopped", {target = message.target, code = err.code, reason = err.message,
            crafted = amount(self.active.crafted)})
        value, err = {ok = true, craftedOutput = amount(self.active.crafted)}, nil
    end
    -- A failed job's leftovers go to the warehouse, not the asker.
    local deliveredTo = value and self.shipTo or nil
    self.shipTo = nil
    if not value then
        self:clearMachine()
        self:ship("failure")
    end
    self.pendingResult = self:result(self.active, value ~= nil, err)
    self.pendingResult.deliveredTo = deliveredTo
    self:log("station.result", {assignment = message.assignment, ok = value ~= nil,
        crafted = self.active.crafted, error = err and err.message})
    self.active = nil
    self:save()
    self:show(value and "done" or "failed", nil, err and Notice.failureText(err, err.message, message.target))
end

function Station:findController()
    if self.controllerId then return self.controllerId end
    local ok, id = pcall(self.rednet.lookup, Util.WORKER_PROTOCOL, self.config.controllerHostname or "autocrafter-controller")
    if ok and id then self.controllerId = tonumber(id) or id; self:save() end
    return self.controllerId
end

-- A job interrupted by a restart is reported as failed with what it made.
function Station:recover()
    if self.active then
        local job = self.active
        self:clearMachine()
        self:ship("restart")
        self.pendingResult = self:result(job, false, failure("STATION_RESTARTED",
            "station restarted during the job; made " .. amount(job.crafted)))
        self.active = nil
        self:save()
    end
end

-- Between jobs: anything left in the machines or the chest goes to the warehouse.
function Station:idle()
    local now = self.now()
    if now < (self.nextIdleShip or 0) then return end
    self.nextIdleShip = now + (self.config.idleShipSeconds or 30)
    self:clearMachine()
    local shipped, why = self:ship("idle")
    if not shipped then
        self:show("chest_not_empty", {reason = Notice.text("reason." .. tostring(why))})
    end
end

function Station:step()
    local controller = self:findController()
    if not controller then
        self:show("no_controller")
        self.sleep(5)
        return
    end
    if self.pendingResult then
        self.rednet.send(controller, self.pendingResult, Util.WORKER_PROTOCOL)
    else
        if not self.announced then
            self.rednet.send(controller, {type = "hello", worker = self.computerId,
                capabilities = {kinds = {self.kind}}}, Util.WORKER_PROTOCOL)
            self.announced = true
        end
        self.rednet.send(controller, {type = "poll", worker = self.computerId, kinds = {self.kind}}, Util.WORKER_PROTOCOL)
    end
    local sender, message = self.rednet.receive(Util.WORKER_PROTOCOL, self.config.pollTimeout or 5)
    if sender ~= controller or type(message) ~= "table" then
        if not self.pendingResult then self:idle() end
        return
    end
    if message.type == "ack" and self.pendingResult
        and tostring(message.assignment) == tostring(self.pendingResult.assignment) then
        self.pendingResult = nil
        self:save()
        self:show("idle")
    elseif message.type == "job" and message.assignment and message.target and not self.pendingResult then
        self:execute(message)
    elseif message.type == "idle" then
        self:idle()
        if self.status ~= "idle" and self.status ~= "chest_not_empty" then self:show("idle") end
    end
end

-- Logs which blocks it found, so a missing one shows at boot.
function Station:survey()
    local found = {}
    for _, id in ipairs({"create:saw", "sliceanddice:slicer", "create:depot", "create:mechanical_crafter"}) do
        local count = #Devices.named(self.peripheral, id)
        if count > 0 then found[id] = count end
    end
    found.ticker = select(1, Devices.one(self.peripheral, self.config.ticker, "Create_StockTicker"))
    found.chest, found.packager = self.chestName, self.packagerName
    self:log("station.devices", found)
end

function Station:start()
    self:log("fleet.release", {version = Station.RELEASE, kind = self.kind})
    local named, frogport = pcall(self.nameFrogport, self)
    self:log("station.frogport", {name = named and frogport or nil, address = self.config.address})
    while true do
        local ok, err = pcall(self.bind, self)
        if ok then break end
        local message = type(err) == "table" and err.message or tostring(err)
        self:log("station.bind_failed", {error = message})
        self:show("idle", nil, message)
        self.sleep(30)
    end
    pcall(self.survey, self)
    self:load()
    self:recover()
    self:show("idle")
    while true do
        -- One bad step (a peripheral rebuilt mid-call) must not stop the station.
        local ok, err = pcall(self.step, self)
        if not ok then
            local message = type(err) == "table" and (err.message or err.code) or tostring(err)
            self:log("station.step_failed", {error = message})
            self:show("idle", nil, message)
            self.sleep(5)
        end
        self.sleep(self.config.pollSeconds or 1)
    end
end

return Station
