-- The pilot's screens on the shared CC UI kit (`require("ui")`, shipped in
-- the Tensa Aeronautics ROM). The kit's App owns the terminal and every
-- monitor: tabs, footer, palette, touch and keys; a monitor follows the
-- terminal's tab. These pages only lay out what E.view(ctx) says, and
-- S.on_action turns the kit's actions into E.action names. Layout is pure:
-- no peripherals, no business changes (those happen in E.action).
--
-- Design: each page reads top-down; the footer is ours: a rule and the
-- page's buttons on the last row (the kit's own footer, scroll hints and
-- [ up ] [ down ], is hidden by S.tall), a warning on the row above the
-- rule; Waypoints adds ^ / v to its buttons (owner 2026-10-17). Points are
-- one line each with the dock tag next to the name.
local UI = require("ui")
local P = require("fc.ui.kitpage")
local V = require("fc.ui.view")
local Rows, Controls, Text = UI.Rows, UI.Controls, UI.Text

local S = {}

local DOT, num, seg = P.DOT, P.num, P.seg
local page, add, blank, line, y_of, left = P.page, P.add, P.blank, P.line, P.y_of, P.left
local widget, button, bar, finish, narrow = P.widget, P.button, P.bar, P.finish, P.narrow

-- Status -------------------------------------------------------------------------

local function speed_target(view)
    if view.nav and view.nav.v_des and view.nav.v_des < 1e8 then return view.nav.v_des end
    if view.man and view.mode == "ARMED" and not view.task then return view.man.v_f end
    return nil
end

