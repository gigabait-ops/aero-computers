package.path = "/?.lua;/?/init.lua;" .. package.path
-- PC121: supplies for the mining turtles (owner 2026-11-03). The diamond
-- chest keeps what config.lua `keep` lists (the stock); the barrel linked
-- with the barrels in the turtles takes what they unload, the rest goes to
-- the outbox, a chest linked with the warehouse. A turtle asks for lava or
-- a block (rednet "kopach_supply") and gets it in the barrel's slot 1
-- (counter.lua). What is short comes from PC48 (a supply to this station's
-- frogport; the packager on the diamond chest unpacks it there): PC48 has it
-- made when the warehouse lacks it (owner 2026-11-06), else sends what it has.
local Util = require("fleet_util")
local Logger = require("logger")
local Counter = dofile("/counter.lua")

local VERSION = "2026-11-07.2"
local SUPPLY = "kopach_supply"
local TOOK_SECONDS = 30   -- a turtle told "ready" takes it in this time, or the next one goes
local ORDER_UNSTACKABLE = 63 -- one per package slot: 7 packages
local ORDER_STACKABLE = 64 * 63 -- the same 7 packages, 9 stacks each (was 64 * 7: one package, owner 2026-11-07 "надто малими партіями")
local ARRIVE_SECONDS = 180
local EMPTY_STOCK_SECONDS = 120
local FAILED_SECONDS = 1800 -- nobody could make it: asked again in half an hour
local SILENT_SECONDS = 600 -- PC48 did not answer at all
local LOOP_SECONDS = 5

local logger = Logger.create("supply-121", {file = "/data/supply.log", max_bytes = 32768, max_files = 2})
local function log(event, fields) Util.log(logger, event, fields) end
local now = function() return os.epoch("utc") / 1000 end

local function config()
    local ok, value = pcall(dofile, "/config.lua")
    if not ok or type(value) ~= "table" or type(value.keep) ~= "table" then
        error("config.lua: " .. tostring(ok and "keep missing" or value), 0)
    end
    return value
end

-- The linked barrel, the stock (the diamond chest, the packager on it only
-- receives) and the outbox (any other inventory); config.lua may name them.
local function devices(cfg)
    local d = {barrel = cfg.barrel, stock = cfg.stock, outbox = cfg.outbox}
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        if not cfg.barrel and (name:find("^sophisticatedstorage:barrel_") or name:find("^minecraft:barrel_")) then
            if not d.barrel or name < d.barrel then d.barrel = name end
        elseif not cfg.stock and name:find("^sophisticatedstorage:chest_") then
            if not d.stock or name < d.stock then d.stock = name end
        end
    end
    if not d.outbox then
        for _, name in ipairs(names) do
            if name ~= d.barrel and name ~= d.stock and peripheral.hasType(name, "inventory")
                and not peripheral.hasType(name, "Create_Packager") then
                if not d.outbox or name < d.outbox then d.outbox = name end
            end
        end
    end
    return d
end

local function list(name)
    local ok, items = pcall(peripheral.call, name, "list")
    return ok and items or {}
end

local function counts(items)
    local total = {}
    for _, item in pairs(items) do total[item.name] = (total[item.name] or 0) + item.count end
    return total
end

local maxCounts = {}
local function orderSize(name, where, slot)
    if maxCounts[name] == nil and where then
        local ok, detail = pcall(peripheral.call, where, "getItemDetail", slot)
        if ok and detail then maxCounts[name] = detail.maxCount end
    end
    -- never seen in the stock yet: a block stacks, a bucket does not (a new
    -- wall block was ordered 63 at a time, owner 2026-11-07)
    local max = maxCounts[name] or (name:find("_bucket$") and 1 or 64)
    return max > 1 and ORDER_STACKABLE or ORDER_UNSTACKABLE
end

local counter = Counter.new(function(name, method, ...)
    local ok, result = pcall(peripheral.call, name, method, ...)
    if ok then return result end
end)

local queue, serving, stockCache = {}, nil, {}
local function busy() return #queue > 0 end

local expecting, retryAt, asking = {}, {}, {}

local function controller()
    local ok, id = pcall(rednet.lookup, Util.REQUEST_PROTOCOL, "craft-controller")
    return ok and id or nil
end

-- One supply per item at a time, asked again every loop until PC48 answers
-- for good (its reply is the same for the same id): first what the
-- warehouse has, and when it has none, made by PC48 (craft).
local function ask(name, count, address, craft)
    asking[name] = {id = "pc121-" .. math.floor(now() * 1000) .. "-" .. name, count = count, craft = craft,
        address = address, at = now()}
end

local function poll(to)
    for name, a in pairs(asking) do
        pcall(rednet.send, to, {type = "supply", id = a.id, address = a.address, craft = a.craft,
            items = {{name = name, count = a.count, optional = not a.craft}}},
            Util.REQUEST_PROTOCOL)
    end
end

local function crafting()
    for _, a in pairs(asking) do if a.craft then return true end end
    return false
end

local function answered(reply)
    for name, a in pairs(asking) do
        if reply.id == a.id then
            a.at = now()
            local sent = reply.state == "SENT" and (reply.sent or {})[name] or 0
            if reply.state == "SENT" then
                log("supply.ordered", {item = name, wanted = a.count, sent = sent, craft = a.craft})
            end
            if sent > 0 then
                asking[name] = nil
                expecting[name] = {count = sent, at = now(), base = stockCache[name] or 0}
            elseif not a.craft and (reply.state == "SENT" or reply.state == "MISSING") then
                -- the warehouse has none: made by PC48, one item at a time
                asking[name] = nil
                if crafting() then retryAt[name] = now() + EMPTY_STOCK_SECONDS
                else ask(name, a.count, a.address, true) end
            elseif reply.state == "SENT" then
                asking[name], retryAt[name] = nil, now() + EMPTY_STOCK_SECONDS
            elseif reply.state == "MISSING" or reply.state == "ERROR" then
                local failure = type(reply.failure) == "table" and reply.failure.message or reply.failure
                log("supply.failed", {item = name, state = reply.state, craft = a.craft, error = failure})
                asking[name], retryAt[name] = nil, now() + FAILED_SECONDS
            end
        end
    end
