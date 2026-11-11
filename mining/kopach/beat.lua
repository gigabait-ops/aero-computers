-- When a turtle tells the remote how it is (owner 2026-11-05: no radio for
-- nothing). Pure: the caller gives the clock and what it is doing.
--   short  word, note, band and row changed (at most every QUICK s), or BEAT s passed
--   full   also the inventory, home and label: every FULL s, or when the remote asks
local Beat = {BEAT = 15, FULL = 60, QUICK = 1, ASKED = 2}

function Beat.new() return {sent = -100, full = -100, key = nil} end

-- key: what the remote shows (word, note, band, row) as one string; asked:
-- the remote pinged. Returns "full", "short" or nil, and marks it sent.
function Beat.due(b, now, key, asked)
    local kind
    if (asked and now - b.full >= Beat.ASKED) or now - b.full >= Beat.FULL then kind = "full"
    elseif (key ~= b.key and now - b.sent >= Beat.QUICK) or now - b.sent >= Beat.BEAT then kind = "short" end
    if kind then
        b.sent, b.key = now, key
        if kind == "full" then b.full = now end
    end
    return kind
end

return Beat
