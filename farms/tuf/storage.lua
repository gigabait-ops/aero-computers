-- Farm storage: the vaults wired to PC124 plus the latest report of each
-- storage agent (PC11 over rednet). Fullness is items over slots x stack
-- size.
local St = {}

local function hasAnyType(api, name, types)
    for _, t in ipairs(types) do
        if api.hasType(name, t) then return true end
    end
    return false
end

-- The vaults -> {name, used, slots, counts}. A vault whose read fails keeps
-- its last good read (cache) for `keep` cycles, so one failed call does not
-- make its items count as empty.
function St.scan(config, api, cache, keep)
    api = api or peripheral
    cache = cache or {}
    keep = keep or 10
    local list = {}
    for _, name in ipairs(api.getNames()) do
        if hasAnyType(api, name, config.storageTypes or {"create:item_vault"}) then
            local okSize, slots = pcall(api.call, name, "size")
            local okList, items = pcall(api.call, name, "list")
            if okSize and okList then
                local counts, used = {}, 0
                for _, it in pairs(items or {}) do
                    counts[it.name] = (counts[it.name] or 0) + it.count
                    used = used + it.count
                end
                cache[name] = {name = name, used = used, slots = tonumber(slots) or 0, counts = counts, misses = 0}
                list[#list + 1] = cache[name]
            elseif cache[name] and cache[name].misses < keep then
                cache[name].misses = cache[name].misses + 1
                list[#list + 1] = cache[name]
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- An agent report (tuf/agent.lua, type "snapshotPush") -> stored report
function St.acceptPush(config, reports, sender, message, now)
    if type(message) ~= "table" or message.type ~= "snapshotPush" then return false end
    local allowed = false
    for _, id in ipairs(config.network.agents or {}) do
        if tonumber(id) == tonumber(sender) then allowed = true end
    end
    if not allowed then return false end
    local sources = {}
    for _, s in ipairs(message.sourceDetails or {}) do
        sources[#sources + 1] = {name = s.name, used = tonumber(s.used) or 0, slots = tonumber(s.slots) or 0}
    end
    if #sources == 0 then
        sources[1] = {name = "storage", used = tonumber(message.used) or 0, slots = tonumber(message.slots) or 0}
    end
    reports[sender] = {at = now, counts = message.counts or {}, sources = sources}
    return true
end

-- Own vaults and agent reports -> storage for plan/view:
-- {ok, used, max, percent, counts, sources = {{id, label, used, max}}, remote}
-- remote: true while every agent answers, false when one does not, nil
-- with no agents. An old report still counts (its items did not vanish).
function St.total(config, list, reports, now)
    local stack = config.stack or 64
    local labels = config.storageLabels or {}
    local net = config.network or {}
    local stale = net.storageStale or 15
    local counts, sources, used, max = {}, {}, 0, 0
    local function add(id, label, itemCounts, u, slots)
        for item, n in pairs(itemCounts or {}) do counts[item] = (counts[item] or 0) + n end
        sources[#sources + 1] = {id = id, label = labels[id] or label, used = u, max = slots * stack}
        used, max = used + u, max + slots * stack
    end
    for _, v in ipairs(list) do add("local:" .. v.name, "Vault", v.counts, v.used, v.slots) end
    local remote = nil
    for _, id in ipairs(net.agents or {}) do
        local r = (reports or {})[id]
        if r then
            if now - r.at <= stale then remote = remote ~= false else remote = false end
            for i, s in ipairs(r.sources) do
                add(("remote:%d:%s"):format(id, s.name), "PC" .. id .. " vault", i == 1 and r.counts or nil, s.used, s.slots)
            end
        else
            remote = false
        end
    end
    return {ok = #sources > 0, used = used, max = max, percent = max > 0 and math.floor(used * 100 / max) or 0,
        counts = counts, sources = sources, remote = remote}
end

return St
