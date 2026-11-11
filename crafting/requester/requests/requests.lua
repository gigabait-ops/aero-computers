-- Station requests: keep `target` stocked at `limit` by ordering `items`
-- from the warehouse to a machine's `address`; the machine makes the target
-- and its output comes back to the warehouse.
-- Fields:
--   enabled        - false turns the rule off (shown as OFF)
--   address        - Create package address of the machine
--   target         - item ID kept in stock
--   limit          - how many of the target to keep
--   items          - one cycle's ingredients: an item ID, a list of IDs
--                    (one item each) or {name = ID, count = n} entries
--   outputPerCycle - how many targets one full cycle of `items` yields
--                    (for the whole list, not per entry; for a chance
--                    output use count * chance)
--   orderLimit     - optional: at most this many items in one order, so one
--                    order is one package a small inventory (a depot) takes whole
--   cooldown       - optional: seconds between orders (default: config.lua)
-- The order counts follow from limit, outputPerCycle and items.
return {
    example_pressing = {
        enabled = false,
        address = "Pressing",
        target = "create:iron_sheet",
        limit = 256,
        outputPerCycle = 1,
        items = "minecraft:iron_ingot",
    },
}
