-- Operator commands: one line per command from /fc_cmd (tools/cmd.sh), e.g.
-- `goto x y z`, `set speed.max 80`, `link gear down`. The power key and the
-- screens' buttons send some of these too (arm, disarm, land, hold).
local K = require("fc.flight.controller")
local Nv = require("fc.flight.nav")
local T = require("fc.flight.tasks")
local Mn = require("fc.flight.manual")
local Tr = require("fc.flight.trim")
local C = require("fc.core.config")
local Cx = require("fc.core.ctx")
local U = require("fc.core.util")
local Nd = require("fc.hw.nodes")
local R = require("fc.hw.rlinks")
local W = require("fc.data.waypoints")
local Rt = require("fc.data.routes")
local Ro = require("fc.flight.route")

local Op = {}

-- "goto 1 2 3" -> {"goto", "1", "2", "3"}; nil for a blank line.
Op.parse = U.words

function Op.quit(ctx)
    T.abort_task(ctx, "quit")
    if ctx.k.mode ~= "STANDBY" then Tr.keep(ctx) end
    K.disarm(ctx.k)
    Nd.send(ctx, K.idle_action(ctx.k))
    ctx.running = false
    Cx.log(ctx, "quit")
end

local OPS = {}

local function refused(ctx, op, err) Cx.log(ctx, op .. " refused: " .. tostring(err)) end

OPS.nodes = function(ctx)
    for _, line in ipairs(Nd.lines(ctx)) do Cx.log(ctx, "nodes: " .. line) end
end

OPS.arm = function(ctx)
    if ctx.task then return refused(ctx, "arm", "task running") end
    if ctx.k.mode ~= "STANDBY" then return Cx.log(ctx, "arm: already " .. ctx.k.mode) end
    local ok, err = K.arm(ctx.k, ctx.state)
    if ok then R.start_engine(ctx) end
    if not ok then ctx.notice = "cannot arm: " .. tostring(err); return Cx.log(ctx, ctx.notice) end
    ctx.notice = nil
    Mn.reset(ctx)
    if ctx.state.pos and ctx.state.vel and math.abs(ctx.state.vel.y) < 0.05 and not ctx.ground_y then ctx.ground_y = ctx.state.pos.y end
    Cx.log(ctx, ("armed: alt_sp %.1f hdg_sp %.1f"):format(ctx.k.alt_sp or 0, ctx.k.hdg_sp or 0))
end

OPS.disarm = function(ctx, words, op)
    T.abort_task(ctx, op)
    K.disarm(ctx.k)
    ctx.notice = nil
    Cx.log(ctx, op == "idle" and "idle: zeroing all motors" or "disarmed")
end
OPS.idle = OPS.disarm

OPS.rehold = function(ctx)
    local ok, err = K.rehold(ctx.k, ctx.state)
    if ok then Mn.reset(ctx) end
    Cx.log(ctx, ok and ("rehold: alt_sp %.1f hdg_sp %.1f"):format(ctx.k.alt_sp or 0, ctx.k.hdg_sp or 0) or ("rehold refused: " .. tostring(err)))
end

-- speed <forward b/s> [side b/s]   manual speed control (0 = brake and hold here)
OPS.speed = function(ctx, words)
    local vf, vr = tonumber(words[2]), tonumber(words[3] or 0)
    if ctx.k.mode ~= "ARMED" then return refused(ctx, "speed", "needs ARMED") end
    if ctx.task and (ctx.task.kind == "hold" or ctx.task.kind == "goto") then
        T.abort_task(ctx, "speed command"); K.rehold(ctx.k, ctx.state)   -- like the keys: take over hold and goto
    end
    if ctx.task then return refused(ctx, "speed", ctx.task.kind .. " running") end
    if not vf or not vr then return refused(ctx, "speed", "usage speed <forward b/s> [side b/s]") end
    ctx.man.v_f = math.max(-Mn.REVERSE_MAX, math.min(Nv.cruise_speed(ctx.cfg, 1e9), vf))
    ctx.man.v_r = math.max(-ctx.cfg.input_side_speed * 2, math.min(ctx.cfg.input_side_speed * 2, vr))
    Cx.log(ctx, ("speed: forward %.1f side %.1f b/s"):format(ctx.man.v_f, ctx.man.v_r))
