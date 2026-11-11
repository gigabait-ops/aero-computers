-- The pocket's tabs, laid out from the teleport, drone and routes models
-- (state = {tp = ..., drone = ..., routes = ...}). Same look as the drone's own screens:
-- a summary first, one touchable line per pad or point, the buttons in the
-- footer. Layout only; the buttons' ids are handled in startup.lua.
local UI = require("ui")
local P = require("pda.kitpage")
local T = require("pda.teleports")
local D = require("pda.drone")
local Rs = require("pda.routes")
local Rows, Text = UI.Rows, UI.Text

local Pages = {}

local seg, add, line, blank = P.seg, P.add, P.line, P.blank

local function dist_text(d)
    if not d then return "--" end
    return d >= 1000 and ("%.1fk"):format(d / 1000) or ("%.0f"):format(d)
end

-- A list, the tab's whole page: no title row (the tab names it; owner
-- 2026-10-18), as many rows as fit, no "3-9 of 12" line (owner 2026-10-23).
-- The mouse wheel scrolls it (m.top, startup.lua); a touched entry scrolled
-- out of view is brought back. Returns the first and last row shown.
local function list_window(p, count, m, sel)
    local room = P.left(p)
    if count == 0 or room >= count then m.top = 1; return 1, count end
    room = math.max(1, room)
    local top = math.max(1, math.min(m.top or 1, count - room + 1))
    if sel and sel < top then top = sel elseif sel and sel > top + room - 1 then top = sel - room + 1 end
    m.top, m.rows = top, room
    return top, math.min(count, top + room - 1)
end

-- The mouse wheel over a list (startup.lua): `dir` rows down (+) or up (-).
function Pages.scroll(m, dir) m.top = math.max(1, (m.top or 1) + dir) end

-- The Drone tab: Status, Points and Routes as sub-tabs on its first row
-- (owner 2026-11-08: one tab, the sub-tabs as one strip). state.dview.
Pages.SUBS = {{"status", "Status"}, {"points", "Points"}, {"routes", "Routes"}}
local function drone_tab(state, context)
    local p = P.page(context)
    P.segments(p, "drone_view", Pages.SUBS, state.dview or "status")
    return p
end

-- Settings: the glasses' own switches, each a touchable row (stored with
-- the CC settings API, on unless set off).
Pages.OPTIONS = {
    {"Chat", {{"pda.chat.fleet", "Crafts"}, {"pda.chat.drone", "Drone"}, {"pda.chat.players", "Players"}}},
    {"Glasses", {{"pda.hud", "HUD"}}},
}
function Pages.on(key)
    local api = rawget(_G, "settings")
    return not (api and api.get(key) == false)
end

