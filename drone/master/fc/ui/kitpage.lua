-- Page building on the shared CC UI kit (`require("ui")`, Tensa Aeronautics
-- ROM), shared by the drone's screens (fc.screens) and the owner's pocket
-- computer (installed there as pda/kitpage.lua). A page is rows the kit
-- draws plus widgets placed on them; the footer is ours: a rule and the
-- page's buttons on the last row(s), a warning above the rule (the kit's own
-- footer is hidden by P.tall). Layout only: no peripherals, no state changes.
local UI = require("ui")
local Rows, Layout, Controls, Render, Text = UI.Rows, UI.Layout, UI.Controls, UI.Render, UI.Text
local Modal = UI.Feedback.Modal

local P = {}

P.DOT = string.char(7)

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function P.num(v, f)
    if v == nil or v ~= v then return "--" end
    return (f or "%.1f"):format(v)
end

function P.seg(text, fg) return Rows.segment(tostring(text), fg) end
local seg = P.seg

-- A page under construction. A control's rect is two rows (the kit wants
-- that) but it draws only on its first ("> Label <" marks focus), so the next
-- row of the page can go there.
function P.page(context)
    return {c = context, t = context.theme, rows = {}, views = {}}
end

function P.add(p, row) p.rows[#p.rows + 1] = row; return #p.rows end
function P.blank(p) return P.add(p, {segs = {}}) end
function P.line(p, color, text) return P.add(p, {segs = {seg(text, color)}}) end
function P.y_of(p, index) return p.c.rowRect.y + index - 1 end

-- Content rows still free above the footer (the rule, the buttons, a warning
-- once P.notice set one: set it and the bar before laying out a list).
-- The button style (common.ui e8b49dbf, ce421e30), only those with the
-- label centred (owner 2026-10-23: "filled" and "tonal" put it high, they
-- are gone): the plain family in one row ("plain" "[ FLY ]" the default,
-- "plain-white" white label, "plain-dim" grey brackets, "paren" ( ),
-- "brace" { }, "bar" | |, "dot", "angle" < >, "chevron"), "tonal-cap" and
-- "tint" (a cap row above the label) or "frame" (bars above and below). The owner picks it (master
-- SETTINGS "Buttons", cfg.ui.buttons; the glasses follow the master). The
-- footer draws the style itself; a button inside the page (laps -/+, the
-- point settings, Legs and Engine) is one row high among text, so it is
-- plain there. A kit without the styles draws them plain.
P.STYLES = {"plain", "plain-white", "plain-dim", "paren", "brace", "bar", "dot", "angle", "chevron", "tonal-cap", "tint", "frame"}
P.VARIANT = "plain"
-- one-row styles go inside a page as they are; the taller ones are plain there
local INLINE = {plain = "plain", ["plain-white"] = "plain-white", ["plain-dim"] = "plain-dim", paren = "paren", brace = "brace",
    bar = "bar", dot = "dot", angle = "angle", chevron = "chevron", ["tonal-cap"] = "plain", tint = "plain", frame = "plain"}

-- The style for this page (unknown or nil: plain).
function P.style(name)
    P.VARIANT = INLINE[name] and name or "plain"
    return P.VARIANT
end

-- The App's theme with the button style: the kit's own buttons (a prompt's
-- OK / Cancel) and the tint palette for "tint" follow; only on a change.
function P.apply_style(app, style)
    style = INLINE[style] and style or "plain"
    if not app or app.style_applied == style or type(app.setTheme) ~= "function" then return end
    app.style_applied = style
    pcall(app.setTheme, app, {name = "dark", button = {variant = style}})
end

-- Rows a footer button takes and its label's offset (the kit's own measure).
local function rows_of(variant)
    local rows = Controls.button and Controls.button.rows
    if type(rows) ~= "function" then return 1, 0 end
    local ok, n, off = pcall(rows, nil, variant)
    if not ok or type(n) ~= "number" then return 1, 0 end
    return n, off or 0
end

-- Rows between two rows of page buttons stacked one over the other: none
-- extra, whatever the style (blank rows between them looked wasted, owner
-- 2026-10-23).
function P.row_step() return 1 end

-- The footer: each row of buttons in the style's own height, nothing
-- between or under them (owner 2026-10-23: no extra gaps).
local function footer_shape(p)
    local n = p.bar and #p.bar.lines or 1
    local rows, off = rows_of(P.VARIANT)
    return math.max(1, n * rows), rows, off, 0
end
local function bar_rows(p) return (footer_shape(p)) end

function P.left(p) return p.c.rect.height - 1 - bar_rows(p) - (p.note and 1 or 0) - #p.rows end

