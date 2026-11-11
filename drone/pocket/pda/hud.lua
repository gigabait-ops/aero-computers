-- The drone's status on the smart glasses' screen overlay (Advanced
-- Peripherals Overlay Module, peripheral "smart_glasses"): a small table in
-- the top-left corner, over a dark band
-- (fixed GUI units: no screen size to depend on; owner 2026-10-18), drawn
-- from the drone model, only
-- while the owner flies: the drone in the air and the owner aboard (within
-- H.NEAR blocks of it; owner 2026-10-18). A link lost in flight stays shown.
-- Without the module (a pocket computer, or no module in the glasses) there
-- is none.
-- The objects are made once when the HUD appears and then only changed
-- (their set<Field> methods; one update sends the changed fields): drawing
-- everything again on each change made it blink (owner 2026-10-18).
local D = require("pda.drone")

local H = {}

-- Minecraft's chat colours (0xRRGGBB; opacity is separate): bright, made
-- for a dark background; the kit's screen palette was too dim over the band
H.COLORS = {text = 0xFFFFFF, muted = 0xBBBBBB, ok = 0x55FF55, warn = 0xFFFF55, bad = 0xFF5555,
    info = 0x55FFFF, extra = 0xFF55FF, accent = 0x55FFFF, band = 0x0B0C10}
H.X, H.Y, H.LINE, H.CHAR = 4, 4, 10, 6    -- GUI units: the top-left corner (owner: as high as it goes), line height, about one character
H.BAND = 0.85                             -- the band behind the text: dark and nearly solid (owner)
H.NEAR = 24                               -- blocks from the drone that count as aboard, standing still
H.LAG = 4                                 -- seconds the drone's position can be old (poll + rednet, at TPS 10 two or three): it flew on
H.HIDE_AFTER = 3                          -- seconds of "not flying" in a row before the HUD goes

-- The Overlay Module's functions: the glasses' peripheral hands each module
-- out by name (getModule("overlay")); they are not on the peripheral itself.
function H.overlay(glasses)
    if type(glasses) ~= "table" then return nil end
    if type(glasses.createText) == "function" then return glasses end
    if type(glasses.getModule) ~= "function" then return nil end
    for _, name in ipairs({"overlay", "advancedperipherals:overlay"}) do
        local ok, m = pcall(glasses.getModule, name)
        if ok and type(m) == "table" and type(m.createText) == "function" then return m end
    end
    return nil
end

function H.new(glasses)
    local g = H.overlay(glasses)
    if not g then return nil end
    pcall(g.setAutoUpdate, false)
    pcall(g.clear)
    pcall(g.update)
    return {g = g, shown = nil}
end

-- The layout (owner 2026-10-24, from the approved mock): a table in fixed
-- GUI units, text at H.FONT (fontSize), so nothing moves as the numbers
-- change (the mod animates every move: text sliding each second looked like
-- blinking). Rows: the activity on a pill in its colour, where to, and the
-- key hint's switch ([8] hint off / ON, always); HEIGHT | SPEED | HEADING over
-- their values; while the hint is on, MOVE | ACTIONS | MORE
-- with the keys as caps (a held one green); a warning last.
H.FONT = 1.25
H.CW, H.LH = 6 * H.FONT, 10 * H.FONT        -- a character's width, a text line
H.ROW = H.LH + 5                            -- a table row
H.W = 320                                   -- the table's width
H.PAD = 5
H.COLORS.dark, H.COLORS.dim, H.COLORS.grid, H.COLORS.head, H.COLORS.cap =
    0x0A0A0C, 0x787A84, 0x404450, 0x16181E, 0x343844
H.COLS = {0, 107, 214}                      -- the three columns' left edges

-- A colour darkened to `k` of itself. Fills under text are deep shades with
-- white shadowed text on them: dark text without a shadow on the bright
-- colours read blurred at H.FONT (owner 2026-10-26).
function H.shade(c, k)
    local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
    return math.floor(r * k) * 65536 + math.floor(g * k) * 256 + math.floor(b * k)
end
H.FILL = 0.45                               -- a coloured fill's share of its colour
H.COLORS.lit = H.shade(H.COLORS.ok, H.FILL) -- a held key's cap

