local Util = require("app.util")

local Selector = {}
Selector.__index = Selector

local unpackValues = table.unpack or unpack

local function normalizeItem(value)
    if type(value) ~= "table" then
        return nil
    end

    local name = value.name or value.item or value.id
    if type(name) ~= "string" or name == "" or name == "minecraft:air" then
        return nil
    end

    return {
        name = name,
        count = math.max(1, Util.integer(value.count, 1)),
        displayName = value.displayName,
        nbt = value.nbt,
    }
end

function Selector:new(logger)
    return setmetatable({
        logger = logger,
        device = nil,
        name = nil,
        slots = {},
        lastError = nil,
    }, self)
end

function Selector:setDevice(device, name)
    if self.name ~= name then
        self.slots = {}
        self.lastError = nil
    end

    self.device = device
    self.name = name
end

function Selector:read()
    if not self.device or type(self.device.getRequest) ~= "function" then
        self.slots = {}
        self.lastError = "redstone requester missing"
        return nil, self.lastError
    end

    local ok, raw = pcall(self.device.getRequest)
    if not ok or type(raw) ~= "table" then
        self.lastError = ok and "requester returned invalid data" or tostring(raw)
        return nil, self.lastError
    end

    local slots = {}
    for slot = 1, 9 do
        slots[slot] = normalizeItem(raw[slot] or raw[tostring(slot)])
    end

    self.slots = slots
    self.lastError = nil
    return slots
end

function Selector:syncDrafts(drafts)
    local slots, err = self:read()
    if not slots then
        return false, err
    end

    local changed = false

    for slot = 1, 9 do
        local key = tostring(slot)
        local item = slots[slot]
        local draft = drafts[key]

        if item then
            if not draft or draft.name ~= item.name or draft.nbt ~= item.nbt then
                drafts[key] = {
                    slot = slot,
                    name = item.name,
                    displayName = item.displayName,
                    sourceCount = item.count,
                    quantity = item.count,
                    nbt = item.nbt,
                }
                changed = true
            else
                if draft.displayName ~= item.displayName then
                    draft.displayName = item.displayName
                    changed = true
                end

                if draft.sourceCount ~= item.count then
                    draft.sourceCount = item.count
                    changed = true
                end

                if not draft.jobId and draft.quantity ~= item.count then
                    draft.quantity = item.count
                    changed = true
                end

                if draft.dirty ~= nil then
                    draft.dirty = nil
                    changed = true
                end
            end
        elseif draft and not draft.jobId then
            drafts[key] = nil
            changed = true
        end
    end

    return changed
end

function Selector:clearSlot(slot, expectedName, expectedCount, expectedNbt)
    local slots, err = self:read()
    if not slots then
        return false, err
    end

    local current = slots[slot]
    if not current or current.name ~= expectedName
        or (expectedCount ~= nil and current.count ~= expectedCount)
        or current.nbt ~= expectedNbt then
        return true, "selection changed"
    end

    local arguments = {n = 9}
    for index = 1, 9 do
        local item = slots[index]
        if index ~= slot and item then
            arguments[index] = {
                name = item.name,
                count = item.count,
                nbt = item.nbt,
            }
        end
    end

    local ok, result = pcall(function()
        return self.device.setRequest(unpackValues(arguments, 1, 9))
    end)

    if not ok or result == false then
        local message = ok and "setRequest returned false" or tostring(result)
        self.lastError = message
        Util.log(self.logger, "error", "selector.clear_failed", {
            slot = slot,
            target = expectedName,
            error = message,
        })
        return false, message
    end

    self.lastError = nil
    return true
end

return Selector
