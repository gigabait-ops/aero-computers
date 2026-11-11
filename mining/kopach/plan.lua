-- The remote's job book: which rows of the current band are free, taken or
-- dug. Rows go out one at a time to whichever turtle asks, nearest first, so
-- the work splits itself over however many turtles answer. A band ends when
-- all its rows are dug; then the next band (3 levels lower) starts.
local G = package.loaded["kopach.geom"] or require("geom")   -- kopach.geom inside another app

local Plan = {}

Plan.STALE = 180   -- seconds: a row taken by a turtle that went silent goes back to the pool
Plan.RETRIES = 2   -- a row done with cells left (another turtle stood there) goes back this often
Plan.ENTER_RETRIES = 10   -- a row no turtle could even get into (left -1): tried this often before it is given up
Plan.SPLIT_MIN = 12  -- a row with at least this many cells still ahead of its digger is shared with a waiting turtle

-- lowest: the deepest level allowed in that world (G.MIN_FLOOR, G.NETHER_FLOOR)
-- build: {walls = bool, roof = bool, floor = bool, up = n | "all", highest = y, mode = "builder",
--         shell = {order = "bulk"|"priority", replace = "holes"|"soft"|"soft+ores"|"all",
--                  materials = {walls = {...}, roof = {...}, floor = {...}}}}
--        (walls on unless false; mode/shell go to the turtles as they are)
-- build.up: levels above the owner's feet too (a number, or "all" up to
-- build.highest: G.NETHER_TOP, G.MAX_Y). The job then starts up there and
-- digs down: the turtles climb their own home column to reach it
-- (owner 2026-11-05: "на всю висоту вверх і на всю висоту вниз").
function Plan.new(center, R, depth, now, lowest, shape, build)
    local feet = math.floor(center.y)
    lowest = lowest or G.MIN_FLOOR
    local floor = lowest
    if depth then floor = math.max(lowest, feet - depth + 1) end
    local top, up = feet, build and build.up
    local highest = build and build.highest or G.MAX_Y
    if up == "all" then top = math.max(feet, highest)
    elseif type(up) == "number" and up > 0 then top = math.max(feet, math.min(highest, feet + up)) end
    local job = {
        id = ("%d"):format(math.floor(now * 1000)),
        cx = math.floor(center.x), cz = math.floor(center.z), feet = feet, up = up ~= 0 and up or nil,
        top = top, floor = math.min(floor, feet), R = R,
        band = 1, rows = {}, started = now, finished = nil, depth = depth or 0, lowest = lowest,
        shape = shape == "square" and "square" or nil,
        box = build and build.box or nil, wet = build and build.wet or nil,
        walls = not (build and build.walls == false), roof = build and build.roof or false,
        floor_on = build and build.floor or false,
        mode = build and build.mode == "builder" and "builder" or nil,
        shell = build and build.shell or nil,
    }
    if job.box then
        local b = job.box
        job.shape = "box"
        job.cx, job.cz = math.floor((b.x0 + b.x1) / 2), math.floor((b.z0 + b.z1) / 2)
        job.R = math.ceil(math.max(b.x1 - b.x0, b.z1 - b.z0) / 2)
    end
    job.bands = G.bands(job)
    Plan.reset_band(job)
    return job
end

-- What a turtle needs to know about the job.
function Plan.summary(job)
    return {id = job.id, cx = job.cx, cz = job.cz, top = job.top, floor = job.floor, R = job.R, bands = job.bands,
        shape = job.shape, box = job.box, wet = job.wet, walls = job.walls, roof = job.roof, floor_on = job.floor_on,
        mode = job.mode, shell = job.shell, layout = job.layout}
end

-- the band being dug for the inspector: its levels and the rows already dug
function Plan.current(job)
    local b = G.layout(job)[job.band]
    if not b or job.finished then return nil end
    local done = {}
    for x, r in pairs(job.rows or {}) do if r.state == "done" then done[x] = true end end
    return {low = b.low, top = b.top, done = done}
