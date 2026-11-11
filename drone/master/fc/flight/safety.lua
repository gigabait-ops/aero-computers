-- Safety checks every control cycle, whatever is running: a ship tipping
-- over, lift running short at speed, a ship resting on the ground.
local K = require("fc.flight.controller")
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")

local Sf = {}

-- Attitude: past arm_cut_tilt (or overturned) the motors are cut; past
-- arm_abort_tilt the flight calms down once per upset.
function Sf.attitude(ctx, state)
    if not state or ctx.k.mode == "STANDBY" then return end
    local tilt = math.max(math.abs(state.tilt.left), math.abs(state.tilt.fwd))
    if tilt > ctx.cfg.arm_cut_tilt or K.overturned(ctx.cfg, state) then
        -- Nearly on its side or inverted (on its back the side components
        -- are small again: it lay there with the props running): thrust
        -- only makes it worse.
        ctx.task = nil
        K.set_trim(ctx.k, ctx.cfg.trim)   -- an upset is not a mass shift
        ctx.k.upset = true
        K.disarm(ctx.k)
        Cx.log(ctx, ("ARMED cut: tilt %.2f (up %.2f) beyond %.2f -> idle"):format(tilt, state.tilt.up or 1, ctx.cfg.arm_cut_tilt))
        Cx.incident(ctx, "motors cut: tilt")
    elseif tilt > ctx.cfg.arm_abort_tilt and not ctx.tilt_latched and not (ctx.task and ctx.task.kind == "land") then
        ctx.tilt_latched = true   -- once per upset: the owner taking over is not overruled while it is still tilted
        -- Keep flying but calm down: no pilot inputs. An autopilot leg
        -- ends in a landing (any key or button takes over); the owner
        -- flying by hand keeps the ship, levelled and holding here. The
        -- trim goes back to the saved one: a big upset with the props
        -- answering is most likely a trim that crept away.
        K.set_trim(ctx.k, ctx.cfg.trim)
        ctx.k.upset = true
        local auto = ctx.task ~= nil
        if auto then T.abort_task(ctx, "tilt") end
        if ctx.k.mode == "ARMED" then
            K.set_pilot(ctx.k, {forward = 0, side = 0, climb = 0, turn = 0})
            Mn.reset(ctx)
            Cx.incident(ctx, "tilt abort")
            if auto then
                Cx.log(ctx, ("ARMED aborted: tilt %.2f exceeds %.2f -> pilot zero, landing"):format(tilt, ctx.cfg.arm_abort_tilt))
                local ok, err = T.start_land(ctx)
                if not ok then Cx.log(ctx, "land after abort refused: " .. tostring(err)) end
            else
                K.rehold(ctx.k, state)
                Cx.log(ctx, ("ARMED aborted: tilt %.2f exceeds %.2f -> pilot zero, levelling out here"):format(tilt, ctx.cfg.arm_abort_tilt))
            end
        end
    end
    if ctx.tilt_latched and tilt < 0.6 * ctx.cfg.arm_abort_tilt then ctx.tilt_latched = nil end
end

-- The lift ran short at speed: fly at most 90 % of that speed from now on
-- (the autopilot and W both respect it), at most one cut every 2 s; the
-- limit ends with the flight (fuel and cargo change). Once the props have
-- room again (every lift motor below LIFT_ROOM of max_speed, not sinking)
-- for LIFT_BACK_S, the limit goes up by half, and away above the top
-- speed: at 300 high the front props neared their top at any speed, the
-- cuts took the limit to 37 b/s, below the ion cube's 40, and the rest of
-- the flight went at 20 b/s (2026-10-21).
Sf.LIFT_ROOM = 0.7
Sf.LIFT_BACK_S = 5

local function lift_room(ctx, state, action)
    if not (action and action.type == "set" and action.targets and state and state.vel) or state.vel.y < -0.5 then return false end
    local top = ctx.cfg.limits.max_speed * Sf.LIFT_ROOM
    for id, m in pairs(ctx.cfg.motors) do
        if m.role == "lift" and math.abs(action.targets[id] or 0) >= top then return false end
    end
    return true
end

local function lift_back(ctx, state, t, action)
    local k = ctx.k
    if not (ctx.v_lift_max and k.mode == "ARMED" and not k.lift_limited and not k.stall_cap and lift_room(ctx, state, action)) then
        ctx.lift_room_since = nil
        return
    end
    ctx.lift_room_since = ctx.lift_room_since or t
    if t - ctx.lift_room_since < Sf.LIFT_BACK_S then return end
    ctx.lift_room_since = t
    local top = (ctx.cfg.speed.max or 0) > 0 and ctx.cfg.speed.max or 200
    local up = math.floor(ctx.v_lift_max * 1.5 + 0.5)
    if up >= top then
        ctx.v_lift_max = nil
        Cx.log(ctx, "lift has room again: no speed limit")
    else
        ctx.v_lift_max, ctx.v_lift_t = up, t
        Cx.log(ctx, ("lift has room again: flying at most %d b/s"):format(up))
    end
end

function Sf.lift_limit(ctx, state, t, action)
    if ctx.k.mode ~= "ARMED" then
        ctx.v_lift_max, ctx.stall_seen = nil, nil
    elseif ctx.k.stall_t and ctx.k.stall_t ~= ctx.stall_seen and state then
        -- the props stopped: at speed that is the lift the speed asks for, so
        -- slow down hard (70 %), not by a tenth
        ctx.stall_seen = ctx.k.stall_t
        local v = math.max(state.v_fwd or 0, 0)
        if v > 30 then
            local lim = math.floor(v * 0.7)
            if not ctx.v_lift_max or lim < ctx.v_lift_max then
                ctx.v_lift_max, ctx.v_lift_t = lim, t
                Cx.log(ctx, ("lift at its limit at %.0f b/s: flying at most %d b/s"):format(v, lim))
            end
        end
    elseif ctx.k.lift_limited and state and t - (ctx.v_lift_t or -math.huge) >= 2 then
        local v = math.max(state.v_fwd or 0, 0)
        local lim = math.max(20, math.floor(v * 0.9))
        if not ctx.v_lift_max or lim < ctx.v_lift_max then
            ctx.v_lift_max, ctx.v_lift_t = lim, t
            Cx.log(ctx, ("lift at its limit at %.0f b/s: flying at most %d b/s"):format(v, lim))
        end
    end
    lift_back(ctx, state, t, action)
end

-- "Resting": still for 2 s with the lift wound down well below hover, so
-- something other than the motors holds the ship up (the ground). Armed
-- and resting with the height target below the hull: the target stays at
-- the hull and the integral clean (the loop would otherwise press the ship
-- into the ground), so the next climb starts at once.
function Sf.resting(ctx, dt)
    local st, kk = ctx.state, ctx.k
    if st and st.vel and st.pos and kk.last_collective and kk.mode ~= "STANDBY"
        and math.abs(st.vel.y) < 0.05 and kk.last_collective <= ctx.cfg.hover - ctx.cfg.rest_margin then
        ctx.rest = (ctx.rest or 0) + dt
    else
        ctx.rest = 0
    end
    if G.resting(ctx) and kk.mode == "ARMED" and not ctx.task and kk.alt_sp and kk.alt_sp < st.pos.y then
        kk.alt_sp = st.pos.y
        K.reset_integrals(kk, "alt")
        if not ctx.rest_logged then ctx.rest_logged = true; Cx.log(ctx, ("resting on the ground: height target raised to %.1f"):format(st.pos.y)) end
    elseif not G.resting(ctx) then
        ctx.rest_logged = nil
    end
end

return Sf
