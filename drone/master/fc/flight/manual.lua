-- The pilot's flight: manual speed control (armed without a task) and the
-- owner's commands that start or take over a flight (FLY, GOTO, keys).
local K = require("fc.flight.controller")
local Nv = require("fc.flight.nav")
local T = require("fc.flight.tasks")
local Cx = require("fc.core.ctx")

local Mn = {}

Mn.REVERSE_MAX = 6   -- b/s: manual reverse speed limit (only the front pair pushes back)

-- Manual speed control ---------------------------------------------------------
-- Armed without a task the ship flies at the speeds the keys set (W/S
-- forward b/s, arrows sideways b/s); with both at 0 it brakes and then holds
-- the point where it stopped.
function Mn.reset(ctx)
    ctx.man = {v_f = 0, v_r = 0, ctl = Nv.speed_new(), hold = nil}
end

function Mn.step(ctx, state, dt)
    local m, k = ctx.man, ctx.k
    if ctx.task then
        -- the autopilot flies; afterwards the ship holds where it ends up
        if m.v_f ~= 0 or m.v_r ~= 0 or m.hold then Mn.reset(ctx) end
        return
    end
    if k.mode ~= "ARMED" or not (state and state.pos and state.heading) then return end
    if state.v_lift_max and m.v_f > state.v_lift_max then m.v_f = state.v_lift_max end
    if m.v_f == 0 and m.v_r == 0 then
        if not m.hold and (state.speed or 0) < 0.5 then
            m.hold = {x = state.pos.x, z = state.pos.z}
            m.ctl.f, m.ctl.r = 0, 0
        end
        if m.hold then
            local h = Nv.hold2d(ctx.cfg, state, m.hold)
            K.set_pilot(k, {forward = h.forward, side = h.side})
            return
        end
    else
        m.hold = nil
    end
    local f, s = Nv.speed_step(ctx.cfg, m.ctl, m.v_f, m.v_r, state, dt)
    K.set_pilot(k, {forward = f, side = s})
end

-- The owner first (2026-10-18): keys, STOP, FLY and HOLD take over any
-- autopilot phase, a landing too, at any height; the automation only keeps
-- the ship level.
function Mn.take_over(ctx)
    if not ctx.task then return true end
    T.abort_task(ctx, "manual input")
    K.rehold(ctx.k, ctx.state)
    return true
end

-- Fly to a waypoint: from the ground this arms and takes off first; in the
-- air it replaces a hold or an earlier goto. A landing is never interrupted.
function Mn.fly_to(ctx, wp)
    if not wp then ctx.notice = "no waypoint selected"; return false end
    local function go(c)
        local ok, err
        if wp.hdg then
            ok, err = T.start_dock(c, wp)                 -- a point with a heading is a dock
        else
            ok, err = T.start_goto(c, wp.x, wp.y, wp.z, nil)
            if ok then c.task.name = wp.name end
        end
        if not ok then c.notice = "fly refused: " .. tostring(err); Cx.log(c, c.notice) end
        return ok
    end
    if ctx.task and ctx.task.kind == "land" then Mn.take_over(ctx) end
    if ctx.k.mode == "STANDBY" then
        local ok, err = T.start_takeoff(ctx, go)
        if not ok then ctx.notice = "fly refused: " .. tostring(err); Cx.log(ctx, ctx.notice); return false end
        ctx.task.name = wp.name
        return true
    end
    if ctx.k.mode ~= "ARMED" then ctx.notice = "fly refused: " .. ctx.k.mode; return false end
    if ctx.task and (ctx.task.kind == "goto" or ctx.task.kind == "dock") then T.abort_task(ctx, "new destination") end
    if ctx.task and ctx.task.kind ~= "hold" then ctx.notice = "fly refused: " .. ctx.task.kind .. " running"; return false end
    return go(ctx)
end

-- A one-off destination by coordinates, not saved (GOTO on the Status page
-- and on the glasses): like a point, from the ground it takes off first. No
-- height typed: the flight height (or this one, if higher).
function Mn.goto_coords(ctx, x, y, z)
    local here = ctx.state and ctx.state.pos and ctx.state.pos.y or 0
    y = y or math.max(ctx.cfg.ap.cruise_y, here)
    return Mn.fly_to(ctx, {name = ("%.0f, %.0f"):format(x, z), x = x, y = y, z = z})
end

return Mn
