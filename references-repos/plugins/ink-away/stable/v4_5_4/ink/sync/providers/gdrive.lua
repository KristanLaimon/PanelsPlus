--[[
Google Drive, for the cloud sync (see ink/sync/providers.lua for what a provider is).

Sign-in is Google's device flow: the reader shows a short code, the person opens
google.com/device on a phone (the QR code leads there), types the code and taps
Allow, and the reader, which waits for it, carries on by itself. Ink Away asks only
for the drive.file permission, which sees nothing but the files Ink Away made, and
keeps them in a folder called "Ink Away" in My Drive. A refresh token is kept,
never the password.

Drive names files by id, not by path, so the folder is mapped by ids
(ink/sync/providers/idindex.lua) and the changes come from Drive's change feed. A
file removed here goes to Drive's bin (kept 30 days), not away for good. Drive does
not offer "only if unchanged" on an upload, so the file is looked at just before
it is replaced and a change in that moment is the only one that could slip by.
]]

local Common = require("ink/sync/providers/common")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Http = require("ink/sync/http")
local Index = require("ink/sync/providers/idindex")
local Json = require("ink/sync/json")

local Gdrive = {}
Gdrive.__index = Gdrive

Gdrive.id = "gdrive"
Gdrive.name = "Google Drive"
Gdrive.AUTH = "device"
Gdrive.HOSTS = { "oauth2.googleapis.com", "www.googleapis.com" }
Gdrive.DEVICE_URL = "https://oauth2.googleapis.com/device/code"
Gdrive.TOKEN_URL = "https://oauth2.googleapis.com/token"
Gdrive.API = "https://www.googleapis.com/drive/v3"
Gdrive.UPLOAD = "https://www.googleapis.com/upload/drive/v3"
Gdrive.SCOPE = "https://www.googleapis.com/auth/drive.file"
Gdrive.FOLDER_NAME = "Ink Away"
Gdrive.FOLDER = "application/vnd.google-apps.folder"
Gdrive.SINGLE_MAX = 8 * 1024 * 1024       -- a bigger file goes up in pieces
Gdrive.CHUNK = 4 * 1024 * 1024            -- (a multiple of 256 KiB, as Drive wants)
Gdrive.FIELDS = "id,name,parents,mimeType,md5Checksum,size,headRevisionId,modifiedTime,trashed"
Gdrive.DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

local form = Common.form

-- A string for a Drive query ('...'): quotes and backslashes escaped.
local function esc(s) return (tostring(s):gsub("[\\']", "\\%0")) end

------------------------------------------------------------------------------
-- Errors
------------------------------------------------------------------------------

-- What a reply says went wrong, as an error. `ctx` is "code" while signing in.
local function replyError(reply, ctx)
    local code = reply.code
    local body = Common.body(reply)
    local err = type(body.error) == "table" and body.error or {}
    local oauth = type(body.error) == "string" and body.error or ""
    local reason = err.errors and err.errors[1] and err.errors[1].reason or ""
    local detail = string.format("HTTP %s %s %s", tostring(code), oauth ~= "" and oauth or reason,
        tostring(err.message or body.error_description or ""):sub(1, 100))
    if oauth == "authorization_pending" then return Errors.make("IA-S206", detail) end
    if oauth == "slow_down" then return Errors.make("IA-S206", detail, 10) end
    if oauth == "access_denied" or oauth == "authorization_declined" or oauth == "expired_token" then return Errors.make("IA-S207", detail) end
    if oauth == "invalid_grant" then return Errors.make(ctx == "code" and "IA-S203" or "IA-S202", detail) end
    if oauth == "invalid_client" or oauth == "unauthorized_client" or oauth == "invalid_scope" then
        return Errors.make("IA-S204", detail)
    end
    if code == 429 then return Errors.make("IA-S302", detail, tonumber(reply.headers["retry-after"]) or 5) end
    if code == 401 then return Errors.make("IA-S202", detail) end
    if code >= 500 then return Errors.make("IA-S303", detail) end
    if code == 403 then
        if reason == "storageQuotaExceeded" then return Errors.make("IA-S301", detail) end
        if reason:find("ateLimitExceeded", 1, true) or reason == "dailyLimitExceeded" then
            return Errors.make("IA-S302", detail, 3)
        end
        return Errors.make("IA-S204", detail)
    end
    if code == 404 then return Errors.make("IA-S307", detail) end
    if code == 412 then return Errors.make("IA-S305", detail) end
    return Errors.make("IA-S304", detail)
