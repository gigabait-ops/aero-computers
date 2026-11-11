-- Supply base of the kopach mining turtles: what the stock chest keeps for
-- them. A turtle asks over rednet for lava (fuel) or a wall/floor block; the
-- base puts it in slot 1 of the barrel linked with the turtles' barrels and
-- the turtle takes it. Everything the turtles unload, and whatever the stock
-- holds over `keep`, goes to the outbox (a chest linked with your storage).
-- Items under `keep` are ordered from the craft controller (crafting-controller
-- role): first from the warehouse, and made when the warehouse has none.
-- The file is read again every few seconds: no reboot needed after a change.
return {
    -- Address (Create frogport / package address) of this base: the craft
    -- controller sends the ordered items there. Set it before you fill
    -- `keep`: without it the orders carry no address. Without a craft
    -- controller on the network nothing is ordered; the base still sorts
    -- and serves what the stock holds.
    address = nil,          -- e.g. "Mining Base"

    -- Peripheral names; nil = found at runtime on the wired network:
    --   barrel: the first sophisticatedstorage or minecraft barrel
    --   stock:  the first sophisticatedstorage chest (name a vanilla or other
    --           chest here yourself)
    --   outbox: any other inventory that is not a Create packager
    barrel = nil,           -- e.g. "sophisticatedstorage:barrel_0"
    stock = nil,            -- e.g. "sophisticatedstorage:chest_0"
    outbox = nil,           -- e.g. "minecraft:chest_0"

    -- item id -> how many the stock keeps. Empty: nothing is kept and the
    -- turtles get only what they carry and dig. Lava buckets do not stack:
    -- the stock and the barrel need stack upgrades to hold many.
    -- The wall and floor blocks the turtles can build with are the lists in
    -- kopach/shell.lua.
    keep = {
        -- ["minecraft:lava_bucket"] = 64,
        -- ["minecraft:cobblestone"] = 256,
        -- ["minecraft:cobbled_deepslate"] = 256,
        -- ["minecraft:cobblestone_slab"] = 128,
    },
}
