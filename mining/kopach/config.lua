-- Kopach mining swarm: who may command the turtles and the radio protocol
-- they share. The same file goes on every turtle, the inspector and the
-- computer that runs the Mine tab (kopach/app.lua).
--
-- remote: the computer id(s) of the remote that runs the Mine tab (a pocket
-- computer or smart glasses with the drone-pocket app). Turtles and the
-- inspector obey only these ids and answer the one they heard from last.
-- Find the id with the `id` command on the remote, then list it here:
--     remote = {12},        -- one remote
--     remote = {12, 34},    -- a pocket computer and a pair of glasses
-- The remote itself does not read this field.
local remote = {}

-- A turtle (or the inspector) with no remote set stops here with a clear
-- message instead of failing later on its first radio call.
if turtle and #remote == 0 then
    error("kopach/config.lua: set remote = {<id of the computer with the Mine tab>} and reboot", 0)
end

return {
    remote = remote,
    -- rednet protocol of the swarm; change it only to run two separate
    -- swarms in one world (then on all their turtles and remotes)
    protocol = "kopach",
}
