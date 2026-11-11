-- Flying a route (cfg.routes, see fc.data.routes): one point after another,
-- lap after lap. The route starts the ordinary tasks (takeoff, goto, hold,
-- land, dock) and goes on from their hooks; any other task (the owner's
-- keys and buttons, a safety stop) ends the route: the owner first.
--
-- ctx.route = {name, i (point), lap, phase, where, until_t, pass, task}
--   phase  "takeoff" | "leg" (to the point) | "landing" | "wait" (at the point)
--   where  while waiting: "air" (holding), "ground" (landed, motors on), "docked"
local A = require("fc.core.attitude")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")
local Nv = require("fc.flight.nav")
local T = require("fc.flight.tasks")
local K = require("fc.flight.controller")
local Mn = require("fc.flight.manual")

local Ro = {}

local OWNER = "route"

local function find(ctx, name)
    for _, r in ipairs(ctx.cfg.routes or {}) do
        if r.name == name then return r end
    end
    return nil
end

-- The running route, its config and the point it is at.
local function current(ctx)
    local ro = ctx.route
    local r = ro and find(ctx, ro.name)
    return ro, r, r and r.points[ro.i]
end

-- The point after point i: the next, or the first of the next lap (and its
-- index); nil after the last point of the last lap.
local function after(r, ro, i)
    if i < #r.points then return r.points[i + 1], i + 1 end
    local laps = r.laps or 1
    if laps == 0 or ro.lap < laps then return r.points[1], 1 end
    return nil
end

local function next_point(r, ro) return (after(r, ro, ro.i)) end

local function own(ctx)
    if ctx.task then ctx.task.owner = OWNER end
    ctx.route.task = ctx.task
end

local function top_speed(ctx, speed)
    local v = Nv.cruise_speed(ctx.cfg, speed)
    if v == math.huge then v = 200 end
    return v
end

local function flat(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) end

-- Flying over point i, coming from `from`: {v, r, turn} (the speed there,
-- how far before it the next leg takes over: fc.flight.nav), or nil and why
-- it stops there instead. The speed leaves room to slow down for what comes
-- after: a stop at the next point, or the next one's own pass speed (looked
-- at up to PLAN_AHEAD points on; beyond that a stop is assumed).
local PLAN_AHEAD = 4
local function pass_plan(ctx, r, ro, i, from, depth)
    local pt = r.points[i]
    local nxt, j = after(r, ro, i)
    if not (nxt and pt.act == "pass") then return nil, "the last point" end
    local cfg, mass = ctx.cfg, ctx.state and ctx.state.mass
    local turn = A.wrap180(Nv.bearing(pt, nxt) - Nv.bearing(from, pt))
    local len_out = flat(pt, nxt)
    local v = Nv.pass_speed(top_speed(ctx, nxt.speed or pt.speed), turn, math.min(flat(from, pt), len_out) / 2)
    if not v then return nil, ("%.0f deg turn at %s"):format(math.abs(turn), pt.name) end
    local v_after, r_after = 0, cfg.goto_radius
    if depth < PLAN_AHEAD then
        local p = pass_plan(ctx, r, ro, j, pt, depth + 1)
        if p then v_after, r_after = p.v, p.r end
    end
    -- the most v that slows to v_after by r_after before the next point
    -- (the braking curve planned speed.lead s ahead, as the legs do)
    local room = len_out - r_after + Nv.stop_distance(cfg, v_after, mass)
    local lo, hi = 0, v
    for _ = 1, 30 do
        local mid = (lo + hi) / 2
        if Nv.stop_distance(cfg, mid, mass) + mid * cfg.speed.lead <= room then lo = mid else hi = mid end
    end
    v = lo
    if v < Nv.PASS_MIN_V then return nil, ("no room after %s"):format(pt.name) end
    return {v = v, r = Nv.pass_lead(cfg, v, turn), turn = turn}
end

function Ro.stop(ctx, why)
    local ro = ctx.route
    if not ro then return false end
    ctx.route = nil
    Cx.log(ctx, ("route %s stopped: %s"):format(ro.name, why))
    return true
end

local leg

