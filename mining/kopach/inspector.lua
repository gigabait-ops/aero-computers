-- The inspector turtle (owner 2026-11-06): a Geo Scanner and an ender modem,
-- no pickaxe in its tool slots. It flies through the dug part of the pit,
-- scans a grid of points and tells the remote where a block was left inside
-- or a wall has a hole; the free diggers fix them (app.lua, miner.lua m.fix).
-- It introduces itself (role "inspector"): nothing to set on the remote.
-- Fuel: lava from its linked barrel; it can only take the barrel back up with
-- a pickaxe, so a pickaxe lying in its inventory is swapped in for that moment.
-- Install: tools/deploy_kopach.sh inspector <id>.
package.path = "/kopach/?.lua;" .. package.path
local Cfg = require("config")
local G = require("geom")
local I = require("inspect")
local Supply = require("supply")
local supply = Supply.new()

local PROTO = Cfg.protocol
local VERSION = 2   -- shown on the remote; 2: lava from PC121
local DX, DZ = G.DX, G.DZ
local LOW_FUEL, FULL_FUEL = 3000, 60000

local function log(text)
    local path = "/kopach/log.txt"
    local f = fs.open(path, fs.exists(path) and fs.getSize(path) < 32000 and "a" or "w")
    if f then f.writeLine(("%s %s"):format(textutils.formatTime(os.time(), true), text)) f.close() end
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("no ender modem") return end
rednet.open(peripheral.getName(modem))
local REMOTES = type(Cfg.remote) == "table" and Cfg.remote or {Cfg.remote}
local trusted = {}
for _, id in ipairs(REMOTES) do trusted[id] = true end
local remote = REMOTES[1]

local st = {word = "start", note = nil, pos = nil, dir = nil, found = 0}
local ctl = {paused = false}
local replies, seq = {}, 0
local function now() return os.epoch("utc") / 1000 end

local function say(word, note)
    if st.word ~= word or st.note ~= note then
        st.word, st.note = word, note
        log(word .. (note and (" " .. note) or ""))
    end
end

local function status()
    local p = st.pos or {}
    return {t = "hi", role = "inspector", word = st.word, note = st.note, fuel = turtle.getFuelLevel(),
        x = p.x, y = p.y, z = p.z, ver = VERSION, label = os.getComputerLabel(), found = st.found}
end

local function ask(info)
    seq = seq + 1
    local id = seq
    info.t, info.req, info.role = "want", id, "inspector"
    rednet.send(remote, info, PROTO)
    local timer = os.startTimer(4)
    while true do
        if replies[id] then local r = replies[id] replies[id] = nil os.cancelTimer(timer) return r end
        local ev, p = os.pullEvent()
        if ev == "timer" and p == timer then return nil end
    end
end

local function radio()
    local tick, last = os.startTimer(1), -100
    while true do
        local ev = {os.pullEvent()}
        if ev[1] == "timer" and ev[2] == tick then
            if now() - last >= 15 then rednet.send(remote, status(), PROTO) last = now() end
            tick = os.startTimer(1)
        elseif ev[1] == "rednet_message" and ev[4] == PROTO and trusted[ev[2]] and type(ev[3]) == "table" then
            local msg = ev[3]
            remote = ev[2]
            if msg.t == "pause" then ctl.paused = true
            elseif msg.t == "resume" then ctl.paused = false
            elseif msg.t == "ping" then rednet.send(remote, status(), PROTO) last = now()
            elseif msg.t == "reply" and msg.req then
                if msg.paused ~= nil then ctl.paused = msg.paused end
                replies[msg.req] = msg.reply
                os.queueEvent("kopach_reply")
            end
        end
    end
end

local function hold()
    while ctl.paused do say("pause") sleep(1) end
end

---------------------------------------------------------------- moving (never digs)
local function locate()
    local x, y, z = gps.locate(2)
    if not x then return false end
    st.pos = {x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)}
    return true
end

local function find_dir()
    for _ = 1, 4 do
        if not turtle.detect() and turtle.forward() then
            local x, _, z = gps.locate(2)
            local back = turtle.back()
            if x then
                local dx, dz = math.floor(x + 0.5) - st.pos.x, math.floor(z + 0.5) - st.pos.z
                if not back then st.pos.x, st.pos.z = st.pos.x + dx, st.pos.z + dz end
                for d = 0, 3 do if DX[d] == dx and DZ[d] == dz then st.dir = d return true end end
            end
            return false
        end
        turtle.turnRight()
    end
    if not turtle.detectUp() and turtle.up() then
        st.pos.y = st.pos.y + 1
        return find_dir()
    end
    return false
end

