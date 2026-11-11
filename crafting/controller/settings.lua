-- Craft controller settings. Every key not set here comes from
-- controller/defaults.lua; put only what you change here.
return {
    -- The Stock Ticker the controller orders through. nil (or left out) finds
    -- the only one on the network; name it when the network has several.
    -- ticker = "Create_StockTicker_0",

    -- Create machines without a computer (fans, crushing wheels, a press...).
    -- When a turtle, a station or an order lacks an item that only such a
    -- machine makes, the controller orders the ingredients to the machine's
    -- address and waits for the result to come back to the warehouse; a
    -- missing ingredient is made first.
    --   address - the Create package address of the machine (the frogport or
    --             packager next to it);
    --   types   - recipe types (as in JEI / Recipe Atlas) the machine runs;
    --   seconds - how long to wait for the result (default 600).
    -- Order matters: the first machine that can make an item makes it (put
    -- smoking before smelting, so food is smoked, not burnt).
    -- Stations with their own computer (mechanical crafter, saws, slicers,
    -- basins, compacting chest) are not listed here: they find the controller.
    -- An empty list means no such machines.
    machines = {
        -- {address = "Fan: Smoking", types = {"minecraft:smoking"}},
        -- {address = "Fan: Smelting", types = {"minecraft:smelting"}},
        -- {address = "Fan: Blasting", types = {"minecraft:blasting"}},
        -- {address = "Fan: Haunting", types = {"create:haunting"}},
        -- {address = "Fan: Washing", types = {"create:splashing"}},
        -- {address = "Crushing", types = {"create:crushing"}},
        -- {address = "Milling", types = {"create:milling"}},
        -- {address = "Pressing", types = {"create:pressing"}, seconds = 300},
    },

    -- Dyeing fans (Create: Dragons Plus bulk coloring), one fan per colour.
    -- A format string for the fan's address, the colour's name in place of
    -- %s ("Dye %s" -> "Dye Light Gray"); false: no dyeing fans. Dyeing fans
    -- take precedence over turtles for coloured items, so keep this false
    -- until every colour you craft has its fan.
    dyeFans = false,
    -- dyeFans = "Dye %s",
}
