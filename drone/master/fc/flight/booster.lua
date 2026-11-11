-- The ion cube (booster): when it may push and how hard.
local Cx = require("fc.core.ctx")
local Nd = require("fc.hw.nodes")

local B = {}

-- Boosters push hard (the ion cube: 0 -> 18 b/s in 2 s), so they are only
-- for a cruise: a goto leg wanting at least limits.booster_min_v, or a
-- manual speed that high, and they fade out over the last booster_band
-- b/s below that speed. Near a point, landing, docking, holding or braking
-- they stay off (a re-approach on the cube overshot again and again,
-- 2026-10-15). Returns 0..1, the share of the booster the moment wants.
local function booster_room(ctx)
    local lim = ctx.cfg.limits
    local want
    if ctx.task then
        local o = ctx.task.kind == "goto" and ctx.task.last
        if o and o.braking then return 0 end
        want = o and o.v_des
    elseif ctx.k.mode == "ARMED" then
        want = ctx.man.v_f
    end
    if not want or want < lim.booster_min_v then return 0 end
    -- it fades over the last booster_band b/s only (a wide band left the
    -- cruise 13-17 b/s short of the set speed: the vectors alone cannot hold it)
    local v = ctx.state and ctx.state.v_fwd or 0
    return math.max(0, math.min(1, (want - v - 1) / lim.booster_band))
end

-- An ion cube drains its buffer in seconds at full throttle (the supply
-- held about 30 %, 2026-10-15). Below booster_low of its energy the booster
-- is held at booster_sustain, so the ship keeps a steady push instead of
-- running dry.
-- The cap changes at most limits.booster_slew per second (dt given): the
-- cube's 30 MN switching on or off swung the nose from -5 to +15 deg.
local function slew(ctx, target, dt)
    if not dt then ctx.boost_s = target; return target end
    local cur = ctx.boost_s or 0
    local step = ctx.cfg.limits.booster_slew * dt
    if target > cur + step then cur = cur + step elseif target < cur - step then cur = cur - step else cur = target end
    ctx.boost_s = cur
    return cur
end

function B.limit(ctx, dt)
    local room = booster_room(ctx)
    if room <= 0 then
        local c = slew(ctx, 0, dt)
        ctx.k.booster_cap = c
        return
    end
    local lim = ctx.cfg.limits
    local cap = 1
    local status = Nd.status(ctx)
    for id, m in pairs(ctx.cfg.motors) do
        local s = status[id]
        if m.role == "booster" and s and s.thrust and s.thrust.fe and s.thrust.fe_cap and s.thrust.fe_cap > 0 then
            if s.thrust.fe / s.thrust.fe_cap < lim.booster_low then cap = math.min(cap, lim.booster_sustain) end
        end
    end
    local low = cap < 1
    if low and not ctx.booster_low then Cx.log(ctx, ("booster energy low: held at %.0f %%"):format(cap * 100)) end
    ctx.booster_low = low
    -- the cube's thrust lifts the nose (fine: it carries the ship); only well
    -- past the target it backs off, so the flight never reaches the 30 deg
    -- abort (at 30 MN the nose went to 27 deg, 2026-10-15)
    local st = ctx.state
    if st and st.pitch_deg then
        local over = st.pitch_deg - math.deg(math.asin(math.max(-1, math.min(1, ctx.k.pitch_sp or 0))))
        if over > 18 then cap = 0 elseif over > 12 then cap = math.min(cap, 0.5) end
    end
    cap = slew(ctx, math.min(cap, room), dt)
    ctx.k.booster_cap = cap < 1 and cap or nil
end

return B
