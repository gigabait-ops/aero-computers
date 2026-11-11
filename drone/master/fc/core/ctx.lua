-- The flight computer's context (`ctx`, made by fc.engine): its clock, the
-- log (the screens' report list, the log sink, the black box), incidents,
-- notices and saving the config. Every module that keeps or reports state
-- goes through these.
local C = require("fc.core.config")

local Cx = {}

Cx.CONFIG_PATH = "/fc_config.lua"
Cx.REPORT_LIMIT = 50     -- lines kept for the screens' Recent list
-- A notice (a refusal, "AUTO-RESUME ...") is news, not a state: it goes
-- after NOTICE_FOR s (the auto-resume one stayed on the screens and the
-- glasses for the rest of the flight, 2026-10-18).
Cx.NOTICE_FOR = 30

function Cx.now(ctx)
    return ctx.clock()
end

function Cx.log(ctx, line)
    if ctx.deps.log then ctx.deps.log(line) end
    local r = ctx.report
    r[#r + 1] = line
    while #r > Cx.REPORT_LIMIT do table.remove(r, 1) end
end

-- Something went wrong: the black box writes what led up to it.
function Cx.incident(ctx, why)
    if ctx.deps.incident then pcall(ctx.deps.incident, why) end
end

function Cx.fade_notice(ctx)
    if ctx.notice ~= ctx.notice_seen then ctx.notice_seen, ctx.notice_t = ctx.notice, Cx.now(ctx) end
    if ctx.notice and Cx.now(ctx) - (ctx.notice_t or 0) > Cx.NOTICE_FOR then ctx.notice, ctx.notice_seen = nil, nil end
end

-- Saves the config after a change from a screen: logs "<what> (saved)", or
-- shows the failure as a notice. Returns true when saved.
function Cx.save(ctx, what)
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    if ok then
        ctx.notice = nil
        Cx.log(ctx, what .. " (saved)")
    else
        ctx.notice = "save failed: " .. tostring(err)
        Cx.log(ctx, ctx.notice)
    end
    return ok
end

return Cx
