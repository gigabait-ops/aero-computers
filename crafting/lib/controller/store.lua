local AtomicStore = require("atomic_store")
local Store = {}
Store.__index = Store
function Store.new(options)
    options = options or {}
    return setmetatable({path = options.path or "data/queue.lua", fs = options.fs or fs}, Store)
end
function Store:load()
    return AtomicStore.load(self.path, self.fs)
end
function Store:save(value)
    local directory = self.fs.getDir(self.path)
    if directory ~= "" and not self.fs.exists(directory) then self.fs.makeDir(directory) end
    return AtomicStore.save(self.path, value, self.fs)
end
return Store
