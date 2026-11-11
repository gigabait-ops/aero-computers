-- Quick drone control. The drone's master computer (fc.remote) is asked for
-- its status about once a second and gets the drone tab's buttons over
-- rednet protocol aero.fc.remote.v1, signed with the shared key. Settings:
-- drone.master (the master's computer id) and drone.key. Every message names
-- the route open on the Routes tab (m.show, pda/routes.lua), whose points
-- then come with the status; m.on_status(msg) hears every status.
local D = {}

D.PROTOCOL = "aero.fc.remote.v1"
D.POLL = 0.4      -- seconds between status requests: every 0.5 s tick (owner: speed shown more often)
D.LOST = 4        -- no answer for this long: the link is lost
D.TO_ME = "\0tome" -- the Points list's first row: the drone to where the owner stands
D.ABOVE = 30       -- blocks above the owner it comes to

-- deps: send(id, msg) on D.PROTOCOL; clock(); settings (CC's API).
function D.new(deps)
    local s = deps.settings
    return {deps = deps, master = s and tonumber(s.get("drone.master")), key = s and s.get("drone.key"),
        status = nil, seen = nil, asked = nil, sel = nil, sent = nil}
end

function D.configured(m) return m.master ~= nil and type(m.key) == "string" and #m.key >= 8 end

local function send(m, msg)
    if not D.configured(m) then return end
    msg.key, msg.show = m.key, m.show
    m.deps.send(m.master, msg)
end

-- Ask for the status when the last request is older than D.POLL.
function D.tick(m)
    local now = m.deps.clock()
    if not m.asked or now - m.asked >= D.POLL then
        m.asked = now
        send(m, {type = "poll"})
    end
end

function D.command(m, cmd)
    local msg = {type = "cmd", cmd = cmd}
    if cmd == "fly" then
        if not m.sel then return end
        msg.point = m.sel
    end
    m.sent = {cmd = cmd, point = msg.point, t = m.deps.clock()}
    m.asked = m.deps.clock()
    send(m, msg)
end

function D.pick(m, name) m.sel, m.picked = name, true end

-- Any other command: {type = "cmd", cmd = name} and `fields` (the Routes tab's).
function D.cmd(m, cmd, fields)
    local msg = {type = "cmd", cmd = cmd}
    for k, v in pairs(fields or {}) do msg[k] = v end
    m.sent = {cmd = cmd, t = m.deps.clock()}
    m.asked = m.deps.clock()
    send(m, msg)
end

-- The keys held on the glasses' keyboard (pda/keys.lua), for the master's
-- key bridge; answered with the status like a poll.
function D.keys(m, names)
    m.asked = m.deps.clock()
    send(m, {type = "keys", keys = names})
end

-- The status now (the Routes tab opened a route: its points at once).
function D.ask(m)
    m.asked = m.deps.clock()
    send(m, {type = "poll"})
end

-- The drone to the owner (Points' "To me" row, FLY): where he stands
-- (`here`, {x, y, z} from the glasses) and D.ABOVE blocks higher, a one-off
-- goto. False and why without a position.
function D.to_me(m, here)
    if not here then return false, "no position (Overlay Module)" end
    return D.go_to(m, ("%.1f %.1f %.1f"):format(here.x, here.y + D.ABOVE, here.z))
end

-- A saved point changed (EDIT on the Points tab): its name and the edited
-- line "Name x y z [hdg]"; the master checks and saves it.
function D.wp_edit(m, name, text)
    m.sent = {cmd = "wp_edit", point = name, t = m.deps.clock()}
    m.asked = m.deps.clock()
    send(m, {type = "cmd", cmd = "wp_edit", point = name, text = tostring(text or "")})
end

-- A new point (NEW on the Points tab): "Name x y z [hdg]"; with a name alone
-- `here` ({x, y, z}: where the owner stands) gives the place. False and why
-- when there is no place to give.
-- A side of the world typed after a name ("Base N"): the dock's heading
-- (Minecraft yaw: S 0, W 90, N 180, E -90; owner 2026-10-24: the glasses
-- cannot tell which way the owner looks, AP's getOwner fails on Aero).
D.SIDES = {n = 180, e = -90, s = 0, w = 90}
function D.side(word) return word and D.SIDES[tostring(word):lower()] end

function D.wp_add(m, text, here)
    local w = {}
    for word in tostring(text or ""):gmatch("%S+") do w[#w + 1] = word end
    if #w == 0 then return false, "type a name" end
    if #w == 1 or (#w == 2 and D.side(w[2])) then
        if not here then return false, "no position: type Name x y z" end
        text = ("%s %.1f %.1f %.1f"):format(w[1], here.x, here.y, here.z)
        if w[2] then text = text .. " " .. D.side(w[2]) end   -- here, facing that side: a dock
    elseif #w < 4 then
        return false, "Name x y z, or a name alone"
    end
    m.sent = {cmd = "wp_add", t = m.deps.clock()}
    m.asked = m.deps.clock()
    send(m, {type = "cmd", cmd = "wp_add", text = text})
    return true
end

-- Typed coordinates ("x z" or "x y z", commas allowed): a one-off goto, not
-- saved. False and why when the text is not two or three numbers.
function D.go_to(m, text)
    local n = {}
    for w in tostring(text or ""):gsub(",", " "):gmatch("%S+") do n[#n + 1] = tonumber(w) or false end
    if not ((#n == 2 or #n == 3) and n[1] and n[2] and n[#n]) then return false, "type x z or x y z" end
    local x, y, z = n[1], #n == 3 and n[2] or nil, n[#n]
    m.sent = {cmd = "goto", t = m.deps.clock()}
    m.asked = m.deps.clock()
    send(m, {type = "cmd", cmd = "goto", x = x, y = y, z = z})
    return true
end

function D.on_message(m, sender, msg)
    if sender ~= m.master or type(msg) ~= "table" or msg.type ~= "status" then return false end
    m.status, m.seen = msg, m.deps.clock()
    local names = {}
    for _, p in ipairs(msg.points or {}) do names[p.name] = true end
    if not (m.sel == D.TO_ME or (m.sel and names[m.sel])) then m.sel = msg.points and msg.points[1] and msg.points[1].name or nil end
    if m.on_status then m.on_status(msg) end
    return true
end

-- "ok" with the status age, "lost" with the time since the last answer, or "never".
function D.link(m)
    if not m.seen then return "never" end
    local age = m.deps.clock() - m.seen
    return age <= D.LOST and "ok" or "lost", age
end

return D
