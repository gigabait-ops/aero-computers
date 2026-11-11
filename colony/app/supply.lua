-- Colony Supply: turns open MineColonies requests into Create stock-ticker orders.
--
-- Pure logic, no CC globals: every dependency (integrator, ticker, clock, log,
-- sleep) is injected so the module runs under lua5.2 on the host for tests.
--
-- Flow per cycle:
--   1. integrator.getRequests()  -> requests the colony cannot fulfil itself
--   2. ticker.list()             -> what the Create network has in stock
--   3. for each open request pick the variant with the most stock and call
--      ticker.requestFiltered(address, {name=..., _requestCount=...})
--   4. remember the order by request id so it is not repeated until
--      `reorder_after` seconds pass or the request disappears (DONE).

local Supply = {}
Supply.__index = Supply

-- MineColonies RequestState names that mean "nothing to deliver any more".
local FINISHED = {
    RESOLVED = true, COMPLETED = true, OVERRULED = true, CANCELLED = true,
    RECEIVED = true, FINALIZING = true, FAILED = true,
}

local DEFAULTS = {
    address = "Colony",         -- frogport / postbox address that receives the packages
    reorder_after = 600,        -- seconds before the same request is ordered again
    missing_retry = 300,        -- seconds between MISSING warnings for one item
    recheck_after = 60,         -- seconds before an out-of-stock request is checked again
    max_orders_per_cycle = 4,   -- Create drops a whole order at >=10 queued packages
    order_gap = 2,              -- seconds between two orders in one cycle
    min_order = 1,
    max_order = 256,
    skip_targets = {},          -- substrings of building names that are never served
    skip_items = {},            -- substrings of item ids that are never ordered
}

local NULL_LOG = {
    info = function() end, warn = function() end,
    debug = function() end, error = function() end,
}

local function numberOr(value, fallback)
    local n = tonumber(value)
    if n == nil then return fallback end
    return n
end

local function matchesAny(text, patterns)
    if type(text) ~= "string" then return false end
    local lower = text:lower()
    for _, pattern in ipairs(patterns or {}) do
        if lower:find(tostring(pattern):lower(), 1, true) then return true end
    end
    return false
end

-- Create ticker filter that matches only the plain item: no component patch
-- (no enchantments, no damage, no custom name). MineColonies adds a tool's
-- enchantment level to its tool level, so enchanted tools never satisfy a
-- worker's request.
function Supply.plainFilter(name, count)
    return {
        _op = "all",
        value = {
            {name = name},
            {_op = "not", value = {nbt = {_op = "type", value = "string"}}},
        },
        _requestCount = count,
    }
end

-- Plain matching for unstackable items (tools, armour) and plain rules.
local function wantsPlain(request, item)
    if type(item) ~= "table" or item.nbt ~= nil then return false end
    if request.plain then return true end
    return tonumber(item.maxStackSize) == 1
end

function Supply.new(deps)
    deps = deps or {}
    assert(type(deps.integrator) == "table", "supply needs an integrator")
    assert(type(deps.ticker) == "table", "supply needs a stock ticker")
    local self = setmetatable({}, Supply)
    self.integrator = deps.integrator
    self.ticker = deps.ticker
    self.clock = deps.clock or function() return os.clock() end
    self.sleep = deps.sleep
    -- optional ordering permit {acquire(packages) -> token, info; release(token, packages)}:
    -- the optional craft module passes its controller's order gate (main sets supply.gate)
    self.gate = deps.gate
    self.log = deps.log or NULL_LOG
    self.config = {}
    for key, value in pairs(DEFAULTS) do self.config[key] = value end
    for key, value in pairs(deps.config or {}) do
        if DEFAULTS[key] ~= nil then self.config[key] = value end
    end
    self.inbox = deps.inbox       -- optional inventory whose contents are already here
    -- optional function(request) -> address: a building's own address (rules/addresses.lua)
    self.addressFor = deps.addressFor
    self.extras = deps.extras or {}   -- functions() -> lists of request-like entries
    self.store = deps.store       -- optional {load = fn() -> table, save = fn(table)}
    self.orders = {}    -- request id -> {at, name, count, target}
    self.byName = {}    -- item name -> time of the last order (dedupe for extra entries)
    self.missing = {}   -- item name -> time of the last MISSING warning
    self.checked = {}   -- request id -> time it was last found out of stock
    local saved = self.store and self.store.load and self.store.load() or nil
    if type(saved) == "table" then
        self.orders = type(saved.orders) == "table" and saved.orders or {}
        self.byName = type(saved.byName) == "table" and saved.byName or {}
        self.missing = type(saved.missing) == "table" and saved.missing or {}
    end
    return self
