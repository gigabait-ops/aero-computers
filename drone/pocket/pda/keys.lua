-- The glasses' keyboard flies the drone like the linked typewriter: with
-- the glasses' screen open and no prompt in it, the flight keys go to the
-- master's key bridge (fc.hw.input) instead of the screen. Numpad 8 (any
-- keyboard) or the Hint row shows or hides the key hint on the HUD (the
-- master keeps it: status.keys_on); flying never hangs on it (owner
-- 2026-10-24). The set held
-- goes out on every change and every K.SEND s while one is held (the master
-- lets a quiet source go after 1.2 s); everything is let go when the tab
-- changes. A held key repeats: one whose repeats stop for K.STALE s is let
-- go here even with no key_up (a lost key_up kept W held for 12 s, X and 7
-- lost against it and the drone flew 220 blocks off, 2026-10-24).
--   W S (up down arrows)  faster forward / slower, back   A D  turn while held
--   left right arrows     slide sideways while held       Space Shift  up / down
--   X brake to a stop     H hover here   L land   9 motors (start, land, off)
--   numpad 7              the forward speed back to 0
--   numpad 8              the HUD's key hint on / off
--   numpad 4 6            turn to the next side of the world, left / right
local D = require("pda.drone")

local K = {}

K.SEND = 0.5
K.STALE = 0.6
-- only the keys that fly while held: a repeat after the drop reads as a
-- fresh press, and numpad 8 then switched the keyboard on and off at once
K.STALE_NAMES = {w = true, s = true, a = true, d = true, left = true, right = true, space = true, shift = true}

-- CC key codes (GLFW, as the typewriter's) -> the bridge's logical names
K.NAMES = {[87] = "w", [265] = "w", [83] = "s", [264] = "s", [65] = "a", [68] = "d", [263] = "left", [262] = "right",
           [32] = "space", [340] = "shift", [344] = "shift", [57] = "power", [329] = "power",
           [88] = "stop", [72] = "hold", [76] = "land", [328] = "keys", [327] = "zero", [324] = "face_left", [326] = "face_right"}

-- the letters those keys type (char events, swallowed while the drone has the keyboard)
K.CHARS = {w = true, s = true, a = true, d = true, x = true, h = true, l = true, [" "] = true, ["9"] = true, ["8"] = true,
           W = true, S = true, A = true, D = true, X = true, H = true, L = true}

function K.new() return {held = {}, sent = nil, last = {}, repeats = {}} end

-- Is the key hint on (the drone's status says so).
function K.on(drone) return drone.status ~= nil and drone.status.keys_on == true end

-- The names held now, sorted, once each.
function K.names(k)
    local seen, out = {}, {}
    for _, n in pairs(k.held) do
        if not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

local function send(k, drone, now)
    k.sent = now
    D.keys(drone, K.names(k))
end

-- A key or key_up event: true when the drone took it (a flight key).
function K.event(k, drone, kind, code, now)
    local name = K.NAMES[code]
    if not name then return false end
    if kind == "key" then
        if k.held[code] then k.repeats[code] = true   -- a repeat: still held
        else k.held[code] = name; send(k, drone, now) end
        k.last[code] = now
    elseif kind == "key_up" then
        if k.held[code] then k.held[code] = nil; send(k, drone, now) end
        k.last[code], k.repeats[code] = nil, nil
    end
    return true
end

-- While a key is held: the set again every K.SEND s.
function K.tick(k, drone, now)
    local dropped = false
    for code in pairs(k.held) do
        if k.repeats[code] and K.STALE_NAMES[k.held[code]] and now - (k.last[code] or now) > K.STALE then
            k.held[code], k.last[code], k.repeats[code] = nil, nil, nil
            dropped = true
        end
    end
    if dropped or (next(k.held) and (not k.sent or now - k.sent >= K.SEND)) then send(k, drone, now) end
end

-- Off the Drone tab or into a prompt: every key let go at once.
function K.release(k, drone, now)
    k.last, k.repeats = {}, {}
    if next(k.held) then k.held = {}; send(k, drone, now) end
end

-- The Hint row: the key hint on / off.
function K.toggle(drone) D.cmd(drone, "keys_toggle") end

-- For the HUD: nil while the hint is off, else {held = {name = true}}:
-- the keys held here and on the drone's other keyboards.
function K.hint(k, drone)
    if not K.on(drone) then return nil end
    local held = {}
    for _, n in pairs(k.held) do held[n] = true end
    for _, n in ipairs(drone.status.held or {}) do held[n] = true end
    return {held = held}
end

return K
