-- The mining remote as a module: the row book, the turtles' radio and the
-- screens. The circle is dug around where the owner stands; every turtle
-- that answers on the protocol gets rows one at a time (kopach/plan.lua), so
-- the work splits over however many there are. PAUSE holds them all.
-- The PDA (120) mounts it as its Mine tab with Dig/Shell/Turtles inside (K.tab), routes
-- actions whose id starts with "kp_" to K.on_action, every event to
-- K.on_event, calls K.second() once a second and K.locate(x, y, z) with GPS.
package.path = "/?.lua;" .. package.path
local UI = require("ui")
local P = require("kopach.kitpage")
local G = require("kopach.geom")
local Plan = require("kopach.plan")
local Cfg = require("kopach.config")
local Shell = package.loaded["kopach.shell"] or require("kopach.shell")
local News = require("kopach.news")
local Chat = require("kopach.chat")
local Rows, Text = UI.Rows, UI.Text
local seg, DOT = P.seg, P.DOT

local PROTO = Cfg.protocol
local JOB_FILE = "/kopach/job"
local TURTLES_FILE = "/kopach/turtles"   -- what each turtle said last: a lost one is still on the list after a reboot
local KEEP = {"word", "note", "fuel", "x", "y", "z", "label", "ver", "seen", "job", "band", "row", "free", "home", "role", "found"}
local ALIVE = 40      -- seconds: a turtle silent longer is shown as lost (it beats every 15 s)
local SURE = 4        -- seconds a SURE? stays armed

local function now() return os.epoch("utc") / 1000 end

local function log(text)
    local path = "/kopach/log.txt"
    local f = fs.open(path, fs.exists(path) and fs.getSize(path) < 32000 and "a" or "w")
    if f then f.writeLine(("%s %s"):format(textutils.formatTime(os.time(), true), text)) f.close() end
end

local function load_job()
    if not fs.exists(JOB_FILE) then return nil end
    local f = fs.open(JOB_FILE, "r") local j = textutils.unserialize(f.readAll()) f.close()
    return j
end

local S = {
    radius = settings.get("kopach.radius", 20),
    depth = settings.get("kopach.depth", 0),      -- 0: down to bedrock
    up = settings.get("kopach.up", 0),            -- levels above the feet: 0 none, a number, "all" (to the top)
    -- the job's top and floor as heights (owner 2026-11-06), whatever builds
    -- a roof or a floor there; false: at my feet (top) / to the bottom (floor)
    topY = settings.get("kopach.top_y", false),
    floorY = settings.get("kopach.floor_y", false),
    nether = settings.get("kopach.nether", false), -- GPS cannot tell the world: the owner says it
    shape = settings.get("kopach.shape", "circle"),
    walls = settings.get("kopach.walls", true),
    roof = settings.get("kopach.roof", false),
    floor = settings.get("kopach.floor", false),
    -- the shell (kopach/shell.lua): what the walls, roof and floor are built
    -- from and what may stand in their place
    mode = settings.get("kopach.mode", "dig"),              -- "dig" | "builder"
    order = settings.get("kopach.order", "bulk"),           -- "bulk" | "priority"
    replace = settings.get("kopach.replace", "all"),         -- "all" | "soft+ores" | "soft" | "holes"
    supply = settings.get("kopach.supply", "barrel"),        -- "barrel": PC121 through the linked barrel | "off"
    blockWalls = settings.get("kopach.block.walls", ""),    -- "" = auto (from the inventory)
    blockRoof = settings.get("kopach.block.roof", ""),      -- "" = same as the walls
    blockFloor = settings.get("kopach.block.floor", ""),    -- "" = same as the walls
    info = nil,                                    -- {text, until}: a short notice above the buttons
    job = nil, paused = false,
    turtles = {}, me = nil, gps = nil, sure = nil, modem = false,
}

local R = {}   -- the model; S is its state
R.NEAR = 32    -- a turtle farther than this from the circle's edge gets no rows
R.QUIET = 60   -- seconds after boot: every turtle answers anew, none of them is "new"

-- Chat news (kopach/news.lua): said through this computer's own Chat Box
-- (kopach/chat.lua); K.on_news(fn) sends them elsewhere instead.
local news_sink, chat
local function news(key, params)
    if news_sink then pcall(news_sink, key, params) else Chat.emit(chat, key, params) end
end
local function who(id)
    local tt = S.turtles[id]
    return tt and tt.label or ("#" .. tostring(id))
end
local booted = nil

-- The job file used to be rewritten (six kilobytes plus a settings file) for
-- every row request: with forty turtles that is a write several times a second
-- on the server thread. Now a change only marks it dirty and it is written at
-- most every two seconds, or at once when the owner acts (START/STOP).
local job_dirty, settings_dirty, saved_at = false, false, -100
function R.flush()
    saved_at = now()
    if job_dirty then
        if S.job then
            local f = fs.open(JOB_FILE, "w") f.write(textutils.serialize(S.job, {compact = true})) f.close()
        elseif fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end
        job_dirty = false
    end
    if settings_dirty then
        settings.set("kopach.radius", S.radius) settings.set("kopach.depth", S.depth) settings.set("kopach.up", S.up) settings.set("kopach.nether", S.nether)
        settings.set("kopach.shape", S.shape) settings.set("kopach.walls", S.walls) settings.set("kopach.roof", S.roof) settings.set("kopach.floor", S.floor)
        settings.set("kopach.mode", S.mode) settings.set("kopach.order", S.order) settings.set("kopach.replace", S.replace)
        settings.set("kopach.supply", S.supply)
        settings.set("kopach.block.walls", S.blockWalls) settings.set("kopach.block.roof", S.blockRoof)
        settings.set("kopach.block.floor", S.blockFloor)
        settings.set("kopach.top_y", S.topY) settings.set("kopach.floor_y", S.floorY)
        settings.set("kopach.paused", S.paused) settings.save()
        settings_dirty = false
    end
