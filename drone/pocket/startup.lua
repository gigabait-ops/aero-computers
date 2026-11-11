-- The owner's pocket computer or smart glasses: teleport pads, quick drone
-- control and the drone's routes on the shared CC UI kit (pda/pages.lua). Glasses
-- add, with their modules and pocket upgrades: the drone's status on the
-- screen while flying (Overlay Module, pda/hud.lua), drone news in chat
-- (Chat Box, pda/chat.lua), players coming near and going in chat
-- (Player Detector), the warehouse fleet's news in chat (the fleet's chat
-- relay; the base's Chat Box PC135 is gone since 2026-11-08), the mining
-- remote's tab when kopach/ is installed, and a Settings tab switching news
-- and the HUD. Needs a wireless or ender modem; the drone needs
-- settings drone.master and drone.key.
local ok, UI = pcall(require, "ui")
if not (ok and type(UI) == "table" and UI.App) then printError("the CC UI kit (require \"ui\") is missing"); return end
local P = require("pda.kitpage")
local T = require("pda.teleports")
local D = require("pda.drone")
local Rs = require("pda.routes")
local Keys = require("pda.keys")
local Pages = require("pda.pages")
local Actions = require("pda.actions")
local Hud = require("pda.hud")
local Chat = require("pda.chat")

-- The fleet's chat relay (PC48 and the stations broadcast keys on
-- gigabait.chat.v1) from the server's fleet ROM, when it is there.
local FLEET_ROM = "/rom/modules/main/fleet_20260906"
local Relay, FLEET_PROTOCOL
if fs.exists(FLEET_ROM) then
    package.path = package.path .. ";" .. FLEET_ROM .. "/?.lua;" .. FLEET_ROM .. "/?/init.lua"
    local okr, mod = pcall(require, "chat.relay")
    local okn, notice = pcall(require, "chat.notice")
    if okr and okn then Relay, FLEET_PROTOCOL = mod, notice.PROTOCOL
    else printError("fleet chat: " .. tostring(okr and notice or mod)) end
end

-- The mining remote (kopach/, put beside this app by the Aero repo's
-- tools/deploy_kopach.sh module <id>) as one more tab, when it is there
-- (owner 2026-11-03): Dig and Turtles inside it. A broken one leaves the
-- rest working.
local Kp, MINE = nil, "Mine"
if rawget(_G, "fs") and fs.exists("/kopach/app.lua") then
    local okk, mod = pcall(require, "kopach.app")
    if okk and type(mod) == "table" and mod.tab then
        local oki, err = pcall(mod.init)
        if oki then Kp = mod else printError("kopach: " .. tostring(err)) end
    else printError("kopach: " .. tostring(mod)) end
end

local function page_list()
    return Pages.list(Kp and {Kp.tab(MINE)} or nil)
end

local function on_action(action, st)
    if Kp and tostring(action.id or ""):find("^kp_") then return Kp.on_action(action) end
    return Actions.on_action(action, st)
end

local state = {
    tp = T.new({send = function(msg) rednet.broadcast(msg, T.PROTOCOL) end, clock = os.clock, settings = settings}),
    drone = D.new({send = function(id, msg) rednet.send(id, msg, D.PROTOCOL) end, clock = os.clock, settings = settings}),
    near = {},
}
state.routes = Rs.new(state.drone)
state.keys = Keys.new()   -- the keyboard flies the drone on its tab
state.dview = settings.get("pda.drone_view") or "status"   -- the Drone tab's sub-tab

-- Who wears the glasses (drone news goes to them only): the glasses' owner,
-- else the one player within a block of a Player Detector in them.
local function owner(detector)
    local api = rawget(_G, "smartglasses")
    if type(api) == "table" and type(api.getOwner) == "function" then
        local okk, o = pcall(api.getOwner)
        if okk and type(o) == "table" and (o.name or o.displayName) then return o.name or o.displayName end
    end
    if detector then
        local okk, names = pcall(detector.getPlayersInRange, 1)
        if okk and type(names) == "table" and #names == 1 then return names[1] end
    end
    return settings.get("owner")
