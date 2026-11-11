-- Basin station (kind = "basin"): Create mixing and compacting. Rules as in turtle_crafting.lua:
-- target and limit, optionally always/from/keep, orderLimit and cooldown.
-- The craft controller gives these targets to the basin station, since only
-- it makes them. Shown on the station's own tab. This file is optional.
return {
    example_basin = {
        enabled = false,
        target = "create:pulp",
        limit = 64,
    },
}
