-- Colony Supply: Ukrainian words for every key of config.lua and the rules
-- files, written in Latin letters (the in-game editor shows no Cyrillic).
-- Inside, the program works with the English keys; the files may use
-- either, so files written before 2026-10-30 keep working.
local W = {}

-- config.lua: groups, then the keys inside each group
local GROUPS = {
    sklad = "create", kolonia = "colony", vyviz = "send", zapas = "keep", budivelnyk = "builder",
    stravy = "dishes", kraft = "craft", zamovlennia = "orders", ekran = "screen", chat = "chat",
    zhurnal = "log", znimok_kozhni = "snapshot_every",
}
local KEYS = {
    create = {tiker = "ticker"},
    colony = {intehrator = "integrator", sklad = "warehouse", tiker = "ticker", dostavka = "delivery",
        skrynia = "inbox", adresa = "address"},
    send = {uvimkneno = "enabled", cherez = "by", skrynia = "outbox", adresa = "to", kozhni = "every",
        vid = "min", za_raz_shtuk = "max", pauza = "wait", za_raz = "per_check", trymaty = "hold",
        trymaty_budivelnyku = "hold_builder"},
    keep = {uvimkneno = "enabled", pravyla = "rules", perechytuvaty = "reload_every", povtor = "reorder_after"},
    builder = {uvimkneno = "enabled", maks_predmetiv = "max_items", povtor = "reorder_after",
        onovliuvaty = "refresh_every"},
    dishes = {uvimkneno = "enabled", pravyla = "rules", perechytuvaty = "reload_every", povtor = "reorder_after"},
    craft = {uvimkneno = "enabled", znovu = "again"},
    orders = {kozhni = "interval", pauza = "gap", za_raz = "per_scan", povtor = "reorder_after",
        nema_povtor = "missing_retry", pereviryty = "recheck_after", min = "min", maks = "max",
        ne_dlia = "skip_huts", ne_zamovliaty = "skip_items"},
    screen = {monitor = "monitor", rozmir = "scale", palitra = "palette"},
    chat = {uvimkneno = "enabled", mova = "locale", radius = "range", pidpys = "prefix",
        zvit_kozhni = "summary_every", pravyla = "rules", cherez_relei = "relay"},
    log = {riven = "level", teka = "dir", fail = "file", konsol = "console", failiv = "max_files"},
}
-- values that have Ukrainian words too
local VALUES = {
    colony = {delivery = {pryamo = "direct", skrynia = "chest"}},
    send = {by = {tiker = "ticker", skrynia = "chest"}},
}

-- one table with its keys renamed; a Ukrainian key wins over the English one
local function rename(t, keys, values)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        if keys[k] == nil then out[k] = v end
    end
    for k, v in pairs(t) do
        local english = keys[k]
        if english then out[english] = v end
    end
    for key, words in pairs(values or {}) do
        if type(out[key]) == "string" and words[out[key]] then out[key] = words[out[key]] end
    end
    return out
end
W.rename = rename

function W.config(user)
    if type(user) ~= "table" then return user end
    local out = rename(user, GROUPS)
    for group, keys in pairs(KEYS) do
        if type(out[group]) == "table" then out[group] = rename(out[group], keys, VALUES[group]) end
    end
    return out
end

-- rules/keep.lua: a list of lines
local KEEP = {predmet = "item", mistyt = "match", maks = "max", nazva = "name", hrupa = "group",
    variatsii = "variants", vid = "from", chysti = "plain"}
function W.keep(list)
    if type(list) ~= "table" then return list end
    local out = {}
    for i, rule in ipairs(list) do out[i] = rename(rule, KEEP) end
    return out
end

-- rules/dishes.lua: dish -> its raw ingredients
local DISH = {predmet = "item", na_odnu = "per", maks = "max"}
function W.dishes(map)
    if type(map) ~= "table" then return map end
    local out = {}
    for dish, list in pairs(map) do
        local items = {}
        for i, entry in ipairs(type(list) == "table" and list or {}) do items[i] = rename(entry, DISH) end
        out[dish] = items
    end
    return out
end

-- rules/chat.lua: message key -> what happens to it
local CHAT = {riven = "level", koly = "mode", kozhni = "every", po = "by", suma = "sum",
    zaholovok = "header", vymkneno = "off"}
local CHAT_VALUES = {level = {dobre = "ok", info = "info", uvaha = "warn", pomylka = "error"},
    mode = {odrazu = "now", raz = "once", zvit = "summary"}}
function W.chat(map)
    if type(map) ~= "table" then return map end
    local out = {}
    for key, rule in pairs(map) do out[key] = rename(rule, CHAT, CHAT_VALUES) end
    return out
end

-- rules/addresses.lua: the colony's and storage's addresses, then one line per building
local ADDRESSES = {kolonia = "colony", sklad = "storage"}
local BUILDING = {de = "at", budivlia = "hut", adresa = "address"}
function W.addresses(t)
    if type(t) ~= "table" then return t end
    local out = rename(t, ADDRESSES)
    for i, entry in ipairs(t) do out[i] = rename(entry, BUILDING) end
    return out
end


return W