end
function R.save()
    job_dirty = true
    if now() - saved_at >= 2 then R.flush() end
end
-- the owner acted (a setting, START, STOP, PAUSE): write the job and the settings now
function R.save_settings()
    job_dirty, settings_dirty = true, true
    R.flush()
end

local function send_all(msg) if S.modem then rednet.broadcast(msg, PROTO) end end

function R.alive(id)
    local tt = S.turtles[id]
    return tt ~= nil and now() - tt.seen <= ALIVE
end

-- Words a turtle cannot get out of by itself; held this long its row goes
-- to another turtle (it keeps answering, so its row never went stale).
R.TROUBLE = {["no fuel"] = true, stuck = true, error = true, ["no storage"] = true, ["no room"] = true, ["no gps"] = true}
R.TROUBLE_SECONDS = 300
function R.working(id)
    local tt = S.turtles[id]
    if not R.alive(id) then return false end
    return not (tt.trouble_at and now() - tt.trouble_at > R.TROUBLE_SECONDS)
end

function R.count()
    local n = 0
    for id, tt in pairs(S.turtles) do if R.alive(id) and tt.role ~= "inspector" then n = n + 1 end end
    return n
end

-- the farthest a turtle can be from the owner: the circle's far edge
function R.reach()
    if not (S.job and S.me) then return 0 end
    local dx, dz = S.me.x - S.job.cx, S.me.z - S.job.cz
    return math.sqrt(dx * dx + dz * dz) + G.corner(S.job)
end

function R.set_paused(on)
    S.paused = on
    send_all({t = on and "pause" or "resume"})
    log(on and "pause" or "resume")
    R.save_settings()
end

