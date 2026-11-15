--[[
The safety copies of the cloud sync (see ink/sync/). Before the sync replaces
or removes a file on this reader, the file as it was is copied into a folder of
the sync's own, one folder per day-and-time, keeping its path inside the
library. They stay for a month and can be copied back by hand or from the
sync's menu. Only old ones are removed, and only from this folder.
]]

local Storage = require("ink/storage")

local Backup = {}

Backup.KEEP_DAYS = 30

local function stamp(now)
    return os.date("%Y%m%d-%H%M%S", now)
end

-- Copy the file at `src` (library path `rel`) into the backup folder `dir`.
-- Returns the copy's path, or nil and why not. A file too big to copy in one
-- piece is copied a piece at a time.
function Backup.put(dir, rel, src, now)
    local dst = Storage.join(Storage.join(dir, stamp(now or os.time())), rel)
    Storage.makePath(Storage.dirName(dst))
    local inf, err = io.open(src, "rb")
    if not inf then return nil, err end
    local out, oerr = io.open(dst, "wb")
    if not out then inf:close(); return nil, oerr end
    while true do
        local piece = inf:read(262144)
        if not piece or piece == "" then break end
        if not out:write(piece) then inf:close(); out:close(); os.remove(dst); return nil, "write failed" end
    end
    inf:close()
    out:close()
    return dst
end

-- The backups in `dir`, newest first: { { name, path, time } }.
function Backup.list(dir)
    local out = {}
    for _i, e in ipairs(Storage.list(dir)) do
        if e.mode == "directory" and e.name:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$") then
            out[#out + 1] = { name = e.name, path = e.path, time = e.mtime }
        end
    end
    table.sort(out, function(a, b) return a.name > b.name end)
    return out
end

-- Remove the backups older than `days` (and never the newest one). Returns how many went.
function Backup.prune(dir, now, days)
    local list = Backup.list(dir)
    local limit = (now or os.time()) - (days or Backup.KEEP_DAYS) * 86400
    local n = 0
    for i = 2, #list do
        if (list[i].time or 0) < limit and Storage.removeTree(list[i].path) then n = n + 1 end
    end
    return n
end

return Backup
