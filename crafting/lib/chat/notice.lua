-- Keyed messages for the whole fleet (2026-10-26), like Laravel's lang
-- files: a computer names an event by key and parameters, gets the text for
-- its own screen, and the event goes to the chat relay (PC135) on rednet.
--
--   local text = Notice.emit("craft.missing", {target = id, raw = raw, needed = 64})
--
-- emit never waits: one broadcast, no reply, and no failure reaches the
-- caller. Templates live in chat/lang/<locale>.lua: "{name}" is a parameter,
-- "{name:item}" an item ID shown as the item's name. Monitors use "en" (the
-- CC font has no Cyrillic); the relay renders "uk".
local Notice = {}

Notice.PROTOCOL = "gigabait.chat.v1"
Notice.FALLBACK = "en"

local cache = {}
function Notice.lang(locale)
    if cache[locale] == nil then
        local ok, value = pcall(require, "chat.lang." .. tostring(locale))
        cache[locale] = ok and type(value) == "table" and value or false
    end
    return cache[locale] or {}
end

-- The template for a key: the locale's, the fallback's, else nil.
function Notice.template(key, locale)
    local entry = Notice.lang(locale or Notice.FALLBACK)[key]
    if entry == nil and locale ~= Notice.FALLBACK then entry = Notice.lang(Notice.FALLBACK)[key] end
    return entry
end

-- "create:crushing_wheel" -> "Crushing wheel".
function Notice.itemName(raw)
    local text = tostring(raw or "?")
    local id = text:match("[^|#]*:[^|]+") or text
    id = id:match("^([^|]+)") or id
    local path = (id:match(":(.+)$") or id):gsub("[_/]", " ")
    return path:sub(1, 1):upper() .. path:sub(2)
end

-- Splits a template into text and {name[:type]} pieces.
function Notice.pieces(template)
    local out, position = {}, 1
    while true do
        local first, last, name, kind = template:find("{([%w_]+):?([%w_]*)}", position)
        if not first then break end
        if first > position then out[#out + 1] = {text = template:sub(position, first - 1)} end
        out[#out + 1] = {param = name, kind = kind ~= "" and kind or nil}
        position = last + 1
    end
    if position <= #template then out[#out + 1] = {text = template:sub(position)} end
    return out
end

-- Plain text for a screen.
function Notice.text(key, params, locale)
    local template = Notice.template(key, locale)
    if type(template) ~= "string" then return key end
    params = params or {}
    local parts = {}
    for _, piece in ipairs(Notice.pieces(template)) do
        if piece.text then parts[#parts + 1] = piece.text
        else
            local value = params[piece.param]
            if piece.kind == "item" then
                value = Notice.itemName(value)
            elseif piece.kind == "reason" then
                local reason = Notice.template("reason." .. tostring(value), locale)
                value = type(reason) == "string" and reason or params.error or value
            end
            parts[#parts + 1] = value == nil and "?" or tostring(value)
        end
    end
    return table.concat(parts)
end

-- A craft failure (PC48's failure table and/or its error text) as one line
-- for a screen, worded like the chat: the missing material, else the reason
-- for the code, else the error text itself.
function Notice.failureText(failure, errorText, target, locale)
    failure = type(failure) == "table" and failure or {}
    local message = tostring(errorText or failure.message or "")
    local raw = failure.target or failure.candidate or failure.ingredient
    local parsedRaw, parsedNeeded = message:match("missing (%S+) x(%d+)")
    if (failure.code == "MISSING_RAW" or parsedRaw) and (raw or parsedRaw) then
        return Notice.text("craft.need", {raw = raw or parsedRaw,
            needed = tonumber(failure.needed) or tonumber(parsedNeeded) or "?"}, locale)
    end
    local code = failure.code
    if code and type(Notice.template("reason." .. tostring(code), locale)) == "string" then
        if target then return Notice.text("craft.failed", {target = target, code = code}, locale) end
        return Notice.text("reason." .. tostring(code), {}, locale)
    end
    if message ~= "" then return message end
    return code and tostring(code) or "failed"
end

-- Fire and forget; returns the screen text.
function Notice.emit(key, params, rednetApi)
    local api = rednetApi or rednet
    if type(api) == "table" and type(api.broadcast) == "function" then
        pcall(api.broadcast, {
            key = key, params = params or {},
            from = os.getComputerID and os.getComputerID() or nil,
            at = os.epoch and os.epoch("utc") or nil,
        }, Notice.PROTOCOL)
    end
    return Notice.text(key, params)
end

return Notice
