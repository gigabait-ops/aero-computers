-- Exports: send every item of `items` the warehouse holds to `address`
-- (ores to a crusher, crushed ores to a washing fan...).
-- Fields:
--   enabled    - false turns the rule off (shown as OFF)
--   address    - Create package address to send to
--   items      - an item ID, a list of IDs, or {name = ID, count = n}
--                entries (count = at most this many; default all)
--   multipleOf - optional: send only whole multiples of this (1-256),
--                e.g. 9 for a block press
--   cooldown   - optional: seconds between orders (default: config.lua)
return {
    example_crushing = {
        enabled = false,
        address = "Crushing",
        items = {
            "minecraft:iron_ore",
            "minecraft:deepslate_iron_ore",
        },
    },
}
