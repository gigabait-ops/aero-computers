-- The kit's actions on the tabs (button ids, list touches, prompts) ->
-- the teleport, drone and routes models (state = {tp = ..., drone = ..., routes = ...}).
local T = require("pda.teleports")
local D = require("pda.drone")
local Rs = require("pda.routes")
local Hud = require("pda.hud")

local A = {}

local DRONE = {fly = true, power = true, stop = true, hold = true, face_n = true, face_e = true, face_s = true, face_w = true}
local prompts = 0

local function prompt(id, title, text)
    prompts = prompts + 1
    return {id = id, n = prompts, title = title, prompt = text}
end

-- A setting kept over restarts (the CC settings API).
local function save(key, value)
    local api = rawget(_G, "settings")
    if not api then return end
    api.set(key, value)
    api.save()
end

-- The Routes tab's buttons; any but DEL drops a DEL waiting for SURE?.
local POINT_LINE = "Name [x y z [hdg]] h180 s100 w30 pass|land|dock"
local ROUTES = {
    rt_fly = Rs.fly,
    rt_open = function(m) Rs.open(m) end,
    rt_back = Rs.back,
    rt_new = function(m) m.edit = prompt("rtnew", "New route", "Its name") end,
    rt_del = Rs.delete,
    rt_laps_dec = function(m) Rs.laps(m, -1) end,
    rt_laps_inc = function(m) Rs.laps(m, 1) end,
    rt_finish = Rs.finish,
    pt_new = function(m) if m.open then m.edit = prompt("ptnew", "New point", POINT_LINE .. "; Name = here, Name N/E/S/W = dock here") end end,
    pt_edit = function(m)
        local pt = Rs.point(m)
        if not pt then return end
        m.edit = prompt("ptedit", ("Point %d"):format(m.pt), POINT_LINE)
        m.edit.value, m.edit.index, m.edit.point = pt.text, m.pt, pt.name
    end,
    pt_up = function(m) Rs.move(m, -1) end,
    pt_down = function(m) Rs.move(m, 1) end,
}

-- A typed route or point: sent, or asked again saying why.
local function routes_prompt(st, id, action)
    local m = st.routes
    if action.type == "cancel" then m.edit = nil; return end
    if action.type ~= "submit" then return end
    local ok, err
    if id:match("^rtnew") then ok, err = Rs.new_route(m, action.value)
    elseif id:match("^ptnew") then ok, err = Rs.point_add(m, action.value, Hud.feet(st.hud))
    else
        local ed = m.edit or {}
        ok, err = Rs.point_edit(m, ed.index, ed.point, action.value, Hud.feet(st.hud))
    end
    if ok then m.edit = nil
    else
        local again = prompt(id:match("^(%a+)"), m.edit and m.edit.title or "Route", err)
        if m.edit then again.index, again.point = m.edit.index, m.edit.point end
        again.value = action.value
        m.edit = again
    end
end

function A.on_action(action, st)
    local id = tostring(action.id or "")
    if id == "drone_view" and action.type == "change" then
        st.dview = action.value
        save("pda.drone_view", action.value)
    elseif id == "set_toggle" and action.type == "change" then
        save(action.value, not require("pda.pages").on(action.value))
    elseif id == "tp_list" and action.type == "change" then T.pick(st.tp, action.value)
    elseif id == "keys_toggle" and action.type == "change" then
        require("pda.keys").toggle(st.drone)
    elseif id == "rt_list" and action.type == "change" then Rs.pick(st.routes, action.value); st.routes.confirm = nil
    elseif id == "pt_list" and action.type == "change" then Rs.pick_point(st.routes, action.value); st.routes.confirm = nil
    elseif id == "rt_title" and action.type == "change" then Rs.back(st.routes)
    elseif id:match("^rtnew%d+$") or id:match("^ptnew%d+$") or id:match("^ptedit%d+$") then routes_prompt(st, id, action)
    elseif ROUTES[id] and action.type == "activate" then
        if id ~= "rt_del" then st.routes.confirm = nil end
        ROUTES[id](st.routes)
    elseif id == "wp_list" and action.type == "change" then
        D.pick(st.drone, action.value)
    elseif id:match("^goto%d+$") then
        if action.type == "cancel" then st.drone.edit = nil
        elseif action.type == "submit" then
            local ok, err = D.go_to(st.drone, action.value)
            st.drone.edit = not ok and prompt("goto", "Go to", err) or nil   -- wrong: asked again, saying why
        end
    elseif id:match("^info%d+$") then
        if action.type == "submit" or action.type == "cancel" then st.drone.edit = nil end
    elseif id:match("^wpnew%d+$") then
        if action.type == "cancel" then st.drone.edit = nil
        elseif action.type == "submit" then
            local ok, err = D.wp_add(st.drone, action.value, Hud.feet(st.hud))
            st.drone.edit = not ok and prompt("wpnew", "New point", err) or nil   -- wrong: asked again, saying why
        end
    elseif id:match("^wpedit%d+$") then
        if action.type == "cancel" then st.drone.edit = nil
        elseif action.type == "submit" then
            D.wp_edit(st.drone, st.drone.edit and st.drone.edit.point, action.value)
            st.drone.edit = nil
        end
    elseif id:match("^edit%d+$") then
        if action.type == "submit" then T.add(st.tp, action.value) end
        if action.type == "submit" or action.type == "cancel" then st.tp.edit = nil end
    elseif action.type == "activate" then
        if id == "tp_go" then T.go(st.tp)
        elseif id == "tp_new" then st.tp.edit = prompt("edit", "New pad", "Its name: A-Z 0-9 _ -")
        elseif id == "tp_del" then T.delete(st.tp)
        elseif id == "go_to" then st.drone.edit = prompt("goto", "Go to", "x z  or  x y z (not saved)")
        elseif id == "wp_new" then
            st.drone.edit = prompt("wpnew", "New point", "Name x y z, or Name = here, Name N/E/S/W = dock here")
        elseif id == "wp_edit" then
            -- the picked point's saved line in the prompt, to change and send
            local m, pt = st.drone, nil
            for _, x in ipairs(m.status and m.status.points or {}) do
                if x.name == m.sel then pt = x end
            end
            if pt and pt.name ~= D.TO_ME then
                m.edit = prompt("wpedit", "Edit " .. pt.name, "Name x y z [hdg]: change, Enter")
                m.edit.value, m.edit.point = pt.text, pt.name
            end
        elseif id == "fly" and st.drone.sel == D.TO_ME then
            local ok, err = D.to_me(st.drone, Hud.feet(st.hud))
            if not ok then st.drone.edit = prompt("info", "To me", err) end
        elseif DRONE[id] then D.command(st.drone, id) end
    end
end

return A
