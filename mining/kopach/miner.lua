-- The mining turtle's work: asks the remote for a row, digs it band by band
-- (everything in the area but bedrock, turtles and the linked barrels),
-- walls the circle's edge, deals with lava, empties itself into its linked
-- Sophisticated storage and refuels from that storage's first slot.
-- The shell (walls, roof, floor) follows kopach/shell.lua: which block each
-- surface is built from (the one there is most of, or one the owner named in
-- the remote's Shell tab) and what may stand in its place (vines, plants,
-- ores, fluids). A "builder" job walks the same rows but only builds the
-- shell: nothing inside the area is dug.
-- Everything outside (turtle API, GPS, radio, files, clock) comes in `env`,
-- so the same code runs on a turtle and in tests/kopach_sim_test.lua.
local G = require("geom")
local Shell = require("shell")
local Supply = require("supply")

local M = {}

M.LOW_FUEL = 2000     -- below this: ask PC121 for lava (kopach/supply.lua)
M.FULL_FUEL = 20000   -- refuel up to this
M.KEEP_FILL = 128     -- filler blocks kept for walls and lava (a lava lake eats a stack fast)
M.KEEP_FILL_ROOF = 192 -- with a roof to build: three stacks
M.SUPPLY_WAIT = 30
M.GPS_EVERY = 8   -- forward steps between GPS checks     -- seconds between looks while it waits for a named block

-- Blocks it may break inside the area: everything (owner 2026-11-03), except
-- bedrock, computers and turtles, and the linked barrels the turtles put down
-- for a moment to empty themselves. What does not break is walked around.
local KEEP_PREFIX = {"^computercraft:", "^sophisticatedstorage:"}

local STOP = setmetatable({}, {__tostring = function() return "stopped" end})

function M.natural(ok, info)
    if not ok or type(info) ~= "table" or info.name == "minecraft:bedrock" then return false end
    for _, pre in ipairs(KEEP_PREFIX) do if tostring(info.name):find(pre) then return false end end
    return true
end
local function fluid(ok, info) return ok and (info.name == "minecraft:lava" or info.name == "minecraft:water") end
local function is_turtle(ok, info) return ok and tostring(info.name):find("^computercraft:turtle") ~= nil end
local function storage_item(d) return d and d.name:find("^sophisticatedstorage:") ~= nil end

