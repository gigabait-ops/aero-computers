-- The SETTINGS page: the few config fields the owner changes himself, and
-- RESET back to the tested trim and hover. Every change is validated and saved.
local K = require("fc.flight.controller")
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")
local U = require("fc.core.util")
local G = require("fc.hw.ground")

local St = {}

-- Each row edits one config field in steps or by a typed value.
St.SETTINGS = {
    -- MAX (0) sits above the top: - from MAX gives 200, + past 200 gives MAX
    {label = "Cruise speed", path = {"ap", "speed"}, unit = "b/s", step = 10, min = 1, max = 200, zero = "MAX"},
    {label = "Flight height", path = {"ap", "cruise_y"}, unit = "", step = 5, min = -64, max = 320},
    -- the button look of the screens and the glasses (owner 2026-10-23: all of them on offer)
    {label = "Buttons", path = {"ui", "buttons"}, choices = C.BUTTON_STYLES},
}

local function text(spec, v)
    if spec.choices then return tostring(v or spec.choices[1]) end
    if type(v) ~= "number" then return "--" end
    if v == 0 and spec.zero then return spec.zero end
    return ((v % 1 == 0) and ("%d"):format(v) or ("%.1f"):format(v)) .. (spec.unit ~= "" and (" " .. spec.unit) or "")
end

function St.set(ctx, index, value)
    local spec = St.SETTINGS[index]
    if not spec then return false end
    if spec.choices then
        local want, found = tostring(value or ""):lower():gsub("%s", ""), nil
        for _, c in ipairs(spec.choices) do if c == want then found = c end end
        if not found then ctx.notice = spec.label .. ": " .. table.concat(spec.choices, " "); return false end
        value = found
    else
        if type(value) == "string" and spec.zero and value:upper() == spec.zero then value = 0 end
        value = tonumber(value)
        if not value then ctx.notice = spec.label .. ": enter a number"; return false end
        if not (spec.zero and value == 0) then value = math.max(spec.min, math.min(spec.max, value)) end
    end
    local old = U.get_path(ctx.cfg, spec.path)
    U.set_path(ctx.cfg, spec.path, value)
    local ok, err = C.validate(ctx.cfg)
    if not ok then
        U.set_path(ctx.cfg, spec.path, old)
        ctx.notice = "refused: " .. tostring(err)
        return false
    end
    return Cx.save(ctx, ("%s = %s"):format(spec.label, text(spec, value)))
end

function St.adjust(ctx, index, dir)
    local spec = St.SETTINGS[index]
    if not spec then return false end
    if spec.choices then   -- the next (or the one before), round
        local cur, at = U.get_path(ctx.cfg, spec.path), 1
        for i, c in ipairs(spec.choices) do if c == cur then at = i end end
        return St.set(ctx, index, spec.choices[(at - 1 + (dir > 0 and 1 or -1)) % #spec.choices + 1])
    end
    local v = tonumber(U.get_path(ctx.cfg, spec.path)) or spec.min
    if spec.zero then
        -- whole steps (a typed 44 goes to 50 or 40); MAX sits above the top
        if v == 0 then return St.set(ctx, index, dir > 0 and 0 or spec.max) end
        local n = dir > 0 and (math.floor(v / spec.step) + 1) * spec.step or (math.ceil(v / spec.step) - 1) * spec.step
        if n > spec.max then n = 0 elseif n < spec.step then n = spec.step end
        return St.set(ctx, index, n)
    end
    return St.set(ctx, index, v + dir * spec.step)
end

function St.rows(ctx)
    local rows = {}
    for i, spec in ipairs(St.SETTINGS) do
        rows[i] = {label = spec.label, value = text(spec, U.get_path(ctx.cfg, spec.path))}
    end
    return rows
end

-- RESET: back to the tested state after an upset: the trim and hover the
-- ship flew well with (cfg.baseline, stored by the `baseline` command after
-- a good test hover; trim 0/0 without one), and the lift and speed limits
-- and held legs of this flight forgotten. Only on the ground, pressed
-- twice; motors that still run there stop. The engine switch stays as the
-- owner set it. (2026-10-15: a landing propped on the dock edge left trim
-- -30/-20 saved, and it took a hand reset to fly again.)
function St.reset(ctx)
    local k = ctx.k
    if k.mode ~= "STANDBY" and not G.on_ground(ctx, 3) then ctx.notice = "Reset: land first"; return false end
    local now = Cx.now(ctx)
    local c = ctx.confirm
    if not (c and c.action == "reset" and now <= c.until_t) then
        ctx.confirm = {action = "reset", until_t = now + 10}
        ctx.notice = "Reset? press RESET again within 10 s"
        return false
    end
    ctx.confirm = nil
    if ctx.task then T.abort_task(ctx, "reset") end
    k.upset = true   -- what this flight learned is what goes: not kept on the way to STANDBY
    if k.mode ~= "STANDBY" then K.disarm(k) end
    local b = ctx.cfg.baseline or {}
    local bt = b.trim or {}
    ctx.cfg.trim = {roll = bt.roll or 0, pitch = bt.pitch or 0}
    if b.hover then ctx.cfg.hover = b.hover end
    ctx.cfg.hover_curve = {}   -- the hover by height is learned again
    K.reset_integrals(k)
    ctx.v_lift_max, ctx.v_lift_t = nil, nil
    ctx.rlinks.override.gear = nil
    ctx.flip = nil
    Mn.reset(ctx)
    local ok = Cx.save(ctx, ("reset: trim roll %+.1f pitch %+.1f, hover %.1f"):format(ctx.cfg.trim.roll, ctx.cfg.trim.pitch, ctx.cfg.hover))
    if ok then ctx.notice = "Reset done: trim and hover as tested" end
    return ok
end

return St
