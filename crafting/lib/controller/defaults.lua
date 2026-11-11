return {
    queueFile = "data/queue.lua",
    -- Recipe rules for the workers (blockedRecipes, avoidCandidates); edit it
    -- on PC48, no /reload needed.
    recipePolicyFile = "recipe_policy.lua",
    -- Who makes what first, and recipes no one uses (controller.recipe_policy).
    makersFile = "makers.lua",
    requestHostname = "craft-controller",
    workerHostname = "autocrafter-controller",
    tickSeconds = 1,
    workerTimeoutSeconds = 20,
    workerBusyTimeoutSeconds = 180,
    stalledAfterSeconds = 120,
    historyLimit = 64,
    maxStationOutput = 64 * 16, -- a station job in one go: the station orders and shares it out itself
    -- Per station kind, at most this much per assignment; the rest of the
    -- job then waits behind the others of that kind (the compacting chest:
    -- 60 000 nether bricks held up 128 coal blocks for diamonds, owner
    -- 2026-11-07). One part is one batch of the chest (72 stacks of nether
    -- bricks make 1152 blocks): a new job waits ~20 s at most. The saws
    -- (twelve, a stack each) take a full chest, 45 stacks (owner 2026-11-08).
    stationOutput = {compact = 1152, saw = 64 * 45},
    maxAssignmentOutput = 64, -- Bounds one worker delivery to at most nine ingredient stacks for a direct 3x3 recipe.
    maxParallelAssignments = 9,
    render = true,
    logging = true,
    logName = "autocrafter-controller",
    logFile = "data/controller.log",
    logLevel = "info",
    logConsole = false,
    logMaxBytes = 32768,
    logMaxFiles = 4,
    -- One worker orders from the warehouse at a time. The estimated packager
    -- backlog stays under Create's silent drop limit (10 packages for Stock
    -- Ticker orders); packagers drain about one package per second.
    orderLeaseSeconds = 10,
    orderWaiterTimeout = 10,
    orderBacklogBudget = 8,
    orderDrainPerSecond = 1,
    -- The Stock Ticker PC48 orders through (controller.supplier); nil finds
    -- the only one on the network.
    ticker = nil,
    -- Create machines without a computer, {address, types}: nil takes the
    -- list in controller/job_kind.lua (JobKind.MACHINES); PC48's settings.lua
    -- holds the live one.
    machines = nil,
    -- Dyeing fans (controller.dye_fan), one per colour: the address with the
    -- colour's name ("Dye %s" -> "Dye Light Gray"); false: none.
    dyeFans = "Dye %s",
}