-- "Legs [ DOWN ]   Engine [ ON ]": a touch switches it; legs set by hand
-- go back to automatic by themselves when the motors start or stop.
local function links_row(p, view, small)
    local l, t = view.links or {}, p.t
    if not l.bridge then
        if not small then add(p, {segs = {seg(DOT .. " ", t.muted), seg(Text.fit("Links", 9), t.muted), seg("no link bridge", t.muted)}}) end
        return
    end
    local i = blank(p)
    local y = y_of(p, i)
    -- small screens: no dots, short words (29 columns: "Legs [ DOWN ] Eng [ OFF ]")
    local legs_w, eng_w, dot_w = small and 5 or 9, small and 4 or 9, small and 0 or 2
    local legs_c, eng_c = l.gear and t.warn or t.ok, l.clutch and t.bad or t.ok
    local x0 = p.c.rect.x
    local segs = {}
    if not small then segs[1] = seg(DOT .. " ", legs_c) end
    segs[#segs + 1] = seg(Text.fit("Legs", legs_w), t.muted)
    local x = button(p, "link_gear", l.gear and "DOWN" or "UP", legs_c, x0 + dot_w + legs_w, y)
    local gap = small and 1 or 4
    segs[#segs + 1] = seg(string.rep(" ", x - x0 - dot_w - legs_w + gap), t.muted)
    if not small then segs[#segs + 1] = seg(DOT .. " ", eng_c) end
    segs[#segs + 1] = seg(Text.fit(small and "Eng" or "Engine", eng_w), t.muted)
    button(p, "link_clutch", l.clutch and "OFF" or "ON", eng_c, x + gap + dot_w + eng_w, y)
    p.rows[i] = {segs = segs}
end

local function status_page(E, ctx, context)
    local view = E.view(ctx)
    local p = page(context)
    local t, small = p.t, narrow(context)
    local act = view.activity or tostring(view.mode)
    local act_color = t[E.ACT_COLOR[act] or "accent"] or t.accent
    if small then
        add(p, Rows.banner(act, act_color, t))
        line(p, t.muted, view.detail or "")
    else
        add(p, Rows.banner(act, act_color, t, view.detail))
    end
    if view.next_step then line(p, t.muted, view.next_step) end   -- a route: what comes after this point
    if not small then add(p, Rows.section("Flight", nil, t)) end
    local st = view.state
    local vt = speed_target(view)
    if st then
        local tgt = vt and (vt >= 300 and "max" or num(vt, "%.0f"))
        local above = view.above and ("%.0f%s"):format(math.max(0, view.above), small and " up" or " above the ground") or ""
        if small then
            add(p, {segs = {seg(DOT .. " ", t.info), seg(Text.fit("Speed", 7), t.muted), seg(Text.fit(num(st.speed, "%.0f"), 5), t.text),
                seg(tgt and ("b/s > " .. tgt) or "b/s", t.muted)}})
            add(p, {segs = {seg(DOT .. " ", t.info), seg(Text.fit("Height", 7), t.muted), seg(Text.fit(num(st.pos.y, "%.0f"), 5), t.text), seg(above, t.muted)}})
        else
            local smax = (view.speed_max and view.speed_max > 0) and view.speed_max or 150
            local lit, dim = Rows.bar(st.speed, smax, 10, t.info, t)
            add(p, {segs = {seg(DOT .. " ", t.info), seg(Text.fit("Speed", 9), t.muted), seg(Text.fit(num(st.speed, "%.0f") .. " b/s", 10), t.text),
                lit, dim, seg(tgt and ("  target " .. tgt) or "", t.muted)}})
            add(p, {segs = {seg(DOT .. " ", t.info), seg(Text.fit("Height", 9), t.muted), seg(Text.fit(num(st.pos.y, "%.0f"), 10), t.text), seg(above, t.muted)}})
        end
    else
        add(p, {segs = {seg(DOT .. " ", t.bad), seg(Text.fit("Sensor", 9), t.muted), seg(tostring(view.err or "lost"), t.bad)}})
    end
    if not small then
        add(p, Rows.section("Ship", nil, t))
        local ok, total, lost = V.motors_ok(view)
        local pw = view.power
        add(p, {segs = {seg(DOT .. " ", ok == total and t.ok or t.bad), seg(Text.fit("Motors", 9), t.muted),
            seg(Text.fit(ok == total and ("all %d working"):format(total) or ("%d not answering: %s"):format(total - ok, table.concat(lost, " ")), 22),
                ok == total and t.text or t.bad),
            seg(pw and (pw.over and "power OVERSTRESSED" or ("power %s/%s"):format(num(pw.su, "%.0f"), num(pw.cap, "%.0f"))) or "",
                pw and pw.over and t.bad or t.muted)}})
    end
    links_row(p, view, small)
    if not small then
        -- what happened lately (newest first); a warning goes on top
        add(p, Rows.section("Recent", nil, t))
        local items = {}
        if view.warn then items[#items + 1] = {t.bad, tostring(view.warn)} end
        for _, e in ipairs(view.recent or {}) do items[#items + 1] = {t[e[1]] or t.text, e[2]} end
        if #items == 0 then line(p, t.muted, "nothing yet") end
        for i = 1, math.min(2, #items) do add(p, {segs = {seg(DOT .. " ", items[i][1]), seg(items[i][2], items[i][1] == t.bad and t.bad or t.text)}}) end
    end
    local word, color = E.power_label(view, small)
    -- GOTO: coordinates to fly to once (not saved), typed in a prompt
    local buttons = {{"power", word, t[color]}, {"stop", "STOP", t.warn}, {"hold", "HOLD", t.ok}}
    if P.keyboard(context) then buttons[#buttons + 1] = {"go_to", "GOTO", t.accent} end   -- typed: not on a monitor
    -- under them: face a side of the world (owner 2026-10-24)
    local sides = {{"face_n", "N", t.accent}, {"face_e", "E", t.accent}, {"face_s", "S", t.accent}, {"face_w", "W", t.accent}}
    P.bars(p, {buttons, sides}, small and 1 or 3)
    P.prompt(p, view.edit)
    return finish(p)
end

-- Waypoints ------------------------------------------------------------------------

local function dist_text(d)
    if not d then return "--" end
    return d >= 1000 and ("%.1fk"):format(d / 1000) or ("%.0f"):format(d)
end

local function waypoints_page(E, ctx, context)
    local view = E.view(ctx)
    local p = page(context)
    local t, small = p.t, narrow(context)
    local list = view.waypoints or {}
    P.notice(p, view.warn)   -- before the list: it takes the rows left
    -- no "Points" title: the tab names the list (owner 2026-10-18)
    local name_w = small and 20 or 22        -- the name and its dock tag (marker 2 + 22 + 18 + 6 = 48 of 49)
    local pos_w = small and 0 or 18
    if #list == 0 then
        line(p, t.muted, not P.keyboard(context) and "none yet: NEW at the computer" or
            (small and "none yet: NEW saves one" or "No points yet: NEW types one (a name alone saves this spot)"))
    else
        if not small then
            add(p, {segs = {seg("  " .. Text.fit("Point", name_w) .. Text.fit("Position", pos_w) .. Text.fit("Dist", 6, true), t.muted)}})
        end
        -- as many lines as fit above a blank, the buttons and a notice;
        -- with more points the window follows the selected one
        local room = math.max(1, left(p))   -- no "1-9 of 12" line (owner 2026-10-23)
        local total = #list
        local sel = math.max(1, math.min(view.wp_sel or 1, #list))
        local first = math.max(1, math.min(sel - math.floor(room / 2), total - room + 1))
        local rows = {}
        for n = first, math.min(total, first + room - 1) do
            local wp = list[n]
            local on = n == sel
            local flying = view.task and view.task.name == wp.name
            local color = flying and t.info or (wp.home and t.warn or t.text)
            local tag = wp.hdg and " (dock)" or ""
            local name = Text.fit(wp.name, name_w - #tag):gsub("%s+$", "")
            local segs = {seg(on and "> " or "  ", t.accent), seg(name, on and t.text or color), seg(tag, t.extra),
                seg(string.rep(" ", name_w - #name - #tag), t.text)}
            if not small then segs[#segs + 1] = seg(Text.fit(("%s %s %s"):format(num(wp.x, "%.0f"), num(wp.y, "%.0f"), num(wp.z, "%.0f")), pos_w), t.muted) end
            segs[#segs + 1] = seg(Text.fit(dist_text(wp.dist), small and 5 or 6, true), t.muted)
            rows[#rows + 1] = {key = wp.name, segs = segs}
        end
        P.pick(p, "wp_list", rows)
    end
    -- one row of buttons (two rows looked bad)
    local sure = view.confirm and view.confirm.action == "wp_delete"
    local del = {"wp_delete", sure and "SURE?" or "DEL", sure and t.bad or t.muted}
    local up, down = {"wp_up", "^", t.accent}, {"wp_down", "v", t.accent}
    -- no HERE: NEW with a name alone saves this spot (owner); NEW and EDIT
    -- (the saved line in the prompt) are typed: on the computer, not a monitor
    local list = {{"wp_fly", "FLY", t.ok}}
    if P.keyboard(context) then
        list[#list + 1] = {"wp_new", "NEW", t.accent}
        if not small then list[#list + 1] = {"wp_edit", "EDIT", t.accent} end
    end
    for _, b in ipairs({del, up, down}) do list[#list + 1] = b end
    bar(p, list, (small or sure) and 1 or 2)
    P.prompt(p, view.edit)
    return finish(p)
end

-- Settings --------------------------------------------------------------------------

local function settings_page(E, ctx, context)
    local view = E.view(ctx)
    local p = page(context)
    local t, small = p.t, narrow(context)
    -- only the settings and RESET: no explanations (owner: little English, little text)
    blank(p)
    local sel = view.set_sel or 1
    local label_w = small and 0 or 18   -- small screens: the name on its own row above the controls
    for n, s in ipairs(view.settings or {}) do
        if n > 1 and not small then blank(p) end   -- room between rows of buttons for a finger
        if small then line(p, n == sel and t.text or t.muted, s.label) end
        local i = blank(p)
        local y = y_of(p, i)
        if not small then p.rows[i] = {segs = {seg(Text.fit(s.label, label_w), n == sel and t.text or t.muted)}} end
        local x = button(p, "set_dec:" .. n, "-", t.accent, p.c.rect.x + label_w, y)
        local value = Text.fit(s.value, 9, true)
        if P.keyboard(context) then   -- touching the value types a new one: at the computer only
            x = widget(p, Controls.link, {id = "set_edit:" .. n, label = value}, x + 1, y, 9, n == sel and t.warn or t.text)
        else   -- the value as plain text where the link would be
            x = widget(p, P.Pick, {id = "set_value:" .. n, rows = {{segs = {seg(value, n == sel and t.warn or t.text)}}}}, x + 1, y, 9)
        end
        button(p, "set_inc:" .. n, "+", t.accent, x + 1, y)
    end
    local sure = view.confirm and view.confirm.action == "reset"
    bar(p, {{"reset", sure and "SURE?" or "RESET", sure and t.bad or t.warn}})
    P.notice(p, view.warn)
    P.prompt(p, view.edit)
    return finish(p)
end

-- Routes --------------------------------------------------------------------------------
-- The list, or one route's page (view.route_open): its own row (back, laps,
-- what comes after), its points, the picked point's height / speed / wait /
-- act by touch, and the buttons. Typing (NEW, EDIT) only where there is a
-- keyboard (owner rule: monitors are touch only).

local function route_list(E, view, p, context, small)
    local t = p.t
    local list = view.routes or {}
    P.notice(p, view.warn)
    if #list == 0 then
        line(p, t.muted, P.keyboard(context) and "No routes yet: NEW makes one" or "none yet: NEW at the computer")
    else
        local sel = math.max(1, math.min(view.route_sel or 1, #list))
        local name_w = small and 13 or 20
        local tail_w = math.max(6, p.c.rect.width - 2 - name_w - 8)
        local rows = {}
        for n, r in ipairs(list) do
            local on = n == sel
            rows[#rows + 1] = {key = tostring(n), segs = {seg(on and "> " or "  ", t.accent),
                seg(Text.fit(r.name, name_w), r.flying and t.info or (on and t.text or t.muted)),
                seg(Text.fit(r.n .. (r.n == 1 and " pt" or " pts"), 8), t.muted), seg(Text.fit(r.tail, tail_w, true), r.laps == 0 and t.info or t.extra)}}
        end
        P.pick(p, "route_list", rows)
    end
    local sure = view.confirm and view.confirm.action == "route_delete"
    local b = {{"route_fly", "FLY", t.ok}, {"route_open", "OPEN", t.accent}}
    if P.keyboard(context) then b[#b + 1] = {"route_new", "NEW", t.accent} end
    b[#b + 1] = {"route_delete", sure and "SURE?" or "DEL", sure and t.bad or t.muted}
    bar(p, b, small and 1 or 2)
end

local LAPS = function(n) return n == 0 and "loop" or (n == 1 and "once" or ("x" .. n)) end

local function point_controls(p, pt, y, x0, step)
    local y2 = y + (step or 1)
    local t = p.t
    -- two columns of 24: a label of 7, [ - ], a value of 4, [ + ]
    local function ctl(label, field, value, x, yy)
        widget(p, P.Pick, {id = "lbl_" .. field, rows = {{segs = {seg(Text.fit(label, 7), t.muted)}}}}, x, yy, 7)
        local bx = button(p, "point_" .. field .. "_dec", "-", t.accent, x + 7, yy)
        widget(p, P.Pick, {id = "val_" .. field, rows = {{segs = {seg(Text.fit(value, 4, true), t.warn)}}}}, bx + 1, yy, 4)
        return button(p, "point_" .. field .. "_inc", "+", t.accent, bx + 6, yy)
    end
    ctl("Height", "height", pt.height and num(pt.height, "%.0f") or "--", x0 + 1, y)
    ctl("Speed", "speed", pt.speed and num(pt.speed, "%.0f") or "--", x0 + 25, y)
    ctl("Wait", "wait", (pt.wait and pt.wait > 0) and (num(pt.wait, "%.0f") .. "s") or "--", x0 + 1, y2)
    widget(p, P.Pick, {id = "lbl_act", rows = {{segs = {seg(Text.fit("At it", 7), t.muted)}}}}, x0 + 25, y2, 7)
    button(p, "point_act", (pt.act or "stop"):upper(), pt.act == "stop" and t.muted or t.extra, x0 + 32, y2)
end

local function route_page(E, view, p, context, small)
    local t = p.t
    local ro = view.route_open
    -- the header: the route's name, then the laps and what comes after the
    -- last lap (on the same row when it fits), then a gap; BACK is at the
    -- bottom with the arrows, as on the glasses (owner 2026-10-23)
    local w = p.c.rect.width
    local laps_w = small and 25 or 35
    local one_row = w >= 12 + 1 + laps_w
    local y = y_of(p, blank(p))
    local name_w = one_row and 12 or math.min(w, 24)
    widget(p, P.Pick, {id = "route_title", rows = {{segs = {seg(Text.fit(ro.name, name_w), t.text)}}}}, p.c.rect.x, y, name_w)
    local row2, lx = y, p.c.rect.x + name_w + 1
    if not one_row then row2, lx = y_of(p, blank(p)), p.c.rect.x end
    if not small then widget(p, P.Pick, {id = "route_laps_lbl", rows = {{segs = {seg("Laps", t.muted)}}}}, lx, row2, 5); lx = lx + 5 end
    local bx = button(p, "route_laps_dec", "-", t.accent, lx, row2)
    widget(p, P.Pick, {id = "route_laps", rows = {{segs = {seg(Text.fit(LAPS(ro.laps), 4, true), ro.laps == 0 and t.info or t.text)}}}}, bx + 1, row2, 4)
    bx = button(p, "route_laps_inc", "+", t.accent, bx + 6, row2)
    if not small then widget(p, P.Pick, {id = "route_then", rows = {{segs = {seg(" then", t.muted)}}}}, bx, row2, 5); bx = bx + 5 end
    button(p, "route_finish", (ro.finish or "hold"):upper(), ro.laps == 0 and t.muted or t.extra, bx + 1, row2)
    if not small then blank(p) end   -- the header apart from the points
    local sure = view.confirm and view.confirm.action == "point_delete"
    local b = {{"route_fly", "FLY", t.ok}}
    if P.keyboard(context) then b[#b + 1] = {"point_new", "NEW", t.accent}; b[#b + 1] = {"point_edit", "EDIT", t.accent} end
    b[#b + 1] = {"point_delete", sure and "SURE?" or "DEL", sure and t.bad or t.muted}
    P.bars(p, {b, {{"route_back", "< BACK", t.warn}, {"point_up", "^", t.accent}, {"point_down", "v", t.accent}}}, 1)
    P.notice(p, view.warn)
    local pts = ro.points
    local controls = not small and #pts > 0
    if #pts == 0 then
        line(p, t.muted, P.keyboard(context) and "No points yet: NEW adds one (a name alone = here or a saved point)" or "no points yet: NEW at the computer")
    else
        local room = math.max(1, left(p) - (controls and (2 + P.row_step()) or 0))
        local sel = ro.sel
        local first = math.max(1, math.min(sel - math.floor(room / 2), #pts - room + 1))
        local rows = {}
        local flying = view.flying_route and view.flying_route.name == ro.name and view.flying_route.i
        for n = first, math.min(#pts, first + room - 1) do
            local pt = pts[n]
            local on = n == sel
            local color = n == flying and t.info or (on and t.text or (pt.act == "dock" and t.warn or t.muted))
            local name_w, pos_w = small and 11 or 13, small and 0 or 14
            local segs = {seg(on and "> " or "  ", t.accent), seg(Text.fit(n .. " " .. pt.name, name_w), color)}
            if not small then segs[#segs + 1] = seg(Text.fit(("%s %s %s"):format(num(pt.x, "%.0f"), num(pt.y, "%.0f"), num(pt.z, "%.0f")), pos_w), t.muted) end
            segs[#segs + 1] = seg(Text.fit(pt.summary, math.max(6, p.c.rect.width - 2 - name_w - pos_w)), t.extra)
            rows[#rows + 1] = {key = tostring(n), segs = segs}
        end
        P.pick(p, "point_list", rows)
        if controls then
            -- the picked point's settings sit at the bottom, just above the buttons (owner 2026-10-23)
            local step = P.row_step()   -- filled buttons: a blank row between the two rows
            while left(p) > 1 + step do blank(p) end
            local yy = y_of(p, blank(p))
            for _ = 1, step do blank(p) end
            point_controls(p, pts[sel], yy, p.c.rect.x, step)
        end
    end
end

local function routes_page(E, ctx, context)
    local view = E.view(ctx)
    local p = page(context)
    local small = narrow(context)
    if view.route_open then route_page(E, view, p, context, small) else route_list(E, view, p, context, small) end
    P.prompt(p, view.edit)
    return finish(p)
end

-- App wiring ---------------------------------------------------------------------------

-- The button style the owner picked (SETTINGS "Buttons"; the App's theme follows, S.apply_style).
local function styled(f)
    return function(ctx, c) P.style(ctx.cfg.ui and ctx.cfg.ui.buttons); return f(ctx, c) end
end

function S.pages(E)
    return {
        {name = "Status", page = styled(function(ctx, c) return status_page(E, ctx, c) end)},
        {name = "Waypoints", page = styled(function(ctx, c) return waypoints_page(E, ctx, c) end)},
        {name = "Routes", page = styled(function(ctx, c) return routes_page(E, ctx, c) end)},
        {name = "Settings", page = styled(function(ctx, c) return settings_page(E, ctx, c) end)},
    }
end

S.apply_style = P.apply_style

-- The kit's actions -> E.action names (button ids are the action names).
function S.on_action(E)
    return function(action, ctx)
        local id = tostring(action.id or "")
        if id == "wp_list" then
            if action.type == "change" then
                for n, wp in ipairs(E.waypoints(ctx)) do
                    if wp.name == action.value then E.action(ctx, "wp_pick:" .. n) end
                end
            end
        elseif id == "route_list" or id == "point_list" then
            if action.type == "change" then E.action(ctx, (id == "route_list" and "route_pick:" or "point_pick:") .. tostring(action.value)) end
        elseif id == "route_title" then
            if action.type == "change" or action.type == "activate" then E.action(ctx, "route_back") end
        elseif id:match("^edit%d*$") then
            if action.type == "submit" then E.edit_submit(ctx, action.value)
            elseif action.type == "cancel" then ctx.edit = nil end
        elseif action.type == "activate" then
            E.action(ctx, id)
        end
    end
end

-- The App's device adapter and event entry (fc.lua and the tests use them).
S.tall, S.handle = P.tall, P.handle

return S
