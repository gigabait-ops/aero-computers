-- PC66 screens on the shared CC UI kit (`require("ui")`, shipped in the
-- Tensa Aeronautics ROM). The kit's App owns the terminal and the monitor:
-- tabs, footer, palette, touch and keys; the monitor follows the terminal's
-- tab. S.model turns app.lua's snapshot into the records the pages draw;
-- the pages only lay them out (no peripherals, no business changes) and
-- app.lua acts on the kit's actions.
--
-- Design (docs/screen-style.md, PC107's look): status lines first, then
-- sections of one row per thing: a pretty name, muted numbers, a bar where
-- there is progress, and a dot with a lowercase state word. A missing raw
-- material is explained once, in "Needs material". Rows of slots, of
-- history and of the checklist are touchable; there is no paging in the
-- body (History and Checklist page with the kit's footer pager).
-- Three tabs (owner 2026-11-08): Craft, History, Checklist.
local UI = require("ui")
local Util = require("app.util")
local Rows, Layout, Controls, Render, Text = UI.Rows, UI.Layout, UI.Controls, UI.Render, UI.Text
local Toasts, Modal = UI.Feedback.Toasts, UI.Feedback.Modal

local S = {}

local DOT = string.char(7)

-- Request states -> the word shown and its colour (docs/screen-style.md:
-- ok fine, info on the way, busy crafting, warn waiting or short, bad error).
local WORDS = {
    READY = {"ready", "ok"}, DONE = {"done", "ok"}, COMPLETED = {"done", "ok"},
    PENDING = {"sending", "info"}, SENDING = {"sending", "info"},
    QUEUED = {"queued", "info"}, ACCEPTED = {"queued", "info"},
    ASSIGNED = {"crafting", "busy"}, STALLED = {"stalled", "warn"}, NEEDS = {"needs", "warn"},
    EMPTY = {"empty", "muted"},
}
function S.word(state)
    local known = WORDS[state]
    if known then return known[1], known[2] end
    return tostring(state or "?"):lower(), "bad"
end

-- An item's name as the player knows it.
local function pretty(item)
    local name = item.displayName
    if type(name) == "string" and name ~= "" then return name end
    return Text.pretty(item.name or "?")
end

-- How a missing raw is made: a station (PC46 rule or route map, capitalised),
-- else the kind of route ("machine SPOUT"), else nothing can make it.
function S.howMade(hint)
    if not hint then return "not craftable: gather it", "warn" end
    if hint:match("^%l") then return "made by " .. hint, "info" end
    return "made at " .. hint, "info"
end

-- Model --------------------------------------------------------------------------

local function slotRecords(drafts)
    local records, ready = {}, 0
    for slot = 1, 9 do
        local draft = drafts[tostring(slot)]
        if draft then
            local state = draft.jobId and tostring(draft.jobState or "PENDING") or "READY"
            if state == "READY" then ready = ready + 1 end
            records[slot] = {slot = slot, name = pretty(draft), count = draft.quantity, state = state}
        else
            records[slot] = {slot = slot, state = "EMPTY", empty = true}
        end
    end
    return records, ready
end

-- History rows (newest first) and, once per raw, what the requests whose
-- newest attempt ended in NEEDS are missing.
local function historyRecords(history, hints, now)
    local records, needs, seenTarget, seenRaw = {}, {}, {}, {}
    for index, job in ipairs(history) do
        local state = tostring(job.state or "?")
        local shortage = Util.rawShortage(job, hints)
        if shortage then state = "NEEDS" end
        local name = pretty({displayName = job.displayName, name = job.target})
        local target = tostring(job.target or "")
        if shortage and not seenTarget[target] then
            local need = seenRaw[shortage.raw]
            if need then
                need.requests = need.requests + 1
            else
                local how, tone = S.howMade(shortage.hint)
                need = {raw = Text.pretty(shortage.raw), needed = shortage.needed, forName = name,
                    how = how, tone = tone, requests = 1}
                seenRaw[shortage.raw] = need
                needs[#needs + 1] = need
            end
        end
        seenTarget[target] = true
        local finished = tonumber(job.finishedAt)
        records[index] = {id = tostring(job.id or index), name = name, count = tonumber(job.count) or 0,
            state = state, ago = finished and Text.age(now - finished) or ""}
    end
    return records, needs
end

-- Item ids inside a reason ("needs minecraft:iron_ingot x3") read as names.
local function reason(text)
    return (tostring(text or ""):gsub("[%w_%.%-]+:[%w_%.%-/]+", function(id) return Text.pretty(id) end))
end

-- A checklist row's state as a word and a colour.
local CHECK_WORDS = {
    READY = {"ready", "ok"}, DONE = {"done", "ok"}, SENT = {"sent", "ok"},
    PARTIAL = {"partly", "warn"}, MISSING = {"missing", "warn"}, NEEDS = {"no material", "warn"},
    NO_RECIPE = {"no recipe", "warn"}, QUEUE = {"queued", "info"}, REQUESTED = {"requested", "info"},
    DELIVERY = {"delivering", "info"}, WAITING = {"crafting", "busy"}, CRAFTING = {"crafting", "busy"},
    CHECKING = {"checking", "muted"}, STACK_INFO = {"stack info", "muted"},
}

-- checklist: app.checklist_runner's snapshot.
local function checklistModel(checklist)
    checklist = checklist or {}
    local records, toSend, toCraft = {}, 0, 0
    for index, row in ipairs(checklist.rows or {}) do
        local state = tostring(row.state or "-")
        local word = CHECK_WORDS[state] or {state:lower():gsub("_", " "), "bad"}
        local needed, remaining = tonumber(row.needed) or 0, tonumber(row.remaining) or 0
        records[index] = {
            key = row.name, name = pretty(row), needed = needed, done = math.max(0, needed - remaining),
            stock = tonumber(row.stock) or 0, word = word[1], tone = word[2],
            note = row.needs and Text.pretty(row.needs)
                or ((state == "ERROR" or state == "CHECK_ERROR") and reason(row.note) or nil),
        }
        if row.canSend then toSend = toSend + 1 end
        if row.canCraft then toCraft = toCraft + 1 end
    end
    local needs = {}
    for index, need in ipairs(checklist.needs or {}) do
        local rows = 0
        for _, row in ipairs(checklist.rows or {}) do if row.needs == need.name then rows = rows + 1 end end
        local how, tone = S.howMade(need.hint)
        needs[index] = {raw = Text.pretty(need.name), needed = tonumber(need.count) or 0, rows = rows, how = how, tone = tone}
    end
    return {
        enabled = checklist.enabled ~= false, visible = checklist.visible == true,
        clipboard = checklist.clipboard, ticker = checklist.ticker, stockError = checklist.stockError,
        records = records, count = #records, needs = needs,
        address = tostring(checklist.address or ""), toSend = toSend, toCraft = toCraft,
        checking = tonumber(checklist.checkingCount) or 0,
        error = checklist.error, recipeError = checklist.recipeError,
        sendEnabled = checklist.sendEnabled == true, craftEnabled = checklist.craftEnabled == true,
        craftSendEnabled = checklist.craftSendEnabled == true,
    }
end

-- snapshot: app.lua's business view.
function S.model(snapshot)
    local now = snapshot.now or 0
    local slots, ready = slotRecords(snapshot.drafts or {})
    local history, needs = historyRecords(snapshot.history or {}, snapshot.hints, now)
    return {
        slots = slots,
        history = history,
        needs = needs,
        checklist = checklistModel(snapshot.checklist),
        selectedCount = snapshot.selectedCount or 0,
        readyCount = ready,
        controller = snapshot.controller or {},
        problem = snapshot.problem,
        toasts = snapshot.toasts or {},
        confirms = snapshot.confirms or {},
        computerId = snapshot.computerId,
        version = snapshot.version,
        updatedAt = snapshot.updatedAt,
        interval = snapshot.interval,
    }
end

-- Pages --------------------------------------------------------------------------

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function seg(text, fg) return Rows.segment(tostring(text), fg) end
local function fit(text, width, right) return Text.fit(text, width, right) end

-- Touch on whole rows: the kit's Rows draw them, this adds one hit per row
-- (part = the row's key); a touch or click emits change with that key.
local Touch = {}

function Touch.layout(props, _, rect)
    local view = {ops = {}, hits = {}, focusables = {}, bindings = {}}
    for index, key in ipairs(props.keys or {}) do
        if index <= rect.height then
            view.hits[#view.hits + 1] = {id = props.id, part = key,
                rect = {x = rect.x, y = rect.y + index - 1, width = rect.width, height = 1}}
        end
    end
    if #view.hits > 0 then view.bindings[props.id] = {widget = Touch, props = props} end
    return view
end

function Touch.handle(props, state, event)
    local touched = event.type == "mouse_click" or event.type == "monitor_touch" or event.type == "click"
    if touched and event.part ~= nil then return state, {{type = "change", id = props.id, value = event.part}} end
    return state, {}
end

-- A page under construction: rows (the kit draws them) and the widgets
-- placed on rows kept free for them (a control is two rows: the focus line).
local function page(model, context)
    return {m = model, c = context, t = context.theme, rows = {}, views = {}}
end
local function add(p, row) p.rows[#p.rows + 1] = row; return #p.rows end
local function blank(p) return add(p, {segs = {}}) end
local function y_of(p, index) return p.c.rowRect.y + index - 1 end
local function left(p) return p.c.rect.height - #p.rows end
local function wide(p) return p.c.rect.width >= 70 end
-- Text width of a row (Rows keep one left cell free).
local function width(p) return p.c.rowRect.width - 1 end

local function sectionRow(p, title, note)
    local row = Rows.section(title, note, p.t)
    return row
end
local function section(p, title, note) return add(p, sectionRow(p, title, note)) end

-- A status line as Rows.status draws it (dot, muted label, value), with
-- room for the longer labels ("Controller", "Last error").
local function status(p, label, value, tone)
    add(p, {segs = {seg(DOT .. " ", p.t[tone]), seg(fit(label, 12), p.t.muted), seg(value, p.t.text)}})
end

local function muted(p, text) add(p, {segs = {seg(text, p.t.muted)}}) end

local function chip(p, state)
    local word, tone = S.word(state)
    return Rows.chip(word, p.t[tone], 11)
end

-- Touchable rows {key, segs}.
local function touchRows(p, id, list)
    local first = #p.rows + 1
    local keys = {}
    for index, row in ipairs(list) do
        add(p, {segs = row.segs})
        keys[index] = row.key
    end
    p.views[#p.views + 1] = Layout.widget(Touch, {id = id, keys = keys},
        {x = p.c.rect.x, y = y_of(p, first), width = p.c.rect.width, height = #list}, p.c)
end

-- A button at x, y with its own accent (a copied theme).
local function buttonAt(c, id, label, color, disabled, x, y)
    local cc = copy(c)
    cc.theme = copy(c.theme); cc.theme.accent = color or c.theme.accent
    return Layout.widget(Controls.button, {id = id, label = label, disabled = disabled},
        {x = x, y = y, width = #label + 4, height = 2}, cc)
end

-- Buttons {id, label, color, disabled} side by side on two fresh rows.
local function buttons(p, list)
    local i = blank(p); blank(p)
    local x, right = p.c.rect.x, p.c.rect.x + p.c.rect.width - 1
    for _, b in ipairs(list) do
        if x + #b.label + 4 - 1 > right then break end
        p.views[#p.views + 1] = buttonAt(p.c, b.id, b.label, b.color, b.disabled, x, y_of(p, i))
        x = x + #b.label + 4 + 2
    end
end

local function button(p, id, label, color, disabled)
    buttons(p, {{id = id, label = label, color = color, disabled = disabled}})
end

-- Results of the last requests (kit toasts) on the last body rows.
local function toastRows(p) return wide(p) and 3 or 1 end
local function toasts(p)
    local count = toastRows(p)
    local r = p.c.rect
    p.views[#p.views + 1] = Toasts.layout({maxCount = count}, p.m.toasts,
        {x = r.x, y = r.y + r.height - count, width = r.width, height = count}, p.t, p.c)
end

-- This screen's question (the monitor and the terminal ask on their own); a
-- fresh id per question, so an old answer never closes a new one.
local function confirm(p)
    local q = p.m.confirms[p.c.screenId]
    if not q then return end
    local choices = q.choices or {}
    local props = {id = "confirm" .. tostring(q.seq), open = true, kind = #choices > 0 and "alert" or "confirm",
        title = q.title, message = q.message, submitLabel = q.submitLabel, cancelLabel = "Cancel",
        width = math.min(q.width or 44, p.c.rect.width)}
    if #choices > 0 then
        -- The choices (a checklist row) on one row; the kit's gap row, then
        -- Cancel on the last row.
        props.contentHeight = 1
        props.content = function(rect, theme, context)
            local views, x = {}, rect.x
            for _, choice in ipairs(choices) do
                if x + #choice.label + 4 - 1 > rect.x + rect.width - 1 then break end
                views[#views + 1] = buttonAt(context, choice.id, choice.label, theme[choice.color] or theme.accent,
                    false, x, rect.y)
                x = x + #choice.label + 4 + 1
            end
            return Render.compose(views, rect, context.bodyRect)
        end
    -- A note (how a missing raw is made) on its own line; the card fits it
    -- and the kit leaves one free row above the buttons. One column left,
    -- since rows start after a space.
    elseif q.note then
        props.contentHeight = 1
        props.content = function(rect, theme)
            return Rows.layout({{segs = {seg(q.note, theme[q.noteTone or "info"])}}},
                {x = rect.x - 1, y = rect.y, width = rect.width + 1, height = rect.height}, theme)
        end
    end
    p.views[#p.views + 1] = Layout.widget(Modal, props, p.c.rect, p.c)
end

local function finish(p)
    toasts(p)
    confirm(p)
    local all = {Rows.layout(p.rows, p.c.rowRect, p.t)}
    for _, v in ipairs(p.views) do all[#all + 1] = v end
    return Render.compose(all, p.c.rect, p.c.bodyRect)
end

-- Needs material: each missing raw once, how it is made, and that the
-- requests stopped (PC66 does not retry them by itself).
local function needsSection(p, most)
    local m, t = p.m, p.t
    local shown = math.min(#m.needs, most)
    if shown == 0 then return end
    local stopped = 0
    for _, need in ipairs(m.needs) do stopped = stopped + need.requests end
    section(p, "Needs material", ("%d request%s stopped"):format(stopped, stopped == 1 and "" or "s"))
    local nameWidth = math.min(30, width(p) - 8 - 11)
    for n = 1, shown do
        local need = m.needs[n]
        local segs = {seg(fit(need.raw, nameWidth), t.text), seg(fit("x" .. tostring(need.needed), 6, true) .. "  ", t.muted),
            Rows.chip("needs", t.warn, 11)}
        if wide(p) then segs[#segs + 1] = seg("for " .. need.forName, t.muted) end
        add(p, {segs = segs})
        add(p, {segs = {seg("  " .. need.how, t[need.tone])}})
    end
    muted(p, #m.needs > shown and ("+%d more; retry from History once in stock"):format(#m.needs - shown)
        or "Retry it from History once it is in stock")
end

-- Craft: the nine requester slots; a touch on a ready slot asks to craft
-- it. One line above them only when something stops the crafts.
local function craftPage(m, context)
    local p = page(m, context)
    local t = p.t
    if m.problem then
        status(p, "Problem", m.problem, "bad")
    elseif not m.controller.online then
        status(p, "Controller", "OFFLINE  requests wait here", "bad")
    end
    section(p, "Requester slots", ("%d of 9 set"):format(m.selectedCount))
    local nameWidth = math.min(40, width(p) - 2 - 8 - 11)
    local list = {}
    for _, s in ipairs(m.slots) do
        list[#list + 1] = {key = s.slot, segs = {seg(fit(s.slot, 2), t.muted),
            seg(fit(s.empty and "-" or s.name, nameWidth), s.empty and t.muted or t.text),
            seg(fit(s.empty and "" or ("x" .. tostring(s.count)), 6, true) .. "  ", t.muted), chip(p, s.state)}}
    end
    touchRows(p, "slots", list)
    button(p, "craft_all", ("CRAFT ALL %d"):format(m.readyCount), t.ok, m.readyCount == 0)
    return finish(p)
end

-- History: finished requests; a touch asks to repeat (or retry) one. It
-- pages (as Checklist): the kit's footer pager scrolls it (context.scroll,
-- in rows), and the page reports how far it goes (view.maxScroll) and its
-- page size (view.pageRows). Craft fits without scrolling.
local function historyPage(m, context)
    local p = page(m, context)
    local t = p.t
    local big = wide(p)
    local total = #m.history
    local head = section(p, "History", ("%d kept  touch one to repeat it"):format(total))
    local maxScroll, pageRows = 0, 0
    if total == 0 then
        muted(p, "Nothing yet")
    else
        -- room for the rows: what the needs, the button and the toasts leave
        local needRows = math.min(#m.needs, big and 3 or 1)
        local reserve = (needRows > 0 and (2 + 2 * needRows) or 0) + 2 + toastRows(p) + (big and 2 or 0)
        pageRows = math.max(1, left(p) - reserve)
        maxScroll = math.max(0, total - pageRows)
        local offset = math.max(0, math.min(math.floor(tonumber(context.scroll) or 0), maxScroll))
        local last = math.min(total, offset + pageRows)
        local nameWidth = math.min(40, width(p) - 8 - 11 - 6)
        local list = {}
        for n = offset + 1, last do
            local h = m.history[n]
            list[#list + 1] = {key = h.id, segs = {seg(fit(h.name, nameWidth), t.text),
                seg(fit("x" .. tostring(h.count), 6, true) .. "  ", t.muted), chip(p, h.state), seg(fit(h.ago, 5, true), t.muted)}}
        end
        touchRows(p, "history", list)
        if total > pageRows then
            p.rows[head] = sectionRow(p, "History", ("%d-%d of %d  touch one to repeat it"):format(offset + 1, last, total))
        end
        if needRows > 0 then
            if big then blank(p) end
            needsSection(p, needRows)
        end
    end
    if big then blank(p) end
    button(p, "clear_history", "CLEAR HISTORY", t.warn, total == 0)
    local view = finish(p)
    view.maxScroll, view.pageRows = maxScroll, pageRows
    return view
end

-- Checklist: the clipboard's missing materials against the warehouse; a
-- touch on a row asks what to do with it (SEND / CRAFT / CRAFT + SEND), the
-- buttons do it for the whole list. Without a Stock Ticker it only shows
-- the list. The rows page with the kit's footer pager (as History).
local function checklistPage(m, context)
    local p = page(m, context)
    local t = p.t
    local cl = m.checklist
    if not cl.enabled then
        status(p, "Clipboard", "off in 66/config.lua", "muted")
        return finish(p)
    end
    if not cl.visible then
        status(p, "Clipboard", cl.clipboard and "reading the list" or "none attached", "muted")
        if not cl.clipboard then muted(p, "Place a Create clipboard with a list on PC66's network") end
        return finish(p)
    end
    local address = cl.address ~= "" and cl.address or nil
    status(p, "Clipboard", ("%d items for %s"):format(cl.count, address or "no address: view only"), address and "ok" or "warn")
    if not cl.ticker then
        status(p, "Ticker", "none: view only", "bad")
    elseif cl.stockError then
        status(p, "Ticker", reason(cl.stockError), "bad")
    end
    local todo = {}
    if cl.toSend > 0 then todo[#todo + 1] = cl.toSend .. " to send" end
    if cl.toCraft > 0 then todo[#todo + 1] = cl.toCraft .. " to craft" end
    if cl.checking > 0 then todo[#todo + 1] = cl.checking .. " checking recipes" end
    status(p, "To do", #todo > 0 and table.concat(todo, ", ") or "nothing", #todo > 0 and "info" or "ok")
    if cl.error then
        status(p, "Problem", reason(cl.error), "bad")
    elseif cl.recipeError then
        status(p, "Recipes", reason(cl.recipeError), "warn")
    end

    local big = wide(p)
    local head = section(p, "Missing", cl.count > 0 and "touch one to send or craft" or nil)
    local needRows = math.min(#cl.needs, big and 2 or 1)
    -- room for the rows: what the needs and the toasts leave
    local reserve = (needRows > 0 and (2 + 2 * needRows + 1) or 0) + toastRows(p)
    local pageRows = math.max(1, left(p) - reserve)
    local maxScroll = math.max(0, cl.count - pageRows)
    if cl.count == 0 then
        muted(p, "Nothing missing: the list is complete")
    else
        local offset = math.max(0, math.min(math.floor(tonumber(context.scroll) or 0), maxScroll))
        local last = math.min(cl.count, offset + pageRows)
        local nameWidth = big and 30 or 19
        local barWidth = big and 16 or 6
        local list = {}
        for n = offset + 1, last do
            local r = cl.records[n]
            local lit, dim = Rows.bar(r.done, r.needed, barWidth, t[r.tone], t)
            local segs = {seg(fit(r.name, nameWidth), t.text), lit, dim,
                seg(fit(r.done .. "/" .. r.needed, big and 11 or 9, true) .. "  ", t.muted), Rows.chip(r.word, t[r.tone], big and 14 or 13)}
            local note = r.note or (r.stock > 0 and (r.stock .. " in stock") or nil)
            if big and note then segs[#segs + 1] = seg(note, t.muted) end
            list[#list + 1] = {key = r.key, segs = segs}
        end
        touchRows(p, "checklist", list)
        if cl.count > pageRows then
            p.rows[head] = sectionRow(p, "Missing", ("%d-%d of %d  touch one to send or craft"):format(offset + 1, last, cl.count))
        end
    end
    if needRows > 0 then
        local waiting = 0
        for _, need in ipairs(cl.needs) do waiting = waiting + need.rows end
        section(p, "Needs material", ("%d item%s wait"):format(waiting, waiting == 1 and "" or "s"))
        local rawWidth = math.min(30, width(p) - 8 - 11)
        for n = 1, needRows do
            local need = cl.needs[n]
            local segs = {seg(fit(need.raw, rawWidth), t.text), seg(fit("x" .. tostring(need.needed), 6, true) .. "  ", t.muted),
                Rows.chip("needs", t.warn, 11)}
            if big then segs[#segs + 1] = seg(("for %d item%s"):format(need.rows, need.rows == 1 and "" or "s"), t.muted) end
            add(p, {segs = segs})
            add(p, {segs = {seg("  " .. need.how, t[need.tone])}})
        end
        muted(p, (#cl.needs > needRows and ("+%d more; "):format(#cl.needs - needRows) or "")
            .. "bulk CRAFT skips these; the item's CRAFT retries")
    end
    local view = finish(p)
    view.maxScroll, view.pageRows = maxScroll, pageRows
    return view
end

-- The checklist's bulk actions sit in the kit's footer, under the list,
-- with short labels (owner 2026-11-08).
local function checklistFooter(m, context)
    local cl, t = m.checklist or {}, context.theme
    if not cl.enabled or not cl.visible then return nil end
    return {buttons = {{
        {id = "cl_send_all", label = "SEND ALL", color = t.ok, disabled = not cl.sendEnabled},
        {id = "cl_craft_all", label = "CRAFT MISSING", color = t.accent, disabled = not cl.craftEnabled},
        {id = "cl_craft_send_all", label = "CRAFT+SEND", color = t.warn, disabled = not cl.craftSendEnabled},
    }}}
end

function S.pages()
    return {
        {name = "Craft", page = craftPage},
        {name = "History", page = historyPage},
        {name = "Checklist", page = checklistPage, footer = checklistFooter},
    }
end

-- A touch or click is not keyboard focus: no focus line stays under what
-- was pressed (as on the drone screens). An open question keeps its focus.
function S.unfocus(app, screenId)
    local s = app.screens[screenId]
    local p = s and s.pages[s.active]
    if p and p.focus and not p.focus.modalId then p.focus.focusedId = nil end
end

return S
