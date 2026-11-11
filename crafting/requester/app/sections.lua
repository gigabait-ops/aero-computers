-- The rule sections of requests/, in the order their rules are read.
--   key       the rows' section (and tab key); a station rule runs as a
--             turtle rule and keeps its own key only for the screens
--   raw       its table in the merged config, also the config loader's
--             paths.<raw> option and App's <raw>Path option
--   file      its file in requests/
--   tab       the screens' tab name, title the tab's list title
--   tabOrder  position among the rule tabs (All comes first)
--   allOrder  position of its group on the All tab (nil: not on All)
--   craft     the rules are crafts PC48 makes (target/limit/always/from)
--   station   the PC48 station those crafts go to
--   optional  a PC46 without the file has no such rules
local Sections = {
    {key = "request", raw = "requests", file = "requests.lua", tab = "Requests",
        title = "Station requests", tabOrder = 6, allOrder = 1},
    {key = "export", raw = "exports", file = "exports.lua", tab = "Exports",
        title = "Exports", tabOrder = 7, allOrder = 7},
    {key = "overflow", raw = "overflow", file = "overflow.lua", tab = "Overflow",
        title = "Overflow", tabOrder = 8},
    {key = "turtle", raw = "turtleCrafting", file = "turtle_crafting.lua", tab = "Turtle",
        title = "Turtle crafts", tabOrder = 1, allOrder = 2, craft = true},
    {key = "mechanical", raw = "mechanicalCrafting", file = "mechanical_crafting.lua", tab = "Mechanical",
        title = "Mechanical crafts", tabOrder = 2, allOrder = 3, craft = true, station = "mechanical", optional = true},
    {key = "saw", raw = "sawCrafting", file = "saw_crafting.lua", tab = "Saw",
        title = "Saw crafts", tabOrder = 3, allOrder = 4, craft = true, station = "saw", optional = true},
    {key = "slicer", raw = "slicerCrafting", file = "slicer_crafting.lua", tab = "Slicer",
        title = "Slicer crafts", tabOrder = 4, allOrder = 5, craft = true, station = "slicer", optional = true},
    {key = "basin", raw = "basinCrafting", file = "basin_crafting.lua", tab = "Basin",
        title = "Basin crafts", tabOrder = 5, allOrder = 6, craft = true, station = "basin", optional = true},
}

local byKey = {}
for _, def in ipairs(Sections) do byKey[def.key] = def end

function Sections.get(key)
    return byKey[key]
end

-- The definitions sorted by one of the order fields; those without it are left out.
function Sections.ordered(field)
    local list = {}
    for _, def in ipairs(Sections) do
        if def[field] then list[#list + 1] = def end
    end
    table.sort(list, function(a, b) return a[field] < b[field] end)
    return list
end

return Sections
