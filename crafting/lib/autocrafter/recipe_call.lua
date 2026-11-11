-- pcall for the recipes module (Recipe Atlas) with a wait on transient
-- refusals: the per-computer call budget (rate_limited; "rate_limited: legacy"
-- for the 1/s unpaged record calls) and runtime admission (runtime_busy,
-- runtime_rate_limited). Other errors return at once.
local Call = {}

-- The error code: Recipe Atlas raises "<code>: <path>[=<value>]" and CC puts
-- "chunk:line: " in front.
function Call.code(err)
    err = tostring(err or ""):gsub("^[^:]*:%d+: ", "")
    return err:match("^([%w_]+)") or err, err
end

local function transient(err)
    local code = Call.code(err)
    return code == "rate_limited" or code == "runtime_busy" or code == "runtime_rate_limited"
end
Call.transient = transient

-- How long a rate_limited refusal asks to wait, from meta().callBudget (free
-- to call). A refused record call may have spent its legacy token too, so the
-- longer of the two waits wins. nil when the module does not say.
local function budgetWait(err)
    if Call.code(err) ~= "rate_limited" then return nil end
    local api = type(recipes) == "table" and recipes or package.loaded.recipes
    if type(api) ~= "table" or type(api.meta) ~= "function" then return nil end
    local ok, meta = pcall(api.meta)
    local budget = ok and type(meta) == "table" and meta.callBudget
    if type(budget) ~= "table" then return nil end
    local legacy = type(budget.legacyRecords) == "table" and budget.legacyRecords or {}
    local ms = math.max(tonumber(budget.retryAfterMs) or 0, tonumber(legacy.retryAfterMs) or 0)
    return ms > 0 and math.min(ms, 2000) / 1000 or nil
end

function Call.pcall(fn, ...)
    local result
    for attempt = 1, 3 do
        result = table.pack(pcall(fn, ...))
        if result[1] or not transient(result[2]) or attempt == 3 then break end
        if type(sleep) == "function" then sleep(budgetWait(result[2]) or attempt * 0.5) end
    end
    return table.unpack(result, 1, result.n)
end

-- Waits until the server's recipe snapshot is published. At server start
-- Recipe Atlas builds it in the background: for a few seconds after the
-- console's "Done" on Aero, meta().ready is false and the other calls raise
-- not_ready, so an order planned then fails with RECIPES_NOT_READY. Gives up
-- after `seconds` (the module missing or broken: the planner reports it as before).
function Call.waitReady(api, seconds, pause)
    if type(api) ~= "table" or type(api.meta) ~= "function" then return false end
    pause = pause or (type(sleep) == "function" and sleep) or nil
    for _ = 1, math.max(1, tonumber(seconds) or 60) do
        local ok, meta = pcall(api.meta)
        if ok and type(meta) == "table" and meta.ready == true then return true end
        if not pause then return false end
        pause(1)
    end
    return false
end

-- Waits while a /reload rebuild is pending. Recipe Atlas builds the new
-- snapshot in the background: for about 3 s the previous generation is served
-- with refreshPending=true and runtime checks (preview, matchesIngredient)
-- raise stale_snapshot. Returns the fresh meta, or the last one after
-- `seconds`. A failed rebuild (refreshStatus "failed") is not waited for, and
-- the start-up window (ready=false) is waitReady's job.
function Call.waitFresh(api, seconds, pause)
    pause = pause or (type(sleep) == "function" and sleep) or nil
    local meta
    for _ = 1, math.max(1, math.floor((tonumber(seconds) or 15) * 2)) do
        local ok, value = pcall(api.meta)
        meta = ok and type(value) == "table" and value or nil
        if not meta or meta.ready ~= true or meta.refreshPending ~= true or meta.refreshStatus == "failed"
            or not pause then
            return meta
        end
        pause(0.5)
    end
    return meta
end

return Call
