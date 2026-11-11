-- The status line: one compact line of everything the controller does, for
-- the black box and /fc.log (while logging is on). Not shown on the screens.
local V = require("fc.ui.view")

local SL = {}

local function num(v, f)
    if v == nil or v ~= v then return "--" end
    return (f or "%.1f"):format(v)
end

function SL.line(view)
    local st = view.state
    local ok, total = V.motors_ok(view)
    local mode = tostring(view.mode) .. (view.task and ("/" .. view.task.kind) or "")
    local body
    if st then
        body = ("roll %s pitch %s hdg %s/%s alt %s/%s vy %s spd %s"):format(
            num(st.roll_deg), num(st.pitch_deg), num(st.heading), num(view.hdg_sp),
            num(st.pos and st.pos.y), num(view.alt_sp), num(st.vel and st.vel.y, "%.2f"), num(st.speed))
    else
        body = "sensor: " .. tostring(view.err or "unavailable")
    end
    local out = ("%s %s %s nodes %d/%d"):format(num(view.now), mode, body, ok, total)
    if view.dt then out = out .. (" dt %.2f"):format(view.dt) end
    if view.mass then out = out .. (" m %.0f"):format(view.mass) end
    if view.above then out = out .. (" agl %.1f%s"):format(view.above, view.ground_src == "sensor" and "s" or "m") end
    local gs = view.ground_seen
    if gs and gs[2] and gs[2] > 0 then out = out .. (" gs %d/%d"):format(gs[1], gs[2]) end
    if view.trim and view.mode ~= "STANDBY" then out = out .. (" trim r%+.0f p%+.0f"):format(view.trim.roll or 0, view.trim.pitch or 0) end
    if st and st.pos then   -- parked too: where it sits against a dock
        out = out .. (" xz %.2f %.2f"):format(st.pos.x, st.pos.z)
        if view.mode ~= "STANDBY" then out = out .. (" vf %.1f vr %.1f"):format(st.v_fwd or 0, st.v_right or 0) end
    end
    if view.nav and view.nav.dist then
        out = out .. (" goto d=%.0f brg=%.0f err=%.0f"):format(view.nav.dist, view.nav.bearing or 0, view.nav.hdg_err or 0)
        if view.nav.v_des and view.nav.v_des < 1e8 then out = out .. (" vdes=%.1f"):format(view.nav.v_des) end
    end
    if view.targets then
        local ids = {}
        for id in pairs(view.targets) do ids[#ids + 1] = id end
        table.sort(ids)
        local parts = {}
        for _, id in ipairs(ids) do
            local tgt = view.targets[id]
            parts[#parts + 1] = type(tgt) == "table" and ("%d:%.2f/%.1f"):format(id, tgt.thr or 0, tgt.vx or 0) or ("%d:%d"):format(id, tgt)
        end
        out = out .. " t " .. table.concat(parts, " ")
    end
    local p = view.pilot
    if p and (p.forward ~= 0 or p.side ~= 0 or p.climb ~= 0) then
        out = out .. (" pilot f%.0f s%.0f c%.1f"):format(p.forward or 0, p.side or 0, p.climb or 0)
    end
    if view.man and view.mode == "ARMED" and not view.task then
        out = out .. (" man %.0f/%.0f%s"):format(view.man.v_f, view.man.v_r, view.man.hold and " hold" or "")
    end
    if view.links and view.links.bridge then out = out .. (" legs %s"):format(view.links.gear and "dn" or "up") end
    -- boosters and vectors: thrust (kN) and the energy buffer as the
    -- thrusters report them (vectors with no energy gave no thrust at full
    -- throttle after the wing move, 2026-10-23)
    local ids = {}
    for id in pairs(view.motors or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local m, s = view.motors[id], (view.status or {})[id]
        if (m.role == "booster" or m.role == "vector") and s and s.thrust then
            out = out .. (" %s%d %skN"):format(m.role == "booster" and "b" or "v", id, num(s.thrust.kn, "%.0f"))
            if s.thrust.fe then out = out .. ("/%s%%"):format(num(100 * s.thrust.fe / math.max(1, s.thrust.fe_cap or 1), "%.0f")) end
        end
    end
    if view.power then out = out .. (" su %s/%s%s"):format(tostring(view.power.su), tostring(view.power.cap), view.power.over and " OVER" or "") end
    if view.warn then out = out .. " ! " .. tostring(view.warn) end
    return out
end

return SL
