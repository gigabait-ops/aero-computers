-- Mining turtle: listens to the remote (pocket PC) on the ender modem and
-- digs the rows it hands out. Takes commands from the remote's id only.
-- Install: tools/deploy_kopach.sh <turtle id>; startup.lua runs this file.
package.path = "/kopach/?.lua;" .. package.path
local Cfg = require("config")
local Miner = require("miner")
local Beat = require("beat")
local Supply = require("supply")

local PROTO = Cfg.protocol
local VERSION = 11  -- shown on the remote; 11: rows shared at the end of a band, lava and blocks from PC121
local STATE = "/kopach/state"

local function log(text)
    local path = "/kopach/log.txt"
    local f = fs.open(path, fs.exists(path) and fs.getSize(path) < 32000 and "a" or "w")
    if f then f.writeLine(("%s %s"):format(textutils.formatTime(os.time(), true), text)) f.close() end
end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("no ender modem") return end
rednet.open(peripheral.getName(modem))

-- the remotes it obeys (config: one id or a list); it answers the one it heard last
local REMOTES = type(Cfg.remote) == "table" and Cfg.remote or {Cfg.remote}
local trusted = {}
for _, id in ipairs(REMOTES) do trusted[id] = true end
local remote = REMOTES[1]

local ctl = {paused = false, stop = false}
local replies = {}   -- request id -> reply
local seq = 0

local link = {}
local pending
-- ask the remote for work; nil when it does not answer
function link.want(info)
    seq = seq + 1
    local id = seq
    info.t, info.req = "want", id
    info.dones = #pending > 0 and pending or nil
    replies[id] = nil
    rednet.send(remote, info, PROTO)
    local timer = os.startTimer(4)
    while true do
        if replies[id] then
            local r = replies[id] replies[id] = nil os.cancelTimer(timer)
            -- the reports it carried got there: forget them
            local ack = r.acked or 0
            for i = #pending, 1, -1 do if pending[i].dseq <= ack then table.remove(pending, i) end end
            return r
        end
        local ev, p = os.pullEvent()
        if ev == "timer" and p == timer then return nil end
    end
end
-- A done report lost (the remote busy at a band end, 41 turtles at once) left
-- the row busy: its digger was given its half again and walked it twice
-- (2026-11-08). Each report goes out at once and with every want until the
-- remote acknowledges it; dseq (ms clock) lets the remote skip repeats.
pending = {}
function link.done(job, band, x, left, part)
    local d = {t = "done", job = job, band = band, x = x, left = left, part = part, dseq = os.epoch("utc")}
    if #pending > 0 and d.dseq <= pending[#pending].dseq then d.dseq = pending[#pending].dseq + 1 end
    pending[#pending + 1] = d
    while #pending > 8 do table.remove(pending, 1) end
    rednet.send(remote, d, PROTO)
end
function link.fixed(job, results) rednet.send(remote, {t = "fixed", job = job, results = results}, PROTO) end

local env = {
    turtle = turtle,
    locate = function() return gps.locate(2) end,
    sleep = sleep,
    now = function() return os.epoch("utc") / 1000 end,
    load = function()
        if not fs.exists(STATE) then return nil end
        local f = fs.open(STATE, "r") local s = textutils.unserialize(f.readAll()) f.close()
        return s
    end,
    save = function(s) local f = fs.open(STATE, "w") f.write(textutils.serialize(s, {compact = true})) f.close() end,
    log = log,
    link = link,
    supply = Supply.new(),
    ctl = ctl,
    turtle_id = os.getComputerID(),
}
local m = Miner.new(env)

-- What the remote shows: the short form, or with `full` the inventory, home
-- and label too. When each goes out: kopach/beat.lua.
local function status(full)
    local st, p = m.st, m.st.pos or {}
    local s = {t = "hi", word = m.word, note = m.note, fuel = turtle.getFuelLevel(), x = p.x, y = p.y, z = p.z,
        job = st.job and st.job.id, band = st.band, row = st.x, dz = m.row_dz, ver = VERSION}
    if full then
        s.full, s.free, s.label, s.fills, s.home = true, m.free_slots(), os.getComputerLabel(), m.fills(), st.home
    end
    return s
end

local beats = Beat.new()
local function beat(asked)
    local st = m.st
    local key = tostring(m.word) .. "|" .. tostring(m.note) .. "|" .. tostring(st.band) .. "|" .. tostring(st.x)
    local kind = Beat.due(beats, os.clock(), key, asked)
    if kind then rednet.send(remote, status(kind == "full"), PROTO) end
end

-- radio: replies, pause/resume/stop, and the heartbeat (checked every second, sent as above)
local function radio()
    local tick = os.startTimer(0)
    while true do
        local ev = {os.pullEvent()}
        if ev[1] == "timer" and ev[2] == tick then
            beat(false)
            tick = os.startTimer(1)
        elseif ev[1] == "rednet_message" and ev[4] == PROTO and trusted[ev[2]] and type(ev[3]) == "table" then
            local msg = ev[3]
            remote = ev[2]
            if msg.t == "pause" then ctl.paused = true
            elseif msg.t == "resume" then ctl.paused = false ctl.stop = false os.queueEvent("kopach_wake")
            elseif msg.t == "stop" then ctl.stop = true ctl.paused = false
            elseif msg.t == "ping" then beat(true)
            elseif msg.t == "cut" then ctl.cut = {job = msg.job, band = msg.band, x = msg.x, z = msg.z}
            elseif msg.t == "reply" and msg.req then
                if msg.paused ~= nil then ctl.paused = msg.paused end
                replies[msg.req] = msg.reply
                os.queueEvent("kopach_reply")
            end
        end
    end
end

local function work()
    -- rebooted in the middle of a service: its barrel stands next to it (take it
    -- back before locate steps away from it)
    if not m.has_storage() then pcall(m.recover_storage) end
    while true do
        local ok, err = m.locate()
        if ok then break end
        local why = {["no gps"] = {"no gps"}, ["no fuel"] = {"no fuel", "give it a lava bucket"}, ["boxed in"] = {"boxed in", "free one side"}}
        local w = why[err] or {"error", tostring(err)}
        m.say(w[1], w[2])
        sleep(5)
    end
    while true do
        local ok, res = pcall(m.work_once)
        if not ok then
            if res == Miner.STOP then pcall(m.stopped)
            else m.say("error", tostring(res)) sleep(5) end
        elseif res ~= "row" then
            -- nothing to dig yet: ask again later (waiting for the band to end
            -- sooner than idle), or at once when the remote says go
            local timer = os.startTimer(res == "wait" and 4 or 8)
            while true do
                local e, a = os.pullEvent()
                if (e == "timer" and a == timer) or e == "kopach_wake" then break end
            end
            os.cancelTimer(timer)
        end
    end
end

local function screen()
    while true do
        term.clear() term.setCursorPos(1, 1)
        local p = m.st.pos or {}
        print("kopach #" .. os.getComputerID())
        print(m.word .. (m.note and (": " .. m.note) or ""))
        print(("fuel %s"):format(tostring(turtle.getFuelLevel())))
        if p.x then print(("at %d %d %d"):format(p.x, p.y, p.z)) end
        if ctl.paused then print("PAUSED") end
        sleep(1)
    end
end

log("start")
parallel.waitForAny(radio, work, screen)
