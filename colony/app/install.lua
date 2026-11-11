-- Colony Supply installer (MineColonies + Create + CC:Tweaked)
--   wget run https://tensa.co.ua/storage/forum-guides/colony-supply/install.lua
-- Later on this computer (after Ctrl+T):
--   install          update the program (your settings and lists stay)
--   install setup    answer the questions again
--   install auto     update without any question (startup.lua uses it)
-- At the top level only what you set up: config.lua and rules/. The program
-- is in app/, with its own memory (app/memory) and logs (app/logs).
local BASE = "https://tensa.co.ua/storage/forum-guides/colony-supply/"

-- `keep` files hold your settings and lists; an update never overwrites them
local FILES = {
    {path = "startup.lua"},
    {path = "app/install.lua"}, {path = "app/scan.lua"}, {path = "app/main.lua"}, {path = "app/util.lua"},
    {path = "app/words.lua"}, {path = "app/settings.lua"}, {path = "app/links.lua"},
    {path = "app/addresses.lua"}, {path = "app/colony.lua"}, {path = "app/supply.lua"},
    {path = "app/builder.lua"}, {path = "app/stock.lua"}, {path = "app/ingredients.lua"},
    {path = "app/send.lua"}, {path = "app/deliver.lua"}, {path = "app/screen.lua"}, {path = "app/ui.lua"},
    {path = "app/chat.lua"}, {path = "app/notify.lua"}, {path = "app/lang/uk.lua"}, {path = "app/lang/en.lua"},
    {path = "app/config.lua", to = "config.lua", keep = true},   -- the template (config.lua on the
                                                                 -- server stays the older one for old installers)
    {path = "rules/keep.lua", keep = true},
    {path = "rules/dishes.lua", keep = true},
    {path = "rules/chat.lua", keep = true},
}
-- files from older versions move to their new places
local MOVED = {{from = "requests/stock.lua", to = "rules/keep.lua"},
    {from = "requests/ingredients.lua", to = "rules/dishes.lua"},
    {from = "logs", to = "app/logs"}, {from = "data/logs", to = "app/logs"},
    {from = "data/orders.lua", to = "app/memory/orders.lua"}, {from = "data/send_hold.lua", to = "app/memory/send_hold.lua"},
    {from = "data/addresses.lua", to = "app/memory/last_addresses.lua"}}
-- program files that used to lie at the top level
local GONE = {"install.lua", "scan.lua", "lang"}

local args = {...}
local setupOnly = args[1] == "setup"
local quiet = args[1] == "auto"
local template   -- the new config.lua, filled in by setup

local function say(color, text)
    if term.isColor() then term.setTextColor(color) end
    print(text)
    term.setTextColor(colors.white)
end

