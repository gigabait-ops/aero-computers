-- Recovery: a master that boots to running props takes over (auto-resume),
-- and an overturned ship is rolled back on its props by the keys.
local K = require("fc.flight.controller")
local M = require("fc.flight.mixer")
local Mn = require("fc.flight.manual")
local Tr = require("fc.flight.trim")
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")
local Nd = require("fc.hw.nodes")
local R = require("fc.hw.rlinks")

local Rc = {}

-- A master that boots while the lift motors are already running (the ship
-- was re-assembled in the air, or only the master restarted) must not sit
-- passive: before the first operator command, once every lift node has
-- reported, arm and hold right here when at least half the lift motors run
-- near hover speed, or the ship is falling.
Rc.RESUME_FALL = 2      -- blocks/s down
Rc.RESUME_SETTLE = 0.5  -- s of sensor history before deciding
Rc.RESUME_TRIM = 15     -- rpm: a running trim further than this from the saved one is not taken over
function Rc.auto_resume(ctx, state, now)
    if ctx.resume_done or ctx.k.mode ~= "STANDBY" or ctx.task then return end
    if not (state and state.pos and state.vel) then return end
    ctx.sensed_since = ctx.sensed_since or now
    if now - ctx.sensed_since < Rc.RESUME_SETTLE then return end
    local status = Nd.status(ctx)
    local lift, running, parts = 0, 0, {}
    for id, m in pairs(ctx.cfg.motors) do
        if m.role == "lift" then
            lift = lift + 1
            local s = status[id]
            if not (s and s.ok) then return end   -- wait for every lift node
            local rpm = tonumber(s.applied)
            if rpm then
                parts[#parts + 1] = ("%d:%d"):format(id, rpm)
                -- lifting, not pressing the ship down: on the ground after a
                -- landing the props ran at -128 and it resumed (2026-10-15)
                if rpm * (m.dir or 1) / (m.scale or 1) >= math.max(5, ctx.cfg.hover * 0.5) then running = running + 1 end
            end
        end
    end
    ctx.resume_done = true
    local falling = state.vel.y < -Rc.RESUME_FALL
    table.sort(parts)
    if lift == 0 or (running * 2 < lift and not falling) then
        Cx.log(ctx, ("boot: lift motors at rest (%s), staying passive"):format(table.concat(parts, " ")))
        return
    end
    local ok, err = K.arm(ctx.k, state)
    if not ok then Cx.log(ctx, "auto-resume refused: " .. tostring(err)); return end
    -- Take over without a bump: the collective and the trim the props run at
    -- now become the altitude and attitude integrals. Arming from scratch at
    -- 206 high (hover 41.9 against the 121 needed there) dropped the ship.
    local n, c, p, r = 0, 0, 0, 0
    for id, m in pairs(ctx.cfg.motors) do
        local pos = m.role == "lift" and M.LIFT[m.pos]
        local rpm = pos and status[id] and tonumber(status[id].applied)
        if rpm then
            local v = rpm * (m.dir or 1) / (m.scale or 1)
            n, c, p, r = n + 1, c + v, p + pos.pitch * v, r + pos.roll * v
        end
    end
    if n > 0 then
        c, p, r = c / n, p / n, r / n
        ctx.k.alt_pid.integral = c - K.hover_at(ctx.cfg, ctx.state and ctx.state.pos and ctx.state.pos.y)
        -- on the ground the props' difference is what pressed against it,
        -- not a trim (resumed on a tree it seeded roll -27, 2026-10-15)
        -- and one far from the saved trim is something pressing on the hull
        -- (resumed with its nose on a roof it seeded pitch -20 for +10)
        local saved = ctx.cfg.trim or {}
        if not G.on_ground(ctx, Tr.LOW) and math.abs(r - (saved.roll or 0)) <= Rc.RESUME_TRIM
            and math.abs(p - (saved.pitch or 0)) <= Rc.RESUME_TRIM then
            K.set_trim(ctx.k, {roll = r, pitch = p})
        end
    end
    Mn.reset(ctx)
    ctx.notice = "AUTO-RESUME: motors were running at boot"
    Cx.log(ctx, ("auto-resume: %s at boot (lift %s), nobody in control -> ARMED, holding alt %.1f hdg %.1f"):format(
        falling and ("falling %.1f b/s"):format(-state.vel.y) or "lift motors running", table.concat(parts, " "),
        state.pos.y, state.heading or 0))
end

-- Overturned (K.overturned: past 60 deg, on its back included) the ship
-- cannot fly, so in STANDBY the keys drive the lift props directly to roll
-- it back (2026-10-15 it lay on its back and no key answered): A / D the
-- left / right pair in reverse, W / S the front / rear pair, Shift all four
-- in reverse, Space all four ahead. A key starts at FLIP_MIN rpm and
-- reaches full reverse (lift_min) after input_turn_ramp s held; together
-- the props never pass FLIP_TOTAL of the hover thrust, so the ship cannot
-- take off on them. Back within 40 deg of level (FLIP_DONE) they stop.
Rc.FLIP_MIN, Rc.FLIP_TOTAL, Rc.FLIP_DONE = 60, 0.8, 0.77
Rc.FLIP_KEYS = {
    a = {front_left = -1, rear_left = -1}, d = {front_right = -1, rear_right = -1},
    w = {front_left = -1, front_right = -1}, s = {rear_left = -1, rear_right = -1},
    shift = {front_left = -1, front_right = -1, rear_left = -1, rear_right = -1},
    space = {front_left = 1, front_right = 1, rear_left = 1, rear_right = 1},
}
function Rc.flip_step(ctx, state, now)
    local k, cfg = ctx.k, ctx.cfg
    local was_on = ctx.flip_on
    ctx.flip_on = nil
    if k.mode ~= "STANDBY" or not (state and state.tilt) then ctx.flip = nil; return nil end
    if K.overturned(cfg, state) then
        if not ctx.flip then Cx.log(ctx, "overturned: A/D, W/S, Shift spin the props in reverse") end
        ctx.flip = true
    elseif ctx.flip and (state.tilt.up or 1) >= Rc.FLIP_DONE then
        ctx.flip = nil
        Cx.log(ctx, "upright again: props stopped")
    end
    local lim = cfg.limits
    local want, any = {}, false
    if ctx.flip then
        for name, pair in pairs(Rc.FLIP_KEYS) do
            local h = ctx.input.held[name]
            if h then
                any = true
                local share = math.min(1, math.max(0, now - h.since) / cfg.input_turn_ramp)
                local rpm = Rc.FLIP_MIN + (-lim.lift_min - Rc.FLIP_MIN) * share
                for pos, sign in pairs(pair) do want[pos] = (want[pos] or 0) + sign * rpm end
            end
        end
    end
    if not any then
        if was_on then k.idle_cycles = K.IDLE_BURST end   -- released: props back to idle
        return nil
    end
    if R.engine_off(ctx) then ctx.notice = R.ENGINE_OFF end
    local n, sum = 0, 0
    for _, m in pairs(cfg.motors) do if m.role == "lift" then n = n + 1 end end
    for _, v in pairs(want) do sum = sum + math.abs(v) end   -- scaled before clamping: A+Shift keeps the left pair harder
    local cap = Rc.FLIP_TOTAL * n * cfg.hover
    local f = sum > cap and cap / sum or 1
    local targets = M.idle(cfg.motors, 0)
    for id, m in pairs(cfg.motors) do
        if m.role == "lift" and want[m.pos] then
            local v = math.max(lim.lift_min, math.min(lim.max_speed, want[m.pos] * f * (m.scale or 1)))
            targets[id] = math.floor(v * (m.dir or 1) + 0.5)
        end
    end
    ctx.flip_on = true
    return {type = "set", targets = targets, fallback = M.idle(cfg.motors, 0)}
end

return Rc
