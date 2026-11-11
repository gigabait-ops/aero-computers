-- Keyed messages (2026-11-02), as the warehouse's chat.notice and Laravel's
-- lang files: the master names an event by a key and its parameters; a
-- screen shows it in English (the CC font has no Cyrillic), the glasses'
-- chat service (pocket/pda/chat.lua) says it in Ukrainian by its own rules.
-- Templates in lang/<locale>.lua: "{x}" a parameter, "{x:name}" a name (a
-- point, a route, a player), "{x:reason}" the locale's "reason.<x>" (else x
-- itself), "{x:state}" the locale's "state.<x>" (else x). One source for the
-- master and the glasses: tools/deploy.sh copies it and lang/ to pda/.
local N = {}

N.FALLBACK = "en"
N.PATHS = {"fc.core.lang.", "pda.lang."}   -- the master's, the glasses'

local cache = {}
function N.lang(locale)
    if cache[locale] == nil then
        cache[locale] = false
        for _, base in ipairs(N.PATHS) do
            local ok, t = pcall(require, base .. locale)
            if ok and type(t) == "table" then cache[locale] = t; break end
        end
    end
    return cache[locale] or {}
end

-- The locale's template for a key, else the fallback's, else nil.
function N.template(key, locale)
    local t = N.lang(locale or N.FALLBACK)[key]
    if t == nil and locale ~= N.FALLBACK then t = N.lang(N.FALLBACK)[key] end
    return t
end

-- The message as parts: {text, name = true for a name}; the key itself
-- when no locale has it.
function N.parts(key, params, locale)
    local template = N.template(key, locale)
    if type(template) ~= "string" then return {{text = tostring(key)}} end
    params = params or {}
    local out, pos = {}, 1
    while true do
        local a, b, name, kind = template:find("{([%w_]+):?([%w_]*)}", pos)
        if not a then break end
        if a > pos then out[#out + 1] = {text = template:sub(pos, a - 1)} end
        local v = params[name]
        v = v == nil and "?" or tostring(v)
        if kind == "reason" or kind == "state" then
            local t = N.template(kind .. "." .. v, locale)
            v = type(t) == "string" and t or v
        end
        out[#out + 1] = {text = v, name = kind == "name" or nil}
        pos = b + 1
    end
    if pos <= #template then out[#out + 1] = {text = template:sub(pos)} end
    return out
end

function N.text(key, params, locale)
    local s = {}
    for i, p in ipairs(N.parts(key, params, locale)) do s[i] = p.text end
    return table.concat(s)
end

return N