end
Gdrive.replyError = replyError

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- Start a sign-in: returns { kind = "device", url, user_code, device_code,
-- interval, expires_at }. `app_key` is Ink Away's client id.
function Gdrive.beginAuth(app_key)
    if type(app_key) ~= "string" or app_key == "" then return nil, Errors.make("IA-S204", "no client id") end
    local reply, err = Http.request({
        url = Gdrive.DEVICE_URL, method = "POST", hosts = Gdrive.HOSTS,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ client_id = app_key, scope = Gdrive.SCOPE }),
    })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply, "code") end
    local t = Json.decode(reply.body)
    local url = type(t) == "table" and (t.verification_url or t.verification_uri)
    if not (url and t.user_code and t.device_code) then return nil, Errors.make("IA-S304", "device code reply") end
    return { kind = "device", url = url, user_code = t.user_code, device_code = t.device_code,
        interval = tonumber(t.interval) or 5, expires_at = os.time() + (tonumber(t.expires_in) or 900) }
end

-- Ask whether the person has allowed it yet. Returns the account record (kept by
-- the caller), or nil and an error: IA-S206 means keep waiting.
function Gdrive.pollAuth(app_key, pending, app_secret)
    if os.time() > (pending.expires_at or 0) then return nil, Errors.make("IA-S207", "expired") end
    local reply, err = Http.request({
        url = Gdrive.TOKEN_URL, method = "POST", hosts = Gdrive.HOSTS,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ client_id = app_key, client_secret = app_secret or "", device_code = pending.device_code,
            grant_type = Gdrive.DEVICE_GRANT }),
    })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply, "code") end
    local t = Json.decode(reply.body)
    if type(t) ~= "table" or not t.refresh_token or not t.access_token then
        return nil, Errors.make("IA-S304", "token reply")
    end
    return { provider = "gdrive", refresh_token = t.refresh_token, access_token = t.access_token,
        expires_at = os.time() + (tonumber(t.expires_in) or 3600) }
end

------------------------------------------------------------------------------
-- A signed-in provider
------------------------------------------------------------------------------

-- `account` is the record pollAuth made; `opts`: app_key, app_secret, now(),
-- save(account) (called when the access token was renewed or the folder made),
-- dir (where the map of the folder is kept).
function Gdrive.new(account, opts)
    opts = opts or {}
    return setmetatable({ account = account, app_key = opts.app_key, app_secret = opts.app_secret,
        now = opts.now or os.time, save = opts.save, dir = opts.dir }, Gdrive)
end

function Gdrive:refreshForm()
    return { grant_type = "refresh_token", refresh_token = self.account.refresh_token,
        client_id = self.app_key, client_secret = self.app_secret or "" }
end

Common.client(Gdrive)

-- A call whose reply is JSON: returns the value, or nil, an error and the reply.
function Gdrive:api(method, path, query, body)
    local url = Gdrive.API .. path .. (query and next(query) and ("?" .. form(query)) or "")
    local reply, err = self:call({ url = url, method = method,
        headers = body and { ["Content-Type"] = "application/json" } or nil, body = body and Json.encode(body) or nil })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply), reply end
    local v = Json.decode(reply.body)
    if v == nil then return nil, Errors.make("IA-S304", "reply is not JSON") end
    return v
end

-- A file's record from Drive's metadata.
local function meta(f, rel)
    return { rel = rel, rev = f.headRevisionId or f.md5Checksum, size = tonumber(f.size) or 0, hash = f.md5Checksum,
        mtime = Common.parseTime(f.modifiedTime) }
end

