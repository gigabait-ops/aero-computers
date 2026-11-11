-- Create redstone links driven through a CC Redstone Link Bridge (peripheral
-- "redstone_link_bridge": sendLinkSignal(item1, item2, strength),
-- getLinkSignal(item1, item2); a frequency is two item ids, "" = empty slot).
--
-- Two outputs:
--   clutch: ON disengages the engine clutch, so no fuel is burnt at idle. The
--           owner's switch (the Engine button), read back from the link at
--           start; the program switches it only at two moments (owner,
--           2026-10-24): engine on for every start (arm, takeoff), engine
--           off once docked at the dock station (not on a plain landing).
--   gear:   ON extends the docking connectors, which are the ship's legs
--           (and dock when a station connector is there): out for every
--           landing (the land and dock tasks, and a manual descent below
--           gear_height), on the ground, and in at takeoff (undocking)
-- `invert = true` in a link's config flips its signal.
--
-- R.want is pure (decided every control cycle); R.apply talks to the bridge
-- from its own coroutine, because every peripheral call waits for a server
-- tick and must not stall the control loop. R.set_by_hand and R.engine_off
-- work on the flight computer's ctx.
local Cx = require("fc.core.ctx")
local G = require("fc.hw.ground")

local R = {}

R.NAMES = {"clutch", "gear"}

function R.new()
    return {
        want = {},       -- name -> true/false (nil = no opinion yet)
        sent = {},       -- name -> last level sent
        sent_t = {},     -- name -> time of the last send
        override = {},   -- name -> true/false set by the operator ("link gear down")
        gear_air = false, -- legs lowered in flight on a manual descent (latched)
    }
end

-- Decide what each link should be. s = {mode, task_kind, on_ground,
-- above (blocks above the remembered ground or nil), vy, now}.
function R.decide(r, cfg, s)
    local gear_h = cfg.gear_height or 10
    local busy = s.mode ~= "STANDBY"
    -- gear: out on the ground and for every landing; in at takeoff (an
    -- armed ship on a dock retracts it to undock) and while flying
    local landing = s.task_kind == "land" or s.task_kind == "dock"   -- the dock task is the final leg
    if busy and s.task_kind ~= "takeoff" and s.above ~= nil and not s.on_ground then
        -- a manual descent below gear_height lowers the legs; climbing away above it raises them
        if s.above <= gear_h and (s.vy or 0) < -0.3 then r.gear_air = true
        elseif s.above > gear_h + 3 then r.gear_air = false end
    else
        r.gear_air = false
    end
    if not busy and s.on_ground then
        r.want.gear = true
    elseif landing or r.gear_air then
        r.want.gear = true
    elseif busy then
        r.want.gear = false
    end
    for name, v in pairs(r.override) do r.want[name] = v end
    return r.want
end

-- At start (and when a bridge is attached): take the clutch's state from the
-- link itself, so the screen shows what the owner left it at.
function R.sync(r, bridge, links)
    local spec = links and links.clutch
    if not (spec and bridge and bridge.getLinkSignal) or r.want.clutch ~= nil then return nil end
    local ok, heard = pcall(bridge.getLinkSignal, spec[1] or "", spec[2] or "")
    if not (ok and type(heard) == "number") then return nil end
    local on = heard > 0
    if spec.invert then on = not on end
    r.override.clutch, r.want.clutch = on, on
    return ("link clutch found %s (signal %d)"):format(R.word("clutch", on), heard)
end

-- Signal level for a link state (15 on, 0 off, flipped by invert).
function R.level(spec, on)
    local level = on and 15 or 0
    if spec.invert then level = 15 - level end
    return level
end

-- Send what changed (and everything again every `refresh` seconds, in case
-- the bridge was broken and replaced). Returns a list of log lines.
function R.apply(r, bridge, links, now, refresh)
    local lines = {}
    if not bridge then return lines end
    for _, name in ipairs(R.NAMES) do
        local spec, on = links and links[name], r.want[name]
        if spec and on ~= nil then
            local level = R.level(spec, on)
            if r.sent[name] ~= level or now - (r.sent_t[name] or -math.huge) >= (refresh or 10) then
                local ok, err = pcall(bridge.sendLinkSignal, spec[1] or "", spec[2] or "", level)
                if ok then
                    if r.sent[name] ~= level then
                        lines[#lines + 1] = ("link %s %s (signal %d)"):format(name, R.word(name, on), level)
                        r.conflict_logged = r.conflict_logged or {}
                        r.conflict_logged[name] = nil
                    end
                    r.sent[name], r.sent_t[name] = level, now
                    -- Create links take the strongest transmitter: a lever or
                    -- handheld remote left on overrides our 0. Say so once.
                    if level == 0 and bridge.getLinkSignal then
                        local okr, heard = pcall(bridge.getLinkSignal, spec[1] or "", spec[2] or "")
                        r.conflict_logged = r.conflict_logged or {}
                        if okr and type(heard) == "number" and heard > 0 and not r.conflict_logged[name] then
                            r.conflict_logged[name] = true
                            lines[#lines + 1] = ("link %s: another transmitter keeps it at %d, switch that lever/remote off"):format(name, heard)
                        end
                    end
                else
                    lines[#lines + 1] = ("link %s send failed: %s"):format(name, tostring(err))
                    r.sent[name] = nil
                end
            end
        end
    end
    return lines
end

-- Human words for a link state.
function R.word(name, on)
    if name == "clutch" then return on and "released" or "engaged" end
    if name == "gear" then return on and "down" or "up" end
    return on and "on" or "off"
end

-- On the flight computer -------------------------------------------------------

-- Hold a link by hand (buttons, `link` command). The clutch is never
-- released while the ship flies: the props would stop and it would fall.
function R.set_by_hand(ctx, name, on)
    if name == "clutch" and on and ctx.k.mode ~= "STANDBY" and not G.on_ground(ctx) then
        ctx.notice = "engine off refused: the ship is flying"
        Cx.log(ctx, ctx.notice)
        return false
    end
    ctx.rlinks.override[name] = on
    ctx.rlinks.want[name] = on       -- the screen shows it at once
    ctx.notice = nil
    Cx.log(ctx, ("link %s held %s by hand"):format(name, R.word(name, on)))
    return true
end

-- The engine clutch is the owner's switch (Engine button): with it released
-- the props cannot turn.
function R.engine_off(ctx)
    return ctx.rlinks.want.clutch == true
end
R.ENGINE_OFF = "the engine is off: switch Engine ON first"

-- A start (arm, takeoff) switches the engine on when it is off.
function R.start_engine(ctx)
    if not R.engine_off(ctx) then return end
    ctx.rlinks.override.clutch, ctx.rlinks.want.clutch = false, false
    Cx.log(ctx, "engine on for the start")
end

-- Docked at the dock station: the engine off (no fuel burnt standing).
function R.stop_engine(ctx, where)
    if R.engine_off(ctx) then return end
    ctx.rlinks.override.clutch, ctx.rlinks.want.clutch = true, true
    Cx.log(ctx, "engine off: docked" .. (where and (" at " .. tostring(where)) or ""))
end

-- Legs held by hand go back to automatic when the motors start or stop.
function R.mode_changed(ctx, mode)
    if ctx.rlinks.override.gear ~= nil then
        ctx.rlinks.override.gear = nil
        Cx.log(ctx, "legs: automatic again (" .. mode .. ")")
    end
end

return R
