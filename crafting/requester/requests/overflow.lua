-- Overflow: keep `limit` of each listed item and send the surplus to
-- `address` (a composter, a smoker fan, a trash can...). Each item is its
-- own rule (key <rule>.<item>).
-- Fields:
--   enabled    - false turns the rule off (shown as OFF)
--   address    - Create package address to send the surplus to
--   limit      - how many of each item stay in the warehouse
--   items      - an item ID, a list of IDs, or a map of
--                key = {name = ID, limit = n, ...} to override fields per item
--   multipleOf - optional: send only whole multiples of this (1-256),
--                e.g. 64 for whole stacks
--   orderLimit - optional: at most this many items in one order
--   cooldown   - optional: seconds between orders (default: config.lua)
return {
    example_composter = {
        enabled = false,
        address = "Composter",
        limit = 64 * 4,
        multipleOf = 64,
        items = {
            "minecraft:wheat_seeds",
            "minecraft:oak_sapling",
        },
    },
}