function Gdrive:accountInfo()
    local v, err = self:api("GET", "/about", { fields = "user(displayName,emailAddress,permissionId)" })
    if not v then return nil, err end
    local u = v.user or {}
    return { id = u.permissionId, name = u.displayName or "", email = u.emailAddress or "" }
end

------------------------------------------------------------------------------
-- The folder, and the map of it
------------------------------------------------------------------------------

-- The id of the "Ink Away" folder, made if there is none.
function Gdrive:root()
    local a = self.account
    if a.root_id then
        local v, err = self:api("GET", "/files/" .. a.root_id, { fields = "id,trashed" })
        if v and not v.trashed then return a.root_id end
        if not v and err.code ~= "IA-S307" then return nil, err end
    end
    local v, err = self:api("GET", "/files", { fields = "files(id)", pageSize = 1, orderBy = "createdTime",
        q = string.format("mimeType='%s' and name='%s' and 'root' in parents and trashed=false", Gdrive.FOLDER, esc(Gdrive.FOLDER_NAME)) })
    if not v then return nil, err end
    local id = v.files and v.files[1] and v.files[1].id
    if not id then
        local made, merr = self:api("POST", "/files", { fields = "id" },
            { name = Gdrive.FOLDER_NAME, mimeType = Gdrive.FOLDER, parents = { "root" } })
        if not made then return nil, merr end
        id = made.id
    end
    a.root_id = id
    if self.save then pcall(self.save, a) end
    return id
end

function Gdrive:index()
    if self.idx then return self.idx end
    local root, err = self:root()
    if not root then return nil, err end
    self.idx = Index.load(self.dir and (self.dir .. "/gdrive-index.json") or nil, root)
    return self.idx
end

local function parentOf(f) return f.parents and f.parents[1] end

-- The path of `id`, fetching any folder above it the map does not know yet.
function Gdrive:resolveRel(idx, id)
    local cur = idx:get(id) and idx:get(id).parent
    for _depth = 1, 30 do
        if not cur or cur == idx.root or idx:get(cur) then break end
        local f = self:api("GET", "/files/" .. cur, { fields = "id,name,parents,mimeType,trashed" })
        if not f or f.trashed then return nil end
        idx:put(f.id, f.name, parentOf(f), true)
        cur = parentOf(f)
    end
    return idx:relOf(id)
end