-- The shell blocks the living turtles say they have (each sends its six most
-- common, most first): the Shell tab cycles through these, so the owner only
-- picks blocks the fleet actually carries.
function R.blocks()
    local seen, list = {}, {}
    for id in pairs(S.turtles) do
        if R.alive(id) then
            for _, name in ipairs(S.turtles[id].fills or {}) do
                if not seen[name] then seen[name] = true list[#list + 1] = name end
            end
        end
    end
    table.sort(list, function(a, b) return Shell.label(a) < Shell.label(b) end)
    return list
end

-- The heights a job would take now, from where I stand: the top never under
-- my feet and the floor never over them (the turtles start at my feet).
function R.highest() return S.nether and G.NETHER_TOP or G.MAX_Y end
function R.lowest() return S.nether and G.NETHER_FLOOR or G.MIN_FLOOR end
function R.heights()
    local feet = S.me and math.floor(S.me.y) or 64
    -- not set as heights yet: the older Up / Depth settings
    local top = S.topY or (S.up == "all" and R.highest()) or feet + (tonumber(S.up) or 0)
    local floor = S.floorY or ((S.depth or 0) > 0 and feet - S.depth + 1) or R.lowest()
    top = math.max(feet, math.min(R.highest(), top))
    floor = math.min(feet, math.max(R.lowest(), floor))
    return top, floor, feet
end

function R.start()
    if not S.me then return end
    local top, floor, feet = R.heights()
    S.up = top >= R.highest() and "all" or (top - feet)
    S.depth = floor <= R.lowest() and 0 or (feet - floor + 1)
    S.info = nil
    S.job = Plan.new(S.me, S.radius, S.depth > 0 and S.depth or nil, now(), S.nether and G.NETHER_FLOOR or G.MIN_FLOOR, S.shape,
        {walls = S.walls, roof = S.roof, floor = S.floor, mode = S.mode,
         up = S.up, highest = S.nether and G.NETHER_TOP or G.MAX_Y,
         shell = {order = S.order, replace = S.replace, supply = S.supply,
                  materials = {walls = S.blockWalls, roof = S.blockRoof, floor = S.blockFloor}}})
    log(("start at %d %d %d R=%d depth=%s"):format(S.job.cx, S.job.top, S.job.cz, S.radius, tostring(S.depth)))
    S.job.known = {}
    for id in pairs(S.turtles) do if R.alive(id) then S.job.known[id] = true end end
    S.paused = false
    send_all({t = "resume"})
    R.save_settings()
    news("kopach.started", {shape = S.job.shape or "circle", radius = S.job.R, levels = S.job.bands})
end

function R.stop()
    send_all({t = "stop"})
    log("stop")
    S.job, S.paused = nil, false
    R.save_settings()
end

-- one radio message from a turtle
function R.on_message(id, msg)
    if type(msg) ~= "table" then return false end
    local t = now()
    if msg.t == "hi" then
        msg.seen = t
        local before = S.turtles[id]
        -- a short beat keeps what the last full one said (inventory, home, label)
        local rec = {}
        if before and not msg.full then
            for _, k in ipairs({"free", "label", "fills", "home"}) do rec[k] = before[k] end
        end
        for k, v in pairs(msg) do rec[k] = v end
        if R.TROUBLE[rec.word] then rec.trouble_at = before and before.trouble_at or t else rec.trouble_at = nil end
        msg = rec
        S.turtles[id] = msg
        -- news: a turtle never seen in this job (not in the first minute after
        -- a boot, when every one answers anew), a turtle turning to trouble
        if S.job and not S.job.finished then
            S.job.known = S.job.known or {}
            if not S.job.known[id] then
                S.job.known[id] = true
                if booted and t - booted > R.QUIET then news("kopach.joined", {turtle = who(id)}) end
            end
            local key = News.words[msg.word]
            if key and (not before or before.word ~= msg.word) then news(key, {turtle = who(id)}) end
        end
        if S.job and R.working(id) then Plan.touch(S.job, id, t, msg.row, msg.z, msg.dz) end   -- in trouble: its row may go stale
        return false   -- the one-second timer redraws; a heartbeat need not
    elseif msg.t == "want" and msg.role == "inspector" then
        local reply = {kind = "idle"}
        -- a finished job too: its last bands are checked once over (the inspector stops when clean)
        if S.job and S.job.finished then reply = {kind = "inspect", job = Plan.summary(S.job), band = S.job.band + 1, finished = true}
        elseif S.job then reply = {kind = "inspect", job = Plan.summary(S.job), band = S.job.band, cur = Plan.current(S.job)} end
        rednet.send(id, {t = "reply", req = msg.req, reply = reply, paused = S.paused}, PROTO)
        return true
    elseif msg.t == "found" then
        if S.job and S.job.id == msg.job and type(msg.cells) == "table" then
            if Plan.add_fixes(S.job, msg.cells) > 0 then R.save() end
        end
        return true
    elseif msg.t == "fixed" then
        if S.job and S.job.id == msg.job then Plan.fixes_done(S.job, msg.results) R.save() end
        return true
    elseif msg.t == "want" then
        local reply
        -- done reports it sends again until they are acknowledged (turtle.lua)
        if type(msg.dones) == "table" then for _, d in ipairs(msg.dones) do R.take_done(id, d) end end
        local far = S.job and msg.x and msg.z and
            math.sqrt((msg.x - S.job.cx) ^ 2 + (msg.z - S.job.cz) ^ 2) > G.corner(S.job) + R.NEAR
        -- outside the circle AND below its top: it cannot fly in (it may not dig
        -- out there) - no rows until it is carried inside. This is the turtle
        -- that used to mark a whole band done without digging a cell.
        local buried = false
        if S.job and msg.x and msg.z and msg.y then
            buried = not G.inside(S.job, msg.x, msg.z) and msg.y < S.job.top
        end
        -- outside: its rows go to the others at once; one that was in this
        -- job digs its own way back in (miner come_back), a new one waits
        if S.job and (far or buried) then Plan.release(S.job, id) end
        if not S.job then reply = {kind = "idle"}
        elseif far then reply = {kind = "idle", why = "outside", job = S.job.id}
        elseif buried then
            reply = {kind = "idle", why = "outside", job = S.job.id}
            if S.turtles[id] then news("kopach.outside", {turtle = who(id)}) end
        else
            local band, finished = S.job.band, S.job.finished
            -- turtles in trouble for five minutes: their rows go to the others now
            for tid, tt in pairs(S.turtles) do
                if tid ~= id and R.alive(tid) and not R.working(tid) then Plan.release(S.job, tid) end
            end
            reply = Plan.next_row(S.job, id, msg.x, t, R.working)
            if reply.kind == "row" then reply.job = Plan.summary(S.job) end
            if reply.cut then
                -- the far half of a busy row went to this one: its digger stops at the meeting cell
                rednet.send(reply.cut.tid, {t = "cut", job = S.job.id, band = reply.band, x = reply.x, z = reply.cut.z}, PROTO)
                reply.cut = nil
            end
            -- nothing to dig now: what the inspector found, if anything
            if (reply.kind == "wait" or reply.kind == "finish") and R.working(id) then
                local cells = Plan.take_fixes(S.job, id, msg.x, msg.z, t, 8)
                if cells and #cells > 0 then reply = {kind = "fix", cells = cells, job = Plan.summary(S.job)} end
            end
            if S.job.band > band then news("kopach.level", {level = band, levels = S.job.bands}) end
            if S.job.finished and not finished then
                if S.job.band < S.job.bands then news("kopach.stopped_at", {level = S.job.band})
                else news("kopach.finished") end
            end
            R.save()
        end
        if type(reply) == "table" and S.job and S.job.acked then reply.acked = S.job.acked[id] end
        rednet.send(id, {t = "reply", req = msg.req, reply = reply, paused = S.paused}, PROTO)
        return true
    elseif msg.t == "done" then
        R.take_done(id, msg)
        R.save()
        return true
    end
    return false
end

-- a row's done report, once: repeats (sent again with each want until
-- acknowledged) are skipped by their dseq; reports without one count always
function R.take_done(id, msg)
    -- (kept in the job, so a rebooted remote does not count one twice)
    if type(msg) ~= "table" or not S.job or S.job.id ~= msg.job then return end
    S.job.acked = S.job.acked or {}
    local seq = tonumber(msg.dseq)
    if seq and seq <= (S.job.acked[id] or 0) then return end
    Plan.row_done(S.job, id, msg.band, msg.x, msg.left, msg.part)
    if seq then S.job.acked[id] = seq end
end

-- every second or two: our position. Walking off does not pause: another
-- account may keep the area loaded (owner 2026-11-03); Reach only shows it.
function R.tick(x, y, z)
    if x then S.me, S.gps = {x = x, y = y, z = z}, true else S.gps = false end
end

-- Screen -------------------------------------------------------------------------

local function sure(id) return S.sure and S.sure.id == id and now() <= S.sure.t end

local function word()
    if not S.modem then return "NO MODEM", "bad" end
    if S.job and S.job.finished then return "DONE", "ok" end
    if S.job and S.paused then return "PAUSED", "warn" end
    if S.job and S.job.last_band then return "LAST LEVEL", "busy" end
    if S.job then return "DIGGING", "busy" end
    if S.gps == false then return "NO GPS", "bad" end
    return "READY", "ok"
end

local function stepper(p, id, label, value, enabled)
    local t = p.t
    local i = P.blank(p)
    local y = P.y_of(p, i)
    local x0 = p.c.rect.x + p.c.rect.width - 12
    local color = enabled and t.accent or t.border
    local x = P.button(p, "kp_" .. id .. "_minus", "-", color, x0, y)
    P.button(p, "kp_" .. id .. "_plus", "+", color, x + 1, y)
    p.rows[i] = {segs = {seg(DOT .. " ", t.info), seg(Text.fit(label, 7), t.muted), seg(value, t.text)}}
