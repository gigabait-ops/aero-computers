-- Circle/square and band geometry shared by the turtles and the remote.
-- A job digs every cell with dx*dx + dz*dz <= R*R + R around (cx, cz) (a
-- square job: |dx| <= R and |dz| <= R), from
-- `top` (the owner's feet, or higher with Up) down to `floor`, in bands of 3
-- levels: a turtle walks the middle level and digs one up and one down.
local G = {}

G.MIN_FLOOR = -59      -- overworld bedrock is -64..-60: deepest fully clear level
G.NETHER_FLOOR = 5     -- Nether bedrock is 0..4
G.MAX_Y = 319          -- the overworld's highest block: "Up all" stops there, no roof over it
G.NETHER_TOP = 122     -- the Nether's roof bedrock is 123..127
G.SIM_BLOCKS = 112     -- simulation distance 8 chunks: a turtle must stay ~7 chunks from the owner
G.MAX_RADIUS = 100     -- the circle's edge with the owner in the centre (owner 2026-11-03: keep 100)
G.MAX_SQUARE = 70      -- the square's corners (70 * 1.41 = 99)

function G.max_size(shape) return shape == "square" and G.MAX_SQUARE or G.MAX_RADIUS end

-- the farthest point of the area from its centre
function G.corner(job)
    local b = job.box
    if b then
        local hx, hz = math.max(job.cx - b.x0, b.x1 - job.cx), math.max(job.cz - b.z0, b.z1 - job.cz)
        return math.sqrt(hx * hx + hz * hz)
    end
    return job.shape == "square" and job.R * math.sqrt(2) or job.R
end

-- A box job (owner 2026-11-08, "по кутах"): any rectangle, job.box =
-- {x0, x1, z0, z1} the cells dug (the walls stand one further out); cx/cz
-- its middle, R half its longer side (travel and the "far" check use them).
function G.box(x0, x1, z0, z1)
    x0, x1 = math.min(x0, x1), math.max(x0, x1)
    z0, z1 = math.min(z0, z1), math.max(z0, z1)
    return {x0 = x0, x1 = x1, z0 = z0, z1 = z1}
end

function G.inside(job, x, z)
    local b = job.box
    if b then return x >= b.x0 and x <= b.x1 and z >= b.z0 and z <= b.z1 end
    local dx, dz = x - job.cx, z - job.cz
    if job.shape == "square" then return math.abs(dx) <= job.R and math.abs(dz) <= job.R end
    return dx * dx + dz * dz <= job.R * job.R + job.R
end

-- Cells of row x: z from zmin to zmax (nil when the row is outside the circle).
function G.span(job, x)
    local b = job.box
    if b then
        if x < b.x0 or x > b.x1 then return nil end
        return b.z0, b.z1
    end
    local dx = x - job.cx
    if job.shape == "square" then
        if math.abs(dx) > job.R then return nil end
        return job.cz - job.R, job.cz + job.R
    end
    local left = job.R * job.R + job.R - dx * dx
    if left < 0 then return nil end
    local h = math.floor(math.sqrt(left))
    return job.cz - h, job.cz + h
end

-- The passes, top down. With a roof the first pass is the top level alone:
-- the turtles walk it and put the roof right over their heads (no climbing
-- at every cell; owner 2026-11-03). With a floor the last pass is the floor
-- level alone, laying the floor under them. Between them bands of 3 levels.
-- Slabs (owner 2026-11-06, "стелю та підлогу з напівблоків"): a slab roof or
-- floor goes INSIDE the area, not into the face beyond it (that is bedrock in
-- the Nether): a top slab in the top level, put up from the level under it,
-- and a bottom slab in the floor level, put down from the level over it.
function G.slabs(job, surface)
    local m = job.shell and job.shell.materials and job.shell.materials[surface]
    if type(m) ~= "table" or #m == 0 then return false end
    for _, n in ipairs(m) do if not tostring(n):find("_slab$") then return false end end
    return true
end

local cache = setmetatable({}, {__mode = "k"})
function G.layout(job)
    -- a layout given with the job (a job changed while it ran, e.g. the part
    -- above it added at the end): the passes in the order they are dug
    if type(job.layout) == "table" and #job.layout > 0 then return job.layout end
    if cache[job] then return cache[job] end
    local list, y, bottom = {}, job.top, job.floor
    local roof_in = job.roof and G.slabs(job, "roof") and job.top - 1 >= job.floor
    local floor_in = job.floor_on and G.slabs(job, "floor") and job.floor + 1 <= job.top
    if roof_in then list[#list + 1] = {top = y, mid = y - 1, low = y - 1, kind = "roof", inner = true} y = y - 2
    elseif job.roof and job.top < G.MAX_Y then list[#list + 1] = {top = y, mid = y, low = y, kind = "roof"} y = y - 1 end
    if job.floor_on and bottom <= y then bottom = bottom + (floor_in and 2 or 1) end
    -- Under water (job.wet = the lowest water level, owner 2026-11-08 "прибрати
    -- воду"): one level a pass. A pass digs its level, which the pass before
    -- filled, and fills every water cell under it. Dug while water stood next
    -- to it, a cell would only fill again; a level all blocks is dug dry.
    if job.wet then
        while y >= math.max(job.wet + 1, bottom) do
            -- the top pass over the water only fills it: nothing is built
            -- above the water (owner 2026-11-08), the turtles' homes are there
            list[#list + 1] = {top = y, mid = y, low = y, kind = "wet", bare = y == job.top or nil}
            y = y - 1
        end
    end
    while y >= bottom do
        local mid = math.max(y - 1, bottom)
        local low = math.max(mid - 1, bottom)
        list[#list + 1] = {top = y, mid = mid, low = low}
        y = low - 1
    end
    if floor_in and job.floor + 1 <= y + 1 then
        list[#list + 1] = {top = job.floor + 1, mid = job.floor + 1, low = job.floor, kind = "floor", inner = true}
    elseif job.floor_on and not floor_in and job.floor <= job.top and not (job.roof and job.floor == job.top) then
        list[#list + 1] = {top = job.floor, mid = job.floor, low = job.floor, kind = "floor"}
    end
    if #list == 0 then list[1] = {top = job.top, mid = job.top, low = job.top} end
    cache[job] = list
    return list
end

function G.bands(job) return #G.layout(job) end

-- Levels of pass b (1 = top): the top level, the walking level, the lowest
-- level, and "roof"/"floor" for those passes.
function G.levels(job, b)
    local layout = G.layout(job)
    local band = layout[math.max(1, math.min(b, #layout))]
    return band.top, band.mid, band.low, band.kind, band.inner, band.bare
end

-- A cell on the edge: some neighbour is outside the circle. Returns the
-- directions (0 = +x east, 1 = +z south, 2 = -x west, 3 = -z north) facing out.
G.DX = {[0] = 1, 0, -1, 0}
G.DZ = {[0] = 0, 1, 0, -1}
function G.outward(job, x, z)
    local out = {}
    for d = 0, 3 do
        if not G.inside(job, x + G.DX[d], z + G.DZ[d]) then out[#out + 1] = d end
    end
    return out
end

function G.rows(job)
    if job.box then return job.box.x0, job.box.x1 end
    return job.cx - job.R, job.cx + job.R
end

return G