end

OPS.land = function(ctx, words)
    local ok, err = T.start_land(ctx, words[2])
    if not ok then refused(ctx, "land", err) end
end

OPS["goto"] = function(ctx, words)
    local ok, err = T.start_goto(ctx, words[2], words[3], words[4], words[5])
    if not ok then refused(ctx, "goto", err) end
end

OPS.hold = function(ctx, words)
    local ok, err = T.start_hold(ctx, words[2], words[3])
    if not ok then refused(ctx, "hold", err) end
end

OPS.home = function(ctx, words)
    if words[2] == "set" then
        W.set_home_at(ctx, tonumber(words[3]), tonumber(words[4]), tonumber(words[5]), tonumber(words[6]))
    elseif ctx.cfg.home then
        Mn.fly_to(ctx, W.list(ctx)[1])
    else
        refused(ctx, "home", "no home set")
    end
end

-- set <numeric field, e.g. limits.booster_gain> <number>
OPS.set = function(ctx, words)
    local path, value = words[2] or "", tonumber(words[3])
    local parent, key = ctx.cfg, nil
    for part in path:gmatch("[^.]+") do
        if key ~= nil then parent = parent[key] end
        key = part
        if type(parent) ~= "table" then parent = nil; break end
    end
    local flags = {on = true, ["true"] = true, off = false, ["false"] = false}
    if parent and key ~= nil and type(parent[key]) == "boolean" and flags[words[3]] ~= nil then value = flags[words[3]]   -- a switch: on / off
    elseif not parent or key == nil or value == nil or type(parent[key]) ~= "number" then
        return refused(ctx, "set", "usage set <numeric field, e.g. limits.booster_gain> <number>, or <switch> on|off")
    end
    local old = parent[key]
    parent[key] = value
    local ok, err = C.validate(ctx.cfg)
    if not ok then parent[key] = old; return refused(ctx, "set", err) end
    K.set_gains(ctx.k, ctx.cfg.gains)
    Cx.log(ctx, ("set %s = %s (was %s)"):format(path, tostring(value), tostring(old)))
end

-- link | link clutch|gear on|off|auto
OPS.link = function(ctx, words)
    local name, v = words[2], words[3]
    local r = ctx.rlinks
    if name == nil then
        for _, n in ipairs(R.NAMES) do
            local want = r.want[n]
            Cx.log(ctx, ("link %s: %s%s, sent %s"):format(n, want == nil and "--" or R.word(n, want),
                r.override[n] ~= nil and " (held)" or "", tostring(r.sent[n])))
        end
        return Cx.log(ctx, "link bridge: " .. tostring(ctx.link_bridge or "none"))
    end
    if not (name == "clutch" or name == "gear") then return refused(ctx, "link", "usage link [clutch|gear on|off|auto]") end
    if v == "auto" then
        r.override[name] = nil
        Cx.log(ctx, "link " .. name .. ": automatic")
    elseif v == "on" or v == "off" or v == "down" or v == "up" then
        R.set_by_hand(ctx, name, v == "on" or v == "down")
    else
        refused(ctx, "link", "usage link [clutch|gear on|off|auto]")
    end
end

-- baseline: the hover and trim flown now become what RESET goes back to.
OPS.baseline = function(ctx)
    local tr = ctx.cfg.trim or {}
    ctx.cfg.baseline = {hover = ctx.cfg.hover, trim = {roll = tr.roll or 0, pitch = tr.pitch or 0}}
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    Cx.log(ctx, ("baseline: hover %.1f, trim roll %+.1f pitch %+.1f%s"):format(ctx.cfg.hover, tr.roll or 0, tr.pitch or 0,
        ok and " (saved)" or (" (save failed: " .. tostring(err) .. ")")))