function M.new(env)
    local t = env.turtle
    local m = {env = env, t = t, word = "idle", note = nil, blocked = {}, blocked_band = nil, held = {}}
    local st = env.load() or {}
    m.st = st   -- saved: pos, dir, home, job, band, x
    -- A write per step was the turtle's most expensive action. Mark the state
    -- dirty instead and write at most every two seconds; everything that has to
    -- survive a crash (a new row, a band change, service, home) calls flush().
    local dirty, saved_at, pending = false, -100, 0
    local function flush()
        if not dirty then return end
        env.save(st)
        dirty, saved_at = false, env.now()
    end
    local function save()
        dirty = true
        pending = pending + 1
        if pending >= 4 then
            pending = 0
            local stamp = env.now()
            if stamp - saved_at >= 2 then env.save(st) dirty, saved_at = false, stamp end
        end
    end
    m.save = save
    m.flush = flush

    -- The job's shell policy (kopach/shell.lua): resolved once per job id, so
    -- a job started before this code (no .shell) still gets the defaults.
    local policy_cache, policy_job
    local function pol()
        if policy_job ~= st.job then policy_job, policy_cache = st.job, Shell.from_job(st.job) end
        return policy_cache
    end
    m.policy = pol

    -- What is in the 16 slots, in the shape Shell.choose wants.
    local function inventory()
        local list = {}
        for i = 1, 16 do
            local d = t.getItemDetail(i)
            if d then list[#list + 1] = {slot = i, name = d.name, count = d.count} end
        end
        return list
    end
    m.inventory = inventory

    -- The slot this surface is built from (nil: nothing suitable, or the block
    -- the owner named is missing). The choice is kept per surface until that
    -- stack runs out, so one wall does not change colour halfway down just
    -- because a stack of dirt grew past the cobblestone.
    local picked = {}   -- surface -> {slot = n, name = "..."}
    local function material_slot(surface)
        local p = picked[surface]
        if p then
            -- a stack is never replaced while it still has items (digs stack on
            -- it), so one count is enough - it used to scan all sixteen slots
            -- the same block still in that slot: when the stack ran out, the
            -- next dug item (quartz, a nugget) lands there, and a plug made of
            -- quartz never goes in - the lava source stayed (2026-11-06)
            local d = t.getItemCount(p.slot) > 0 and t.getItemDetail(p.slot)
            if d and d.name == p.name then return p.slot, p.name end
            picked[surface] = nil
        end
        local slot, want = Shell.choose(inventory(), surface, pol())
        if slot then picked[surface] = {slot = slot, name = want} end
        return slot, want
    end
    m.material_slot = material_slot
    m.forget_material = function() picked = {} end

    -- The shell blocks this turtle could build with, most first: the remote's
    -- Shell tab cycles through these names instead of a list it cannot see.
    function m.fills()
        local list = {}
        for _, s in ipairs(inventory()) do
            if Shell.is_material(s.name, pol()) then list[#list + 1] = s end
        end
        local function rank(s) return Shell.rank(s.name, pol()) or 99 end
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return rank(a) < rank(b)
        end)
        local names = {}
        for _, s in ipairs(list) do
            local seen = false
            for _, n in ipairs(names) do if n == s.name then seen = true break end end
            if not seen then names[#names + 1] = s.name end
            if #names >= 6 then break end
        end
        return names
    end

    local function say(word, note)
        if word ~= m.word or note ~= m.note then
            m.word, m.note = word, note
            env.log(word .. (note and (" " .. note) or ""))
        end
    end
    m.say = say

    -- pause and stop come from the radio between any two actions
    local function check()
        local ctl = env.ctl
        if ctl.stop and st.job then error(STOP, 0) end
        if ctl.paused then
            flush()
            local before, note = m.word, m.note
            say("pause")
            while ctl.paused and not ctl.stop do env.sleep(0.5) end
            say(before, note)
            if ctl.stop and st.job then error(STOP, 0) end
        end
    end
    m.check = check

    ---------------------------------------------------------------- position
    local DX, DZ = G.DX, G.DZ
    local function pos() return st.pos end

    local function turn_to(d)
        d = d % 4
        if (st.dir + 1) % 4 == d then
            t.turnRight() st.dir = d save() flush() return
        end
        while st.dir ~= d do t.turnLeft() st.dir = (st.dir + 3) % 4 save() end
        flush()
    end
    m.turn_to = turn_to

    -- GPS position; facing from the saved state, or found by one step and back.
    -- The saved facing is written lazily (every 2 s), so after a reboot or a
    -- chunk unload it can be a turn behind: 2026-11-06 turtles 13, 38, 43, 47,
    -- 169 dug the wrong way and two walked out of the circle. At boot the
    -- facing is always measured again; the saved one is the fallback only.
    function m.locate()
        local x, y, z = env.locate()
        if not x then return false, "no gps" end
        st.pos = {x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)}
        local placed = {x = st.pos.x, y = st.pos.y, z = st.pos.z}   -- the cell the owner put it in
        local saved_dir = st.dir
        st.dir = nil
        do
            -- one step to a free side and back; boxed in at the sides: try from one block up
            local function probe()
                for _ = 1, 4 do
                    if not t.detect() and t.forward() then
                        local x2, y2, z2 = env.locate()
                        local back = t.back()
                        if not x2 then
                            if not back then st.pos = nil end   -- where it is now is unknown
                            return
                        end
                        local nx, nz = math.floor(x2 + 0.5), math.floor(z2 + 0.5)
                        local dx, dz = nx - st.pos.x, nz - st.pos.z
                        for d = 0, 3 do if DX[d] == dx and DZ[d] == dz then st.dir = d end end
                        -- someone took the cell behind (a crowd of new turtles): it stays here
                        if not back then st.pos = {x = nx, y = math.floor(y2 + 0.5), z = nz} end
                        return
                    end
                    t.turnRight()
                end
            end
            if t.getFuelLevel() ~= "unlimited" and t.getFuelLevel() < 10 then m.service() end   -- new turtles come empty
            probe()
            if not st.pos then st.dir = saved_dir return false, "no gps" end
            if st.dir == nil and not t.detectUp() and t.up() then
                st.pos.y = st.pos.y + 1
                probe()
                if not st.pos then st.dir = saved_dir return false, "no gps" end
                if t.down() then st.pos.y = st.pos.y - 1 end
            end
            if st.dir == nil and saved_dir ~= nil then
                st.dir = saved_dir   -- nowhere to step: trust the saved facing
                env.log("facing: kept the saved one")
            elseif st.dir ~= nil and saved_dir ~= nil and st.dir ~= saved_dir then
                env.log(("facing: saved %d, measured %d"):format(saved_dir, st.dir))
            end
            if st.dir == nil then return false, t.getFuelLevel() == 0 and "no fuel" or "boxed in" end
        end
        -- home is where the owner put it (not where the probe left it: in a crowd
        -- two turtles ended up sharing one), unless it is in the middle of a job
        if not st.job or not st.home then st.home = placed end
        save() flush()
        return true
    end

    ---------------------------------------------------------------- inventory
    local function free_slots()
        local n = 0 for i = 1, 16 do if t.getItemCount(i) == 0 then n = n + 1 end end
        return n
    end
    local function find(pred)
        for i = 1, 16 do
            local d = t.getItemDetail(i)
            if d and pred(d) then return i, d end
        end
    end
    -- the first empty slot but `skip` (the barrel's while it stands)
    local function empty_slot(skip)
        for i = 1, 16 do if i ~= skip and t.getItemCount(i) == 0 then return i end end
    end
    local function room(n)
        local lvl, lim = t.getFuelLevel(), t.getFuelLimit()
        if lvl == "unlimited" then return false end
        return lvl + n <= lim
    end
    m.free_slots = free_slots

    -- burn what burns in the inventory (coal it dug, lava buckets), keep the rest
    local function burn()
        local sel = t.getSelectedSlot()
        for i = 1, 16 do
            local d = t.getItemDetail(i)
            if d and not storage_item(d) and d.name ~= "minecraft:bucket" and not Shell.is_material(d.name, pol()) then
                t.select(i)
                if d.name == "minecraft:lava_bucket" then
                    if room(1000) then t.refuel() end
                else
                    while t.getFuelLevel() < M.FULL_FUEL and t.refuel(1) do end
                end
            end
        end
        t.select(sel)
    end

    -- A barrel left standing next to it by a reboot in the middle of a service:
    -- take it back (turtle.lua, before locate steps away from it).
    local function recover_storage()
        local sides = {{t.inspectUp, t.digUp}, {t.inspectDown, t.digDown}, {t.inspect, t.dig}}
        for turn = 0, 3 do
            for i, sd in ipairs(sides) do
                if turn == 0 or i == 3 then
                    local ok, info = sd[1]()
                    if ok and tostring(info.name):find("^sophisticatedstorage:") and free_slots() > 0 then
                        sd[2]()
                        if find(storage_item) then
                            if st.dir then turn_to(st.dir) end
                            env.log("storage: took back a barrel left standing")
                            return true
                        end
                    end
                end
            end
            if st.dir then turn_to(st.dir + 1) else t.turnRight() end
        end
        return false
    end
    m.recover_storage = recover_storage
    function m.has_storage() return find(storage_item) ~= nil end

    -- place the linked barrel, fn(suck, drop, side, bslot), take it back with
    -- nothing spilled (it turns to find room; it always turns back: a step half
    -- done goes on the way it faced, or it would walk off its row)
    local function with_storage(fn)
        -- no barrel: never take one that stands next to it here, it is another
        -- turtle's in the middle of its service (162 took 158's, 2026-11-06);
        -- only right after a reboot is a standing one its own (turtle.lua)
        local slot = find(storage_item)
        if not slot then say("no storage", "give it its barrel") return false end
        local facing = st.dir
        local function back()
            if facing then turn_to(facing) end
        end
        local ways = {
            {t.placeUp, t.dropUp, t.digUp, t.detectUp, t.suckUp, t.inspectUp, "top"},
            {t.placeDown, t.dropDown, t.digDown, t.detectDown, t.suckDown, t.inspectDown, "bottom"},
            {t.place, t.drop, t.dig, t.detect, t.suck, t.inspect, "front"},
        }
        for turn = 0, 3 do
            for i, w in ipairs(ways) do
                if turn == 0 or i == 3 then
                    t.select(slot)
                    if not w[4]() and w[1]() then
                        -- whatever fn does (an error, a stop), the barrel comes back:
                        -- one left standing is a turtle with no storage (168, 2026-11-06)
                        local okf, err = pcall(fn, w[5], w[2], w[7], slot)
                        for _ = 1, 5 do
                            t.select(slot)
                            local okb, infob = w[6]()          -- only take back a container
                            if not (okb and Shell.container(infob.name)) then break end
                            w[3]()
                            if find(storage_item) then break end
                            env.log("storage: the barrel did not come back, again")
                            env.sleep(1)
                        end
                        back()
                        if not okf then error(err, 0) end
                        return true
                    end
                end
            end
            if st.dir then turn_to(st.dir + 1) else t.turnRight() end
        end
        back()
        say("no room", "for its barrel")
        return false
    end

    local function keep_fill() return st.job and (st.job.roof or st.job.floor_on) and M.KEEP_FILL_ROOF or M.KEEP_FILL end

    -- One visit: empty everything (keep the storage, one empty bucket and a
    -- stack of shell blocks) and, when fuel is low, lava from PC121.
    function m.service()
        burn()
        local before = m.word
        say("service")
        -- the block the shell is built from right now (walls is the general
        -- choice; a surface with its own block keeps its own)
        local _, keep_name = material_slot("walls")
        local ok = with_storage(function(suck, drop, side, bslot)
            local bucket = false
            local kept = 0
            for i = 1, 16 do
                local d = t.getItemDetail(i)
                if d and not storage_item(d) then
                    t.select(i)
                    if d.name == "minecraft:bucket" and not bucket then
                        bucket = true
                        if d.count > 1 then drop(d.count - 1) end
                    elseif keep_name and d.name == keep_name and kept < keep_fill() then
                        local keep = math.min(d.count, keep_fill() - kept)
                        kept = kept + keep
                        if d.count > keep then drop(d.count - keep) end
                    else
                        drop()
                    end
                end
            end
            if t.getFuelLevel() < M.LOW_FUEL * 2 then
                -- PC121 puts the lava in the barrel's slot 1 (the barrel cannot reorder itself)
                local _, r, kept = Supply.take_lava(env.supply, {
                    turtle = t, suck = suck, drop = drop, keep_bucket = not bucket,
                    want = math.min(20, math.ceil((M.FULL_FUEL - t.getFuelLevel()) / 1000)),
                    full = function() return t.getFuelLevel() >= M.FULL_FUEL or not room(1000) end,
                    free = function() return empty_slot(bslot) end,
                })
                bucket = bucket or kept
                if not (r and r.t == "ready") then env.log("supply: no lava (" .. Supply.why(r) .. ")") end
            end
        end)
        m.forget_material()   -- the slots moved: pick the shell block again
        flush()
        say(before)
        return ok
    end

    local function fuel(need)
        local lvl = t.getFuelLevel()
        if lvl == "unlimited" or lvl >= need then return end
        burn()
        while t.getFuelLevel() < math.max(need, 1) do
            m.service()
            if t.getFuelLevel() >= need then break end
            say("no fuel", "no lava at PC121")
            env.sleep(5)
            check()
        end
    end
    m.fuel = fuel

    ---------------------------------------------------------------- blocks

    -- Lava in a direction inside the dig area: scoop a source and burn it;
    -- with no empty bucket (or full tank) plug it with a block and break that block.
    local function lava(inspect, place, dig)
        local ok, b = inspect()
        if not (ok and b.name == "minecraft:lava") then return end
        local sel = t.getSelectedSlot()
        if b.state and b.state.level == 0 then
            local i = find(function(d) return d.name == "minecraft:bucket" end)
            if i and room(1000) then
                t.select(i)
                if place() then t.refuel() t.select(sel) return end
            end
        end
        -- plug it with a block and break that: try the shell block, then any
        -- block it carries that goes in
        local tried = {}
        local fi = material_slot("walls")
        for _ = 1, 3 do
            if not fi or tried[fi] then
                fi = nil
                for i = 1, 16 do
                    local d = not tried[i] and t.getItemDetail(i)
                    if d and Shell.is_material(d.name, pol()) then fi = i break end
                end
            end
            if not fi then break end
            tried[fi] = true
            t.select(fi)
            if place() then dig() break end
            fi = nil
        end
        if not fi and b.state and b.state.level == 0 then
            -- nothing to plug it with: step into the source and back. Lava
            -- does not stay in a turtle's cell (it is not waterloggable),
            -- so the source is gone; water would stay, the Nether has none.
            local into, back, dx, dy
            if inspect == t.inspectUp then into, back, dx, dy = t.up, t.down, 0, 1
            elseif inspect == t.inspectDown then into, back, dx, dy = t.down, t.up, 0, -1
            else into, back, dx = t.forward, t.back, 1 end
            if into() then
                local p = pos()
                if not back() then
                    -- the cell behind was taken: it stays where it stepped
                    if dy then st.pos = {x = p.x, y = p.y + dy, z = p.z}
                    else st.pos = {x = p.x + DX[st.dir], y = p.y, z = p.z + DZ[st.dir]} end
                    save()
                end
                env.log("lava: stepped into the source")
                fi = true
            end
        end
        if not fi then env.log("lava: nothing to plug it with") end
        t.select(sel)
    end

    m.lava = lava

    -- break the block in a direction if it is natural (falling sand/gravel too)
    -- -> "clear" | "blocked" (not natural) | "turtle" (another turtle there)
    local function clear(inspect, dig, detect)
        for _ = 1, 30 do
            -- make room first: service() may take seconds, and a turtle that
            -- moved into the cell while it ran must not be found by the dig.
            -- Two cheap counts first; the full count only when both are taken
            -- (the barrel or the bucket may live in 15/16 for good, and that
            -- alone must not send it to empty itself at every block).
            if t.getItemCount(15) > 0 and t.getItemCount(16) > 0 and free_slots() <= 1 then m.service() end
            if not detect() then return "clear" end
            local ok, info = inspect()
            if not ok then return "clear" end   -- a turtle there a moment ago has just moved on
            if is_turtle(ok, info) then return "turtle" end
            if not M.natural(ok, info) then return "blocked" end
            if not dig() then return "blocked" end
        end
        return detect() and "blocked" or "clear"
    end

    -- clear() once may see another turtle in the cell (the whole fleet walks
    -- the same band): give it a few seconds to move on before the cell counts
    -- as left over. This is what left single blocks above and below a turtle.
    local function clear_face(s, tries)
        local r
        for i = 1, tries or 1 do
            r = clear(s.inspect, s.dig, s.detect)
            if r ~= "turtle" then return r end
            env.sleep(1 + i)
            check()
        end
        return r
    end

    local F = {inspect = t.inspect, dig = t.dig, detect = t.detect, place = t.place, move = t.forward}
    local U = {inspect = t.inspectUp, dig = t.digUp, detect = t.detectUp, place = t.placeUp, move = t.up}
    local D = {inspect = t.inspectDown, dig = t.digDown, detect = t.detectDown, place = t.placeDown, move = t.down}
    m.F, m.U, m.D = F, U, D

    -- dig a side clear (only where digging is allowed)
    local function open(s, may_dig)
        if may_dig then lava(s.inspect, s.place, s.dig) end
        if not s.detect() then return "clear" end
        if not may_dig then
            local ok, info = s.inspect()
            if not ok then return "clear" end
            if is_turtle(ok, info) then return "turtle" end
            return "blocked"
        end
        return clear(s.inspect, s.dig, s.detect)
    end
    m.open = open

    -- one step; may_dig says whether the target cell is inside the job's area
    local function step(s, dx, dy, dz, may_dig)
        check()
        local tries_turtle
        for _ = 1, 20 do
            local r = open(s, may_dig)
            if r == "blocked" then return false, "blocked" end
            if r == "clear" then
                fuel(1)
                if s.move() then
                    st.pos = {x = st.pos.x + dx, y = st.pos.y + dy, z = st.pos.z + dz}
                    save()
                    return true
                end
                if s == F then t.attack() elseif s == U then t.attackUp() else t.attackDown() end
            end
            if r == "turtle" then
                tries_turtle = (tries_turtle or 0) + 1
                if tries_turtle >= 3 then return false, "turtle" end
            end
            env.sleep(0.5)   -- a turtle or a mob in the way: wait a moment
            check()
        end
        return false, "turtle"
    end

    local function job() return st.job end
    local function in_area(x, y, z)
        if m.homing or m.nodig then return false end   -- the way home and a builder job break nothing
        local j = job()
        return j ~= nil and G.inside(j, x, z) and y <= j.top and y >= j.floor
    end

    -- GPS every few steps: a facing gone stale (a reboot in the middle of a
    -- turn) walks a row the wrong way, out through the wall (2026-11-08: 184
    -- went 35 blocks out into the ocean and built there)
    local steps_unchecked = 0
    local function fwd()
        local p = pos()
        local nx, nz = p.x + DX[st.dir], p.z + DZ[st.dir]
        local ok, why = step(F, DX[st.dir], 0, DZ[st.dir], in_area(nx, p.y, nz))
        if ok then
            steps_unchecked = steps_unchecked + 1
            if steps_unchecked >= M.GPS_EVERY and m.resync then
                steps_unchecked = 0
                -- it was somewhere else: the step is done, but the way it was
                -- following is wrong now - the caller works it out again
                if m.resync() then return false, "drift" end
            end
        end
        return ok, why
    end
    local function up() local p = pos() return step(U, 0, 1, 0, in_area(p.x, p.y + 1, p.z)) end
    local function down() local p = pos() return step(D, 0, -1, 0, in_area(p.x, p.y - 1, p.z)) end
    m.fwd, m.up, m.down = fwd, up, down

    ---------------------------------------------------------------- moving around
    local function key(x, z) return x .. "," .. z end

    -- breadth-first path over the circle's cells at the walking level, around known obstacles
    local function path(tx, tz)
        local j, p = job(), pos()
        M.stats.paths = M.stats.paths + 1
        local start = key(p.x, p.z)
        local prev, q, qi = {[start] = false}, {{p.x, p.z}}, 1
        while qi <= #q do
            local c = q[qi] qi = qi + 1
            M.stats.visited = M.stats.visited + 1
            if c[1] == tx and c[2] == tz then
                local out, k = {}, key(tx, tz)
                while prev[k] do table.insert(out, 1, prev[k].dir) k = prev[k].from end
                return out
            end
            for d = 0, 3 do
                local nx, nz = c[1] + DX[d], c[2] + DZ[d]
                local nk = key(nx, nz)
                local held = m.held[nk] and m.held[nk] > env.now()
                if prev[nk] == nil and G.inside(j, nx, nz) and not m.blocked[nk] and not held then
                    prev[nk] = {from = key(c[1], c[2]), dir = d}
                    q[#q + 1] = {nx, nz}
                end
            end
        end
    end

    -- walk to a cell of the circle at the current level; false = cannot reach
    -- another turtle in a cell: route around it for a few seconds (each waits a
    -- different time, so two that meet head on do not keep dodging the same way)
    local function hold(k) m.held[k] = env.now() + 4 + (env.turtle_id or 0) % 5 end
    local function holding()
        local t0 = env.now()
        for _, until_t in pairs(m.held) do if until_t > t0 then return true end end
        return false
    end
    local function go(tx, tz)
        -- The row is dug and clear almost all the time: walk it straight first.
        -- The search below used to run for every single cell of every row.
        local p0 = pos()
        if p0.x == tx and p0.z ~= tz then
            local d = tz > p0.z and 1 or 3
            local guard, tick = 0, 0
            while pos().z ~= tz and guard < 400 do
                guard = guard + 1
                tick = tick + 1
                if tick >= 16 then tick = 0 check() end
                turn_to(d)
                local ok, why = fwd()
                if not ok then
                    local k = key(pos().x + DX[d], pos().z + DZ[d])
                    if why == "blocked" then m.blocked[k] = true else hold(k) end
                    break
                end
            end
            if pos().z == tz then return true end
        end
        for _ = 1, 120 do
            local p = pos()
            if p.x == tx and p.z == tz then return true end
            local route = path(tx, tz)
            if not route then
                if not holding() then return false end
                env.sleep(1)   -- the way is only held by turtles: wait for them to move on
                check()
            else
                local moved = true
                for _, d in ipairs(route) do
                    turn_to(d)
                    local ok, why = fwd()
                    if not ok then
                        local k = key(pos().x + DX[d], pos().z + DZ[d])
                        if why == "blocked" then m.blocked[k] = true else hold(k) end
                        moved = false
                        break
                    end
                end
                if moved then return true end
            end
        end
        return false
    end
    m.go = go

    -- to level y in this column (digging only inside the area)
    -- another turtle in the column (all leave home at once when a band starts):
    -- wait for it instead of giving the row up (owner 2026-11-03: a row was left)
    local function to_level(y)
        local waits = 0
        while pos().y ~= y do
            local ok, why
            if pos().y > y then ok, why = down() else ok, why = up() end
            if not ok then
                if why ~= "turtle" or waits >= 60 then return false end
                waits = waits + 1
                env.sleep(1)
            end
        end
        return true
    end
    m.to_level = to_level

    -- Fly over the ground to (x, z) at height y or above: no digging, climbs over things.
    local function fly(x, z, y)
        local lift, blocked_by = 0, 0
        while pos().y < y + lift do if not up() then lift = lift + 1 if lift > 24 then return false end end end
        for _ = 1, 4000 do
            local p = pos()
            if p.x == x and p.z == z then return true end
            local d
            if p.x ~= x then d = p.x < x and 0 or 2 else d = p.z < z and 1 or 3 end
            turn_to(d)
            local ok, why = fwd()
            if not ok then
                -- a turtle in the way: wait a little, then over it (two
                -- coming head on would each wait for the other for good,
                -- 2026-11-08 at the homes on the ocean wall)
                -- (head on, only one of the two climbs: the one going east or
                -- south; the other waits longer. Both climbing at once would
                -- climb together for good)
                if why == "drift" then
                    blocked_by = 0   -- it is where GPS says now: on from there
                elseif why == "turtle" then
                    blocked_by = blocked_by + 1
                    if blocked_by <= (d < 2 and 3 or 12) or pos().y >= y + 24 then env.sleep(1)
                    elseif up() then blocked_by = 0
                    else env.sleep(1) end
                elseif not up() then return false end
            else
                blocked_by = 0
            end
        end
        return false
    end

    -- Get into the circle at the walking level of band b, starting from anywhere.
    local function enter(b)
        local j = job()
        local _, mid = G.levels(j, b)
        local p = pos()
        if not G.inside(j, p.x, p.z) then
            -- nearest cell of the circle along the line to the centre
            local dx, dz = j.cx - p.x, j.cz - p.z
            local len = math.max(1, math.sqrt(dx * dx + dz * dz))
            local k = math.max(0, len - j.R + 1) / len
            local tx, tz = math.floor(p.x + dx * k + 0.5), math.floor(p.z + dz * k + 0.5)
            if not G.inside(j, tx, tz) then tx, tz = j.cx, j.cz end
            say("travel")
            if not fly(tx, tz, math.max(j.top + 1, p.y)) then return false end
        end
        return to_level(mid)
    end

    local roof, floor_here   -- defined with the row code below

    ---------------------------------------------------------------- shell
    -- The face in `s` (F, U or D) is one cell of the job's shell. Keep what the
    -- policy accepts; build the chosen block over everything else: a vine, an
    -- ore, a cave, a lava pocket (a block is placed into the fluid, no bucket
    -- needed). Walls sit outside the area, so this digs where `step` may not.
    -- borrow: with nothing to build with, take the block under the turtle (the
    -- roof pass comes first and the next band digs it anyway).
    local function ensure(surface, s, borrow)
        local ok, info = s.inspect()
        local p = pos()
        local sx, sy, sz = p.x, p.y, p.z
        local fi, want = material_slot(surface)
        if Shell.wanted(ok and info or nil, surface, pol(), want) ~= "replace" then return true end
        if not fi and m.restock(surface) then
            -- the supply trip left the turtle at home: this face is not here
            -- any more, so the cell comes back in the row's second pass
            if pos().x ~= sx or pos().y ~= sy or pos().z ~= sz then return false end
            fi = material_slot(surface)
        end
        -- a named block PC121 has none of yet (owner 2026-11-07: "якщо немає
        -- потрібних блоків то хай чекають"): wait here for it, the row is not
        -- walked on with nothing to build and not given back as done
        while not fi and want and pol().supply ~= "off" and not env.ctl.stop do
            say("waiting", "no " .. Shell.label(want) .. " yet")
            env.sleep(M.SUPPLY_WAIT)
            check()
            if m.restock(surface) then
                if pos().x ~= sx or pos().y ~= sy or pos().z ~= sz then return false end
            end
            fi = material_slot(surface)
        end
        if not fi and borrow and pos().y - 1 >= job().floor then
            lava(t.inspectDown, t.placeDown, t.digDown)
            clear(t.inspectDown, t.digDown, t.detectDown)
            fi, want = material_slot(surface)
        end
        if not fi then say("no blocks", "nothing for the " .. surface) return false end
        local sel = t.getSelectedSlot()
        t.select(fi)
        if ok and not Shell.placeable(info) then
            -- look again right before the dig: another turtle may have moved
            -- into this face since the first inspect, and a turtle is never
            -- ours to break (two were lost to exactly that race, 2026-11-03)
            local ok2, info2 = s.inspect()
            if ok2 and Shell.protected(info2.name) then t.select(sel) return false end
            -- what it breaks has to fit (a builder replaces whole walls and
            -- digs little else, so clear() seldom sends it to empty itself)
            if t.getItemCount(16) > 0 and free_slots() == 0 then
                m.service()
                fi = material_slot(surface)
                if not fi then t.select(sel) return false end
                t.select(fi)
            end
            s.dig()
        end
        if not s.place() then
            -- something came in between (falling gravel, a mob, a turtle): break
            -- it only if it is not one of ours, then try once more
            local ok3, info3 = s.inspect()
            if ok3 and (Shell.protected(info3.name) or info3.name == "minecraft:bedrock") then t.select(sel) return false end
            s.dig()
            if not s.place() then t.select(sel) return false end
        end
        t.select(sel)
        return true
    end
    m.ensure = ensure

    -- the outside neighbour in direction d at this level: air, fluid or
    -- anything the policy would not accept -> a shell block goes there
    local function wall_here(dirs)
        local clean = true
        for _, d in ipairs(dirs) do
            check()
            turn_to(d)
            if not ensure("walls", F) then clean = false end
        end
        return clean
    end

    local function walls(b, dirs)
        local j = job()
        local top, mid, low = G.levels(j, b)
        local clean = wall_here(dirs)
        if top > mid then
            if up() then
                if not wall_here(dirs) then clean = false end
                if not to_level(mid) then return false end   -- a turtle under it: the low wall waits
            else
                clean = false
            end
        end
        if low < mid then
            if down() then
                if not wall_here(dirs) then clean = false end
                up()
            else
                clean = false
            end
        end
        return clean
    end

    -- The roof: a block over every cell of the area, one above the top level,
    -- where the policy wants one (a vine or an ore over the top is replaced,
    -- a block already there stays).
    -- A slab with nothing to hang from comes out the wrong half (owner
    -- 2026-11-07: a roof slab with air over it was a bottom one, and a slab
    -- over it does not hold it either). Then a whole block (the walls'
    -- material) goes in one further out first, and the slab after it.
    local function slab_half(surface, s, half, out, back)
        local ok, info = s.inspect()
        if not (ok and Shell.slab(info.name) and type(info.state) == "table"
            and info.state.type and info.state.type ~= half) then return true end
        s.dig()
        if not out() then return false end
        local ok2, info2 = s.inspect()
        if ok2 and Shell.slab(info2.name) then s.dig() end   -- a slab put there to hold it before
        local held = ensure("walls", s, false)
        if not back() or not held then return false end
        return ensure(surface, s, false)
    end

    roof = function(top, inner)
        -- a slab roof: a top slab in the top level, put up from under it
        if inner then return ensure("roof", U, true) and slab_half("roof", U, "top", up, down) end
        local climbed = false
        if pos().y < top then
            if not up() then return false end
            climbed = true
        end
        local clean = ensure("roof", U, true) and slab_half("roof", U, "top", up, down)
        if climbed then down() end
        return clean
    end

    -- The floor: a block under the cell where the policy wants one.
    floor_here = function() return ensure("floor", D) and slab_half("floor", D, "bottom", down, up) end

    ---------------------------------------------------------------- one row
    -- One cell of a band. Returns false when something in it could not be
    -- finished (a block above or below left standing, a wall not built, no
    -- shell block): the row then comes back once, and what is still left is
    -- logged as "left" instead of being forgotten.
    local function dig_cell(b)
        local j = job()
        local top, mid, low, kind, inner, bare = G.levels(j, b)
        local p = pos()
        local clean = true
        if p.y < top then
            lava(t.inspectUp, t.placeUp, t.digUp)
            if clear_face(U, 3) ~= "clear" then clean = false end
        end
        if low < mid then
            lava(t.inspectDown, t.placeDown, t.digDown)
            if clear_face(D, 3) ~= "clear" then clean = false end
        end
        local out = G.outward(j, p.x, p.z)
        if #out > 0 and j.walls ~= false and not bare and not walls(b, out) then clean = false end
        if kind == "roof" then
            if not roof(top, inner) then clean = false end
        elseif kind == "floor" then
            if not floor_here() then clean = false end
        elseif kind == "wet" then
            -- On the edge the wall one level down is built now, before that
            -- level is opened: dug next to the sea, an edge cell lets the sea
            -- in. The turtle steps down into it (taking the water's place),
            -- walls it, and comes back.
            if #out > 0 and j.walls ~= false and mid - 1 >= j.floor then
                if not (to_level(mid - 1) and wall_here(out)) then clean = false end
                if not to_level(mid) then return false end
            end
            -- the water under it filled for the next pass (geom: wet passes)
            local ok, info = t.inspectDown()
            local watery = ok and (Shell.fluid(info.name) or (type(info.state) == "table" and info.state.waterlogged))
            if watery and not ensure("walls", D, false) then clean = false end
        end
        return clean
    end

    -- Builder: the shell of this cell only; what is inside is left alone.
    local function shell_cell(b)
        local j = job()
        local top, _, _, kind, inner = G.levels(j, b)
        local clean = true
        -- the walls of the roof and floor passes too (their levels had none)
        local p = pos()
        local out = G.outward(j, p.x, p.z)
        if #out > 0 and j.walls ~= false and not walls(b, out) then clean = false end
        if kind == "roof" and not roof(top, inner) then clean = false end
        if kind == "floor" and not floor_here() then clean = false end
        return clean
    end

    -- GPS against where it thinks it is: a mismatch is logged and corrected
    function m.resync()
        local drifted = false
        local x, y, z = env.locate()
        if not x then return false end
        x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
        local p = st.pos
        if p.x ~= x or p.y ~= y or p.z ~= z then
            env.log(("drift: thought %d %d %d, is at %d %d %d"):format(p.x, p.y, p.z, x, y, z))
            drifted = true
            st.pos = {x = x, y = y, z = z}
            -- off sideways: the facing was wrong (each step went the wrong way) - measure it
            if p.x ~= x or p.z ~= z then
                local home = st.home
                m.locate()
                st.home = home
            end
            save() flush()
        end
        return drifted
    end

    -- part = {from, to}: the far half of another turtle's row (Plan split),
    -- dug from its far end; a "cut" from the remote (env.ctl.cut) stops the
    -- digger of the whole row at the cell where the helper's half begins.
    -- own = {from, to}: only this turtle's half of a row it shares with a helper
    function m.dig_row(b, x, part, own)
        local j = job()
        local builder = pol().mode == "builder"
        m.resync()
        local zmin, zmax = G.span(j, x)
        if not zmin then return true end
        local bkey = tostring(j.id) .. ":" .. tostring(st.band)
        if bkey ~= m.blocked_band then m.blocked, m.blocked_band = {}, bkey end
        m.homing = false
        local _, mid, low, kind = G.levels(j, b)
        say(builder and "build" or "dig", ("band %d/%d row %d"):format(b, j.bands, x - j.cx))
        m.nodig = builder   -- a builder job digs nothing but the shell faces
        -- inside, a failed climb is bedrock over it (the Nether's roof): pass() goes round
        if not enter(b) and not G.inside(j, pos().x, pos().z) then m.nodig = false return false, "cannot get into the circle" end
        local p = pos()
        local z0, z1, dz = zmin, zmax, 1
        if math.abs(p.z - zmax) < math.abs(p.z - zmin) then z0, z1, dz = zmax, zmin, -1 end
        if part and tonumber(part.from) and tonumber(part.to) then
            z0 = math.max(zmin, math.min(zmax, part.from))
            z1 = math.max(zmin, math.min(zmax, part.to))
            dz = z1 >= z0 and 1 or -1
        elseif own and tonumber(own.from) and tonumber(own.to) then
            local a = math.max(zmin, math.min(zmax, own.from))
            local c = math.max(zmin, math.min(zmax, own.to))
            if math.abs(p.z - c) < math.abs(p.z - a) then a, c = c, a end   -- nearer end first
            z0, z1, dz = a, c, c >= a and 1 or -1
        end
        -- the helper's far end: over the level above (dug, open), not along
        -- the row behind its digger (owner 2026-11-08: it trailed the
        -- digger the whole row, as if both dug it)
        if part and b > 1 then
            local q = pos()
            if q.x ~= x or q.z ~= z0 then
                local ptop = G.levels(j, b)
                fly(x, z0, ptop + 1)
            end
        end
        env.ctl.cut = nil
        m.row_dz = not part and dz or nil
        -- a builder job touches only the shell: shell_cell() skips every cell
        -- that is not on the ring (and does the roof/floor passes everywhere)
        local function act(z)
            if builder then return shell_cell(b) end
            return dig_cell(b)
        end
        local missed = {}
        m.left = 0
        -- one cell of the row: get into the circle again (home is outside it
        -- after a supply trip), be on the walking level, get there, do it
        local function pass(z)
            if not G.inside(j, pos().x, pos().z) and not enter(b) then return false, "enter" end
            if (pos().y == mid or to_level(mid)) and go(x, z) then
                if act(z) == false then return false, "cell" end
                return true
            end
            -- under the Nether's roof the walking level is cut up by bedrock:
            -- walk the band's low level to the cell, climb if it can, dig from there
            if low >= mid or not to_level(low) or not go(x, z) then
                local p = pos()
                return false, ("way at %d %d %d"):format(p.x, p.y, p.z)
            end
            to_level(mid)
            if act(z) == false then return false, "cell" end
            return true
        end
        for z = z0, z1, dz do
            check()
            local cut = env.ctl.cut
            if not part and cut and cut.x == x and cut.band == b and (z - cut.z) * dz > 0 then
                env.log(("row %d: the rest from z %d is another turtle's"):format(x - j.cx, cut.z + dz))
                break
            end
            -- a cell blocked a moment ago (a barrel, a turtle) is tried again below
            if m.blocked[key(x, z)] or not pass(z) then missed[#missed + 1] = z end
        end
        m.row_dz = nil
        m.blocked = {}
        for i = #missed, 1, -1 do   -- once more, nearest first on the way back
            check()
            local z = missed[i]
            local ok, why = pass(z)
            if ok then
                -- finished on the second try
            else
                env.log(("left %d %d %d: %s"):format(x, mid, z, tostring(why)))
                m.left = m.left + 1
            end
        end
        m.nodig = false
        return true
    end

    ---------------------------------------------------------------- fixes
    -- Cells the inspector found in dug levels (kopach/inspect.lua): "dig" a
    -- block or lava left inside -> go into that cell; "wall" a hole -> stand
    -- next to it inside and build the wall there. Returns {x, y, z, ok}.
    local function fix_one(c)
        local j = job()
        if c.kind == "wall" then
            for d = 0, 3 do
                local nx, nz = c.x - DX[d], c.z - DZ[d]
                if G.inside(j, nx, nz) then
                    if not to_level(c.y) then return false end
                    if not go(nx, nz) then return false end
                    turn_to(d)
                    return ensure("walls", F)
                end
            end
            return false
        end
        if not G.inside(j, c.x, c.z) or c.y > j.top or c.y < j.floor then return false end
        if not to_level(c.y) then return false end
        if not go(c.x, c.z) then return false end
        local p = pos()
        if c.kind == "lava" then
            -- a pool's top: plug the sources around (inside the area only)
            lava(t.inspectUp, t.placeUp, t.digUp)
            lava(t.inspectDown, t.placeDown, t.digDown)
            for d = 0, 3 do
                if G.inside(j, p.x + DX[d], p.z + DZ[d]) then turn_to(d) lava(t.inspect, t.place, t.dig) end
            end
        end
        return p.x == c.x and p.y == c.y and p.z == c.z
    end

    function m.fix(cells)
        say("fix", ("%d cells"):format(#cells))
        m.homing, m.nodig, m.blocked = false, false, {}
        local results = {}
        for _, c in ipairs(cells) do
            check()
            local ok, ok2 = pcall(fix_one, c)
            if not ok and ok2 == STOP then error(STOP, 0) end
            local fine = ok and ok2 == true
            results[#results + 1] = {x = c.x, y = c.y, z = c.z, ok = fine}
            if not fine then env.log(("fix failed %s %d %d %d"):format(c.kind, c.x, c.y, c.z)) end
        end
        return results
    end

    ---------------------------------------------------------------- lost
    -- Outside the pit in the middle of a job (2026-11-06: a wrong facing walked
    -- eight of them out into the rock). Tunnel straight back towards the centre
    -- at this height, then close the hole it made in the wall behind it. The
    -- only time a turtle digs outside the circle: one tunnel, sealed.
    function m.come_back()
        local j = job()
        if not j then return false end
        say("travel", "back into the pit")
        m.homing = false
        for _ = 1, 2 * (j.R + 200) do
            check()
            local p = pos()
            if G.inside(j, p.x, p.z) then
                if p.y > j.top and not to_level(j.top) then return false end
                -- the wall cell it came through: build it again
                if j.walls ~= false then
                    local back = st.dir and (st.dir + 2) % 4
                    if back and not G.inside(j, p.x + DX[back], p.z + DZ[back]) then
                        turn_to(back)
                        ensure("walls", F)
                    end
                end
                env.log(("back in the pit at %d %d %d"):format(p.x, p.y, p.z))
                return true
            end
            local dx, dz = j.cx - p.x, j.cz - p.z
            local d
            if math.abs(dx) >= math.abs(dz) then d = dx > 0 and 0 or 2 else d = dz > 0 and 1 or 3 end
            turn_to(d)
            lava(t.inspect, t.place, t.dig)
            local ok, info = t.inspect()
            if ok and not M.natural(ok, info) then
                if is_turtle(ok, info) then env.sleep(1)
                else
                    -- bedrock or one of ours ahead: one up and on
                    lava(t.inspectUp, t.placeUp, t.digUp)
                    local oku, infou = t.inspectUp()
                    if oku and not M.natural(oku, infou) then return false end
                    if oku then t.digUp() end
                    if t.up() then st.pos = {x = p.x, y = p.y + 1, z = p.z} save() end
                end
            else
                if ok then t.dig() end
                fuel(1)
                if t.forward() then
                    st.pos = {x = p.x + DX[d], y = p.y, z = p.z + DZ[d]}
                    save()
                else
                    t.attack()
                end
            end
        end
        return false
    end

    ---------------------------------------------------------------- home
    -- Home without breaking anything: back through what is dug at this level
    -- to the home column, then up or down it; blocked at this level: one up
    -- and try again. Never wanders off looking for a way (owner 2026-11-03:
    -- after STOP they tunnelled away along the roof).
    function m.go_home()
        local h, j = st.home, job()
        if not h then return true end
        say("home")
        m.homing = true
        local saved_blocked = m.blocked
        m.blocked = {}
        -- a turtle passing in its lane is waited for (2026-11-08: a lane
        -- crossed the home column and the turtle gave up "cannot get home")
        local function vertical()
            local waits = 0
            while pos().y ~= h.y do
                local ok, why
                if pos().y < h.y then ok, why = up() else ok, why = down() end
                if not ok then
                    if why ~= "turtle" or waits >= 60 then return false end
                    waits = waits + 1
                    env.sleep(1)
                end
            end
            return true
        end
        local home = false
        local p = pos()
        if j and G.inside(j, h.x, h.z) and G.inside(j, p.x, p.z) then
            for _ = 1, 400 do
                if go(h.x, h.z) then
                    if vertical() then home = true break end
                    env.sleep(1)   -- another turtle in the home column: let it pass
                elseif holding() then
                    env.sleep(1)   -- the way is held by turtles only: wait, do not climb
                else
                    m.blocked = {}
                    if not up() then break end
                end
            end
        else
            -- over the homes, not through their row (they stand in a line
            -- on the ocean wall); each turtle a lane of its own height
            home = fly(h.x, h.z, math.max(h.y + 1 + (env.turtle_id or 0) % 3, pos().y)) and vertical()
        end
        m.homing = false
        m.blocked = saved_blocked
        if not home then say("stuck", "cannot get home") end
        return home
    end

    local restock_next = 0   -- after a refusal PC121 is asked again in two minutes

    -- A stack of shell blocks from PC121 (it puts them in the barrel's slot 1);
    -- with nothing named, the shell block its stock has most of.
    local function restock_barrel(want, surface)
        local got = false
        with_storage(function(suck, drop, _, bslot)
            if not want then
                local items = env.supply.stock()
                if not items then return end
                local slots = {}
                for name, count in pairs(items) do slots[#slots + 1] = {slot = #slots + 1, name = name, count = count} end
                want = select(2, Shell.choose(slots, surface, pol()))
            end
            if not want then return end
            local have = 0
            for _, s in ipairs(inventory()) do if s.name == want then have = have + s.count end end
            if have >= 64 then got = true return end
            local slot = empty_slot(bslot)
            if not slot then return end
            local r = env.supply.want(want, 64 - have)
            if not (r and r.t == "ready") then
                env.log("supply: no " .. Shell.label(want) .. " (" .. Supply.why(r) .. ")")
                return
            end
            local sel = t.getSelectedSlot()
            t.select(slot)
            suck(64 - have)
            local d = t.getItemDetail(slot)
            if d and d.name == want then got = true
            elseif d then drop() end   -- not ours: another turtle unloaded in between
            t.select(sel)
            env.supply.took()
        end)
        if got then say("supply", Shell.label(want)) end
        return got, want
    end

    function m.restock(surface)
        local stamp = env.now()
        if stamp < restock_next then return false end
        if pol().supply == "off" then return false end
        -- full of what it took out (old walls in a builder job): no slot to
        -- take the blocks into, so empty itself first
        if free_slots() == 0 then m.service() end
        local _, want = material_slot(surface)
        local got, asked = restock_barrel(want, surface)
        m.forget_material()
        if not got then
            restock_next = stamp + 120
            say("no supply", "no " .. Shell.label(asked or want) .. " at PC121")
        end
        return got
    end

    ---------------------------------------------------------------- main loop
    -- One turn of work: ask for a row and dig it. Returns the reply kind.
    function m.work_once()
        m.homing = false
        check()
        local p = pos()
        local reply = env.link.want({x = p.x, y = p.y, z = p.z, fuel = t.getFuelLevel()})
        if not reply then say("no remote") return "none" end
        if reply.kind == "idle" then
            if reply.why == "outside" and st.job and st.job.id == reply.job then
                -- lost its way out of the pit in this job: dig back in by itself
                if m.come_back() then return "wait" end
                say("outside", "carry it into the pit") return "idle"
            end
            if st.job then m.go_home() st.job, st.band, st.x = nil, nil, nil save() flush() end
            env.ctl.stop = false
            say("idle") return "idle"
        end
        if reply.kind == "wait" then
            -- out of the band while the others finish: a turtle left standing
            -- in a row blocks the one finishing its other half (2026-11-07:
            -- 179 sat over helper 171 and the whole swarm waited on them)
            -- a home outside the area (on the ocean wall, 2026-11-08): the
            -- whole crowd flying there at every band end jammed; out of the
            -- band's way, one level over it, is enough
            if st.job then
                local j, h = job(), st.home
                if h and not G.inside(j, h.x, h.z) and G.inside(j, p.x, p.z) and st.band then
                    -- two levels over it: helpers fly to their half one level
                    -- over the band and go down there (2026-11-08: 166 parked
                    -- right over helper 171's cell and the swarm waited)
                    -- a turtle over it (a helper coming down into this
                    -- column): one cell aside first, or both wait for good
                    local top = G.levels(j, st.band)
                    if p.y <= top + 1 then
                        local ok, info = t.inspectUp()
                        if ok and tostring(info.name):find("turtle") then
                            for d = 0, 3 do
                                if G.inside(j, p.x + DX[d], p.z + DZ[d]) then
                                    turn_to(d)
                                    if fwd() then break end
                                end
                            end
                        end
                        to_level(top + 2)
                    end
                else
                    m.go_home()
                end
            end
            say("wait", "others finish this band") return "wait"
        end
        if reply.kind == "fix" and type(reply.cells) == "table" and reply.job then
            if not st.job or st.job.id ~= reply.job.id then st.job, st.band = reply.job, nil save() flush() end
            if t.getFuelLevel() < M.LOW_FUEL then fuel(M.LOW_FUEL) end
            local results = m.fix(reply.cells)
            if env.link.fixed then env.link.fixed(st.job.id, results) end
            return "row"   -- ask again at once
        end
        if reply.kind == "finish" then
            if st.job then m.go_home() m.service() end
            st.job, st.band, st.x = nil, nil, nil save() flush()
            say("done") return "finish"
        end
        if reply.kind == "row" then
            -- a new job: home is the cell it was placed in (locate keeps it; a
            -- turtle the owner moves is placed again and boots), else where it is
            if not st.job or st.job.id ~= reply.job.id then st.home = st.home or {x = p.x, y = p.y, z = p.z} end
            st.job, st.band, st.x = reply.job, reply.band, reply.x
            save() flush()
            if t.getFuelLevel() < M.LOW_FUEL then fuel(M.LOW_FUEL) end
            if reply.part then say("dig", ("band %d half of row %d"):format(reply.band, reply.x - reply.job.cx)) end
            local ok, why = m.dig_row(reply.band, reply.x, reply.part, reply.own)
            if not ok then
                say("stuck", why)
                -- outside the pit it may not dig its way in, so asking again
                -- every two seconds only burns rows: back off and say what
                -- the owner has to do
                if why == "cannot get into the circle" then
                    say("stuck", "outside the pit: move it")
                    env.sleep(10)
                else
                    env.sleep(2)
                end
            end
            env.link.done(st.job.id, reply.band, reply.x, ok and m.left or -1, reply.part and true or nil)   -- -1: not dug, give it out again
            st.x = nil save()
            return ok and "row" or "stuck"
        end
        return "none"
    end

    -- after a stop: back home, forget the job
    function m.stopped()
        env.ctl.stop = false
        local j = st.job
        if j then m.go_home() m.service() end
        st.job, st.band, st.x = nil, nil, nil save() flush()
        say("stopped")
    end

    m.STOP = STOP
    return m
end

M.STOP = STOP
M.stats = {paths = 0, visited = 0}   -- what the row walker had to search
return M