end

local function short(n)
    if type(n) ~= "number" then return tostring(n or "--") end
    return n >= 1000 and ("%.1fk"):format(n / 1000) or tostring(n)
end

-- A row with its label, its value and one "<>" at the right (the same shape
-- the radius stepper uses): pressing it cycles the setting.
local function chooser(p, id, label, value, color)
    local t = p.t
    local i = P.blank(p)
    P.button(p, "kp_" .. id, "<>", color or t.accent, p.c.rect.x + p.c.rect.width - 7, P.y_of(p, i))
    local room = math.max(4, p.c.rect.width - 17)   -- prefix + label + the button
    p.rows[i] = {segs = {seg(DOT .. " ", t.info), seg(Text.fit(label, 8), t.muted), seg(Text.fit(value, room), t.text)}}
end

-- The rows under the state word, one function each (one row each), so the
-- pocket shows them all and a tab inside another app shows a window that the
-- wheel scrolls. bw: width of the progress bars.
-- A setting with many values opens a page of its own (owner 2026-11-06):
-- S.sub = {kind = "blocks", surface = "walls"} or {kind = "height", which = "top"}.
local SURFACE_KEY = {walls = "blockWalls", roof = "blockRoof", floor = "blockFloor"}

local function sub_rows(t)
    local list, sub = {}, S.sub
    if sub.kind == "blocks" then
        local key = SURFACE_KEY[sub.surface]
        local names, seen = {""}, {[""] = true}
        for _, name in ipairs(R.blocks()) do if not seen[name] then names[#names + 1] = name seen[name] = true end end
        for _, name in ipairs(Shell.choices(sub.surface)) do if not seen[name] then names[#names + 1] = name seen[name] = true end end
        list[#list + 1] = function(p) P.add(p, Rows.status(sub.surface == "walls" and "Walls" or sub.surface == "roof" and "Roof" or "Floor",
            S[key] ~= "" and Shell.label(S[key]) or (sub.surface == "walls" and "auto" or "same"), t.accent, t)) end
        local carried = {}
        for _, name in ipairs(R.blocks()) do carried[name] = true end
        for _, name in ipairs(names) do
            local on = S[key] == name
            local label = name == "" and (sub.surface == "walls" and "auto" or "same") or Shell.label(name)
            list[#list + 1] = function(p)
                P.pick(p, "kp_block", {{key = name == "" and "-" or name, segs = {
                    seg(on and (DOT .. " ") or "  ", t.accent), seg(Text.fit(label, p.c.rect.width - 4), on and t.accent or (carried[name] and t.ok or t.text))}}})
            end
        end
    elseif sub.kind == "height" then
        local top, floor = R.heights()
        local v = sub.which == "top" and top or floor
        list[#list + 1] = function(p) P.add(p, Rows.status(sub.which == "top" and "Top" or "Bottom", "y " .. v, t.accent, t)) end
        list[#list + 1] = function(p) P.blank(p) end
        list[#list + 1] = function(p)
            local i = P.blank(p)
            local y = P.y_of(p, i)
            local x = P.button(p, "kp_h_m10", "-10", t.accent, p.c.rect.x, y)
            x = P.button(p, "kp_h_m1", "-1", t.accent, x + 1, y)
            x = P.button(p, "kp_h_p1", "+1", t.accent, x + 1, y)
            P.button(p, "kp_h_p10", "+10", t.accent, x + 1, y)
        end
        list[#list + 1] = function(p)
            local i = P.blank(p)
            local y = P.y_of(p, i)
            local x = P.button(p, "kp_h_here", "HERE", t.accent, p.c.rect.x, y)
            P.button(p, "kp_h_end", sub.which == "top" and "TOP" or "BOTTOM", t.accent, x + 1, y)
        end
    end
    return list
end

local function dig_rows(t, bw)
    local list, job = {}, S.job
    local function add(f) list[#list + 1] = f end
    local function blank() add(function(p) P.blank(p) end) end
    local function toggle(id, label, value)
        add(function(p)
            local i = P.blank(p)
            P.button(p, "kp_" .. id, "<>", t.accent, p.c.rect.x + p.c.rect.width - 6, P.y_of(p, i))
            p.rows[i] = {segs = {seg(DOT .. " ", t.info), seg(Text.fit(label, 7), t.muted), seg(value, t.text)}}
        end)
    end
    if job then
        local build = {}
        if job.walls ~= false then build[#build + 1] = "walls" end
        if job.roof then build[#build + 1] = "roof" end
        if job.floor_on then build[#build + 1] = "floor" end
        local pr = Plan.progress(job)
        add(function(p) P.add(p, Rows.status("Area", job.box and ("%dx%d"):format(job.box.x1 - job.box.x0 + 1, job.box.z1 - job.box.z0 + 1)
            or ("%s %d"):format(job.shape or "circle", job.R), t.info, t)) end)
        add(function(p) P.add(p, Rows.status("Depth", ("y %d to %d"):format(job.top, job.floor), t.info, t)) end)
        add(function(p) P.add(p, Rows.status("Build", #build > 0 and table.concat(build, " ") or "none", t.info, t)) end)
        local fixes = Plan.fix_count(job)
        local insp
        for id, tt in pairs(S.turtles) do if tt.role == "inspector" and R.alive(id) then insp = id end end
        if insp or fixes > 0 then
            add(function(p) P.add(p, Rows.status("Fixes", fixes > 0 and (fixes .. " to fix") or "none found",
                fixes > 0 and t.warn or t.ok, t)) end)
        end
        blank()
        add(function(p)
            local lit, dim = Rows.bar(pr.band - (pr.finished and 0 or 1) + (pr.total > 0 and pr.done / pr.total or 0), pr.bands, bw, t.busy, t)
            local bands = pr.last and not pr.finished and (" %d last"):format(pr.band) or (" %d/%d"):format(pr.band, pr.bands)
            P.add(p, {segs = {seg(DOT .. " ", t.busy), seg(Text.fit("Levels", 7), t.muted), lit, dim, seg(bands, pr.last and t.busy or t.muted)}})
        end)
        add(function(p)
            local lit, dim = Rows.bar(pr.done, pr.total, bw, t.info, t)
            P.add(p, {segs = {seg(DOT .. " ", t.info), seg(Text.fit("Rows", 7), t.muted), lit, dim, seg((" %d/%d"):format(pr.done, pr.total), t.muted)}})
        end)
        if S.me then
            add(function(p)
                P.add(p, Rows.status("Reach", ("%d of %d"):format(math.floor(R.reach()), G.SIM_BLOCKS), R.reach() > G.SIM_BLOCKS and t.warn or t.ok, t))
            end)
        end
    else
        add(function(p)
            P.add(p, Rows.status("Here", S.me and ("%d %d %d"):format(math.floor(S.me.x), math.floor(S.me.y), math.floor(S.me.z)) or "--",
                S.me and t.ok or t.bad, t))
        end)
        add(function(p) stepper(p, "radius", "Radius", tostring(S.radius), true) end)
        local top, floor = R.heights()
        add(function(p) chooser(p, "height_top", "Top", "y " .. top, t.accent) end)
        add(function(p) chooser(p, "height_floor", "Bottom", "y " .. floor, t.accent) end)
        toggle("world", "World", S.nether and "nether" or "overworld")
        toggle("shape", "Shape", S.shape)
        toggle("walls", "Walls", S.walls and "yes" or "no")
        toggle("roof", "Roof", S.roof and "yes" or "no")
        toggle("floor", "Floor", S.floor and "yes" or "no")
        add(function(p) P.add(p, Rows.status("Turtles", tostring(R.count()), R.count() > 0 and t.ok or t.warn, t)) end)
    end
    return list
end

-- The Shell tab: what the walls, roof and floor are built from and what may
-- stand in their place (kopach/shell.lua). A running job shows its own values
-- and locks them: they were fixed when START was pressed.
local function shell_rows(t)
    local list = {}
    local function add(f) list[#list + 1] = f end
    local job = S.job
    local shell = job and job.shell or {order = S.order, replace = S.replace,
        materials = {walls = S.blockWalls, roof = S.blockRoof, floor = S.blockFloor}}
    local color = job and t.border or t.accent
    local function named(v)
        if type(v) == "table" then v = v[1] end
        return type(v) == "string" and v ~= "" and Shell.label(v) or nil
    end
    add(function(p) chooser(p, "mode", "Mode", (job and job.mode or S.mode) == "builder" and "builder" or "dig", color) end)
    add(function(p) chooser(p, "order", "Pick", shell.order or S.order, color) end)
    add(function(p) chooser(p, "replace", "Replace", shell.replace or S.replace, color) end)
    add(function(p) chooser(p, "supply", "Supply", shell.supply or S.supply, color) end)
    add(function(p) P.blank(p) end)
    local walls = named(shell.materials and shell.materials.walls)
    add(function(p) chooser(p, "block_walls", "Walls", walls or "auto", color) end)
    add(function(p) chooser(p, "block_roof", "Roof", named(shell.materials and shell.materials.roof) or "same", color) end)
    add(function(p) chooser(p, "block_floor", "Floor", named(shell.materials and shell.materials.floor) or "same", color) end)
    add(function(p) P.blank(p) end)
    local have = {}
    for _, name in ipairs(R.blocks()) do have[#have + 1] = Shell.label(name) end
    add(function(p)
        P.line(p, t.muted, Text.fit(#have > 0 and ("have " .. table.concat(have, " ")) or "no shell blocks seen yet", p.c.rect.width))
    end)
    local supply = shell.supply or S.supply
    local said = supply == "off" and "no supply: only what it digs" or "supply: PC121, through the barrel"
    add(function(p) P.line(p, t.muted, Text.fit(said, p.c.rect.width)) end)
    return list
end

local function shell_page(state, context)
    local p = P.page(context)
    for _, row in ipairs(shell_rows(p.t)) do row(p) end
    return P.finish(p)
end

-- its own button right over the rule: dig the level they are on to the end, then home;
-- after such an end CONTINUE takes the next level of the same job (owner 2026-11-03)
local function finish_button(t)
    if not S.job then return nil end
    local pr = Plan.progress(S.job)
    if not pr.finished then
        return "kp_last", pr.last and "DIG ALL LEVELS" or "FINISH THIS LEVEL", pr.last and t.info or t.warn
    elseif pr.band < pr.bands then
        return "kp_continue", "CONTINUE", t.ok
    end
end

local function bottom_button(p, id, label, color)
    while P.left(p) > 1 do P.blank(p) end
    local r = P.blank(p)
    P.button(p, id, label, color, p.c.rect.x + math.floor((p.c.rect.width - #label - 4) / 2), P.y_of(p, r))
end

local function dig_page(state, context)
    local p = P.page(context)
    local t = p.t
    local w, c = word()
    local busy = S.job ~= nil
    local sure_start, sure_stop = sure("start"), sure("stop")
    -- START and STOP, under them one PAUSE that turns into RESUME while paused (owner 2026-11-03;
    -- all three on one row do not fit 26 columns)
    local pause = S.paused and {"kp_resume", "RESUME", busy and t.ok or t.border} or {"kp_pause", "PAUSE", busy and t.warn or t.border}
    P.bars(p, {
        {{"kp_start", sure_start and "SURE?" or "START", busy and t.border or (sure_start and t.warn or t.ok)},
         {"kp_stop", sure_stop and "SURE?" or "STOP", busy and t.bad or t.border}},
        {pause},
    }, 2)
    if S.info and now() <= S.info.t then P.notice(p, S.info.text, t.warn) end
    P.add(p, Rows.banner(w, t[c] or t.text, t, busy and ("%d turtles"):format(R.count()) or nil))
    P.blank(p)
    for _, row in ipairs(dig_rows(t, 6)) do row(p) end
    local id, label, color = finish_button(t)
    if id then bottom_button(p, id, label, color) end
    return P.finish(p)
end

local COLOR = {far = "warn", outside = "warn", dig = "busy", build = "busy", travel = "info", service = "info", home = "info", wait = "muted", idle = "muted",
    done = "ok", stopped = "muted", pause = "warn", ["no fuel"] = "bad", ["no storage"] = "bad", ["no blocks"] = "warn",
    ["no room"] = "warn", stuck = "bad", error = "bad", ["no gps"] = "bad", ["no remote"] = "warn"}

-- width: the page's; 34 and more puts the note (band, row) on the turtle's own row
local function turtle_rows(t, width)
    local list = {}
    local ids = {}
    for id in pairs(S.turtles) do ids[#ids + 1] = id end
    -- the inspector first, then the ones in trouble, then by number (owner 2026-11-06)
    local function rank(id)
        local tt = S.turtles[id]
        if tt.role == "inspector" then return 0 end
        if not R.alive(id) or R.TROUBLE[tt.word] or tt.word == "outside" or tt.word == "no supply" then return 1 end
        if S.job and tt.x and tt.word == "idle" and not G.inside(S.job, tt.x, tt.z) then return 1 end
        return 2
    end
    table.sort(ids, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    if #ids == 0 then
        list[1] = function(p) P.line(p, t.muted, "none answer yet") end
    else
        -- the count lives here now (the tab is 39 columns: Dig Shell Turtles)
        list[#list + 1] = function(p) P.line(p, t.muted, ("%d turtles"):format(#ids)) end
    end
    for _, id in ipairs(ids) do
        local tt = S.turtles[id]
        local name = tt.label or ("#" .. id)
        local wd = R.alive(id) and (tt.word or "?") or "lost"
        if R.alive(id) and S.job and tt.x and tt.word == "idle"
            and math.sqrt((tt.x - S.job.cx) ^ 2 + (tt.z - S.job.cz) ^ 2) > G.corner(S.job) + R.NEAR then wd = "far"
        elseif R.alive(id) and S.job and tt.x and tt.y and tt.word == "idle"
            and not G.inside(S.job, tt.x, tt.z) and tt.y < S.job.top then wd = "outside" end   -- gets no rows: carry it in
        local col = R.alive(id) and (t[COLOR[wd] or "text"] or t.text) or t.bad
        local note = tt.note and R.alive(id) and tostring(tt.note) or nil
        -- a touch on a turtle's row opens its card (owner 2026-11-05: where is the lost one)
        if (width or 0) >= 34 then
            list[#list + 1] = function(p)
                local segs = {seg(Text.fit(name, 6), t.text), Rows.chip(wd, col, 10), seg(Text.fit(short(tt.fuel), 6), t.muted)}
                if note then segs[#segs + 1] = seg(Text.fit(note:gsub("^band ", ""), math.max(1, width - 23)), t.muted) end
                P.pick(p, "kp_turtle", {{key = id, segs = segs}})
            end
        else
            list[#list + 1] = function(p)
                P.pick(p, "kp_turtle", {{key = id, segs = {seg(Text.fit(name, 9), t.text), Rows.chip(wd, col, 10), seg(Text.fit(short(tt.fuel), 6), t.muted)}}})
            end
            if note then list[#list + 1] = function(p) P.add(p, {segs = {seg("  " .. note, t.muted)}}) end end
        end
    end
    return list
end

local function ago(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds < 60 then return ("%d s ago"):format(seconds) end
    if seconds < 3600 then return ("%d min ago"):format(math.floor(seconds / 60)) end
    if seconds < 86400 then return ("%d h ago"):format(math.floor(seconds / 3600)) end
    return ("%d d ago"):format(math.floor(seconds / 86400))
end

-- One turtle's card: what it said last and where it was then
local function turtle_card(t, id)
    local tt = S.turtles[id]
    local list = {}
    local function add(label, value, color)
        list[#list + 1] = function(p) P.add(p, Rows.status(label, value, color or t.info, t)) end
    end
    if not tt then
        list[1] = function(p) P.line(p, t.muted, "not heard of") end
        return list
    end
    local alive = R.alive(id)
    local wd = alive and (tt.word or "?") or "lost"
    list[#list + 1] = function(p)
        P.add(p, {segs = {seg(Text.fit(tt.label or ("#" .. id), 10), t.text), Rows.chip(wd, alive and (t[COLOR[wd] or "text"] or t.text) or t.bad, 12)}})
    end
    if tt.note then add("Note", tostring(tt.note)) end
    add("At", tt.x and ("%d %d %d"):format(tt.x, tt.y, tt.z) or "--", alive and t.ok or t.warn)
    if type(tt.home) == "table" and tt.home.x then add("Home", ("%d %d %d"):format(tt.home.x, tt.home.y, tt.home.z)) end
    add("Seen", tt.seen and ago(now() - tt.seen) or "--", alive and t.ok or t.bad)
    add("Fuel", short(tt.fuel))
    if tt.free then add("Free", ("%d slots"):format(tt.free)) end
    if tt.band and tt.row and S.job and tt.job == S.job.id then add("Row", ("level %d, row %d"):format(tt.band, tt.row - S.job.cx)) end
    add("Code", "v" .. tostring(tt.ver or 1))
    add("ID", "#" .. tostring(id))
    return list
end

local function turtles_page(state, context)
    local p = P.page(context)
    if S.pick then
        for _, row in ipairs(turtle_card(p.t, S.pick)) do row(p) end
        bottom_button(p, "kp_turtle_back", "BACK", p.t.accent)
    else
        for _, row in ipairs(turtle_rows(p.t, p.c.rect.width)) do row(p) end
    end
    return P.finish(p)
end

-- One tab inside another app (the PDA on 120, 39x13): Dig Shell Turtles
-- as one strip on the first row, START PAUSE STOP on one
-- footer row, FINISH THIS LEVEL over the rule, the rows between scrolled by
-- the wheel (K.scroll). The turtle count is the Turtles list's first row and
-- the Dig banner (39 columns do not fit a count on the tab itself).
S.view, S.top = "dig", {dig = 1, shell = 1, turtles = 1}

local function tab_page(state, context)
    local p = P.page(context)
    local t = p.t
    local busy = S.job ~= nil
    local sure_start, sure_stop = sure("start"), sure("stop")
    P.bar(p, {
        {"kp_start", sure_start and "SURE?" or "START", busy and t.border or (sure_start and t.warn or t.ok)},
        S.paused and {"kp_resume", "RESUME", busy and t.ok or t.border} or {"kp_pause", "PAUSE", busy and t.warn or t.border},
        {"kp_stop", sure_stop and "SURE?" or "STOP", busy and t.bad or t.border},
    }, 2)
    if S.info and now() <= S.info.t then P.notice(p, S.info.text, t.warn) end
    -- the three tabs as one strip (the state word is on the Dig banner)
    P.segments(p, "kp_view", {{"dig", "Dig"}, {"shell", "Shell"}, {"turtles", "Turtles"}}, S.view)
    local rows
    if S.sub then rows = sub_rows(t)
    elseif S.view == "turtles" and S.pick then rows = turtle_card(t, S.pick)
    elseif S.view == "turtles" then rows = turtle_rows(t, p.c.rect.width)
    elseif S.view == "shell" then rows = shell_rows(t)
    else rows = dig_rows(t, math.max(6, p.c.rect.width - 22)) end
    local id, label, color
    if S.sub then id, label, color = "kp_sub_back", "BACK", t.accent
    elseif S.view == "dig" then id, label, color = finish_button(t)
    elseif S.view == "turtles" and S.pick then id, label, color = "kp_turtle_back", "BACK", t.accent end
    local room = math.max(1, P.left(p) - (id and 1 or 0))
    local key = S.sub and "sub" or S.view
    local top = math.max(1, math.min(S.top[key] or 1, #rows - room + 1))
    S.top[key] = top
    for n = top, math.min(#rows, top + room - 1) do rows[n](p) end
    if id then bottom_button(p, id, label, color) end
    return P.finish(p)
end

local function pages()
    return {{name = "Dig", page = dig_page}, {name = "Shell", page = shell_page}, {name = "Turtles", page = turtles_page}}
end

local LIMIT = {radius = {1, G.MAX_RADIUS}, depth = {0, 300}}
-- Up steps: a few small ones, then bigger, then all the way to the top
R.UPS = {0, 3, 6, 9, 12, 15, 21, 30, 45, 60, 90, 120, "all"}
function R.on_action(action)
    if action.type == "change" and action.id == "kp_block" and S.sub and S.sub.kind == "blocks" then
        if not S.job then
            S[SURFACE_KEY[S.sub.surface]] = action.value == "-" and "" or action.value
            R.save_settings()
        end
        S.sub = nil
        return
    end
    if action.type == "change" and action.id == "kp_view" then
        S.view, S.pick, S.sub = action.value, nil, nil
        return
    end
    if action.type == "change" and action.id == "kp_turtle" then
        S.pick = action.value
        S.top[S.view] = 1
        return
    end
    if action.type ~= "activate" then return end
    local id = tostring(action.id or ""):match("^kp_(.+)$")
    if not id then return end
    local key, sign = id:match("^(%a+)_(%a+)$")
    if key == "up" and (sign == "minus" or sign == "plus") then
        if S.job then return end
        local at = 1
        for i, v in ipairs(R.UPS) do if v == S.up then at = i end end
        S.up = R.UPS[math.max(1, math.min(#R.UPS, at + (sign == "plus" and 1 or -1)))]
        R.save_settings() return
    end
    if key and LIMIT[key] and (sign == "minus" or sign == "plus") then
        if S.job then return end
        local step = key == "depth" and 3 or (S.radius < 10 and 1 or 5)
        if key == "radius" and sign == "minus" and S.radius <= 10 then step = 1 end
        local v = S[key] + (sign == "plus" and step or -step)
        local hi = key == "radius" and G.max_size(S.shape) or LIMIT[key][2]
        S[key] = math.max(LIMIT[key][1], math.min(hi, v))
        R.save_settings() return
    end
    if id == "walls" or id == "roof" or id == "floor" then
        if not S.job then S[id] = not S[id] R.save_settings() end
        return
    end
    if id == "shape" then
        if not S.job then
            S.shape = S.shape == "square" and "circle" or "square"
            S.radius = math.min(S.radius, G.max_size(S.shape))
            R.save_settings()
        end
        return
    end
    if id == "last" then   -- finish the band being dug now and stop there (owner 2026-11-03)
        if S.job and not S.job.finished then
            Plan.last_band(S.job, not S.job.last_band)
            log(S.job.last_band and ("finish after band %d"):format(S.job.band) or "dig all bands")
            R.save_settings()
        end
        return
    end
    -- the Shell tab: the mode, how a block is picked, what gets replaced, and
    -- one block per surface. All fixed while a job runs (they were handed out
    -- with START), so the rows are locked then.
    if id == "mode" then
        if not S.job then S.mode = S.mode == "dig" and "builder" or "dig" R.save_settings() end
        return
    end
    if id == "order" then
        if not S.job then S.order = S.order == "bulk" and "priority" or "bulk" R.save_settings() end
        return
    end
    if id == "replace" then
        if not S.job then
            local at = 1
            for i, v in ipairs(Shell.REPLACE) do if v == S.replace then at = i end end
            S.replace = Shell.REPLACE[at % #Shell.REPLACE + 1]
            R.save_settings()
        end
        return
    end
    if id == "supply" then
        if not S.job then
            local at = 1
            for i, v in ipairs(Shell.SUPPLY) do if v == S.supply then at = i end end
            S.supply = Shell.SUPPLY[at % #Shell.SUPPLY + 1]
            R.save_settings()
        end
        return
    end
    if id == "block_walls" or id == "block_roof" or id == "block_floor" then
        if not S.job then S.sub = {kind = "blocks", surface = id:sub(7)} S.top.sub = 1 end
        return
    end
    if id == "height_top" or id == "height_floor" then
        if not S.job then S.sub = {kind = "height", which = id:sub(8)} S.top.sub = 1 end
        return
    end
    if id == "sub_back" then S.sub = nil return end
    if S.sub and S.sub.kind == "height" and id:match("^h_") then
        if S.job then return end
        local top, floor, feet = R.heights()
        local which = S.sub.which
        local v = which == "top" and top or floor
        local step = ({h_m10 = -10, h_m1 = -1, h_p1 = 1, h_p10 = 10})[id]
        if step then v = v + step
        elseif id == "h_here" then v = feet
        elseif id == "h_end" then v = which == "top" and R.highest() or R.lowest() end
        if which == "top" then S.topY = math.max(feet, math.min(R.highest(), v))
        else S.floorY = math.min(feet, math.max(R.lowest(), v)) end
        R.save_settings()
        return
    end
    if id == "turtle_back" then S.pick = nil return end
    if id == "continue" then
        if S.job and Plan.continue(S.job) then
            log(("continue with band %d"):format(S.job.band))
            S.paused = false
            send_all({t = "resume"})
            R.save_settings()
        end
        return
    end
    if id == "world" then
        if not S.job then S.nether = not S.nether R.save_settings() end
        return
    end
    if id == "start" and not S.job and S.me then
        if sure("start") then S.sure = nil R.start() else S.sure = {id = "start", t = now() + SURE} end
    elseif id == "stop" and S.job then
        if sure("stop") then S.sure = nil R.stop() else S.sure = {id = "stop", t = now() + SURE} end
    elseif id == "pause" and S.job and not S.paused then R.set_paused(true)
    elseif id == "resume" and S.job and S.paused then R.set_paused(false) end
end

-- Mounting ----------------------------------------------------------------------

local K = {R = R, S = S, pages = pages, tab = function(name) return {name = name or "Mine", page = tab_page} end, on_action = R.on_action, locate = R.tick, PROTO = PROTO}

local function save_turtles()
    local out = {}
    for id, tt in pairs(S.turtles) do
        local o = {}
        for _, k in ipairs(KEEP) do o[k] = tt[k] end
        out[id] = o
    end
    local f = fs.open(TURTLES_FILE, "w")
    if f then f.write(textutils.serialize(out, {compact = true})) f.close() end
end

local function load_turtles()
    if not fs.exists(TURTLES_FILE) then return end
    local f = fs.open(TURTLES_FILE, "r")
    local ok, t = pcall(textutils.unserialize, f.readAll())
    f.close()
    if ok and type(t) == "table" then
        for id, tt in pairs(t) do if type(id) == "number" and type(tt) == "table" and not S.turtles[id] then S.turtles[id] = tt end end
    end
end

-- once at boot: the saved job, the turtles as they were, the radio
function K.init()
    S.job = load_job()
    load_turtles()
    S.paused = S.job ~= nil and settings.get("kopach.paused", false) or false
    local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if modem then
        local name = peripheral.getName(modem)
        if not rednet.isOpen(name) then rednet.open(name) end
        S.modem = true
    end
    log("remote start")
    booted = now()
    chat = Chat.new(peripheral.find("chat_box"), peripheral.find("playerDetector"), now)
end

-- another chat service instead of this computer's Chat Box: fn(key, params);
-- News.uk / News.en / News.rules are the templates and rules (kopach/news.lua)
K.NEWS = News
function K.on_news(fn) news_sink = fn end

-- any event; true when it was ours and the screen should redraw
function K.on_event(name, a, b, c)
    if name == "rednet_message" and c == PROTO then return R.on_message(a, b) end
    return false
end

-- the mouse wheel over the tab: dir rows down (+) or up (-)
function K.scroll(dir)
    local key = S.sub and "sub" or S.view
    S.top[key] = math.max(1, (S.top[key] or 1) + dir)
end

-- once a second: who is there, and the pause state again for turtles that missed it
local ping = 0
function K.second()
    R.flush()
    ping = ping + 1
    -- who is there: at boot and once a minute (the turtles beat by themselves);
    -- the pause state again every 15 s for one that missed it
    if ping % 60 == 1 then send_all({t = "ping"}) end
    if S.job and ping % 15 == 3 then send_all({t = S.paused and "pause" or "resume"}) end
    if chat and not chat.box and ping % 10 == 0 then chat.box = peripheral.find("chat_box") end   -- put in later
    if ping % 30 == 0 then save_turtles() end
    Chat.tick(chat)
    -- a turtle that went quiet while a job runs: once, until it answers again
    if S.job and not S.job.finished and not S.paused then
        for id, tt in pairs(S.turtles) do
            if R.alive(id) then tt.quiet = nil
            elseif not tt.quiet then tt.quiet = true news("kopach.lost", {turtle = who(id)}) end
        end
    end
end

return K
