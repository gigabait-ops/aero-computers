-- Recipe rules every worker follows (blockedRecipes, avoidCandidates), read
-- from a file on PC48 and re-read whenever it changes. The controller sends
-- them with each job, so a new rule needs no /reload of the ROM.
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
    return normalize(value)
end

-- The current rules; nil until a readable file exists. A broken edit keeps
-- the last good rules and reports the error once.
function RecipePolicy:get()
    local stamp = self:stampOf()
    if stamp == self.stamp then return self.current end
    self.stamp = stamp
    if not stamp then
        self.error = "missing " .. self.path
        if self.log then self.log("recipe_policy.missing", {path = self.path}) end
        return self.current
    end
    local policy, err = self:read()
    if not policy then
        self.error = tostring(err)
        if self.log then self.log("recipe_policy.error", {path = self.path, error = self.error}) end
        return self.current
    end
    local recipes = 0
    for _ in pairs(policy.avoidCandidates) do recipes = recipes + 1 end
    self.current, self.error = policy, nil
    if self.log then
        self.log("recipe_policy.loaded", {blocked = #policy.blockedRecipes, avoidRecipes = recipes})
    end
    return policy
end

return RecipePolicy
