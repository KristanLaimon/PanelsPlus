--[[
One run of the cloud sync (see ink/sync/): make this reader's notebooks and the
cloud's the same, losing nothing. The cloud service is a provider (Dropbox
today, see ink/sync/providers.lua) that is passed in, so the same run works for
any service. Plain Lua apart from the files, so the headless tests drive it
against a pretend cloud.

A run:
  1. checks the cloud's layout version (an older Ink Away stops here),
  2. finds the files the notebooks use and brings the ones outside the library
     into ".attachments",
  3. asks the cloud only for what changed since last time,
  4. looks at this reader's files and decides each one (ink/sync/plan.lua),
  5. does it, one file at a time, saving what it knows after each.

What keeps it safe:
  - a file is only replaced after the new one arrived whole, matches its size
    and hash, and (for a notebook) reads back as a notebook;
  - the old file is copied into the backup folder first;
  - the file is looked at again just before it is replaced, and left alone if
    it changed meanwhile or is open in the editor;
  - a file changed in both places is kept twice, never merged or overwritten;
  - a deletion never wins over an edit, and a run that would delete much of the
    library stops before deleting anything;
  - an upload says which version it builds on, so the cloud refuses it if
    another reader got there first;
  - nothing is decided from a clock.
]]

local Backup = require("ink/sync/backup")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Plan = require("ink/sync/plan")
local Portable = require("ink/sync/portable")
local Refs = require("ink/sync/refs")
local State = require("ink/sync/state")
local Storage = require("ink/storage")

local Engine = {}

Engine.SCHEMA = 1
Engine.SCHEMA_FILE = ".inkaway-sync.json"
Engine.TMP = ".synctmp"

Engine.LIMITS = {
    max_file = 150 * 1024 * 1024,       -- the biggest file sent
    hash_max = 32 * 1024 * 1024,        -- the biggest file hashed in full
    max_delete_fraction = 0.25,         -- of the files, deleted in one run, before it stops
    min_delete_guard = 4,               -- fewer deletions than this are never blocked
}

------------------------------------------------------------------------------
-- Names and paths
------------------------------------------------------------------------------

-- Is `rel` a path inside the library and nothing else? (A name from the cloud is
-- never trusted: no "..", no absolute path, no odd characters.)
function Engine.safeRel(rel)
    if type(rel) ~= "string" or rel == "" or #rel > 400 then return false end
    if rel:find("^/") or rel:find("\\", 1, true) or rel:find("%c") or rel:find("//", 1, true) then return false end
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part == "." then return false end
    end
    return true
end

