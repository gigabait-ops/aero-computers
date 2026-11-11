-- The attitude trim: where it may learn in flight and what a flight keeps.
local K = require("fc.flight.controller")
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")

local Tr = {}

Tr.LOW = 3     -- blocks: the attitude trim learns only higher above the ground than this
Tr.LEARN = 20  -- s of learning in a flight before its trim is kept
Tr.NEAR = 8    -- blocks: landing / taking off, no learning closer to the ground (a dock edge holds the hull where the sensors see further down)

-- No trim learning where the hull may rest on something: the last blocks
-- of a landing, a takeoff or a dock. The way down from the flight height
-- learns: frozen from 251 down, the trim kept the thin-air +19 for the
-- +10 needed at the dock, the nose came up 5 deg and the ship sat on its
-- rear legs off the point (2026-10-17).
function Tr.learning(ctx, state, above)
    local task, near = ctx.task, false
    if task and task.kind == "dock" then
        -- at creep_lift the legs are clear of the dock: it learns there, so a
        -- wrong trim levels out before the settle
        near = task.settling or (state ~= nil and state.pos.y < task.dock.y + ctx.cfg.dock.creep_lift - 1)
    elseif task and (task.kind == "land" or task.kind == "takeoff") then
        near = above == nil or above < Tr.NEAR
    end
    K.set_learning(ctx.k, not near)
end

-- The attitude trim learned in flight is kept for the next one: saved when
-- the ship leaves ARMED if it moved by 1 rpm or more.
-- Only a flight that learned for LEARN s without an upset counts, and
-- what it keeps is the averaged trim (K.kept_trim).
-- The hover by height learned this flight (fc.flight.controller), saved
-- when the motors stop, unless something upset the flight.
function Tr.keep_hover(ctx)
    local k = ctx.k
    if not k.hover_dirty then return false end
    k.hover_dirty = false
    if k.upset then return false end
    local parts = {}
    for _, p in ipairs(ctx.cfg.hover_curve or {}) do parts[#parts + 1] = ("%d:%.1f"):format(p.y, p.c) end
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    Cx.log(ctx, ("hover by height: %s%s"):format(table.concat(parts, " "), ok and " (saved)" or (" (save failed: " .. tostring(err) .. ")")))
    return ok
end

function Tr.keep(ctx)
    if ctx.k.upset or (ctx.k.learn_t or 0) < Tr.LEARN then return false end
    local tr = K.kept_trim(ctx.k)
    local cur = ctx.cfg.trim
    if math.abs(tr.roll - cur.roll) < 1 and math.abs(tr.pitch - cur.pitch) < 1 then return false end
    local function tenth(v) return math.floor(v * 10 + 0.5) / 10 end
    ctx.cfg.trim = {roll = tenth(tr.roll), pitch = tenth(tr.pitch)}
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    Cx.log(ctx, ("trim learned: roll %+.1f pitch %+.1f rpm%s"):format(ctx.cfg.trim.roll, ctx.cfg.trim.pitch,
        ok and " (saved)" or (" (save failed: " .. tostring(err) .. ")")))
    return true
end

return Tr
