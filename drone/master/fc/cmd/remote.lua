-- Quick control from the owner's pocket computer: rednet protocol
-- aero.fc.remote.v1. Only the computer ids in cfg.remote.ids that send the
-- shared cfg.remote.key are heard. The pocket asks for the status about once
-- a second ({type = "poll"}) and sends the drone tab's buttons
-- ({type = "cmd", cmd = power|stop|hold|fly, point = name}), typed
-- coordinates ({type = "cmd", cmd = "goto", x, z [, y]}: a one-off
-- destination, not saved), a point changed on the glasses ({cmd =
-- "wp_edit", point, text = "Name x y z [hdg]"}) and a new one ({cmd =
-- "wp_add", text = "Name x y z [hdg]"}), the Routes tab's (ROUTE below) and
-- the keys held on its keyboard ({type = "keys", keys = {"w", ...}},
-- fc.hw.input: flown like the typewriter's);
-- every message is answered with the status, which carries the points of
-- the route open on the glasses when the message names it ({show = name}).
-- A command is the same action as the button on the drone's screens, so
-- whoever presses last wins.
local Rm = {}

Rm.PROTOCOL = "aero.fc.remote.v1"

local ACTIONS = {power = "power", stop = "stop", hold = "hold", face_n = "face_n", face_e = "face_e", face_s = "face_s", face_w = "face_w"}

function Rm.allowed(cfg, sender, msg)
    local r = cfg.remote
    if type(r) ~= "table" or type(r.key) ~= "string" or #r.key < 8 then return false end
    if type(msg) ~= "table" or msg.key ~= r.key then return false end
    for _, id in ipairs(r.ids or {}) do
        if id == sender then return true end
    end
    return false
end

local function round(v) return v and math.floor(v + 0.5) or nil end

-- The routes for the glasses: every route in short, the one flying, and the
-- one open there (`show`) with its points as their lines.
local function routes(E, ctx, v, show)
    local list = {}
    for i, r in ipairs(E.routes(ctx)) do list[i] = {name = r.name, n = #r.points, tail = E.route_tail(r)} end
    local open
    local r = show and E.route_get(ctx, tostring(show))
    if r then
        local pts = {}
        for i, pt in ipairs(r.points) do pts[i] = {name = pt.name, text = E.point_text(pt), summary = E.point_summary(pt)} end
        open = {name = r.name, laps = r.laps or 1, finish = r.finish or "hold", points = pts}
    end
    local f = v.flying_route
    return list, f and {name = f.name, i = f.i, lap = f.lap} or nil, open
end

-- The keys held now, any source (the HUD's hint lights them).
local function held_names(ctx)
    local out = {}
    for name in pairs(ctx.input and ctx.input.held or {}) do out[#out + 1] = name end
    table.sort(out)
    return #out > 0 and out or nil
end

-- What the pocket's tabs show (small: it goes over rednet every second).
function Rm.status(E, ctx, show)
    local v = E.view(ctx)
    local st = v.state
    local word, color = E.power_label(v)
    local short = E.power_label(v, true)
    local points = {}
    for _, wp in ipairs(v.waypoints or {}) do
        points[#points + 1] = {name = wp.name, dist = round(wp.dist), dock = wp.hdg ~= nil, text = E.waypoint_text(wp)}
    end
    local recent = {}
    for i = 1, math.min(3, #(v.recent or {})) do recent[i] = v.recent[i] end   -- the glasses tell new ones in chat
    local list, flying, open = routes(E, ctx, v, show)
    return {type = "status", mode = v.mode, activity = v.activity, detail = v.detail, activity_color = E.ACT_COLOR[v.activity],
        warn = v.warn and tostring(v.warn) or nil,
        height = st and st.pos and round(st.pos.y), speed = st and round(st.speed), above = round(v.above),
        hdg = st and round(st.heading),   -- the HUD's heading (Minecraft yaw)
        pos = st and st.pos and {x = round(st.pos.x), y = round(st.pos.y), z = round(st.pos.z)},   -- glasses: is the owner aboard
        target = v.task and v.task.name, power = word, power_short = short, power_color = color,
        points = points, recent = recent, routes = list, flying = flying, open = open,
        keys_on = ctx.keys_on or nil, held = held_names(ctx), buttons = ctx.cfg.ui and ctx.cfg.ui.buttons}
end

-- The Routes tab's commands: {route = name} and for a point its place and
-- name ({index, point}: a list changed on the master meanwhile is refused,
-- not the wrong point changed). The glasses ask before a deletion, so it
-- goes at once. What the master's screens have picked stays picked.
local function point_of(E, ctx, msg)
    local r = E.route_get(ctx, tostring(msg.route))
    local i = tonumber(msg.index)
    local pt = r and i and r.points[i]
    if not pt or (msg.point ~= nil and pt.name ~= msg.point) then ctx.notice = "the route changed: look again"; return nil end
    return r.name, i
end

local function text(msg) return tostring(msg.text or "") end

local ROUTE = {
    route_fly = function(E, ctx, msg) E.route_start(ctx, tostring(msg.route), tonumber(msg.from) or 1) end,
    route_new = function(E, ctx, msg) E.route_add(ctx, text(msg)) end,
    route_del = function(E, ctx, msg) E.route_delete(ctx, tostring(msg.route), true) end,
    route_laps = function(E, ctx, msg) E.route_laps(ctx, tostring(msg.route), (tonumber(msg.dir) or 1) < 0 and -1 or 1) end,
    route_finish = function(E, ctx, msg) E.route_finish(ctx, tostring(msg.route)) end,
    pt_add = function(E, ctx, msg) E.point_add(ctx, tostring(msg.route), tonumber(msg.after), text(msg)) end,
    pt_edit = function(E, ctx, msg) local r, i = point_of(E, ctx, msg); if r then E.point_edit(ctx, r, i, text(msg)) end end,
    pt_del = function(E, ctx, msg) local r, i = point_of(E, ctx, msg); if r then E.point_delete(ctx, r, i, true) end end,
    pt_move = function(E, ctx, msg)
        local r, i = point_of(E, ctx, msg)
        if r then E.point_move(ctx, r, i, (tonumber(msg.dir) or 1) < 0 and -1 or 1) end
    end,
}

local function route_cmd(E, ctx, sender, cmd, msg)
    E.log(ctx, ("remote %d: %s %s%s"):format(sender, cmd, tostring(msg.route or ""), msg.text and (" " .. text(msg)) or ""))
    local route_sel, point_sel = ctx.route_sel, ctx.point_sel
    ROUTE[cmd](E, ctx, msg)
    ctx.route_sel = math.max(1, math.min(route_sel or 1, #E.routes(ctx)))
    ctx.point_sel = point_sel
end

-- One message from rednet: the reply (the status) or nil when it is not for us.
function Rm.handle(E, ctx, sender, msg)
    if not Rm.allowed(ctx.cfg, sender, msg) then return nil end
    if msg.type == "cmd" then
        local cmd = tostring(msg.cmd)
        if cmd == "fly" then
            local wp
            for _, w in ipairs(E.waypoints(ctx)) do
                if w.name == msg.point then wp = w end
            end
            E.log(ctx, ("remote %d: fly %s"):format(sender, tostring(msg.point)))
            if wp then E.fly_to(ctx, wp) else ctx.notice = "no point " .. tostring(msg.point) end
        elseif cmd == "wp_add" then
            -- the glasses' NEW: "Name x y z" (the glasses put in where the owner stands)
            E.log(ctx, ("remote %d: new point %s"):format(sender, tostring(msg.text)))
            local w = E.parse_command(tostring(msg.text or ""))
            if w and w[2] then E.waypoint_add(ctx, w[1], w[2], w[3], w[4], w[5])
            else ctx.notice = "new point: name x y z" end
        elseif cmd == "wp_edit" then
            -- the glasses' EDIT: the point by name, the edited line as on the master's prompt
            local index
            for i, w in ipairs(E.waypoints(ctx)) do
                if w.name == msg.point then index = i end
            end
            E.log(ctx, ("remote %d: edit %s -> %s"):format(sender, tostring(msg.point), tostring(msg.text)))
            if index then E.waypoint_edit_text(ctx, index, tostring(msg.text or "")) else ctx.notice = "no point " .. tostring(msg.point) end
        elseif cmd == "goto" then
            local x, y, z = tonumber(msg.x), tonumber(msg.y), tonumber(msg.z)
            local function ok(v) return v and v == v and math.abs(v) < 3e7 end
            E.log(ctx, ("remote %d: goto %s %s %s"):format(sender, tostring(msg.x), tostring(msg.y), tostring(msg.z)))
            if ok(x) and ok(z) and (y == nil or ok(y)) then
                E.goto_coords(ctx, x, y, z)
            else
                ctx.notice = "goto: x and z must be numbers"
            end
        elseif cmd == "keys_toggle" then   -- the glasses' Hint row: the key hint on the HUD
            ctx.keys_on = not ctx.keys_on
            E.log(ctx, ("remote %d: key hint %s"):format(sender, ctx.keys_on and "on" or "off"))
        elseif ROUTE[cmd] then
            route_cmd(E, ctx, sender, cmd, msg)
        elseif ACTIONS[cmd] then
            E.log(ctx, ("remote %d: %s"):format(sender, cmd))
            E.action(ctx, ACTIONS[cmd])
        end
    elseif msg.type == "keys" then
        -- the glasses' keyboard: one more source on the key bridge, flown like
        -- the typewriter, the key hint on or off (owner 2026-10-24: flying
        -- must not hang on the hint)
        local keys = {}
        for _, k in ipairs(type(msg.keys) == "table" and msg.keys or {}) do keys[#keys + 1] = k end
        E.key_source(ctx, "glasses " .. sender, keys)
    elseif msg.type ~= "poll" then
        return nil
    end
    return Rm.status(E, ctx, msg.show)
end

return Rm
