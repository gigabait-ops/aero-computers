-- Small helpers the fleet modules share (2026-10-28): counts, failure
-- tables, quiet logging and the rednet protocol names.
local Util = {}

Util.REQUEST_PROTOCOL = "gigabait.craft.request.v1"
Util.WORKER_PROTOCOL = "gigabait.autocrafter.worker.v1"

-- A whole, non-negative count from anything.
function Util.amount(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

-- {code, message, ...fields}
function Util.failure(code, message, fields)
    local err = {code = code, message = message}
    for key, value in pairs(fields or {}) do err[key] = value end
    return err
end

-- logger:info that never throws (no logger is fine).
function Util.log(logger, event, fields)
    if logger and type(logger.info) == "function" then
        pcall(logger.info, logger, event, fields or {})
    end
end

return Util
