-- Manual flight from the linked typewriter, and the power button.
-- Every press (and key repeat while held) steps a setpoint: W/S the forward
-- speed, Space/Shift the height target; A/D turn while held, arrows slide
-- sideways while held; 9 = power (arm on the ground, land in the air,
-- motors off on the ground); X stop (brake and hold); H hold; L land;
-- numpad 7 the forward speed back to 0; numpad 8 the glasses' key hint;
-- numpad 4 / 6 turn to the next side of the world to the left / right.
-- X and 7 win over W/S held at the same time: those count again only once
-- let go (a W held through them wound the speed up again at once, 2026-10-24).
local K = require("fc.flight.controller")
local Nv = require("fc.flight.nav")
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")
local I = require("fc.hw.input")
local Op = require("fc.cmd.operator")
local Ro = require("fc.flight.route")
local A = require("fc.core.attitude")

local Ky = {}

-- Power (typewriter 9 and the START/LAND buttons).
function Ky.power(ctx)
    local k = ctx.k
    local landing = ctx.task and ctx.task.kind == "land"
    if k.mode == "STANDBY" then
        Op.run(ctx, {"arm"})
    elseif landing then
        if G.on_ground(ctx, 3) then
            T.abort_task(ctx, "power key on the ground")
            Op.run(ctx, {"disarm"})
        else
            ctx.notice = "landing: keys take over, power only on the ground"
        end
    elseif G.on_ground(ctx) then
        Op.run(ctx, {"disarm"})
    else
        if ctx.task then T.abort_task(ctx, "power key") end
        Op.run(ctx, {"land"})
    end
end

-- W/S step the wanted forward speed. It never runs more than
-- input_speed_lead ahead of the speed the ship has (enough to wake the
-- booster from a standstill), and slowing down starts from the speed it
-- has: W held at top speed once wound the wanted speed up to 1302 b/s
-- while the ship flew 190, and S then took a hundred taps to bite
-- (2026-10-15).
local function step_speed(ctx, dir, step)
    local cfg, m = ctx.cfg, ctx.man
    local v_now = ctx.state and ctx.state.v_fwd or 0
    local v = m.v_f
    if dir < 0 and v > v_now then v = math.max(v_now, 0) end
    v = v + dir * step
    if dir > 0 then v = math.min(v, math.max(v_now, 0) + cfg.input_speed_lead) end
    m.v_f = math.max(-Mn.REVERSE_MAX, math.min(Nv.cruise_speed(cfg, 1e9), v))
end

-- Arrows held: slide sideways at input_side_speed (vector thrusters).
function Ky.strafe(ctx)
    local k, m = ctx.k, ctx.man
    local dir = 0
    if k.mode == "ARMED" and not (ctx.task and (ctx.task.kind == "land" or ctx.task.kind == "takeoff")) then
        if I.is_down(ctx.input, "right") then dir = dir + 1 end
        if I.is_down(ctx.input, "left") then dir = dir - 1 end
    end
    if dir == 0 then
        if ctx.strafing then m.v_r = 0 end
        ctx.strafing = false
        return
    end
    ctx.strafing = true
    m.v_r = dir * ctx.cfg.input_side_speed
end

-- A/D turn only while held; releasing captures the heading. The longer the
-- key is held, the harder the turn: input_turn_min at first, full thrust
-- after input_turn_ramp s (it was a fixed 40 of 200, a fifth of what the
-- autopilot turns with, 2026-10-15); never faster than input_turn_rate deg/s.
function Ky.turn(ctx)
    local k = ctx.k
    if k.mode ~= "ARMED" or (ctx.task and (ctx.task.kind == "land" or ctx.task.kind == "takeoff")) then
        if k.yaw_override then K.set_yaw_override(k, nil) end
        return
    end
    local dir = 0
    if I.is_down(ctx.input, "d") then dir = dir + 1 end
    if I.is_down(ctx.input, "a") then dir = dir - 1 end
    if dir == 0 then
        ctx.turn_dir, ctx.turn_since = nil, nil
        if k.yaw_override then K.set_yaw_override(k, nil) end
        return
    end
    local cfg, now = ctx.cfg, Cx.now(ctx)
    if ctx.turn_dir ~= dir then ctx.turn_dir, ctx.turn_since = dir, now end
    local full = cfg.limits.thrust_max * (ctx.state and ctx.state.vn or 1)
    local share = math.min(1, (now - ctx.turn_since) / cfg.input_turn_ramp)
    local demand = cfg.input_turn_min + (full - cfg.input_turn_min) * share
    local rate = ctx.state and ctx.state.yaw_rate or 0
    if dir * rate > cfg.input_turn_rate then demand = 0 end
    K.set_yaw_override(k, dir * demand)
end

-- Facing a side of the world (owner 2026-10-24): the Minecraft yaw, 0 =
-- south (+z), 90 = west, 180 = north, -90 = east. The owner's own input
-- (Mn.take_over): a hold, goto or route ends; never during a takeoff,
-- landing or dock.
Ky.SIDES = {S = 0, W = 90, N = 180, E = -90}
Ky.SIDE_NAMES = {[0] = "S", [90] = "W", [180] = "N", [-180] = "N", [-90] = "E"}