local function turn_to(d)
    d = d % 4
    if (st.dir + 1) % 4 == d then turtle.turnRight() st.dir = d return end
    while st.dir ~= d do turtle.turnLeft() st.dir = (st.dir + 3) % 4 end
end

local function fwd()
    if turtle.forward() then st.pos.x, st.pos.z = st.pos.x + DX[st.dir], st.pos.z + DZ[st.dir] return true end
    return false
end
local function up() if turtle.up() then st.pos.y = st.pos.y + 1 return true end return false end
local function down() if turtle.down() then st.pos.y = st.pos.y - 1 return true end return false end

-- Fly to (x, y, z) through air only: across at this height (over anything
-- in the way), then straight up or down. Gives up after `limit` tries (a
-- leftover block or a turtle in the way for good: the next point).
local function fly(x, y, z, limit, job)
    local stuck, blocked_axis = 0, nil
    for _ = 1, limit or 600 do
        hold()
        local p = st.pos
        if p.x == x and p.y == y and p.z == z then return true end
        local moved
        if p.x == x and p.z == z then
            moved = p.y > y and down() or (p.y < y and up())
        elseif p.y > y + 6 then moved = down()
        elseif p.y < y - 6 then moved = up()
        else
            -- across first; once past what was in the way, back towards the height
            -- the axis whose next cell stays inside the circle (along the edge
            -- the straight line runs into the wall)
            local dxs = p.x ~= x and (p.x < x and 0 or 2) or nil
            local dzs = p.z ~= z and (p.z < z and 1 or 3) or nil
            local d = dxs or dzs
            if job and dxs and dzs then
                local inx = G.inside(job, p.x + DX[dxs], p.z)
                local inz = G.inside(job, p.x, p.z + DZ[dzs])
                if not inx and inz then d = dzs end
                if blocked_axis == dxs and inz then d = dzs elseif blocked_axis == dzs and inx then d = dxs end
            end
            turn_to(d)
            moved = fwd()
            blocked_axis = not moved and d or nil
            if moved then
                if p.y > y then down() elseif p.y < y then up() end
            else
                moved = (p.y < y + 6 and up()) or (p.y > y - 6 and down())
            end
        end
        if moved then stuck = 0
        else
            stuck = stuck + 1
            if stuck > 20 then return false end
            sleep(1)
        end
    end
    return false
end

---------------------------------------------------------------- fuel
local function slot_of(pred)
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and pred(d.name) then return i end
    end
end

local function refuel()
    local barrel = slot_of(function(n) return n:find("^sophisticatedstorage:") ~= nil end)
    local pick = slot_of(function(n) return n:find("pickaxe") ~= nil end)
    if not barrel then say("no storage", "give it its barrel") return false end
    if not pick then say("no fuel", "put a pickaxe in its inventory") return false end
    say("service")
    turtle.select(pick)
    if not turtle.equipRight() then say("no fuel", "cannot swap the pickaxe in") return false end
    local scanner_slot = pick   -- the scanner is in that slot now
    local placed
    for _, w in ipairs({{turtle.placeUp, turtle.suckUp, turtle.dropUp, turtle.digUp, "top"},
                        {turtle.placeDown, turtle.suckDown, turtle.dropDown, turtle.digDown, "bottom"},
                        {turtle.place, turtle.suck, turtle.drop, turtle.dig, "front"}}) do
        turtle.select(barrel)
        if w[1]() then placed = w break end
    end
    if placed then
        -- PC121 puts the lava in the barrel's slot 1 (the barrel cannot reorder itself)
        local _, r = Supply.take_lava(supply, {
            turtle = turtle, suck = placed[2], drop = placed[3],
            want = math.max(1, math.min(20, math.ceil((FULL_FUEL - turtle.getFuelLevel()) / 1000))),
            full = function() return turtle.getFuelLevel() >= FULL_FUEL end,
            free = function()
                for i = 1, 16 do if i ~= barrel and turtle.getItemCount(i) == 0 then return i end end
            end,
        })
        if not (r and r.t == "ready") then log("supply: no lava (" .. Supply.why(r) .. ")") end
        turtle.select(barrel)
        placed[4]()
    end
    turtle.select(scanner_slot)
    turtle.equipRight()   -- the scanner back, the pickaxe to the inventory
    say("idle")
    return placed ~= nil and turtle.getFuelLevel() > LOW_FUEL
end

---------------------------------------------------------------- scanning
local function scanner()
    return peripheral.find("geoScanner") or peripheral.find("geo_scanner")
end

local function scan()
    for _ = 1, 10 do
        local sc = scanner()
        if not sc then say("error", "no geo scanner") return nil end
        local f = sc.scanBlocks or sc.scan   -- AP 0.8: scanBlocks(radius)
        local res, err = f(I.RADIUS)
        if type(res) == "table" then return res end
        sleep(1)   -- cooldown
        if err and not tostring(err):lower():find("cool") then log("scan: " .. tostring(err)) end
    end
    return nil
