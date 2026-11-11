-- What the glasses' chat service (pda/chat.lua) says in chat, per message
-- key (the keys are in fc/core/lang/*.lua):
--   level   ok | info | warn | error (the mark in front and its colour)
--   once    seconds of quiet after it is said (the same key and its params)
--   prefix  the chat's [prefix] (default: pda/chat.lua C.PREFIX)
-- A key with no rule is shown on the screens only, never in chat.
-- Example: say "arrived" only once every 5 minutes, under its own prefix:
--   ["arrived"] = {level = "ok", once = 300, prefix = "Drone"},
return {
    ["drone.cut"] = {level = "error"},
    ["drone.too_steep"] = {level = "error"},
    ["props.stalled"] = {level = "error"},
    ["power.lost"] = {level = "error"},
    ["power.back"] = {level = "ok"},
    ["lift.full"] = {level = "ok"},
    ["lift.short"] = {level = "warn", once = 300},
    ["refused"] = {level = "warn"},
    ["resumed"] = {level = "warn"},
    ["ion.low"] = {level = "warn", once = 600},
    ["arrived"] = {level = "ok"},
    ["arrived.at"] = {level = "ok"},
    ["docked"] = {level = "ok"},
    ["landed"] = {level = "ok"},
    ["motors.on"] = {level = "ok"},
    ["land"] = {level = "info"},
    ["route.done"] = {level = "ok"},
    ["route.stopped"] = {level = "warn"},
    ["link.lost"] = {level = "error"},
    ["link.back"] = {level = "ok"},
    ["player.near"] = {level = "info", prefix = "Players"},
    ["player.left"] = {level = "info", prefix = "Players"},
}
