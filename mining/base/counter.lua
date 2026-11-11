-- PC121's counter (owner 2026-11-06): the stock lives in the diamond chest
-- (PC48's deliveries come there, the packager is on it), the barrel linked
-- with the mining turtles only takes what they unload and gives out what one
-- of them asks for; the rest goes to the outbox, a chest linked with the
-- warehouse. A turtle can take only the barrel's
-- first stack (turtle.suck), and the barrel puts an item with the stack it
-- already has whatever slot it is sent to; so for each ask slot 1 is
-- emptied, that item is moved out of the barrel, and then the asked count
-- goes in: it lands in slot 1, the turtle takes it.
-- call(name, method, ...) -> result or nil (peripheral.call under pcall).
local C = {}

C.MOVE_CALLS = 80      -- a stack of 1000+ moves 64 a call
C.MAX_ASK = 256

local function counts(items)
    local total = {}
    for _, item in pairs(items or {}) do total[item.name] = (total[item.name] or 0) + item.count end
    return total
end
C.counts = counts

function C.new(call)
    local c = {}
    local function list(name) return call(name, "list") or {} end
    c.list = list

    -- everything in `slot` of `from` into `to`; true when the slot is empty
    local function move_all(from, slot, to)
        for _ = 1, C.MOVE_CALLS do
            local it = list(from)[slot]
            if not it then return true end
            local n = call(from, "pushItems", to, slot) or 0
            if n == 0 then return false end
        end
        return list(from)[slot] == nil
    end
    c.move_all = move_all

    -- d = {barrel, stock, outbox}; req = {item, count} -> {t = "ready", count} | {t = "none"} | {t = "busy", why}
    function c.serve(d, req)
        local item = type(req.item) == "string" and req.item or nil
        if not item then return {t = "none"} end
        local want = math.max(1, math.min(math.floor(tonumber(req.count) or 1), C.MAX_ASK))
        local b = list(d.barrel)
        if (counts(list(d.stock))[item] or 0) == 0 and (counts(b)[item] or 0) == 0 then return {t = "none"} end
        if b[1] and b[1].name ~= item and not move_all(d.barrel, 1, d.stock) then
            return {t = "busy", why = "slot 1 does not empty"}
        end
        for slot, it in pairs(b) do
            if slot ~= 1 and it.name == item and not move_all(d.barrel, slot, d.stock) and d.outbox then
                move_all(d.barrel, slot, d.outbox)   -- the stock is full of it
            end
        end
        b = list(d.barrel)
        for slot, it in pairs(b) do
            if slot ~= 1 and it.name == item then return {t = "busy", why = "the item stays in the barrel"} end
        end
        if b[1] and b[1].name ~= item then return {t = "busy", why = "slot 1 taken again"} end
        local have, calls = b[1] and b[1].count or 0, 0
        for slot, it in pairs(list(d.stock)) do
            if have >= want then break end
            if it.name == item then
                while have < want and calls < want + 8 do
                    calls = calls + 1
                    local n = call(d.barrel, "pullItems", d.stock, slot, want - have, 1) or 0
                    if n == 0 then break end
                    have = have + n
                end
            end
        end
        local front = list(d.barrel)[1]
        if not (front and front.name == item) then return {t = "busy", why = "it went elsewhere"} end
        return {t = "ready", count = front.count}
    end

    -- What the turtles unloaded that is kept goes to the stock, up to keep;
    -- the rest, and what the stock has over keep, to the outbox. busy() is
    -- asked between the moves: an ask waits for nothing. -> moved per item
    function c.sort(d, keep, busy)
        local moved, have = {}, counts(list(d.stock))
        for slot, it in pairs(list(d.barrel)) do
            if busy() then break end
            local room = (keep[it.name] or 0) - (have[it.name] or 0)
            local left = it.count
            for _ = 1, C.MOVE_CALLS do
                if room <= 0 or left <= 0 or busy() then break end
                local n = call(d.barrel, "pushItems", d.stock, slot, math.min(room, left)) or 0
                if n == 0 then break end
                room, left = room - n, left - n
                have[it.name] = (have[it.name] or 0) + n
                moved[it.name] = (moved[it.name] or 0) + n
            end
            if left > 0 and d.outbox and not busy() then move_all(d.barrel, slot, d.outbox) end
        end
        if d.outbox then
            local stay = {}
            for name, n in pairs(keep) do stay[name] = n end
            for slot, it in pairs(list(d.stock)) do
                if busy() then break end
                local keepHere = math.min(it.count, stay[it.name] or 0)
                if stay[it.name] then stay[it.name] = stay[it.name] - keepHere end
                if it.count > keepHere then call(d.stock, "pushItems", d.outbox, slot, it.count - keepHere) end
            end
        end
        return moved
    end

    return c
end

return C