end

-- Forget per-item memory older than a day so the saved state stays small.
function Supply:prune(now)
    local day = 86400
    for name, at in pairs(self.byName) do if now - at > day then self.byName[name] = nil end end
    for name, at in pairs(self.missing) do if now - at > day then self.missing[name] = nil end end
end

function Supply:save()
    self:prune(self.clock())
    if self.store and self.store.save then
        pcall(self.store.save, {orders = self.orders, byName = self.byName, missing = self.missing})
    end
end

Supply.FINISHED = FINISHED
Supply.DEFAULTS = DEFAULTS

-- How many items a request asks for, clamped to the configured window.
function Supply:wanted(request)
    local count = numberOr(request.count, 0)
    if count <= 0 then count = numberOr(request.minCount, 0) end
    if count <= 0 and type(request.items) == "table" and type(request.items[1]) == "table" then
        count = numberOr(request.items[1].count, 0)
    end
    if count <= 0 then count = 1 end
    count = math.floor(count)
    if count < self.config.min_order then count = self.config.min_order end
    if count > self.config.max_order then count = self.config.max_order end
    return count
end

-- name -> total count across the ticker's stock summary.
-- Create 6: ticker.stock() is the network summary; ticker.list() is only the
-- ticker's own payments drawer, so it is just a fallback.
function Supply:readStock()
    local reader = type(self.ticker.stock) == "function" and self.ticker.stock or self.ticker.list
    local ok, list = pcall(reader)
    if not ok or type(list) ~= "table" then
        return nil, tostring(list)
    end
    local stock = {}
    for _, entry in pairs(list) do
        if type(entry) == "table" and type(entry.name) == "string" then
            local n = tonumber(entry.count) or 0
            stock[entry.name] = (stock[entry.name] or 0) + n
            local key = entry.nbt ~= nil and (entry.name .. "#" .. tostring(entry.nbt)) or (entry.name .. "#plain")
            stock[key] = (stock[key] or 0) + n
        end
    end
    -- Items waiting in the inbox count as network stock (its packager is
    -- linked) but are already here, so they must not be ordered again.
    if self.inbox ~= nil then
        local okInbox, slots = pcall(self.inbox.list)
        if okInbox and type(slots) == "table" then
            for _, stack in pairs(slots) do
                if type(stack) == "table" and type(stack.name) == "string" then
                    local n = tonumber(stack.count) or 0
                    if stock[stack.name] then stock[stack.name] = math.max(0, stock[stack.name] - n) end
                    local key = stack.nbt ~= nil and (stack.name .. "#" .. tostring(stack.nbt)) or (stack.name .. "#plain")
                    if stock[key] then stock[key] = math.max(0, stock[key] - n) end
                end
            end
        end
    end
    return stock
end

-- The acceptable variant with the most stock, or nil when nothing is in stock.
-- An item with `nbt` (non-default components: Domum Ornamentum blocks,
-- enchanted gear...) only matches that exact variant. Returns name, count,
-- nbt, stock key.
function Supply:choose(request, stock)
    local best, bestCount, bestNbt, bestKey
    for _, item in ipairs(request.items or {}) do
        local name = type(item) == "table" and item.name or nil
        if type(name) == "string" and not matchesAny(name, self.config.skip_items) then
            local nbt = item.nbt
            local key = name
            if nbt ~= nil then
                key = name .. "#" .. tostring(nbt)
            elseif wantsPlain(request, item) then
                key = name .. "#plain"
            end
            local have = stock[key] or 0
            if have > 0 and (best == nil or have > bestCount) then
                best, bestCount, bestNbt, bestKey = name, have, nbt, key
            end
        end
    end
    return best, bestCount, bestNbt, bestKey
end

local function firstItemName(request)
    if type(request.items) == "table" and type(request.items[1]) == "table"
        and type(request.items[1].name) == "string" then
        return request.items[1].name
    end
    return tostring(request.displayName or request.description or "?")
