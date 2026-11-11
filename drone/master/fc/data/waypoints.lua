-- Waypoints: Home (cfg.home) first, then the saved list (cfg.waypoints). A
-- point saved with a heading is a dock. Every change is saved at once.
local A = require("fc.core.attitude")
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")
local U = require("fc.core.util")

local W = {}

W.DELETE_HOLD = 3   -- s: after a deletion Delete does nothing for this long (fc.ui.actions)

function W.list(ctx)
    local list = {}
    local home = ctx.cfg.home
    if home then list[1] = {name = "Home", x = home.x, y = home.y, z = home.z, hdg = home.hdg, home = true} end
    for _, wp in ipairs(ctx.cfg.waypoints) do
        list[#list + 1] = {name = wp.name, x = wp.x, y = wp.y, z = wp.z, hdg = wp.hdg}
    end
    return list
end

-- The list with each point's distance from the ship (the screens).
function W.rows(ctx)
    local rows = W.list(ctx)
    local pos = ctx.state and ctx.state.pos
    if pos then
        for _, wp in ipairs(rows) do wp.dist = math.sqrt((wp.x - pos.x) ^ 2 + (wp.z - pos.z) ^ 2) end
    end
    return rows
end

-- A point by its number or its name (any case); nil when there is none.
function W.index(ctx, key)
    local list = W.list(ctx)
    local n = tonumber(key)
    if n and list[n] then return n end
    key = tostring(key or ""):lower()
    for i, wp in ipairs(list) do if wp.name:lower() == key then return i end end
    return nil
end

function W.clamp_sel(ctx)
    local n = #W.list(ctx)
    if ctx.wp_sel > n then ctx.wp_sel = n end
    if ctx.wp_sel < 1 then ctx.wp_sel = 1 end
end

-- Point names start with a capital letter (owner, 2026-10-15).
function W.capital(name)
    name = tostring(name or "")
    return name:sub(1, 1):upper() .. name:sub(2)
end

-- Home at x y z [hdg] (numbers), or where the ship is, facing its heading.
-- The `home set` command, and NEW with the name Home.
function W.set_home_at(ctx, x, y, z, hdg)
    if not x and ctx.state and ctx.state.pos then
        x, y, z, hdg = ctx.state.pos.x, ctx.state.pos.y, ctx.state.pos.z, ctx.state.heading
    end
    if not (x and y and z) then Cx.log(ctx, "home refused: usage home set [x y z [heading]]"); return false end
    ctx.cfg.home = {x = x, y = y, z = z, hdg = hdg and A.wrap180(hdg) or nil}
    Cx.log(ctx, ("home set to (%.1f, %.1f, %.1f)%s"):format(x, y, z, hdg and (" facing %.1f (dock)"):format(hdg) or ""))
    C.save(Cx.CONFIG_PATH, ctx.cfg)
    return true
end

-- Add (or replace, by name) a waypoint; no coordinates = the current
-- position AND heading (a dock: the ship comes back facing the same way).
function W.add(ctx, name, x, y, z, hdg)
    name = W.capital(tostring(name or ""):sub(1, 12))
    if name == "" then ctx.notice = "waypoint needs a name"; return false end
    if name:lower() == "home" then
        ctx.resume_done = true   -- the owner is here: no auto-resume after this
        if x ~= nil then W.set_home_at(ctx, tonumber(x), tonumber(y), tonumber(z), tonumber(hdg))
        else W.set_home_at(ctx) end
        ctx.wp_sel = 1
        return ctx.cfg.home ~= nil
    end
    if x == nil then
        local st = ctx.state
        if not st or not st.pos then ctx.notice = "no position yet: give x y z"; return false end
        x, y, z, hdg = st.pos.x, st.pos.y, st.pos.z, st.heading
    end
    x, y, z, hdg = tonumber(x), tonumber(y), tonumber(z), tonumber(hdg)
    if not (x and y and z) then ctx.notice = "waypoint: name x y z [heading] (or a name only = here)"; return false end
    local list = ctx.cfg.waypoints
    local at
    for i, wp in ipairs(list) do if wp.name == name then at = i end end
    local r1 = U.tenth
    local entry = {name = name, x = r1(x), y = r1(y), z = r1(z), hdg = hdg and r1(A.wrap180(hdg)) or nil}
    if at then list[at] = entry else list[#list + 1] = entry; at = #list end
    ctx.wp_sel = at + (ctx.cfg.home and 1 or 0)
    return Cx.save(ctx, ("waypoint %s = (%.1f, %.1f, %.1f)%s"):format(name, entry.x, entry.y, entry.z, entry.hdg and (" facing %.1f (dock)"):format(entry.hdg) or ""))
end

-- A saved point as one line to edit: "Name x y z [hdg]".
function W.text(wp)
    local function n(v) return (("%.1f"):format(v):gsub("%.0$", "")) end
    return ("%s %s %s %s%s"):format(wp.name, n(wp.x), n(wp.y), n(wp.z), wp.hdg and (" " .. n(wp.hdg)) or "")
end

-- Change a saved point in place (EDIT on the master's own screen and the
-- glasses' Points tab): a name alone renames it and keeps where it is;
-- Home keeps its name.
function W.update(ctx, index, name, x, y, z, hdg)
    local wp = W.list(ctx)[index]
    if not wp then ctx.notice = "no waypoint selected"; return false end
    if x == nil then x, y, z, hdg = wp.x, wp.y, wp.z, wp.hdg end
    x, y, z, hdg = tonumber(x), tonumber(y), tonumber(z), tonumber(hdg)
    if not (x and y and z) then ctx.notice = "edit: name x y z [heading]"; return false end
    local r1 = U.tenth
    if wp.home then
        ctx.cfg.home = {x = r1(x), y = r1(y), z = r1(z), hdg = hdg and r1(A.wrap180(hdg)) or nil}
        return Cx.save(ctx, ("home = (%.1f, %.1f, %.1f)%s"):format(x, y, z, hdg and (" facing %.1f"):format(hdg) or ""))
    end
    name = W.capital(tostring(name or wp.name):sub(1, 12))
    if name == "" or name:lower() == "home" then ctx.notice = "edit: give the point a name (not Home)"; return false end
    local list, at = ctx.cfg.waypoints, index - (ctx.cfg.home and 1 or 0)
    for i, other in ipairs(list) do
        if i ~= at and other.name == name then ctx.notice = "edit: " .. name .. " is taken"; return false end
    end
    list[at] = {name = name, x = r1(x), y = r1(y), z = r1(z), hdg = hdg and r1(A.wrap180(hdg)) or nil}
    ctx.wp_sel = index
    return Cx.save(ctx, ("waypoint %s%s = (%.1f, %.1f, %.1f)%s"):format(wp.name, name ~= wp.name and (" -> " .. name) or "",
        x, y, z, hdg and (" facing %.1f (dock)"):format(hdg) or ""))
end

-- One typed line ("Name x y z [hdg]") onto the point at `index`.
function W.edit_text(ctx, index, text)
    local w = U.words(text)
    if not w then ctx.notice = "edit: name x y z [heading]"; return false end
    return W.update(ctx, index, w[1], w[2], w[3], w[4], w[5])
end

-- Delete asks first: a second press within 10 s deletes.
function W.delete(ctx, index)
    local wp = W.list(ctx)[index]
    if not wp then ctx.notice = "no waypoint selected"; return false end
    if wp.home then ctx.notice = "home cannot be deleted (type `home` to move it)"; return false end
    local now = Cx.now(ctx)
    local c = ctx.confirm
    if not (c and c.action == "wp_delete" and c.name == wp.name and now <= c.until_t) then
        ctx.confirm = {action = "wp_delete", name = wp.name, until_t = now + 10}
        ctx.notice = ("Delete %s? press Delete again within 10 s"):format(wp.name)
        return false
    end
    ctx.confirm = nil
    ctx.delete_hold = now + W.DELETE_HOLD
    table.remove(ctx.cfg.waypoints, index - (ctx.cfg.home and 1 or 0))
    W.clamp_sel(ctx)
    return Cx.save(ctx, "waypoint " .. wp.name .. " deleted")
end

-- A saved point becomes Home.
function W.set_home(ctx, index)
    local wp = W.list(ctx)[index]
    if not wp then ctx.notice = "no waypoint selected"; return false end
    ctx.cfg.home = {x = wp.x, y = wp.y, z = wp.z, hdg = wp.hdg}
    return Cx.save(ctx, ("home = %s (%.0f, %.0f, %.0f)%s"):format(wp.name, wp.x, wp.y, wp.z, wp.hdg and (" facing %.0f"):format(wp.hdg) or ""))
end

return W
