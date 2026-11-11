-- Colony Supply settings. "install setup" fills them in for you.
-- Save the file (Ctrl, Save): the program starts again by itself.
-- The addresses (the colony's, the storage's, each hut's) are in
-- rules/addresses.lua.
return {
    -- sklad: your Create storage
    sklad = {
        tiker = "auto",            -- its stock ticker: "auto" or a name like "Create_StockTicker_3"
    },

    -- kolonia: the colony side
    kolonia = {
        sklad = "auto",            -- the warehouse hut on a cable, false = none
        tiker = false,             -- OPTIONAL ticker on the colony's own network: "auto" or a name
        dostavka = "skrynia",      -- "skrynia": packages land in a chest, the computer moves them
                                   -- "pryamo":  the packager sits on the warehouse hut
        skrynia = false,           -- that chest's name, only for "skrynia"
    },

    -- vyviz: the extra goes back to Create storage (maks in rules/keep.lua)
    vyviz = {
        cherez = "auto",           -- "tiker": the colony's ticker; "skrynia": an outbox chest
        skrynia = false,           -- the outbox chest's name, only for "skrynia"
    },

    zapas = true,       -- bring items up to their min (rules/keep.lua)
    budivelnyk = true,  -- bring building materials before the builder asks
    stravy = true,      -- bring raw food for oven dishes (rules/dishes.lua)

    ekran = {
        monitor = "auto",          -- an attached monitor shows the same screen, false = off
        rozmir = 0.5,              -- text size on the monitor, 0.5 to 5
        palitra = true,            -- soft colours, false = plain Minecraft colours
    },

    -- OPTIONAL: messages in the game chat through a Chat Box on the
    -- computer; without one nothing happens. Which and how often: rules/chat.lua
    chat = {
        mova = "uk",               -- "uk" or "en"
        radius = 128,              -- players within this many blocks hear it
    },
}