-- Minecraft yaw -> the side of the world it faces (S 0, W 90, N 180, E -90).
local SIDES8 = {"S", "SW", "W", "NW", "N", "NE", "E", "SE"}
function H.side(hdg)
    if type(hdg) ~= "number" then return "" end
    return SIDES8[math.floor(((hdg % 360) + 22.5) / 45) % 8 + 1]
end

-- The keys table: {caps, label} per cell, by row, the columns MOVE | ACTIONS | MORE.
H.KEYS = {
    {{{"W", "w"}, {"S", "s"}, "speed"}, {{"X", "stop"}, "brake"}, {{"9", "power"}, "motors"}},
    {{{"A", "a"}, {"D", "d"}, "turn"}, {{"H", "hold"}, "hover"}, {{"4", "face_left"}, {"6", "face_right"}, "N E S W"}},
    {{{"<", "left"}, {">", "right"}, "slide"}, {{"L", "land"}, "land"}, {{"7", "zero"}, "speed 0"}},
}
-- the last row, across the whole table
H.KEYS_WIDE = {{"Space", "space"}, {"Shift", "shift"}, "up / down"}

local function cut(text, n)
    text = tostring(text or "")
    if #text <= n then return text end
    return text:sub(1, math.max(0, n - 2)) .. ".."
end

