-- A short log: start, changes and problems only (never one line per
-- cycle). The newest lines stay in memory for the terminal's Log page; the
-- file rolls over at `max` bytes into a single .old copy.
local Log = {}
Log.__index = Log

function Log.new(path, max, keep)
    return setmetatable({path = path, max = max or 32000, keep = keep or 40, lines = {}}, Log)
end

local TONES = {INFO = "text", WARN = "warn", ERROR = "bad"}

function Log:add(level, text)
    local time = os.date and os.date("%m-%d %H:%M:%S") or textutils.formatTime(os.time(), true)
    self.lines[#self.lines + 1] = {time = time, text = text, tone = TONES[level] or "text"}
    if #self.lines > self.keep then table.remove(self.lines, 1) end
    if not self.path then return end
    if fs.exists(self.path) and fs.getSize(self.path) > self.max then
        local old = self.path .. ".old"
        if fs.exists(old) then fs.delete(old) end
        fs.move(self.path, old)
    end
    local f = fs.open(self.path, "a")
    if f then
        f.writeLine(("%s %s %s"):format(time, level, text))
        f.close()
    end
end

function Log:info(text) self:add("INFO", text) end
function Log:warn(text) self:add("WARN", text) end
function Log:error(text) self:add("ERROR", text) end

-- Log a message only when it differs from the last one under this key
-- (a state that holds, such as the lever on the power, is said once).
function Log:once(key, level, text)
    self.seen = self.seen or {}
    if self.seen[key] == text then return end
    self.seen[key] = text
    if text then self:add(level, text) end
end

return Log
