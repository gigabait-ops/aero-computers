-- Colony Supply: settings. Defaults for every key, the user's /config.lua on
-- top, and older config files (flat keys before 2026-10-21) moved into the
-- new groups, so an update never breaks a working computer.
--
-- Groups: create (Create storage), colony (the colony side), send (colony ->
-- Create storage), keep / builder / dishes (what the program brings), craft
-- (optional module), orders (fine tuning), screen.
local W = require("app.words")

local Settings = {}

Settings.DEFAULTS = {
    create = {
        ticker = "auto",              -- stock ticker on the Create storage network
    },
    colony = {
        address = "Colony",           -- address of the colony's frogport / postbox
        integrator = "auto",          -- Advanced Peripherals colony integrator
        warehouse = "auto",           -- colony warehouse hut on a cable; false = none
        ticker = false,               -- optional second ticker on the colony's own network
        delivery = "chest",           -- "chest": inbox chest, the computer moves; "direct": into the warehouse
        inbox = false,                -- inbox chest name ("chest" only)
    },
    send = {
        enabled = true,
        by = "auto",                  -- "ticker", "chest" or "auto" (ticker when there is one)
        to = "Storage",               -- Create storage address the colony ticker sends to
        outbox = false,               -- outbox chest name ("chest")
        every = 30,                   -- seconds between checks
        min = 64,                     -- send only once this much is extra
        max = 576,                    -- at most this much at once (one package)
        wait = 60,                    -- seconds before the same item is sent again
        per_check = 2,                -- items sent in one check
        hold = 3600,                  -- seconds what was just ordered for the colony stays
        hold_builder = 21600,         -- the same for builders' deliveries (6 h)
    },
    -- rules/keep.lua: `min` = bring up to (keep), `max` = send the rest (send)
    keep = {enabled = true, rules = "/rules/keep.lua", reload_every = 10, reorder_after = 600},
    addresses = "/rules/addresses.lua",   -- the colony's, storage's and buildings' addresses
    builder = {enabled = true, max_items = 64, reorder_after = 10800, refresh_every = 60},
    dishes = {enabled = true, rules = "/rules/dishes.lua", reload_every = 10, reorder_after = 21600},
    craft = {enabled = true},         -- only used when app/craft.lua exists
    orders = {
        interval = 15,                -- seconds between colony scans
        gap = 2,                      -- seconds between two orders in one scan
        per_scan = 4,                 -- Create drops a whole order at >= 10 queued packages
        reorder_after = 600,          -- seconds before the same request is ordered again
        missing_retry = 900,          -- seconds between "no stock" log lines for one item
        recheck_after = 60,
        min = 1, max = 256,
        skip_huts = {},               -- e.g. {"Tavern"}: never served
        skip_items = {},              -- e.g. {"minecraft:diamond"}: never ordered
    },
    screen = {monitor = "auto", scale = 0.5, palette = true},
    -- OPTIONAL: chat messages through a Chat Box on the computer (none = off)
    chat = {enabled = true, locale = "uk", range = 128, prefix = "Колонія",
        summary_every = 600, rules = "/rules/chat.lua",
        relay = false},               -- true: no own Chat Box, lines go over rednet to a chat relay
    log = {level = "info", dir = "/app/logs", file = "/app/logs/colony.log", console = false, max_files = 2},
    snapshot_every = 0,
}

-- Rule files before 2026-10-21, used while the new file does not exist.
Settings.OLD_RULES = {keep = "/requests/stock.lua", dishes = "/requests/ingredients.lua"}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- flat key before 2026-10-21 -> {group, key}
local MOVED = {
    integrator = {"colony", "integrator"}, ticker = {"create", "ticker"}, address = {"colony", "address"},
    warehouse = {"colony", "warehouse"}, delivery = {"colony", "delivery"}, inbox = {"colony", "inbox"},
    monitor = {"screen", "monitor"}, monitor_scale = {"screen", "scale"}, palette = {"screen", "palette"},
    interval = {"orders", "interval"}, order_gap = {"orders", "gap"}, max_orders_per_cycle = {"orders", "per_scan"},
    reorder_after = {"orders", "reorder_after"}, missing_retry = {"orders", "missing_retry"},
    recheck_after = {"orders", "recheck_after"}, min_order = {"orders", "min"}, max_order = {"orders", "max"},
    skip_targets = {"orders", "skip_huts"}, skip_items = {"orders", "skip_items"},
}
-- whole groups that were renamed
local RENAMED = {stock = "keep", ingredients = "dishes", autocraft = "craft", crafter = "craft"}

-- `x = false` / `x = true` shorthands for the parts that can be switched off
local SWITCHES = {send = true, keep = true, builder = true, dishes = true, craft = true, chat = true}

-- The user's table in the new shape (old flat keys moved into their groups).
function Settings.migrate(user)
    local out = {}
    for key, value in pairs(user or {}) do
        if not MOVED[key] and not RENAMED[key] then out[key] = copy(value) end
    end
    for old, value in pairs(user or {}) do
        local new = RENAMED[old]
        if new and out[new] == nil then out[new] = copy(value) end
    end
    for old, place in pairs(MOVED) do
        local value = user and user[old]
        if value ~= nil then
            local group = out[place[1]]
            if type(group) ~= "table" then group = {} out[place[1]] = group end
            if group[place[2]] == nil then group[place[2]] = copy(value) end
        end
    end
    return out
end

-- Defaults overlaid with the user's (migrated) settings.
function Settings.merge(user)
    local cfg = copy(Settings.DEFAULTS)
    for key, value in pairs(Settings.migrate(user)) do
        local default = cfg[key]
        if SWITCHES[key] and type(value) == "boolean" then
            cfg[key].enabled = value
        elseif key == "screen" and value == false then
            cfg.screen.monitor = false
        elseif type(default) == "table" and type(value) ~= "table" then
            -- `chat = 5` and the like: keep the defaults rather than break
        elseif type(default) == "table" and type(value) == "table" and next(default) ~= nil and #default == 0 then
            for k, v in pairs(value) do default[k] = copy(v) end
        else
            cfg[key] = copy(value)
        end
    end
    return cfg
end

-- Rules path for a part: the new file, else the old one when only that exists.
function Settings.rulesPath(cfg, part, exists)
    local path = cfg[part] and cfg[part].rules or Settings.DEFAULTS[part].rules
    local old = Settings.OLD_RULES[part]
    if old and path == Settings.DEFAULTS[part].rules and not exists(path) and exists(old) then return old end
    return path
end

-- The flat table the ordering engine (app/supply.lua) reads.
function Settings.supplyConfig(cfg)
    local o = cfg.orders
    return {
        address = cfg.colony.address, interval = o.interval, order_gap = o.gap,
        max_orders_per_cycle = o.per_scan, reorder_after = o.reorder_after, missing_retry = o.missing_retry,
        recheck_after = o.recheck_after, min_order = o.min, max_order = o.max,
        skip_targets = o.skip_huts, skip_items = o.skip_items,
    }
end

-- Load /config.lua: cfg, or cfg with defaults plus the error text when the
-- file is broken (a missing file is fine).
function Settings.load(loadTable, path)
    local user, err = loadTable(path or "/config.lua")
    if user then return Settings.merge(W.config(user)) end
    if err and not tostring(err):find("^missing") then return Settings.merge({}), err end
    return Settings.merge({})
end

return Settings
