-- The inspector's arithmetic (owner 2026-11-06): where to scan and what a
-- Geo Scanner result means. Pure Lua, so the inspector turtle, the remote and
-- the tests share it. The inspector only looks and reports; the free diggers
-- fix what it finds (app.lua hands the cells out, miner.lua m.fix).
--   dig   a block (or lava) left inside the pit in a level already dug
--   wall  a hole (air, fluid, a plant) in the wall ring of a dug level
--   lava  where a lava pool may have its source (the digger plugs around it)
local G = require("geom")

local I = {}

I.RADIUS = 8      -- the scanner's free radius (no fuel cost)
I.STEP = 14       -- grid spacing: cubes of 17 overlap a little
I.MAX_REPORT = 120

local AIR = {["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true}
I.AIR = AIR

-- never a leftover: turtles, computers, our barrels
local function ours(name)
    return name:find("^computercraft:") ~= nil or name:find("^sophisticatedstorage:") ~= nil
end

local function fluid(name)
    return name == "minecraft:lava" or name == "minecraft:water" or name:find("flowing") ~= nil
end

-- holes in a wall: nothing solid (fluids, plants, snow and the like)
local function soft(entry)
    if fluid(entry.name) then return true end
    local tags = entry.tags
    if type(tags) == "table" then
        if tags["minecraft:replaceable"] then return true end
        for _, tg in ipairs(tags) do if tg == "minecraft:replaceable" then return true end end
    end
    return false
end

-- The levels already dug: from the job's top down to the top of the band
-- being dug now (exclusive). nil when nothing is done yet.
-- With job.cur (the band being dug: low, top, done = {[x] = true} its rows
-- already dug) that band is in too: a source left in a dug row floods the
-- band long before the band is over (1171 18 159, 2026-11-06).
function I.done_levels(job, band)
    if not band then return nil end
    -- the passes before this one (a layout may run in any order): one block
    -- of levels from the lowest to the highest of them
    local layout = G.layout(job)
    local lo, hi
    for i = 1, math.min(band - 1, #layout) do
        local b = layout[i]
        lo = math.min(lo or b.low, b.low)
        hi = math.max(hi or b.top, b.top)
    end
    local cur = job.cur
    if cur and next(cur.done or {}) then
        lo = math.min(lo or cur.low, cur.low)
        hi = math.max(hi or cur.top, cur.top)
    end
    if not lo then return nil end
    hi = math.min(hi, job.top - 1)   -- the job's top level: the owner's feet (their own blocks may stand there)
    if lo > hi then return nil end
    return lo, hi, hi
end

-- Scan points: a grid over the circle, each pulled inside (the inspector
-- flies only through the dug pit), serpentine so the flight is short.
function I.points(job, y)
    local pts = {}
    local x0, x1 = G.rows(job)
    local row = 0
    for x = x0 + I.RADIUS - 1, x1 + I.STEP - 1, I.STEP do
        x = math.min(x, x1 - 1)
        local zs = {}
        local zmin, zmax = G.span(job, x)
        if zmin then
            for z = zmin + 1, zmax - 1 + I.STEP - 1, I.STEP do zs[#zs + 1] = math.min(z, zmax - 1) end
            if row % 2 == 1 then
                local rev = {}
                for i = #zs, 1, -1 do rev[#rev + 1] = zs[i] end
                zs = rev
            end
            for _, z in ipairs(zs) do
                if G.inside(job, x, z) then pts[#pts + 1] = {x = x, y = y, z = z} end
            end
            row = row + 1
        end
    end
    return pts
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end
I.key = key

local function ring(job, x, z)
    if G.inside(job, x, z) then return false end
    for d = 0, 3 do if G.inside(job, x + G.DX[d], z + G.DZ[d]) then return true end end
    return false
end
I.ring = ring

-- One scan at (px, py, pz): entries {x, y, z relative, name, tags}. lo/hi:
-- the dug levels (walls are checked up to whi). Returns a list of
-- {x, y, z, kind = "dig" | "wall", name}.
-- in the band being dug only the rows already dug count (a wall cell: a row
-- next to it dug)
local function counted(job, x, y, wall)
    local cur = job.cur
    if not cur or y < cur.low or y > cur.top then return true end
    local done = cur.done or {}
    if done[x] then return true end
    return wall and (done[x - 1] or done[x + 1]) or false
end

-- The levels the shell itself stands in: the slab roof and slab floor
-- passes put their blocks inside the pit (the roof's top, the floor's low).
-- A block there is the shell, not something left (2026-11-07: the floor's
-- slabs were reported and the free turtles broke them).
local function shell_levels(job)
    local ys = {}
    for _, b in ipairs(G.layout(job)) do
        if b.inner and b.kind == "floor" then ys[b.low] = true
        elseif b.inner and b.kind == "roof" then ys[b.top] = true end
    end
    return ys
end
I.shell_levels = shell_levels

function I.classify(job, px, py, pz, entries, lo, hi, whi)
    local seen, out, lavas = {}, {}, {}
    local shell = shell_levels(job)
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.name then
            local x, y, z = px + e.x, py + e.y, pz + e.z
            seen[key(x, y, z)] = e
            if not AIR[e.name] and not ours(e.name) and y >= lo and y <= hi and G.inside(job, x, z) and counted(job, x, y) then
                if fluid(e.name) then lavas[#lavas + 1] = {x = x, y = y, z = z}
                elseif not shell[y] then out[#out + 1] = {x = x, y = y, z = z, kind = "dig", name = e.name} end
            end
        end
    end
    -- Lava: the scan does not say source or flow, and a single source floods
    -- hundreds of cells. One spot per pool: its highest cells (a source sits
    -- on top, the flow runs down and out), the two nearest its middle. The
    -- digger sent there plugs every source around it (miner fix "lava").
    for _, c in ipairs(I.pools(lavas)) do out[#out + 1] = c end
    if job.walls ~= false then
        local r = I.RADIUS
        for dx = -r, r do
            for dz = -r, r do
                local x, z = px + dx, pz + dz
                if ring(job, x, z) then
                    for dy = -r, r do
                        local y = py + dy
                        if y >= lo and y <= whi and counted(job, x, y, true) then   -- the scan is a cube (AP ScanUtil), air left out
                            local e = seen[key(x, y, z)]
                            if not e or AIR[e.name] or soft(e) then
                                out[#out + 1] = {x = x, y = y, z = z, kind = "wall", name = e and e.name or "air"}
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

-- lava cells -> a few "lava" spots per connected pool (6-neighbours)
function I.pools(cells)
    local at, done, out = {}, {}, {}
    for _, c in ipairs(cells) do at[key(c.x, c.y, c.z)] = c end
    for _, c in ipairs(cells) do
        local k0 = key(c.x, c.y, c.z)
        if not done[k0] then
            local pool, stack = {}, {c}
            done[k0] = true
            while #stack > 0 do
                local q = table.remove(stack)
                pool[#pool + 1] = q
                for _, d in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) do
                    local k = key(q.x + d[1], q.y + d[2], q.z + d[3])
                    if at[k] and not done[k] then done[k] = true stack[#stack + 1] = at[k] end
                end
            end
            local top, sx, sz, n = -1e9, 0, 0, 0
            for _, q in ipairs(pool) do if q.y > top then top = q.y end end
            local tops = {}
            for _, q in ipairs(pool) do
                if q.y == top then tops[#tops + 1] = q sx, sz, n = sx + q.x, sz + q.z, n + 1 end
            end
            local mx, mz = sx / n, sz / n
            table.sort(tops, function(a, b)
                return (a.x - mx) ^ 2 + (a.z - mz) ^ 2 < (b.x - mx) ^ 2 + (b.z - mz) ^ 2
            end)
            for i = 1, math.min(2, #tops) do
                out[#out + 1] = {x = tops[i].x, y = tops[i].y, z = tops[i].z, kind = "lava", pool = #pool}
            end
        end
    end
    return out
end

-- Holes first (they let the lava in), then what is nearest the centre line.
function I.rank(cells)
    table.sort(cells, function(a, b)
        local order = {wall = 1, lava = 2, dig = 3}
        if a.kind ~= b.kind then return (order[a.kind] or 9) < (order[b.kind] or 9) end
        if a.y ~= b.y then return a.y > b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)
    return cells
end

return I
