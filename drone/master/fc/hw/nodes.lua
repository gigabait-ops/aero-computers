-- The motor nodes as the flight computer sees them: targets out, telemetry
-- in, who is alive, the kinetic power, the thrusters on each corner.
-- (fc.hw.link is the protocol itself.)
local L = require("fc.hw.link")
local Cx = require("fc.core.ctx")

local Nd = {}

function Nd.send(ctx, action)
    if action.type == "set" then
        L.broadcast_set(ctx.link, action.targets, action.fallback)
    elseif action.type == "idle" then
        L.broadcast_idle(ctx.link, action.targets)
    else
        return
    end
    ctx.last_action = action
end

function Nd.handle_message(ctx, sender, msg)
    return L.handle(ctx.link, sender, msg, Cx.now(ctx))
end

-- Node liveness uses telemetry_timeout (3 s): telemetry arrives once a second.
function Nd.status(ctx)
    return L.status(ctx.link, Cx.now(ctx), ctx.cfg.motors, ctx.cfg.telemetry_timeout)
end

local function node_line(ctx, id, s)
    local m = ctx.cfg.motors[id]
    return ("%d %s %s: %s age %s mode %s target %s applied %s pending %s%s%s"):format(
        id, m.role, m.pos, s.ok and "ok" or (s.age and "BAD" or "MISSING"),
        s.age and ("%.1f"):format(s.age) or "--", tostring(s.mode), tostring(s.target), tostring(s.applied),
        tostring(s.apply_pending), s.apply_err and (" err " .. tostring(s.apply_err)) or "",
        s.stress and (" stress %s/%s%s"):format(tostring(s.stress.su), tostring(s.stress.cap), s.stress.over and " OVERSTRESSED" or "") or "")
end

-- One line per configured motor (the `nodes` command).
function Nd.lines(ctx)
    local st, ids, lines = Nd.status(ctx), {}, {}
    for id in pairs(ctx.cfg.motors) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do lines[#lines + 1] = node_line(ctx, id, st[id]) end
    return lines
end

-- Kinetic power as seen by the first node with a Stressometer: {su, cap, over}, or nil.
function Nd.power_status(ctx)
    local st = Nd.status(ctx)
    local ids = {}
    for id in pairs(st) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local s = st[id]
        if s.ok and s.stress then return s.stress end
    end
    return nil
end

-- Called from the UI loop: log when the kinetic network becomes overstressed or recovers.
function Nd.watch_power(ctx)
    local p = Nd.power_status(ctx)
    local over = p and p.over or false
    if over ~= (ctx.power_over or false) then
        ctx.power_over = over
        Cx.log(ctx, over and ("POWER LOST: kinetic network overstressed (%s/%s su)"):format(tostring(p.su), tostring(p.cap))
            or "power back: network no longer overstressed")
    end
    if over then ctx.k.warn = "POWER: overstressed, no thrust" end
end

-- Vector thrusters per corner from the nodes (two on a corner since
-- 2026-10-20): the mixer shares a corner's throttle among them and the
-- demands may go up to vn times thrust_max (vn = the fewest on a corner).
-- A change is logged; it is shown on the screens only when the corners
-- differ (a thruster missing), not "2 per corner" at every start (owner
-- 2026-10-23).
function Nd.vector_counts(ctx)
    local counts, vn, known = L.vector_counts(ctx.link, ctx.cfg.motors)
    local ids, parts, same = {}, {}, true
    for id in pairs(counts) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        parts[#parts + 1] = ("%d:%d"):format(id, counts[id])
        if counts[id] ~= vn then same = false end
    end
    local sig = table.concat(parts, " ")
    -- said once every node has reported (at boot they come in one by one)
    if known and sig ~= ctx.vsig and (ctx.vsig or vn > 1 or not same) then
        local line = same and ("vectors: %d per corner"):format(vn) or ("vectors: " .. sig)
        Cx.log(ctx, line)
        if not same then ctx.notice = line
        elseif ctx.notice and ctx.notice:find("^vectors: ") then ctx.notice = nil end   -- the short corner is back
    end
    if known then ctx.vsig = sig end
    ctx.vcounts, ctx.vn = counts, vn
end

return Nd
