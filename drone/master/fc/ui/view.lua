-- What the screens, the glasses and the log line show: the ship's activity
-- in plain words, the power button's word, the Recent list, and the view
-- (one table with everything they draw).
local K = require("fc.flight.controller")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")
local Nd = require("fc.hw.nodes")
local W = require("fc.data.waypoints")
local St = require("fc.data.settings")
local Rt = require("fc.data.routes")
local Ro = require("fc.flight.route")
local N = require("fc.core.notice")

local V = {}

-- Theme colour token for each activity word (screens, pocket).
V.ACT_COLOR = {["ON THE GROUND"] = "muted", FLYING = "info", CLIMBING = "info", DESCENDING = "info", DOCKING = "info",
    ["TAKING OFF"] = "info", LANDING = "extra", HOLDING = "ok", MANUAL = "extra", BRAKING = "ok", ["SENSOR LOST"] = "bad",
    OVERTURNED = "bad", ROUTE = "info"}

-- What the ship is doing, in a few plain words: the word and a detail.
function V.activity(ctx)
    local k, task = ctx.k, ctx.task
    if k.mode == "STANDBY" and ctx.flip then return "OVERTURNED", "hold A/D, W/S or Shift: props in reverse" end
    if k.mode == "STANDBY" then return "ON THE GROUND", "motors off" end
    if k.mode == "DEGRADED" then return "SENSOR LOST", "hovering only" end
    if ctx.route then
        local now, nxt = Ro.describe(ctx)
        if now then return "ROUTE", now, nxt end
    end
    if task then
        local name = task.name
        if task.kind == "takeoff" then return "TAKING OFF", ("to height %.0f"):format(task.target_y or 0) end
        if task.kind == "goto" then
            local where = name or ("%d, %d"):format(task.target.x, task.target.z)
            local last = task.last
            if last and last.climbing then return "CLIMBING", ("to %.0f, then to %s"):format(last.target_y or 0, where) end
            if last and last.descending then return "DESCENDING", ("over %s to %.0f"):format(where, task.target.y) end
            return "FLYING", ("to %s, %s blocks"):format(where, last and ("%.0f"):format(last.dist) or "?")
        end
        if task.kind == "dock" then
            local d = task.last
            if task.settling then return "DOCKING", ("settling at %s"):format(tostring(name)) end
            return "DOCKING", d and ("at %s: %.1f to go"):format(tostring(name), math.sqrt(d.along ^ 2 + d.side ^ 2)) or tostring(name)
        end
        if task.kind == "hold" then return "HOLDING", name and ("at " .. name) or "this point" end
        if task.kind == "land" then
            local above = task.last and task.last.above
            return "LANDING", above and ("%.0f above the ground"):format(above) or (name or "")
        end
        return task.kind:upper(), ""
    end
    local m = ctx.man
    if m.v_f ~= 0 or m.v_r ~= 0 then return "MANUAL", ("speed %+.0f, side %+.0f b/s"):format(m.v_f, m.v_r) end
    if m.hold then return "HOLDING", "this point" end
    return "BRAKING", "then holding here"
end

-- The power button's word and colour token for a view (screens, pocket).
function V.power_label(view, short)
    if view.mode == "STANDBY" then return "START", "ok" end
    if view.task and view.task.kind == "land" then return short and "WAIT" or "LANDING", "warn" end
    if view.on_ground then return short and "OFF" or "MOTORS OFF", "bad" end
    return "LAND", "warn"
end

-- The log as keyed news for the Recent lists and the glasses' chat (nil:
-- not news): a theme token, a key of fc/core/notice.lua and its params.
local function plain(l)
    local m
    if l:find("^ARMED cut") then return "bad", "drone.cut" end
    if l:find("^ARMED aborted") then return "bad", "drone.too_steep" end
    if l:find("^props stalled") then return "bad", "props.stalled" end
    if l:find("^lift cap lifted") then return "ok", "lift.full" end
    m = l:match("^lift at its limit at %d+ b/s: flying at most (%d+)"); if m then return "warn", "lift.short", {speed = m} end
    if l:find("^POWER LOST") then return "bad", "power.lost" end
    if l:find("^power back") then return "ok", "power.back" end
    m = l:match("refused: (.*)$"); if m then return "warn", "refused", {reason = m} end
    m = l:match("^arrived at (%S+) %("); if m then return "ok", "arrived.at", {point = m} end
    if l:find("^arrived") then return "ok", "arrived" end
    m = l:match("^DOCKED at (%S+) on the ground"); if m then return "ok", "docked", {point = m} end
    if l:find("^landed") then return "ok", "landed" end
    if l:find("^takeoff:") then return "accent", "takeoff" end
    m = l:match("^goto start: .- dist (%d+)"); if m then return "accent", "goto", {blocks = m} end
    if l:find("^land start") then return "extra", "land" end
    if l:find("^auto%-resume") then return "warn", "resumed" end
    if l:find("^armed") then return "ok", "motors.on" end
    if l:find("^disarmed") then return "muted", "motors.off" end
    m = l:match("^link gear (%a+)"); if m == "down" or m == "up" then return "muted", "legs." .. m end
    m = l:match("^link clutch (%a+)"); if m == "released" then return "muted", "engine.off" elseif m == "engaged" then return "muted", "engine.on" end
    if l:find("^booster energy low") then return "warn", "ion.low" end
    m = l:match("^waypoint (.-) deleted"); if m then return "muted", "point.deleted", {point = m} end
    m = l:match("^route (.-): start at point"); if m then return "accent", "route.start", {route = m} end
    m = l:match("^route (.-) done"); if m then return "ok", "route.done", {route = m} end
    m = l:match("^route (.-) stopped"); if m then return "warn", "route.stopped", {route = m} end
    m = l:match("^passed (%S+)"); if m then return "muted", "passed", {point = m} end
    return nil