local function settings_page(state, context)
    local p = P.page(context)
    local t = p.t
    for n, group in ipairs(Pages.OPTIONS) do
        if n > 1 then blank(p) end
        add(p, Rows.section(group[1], nil, t))
        local rows = {}
        for _, o in ipairs(group[2]) do
            local on = Pages.on(o[1])
            local r = Rows.status(o[2], on and "ON" or "off", on and t.ok or t.muted, t)
            r.key = o[1]
            rows[#rows + 1] = r
        end
        P.pick(p, "set_toggle", rows)
    end
    return P.finish(p)
end

-- Teleports --------------------------------------------------------------------

local function teleports_page(state, context)
    local m = state.tp
    local p = P.page(context)
    local t = p.t
    -- the footer and a warning first: the list below takes the rows they leave
    local sure = m.confirm ~= nil and m.confirm == T.selected(m)
    P.bar(p, {{"tp_go", "GO", t.ok}, {"tp_new", "NEW", t.accent}, {"tp_del", sure and "SURE?" or "DEL", sure and t.bad or t.muted}}, sure and 1 or 2)
    P.notice(p, m.info, t.warn)
    -- the pads at once, each with whether it answers; the last GO shows on
    -- its pad's row for a while (owner 2026-10-18: no summary above)
    local r = T.result(m)
    local first, last = list_window(p, #m.names, m, m.picked and m.sel or nil)
    m.picked = nil
    if #m.names == 0 then
        line(p, t.muted, "none yet: NEW adds one")
    else
        local rows = {}
        local name_w = p.c.rect.width - 2 - 12
        for n = first, last do
            local name = m.names[n]
            local on = n == m.sel
            local chip
            if r and r.name == name and r.recent then
                if r.fired > 0 then chip = Rows.chip(r.fired > 1 and (r.fired .. " fired") or "fired", t.ok, 12)
                elseif r.waiting then chip = Rows.chip("sending", t.info, 12)
                else chip = Rows.chip("no answer", t.warn, 12) end
            else
                local got = T.answered(m, name)
                if got == nil then chip = Rows.chip("asking", t.muted, 12)
                elseif got == 0 then chip = Rows.chip("no answer", t.muted, 12)
                else chip = Rows.chip(got > 1 and (got .. " ready") or "ready", t.ok, 12) end
            end
            rows[#rows + 1] = {key = name, segs = {seg(on and "> " or "  ", t.accent),
                seg(Text.fit(Text.pretty(name), name_w), on and t.text or t.muted), chip}}
        end
        P.pick(p, "tp_list", rows)
    end
    P.prompt(p, m.edit, 32)
    return P.finish(p)
end

-- Drone and Points ----------------------------------------------------------------

-- Buttons laid out the same whatever the power word (a layout that jumped
-- when START turned into MOTORS OFF moved things under the owner's finger):
-- one row when they fit with the short word, the long word only when that
-- fits too; else two rows (a pocket computer).
local function buttons(p, list, power_at, s, extra)
    local room, long, short = p.c.rect.width, s.power or "START", s.power_short or s.power or "START"
    local function need(word, gap)
        local n = 0
        for i, b in ipairs(list) do n = n + #(i == power_at and word or b[2]) + 4 end
        return n + (#list - 1) * gap
    end
    local function with(word)
        local out = {}
        for i, b in ipairs(list) do out[i] = i == power_at and {b[1], word, b[3]} or b end
        return out
    end
    if need("START", 1) <= room then
        P.bars(p, {with(need(long, 1) <= room and long or short), extra}, need("MOTORS OFF", 2) <= room and 2 or 1)
    else
        local all = with(long)
        local half = math.ceil(#all / 2)
        P.bars(p, {{table.unpack(all, 1, half)}, {table.unpack(all, half + 1)}, extra}, 1)
    end
end

-- Not set up / no answer yet: the page says so and stops there.
local function no_drone(p, m)
    local t = p.t
    if not D.configured(m) then
        add(p, Rows.banner("NOT SET UP", t.bad, t)); blank(p)
        line(p, t.muted, "settings drone.master and drone.key")
        return true
    end
    if not m.status then
        add(p, Rows.banner("NO LINK", t.bad, t)); blank(p)
        line(p, t.muted, "the drone does not answer yet")
        return true
    end
    return false
end

-- DRONE: what it does, how high and fast, the link, what happened lately;
-- the buttons, GOTO typing coordinates for a one-off flight.
local function drone_page(state, context)
    local m = state.drone
    local p = drone_tab(state, context)
    local t = p.t
    if no_drone(p, m) then return P.finish(p) end
    local s = m.status
    local link, age = D.link(m)
    local wide = p.c.rect.width >= 34
    -- the row under them: face a side of the world (owner 2026-10-24)
    buttons(p, {{"go_to", "GOTO", t.accent}, {"power", "", t[s.power_color or "ok"] or t.ok},
        {"stop", "STOP", t.warn}, {"hold", "HOLD", t.ok}}, 2, s,
        {{"face_n", "N", t.accent}, {"face_e", "E", t.accent}, {"face_s", "S", t.accent}, {"face_w", "W", t.accent}})
    local hud_err = state.hud and state.hud.err
    P.notice(p, s.warn or (hud_err and ("HUD: " .. hud_err)))
    local act_color = t[s.activity_color or "accent"] or t.accent
    add(p, Rows.banner(s.activity or tostring(s.mode), act_color, t, wide and s.detail or nil))
    if not wide then line(p, t.muted, s.detail or "") end
    -- the gap only where the news still fits under it (glasses: the sub-tabs took a row)
    if P.left(p) >= 7 then blank(p) end
    local up = s.above and (", %d up"):format(math.max(0, s.above)) or ""
    add(p, Rows.status("Height", s.height and (s.height .. up) or "--", t.info, t))
    add(p, Rows.status("Speed", s.speed and (s.speed .. " b/s") or "--", t.info, t))
    local lost = link ~= "ok"
    add(p, Rows.status("Link", lost and ("no answer " .. Text.age(age)) or "ok", lost and t.bad or t.ok, t))
    -- the HUD's key hint (numpad 8 on any keyboard, or a touch here; the keys fly the drone either way)
    local on = s.keys_on == true
    local krow = Rows.status("Hint", on and "ON" or "off", on and t.ok or t.muted, t)
    krow.key = "toggle"
    if on then krow.segs[3].fg = t.ok end
    P.pick(p, "keys_toggle", {krow})
    -- what happened lately, as many as there is room for
    -- (tight: no gap above the section, so the newest still shows)
    local left = P.left(p)
    if left >= 2 and s.recent and #s.recent > 0 then
        if left >= 4 then blank(p); left = left - 1 end
        add(p, Rows.section("Recent", nil, t))
        for i = 1, math.min(left - 1, #s.recent) do
            local e = s.recent[i]
            add(p, {segs = {seg(P.DOT .. " ", t[e[1]] or t.muted), seg(e[2], t.text)}})
        end
    end
    P.prompt(p, m.edit, 32)
    return P.finish(p)
end

-- POINTS: every saved point (the wheel scrolls), FLY to the picked one.
local function points_page(state, context)
    local m = state.drone
    local p = drone_tab(state, context)
    local t = p.t
    if no_drone(p, m) then return P.finish(p) end
    local s = m.status
    -- one row on the glasses, two on a pocket computer
    local all = {{"fly", "FLY", t.ok}, {"wp_new", "NEW", t.accent}, {"wp_edit", "EDIT", t.accent}, {"stop", "STOP", t.warn}}
    if 7 + 7 + 8 + 8 + 3 * 2 <= p.c.rect.width then P.bar(p, all) else P.bars(p, {{all[1], all[2]}, {all[3], all[4]}}) end
    -- the first row calls the drone to where the owner stands (+30), then the saved points
    local points = {{name = D.TO_ME, to_me = true}}
    for _, pt in ipairs(s.points or {}) do points[#points + 1] = pt end
    local sel = 1
    for i, pt in ipairs(points) do
        if pt.name == m.sel then sel = i end
    end
    local first, last = list_window(p, #points, m, m.picked and sel or nil)
    m.picked = nil
    local here = state.hud and require("pda.hud").feet(state.hud)
    local rows = {}
    local name_w = p.c.rect.width - 2 - 6
    for n = first, last do
        local pt = points[n]
        local on = n == sel
        if pt.to_me then
            -- its own look: blue, the height above you, how far the drone is from you
            local d
            if here and s.pos and s.pos.x then d = math.sqrt((here.x - s.pos.x) ^ 2 + (here.z - s.pos.z) ^ 2) end
            local tag = (" (+%d)"):format(D.ABOVE)
            rows[#rows + 1] = {key = D.TO_ME, segs = {seg(on and "> " or "  ", t.accent), seg("To me", t.info), seg(tag, t.info),
                seg(string.rep(" ", name_w - 5 - #tag), t.text), seg(Text.fit(dist_text(d), 6, true), t.muted)}}
        else
            local flying = s.target == pt.name
            local tag = pt.dock and " (dock)" or ""
            local name = Text.fit(pt.name, name_w - #tag):gsub("%s+$", "")
            rows[#rows + 1] = {key = pt.name, segs = {seg(on and "> " or "  ", t.accent),
                seg(name, flying and t.info or (on and t.text or t.muted)), seg(tag, t.extra),
                seg(string.rep(" ", name_w - #name - #tag), t.text), seg(Text.fit(dist_text(pt.dist), 6, true), t.muted)}}
        end
    end
    P.pick(p, "wp_list", rows)
    P.prompt(p, m.edit, 40)
    return P.finish(p)
end

-- Routes ------------------------------------------------------------------------

local LAPS = function(n) return n == 0 and "loop" or (n == 1 and "once" or ("x" .. n)) end

-- The routes: each with its points and what comes after (the one flying:
-- how far it is); FLY from the first point, OPEN, NEW, DEL.
local function route_list(p, m, s)
    local t, w = p.t, p.c.rect.width
    local sure = Rs.sure(m)
    local all = {{"rt_fly", "FLY", t.ok}, {"rt_open", "OPEN", t.accent}, {"rt_new", "NEW", t.accent},
        {"rt_del", sure and "SURE?" or "DEL", sure and t.bad or t.muted}}
    if 7 + 8 + 7 + 9 + 3 * 2 <= w then P.bar(p, all) else P.bars(p, {{all[1], all[2]}, {all[3], all[4]}}) end
    P.notice(p, s.warn)
    local list, fl = Rs.list(m), Rs.flying(m)
    if #list == 0 then line(p, t.muted, "none yet: NEW adds one"); return end
    local sel = 1
    for i, r in ipairs(list) do if r.name == m.sel then sel = i end end
    local first, last = list_window(p, #list, m, m.picked and sel or nil)
    m.picked = nil
    local tail_w = w >= 34 and 17 or 10
    local name_w = w - 2 - 7 - tail_w
    local rows = {}
    for n = first, last do
        local r = list[n]
        local on, flying = n == sel, fl and fl.name == r.name
        local tail = flying and ("flying %d/%d"):format(fl.i, r.n) or r.tail
        rows[#rows + 1] = {key = r.name, segs = {seg(on and "> " or "  ", t.accent),
            seg(Text.fit(r.name, name_w), flying and t.info or (on and t.text or t.muted)),
            seg(Text.fit(r.n .. (r.n == 1 and " pt" or " pts"), 7), t.muted),
            seg(Text.fit(tail, tail_w, true), (flying or r.tail == "loop") and t.info or t.extra)}}
    end
    P.pick(p, "rt_list", rows)
end

-- A route open: its name (touch: back to the list), laps and what comes
-- after; its points with what each does (the one the drone flies to in its
-- own colour); FLY from the picked point, NEW after it, EDIT its line, DEL,
-- the arrows move it, < back. A point's height, speed, wait and act are
-- typed in its line (h180 s100 w30 pass|land|dock).
local function route_open(p, m, s)
    local t, w = p.t, p.c.rect.width
    local sure = Rs.sure(m)
    local wide = 7 + 7 + 8 + 9 + 3 * 2 <= w
    local del = {"rt_del", sure and "SURE?" or "DEL", sure and t.bad or t.muted}
    local fly, new, edit = {"rt_fly", "FLY", t.ok}, {"pt_new", "NEW", t.accent}, {"pt_edit", "EDIT", t.accent}
    local back, up, down = {"rt_back", "< BACK", t.warn}, {"pt_up", "^", t.accent}, {"pt_down", "v", t.accent}
    -- BACK at the bottom with the arrows, as on the master's screen; a pocket
    -- computer: DEL on a row of its own (SURE? fits there, nothing moves)
    if wide then P.bars(p, {{fly, new, edit, del}, {back, up, down}})
    else P.bars(p, {{fly, new, edit}, {back, up, down}, {del}}, 1) end
    P.notice(p, s.warn)
    local o = Rs.opened(m)
    if not o then line(p, t.muted, "asking the drone..."); return end
    local fl = Rs.flying(m)
    fl = fl and fl.name == o.name and fl or nil
    -- the header: the name (touch it: back too), then the laps and what
    -- comes after (no "Laps" and "then" words on a pocket computer)
    local x = p.c.rect.x
    local y = P.y_of(p, blank(p))
    -- too narrow for the laps and what comes after on one row (a pocket
    -- computer): what comes after goes to the right of the name
    local fin, fin_color = o.finish:upper(), o.laps == 0 and t.muted or t.extra
    local fin_up = not wide and 5 + 1 + 4 + 1 + 5 + 1 + #fin + 4 > w
    local name_w = fin_up and w - #fin - 5 or w
    P.widget(p, P.Pick, {id = "rt_title", rows = {{key = "back", segs = {seg(Text.fit(o.name, name_w), fl and t.info or t.text)}}}}, x, y, name_w)
    if fin_up then P.button(p, "rt_finish", fin, fin_color, x + w - #fin - 4, y) end
    local y2 = P.y_of(p, blank(p))
    local lx = x
    if wide then P.widget(p, P.Pick, {id = "rt_laps_lbl", rows = {{segs = {seg("Laps", t.muted)}}}}, lx, y2, 5); lx = lx + 5 end
    local bx = P.button(p, "rt_laps_dec", "-", t.accent, lx, y2)
    P.widget(p, P.Pick, {id = "rt_laps", rows = {{segs = {seg(Text.fit(LAPS(o.laps), 4, true), o.laps == 0 and t.info or t.text)}}}}, bx + 1, y2, 4)
    bx = P.button(p, "rt_laps_inc", "+", t.accent, bx + 6, y2)
    if wide then P.widget(p, P.Pick, {id = "rt_then", rows = {{segs = {seg(" then", t.muted)}}}}, bx, y2, 5); bx = bx + 5 end
    if not fin_up then P.button(p, "rt_finish", fin, fin_color, bx + 1, y2) end
    if P.left(p) > 6 then blank(p) end   -- a gap before the points where there is room
    local pts = o.points
    if #pts == 0 then line(p, t.muted, "no points: NEW adds one"); return end
    local first, last = list_window(p, #pts, m, m.picked and m.pt or nil)
    m.picked = nil
    local sum_w = math.max(0, math.min(22, w - 2 - 3 - 8))
    local pname_w = w - 2 - 3 - sum_w
    local rows = {}
    for n = first, last do
        local pt = pts[n]
        local on, next_one = n == m.pt, fl and fl.i == n
        rows[#rows + 1] = {key = n, segs = {seg(on and "> " or "  ", t.accent), seg(Text.fit(tostring(n), 2, true) .. " ", t.muted),
            seg(Text.fit(pt.name, pname_w), next_one and t.info or (on and t.text or t.muted)), seg(Text.fit(pt.summary, sum_w, true), t.extra)}}
    end
    P.pick(p, "pt_list", rows)
end

local function routes_page(state, context)
    local m = state.routes
    local p = drone_tab(state, context)
    if no_drone(p, m.d) then return P.finish(p) end
    if m.open then route_open(p, m, m.d.status) else route_list(p, m, m.d.status) end
    P.prompt(p, m.edit, 60)
    return P.finish(p)
end

-- The button style the drone's owner picked (its SETTINGS; the status says which).
local function styled(f)
    return function(state, c)
        P.style(state.drone and state.drone.status and state.drone.status.buttons)
        return f(state, c)
    end
end

local SUB_PAGES = {points = points_page, routes = routes_page}

-- The tabs; `extra` (the Mine tab) goes before Settings.
function Pages.list(extra)
    local l = {
        {name = "Teleports", page = styled(function(state, c) return teleports_page(state, c) end)},
        {name = "Drone", page = styled(function(state, c) return (SUB_PAGES[state.dview] or drone_page)(state, c) end)},
    }
    for _, pg in ipairs(extra or {}) do l[#l + 1] = pg end
    l[#l + 1] = {name = "Settings", page = styled(function(state, c) return settings_page(state, c) end)}
    return l
end

return Pages