end

function Supply:acceptableNames(request)
    local names = {}
    for _, item in ipairs(request.items or {}) do
        local name = type(item) == "table" and item.name or nil
        if type(name) == "string" and not matchesAny(name, self.config.skip_items) then
            names[#names + 1] = name
        end
    end
    return names
end

-- false for tools and armour (max stack 1), so crafts are not padded to a batch
local function stackable(request)
    local first = type(request.items) == "table" and request.items[1] or nil
    local max = type(first) == "table" and tonumber(first.maxStackSize) or nil
    if max == nil then return true end
    return max > 1
end

-- Packages one order makes: Create packs about 9 stacks per package.
function Supply.packagesFor(amount, isStackable)
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    local stacks = isStackable == false and amount or math.ceil(amount / 64)
    return math.max(1, math.ceil(stacks / 9))
end

-- The order itself, inside the gate's permit when there is a gate. A gate
-- that fails or does not answer never stops the order.
function Supply:requestGated(filter, amount, request, address)
    local packages = Supply.packagesFor(amount, stackable(request))
    local token, info
    if self.gate then
        local okGate, t, i = pcall(self.gate.acquire, self.gate, packages)
        if okGate then token, info = t, i end
        if type(info) == "table" and (tonumber(info.waited) or 0) >= 10 then
            self.log.info("GATE", tostring(filter.name or "?"), info.gate or "?", string.format("waited %.0fs", info.waited))
        end
    end
    local okReq, accepted = pcall(self.ticker.requestFiltered, address or self.config.address, filter)
    if token then pcall(self.gate.release, self.gate, token, packages) end
    return okReq, accepted
end

-- Every out-of-stock check is reported in result.missing (the craft module
-- acts on it and keeps its own pauses); only the log line is
-- limited to one per item and missing_retry, so a prestock note can never
-- hide a real colony request for the same item.
function Supply:noteMissing(result, now, name, label, count, target, request)
    table.insert(result.missing, {name = name, names = self:acceptableNames(request), displayName = label,
        count = count, target = target, stackable = stackable(request) and not request.noPad,
        noCraft = request.noCraft == true})
    local last = self.missing[name]
    if last ~= nil and now - last < self.config.missing_retry then return end
    self.missing[name] = now
    result.logged = true
    self.log.warn("MISSING", label, count, "for", tostring(target))
end

-- Forget orders whose request vanished from the colony (delivered or cancelled).
function Supply:forgetDone(seen, now, result)
    local done = 0
    for key, order in pairs(self.orders) do
        if not seen[key] then
            self.log.info("DONE", order.name, order.count, "for", tostring(order.target),
                math.floor(now - order.at) .. "s")
            self.orders[key] = nil
            done = done + 1
            if result then
                table.insert(result.completed, {id = key, name = order.name, count = order.count, target = order.target,
                    address = order.address, seconds = math.floor(now - order.at)})
            end
        end
    end
    return done
end

function Supply:cycle()
    local now = self.clock()
    local result = {ordered = {}, missing = {}, errors = {}, skipped = 0, open = 0, done = 0, requests = {}, completed = {}}

    local ok, requests = pcall(self.integrator.getRequests)
    if not ok or type(requests) ~= "table" then
        table.insert(result.errors, "colony: " .. tostring(requests))
        return result
    end

    local seen, open = {}, {}
    local function collect(list)
        for _, request in pairs(list) do
            if type(request) == "table" and request.id ~= nil then
                local key = tostring(request.id)
                if not FINISHED[tostring(request.state)] and not seen[key] then
                    seen[key] = true
                    table.insert(open, request)
                end
            end
        end
    end
    collect(requests)
    -- an extra that cannot tell this time (nil, or an error) keeps its own
    -- orders open instead of reporting them all as delivered
    local unsure = false
    for _, fn in ipairs(self.extras) do
        local okExtra, extra = pcall(fn)
        if okExtra and type(extra) == "table" then
            collect(extra)
        else
            unsure = true
            if not okExtra then table.insert(result.errors, "extra: " .. tostring(extra)) end
        end
    end
    if unsure then
        for key in pairs(self.orders) do
            if key:find("^stock:") or key:find("^wo:") then seen[key] = true end
        end
    end
    result.done = self:forgetDone(seen, now, result)
    result.open = #open
    for key in pairs(self.checked) do
        if not seen[key] then self.checked[key] = nil end
    end
    if #open == 0 then
        if result.done > 0 then self:save() end
        return result
    end
    table.sort(open, function(a, b) return tostring(a.id) < tostring(b.id) end)

    -- The Create stock list is large; read it only when a request may be
    -- ordered right now, at most once per scan.
    local stock, stockFailed
    local function currentStock()
        if stock == nil and not stockFailed then
            local list, err = self:readStock()
            if list then
                stock = list
            else
                stockFailed = true
                table.insert(result.errors, "ticker: " .. tostring(err))
            end
        end
        return stock
    end

    local sent = 0
    for _, request in ipairs(open) do
        local key = tostring(request.id)
        local target = request.target
        local firstName = firstItemName(request)
        local row = {id = key, name = tostring(request.displayName or firstName), count = self:wanted(request),
            target = target, item = firstName, status = "waiting"}
        result.requests[#result.requests + 1] = row
        local order = self.orders[key]
        local reorderAfter = tonumber(request.reorder_after) or self.config.reorder_after
        local lastByName = self.byName[firstName]
        local checkedAt = self.checked[key]

        if order ~= nil and now - order.at < reorderAfter then
            row.status, row.orderedAt, row.item = "ordered", order.at, order.name
            result.skipped = result.skipped + 1
        elseif matchesAny(target, self.config.skip_targets) then
            row.status = "skipped"
            result.skipped = result.skipped + 1
        elseif request.dedupeByName and lastByName ~= nil and now - lastByName < reorderAfter then
            -- a real colony request already ordered this item recently
            row.status = "covered"
            result.skipped = result.skipped + 1
        elseif checkedAt ~= nil and now - checkedAt < self.config.recheck_after then
            row.status = "missing"      -- not in stock a moment ago; look again later
        elseif sent >= self.config.max_orders_per_cycle then
            row.status = "queued"
        elseif not currentStock() then
            row.status = "error"
        else
            local wanted = row.count
            local name, have, nbt, stockKey = self:choose(request, stock)
            if name == nil then
                row.status = "missing"
                self.checked[key] = now
                self:noteMissing(result, now, firstName, tostring(request.displayName or firstName), wanted, target, request)
            else
                local amount = math.min(wanted, have)
                if sent > 0 and self.sleep and (self.config.order_gap or 0) > 0 then
                    self.sleep(self.config.order_gap)
                end
                local filter = {name = name, _requestCount = amount}
                if nbt ~= nil then
                    filter.nbt = nbt
                elseif stockKey == name .. "#plain" then
                    filter = Supply.plainFilter(name, amount)
                end
                local address = self.addressFor and self.addressFor(request) or self.config.address
                local okReq, accepted = self:requestGated(filter, amount, request, address)
                if not okReq or type(accepted) ~= "number" then
                    row.status = "error"
                    table.insert(result.errors, "order " .. name .. ": " .. tostring(accepted))
                    self.log.error("ORDER_FAILED", name, amount, tostring(accepted))
                elseif accepted <= 0 then
                    row.status = "missing"
                    self.checked[key] = now
                    self:noteMissing(result, now, name, name, amount, target, request)
                else
                    row.status, row.item, row.orderedAt = "ordered", name, now
                    stock[stockKey] = have - accepted
                    if stockKey ~= name and stock[name] then stock[name] = math.max(0, stock[name] - accepted) end
                    self.orders[key] = {at = now, name = name, count = accepted, target = target, address = address}
                    self.byName[name] = now
                    self.checked[key] = nil
                    sent = sent + 1
                    self.log.info("ORDERED", name, accepted, "->", address, "for", tostring(target))
                    table.insert(result.ordered, {id = key, name = name, count = accepted, target = target,
                        address = address})
                end
            end
        end
    end
    if #result.ordered > 0 or result.done > 0 or result.logged then self:save() end
    result.stock = stock   -- Create stock, when this scan read it (the craft module looks at it)
    return result
end

function Supply:openOrders()
    local list = {}
    for key, order in pairs(self.orders) do
        table.insert(list, {id = key, name = order.name, count = order.count, target = order.target, at = order.at})
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    return list
end

return Supply
