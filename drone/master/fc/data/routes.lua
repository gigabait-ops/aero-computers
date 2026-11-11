-- Routes: named flights through a list of points (cfg.routes), flown by
-- fc.flight.route. Every change is saved at once.
--
--   route = {name, laps, finish, points}
--     laps    1 = once (the default), 0 = round and round until stopped, N = N laps
--     finish  after the last lap: "hold" there (the default), "land" there, or fly "home"
--   point = {name, x, y, z [, hdg], height, speed, wait, act}
--     height  the flight height of the leg to the point (nil: the SETTINGS one)
--     speed   the cruise speed of that leg in b/s (nil: the SETTINGS one)
--     wait    seconds at the point (hovering, on the ground or docked)
--     act     "stop" (the default): stop there; "pass": fly on without
--             stopping (the leg's height, a gentle turn); "land": land, wait,
--             take off; "dock": dock (a point with a heading), motors off, wait,
--             take off
--
-- A point as one line (NEW, EDIT, the glasses): "Name [x y z [hdg]] [h180]
-- [s100] [w30] [stop|pass|land|dock]". A name alone is a saved waypoint of
-- that name, or else where the ship is now (and its heading).
local A = require("fc.core.attitude")
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")
local U = require("fc.core.util")
local W = require("fc.data.waypoints")

local Rt = {}

Rt.ACTS = {"stop", "pass", "land", "dock"}    -- the order the act button goes round
Rt.FINISH = {"hold", "land", "home"}
Rt.LIMITS = {height = {-64, 320, 10}, speed = {10, 200, 10}, wait = {0, 3600, 5}}   -- min, max, step
Rt.NAME_MAX = 12

function Rt.list(ctx)
    return ctx.cfg.routes
end

function Rt.get(ctx, name)
    for i, r in ipairs(ctx.cfg.routes) do
        if r.name == name then return r, i end
    end
    return nil
end

-- What the list shows after a route's points: "loop", "then Home", "3 laps, then Hold".
function Rt.tail(r)
    local laps, fin = r.laps or 1, r.finish or "hold"
    if laps == 0 then return "loop" end
    local word = fin:sub(1, 1):upper() .. fin:sub(2)
    if laps == 1 then return "then " .. word end
    return ("%d laps, then %s"):format(laps, word)
end

function Rt.add(ctx, name)
    name = W.capital(tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, Rt.NAME_MAX))
    if name == "" then ctx.notice = "a route needs a name"; return false end
    if Rt.get(ctx, name) then ctx.notice = "route " .. name .. " exists"; return false end
    local list = ctx.cfg.routes
    list[#list + 1] = {name = name, laps = 1, finish = "hold", points = {}}
    ctx.route_sel = #list
    return Cx.save(ctx, "route " .. name .. " added")
end

-- Delete asks first: a second press within 10 s deletes (`sure`: asked
-- already, on the glasses).
function Rt.delete(ctx, name, sure)
    local r, i = Rt.get(ctx, name)
    if not r then ctx.notice = "no route selected"; return false end
    if ctx.route and ctx.route.name == name then ctx.notice = "route " .. name .. " is flying: stop it first"; return false end
    local now = Cx.now(ctx)
    local c = ctx.confirm
    if not sure and not (c and c.action == "route_delete" and c.name == name and now <= c.until_t) then
        ctx.confirm = {action = "route_delete", name = name, until_t = now + 10}
        ctx.notice = ("Delete %s? press DEL again within 10 s"):format(name)
        return false
    end
    ctx.confirm = nil
    ctx.delete_hold = now + W.DELETE_HOLD
    table.remove(ctx.cfg.routes, i)
    ctx.route_sel = math.max(1, math.min(ctx.route_sel or 1, #ctx.cfg.routes))
    if ctx.route_open == name then ctx.route_open = nil end
    return Cx.save(ctx, "route " .. name .. " deleted")
end

-- Laps: 1 once, 2.. that many, 0 (shown "loop") above the top and below 1.
function Rt.adjust_laps(ctx, name, dir)
    local r = Rt.get(ctx, name)
    if not r then return false end
    local n = r.laps or 1
    if dir > 0 then n = (n == 0) and 1 or (n >= 99 and 0 or n + 1)
    else n = (n == 0) and 99 or (n <= 1 and 0 or n - 1) end
    r.laps = n
    return Cx.save(ctx, ("route %s: %s"):format(r.name, Rt.tail(r)))
end

-- After the last lap: hold -> land -> home -> hold.
function Rt.cycle_finish(ctx, name)
    local r = Rt.get(ctx, name)
    if not r then return false end
    local at = 1
    for i, f in ipairs(Rt.FINISH) do if f == (r.finish or "hold") then at = i end end
    r.finish = Rt.FINISH[at % #Rt.FINISH + 1]
    return Cx.save(ctx, ("route %s: %s"):format(r.name, Rt.tail(r)))
end

-- Points ----------------------------------------------------------------------

local function n1(v) return (("%.1f"):format(v):gsub("%.0$", "")) end

-- A point as its line: "Mine 300 60 20 h180 s100 w60 land".
function Rt.point_text(pt)
    local out = {pt.name, n1(pt.x), n1(pt.y), n1(pt.z)}
    if pt.hdg then out[#out + 1] = n1(pt.hdg) end
    if pt.height then out[#out + 1] = "h" .. n1(pt.height) end
    if pt.speed then out[#out + 1] = "s" .. n1(pt.speed) end
    if pt.wait and pt.wait > 0 then out[#out + 1] = "w" .. n1(pt.wait) end
    if pt.act and pt.act ~= "stop" then out[#out + 1] = pt.act end
    return table.concat(out, " ")
end

-- What a list row shows after the point: "h180 100b/s land 60s".
function Rt.point_summary(pt)
    local out = {}
    if pt.height then out[#out + 1] = "h" .. n1(pt.height) end
    if pt.speed then out[#out + 1] = n1(pt.speed) .. "b/s" end
    local act, wait = pt.act or "stop", pt.wait or 0
    if act == "pass" then out[#out + 1] = "pass"
    elseif act == "stop" then if wait > 0 then out[#out + 1] = "wait " .. n1(wait) .. "s" end
    else out[#out + 1] = act .. (wait > 0 and (" " .. n1(wait) .. "s") or "") end
    return table.concat(out, " ")
end

local function in_range(field, v)
    local lim = Rt.LIMITS[field]
    return v >= lim[1] and v <= lim[2]
end

-- A typed line -> a point, or nil and why.
function Rt.parse_point(ctx, text)
    local words = U.words(text)
    if not words then return nil, "point: Name [x y z [hdg]] [h180] [s100] [w30] [pass|land|dock]" end
    local name = W.capital(words[1]:sub(1, Rt.NAME_MAX))
    local i, nums = 2, {}
    while words[i] and tonumber(words[i]) and #nums < 4 do nums[#nums + 1] = tonumber(words[i]); i = i + 1 end
    local pt = {name = name}
    local dock_like = false   -- a saved dock, or a typed heading: a dock unless the line says otherwise
    if #nums >= 3 then
        pt.x, pt.y, pt.z, pt.hdg = nums[1], nums[2], nums[3], nums[4]
        dock_like = nums[4] ~= nil
    elseif #nums == 0 then
        local wi = W.index(ctx, name)
        if wi then
            local wp = W.list(ctx)[wi]
            pt.name, pt.x, pt.y, pt.z, pt.hdg = wp.name, wp.x, wp.y, wp.z, wp.hdg
            dock_like = wp.hdg ~= nil
        else
            local st = ctx.state
            if not (st and st.pos) then return nil, "point: no position yet, type x y z" end
            pt.x, pt.y, pt.z, pt.hdg = st.pos.x, st.pos.y, st.pos.z, st.heading
        end
    else
        return nil, "point: x y z, all three"
    end
    for j = i, #words do
        local w = words[j]:lower()
        local key, num = w:match("^([hsw])(%-?[%d.]+)$")
        local field = key and ({h = "height", s = "speed", w = "wait"})[key]
        if field and tonumber(num) then
            local v = tonumber(num)
            if not in_range(field, v) then return nil, ("point: %s %s out of %s..%s"):format(field, num, Rt.LIMITS[field][1], Rt.LIMITS[field][2]) end
            pt[field] = v
        elseif C.ROUTE_ACTS[w] then
            pt.act = w
        else
            return nil, "point: what is " .. words[j] .. "? (h180 s100 w30 pass land dock)"
        end
    end
    -- "Home" alone once flew to the dock's height and stopped there, on the
    -- dock but not docked (owner 2026-10-23)
    if pt.act == nil and dock_like then pt.act = "dock" end
    if pt.act == "dock" and pt.hdg == nil then return nil, "point: a dock needs a heading (x y z hdg, or a saved dock)" end
    local r1 = U.tenth
    pt.x, pt.y, pt.z = r1(pt.x), r1(pt.y), r1(pt.z)
    if pt.hdg then pt.hdg = r1(A.wrap180(pt.hdg)) end
    return pt
end

local function route_points(ctx, name)
    local r = Rt.get(ctx, name)
    if not r then ctx.notice = "no route selected"; return nil end
    return r.points, r
end

-- A new point after `after` (0 = first; nil = last).
function Rt.point_add(ctx, name, after, text)
    local list, r = route_points(ctx, name)
    if not list then return false end
    local pt, err = Rt.parse_point(ctx, text)
    if not pt then ctx.notice = err; return false end
    local at = math.max(1, math.min((after or #list) + 1, #list + 1))
    table.insert(list, at, pt)
    ctx.point_sel = at
    return Cx.save(ctx, ("route %s: point %d %s"):format(r.name, at, Rt.point_text(pt)))
end

function Rt.point_edit(ctx, name, index, text)
    local list, r = route_points(ctx, name)
    if not (list and list[index]) then ctx.notice = "no point selected"; return false end
    local pt, err = Rt.parse_point(ctx, text)
    if not pt then ctx.notice = err; return false end
    list[index] = pt
    return Cx.save(ctx, ("route %s: point %d %s"):format(r.name, index, Rt.point_text(pt)))
end

-- Delete asks first: a second press within 10 s deletes (`sure`: asked already).
function Rt.point_delete(ctx, name, index, sure)
    local list, r = route_points(ctx, name)
    if not (list and list[index]) then ctx.notice = "no point selected"; return false end
    local now = Cx.now(ctx)
    local c = ctx.confirm
    local key = r.name .. "#" .. index
    if not sure and not (c and c.action == "point_delete" and c.name == key and now <= c.until_t) then
        ctx.confirm = {action = "point_delete", name = key, until_t = now + 10}
        ctx.notice = ("Delete point %d %s? press DEL again within 10 s"):format(index, list[index].name)
        return false
    end
    ctx.confirm = nil
    ctx.delete_hold = now + W.DELETE_HOLD
    local gone = table.remove(list, index)
    ctx.point_sel = math.max(1, math.min(index, #list))
    return Cx.save(ctx, ("route %s: point %s deleted"):format(r.name, gone.name))
end

-- One place up (dir -1) or down (+1).
function Rt.point_move(ctx, name, index, dir)
    local list, r = route_points(ctx, name)
    local to = index + dir
    if not (list and list[index] and list[to]) then return false end
    list[index], list[to] = list[to], list[index]
    ctx.point_sel = to
    return Cx.save(ctx, ("route %s: %s now point %d"):format(r.name, list[to].name, to))
end

-- Height / speed / wait one step up or down. "--" (nil) is the SETTINGS
-- value: a step from it starts there; below the least height or speed it
-- goes back to "--".
local function usual(ctx, field)
    if field == "height" then return ctx.cfg.ap.cruise_y or 0 end
    if field == "speed" then
        local v = ctx.cfg.ap.speed or 0
        if v <= 0 then v = ctx.cfg.speed.max or 0 end
        return v > 0 and v or Rt.LIMITS.speed[2]
    end
    return 0
end

function Rt.point_adjust(ctx, name, index, field, dir)
    local list, r = route_points(ctx, name)
    local pt = list and list[index]
    local lim = Rt.LIMITS[field]
    if not (pt and lim) then return false end
    local v = (pt[field] or usual(ctx, field)) + dir * lim[3]
    if v < lim[1] then v = nil elseif v > lim[2] then v = lim[2] end
    if field == "wait" and v == 0 then v = nil end
    pt[field] = v
    return Cx.save(ctx, ("route %s: point %d %s"):format(r.name, index, Rt.point_text(pt)))
end

-- The act button: stop -> pass -> land -> dock (only with a heading) -> stop.
function Rt.point_cycle_act(ctx, name, index)
    local list, r = route_points(ctx, name)
    local pt = list and list[index]
    if not pt then return false end
    local at = 1
    for i, a in ipairs(Rt.ACTS) do if a == (pt.act or "stop") then at = i end end
    local nxt = Rt.ACTS[at % #Rt.ACTS + 1]
    if nxt == "dock" and pt.hdg == nil then nxt = "stop" end
    pt.act = nxt ~= "stop" and nxt or nil
    return Cx.save(ctx, ("route %s: point %d %s"):format(r.name, index, Rt.point_text(pt)))
end

return Rt