local function ask(question, default)
    if term.isColor() then term.setTextColor(colors.yellow) end
    write(question .. (default and (" [" .. default .. "]") or "") .. ": ")
    term.setTextColor(colors.white)
    local answer = read()
    if answer == nil or answer:match("^%s*$") then return default end
    return (answer:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function writeFile(path, text)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then error("cannot write " .. path, 0) end
    f.write(text)
    f.close()
end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local function get(path)
    local response, err = http.get(BASE .. path, nil, true)
    if not response then error("download failed: " .. path .. " (" .. tostring(err) .. ")", 0) end
    local text = response.readAll()
    response.close()
    return text
end

-- --------------------------------------------------------------- download

local function download()
    if not http then error("HTTP is disabled on this server, ask an admin.", 0) end
    say(colors.lightBlue, "Downloading Colony Supply...")
    local got = {}
    for _, file in ipairs(FILES) do
        got[file.path] = get(file.path)
        write(".")
    end
    print()
    template = got["app/config.lua"]
    -- write only after every file arrived, so a failed download changes nothing
    if fs.exists("/startup.lua") and not (readFile("/startup.lua") or ""):find("Colony Supply", 1, true) then
        fs.delete("/startup.old.lua")
        fs.move("/startup.lua", "/startup.old.lua")
        say(colors.orange, "Your old startup.lua is saved as startup.old.lua")
    end
    for _, m in ipairs(MOVED) do
        if fs.exists("/" .. m.from) and not fs.exists("/" .. m.to) then
            local dir = fs.getDir("/" .. m.to)
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            fs.move("/" .. m.from, "/" .. m.to)
            say(colors.lightGray, m.from .. " is now " .. m.to)
        end
    end
    -- old folders go once they are empty
    for _, dir in ipairs({"/requests", "/data", "/logs"}) do
        if fs.exists(dir) and fs.list and #fs.list(dir) == 0 then fs.delete(dir) end
    end
    local fresh = not fs.exists("/config.lua")
    for _, file in ipairs(FILES) do
        local to = file.to or file.path
        if not (file.keep and fs.exists("/" .. to)) then
            writeFile("/" .. to, got[file.path])
        end
    end
    for _, path in ipairs(GONE) do
        if fs.exists("/" .. path) then fs.delete("/" .. path) end
    end
    say(colors.lime, "Program files are ready.")
    if not fresh and not (readFile("/config.lua") or ""):find("\n    kolonia = {", 1, true) then
        say(colors.lightGray, "Your config.lua uses the older English words: it keeps working.")
    end
    return fresh
end

-- ------------------------------------------------------------------ setup

local function check(ptype, what, fix)
    local p = peripheral.find(ptype)
    if p then
        say(colors.lime, "  ok   " .. what)
        return peripheral.getName(p)
    end
    say(colors.red, "  --   " .. what .. " not found")
    if fix then say(colors.lightGray, "       " .. fix) end
    return nil
end

-- key = value inside one group of config.lua ("sklad", "kolonia", "vyviz")
local function setIn(text, group, key, value)
    local open = text:find("\n    " .. group .. " = {", 1, true)
    if not open then return text end
    local close = text:find("\n    },", open, true)
    if not close then return text end
    local inside = text:sub(open, close)
    local line = "\n        " .. key .. " = " .. value .. ","
    local replaced, n = inside:gsub("\n[ \t]*" .. key .. " = [^\n]-,", (line:gsub("%%", "%%%%")), 1)
    if n == 0 then replaced = inside .. line:sub(2) .. "\n" end
    return text:sub(1, open - 1) .. replaced .. text:sub(close + 1)
end

local function quoted(name) return string.format("%q", name) end

local function chests(except)
    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "inventory") and not except[name] then list[#list + 1] = name end
    end
    return list
end

local function pickChest(question, list)
    if #list == 0 then return nil end
    say(colors.lightBlue, question)
    for i, name in ipairs(list) do
        local okSize, size = pcall(peripheral.call, name, "size")
        print(string.format("  %d  %s (%s slots)", i, name, okSize and tostring(size) or "?"))
    end
    local pick = tonumber(ask("Choose", "1")) or 1
    return list[pick] or list[1]
end

-- The addresses this computer uses now: rules/addresses.lua, else the
-- older config.lua (colony.address, send.to, or the flat `address`).
local function currentAddresses()
    local function readTable(path)
        local text = readFile(path)
        local fn = text and load(text, "=" .. path, "t", {})
        local ok, value = pcall(fn or error)
        return ok and type(value) == "table" and value or {}
    end
    local book, cfg = readTable("/rules/addresses.lua"), readTable("/config.lua")
    local colony = type(cfg.colony) == "table" and cfg.colony or {}
    local send = type(cfg.send) == "table" and cfg.send or {}
    local kolonia = type(cfg.kolonia) == "table" and cfg.kolonia or {}
    local vyviz = type(cfg.vyviz) == "table" and cfg.vyviz or {}
    return {colony = book.kolonia or book.colony or kolonia.adresa or colony.address or cfg.address,
        storage = book.sklad or book.storage or vyviz.adresa or send.to}
end

local function setup()
    print()
    say(colors.lightBlue, "Devices on this computer:")
    check("colony_integrator", "Colony Integrator", "place it touching the computer, inside the colony")
    local warehouse = check("minecolonies:warehouse", "Colony warehouse on a cable",
        "optional with a colony ticker; else put a wired modem on the Warehouse hut")

    -- tickers: the Create storage one, and maybe one on the colony's network
    local tickers = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "Create_StockTicker") then
            local ok, list = pcall(peripheral.call, name, "stock")
            local kinds = 0
            if ok and type(list) == "table" then for _ in pairs(list) do kinds = kinds + 1 end end
            tickers[#tickers + 1] = {name = name, kinds = kinds}
        end
    end
    local createTicker, colonyTicker = "auto", false
    if #tickers == 0 then
        say(colors.red, "  --   Stock Ticker not found")
        say(colors.lightGray, "       connect it with a wired modem (right-click the modem)")
    elseif #tickers == 1 then
        say(colors.lime, "  ok   Stock Ticker")
    else
        say(colors.lightBlue, "Stock tickers:")
        local biggest = 1
        for i, t in ipairs(tickers) do
            print(string.format("  %d  %s (%d kinds of items)", i, t.name, t.kinds))
            if t.kinds > tickers[biggest].kinds then biggest = i end
        end
        local main = tonumber(ask("Which one is on your Create storage?", tostring(biggest))) or biggest
        if not tickers[main] then main = biggest end
        createTicker = quoted(tickers[main].name)
        local other = tonumber(ask("Which one is on the colony's own network? (0 = none)", "0")) or 0
        if tickers[other] and other ~= main then colonyTicker = quoted(tickers[other].name) end
    end
    print()

    say(colors.lightBlue, "How do packages arrive?")
    print("  1  into a chest, the computer moves them")
    print("  2  straight into the colony warehouse")
    local mode = ask("Choose", "1") == "2" and "pryamo" or "skrynia"
    local used = {}
    if warehouse then used[warehouse] = true end
    local inbox = "false"
    if mode == "skrynia" then
        local pick = pickChest("Which chest receives the packages?", chests(used))
        if pick then
            inbox = quoted(pick)
            used[pick] = true
        else
            say(colors.red, "No chest found on the network.")
            say(colors.lightGray, "Put a wired modem on the inbox chest, right-click it, then run: install setup")
        end
    end
    local known = currentAddresses()
    local address = ask("Colony address (its frogport / postbox)", known.colony or "Colony")

    print()
    say(colors.lightBlue, "Send extra items back to Create storage?")
    print("  0  no")
    print("  1  through an outbox chest (its packager sends it)")
    if colonyTicker then print("  2  by the colony ticker") end
    local send = ask("Choose", "0")
    local sendBy, outbox, to = quoted("auto"), "false", nil
    if send == "1" then
        local pick = pickChest("Which chest is the outbox?", chests(used))
        if pick then
            sendBy, outbox = quoted("skrynia"), quoted(pick)
        else
            say(colors.red, "No free chest found for the outbox.")
        end
    elseif send == "2" and colonyTicker then
        sendBy = quoted("tiker")
        to = ask("Create storage address", known.storage or "Storage")
    end
    local sendOn = (send == "1" or send == "2") and "true" or "false"

    local text = readFile("/config.lua") or ""
    if text:find("\n    colony = {", 1, true) then
        -- the previous version's config (English words): only the answers
        -- change, every other setting stays
        local english = {chest = "chest", pryamo = "direct", skrynia = "chest", tiker = "ticker", auto = "auto"}
        local function en(v) return (v:gsub('^"(%a+)"$', function(w) return '"' .. (english[w] or w) .. '"' end)) end
        text = setIn(text, "create", "ticker", createTicker == "auto" and quoted("auto") or createTicker)
        text = setIn(text, "colony", "ticker", colonyTicker or "false")
        text = setIn(text, "colony", "delivery", en(quoted(mode)))
        text = setIn(text, "colony", "inbox", inbox)
        text = setIn(text, "send", "enabled", sendOn)
        text = setIn(text, "send", "by", en(sendBy))
        text = setIn(text, "send", "outbox", outbox)
    else
        if not text:find("\n    kolonia = {", 1, true) then
            -- none yet, or a very old one: start from the template
            text = template or get("app/config.lua")
            if fs.exists("/config.lua") then
                fs.delete("/config.old.lua")
                fs.move("/config.lua", "/config.old.lua")
                say(colors.lightGray, "Your very old settings are saved as config.old.lua")
            end
        end
        text = setIn(text, "sklad", "tiker", createTicker == "auto" and quoted("auto") or createTicker)
        text = setIn(text, "kolonia", "tiker", colonyTicker or "false")
        text = setIn(text, "kolonia", "dostavka", quoted(mode))
        text = setIn(text, "kolonia", "skrynia", inbox)
        text = setIn(text, "vyviz", "uvimkneno", sendOn)
        text = setIn(text, "vyviz", "cherez", sendBy)
        text = setIn(text, "vyviz", "skrynia", outbox)
    end
    writeFile("/config.lua", text)
    -- the addresses: rules/addresses.lua (the program adds the huts later)
    local book = readFile("/rules/addresses.lua") or get("rules/addresses.lua")
    local function setLine(t, key, value)
        local line = "\n    " .. key .. " = " .. quoted(value) .. ","
        local out, n = t:gsub("\n    " .. key .. " = [^\n]*", (line:gsub("%%", "%%%%")), 1)
        return out
    end
    book = setLine(book, "kolonia", address)
    book = setLine(book, "sklad", to or known.storage or "Storage")
    writeFile("/rules/addresses.lua", book)
    say(colors.lime, "Settings saved to config.lua and rules/addresses.lua")
    if send == "1" or send == "2" then say(colors.lightGray, "Give the items to send a maks in rules/keep.lua") end
end

-- ------------------------------------------------------------------- main

if not quiet then
    term.clear()
    term.setCursorPos(1, 1)
end
say(colors.lightBlue, "== Colony Supply installer ==")
if not term.isColor() then
    say(colors.red, "This program needs an Advanced Computer (the gold one).")
    return
end

local fresh = false
if not setupOnly then fresh = download() end
if quiet then return end
if setupOnly or fresh then setup() end

print()
if (ask("Start the program now? (y/n)", "y") or "y"):lower():sub(1, 1) == "y" then
    os.reboot()
else
    say(colors.lightGray, "Restart the computer (Ctrl+R) when you are ready.")
end
