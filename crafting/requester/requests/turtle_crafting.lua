-- Turtle crafts: keep `target` stocked at `limit` by asking the craft
-- controller to craft the shortage. The controller plans the ingredients
-- and picks who makes it (crafting turtles, or a station / machine when only
-- that makes it); the output lands in the warehouse.
-- Fields:
--   enabled    - false turns the rule off (shown as OFF)
--   target     - item ID kept in stock
--   limit      - how many to keep (with always = true: at most this many
--                per request)
--   always     - optional: true = craft whenever there is something to make
--                it from, regardless of stock
--   from       - optional (with always): only from these item IDs
--   keep       - optional (with always and from): leave this many of each
--                `from` item in stock
--   orderLimit - optional: at most this many made per request
--   cooldown   - optional: seconds between requests (default: config.lua
--                turtle.cooldown)
-- Craft rules must not have items/address/outputPerCycle: the controller
-- plans those itself.
return {
    example_turtle = {
        enabled = false,
        target = "minecraft:stone_bricks",
        limit = 64 * 4,
    },
    -- An "always" rule: turn every nugget beyond 64 into blocks.
    -- example_always = {
    --     enabled = false,
    --     target = "create:experience_block",
    --     limit = 64,
    --     always = true,
    --     from = {"create:experience_nugget"},
    --     keep = 64,
    -- },
}
