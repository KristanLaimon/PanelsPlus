--[[
What the sync does with one file (see ink/sync/). The decision comes from three
facts, each compared with the BASE, the version this reader and the cloud last
agreed on:

    local   "absent" (deleted here), "same" (as at the last sync), "changed"
    remote  "absent" (deleted in the cloud), "same", "changed"
    base    nil when the file has never been synced, else its record

Nothing is ever decided from a clock, since a reader's clock may be wrong. The
rule that holds everywhere: a file changed on both sides is a conflict and is
kept twice, and a change always beats a deletion, so nothing is lost.

Actions: "none", "upload", "download", "conflict", "delete_remote",
"delete_local", "adopt" (both sides already hold the same file: only note it),
"forget" (both sides lost it: drop the record).
]]

local Plan = {}

-- Decide for a file never synced before. `equal` says whether the two copies
-- are the same bytes (only asked when both exist).
local function fresh(loc, rem, equal)
    if loc == "absent" and rem == "absent" then return "none" end
    if rem == "absent" then return "upload" end
    if loc == "absent" then return "download" end
    return equal and "adopt" or "conflict"
end

-- Decide for a file synced before.
local function known(loc, rem)
    if loc == "absent" and rem == "absent" then return "forget" end
    if loc == "same" and rem == "same" then return "none" end
    if loc == "changed" and rem == "same" then return "upload" end
    if loc == "same" and rem == "changed" then return "download" end
    if loc == "changed" and rem == "changed" then return "conflict" end
    if loc == "absent" then
        return rem == "same" and "delete_remote" or "download"   -- edited elsewhere: bring it back
    end
    -- the cloud no longer has it
    return loc == "same" and "delete_local" or "upload"   -- edited here: send it again
end

-- The action for a file. `equal` is a function returning whether the local and
-- remote copies are identical, called only if it matters.
function Plan.decide(base, loc, rem, equal)
    if not base then return fresh(loc, rem, loc ~= "absent" and rem ~= "absent" and equal and equal()) end
    return known(loc, rem)
end

-- The local state of a file against its base record: `now` is { size, mtime }
-- (nil when the file is gone) and `hash()` the file's hash, called only if size
-- or time differ.
function Plan.localState(base, now, hash)
    if not now then return "absent" end
    if not base then return "changed" end
    if base.lsize == now.size and base.lmtime == now.mtime then
        -- written in the same second as the sync: the time cannot tell, the bytes can
        if base.synced and now.mtime + 2 >= base.synced and base.lhash and hash then
            return hash() == base.lhash and "same" or "changed"
        end
        return "same"
    end
    if base.lhash and hash and hash() == base.lhash then return "same" end
    return "changed"
end

-- The remote state of a file against its base record: `now` is the cloud's entry
-- { rev } (nil when it has none).
function Plan.remoteState(base, now)
    if not now then return "absent" end
    if base and base.rev == now.rev then return "same" end
    return "changed"
end

return Plan
