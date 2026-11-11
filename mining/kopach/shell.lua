-- What a job's shell (walls, roof, floor) is made of, and what may stand in
-- its place. Pure Lua: no turtle API, no fs, no clock, so the remote and the
-- tests ask the same questions the turtle asks on site.
--
-- Two dials per job:
--   order    "bulk"     - the shell material you have MOST of in the inventory
--                         (owner 2026-11-03: "той якого найбільше в інвентарі")
--            "priority" - the cheapest in Shell.PRIORITY; the count only breaks ties
--   replace  "all"      - everything that is not the chosen block: the shell
--                         is built, not patched (the default)
--            "soft+ores"- keep any solid block, but vines, plants, fluids and
--                         every *_ore go
--            "soft"     - keep the ores too
--            "holes"    - air and fluids only: the old behaviour, leaves vines
--   supply   "barrel"   - out of blocks, ask PC121 for them: it puts them in
--                         the linked barrel every turtle carries (the default;
--                         kopach/supply.lua, 121/counter.lua)
--            "off"      - only what it digs (lava is asked for either way)
--
-- Materials: materials.walls is what all three surfaces use unless
-- materials.roof / materials.floor name their own (any of them may be empty
-- or left out = pick from the inventory by `order`).
--
-- The shell of a band is the three levels a turtle digs: the outside face of
-- the circle's edge (walls), the block over the top level (roof) and the block
-- under the floor level (floor). Shell.wanted() answers "keep it / replace it
-- / do not touch it" for what is found there.
local Shell = {}

Shell.ORDER = {"bulk", "priority"}
Shell.REPLACE = {"all", "soft+ores", "soft", "holes"}
Shell.SUPPLY = {"barrel", "off"}
Shell.SURFACES = {"walls", "roof", "floor"}

-- Cheap, common blocks first (the same ladder the turtles used before). What
-- is not listed is never used as shell material unless the owner names it.
Shell.PRIORITY = {
    ["minecraft:cobblestone"] = 1,
    ["minecraft:cobbled_deepslate"] = 1,
    ["minecraft:stone"] = 2,
    ["minecraft:deepslate"] = 2,
    ["minecraft:netherrack"] = 2,
    ["minecraft:blackstone"] = 2,
    ["minecraft:basalt"] = 3,
    ["minecraft:dirt"] = 3,
    ["minecraft:andesite"] = 3,
    ["minecraft:diorite"] = 3,
    ["minecraft:granite"] = 3,
    ["minecraft:tuff"] = 3,
    ["minecraft:calcite"] = 3,
    ["minecraft:dripstone_block"] = 3,
    ["minecraft:mossy_cobblestone"] = 2,
    ["minecraft:nether_bricks"] = 3,
    -- the owner's picks (2026-11-06; black concrete dropped again: ghasts break it)
    ["minecraft:polished_deepslate"] = 4,
    ["minecraft:deepslate_bricks"] = 4,
    ["create:cut_deepslate_bricks"] = 4,
    ["create:polished_cut_deepslate"] = 4,
}

-- Slabs (owner 2026-11-06): for the floor and the roof only, and only when
-- named in the Shell tab. The floor is placed down from above (a bottom
-- slab), the roof up from below (a top slab): that is how a turtle places.
Shell.SLABS = {
    "minecraft:cobblestone_slab", "minecraft:stone_slab", "minecraft:smooth_stone_slab",
    "minecraft:stone_brick_slab", "minecraft:cobbled_deepslate_slab", "minecraft:blackstone_slab",
    "minecraft:polished_blackstone_slab", "minecraft:nether_brick_slab", "minecraft:mossy_cobblestone_slab",
    "minecraft:andesite_slab", "minecraft:diorite_slab", "minecraft:granite_slab", "minecraft:tuff_slab",
    "minecraft:polished_deepslate_slab", "minecraft:deepslate_brick_slab",
    "create:cut_deepslate_brick_slab", "create:polished_cut_deepslate_slab",
}
function Shell.slab(name) return type(name) == "string" and name:find("_slab$") ~= nil end