function Ky.face(ctx, hdg)
    local k, task = ctx.k, ctx.task
    if k.mode ~= "ARMED" then ctx.notice = "face: the motors are off"; return false end
    if task and (task.kind == "land" or task.kind == "takeoff" or task.kind == "dock") then
        ctx.notice = "face: not during the " .. task.kind
        return false
    end
    if ctx.route then Ro.stop(ctx, "face") end
    Mn.take_over(ctx)
    K.set_yaw_override(k, nil)
    ctx.turn_dir, ctx.turn_since, k.yaw_settle = nil, nil, nil
    k.hdg_sp = A.wrap180(hdg)
    Cx.log(ctx, ("facing %s (heading %.0f)"):format(Ky.SIDE_NAMES[math.floor(k.hdg_sp + 0.5)] or "?", k.hdg_sp))
    return true
end

-- The next side to the right (dir 1) or left (-1) of the heading wanted now;
-- within 5 deg of one counts as on it.
function Ky.face_step(ctx, dir)
    local h = ctx.k.hdg_sp or (ctx.state and ctx.state.heading) or 0
    local n = dir > 0 and math.floor((h + 5) / 90) + 1 or math.ceil((h - 5) / 90) - 1
    return Ky.face(ctx, n * 90)
end

-- The keys held now (codes from the key bridge, fc.hw.input; `from`: the
-- sources holding them, for the log); presses and repeats act.
function Ky.handle(ctx, codes, from)
    local now = Cx.now(ctx)
    local fired = I.edges(ctx.input, codes, now)
    local sig = table.concat(codes or {}, " ")
    if sig ~= (ctx.manual_sig or "") then
        ctx.manual_sig = sig
        if sig ~= "" then Cx.log(ctx, "keys: " .. sig .. (from and #from > 0 and (" (" .. table.concat(from, ", ") .. ")") or "")) end
    end
    if ctx.speed_lock and not I.is_down(ctx.input, "w") and not I.is_down(ctx.input, "s") then ctx.speed_lock = nil end
    Ky.turn(ctx)
    Ky.strafe(ctx)
    if fired.keys then
        -- numpad 8, any source: the key hint on the glasses' HUD on or off
        -- (the keys fly the drone either way); once a second at most (it
        -- went on and off within one, 2026-10-24)
        fired.keys = nil
        if now - (ctx.keys_toggled or -math.huge) >= 1 then
            ctx.keys_toggled = now
            ctx.keys_on = not ctx.keys_on
            Cx.log(ctx, "key hint " .. (ctx.keys_on and "on" or "off"))
        end
    end
    if next(fired) == nil then return end
    local cfg, k, m = ctx.cfg, ctx.k, ctx.man
    if ctx.route then Ro.stop(ctx, "keys") end   -- the owner first
    for name, mult in pairs(fired) do
        if name == "power" then
            Ky.power(ctx)
        elseif k.mode ~= "ARMED" then
            -- other keys need ARMED
        elseif name == "w" or name == "s" then
            if not ctx.speed_lock and Mn.take_over(ctx) then step_speed(ctx, name == "w" and 1 or -1, cfg.input_speed_step * mult) end
        elseif name == "a" or name == "d" or name == "left" or name == "right" then
            Mn.take_over(ctx)   -- turning / sliding is handled while held
        elseif name == "space" or name == "shift" then
            if Mn.take_over(ctx) and k.alt_sp then
                local sp = k.alt_sp + (name == "space" and 1 or -1) * cfg.input_alt_step * mult
                local y = ctx.state and ctx.state.pos and ctx.state.pos.y
                local lead = cfg.input_alt_lead
                if y then sp = math.max(y - lead, math.min(y + lead, sp)) end
                k.alt_sp = sp
            end
        elseif name == "stop" then
            if Mn.take_over(ctx) then m.v_f, m.v_r = 0, 0 end
            ctx.speed_lock = I.is_down(ctx.input, "w") or I.is_down(ctx.input, "s") or nil
        elseif name == "zero" then   -- numpad 7: a long W or S undone at once, to go the other way
            if Mn.take_over(ctx) then m.v_f = 0 end
            ctx.speed_lock = I.is_down(ctx.input, "w") or I.is_down(ctx.input, "s") or nil
        elseif name == "face_left" or name == "face_right" then
            Ky.face_step(ctx, name == "face_right" and 1 or -1)
        elseif name == "hold" then
            if Mn.take_over(ctx) then Op.run(ctx, {"hold"}) end
        elseif name == "land" then
            if ctx.task and ctx.task.kind == "takeoff" then T.abort_task(ctx, "land key") end
            if not (ctx.task and ctx.task.kind == "land") then Op.run(ctx, {"land"}) end
        end
    end
end

return Ky
