-- PC11: TUF storage agent. It counts the inventories next to it every
-- second and broadcasts the counts to PC124 ("snapshotPush" on the storage
-- protocol, the same message as before) when they change, and at least
-- every `beat` seconds so PC124 knows it is alive.
local Lib = require("ui")
local config = require("tuf.config")
local N = require("tuf.net")

local Agent = {}

Agent.SCAN = 1

local Rows, Text = Lib.Rows, Lib.Text

-- every inventory but the modems' own ports
function Agent.scan(api)
    api = api or peripheral
    local counts, sources, used, slots = {}, {}, 0, 0
    for _, name in ipairs(api.getNames()) do
        if api.hasType(name, "inventory") then
            local okSize, size = pcall(api.call, name, "size")
            local okList, items = pcall(api.call, name, "list")
            if okSize and okList then
                local u = 0
                for _, it in pairs(items or {}) do
                    counts[it.name] = (counts[it.name] or 0) + it.count
                    u = u + it.count
                end
                sources[#sources + 1] = {name = name, used = u, slots = tonumber(size) or 0}
                used, slots = used + u, slots + (tonumber(size) or 0)
            end
        end
    end
    table.sort(sources, function(a, b) return a.name < b.name end)
    return {counts = counts, sources = sources, used = used, slots = slots}
end

local function page(st, context)
    local t = context.theme
    local rows = {}
    local function status(label, value, color)
        rows[#rows + 1] = {segs = {Rows.segment(string.char(7) .. " ", color),
            Rows.segment(Text.fit(label, 11), t.muted), Rows.segment(value, t.text)}}
    end
    local s = st.snap or {sources = {}, used = 0, slots = 0}
    status("Role", "storage report for PC" .. tostring(config.network.server or "?"), t.ok)
    status("Modems", st.modems ~= "" and st.modems or "MISSING", st.modems ~= "" and t.ok or t.bad)
    status("Storage", ("%d inventories  %d slots"):format(#s.sources, s.slots), #s.sources > 0 and t.ok or t.bad)
    status("Items", tostring(s.used), t.ok)
    local age = (tonumber(context.now) or 0) - (tonumber(st.sentAt) or 0)
    status("Last sent", st.sentAt and (Text.age(age) .. " ago  #" .. tostring(st.seq)) or "not yet", st.sentAt and t.ok or t.warn)
    return rows
end

function Agent.run()
    local net = config.network
    local host = "tuf-storage-" .. os.getComputerID()
    local modems = N.open()
    if #modems == 0 then error("PC11 needs a modem") end
    pcall(rednet.host, net.storageProtocol, host)
    local st = {modems = table.concat(modems, ","), seq = 0, interval = net.beat}
    local app = Lib.App.new({pages = {{name = "Storage", page = page}}, state = st, interval = 1,
        adapters = {clock = N.clock, isMonitor = function() return false end}})
    local lastKey

    local function work()
        while true do
            local snap = Agent.scan()
            st.snap = snap
            local key = textutils.serialize(snap.counts, {compact = true})
            local now = N.clock()
            if key ~= lastKey or now - (st.sentAt or 0) >= net.beat then
                st.seq = st.seq + 1
                rednet.broadcast({protocol = net.storageProtocol, type = "snapshotPush", sequence = st.seq,
                    time = os.epoch("utc"), hostname = host, computerId = os.getComputerID(), ok = #snap.sources > 0,
                    used = snap.used, slots = snap.slots, sources = #snap.sources, counts = snap.counts,
                    sourceDetails = snap.sources}, net.storageProtocol)
                lastKey, st.sentAt = key, now
            end
            if app then app:render(st) end
            sleep(Agent.SCAN)
        end
    end

    local function screen()
        while true do
            local event = {os.pullEvent()}
            if app then app:handle(table.unpack(event)) end
        end
    end

    parallel.waitForAny(work, screen)
end

return Agent
