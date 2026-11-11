return {
    -- Global settings for all rules. The rules themselves live in requests/:
    --   requests.lua            keep an item stocked by ordering ingredients
    --                           to a machine's address (Station requests tab)
    --   exports.lua             send every item of a list to an address
    --   overflow.lua            send the surplus over a limit to an address
    --   turtle_crafting.lua     keep an item stocked by asking the craft
    --                           controller to craft it
    --   mechanical_crafting.lua, saw_crafting.lua, slicer_crafting.lua,
    --   basin_crafting.lua      the same, for items only that station makes
    --                           (optional files: absent = no such rules)
    -- A rule's key must be unique across all files. At least one rule (it
    -- may be disabled) must exist in some file, or the app reports "jobs empty".
    -- All orders go through the Stock Ticker (shared with the craft
    -- controller), one at a time through the controller's order gate.

    -- Seconds between two orders of the same rule (a rule may set its own).
    cooldown = 60,
    -- Most rules that may order in one tick.
    maxOrdersPerTick = 8,

    logging = {
        -- One compact line per plan and per order.
        -- To turn it off quickly set enabled = false or level = "off".
        enabled = true,
        name = "requester",
        level = "info",
        console = false,
        maxBytes = 32768,
        maxFiles = 4
    },

    sorting = {
        -- auto = material type from tags/name, then itemGroups/tags, then OTHER.
        -- Other modes: type, tags, itemGroups, name, count.
        stockMode = "auto",

        -- true = active/problem rows (NO_STOCK, LOW, QUEUE, REQUESTED, WAIT)
        -- are listed above the OK ones.
        activeFirst = true
    },

    queue = {
        -- How often to check the planned queue between full warehouse scans.
        pollSeconds = 0.25,

        -- How many batches to send per background poll.
        -- 1 keeps the screen responsive when many OVER/EXPORT orders wait.
        maxBatchesPerPoll = 1,

        -- Least pause between two batches of the same rule; other rules
        -- may send theirs meanwhile.
        perJobDelaySeconds = 0.75
    },

    devices = {
        -- "auto" = the first Stock Ticker on the network, or its peripheral name.
        -- The warehouse is read only through the Stock Ticker.
        stockTicker = "auto"
    },

    timing = {
        tickSeconds = 2,

        -- How often the screens (terminal and monitor) refresh without a
        -- warehouse scan: the queue, the last action.
        uiRefreshSeconds = 1
    },

    -- NEEDS hints: which station makes a material no turtle can craft.
    -- First the address of a requests/ rule whose target is that material;
    -- otherwise the Recipe Atlas route the controller attaches to MISSING_RAW,
    -- by key = the recipe id up to "/" (create:cutting) or the workbench /
    -- first machine of the route (minecraft:furnace) -> station address.
    -- "<Colour>" = the item's colour in English ("Dye <Colour>" -> "Dye Red").
    -- Empty: hints show the route's machine instead.
    routeStations = {
        -- ["create:cutting"] = "Saw Station",
        -- ["minecraft:furnace"] = "Fan: Smelting",
        -- ["minecraft:smoker"] = "Fan: Smoking",
        -- ["create:splashing"] = "Fan: Washing",
        -- ["create:crushing"] = "Crushing",
        -- ["create:pressing"] = "Pressing",
        -- ["create_dragons_plus:coloring"] = "Dye <Colour>",
    },

    -- Cleaning tab, Filters view: where configured filters go to be reset
    -- (the values shown are the defaults).
    -- filterCleaningAddress = "Filters Cleaner",
    -- Cleaning tab, Backpacks view: where used backpacks go to be unloaded.
    -- backpackUnloadAddress = "Backpack Unloader",

    turtle = {
        -- Craft rules go to the craft controller, found by this rednet
        -- hostname (its computer id is looked up at runtime, never stored).
        controllerHostname = "craft-controller",
        -- Must match the controller's request protocol.
        protocol = "gigabait.craft.request.v1",
        -- Seconds between two craft requests of the same rule.
        cooldown = 300,
        -- Pause of a rule after a raw-material shortage (seconds): 10 min
        -- after the first, doubled for each shortage in a row, at most 2 h.
        -- A craft that made something starts again from 10 min. The pause
        -- also ends as soon as the material appears in the warehouse.
        rawShortageSeconds = 600,
        rawShortageMaxSeconds = 7200,
        controllerRetrySeconds = 2,
        controllerRetryMaxSeconds = 30
    }
}