-- On to the next point (or the next lap, or the finish). `prev`: the leg
-- just flown over (a pass), its speed loop goes on.
function Ro.next(ctx, prev)
    local ro, r = current(ctx)
    if not r then return Ro.stop(ctx, "the route is gone") end
    ro.i = ro.i + 1
    if ro.i > #r.points then
        local laps = r.laps or 1
        if laps ~= 0 and ro.lap >= laps then return Ro.finish(ctx, r) end
        ro.i, ro.lap = 1, ro.lap + 1
        Cx.log(ctx, ("route %s: lap %d%s"):format(r.name, ro.lap, laps > 0 and ("/" .. laps) or ""))
    end
    return leg(ctx, prev)
end

-- After the last lap: hold there, land there, or fly home (r.finish). A
-- route that ends on the ground stays there, motors off.
function Ro.finish(ctx, r)
    ctx.route = nil
    local fin = r.finish or "hold"
    Cx.log(ctx, ("route %s done: %s"):format(r.name, fin))
    if ctx.k.mode == "STANDBY" then return true end   -- docked at the last point
    if ctx.task and ctx.task.kind == "land" then return true end
    if not ctx.task and G.on_ground(ctx) and G.sees_ground(ctx) then K.disarm(ctx.k); Cx.log(ctx, "disarmed"); return true end   -- landed at the last point
    if fin == "land" then
        local ok, err = T.start_land(ctx)
        if not ok then Cx.log(ctx, "land refused: " .. tostring(err)) end
    elseif fin == "home" and ctx.cfg.home then
        local h = ctx.cfg.home
        Mn.fly_to(ctx, {name = "Home", x = h.x, y = h.y, z = h.z, hdg = h.hdg})
    elseif not ctx.task and ctx.state and ctx.state.pos then
        T.start_hold(ctx, ctx.state.pos.x, ctx.state.pos.z)
    end
    return true
end

-- Waiting at the point (wait s), then on.
local function wait_here(ctx, where)
    local ro, _, pt = current(ctx)
    if not pt then return Ro.stop(ctx, "the route changed") end
    ro.phase, ro.where = "wait", where
    ro.until_t = Cx.now(ctx) + (pt.wait or 0)
    if (pt.wait or 0) <= 0 then return Ro.next(ctx) end
    return true
end

-- The goto reached the point (`task` is the leg that ended).
local function arrived(ctx, task)
    local ro, _, pt = current(ctx)
    if not pt then return Ro.stop(ctx, "the route changed") end
    if ro.pass then return Ro.next(ctx, task) end   -- flown over: straight on
    if pt.act == "land" then
        local ok, err = T.start_land(ctx, nil, {keep_armed = true})
        if not ok then return Ro.stop(ctx, "land refused: " .. tostring(err)) end
        ctx.task.on_landed = function(c) if c.route then wait_here(c, "ground") end end
        own(ctx)
        ro.phase = "landing"
        return true
    end
    if (pt.wait or 0) > 0 then
        T.start_hold(ctx, pt.x, pt.z)
        if ctx.task then ctx.task.name = pt.name end
        own(ctx)
    end
    return wait_here(ctx, "air")
end

-- Fly to the route's point now (`prev`: the leg flown over just before).
leg = function(ctx, prev)
    local ro, r, pt = current(ctx)
    if not pt then return Ro.stop(ctx, "the route has no point " .. tostring(ro and ro.i)) end
    ro.pass = false
    if ctx.k.mode == "STANDBY" then
        -- on the ground (the start, after a dock): take off first
        local ok, err = T.start_takeoff(ctx, function(c) if c.route then leg(c) end end)
        if not ok then return Ro.stop(ctx, "takeoff refused: " .. tostring(err)) end
        own(ctx)
        ro.phase = "takeoff"
        return true
    end
    if ctx.k.mode ~= "ARMED" then return Ro.stop(ctx, "the motors are " .. ctx.k.mode) end
    if ctx.task and ctx.task.kind == "hold" then ctx.task = nil end
    if pt.act == "dock" then
        local ok, err = T.start_dock(ctx, pt, {owner = OWNER, on_docked = function(c) if c.route then wait_here(c, "docked") end end})
        if not ok then return Ro.stop(ctx, "dock refused: " .. tostring(err)) end
        own(ctx)
        ro.phase = "leg"
        return true
    end
    local opts = {cruise_y = pt.height}
    if pt.act == "pass" and ctx.state and ctx.state.pos then
        local plan, why = pass_plan(ctx, r, ro, ro.i, ctx.state.pos, 1)
        if plan then
            opts.pass = {v = plan.v, r = plan.r}
            Cx.log(ctx, ("route %s: over %s at %.0f b/s, %.0f deg turn from %.0f blocks before"):format(r.name, pt.name, plan.v, math.abs(plan.turn), plan.r))
        else
            Cx.log(ctx, ("route %s: %s: stopping there"):format(r.name, why))
        end
    end
    if prev and prev.nav then opts.ctl, opts.cruising = prev.nav.ctl, true end
    local ok, err = T.start_goto(ctx, pt.x, pt.y, pt.z, pt.speed, opts)
    if not ok then return Ro.stop(ctx, "goto refused: " .. tostring(err)) end
    ctx.task.name = pt.name
    ctx.task.on_arrive = function(c, task) if c.route then arrived(c, task) end end
    own(ctx)
    ro.phase, ro.pass = "leg", opts.pass ~= nil
    return true
