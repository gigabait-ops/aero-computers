-- Black box: the last `n` lines the program said, kept in memory only. When
-- something goes wrong (BB.trip: a tilt abort, motors cut, props stalled,
-- sensor lost, a crash) they are written out, and everything for `follow`
-- seconds after; a normal flight writes nothing. Pure: `write(lines)` does
-- the disk part.
local BB = {}

function BB.new(n, write, follow)
    return {n = n, lines = {}, head = 0, write = write, follow = follow or 30}
end

function BB.add(bb, line, now)
    bb.head = bb.head % bb.n + 1
    bb.lines[bb.head] = line
    if bb.until_t then
        if now <= bb.until_t then bb.write({line}) else bb.until_t = nil end
    end
end

-- Write what led up to it (oldest first), then keep writing for `follow` s.
-- A second trip while still writing only adds its marker.
function BB.trip(bb, why, now)
    local out = {"=== " .. tostring(why) .. " ==="}
    if not bb.until_t then
        for i = 1, bb.n do
            local l = bb.lines[(bb.head + i - 1) % bb.n + 1]
            if l then out[#out + 1] = l end
        end
    end
    bb.write(out)
    bb.until_t = now + bb.follow
end

return BB
