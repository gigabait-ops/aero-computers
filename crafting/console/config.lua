-- Only what differs from DEFAULTS in app/app.lua (timing, controller
-- hostname/protocol and retries, state file, checklist, logging): those
-- apply as they are unless set here.
return {
    -- Checklist tab: a Create Clipboard and a Stock Ticker on this computer's
    -- wired network. What is in stock the ticker sends to `address`; what is
    -- missing the craft controller crafts. Without a ticker the tab only
    -- shows the list.
    checklist = {
        enabled = true,

        -- The Create package address the clipboard's materials are delivered
        -- to (e.g. your build site's frogport). While it is empty the tab is
        -- view only.
        address = "",

        -- Clipboard methods run on the main thread, so only the compact
        -- getMissingItems() is read, at most once every 2 seconds.
        readSeconds = 2,

        -- How often to read the warehouse through the Stock Ticker while the
        -- clipboard is in place.
        stockSeconds = 2,

        -- How many items to check per warehouse read (one Recipe Atlas
        -- request, at most 16).
        recipeChecksPerScan = 16,

        -- Seconds a bulk CRAFT skips an item that lacks raw materials (less
        -- if the material shows up in the warehouse sooner); a row's own
        -- CRAFT tries at once.
        rawPauseSeconds = 600,
    },

    -- NEEDS in History names the station that makes a missing raw material,
    -- by the same rule as the requester (requester app/route_hints.lua). This
    -- computer cannot read the requester's files, so these are copies:
    --   rules         = station address -> the items its requester rules
    --                   keep in stock (requests/*.lua);
    --   routeStations = the requester config.lua's map for the Recipe Atlas
    --                   routes the controller sends with MISSING_RAW (recipe
    --                   id prefix or workbench/executor id; "<Colour>" = the
    --                   item's colour).
    -- Empty: hints show the route's machine instead.
    routeHints = {
        rules = {
            -- ["Pressing"] = {"create:iron_sheet", "create:brass_sheet"},
            -- ["Crushing"] = {"minecraft:gravel", "minecraft:sand"},
        },
        routeStations = {
            -- ["create:cutting"] = "Saw Station",
            -- ["create:crushing"] = "Crushing",
            -- ["create:pressing"] = "Pressing",
            -- ["create_dragons_plus:coloring"] = "Dye <Colour>",
        },
    },
}
