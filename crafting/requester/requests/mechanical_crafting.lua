-- Mechanical crafter station (kind = "mechanical"). Rules as in turtle_crafting.lua:
-- target and limit, optionally always/from/keep, orderLimit and cooldown.
-- The craft controller gives these targets to the mechanical station, since only
-- it makes them. Shown on the station's own tab. This file is optional.
return {
    example_mechanical = {
        enabled = false,
        target = "create:crushing_wheel",
        limit = 64,
    },
}
