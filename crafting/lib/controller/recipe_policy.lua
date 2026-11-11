-- Recipe rules every worker follows (blockedRecipes, avoidCandidates), read
-- from a file on PC48 and re-read whenever it changes. The controller sends
-- them with each job, so a new rule needs no /reload of the ROM. Any other
-- data file of PC48 read the same way passes its own `normalize`, `summary`
-- and `event` (makers.lua, below).
local RecipePolicy = {}
RecipePolicy.__index = RecipePolicy

local function stringList(value)
    local out = {}
    for _, name in ipairs(type(value) == "table" and value or {}) do
        if type(name) == "string" and name ~= "" then out[#out + 1] = name end
    end
    return out
end

local function normalize(value)
    if type(value) ~= "table" then return nil, "the file must return a table" end
    local avoid = {}
    for recipe, names in pairs(type(value.avoidCandidates) == "table" and value.avoidCandidates or {}) do
        if type(recipe) == "string" then avoid[recipe] = stringList(names) end
    end
    return {blockedRecipes = stringList(value.blockedRecipes), avoidCandidates = avoid}
end

function RecipePolicy.new(options)
    options = options or {}
    return setmetatable({
        path = options.path or "/recipe_policy.lua",
        fs = options.fs or fs,
        log = options.log,
        normalize = options.normalize or normalize,
        summary = options.summary,
        event = options.event or "recipe_policy",
        current = nil,
        stamp = false,
        error = nil,
    }, RecipePolicy)
end

function RecipePolicy:stampOf()
    local files = self.fs
    if type(files) ~= "table" or not files.exists or not files.exists(self.path) then return nil end
    local size = files.getSize and select(2, pcall(files.getSize, self.path)) or "?"
    local ok, attributes = pcall(files.attributes or function() return nil end, self.path)
    local modified = ok and type(attributes) == "table" and (attributes.modified or attributes.modification) or "?"
    return tostring(modified) .. "/" .. tostring(size)
end

function RecipePolicy:read()
    local handle = self.fs.open(self.path, "r")
    if not handle then return nil, "cannot open " .. self.path end
    local text = handle.readAll()
    handle.close()
    local chunk, loadError = load(text, "@" .. self.path, "t", {})
    if not chunk then return nil, loadError end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return self.normalize(value)
end

-- The current rules; nil until a readable file exists. A broken edit keeps
-- the last good rules and reports the error once.
function RecipePolicy:get()
    local stamp = self:stampOf()
    if stamp == self.stamp then return self.current end
    self.stamp = stamp
    if not stamp then
        self.error = "missing " .. self.path
        if self.log then self.log(self.event .. ".missing", {path = self.path}) end
        return self.current
    end
    local policy, err = self:read()
    if not policy then
        self.error = tostring(err)
        if self.log then self.log(self.event .. ".error", {path = self.path, error = self.error}) end
        return self.current
    end
    self.current, self.error = policy, nil
    if self.log then
        local fields
        if self.summary then
            fields = self.summary(policy)
        else
            local recipes = 0
            for _ in pairs(policy.avoidCandidates) do recipes = recipes + 1 end
            fields = {blocked = #policy.blockedRecipes, avoidRecipes = recipes}
        end
        self.log(self.event .. ".loaded", fields)
    end
    return policy
end

-- Who makes what first: PC48's makers.lua (owner 2026-11-11), read the
-- same way (normalize = RecipePolicy.normalizeMakers).
--   order   - the default order of makers: "turtle", "compact",
--             "mechanical", "saw", "slicer", "basin", "machine" (every
--             machine of settings `machines`, in that order) or a
--             machine's address; makers left out come after, as before
--   items   - item id -> makers to try first for it, in order; when none
--             of them can, the rest are tried in the default order
--   blocked - recipe ids no one uses: PC48 plans without them and the
--             workers get them with their jobs

local function strings(value)
    local out = {}
    for _, name in ipairs(type(value) == "table" and value or {}) do
        if type(name) == "string" and name ~= "" then out[#out + 1] = name end
    end
    return out
end

function RecipePolicy.normalizeMakers(value)
    if type(value) ~= "table" then return nil, "the file must return a table" end
    local items = {}
    for item, makers in pairs(type(value.items) == "table" and value.items or {}) do
        if type(item) == "string" then
            local list = type(makers) == "string" and {makers} or strings(makers)
            if #list > 0 then items[item] = list end
        end
    end
    local order = strings(value.order)
    local blocked, list = {}, strings(value.blocked)
    for _, id in ipairs(list) do blocked[id] = true end
    return {order = #order > 0 and order or nil, items = items, blocked = blocked, blockedList = list}
end

function RecipePolicy.summarizeMakers(policy)
    local items = 0
    for _ in pairs(policy.items) do items = items + 1 end
    return {items = items, blocked = #policy.blockedList, order = policy.order and #policy.order or 0}
end

return RecipePolicy
