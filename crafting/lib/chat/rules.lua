-- What the chat relay does with each key (2026-10-26).
--   level: ok | info | warn | error (the mark and colour)
--   mode:  now     - say it at once
--          summary - add params[sum] per params[by]; one "header" line each period
--          once    - say it, then stay quiet about the same params[by] for an hour
--   now:   params that make it "now" anyway ({source = "manual"}: PC66 orders)
--   as:    the key used when not "now" (a shorter wording for summaries/once)
--   clears: a successful key that lets the paired warning be said again
-- A key with no rule is said at once as "info".
return {
    ["craft.done"] = {level = "ok", mode = "summary", sum = "crafted", by = "target",
        header = "craft.summary", now = {source = "manual"}},
    ["craft.missing"] = {level = "error", mode = "once", by = "raw", as = "craft.shortage",
        asLevel = "warn", now = {source = "manual"}},
    ["craft.failed"] = {level = "error", mode = "once", by = "target", now = {source = "manual"}},
    ["station.ship_incomplete"] = {level = "warn", mode = "once"},
    ["worker.offline"] = {level = "warn", mode = "once", by = "id"},
    ["worker.online"] = {level = "ok", mode = "now", clears = "worker.offline", by = "id", onlyIfCleared = true},
    ["system.started"] = {level = "info", mode = "now"},
}
