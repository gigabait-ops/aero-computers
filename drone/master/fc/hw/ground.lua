-- Height above the ground and "on the ground".
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")

local G = {}

G.FRESH = 1.0   -- s: an optical sensor reading older than this is ignored

-- Optical sensors pointing down (Create Simulated, peripheral "optical_sensor",
-- read by fc.lua's ground loop and by nodes, fc.hw.link "ground"): each
-- reading corrected for the hull's tilt, minus that sensor's zero (its
-- reading when the ship stands on its legs, cfg.ground_zeros[name], learned
-- on the ground; cfg.ground_zero for a sensor without one); the height is
-- the lowest. Without a fresh hit: the height above the ground remembered
-- where the ship took off or landed.
-- readings: {{name, d}, ...} (plain numbers count as unnamed sensors);
-- present: the sensors there are, seeing something or not (default #readings).
function G.reading(ctx, readings, now, present)
    local list, best = {}, nil
    for i, r in ipairs(readings) do
        local name, d = "#" .. i, r
        if type(r) == "table" then name, d = r.name, r.d end
        if type(d) == "number" then
            list[#list + 1] = {name = name, d = d}
            if not best or d < best then best = d end
        end
    end
    ctx.gsens = {dist = best, list = list, n = present or #list, t = now or Cx.now(ctx)}
end

local function zero_of(cfg, name)
    local z = cfg.ground_zeros and cfg.ground_zeros[name]
    if type(z) == "number" then return z end
    return cfg.ground_zero >= 0 and cfg.ground_zero or 0
end

-- Each fresh reading as a height above the ground ({{name, above}, ...}), or nil.
function G.heights(ctx)
    local st, g = ctx.state, ctx.gsens
    if not (st and g and g.list and #g.list > 0 and Cx.now(ctx) - g.t <= G.FRESH) then return nil end
    local up = (st.tilt and st.tilt.up) or 1
    local out = {}
    for _, r in ipairs(g.list) do out[#out + 1] = {name = r.name, above = r.d * up - zero_of(ctx.cfg, r.name)} end
    return out
end

function G.above(ctx)
    local st = ctx.state
    if not (st and st.pos) then return nil end
    local hs = G.heights(ctx)
    if hs then
        local above
        for _, h in ipairs(hs) do if not above or h.above < above then above = h.above end end
        ctx.ground_y = st.pos.y - above       -- the terrain under the ship
        ctx.ground_src = "sensor"
        return above
    end
    if ctx.ground_y then ctx.ground_src = "memory"; return st.pos.y - ctx.ground_y end
    return nil
end

-- The range the optical sensors should have now. They cast every tick and
-- cannot be switched off, so high in the air (cruising, far above anything
-- they could see) they are cut to 1 block; the full ground_range comes back
-- for the ground: on it, takeoff, landing, docking, any descent, and within
-- ground_range + 10 of the remembered ground (owner, 2026-10-15).
function G.range(ctx)
    local full, st, task = ctx.cfg.ground_range, ctx.state, ctx.task
    if ctx.k.mode ~= "ARMED" or not (st and st.vel) then return full end
    if task and (task.kind == "takeoff" or task.kind == "land" or task.kind == "dock") then return full end
    if st.vel.y < -1 then return full end
    local above = G.above(ctx)
    if not above or above < full + 10 then return full end
    return 1
end

-- On the legs and at rest in STANDBY: the reading is the zero (saved when it moved by 0.2).
function G.learn_zero(ctx, t)
    local g, st = ctx.gsens, ctx.state
    if not (g and g.dist and st and st.vel) or ctx.k.mode ~= "STANDBY" or ctx.rlinks.want.gear ~= true then ctx.zero_since = nil; return end
    if math.abs(st.vel.y) > 0.02 or t - g.t > G.FRESH then ctx.zero_since = nil; return end
    ctx.zero_since = ctx.zero_since or t
    if t - ctx.zero_since < 3 then return end
    local up = (st.tilt and st.tilt.up) or 1
    local z = math.floor(g.dist * up * 100 + 0.5) / 100
    local zeros = ctx.cfg.ground_zeros or {}
    local changed, parts = math.abs(z - ctx.cfg.ground_zero) > 0.2, {}
    for _, r in ipairs(g.list or {}) do
        local zi = math.floor(r.d * up * 100 + 0.5) / 100
        if type(zeros[r.name]) ~= "number" or math.abs(zi - zeros[r.name]) > 0.2 then changed = true end
        zeros[r.name] = zi
        parts[#parts + 1] = ("%s %.2f"):format(r.name, zi)
    end
    if changed then
        ctx.cfg.ground_zero, ctx.cfg.ground_zeros = z, zeros
        local ok = C.save(Cx.CONFIG_PATH, ctx.cfg)
        Cx.log(ctx, ("ground sensor zero = %.2f on the legs (%s)%s"):format(z, table.concat(parts, ", "), ok and " (saved)" or ""))
    end
end

-- "Resting": still for 2 s with the lift wound down well below hover (see
-- fc.flight.safety), so something other than the motors holds the ship up.
function G.resting(ctx)
    return (ctx.rest or 0) >= 2
end

-- The fuse for every automatic motors-off (touchdown, dock, a route's end;
-- owner 2026-10-24): the optical sensors see, in fresh readings, the ground
-- within CUT_HEIGHT blocks under the ship: all of them, or all but one when
-- there are three or more (one over a hole or a ledge may miss). A
-- remembered ground is not enough: it can be old, and a landing counted
-- within 3 blocks of it.
G.CUT_HEIGHT = 2
function G.seeing(ctx)
    local hs, n = G.heights(ctx), ctx.gsens and ctx.gsens.n or 0
    local near = 0
    for _, h in ipairs(hs or {}) do if h.above <= G.CUT_HEIGHT then near = near + 1 end end
    return near, n
end

function G.sees_ground(ctx)
    local near, n = G.seeing(ctx)
    if n == 0 then return false end
    return near >= (n >= 3 and n - 1 or n)
end

-- Says once per task why the motors stay on. Returns true when they may go off.
function G.may_cut(ctx, task)
    if G.sees_ground(ctx) then return true end
    if task and not task.cut_wait_logged then
        task.cut_wait_logged = true
        local near, n = G.seeing(ctx)
        Cx.log(ctx, ("motors stay on: the ground sensors do not see the ground within %d blocks (%d of %d)"):format(G.CUT_HEIGHT, near, n))
    end
    return false
end

-- On the ground: resting (something holds the ship up), within tol of the
-- ground under it, or still in STANDBY.
function G.on_ground(ctx, tol)
    local st = ctx.state
    if not st or not st.pos then return false end
    if G.resting(ctx) then return true end
    if ctx.ground_y then return st.pos.y - ctx.ground_y < (tol or 1.0) end
    return st.vel and math.abs(st.vel.y) < 0.05 and ctx.k.mode == "STANDBY"
end

return G
