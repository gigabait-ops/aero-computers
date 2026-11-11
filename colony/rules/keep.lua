-- Zapas: how much of each item the colony warehouse holds.
--   predmet = the item's ID (JEI/EMI shows it)
--   min     = at least this many: more is ordered from Create storage
--   maks    = at most this many: the extra goes back to Create storage
--   mistyt  = instead of predmet: every item whose ID contains this text
--   nazva   = label on the screen, hrupa = heading on the Keep tab
--   chysti  = true: only tools without enchantments or damage
--             (colony workers refuse enchanted tools until hut level 5)
--   variatsii = true: a maks line also sends worn, dyed or enchanted ones
--   vid     = send even when only this many are extra (else 64, vyviz.vid)
-- One line per item, with a min, a maks or both:
--   {predmet = "minecraft:potato", min = 64, nazva = "Potato", hrupa = "Food"},
--   {predmet = "minecraft:cobblestone", maks = 256},
--   {mistyt = "_log", maks = 128},
-- Saved changes work within a few seconds.
return {
    -- Food for the cook
    {predmet = "minecraft:potato",   min = 64, nazva = "Potato",   hrupa = "Food"},
    {predmet = "minecraft:carrot",   min = 64, nazva = "Carrot",   hrupa = "Food"},
    {predmet = "minecraft:apple",    min = 64, nazva = "Apple",    hrupa = "Food"},
    {predmet = "minecraft:beetroot", min = 64, nazva = "Beetroot", hrupa = "Food"},
    {predmet = "minecraft:bread",    min = 64, nazva = "Bread",    hrupa = "Food"},

    -- One tool of each kind for new workers
    {predmet = "minecraft:wooden_pickaxe", min = 1, nazva = "Wooden pickaxe", hrupa = "Tools", chysti = true},
    {predmet = "minecraft:wooden_axe",     min = 1, nazva = "Wooden axe",     hrupa = "Tools", chysti = true},
    {predmet = "minecraft:wooden_shovel",  min = 1, nazva = "Wooden shovel",  hrupa = "Tools", chysti = true},
    {predmet = "minecraft:wooden_hoe",     min = 1, nazva = "Wooden hoe",     hrupa = "Tools", chysti = true},
    {predmet = "minecraft:wooden_sword",   min = 1, nazva = "Wooden sword",   hrupa = "Tools", chysti = true},
    {predmet = "minecraft:stone_pickaxe",  min = 1, nazva = "Stone pickaxe",  hrupa = "Tools", chysti = true},
    {predmet = "minecraft:stone_axe",      min = 1, nazva = "Stone axe",      hrupa = "Tools", chysti = true},
    {predmet = "minecraft:stone_shovel",   min = 1, nazva = "Stone shovel",   hrupa = "Tools", chysti = true},
    {predmet = "minecraft:stone_hoe",      min = 1, nazva = "Stone hoe",      hrupa = "Tools", chysti = true},
    {predmet = "minecraft:stone_sword",    min = 1, nazva = "Stone sword",    hrupa = "Tools", chysti = true},
    {predmet = "minecraft:iron_pickaxe",   min = 1, nazva = "Iron pickaxe",   hrupa = "Tools", chysti = true},
    {predmet = "minecraft:iron_axe",       min = 1, nazva = "Iron axe",       hrupa = "Tools", chysti = true},
    {predmet = "minecraft:iron_shovel",    min = 1, nazva = "Iron shovel",    hrupa = "Tools", chysti = true},
    {predmet = "minecraft:iron_hoe",       min = 1, nazva = "Iron hoe",       hrupa = "Tools", chysti = true},
    {predmet = "minecraft:iron_sword",     min = 1, nazva = "Iron sword",     hrupa = "Tools", chysti = true},
    {predmet = "minecraft:bow",            min = 1, nazva = "Bow",            hrupa = "Tools", chysti = true},
    {predmet = "minecraft:fishing_rod",    min = 1, nazva = "Fishing rod",    hrupa = "Tools", chysti = true},
    {predmet = "minecraft:shears",         min = 1, nazva = "Shears",         hrupa = "Tools", chysti = true},

    -- Too much of these goes back to Create storage (needs a way out in config.lua)
    -- {predmet = "minecraft:cobblestone", maks = 256, nazva = "Cobblestone", hrupa = "Blocks"},
    -- {predmet = "minecraft:dirt",        maks = 0,   nazva = "Dirt",        hrupa = "Blocks"},
    -- {mistyt = ":", maks = 64},   -- everything else: keep one stack, the rest goes back
}
