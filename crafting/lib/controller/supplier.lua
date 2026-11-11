-- PC48's warehouse service (owner 2026-10-28: one controller decides). A
-- station or turtle reads the stock and orders its own ingredients; only
-- what the warehouse lacks it asks PC48 for ("supply"). PC48 has that made,
-- never by the asker's own kind: by a turtle or a station (a craft job; the
-- worker ships the output straight to the asker), or by a machine without
-- a computer (owner 2026-11-02, PC48's settings `machines`: a fan, crushing
-- wheels, a press): PC48 sends it the inputs and, once the output is in the
-- warehouse, sends that on. A missing input is made first the same way, to
-- the warehouse, down to `maxDepth` levels. What still lands in the
-- warehouse PC48 sends on through its own Stock Ticker under the order gate.
-- Supplies live in RAM: after a PC48 restart (the base unloads when the
-- owner is away) a requester asks again with the same id, and the craft
-- jobs already queued for it are taken up again instead of queued twice.
local Util = require("fleet_util")
local JobKind = require("controller.job_kind")
local Compacting = require("mechanical.compacting")
local Producers = require("autocrafter.producers")

local amount, failure = Util.amount, Util.failure

local Supplier = {}
Supplier.__index = Supplier

Supplier.TICKER_TYPE = "Create_StockTicker"
local TERMINAL = {SENT = true, MISSING = true, ERROR = true}

function Supplier.new(controller, options)
    options = options or {}
    return setmetatable({
        controller = controller,
        configured = options.ticker,
        stockSeconds = tonumber(options.stockSeconds) or 1,
        retrySeconds = tonumber(options.retrySeconds) or 3,
        craftSendSeconds = tonumber(options.craftSendSeconds) or 180,
        keepSeconds = tonumber(options.keepSeconds) or 600,
        machineSeconds = tonumber(options.machineSeconds) or 600,
        maxDepth = tonumber(options.maxDepth) or 4,
        supplies = {},
        order = {},
        sequence = 0,
    }, Supplier)
end

function Supplier:log(event, fields) self.controller:log(event, fields) end
function Supplier:now() return self.controller.now() end