end

local function report(job, cells)
    for i = 1, #cells, 40 do
        local part = {}
        for k = i, math.min(#cells, i + 39) do
            local c = cells[k]
            part[#part + 1] = {x = c.x, y = c.y, z = c.z, kind = c.kind}
        end
        rednet.send(remote, {t = "found", job = job.id, cells = part}, PROTO)
        sleep(0.2)
    end
end

-- one pass: the grid at height y, cells of levels lo..hi (walls lo..whi)
local function pass(job, y, lo, hi, whi)
    local pts = I.points(job, y)
    local all, seen = {}, {}
    for i, p in ipairs(pts) do
        hold()
        if turtle.getFuelLevel() < LOW_FUEL and not refuel() then return nil end
        say("inspect", ("y %d point %d/%d"):format(y, i, #pts))
        if fly(p.x, p.y, p.z, 400, job) then
            local res = scan()
            if res then
                for _, c in ipairs(I.classify(job, st.pos.x, st.pos.y, st.pos.z, res, lo, hi, whi)) do
                    local k = I.key(c.x, c.y, c.z)
                    if not seen[k] then seen[k] = true all[#all + 1] = c end
                end
            end
        end
        -- report as it goes: every 10 points what is new
        if i % 10 == 0 or i == #pts then
            local new = {}
            for k = (st.sent or 0) + 1, #all do new[#new + 1] = all[k] end
            st.sent = #all
            if #new > 0 then report(job, I.rank(new)) end
        end
        if #all >= I.MAX_REPORT then break end
    end
    local rest = {}
    for k = (st.sent or 0) + 1, #all do rest[#rest + 1] = all[k] end
    if #rest > 0 then report(job, I.rank(rest)) end
    st.sent = 0
    st.found = #all
    log(("pass y %d: %d found"):format(y, #all))
    return #all
end

local function main()
    while not locate() do say("no gps") sleep(5) end
    -- it comes with no fuel: refuel first (that needs no facing), then find it
    while turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 100 do
        if not refuel() then sleep(10) end
    end
    while not st.dir do
        if not find_dir() then say("boxed in", "free one side") sleep(5) locate() end
    end
    local rounds, older, over = 0, 0, {}
    while true do
        hold()
        local r = ask({x = st.pos.x, y = st.pos.y, z = st.pos.z})
        if not r then say("no remote") sleep(10)
        elseif r.kind ~= "inspect" or not r.job then say("idle") sleep(20)
        else
            local job, band = r.job, r.band
            job.cur = r.cur
            local lo, hi, whi = I.done_levels(job, band)
            if not lo then say("wait", "nothing dug yet") sleep(30)
            else
                -- follow the diggers down (owner 2026-11-06): the levels just
                -- above them on every pass, an older layer every fourth pass
                local layers = math.max(1, math.ceil((hi - lo + 1) / (2 * I.RADIUS + 1)))
                rounds = rounds + 1
                local layer = 0
                if r.finished then
                    -- a finished job: every layer in turn, bottom up, until a
                    -- whole round finds nothing; then it rests until a new job
                    if over.job ~= job.id then over = {job = job.id, layer = 0, clean = 0} end
                    layer = over.layer % layers
                elseif rounds % 4 == 0 and layers > 1 then
                    older = older % (layers - 1) + 1
                    layer = older
                end
                if r.finished and over.clean >= layers then
                    say("done", "all clean") sleep(60)
                else
                    local y = math.min(hi - 1, lo + I.RADIUS + layer * (2 * I.RADIUS + 1))
                    if not G.inside(job, st.pos.x, st.pos.z) then
                        fly(job.cx, math.max(st.pos.y, job.top - 1), job.cz, 800)
                    end
                    local found = pass(job, y, lo, hi, whi)
                    if found == nil then sleep(30) end
                    if r.finished and found then
                        over.clean = found == 0 and over.clean + 1 or 0
                        over.layer = over.layer + 1
                    end
                end
            end
        end
    end
end

local function screen()
    while true do
        term.clear() term.setCursorPos(1, 1)
        local p = st.pos or {}
        print("inspector #" .. os.getComputerID())
        print(st.word .. (st.note and (": " .. st.note) or ""))
        print("fuel " .. tostring(turtle.getFuelLevel()))
        if p.x then print(("at %d %d %d"):format(p.x, p.y, p.z)) end
        print("last pass found " .. tostring(st.found))
        sleep(1)
    end
end

log("start")
parallel.waitForAny(radio, function()
    while true do
        local ok, err = pcall(main)
        if not ok then say("error", tostring(err)) sleep(10) end
    end
end, screen)
