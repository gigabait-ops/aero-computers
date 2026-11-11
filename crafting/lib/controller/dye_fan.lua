-- Dyeing fans (owner 2026-11-08): a fan blowing through a block of dye
-- fluid (Create: Dragons Plus "bulk coloring") colours what passes it, one
-- item into one, the dye already in the fan. The fan takes the game's own
-- crafting recipe for the item next to one dye, or eight round one dye, so
-- a target counts when one of its crafting recipes is one vanilla dye with
-- one or eight of the same item. Each colour has its own fan, addressed
-- "Dye Light Gray" and so on (PC48's settings `dyeFans`).
local Util = require("fleet_util")

local amount = Util.amount

local DyeFan = {}

DyeFan.COLOURS = {"white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
    "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"}
local DYES = {}
for _, colour in ipairs(DyeFan.COLOURS) do DYES["minecraft:" .. colour .. "_dye"] = colour end

local CRAFTING = {["minecraft:crafting_shaped"] = true, ["minecraft:crafting_shapeless"] = true}

-- "light_gray" -> "Light Gray"
local function title(colour)
    return (colour:gsub("_", " "):gsub("(%a)(%a*)", function(a, b) return a:upper() .. b end))
end

-- Does the item id name a colour ("red_wool", "gray_dark_metal_plating")?
local function coloured(id)
    local path = "_" .. tostring(id):gsub("^[^:]*:", "") .. "_"
    for _, colour in ipairs(DyeFan.COLOURS) do
        if path:find("_" .. colour .. "_", 1, true) then return colour end
    end
    return nil
end

-- The colour and the items a crafting record dyes, when it is one dye with
-- one or eight of the same item; else nil.
function DyeFan.shape(record)
    if type(record) ~= "table" or not CRAFTING[record.type] or type(record.ingredients) ~= "table" then return nil end
    local colour, items, same, others = nil, nil, nil, 0
    for _, ingredient in ipairs(record.ingredients) do
        local list = type(ingredient) == "table" and ingredient.items
        if type(list) == "table" and #list > 0 then
            if amount(ingredient.count) > 1 then return nil end
            local dye
            for _, id in ipairs(list) do dye = dye or DYES[id] end
            if dye then
                if colour then return nil end
                colour = dye
            else
                local sorted = {}
                for i, id in ipairs(list) do sorted[i] = id end
                table.sort(sorted)
                local key = table.concat(sorted, " ")
                if same and same ~= key then return nil end
                same, items, others = key, list, others + 1
            end
        end
    end
    if not colour or (others ~= 1 and others ~= 8) then return nil end
    return colour, items
end

-- What the fan is given: the plain item ("dark_metal_plating" for gray
-- plating); without one the white ("white_wool"); only else any colour, so
-- the fan does not repaint stock of another colour.
local function bases(items, target)
    local plain, white, any = {}, {}, {}
    for _, id in ipairs(items) do
        if id ~= target then
            local colour = coloured(id)
            any[#any + 1] = id
            if not colour then plain[#plain + 1] = id elseif colour == "white" then white[#white + 1] = id end
        end
    end
    return #plain > 0 and plain or #white > 0 and white or any
end

-- The fans that make `target`: {{address, colour, from = {ids}, recipeId}},
-- or nil and why. `format` names the fan: "Dye %s" -> "Dye Gray".
function DyeFan.recipes(api, target, format)
    if type(api) ~= "table" or type(api.find) ~= "function" then return nil, "RECIPES_UNAVAILABLE" end
    local ok, page = pcall(api.find, {result = target, workbench = "crafting_table", limit = 50})
    if not ok or type(page) ~= "table" then return nil, "recipe lookup failed: " .. tostring(page) end
    local out = {}
    for _, record in ipairs(page.items or {}) do
        local colour, items = DyeFan.shape(record)
        local from = colour and bases(items, target) or {}
        if #from > 0 then
            out[#out + 1] = {address = string.format(format or "Dye %s", title(colour)), colour = colour,
                from = from, recipeId = record.id}
        end
    end
    return out
end

return DyeFan