end

-- Drone news or players coming and going, as the Settings tab says.
local function allow(key)
    return Pages.on(key:match("^player%.") and "pda.chat.players" or "pda.chat.drone")
end

-- The fleet's lines go to the wearer only (no owner known: players within
-- 16 blocks), not to everyone near as the base's Chat Box did.
local function fleet_box(box, who)
    if not box then return nil end
    return {sendFormattedMessage = function(json, opts)
        opts = opts or {}
        if who then opts.player, opts.range = who, nil else opts.range = 16 end
        return box.sendFormattedMessage(json, opts)
    end}
end

-- Modem, modules and upgrades may come and go (glasses: their slots); each
-- is found again on a peripheral or module event.
local hud, chat, detector, relay
local function attach()
    local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if modem then rednet.open(peripheral.getName(modem)) end
    hud = Hud.new(peripheral.find("smart_glasses"))
    detector = peripheral.find("player_detector")
    local box, who = peripheral.find("chat_box"), owner(detector)
    chat = Chat.new(box, who, nil, allow)
    if Relay then
        relay = relay or Relay.new({config = {prefix = "Склад"}})
        relay.box = fleet_box(box, who)
    end
    state.hud = hud
end
attach()

-- Other players within 128 blocks (the detector's limit on Aero).
local function look_around()
    state.near = {}
    if not detector then return end
    local okk, names = pcall(detector.getPlayersInRange, 128)
    local me = chat and chat.owner or owner(detector)
    for _, n in ipairs(okk and type(names) == "table" and names or {}) do
        if n ~= me then state.near[#state.near + 1] = n end
    end
end

-- Any tab with no prompt open: there the keyboard flies the drone (the
-- hint on or off; owner 2026-10-24).
local function drone_keys_tab(app)
    local s = app.screens.terminal
    return s ~= nil and not (state.drone.edit or state.routes.edit or state.tp.edit) and D.configured(state.drone)
end
local flying_keys = drone_keys_tab

-- The HUD's key hint while it is on (numpad 8, the Hint row).
local function keys_hint()
    return Keys.hint(state.keys, state.drone)
end

-- The HUD unless the Settings tab turned it off (then wiped once).
local hud_off = false
local function draw_hud()
    if Pages.on("pda.hud") then hud_off = false; return Hud.draw(hud, state.drone, keys_hint()) end
    if not hud_off then hud_off = true; Hud.clear(hud) end
end

-- One run of the app: until the owner ends it (Ctrl+T) or it fails.
local function run()
    local app = assert(UI.App.new{pages = page_list(), state = state, onAction = on_action, interval = 1,
        adapters = {getNames = function() return {} end, current = function() return P.tall(term.current()) end}})
    -- the tab open before a restart opens again (settings pda.tab; owner 2026-10-18)
    local kept = settings.get("pda.tab")
    for _, pg in ipairs(page_list()) do
        if pg.name == kept and app.screens.terminal then app.screens.terminal.active = kept end
    end

    -- The open tab does the talking: Teleports pings the pads now and then;
    -- the drone is asked for its status every second on its tabs, and always
    -- with the HUD or the chat box.
    local tick, shown, looked, second = os.startTimer(0.5), nil, -math.huge, -math.huge
    local function loop()
        app:render()
        while not app.closed do
            local ev = table.pack(os.pullEvent())
            if Kp and Kp.on_event(table.unpack(ev, 1, ev.n)) then
                app:render()   -- the turtles' radio
            elseif ev[1] == "rednet_message" and relay and ev[4] == FLEET_PROTOCOL then
                if Pages.on("pda.chat.fleet") then pcall(relay.handle, relay, ev[3]) end
            elseif ev[1] == "rednet_message" then
                local sender, msg, proto = ev[2], ev[3], ev[4]
                local changed = (proto == T.PROTOCOL and T.on_message(state.tp, sender, msg))
                    or (proto == D.PROTOCOL and D.on_message(state.drone, sender, msg))
                if changed then
                    local st = state.drone.status
                    P.apply_style(app, st and st.buttons)   -- the drone's button style
                    app:render(); draw_hud(); Chat.notify(chat, state.drone)
                end
            elseif (ev[1] == "key" or ev[1] == "key_up") and drone_keys_tab(app)
                and Keys.event(state.keys, state.drone, ev[1], ev[2], os.clock()) then
                draw_hud()   -- a flight key: the drone took it (the hint lights it)
            elseif ev[1] == "char" and flying_keys(app) and Keys.CHARS[ev[2]] then
                -- the letter of a flight key: nothing to type on the Drone tab
            elseif ev[1] == "timer" and ev[2] == tick then
                local s = app.screens.terminal
                local active = s and s.active
                if flying_keys(app) then Keys.tick(state.keys, state.drone, os.clock()) else Keys.release(state.keys, state.drone, os.clock()) end
                if active == "Drone" or hud or chat then D.tick(state.drone) end
                if active == "Teleports" then
                    if active ~= shown then T.ping(state.tp) else T.tick(state.tp) end
                end
                if active and active ~= shown then settings.set("pda.tab", active); settings.save() end
                shown = active
                if Kp and os.clock() - second >= 1 then second = os.clock(); Kp.second() end
                if os.clock() - looked >= 2 then
                    looked = os.clock(); look_around()
                    Chat.players(chat, state.near, looked)   -- players come and go, drone or not
                end
                tick = os.startTimer(0.5)
                app:render()
                draw_hud()
                Chat.notify(chat, state.drone)
                Chat.tick(chat)   -- one chat message a tick, queued by the news
                -- the fleet's when the drone's are out (one box, one message a tick)
                if relay and not (chat and chat.queue[1]) then pcall(relay.tick, relay) end
            elseif ev[1] == "mouse_scroll" then
                -- the wheel scrolls the open tab's list
                local s = app.screens.terminal
                local sub = s and s.active == "Drone" and state.dview
                local m = s and (sub == "points" and state.drone or sub == "routes" and state.routes or s.active == "Teleports" and state.tp)
                if m then Pages.scroll(m, ev[2]); app:render()
                elseif Kp and s and s.active == MINE then Kp.scroll(ev[2]); app:render() end
            elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" or ev[1] == "glasses_module" or ev[1] == "glasses_module_detach" then
                attach()
                P.handle(app, table.unpack(ev, 1, ev.n))
            else
                P.handle(app, table.unpack(ev, 1, ev.n))
            end
        end
    end
    -- the mining tab's GPS, every 2 s while it is open, beside the loop:
    -- gps.locate drops the events it waits through (keys, the drone's status)
    local function gps_loop()
        while true do
            local s = app.screens.terminal
            if s and s.active == MINE then Kp.locate(gps.locate(1)) end
            sleep(2)
        end
    end
    -- the kit's palette and the HUD are put back however the loop ends
    local ok, err = pcall(function()
        if Kp then parallel.waitForAny(loop, gps_loop) else loop() end
    end)
    app:close()
    Hud.clear(hud)
    if not ok then error(err, 0) end
    if app.error then error(app.error, 0) end   -- the kit closed itself after an error
end

-- A failure starts the app again after a moment (glasses left blank with no
-- HUD, no news, no tabs are worse than a blink); Ctrl+T ends it.
while true do
    local ok, err = pcall(run)
    if ok or err == "Terminated" then break end
    pcall(Hud.clear, hud)
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    term.clear(); term.setCursorPos(1, 1)
    printError("pda: " .. tostring(err) .. " - starting again")
    sleep(3)
    attach()
end
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1)
