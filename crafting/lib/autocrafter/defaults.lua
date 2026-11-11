return {
    -- The input barrel and packager are found at boot (autocrafter.peripherals);
    -- every craft result goes back into the barrel, and the packager ships it
    -- to `shipAddress` when the turtle cleans up.
    shipAddress = "Storage",
    peripheralStateFile = "data/peripherals.lua",
    stateFile = "data/state.lua",
    controllerHostname = "autocrafter-controller",
    controllerDiscoverySeconds = 5,
    controllerMissLimit = 3,
    pollTimeout = 5,
    pollSeconds = 1,
    maxDepth = 16,
    maxNodes = 256,
    -- Seconds without a new item arriving before an order counts as lost,
    -- and the longest wait for one delivery.
    stockTickerDeliveryTimeout = 300,
    deliveryMaxTimeout = 300,
    deliveryPollSeconds = 2,
    -- Ask the controller for a fleet-wide ordering permit (false: order freely).
    orderGate = true,
    -- Reorder ingredients that never started arriving after this many seconds.
    deliveryStallSeconds = 30,
    deliveryMaxReorders = 2,
    idleCleanupSeconds = 10,
    -- Station-made ingredients (mechanical crafter, saw, slicer) are ordered
    -- from PC48: the longest wait for that job, then how often and how long to
    -- wait for its packages before planning again.
    mechanicalWaitSeconds = 1800,
    mechanicalSettleTries = 4,
    mechanicalSettleSeconds = 15,
    -- At boot, how long to wait for the server's recipe snapshot.
    recipesReadySeconds = 60,
    completedLimit = 64,
    logging = true,
    logName = "autocrafter",
    logFile = "data/autocrafter.log",
    logLevel = "info",
    logConsole = false,
    logMaxBytes = 32768,
    logMaxFiles = 4,
    tagCandidates = {},
    -- Crafting tools the recipe returns instead of consuming (getCraftingRemainingItem
    -- is the item itself): planned once per step. The Structurize build wand is
    -- used by MineColonies huts and racks.
    reusableIngredients = {"structurize:sceptergold"},
    -- Recipe rules (avoidCandidates, blockedRecipes) come from PC48's
    -- /recipe_policy.lua with each job; these are only the fallbacks.
    avoidCandidates = {},
    blockedRecipes = {},
    -- After each plan, ask Recipe Atlas's recipes.resolve for the same job and log
    -- the comparison (worker.resolve_shadow). Read-only; it decides nothing.
    resolveShadow = true,
}
