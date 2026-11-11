-- The farm view the pages draw (tuf/ui.lua): only what they show.
local P = require("tuf.plan")

local V = {}

local ITEMS_SHOWN = 60

local function label(s)
    if s.label then return s.label end
    local name = tostring(s.item or "?"):gsub("^[%w_]+:", ""):gsub("_", " ")
    return (name:gsub("^%l", string.upper))
end

-- decision (plan.decide), storage (storage.total), channels (after
-- links:apply), bridge name, settings
function V.build(config, decision, storage, channels, bridge, state)
    local byName = {}
    for _, ch in ipairs(channels) do byName[ch.name] = ch end
    local factories = {}
    for _, d in ipairs(decision.factories) do
        local f = d.factory
        local out = {name = f.name, label = f.label, mode = d.mode, parallel = f.parallel or nil, stages = {}}
        if f.base then
            out.base = {item = f.base.item, count = tonumber(storage.counts[f.base.item]) or 0,
                limit = P.baseLimit(f, state)}
        end
        if f.resources then
            out.resources = {}
            for _, r in ipairs(f.resources) do
                local from = r.from and P.factory(config, r.from)
                out.resources[#out.resources + 1] = {key = r.key, item = r.item, editable = r.editable or nil,
                    count = tonumber(storage.counts[r.item]) or 0, limit = P.resourceLimit(config, f, r, state),
                    from = from and from.label or nil}
            end
        end
        for _, s in ipairs(d.stages) do
            local ch = byName[s.name] or {}
            local st = s.state
            if ch.err then st = "link" end
            out.stages[#out.stages + 1] = {name = s.name, label = label(s), item = s.item, count = s.count,
                limit = s.limit, priority = s.priority, state = st, need = s.need, feeds = s.feeds,
                manual = s.manual, want = ch.want, read = ch.read}
        end
        factories[#factories + 1] = out
    end
    local items = {}
    for item, n in pairs(storage.counts) do
        if n > 0 then items[#items + 1] = {item, n} end
    end
    table.sort(items, function(a, b)
        if a[2] == b[2] then return a[1] < b[1] end
        return a[2] > b[2]
    end)
    for i = #items, ITEMS_SHOWN + 1, -1 do items[i] = nil end
    local list = {}
    for _, ch in ipairs(channels) do
        list[#list + 1] = {name = ch.name, label = ch.label or label(ch), freq1 = ch.freq1, freq2 = ch.freq2,
            want = ch.want, read = ch.read, ok = ch.ok, held = ch.held or nil, err = ch.err}
    end
    local powerCh = byName[config.power.name] or {}
    return {
        power = {mode = decision.power.mode, reason = decision.power.reason, want = powerCh.want,
            read = powerCh.read, held = powerCh.held or nil},
        storage = {ok = storage.ok, used = storage.used, max = storage.max, percent = storage.percent,
            remote = storage.remote},
        stops = decision.stops,
        items = items,
        factories = factories,
        links = {bridge = bridge, list = list},
    }
end

return V
