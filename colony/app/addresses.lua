-- Colony Supply: Create addresses. /rules/addresses.lua holds the colony's
-- address (kolonia), the Create storage's address (sklad) and one line per
-- building of the colony, found by the hut block's position (two huts of one
-- kind differ only there). A building with an `adresa` gets its requests
-- straight from Create; the rest arrives at the colony's address.
--
-- The program only ever appends lines for buildings it has not listed yet:
-- what the player wrote (addresses, comments, order) is never rewritten.
-- Lines of buildings that are gone stay and simply match nothing.
local W = require("app.words")

local Addresses = {}
Addresses.__index = Addresses

local HEADER = [[
-- Create addresses. Saved changes work within two minutes.
--   kolonia = the colony's frogport / postbox: Create sends here
--   sklad   = your Create storage: the extra goes back here
-- One line per building (de = the hut block's x,y,z, budivlia = its kind
-- as the game names it):
--   adresa = nil       -> its packages go to kolonia, as usual
--   adresa = "Kukhnia" -> straight to that address (a packager with a
--                         frogport on the hut block)
-- New buildings are added at the end by the program; your lines stay as
-- you wrote them.
return {
    kolonia = %q,
    sklad = %q,

]]

local function posKey(pos)
    if type(pos) == "string" then
        local x, y, z = pos:match("^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$")
        return x and string.format("%d,%d,%d", tonumber(x), tonumber(y), tonumber(z)) or nil
    end
    if type(pos) ~= "table" then return nil end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not (x and y and z) then return nil end
    return string.format("%d,%d,%d", x, y, z)
end
Addresses.posKey = posKey

-- deps: path, read(path) -> text|nil, write(path, text), load(path) -> table|nil, err;
-- colony / storage: the addresses from config.lua, used until the file names its own; log
function Addresses.new(deps)
    deps = deps or {}
    local self = setmetatable({}, Addresses)
    self.path = deps.path or "/rules/addresses.lua"
    self.read, self.write, self.load = deps.read, deps.write, deps.load
    self.log = deps.log
    self.colony = deps.colony or "Colony"
    self.storage = deps.storage or "Storage"
    self.map = {}        -- "x,y,z" -> address
    self.count, self.own = 0, 0
    -- the last good addresses (app/memory/last_addresses.lua): a broken or deleted file
    -- never sends the colony's packages to a default address
    self.store = deps.store
    local last = self.store and self.store.load and self.store.load()
    if type(last) == "table" then
        if type(last.colony) == "string" then self.colony = last.colony end
        if type(last.storage) == "string" then self.storage = last.storage end
        if type(last.map) == "table" then self.map = last.map end
    end
    return self
end

-- budivlia: the hut's kind exactly as the game names it (builder, cook...)
local function line(b)
    return string.format('    {de = "%s", budivlia = "%s", adresa = nil},\n', posKey(b.pos), tostring(b.type or "?"))
end

-- Reads the file (written first with the config's two addresses), lists new
-- buildings and takes the addresses again, so an edit works without a
-- restart. A file with an error is left alone and the last good one is used.
function Addresses:sync(buildings)
    local text = self.read(self.path)
    local file = {}
    if text then
        local t, err = self.load(self.path)
        if type(t) ~= "table" then
            if self.problem ~= err and self.log then self.log.warn("ADDRESSES", tostring(err)) end
            self.problem = err
            return false
        end
        file = W.addresses(t)
    end
    self.problem = nil
    local known = {}
    for _, e in ipairs(file) do
        local key = type(e) == "table" and posKey(e.at)
        if key then known[key] = true end
    end
    local add = {}
    for _, b in ipairs(buildings or {}) do
        local key = posKey(b.pos)
        if key and not known[key] then
            known[key] = true
            add[#add + 1] = line(b)
        end
    end
    if not text or #add > 0 then
        local head = text and text:match("^(.*)}%s*$")
        if text and not head then
            if self.log then self.log.warn("ADDRESSES", self.path .. " does not end with }") end
        else
            self.write(self.path, (head or HEADER:format(self.colony, self.storage)) .. table.concat(add) .. "}\n")
            if self.log and #add > 0 then self.log.info("ADDRESSES", #add, "new buildings listed") end
            file = W.addresses(self.load(self.path) or {}) or file
        end
    end
    if type(file.colony) == "string" and file.colony ~= "" then self.colony = file.colony end
    if type(file.storage) == "string" and file.storage ~= "" then self.storage = file.storage end
    local map, own = {}, 0
    for _, e in ipairs(file) do
        local key = type(e) == "table" and posKey(e.at)
        if key and type(e.address) == "string" and e.address ~= "" then
            map[key] = e.address
            own = own + 1
        end
    end
    self.map, self.count, self.own = map, #file, own
    -- written only when an address changed
    local keys = {}
    for key, address in pairs(map) do keys[#keys + 1] = key .. "=" .. address end
    table.sort(keys)
    local sig = self.colony .. "|" .. self.storage .. "|" .. table.concat(keys, ";")
    if self.store and self.store.save and sig ~= self.savedSig then
        pcall(self.store.save, {colony = self.colony, storage = self.storage, map = map})
        self.savedSig = sig
    end
    return true
end

-- Where a request's packages go: the building's own address, else the colony's.
function Addresses:of(pos)
    local key = posKey(pos)
    return key and self.map[key] or self.colony
end

return Addresses
