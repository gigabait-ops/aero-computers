-- Flight controller: example config. Copy it to the master PC as
-- /fc_config.lua and fill in your own ship; everything not listed here comes
-- from the defaults in fc/config.lua. The master rewrites this file on every
-- change made from its screens or commands (only the differences from the
-- defaults are kept, these comments go).
--
-- As shipped, `motors` is empty: the controller starts, prints
--   config: config invalid: motors: no lift motor configured (fc_config.lua)
-- and will not fly until you add your motors below.
--
-- motors: [computer id of the motor's node PC] = role and position
--   lift    pos front_left|front_right|rear_left|rear_right, dir +1/-1 (a
--           positive rpm must lift the ship)
--   vector  pos (one of the corners), push fwd|aft (which way it pushes with
--           the nozzle centred), side +1/-1 (mirrored mounts)
--   booster pos rear|front|center, push fwd|aft (an ion thruster or cube)
--   The node PCs print their own computer id when they start (node/startup.lua).
-- hover: the lift rpm that holds the ship (optional: a guess is fine, it is
--   learned in flight).
-- ap.speed: cruise speed in b/s (0 = as fast as it goes). A new ship should
--   stay at 40 until its braking is measured (docs/tuning.md).
-- input_keys: GLFW key codes of the typewriter's action keys, only where you
--   want other keys than the defaults (fc/hw/input.lua, e.g. power = 57, "9").
-- links: the Create redstone link frequencies on the CC Redstone Link Bridge,
--   two item ids each, BOTH set (the bridge sends nothing on a frequency with
--   an empty slot). clutch = the engine clutch, gear = the landing legs.
--   Empty here: no links are driven until you name your own frequencies.
-- remote: the pocket computer / smart glasses allowed to control the drone:
--   their computer ids and a shared key of at least 8 characters (the same key
--   goes into the pocket's `set drone.key ...`). Empty = no remote control.
-- home / waypoints / routes: set later from the screens or the glasses.
return {
  ap = {speed = 40},
  motors = {
    -- [11] = {role = "lift", pos = "front_left", dir = 1},
    -- [12] = {role = "lift", pos = "front_right", dir = 1},
    -- [13] = {role = "lift", pos = "rear_left", dir = 1},
    -- [14] = {role = "lift", pos = "rear_right", dir = 1},
    -- [15] = {role = "vector", pos = "front_left", push = "aft", side = 1},
    -- [16] = {role = "vector", pos = "front_right", push = "aft", side = 1},
    -- [17] = {role = "vector", pos = "rear_left", push = "fwd", side = -1},
    -- [18] = {role = "vector", pos = "rear_right", push = "fwd", side = -1},
    -- [19] = {role = "booster", pos = "rear", push = "fwd"},
  },
  links = {
    -- clutch = {"minecraft:red_dye", "minecraft:red_dye"},
    -- gear = {"minecraft:lever", "minecraft:lever"},
  },
  -- hover = 40,
  -- input_keys = {power = 57},
  -- remote = {ids = {42}, key = "change-me-please"},
}
