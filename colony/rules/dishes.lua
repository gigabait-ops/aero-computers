-- Stravy: when the colony asks for a dish the cook makes in its furnace,
-- the raw ingredient is delivered instead and the cook roasts or bakes it.
--   ["dish"] = { {predmet = "ingredient", na_odnu = how many per dish, maks = cap} }
-- na_odnu is 1 when left out; maks caps one order (else zamovlennia.maks).
-- Food eaten raw (apple, carrot, beetroot...) needs no line.
-- Saved changes work within a few seconds.
return {
    -- furnace: the cook bakes / roasts these
    ["minecraft:baked_potato"]   = { {predmet = "minecraft:potato"} },
    ["minecraft:cooked_chicken"] = { {predmet = "minecraft:chicken"} },
    ["minecraft:cooked_beef"]    = { {predmet = "minecraft:beef"} },
    ["minecraft:cooked_porkchop"]= { {predmet = "minecraft:porkchop"} },
    ["minecraft:cooked_mutton"]  = { {predmet = "minecraft:mutton"} },
    ["minecraft:cooked_rabbit"]  = { {predmet = "minecraft:rabbit"} },
    ["minecraft:cooked_cod"]     = { {predmet = "minecraft:cod"} },
    ["minecraft:cooked_salmon"]  = { {predmet = "minecraft:salmon"} },
    ["minecraft:dried_kelp"]     = { {predmet = "minecraft:kelp"} },

    -- NOT here: mushroom stew, beetroot soup, rabbit stew, pumpkin pie.
    -- The restaurant cook only smelts in its furnace; it has no crafting
    -- table, so those dishes are delivered ready-made from storage.
}
