local Util = require("app.util")

local Sorting = {}

local TYPE_RULES = {
    {name = "ORES", tags = {"c:ores", "forge:ores", "minecraft:ores"}, patterns = {"_ore$"}},
    {name = "RAW MATERIALS", tags = {"c:raw_materials", "forge:raw_materials"}, patterns = {"raw_"}},
    {name = "INGOTS", tags = {"c:ingots", "forge:ingots"}, patterns = {"_ingot$"}},
    {name = "NUGGETS", tags = {"c:nuggets", "forge:nuggets"}, patterns = {"_nugget$"}},
    {name = "SHEETS", tags = {"c:plates", "forge:plates"}, patterns = {"_sheet$", "_plate$"}},
    {name = "GEMS", tags = {"c:gems", "forge:gems"}, patterns = {"diamond$", "emerald$", "quartz$"}},
    {name = "DYES", tags = {"c:dyes", "forge:dyes"}, patterns = {"_dye$"}},
    {name = "WOOD", tags = {"minecraft:logs", "minecraft:planks"}, patterns = {"_log$", "_wood$", "_planks$"}},
    {name = "STONE", tags = {"minecraft:stone_tool_materials"}, patterns = {"stone", "deepslate", "cobble", "tuff", "granite", "andesite", "diorite"}},
    {name = "FOOD", tags = {"c:foods", "forge:foods"}, patterns = {"wheat$", "bread$"}},
}

local function cloneMetadata(item)
    local result = {}

    if type(item.tags) == "table" then
        result.tags = {}

        for key, value in pairs(item.tags) do
            result.tags[key] = value
        end
    end

    if type(item.itemGroups) == "table" then
        result.itemGroups = {}

        for index, group in ipairs(item.itemGroups) do
            if type(group) == "table" then
                result.itemGroups[index] = {
                    id = group.id,
                    displayName = group.displayName
                }
            end
        end
    end

    return result
end

function Sorting.mergeMetadata(metadata, item)
    if type(item) ~= "table" or type(item.name) ~= "string" then
        return
    end

    local current = metadata[item.name]
    local nextValue = cloneMetadata(item)

    if not current then
        metadata[item.name] = nextValue
        return
    end

    current.tags = current.tags or nextValue.tags
    current.itemGroups = current.itemGroups or nextValue.itemGroups
end

local function firstItemGroup(metadata)
    local groups = metadata and metadata.itemGroups
    local group = type(groups) == "table" and groups[1] or nil

    if type(group) ~= "table" then
        return nil
    end

    return group.displayName or group.id
end

local function firstTag(metadata)
    local tags = metadata and metadata.tags

    for _, tag in ipairs(Util.sortedKeys(tags)) do
        if tags[tag] == true then
            return tag
        end
    end

    return nil
end

local function hasTag(metadata, wanted)
    local tags = metadata and metadata.tags

    return type(tags) == "table" and tags[wanted] == true
end

local function typeGroup(name, metadata)
    local lowered = tostring(name or ""):lower()

    for index, rule in ipairs(TYPE_RULES) do
        for _, tag in ipairs(rule.tags or {}) do
            if hasTag(metadata, tag) then
                return index, rule.name
            end
        end

        for _, pattern in ipairs(rule.patterns or {}) do
            if lowered:match(pattern) then
                return index, rule.name
            end
        end
    end

    return 999, "OTHER"
end

local function sortParts(item, mode)
    local metadata = item.metadata or {}
    mode = tostring(mode or "count")

    if mode == "name" then
        return 1, ""
    end

    if mode == "itemGroups" then
        local group = firstItemGroup(metadata)

        if group then
            return 1, tostring(group)
        end

        local rank, typed = typeGroup(item.name, metadata)
        return rank < 999 and rank or 999, rank < 999 and typed or "OTHER"
    end

    if mode == "tags" then
        local tag = firstTag(metadata)

        if tag then
            return 1, tostring(tag)
        end

        local rank, typed = typeGroup(item.name, metadata)
        return rank < 999 and rank or 999, rank < 999 and typed or "other"
    end

    if mode == "type" then
        return typeGroup(item.name, metadata)
    end

    if mode == "auto" then
        local rank, group = typeGroup(item.name, metadata)

        if rank < 999 then
            return rank, group
        end

        local itemGroup = firstItemGroup(metadata)

        if itemGroup then
            return 1000, tostring(itemGroup)
        end

        local tag = firstTag(metadata)

        if tag then
            return 1001, tostring(tag)
        end

        return 9999, "OTHER"
    end

    return 0, ""
end

local function sortingMode(sorting)
    return tostring((sorting or {}).stockMode or "count")
end

local function activePriority(row)
    local status = tostring((row or {}).status or "")

    if status == "ERROR" then
        return 0
    end

    -- Rules waiting for material (NEEDS) are problems too: near the top.
    if status == "NO_STOCK" or status == "NEEDS" then
        return 1
    end

    if status == "LOW" then
        return 2
    end

    if status == "QUEUE" or status == "REQUESTED" then
        return 3
    end

    if status == "WAIT" then
        return 4
    end

    if status == "OFF" then
        return 30
    end

    return 20
end

local function compareItems(left, right, mode)
    if mode == "count" then
        if (left.count or 0) ~= (right.count or 0) then
            return (left.count or 0) > (right.count or 0)
        end

        return tostring(left.name or "") < tostring(right.name or "")
    end

    local leftRank, leftGroup = sortParts(left, mode)
    local rightRank, rightGroup = sortParts(right, mode)

    if leftRank ~= rightRank then
        return leftRank < rightRank
    end

    if leftGroup ~= rightGroup then
        return leftGroup < rightGroup
    end

    return tostring(left.name or "") < tostring(right.name or "")
end

local function rowItem(row, metadata)
    local name = row.check or row.key

    return {
        name = name,
        count = tonumber(row.count) or 0,
        label = row.label,
        key = row.key,
        metadata = (metadata or {})[name] or {}
    }
end

function Sorting.sortRows(rows, metadata, sorting)
    local mode = sortingMode(sorting)
    local activeFirst = (sorting or {}).activeFirst ~= false

    table.sort(rows or {}, function(left, right)
        if activeFirst then
            local leftPriority = activePriority(left)
            local rightPriority = activePriority(right)

            if leftPriority ~= rightPriority then
                return leftPriority < rightPriority
            end
        end

        local leftItem = rowItem(left, metadata)
        local rightItem = rowItem(right, metadata)

        if compareItems(leftItem, rightItem, mode) then
            return true
        end

        if compareItems(rightItem, leftItem, mode) then
            return false
        end

        return tostring(left.label or left.key or "") < tostring(right.label or right.key or "")
    end)
end

return Sorting
