--[[
What the sync remembers between runs (see ink/sync/), in one file in the
sync's own folder (never in the library, so it is never synced itself):

    account    who the cloud knows this reader as
    root       the library folder the records are about
    cursor     where the cloud's list of changes was read up to
    files      per file (key = its path in lower case): the BASE, the version
               this reader and the cloud last agreed on: rev, size and hash in
               the cloud, size, time and hash here, and when
    remote     the cloud's files as last listed (rev, size, hash)
    conflicts  the copies made when a file was changed in two places
    refs       the files each notebook uses, per notebook, read once
    last       the result of the last run

It is written whole and atomically after each file, so a run cut short by a
dead battery carries on from the last file done.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local State = {}
State.__index = State

State.VERSION = 1
State.FILE = "state.lua"

local function fresh()
    return { v = State.VERSION, files = {}, remote = {}, conflicts = {}, refs = {} }
end

-- The state kept in folder `dir` (a new one if there is none, or it cannot be read).
function State.load(dir)
    local self = setmetatable({ dir = dir }, State)
    local f = io.open(Storage.join(dir, State.FILE), "rb")
    local data
    if f then
        local text = f:read("*a")
        f:close()
        data = Project.decode(text)
    end
    if type(data) ~= "table" or data.v ~= State.VERSION then data = fresh() end
    for k, v in pairs(fresh()) do if data[k] == nil then data[k] = v end end
    self.data = data
    return self
end

function State:save()
    Storage.ensureDir(self.dir)
    return Storage.writeAtomic(Storage.join(self.dir, State.FILE), Project.encode(self.data))
end

-- Forget what was agreed (keeping the account): the next run treats every file
-- as new, which keeps both sides' copies when they differ.
function State:rebase(root)
    local d = self.data
    d.files, d.remote, d.refs, d.cursor = {}, {}, {}, nil
    d.root = root
end

-- Forget everything, including the account.
function State:clear()
    self.data = fresh()
end

-- A file's key: its path in lower case, as the cloud sees it.
function State.key(rel) return rel:lower() end

return State