end

-- The latest notable events (newest first): {theme token, English text,
-- key, params}; the glasses say the key in chat in their own language.
function V.recent(ctx, n)
    local out = {}
    for i = #ctx.report, 1, -1 do
        local token, key, params = plain(ctx.report[i])
        local text = key and N.text(key, params)
        if text and (#out == 0 or out[#out][2] ~= text) then out[#out + 1] = {token, text, key, params} end
        if #out >= (n or 3) then break end
    end
    return out
end

-- Everything the screens and the log line show.
function V.view(ctx)
    local task, st = ctx.task, ctx.state
    local act, detail, next_step = V.activity(ctx)
    local nav = task and task.last
    return {
        mode = ctx.k.mode, task = task and {kind = task.kind, name = task.name, target = task.target} or nil,
        activity = act, detail = detail, next_step = next_step,
        warn = ctx.k.warn or ctx.notice or ctx.cfg_err,
        state = st, err = ctx.err,
        alt_sp = ctx.k.alt_sp, hdg_sp = ctx.k.hdg_sp,
        above = G.above(ctx), ground_src = ctx.ground_src,
        ground_seen = {G.seeing(ctx)},   -- {sensors seeing the ground within the cut height, sensors there are}
        trim = K.trim_estimate(ctx.k),
        status = Nd.status(ctx), motors = ctx.cfg.motors,
        targets = ctx.last_action and ctx.last_action.targets,
        now = Cx.now(ctx), dt = ctx.last_dt, mass = ctx.mass,
        pilot = ctx.k.pilot, man = {v_f = ctx.man.v_f, v_r = ctx.man.v_r, hold = ctx.man.hold ~= nil},
        nav = nav and {dist = nav.dist, bearing = nav.bearing, hdg_err = nav.hdg_err, v_des = nav.v_des} or nil,
        waypoints = W.rows(ctx), wp_sel = ctx.wp_sel,
        settings = St.rows(ctx), set_sel = ctx.set_sel,
        routes = V.route_rows(ctx), route_sel = ctx.route_sel or 1, route_open = V.open_route(ctx),
        flying_route = ctx.route and {name = ctx.route.name, i = ctx.route.i, lap = ctx.route.lap} or nil,
        ap = ctx.cfg.ap, speed_max = ctx.cfg.speed.max,
        edit = ctx.edit and {prompt = ctx.edit.prompt, n = ctx.edit.n, title = ctx.edit.title, value = ctx.edit.value} or nil,
        on_ground = G.on_ground(ctx),
        power = Nd.power_status(ctx),
        links = {clutch = ctx.rlinks.want.clutch, gear = ctx.rlinks.want.gear, bridge = ctx.link_bridge},
        confirm = (ctx.confirm and Cx.now(ctx) <= ctx.confirm.until_t) and ctx.confirm or nil,
        recent = V.recent(ctx, 3),
    }
end

-- The routes for the list: name, how many points, what comes after.
function V.route_rows(ctx)
    local rows = {}
    for i, r in ipairs(Rt.list(ctx)) do
        rows[i] = {name = r.name, n = #r.points, laps = r.laps or 1, finish = r.finish or "hold", tail = Rt.tail(r),
            flying = ctx.route and ctx.route.name == r.name or nil}
    end
    return rows
end

-- The route open on its page, with its points: {name, laps, finish, tail, sel, points = {{name, x, y, z, hdg, height, speed, wait, act, text, summary}}}.
function V.open_route(ctx)
    local r = ctx.route_open and Rt.get(ctx, ctx.route_open)
    if not r then return nil end
    local pts = {}
    for i, pt in ipairs(r.points) do
        pts[i] = {name = pt.name, x = pt.x, y = pt.y, z = pt.z, hdg = pt.hdg, height = pt.height, speed = pt.speed,
            wait = pt.wait, act = pt.act or "stop", text = Rt.point_text(pt), summary = Rt.point_summary(pt)}
    end
    return {name = r.name, laps = r.laps or 1, finish = r.finish or "hold", tail = Rt.tail(r), points = pts,
        sel = math.max(1, math.min(ctx.point_sel or 1, math.max(1, #pts)))}
end

-- Motors alive, motors configured and the ids not answering (sorted), for
-- a view (the Status page and the log line).
function V.motors_ok(view)
    local ok, total, lost = 0, 0, {}
    for id in pairs(view.motors or {}) do
        total = total + 1
        local s = (view.status or {})[id]
        if s and s.ok then ok = ok + 1 else lost[#lost + 1] = id end
    end
    table.sort(lost)
    return ok, total, lost
end

return V
