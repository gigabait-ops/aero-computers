-- TUF farm pages on the shared UI kit (`require("ui")`, common.ui with App).
-- The kit owns the screen: tabs, footer, pager, touch and palette. This
-- module only turns the farm view (tuf.view) into rows, in
-- PC107's look (docs/screen-style.md): status lines first, then sections
-- of one row per thing with a name, a bar, the numbers and a state word.
--
-- Pages never act: a touch on a row or a button becomes a kit action that
-- the program (tuf/farm.lua) turns into a settings command.
local Lib = require("ui")
local Rows, Layout, Controls, Render, Text = Lib.Rows, Lib.Layout, Lib.Controls, Lib.Render, Lib.Text
local Modal, Toasts = Lib.Feedback.Modal, Lib.Feedback.Toasts

local M = {}

local DOT = string.char(7)

-- Limit steps on the edit card, in items (1, 4, 16 and 64 stacks).
M.STEPS = {64, 256, 1024, 4096}
M.PERCENT_STEPS = {1, 5}

local function seg(text, fg) return Rows.segment(text, fg) end
local function fit(text, width, right) return Text.fit(text, width, right) end

-- 80007 -> "80,007"
function M.num(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end

-- 80007 -> "80k" for narrow screens
function M.short(n)
    n = tonumber(n) or 0
    if n >= 100000 then return ("%dk"):format(math.floor(n / 1000)) end
    if n >= 10000 then return ("%.1fk"):format(n / 1000) end
    return tostring(math.floor(n))
end

function M.item(id) return Text.pretty(id or "?") end

-- ------------------------------------------------------------ the words

-- Stage state -> word and theme token (screen-style: ok fine, warn short
-- or waiting, busy working, info manual, bad broken, muted idle).
local STATE = {
    run = {"running", "busy"}, wait = {"waiting", "muted"}, full = {"full", "ok"},
    off = {"off", "muted"}, base = {"low input", "warn"}, power = {"no power", "warn"},
    link = {"no bridge", "bad"}, signal = {"no signal", "bad"},
}

function M.stageWord(stage)
    if stage.manual ~= nil then
        return stage.manual == 0 and "manual run" or "manual stop", "info"
    end
    if stage.state == "api" then
        return "needs " .. tostring(stage.need or "input"):lower(), "warn"
    end
    if stage.state == "run" and stage.feeds then
        return "feeds " .. tostring(stage.feeds):lower(), "busy"
    end
    local w = STATE[stage.state] or {tostring(stage.state or "?"), "muted"}
    return w[1], w[2]
end

-- What a factory does now: the stage that runs, else why nothing runs.
function M.factoryNow(f)
    local running, manual = {}, nil
    for _, s in ipairs(f.stages or {}) do
        if s.state == "run" then running[#running + 1] = s end
        if s.manual ~= nil then manual = s end
    end
    if f.mode == "off" then return nil, "off", "muted" end
    if #running > 1 then return nil, ("%d lines"):format(#running), "busy" end
    if running[1] then return running[1], "running", "busy" end
    if manual then return manual, M.stageWord(manual) end
    local first = f.stages and f.stages[1]
    if first and first.state == "base" then return nil, "low input", "warn" end
    if first and first.state == "power" then return nil, "no power", "warn" end
    for _, s in ipairs(f.stages or {}) do
        if s.state == "api" then return s, M.stageWord(s) end
        if s.state == "link" or s.state == "signal" then return s, M.stageWord(s) end
    end
    return nil, "all full", "ok"
end

-- Power: on, off here, stopped for a full storage, or held off by another
-- transmitter on the power channel (the owner's lever).
function M.powerLine(power, theme)
    power = power or {}
    if power.reason == "off" then return "off  turned off here", theme.warn end
    if power.reason == "storage" then return "stopped  storage is full", theme.warn end
    if power.held then return "stopped by the lever", theme.warn end
    return "on", theme.ok
end

-- ------------------------------------------------------------ page parts

local function newPage(st, context)
    local t = context.theme
    return {st = st, v = st.view or {}, c = context, t = t, rows = {}, views = {}, touch = {},
        wide = context.rowRect.width >= 70}
end
local function add(p, row) p.rows[#p.rows + 1] = row; return #p.rows end
local function blank(p) return add(p, {segs = {}}) end
local function line(p, text, tone) return add(p, {segs = {seg(text, p.t[tone or "muted"])}}) end

local function section(p, title, note)
    local row = Rows.section(title, note, p.t)
    if row.right then row.right.inset = 1 end
    return add(p, row)
end

local function status(p, label, value, color)
    return add(p, {segs = {seg(DOT .. " ", color or p.t.muted), seg(fit(label, 11), p.t.muted),
        seg(value, p.t.text)}})
end

-- Touch on whole rows: the kit's Rows draw them, this adds one hit per row
-- (part = the row's key); a touch or click emits change with that key.
local Touch = {}
function Touch.layout(props, _, rect)
    local view = {ops = {}, hits = {}, focusables = {}, bindings = {}}
    for index, key in ipairs(props.keys or {}) do
        if key and index <= rect.height then
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
M.Touch = Touch

-- Rows that a touch opens (list of {key, segs}); key false = not touchable.
-- The hits are placed in finish(), after the scroll offset is known.
local function touchRows(p, id, list)
    if #list == 0 then return end
    local first = #p.rows + 1
    local keys = {}
    for index, row in ipairs(list) do
        add(p, {segs = row.segs})
        keys[index] = row.key or false
    end
    p.touch[#p.touch + 1] = {id = id, first = first, keys = keys}
end

-- One stock row: name, bar, count / limit, state word, note.
local function stockSegs(p, name, count, limit, word, tone, note)
    local t = p.t
    local nameW, barW = p.wide and 20 or 13, p.wide and 24 or 8
    local segs = {seg(fit(name, nameW), t.text)}
    local lit, dim = Rows.bar(count, limit and limit > 0 and limit or math.max(count, 1), barW, t[tone] or t.accent, t)
    segs[#segs + 1] = lit
    segs[#segs + 1] = dim
    local nums
    if p.wide then
        nums = M.num(count) .. " / " .. (limit and limit > 0 and M.num(limit) or "no limit")
        segs[#segs + 1] = seg(" " .. fit(nums, 18, true) .. "  ", t.muted)
    else
        nums = M.short(count) .. "/" .. (limit and limit > 0 and M.short(limit) or "-")
        segs[#segs + 1] = seg(" " .. fit(nums, 11, true) .. " ", t.muted)
    end
    segs[#segs + 1] = Rows.chip(word, t[tone] or t.muted, p.wide and 14 or 12)
    if note and p.wide then segs[#segs + 1] = seg(note, t.muted) end
    return segs
end

-- Results of the last commands (kit toasts) on the last body rows.
local function toasts(p)
    if not p.st.toasts then return end
    local r = p.c.rect
    p.views[#p.views + 1] = Toasts.layout({maxCount = 2}, p.st.toasts,
        {x = r.x, y = r.y + r.height - 2, width = r.width, height = 2}, p.t, p.c)
end

local function buttonAt(c, id, label, color, x, y, width)
    local cc = {}
    for k, v in pairs(c) do cc[k] = v end
    cc.theme = {}
    for k, v in pairs(c.theme) do cc.theme[k] = v end
    cc.theme.accent = color or c.theme.accent
    return Layout.widget(Controls.button, {id = id, label = label},
        {x = x, y = y, width = width or (#label + 4), height = 2}, cc)
end

-- Buttons in rows inside a card; each row is a list of {id, label, color}.
local function buttonRows(rect, context, rows, width)
    local views, y = {}, rect.y
    for _, list in ipairs(rows) do
        local x = rect.x
        for _, b in ipairs(list) do
            local w = width or (#b.label + 4)
            if x + w - 1 > rect.x + rect.width - 1 then break end
            views[#views + 1] = buttonAt(context, b.id, b.label, context.theme[b.color or "accent"], x, y, w)
            x = x + w + 1
        end
        y = y + 2
    end
    return Render.compose(views, rect, context.bodyRect)
end

-- What an edit card is about, read from the current view (so the numbers
-- follow the farm while the card is open). e = st.edit[screenId]:
-- {kind = "stage"|"base"|"res"|"rule", factory?, name?, key?, id?}
function M.target(view, e)
    view = view or {}
    if e.kind == "rule" then
        for _, r in ipairs(view.stops or {}) do
            if r.id == e.id then return r end
        end
        return nil
    end
    for _, f in ipairs(view.factories or {}) do
        if e.kind == "stage" then
            for rank, s in ipairs(f.stages) do
                if s.name == e.name then return s, f, rank end
            end
        elseif f.name == e.factory then
            if e.kind == "base" then return f.base, f end
            for _, r in ipairs(f.resources or {}) do
                if r.key == e.key then return r, f end
            end
        end
    end
    return nil
end

local ORDINAL = {"First", "Second", "Third", "Fourth", "Fifth", "Sixth"}

local function cardText(view, e)
    local x, f, rank = M.target(view, e)
    if not x then return nil end
    if e.kind == "rule" then
        local fill = x.max > 0 and math.floor(x.used * 100 / x.max) or 0
        if x.enabled then
            return x.label, ("Power stops at %d%% full (now %d%%)."):format(x.percent, fill)
        end
        return x.label, ("No stop. It would stop at %d%% (now %d%%)."):format(x.percent, fill)
    end
    local limit = x.limit > 0 and M.num(x.limit) or "no limit"
    if e.kind == "base" then
        return M.item(x.item), ("The lines start at %s (now %s)."):format(limit, M.num(x.count))
    end
    local text = ("Full at %s (now %s)."):format(limit, M.num(x.count))
    if e.kind == "stage" and not f.parallel then
        text = text .. " " .. (ORDINAL[rank] or ("No. " .. rank)) .. " in line."
    end
    return x.label or M.item(x.item), text
end

-- The edit card a touch opened on this screen (st.edit[screenId]).
local function editCard(p)
    local e = p.st.edit and p.st.edit[p.c.screenId]
    if not e or e.page ~= p.name then return end
    local title, message = cardText(p.v, e)
    if not title then return end
    local r = p.c.rect
    local narrow = r.width < 70
    local rows = {}
    if e.kind == "rule" then
        local x = M.target(p.v, e)
        local list = {{id = "edit:rule:toggle", label = x.enabled and "STOP OFF" or "STOP ON", color = x.enabled and "warn" or "ok"}}
        for i = #M.PERCENT_STEPS, 1, -1 do list[#list + 1] = {id = "edit:pct:-" .. M.PERCENT_STEPS[i], label = "-" .. M.PERCENT_STEPS[i] .. "%", color = "warn"} end
        for i = 1, #M.PERCENT_STEPS do list[#list + 1] = {id = "edit:pct:" .. M.PERCENT_STEPS[i], label = "+" .. M.PERCENT_STEPS[i] .. "%", color = "ok"} end
        rows[#rows + 1] = list
    else
        local minus, plus = {}, {}
        for i = #M.STEPS, 1, -1 do minus[#minus + 1] = {id = "edit:delta:-" .. M.STEPS[i], label = "-" .. M.STEPS[i], color = "warn"} end
        for i = 1, #M.STEPS do plus[#plus + 1] = {id = "edit:delta:" .. M.STEPS[i], label = "+" .. M.STEPS[i], color = "ok"} end
        if narrow then
            rows[#rows + 1] = minus
            rows[#rows + 1] = plus
        else
            local both = {}
            for _, b in ipairs(minus) do both[#both + 1] = b end
            for _, b in ipairs(plus) do both[#both + 1] = b end
            rows[#rows + 1] = both
        end
        local more = {{id = "edit:nolimit", label = "NO LIMIT", color = "muted"}}
        local _, f = M.target(p.v, e)
        if e.kind == "stage" and f and not f.parallel then
            more[#more + 1] = {id = "edit:up", label = "UP", color = "accent"}
            more[#more + 1] = {id = "edit:down", label = "DOWN", color = "accent"}
        end
        rows[#rows + 1] = more
        if e.kind == "stage" then
            rows[#rows + 1] = {{id = "edit:manual:auto", label = "AUTO", color = "ok"},
                {id = "edit:manual:0", label = "RUN", color = "busy"}, {id = "edit:manual:15", label = "STOP", color = "warn"}}
        end
    end
    local props = {id = "edit" .. tostring(e.seq or 0), open = true, kind = "alert", title = title,
        message = message, submitLabel = "Close", width = narrow and r.width or 76,
        contentHeight = #rows * 2}
    props.content = function(rect, theme, context) return buttonRows(rect, context, rows, narrow and 9 or nil) end
    p.views[#p.views + 1] = Layout.widget(Modal, props, r, p.c)
end

local function finish(p)
    -- long pages scroll with the kit's footer pager (context.scroll, in rows)
    local rect = p.c.rowRect
    local maxScroll = math.max(0, #p.rows - rect.height)
    local offset = math.max(0, math.min(math.floor(tonumber(p.c.scroll) or 0), maxScroll))
    local all = {Rows.layout(p.rows, rect, p.t, offset)}
    for _, group in ipairs(p.touch) do
        local keys = {}
        local top = group.first - offset
        for i, key in ipairs(group.keys) do
            local row = top + i - 1
            if row >= 1 and row <= rect.height then keys[#keys + 1] = {row, key} end
        end
        if #keys > 0 then
            local from, to = keys[1][1], keys[#keys][1]
            local list = {}
            for _, k in ipairs(keys) do list[k[1] - from + 1] = k[2] end
            all[#all + 1] = Layout.widget(Touch, {id = group.id, keys = list},
                {x = p.c.rect.x, y = rect.y + from - 1, width = p.c.rect.width, height = to - from + 1}, p.c)
        end
    end
    toasts(p)
    editCard(p)
    for _, v in ipairs(p.views) do all[#all + 1] = v end
    local view = Render.compose(all, p.c.rect, p.c.bodyRect)
    view.maxScroll = maxScroll
    view.pageRows = rect.height
    return view
end

local function starting(p)
    if p.v.factories then return false end
    status(p, "Farm", "starting", p.t.warn)
    return true
end

-- ------------------------------------------------------------ pages

local function storageValue(v, wide)
    local s = v.storage or {}
    local all = v.stops and v.stops[1]
    if not wide then
        local stop = all and all.enabled and ("  stop " .. all.percent .. "%") or ""
        return ("%d%%  %s/%s%s"):format(s.percent or 0, M.short(s.used), M.short(s.max), stop)
    end
    local stop = all and all.enabled and ("  stop at " .. all.percent .. "%") or "  no stop"
    return ("%d%%  %s of %s items%s"):format(s.percent or 0, M.num(s.used), M.num(s.max), stop)
end

local function storageTone(v, t)
    local s = v.storage or {}
    if not s.ok then return t.bad end
    local all = v.stops and v.stops[1]
    if all and all.enabled and (s.percent or 0) >= all.percent then return t.bad end
    if (s.percent or 0) >= 90 then return t.warn end
    return t.ok
end

local function linksValue(v)
    local l = v.links or {}
    local bad = 0
    for _, ch in ipairs(l.list or {}) do if not ch.ok and not ch.held then bad = bad + 1 end end
    if not l.bridge then return "no bridge found", false end
    if bad > 0 then return ("%d channels  %d with a problem"):format(#(l.list or {}), bad), false end
    return ("%d channels on one bridge"):format(#(l.list or {})), true
end

local function statusPage(st, context)
    local p = newPage(st, context)
    p.name = "Status"
    if starting(p) then return finish(p) end
    local v, t = p.v, p.t
    local power, powerTone = M.powerLine(v.power, t)
    if v.hold then status(p, "Start", "waiting for the PC11 report before switching", t.warn) end
    status(p, "Power", power, powerTone)
    status(p, "Storage", storageValue(v, p.wide), storageTone(v, t))
    local linkText, linksOk = linksValue(v)
    status(p, "Links", linkText, linksOk and t.ok or t.bad)
    blank(p)
    local running = 0
    for _, f in ipairs(v.factories) do
        for _, s in ipairs(f.stages) do if s.state == "run" then running = running + 1 end end
    end
    section(p, "Factories", ("%d lines running"):format(running))
    local nameW = 10
    for _, f in ipairs(v.factories) do
        local s, word, tone = M.factoryNow(f)
        local what = s and M.item(s.item) or (f.base and M.item(f.base.item)) or ""
        local count, limit = 0, 0
        if s then count, limit = s.count, s.limit
        elseif f.base then count, limit = f.base.count, f.base.limit end
        if f.parallel and #f.stages > 0 then
            what = M.item(f.stages[1].item)
            count, limit = f.stages[1].count, f.stages[1].limit
        end
        if p.wide then
            local segs = {seg(fit(f.label, nameW), t.text)}
            for _, x in ipairs(stockSegs(p, what, count, limit, word, tone)) do segs[#segs + 1] = x end
            add(p, {segs = segs})
        else
            add(p, {segs = stockSegs(p, f.label, count, limit, word, tone)})
        end
    end
    return finish(p)
end

local function statusFooter(st, context)
    if not (st.view and st.view.power) then return nil end
    local on = st.view.power.mode ~= "off"
    return {buttons = {{{id = "power", label = on and "POWER OFF" or "POWER ON", width = 13,
        color = on and context.theme.warn or context.theme.ok}}}}
end

local function factoryPage(name)
    return function(st, context)
        local p = newPage(st, context)
        p.name = name
        if starting(p) then return finish(p) end
        local t, f = p.t, nil
        for _, x in ipairs(p.v.factories) do if x.label == name then f = x end end
        if not f then line(p, "No factory " .. name, "bad"); return finish(p) end
        local _, word, tone = M.factoryNow(f)
        status(p, "Mode", f.mode == "off" and "off  touch START" or "auto", f.mode == "off" and t.warn or t.ok)
        status(p, "Now", word, t[tone])
        blank(p)
        local inputs = {}
        if f.base then
            local low = f.base.limit > 0 and f.base.count < f.base.limit
            inputs[#inputs + 1] = {key = "base:" .. f.name, segs = stockSegs(p, M.item(f.base.item), f.base.count, f.base.limit,
                low and "low" or "enough", low and "warn" or "ok", "starts at the limit")}
        end
        for _, r in ipairs(f.resources or {}) do
            local note = r.from and ("set on " .. r.from) or nil
            local full = r.limit > 0 and r.count >= r.limit
            local word, tone = full and "full" or "filling", full and "ok" or "info"
            if r.from then word, tone = full and "enough" or "low", full and "ok" or "warn" end
            inputs[#inputs + 1] = {key = r.editable and ("res:" .. f.name .. ":" .. r.key) or false,
                segs = stockSegs(p, M.item(r.item), r.count, r.limit, word, tone, note)}
        end
        if #inputs > 0 then
            section(p, f.parallel and "Stock" or "Input", "touch to set")
            touchRows(p, "stock", inputs)
            blank(p)
        end
        section(p, f.parallel and "Lines" or "Output", f.parallel and "run side by side" or "in priority order, touch to set")
        local list = {}
        for _, s in ipairs(f.stages) do
            local w, tn = M.stageWord(s)
            local label = s.label or M.item(s.item)
            list[#list + 1] = {key = "stage:" .. s.name, segs = stockSegs(p, label, s.count, s.limit, w, tn)}
        end
        touchRows(p, "stage", list)
        for _, s in ipairs(f.stages) do
            if s.state == "api" then
                blank(p)
                line(p, "A line waits until its factory is full: that factory's ingots feed it.", "warn")
                break
            end
        end
        return finish(p)
    end
end

local function factoryFooter(name)
    return function(st, context)
        if not st.view or not st.view.factories then return nil end
        for _, f in ipairs(st.view.factories) do
            if f.label == name then
                local off = f.mode == "off"
                return {buttons = {{{id = "mode:" .. f.name, label = off and "START" or "STOP", width = 9,
                    color = off and context.theme.ok or context.theme.warn}}}}
            end
        end
        return nil
    end
end

local function storagePage(st, context)
    local p = newPage(st, context)
    p.name = "Storage"
    if starting(p) then return finish(p) end
    local v, t = p.v, p.t
    status(p, "Fill", storageValue(v, p.wide), storageTone(v, t))
    local s = v.storage or {}
    status(p, "Sources", ("%d storages%s"):format(#(v.stops or {}) - 1,
        s.remote == false and "  PC11 not answering" or ""), s.remote == false and t.warn or t.ok)
    if v.surplus then
        local text, tone = M.surplusLine(v.surplus, p.c.now, p.wide)
        status(p, "Surplus", text, t[tone])
    end
    blank(p)
    section(p, "Stop the farm when full", "touch to set")
    local list = {}
    for _, r in ipairs(v.stops or {}) do
        local word = r.enabled and ("at " .. r.percent .. "%") or "off"
        local tone = r.stopping and "bad" or (r.enabled and "ok" or "muted")
        if r.stopping then word = "stopping" end
        list[#list + 1] = {key = "rule:" .. r.id, segs = stockSegs(p, r.label, r.used, r.max, word, tone)}
    end
    touchRows(p, "rule", list)
    blank(p)
    local items = v.items or {}
    section(p, "Items", ("%d kinds"):format(#items))
    local cols = p.wide and 3 or 1
    local colW = math.floor((p.c.rowRect.width - 1) / cols)
    for i = 1, #items, cols do
        local segs = {}
        for c = 0, cols - 1 do
            local it = items[i + c]
            if it then
                segs[#segs + 1] = seg(fit(M.item(it[1]), colW - 10), t.text)
                segs[#segs + 1] = seg(fit(M.num(it[2]), 8, true) .. "  ", t.muted)
            end
        end
        add(p, {segs = segs})
    end
    return finish(p)
end

local function linksPage(st, context)
    local p = newPage(st, context)
    p.name = "Links"
    if starting(p) then return finish(p) end
    local v, t = p.v, p.t
    local l = v.links or {}
    status(p, "Bridge", l.bridge or "none found", l.bridge and t.ok or t.bad)
    local text, ok = linksValue(v)
    status(p, "Channels", text, ok and t.ok or t.bad)
    blank(p)
    section(p, "Channels", "0 = run, 15 = stop")
    for _, ch in ipairs(l.list or {}) do
        local word, tone = "ok", "ok"
        if ch.err then word, tone = "no bridge", "bad"
        elseif ch.held then word, tone = "held", "warn"
        elseif not ch.ok then word, tone = "no signal", "bad" end
        local pair = M.item(ch.freq1) .. " + " .. M.item(ch.freq2)
        local segs = {seg(fit(ch.label, p.wide and 20 or 13), t.text)}
        if p.wide then segs[#segs + 1] = seg(fit(pair, 40), t.muted) end
        segs[#segs + 1] = seg(fit(("%2d > %2d"):format(ch.want or 0, ch.read or 0), 9), t.muted)
        segs[#segs + 1] = Rows.chip(word, t[tone], 12)
        if ch.held and p.wide then segs[#segs + 1] = seg("by another source", t.muted) end
        add(p, {segs = segs})
    end
    return finish(p)
end

local function logPage(st, context)
    local p = newPage(st, context)
    p.name = "Log"
    local lines = st.log or {}
    if #lines == 0 then line(p, "Nothing to report") end
    for i = #lines, 1, -1 do
        local e = lines[i]
        add(p, {segs = {seg(fit(e.time or "", 6), p.t.muted), seg(e.text, p.t[e.tone or "text"])}})
    end
    return finish(p)
end

-- The surplus status: where it goes, what is over now, the last order.
-- -> text, tone
function M.surplusLine(sp, now, wide)
    if sp.state == "off" then return "off in config", "muted" end
    if sp.state == "missing" then return "no redstone requester found", "bad" end
    if sp.state == "error" then return "order failed: " .. tostring(sp.err), "bad" end
    local text = "to " .. tostring(sp.address)
    local ago = sp.last and Text.age((tonumber(now) or 0) - sp.last.at)
    if not wide then
        text = text .. (#sp.over == 0 and "  nothing over" or ("  %d over"):format(#sp.over))
        return text .. (ago and ("  sent " .. ago .. " ago") or ""), #sp.over == 0 and "ok" or "warn"
    end
    if sp.last then
        local first = sp.last.lines[1]
        text = text .. ("  last %s ago: %s %s%s"):format(ago, M.num(first.count), M.item(first.name),
            #sp.last.lines > 1 and (" +" .. (#sp.last.lines - 1)) or "")
    end
    if #sp.over == 0 then return text .. "  nothing over", "ok" end
    local parts = {}
    for i = 1, math.min(#sp.over, 3) do parts[i] = M.short(sp.over[i].count) .. " " .. M.item(sp.over[i].item) end
    return text .. "  over: " .. table.concat(parts, ", "), "warn"
end

-- Pages for App.new{pages = ...}: the same on the monitor (touch) and the
-- terminal.
function M.pages(config)
    local list = {{name = "Status", page = statusPage, footer = statusFooter}}
    for _, f in ipairs(config.factories or {}) do
        list[#list + 1] = {name = f.label, page = factoryPage(f.label), footer = factoryFooter(f.label)}
    end
    list[#list + 1] = {name = "Storage", page = storagePage}
    list[#list + 1] = {name = "Links", page = linksPage}
    list[#list + 1] = {name = "Log", page = logPage}
    return list
end

return M
