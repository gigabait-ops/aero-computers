-- Colony Supply: moves everything from one inventory into a list of target inventories.
--
-- All inventories must hang on the same wired modem network; `source.pushItems`
-- is called with each target's peripheral NAME. Pure, testable: the source and
-- targets are injected.

local Deliver = {}
Deliver.__index = Deliver

function Deliver.new(deps)
    deps = deps or {}
    assert(type(deps.source) == "table", "deliver needs a source inventory")
    local self = setmetatable({}, Deliver)
    self.source = deps.source
    self.targets = deps.targets or {}     -- list of peripheral names
    self.log = deps.log or {info = function() end, warn = function() end}
    return self
end

-- Returns moved count and a list of stacks that found no room.
function Deliver:run()
    local ok, slots = pcall(self.source.list)
    if not ok or type(slots) ~= "table" then
        return 0, {}, "source: " .. tostring(slots)
    end
    local moved, stuck = 0, {}
    for slot, stack in pairs(slots) do
        local remaining = tonumber(type(stack) == "table" and stack.count) or 0
        for _, target in ipairs(self.targets) do
            if remaining <= 0 then break end
            local okPush, n = pcall(self.source.pushItems, target, slot, remaining)
            if okPush and type(n) == "number" and n > 0 then
                remaining = remaining - n
                moved = moved + n
            end
        end
        if remaining > 0 then
            table.insert(stuck, {slot = slot, name = stack.name, count = remaining})
        end
    end
    if moved > 0 then self.log.info("MOVED", moved, "items into", #self.targets, "targets") end
    if #stuck > 0 and #stuck ~= self.lastStuck then
        self.log.warn("NO_ROOM", #stuck, "stacks stay in the source")
    end
    self.lastStuck = #stuck
    return moved, stuck
end

return Deliver