-- Of the entries found for one path (Drive allows two files of one name) keep the
-- newest, and give the entries in path order.
local function distinct(byrel)
    local out = {}
    for _rel, e in pairs(byrel) do out[#out + 1] = e end
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return out
end

-- The whole folder: a start token first (so nothing is missed in between), then
-- every file Ink Away made.
function Gdrive:fullList(idx)
    local tok, err = self:api("GET", "/changes/startPageToken", {})
    if not tok then return nil, err end
    idx:clear()
    local files, page = {}, nil
    repeat
        local v, lerr = self:api("GET", "/files", { q = "trashed=false", pageSize = 1000, pageToken = page,
            fields = "nextPageToken,files(" .. Gdrive.FIELDS .. ")" })
        if not v then return nil, lerr end
        for _i, f in ipairs(v.files or {}) do
            idx:put(f.id, f.name, parentOf(f), f.mimeType == Gdrive.FOLDER)
            if f.mimeType ~= Gdrive.FOLDER then files[#files + 1] = f end
        end
        page = v.nextPageToken
    until not page
    local byrel = {}
    for _i, f in ipairs(files) do
        local rel = idx:relOf(f.id)
        if rel then
            local m = meta(f, rel)
            local old = byrel[rel]
            if not old or (m.mtime or 0) > (old.mtime or 0) then byrel[rel] = m end
        end
    end
    idx.cursor = tok.startPageToken
    idx:save()
    return { entries = distinct(byrel), cursor = tok.startPageToken, reset = true }
end

-- The changes since `cursor`. Returns the listing, or nil, an error; or nil, nil,
-- true when a full listing is needed (the token ran out, or a folder changed).
function Gdrive:changes(idx, cursor)
    local byrel, deleted, full, page, newtoken = {}, {}, false, cursor, nil
    repeat
        local v, err = self:api("GET", "/changes", { pageToken = page, pageSize = 1000, includeRemoved = true,
            fields = "nextPageToken,newStartPageToken,changes(fileId,removed,file(" .. Gdrive.FIELDS .. "))" })
        if not v then
            if err.code == "IA-S307" or err.code == "IA-S304" then return nil, nil, true end
            return nil, err
        end
        for _i, ch in ipairs(v.changes or {}) do
            local id, f = ch.fileId, ch.file
            local known = idx:get(id)
            if ch.removed or (f and f.trashed) then
                if known and known.folder then full = true
                elseif known then
                    local rel = idx:relOf(id)
                    if rel then deleted[#deleted + 1] = { rel = rel, deleted = true } end
                    idx:remove(id)
                end
            elseif f and f.mimeType == Gdrive.FOLDER then
                if known and (known.name ~= f.name or known.parent ~= parentOf(f)) then full = true end
                idx:put(id, f.name, parentOf(f), true)
            elseif f then
                local oldrel = known and idx:relOf(id)
                idx:put(id, f.name, parentOf(f), false)
                local rel = self:resolveRel(idx, id)
                if rel then
                    byrel[rel] = meta(f, rel)
                    if oldrel and oldrel ~= rel then deleted[#deleted + 1] = { rel = oldrel, deleted = true } end
                elseif oldrel then
                    deleted[#deleted + 1] = { rel = oldrel, deleted = true }
                end
            end
        end
        page = v.nextPageToken
        newtoken = v.newStartPageToken or newtoken
    until not page
    if full then return nil, nil, true end
    local entries = distinct(byrel)
    for _i, d in ipairs(deleted) do
        if not byrel[d.rel] then entries[#entries + 1] = d end
    end
    idx.cursor = newtoken or cursor
    idx:save()
    return { entries = entries, cursor = idx.cursor, reset = false }
end

-- The changes since `cursor` (everything if nil or if the map no longer matches
-- it): { entries = { {rel, rev, size, hash} | {rel, deleted = true} }, cursor, reset }.
function Gdrive:list(cursor)
    local idx, err = self:index()
    if not idx then return nil, err end
    if cursor and idx.cursor == cursor then
        local out, cerr, again = self:changes(idx, cursor)
        if out then return out end
        idx.cursor = nil   -- (half read: a retry in this run starts over; the file on disk is untouched)
        if not again then return nil, cerr end
    end
    return self:fullList(idx)
end

-- The id and record of `rel` as Drive has it now (looking folder by folder), or nil.
function Gdrive:lookup(rel)
    local idx, err = self:index()
    if not idx then return nil, err end
    local parts = {}
    for p in rel:gmatch("[^/]+") do parts[#parts + 1] = p end
    local parent, rec = idx.root, nil
    for i, name in ipairs(parts) do
        local v, lerr = self:api("GET", "/files", { pageSize = 10, orderBy = "createdTime",
            fields = "files(" .. Gdrive.FIELDS .. ")",
            q = string.format("'%s' in parents and name='%s' and trashed=false", parent, esc(name)) })
        if not v then return nil, lerr end
        rec = v.files and v.files[1]
        if not rec or (i < #parts and rec.mimeType ~= Gdrive.FOLDER) then return nil end
        idx:put(rec.id, rec.name, parent, rec.mimeType == Gdrive.FOLDER)
        parent = rec.id
    end
    return rec and rec.id, rec
end

-- The id and record of `rel`, from the map if it knows it, else from Drive.
function Gdrive:find(rel)
    local idx, err = self:index()
    if not idx then return nil, err end
    local id = idx:idOf(rel)
    if id then
        local f, gerr = self:api("GET", "/files/" .. id, { fields = Gdrive.FIELDS })
        if f and not f.trashed then return id, f end
        if not f and gerr.code ~= "IA-S307" then return nil, gerr end
        idx:remove(id)
    end
    return self:lookup(rel)
end

-- The id of folder `dir` (a path), made as far as it is missing.
function Gdrive:ensureFolder(dir)
    local idx, err = self:index()
    if not idx then return nil, err end
    local parent, path = idx.root, nil
    for name in dir:gmatch("[^/]+") do
        path = path and (path .. "/" .. name) or name
        local id = idx:idOf(path)
        if not id then
            local _lid, rec = self:lookup(path)
            id = rec and rec.mimeType == Gdrive.FOLDER and rec.id or nil
        end
        if not id then
            local made, merr = self:api("POST", "/files", { fields = "id" },
                { name = name, mimeType = Gdrive.FOLDER, parents = { parent } })
            if not made then return nil, merr end
            id = made.id
            idx:put(id, name, parent, true)
        end
        parent = id
    end
    return parent
end

------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------

-- Fetch a file's content (or a given earlier revision of it) into `dest`.
function Gdrive:fetch(id, revision, dest)
    local url = Gdrive.API .. "/files/" .. id .. (revision and ("/revisions/" .. revision) or "") .. "?alt=media"
    local reply, err = self:call({ url = url, method = "GET", sink_file = dest })
    if not reply then return nil, err end
    if reply.code ~= 200 then
        local f = io.open(dest, "rb")
        reply.body = f and f:read(4096) or ""
        if f then f:close() end
        os.remove(dest)
        return nil, replyError(reply)
    end
    return true
end

-- Fetch `rel` (revision `rev`, or the latest) into `dest`.
function Gdrive:download(rel, rev, dest)
    local id, f = self:find(rel)
    if not id then return nil, f or Errors.make("IA-S307", rel) end
    local old = rev and rev ~= f.headRevisionId and rev or nil
    local ok, err = self:fetch(id, old, dest)
    if not ok then return nil, err end
    if not old then return meta(f, rel) end
    local r = self:api("GET", "/files/" .. id .. "/revisions/" .. old, { fields = "id,md5Checksum,size,modifiedTime" })
    if not r then os.remove(dest); return nil, Errors.make("IA-S304", "revision") end
    return { rel = rel, rev = old, size = tonumber(r.size) or 0, hash = r.md5Checksum, mtime = Common.parseTime(r.modifiedTime) }
end

-- Send the pieces of a file to an upload session. Returns Drive's record of the
-- new file, or nil and an error.
function Gdrive:sendSession(session, src, size)
    local function put(headers, file)
        local err
        for _try = 1, 3 do
            local reply, e = self:call({ url = session, method = "PUT", headers = headers, body_file = file })
            if reply and (reply.code == 200 or reply.code == 201 or reply.code == 308) then return reply end
            err = e or replyError(reply)
            if not Errors.isRetryable(err) then break end
        end
        return nil, err
    end
    local function done(reply)
        local f = Json.decode(reply.body)
        if type(f) ~= "table" or not f.id then return nil, Errors.make("IA-S304", "upload reply") end
        return f
    end
    if size <= Gdrive.SINGLE_MAX then
        local reply, err = put({ ["Content-Type"] = "application/octet-stream" }, src)
        if not reply then return nil, err end
        return done(reply)
    end
    local inf = io.open(src, "rb")
    if not inf then return nil, Errors.make("IA-S401") end
    local piece, offset = src .. ".piece", 0
    while offset < size do
        inf:seek("set", offset)
        local data = inf:read(Gdrive.CHUNK) or ""
        local out = io.open(piece, "wb")
        if not out then inf:close(); return nil, Errors.make("IA-S402", "piece") end
        out:write(data)
        out:close()
        local reply, err = put({ ["Content-Type"] = "application/octet-stream",
            ["Content-Range"] = string.format("bytes %d-%d/%d", offset, offset + #data - 1, size) }, piece)
        os.remove(piece)
        if not reply then inf:close(); return nil, err end
        if reply.code == 308 then
            local last = tonumber(tostring(reply.headers.range or ""):match("bytes=0%-(%d+)"))
            offset = last and (last + 1) or (offset + #data)
        else
            inf:close()
            return done(reply)
        end
    end
    inf:close()
    return nil, Errors.make("IA-S304", "upload did not finish")
end

-- Send the file at `src` as `rel`. `expect` is the revision this builds on (the
-- file must still be at it), or nil for a file that must not exist yet.
function Gdrive:upload(src, rel, expect)
    local f, ferr = io.open(src, "rb")
    if not f then return nil, Errors.make("IA-S401", ferr) end
    local size = f:seek("end")
    f:close()
    local idx, ierr = self:index()
    if not idx then return nil, ierr end
    local dir, base = rel:match("^(.*)/([^/]+)$")
    local parent = idx.root
    if dir then
        local perr
        parent, perr = self:ensureFolder(dir)
        if not parent then return nil, perr end
    else
        base = rel
    end
    local id, cur = self:find(rel)
    if not id and cur then return nil, cur end
    if expect then
        if not id then return nil, Errors.make("IA-S307", rel) end
        if (cur.headRevisionId or cur.md5Checksum) ~= expect then return nil, Errors.make("IA-S305", "changed meanwhile") end
    elseif id then
        return nil, Errors.make("IA-S305", "already there")
    end
    local url, method, body
    if id then
        url, method, body = Gdrive.UPLOAD .. "/files/" .. id, "PATCH", "{}"
    else
        url, method = Gdrive.UPLOAD .. "/files", "POST"
        body = Json.encode({ name = base, parents = { parent }, mimeType = "application/octet-stream" })
    end
    local reply, err = self:call({ url = url .. "?" .. form({ uploadType = "resumable", fields = Gdrive.FIELDS }), method = method,
        headers = { ["Content-Type"] = "application/json; charset=UTF-8", ["X-Upload-Content-Type"] = "application/octet-stream",
            ["X-Upload-Content-Length"] = tostring(size) }, body = body })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply) end
    local session = reply.headers.location
    if not session then return nil, Errors.make("IA-S304", "no upload address") end
    local rec, serr = self:sendSession(session, src, size)
    if not rec then return nil, serr end
    idx:put(rec.id, rec.name or base, parentOf(rec) or parent, false)
    idx:save()
    return meta(rec, rel)
end

-- Move `rel` to Drive's bin (kept 30 days); `rev` (if given) must still be its revision.
function Gdrive:delete(rel, rev)
    local id, f = self:find(rel)
    if not id then return nil, f or Errors.make("IA-S307", rel) end
    if rev and (f.headRevisionId or f.md5Checksum) ~= rev then return nil, Errors.make("IA-S305", "changed meanwhile") end
    local v, err = self:api("PATCH", "/files/" .. id, { fields = "id" }, { trashed = true })
    if not v then return nil, err end
    local idx = self:index()
    if idx then idx:remove(id); idx:save() end
    return true
end

-- The earlier versions of a file, newest first: { { rev, size, mtime, current } }.
function Gdrive:revisions(rel)
    local id, f = self:find(rel)
    if not id then return nil, f or Errors.make("IA-S307", rel) end
    local v, err = self:api("GET", "/files/" .. id .. "/revisions", { pageSize = 200, fields = "revisions(id,modifiedTime,size)" })
    if not v then return nil, err end
    local out, list = {}, v.revisions or {}
    for i = #list, 1, -1 do
        local r = list[i]
        out[#out + 1] = { rev = r.id, size = tonumber(r.size), mtime = Common.parseTime(r.modifiedTime), current = i == #list }
    end
    return out
end

-- Make an earlier version the current one again (as a new version, so it syncs).
function Gdrive:restore(rel, rev)
    local id, f = self:find(rel)
    if not id then return nil, f or Errors.make("IA-S307", rel) end
    local tmp = os.tmpname()
    local ok, err = self:fetch(id, rev, tmp)
    if not ok then os.remove(tmp); return nil, err end
    local m, uerr = self:upload(tmp, rel, f.headRevisionId or f.md5Checksum)
    os.remove(tmp)
    if not m then return nil, uerr end
    return m
end

-- The hash of a file here, the way Drive gives it.
function Gdrive:hashFile(path) return (Hash.md5(path)) end

return Gdrive