-- A control with its own accent (the kit's per-component colour: a copied theme).
function P.widget(p, w, props, x, y, width, color, height)
    local c = copy(p.c)
    if color then c.theme = copy(p.t); c.theme.accent = color end
    p.views[#p.views + 1] = Layout.widget(w, props, {x = x, y = y, width = width, height = height or 2}, c)
    return x + width
end

-- A button inside the page: on row y, one row high.
function P.button(p, id, label, color, x, y)
    return P.widget(p, Controls.button, {id = id, label = label, variant = INLINE[P.VARIANT] or "plain"}, x, y, #label + 4, color)
end

-- The page's buttons {id, label, color} on the footer row; `lines` instead
-- gives several footer rows of buttons (top first).
function P.bar(p, list, gap) p.bar = {lines = {list}, gap = gap or 2} end
function P.bars(p, lines, gap) p.bar = {lines = lines, gap = gap or 2} end

-- A warning for the row above the rule.
function P.notice(p, text, color)
    if text then p.note = {segs = {seg(P.DOT .. " ", color or p.t.bad), seg(tostring(text), color or p.t.bad)}} end
end

-- Typed input over the page while `edit` ({n, title, prompt [, id, value]}) is
-- set (value: the text it opens with, e.g. a saved point to change);
-- a fresh id per prompt ("edit<n>", or edit.id .. n) so no old state reopens
-- or closes it.
function P.prompt(p, edit, max)
    if not edit or not P.keyboard(p.c) then return end   -- typed at the computer, not on a monitor
    p.views[#p.views + 1] = Layout.widget(Modal, {id = (edit.id or "edit") .. tostring(edit.n or 0), open = true, kind = "prompt",
        title = edit.title or "Type", message = edit.prompt, value = edit.value, maxLength = max or 40, width = math.min(40, p.c.rect.width)}, p.c.rect, p.c)
end

function P.finish(p)
    local h = p.c.rect.height
    local lines = p.bar and p.bar.lines or {}
    local top = math.max(0, h - 1 - bar_rows(p))   -- content (and the warning) above the rule
    while #p.rows > top do table.remove(p.rows) end
    if p.note and top > 0 then
        while #p.rows < top - 1 do P.blank(p) end
        if #p.rows == top then p.rows[top] = p.note else P.add(p, p.note) end
    end
    if h >= 2 then
        while #p.rows < top do P.blank(p) end
        P.add(p, {segs = {}, rule = p.t.border})
    end
    local _, rows, _, gap = footer_shape(p)
    for n, list in ipairs(lines) do
        local row = 1 + (n - 1) * (rows + gap)   -- this button row's first row, under the rule
        if top + row + rows - 1 > h then break end
        local y = p.c.rowRect.y + top + row
        local x, width = p.c.rect.x, p.c.rect.width
        -- the buttons that fit with the bar's gap (narrow pages pass fewer),
        -- then spread over the whole row, the first at the left edge and the
        -- last at the right (owner 2026-10-24: space between)
        local fit, used = {}, 0
        for _, b in ipairs(list) do
            local need = used + (#fit > 0 and p.bar.gap or 0) + #b[2] + 4
            if need > width then break end
            fit[#fit + 1], used = b, need
        end
        local free, words = width, 0
        for _, b in ipairs(fit) do words = words + #b[2] + 4 end
        free = width - words
        for i, b in ipairs(fit) do
            P.widget(p, Controls.button, {id = b[1], label = b[2], variant = P.VARIANT}, x, y, #b[2] + 4, b[3], math.max(2, rows))
            local spaces = #fit - i
            local step = spaces > 0 and math.floor(free / spaces) or 0
            x, free = x + #b[2] + 4 + step, free - step
        end
    end
    local all = {Rows.layout(p.rows, p.c.rowRect, p.t)}
    for _, v in ipairs(p.views) do all[#all + 1] = v end
    return Render.compose(all, p.c.rect, p.c.bodyRect)
end

function P.narrow(context) return context.rect.width < 40 or context.rect.height < 13 end

-- A keyboard to type with: the computer's own screen (the kit's "terminal"),
-- not a monitor. Owner rule (2026-10-18), for every screen: a monitor shows
-- no button and no action that needs typing (prompts, typed values).
function P.keyboard(context) return context.screenId == nil or context.screenId == "terminal" end

-- Pick list: one line per entry ({key, segs}), the whole line touchable; a
-- touch emits change with the entry's key. Rows of coloured segments, which
-- the kit's Table (one colour per cell) cannot draw.
local Pick = {}
P.Pick = Pick

function Pick.layout(props, _, rect, theme)
    local v = {ops = {}, hits = {}, focusables = {}, bindings = {}}
    local right = rect.x + rect.width
    for i, r in ipairs(props.rows or {}) do
        local y = rect.y + i - 1
        if y >= rect.y + rect.height then break end
        local x = rect.x
        for _, sg in ipairs(r.segs) do
            local glyphs = sg.allowGlyphs or sg.kind == "graphics"   -- a chip's dot, a bar
            local text = Text.ascii(sg.text, glyphs)
            if x < right and #text > 0 then
                v.ops[#v.ops + 1] = {x = x, y = y, text = text:sub(1, right - x), fg = sg.fg, bg = theme.bg,
                    kind = sg.kind or "text", allowGlyphs = glyphs}
            end
            x = x + #text
        end
        if r.key ~= nil then v.hits[#v.hits + 1] = {id = props.id, rect = {x = rect.x, y = y, width = rect.width, height = 1}, part = r.key} end
    end
    if #v.hits > 0 then v.bindings[props.id] = {widget = Pick, props = props} end
    return v
end

function Pick.handle(props, state, event)
    local touched = event.type == "mouse_click" or event.type == "monitor_touch" or event.type == "click"
    if touched and event.part ~= nil then return state, {{type = "change", id = props.id, value = event.part}} end
    return state, {}
end

-- A Pick list of `rows` on the page's next rows.
function P.pick(p, id, rows)
    local i = #p.rows + 1
    p.views[#p.views + 1] = Layout.widget(Pick, {id = id, rows = rows},
        {x = p.c.rect.x, y = P.y_of(p, i), width = p.c.rect.width, height = #rows}, p.c)
    for _ = 1, #rows do P.blank(p) end
end

-- Sub-tabs as one filled strip split evenly, the open one in the accent
-- with dark text (owner 2026-11-08: variant "segments" for the Drone and
-- Mine tabs). `items` = {{key, label}}; a touch emits change with the key.
-- fill = true: the kit paints an op's own bg only then.
local Segments = {}
P.Segments = Segments

function Segments.layout(props, _, rect, theme)
    local v = {ops = {}, hits = {}, focusables = {}, bindings = {}}
    local items = props.items or {}
    if #items == 0 or rect.width < #items then return v end
    local x = rect.x
    for i, it in ipairs(items) do
        -- even widths, the spare columns spread (38 over 3: 12 13 13)
        local w = math.floor(rect.width * i / #items) - math.floor(rect.width * (i - 1) / #items)
        local on = it[1] == props.active
        local label = Text.ascii(it[2]):sub(1, w)
        local lead = math.floor((w - #label) / 2)
        v.ops[#v.ops + 1] = {x = x, y = rect.y, text = (" "):rep(lead) .. label .. (" "):rep(w - lead - #label),
            fg = on and theme.bg or theme.muted, bg = on and theme.accent or theme.surface, kind = "text", fill = true}
        v.hits[#v.hits + 1] = {id = props.id, rect = {x = x, y = rect.y, width = w, height = 1}, part = it[1]}
        x = x + w
    end
    v.bindings[props.id] = {widget = Segments, props = props}
    return v
end

Segments.handle = Pick.handle

-- The sub-tabs on the page's next row, a blank row under them (owner
-- 2026-11-08: the strip should not touch the rows below).
function P.segments(p, id, items, active)
    local i = P.blank(p)
    p.views[#p.views + 1] = Layout.widget(Segments, {id = id, items = items, active = active},
        {x = p.c.rect.x, y = P.y_of(p, i), width = p.c.rect.width, height = 1}, p.c)
    P.blank(p)
end

-- The kit's App keeps the last two rows of a screen for its footer (a rule
-- and its pager) and a program cannot draw there; our footer is a button
-- row, so the App gets a target two rows taller than the device and those
-- two rows go nowhere. Touches only ever land on the real rows.
function P.tall(dev)
    local row = 1
    local function shown() local _, h = dev.getSize(); return row <= h end
    return setmetatable({
        getSize = function() local w, h = dev.getSize(); return w, h + 2 end,
        setCursorPos = function(x, y) row = y; return dev.setCursorPos(x, y) end,
        write = function(text) if shown() then return dev.write(text) end end,
        blit = function(text, fg, bg) if shown() then return dev.blit(text, fg, bg) end end,
    }, {__index = dev})
end

-- One CC event to the App. On a screen used by touch or click nothing stays
-- marked "> Label <": the kit focuses what a pointer hits and gives focus
-- back to the button that opened a prompt (owner 2026-10-17). Tab on the
-- terminal brings keyboard focus back. An open prompt keeps its focus.
function P.handle(app, name, ...)
    local result, err = app:handle(name, ...)
    if app.closed then return result, err end
    local id = (name == "monitor_touch" or name == "monitor_resize") and (...) or "terminal"
    local s = app.screens[id]
    if not s then return result, err end
    if name == "monitor_touch" or name == "mouse_click" then s.pointer = true
    elseif name == "key" then
        local k = ...
        if k == "tab" or (keys and k == keys.tab) then s.pointer = false end   -- CC sends the key code
    end
    local pg = s.pages[s.active]
    if s.pointer and pg and pg.focus and pg.focus.focusedId and not pg.focus.modalId then
        pg.focus.focusedId = nil; app:render()
    end
    return result, err
end

return P
