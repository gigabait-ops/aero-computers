-- What makes an item, from Recipe Atlas: producers() lists every declared
-- output row that names it (crafting results, machine outputs, chance rows
-- too) in one paged call, and getMany() reads the machine data of several
-- recipes at once. Replaces one ids() query per recipe type and one
-- getDetails() per recipe.
local Call = require("autocrafter.recipe_call")

local Producers = {}

Producers.PAGE = 100   -- rows per producers() page (server maximum 500)
Producers.BATCH = 50   -- ids per getMany() call (server maximum 500)

-- Every producer row of `item`: {recipeId, type, executor, kind, quantity,
-- mode, probability, role}; nil and the error when the module does not
-- answer. Colony definition rows (no recipeId) are left out.
function Producers.rows(api, item)
    if type(api) ~= "table" or type(api.producers) ~= "function" then return nil, "RECIPES_UNAVAILABLE" end
    local rows, cursor, generation = {}, nil, nil
    for _ = 1, 50 do
        local ok, page = Call.pcall(api.producers, item,
            {limit = Producers.PAGE, cursor = cursor, expectedGeneration = generation})
        if not ok or type(page) ~= "table" then return nil, page end
        generation = generation or page.generation
        for _, row in ipairs(page.items or {}) do
            if type(row) == "table" and type(row.recipeId) == "string" then rows[#rows + 1] = row end
        end
        cursor = page.next_cursor
        if not cursor then return rows end
    end
    return rows
end

local function set(list)
    local out = {}
    for _, value in ipairs(list or {}) do out[value] = true end
    return out
end

-- Does a row count? `byOutput`: also a later guaranteed output (tree bark
-- from stripping a log); `anyOutput`: any item output, chance ones too
-- (netherite scrap from crushing nether bricks). Otherwise only the first
-- declared output, as Recipe Atlas's `result` filter.
function Producers.matches(row, options)
    options = options or {}
    if row.kind ~= nil and row.kind ~= "item" then return false end
    if options.anyOutput then return true end
    if row.role == "primary" or row.role == nil then return true end
    return options.byOutput == true and row.mode == "guaranteed"
end

-- The recipe ids among `rows` of the given types, in row order, once each.
function Producers.ids(rows, types, options)
    local wanted, ids, seen = set(types), {}, {}
    for _, row in ipairs(rows or {}) do
        if wanted[row.type] and not seen[row.recipeId] and Producers.matches(row, options) then
            seen[row.recipeId] = true
            ids[#ids + 1] = row.recipeId
        end
    end
    return ids
end

-- A crafting-table recipe (the turtles') among the rows.
function Producers.crafting(rows)
    for _, row in ipairs(rows or {}) do
        if row.executor == "crafting_table" and Producers.matches(row) then return true end
    end
    return false
end

-- Records by id for `ids` (getMany with `fields`); missing ones are left
-- out. nil and the error when the module does not answer.
function Producers.details(api, ids, fields)
    local out = {}
    if #ids == 0 then return out end
    if type(api.getMany) ~= "function" then return nil, "RECIPES_UNAVAILABLE" end
    for first = 1, #ids, Producers.BATCH do
        local chunk = {}
        for i = first, math.min(#ids, first + Producers.BATCH - 1) do chunk[#chunk + 1] = ids[i] end
        local ok, page = Call.pcall(api.getMany, chunk, {fields = fields or {"machine"}})
        if not ok or type(page) ~= "table" then return nil, page end
        for _, record in ipairs(page.items or {}) do
            if type(record) == "table" and record.id then out[record.id] = record end
        end
    end
    return out
end

return Producers
