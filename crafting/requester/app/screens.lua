-- PC46 screens on the shared CC UI kit (`require("ui")`, shipped in the
-- Tensa Aeronautics ROM), in the fleet's screen style (docs/screen-style.md,
-- after PC107): summary lines first, then lists as rows (name, bar, x/y and
-- a lowercase state word), grouped by sections, a shared cause said once.
-- The kit's App owns the terminal and the wall monitor: tabs, footer,
-- scrolling, palette, touch and keys; the monitor follows the terminal's
-- tab. S.model turns the controller's snapshot into records; the pages only
-- lay them out (no peripherals, no business changes) and the controller
-- acts on the kit's actions.
local Bus = require("app.bus")
local Sections = require("app.sections")
local UI = require("ui")
local Rows, Layout, Controls, Render, Text = UI.Rows, UI.Layout, UI.Controls, UI.Render, UI.Text
local Toasts, Modal = UI.Feedback.Toasts, UI.Feedback.Modal

local S = {}

local DOT = string.char(7)

-- The rule tabs: All, then one per rule file (app.sections): kit tab
-- name, the rows' section key, the section title.
local SECTIONS = {{name = "All", key = "all", title = "All rules"}}
for _, def in ipairs(Sections.ordered("tabOrder")) do
    SECTIONS[#SECTIONS + 1] = {name = def.tab, key = def.key, title = def.title}
end
-- The groups of the All tab, in order (overflow rules are not on All).
local ALL_GROUPS = Sections.ordered("allOrder")
S.CLEANING, S.WAITING = "Cleaning", "Waiting"

-- Labels -------------------------------------------------------------------------

-- Common tags stand for one item ("#c:ingots/iron" is iron ingot).
local function canonicalTag(text)
    local path = text:gsub("^#", ""):lower()
    path = path:match("^[^:]+:(.+)$") or path
    local dust = path:match("^dusts/(.+)$")
    if dust then return dust == "redstone" and "minecraft:redstone" or (dust .. "_dust") end
    local plate = path:match("^plates/(.+)$") or path:match("^sheets/(.+)$")
    if plate then return "create:" .. (plate == "gold" and "golden" or plate) .. "_sheet" end
    local ingot = path:match("^ingots/(.+)$")
    if ingot then return "minecraft:" .. ingot .. "_ingot" end
    local nugget = path:match("^nuggets/(.+)$")
    if nugget then return "minecraft:" .. nugget .. "_nugget" end
    return nil
end

-- "minecraft:stripped_oak_log" -> "Stripped oak log".
function S.label(id)
    local text = tostring(id or "-")
    return Text.pretty((canonicalTag(text) or text:gsub("^#", "")))
end

-- Item ids inside a reason ("missing minecraft:iron_ingot 3/9") read as labels.
function S.reason(text)
    text = tostring(text or "")
    text = text:gsub("#[%w_%.%-:/]+", S.label)
    text = text:gsub("[%w_%.%-]+:[%w_%.%-/]+", S.label)
    return text
end

local function nonEmpty(value)
    if value ~= nil and value ~= "" then return value end
    return nil
end

-- "300" -> "5 min", "3600" -> "1 h".
local function duration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds >= 3600 and seconds % 3600 == 0 then return (seconds / 3600) .. " h" end
    if seconds >= 60 then return math.floor(seconds / 60 + 0.5) .. " min" end
    return seconds .. " s"
end

-- Model --------------------------------------------------------------------------

-- The tab of a row: its section, a station rule its station's.
local function rowSection(row)
    local resource = row.resource or {}
    local section = resource.station or row.section or resource.section
    return Sections.get(section) and section or "request"
end

-- A rule's state as the row's word and colour (style: green fine, yellow
-- short or waiting, blue on the way, purple working, red error, grey idle).
local function ruleWord(kind, row)
    local status = tostring(row.status or "?")
    if status == "OK" then
        if kind == "export" then return "empty", "muted" end
        return kind == "overflow" and "kept" or "ok", "ok"
    end
    if status == "LOW" then
        if kind == "export" then return "to send", "info" end
        if kind == "overflow" then return "too much", "warn" end
        return "low", "warn"
    end
    if status == "NEEDS" then return "no material", "warn" end
    if status == "NO_STOCK" then return "no input", "warn" end
    if status == "QUEUE" then return "queued", "info" end
    if status == "REQUESTED" then return "ordered", "info" end
    if status == "WAIT" then
        if tostring(row.reason) == "craft in progress" then return "crafting", "busy" end
        return "cooldown", "muted"
    end
    if status == "OFF" then return "off", "muted" end
    return status:lower(), "bad"
end

-- One rule row. Exports have no limit and are named by their rule.
local function ruleRecord(row)
    local kind = rowSection(row)
    local resource = row.resource or {}
    local word, tone = ruleWord(kind, row)
    local record = {
        id = row.key, kind = kind, word = word, tone = tone,
        name = S.label(nonEmpty(row.check) or row.key),
        count = tonumber(row.count) or 0, limit = tonumber(row.limit) or 0,
        cooldownEndsAt = tostring(row.status) == "WAIT" and tonumber(row.cooldownEndsAt) or nil,
        needs = tostring(row.status) == "NEEDS" and row.needs or nil,
    }
    if kind == "export" then
        record.limit = nil
        record.note = "to " .. tostring(resource.address or "-")
    elseif record.needs then
        record.note = S.label(record.needs.raw)
    elseif row.status == "NO_STOCK" or row.status == "ERROR" then
        record.note = S.reason(row.reason)
    end
    return record
end

-- NEEDS rules grouped by the missing material: how much, how many rules
-- wait for it and where it is made (said once, not on every row).
local function waiting(records)
    local list, byRaw = {}, {}
    for _, record in ipairs(records) do
        local needs = record.needs
        if needs and needs.raw then
            local entry = byRaw[needs.raw]
            if not entry then
                entry = {raw = needs.raw, label = S.label(needs.raw), needed = 0, rules = 0}
                byRaw[needs.raw] = entry
                list[#list + 1] = entry
            end
            entry.needed = entry.needed + (tonumber(needs.needed) or 0)
            entry.rules = entry.rules + 1
            entry.hint = entry.hint or (needs.hint and S.reason(needs.hint))
        end
    end
    table.sort(list, function(a, b)
        if a.rules ~= b.rules then return a.rules > b.rules end
        return a.raw < b.raw
    end)
    return list
end

local function summary(records)
    local counts = {total = #records, ok = 0, low = 0, waiting = 0, problems = 0}
    for _, record in ipairs(records) do
        if record.tone == "ok" or record.word == "empty" then counts.ok = counts.ok + 1 end
        if record.word == "low" or record.word == "no input" or record.word == "too much" then counts.low = counts.low + 1 end
        if record.word == "no material" then counts.waiting = counts.waiting + 1 end
        if record.tone == "bad" then counts.problems = counts.problems + 1 end
    end
    return counts
end

local function ruleModel(rows)
    local sections = {}
    for _, def in ipairs(SECTIONS) do sections[def.key] = {records = {}} end
    for _, row in ipairs(rows or {}) do
        local record = ruleRecord(row)
        table.insert(sections[record.kind].records, record)
        if Sections.get(record.kind).allOrder then table.insert(sections.all.records, record) end
    end
    for _, def in ipairs(SECTIONS) do
        local data = sections[def.key]
        data.summary = summary(data.records)
        data.waiting = waiting(data.records)
    end
    return sections
end

local function cleaningModel(c)
    c = c or {}
    local records = {}
    for index, row in ipairs(c.rows or {}) do
        records[index] = {name = tostring(row.label or "-"), count = tonumber(row.count) or 0, used = tonumber(row.used) or 0}
    end
    return {
        records = records, address = tostring(c.address or ""), addressKey = tostring(c.addressKey or ""),
        kind = c.kind, kindLabel = tostring(c.kindLabel or "Items"), button = tostring(c.button or "SEND"),
        kinds = c.kinds or {}, total = tonumber(c.total) or 0, used = tonumber(c.used) or 0,
        loaded = c.loaded == true, busy = c.busy == true,
        sending = c.sending == true, canSend = c.canSend == true, error = c.error, message = c.message,
    }
end

-- snapshot: Controller:screenSnapshot().
function S.model(snapshot)
    local stock = snapshot.stock or {}
    return {
        rules = ruleModel(snapshot.rows),
        cleaning = cleaningModel(snapshot.cleaning),
        pause = {seconds = tonumber(snapshot.pauseSeconds) or 3600, retry = tonumber(snapshot.retrySeconds) or 300},
        stock = {ok = stock.ok ~= false, used = tonumber(stock.used) or 0, sources = #(stock.sources or {}),
            error = stock.error},
        devices = snapshot.devices or {},
        queueCount = tonumber(snapshot.queueCount) or 0,
        controller = snapshot.controller or {},
        lastAction = snapshot.lastAction,
        lastError = snapshot.lastError,
        toasts = snapshot.toasts or {},
        confirms = snapshot.confirms or {},
        computerId = snapshot.computerId,
        version = snapshot.version,
        updatedAt = snapshot.updatedAt,
        interval = snapshot.interval,
    }
end

-- Rows ---------------------------------------------------------------------------

local function seg(text, fg) return Rows.segment(tostring(text), fg) end
local function status(label, value, color, t) return Rows.status(label, tostring(value), color, t) end
local function section(title, note, t)
    local row = Rows.section(title, note ~= nil and tostring(note) or nil, t)
    if row.right then row.right.inset = 1 end
    return row
end
local BLANK = {segs = {}}

-- Column widths of a list row: wall monitor or computer terminal.
local function columns(width)
    if width >= 70 then return {name = 30, bar = 16, numbers = 11, chip = 14, note = true} end
    return {name = 20, bar = 6, numbers = 9, chip = 12}
end

-- name, bar, x/y, word: one thing per row (the PC107 stock row).
local function listRow(c, t, name, value, max, numbers, word, tone, note)
    local color = t[tone] or t.muted
    local segs = {seg(Text.fit(name, c.name), t.text)}
    if max and max > 0 then
        local lit, dim = Rows.bar(value, max, c.bar, color, t)
        segs[#segs + 1] = lit
        segs[#segs + 1] = dim
    else
        segs[#segs + 1] = seg(string.rep(" ", c.bar), t.text)
    end
    segs[#segs + 1] = seg(Text.fit(numbers, c.numbers, true) .. "  ", t.muted)
    segs[#segs + 1] = Rows.chip(word, color, c.chip)
    if c.note and note then segs[#segs + 1] = seg(note, t.muted) end
    return {segs = segs}
end

local function ruleRow(r, c, t, now)
    local note = r.note
    if r.cooldownEndsAt then note = "next in " .. math.max(0, math.ceil(r.cooldownEndsAt - now)) .. "s" end
    local numbers = r.limit and (r.count .. "/" .. r.limit) or tostring(r.count)
    return listRow(c, t, r.name, r.count, r.limit, numbers, r.word, r.tone, note)
end

-- "Waiting for material": per material, how much, for how many rules and
-- where it is made; then what the pause means. Wide screens use one line
-- per material, the terminal two.
local function waitingRows(list, entries, t, wide, unit, pause)
    if #entries == 0 then return end
    local rules = 0
    for _, e in ipairs(entries) do rules = rules + (e.rules or 0) end
    list[#list + 1] = section("Waiting for material", ("%d material%s, %d %s"):format(#entries,
        #entries == 1 and "" or "s", rules, rules == 1 and unit:gsub("s$", "") or unit), t)
    for _, e in ipairs(entries) do
        local how = e.hint and ("made at " .. e.hint) or "no recipe here: gather it"
        local howColor = e.hint and t.info or t.muted
        local count = ("%d missing"):format(e.needed)
        local who = ("for %d %s"):format(e.rules or 0, (e.rules or 0) == 1 and unit:gsub("s$", "") or unit)
        if wide then
            list[#list + 1] = {segs = {seg(DOT .. " ", t.warn), seg(Text.fit(e.label, 24), t.text),
                seg(Text.fit(count, 13), t.text), seg(Text.fit(who, 14), t.muted), seg(how, howColor)}}
        else
            list[#list + 1] = {segs = {seg(DOT .. " ", t.warn), seg(Text.fit(e.label, 22), t.text),
                seg(Text.fit(count, 12), t.text), seg(who, t.muted)}}
            list[#list + 1] = {segs = {seg("  " .. how, howColor)}}
        end
    end
    list[#list + 1] = {segs = {seg(pause, t.muted)}}
end

-- Pages --------------------------------------------------------------------------

local function ruleCounts(s, wide)
    local parts = {("%d rules"):format(s.total)}
    if s.ok > 0 then parts[#parts + 1] = s.ok .. " ok" end
    if s.low > 0 then parts[#parts + 1] = s.low .. " low" end
    if s.waiting > 0 then parts[#parts + 1] = s.waiting .. (wide and " waiting for material" or " waiting") end
    if s.problems > 0 then parts[#parts + 1] = s.problems .. " errors" end
    return table.concat(parts, ", "), (s.problems > 0 and "bad") or ((s.low + s.waiting) > 0 and "warn") or "ok"
end

local function pauseText(m, wide)
    if wide then
        return ("These rules pause until the warehouse has it (at most %s) instead of retrying every %s.")
            :format(duration(m.pause.seconds), duration(m.pause.retry))
    end
    return ("Paused until stocked (max %s), not every %s"):format(duration(m.pause.seconds), duration(m.pause.retry))
end

-- The rule tabs (All and one per rule file): a summary, then the rules,
-- grouped by file on All. The kit scrolls the list (virtual rows).
local function rulesPage(def)
    return function(m, context)
        local t, now = context.theme, context.now or 0
        local width = context.rowRect.width
        local wide = width >= 70
        local c = columns(width)
        local data = m.rules[def.key]
        local head = {}
        local text, tone = ruleCounts(data.summary, wide)
        head[#head + 1] = status("Rules", text, t[tone], t)
        if def.key == "all" then
            head[#head + 1] = status("Queue", m.queueCount > 0 and (m.queueCount .. " batches waiting") or "nothing queued",
                m.queueCount > 0 and t.info or t.ok, t)
            if m.lastError then head[#head + 1] = status("Error", S.reason(m.lastError), t.bad, t) end
        end
        -- The list, by kind on All; one section elsewhere. What rules wait
        -- for is on the Waiting tab (owner 2026-10-27), not repeated here.
        local groups = {}
        if def.key == "all" then
            local byKind = {}
            for _, r in ipairs(data.records) do
                byKind[r.kind] = byKind[r.kind] or {}
                table.insert(byKind[r.kind], r)
            end
            for _, group in ipairs(ALL_GROUPS) do
                if byKind[group.key] then
                    groups[#groups + 1] = {title = group.title, records = byKind[group.key]}
                end
            end
        elseif #data.records > 0 then
            groups[1] = {title = def.title, records = data.records}
        end
        local entries = {}
        for _, row in ipairs(head) do entries[#entries + 1] = {row = row} end
        for _, group in ipairs(groups) do
            entries[#entries + 1] = {row = BLANK}
            entries[#entries + 1] = {row = section(group.title, tostring(#group.records), t)}
            for _, r in ipairs(group.records) do entries[#entries + 1] = {rule = r} end
        end
        if #groups == 0 then
            entries[#entries + 1] = {row = BLANK}
            entries[#entries + 1] = {row = {segs = {seg("No rules here. Rules live in 46/requests/*.lua", t.muted)}}}
        end
        return {count = #entries, row = function(index)
            local entry = entries[index]
            return entry.row or ruleRow(entry.rule, c, t, now)
        end}
    end
end

-- Waiting (the first tab, 2026-10-27): the materials rules wait for, then
-- those rules.
local function waitingPage(m, context)
    local t, now = context.theme, context.now or 0
    local wide = context.rowRect.width >= 70
    local c = columns(context.rowRect.width)
    local data = m.rules.all
    local head = {}
    local waitingRecords = {}
    for _, r in ipairs(data.records) do
        if r.needs then waitingRecords[#waitingRecords + 1] = r end
    end
    if #data.waiting == 0 then
        head[#head + 1] = status("Waiting", "nothing waits for material", t.ok, t)
    else
        waitingRows(head, data.waiting, t, wide, "rules", pauseText(m, wide))
        head[#head + 1] = BLANK
        head[#head + 1] = section("Rules waiting", tostring(#waitingRecords), t)
    end
    return {count = #head + #waitingRecords, row = function(index)
        if index <= #head then return head[index] end
        return ruleRow(waitingRecords[index - #head], c, t, now)
    end}
end

-- Info: what PC46 is connected to and what it did last.
local function infoPage(m, context)
    local t = context.theme
    local d, ctl, stock = m.devices, m.controller, m.stock
    local L = {section(("Warehouse requester #%s"):format(tostring(m.computerId or "?")), m.version, t)}
    if stock.ok then
        L[#L + 1] = status("Stock", ("%d items in %d sources"):format(stock.used, stock.sources), t.ok, t)
    else
        L[#L + 1] = status("Stock", "unreadable: " .. S.reason(stock.error or "no stock source"), t.bad, t)
    end
    local ticker = (Bus.ticker(d) or {}).name
    L[#L + 1] = status("Ticker", ticker or "none", ticker and t.ok or t.muted, t)
    local monitors = ctl.monitors or {}
    L[#L + 1] = status("Monitors", #monitors > 0 and table.concat(monitors, ", ") or "none", #monitors > 0 and t.ok or t.muted, t)
    if ctl.id then
        L[#L + 1] = status("PC48", ("PC%s, %d open requests"):format(tostring(ctl.id), ctl.open or 0), t.ok, t)
    else
        L[#L + 1] = status("PC48", "not found yet: " .. tostring(ctl.hostname or "craft-controller"), t.warn, t)
    end
    L[#L + 1] = status("Queue", ("%d batches waiting"):format(m.queueCount), m.queueCount > 0 and t.info or t.ok, t)
    L[#L + 1] = BLANK
    L[#L + 1] = status("Activity", S.reason(m.lastAction or "waiting"), t.muted, t)
    L[#L + 1] = status("Error", m.lastError and S.reason(m.lastError) or "none", m.lastError and t.bad or t.ok, t)
    return L
end

-- Pages with buttons (Cleaning) --------------------------------------------------

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- A page under construction: rows (the kit draws them) and the widgets
-- placed on rows kept free for them (a control is two rows: the focus line).
local function page(model, context, name)
    return {m = model, c = context, t = context.theme, rows = {}, views = {}, name = name}
end
local function add(p, row) p.rows[#p.rows + 1] = row; return #p.rows end
local function blank(p) return add(p, {segs = {}}) end
local function y_of(p, index) return p.c.rowRect.y + index - 1 end
local function left(p) return p.c.rect.height - #p.rows end
local function wide(p) return p.c.rect.width >= 70 end

local function buttonAt(c, id, label, color, disabled, x, y)
    local cc = copy(c)
    cc.theme = copy(c.theme); cc.theme.accent = color or c.theme.accent
    return Layout.widget(Controls.button, {id = id, label = label, disabled = disabled},
        {x = x, y = y, width = #label + 4, height = 2}, cc)
end

-- The page's buttons {id, label, color, disabled} on the next two free rows.
local function buttons(p, list)
    local i = blank(p); blank(p)
    local x, right = p.c.rect.x, p.c.rect.x + p.c.rect.width - 1
    for _, b in ipairs(list) do
        if x + #b.label + 4 - 1 > right then break end
        p.views[#p.views + 1] = buttonAt(p.c, b.id, b.label, b.color, b.disabled, x, y_of(p, i))
        x = x + #b.label + 4 + 2
    end
end

-- Results of the last actions (kit toasts) on the rows above the buttons.
local function toasts(p, above)
    local count = wide(p) and 3 or 1
    local r = p.c.rect
    p.views[#p.views + 1] = Toasts.layout({maxCount = count}, p.m.toasts,
        {x = r.x, y = r.y + r.height - (above or 0) - count, width = r.width, height = count}, p.t, p.c)
end

-- This screen's question (each screen asks on its own), on the tab it was
-- asked from; a fresh id per question, so an old answer never closes a new one.
local function question(p)
    local q = p.m.confirms[p.c.screenId]
    if not q or (q.page and q.page ~= p.name) then return end
    local r = p.c.rect
    local props = {id = "q" .. tostring(q.seq), open = true, kind = q.kind or "confirm",
        title = q.title, message = q.message, submitLabel = q.submitLabel, cancelLabel = "Cancel",
        width = math.min(46, r.width)}
    p.views[#p.views + 1] = Layout.widget(Modal, props, r, p.c)
end

local function finish(p, barRows)
    toasts(p, barRows)
    question(p)
    local all = {Rows.layout(p.rows, p.c.rowRect, p.t)}
    for _, v in ipairs(p.views) do all[#all + 1] = v end
    return Render.compose(all, p.c.rect, p.c.bodyRect)
end

-- Cleaning: used items of one kind (configured filters, opened backpacks) go
-- to the station that resets them. The buttons on top switch the kind; the
-- bottom button sends every used one. Clean ones stay.
local function cleaningPage(m, context)
    local p = page(m, context, S.CLEANING)
    local t = p.t
    local c = m.cleaning
    local kinds = {}
    for _, kind in ipairs(c.kinds) do
        local current = kind.key == c.kind
        kinds[#kinds + 1] = {id = "cleaning_kind:" .. kind.key, label = kind.label:upper(),
            color = current and t.ok or t.muted, disabled = c.sending and not current}
    end
    buttons(p, kinds)
    if c.address == "" then
        add(p, status("Send to", "off: set " .. c.addressKey .. " in 46/config.lua", t.muted, t))
        return finish(p, 0)
    end
    add(p, status("Send to", c.address, t.ok, t))
    if c.error then add(p, status("Problem", S.reason(c.error), t.bad, t))
    elseif c.sending then add(p, status("Sending", S.reason(c.message or "preparing"):lower(), t.busy, t))
    elseif c.busy then add(p, status("Working", "reading the stock", t.busy, t))
    elseif c.message then add(p, status("Last", S.reason(c.message):lower(), t.info, t))
    end
    blank(p)
    add(p, section(c.kindLabel, c.loaded and (c.used .. " to send of " .. c.total) or "reading stock", t))
    local col = columns(p.c.rowRect.width)
    for _, r in ipairs(c.records) do
        add(p, {segs = {seg(Text.fit(r.name, col.name), t.text),
            seg(Text.fit(r.used .. " to send", 12, true), r.used > 0 and t.warn or t.muted),
            seg(Text.fit(r.count .. " total", 11, true), t.muted)}})
    end
    while left(p) > 2 do blank(p) end
    buttons(p, {{id = "clean_send", label = c.button, color = t.ok, disabled = not c.canSend}})
    return finish(p, 2)
end

function S.pages()
    local pages = {{name = S.WAITING, page = waitingPage}}
    for _, def in ipairs(SECTIONS) do pages[#pages + 1] = {name = def.name, page = rulesPage(def)} end
    pages[#pages + 1] = {name = S.CLEANING, page = cleaningPage}
    pages[#pages + 1] = {name = "Info", page = infoPage}
    return pages
end

-- Helpers for the controller -------------------------------------------------------

-- Monitor IDs attached to the App (every screen but the terminal).
function S.monitors(app)
    local names = {}
    for id in pairs(app and app.screens or {}) do
        if id ~= "terminal" then names[#names + 1] = tostring(id) end
    end
    table.sort(names)
    return names
end

-- The tab names some healthy screen shows right now.
function S.shown(app)
    local shown = {}
    for _, id in ipairs(app and app.order or {}) do
        local s = app.screens[id]
        if s and not s.error and s.active then shown[s.active] = true end
    end
    return shown
end

-- A touch or click is not keyboard focus: no focus line stays under what
-- was pressed (as on PC66 and PC48). An open question keeps its focus.
function S.unfocus(app, screenId)
    local s = app.screens[screenId]
    local p = s and s.pages[s.active]
    if p and p.focus and not p.focus.modalId then p.focus.focusedId = nil end
end

return S