end

local function step()
    local cfg = config()
    local d = devices(cfg)
    if not d.barrel or not d.stock then return "no barrel or chest" end
    counter.sort(d, cfg.keep, busy)
    local stock = list(d.stock)
    for slot, item in pairs(stock) do orderSize(item.name, d.stock, slot) end   -- learns stack sizes once
    local have = counts(stock)
    -- PC48's deliveries come into the stock itself: there when it has grown by them
    for name, wait in pairs(expecting) do
        if (have[name] or 0) >= (wait.base or 0) + wait.count then expecting[name] = nil end
    end
    for name, wait in pairs(expecting) do
        if now() - wait.at > ARRIVE_SECONDS then
            log("supply.not_arrived", {item = name, missing = wait.count})
            expecting[name] = nil
        end
    end
    -- A craft PC48 still reports on is waited for: asked again it would be made twice.
    for name, a in pairs(asking) do
        if now() - a.at > SILENT_SECONDS then
            log("supply.timeout", {item = name, count = a.count})
            asking[name], retryAt[name] = nil, now() + EMPTY_STOCK_SECONDS
        end
    end
    local inBarrel = counts(list(d.barrel))
    stockCache = have
    local lines = {}
    if not d.outbox then lines[1] = "! no outbox chest: nothing goes to the warehouse" end
    -- First what the warehouse has (owner 2026-11-06); only what it has none
    -- of is made by PC48 (answered), one item at a time, so the fleet keeps
    -- working for the others (two 448 slab orders took all eleven turtles).
    for name, count in pairs(cfg.keep) do
        local want = count - (have[name] or 0) - (inBarrel[name] or 0)
        if want >= math.min(9, count) and not expecting[name] and not asking[name] and now() >= (retryAt[name] or 0) then
            ask(name, math.min(want, orderSize(name)), cfg.address, false)
        end
        local state = asking[name] and (asking[name].craft and " crafting" or " asking")
            or expecting[name] and " coming" or ""
        lines[#lines + 1] = string.format("%s %d/%d%s", (name:gsub("^minecraft:", "")), have[name] or 0, count, state)
    end
    return table.concat(lines, "\n")
end

-- One ask at a time: slot 1 made ready, the turtle told, then it is given
-- TOOK_SECONDS to take it (it says "took") before the next ask.
local function serveNext()
    local r = table.remove(queue, 1)
    local d = devices(config())
    local reply
    if not d.barrel or not d.stock then reply = {t = "busy", why = "no barrel or chest"}
    else
        local ok, res = pcall(counter.serve, d, r)
        reply = ok and res or {t = "busy", why = tostring(res)}
    end
    reply.req = r.req
    pcall(rednet.send, r.id, reply, SUPPLY)
    log("supply.counter", {turtle = r.id, item = r.item, count = r.count, reply = reply.t, got = reply.count, why = reply.why})
    if reply.t ~= "ready" then return end
    serving = {id = r.id, req = r.req, at = now()}
    local timer = os.startTimer(TOOK_SECONDS)
    while serving and not serving.took do
        local ev, p = os.pullEvent()
        if ev == "timer" and p == timer then break end
    end
    os.cancelTimer(timer)
    serving = nil
end

local controllerId
-- turtles' asks and PC48's answers; no peripheral call here (one would drop
-- the messages that come meanwhile)
local function receiver()
    while true do
        local sender, msg, protocol = rednet.receive()
        if protocol == SUPPLY and type(msg) == "table" then
            if msg.t == "want" then
                for i = #queue, 1, -1 do if queue[i].id == sender then table.remove(queue, i) end end
                queue[#queue + 1] = {id = sender, req = msg.req, item = msg.item, count = msg.count}
                os.queueEvent("supply_queue")
            elseif msg.t == "stock" then
                pcall(rednet.send, sender, {t = "stock", req = msg.req, items = stockCache}, SUPPLY)
            elseif msg.t == "took" and serving and serving.id == sender then
                serving.took = true
                os.queueEvent("supply_took")
            end
        elseif protocol == Util.REQUEST_PROTOCOL and sender == controllerId and type(msg) == "table" and msg.type == "supply" then
            answered(msg)
        end
    end
end

local function worker()
    while true do
        if busy() then
            serveNext()
        else
            local ok, status = pcall(step)
            term.clear(); term.setCursorPos(1, 1)
            print("Mining supply base")
            print(ok and status or ("error: " .. tostring(status)))
            if not ok then log("supply.error", {error = tostring(status)}) end
            controllerId = next(asking) and controller() or controllerId
            if next(asking) and controllerId then poll(controllerId) end
            local timer = os.startTimer(LOOP_SECONDS)
            while not busy() do
                local ev, p = os.pullEvent()
                if ev == "timer" and p == timer then break end
            end
            os.cancelTimer(timer)
        end
    end
end

peripheral.find("modem", function(name, m) rednet.open(name) end)
rednet.host(SUPPLY, "pc121")
log("fleet.release", {version = VERSION})
do
    local ok, cfg = pcall(config)
    local d = ok and devices(cfg) or {}
    log("supply.devices", {barrel = d.barrel, stock = d.stock, outbox = d.outbox or "none"})
end
parallel.waitForAny(receiver, worker)
