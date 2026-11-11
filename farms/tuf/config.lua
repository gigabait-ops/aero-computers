-- TUF farm: tuff is made and crushed into nuggets; factories turn the
-- nuggets into ingots, plates and blocks. The farm computer counts the
-- item vaults wired to it (and the reports of agent computers that watch
-- another store), decides which line of each factory runs, drives one
-- Redstone Link bridge (mod cc-redstone-link-bridge) and shows it all on
-- its monitor. Signal 0 = run, 15 = stop on every channel.
--
-- This file describes YOUR build: every factory line is a Redstone Link
-- receiver in the world, so nothing here can be guessed. As shipped the farm
-- starts with no factories and no power channel: it shows the storage and
-- tells you "channels not set" until you fill `power` and `factories` below
-- (see the commented example at the end).
--
-- Stage and factory names are the keys of the saved settings
-- (/tuf/state.txt on the farm computer): keep them when relabelling.

-- A line of a factory: `item` is what it makes and is counted in storage,
-- `limit` the count it stops at (items, rounded up to whole stacks; 0 = no
-- limit), freq1/freq2 the two items in the frequency slots of the line's
-- Redstone Link receiver (freq2 defaults to `item`).
local function stage(name, item, limit, freq1, freq2)
    return {name = name, item = item, limit = limit, freq1 = freq1, freq2 = freq2 or item}
end

return {
    title = "TUF FARM",
    stack = 64,

    network = {
        -- rednet protocol of the agents' storage reports; the same on the
        -- farm and every agent
        storageProtocol = "tuf.farm.storage",
        -- id of the farm computer; only shown on the agents' screens
        server = nil,           -- e.g. 5
        -- ids of the agent computers (startup: require("tuf.agent").run())
        -- whose reports the farm takes; {} = no agents
        agents = {},            -- e.g. {7}
        -- an agent sends at least this often (seconds)
        beat = 5,
        -- an agent report older than this marks the agent as not answering
        storageStale = 15,
    },

    -- One redstone_link_bridge carries every channel (the mod keeps one
    -- channel per frequency pair); other bridges get these channels set to 0.
    bridge = {type = "redstone_link_bridge", recheck = 5},

    -- Inventories counted as the farm's storage.
    storageTypes = {"create:item_vault"},
    -- Names on the Storage page. Keys: "local:<peripheral name>" for a
    -- vault on the farm computer, "remote:<agent id>:<peripheral name>" for
    -- an agent's inventory. Unnamed ones show as "Vault" / "PC<id> vault".
    storageLabels = {
        -- ["local:create:item_vault_0"] = "Factory vault",
        -- ["remote:7:back"] = "Ingot store",
    },

    -- The whole farm (tuff generator and crushers) runs on this channel.
    -- Another transmitter on the same frequency (a lever) may hold it at 15:
    -- the farm reports that and does not fight it.
    -- Set freq1/freq2 to the frequency items of your power receiver.
    power = {name = "FACTORY_POWER", label = "Power",
        freq1 = nil,            -- e.g. "minecraft:redstone"
        freq2 = nil},           -- e.g. "minecraft:lever"
    -- default rule for all storage: stop the power when it is this full (%)
    storageStop = {enabled = true, percent = 98},

    -- Items over their limit are sent to `address` by a Create Redstone
    -- Requester on the farm computer's network (found by itself; without one
    -- nothing is sent). Nuggets, the factories' input, are never sent. One
    -- order every `every` seconds, only items at least `min` over; an item
    -- just ordered counts as gone for `settle` seconds while it leaves.
    surplus = {enabled = false,
        address = nil,          -- e.g. "Main Storage" (your warehouse's address)
        every = 15, settle = 30, min = 64},

    -- All item limits together may not pass one largest Create item vault:
    -- 3x3x9 blocks x 20 stacks = 1620 stacks. A raised limit is cut to what
    -- still fits.
    limitBudget = 3 * 3 * 9 * 20 * 64,

    -- Your factories, in screen order. Empty: the farm only shows storage.
    factories = {},
}

--[[ Example `factories` (replace the empty list above). Item ids, limits
     and frequency items are placeholders: use your own receivers' items.

    factories = {
        -- A plain factory: its lines run one at a time by priority (the
        -- first line under its limit runs, the others wait); every line
        -- stops while the base item (the nuggets) is under base.limit.
        {name = "IRON_FACTORY", label = "Iron",
            base = {item = "minecraft:iron_nugget", limit = 64 * 64},
            stages = {
                stage("IRON_INGOT_LIMIT", "minecraft:iron_ingot", 64 * 64,
                    "minecraft:white_wool", "minecraft:iron_ingot"),
                stage("IRON_BLOCK_LIMIT", "minecraft:iron_block", 64 * 16,
                    "minecraft:white_wool", "minecraft:iron_block"),
            }},
        {name = "ZINC_FACTORY", label = "Zinc",
            base = {item = "create:zinc_nugget", limit = 64 * 64},
            stages = {
                stage("ZINC_INGOT_LIMIT", "create:zinc_ingot", 64 * 64,
                    "minecraft:gray_wool", "create:zinc_ingot"),
            }},
        -- A parallel factory: all its lines run side by side. A line with
        -- `needs` runs only while the provider factory is full (every line
        -- at its limit), and then keeps the provider's named line running
        -- to feed it. limitFrom shares one editable resource limit.
        {name = "BRASS_FACTORY", label = "Brass", parallel = true,
            resources = {
                {key = "BRASS_INGOTS", item = "create:brass_ingot", limit = 64 * 64, editable = true},
                {key = "ZINC_NUGGETS", item = "create:zinc_nugget", from = "ZINC_FACTORY"},
            },
            stages = {
                {name = "BRASS_ZINC_INPUT", label = "Zinc input", item = "create:brass_ingot",
                    limitFrom = "BRASS_INGOTS",
                    needs = {factory = "ZINC_FACTORY", stage = "ZINC_INGOT_LIMIT"},
                    freq1 = "minecraft:yellow_wool", freq2 = "create:brass_ingot"},
            }},
    },
]]
