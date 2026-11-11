-- Colony Supply: colony requests with the requesting building resolved to a name.
--
-- Advanced Peripherals returns `target` as the requester's block position;
-- getBuildings() maps positions to display names. Cached for `cache_for` s.

local Colony = {}
Colony.__index = Colony

local function posKey(pos)
    if type(pos) ~= "table" then return nil end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not (x and y and z) then return nil end
    return string.format("%d,%d,%d", x, y, z)
end

function Colony.new(deps)
    deps = deps or {}
    assert(type(deps.integrator) == "table", "colony needs an integrator")
    local self = setmetatable({}, Colony)
    self.integrator = deps.integrator
    self.clock = deps.clock or function() return os.clock() end
    self.log = deps.log
    self.cacheFor = tonumber(deps.cache_for) or 120
    self.expand = deps.expand     -- optional function(requests) -> requests (dish -> ingredients)
    self.addresses = deps.addresses   -- optional app/addresses: lists every hut in rules/addresses.lua
    self.names = {}
    self.buildingList = {}   -- {type, level, maxLevel, built, pos, people}
    self.cachedAt = nil
    -- Supply calls integrator.getRequests() as a plain function (peripheral style)
    self.getRequests = function() return self:requests() end
    return self
end

function Colony:refreshBuildings(now)
    if self.cachedAt ~= nil and now - self.cachedAt < self.cacheFor then return end
    local ok, buildings = pcall(self.integrator.getBuildings)
    if not ok or type(buildings) ~= "table" then return end
    local names, builders, list = {}, 0, {}
    for _, b in pairs(buildings) do
        if type(b) == "table" and b.type == "builder" and b.built ~= false then builders = builders + 1 end
        if type(b) == "table" then
            list[#list + 1] = {
                type = b.type, level = tonumber(b.level) or 0, maxLevel = tonumber(b.maxLevel),
                built = b.built ~= false, pos = b.pos,
                people = type(b.citizens) == "table" and #b.citizens or tonumber(b.citizens) or 0,
            }
            local key = posKey(b.pos)
            if key then
                local label = tostring(b.displayName or b.name or b.type or "building")
                label = label:gsub("^com%.minecolonies%.building%.", ""):gsub("^block%.minecolonies%.blockhut", "")
                names[key] = label .. " L" .. tostring(b.level or "?")
            end
        end
    end
    self.names = names
    self.builders = builders
    self.buildingList = list
    self.cachedAt = now
    if self.addresses then
        local okA, err = pcall(self.addresses.sync, self.addresses, list)
        if not okA and self.log then self.log.error("addresses", tostring(err)) end
    end
end

function Colony:buildingName(pos)
    if type(pos) == "string" then return pos end
    local key = posKey(pos)
    if not key then return tostring(pos) end
    return self.names[key] or ("@" .. key)
end

-- integrator.getRequests() with `target` replaced by the building's name.
function Colony:requests()
    self:refreshBuildings(self.clock())
    local requests = self.integrator.getRequests()   -- errors propagate to Supply's pcall
    if type(requests) ~= "table" then return requests end
    for _, r in pairs(requests) do
        if type(r) == "table" then
            r.targetPos = r.target
            r.target = self:buildingName(r.target)
        end
    end
    if type(self.expand) == "function" then
        local ok, expanded = pcall(self.expand, requests)
        if ok and type(expanded) == "table" then return expanded end
    end
    return requests
end

return Colony
