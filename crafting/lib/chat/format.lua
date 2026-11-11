-- Minecraft text components for the chat relay (2026-10-26).
-- JSON is written here, not with textutils: the Chat Box takes the UTF-8
-- bytes as they are (option utf8 = true), which keeps Cyrillic short enough
-- for its 512-character message limit (\uXXXX would triple it).
local Format = {}

local function escape(text)
    return (tostring(text):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        return string.format("\\u%04x", c:byte())
    end))
end

local function encode(value)
    local kind = type(value)
    if kind == "string" then return '"' .. escape(value) .. '"' end
    if kind == "number" then return tostring(math.floor(value)) end
    if kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "null" end
    if value[1] ~= nil or next(value) == nil then
        local parts = {}
        for i, item in ipairs(value) do parts[i] = encode(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = '"' .. escape(key) .. '":' .. encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
Format.encode = encode

-- "c:plates/x|createcasing:andesite_sheet" -> "createcasing:andesite_sheet".
function Format.itemId(raw)
    raw = tostring(raw or "")
    for part in raw:gmatch("[^|]+") do
        if part:sub(1, 1) ~= "#" and part:find(":", 1, true) then return part end
    end
    return nil
end

local function pretty(id)
    local path = tostring(id):match(":(.+)$") or tostring(id)
    path = path:gsub("[_/]", " ")
    return path:sub(1, 1):upper() .. path:sub(2)
end

-- "block" or "item" for the name key, from chat.lang.blocks (generated from
-- the server's lang files); nil for a namespace it does not list.
local blockSets
function Format.nameKind(ns, path)
    if blockSets == nil then
        local ok, data = pcall(require, "chat.lang.blocks")
        blockSets = {data = ok and type(data) == "table" and data or {}}
    end
    local set = blockSets[ns]
    if set == nil then
        local list = blockSets.data[ns]
        if not list then return nil end
        set = {}
        for p in list:gmatch("%S+") do set[p] = true end
        blockSets[ns] = set
    end
    return set[path] and "block" or "item"
end

-- How many %s a name key holds, from chat.lang.args (generated).
local argSets
function Format.nameArgs(ns, key)
    if argSets == nil then
        local ok, data = pcall(require, "chat.lang.args")
        argSets = {data = ok and type(data) == "table" and data or {}}
    end
    local set = argSets[ns]
    if set == nil then
        set = {}
        for k, n in tostring(argSets.data[ns] or ""):gmatch("(%S+)=(%d+)") do set[k] = tonumber(n) end
        argSets[ns] = set
    end
    return set[key] or 0
end

-- The item's name in the reader's language: the item key, else the block
-- key (block items), with the item itself on hover.
function Format.item(raw, count)
    local id = Format.itemId(raw)
    if not id then
        return {text = tostring(raw or "?"):gsub("^#", ""), color = "aqua"}
    end
    local ns, path = id:match("^([^:]+):(.+)$")
    path = path:gsub("/", ".")
    local kind = Format.nameKind(ns, path)
    local name
    if kind then
        name = {translate = kind .. "." .. ns .. "." .. path}
        -- A name that is a template ("%s%sBarrel") gets empty arguments.
        local holes = Format.nameArgs(ns, kind .. "." .. path)
        if holes > 0 then
            name.with = {}
            for i = 1, holes do name.with[i] = "" end
        end
    else
        -- A namespace the generated list does not know: the item key, else
        -- the block key (no English fallback: it costs ~30 of 512 characters).
        name = {translate = "item." .. ns .. "." .. path, fallback = "%s",
            with = {{translate = "block." .. ns .. "." .. path}}}
    end
    -- show_text, not show_item: the Chat Box (AP 0.8) rebuilds a show_item
    -- tooltip on the server without a player and gets "Invalid item" for
    -- many modded items (seen 2026-10-27 on a backpack stack upgrade).
    name.color, name.hoverEvent = "aqua", {action = "show_text", contents = {text = id, color = "gray"}}
    -- A click copies the ID (owner 2026-10-30).
    name.clickEvent = {action = "copy_to_clipboard", value = id}
    if count and count > 0 then name.extra = {" ×" .. math.floor(count)} end
    return name
end

-- The line with a copy-the-ID click on every hovered item name that has
-- none (lines worded elsewhere, PC107's, carry only the hover).
function Format.clickable(line)
    local out = {}
    for index, part in ipairs(line) do
        local hover = type(part) == "table" and part.hoverEvent
        local id = hover and hover.action == "show_text" and type(hover.contents) == "table" and hover.contents.text
        if id and not part.clickEvent and tostring(id):find("^[%w_.-]+:[%w_./-]+$") then
            local copy = {}
            for k, v in pairs(part) do copy[k] = v end
            copy.clickEvent = {action = "copy_to_clipboard", value = id}
            part = copy
        end
        out[index] = part
    end
    return out
end

-- The same line with up to `limit` item names made plain (no hover, English
-- name), for a line over the Chat Box limit; nil when none is left.
function Format.plain(line, limit)
    local out, changed = {}, 0
    for index, part in ipairs(line) do
        if (not limit or changed < limit) and type(part) == "table" and part.hoverEvent
            and part.color == "aqua" then
            changed = changed + 1
            local id = part.hoverEvent.contents.text
            local text = pretty(id)
            if part.extra then text = text .. part.extra[1] end
            out[index] = {text = text, color = "aqua"}
        else
            out[index] = part
        end
    end
    if changed == 0 then return nil end
    return out
end

Format.COLORS = {ok = "green", info = "gray", warn = "yellow", error = "red"}
Format.MARKS = {ok = "✔ ", info = "• ", warn = "⚠ ", error = "✖ "}

-- A keyed template as components: "{x:item}" an item, "{x:reason}" the
-- locale's "reason.<value>" (else params.error), "{x}" plain text.
function Format.render(Notice, key, params, locale)
    params = params or {}
    local template = Notice.template(key, locale)
    if type(template) ~= "string" then return {key} end
    local out = {}
    for _, piece in ipairs(Notice.pieces(template)) do
        if piece.text then
            -- Bare strings: the shortest component, in the default colour.
            out[#out + 1] = piece.text
        else
            local value = params[piece.param]
            if piece.kind == "item" then
                out[#out + 1] = Format.item(value)
            elseif piece.kind == "reason" then
                local reason = Notice.template("reason." .. tostring(value), locale)
                local text = type(reason) == "string" and reason or tostring(params.error or value or "?")
                if #text > 80 then text = text:sub(1, 77) .. "..." end
                out[#out + 1] = text
            else
                out[#out + 1] = value == nil and "?" or tostring(value)
            end
        end
    end
    -- Adjacent plain strings as one (fewer characters).
    local merged = {}
    for _, part in ipairs(out) do
        if type(part) == "string" and type(merged[#merged]) == "string" then
            merged[#merged] = merged[#merged] .. part
        else
            merged[#merged + 1] = part
        end
    end
    return merged
end

-- One chat line: a coloured mark, then the parts.
function Format.line(level, parts)
    local out = {"", {text = Format.MARKS[level] or "", color = Format.COLORS[level] or "white"}}
    for _, part in ipairs(parts) do out[#out + 1] = part end
    return out
end

return Format