-- The objects for a drone model ({{id, kind, props}, ...} in drawing order),
-- `keys` = nil or {held = {name = true}} (the keyboard flies the drone) and
-- `on` = the keyboard switch. Positions are offsets from H.X, H.Y.
function H.scene(m, keys)
    local C, CW, ROW, PAD = H.COLORS, H.CW, H.ROW, H.PAD
    local out = {}
    local function rect(id, x, y, w, h, color, opacity, z)
        out[#out + 1] = {id, "rect", {x = x + w / 2, y = y + h / 2, sizeX = w, sizeY = h, color = color, opacity = opacity or 1, z = z or -1}}
    end
    local function txt(id, x, y, content, color, shadow)
        out[#out + 1] = {id, "text", {content = content, x = x, y = y, color = color, shadow = shadow ~= false}}
    end
    local s = m.status
    local held = keys and keys.held or {}
    local on = s and s.keys_on == true
    local link, age = D.link(m)
    local warn
    if not D.configured(m) then warn = "not set up"
    elseif not s then warn = "no link"
    elseif link ~= "ok" then warn = ("no answer %ds"):format(math.floor(age or 0))
    elseif s.warn then warn = tostring(s.warn) end
    local rows = 3 + (keys and 5 or 0) + (warn and 1 or 0)
    local W, Hh = H.W, rows * ROW + 2
    local act = C[s and s.activity_color or "muted"] or C.accent
    rect("band", 0, 0, W, Hh, C.band, H.BAND, -3)
    rect("edge", 0, 0, 2, Hh, act, 1, -2)
    -- 1. the pill, where to, the keyboard switch
    rect("head1", 2, 0, W - 2, ROW, C.head, 0.9, -2)
    local word = s and (s.activity or tostring(s.mode)) or "DRONE"
    local pill = #word * CW + 7
    rect("pill", PAD, 2, pill, ROW - 4, H.shade(act, H.FILL), 1, -1)
    txt("act", PAD + 3.5, 3.5, word, C.text)
    local kx = W - 12 * CW
    local dx = PAD + pill + 6
    txt("detail", dx, 3.5, cut(s and s.detail, math.floor((kx - dx) / CW) - 1), C.muted)
    rect("cap8", kx, 2.5, CW + 5, H.LH + 1, held.keys and C.lit or C.cap, 1, -1)
    txt("key8", kx + 2.5, 3.5, "8", C.text)
    txt("keys", kx + CW + 9, 3.5, on and "hint ON" or "hint off", on and C.ok or C.dim)
    -- 2. the numbers
    local y = ROW
    rect("rule1", 2, y, W - 2, 1, C.grid, 1, -1)
    local heads = {"HEIGHT", "SPEED", "HEADING"}
    local up = s and s.above and ("+%d up"):format(math.max(0, s.above)) or ""
    local vals = {{s and s.height and tostring(s.height) or "--", up, C.muted},
        {s and s.speed and tostring(s.speed) or "--", "b/s", C.muted},
        {s and s.hdg and tostring(s.hdg) or "--", H.side(s and s.hdg), C.info}}
    for i = 1, 3 do
        local cx = H.COLS[i] + PAD + 2
        txt("h" .. i, cx, y + 3.5, heads[i], C.dim)
        txt("v" .. i, cx, y + ROW + 3.5, vals[i][1], C.text)
        txt("u" .. i, cx + 5 * CW, y + ROW + 3.5, vals[i][2], vals[i][3])
        if i > 1 then rect("vs" .. i, H.COLS[i], y + 2, 1, 2 * ROW - 2, C.grid, 1, -1) end
    end
    y = y + 2 * ROW
    -- 3. the keys, while the keyboard flies the drone
    if keys then
        rect("rule2", 2, y, W - 2, 1, C.grid, 1, -1)
        rect("head2", 2, y + 1, W - 2, ROW - 1, C.head, 0.9, -2)
        for i, h in ipairs({"MOVE", "ACTIONS", "MORE"}) do txt("kh" .. i, H.COLS[i] + PAD + 2, y + 3.5, h, C.dim) end
        y = y + ROW
        -- one cell: its caps then its label, from `left` (centred in `width` when given)
        local function cell_at(id, cell, left, width)
            local caps, label = {}, nil
            for _, x in ipairs(cell) do if type(x) == "table" then caps[#caps + 1] = x else label = x end end
            local total = 0
            for _, capd in ipairs(caps) do total = total + #capd[1] * CW + 5 + 2 end
            if label then total = total + 2 + #label * CW end
            local x = width and left + (width - total) / 2 or left
            for k, capd in ipairs(caps) do
                local w = #capd[1] * CW + 5
                local lit = held[capd[2]]
                rect("c" .. id .. k, x, y + 2.5, w, H.LH + 1, lit and C.lit or C.cap, 1, -1)
                txt("t" .. id .. k, x + 2.5, y + 3.5, capd[1], C.text)
                x = x + w + 2
            end
            if label then txt("l" .. id, x + 2, y + 3.5, label, C.muted) end
        end
        for r, row in ipairs(H.KEYS) do
            rect("kr" .. r, 2, y, W - 2, 1, C.grid, 1, -1)
            for c, cell in ipairs(row) do cell_at(("k%d%d"):format(r, c), cell, H.COLS[c] + PAD + 2) end
            y = y + ROW
        end
        for i = 2, 3 do rect("ks" .. i, H.COLS[i], y - 4 * ROW + 1, 1, 4 * ROW - 1, C.grid, 1, -1) end
        rect("kr4", 2, y, W - 2, 1, C.grid, 1, -1)
        cell_at("kw", H.KEYS_WIDE, 2, W - 2)   -- the one row centred (owner)
        y = y + ROW
    end
    -- 4. a warning
    if warn then
        rect("rule3", 2, y, W - 2, 1, C.grid, 1, -1)
        rect("warnbg", 2, y + 1, W - 2, ROW - 1, 0x3C0A0A, 0.7, -2)
        txt("warn", PAD + 2, y + 3.5, cut("! " .. warn, math.floor((W - 2 * PAD) / CW)), C.bad)
    end
    return out
end

-- Is the owner flying: the drone in the air, the owner's eyes near it.
function H.flying(h, m)
    local s = m.status
    if not s then return false end
    if D.link(m) ~= "ok" then return h.flying == true end   -- lost in flight: keep saying so
    if s.mode == "STANDBY" or s.activity == "ON THE GROUND" then return false end
    local ok, ex, ey, ez = pcall(h.g.getEyePosition)
    if ok and type(ex) == "number" and type(s.pos) == "table" and s.pos.x then
        -- the position is seconds old: at 190 b/s the drone is hundreds of
        -- blocks past it, with the owner aboard (the HUD blinked in fast flight)
        -- shown already: three times the radius before it counts as off (no flapping at the edge)
        local dx, dy, dz = ex - s.pos.x, ey - s.pos.y, ez - s.pos.z
        local near = (h.flying and 3 or 1) * H.NEAR + (tonumber(s.speed) or 0) * H.LAG
        return dx * dx + dy * dy + dz * dz <= near * near
    end
    return true   -- where the owner is cannot be told: show it
end

-- Where the owner stands (feet, from the eyes), or nil without the Overlay Module.
H.EYES = 1.62
function H.feet(h)
    if not h then return nil end
    local ok, x, y, z = pcall(h.g.getEyePosition)
    if not (ok and type(x) == "number") then return nil end
    return {x = x, y = y - H.EYES, z = z}
end

function H.clear(h)
    if h then pcall(h.g.clear); pcall(h.g.update); h.pool, h.shown = nil, nil end
end

-- obj.set<Field>(v) when the value changed (cache in obj's slot).
local function set(slot, field, v)
    if slot.v[field] == v then return end
    slot.v[field] = v
    local f = slot.obj["set" .. field:sub(1, 1):upper() .. field:sub(2)]
    if f then f(v) end
end

local function make(g, kind, props)
    local obj = kind == "rect" and g.createRectangle(props) or g.createText(props)
    local v = {}
    for k, x in pairs(props) do v[k] = x end
    return {obj = obj, v = v}
end

-- `keys`: the keyboard flies the drone now ({held = {name = true}}): the
-- HUD shows, flying or not, with the keys under the status.
function H.draw(h, m, keys)
    if not h then return end
    -- shown at once; gone only after H.HIDE_AFTER s of "not flying" in a row:
    -- one late status hid and rebuilt the HUD (a blink)
    local now = m.deps.clock()
    if H.flying(h, m) then h.flying, h.off_since = true, nil
    elseif h.flying then
        h.off_since = h.off_since or now
        if now - h.off_since >= H.HIDE_AFTER then h.flying, h.off_since = false, nil end
    end
    local scene = (h.flying or keys) and H.scene(m, keys) or {}
    local parts = {}
    for _, o in ipairs(scene) do
        parts[#parts + 1] = o[1]
        for _, f in ipairs({"content", "x", "y", "sizeX", "sizeY", "color", "opacity"}) do parts[#parts + 1] = tostring(o[3][f]) end
    end
    local k = table.concat(parts, "\1")
    if k == h.shown then return end
    h.shown = k
    local g = h.g
    local ok, err = pcall(function()
        if #scene == 0 then   -- not flying: nothing on the screen
            if h.pool then g.clear(); g.update(); h.pool = nil end
            return
        end
        if not h.pool then
            g.clear()
            h.pool = {slots = {}}
        end
        local used = {}
        for _, o in ipairs(scene) do
            local id, kind, props = o[1], o[2], o[3]
            used[id] = true
            local p = {}
            for f, v in pairs(props) do p[f] = v end
            p.x, p.y = H.X + p.x, H.Y + p.y
            local slot = h.pool.slots[id]
            if slot and slot.kind ~= kind then slot = nil end
            if not slot then
                p.gui = true
                if kind == "text" then p.z, p.opacity, p.fontSize = 1, 1, H.FONT end
                h.pool.slots[id] = make(g, kind, p)
                h.pool.slots[id].kind = kind
                if kind == "rect" and not h.pool.flushed then
                    -- the mod flushes a rectangle together with the first text
                    -- drawn after it, rectangle last: that text sat under it
                    -- (FLYING / HOLDING almost unreadable). An invisible first
                    -- text takes that turn.
                    h.pool.flushed = true
                    make(g, "text", {content = " ", x = H.X, y = H.Y, z = 1, color = H.COLORS.band, opacity = 0, shadow = false, gui = true})
                end
            else
                for f, v in pairs(p) do if f ~= "gui" and f ~= "z" and f ~= "shadow" then set(slot, f, v) end end
            end
        end
        -- unused objects: blank text, see-through rectangles (kept for when they come back)
        for id, slot in pairs(h.pool.slots) do
            if not used[id] then
                if slot.kind == "text" then set(slot, "content", "") else set(slot, "opacity", 0) end
            end
        end
        g.update()
    end)
    if not ok then h.pool = nil end   -- made again on the next change
    h.err = not ok and tostring(err) or nil   -- shown on the Drone tab
end

return H
