-- Asks PC121 (rednet "kopach_supply", found by its host name) for what the
-- linked barrel's slot 1 should hold (owner 2026-11-06): a turtle takes only
-- the first stack, so PC121 puts the asked item there and says "ready".
--   want(item, count) -> {t = "ready", count} | {t = "none"} | {t = "busy", why} | nil (no answer)
--   took()            the turtle has taken it: the next ask may go
--   stock()           -> {[name] = count} of PC121's stock, or nil
-- Supply.take_lava(s, o): ask for lava, burn it bucket by bucket, say took.
local Supply = {}

Supply.PROTO = "kopach_supply"
Supply.HOST = "pc121"
Supply.WAIT = 90   -- the asks are served one by one

function Supply.new()
    local s, seq, id = {}, 0, nil
    local function call(msg, wait)
        id = id or rednet.lookup(Supply.PROTO, Supply.HOST)
        if not id then return nil end
        seq = seq + 1
        local req = os.getComputerID() * 100000 + seq
        msg.req = req
        rednet.send(id, msg, Supply.PROTO)
        if not wait then return true end
        local timer = os.startTimer(wait)
        while true do
            local ev, a, b, c = os.pullEvent()
            if ev == "rednet_message" and a == id and c == Supply.PROTO and type(b) == "table" and b.req == req then
                os.cancelTimer(timer)
                return b
            elseif ev == "timer" and a == timer then
                id = nil   -- looked up again next time
                return nil
            end
        end
    end
    function s.want(item, count) return call({t = "want", item = item, count = count}, Supply.WAIT) end
    function s.took() call({t = "took"}) end
    function s.stock()
        local r = call({t = "stock"}, 4)
        return r and r.items
    end
    return s
end

-- why an ask gave nothing, for the log
function Supply.why(r)
    if not r then return "PC121 silent" end
    return tostring(r.t) .. (r.why and (", " .. r.why) or "")
end

-- With the barrel standing: o = {turtle, suck, drop, want (buckets), full(),
-- free() -> an empty slot, keep_bucket (keep one empty bucket)}.
-- -> taken (bool), the reply, kept (a bucket was kept)
function Supply.take_lava(s, o)
    local t = o.turtle
    local r = s.want("minecraft:lava_bucket", o.want)
    if not (r and r.t == "ready") then return false, r, false end
    local took, kept = 0, false
    for _ = 1, math.min(r.count or o.want, o.want) do
        if o.full() then break end
        local i = o.free()
        if not i then break end
        t.select(i)
        if not o.suck(1) then break end
        local d = t.getItemDetail(i)
        if not (d and d.name == "minecraft:lava_bucket") then
            if d then o.drop() end   -- not the lava: another turtle unloaded in between
            break
        end
        t.refuel()
        took = took + 1
        d = t.getItemDetail(i)
        if d and d.name == "minecraft:bucket" and o.keep_bucket and not kept then kept = true
        elseif d then o.drop() end
    end
    s.took()
    return took > 0, r, kept
end

return Supply
