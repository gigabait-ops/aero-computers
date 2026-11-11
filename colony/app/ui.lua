-- Colony Supply pages for the shared UI library (`require("ui")`, the
-- server's common.ui with App). The library owns the screen: tabs, footer,
-- scrolling, touch, the optional monitor and the palette. This module only
-- turns the state main refreshes every scan into rows.
--
-- One topic per tab: Home (colony + links), Requests, Keep, Send, Build,
-- Craft (only with the craft module), Log. Plain short English words; the
-- CC font has no Cyrillic.
--
-- A page is a list of rows; a row is a list of coloured segments, so
-- columns, state dots and bars stay on a fixed grid (common.ui Rows).
local Lib = require("ui")
local Text, Rows, Theme = Lib.Text, Lib.Rows, Lib.Theme

local UI = {}

UI.C = Lib.colors      -- CC colours (the library falls back to the 16 slots)
UI.age = Text.age      -- 59s, 12m, 1.5h

local THEME = Theme.resolve()
UI.COLOR = THEME
local TEXT, MUTED, ACCENT = THEME.text, THEME.muted, THEME.accent
local OK, WARN, BAD, INFO, BUSY = THEME.ok, THEME.warn, THEME.bad, THEME.info, THEME.busy

-- ---------------------------------------------------------------- helpers

local function fit(text, width, right) return Text.fit(text, width, right) end
UI.fit = fit

-- The screen's clock (App passes context.now to every page), else the
-- time of the last scan.
local function clockOf(state, context)
    return tonumber(context and context.now) or tonumber(state.now) or 0
end
UI.clockOf = clockOf

-- Cells a row may use: 49 on the 51-wide computer screen, less on a small
-- monitor. Name columns take what the fixed columns leave.
local function widthOf(context)
    local rect = context and (context.rect or context.bodyRect)
    return math.max(20, ((rect and rect.width) or 50) - 1)
end
UI.widthOf = widthOf
local NARROW = 40

local function seg(text, fg, bg) return Rows.segment(text, fg, bg) end
UI.seg = seg

local function line(list, color, text) list[#list + 1] = {segs = {seg(text, color or TEXT)}} end
local function blank(list) list[#list + 1] = {segs = {}} end
local function row(list, segs) list[#list + 1] = {segs = segs} end
local function section(list, title, note)
    local r = Rows.section(title, note ~= nil and tostring(note) or nil, THEME)
    list[#list + 1] = r
end
UI.line, UI.blank, UI.row, UI.section = line, blank, row, section

local DOT = string.char(7)
UI.DOT = DOT

local function chip(word, color, width) return Rows.chip(word, color, width) end
UI.chip = chip
local function bar(value, max, width, color) return Rows.bar(value, max, width or 10, color, THEME) end
UI.bar = bar
local function pips(level, max, color) return Rows.pips(level, max, color, THEME) end

-- "minecraft:brown_mushroom" -> "Brown mushroom", "1-64 Lamb Stew" -> "Lamb Stew"
function UI.pretty(name) return Text.pretty(name) end

-- MineColonies hut type -> name shown in the game
UI.HUT_NAMES = {
    townhall = "Town Hall", builder = "Builder's Hut", warehouse = "Warehouse", deliveryman = "Courier's Hut",
    residence = "Residence", citizen = "Residence", cook = "Dining Hall", kitchen = "Kitchen", baker = "Bakery",
    guardtower = "Guard Tower", barracks = "Barracks", barrackstower = "Barracks Tower", archery = "Archery",
    combatacademy = "Combat Academy", university = "University", library = "Library", school = "School",
    hospital = "Hospital", tavern = "Tavern", postbox = "Postbox", stash = "Stash",
    fisherman = "Fisher's Hut", lumberjack = "Forester's Hut", miner = "Mine", quarrier = "Quarry",
    farmer = "Farm", plantation = "Plantation", beekeeper = "Apiary", chickenherder = "Chicken Farmer",
    cowboy = "Cowhand", shepherd = "Shepherd", swineherder = "Swine Herder", rabbithutch = "Rabbit Hutch",
    composter = "Composter", florist = "Flower Shop", sawmill = "Sawmill", stonemason = "Stonemason",
    stonesmeltery = "Stone Smeltery", smeltery = "Smeltery", crusher = "Crusher", sifter = "Sifter",
    blacksmith = "Blacksmith's Hut", mechanic = "Mechanic's Hut", fletcher = "Fletcher", dyer = "Dyer",
    glassblower = "Glassblower", concretemixer = "Concrete Mixer", enchanter = "Enchanter's Tower",
    alchemist = "Alchemist", netherworker = "Nether Mine", graveyard = "Graveyard", mysticalsite = "Mystical Site",
}

function UI.hutName(kind)
    kind = tostring(kind or "?")
    return UI.HUT_NAMES[kind] or (kind:gsub("^%l", string.upper))
end

-- Who asked, in the game's words: "cook L1" -> "Dining Hall",
-- "builder: Residence" (materials for a build) -> "Build plan", "stock rule" -> "Keep"
function UI.prettyTarget(target)
    target = tostring(target or "")
    if target == "stock rule" then return "Keep" end
    if target:find("^builder:") then return "Build plan" end
    target = target:gsub("%s+L%d+$", "")
    if UI.HUT_NAMES[target:lower()] then return UI.HUT_NAMES[target:lower()] end
    return (target:gsub("^%l", string.upper))
end

local LEVEL = {ok = OK, warn = WARN, bad = BAD, off = MUTED}

-- ------------------------------------------------------------------- Home

-- The colony and one row per link, each with its own state.
function UI.homePage(state)
    local L = {}
    local col = state.colony or {}
    if col.name then
        row(L, {seg(fit(col.name, 34), ACCENT), seg(fit(string.format("%s citizens", tostring(col.citizens or "?")), 15, true), MUTED)})
        local hap = tonumber(col.happiness) or 0
        local hapColor = hap >= 7 and OK or (hap >= 4 and WARN or BAD)
        local a, b = bar(hap, 10, 20, hapColor)
        row(L, {seg(fit("Happiness", 18), MUTED), a, b, seg(string.format("  %.1f / 10", hap), TEXT)})
    else
        row(L, {seg(DOT .. " ", col.text and BAD or MUTED), seg(tostring(col.text or "Looking for the colony..."), col.text and BAD or MUTED)})
        blank(L)
    end
    blank(L)
    section(L, "Links")
    for _, link in ipairs(state.links or {}) do
        local color = LEVEL[link.level] or MUTED
        row(L, {seg(DOT .. " ", color), seg(fit(link.label, 16), TEXT), seg(tostring(link.value or ""), link.level == "ok" and MUTED or color)})
    end
    local errors = state.last and state.last.errors or {}
    if #errors > 0 then
        blank(L)
        for _, e in ipairs(errors) do row(L, {seg(DOT .. " ", BAD), seg(fit("Last scan", 16), TEXT), seg(tostring(e), BAD)}) end
    end
    return L
end

-- --------------------------------------------------------------- Requests

local REQUEST_STATE = {
    ordered = {"ordered", OK}, covered = {"ordered", OK}, waiting = {"waiting", MUTED}, queued = {"next", MUTED},
    missing = {"no stock", WARN}, crafting = {"craft asked", INFO}, skipped = {"skipped", MUTED}, error = {"error", BAD},
}

-- Open colony requests, grouped by the hut that asked.
function UI.requestsPage(state, context)
    local L = {}
    local nameW = widthOf(context) - 20
    local list = state.last and state.last.requests or {}
    if #list == 0 then
        line(L, MUTED, "Nothing open. The colony has all it asked for.")
        return L
    end
    local groups, order = {}, {}
    for _, req in ipairs(list) do
        local who = UI.prettyTarget(req.target)
        if not groups[who] then groups[who] = {} order[#order + 1] = who end
        table.insert(groups[who], req)
    end
    table.sort(order)
    for i, who in ipairs(order) do
        local reqs = groups[who]
        table.sort(reqs, function(a, b) return UI.pretty(a.name) < UI.pretty(b.name) end)
        if i > 1 then blank(L) end
        section(L, who, tostring(#reqs))
        for _, req in ipairs(reqs) do
            local st = REQUEST_STATE[req.status] or {tostring(req.status), MUTED}
            row(L, {seg(fit(UI.pretty(req.name), nameW), TEXT), seg(fit(tonumber(req.count) or 0, 5, true) .. "  ", MUTED),
                chip(st[1], st[2], 13)})
        end
    end
    return L
end

-- ------------------------------------------------------------------- Keep

-- What the colony keeps at least, with a bar each (no bar on a small monitor).
function UI.keepPage(state, context)
    local L = {}
    local width = widthOf(context)
    local narrow = width < NARROW
    local nameW = width - (narrow and 22 or 30)
    local stock = state.stock or {}
    local rules = state.rules or {}
    if state.keepOff then
        line(L, MUTED, state.keepOff)
        return L
    end
    if stock.error then line(L, BAD, "rules/keep.lua: " .. tostring(stock.error)) end
    if #rules == 0 then
        line(L, MUTED, "Nothing to keep. Give an item a min")
        line(L, MUTED, "in rules/keep.lua, e.g. min = 64.")
    end
    local ordered = {}
    for _, o in ipairs(state.openOrders or {}) do ordered[tostring(o.id)] = true end
    local crafting = state.craftingItems or {}
    local group = false
    for _, rule in ipairs(rules) do
        if rule.group ~= group then
            if group ~= false then blank(L) end
            group = rule.group
            section(L, group or "Keep")
        end
        local have = (stock.levels or {})[rule.item] or 0
        local word, color = "ok", OK
        if have < rule.min then
            if ordered["stock:" .. rule.item] then word, color = "on the way", INFO
            elseif crafting[rule.item] then word, color = "craft asked", BUSY
            else word, color = "short", WARN end
        end
        local segs = {seg(fit(UI.pretty(rule.name or rule.item), nameW), TEXT)}
        if not narrow then
            local a, b = bar(have, rule.min, 8, color)
            segs[#segs + 1], segs[#segs + 2] = a, b
        end
        segs[#segs + 1] = seg(fit(string.format("%d/%d", have, rule.min), 8, true) .. "  ", MUTED)
        segs[#segs + 1] = chip(word, color, 12)
        row(L, segs)
    end
    return L
end

-- ------------------------------------------------------------------- Send

local SEND_STATE = {ok = {"ok", OK}, sent = {"sent", INFO}, next = {"next", MUTED}, stuck = {"stuck", WARN},
    error = {"error", BAD}, ["not linked"] = {"not linked", WARN}, small = {"extra", MUTED}}
-- rows with something going on first; plain "ok" rows only as a count
local SEND_ORDER = {error = 1, stuck = 2, ["not linked"] = 3, next = 4, sent = 5, small = 6, ok = 7}

-- What goes to Create storage: how much the colony has, what stays, the state.
function UI.sendPage(state, context)
    local L = {}
    local send = state.send or {}
    if state.sendOff then
        line(L, MUTED, state.sendOff)
        return L
    end
    if send.error then line(L, BAD, tostring(send.error)) end
    local rows = send.rows or {}
    if #rows == 0 then
        if (send.rules or 0) == 0 then
            line(L, MUTED, "Nothing to send. Give an item a maks")
            line(L, MUTED, "in rules/keep.lua, e.g. maks = 256.")
        else
            line(L, MUTED, "No item with a max is in the colony now.")
        end
        return L
    end
    local now = clockOf(state, context)
    local width = widthOf(context)
    local narrow = width < NARROW
    local nameW = width - (narrow and 20 or 31)
    local shown, quiet = {}, 0
    for _, r in ipairs(rows) do
        if r.state == "ok" and not r.name then quiet = quiet + 1 else shown[#shown + 1] = r end
    end
    table.sort(shown, function(a, b)
        local oa, ob = SEND_ORDER[a.state] or 9, SEND_ORDER[b.state] or 9
        if oa ~= ob then return oa < ob end
        return UI.pretty(a.name or a.item) < UI.pretty(b.name or b.item)
    end)
    if #shown == 0 then line(L, OK, "Nothing extra: every item is within its max.") end
    for _, r in ipairs(shown) do
        local st = SEND_STATE[r.state] or {tostring(r.state or "-"), MUTED}
        local word = st[1]
        if r.state == "sent" and r.sentAt then word = "sent " .. Text.age(now - r.sentAt) end
        if r.state == "small" then word = "+" .. tostring(r.extra) .. " wait" end
        local segs = {seg(fit(UI.pretty(r.name or r.item), nameW), TEXT), seg(fit(r.have, 6, true), TEXT)}
        segs[#segs + 1] = seg(narrow and " " or fit(" max " .. r.max, 12), MUTED)
        segs[#segs + 1] = chip(word, st[2], 13)
        row(L, segs)
    end
    if quiet > 0 then
        blank(L)
        line(L, MUTED, string.format("%d more item%s within the max", quiet, quiet == 1 and "" or "s"))
    end
    return L
end

-- ------------------------------------------------------------------ Build

local STAGE = {
    CLEAR = "clearing", CLEAR_WATER = "clearing", CLEAR_NON_SOLIDS = "clearing", REMOVE_WATER = "clearing",
    BUILD_SOLID = "building", WEAK_SOLID = "building", DECORATE = "decorating", SPAWN = "finishing",
}

local function orderLevels(o)
    local from, to = tonumber(o.level) or 0, tonumber(o.targetLevel) or 0
    local kind = tostring(o.type or ""):lower()
    if kind == "build" or (from == 0 and to > 0) then return "new, level " .. to end
    if kind == "remove" then return "remove" end
    if kind == "repair" then return "repair" end
    return string.format("level %d -> %d", from, to)
end

local function samePos(a, b)
    return type(a) == "table" and type(b) == "table" and a.x == b.x and a.y == b.y and a.z == b.z
end

local function hutRows(L, state)
    local huts = state.buildings or {}
    local sorted = {}
    for _, b in ipairs(huts) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b)
        local na, nb = UI.hutName(a.type), UI.hutName(b.type)
        if na ~= nb then return na < nb end
        return (a.level or 0) > (b.level or 0)
    end)
    local built = 0
    for _, b in ipairs(sorted) do if b.built and (b.level or 0) > 0 then built = built + 1 end end
    section(L, "Huts", string.format("%d built of %d", built, #sorted))
    if #sorted == 0 then line(L, MUTED, "reading the huts...") end
    for _, b in ipairs(sorted) do
        local work, color
        for _, o in ipairs(state.queue or {}) do
            if samePos(o.pos, b.pos) then
                work, color = o.claimed and "building" or "queued", o.claimed and INFO or MUTED
                break
            end
        end
        local level, maxLevel = tonumber(b.level) or 0, tonumber(b.maxLevel) or 5
        local isBuilt = b.built and level > 0
        local segs = {seg(fit(UI.hutName(b.type), 18), isBuilt and TEXT or MUTED)}
        if not isBuilt then
            segs[#segs + 1] = seg(fit("not built", 15), MUTED)
            work, color = work or "placed", color or MUTED
        else
            -- pips take a fixed 9 cells (up to 5 levels) so the x/y column lines up
            local shown = math.min(maxLevel, 5)
            local a, z = pips(math.min(level, shown), shown, level >= maxLevel and OK or ACCENT)
            segs[#segs + 1] = a
            segs[#segs + 1] = z
            segs[#segs + 1] = seg(string.rep(" ", 9 - (2 * shown - 1)) .. fit(string.format(" %d/%d", level, maxLevel), 6), MUTED)
            if not work and level >= maxLevel then work, color = "max", OK end
        end
        segs[#segs + 1] = seg(fit((b.people or 0) > 0 and (b.people .. " ppl") or "", 7), MUTED)
        -- 10 cells: the row then ends exactly at the right edge of a 51-wide screen
        if work then segs[#segs + 1] = chip(work, color, 10) end
        row(L, segs)
    end
end

-- What the builders do now, what waits, and every hut.
function UI.buildPage(state)
    local L = {}
    local queue = state.queue or {}
    local materials = (state.builder or {}).materials or {}
    local working, waiting = {}, {}
    for _, o in ipairs(queue) do
        if o.claimed then working[#working + 1] = o else waiting[#waiting + 1] = o end
    end
    local builders = tonumber(state.builders)
    section(L, "Building now", builders and string.format("%d builder%s", builders, builders == 1 and "" or "s") or nil)
    if #working == 0 then
        line(L, #waiting > 0 and WARN or MUTED, #waiting > 0 and "no builder is working" or "nothing to build")
    end
    for _, o in ipairs(working) do
        row(L, {seg(fit(tostring(o.name), 20), TEXT), seg(fit(orderLevels(o), 17), MUTED),
            chip(STAGE[tostring(o.stage)] or tostring(o.stage or "started"):lower(), INFO, 12)})
        local m = materials[tostring(o.id)]
        if m and m.items > 0 then
            local ready = m.items - m.missing
            local a, b = bar(ready, m.items, 20, m.missing > 0 and WARN or OK)
            row(L, {seg(fit("materials", 12), MUTED), a, b, seg(string.format(" %d/%d ready", ready, m.items), TEXT)})
        end
    end
    if #waiting > 0 then
        blank(L)
        section(L, "Waiting", tostring(#waiting))
        for i, o in ipairs(waiting) do
            row(L, {seg(fit(i .. ".", 3, true) .. " ", MUTED), seg(fit(tostring(o.name), 20), TEXT), seg(orderLevels(o), MUTED)})
        end
    end
    blank(L)
    hutRows(L, state)
    return L
end

-- ------------------------------------------------------------------ Craft

local CRAFT_ANSWER = {accepted = {"accepted", OK}, refused = {"refused", WARN}, done = {"done", OK},
    ["no raw"] = {"no raw", WARN}}
-- never sent: how the item is made instead (Recipe Atlas)
local NOT_TURTLE = {machine = "machine", furnace = "furnace", colony = "colony hut", special = "special", none = "no recipe"}

-- What was asked of the craft controller (craft module only).
function UI.craftPage(state, context)
    local L = {}
    local rows = state.craftRows or {}
    if #rows == 0 then
        line(L, MUTED, "Nothing asked yet. What Create storage lacks")
        line(L, MUTED, "is asked here, once in 15 minutes per item.")
        return L
    end
    local now = clockOf(state, context)
    local width = widthOf(context)
    local narrow = width < NARROW
    local nameW = width - (narrow and 15 or 34)
    for _, r in ipairs(rows) do
        local answer = CRAFT_ANSWER[r.answer] or {"no answer", MUTED}
        if r.answer == "not turtle" then answer = {NOT_TURTLE[r.kind] or "not turtle", MUTED} end
        local segs = {seg(fit(UI.pretty(r.label or r.item), nameW), TEXT), seg(fit(r.count, 4, true) .. " ", MUTED)}
        if not narrow then
            segs[#segs + 1] = seg(fit(UI.prettyTarget(r.target), 13) .. " ", MUTED)
            segs[#segs + 1] = seg(fit(Text.age(now - (r.at or now)), 4, true) .. " ", MUTED)
        end
        segs[#segs + 1] = chip(answer[1], answer[2], 10)
        row(L, segs)
    end
    return L
end

-- -------------------------------------------------------------------- Log

local EVENT = {order = OK, delivered = TEXT, sent = INFO, craft = BUSY, problem = BAD, info = MUTED}

-- What happened lately, newest first.
function UI.logPage(state, context)
    local L = {}
    local events = state.events or {}
    if #events == 0 then
        line(L, MUTED, "Nothing yet.")
        return L
    end
    local now = clockOf(state, context)
    for _, e in ipairs(events) do
        row(L, {seg(fit(Text.age(now - (e.at or now)), 4, true) .. " ", MUTED), seg(DOT .. " ", EVENT[e.kind] or MUTED),
            seg(tostring(e.text), e.kind == "problem" and BAD or TEXT)})
    end
    return L
end

-- The tab list for UI.App.new{pages = ...}; App calls page(state, context).
-- `craft` adds the Craft tab (the module is installed and on).
function UI.pages(craft)
    local list = {
        {name = "Home", page = UI.homePage},
        {name = "Requests", page = UI.requestsPage},
        {name = "Keep", page = UI.keepPage},
        {name = "Send", page = UI.sendPage},
        {name = "Build", page = UI.buildPage},
    }
    if craft then list[#list + 1] = {name = "Craft", page = UI.craftPage} end
    list[#list + 1] = {name = "Log", page = UI.logPage}
    return list
end

return UI
