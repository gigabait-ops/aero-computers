-- Saw station (kind = "saw"): stonecutting and Create cutting. Rules as in turtle_crafting.lua:
-- target and limit, optionally always/from/keep, orderLimit and cooldown.
-- The craft controller gives these targets to the saw station, since only
-- it makes them. Shown on the station's own tab. This file is optional.
return {
    example_saw = {
        enabled = false,
        target = "minecraft:stone_brick_stairs",
        limit = 64,
    },
}
