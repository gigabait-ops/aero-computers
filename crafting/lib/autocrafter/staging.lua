local Staging = {}
local identity = require("autocrafter.recipe_grid").identity

-- Error texts of a craft that stopped on its staged inputs (missing, moved or
-- changed items). TurtleIO waits on them; the executor also tries another recipe.
Staging.INPUT_FAILURES = {"missing input", "input pull", "input reorder", "wrong item", "staging changed"}

function Staging.inputFailure(text)
    text = tostring(text or "")
    for _, fragment in ipairs(Staging.INPUT_FAILURES) do
        if text:find(fragment, 1, true) then return true end
    end
    return false
end

-- Bind concrete alternatives before moving items; a grid slot cannot mix them.
function Staging.allocate(entries, items, cap, io)
    local stock, kinds, choices = {}, {}, {}
    for _, item in ipairs(items) do
        local key = identity(item)
        stock[key] = (stock[key] or 0) + item.count
        kinds[key] = item
    end
    local totals = {}
    for key, count in pairs(stock) do totals[key] = count end
    for _, entry in ipairs(entries) do
        local item = io.detail(entry.slot)
        if item and io.count(entry.slot) > 0 then
            local key = identity(item)
            kinds[key] = item
            totals[key] = (totals[key] or 0) + io.count(entry.slot)
        end
    end
    for _, entry in ipairs(entries) do
        local current = io.detail(entry.slot)
        local row = {slot = entry.slot, count = io.count(entry.slot), candidates = {}}
        if row.count > 0 then
            if not current or not io.matches(current, entry.ingredient) then return nil, "wrong staged item" end
            row.candidates[1] = identity(current)
            kinds[row.candidates[1]] = current
        else
            for key, item in pairs(kinds) do
                if io.matches(item, entry.ingredient) then row.candidates[#row.candidates + 1] = key end
            end
            table.sort(row.candidates, function(a, b)
                if stock[a] ~= stock[b] then return (stock[a] or 0) > (stock[b] or 0) end
                return a < b
            end)
        end
        choices[#choices + 1] = row
    end
    table.sort(choices, function(a, b)
        if #a.candidates ~= #b.candidates then return #a.candidates < #b.candidates end
        return a.slot < b.slot
    end)
    -- Do not search batch sizes that no concrete stack can hold.
    for _, row in ipairs(choices) do
        local capacity = 0
        for _, key in ipairs(row.candidates) do
            capacity = math.max(capacity, math.min(
                tonumber(kinds[key].maxCount) or 64,
                (totals[key] or 0)))
        end
        cap = math.min(cap, capacity)
    end
    local visits, rejection, fatal, acceptedCrafts = 0, false, nil, nil
    for crafts = cap, 1, -1 do
        local remaining, assigned = {}, {}
        for key, count in pairs(stock) do remaining[key] = count end
        for _, row in ipairs(choices) do
            if row.count > crafts then
                local key = row.candidates[1]
                remaining[key] = (remaining[key] or 0) + row.count - crafts
            end
        end
        local function choose(index)
            visits = visits + 1
            if fatal or visits > 20000 then return false end
            if visits % 128 == 0 and io.yield then io.yield() end
            local row = choices[index]
            if not row then
                if not io.accept then return true end
                local accepted, err, limit = io.accept(assigned, crafts, kinds, totals)
                if accepted == nil then fatal = err or "native recipe evaluation failed" end
                if accepted == false then rejection = true end
                if accepted then acceptedCrafts = math.min(crafts, limit or crafts) end
                return accepted == true
            end
            local need = math.max(0, crafts - row.count)
            for _, key in ipairs(row.candidates) do
                local capacity = tonumber(kinds[key].maxCount) or 64
                if crafts <= capacity and (remaining[key] or 0) >= need then
                    remaining[key] = (remaining[key] or 0) - need
                    assigned[row.slot] = key
                    if choose(index + 1) then return true end
                    assigned[row.slot] = nil
                    remaining[key] = remaining[key] + need
                end
            end
            return false
        end
        if choose(1) then return assigned, acceptedCrafts or crafts, kinds, totals end
        if fatal then return nil, fatal end
        if visits > 20000 then return nil, "input allocation search limit" end
    end
    return nil, rejection and "recipe validation failed: no matching input combination" or "missing input"
end

function Staging.stage(entries, cap, io)
    local refreshes = 0
    local function resync(reason)
        refreshes = refreshes + 1
        if io.resync then io.resync(reason, refreshes) end
        if refreshes >= 32 then return false end
        if io.pause then io.pause() elseif io.yield then io.yield() end
        return true
    end
    local function stalled(reason)
        return false, "input staging stalled: " .. tostring(reason)
    end
    local assigned, crafts, kinds, totals
    repeat
        assigned, crafts, kinds, totals = Staging.allocate(entries, io.list(), cap, io)
        if not assigned then
            if crafts ~= "missing input" then return false, crafts end
            if not resync("waiting for delivered stacks") then return false, "missing input" end
        end
    until assigned
    refreshes = 0

    local groups, lowest, highest = {}, 64, 1
    for _, entry in ipairs(entries) do
        local key = assigned[entry.slot]
        local group = groups[key]
        if not group then
            group = {slots = {}, limit = math.max(1, math.min(64,
                tonumber(kinds[key].maxCount) or 64))}
            groups[key] = group
        end
        group.slots[#group.slots + 1] = entry.slot
        lowest, highest = math.min(lowest, group.limit), math.max(highest, group.limit)
    end
    local mixed, goals = lowest < highest, {}
    if mixed then
        for key, group in pairs(groups) do
            local perSlot = math.min(tonumber(io.preloadCrafts) or cap, group.limit,
                math.floor(totals[key] / #group.slots))
            for _, slot in ipairs(group.slots) do goals[slot] = math.max(crafts, perSlot) end
        end
    end
    local function wanted(slot) return goals[slot] or crafts end
    -- Keep prefilled stackable cells through the entire mixed-capacity series.
    local function redistribute(targets)
        for _, target in ipairs(entries) do
            for _, source in ipairs(entries) do
                local missing = (targets[target.slot] or crafts) - io.count(target.slot)
                local extra = io.count(source.slot) - (targets[source.slot] or crafts)
                if missing > 0 and extra > 0 and assigned[target.slot] == assigned[source.slot] then
                    if not io.transfer or not io.transfer(source.slot, target.slot, math.min(missing, extra)) then
                        return false, "staged ingredient redistribution blocked"
                    end
                end
            end
        end
        return true
    end
    local distributed, distributionError = redistribute(goals)
    if not distributed then return false, distributionError end
    local function receiver(item)
        local key = identity(item)
        for _, entry in ipairs(entries) do
            local limit = wanted(entry.slot)
            if assigned[entry.slot] == key and io.count(entry.slot) < limit then
                return entry.slot, limit
            end
        end
    end
    local function complete()
        for _, entry in ipairs(entries) do
            if io.count(entry.slot) < wanted(entry.slot) then return false end
        end
        return true
    end

    -- io.push moves a listed chest stack straight into its recipe cell.
    while not complete() do
        local source, target, limit
        local priority = -1
        for _, item in ipairs(io.list()) do
            local candidate, candidateLimit = receiver(item)
            local capacity = tonumber(item.maxCount) or 64
            if candidate and (not mixed or capacity > priority) then
                source, target, limit, priority = item, candidate, candidateLimit, capacity
                if not mixed then break end
            end
        end
        if not source then
            local reason = "requested stacks not visible"
            if not resync(reason) then return stalled(reason) end
        else
            local before = io.count(target)
            local _, err, fatal = io.push(source, target, math.min(source.count, limit - before))
            if fatal then return false, err end
            local received = io.count(target) - before
            if received > 0 then
                local after = io.detail(target)
                if not after or identity(after) ~= assigned[target] then
                    if not io.drop(target, received) then
                        return false, "input blocked returning changed source"
                    end
                    local reason = "source identity changed during transfer"
                    if not resync(reason) then return stalled(reason) end
                else
                    if io.count(target) > limit and not io.drop(target, io.count(target) - limit) then
                        return false, "input blocked returning excess"
                    end
                    refreshes = 0
                end
            else
                local reason = err or "source transfer made no progress"
                if not resync(reason) then return stalled(reason) end
            end
        end
    end
    if mixed then
        local balanced = {}
        for _, group in pairs(groups) do
            local total = 0
            for _, slot in ipairs(group.slots) do total = total + io.count(slot) end
            local perSlot, remainder = math.floor(total / #group.slots), total % #group.slots
            for index, slot in ipairs(group.slots) do
                balanced[slot] = perSlot + (index <= remainder and 1 or 0)
            end
        end
        distributed, distributionError = redistribute(balanced)
        if not distributed then return false, distributionError end
    end
    return true, nil, crafts
end

return Staging
