-- Station defaults (PC134, PC136, PC137); each /settings.lua names its kind,
-- address and chest, and anything else it changes. The machines, the Stock
-- Ticker and the packager are found on the network (mechanical.devices);
-- name `ticker`/`packager` only when the network has several.
return {
    -- kind = "mechanical" | "saw" | "slicer"           (required)
    -- address = "<frogport address>"                    (required)
    -- chest = "<inventory the machines work from>"      (required)
    -- grid = {{ids...}, ...}, trigger = {side = "right"} (mechanical only)
    -- tools = {axe = "...", knife = "...", ...}          (slicer only)
    shipAddress = "Storage",
    shipGapSeconds = 1.5,
    shipRetries = 4,
    pulseSeconds = 0.3,
    -- Most items per machine per feed (saws, slicer depots): a full stack;
    -- a batch is shared evenly over every machine, and a machine takes what
    -- fits its slot.
    chunk = 64,
    -- A machine whose input does not go down this long sits out the batch.
    stallSeconds = 15,
    dropSettleSeconds = 30, -- bulkCutting saws (owner 2026-11-07) drop whole stacks at once: the magnet takes a while
    craftTimeout = 60,
    craftPollSeconds = 0.5,
    deliveryTimeout = 300,
    deliveryPollSeconds = 2,
    -- Stacks one batch of ingredients may take (order and chest room).
    batchStacks = 45,
    idleShipSeconds = 30,
    pollSeconds = 1,
    pollTimeout = 5,
    beatSeconds = 10,
    delegateWaitSeconds = 1800,
    controllerHostname = "autocrafter-controller",
    requestHostname = "craft-controller",
    stateFile = "data/state.lua",
    logging = true,
    logFile = "data/station.log",
    logLevel = "info",
    logConsole = false,
    logMaxBytes = 32768,
    logMaxFiles = 4,
}
