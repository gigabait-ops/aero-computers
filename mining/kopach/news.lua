-- The mining remote's chat news (owner 2026-11-05), in the warehouse's
-- keyed style: app.lua names an event by a key and its params (K.news);
-- the host's chat service (the PDA's pda/chat.lua) says it in Ukrainian
-- with these templates and rules, and a screen shows the English text.
--   rules   level ok | info | warn | error, once = seconds of quiet for the
--           same key and params[by], prefix = the chat's [prefix]
--   uk, en  "{x}" a parameter, "{x:name}" a name (in aqua)
-- A key with no rule stays off the chat.
local P = "Копачі"

return {
    rules = {
        ["kopach.started"] = {level = "ok", prefix = P},
        ["kopach.level"] = {level = "info", prefix = P},
        ["kopach.finished"] = {level = "ok", prefix = P},
        ["kopach.stopped_at"] = {level = "ok", prefix = P},
        ["kopach.joined"] = {level = "info", prefix = P, once = 3600, by = "turtle"},
        ["kopach.lost"] = {level = "warn", prefix = P, once = 1800, by = "turtle"},
        ["kopach.no_fuel"] = {level = "error", prefix = P, once = 900, by = "turtle"},
        ["kopach.no_storage"] = {level = "error", prefix = P, once = 900, by = "turtle"},
        ["kopach.no_room"] = {level = "warn", prefix = P, once = 900, by = "turtle"},
        ["kopach.no_blocks"] = {level = "warn", prefix = P, once = 900, by = "turtle"},
        ["kopach.no_gps"] = {level = "error", prefix = P, once = 900, by = "turtle"},
        ["kopach.stuck"] = {level = "error", prefix = P, once = 900, by = "turtle"},
        ["kopach.outside"] = {level = "warn", prefix = P, once = 1800, by = "turtle"},
        ["kopach.error"] = {level = "error", prefix = P, once = 900, by = "turtle"},
    },
    uk = {
        ["kopach.started"] = "Почали копати: {shape} {radius}, {levels} рівнів",
        ["kopach.level"] = "Рівень {level} з {levels} готовий",
        ["kopach.finished"] = "Усе викопано, черепашки вдома",
        ["kopach.stopped_at"] = "Рівень {level} докопано, черепашки вдома",
        ["kopach.joined"] = "Нова черепашка {turtle:name}",
        ["kopach.lost"] = "{turtle:name} не відповідає",
        ["kopach.no_fuel"] = "{turtle:name} без палива",
        ["kopach.no_storage"] = "{turtle:name} без своєї бочки",
        ["kopach.no_room"] = "{turtle:name} нікуди поставити бочку",
        ["kopach.no_blocks"] = "{turtle:name} не має блоків для стін",
        ["kopach.no_gps"] = "{turtle:name} не бачить GPS",
        ["kopach.stuck"] = "{turtle:name} застрягла",
        ["kopach.outside"] = "{turtle:name} поза ямою: перенеси її",
        ["kopach.error"] = "{turtle:name}: помилка програми",
    },
    en = {
        ["kopach.started"] = "Digging: {shape} {radius}, {levels} levels",
        ["kopach.level"] = "Level {level} of {levels} done",
        ["kopach.finished"] = "All dug, the turtles are home",
        ["kopach.stopped_at"] = "Level {level} done, the turtles are home",
        ["kopach.joined"] = "New turtle {turtle:name}",
        ["kopach.lost"] = "{turtle:name} does not answer",
        ["kopach.no_fuel"] = "{turtle:name} has no fuel",
        ["kopach.no_storage"] = "{turtle:name} has no barrel",
        ["kopach.no_room"] = "{turtle:name}: no room for its barrel",
        ["kopach.no_blocks"] = "{turtle:name} has no blocks for the walls",
        ["kopach.no_gps"] = "{turtle:name} sees no GPS",
        ["kopach.stuck"] = "{turtle:name} is stuck",
        ["kopach.outside"] = "{turtle:name} is outside the pit: carry it in",
        ["kopach.error"] = "{turtle:name}: program error",
    },
    -- a turtle's word (its heartbeat) -> the key said when it turns to that word
    words = {
        ["no fuel"] = "kopach.no_fuel", ["no storage"] = "kopach.no_storage", ["no room"] = "kopach.no_room",
        ["no blocks"] = "kopach.no_blocks", ["no gps"] = "kopach.no_gps", stuck = "kopach.stuck",
        error = "kopach.error", outside = "kopach.outside",
    },
}
