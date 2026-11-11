-- The screens' buttons (and the glasses' commands) by name, and typed
-- input: a new waypoint, a point's line to edit, coordinates to fly to once,
-- a setting's value.
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local Cx = require("fc.core.ctx")
local U = require("fc.core.util")
local R = require("fc.hw.rlinks")
local W = require("fc.data.waypoints")
local St = require("fc.data.settings")
local Rt = require("fc.data.routes")
local Ro = require("fc.flight.route")
local Op = require("fc.cmd.operator")
local Ky = require("fc.ui.keys")

local Ac = {}

-- "x z" or "x y z" (commas allowed) -> x, y (or nil), z; nil when not that.
function Ac.parse_coords(text)
    local n = {}
    for w in tostring(text or ""):gsub(",", " "):gmatch("%S+") do
        local v = tonumber(w)
        if not (v and v == v and math.abs(v) < 3e7) then return nil end
        n[#n + 1] = v
    end
    if #n == 2 then return n[1], nil, n[2] end
    if #n == 3 then return n[1], n[2], n[3] end
    return nil
end

-- Typed input ------------------------------------------------------------------

function Ac.edit_begin(ctx, kind, index)
    local prompt, value, title
    if kind == "waypoint" then
        prompt = "Name [x y z [hdg]]: a name alone = here + heading"
    elseif kind == "goto" then
        prompt = "x z  or  x y z: fly there once (not saved)"
    elseif kind == "waypoint_edit" then
        local wp = W.list(ctx)[index]
        if not wp then ctx.notice = "no waypoint selected"; return false end
        prompt, value, title = "Name x y z [hdg]", W.text(wp), "Edit " .. wp.name
    elseif kind == "route" then
        prompt, title = "Its name", "New route"
    elseif kind == "route_point" or kind == "route_point_edit" then
        local r = ctx.route_open and Rt.get(ctx, ctx.route_open)
        if not r then ctx.notice = "no route open"; return false end
        prompt = "Name [x y z [hdg]] h180 s100 w30 pass|land|dock"
        if kind == "route_point_edit" then
            local pt = r.points[index]
            if not pt then ctx.notice = "no point selected"; return false end
            value, title = Rt.point_text(pt), ("Point %d"):format(index)
        else
            title = "New point"
        end
    else
        local spec = St.SETTINGS[index]
        if not spec then return false end
        if spec.choices then prompt = spec.label .. ": " .. table.concat(spec.choices, " ")
        else
            prompt = ("%s (%s..%s %s%s): type, Enter"):format(spec.label, tostring(spec.min), tostring(spec.max), spec.unit,
                spec.zero and (", 0 = " .. spec.zero) or "")
        end
    end
    ctx.edit_n = (ctx.edit_n or 0) + 1   -- a fresh prompt each time (screens.lua)
    ctx.edit = {kind = kind, index = index, buffer = "", prompt = prompt, n = ctx.edit_n, value = value,
        title = title or kind == "waypoint" and "New point" or kind == "goto" and "Go to" or St.SETTINGS[index].label}
    return true
end

function Ac.edit_commit(ctx)
    local ed = ctx.edit
    ctx.edit = nil
    if not ed then return false end
    if ed.kind == "waypoint" then
        local words = U.words(ed.buffer)
        if not words then return false end
        return W.add(ctx, words[1], words[2], words[3], words[4], words[5])
    elseif ed.kind == "waypoint_edit" then
        return W.edit_text(ctx, ed.index, ed.buffer)
    elseif ed.kind == "goto" then
        local x, y, z = Ac.parse_coords(ed.buffer)
        if not x then ctx.notice = "go to: type x z or x y z"; return false end
        if ctx.route then Ro.stop(ctx, "GOTO") end
        return Mn.goto_coords(ctx, x, y, z)
    elseif ed.kind == "route" then
        return Rt.add(ctx, ed.buffer)
    elseif ed.kind == "route_point" then
        return Rt.point_add(ctx, ctx.route_open, ed.index, ed.buffer)
    elseif ed.kind == "route_point_edit" then
        return Rt.point_edit(ctx, ctx.route_open, ed.index, ed.buffer)
    end
    return St.set(ctx, ed.index, ed.buffer)
end

-- What was typed into the prompt.
function Ac.edit_submit(ctx, text)
    if not ctx.edit then return false end
    ctx.edit.buffer = tostring(text or "")
    return Ac.edit_commit(ctx)
end

-- Buttons ----------------------------------------------------------------------

Ac.ACTIONS = {
    power = function(ctx) Ky.power(ctx) end,
    land = function(ctx)
        if ctx.task and ctx.task.kind == "takeoff" then T.abort_task(ctx, "land button") end
        if not (ctx.task and ctx.task.kind == "land") then Op.run(ctx, {"land"}) end
    end,
    hold = function(ctx)
        if ctx.task and ctx.task.kind == "land" then Mn.take_over(ctx) end
        Op.run(ctx, {"hold"})
    end,
    stop = function(ctx)   -- brake and hold here: ends any autopilot phase, a landing too
        if ctx.k.mode ~= "ARMED" then return end
        Mn.take_over(ctx)
        ctx.man.v_f, ctx.man.v_r = 0, 0
    end,
    -- face a side of the world (the N E S W buttons)
    face_n = function(ctx) Ky.face(ctx, Ky.SIDES.N) end,
    face_e = function(ctx) Ky.face(ctx, Ky.SIDES.E) end,
    face_s = function(ctx) Ky.face(ctx, Ky.SIDES.S) end,
    face_w = function(ctx) Ky.face(ctx, Ky.SIDES.W) end,
    -- links by hand: toggle against what is wanted now (legs set by hand go
    -- back to automatic when the motors start or stop)
    link_gear = function(ctx) R.set_by_hand(ctx, "gear", not ctx.rlinks.want.gear) end,
    link_clutch = function(ctx) R.set_by_hand(ctx, "clutch", not ctx.rlinks.want.clutch) end,
    -- WAYPOINTS page
    wp_pick = function(ctx, n) n = tonumber(n); if n then ctx.wp_sel = n; W.clamp_sel(ctx) end end,
    wp_up = function(ctx) ctx.wp_sel = ctx.wp_sel - 1; W.clamp_sel(ctx) end,
    wp_down = function(ctx) ctx.wp_sel = ctx.wp_sel + 1; W.clamp_sel(ctx) end,
    wp_fly = function(ctx) Mn.fly_to(ctx, W.list(ctx)[ctx.wp_sel]) end,
    wp_new = function(ctx) Ac.edit_begin(ctx, "waypoint") end,
    wp_edit = function(ctx) Ac.edit_begin(ctx, "waypoint_edit", ctx.wp_sel) end,
    go_to = function(ctx) Ac.edit_begin(ctx, "goto") end,   -- STATUS page: coordinates to fly to once
    wp_delete = function(ctx) W.delete(ctx, ctx.wp_sel) end,
    reset = function(ctx) St.reset(ctx) end,
    -- SETTINGS page
    set_dec = function(ctx, n) n = tonumber(n) or ctx.set_sel; ctx.set_sel = n; St.adjust(ctx, n, -1) end,
    set_inc = function(ctx, n) n = tonumber(n) or ctx.set_sel; ctx.set_sel = n; St.adjust(ctx, n, 1) end,
    set_edit = function(ctx, n) n = tonumber(n) or ctx.set_sel; ctx.set_sel = n; Ac.edit_begin(ctx, "setting", n) end,
    -- ROUTES page: the list
    route_pick = function(ctx, n) n = tonumber(n); if n and Rt.list(ctx)[n] then ctx.route_sel = n end end,
    route_open = function(ctx, n)
        n = tonumber(n) or ctx.route_sel or 1
        local r = Rt.list(ctx)[n]
        if r then ctx.route_sel, ctx.route_open, ctx.point_sel = n, r.name, 1 end
    end,
    route_back = function(ctx) ctx.route_open = nil end,
    route_new = function(ctx) Ac.edit_begin(ctx, "route") end,
    route_fly = function(ctx)   -- the list: from the first point; a route's page: from the picked one
        if ctx.route_open then return Ro.start(ctx, ctx.route_open, ctx.point_sel or 1) end
        local r = Rt.list(ctx)[ctx.route_sel or 1]
        if r then Ro.start(ctx, r.name, 1) end
    end,
    route_delete = function(ctx)
        local r = ctx.route_open and Rt.get(ctx, ctx.route_open) or Rt.list(ctx)[ctx.route_sel or 1]
        if r then Rt.delete(ctx, r.name) end
    end,
    -- a route's page: the route itself
    route_laps_dec = function(ctx) if ctx.route_open then Rt.adjust_laps(ctx, ctx.route_open, -1) end end,
    route_laps_inc = function(ctx) if ctx.route_open then Rt.adjust_laps(ctx, ctx.route_open, 1) end end,
    route_finish = function(ctx) if ctx.route_open then Rt.cycle_finish(ctx, ctx.route_open) end end,
    -- a route's page: its points
    point_pick = function(ctx, n) n = tonumber(n); if n then ctx.point_sel = n end end,
    point_new = function(ctx) Ac.edit_begin(ctx, "route_point", ctx.point_sel or 0) end,
    point_edit = function(ctx) Ac.edit_begin(ctx, "route_point_edit", ctx.point_sel or 1) end,
    point_delete = function(ctx) if ctx.route_open then Rt.point_delete(ctx, ctx.route_open, ctx.point_sel or 1) end end,
    point_up = function(ctx) if ctx.route_open then Rt.point_move(ctx, ctx.route_open, ctx.point_sel or 1, -1) end end,
    point_down = function(ctx) if ctx.route_open then Rt.point_move(ctx, ctx.route_open, ctx.point_sel or 1, 1) end end,
    point_act = function(ctx) if ctx.route_open then Rt.point_cycle_act(ctx, ctx.route_open, ctx.point_sel or 1) end end,
}
-- the picked point's height / speed / wait one step down or up
for _, f in ipairs({"height", "speed", "wait"}) do
    Ac.ACTIONS["point_" .. f .. "_dec"] = function(ctx) if ctx.route_open then Rt.point_adjust(ctx, ctx.route_open, ctx.point_sel or 1, f, -1) end end
    Ac.ACTIONS["point_" .. f .. "_inc"] = function(ctx) if ctx.route_open then Rt.point_adjust(ctx, ctx.route_open, ctx.point_sel or 1, f, 1) end end
end

-- The owner first: these fly the ship, so a route flying ends.
local STOPS_ROUTE = {power = true, land = true, hold = true, stop = true, wp_fly = true}

-- Touches and keys can come in a burst when the server lags: the owner
-- pressed SURE? a few times on a screen that did not answer and three
-- waypoints went in one second (2026-10-15). A command (anything but moving
-- through a list or stepping a value) repeated within REPEAT_GUARD s is
-- dropped, and after a deletion Delete does nothing for W.DELETE_HOLD s.
Ac.REPEAT_GUARD = 0.5
local REPEATABLE = {wp_pick = true, wp_up = true, wp_down = true, set_dec = true, set_inc = true,
    route_pick = true, point_pick = true, point_up = true, point_down = true, route_laps_dec = true, route_laps_inc = true,
    point_height_dec = true, point_height_inc = true, point_speed_dec = true, point_speed_inc = true,
    point_wait_dec = true, point_wait_inc = true}

-- One button by name ("wp_pick:3" carries an argument). Returns true when it ran.
function Ac.run(ctx, name)
    local base, arg = tostring(name):match("^([^:]+):?(.*)$")
    local f = Ac.ACTIONS[base or name]
    if not f then return false end
    if not REPEATABLE[base] then
        local now = Cx.now(ctx)
        if ctx.last_cmd == name and now - ctx.last_cmd_t < Ac.REPEAT_GUARD then return false end
        if (base == "wp_delete" or base == "route_delete" or base == "point_delete") and now < (ctx.delete_hold or -math.huge) then return false end
        ctx.last_cmd, ctx.last_cmd_t = name, now
    end
    if ctx.confirm and ctx.confirm.action ~= base then
        ctx.confirm = nil
        if ctx.notice and (ctx.notice:find("^Delete ") or ctx.notice:find("^Reset%?")) then ctx.notice = nil end
    end
    if STOPS_ROUTE[base] and ctx.route then Ro.stop(ctx, base:upper() .. " button") end
    f(ctx, arg ~= "" and arg or nil)
    return true
end

return Ac