-- What the Shell tab offers for a surface: every whitelisted block (the base
-- keeps them all in the barrel), the floor also the slabs.
function Shell.choices(surface)
    local list = {}
    for name in pairs(Shell.PRIORITY) do list[#list + 1] = name end
    table.sort(list, function(a, b)
        if Shell.PRIORITY[a] ~= Shell.PRIORITY[b] then return Shell.PRIORITY[a] < Shell.PRIORITY[b] end
        return a < b
    end)
    if surface == "floor" or surface == "roof" then for _, n in ipairs(Shell.SLABS) do list[#list + 1] = n end end
    return list
end

-- Never shell material, even if someone puts it in the priority list: ores and
-- mineral blocks are worth more than a wall (owner 2026-11-03: "будь яку руду
-- і т д" - the ore goes, the wall does not get built out of it).
Shell.DENY = {
    "_ore$", "^minecraft:ancient_debris$", "_block$", "^minecraft:raw_", "^minecraft:.*_chest$",
    "^minecraft:barrel$", "^minecraft:.*_box$", "^minecraft:hopper$", "^minecraft:spawner$",
    "^minecraft:.*_bed$", "^minecraft:.*_sign$", "^minecraft:.*shulker",
}

-- Blocks with no collision that can sit in a wall and still leave a hole:
-- they have to go before the shell block can be placed.
Shell.SOFT = {
    "^minecraft:vine$", "^minecraft:glow_lichen$", "^minecraft:hanging_roots$", "_carpet$",
    "^minecraft:snow$", "^minecraft:short_grass$", "^minecraft:grass$", "^minecraft:tall_grass$",
    "^minecraft:fern$", "^minecraft:large_fern$", "^minecraft:dead_bush$", "_flower$",
    "^minecraft:dandelion$", "^minecraft:poppy$", "^minecraft:blue_orchid$", "^minecraft:allium$",
    "^minecraft:azure_bluet$", "^minecraft:oxeye_daisy$", "^minecraft:cornflower$",
    "^minecraft:lily_of_the_valley$", "^minecraft:wither_rose$", "^minecraft:torchflower$",
    "^minecraft:sunflower$", "^minecraft:lilac$", "^minecraft:rose_bush$", "^minecraft:peony$",
    "^minecraft:torch$", "^minecraft:wall_torch$", "^minecraft:soul_torch$", "^minecraft:soul_wall_torch$",
    "^minecraft:lantern$", "^minecraft:soul_lantern$", "^minecraft:cobweb$", "^minecraft:kelp",
    "^minecraft:seagrass$", "^minecraft:tall_seagrass$", "_sapling$", "^minecraft:brown_mushroom$",
    "^minecraft:red_mushroom$", "^minecraft:sugar_cane$", "^minecraft:bamboo$", "^minecraft:lily_pad$",
    "^minecraft:crimson_roots$", "^minecraft:warped_roots$", "^minecraft:nether_sprouts$",
    "^minecraft:weeping_vines", "^minecraft:twisting_vines", "^minecraft:cave_vines",
    "_coral$", "_coral_fan$", "_coral_wall_fan$", "^minecraft:moss_carpet$", "^minecraft:pink_petals$",
    "^minecraft:spore_blossom$", "^minecraft:big_dripleaf$", "^minecraft:small_dripleaf$",
    "^minecraft:azalea$", "^minecraft:flowering_azalea$", "_bush$", "^minecraft:fire$",
    "^minecraft:soul_fire$", "^minecraft:scaffolding$", "^minecraft:ladder$", "^minecraft:rail$",
    "^minecraft:.*_button$", "^minecraft:.*_pressure_plate$", "^minecraft:lever$", "^minecraft:tripwire",
}

Shell.FLUID = {["minecraft:water"] = true, ["minecraft:lava"] = true,
    -- water plants and bubbles are water too: broken, they leave a source
    -- (owner 2026-11-08, an ocean drained)
    ["minecraft:kelp"] = true, ["minecraft:kelp_plant"] = true, ["minecraft:seagrass"] = true,
    ["minecraft:tall_seagrass"] = true, ["minecraft:bubble_column"] = true, ["minecraft:sea_pickle"] = true}

-- Containers: the turtle takes back only one of these after placing its barrel.
Shell.CONTAINERS = {"chest", "shulker", "barrel", "crate"}

-- Blocks the turtles must never break or build over: other computers, our own
-- storage barrels, bedrock (the miner's `natural` already refuses these).
Shell.PROTECTED = {"^computercraft:", "^sophisticatedstorage:"}

local function matches(name, list)
    for _, pattern in ipairs(list) do
        if name:find(pattern) then return true end
    end
    return false
end

function Shell.denied(name) return matches(name, Shell.DENY) end
function Shell.soft(name) return matches(name, Shell.SOFT) end
function Shell.protected(name) return matches(name, Shell.PROTECTED) end
function Shell.container(name) return matches(name, Shell.CONTAINERS) end
function Shell.ore(name) return name:find("_ore$") ~= nil or name == "minecraft:ancient_debris" end
function Shell.fluid(name) return Shell.FLUID[name] == true or name:find("minecraft:flowing_") ~= nil end

-- "minecraft:cobblestone" -> "cobblestone" (screens have 26-39 columns)
function Shell.label(name)
    if not name or name == "" then return "auto" end
    return (name:gsub("^minecraft:", ""))
end

function Shell.defaults()
    return {mode = "dig", order = "bulk", replace = "all", supply = "barrel", materials = {}}
end

local function list_of(v)
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then return {v} end
    return nil
end

-- Normalise what the remote put in the job (or a saved job from an older
-- version, or nothing at all) into the table the rest of this file uses.
function Shell.policy(shell)
    local p = Shell.defaults()
    if type(shell) == "table" then
        if shell.mode == "builder" then p.mode = "builder" end
        for _, v in ipairs(Shell.ORDER) do if shell.order == v then p.order = v end end
        for _, v in ipairs(Shell.REPLACE) do if shell.replace == v then p.replace = v end end
        for _, v in ipairs(Shell.SUPPLY) do if shell.supply == v then p.supply = v end end
        if type(shell.materials) == "table" then
            for _, surface in ipairs(Shell.SURFACES) do
                local want = list_of(shell.materials[surface])
                if want and #want > 0 then
                    local kept = {}
                    for _, name in ipairs(want) do
                        if type(name) == "string" and name ~= "" then kept[#kept + 1] = name end
                    end
                    if #kept > 0 then p.materials[surface] = kept end
                end
            end
        end
    end
    p.set = {soft = p.replace ~= "holes", ores = p.replace == "soft+ores" or p.replace == "all", all = p.replace == "all"}
    return p
end

-- The policy of a job: `mode` sits beside `shell` in the job record (the tab
-- shows it as its own row), everything else is inside it.
function Shell.from_job(job)
    if not (job and job.shell) then
        -- A job started before this code (or by an older remote) carries no
        -- shell settings: keep exactly its old behaviour until it ends, so a
        -- mid-job deploy changes nothing the owner did not ask for.
        -- ...except the supply: out of blocks under a lava lake it plugged
        -- nothing and left the sources (2026-11-06), so the barrel refills it
        return Shell.policy({mode = "dig", order = "priority", replace = "holes", supply = "barrel"})
    end
    local shell = job.shell
    return Shell.policy({mode = job.mode, order = shell.order, replace = shell.replace,
        supply = shell.supply, materials = shell.materials})
end

-- The ladder position of a block, or nil when it may not be shell material.
function Shell.rank(name, pol)
    if type(name) ~= "string" or name == "" then return nil end
    if Shell.protected(name) or Shell.ore(name) then return nil end
    -- the ladder names blocks one by one, so it wins over the DENY patterns
    -- (dripstone_block matched "_block$" and was never used)
    if Shell.denied(name) and not Shell.PRIORITY[name] then return nil end
    if pol and pol.materials then
        for _, surface in ipairs(Shell.SURFACES) do
            local want = pol.materials[surface]
            if want then
                for _, n in ipairs(want) do if n == name then return 0 end end   -- named by the owner: best
            end
        end
    end
    return Shell.PRIORITY[name]
end

-- Could this block be used for the shell at all?
function Shell.is_material(name, pol) return Shell.rank(name, pol) ~= nil end

-- A turtle's inventory as {{slot = 1, name = "minecraft:cobblestone", count = 64}, ...}
-- -> slot, name of the block this surface should be built from (nil when the
-- inventory has nothing usable, or when a named block is missing).
function Shell.choose(slots, surface, pol)
    pol = pol or Shell.defaults()
    local want = pol.materials[surface] or pol.materials.walls
    if want and surface ~= "floor" and surface ~= "roof" then
        -- a slab named for the floor or the roof is no wall
        local solid = {}
        for _, n in ipairs(want) do if not Shell.slab(n) then solid[#solid + 1] = n end end
        want = #solid > 0 and solid or nil
    end
    if want then
        for _, n in ipairs(want) do
            local best
            for _, s in ipairs(slots) do
                if s.name == n and s.count > 0 and (not best or s.count > best.count) then best = s end
            end
            if best then return best.slot, best.name end
        end
        return nil, want[1]   -- named but not in the inventory
    end
    local best, bestkey
    for _, s in ipairs(slots) do
        local rank = not Shell.slab(s.name) and Shell.rank(s.name, pol)
        if rank and s.count > 0 then
            local key
            if pol.order == "priority" then
                key = {rank, -s.count, s.slot}
            else
                key = {-s.count, rank, s.slot}
            end
            local better = not bestkey
            if bestkey then
                for i = 1, 3 do
                    if key[i] ~= bestkey[i] then better = key[i] < bestkey[i] break end
                end
            end
            if better then best, bestkey = s, key end
        end
    end
    if best then return best.slot, best.name end
end

-- Can the turtle place into this block, or must it break it first?
-- (air, fluids and replaceable plants take a block; a vine or an ore does not)
function Shell.placeable(info)
    if not info then return true end
    local name = info.name or ""
    if Shell.fluid(name) then return true end
    local tags = info.tags
    return tags ~= nil and tags["minecraft:replaceable"] == true
end

-- "keep"    - a proper shell block already sits there
-- "replace" - break it (when it is not placeable) and build the shell block
-- "skip"    - never touch it (bedrock, computers, our own storage)
-- material: the block this turtle would put there (from its inventory); with
-- `all` a face already made of it is kept, anything else is rebuilt.
function Shell.wanted(info, surface, pol, material)
    pol = pol or Shell.defaults()
    if not info then return "replace" end                       -- air: a hole
    local name = info.name or ""
    if name == "minecraft:bedrock" then return "skip" end
    if Shell.protected(name) then return "skip" end
    if Shell.fluid(name) then return "replace" end
    local tags = info.tags
    if tags and tags["minecraft:replaceable"] then return "replace" end
    if pol.set.all then
        if material then return name == material and "keep" or "replace" end
        return "keep"                                          -- nothing to build with
    end
    if Shell.soft(name) then
        return pol.set.soft and "replace" or "keep"             -- "holes" leaves the old bug
    end
    if Shell.ore(name) then
        return pol.set.ores and "replace" or "keep"
    end
    return "keep"
end

-- One line for the screens: "bulk · soft+ores".
function Shell.summary(pol)
    pol = pol or Shell.defaults()
    return ("%s · %s"):format(pol.order, pol.replace)
end

return Shell
