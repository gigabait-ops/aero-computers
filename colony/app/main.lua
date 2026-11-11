-- Colony Supply: wiring and the parallel loops (scan, input, optional modules).
--
--   app/settings.lua    config.lua with defaults; old config files still work
--   app/words.lua       the Ukrainian keys of config.lua and rules/*.lua
--   app/links.lua       what is connected: tickers, warehouse, chests
--   app/addresses.lua   rules/addresses.lua: the colony's, storage's and
--                       each building's Create address
--   app/colony.lua      colony requests with building names, hut list
--   app/supply.lua      orders from Create storage for every open request
--   app/stock.lua       Keep: the `min` lines of rules/keep.lua
--   app/builder.lua     Build: the builders' queue, materials before they ask
--   app/ingredients.lua dishes -> raw food for the cook (rules/dishes.lua)
--   app/send.lua        Send: above `max` (rules/keep.lua) back to Create storage
--   app/deliver.lua     inbox chest -> colony warehouse ("chest" delivery)
--   app/screen.lua      the screens (the server's shared UI library)
--   app/ui.lua          the pages
--   app/chat.lua        OPTIONAL: game chat through a Chat Box or a chat relay
--                       (texts app/lang/*.lua, rules rules/chat.lua)
--   app/notify.lua      what is worth a chat line (used by app/chat.lua)
--   app/craft.lua       OPTIONAL, the author's computer only: asks a craft
--                       controller for what storage lacks
--   app/snapshot.lua    OPTIONAL diagnostics dump (snapshot_every > 0)
local U = require("app.util")
local W = require("app.words")
local Settings = require("app.settings")
local Links = require("app.links")
local Addresses = require("app.addresses")
local Supply = require("app.supply")
local Deliver = require("app.deliver")
local Builder = require("app.builder")
local Colony = require("app.colony")
local Stock = require("app.stock")
local Ingredients = require("app.ingredients")
local Send = require("app.send")
local Screen = require("app.screen")
local UI   -- app.ui, loaded once the library is checked

local M = {}

local function openModems()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            pcall(rednet.open, name)
            names[#names + 1] = name
        end
    end
    return names
end

-- Four integrator calls, once a minute.
local function colonyStatus(integrator)
    local ok, inColony = pcall(integrator.isInColony)
    if not ok or not inColony then return {text = "OUTSIDE THE COLONY"} end
    local okName, name = pcall(integrator.getColonyName)
    if not okName then return {text = "NO PERMISSION for this computer"} end
    local _, citizens = pcall(integrator.getCitizenCount)
    local _, hap = pcall(integrator.getHappiness)
    return {name = tostring(name), citizens = tonumber(citizens), happiness = tonumber(hap) or 0}
end

-- The Log tab: newest first, at most 40.
local function remember(st, kind, text)
    table.insert(st.events, 1, {kind = kind, text = text, at = U.now()})
    while #st.events > 40 do table.remove(st.events) end
end

-- The optional craft module. A missing file is fine; a broken one is logged.
local function loadCraft(cfg, log, st, onMade)
    if cfg.craft.enabled == false then return nil end
    local ok, Craft = pcall(require, "app.craft")
    if not ok then
        if not tostring(Craft):find("not found", 1, true) then log.error("craft", tostring(Craft)) end
        return nil
    end
    if #openModems() == 0 then
        log.warn("no modem: craft module off")
        return nil, "no modem on the computer"
    end
    return Craft.new({config = cfg.craft, log = log, clock = U.now, send = rednet.send, lookup = rednet.lookup,
        receive = rednet.receive, computerId = os.getComputerID and os.getComputerID() or 107,
        deliverTo = cfg.colony.address, onMade = onMade,
        remember = function(kind, text) remember(st, kind, text) end})
end

-- The optional chat module: needs app/chat.lua; it speaks once a Chat Box
-- is on the computer (placed later is fine). Without either nothing changes.
local function findChatBox()
    return peripheral.find("chat_box") or peripheral.find("chatBox")
end

local function loadChat(cfg, log, integrator)
    if cfg.chat.enabled == false then return nil end
    local okC, Chat = pcall(require, "app.chat")
    local okN, Notify = pcall(require, "app.notify")
    if not (okC and okN) then
        log.warn("chat", tostring(okC and Notify or Chat))
        return nil
    end
    local rules = U.watchTable(cfg.chat.rules, W.chat)
    local relay
    if cfg.chat.relay then
        if #openModems() == 0 then
            log.warn("chat", "relay needs a modem")
        else
            relay = function(message) rednet.broadcast(message, Chat.PROTOCOL) end
        end
    end
    local chat = Chat.new({box = not relay and findChatBox() or nil, relay = relay, config = cfg.chat,
        clock = U.now, log = log, rules = rules() or {}})
    chat.reloadRules = rules   -- rules/chat.lua edits work without a restart
    return chat, Notify.new({chat = chat, integrator = integrator, clock = U.now})
end

local function configStamp()
    local ok, attr = pcall(fs.attributes, "/config.lua")
    return ok and type(attr) == "table" and attr.modified or nil
end

-- A broken config.lua must not run with defaults (wrong address, wrong mode).
local function waitForConfigFix(err)
    local before = configStamp()
    return Screen.hold("config.lua has an error:", {(tostring(err):gsub("^/", "")), "",
        "Hold Ctrl+T, then: edit config.lua"}, function() return configStamp() ~= before end)
end

-- No integrator or no Create ticker: wait for a device or a config change.
local function waitForLinks(problem)
    local names = #peripheral.getNames()
    local before = configStamp()
    return Screen.hold("Colony Supply cannot start:", {problem}, function()
        return #peripheral.getNames() ~= names or configStamp() ~= before
    end)
end

local function waitForLibrary(err)
    return Screen.hold("Colony Supply needs the server's UI library.", {tostring(err), "",
        "It is common.ui from the Tensa Aeronautics datapack."}, function() return Screen.library() ~= nil end)
end

function M.run()
    local cfg, configError = Settings.load(U.loadTable, "/config.lua")
    if configError then return waitForConfigFix(configError) end
    -- a diagnostics dump left over from a check is about half the 1 MB disk:
    -- with it the logs ran out of space (2026-10-30)
    if (tonumber(cfg.snapshot_every) or 0) <= 0 and fs.exists("/app/memory/snapshot.lua") then
        pcall(fs.delete, "/app/memory/snapshot.lua")
    end
    local Lib, libError = Screen.library()
    if not Lib then return waitForLibrary(libError) end
    package.loaded["app.ui"] = nil
    UI = require("app.ui")
    local st = {now = U.now(), interval = cfg.orders.interval, events = {}, craftingItems = {}, links = {}}
    local log = U.makeLog(cfg.log)
    log.info("devices", table.concat(peripheral.getNames(), " "))
    -- rules/addresses.lua (written now when missing, from the config's two
    -- addresses); the colony's huts are added at the first look at the colony
    local addresses = Addresses.new({path = cfg.addresses, read = U.readText, write = U.writeText,
        load = U.loadTable, log = log, colony = cfg.colony.address, storage = cfg.send.to,
        store = U.fileStore("/app/memory/last_addresses.lua")})
    local okA, errA = pcall(addresses.sync, addresses, {})
    if not okA then log.error("addresses", tostring(errA)) end
    cfg.colony.address, cfg.send.to = addresses.colony, addresses.storage
    local links = Links.find(cfg, peripheral)
    if links.fatal then
        log.error("links", links.fatal)
        return waitForLinks(links.fatal)
    end
    -- one read of each chest serves the whole scan (orders, keep, send)
    local function cached(inv) return U.cachedInventory(inv, math.max(5, cfg.orders.interval - 1), U.now) end
    local colonyView = Links.colonyView(links, cached)   -- what the colony holds (nil: not seen)
    local inboxView = cached(links.inbox)
    local function exists(path) return fs.exists(path) end

    local extras = {}
    local builder
    if cfg.builder.enabled then
        builder = Builder.new({integrator = links.integrator, log = log, config = cfg.builder, clock = U.now,
            inventories = {colonyView, inboxView}})
        extras[#extras + 1] = function()
            -- without seeing the colony's storage it would order whole plans
            if not colonyView then return {} end
            return builder:entries()
        end
    end
    -- rules/keep.lua: `min` for Keep, `maks` for Send, read once per change
    local keepRules = U.watchTable(Settings.rulesPath(cfg, "keep", exists), W.keep)
    local stock
    if cfg.keep.enabled and colonyView then
        stock = Stock.new({warehouse = colonyView, inbox = inboxView, log = log, clock = U.now, config = cfg.keep,
            loader = keepRules})
        extras[#extras + 1] = function() return stock:entries() end
    end
    st.keepOff = not cfg.keep.enabled and "Keep is off (config.lua: zapas = false)."
        or (not colonyView and "Keep needs to see the colony storage: a cable to the warehouse hut or a colony ticker.")
        or nil
    local ingredients
    if cfg.dishes.enabled then
        ingredients = Ingredients.new({log = log, clock = U.now,
            config = {reload_every = cfg.dishes.reload_every, max = cfg.orders.max, reorder_after = cfg.dishes.reorder_after},
            loader = U.watchTable(Settings.rulesPath(cfg, "dishes", exists), W.dishes)})
    end
    local send
    if cfg.send.enabled and colonyView then
        send = Send.new({loader = keepRules, view = colonyView, by = links.sendBy,
            ticker = links.colonyTicker, warehouse = links.warehouse, outboxName = links.outboxName,
            log = log, clock = U.now, config = cfg.send, store = U.fileStore("/app/memory/send_hold.lua")})
    end
    st.sendOff = not cfg.send.enabled and "Send is off (config.lua: vyviz = false)."
        or (not colonyView and "Send needs to see the colony storage: a cable to the warehouse hut or a colony ticker.")
        or nil

    local colony = Colony.new({integrator = links.integrator, clock = U.now, log = log, addresses = addresses,
        expand = ingredients and function(list) return ingredients:expand(list) end or nil})
    local supply = Supply.new({
        integrator = colony, ticker = links.ticker, inbox = inboxView, log = log, config = Settings.supplyConfig(cfg),
        clock = U.now, sleep = sleep, store = U.fileStore("/app/memory/orders.lua"), extras = extras,
        addressFor = function(request) return addresses:of(request.targetPos) end,
    })

    -- "chest" delivery: everything in the inbox goes into the colony warehouse
    local deliver
    if links.inbox and links.warehouseName then
        deliver = Deliver.new({source = links.inbox, targets = {links.warehouseName}, log = log})
    end

    -- what the craft controller ships straight to the colony is held like an order (not sent back at once)
    local craft, craftProblem = loadCraft(cfg, log, st, function(name, count)
        if send then send:noteOrdered(name, count) end
    end)
    if craft then supply.gate = craft:orderGate() end
    local chat, notify = loadChat(cfg, log, links.integrator)
    -- said once per boot, not after every saved config.lua
    if chat and not _G.colonySupplyStarted then
        chat:emit("system.started", {})
        _G.colonySupplyStarted = true
    end

    local snapshotEvery = tonumber(cfg.snapshot_every) or 0
    local Snapshot
    if snapshotEvery > 0 then
        local okSnap, mod = pcall(require, "app.snapshot")
        if okSnap then Snapshot = mod else log.warn("snapshot module missing") end
    end

    local screen = Screen.open(Lib, UI.pages(craft ~= nil), st, cfg, log, U.now)
    for _, id in ipairs(screen.monitors) do log.info("monitor", id, "attached") end

    log.info("boot", "integrator", links.integratorName, "ticker", links.tickerName,
        "colony", links.colonyView or "not seen", "colony ticker", links.colonyTickerName or "-",
        "delivery", links.delivery, "inbox", links.inboxName or "-", "send", links.sendBy or "-",
        "craft", craft and "on" or "off", "chat", chat and (chat.relay and "relay" or chat.box and "on" or "no Chat Box") or "off", "monitor", #screen.monitors > 0 and table.concat(screen.monitors, ",") or "none",
        "order gate", supply.gate and "on" or "off")

    -- Home rows: the links found at boot plus the craft module's live state
    local function linkRows()
        local rows = {}
        for _, r in ipairs(links.rows) do rows[#rows + 1] = r end
        if craft then
            local level, value = craft:link()
            rows[#rows + 1] = {label = "Craft", level = level, value = value}
        elseif craftProblem then
            rows[#rows + 1] = {label = "Craft", level = "warn", value = craftProblem}
        end
        rows[#rows + 1] = {label = "Addresses", level = addresses.problem and "warn" or "ok",
            value = addresses.problem and "rules/addresses.lua has an error"
                or string.format("%s; %d of %d huts own", addresses.colony, addresses.own, addresses.count)}
        if chat then
            rows[#rows + 1] = (chat.box or chat.relay)
                and {label = "Chat", level = "ok", value = string.format("%s, %d sent", chat.relay and "relay" or "Chat Box", chat.sent)}
                or {label = "Chat", level = "off", value = "no Chat Box (optional)"}
        end
        return rows
    end

    local colonyAt
    local function refreshState()
        st.now = U.now()
        if not colonyAt or st.now - colonyAt >= 60 then
            st.colony = colonyStatus(links.integrator)
            colonyAt = st.now
        end
        -- addresses edited in rules/addresses.lua work without a restart
        if send then send.config.to = addresses.storage end
        if craft then craft.deliverTo = addresses.colony end
        st.links = linkRows()
        st.openOrders = supply:openOrders()
        st.stock = stock and stock.last or nil
        st.rules = stock and stock.rules or {}
        st.send = send and send.last or nil
        st.builder = builder and builder.last or nil
        st.queue = builder and builder.queue or {}
        st.builders = colony.builders
        st.buildings = colony.buildingList
        if notify then
            notify:buildings(colony.buildingList)
            notify:colony(st.now)
        end
        st.craftRows = craft and craft:rows() or nil
        st.craftingItems = {}
        for _, r in ipairs(st.craftRows or {}) do
            if st.now - (r.at or 0) < (cfg.craft.again or 900) and (r.answer == nil or r.answer == "accepted") then
                st.craftingItems[r.item] = true
            end
        end
    end

    -- what the colony asks for right now (stays in the colony when sending)
    local function askedNow()
        local asked = {}
        for _, r in ipairs(st.last and st.last.requests or {}) do
            if r.item then asked[r.item] = (asked[r.item] or 0) + (tonumber(r.count) or 0) end
        end
        -- everything the builders' plans still need, also what already lies here
        if builder then
            for name, n in pairs(builder:needs()) do asked[name] = math.max(asked[name] or 0, n) end
        end
        return asked
    end
    local function keepMinimums()
        local mins = {}
        for _, rule in ipairs(stock and stock.rules or {}) do mins[rule.item] = math.max(mins[rule.item] or 0, rule.min) end
        return mins
    end

    local lastProblem
    local function scan()
        local ok, result = pcall(supply.cycle, supply)
        if not ok then
            st.last = {open = 0, ordered = {}, missing = {}, errors = {tostring(result)}, done = 0, requests = {}}
            log.error("cycle crashed", tostring(result))
            return
        end
        st.last = result
        local errors = table.concat(result.errors, " | ")
        if errors ~= "" and errors ~= lastProblem then
            log.error("CYCLE", errors)
            remember(st, "problem", errors)
        end
        lastProblem = errors
        -- what goes to the warehouse is held there for a while; a hut with
        -- its own address gets its packages elsewhere
        local function toWarehouse(e) return e.address == nil or e.address == addresses.colony end
        for _, o in ipairs(result.ordered) do
            remember(st, "order", string.format("Ordered %dx %s for %s", o.count, UI.pretty(o.name), UI.prettyTarget(o.target)))
            if send and toWarehouse(o) then send:noteOrdered(o.name, o.count, tostring(o.target):find("^builder") ~= nil) end
        end
        for _, c in ipairs(result.completed or {}) do
            remember(st, "delivered", string.format("Delivered %dx %s for %s", c.count, UI.pretty(c.name), UI.prettyTarget(c.target)))
            if send and toWarehouse(c) then send:noteDelivered(c.name, c.count, tostring(c.target):find("^builder") ~= nil) end
        end
        if craft then
            local okC, err = pcall(craft.afterCycle, craft, result)
            if not okC then log.error("craft", tostring(err)) end
        end
        if notify then
            local okN, err = pcall(notify.cycle, notify, result, function(name)
                return st.craftingItems ~= nil and st.craftingItems[name] == true
            end)
            if not okN then log.error("chat", tostring(err)) end
        end
        -- after a boot nothing goes out until the builders' plans were read
        if send and (not builder or builder.cachedAt) then
            local okS, sent = pcall(send.check, send, askedNow(), keepMinimums())
            if not okS then
                log.error("send", tostring(sent))
            else
                for _, s in ipairs(sent) do
                    remember(st, "sent", string.format("Sent %dx %s to storage", s.count, UI.pretty(s.name)))
                end
            end
        end
        if send then send:flush() end
    end

    -- a saved config.lua restarts the program with the new settings
    local bootStamp = configStamp()
    local restart = false
    local function loop()
        local cycles = 0
        while true do
            scan()
            if deliver then
                local okD, moved, _, err = pcall(deliver.run, deliver)
                if not okD then log.error("deliver", tostring(moved)) elseif err then log.warn(err) end
            end
            st.updatedAt = U.now()
            local okR, errR = pcall(refreshState)
            if not okR then log.error("refresh", tostring(errR)) end
            screen.draw()
            cycles = cycles + 1
            if Snapshot and cycles % snapshotEvery == 0 then
                local okSnap, snapErr = pcall(Snapshot.write, links.integrator, {last = st.last}, nil,
                    {warehouse = links.warehouse, inbox = links.inbox})
                if not okSnap then log.error("SNAPSHOT", tostring(snapErr)) end
            end
            sleep(cfg.orders.interval)
            if configStamp() ~= bootStamp then
                log.info("config.lua changed: starting again")
                restart = true
                return
            end
        end
    end

    local loops = {loop, screen.input}
    if craft then loops[#loops + 1] = function() craft:loop() end end
    if chat then
        loops[#loops + 1] = function()
            while true do
                local okW, found = pcall(chat.watch, chat, findChatBox, 5)
                if okW and found then log.info("chat", "Chat Box found") end
                chat.rules = chat.reloadRules() or chat.rules
                local okT, err = pcall(chat.tick, chat)
                if not okT then log.error("chat", tostring(err)) end
                sleep(1)
            end
        end
    end
    pcall(refreshState)
    screen.draw()
    local ok, err = pcall(parallel.waitForAny, table.unpack(loops))
    screen.close()
    if not ok then error(err, 0) end
    if restart then return "restart" end
end

return M