end

function Plan.reset_band(job)
    job.rows = {}
    local x0, x1 = G.rows(job)
    for x = x0, x1 do job.rows[x] = {state = "free"} end
end

local function counts(job)
    local free, busy, done = 0, 0, 0
    for _, r in pairs(job.rows) do
        if r.state == "free" then free = free + 1 elseif r.state == "busy" then busy = busy + 1 else done = done + 1 end
    end
    return free, busy, done
end

-- The end of a band (owner 2026-11-06): forty turtles waited for the last
-- row. A turtle with nothing to do takes the far half of what is left of a
-- busy row (its digger's z and way, from its beat: Plan.touch) and digs it
-- from the far end; the digger is told to stop at the meeting cell (reply.cut
-- for the remote to send). The row is done when both have reported.
local function split(job, tid, now)
    local best, bestleft
    for x, r in pairs(job.rows) do
        if r.state == "busy" and r.by ~= tid and not r.helper and not r.digger_done and r.z and r.dz then
            local zmin, zmax = G.span(job, x)
            if zmin then
                local z1 = r.dz > 0 and zmax or zmin
                local left = (z1 - r.z) * r.dz
                if left >= Plan.SPLIT_MIN and (not best or left > bestleft) then best, bestleft = x, left end
            end
        end
    end
    if not best then return nil end
    local r = job.rows[best]
    local zmin, zmax = G.span(job, best)
    local z1 = r.dz > 0 and zmax or zmin
    local meet = r.z + r.dz * math.ceil(bestleft / 2)
    r.helper, r.hat, r.cut = tid, now, meet
    r.part = {from = z1, to = meet + r.dz}
    return {kind = "row", band = job.band, x = best, part = r.part, cut = {tid = r.by, z = meet}}
end

-- alive(tid) -> true while that turtle answers (rows of silent ones are freed after STALE)
function Plan.next_row(job, tid, tx, now, alive)
    if job.finished then return {kind = "finish"} end
    for x, r in pairs(job.rows) do
        if r.state == "busy" and r.helper == tid then return {kind = "row", band = job.band, x = x, part = r.part} end
        if r.state == "busy" and r.by == tid and not r.digger_done then
            -- asked again (a reboot, the remote lost): with a helper on the far
            -- half only its own half, or it digs into the helper (2026-11-08:
            -- 26 and 169 stood in one column and the swarm waited)
            local own
            -- (the side from the helper's half: r.dz follows its beats and
            -- turns round when it walks back)
            if r.helper and r.cut and r.part then
                local zmin, zmax = G.span(job, x)
                if zmin then own = {from = r.part.from == zmin and zmax or zmin, to = r.cut} end
            end
            return {kind = "row", band = job.band, x = x, own = own}
        end
        if r.state == "busy" and r.helper and now - (r.hat or 0) > Plan.STALE and not (alive and alive(r.helper)) then
            r.helper, r.lost_part = nil, true   -- its half was not reported: the row is dug again
            if r.digger_done then job.rows[x] = {state = "free", retries = r.retries} end
        end
        if r.state == "busy" and not r.digger_done and now - r.at > Plan.STALE and not (alive and alive(r.by)) then r.state = "free" end
    end
    while true do
        local best, bestd
        for x, r in pairs(job.rows) do
            if r.state == "free" then
                local d = math.abs(x - (tx or job.cx))
                if not best or d < bestd or (d == bestd and x < best) then best, bestd = x, d end
            end
        end
        if best then
            job.rows[best] = {state = "busy", by = tid, at = now, retries = job.rows[best].retries}
            return {kind = "row", band = job.band, x = best}
        end
        local _, busy = counts(job)
        if busy > 0 then return split(job, tid, now) or {kind = "wait"} end
        if job.band >= (job.last_band or job.bands) then
            job.finished = now
            return {kind = "finish"}
        end
        job.band = job.band + 1
        Plan.reset_band(job)
    end
end

-- left: cells the turtle could not reach (another turtle stood there), -1 when
-- it never got into the circle at all: the row goes back for another try.
-- Returns "retry" or "done" (nil for a row of another band). A turtle parked
-- outside the pit gets no rows at all (app.lua, "buried").
function Plan.row_done(job, tid, band, x, left, part)
    local r = job.rows[x]
    if band ~= job.band or not r then return nil end
    if part then
        -- a helper's half: the row is done when its digger is too
        if r.helper ~= tid then return nil end
        r.helper = nil
        if r.digger_done then
            job.rows[x] = r.retry and {state = "free", retries = (r.retries or 0) + 1} or {state = "done", by = r.by}
            return job.rows[x].state
        end
        return "half"
    end
    if r.helper and r.state == "busy" then
        -- its digger is through (stopped at the cut): wait for the helper's half
        r.digger_done = true
        r.retry = (left or 0) ~= 0 and (r.retries or 0) < Plan.RETRIES
        return "half"
    end
    if r.lost_part then left = math.max(left or 0, 1) end   -- the half of a helper that went silent
    local tries = r.retries or 0
    -- never reached at all: not dug, so not done (only after many tries, so a
    -- row nobody can get into does not hold the band for ever)
    if (left or 0) < 0 and tries < Plan.ENTER_RETRIES then
        job.rows[x] = {state = "free", retries = tries + 1}
        return "retry"
    end
    if (left or 0) > 0 and tries < Plan.RETRIES then
        job.rows[x] = {state = "free", retries = tries + 1}
        return "retry"
    end
    job.rows[x] = {state = "done", by = tid}
    return "done"
end

-- The rows a turtle holds go back to the pool (it is outside the pit, or stuck).
function Plan.release(job, tid)
    local n = 0
    for x, r in pairs(job.rows) do
        if r.state == "busy" and r.helper == tid then
            r.helper, r.lost_part = nil, true
            if r.digger_done then job.rows[x] = {state = "free", retries = r.retries} end
            n = n + 1
        elseif r.state == "busy" and r.by == tid and not r.digger_done then
            job.rows[x] = {state = "free", retries = r.retries} n = n + 1
        end
    end
    return n
end

-- Fixes the inspector found (kopach/inspect.lua): cells of dug levels with a
-- block left inside ("dig") or a hole in the wall ("wall"). Free diggers take
-- a few near each other when they would otherwise wait.
Plan.FIX_MAX = 600       -- kept at most (holes first)
Plan.FIX_STALE = 600     -- a fix taken this long ago and not reported goes back
Plan.FIX_TRIES = 3

local function fkey(c) return c.x .. "," .. c.y .. "," .. c.z end

function Plan.add_fixes(job, cells)
    job.fixes = job.fixes or {}
    local n, count = 0, 0
    for _ in pairs(job.fixes) do count = count + 1 end
    for _, c in ipairs(cells or {}) do
        if type(c) == "table" and tonumber(c.x) and tonumber(c.y) and tonumber(c.z)
            and (c.kind == "dig" or c.kind == "wall" or c.kind == "lava") then
            local k = fkey(c)
            if not job.fixes[k] and count < Plan.FIX_MAX then
                job.fixes[k] = {x = c.x, y = c.y, z = c.z, kind = c.kind, state = "free", tries = 0}
                n, count = n + 1, count + 1
            end
        end
    end
    return n
end

function Plan.fix_count(job)
    local n = 0
    for _ in pairs(job.fixes or {}) do n = n + 1 end
    return n
end

-- up to n cells near the first (holes first, then the one nearest x, z)
function Plan.take_fixes(job, tid, x, z, now, n)
    local fixes = job.fixes
    if not fixes then return nil end
    local best, bestd
    for _, f in pairs(fixes) do
        if f.state == "busy" and now - (f.at or 0) > Plan.FIX_STALE then f.state = "free" end
        if f.state == "busy" and f.by == tid then f.state = "free" end   -- it asks again: those are lost
    end
    for _, f in pairs(fixes) do
        if f.state == "free" then
            local d = math.abs(f.x - (x or job.cx)) + math.abs(f.z - (z or job.cz)) + (f.kind == "wall" and 0 or 1000)
            if not best or d < bestd then best, bestd = f, d end
        end
    end
    if not best then return nil end
    local list = {}
    for _, f in pairs(fixes) do
        if f.state == "free" and math.abs(f.x - best.x) + math.abs(f.z - best.z) + math.abs(f.y - best.y) <= 12 then
            list[#list + 1] = f
        end
    end
    table.sort(list, function(a, b)
        local da = math.abs(a.x - best.x) + math.abs(a.z - best.z) + math.abs(a.y - best.y)
        local db = math.abs(b.x - best.x) + math.abs(b.z - best.z) + math.abs(b.y - best.y)
        if da ~= db then return da < db end
        return a.y > b.y
    end)
    local out = {}
    for i = 1, math.min(n or 8, #list) do
        local f = list[i]
        f.state, f.by, f.at = "busy", tid, now
        out[#out + 1] = {x = f.x, y = f.y, z = f.z, kind = f.kind}
    end
    return out
end

-- results: {{x, y, z, ok = true|false}}
function Plan.fixes_done(job, results)
    for _, r in ipairs(results or {}) do
        local f = job.fixes and job.fixes[fkey(r)]
        if f then
            if r.ok then job.fixes[fkey(r)] = nil
            else
                f.tries = (f.tries or 0) + 1
                if f.tries >= Plan.FIX_TRIES then job.fixes[fkey(r)] = nil else f.state = "free" end
            end
        end
    end
end

-- The job grows up to `top` (owner 2026-11-06: up to the Nether's bedrock):
-- the passes left keep their place, the new levels above come after them,
-- bottom up (so what is dug stays one block of levels). Roof and floor off.
function Plan.extend_up(job, top)
    if top <= job.top then return false end
    local old = G.layout(job)
    local list = {}
    for i, b in ipairs(old) do list[i] = {top = b.top, mid = b.mid, low = b.low, kind = i < job.band and b.kind or nil} end
    local y = job.top + 1
    while y <= top do
        local low, mid, hi = y, math.min(y + 1, top), math.min(y + 2, top)
        list[#list + 1] = {top = hi, mid = mid, low = low}
        y = hi + 1
    end
    job.layout, job.top, job.roof, job.floor_on = list, top, false, false
    job.bands = #list
    return true
end

-- Finish with the band being dug now: no new band starts after it (on = false: dig them all again).
function Plan.last_band(job, on)
    job.last_band = on and job.band or nil
end

-- A job finished early (Finish) goes on with the next band: same centre, walls, no new roof.
function Plan.continue(job)
    if not job.finished or job.band >= job.bands then return false end
    job.finished, job.last_band = nil, nil
    job.band = job.band + 1
    Plan.reset_band(job)
    return true
end

-- A turtle that keeps its row alive (heartbeat) refreshes the taken time;
-- x: the row it says it has (no search over the band then).
-- z, dz: where the digger is in its row and which way it goes (a waiting
-- turtle may take the far half: split)
function Plan.touch(job, tid, now, x, z, dz)
    local r = x and job.rows[x]
    if r then
        if r.state == "busy" and r.by == tid and not r.digger_done then
            r.at = now
            if tonumber(z) and (dz == 1 or dz == -1) then r.z, r.dz = z, dz end
        elseif r.state == "busy" and r.helper == tid then r.hat = now end
        return
    end
    for _, row in pairs(job.rows) do
        if row.state == "busy" and row.by == tid and not row.digger_done then row.at = now end
        if row.state == "busy" and row.helper == tid then row.hat = now end
    end
end

function Plan.progress(job)
    local free, busy, done = counts(job)
    return {band = job.band, bands = job.bands, done = done, busy = busy, total = free + busy + done,
        finished = job.finished ~= nil, last = job.last_band}
end

return Plan
