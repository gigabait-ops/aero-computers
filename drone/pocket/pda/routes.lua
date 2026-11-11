-- The Routes tab: the drone's routes and one of them open with its points.
-- What it shows comes with the master's status (routes, flying, open: see
-- fc.cmd.remote); every change is a command to the master, which checks and
-- saves it and answers with the status. Deleting asks here first: a second
-- press within Rs.SURE s sends it.
--
-- m = {d (the drone model, pda/drone.lua), sel (route name), open (route
-- name), pt (point index), confirm, edit, top (the list's scroll)}
local D = require("pda.drone")

local Rs = {}

Rs.SURE = 10

function Rs.new(drone)
    local m = {d = drone, sel = nil, open = nil, pt = 1, confirm = nil, top = 1}
    drone.on_status = function() Rs.on_status(m) end
    return m
end

local function now(m) return m.d.deps.clock() end
local function cmd(m, name, fields) D.cmd(m.d, name, fields) end

local function words(text)
    local w = {}
    for word in tostring(text or ""):gmatch("%S+") do w[#w + 1] = word end
    return w
end

-- The routes ({name, n, tail}), the one flying ({name, i, lap}) and the
-- open one ({name, laps, finish, points = {{name, text, summary}}}) once
-- its points have come.
function Rs.list(m) return m.d.status and m.d.status.routes or {} end
function Rs.flying(m) return m.d.status and m.d.status.flying end
function Rs.opened(m)
    local o = m.d.status and m.d.status.open
    if o and m.open and o.name == m.open then return o end
    return nil
end

function Rs.point(m)
    local o = Rs.opened(m)
    return o and o.points[m.pt]
end

-- A status came: a route gone from the master closes, the picks stay in range.
function Rs.on_status(m)
    local list = Rs.list(m)
    local names = {}
    for _, r in ipairs(list) do names[r.name] = true end
    if m.open and not names[m.open] then Rs.back(m) end
    -- NEW: the new route (the master adds it last) gets picked when it comes
    if m.added and #list > m.added.n then m.sel, m.picked, m.added = list[#list].name, true, nil
    elseif m.added and now(m) - m.added.t > 3 then m.added = nil end
    if not (m.sel and names[m.sel]) then m.sel = list[1] and list[1].name or nil end
    local o = Rs.opened(m)
    if o then m.pt = math.max(1, math.min(m.pt or 1, #o.points)) end
    if m.confirm and now(m) > m.confirm.until_t then m.confirm = nil end
end

function Rs.pick(m, name) m.sel, m.picked = name, true end
function Rs.pick_point(m, i) if tonumber(i) then m.pt, m.picked = tonumber(i), true end end

-- OPEN: the route's page; its points come with the next status (asked now).
function Rs.open(m, name)
    name = name or m.sel
    if not name then return false end
    m.open, m.sel, m.pt, m.top, m.confirm = name, name, 1, 1, nil
    m.d.show = name
    D.ask(m.d)
    return true
end

function Rs.back(m)
    m.open, m.top, m.confirm = nil, 1, nil
    m.d.show = nil
end

-- FLY: on the list from the first point, on a route's page from the picked one.
function Rs.fly(m)
    if m.open then cmd(m, "route_fly", {route = m.open, from = m.pt})
    elseif m.sel then cmd(m, "route_fly", {route = m.sel, from = 1}) end
end

function Rs.new_route(m, text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false, "type a name" end
    m.added = {n = #Rs.list(m), t = now(m)}
    cmd(m, "route_new", {text = text})
    return true
end

-- What DEL deletes: the picked point on a route's page, the picked route on the list.
local function doomed(m)
    if m.open then
        local pt = Rs.point(m)
        return pt and (m.open .. "#" .. m.pt .. " " .. pt.name), pt
    end
    return m.sel
end

-- Whether DEL asks now (SURE?).
function Rs.sure(m)
    local key = doomed(m)
    return m.confirm ~= nil and key ~= nil and m.confirm.key == key and now(m) <= m.confirm.until_t
end

function Rs.delete(m)
    local key, pt = doomed(m)
    if not key then return end
    if not Rs.sure(m) then m.confirm = {key = key, until_t = now(m) + Rs.SURE}; return end
    m.confirm = nil
    if m.open then cmd(m, "pt_del", {route = m.open, index = m.pt, point = pt.name})
    else cmd(m, "route_del", {route = m.sel}) end
end

function Rs.laps(m, dir) if m.open then cmd(m, "route_laps", {route = m.open, dir = dir}) end end
function Rs.finish(m) if m.open then cmd(m, "route_finish", {route = m.open}) end end

-- A point's line as typed: "Name [x y z [hdg]] [h180] [s100] [w30]
-- [stop|pass|land|dock]". A name alone (options or not) is the saved point
-- of that name, or else where the owner stands (`here`, {x, y, z}); a side
-- after the name ("Name N") makes it a dock facing that way. The
-- line to send, or nil and why.
function Rs.with_place(m, text, here)
    local w = words(text)
    if #w == 0 then return nil, "type a name" end
    if #w >= 4 and tonumber(w[2]) and tonumber(w[3]) and tonumber(w[4]) then return table.concat(w, " ") end
    for _, p in ipairs(m.d.status and m.d.status.points or {}) do
        if p.name:lower() == w[1]:lower() then return table.concat(w, " ") end
    end
    if tonumber(w[2]) then return nil, "Name x y z, or a name alone" end
    if not here then return nil, "no position: type Name x y z" end
    local hdg = D.side(w[2])
    if hdg then table.remove(w, 2) end   -- "Name N": here, facing north, a dock
    table.insert(w, 2, ("%.1f %.1f %.1f"):format(here.x, here.y, here.z) .. (hdg and (" " .. hdg) or ""))
    return table.concat(w, " ")
end

-- NEW on a route's page: after the picked point (the first on an empty route).
function Rs.point_add(m, text, here)
    if not m.open then return false, "no route open" end
    local line, err = Rs.with_place(m, text, here)
    if not line then return false, err end
    local o = Rs.opened(m)
    local after = (o and #o.points > 0) and m.pt or 0
    cmd(m, "pt_add", {route = m.open, after = after, text = line})
    m.pt, m.picked = after + 1, true
    return true
end

-- EDIT: the picked point's line changed (`index`, `name`: the point it was
-- opened for).
function Rs.point_edit(m, index, name, text, here)
    if not m.open then return false, "no route open" end
    local line, err = Rs.with_place(m, text, here)
    if not line then return false, err end
    cmd(m, "pt_edit", {route = m.open, index = index, point = name, text = line})
    return true
end

-- The arrows: the picked point one place up (-1) or down (+1).
function Rs.move(m, dir)
    local o, pt = Rs.opened(m), Rs.point(m)
    if not (o and pt and o.points[m.pt + dir]) then return end
    cmd(m, "pt_move", {route = m.open, index = m.pt, point = pt.name, dir = dir})
    m.pt, m.picked = m.pt + dir, true
end

return Rs
