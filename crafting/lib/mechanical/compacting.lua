-- What a Sophisticated chest with the compacting upgrade on "Compact
-- Anything" makes (station PC191, owner 2026-11-07). The upgrade crafts an
-- item X put into the chest when the game has a crafting recipe for X alone
-- in a 2x2 square, a full 3x3 or a hollow 3x3 ring (the server's
-- additionalCompactingShapes). It takes whatever recipe the game finds for
-- that grid, so a target counts only when:
-- - one of its crafting recipes is X alone in such a shape;
-- - no other crafting recipe takes X alone in such a shape (4 planks make a
--   crafting table, 8 a chest: which one the chest makes is not ours to say);
-- - the target itself does not compact on (nuggets -> ingot -> block).
-- Recipe Atlas's compactions() lists exactly these crafting recipes (2x2,
-- 3x3 or ring, one ingredient in every cell, one result), per item both
-- ways: `from` makes the item, `into` consumes it.
local Call = require("autocrafter.recipe_call")
local Util = require("fleet_util")

local amount = Util.amount

local Compacting = {}

local function compactions(api, item)
    local ok, reply = Call.pcall(api.compactions, item)
    if not ok or type(reply) ~= "table" then return nil, "recipe lookup failed: " .. tostring(reply) end
    return reply
end

-- The ways the chest makes `target`: {{item, cells, perCraft, recipeId}},
-- or nil and why not.
function Compacting.sources(api, target)
    if type(api) ~= "table" or type(api.compactions) ~= "function" then return nil, "RECIPES_UNAVAILABLE" end
    local own, why = compactions(api, target)
    if not own then return nil, why end
    local candidates = {}
    for _, row in ipairs(own.from or {}) do
        local input = type(row.input) == "table" and row.input or {}
        for _, item in ipairs(input.items or {}) do
            if item ~= target then
                candidates[#candidates + 1] = {item = item, cells = amount(row.cells),
                    perCraft = math.max(1, amount(row.count)), recipeId = row.recipeId}
            end
        end
    end
    if #candidates == 0 then return nil, "no compacting recipe" end
    if #(own.into or {}) > 0 then return nil, target .. " compacts on" end
    local sources = {}
    for _, candidate in ipairs(candidates) do
        local of, err = compactions(api, candidate.item)
        if not of then return nil, err end
        local into = of.into or {}
        if #into == 1 and into[1].recipeId == candidate.recipeId then sources[#sources + 1] = candidate end
    end
    if #sources == 0 then return nil, "its inputs compact into other things too" end
    table.sort(sources, function(a, b) return a.item < b.item end)
    return sources
end

return Compacting