-- The Stock Ticker: settings `ticker`, else the first on the network (one
-- ticker on two modems shows twice; other peripherals are ignored).
function Supplier:ticker()
    local api = self.controller.peripheral
    if self.tickerName then
        local device = api.wrap(self.tickerName)
        if device then return device end
        self.tickerName = nil
    end
    local name = self.configured
    if not name then
        local found = {}
        for _, candidate in ipairs(api.getNames and api.getNames() or {}) do
            if api.hasType and api.hasType(candidate, Supplier.TICKER_TYPE) then found[#found + 1] = candidate end
        end
        table.sort(found)
        name = found[1]
    end
    local device = name and api.wrap(name)
    if not device then return nil, failure("TICKER_MISSING", "no stock ticker on PC48's network") end
    if self.tickerName ~= name then self:log("supplier.ticker", {name = name}) end
    self.tickerName = name
    return device
end

-- The warehouse summary, read at most once a second (only for supplies):
-- {name -> {plain, all, maxCount}}.
function Supplier:summary()
    local now = self:now()
    if self.cache and now - self.cacheAt < self.stockSeconds then return self.cache end
    local ticker, err = self:ticker()
    if not ticker then return nil, err end
    local ok, list = pcall(ticker.stock, true)
    if not ok or type(list) ~= "table" then
        return nil, failure("STOCK_UNAVAILABLE", "stock ticker: " .. tostring(list))
    end
    local summary = {}
    for _, item in pairs(list) do
        if type(item) == "table" and type(item.name) == "string" then
            local entry = summary[item.name] or {plain = 0, all = 0, maxCount = 0}
            summary[item.name] = entry
            entry.all = entry.all + amount(item.count)
            if item.nbt == nil or item.nbt == "" then entry.plain = entry.plain + amount(item.count) end
            entry.maxCount = math.max(entry.maxCount, amount(item.maxCount))
        end
    end
    self.cache, self.cacheAt = summary, now
    return summary
end

-- Who can make an item for a requester of kind `exclude` (never itself: it
-- would wait on itself), in the order to try them: "turtle", a station
-- kind, "machine". A "turtle" has a crafting-table recipe.
function Supplier:makers(name, exclude)
    local kinds = self.controller:kinds()
    local ok, list = pcall(kinds.makers, kinds, name)
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for _, kind in ipairs(list) do
        local usable = kind ~= exclude
        if usable and kind == JobKind.TURTLE then usable = kinds:crafted(name) end
        if usable then out[#out + 1] = kind end
    end
    return out
end

-- The machine recipes for `name`, in the order of the `machines` list:
-- {address, seconds, yield (per craft, chance counted), chance, inputs =
-- {{quantity, alternatives = {ids}}}}. Recipes with a fluid input are left
-- out (PC48 sends items only).
function Supplier:machineRecipes(name)
    local kinds = self.controller:kinds()
    local api, list = kinds:recipes(), {}
    if not api then return list end
    -- The dyeing fans first: one item into one, the dye already there.
    for _, fan in ipairs(kinds.dyeFanRecipes and kinds:dyeFanRecipes(name) or {}) do
        list[#list + 1] = {address = fan.address, seconds = self.machineSeconds, yield = 1,
            inputs = {{quantity = 1, alternatives = fan.from}}}
    end
    local rows = kinds:rows(api, name)
    if not rows then return list end
    for _, machine in ipairs(kinds.machines) do
        -- any output counts, a later chance one too (netherite scrap from
        -- crushing nether bricks, 2026-11-07)
        local ids = Producers.ids(rows, machine.types, {anyOutput = true})
        local records = Producers.details(api, ids) or {}
        for _, id in ipairs(ids) do
            local record = records[id]
            local details = type(record) == "table" and record.machine or {}
            local recipe = {address = machine.address, inputs = {},
                seconds = tonumber(machine.seconds) or self.machineSeconds, yield = 0}
            for _, output in ipairs(details.outputs or {}) do
                if output.id == name then
                    local each = math.max(1, amount(output.quantity))
                    if output.mode == "chance" then
                        each, recipe.chance = each * (tonumber(output.probability) or 1), true
                    end
                    recipe.yield = recipe.yield + each
                end
            end
            for _, input in ipairs(details.inputs or {}) do
                local alternatives = {}
                for _, alternative in ipairs(input.alternatives or {}) do
                    if alternative.id and alternative.id ~= name then alternatives[#alternatives + 1] = alternative.id end
                end
                if input.kind ~= "item" or #alternatives == 0 then recipe = nil; break end
                recipe.inputs[#recipe.inputs + 1] = {quantity = math.max(1, amount(input.quantity)),
                    alternatives = alternatives}
            end
            if recipe and recipe.yield > 0 and #recipe.inputs > 0 then list[#list + 1] = recipe end
        end
    end
    return list
end

-- Do the turtles make `name` only from what this supply chain is making
-- (coal from coal blocks, for coal blocks for diamonds, 2026-11-07)? Then
-- a machine makes it instead.
function Supplier:turtleGoesRound(name, chain)
    if not next(chain or {}) then return false end
    local api = self.controller:kinds():recipes()
    if not api or type(api.find) ~= "function" then return false end
    local ok, page = pcall(api.find, {result = name, workbench = "crafting_table", limit = 50})
    local records = ok and type(page) == "table" and page.items or {}
    if #records == 0 then return false end
    for _, record in ipairs(records) do
        local round = false
        for _, ingredient in ipairs(type(record.ingredients) == "table" and record.ingredients or {}) do
            local items = type(ingredient) == "table" and ingredient.items or {}
            local all = #items > 0
            for _, item in ipairs(items) do if not chain[item] then all = false end end
            if all then round = true end
        end
        if not round then return false end
    end
    return true
end

-- The input slots (item ids each) of every recipe a station of one of
-- `types` has for `name`, by its first or a later guaranteed output.
local function stationRecipes(kinds, api, name, types)
    local ids = Producers.ids(kinds:rows(api, name), types, {byOutput = true})
    local records = Producers.details(api, ids) or {}
    local recipes = {}
    for _, id in ipairs(ids) do
        local record = records[id]
        local slots = {}
        for _, input in ipairs(type(record) == "table" and type(record.machine) == "table"
                and record.machine.inputs or {}) do
            -- items only: the station keeps its fluids itself
            if input.kind == nil or input.kind == "item" then
                local items = {}
                for _, alternative in ipairs(input.alternatives or {}) do items[#items + 1] = alternative.id end
                slots[#slots + 1] = items
            end
        end
        recipes[#recipes + 1] = slots
    end
    return recipes
end

-- Does a station of `kind` make `name` only from what it is made for: an
-- item up this supply chain (nether brick sliced from the nether brick
-- blocks the compacting chest was making for netherite scrap), or `name`
-- itself one cut away when the warehouse has none of the cut (netherrack
-- from cut netherrack, which the saw cuts from netherrack: 16 round and
-- round, 2026-11-08)?
function Supplier:stationGoesRound(name, chain, kind, ctx)
    local kinds = self.controller:kinds()
    local api = kinds:recipes()
    local types = JobKind.stationTypes(kind)
    if not api or not types then return false end
    local loop = {[name] = true}
    for item in pairs(chain or {}) do loop[item] = true end
    local function within(items)
        if #items == 0 then return false end
        for _, item in ipairs(items) do if not loop[item] then return false end end
        return true
    end
    local function stocked(item)
        local entry = ctx and ctx.summary and ctx.summary[item]
        return entry and (entry.plain or 0) > (ctx.taken[item] or 0)
    end
    -- made by this station only from the loop
    local function onlyFromLoop(item)
        if stocked(item) then return false end
        local recipes = stationRecipes(kinds, api, item, types)
        if #recipes == 0 then return false end
        for _, slots in ipairs(recipes) do
            local round = false
            for _, items in ipairs(slots) do if within(items) then round = true end end
            if not round then return false end
        end
        return true
    end
    local recipes = stationRecipes(kinds, api, name, types)
    if #recipes == 0 then return false end
    for _, slots in ipairs(recipes) do
        local round = false
        for _, items in ipairs(slots) do
            local all = #items > 0
            for _, item in ipairs(items) do
                if not loop[item] and not onlyFromLoop(item) then all = false; break end
            end
            if all then round = true end
        end
        if not round then return false end
    end
    return true
end

local function left(ctx, name)
    local entry = ctx.summary[name]
    return math.max(0, (entry and entry.plain or 0) - (ctx.taken[name] or 0))
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Plans making `count` of `name`: appends steps to ctx.steps, inputs
-- before what uses them. A craft job ships to `deliverTo` (nil: the
-- warehouse); a machine's output arrives in the warehouse. Returns true, or
-- false and the item that cannot be had ({name, count}).
function Supplier:plan(name, count, ctx, depth, deliverTo)
    -- Made for it further up: it would wait on itself.
    if ctx.chain[name] then return false, {name = name, count = count} end
    -- Every maker in turn, the first that can have what it needs (owner
    -- 2026-11-08: one maker a time said MISSING while another could).
    local lacking
    for _, maker in ipairs(self:makers(name, ctx.exclude)) do
        local made, why
        if maker == JobKind.MACHINE then
            made, why = self:planMachine(name, count, ctx, depth)
        else
            made, why = self:planJob(name, count, maker, ctx, depth, deliverTo)
        end
        if made then return true end
        lacking = lacking or why
    end
    return false, lacking or {name = name, count = count}
end

-- A turtle or station job for `name`, when that maker does not go round
-- through the chain and can have its inputs.
function Supplier:planJob(name, count, maker, ctx, depth, deliverTo)
    local can, lacking
    if maker == JobKind.TURTLE then
        -- going round says nothing of what is lacking: the next maker tells
        if self:turtleGoesRound(name, ctx.chain) then return false end
        can, lacking = self:turtleCan(name, count, ctx, depth)
    else
        if self:stationGoesRound(name, ctx.chain, maker, ctx) then return false end
        can, lacking = self:stationCan(name, count, maker, ctx, depth)
    end
    if not can then return false, lacking end
    ctx.steps[#ctx.steps + 1] = {type = "job", name = name, count = count, kind = maker,
        deliverTo = deliverTo, top = depth == 1}
    return true
end

-- A machine makes `name`: its inputs from stock, or made first.
function Supplier:planMachine(name, count, ctx, depth)
    if depth > self.maxDepth or ctx.visiting[name] then return false, {name = name, count = count} end
    ctx.visiting[name] = true
    local lacking
    for _, recipe in ipairs(self:machineRecipes(name)) do
        -- A chance output gets a quarter more input, for bad luck.
        local crafts = math.ceil(count / recipe.yield * (recipe.chance and 1.25 or 1))
        local mark, taken = #ctx.steps, copy(ctx.taken)
        local inputs = {}
        for _, input in ipairs(recipe.inputs) do
            local need, chosen = crafts * input.quantity, nil
            -- Never from what the chain is making: crushing nether brick
            -- blocks back into the bricks they were made of.
            for _, alternative in ipairs(input.alternatives) do
                if not ctx.chain[alternative] and left(ctx, alternative) >= need then chosen = alternative; break end
            end
            if chosen then
                ctx.taken[chosen] = (ctx.taken[chosen] or 0) + need
                inputs[#inputs + 1] = {name = chosen, count = need}
            else
                -- No one kind has it all: every kind in stock together, the
                -- most stocked first (any log burns to charcoal; the diamond
                -- chain asked 7346 of acacia alone and made acacia wood from
                -- acacia logs for it, 2026-11-10). What stock lacks is made.
                local pool = {}
                for _, alternative in ipairs(input.alternatives) do
                    local have = not ctx.chain[alternative] and left(ctx, alternative) or 0
                    if have > 0 then pool[#pool + 1] = {name = alternative, have = have} end
                end
                table.sort(pool, function(a, b) return a.have > b.have end)
                local rest, parts = need, {}
                for _, entry in ipairs(pool) do
                    if rest == 0 then break end
                    local take = math.min(rest, entry.have)
                    parts[#parts + 1] = {name = entry.name, count = take}
                    ctx.taken[entry.name] = (ctx.taken[entry.name] or 0) + take
                    rest = rest - take
                end
                if rest > 0 then
                    -- never one kind crafted from the others (acacia wood
                    -- from acacia logs burns no better than the logs)
                    local kinds = {}
                    for _, alternative in ipairs(input.alternatives) do kinds[alternative] = true end
                    for _, alternative in ipairs(input.alternatives) do
                        local made, why = false, nil
                        if not self:turtleGoesRound(alternative, kinds) then
                            made, why = self:plan(alternative, rest, ctx, depth + 1, nil)
                        end
                        if made then
                            parts[#parts + 1] = {name = alternative, count = rest}
                            rest = 0
                            break
                        end
                        lacking = lacking or why
                    end
                end
                if rest == 0 then
                    chosen = true
                    for _, part in ipairs(parts) do inputs[#inputs + 1] = part end
                end
            end
            if not chosen then inputs = nil; break end
        end
        if inputs then
            ctx.steps[#ctx.steps + 1] = {type = "machine", name = name, count = count, address = recipe.address,
                inputs = inputs, left = inputs, seconds = recipe.seconds, top = depth == 1}
            ctx.visiting[name] = nil
            return true
        end
        for index = #ctx.steps, mark + 1, -1 do ctx.steps[index] = nil end
        ctx.taken = taken
    end
    ctx.visiting[name] = nil
    return false, lacking or {name = name, count = count}
end

-- Can a station of `kind` make `name` from what is in stock or can be had?
-- Asked before its job is queued, so a station short of everything says
-- MISSING at once instead of after the job waited its turn (coal blocks for
-- diamonds: ten minutes in the compacting chest's queue to learn there was
-- no charcoal, 2026-11-08). A dry plan: nothing is queued or taken. Returns
-- true, or false and what is lacking.
function Supplier:stationCan(name, count, kind, ctx, depth)
    local kinds = self.controller:kinds()
    local api = kinds:recipes()
    if not api then return true end
    local recipes = {}
    if kind == JobKind.COMPACT then
        for _, source in ipairs(Compacting.sources(api, name) or {}) do
            recipes[#recipes + 1] = {{items = {source.item},
                need = math.ceil(count / math.max(1, source.perCraft)) * source.cells}}
        end
    else
        for _, slots in ipairs(stationRecipes(kinds, api, name, JobKind.stationTypes(kind) or {})) do
            local recipe = {}
            for _, items in ipairs(slots) do recipe[#recipe + 1] = {items = items, need = 1} end
            recipes[#recipes + 1] = recipe
        end
    end
    if #recipes == 0 then return true end
    -- what it is made from is made for it: never back out of it
    local chain = {[name] = true}
    for item in pairs(ctx.chain or {}) do chain[item] = true end
    local lacking
    for _, recipe in ipairs(recipes) do
        local all = true
        for _, slot in ipairs(recipe) do
            local got = false
            for _, item in ipairs(slot.items) do
                if not chain[item] then
                    local have = left(ctx, item)
                    if have >= slot.need then got = true; break end
                    local dry = {summary = ctx.summary, taken = copy(ctx.taken), exclude = kind, steps = {},
                        visiting = copy(ctx.visiting), chain = chain}
                    dry.visiting[name] = true
                    local made, why = self:plan(item, slot.need - have, dry, depth + 1, nil)
                    if made then got = true; break end
                    lacking = lacking or why
                end
            end
            if not got then all = false; break end
        end
        if all then return true end
    end
    return false, lacking or {name = name, count = count}
end

-- Can the turtles make `name`: has one of its crafting-table recipes every
-- ingredient in stock, or can it be had (a dry plan, as stationCan)? Deeper
-- than the supplier looks it is left to the turtles. Returns true, or false
-- and what is lacking.
function Supplier:turtleCan(name, count, ctx, depth)
    if depth >= self.maxDepth then return true end
    local api = self.controller:kinds():recipes()
    if not api or type(api.find) ~= "function" then return true end
    local ok, page = pcall(api.find, {result = name, workbench = "crafting_table", limit = 50})
    local records = ok and type(page) == "table" and page.items or nil
    if not records or #records == 0 then return true end
    local chain = {[name] = true}
    for item in pairs(ctx.chain or {}) do chain[item] = true end
    local lacking
    for _, record in ipairs(records) do
        local all = true
        for _, ingredient in ipairs(type(record.ingredients) == "table" and record.ingredients or {}) do
            local items = type(ingredient) == "table" and type(ingredient.items) == "table" and ingredient.items or {}
            local got = #items == 0
            for _, item in ipairs(items) do
                if not chain[item] then
                    if left(ctx, item) > 0 then got = true; break end
                    local dry = {summary = ctx.summary, taken = copy(ctx.taken), steps = {},
                        visiting = copy(ctx.visiting), chain = chain}
                    dry.visiting[name] = true
                    local made, why = self:plan(item, 1, dry, depth + 1, nil)
                    if made then got = true; break end
                    lacking = lacking or why
                end
            end
            if not got then all = false; break end
        end
        if all then return true end
    end
    return false, lacking or {name = name, count = count}
end

local function key(sender, id) return tostring(sender) .. "/" .. tostring(id) end

-- The job behind a worker's supply id ("<assignment>:<item>", the
-- assignment "<job id>:<n>"), or nil.
local function jobOf(queue, id, item)
    id, item = tostring(id or ""), tostring(item or "")
    if id:sub(-#item - 1) ~= ":" .. item then return nil end
    local assignment = id:sub(1, #id - #item - 1)
    -- "<job>:<n>", or "<job>:<n>:<ask>" for a station's later asks
    local job = queue:find(assignment:match("^(.-):%d+$") or assignment)
    return job or queue:find(assignment:match("^(.-):%d+:%d+$") or assignment)
end

-- What the asker's job is made for, up the supply chain: its target, the
-- target of the job whose supply queued it, and so on (owner 2026-11-02: a
-- cake without milk asked for cake slices, the slicer cut them from a cake
-- and asked for one, round and round).
function Supplier:chain(id, item)
    local queue, targets = self.controller.queue, {}
    local job = jobOf(queue, id, item)
    for _ = 1, 8 do
        if not job then break end
        targets[job.target] = true
        local parent = job.supplyKey and job.supplyKey:match("^[^/]*/(.*)$")
        job = parent and jobOf(queue, parent, job.target)
    end
    return targets
end

local function reply(supply)
    return {type = "supply", id = supply.id, state = supply.state, sent = supply.sent,
        missing = supply.missing, crafting = supply.crafting, failure = supply.failure}
end

-- "supply": {id, address, items = {{name, count, nbt?, optional?}}, craft?,
-- exclude?, toStorage?}. An item short in stock is made first when `craft`
-- is set and someone can make it; an optional one is just skipped; anything
-- else makes the whole supply MISSING and nothing is sent. toStorage (a
-- machine job, controller): everything is made, into the warehouse.
function Supplier:supply(sender, message)
    local existing = self.supplies[key(sender, message.id)]
    if existing then
        if existing.polledState ~= existing.state then
            existing.polledState = existing.state
            self:log("supply.poll", {id = existing.id, sender = sender, state = existing.state})
        end
        return reply(existing)
    end
    if type(message.address) ~= "string" or message.address == "" or type(message.items) ~= "table" then
        return {type = "supply", id = message.id, state = "ERROR", failure = failure("BAD_SUPPLY", "address and items required")}
    end
    local summary, err = self:summary()
    if not summary then return {type = "supply", id = message.id, state = "ERROR", failure = err} end
    local supply = {
        id = message.id, sender = sender, address = message.address, state = "ORDERING",
        pending = {}, steps = {}, sent = {}, missing = {}, crafting = {}, createdAt = self:now(),
        toStorage = message.toStorage,
    }
    local first = message.items[1]
    local chain = self:chain(message.id, type(first) == "table" and first.name)
    local ctx = {summary = summary, taken = {}, exclude = message.exclude, steps = supply.steps, visiting = {},
        chain = chain}
    for _, item in ipairs(message.items) do
        local name, count = item.name, amount(item.count)
        if type(name) == "string" and count > 0 then
            local inStock = 0
            if not message.toStorage then
                local entry = summary[name]
                local have = entry and (item.nbt and entry.all or entry.plain) or 0
                inStock = math.min(count, math.max(0, have - (ctx.taken[name] or 0)))
                ctx.taken[name] = (ctx.taken[name] or 0) + inStock
            end
            if inStock > 0 then
                supply.pending[#supply.pending + 1] = {name = name, count = inStock, nbt = item.nbt}
            end
            local short = count - inStock
            if short > 0 and not item.optional then
                local made, lacking = false, nil
                if message.craft and not item.nbt then
                    made, lacking = self:plan(name, short, ctx, 1,
                        not message.toStorage and message.address or nil)
                end
                if made then
                    supply.crafting[name] = short
                else
                    supply.missing[#supply.missing + 1] = lacking or {name = name, count = short}
                end
            end
        end
    end
    if #supply.missing > 0 then
        supply.state, supply.pending, supply.crafting = "MISSING", {}, {}
        for index = #supply.steps, 1, -1 do supply.steps[index] = nil end
        supply.doneAt = self:now()
        self:log("supply.missing", {id = message.id, sender = sender, missing = supply.missing[1].name,
            count = supply.missing[1].count})
    else
        local supplyKey = key(sender, message.id)
        local machines = 0
        for _, step in ipairs(supply.steps) do
            if step.type == "job" then
                for _, queued in ipairs(self.controller.queue.jobs) do
                    if queued.supplyKey == supplyKey and queued.target == step.name
                        and not self.controller.queue:terminal(queued) then
                        step.jobId = queued.id
                    end
                end
                step.jobId = step.jobId or self.controller:enqueueInternal(step.name, step.count, step.kind,
                    "supply " .. supplyKey, step.deliverTo, supplyKey)
                if not step.jobId then
                    supply.state, supply.failure = "ERROR", failure("QUEUE_SAVE_FAILED", "craft job for " .. step.name .. " not saved")
                    supply.doneAt = self:now()
                end
            else
                machines = machines + 1
            end
        end
        self:log("supply.accepted", {id = message.id, sender = sender, address = message.address,
            items = #message.items, steps = #supply.steps, machines = machines})
    end
    self.supplies[key(sender, message.id)] = supply
    self.order[#self.order + 1] = key(sender, message.id)
    if supply.state == "ORDERING" then self:advance(supply) end
    return reply(supply)
end

-- One order of `entries` to `address` (default: the asker's) under the
-- order gate. Returns the accepted count per entry, or nil while the gate
-- makes it wait.
function Supplier:send(supply, entries, address)
    address = address or supply.address
    local controller, now = self.controller, self:now()
    local stacks = 0
    for _, entry in ipairs(entries) do
        local maxCount = (self.cache and self.cache[entry.name] and self.cache[entry.name].maxCount) or 64
        stacks = stacks + math.ceil(entry.count / math.max(1, maxCount))
    end
    local packages = math.max(1, math.ceil(stacks / 9))
    local holder = "supply:" .. key(supply.sender, supply.id)
    supply.token = supply.token or (holder .. ":" .. tostring(now))
    local decision, position, grants = controller.orderGate:request(holder, supply.token, packages, now)
    controller:sendOrderGrants(grants)
    if decision ~= "grant" then
        if now - (supply.gateLoggedAt or 0) >= 30 then
            supply.gateLoggedAt = now
            self:log("supply.gate_wait", {id = supply.id, address = address, position = position})
        end
        return nil
    end
    local ticker, err = self:ticker()
    local filters, wanted = {}, 0
    for index, entry in ipairs(entries) do
        filters[index] = {name = entry.name, nbt = entry.nbt, _requestCount = entry.count}
        wanted = wanted + entry.count
    end
    local ok, result = false, err and err.message
    if ticker then ok, result = pcall(ticker.requestFiltered, address, table.unpack(filters)) end
    local _, after = controller.orderGate:release(holder, supply.token, ok and packages or 0, self:now())
    controller:sendOrderGrants(after)
    supply.token = nil
    self.cache = nil
    if not ok or type(result) ~= "number" then
        return false, failure("ORDER_FAILED", "stock ticker: " .. tostring(result))
    end
    -- One total comes back; split it over the entries in order.
    local accepted, rest = {}, math.min(wanted, amount(result))
    for index, entry in ipairs(entries) do
        accepted[index] = math.min(entry.count, rest)
        rest = rest - accepted[index]
    end
    self:log("supply.sent", {id = supply.id, address = address, wanted = wanted, accepted = result,
        packages = packages})
    return accepted
end

local function fail(supply, now, code, message, fields)
    supply.state, supply.doneAt = "ERROR", now
    supply.failure = failure(code, message, fields)
end

-- Of `entries`, what the warehouse has now (a made output may still be on
-- its way): {index, entry with the count to send}; nothing ordered for 0.
function Supplier:ready(entries)
    local summary = self:summary()
    if not summary then return {} end
    local list, used = {}, {}
    for index, entry in ipairs(entries) do
        local stock = summary[entry.name]
        local have = stock and (entry.nbt and stock.all or stock.plain) or 0
        local count = math.min(entry.count, math.max(0, have - (used[entry.name] or 0)))
        if count > 0 then
            used[entry.name] = (used[entry.name] or 0) + count
            list[#list + 1] = {index = index, entry = {name = entry.name, nbt = entry.nbt, count = count}}
        end
    end
    return list
end

-- Sends what is in stock of `entries` to `address`. Returns the accepted
-- count per entry (0 for one not in stock), nil while the gate makes it
-- wait, or false and a failure.
function Supplier:sendReady(supply, entries, address)
    local ready, batch = self:ready(entries), {}
    local accepted = {}
    for index in ipairs(entries) do accepted[index] = 0 end
    if #ready == 0 then return accepted end
    for index, item in ipairs(ready) do batch[index] = item.entry end
    local result, err = self:send(supply, batch, address)
    if not result then return result, err end
    for index, item in ipairs(ready) do accepted[item.index] = result[index] end
    return accepted
end

-- Sends what is left of a machine step's inputs; an input still on its way
-- into the warehouse (made by an earlier step) is tried again until the
-- step's time is up. Returns false when the supply failed.
function Supplier:feedMachine(supply, step, now)
    step.startedAt = step.startedAt or now
    if now < (step.retryAt or 0) then return true end
    local accepted, err = self:sendReady(supply, step.left, step.address)
    if accepted == false then
        supply.state, supply.failure, supply.doneAt = "ERROR", err, now
        return false
    end
    if not accepted then return true end
    local rest = {}
    for index, entry in ipairs(step.left) do
        if entry.count > accepted[index] then rest[#rest + 1] = {name = entry.name, count = entry.count - accepted[index]} end
    end
    step.left = rest
    if #rest == 0 then
        step.done, step.sentAt = true, now
        self:log("supply.machine", {id = supply.id, target = step.name, count = step.count, address = step.address})
        if step.top then
            supply.crafting[step.name] = nil
            if not supply.toStorage then
                supply.pending[#supply.pending + 1] = {name = step.name, count = step.count, craftedAt = now,
                    wait = step.seconds}
            end
        end
    elseif now - step.startedAt > step.seconds then
        fail(supply, now, "SUPPLY_SHORT", rest[1].name .. ": " .. rest[1].count .. " not in stock for "
            .. step.address, {target = rest[1].name, needed = rest[1].count})
        return false
    else
        step.retryAt = now + self.retrySeconds
    end
    return true
end

-- Moves one supply on: finished craft jobs (the asker's own ones join the
-- pending items with what they could not deliver), machine steps fed once
-- every step before them is done, pending items sent (a short send is
-- retried: an output may still be on its way into storage); with nothing
-- left it is SENT.
function Supplier:advance(supply)
    if TERMINAL[supply.state] then return end
    local now, queue = self:now(), self.controller.queue
    local before = true
    for _, step in ipairs(supply.steps) do
        if not step.done then
            if step.type == "job" then
                local record = queue:find(step.jobId)
                if not record or queue:terminal(record) then
                    local result = record and record.result or {}
                    if record and record.status ~= "DONE" then
                        supply.state, supply.doneAt = "ERROR", now
                        supply.failure = result.failure or failure("CRAFT_FAILED", tostring(result.error or (step.name .. " not crafted")))
                        return
                    end
                    step.done = true
                    if step.top then
                        local rest = math.min(step.count, record and record.undeliveredOutput or 0)
                        if rest > 0 and not supply.toStorage then
                            supply.pending[#supply.pending + 1] = {name = step.name, count = rest, craftedAt = now}
                        end
                        supply.sent[step.name] = (supply.sent[step.name] or 0) + step.count - rest
                        supply.crafting[step.name] = nil
                    end
                end
            elseif before then
                if not self:feedMachine(supply, step, now) then return end
            end
        end
        before = before and step.done == true
    end
    if #supply.pending > 0 and now >= (supply.retryAt or 0) then
        local accepted, err = self:sendReady(supply, supply.pending)
        if accepted == false then
            supply.state, supply.failure, supply.doneAt = "ERROR", err, now
            return
        end
        if accepted then
            local rest = {}
            for index, entry in ipairs(supply.pending) do
                supply.sent[entry.name] = (supply.sent[entry.name] or 0) + accepted[index]
                local count = entry.count - accepted[index]
                if count > 0 then
                    if now - (entry.craftedAt or supply.createdAt) > (entry.wait or self.craftSendSeconds) then
                        fail(supply, now, "SUPPLY_SHORT", entry.name .. ": " .. count .. " not in stock to send",
                            {target = entry.name, needed = count})
                        return
                    end
                    rest[#rest + 1] = {name = entry.name, count = count, nbt = entry.nbt, craftedAt = entry.craftedAt,
                        wait = entry.wait}
                end
            end
            supply.pending = rest
            if #rest > 0 then supply.retryAt = now + self.retrySeconds end
        end
    end
    if #supply.pending == 0 and before then
        supply.state, supply.doneAt = "SENT", now
        self:log("supply.done", {id = supply.id, sender = supply.sender})
    end
end

-- A queued "machine" job (a craft request only a machine makes): run as a
-- supply into the warehouse (or to its deliverTo address), the job ending
-- with it. A PC48 restart mid-way loses the supply (RAM): the job then
-- ends as INTERRUPTED rather than sending the inputs twice.
function Supplier:runJobs()
    local controller, queue, now = self.controller, self.controller.queue, self:now()
    for _, job in ipairs(queue.jobs) do
        if job.kind == JobKind.MACHINE and not queue:terminal(job) then
            local supply = self.supplies[key(controller.controllerId, job.id)]
            if not supply and job.machineStartedAt then
                supply = {state = "ERROR", failure = failure("INTERRUPTED",
                    "PC48 restarted while the machine was working; the output may be in the warehouse")}
            elseif not supply then
                job.machineStartedAt, job.status, job.startedAt = now, "ASSIGNED", job.startedAt or now
                controller:save("machine job started")
                self:supply(controller.controllerId, {type = "supply", id = job.id,
                    address = job.deliverTo or "Storage", items = {{name = job.target, count = job.count}},
                    craft = true, toStorage = job.deliverTo == nil})
                supply = self.supplies[key(controller.controllerId, job.id)]
            end
            if supply and TERMINAL[supply.state] then
                local ok = supply.state == "SENT"
                local problem = supply.failure
                if supply.state == "MISSING" then
                    local first = supply.missing[1] or {}
                    problem = failure("MISSING_RAW", "missing " .. tostring(first.name) .. " x" .. tostring(first.count)
                        .. "; unavailable in stock", {target = first.name, needed = first.count, severity = "WARN"})
                end
                job.status, job.completedAt, job.notified = ok and "DONE" or "ERROR", now, false
                job.completedOutput = ok and job.count or 0
                job.result = {ok = ok, complete = true, craftedOutput = job.completedOutput,
                    failure = not ok and problem or nil, error = not ok and problem and problem.message or nil}
                controller:save("machine job done")
                controller:log("job.completed", {id = job.clientId, status = job.status,
                    craftedOutput = job.completedOutput, error = job.result.error, worker = "machine"})
                if controller.chatJob then pcall(controller.chatJob, controller, job) end
            end
        end
    end
end

-- Every tick: move the open supplies on, run machine jobs and forget old
-- finished supplies.
function Supplier:tick()
    local now, kept = self:now(), {}
    for _, k in ipairs(self.order) do
        local supply = self.supplies[k]
        if supply and supply.doneAt and now - supply.doneAt > self.keepSeconds then
            self.supplies[k] = nil
        elseif supply then
            kept[#kept + 1] = k
            if not TERMINAL[supply.state] then
                local ok, err = pcall(self.advance, self, supply)
                if not ok then
                    supply.state, supply.doneAt = "ERROR", now
                    supply.failure = failure("SUPPLIER_EXCEPTION", tostring(err))
                end
                if supply.state == "ERROR" then
                    self:log("supply.failed", {id = supply.id, sender = supply.sender,
                        error = supply.failure and supply.failure.message})
                end
            end
        end
    end
    self.order = kept
    local ok, err = pcall(self.runJobs, self)
    if not ok then self:log("supplier.machine_jobs_failed", {error = tostring(err)}) end
end

-- Open supplies for the screen.
function Supplier:open()
    local count = 0
    for _, supply in pairs(self.supplies) do
        if not TERMINAL[supply.state] then count = count + 1 end
    end
    return count
end

return Supplier
