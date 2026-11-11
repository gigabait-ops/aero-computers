-- Chat: what happens to each message.
--   riven = "dobre" | "info" | "uvaha" | "pomylka"   (the mark and its colour)
--   koly  = "odrazu" - say it at once
--           "raz"    - say it, then stay quiet about the same `po` for `kozhni` seconds
--           "zvit"   - count per `po`, one list every chat.zvit_kozhni seconds
--   vymkneno = true: never say it
-- The words are in app/lang/uk.lua and app/lang/en.lua; config.lua chat.mova picks one.
return {
    ["system.started"]       = {riven = "info", koly = "odrazu"},

    ["colony.attack"]        = {riven = "pomylka", koly = "raz", kozhni = 600},
    ["colony.raid"]          = {riven = "pomylka", koly = "raz", kozhni = 600},
    ["colony.grave"]         = {riven = "uvaha", koly = "odrazu"},
    ["colony.citizen_new"]   = {riven = "dobre", koly = "odrazu"},
    ["colony.full"]          = {riven = "info", koly = "raz", kozhni = 21600},
    ["colony.hungry"]        = {riven = "uvaha", koly = "raz", kozhni = 3600},

    ["building.built"]       = {riven = "dobre", koly = "odrazu"},
    ["building.upgraded"]    = {riven = "dobre", koly = "odrazu"},

    ["supply.missing"]       = {riven = "uvaha", koly = "raz", po = "item", kozhni = 3600},
    ["supply.missing_stock"] = {riven = "info", koly = "raz", po = "item", kozhni = 21600},
    ["supply.missing_build"] = {riven = "uvaha", koly = "raz", po = "item", kozhni = 3600},
    ["supply.crafting"]       = {riven = "info", koly = "raz", po = "item", kozhni = 1800},
    ["supply.crafting_stock"] = {riven = "info", koly = "raz", po = "item", kozhni = 1800},
    ["supply.crafting_build"] = {riven = "info", koly = "raz", po = "item", kozhni = 1800},
    ["supply.ordered"]       = {riven = "info", koly = "zvit", po = "item", suma = "count",
                                zaholovok = "supply.ordered"},
    ["supply.delivered"]     = {riven = "dobre", koly = "zvit", po = "item", suma = "count",
                                zaholovok = "supply.delivered"},
}