end

-- Fly route `name` from point `from` (default 1). From the ground it takes
-- off first; in the air it replaces a hold or a goto; a landing is taken over.
function Ro.start(ctx, name, from)
    local r = find(ctx, name)
    if not r then ctx.notice = "no route " .. tostring(name); return false end
    if #r.points == 0 then ctx.notice = "route " .. r.name .. " has no points yet"; return false end
    from = math.max(1, math.min(tonumber(from) or 1, #r.points))
    if ctx.k.mode == "DEGRADED" then ctx.notice = "route refused: sensor lost"; return false end
    if ctx.route then Ro.stop(ctx, "another route") end
    if ctx.task and ctx.task.kind == "land" then Mn.take_over(ctx) end
    if ctx.task and ctx.task.kind ~= "hold" then T.abort_task(ctx, "route " .. r.name) end
    ctx.route = {name = r.name, i = from, lap = 1}
    ctx.notice = nil
    Cx.log(ctx, ("route %s: start at point %d of %d (%s)"):format(r.name, from, #r.points,
        (r.laps or 1) == 0 and "loop" or ((r.laps or 1) .. " lap" .. ((r.laps or 1) > 1 and "s" or ""))))
    return leg(ctx) and ctx.route ~= nil
end

-- Every control cycle: the waits run out here, and a task that is not the
-- route's (the owner took over, a safety stop) ends it.
function Ro.step(ctx)
    local ro = ctx.route
    if not ro then return end
    local task = ctx.task
    if task and task.owner ~= OWNER then return Ro.stop(ctx, "taken over (" .. task.kind .. ")") end
    if ro.phase == "wait" then
        if ro.where == "air" and not task and ctx.k.mode ~= "ARMED" then return Ro.stop(ctx, "the motors stopped") end
        if ro.where == "ground" and ctx.k.mode ~= "ARMED" then return Ro.stop(ctx, "the motors stopped") end
        if ro.where == "docked" and ctx.k.mode ~= "STANDBY" then return Ro.stop(ctx, "taken over") end
        if ro.where == "air" and (task == nil) ~= (ro.task == nil) then return Ro.stop(ctx, "taken over") end
        if Cx.now(ctx) >= ro.until_t then Ro.next(ctx) end
        return
    end
    -- takeoff, leg, landing: the route's task runs; none = it ended without its hook
    if not task then return Ro.stop(ctx, "taken over") end
end

-- What the screens say: "ROUTE", "Patrol 2/5: to Mine" and what comes next.
function Ro.describe(ctx)
    local ro, r, pt = current(ctx)
    if not (ro and r and pt) then return nil end
    local n = #r.points
    local head = ("%s %d/%d"):format(r.name, ro.i, n)
    if (r.laps or 1) ~= 1 then head = head .. (" lap %d%s"):format(ro.lap, (r.laps or 1) > 0 and ("/" .. r.laps) or "") end
    local now
    if ro.phase == "takeoff" then now = "taking off"
    elseif ro.phase == "leg" then now = (ro.pass and "over " or "to ") .. pt.name
    elseif ro.phase == "landing" then now = "landing at " .. pt.name
    else
        local left = math.max(0, math.ceil((ro.until_t or 0) - Cx.now(ctx)))
        now = (ro.where == "docked" and "docked at " or ro.where == "ground" and "landed at " or "at ") .. pt.name .. (" %ds"):format(left)
    end
    local nxt = next_point(r, ro)
    return head .. ": " .. now, nxt and ("then " .. nxt.name) or ("then " .. (r.finish or "hold"))
end

return Ro