-- Is this one of the files the sync's own bookkeeping uses (never synced as a file)?
local function reserved(rel)
    return rel == Engine.SCHEMA_FILE or rel:sub(-#Engine.TMP) == Engine.TMP or rel:sub(-4) == ".tmp"
end

-- The part (area) of the sync a cloud path belongs to (see ink/sync/areas.lua).
local function areaOf(ctx, rel)
    for _i, a in ipairs(ctx.areas) do
        if a.owns(rel) then return a end
    end
end

-- Where the cloud path `rel` is on this reader.
local function abs(ctx, rel)
    local a = areaOf(ctx, rel)
    return a and a.locate(rel) or Storage.join(ctx.root, rel)
end

-- Is `rel` in a part that is on, and does it have a place on this reader?
local function isTracked(ctx, rel)
    local a = areaOf(ctx, rel)
    return a ~= nil and a.enabled() and a.locate(rel) ~= nil
end

-- Copy a file a piece at a time (a notebook with pictures can be big).
local function copyStream(src, dst)
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
    local ok = out:close()
    if not ok then os.remove(dst); return nil, "close failed" end
    return true
end

local function stat(path)
    local size = Storage.size(path)
    if not size then return nil end
    return { size = size, mtime = Storage.mtime(path) or 0 }
end

-- Move `tmp` over `target`, or fail leaving `target` as it was. Returns true, or
-- nil and what the system said (for the log).
local function replace(tmp, target)
    local ok, why = os.rename(tmp, target)
    if not ok then
        -- a file system that will not rename over a file: the old one is moved aside first
        local old = target .. ".syncold"
        os.remove(old)
        local moved, why2 = os.rename(target, old)
        if moved then
            ok, why = os.rename(tmp, target)
            if ok then os.remove(old) else os.rename(old, target) end
        else
            why = tostring(why) .. "; aside: " .. tostring(why2)
        end
    end
    return ok, why
end

local function lower(rel) return State.key(rel) end

-- "Name (conflict Boox 2026-11-03).ext" in the folder of `rel`, not used yet.
local function conflictRel(ctx, rel)
    local dir = rel:match("^(.*)/[^/]*$")
    local name = rel:match("([^/]+)$")
    local stem, ext = name:match("^(.+)(%.[^.]+)$")
    if not stem then stem, ext = name, "" end
    local who = (ctx.device or "reader"):gsub("[/\\:%c]", ""):sub(1, 24)
    local base = string.format("%s (conflict %s %s)", stem, who, os.date("%Y-%m-%d", ctx.now()))
    local n, cand = 1
    repeat
        cand = (dir and dir .. "/" or "") .. base .. (n > 1 and (" " .. n) or "") .. ext
        n = n + 1
    until not Storage.exists(abs(ctx, cand)) and not ctx.state.data.remote[lower(cand)]
    return cand
end

------------------------------------------------------------------------------
-- Talking to the cloud, with a few tries for what may pass
------------------------------------------------------------------------------

local function try(ctx, fn)
    local err
    for attempt = 1, 3 do
        local a, b = fn()
        if a ~= nil and a ~= false then return a, nil end
        err = b or Errors.make("IA-S503", "no answer")
        if not Errors.isRetryable(err) or attempt == 3 or ctx.stop() then break end
        local wait = math.min(err.retry_after or (2 ^ attempt), 30)
        ctx.sleep(wait)
    end
    return nil, err
end

------------------------------------------------------------------------------
-- Looking at this reader's files
------------------------------------------------------------------------------

-- Notebooks and folder files in the library (a walk), as { [key] = rel }.
local function walk(root, clashes)
    local out = {}
    local function go(dir, prefix, depth)
        if depth > 12 then return end
        for _i, e in ipairs(Storage.list(dir)) do
            local rel = prefix .. e.name
            if e.mode == "directory" then
                if e.name:sub(1, 1) ~= "." and not e.name:match("%.sdr$") then go(e.path, rel .. "/", depth + 1) end
            elseif e.mode == "file" and e.name:sub(-#Engine.TMP) == Engine.TMP and os.time() - (e.mtime or 0) > 86400 then
                os.remove(e.path)   -- (left by a run that was cut short)
            elseif e.mode == "file" and not reserved(rel)
                    and (e.name:match("%.inkaway$") or e.name == ".inkaway-folder") then
                local k = lower(rel)
                if out[k] and out[k] ~= rel then clashes[#clashes + 1] = { out[k], rel } end
                if not out[k] or rel < out[k] then out[k] = rel end
            end
        end
    end
    go(root, "", 0)
    return out
end

-- The files notebooks use: finds them (again only for a notebook that changed),
-- copies those outside the library into ".attachments", and returns { [key] = rel }.
local function usedFiles(ctx, docs, res)
    local refs = ctx.state.data.refs
    local out = {}
    for dkey in pairs(refs) do if not docs[dkey] then refs[dkey] = nil end end
    for dkey, drel in pairs(docs) do
        if drel:match("%.inkaway$") then
            local st = stat(abs(ctx, drel))
            local r = refs[dkey]
            if st and (not r or r.size ~= st.size or r.mtime ~= st.mtime) then
                local paths = Refs.ofFile(abs(ctx, drel)) or {}
                local rels = {}
                for _i, p in ipairs(paths) do
                    if Storage.within(p, ctx.root) and p ~= ctx.root then
                        local rel = p:sub(#ctx.root:gsub("/+$", "") + 2)
                        if Engine.safeRel(rel) and Storage.exists(p) then rels[#rels + 1] = rel end
                    elseif Storage.exists(p) and not Storage.isDir(p) then
                        local rel = Portable.attachRel(p)
                        local size = Storage.size(p) or 0
                        if size > ctx.limits.max_file then
                            res.warnings[#res.warnings + 1] = { rel = p, err = Errors.make("IA-S306", "attachment too large") }
                        elseif not ctx.dry then
                            if not Storage.exists(abs(ctx, rel)) then
                                Storage.makePath(Storage.dirName(abs(ctx, rel)))
                                local ok = copyStream(p, abs(ctx, rel) .. Engine.TMP)
                                if ok then replace(abs(ctx, rel) .. Engine.TMP, abs(ctx, rel))
                                else os.remove(abs(ctx, rel) .. Engine.TMP) end
                            end
                            if Storage.exists(abs(ctx, rel)) then rels[#rels + 1] = rel end
                        end
                    elseif not Storage.exists(p) and not Storage.exists(abs(ctx, Portable.attachRel(p))) then
                        local found = Portable.resolve(p, ctx.root)
                        if found == p then
                            res.warnings[#res.warnings + 1] = { rel = drel, err = Errors.make("IA-S405", p) }
                        end
                    end
                end
                r = { size = st.size, mtime = st.mtime, rels = rels }
                refs[dkey] = r
            end
            if r then for _i, rel in ipairs(r.rels) do out[lower(rel)] = rel end end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- The steps of a file
------------------------------------------------------------------------------

local function base(ctx, key) return ctx.state.data.files[key] end

-- Record that this reader and the cloud now agree on a file.
local function agree(ctx, key, rel, meta, lst, lhash)
    ctx.state.data.files[key] = {
        rel = rel, rev = meta.rev, rsize = meta.size, rhash = meta.hash,
        lsize = lst.size, lmtime = lst.mtime, lhash = lhash, synced = ctx.now(),
    }
    ctx.state.data.remote[key] = { rel = rel, rev = meta.rev, size = meta.size, hash = meta.hash }
end

-- The local file's hash, if it is small enough to be worth it.
local function localHash(ctx, path, size)
    if size > ctx.limits.hash_max then return nil end
    return (Hash.file(path))
end

local function backupOf(ctx, rel)
    local p = abs(ctx, rel)
    if not Storage.exists(p) then return true end
    local dst, err = Backup.put(ctx.backup_dir, rel, p, ctx.now())
    if not dst then return nil, Errors.make("IA-S402", "backup: " .. tostring(err)) end
    return dst
end

-- Send a file. Returns true, or nil and an error.
local function doUpload(ctx, key, rel)
    local path = abs(ctx, rel)
    local before = stat(path)
    if not before then return nil, Errors.make("IA-S401", "gone: " .. rel) end
    if before.size > ctx.limits.max_file then return nil, Errors.make("IA-S306", rel) end
    -- the file as it is now, copied, so a save while it uploads cannot tear it
    local snap = path .. Engine.TMP
    local ok, cerr = copyStream(path, snap)
    if not ok then os.remove(snap); return nil, Errors.make("IA-S401", cerr) end
    local after = stat(path)
    if not after or after.size ~= before.size or after.mtime ~= before.mtime then
        os.remove(snap)
        return nil, Errors.make("IA-S504", rel)
    end
    local lhash = localHash(ctx, snap, before.size)
    local b = base(ctx, key)
    local rem = ctx.state.data.remote[key]
    local expect = (b and rem) and b.rev or nil
    local meta, err = try(ctx, function() return ctx.provider:upload(snap, rel, expect) end)
    os.remove(snap)
    if not meta then
        return nil, err   -- (an IA-S305 here: the next list shows what changed, and the file is decided again)
    end
    agree(ctx, key, rel, meta, before, lhash)
    return true
end

-- `path`'s hash in the kind the cloud gave `like`: the provider's own, else Dropbox's.
local function remoteKind(ctx, path, like)
    local f = ctx.provider.hashFile
    if f then return f(ctx.provider, path, like) end
    return (Hash.dropbox(path))
end

-- Fetch the cloud's version into a temporary file beside `rel` and check it.
local function fetch(ctx, rel, rem)
    local target = abs(ctx, rel)
    Storage.makePath(Storage.dirName(target))
    local tmp = target .. Engine.TMP
    os.remove(tmp)
    local meta, err = try(ctx, function() return ctx.provider:download(rel, rem.rev, tmp) end)
    if not meta then os.remove(tmp); return nil, err end
    local st = stat(tmp)
    if not st or (rem.size and st.size ~= rem.size) then
        os.remove(tmp)
        return nil, Errors.make("IA-S403", "size " .. tostring(st and st.size) .. " of " .. tostring(rem.size))
    end
    if rem.hash and st.size <= ctx.limits.hash_max then
        local h = remoteKind(ctx, tmp, rem.hash)
        if h and h ~= rem.hash then os.remove(tmp); return nil, Errors.make("IA-S403", "hash differs") end
    end
    if ctx.validate then
        local good, why = ctx.validate(rel, tmp)
        if not good then os.remove(tmp); return nil, Errors.make("IA-S403", why or "not valid") end
    end
    return tmp, nil, st
end

-- Did the local file change since `seen` (what the run looked at)?
local function changedSince(ctx, rel, seen)
    local now = stat(abs(ctx, rel))
    if not seen then return now ~= nil end
    return not now or now.size ~= seen.size or now.mtime ~= seen.mtime
end

-- Bring the cloud's version down over the local file. `seen` is what the run saw.
local function doDownload(ctx, key, rel, rem, seen)
    local tmp, err = fetch(ctx, rel, rem)
    if not tmp then return nil, err end
    if changedSince(ctx, rel, seen) then os.remove(tmp); return nil, Errors.make("IA-S504", rel) end
    local bok, berr = backupOf(ctx, rel)
    if not bok then os.remove(tmp); return nil, berr end
    local replaced, rwhy = replace(tmp, abs(ctx, rel))
    if not replaced then
        os.remove(tmp)
        return nil, Errors.make("IA-S402", "replace " .. rel .. ": " .. tostring(rwhy))
    end
    local st = stat(abs(ctx, rel))
    agree(ctx, key, rel, rem, st, localHash(ctx, abs(ctx, rel), st.size))
    return true
end

-- Both sides changed a file that can be combined (the ink on a book): the two are
-- merged into this reader's file, which is then sent as the next version of the
-- cloud's. Nothing is left out. Returns true and "" (the caller sends it).
local function doMerge(ctx, key, rel, rem, tmp, area)
    local merged = area.merge(abs(ctx, rel), tmp)
    if not merged then os.remove(tmp); return nil, Errors.make("IA-S503", "cannot merge " .. rel) end
    local bok, berr = backupOf(ctx, rel)
    if not bok then os.remove(tmp); return nil, berr end
    local rst = stat(tmp)
    local rhash = localHash(ctx, tmp, rst.size)
    local target = abs(ctx, rel)
    local out, oerr = io.open(target .. Engine.TMP, "wb")
    if not out then os.remove(tmp); return nil, Errors.make("IA-S402", "merge " .. rel .. ": " .. tostring(oerr)) end
    out:write(merged)
    out:close()
    local replaced, rwhy = replace(target .. Engine.TMP, target)
    if not replaced then
        os.remove(target .. Engine.TMP); os.remove(tmp)
        return nil, Errors.make("IA-S402", "replace " .. rel .. ": " .. tostring(rwhy))
    end
    os.remove(tmp)
    -- the base is the cloud's version, so the merged file counts as changed and goes up
    ctx.state.data.files[key] = { rel = rel, rev = rem.rev, rsize = rem.size, rhash = rem.hash,
        lsize = rst.size, lmtime = 0, lhash = rhash, synced = ctx.now() }
    return true, ""
end

-- Both sides changed: the cloud's version keeps the name, this reader's goes to
-- a copy beside it; both end up in the cloud. Returns true, the copy's rel.
local function doConflict(ctx, key, rel, rem, seen)
    local tmp, err = fetch(ctx, rel, rem)
    if not tmp then return nil, err end
    if changedSince(ctx, rel, seen) then os.remove(tmp); return nil, Errors.make("IA-S504", rel) end
    local area = areaOf(ctx, rel)
    if area and area.merge then return doMerge(ctx, key, rel, rem, tmp, area) end
    local crel = conflictRel(ctx, rel)
    local ok, cerr = copyStream(abs(ctx, rel), abs(ctx, crel))
    if not ok then os.remove(tmp); os.remove(abs(ctx, crel)); return nil, Errors.make("IA-S402", cerr) end
    local bok, berr = backupOf(ctx, rel)
    if not bok then os.remove(tmp); return nil, berr end
    local replaced, rwhy = replace(tmp, abs(ctx, rel))
    if not replaced then
        os.remove(tmp)
        return nil, Errors.make("IA-S402", "replace " .. rel .. ": " .. tostring(rwhy))
    end
    local st = stat(abs(ctx, rel))
    agree(ctx, key, rel, rem, st, localHash(ctx, abs(ctx, rel), st.size))
    local list = ctx.state.data.conflicts
    list[#list + 1] = { orig = rel, copy = crel, at = ctx.now(), device = ctx.device }
    return true, crel
end

------------------------------------------------------------------------------
-- A run
------------------------------------------------------------------------------

local PRIORITY = function(rel) return rel:match("%.inkaway$") and 2 or (rel == ".inkaway-folder" or rel:match("/%.inkaway%-folder$")) and 3 or 1 end

local function note(res, rel, action, status, err)
    res.items[#res.items + 1] = { rel = rel, action = action, status = status, err = err }
    if err then res.errors[#res.errors + 1] = { rel = rel, err = err } end
end

local function checkSchema(ctx)
    local p = ctx.provider
    -- the layout version is looked at once a day (and on the first run), not on every run
    local last = ctx.state.data.schema_checked
    if last and ctx.now() - last < 86400 and not ctx.dry then return true end
    local tmp = Storage.join(ctx.state.dir, "schema.tmp")
    os.remove(tmp)
    local meta, err = try(ctx, function() return p:download(Engine.SCHEMA_FILE, nil, tmp) end)
    if meta then
        local f = io.open(tmp, "rb")
        local text = f and f:read("*a") or ""
        if f then f:close() end
        os.remove(tmp)
        local Json = require("ink/sync/json")
        local v = Json.decode(text)
        if type(v) == "table" and type(v.schema) == "number" and v.schema > Engine.SCHEMA then
            return nil, Errors.make("IA-S501", "cloud schema " .. v.schema)
        end
        if not ctx.dry then ctx.state.data.schema_checked = ctx.now() end
        return true
    end
    os.remove(tmp)
    if err and err.code == "IA-S307" then
        if ctx.dry then return true end
        local Json = require("ink/sync/json")
        local f = io.open(tmp, "wb")
        if not f then return nil, Errors.make("IA-S402", "schema") end
        f:write(Json.encode({ schema = Engine.SCHEMA, created_by = ctx.device or "reader" }))
        f:close()
        local up, uerr = try(ctx, function() return p:upload(tmp, Engine.SCHEMA_FILE, nil) end)
        os.remove(tmp)
        if not up and not (uerr and uerr.code == "IA-S305") then return nil, uerr end
        ctx.state.data.schema_checked = ctx.now()
        return true
    end
    return nil, err
end

-- Run a sync. `ctx` holds:
--   root, provider, state, backup_dir, device (this reader's name), now(), sleep(s),
--   stop() -> bool, skip(key) -> bool (open in the editor), report(info),
--   validate(rel, path) -> ok, why, dry (only decide), limits (see Engine.LIMITS),
--   allow_mass_delete, rebase (the library folder changed: start afresh), only (a set
--   of keys: decide just those, for a quick check of the notebook being opened), log(line).
-- Returns the result: { items, errors, warnings, counts..., fatal }.
function Engine.run(ctx)
    ctx.now = ctx.now or os.time
    ctx.sleep = ctx.sleep or function() end
    ctx.stop = ctx.stop or function() return false end
    ctx.skip = ctx.skip or function() return false end
    ctx.report = ctx.report or function() end
    ctx.log = ctx.log or function() end
    ctx.limits = setmetatable(ctx.limits or {}, { __index = Engine.LIMITS })
    ctx.areas = ctx.areas or { { id = "notebooks", enabled = function() return true end, library = true,
        owns = function() return true end, locate = function(rel) return Storage.join(ctx.root, rel) end } }
    local S = ctx.state
    local res = { items = {}, errors = {}, warnings = {}, uploaded = 0, downloaded = 0, conflicts = 0,
        deleted = 0, merged = 0, waiting = 0, started = ctx.now(), dry = ctx.dry or false }

    local function finish(fatal)
        res.fatal = fatal
        res.finished = ctx.now()
        if not ctx.dry then
            S.data.last = { at = res.finished, uploaded = res.uploaded, downloaded = res.downloaded,
                conflicts = res.conflicts, deleted = res.deleted, errors = #res.errors,
                fatal = fatal and fatal.code or nil, first_error = res.errors[1] and res.errors[1].err.code or nil }
            S:save()
            pcall(Backup.prune, ctx.backup_dir, ctx.now())
        end
        ctx.log(string.format("run %s: up %d down %d conflicts %d deleted %d errors %d%s", ctx.dry and "(dry)" or "",
            res.uploaded, res.downloaded, res.conflicts, res.deleted, #res.errors, fatal and (" FATAL " .. fatal.code) or ""))
        return res
    end

    if not Storage.isDir(ctx.root) then return finish(Errors.make("IA-S401", "library folder missing")) end
    if S.data.root and S.data.root ~= ctx.root and not ctx.rebase then
        return finish(Errors.make("IA-S506", S.data.root .. " -> " .. ctx.root))
    end
    if ctx.rebase and S.data.root ~= ctx.root then S:rebase(ctx.root) end
    S.data.root = ctx.root

    ctx.report({ phase = "check" })
    local ok, err = checkSchema(ctx)
    if not ok then return finish(err) end
    if ctx.stop() then return finish(Errors.make("IA-S502")) end

    -- what changed in the cloud
    ctx.report({ phase = "cloud" })
    local listing, lerr = try(ctx, function() return ctx.provider:list(S.data.cursor) end)
    if not listing then return finish(lerr) end
    if listing.reset or not S.data.cursor then S.data.remote = {} end
    for _i, e in ipairs(listing.entries) do
        if Engine.safeRel(e.rel) and not reserved(e.rel) then
            local key = lower(e.rel)
            if e.deleted then
                S.data.remote[key] = nil
                -- (a deleted folder is listed once, not once per file in it)
                local prefix = key .. "/"
                for k in pairs(S.data.remote) do
                    if k:sub(1, #prefix) == prefix then S.data.remote[k] = nil end
                end
            else S.data.remote[key] = { rel = e.rel, rev = e.rev, size = e.size, hash = e.hash } end
        end
    end
    local new_cursor = listing.cursor
    if ctx.stop() then return finish(Errors.make("IA-S502")) end

    -- what is on this reader
    ctx.report({ phase = "reader" })
    local clashes = {}
    local docs = walk(ctx.root, clashes)
    for k, rel in pairs(docs) do
        if not isTracked(ctx, rel) then docs[k] = nil end
    end
    -- the parts that are folders of their own, and the books
    local walked = {}
    for _i, a in ipairs(ctx.areas) do
        if a.walk and a.enabled() then
            a.walk(function(rel)
                local k = lower(rel)
                if walked[k] and walked[k] ~= rel then clashes[#clashes + 1] = { walked[k], rel } end
                if not walked[k] or rel < walked[k] then walked[k] = rel end
            end)
        end
    end
    for _i, c in ipairs(clashes) do
        res.warnings[#res.warnings + 1] = { rel = c[2], err = Errors.make("IA-S404", c[1] .. " / " .. c[2]) }
    end
    local used = usedFiles(ctx, docs, res)
    local keys, rels = {}, {}
    local function track(key, rel)
        if not rels[key] and isTracked(ctx, rel) then rels[key] = rel; keys[#keys + 1] = key end
    end
    for k, rel in pairs(docs) do track(k, rel) end
    for k, rel in pairs(walked) do track(k, rel) end
    for k, rel in pairs(used) do track(k, rel) end
    for k, b in pairs(S.data.files) do track(k, b.rel) end
    for k, r in pairs(S.data.remote) do track(k, r.rel) end

    table.sort(keys, function(a, b)
        local pa, pb = PRIORITY(rels[a]), PRIORITY(rels[b])
        if pa ~= pb then return pa < pb end
        return a < b
    end)

    -- decide
    local plan = {}
    local seen_stat = {}
    for _i, key in ipairs(keys) do
        local rel = rels[key]
        local b = S.data.files[key]
        local st = stat(abs(ctx, rel))
        seen_stat[key] = st
        local rem = S.data.remote[key]
        local loc = Plan.localState(b, st, function() return localHash(ctx, abs(ctx, rel), st.size) end)
        local rms = Plan.remoteState(b, rem)
        local action = Plan.decide(b, loc, rms, function()
            if not (st and rem) or st.size ~= rem.size then return false end
            if st.size > ctx.limits.hash_max or not rem.hash then return false end
            return remoteKind(ctx, abs(ctx, rel), rem.hash) == rem.hash
        end)
        if action ~= "none" and (not ctx.only or ctx.only[key]) then
            plan[#plan + 1] = { key = key, rel = rel, action = action }
        end
    end

    -- stop short of deleting much of the library
    local deletes = 0
    for _i, p in ipairs(plan) do
        if p.action == "delete_remote" or p.action == "delete_local" then deletes = deletes + 1 end
    end
    local tracked = 0
    for _k, b in pairs(S.data.files) do
        if isTracked(ctx, b.rel) then tracked = tracked + 1 end
    end
    if deletes >= ctx.limits.min_delete_guard and deletes > ctx.limits.max_delete_fraction * tracked
            and not ctx.allow_mass_delete then
        local kept = {}
        for _i, p in ipairs(plan) do
            if p.action ~= "delete_remote" and p.action ~= "delete_local" then kept[#kept + 1] = p end
        end
        plan = kept
        res.blocked_deletes = deletes
        res.errors[#res.errors + 1] = { rel = "", err = Errors.make("IA-S505", deletes .. " of " .. tracked) }
    end
    res.plan = plan
    if ctx.dry then
        return finish(nil)
    end

    -- do
    local i = 0
    local queue = plan
    local fatal
    while i < #queue do
        i = i + 1
        if ctx.stop() then fatal = Errors.make("IA-S502"); break end
        local p = queue[i]
        local key, rel, action = p.key, p.rel, p.action
        ctx.report({ phase = "files", done = i - 1, total = #queue, rel = rel, action = action })
        local good, ferr, extra
        if ctx.skip(key) and action ~= "none" then
            res.waiting = res.waiting + 1
            note(res, rel, action, "waiting")
            goto continue
        end
        do
            local rem = S.data.remote[key]
            local okc, a, b2 = pcall(function()
                if action == "upload" then return doUpload(ctx, key, rel)
                elseif action == "download" then return doDownload(ctx, key, rel, rem, seen_stat[key])
                elseif action == "conflict" then return doConflict(ctx, key, rel, rem, seen_stat[key])
                elseif action == "delete_remote" then
                    local b = S.data.files[key]
                    local r, e = try(ctx, function() return ctx.provider:delete(rel, b and b.rev) end)
                    if r or (e and e.code == "IA-S307") then
                        S.data.files[key] = nil; S.data.remote[key] = nil
                        return true
                    end
                    return nil, e
                elseif action == "delete_local" then
                    local bok, berr = backupOf(ctx, rel)
                    if not bok then return nil, berr end
                    if changedSince(ctx, rel, seen_stat[key]) then return nil, Errors.make("IA-S504", rel) end
                    os.remove(abs(ctx, rel))
                    S.data.files[key] = nil; S.data.remote[key] = nil
                    return true
                elseif action == "adopt" then
                    local st = seen_stat[key]
                    agree(ctx, key, rel, rem, st, localHash(ctx, abs(ctx, rel), st.size))
                    return true
                elseif action == "forget" then
                    S.data.files[key] = nil; S.data.remote[key] = nil
                    return true
                end
            end)
            if okc then good, ferr, extra = a, b2, nil; if action == "conflict" and good then extra = b2; ferr = nil end
            else good, ferr = nil, Errors.make("IA-S503", a) end
        end
        if good then
            if action == "upload" then res.uploaded = res.uploaded + 1
            elseif action == "download" then res.downloaded = res.downloaded + 1
            elseif action == "delete_remote" or action == "delete_local" then res.deleted = res.deleted + 1
            elseif action == "conflict" and extra == "" then
                -- merged: the combined file goes up as the next version
                res.merged = res.merged + 1; res.downloaded = res.downloaded + 1
                seen_stat[key] = stat(abs(ctx, rel))
                queue[#queue + 1] = { key = key, rel = rel, action = "upload" }
            elseif action == "conflict" then
                res.conflicts = res.conflicts + 1; res.downloaded = res.downloaded + 1
                -- the copy is a new file: send it too, in this run
                local ckey = lower(extra)
                rels[ckey] = extra
                seen_stat[ckey] = stat(abs(ctx, extra))
                queue[#queue + 1] = { key = ckey, rel = extra, action = "upload" }
            end
            note(res, rel, action, "ok")
        else
            if ferr and ferr.code == "IA-S504" then res.waiting = res.waiting + 1; note(res, rel, action, "waiting")
            else note(res, rel, action, "error", ferr) end
            if ferr and Errors.isFatal(ferr) then fatal = ferr; S:save(); break end
        end
        S:save()
        ::continue::
    end

    if not fatal and new_cursor then S.data.cursor = new_cursor end
    ctx.report({ phase = "done", done = #queue, total = #queue })
    return finish(fatal)
end

return Engine
