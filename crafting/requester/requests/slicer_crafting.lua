-- Slicer station (kind = "slicer"): Slice & Dice cutting. Rules as in turtle_crafting.lua:
-- target and limit, optionally always/from/keep, orderLimit and cooldown.
-- The craft controller gives these targets to the slicer station, since only
-- it makes them. Shown on the station's own tab. This file is optional.
return {
    example_slicer = {
        enabled = false,
        target = "farmersdelight:tree_bark",
        limit = 64,
    },
}