end

-- log on|off: /fc.log for a test session (saved); off = nothing on the disk
OPS.log = function(ctx, words)
    local v = words[2]
    if v ~= "on" and v ~= "off" then return refused(ctx, "log", "usage log on|off") end
    ctx.cfg.log = v == "on"
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    Cx.log(ctx, "logging " .. v .. (ok and " (saved)" or (" (save failed: " .. tostring(err) .. ")")))
end

OPS.save = function(ctx)
    local ok, err = C.save(Cx.CONFIG_PATH, ctx.cfg)
    Cx.log(ctx, ok and ("saved " .. Cx.CONFIG_PATH) or ("save failed: " .. tostring(err)))
end

OPS.abort = function(ctx) T.abort_task(ctx, "operator") end
OPS.quit = function(ctx) Op.quit(ctx) end

-- wp add <name> [x y z [hdg]] | del <name|#> | fly <name|#> | home <name|#> | list
OPS.wp = function(ctx, words)
    local sub = words[2]
    ctx.notice = nil
    if sub == "add" then
        W.add(ctx, words[3], words[4], words[5], words[6], words[7])
    elseif sub == "del" or sub == "fly" or sub == "home" then
        local i = W.index(ctx, words[3])
        if not i then Cx.log(ctx, "wp: unknown point " .. tostring(words[3]))
        elseif sub == "del" then W.delete(ctx, i)
        elseif sub == "home" then W.set_home(ctx, i)
        else Mn.fly_to(ctx, W.list(ctx)[i]) end
    elseif sub == "list" then
        for i, wp in ipairs(W.list(ctx)) do
            Cx.log(ctx, ("wp %d: %s (%.1f, %.1f, %.1f)%s"):format(i, wp.name, wp.x, wp.y, wp.z, wp.hdg and (" dock facing %.1f"):format(wp.hdg) or ""))
        end
    else
        Cx.log(ctx, "wp: usage wp add <name> [x y z [heading]] | del <name> | fly <name> | home <name> | list")
    end
    if ctx.notice then Cx.log(ctx, "wp: " .. ctx.notice) end
end

-- route list | route fly <name> [from point] | route stop
OPS.route = function(ctx, words)
    local sub = words[2]
    if sub == "list" or sub == nil then
        for i, r in ipairs(Rt.list(ctx)) do
            Cx.log(ctx, ("route %d: %s, %d points, %s"):format(i, r.name, #r.points, Rt.tail(r)))
            for j, pt in ipairs(r.points) do Cx.log(ctx, ("  %d %s"):format(j, Rt.point_text(pt))) end
        end
    elseif sub == "fly" then
        if not Ro.start(ctx, words[3], words[4]) then refused(ctx, "route", ctx.notice or "cannot start") end
    elseif sub == "stop" then
        if not Ro.stop(ctx, "operator") then Cx.log(ctx, "route: none flying") end
    else
        Cx.log(ctx, "route: usage route list | fly <name> [from] | stop")
    end
end

-- These fly the ship: a route flying ends first (the owner first).
local STOPS_ROUTE = {arm = true, disarm = true, idle = true, rehold = true, speed = true, land = true, ["goto"] = true,
    hold = true, home = true, abort = true, quit = true}

OPS.__default = function(ctx, words, op)
    Cx.log(ctx, "unknown command: " .. tostring(op))
end

function Op.run(ctx, words)
    ctx.resume_done = true   -- the operator is here: no auto-resume after this
    local op = words[1]
    if STOPS_ROUTE[op] and ctx.route then Ro.stop(ctx, "operator " .. op) end
    local handler = OPS[op] or OPS.__default
    return handler(ctx, words, op)
end

return Op
