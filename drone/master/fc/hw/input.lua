-- Manual flight input from the Simulated linked typewriter (GLFW key codes,
-- the same numbers as CC's `keys`). Each key press is an edge that steps a
-- setpoint in the engine (the power key is 9, since P is bound in the owner's
-- Minecraft); a key held longer than input_repeat_delay repeats
-- every input_repeat seconds. Pure.
local I = {}

I.KEYS = {w = 87, a = 65, s = 83, d = 68, space = 32, lshift = 340, rshift = 344,
          up = 265, down = 264, left = 263, right = 262, nine = 57, x = 88, h = 72, l = 76}

-- key code -> logical name
I.NAMES = {[87] = "w", [265] = "w", [83] = "s", [264] = "s", [65] = "a", [263] = "left", [68] = "d", [262] = "right",
           [32] = "space", [340] = "shift", [344] = "shift", [57] = "power", [88] = "x", [72] = "h", [76] = "l"}

-- Default codes for the action keys; cfg.input_keys = {power=, stop=, hold=, land=, keys=, zero=} overrides them.
-- keys (numpad 8): the keyboard switch, from any source; zero (numpad 7):
-- the forward speed back to 0 (fc.ui.keys); face_left / face_right
-- (numpad 4 / 6): turn to the next side of the world, 90 deg steps.
I.ACTION_DEFAULTS = {power = 57, stop = 88, hold = 72, land = 76, keys = 328, zero = 327, face_left = 324, face_right = 326}

function I.new(cfg)
    local names = {}
    for code, name in pairs(I.NAMES) do
        if not I.ACTION_DEFAULTS[name] then names[code] = name end
    end
    for action, default in pairs(I.ACTION_DEFAULTS) do
        names[(cfg.input_keys and cfg.input_keys[action]) or default] = action
    end
    return {cfg = cfg, held = {}, names = names}   -- held[name] = {since = t, last = t}
end

-- Returns a map name -> multiplier of the keys that fire this poll: a fresh
-- press fires x1; a key held past input_repeat_delay fires every
-- input_repeat seconds with a multiplier that grows by one each repeat up to
-- input_accel_max. Power never repeats; A/D are not stepped at all (held = turn).
I.NO_REPEAT = {power = true, keys = true, zero = true, face_left = true, face_right = true}

function I.edges(inp, codes, now)
    local cfg = inp.cfg
    local delay, period = cfg.input_repeat_delay or 0.4, cfg.input_repeat or 0.25
    local accel_max = cfg.input_accel_max or 5
    local down = {}
    for _, c in ipairs(codes or {}) do
        local name = inp.names[c]
        if name then down[name] = true end
    end
    local fired = {}
    for name in pairs(down) do
        local h = inp.held[name]
        if not h then
            inp.held[name] = {since = now, last = now, mult = 0}
            fired[name] = 1
        elseif not I.NO_REPEAT[name] and now - h.since >= delay and now - h.last >= period then
            h.last = now
            h.mult = math.min(h.mult + 1, accel_max)
            fired[name] = h.mult
        end
    end
    for name in pairs(inp.held) do
        if not down[name] then inp.held[name] = nil end
    end
    return fired
end

-- The key bridge: every source of keys (the typewriter, the owner's
-- glasses, anything added later) says which keys it holds now, as key codes
-- or as the logical names below; the flight sees them all as one keyboard.
-- A source that goes quiet for longer than its hold is let go (the glasses
-- closed with a key down): the typewriter is polled 10 times a second, the
-- glasses send on every change and twice a second while a key is held.
I.HOLD = {typewriter = 0.5}
I.HOLD_DEFAULT = 1.2
I.LOGICAL = {w = true, s = true, a = true, d = true, left = true, right = true, space = true, shift = true,
             power = true, stop = true, hold = true, land = true, keys = true, zero = true, face_left = true, face_right = true}

-- `source` (a name: "typewriter", "glasses 120", ...) holds `keys` now.
-- Returns the logical names it holds.
function I.feed(inp, source, keys, now)
    local set, seen = {}, {}
    for _, k in ipairs(type(keys) == "table" and keys or {}) do
        local name = type(k) == "number" and inp.names[k] or (I.LOGICAL[k] and k) or nil
        if name and not seen[name] then seen[name] = true; set[#set + 1] = name end
    end
    inp.sources = inp.sources or {}
    local key = tostring(source)
    inp.sources[key] = {names = set, t = now, hold = I.HOLD[key:match("^%S+")] or I.HOLD_DEFAULT}
    return set
end

-- Every key held by any source still heard, as the codes this input knows
-- (for I.edges); the sources holding something, for the log.
function I.held_codes(inp, now)
    local code_of = {}
    for code, name in pairs(inp.names) do
        if not code_of[name] or code < code_of[name] then code_of[name] = code end
    end
    local out, seen, who = {}, {}, {}
    for source, s in pairs(inp.sources or {}) do
        if now - s.t <= s.hold then
            for _, n in ipairs(s.names) do
                local c = code_of[n]
                if c and not seen[c] then seen[c] = true; out[#out + 1] = c end
            end
            if #s.names > 0 then who[#who + 1] = source end
        else
            inp.sources[source] = nil
        end
    end
    table.sort(out); table.sort(who)
    return out, who
end

function I.is_down(inp, name)
    return inp.held[name] ~= nil
end

return I
