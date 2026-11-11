-- Colony Supply: dish requests -> ingredient requests (the cook makes the dish).
--
-- Rules from /rules/dishes.lua: ["dish"] = {{item, per, max}, ...}.
-- expand(requests) replaces every request whose acceptable items contain a
-- known dish with one request-like entry per ingredient. Pure and reloadable.

local Ingredients = {}
Ingredients.__index = Ingredients

function Ingredients.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Ingredients)
    self.loader = assert(deps.loader, "ingredients needs loader() -> rules, err")
    self.clock = deps.clock or function() return os.clock() end
    self.log = deps.log or {warn = function() end, info = function() end}
    self.config = {
        reload_every = tonumber(deps.config and deps.config.reload_every) or 10,
        max = tonumber(deps.config and deps.config.max) or 256,
        -- ingredients go out once per dish request; a request that stays open
        -- this long after delivery means the cook cannot make the dish
        reorder_after = tonumber(deps.config and deps.config.reorder_after) or 21600,
    }
    self.rules = {}
    self.loadedAt = nil
    self.error = nil
    self.last = {rules = 0, expanded = 0}
    return self
end

function Ingredients:reload(now)
    if self.loadedAt ~= nil and now - self.loadedAt < self.config.reload_every then return end
    self.loadedAt = now
    local rules, err = self.loader()
    if type(rules) ~= "table" then
        if err ~= self.error then self.log.warn("INGREDIENT_RULES", tostring(err)) end
        self.error = err or "invalid rules"
        return
    end
    local clean, count = {}, 0
    for dish, list in pairs(rules) do
        if type(dish) == "string" and type(list) == "table" then
            local parts = {}
            for _, part in ipairs(list) do
                if type(part) == "table" and type(part.item) == "string" and part.item ~= "" then
                    parts[#parts + 1] = {item = part.item, per = math.max(1, math.floor(tonumber(part.per) or 1)),
                        max = tonumber(part.max)}
                end
            end
            if #parts > 0 then clean[dish] = parts count = count + 1 end
        end
    end
    if count ~= self.last.rules or self.error then self.log.info("INGREDIENT_RULES", count, "dishes loaded") end
    self.rules = clean
    self.error = nil
    self.last.rules = count
end

-- The first acceptable item of the request that has a rule, or nil.
function Ingredients:dishOf(request)
    for _, item in ipairs(type(request.items) == "table" and request.items or {}) do
        if type(item) == "table" and type(item.name) == "string" and self.rules[item.name] then
            return item.name
        end
    end
    return nil
end

function Ingredients:expand(requests)
    self:reload(self.clock())
    if type(requests) ~= "table" then return requests end
    local out, expanded = {}, 0
    for _, request in pairs(requests) do
        local dish = type(request) == "table" and self:dishOf(request) or nil
        if dish == nil then
            out[#out + 1] = request
        else
            expanded = expanded + 1
            local wanted = math.max(1, math.floor(tonumber(request.count) or tonumber(request.minCount) or 1))
            for _, part in ipairs(self.rules[dish]) do
                local count = math.min(wanted * part.per, part.max or self.config.max)
                out[#out + 1] = {
                    id = tostring(request.id) .. ":" .. part.item,
                    state = request.state,
                    count = count,
                    minCount = count,
                    target = request.target,
                    targetPos = request.targetPos,
                    displayName = tostring(request.displayName or dish):gsub("^%d+%-%d+%s+", "") .. " <- " .. part.item:gsub("^[%w_]+:", ""),
                    items = {{name = part.item, count = count, maxStackSize = 64}},
                    dish = dish,
                    dedupeByName = true,
                    reorder_after = self.config.reorder_after,
                }
            end
        end
    end
    self.last.expanded = expanded
    return out
end

return Ingredients
