--[[
OneDrive (a personal Microsoft account), for the cloud sync (see
ink/sync/providers.lua for what a provider is).

Sign-in is Microsoft's device flow: the reader shows a short code, the person opens
microsoft.com/link on a phone (the QR code leads there), types the code and taps
Allow, and the reader, which waits for it, carries on by itself. Ink Away asks only
for the app folder permission, so it sees nothing but its own folder ("Apps/Ink
Away" in OneDrive). A refresh token is kept, never the password. Work and school
accounts are not supported: Microsoft gives an app folder only to personal accounts.

Files are addressed by path inside the app folder; the changes come from OneDrive's
delta feed, which names items by id, so the folder is also mapped by ids
(ink/sync/providers/idindex.lua). A file removed here goes to the OneDrive recycle
bin. An upload or delete says "only if unchanged" (If-Match), so a change in the
cloud in between is never overwritten.
]]

local Common = require("ink/sync/providers/common")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Http = require("ink/sync/http")
local Index = require("ink/sync/providers/idindex")
local Json = require("ink/sync/json")

local Onedrive = {}
Onedrive.__index = Onedrive

Onedrive.id = "onedrive"
Onedrive.name = "OneDrive"
Onedrive.AUTH = "device"
Onedrive.HOSTS = { "login.microsoftonline.com", "graph.microsoft.com", "api.onedrive.com", "*.1drv.com",
    "*.microsoftpersonalcontent.com", "*.live.com", "*.sharepoint.com" }
Onedrive.LOGIN = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
Onedrive.DEVICE_URL = Onedrive.LOGIN .. "/devicecode"
Onedrive.TOKEN_URL = Onedrive.LOGIN .. "/token"
Onedrive.GRAPH = "https://graph.microsoft.com/v1.0"
Onedrive.ROOT = Onedrive.GRAPH .. "/me/drive/special/approot"
Onedrive.SCOPE = "Files.ReadWrite.AppFolder offline_access User.Read"
Onedrive.DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
Onedrive.SIMPLE_MAX = 4 * 1000 * 1000     -- a bigger file goes up in an upload session
Onedrive.CHUNK = 12 * 327680              -- (a multiple of 320 KiB, as OneDrive wants)

local form, urlpath = Common.form, Common.urlpath

------------------------------------------------------------------------------
-- Errors
------------------------------------------------------------------------------

-- What a reply says went wrong, as an error. `ctx` is "code" while signing in.
local function replyError(reply, ctx)
    local code = reply.code
    local body = Common.body(reply)
    local err = type(body.error) == "table" and body.error or {}
    local oauth = type(body.error) == "string" and body.error or ""
    local gcode = tostring(err.code or "")
    local detail = string.format("HTTP %s %s %s", tostring(code), oauth ~= "" and oauth or gcode,
        tostring(err.message or body.error_description or ""):sub(1, 100))
    if oauth == "authorization_pending" then return Errors.make("IA-S206", detail) end
    if oauth == "slow_down" then return Errors.make("IA-S206", detail, 10) end
    if oauth == "authorization_declined" or oauth == "access_denied" or oauth == "expired_token" or oauth == "bad_verification_code" then
        return Errors.make("IA-S207", detail)
    end
    if oauth == "invalid_grant" or oauth == "interaction_required" then
        return Errors.make(ctx == "code" and "IA-S203" or "IA-S202", detail)
    end
    if oauth == "invalid_client" or oauth == "unauthorized_client" or oauth == "invalid_scope" or oauth == "consent_required" then
        return Errors.make("IA-S204", detail)
    end
    if code == 429 or gcode == "activityLimitReached" or gcode == "throttledRequest" then
        return Errors.make("IA-S302", detail, tonumber(reply.headers["retry-after"]) or 5)
    end
    if code == 401 then return Errors.make("IA-S202", detail) end
    if code == 507 or gcode == "quotaLimitReached" or gcode == "insufficientStorage" then return Errors.make("IA-S301", detail) end
    if code >= 500 then return Errors.make("IA-S303", detail, tonumber(reply.headers["retry-after"])) end
    if code == 403 then return Errors.make("IA-S204", detail) end
    if code == 404 or gcode == "itemNotFound" then return Errors.make("IA-S307", detail) end
    if code == 409 or code == 412 then return Errors.make("IA-S305", detail) end
    if code == 413 or gcode == "invalidFileName" or gcode == "invalidName" then return Errors.make("IA-S306", detail) end
    return Errors.make("IA-S304", detail)
end
Onedrive.replyError = replyError

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- Start a sign-in: returns { kind = "device", url, user_code, device_code,
-- interval, expires_at }. `app_key` is Ink Away's application (client) id.
function Onedrive.beginAuth(app_key)
    if type(app_key) ~= "string" or app_key == "" then return nil, Errors.make("IA-S204", "no client id") end
    local reply, err = Http.request({
        url = Onedrive.DEVICE_URL, method = "POST", hosts = Onedrive.HOSTS,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ client_id = app_key, scope = Onedrive.SCOPE }),
    })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply, "code") end
    local t = Json.decode(reply.body)
    local url = type(t) == "table" and (t.verification_uri or t.verification_url)
    if not (url and t.user_code and t.device_code) then return nil, Errors.make("IA-S304", "device code reply") end
    return { kind = "device", url = url, user_code = t.user_code, device_code = t.device_code,
        interval = tonumber(t.interval) or 5, expires_at = os.time() + (tonumber(t.expires_in) or 900) }
end

-- Ask whether the person has allowed it yet. Returns the account record (kept by
-- the caller), or nil and an error: IA-S206 means keep waiting.
function Onedrive.pollAuth(app_key, pending)
    if os.time() > (pending.expires_at or 0) then return nil, Errors.make("IA-S207", "expired") end
    local reply, err = Http.request({
        url = Onedrive.TOKEN_URL, method = "POST", hosts = Onedrive.HOSTS,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ client_id = app_key, device_code = pending.device_code, grant_type = Onedrive.DEVICE_GRANT }),
    })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply, "code") end
    local t = Json.decode(reply.body)
    if type(t) ~= "table" or not t.refresh_token or not t.access_token then
        return nil, Errors.make("IA-S304", "token reply")
    end
    return { provider = "onedrive", refresh_token = t.refresh_token, access_token = t.access_token,
        expires_at = os.time() + (tonumber(t.expires_in) or 3600) }
end

------------------------------------------------------------------------------
-- A signed-in provider
------------------------------------------------------------------------------

-- `account` is the record pollAuth made; `opts`: app_key, now(), save(account)
-- (called when the access token was renewed), dir (where the map of the folder
-- is kept).
function Onedrive.new(account, opts)
    opts = opts or {}
    return setmetatable({ account = account, app_key = opts.app_key, now = opts.now or os.time,
        save = opts.save, dir = opts.dir }, Onedrive)
end

function Onedrive:refreshForm()
    return { grant_type = "refresh_token", refresh_token = self.account.refresh_token,
        client_id = self.app_key, scope = Onedrive.SCOPE }
end

Common.client(Onedrive)

-- A call whose reply is JSON: returns the value, or nil, an error and the reply.
-- `url` is a whole address; `headers` and a JSON `body` are optional.
function Onedrive:json(method, url, body, headers)
    headers = headers or {}
    if body ~= nil then headers["Content-Type"] = "application/json" end
    local reply, err = self:call({ url = url, method = method, headers = headers,
        body = body ~= nil and Json.encode(body) or nil })
    if not reply then return nil, err end
    if reply.code ~= 200 and reply.code ~= 201 and reply.code ~= 204 then return nil, replyError(reply), reply end
    if reply.body == "" then return {} end
    local v = Json.decode(reply.body)
    if v == nil then return nil, Errors.make("IA-S304", "reply is not JSON") end
    return v
end

-- The address of the item at `rel` (with `more` after it: "/content").
local function item(rel, more)
    return Onedrive.ROOT .. ":/" .. urlpath(rel) .. ":" .. (more or "")
end

-- The hash OneDrive gives: SHA-1 where it has one, else the quickXorHash, with the
-- kind in front so the same kind can be worked out here.
local function hashOf(it)
    local h = it.file and it.file.hashes
    if type(h) ~= "table" then return nil end
    if h.sha1Hash then return "sha1:" .. tostring(h.sha1Hash):lower() end
    if h.quickXorHash then return "qx:" .. h.quickXorHash end
    return nil
end

-- A file's record from OneDrive's item.
local function meta(it, rel)
    return { rel = rel, rev = it.cTag or it.eTag, size = tonumber(it.size) or 0, hash = hashOf(it),
        mtime = Common.parseTime(it.lastModifiedDateTime) }
end

function Onedrive:accountInfo()
    local v, err = self:json("GET", Onedrive.GRAPH .. "/me?$select=id,displayName,mail,userPrincipalName")
    if not v then return nil, err end
    return { id = v.id, name = v.displayName or "", email = v.mail or v.userPrincipalName or "" }
end

------------------------------------------------------------------------------
-- Listing
------------------------------------------------------------------------------

-- The id of the app folder (OneDrive makes it when it is first asked for).
function Onedrive:index()
    if self.idx then return self.idx end
    local v, err = self:json("GET", Onedrive.ROOT .. "?$select=id")
    if not v then return nil, err end
    if not v.id then return nil, Errors.make("IA-S304", "no app folder") end
    self.idx = Index.load(self.dir and (self.dir .. "/onedrive-index.json") or nil, v.id)
    return self.idx
end

-- Read a delta feed from `url` to its end. Returns the listing, or nil, an error,
-- or nil, nil, true when a full listing is needed (the cursor ran out, or a folder
-- changed). `full` says this feed is the whole folder.
function Onedrive:feed(idx, url, full)
    if not url:find("^https://graph%.microsoft%.com/") then return nil, Errors.make("IA-S304", "cursor") end
    local files, at, deleted, folders_changed, final = {}, {}, {}, false, nil
    while url do
        local v, err, reply = self:json("GET", url)
        if not v then
            if reply and reply.code == 410 then return nil, nil, true end
            return nil, err
        end
        for _i, it in ipairs(v.value or {}) do
            local id = it.id
            local known = idx:get(id)
            local parent = it.parentReference and it.parentReference.id
            if not (it.root or id == idx.root) then   -- (the app folder itself is not an item)
                if it.deleted then
                    if known and known.folder then folders_changed = true
                    elseif known then
                        local rel = idx:relOf(id)
                        if rel then deleted[#deleted + 1] = { rel = rel, deleted = true } end
                        idx:remove(id)
                    end
                elseif it.folder then
                    if known and (known.name ~= it.name or known.parent ~= parent) then folders_changed = true end
                    idx:put(id, it.name, parent, true)
                elseif it.file then
                    -- (an item seen twice in the feed: the later one counts)
                    if at[id] then files[at[id]].it = it
                    else
                        files[#files + 1] = { it = it, old = known and idx:relOf(id) }
                        at[id] = #files
                    end
                    idx:put(id, it.name, parent, false)
                end
            end
        end
        final = v["@odata.deltaLink"] or final
        url = v["@odata.nextLink"]
    end
    if folders_changed and not full then return nil, nil, true end
    local entries, seen = {}, {}
    for _i, f in ipairs(files) do
        local rel = idx:relOf(f.it.id)
        if rel then
            entries[#entries + 1] = meta(f.it, rel)
            seen[rel] = true
            if f.old and f.old ~= rel then deleted[#deleted + 1] = { rel = f.old, deleted = true } end
        elseif f.old then
            deleted[#deleted + 1] = { rel = f.old, deleted = true }
        end
    end
    for _i, d in ipairs(deleted) do
        if not seen[d.rel] then entries[#entries + 1] = d end
    end
    table.sort(entries, function(a, b) return a.rel < b.rel end)
    if not final then return nil, Errors.make("IA-S304", "no delta link") end
    idx.cursor = final
    idx:save()
    return { entries = entries, cursor = final, reset = full }
end

-- The changes since `cursor` (everything if nil or if the map no longer matches
-- it): { entries = { {rel, rev, size, hash} | {rel, deleted = true} }, cursor, reset }.
function Onedrive:list(cursor)
    local idx, err = self:index()
    if not idx then return nil, err end
    if cursor and idx.cursor == cursor then
        local out, cerr, again = self:feed(idx, cursor, false)
        if out then return out end
        idx.cursor = nil   -- (half read: a retry in this run starts over; the file on disk is untouched)
        if not again then return nil, cerr end
    end
    idx:clear()
    local out, ferr = self:feed(idx, Onedrive.ROOT .. "/delta", true)
    if not out then return nil, ferr end
    return out
end

------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------

-- The item at `rel` as OneDrive has it now: the item, or nil (and nil) if there is
-- none, or nil and an error.
function Onedrive:stat(rel)
    local v, err = self:json("GET", item(rel))
    if v then return v end
    if err.code == "IA-S307" then return nil end
    return nil, err
end

-- Fetch the content at `url` (OneDrive answers with a redirect to where it is kept)
-- into `dest`.
function Onedrive:fetch(url, dest)
    local reply, err = self:call({ url = url, method = "GET", sink_file = dest })
    if reply and (reply.code == 301 or reply.code == 302 or reply.code == 303 or reply.code == 307 or reply.code == 308)
            and reply.headers.location then
        reply, err = self:call({ url = reply.headers.location, method = "GET", sink_file = dest, no_auth = true })
    end
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

-- Fetch the latest of `rel` into `dest` (OneDrive keeps no way to fetch a given
-- version here; the caller checks what arrived against the listing).
function Onedrive:download(rel, _rev, dest)
    local it, err = self:stat(rel)
    if not it then return nil, err or Errors.make("IA-S307", rel) end
    local ok, ferr = self:fetch(item(rel, "/content"), dest)
    if not ok then return nil, ferr end
    return meta(it, rel)
end

-- Send the pieces of a file to an upload session. Returns OneDrive's item, or
-- nil and an error.
function Onedrive:sendSession(session, src, size)
    local inf = io.open(src, "rb")
    if not inf then return nil, Errors.make("IA-S401") end
    local piece, offset = src .. ".piece", 0
    while offset < size do
        inf:seek("set", offset)
        local data = inf:read(Onedrive.CHUNK) or ""
        local out = io.open(piece, "wb")
        if not out then inf:close(); return nil, Errors.make("IA-S402", "piece") end
        out:write(data)
        out:close()
        local reply, err
        for _try = 1, 3 do
            reply, err = self:call({ url = session, method = "PUT", no_auth = true, body_file = piece,
                headers = { ["Content-Range"] = string.format("bytes %d-%d/%d", offset, offset + #data - 1, size) } })
            if reply and (reply.code == 200 or reply.code == 201 or reply.code == 202) then break end
            err = err or replyError(reply)
            reply = nil
            if not Errors.isRetryable(err) then break end
        end
        os.remove(piece)
        if not reply then inf:close(); return nil, err end
        if reply.code == 202 then
            local nxt = tonumber(tostring((Common.body(reply).nextExpectedRanges or {})[1] or ""):match("^(%d+)"))
            offset = nxt or (offset + #data)
        else
            inf:close()
            local it = Json.decode(reply.body)
            if type(it) ~= "table" or not it.id then return nil, Errors.make("IA-S304", "upload reply") end
            return it
        end
    end
    inf:close()
    return nil, Errors.make("IA-S304", "upload did not finish")
end

-- Send the file at `src` as `rel`. `expect` is the revision this builds on (the
-- file must still be at it), or nil for a file that must not exist yet.
function Onedrive:upload(src, rel, expect)
    local f, ferr = io.open(src, "rb")
    if not f then return nil, Errors.make("IA-S401", ferr) end
    local size = f:seek("end")
    f:close()
    local cur, serr = self:stat(rel)
    if serr then return nil, serr end
    if expect then
        if not cur then return nil, Errors.make("IA-S307", rel) end
        if (cur.cTag or cur.eTag) ~= expect then return nil, Errors.make("IA-S305", "changed meanwhile") end
    elseif cur then
        return nil, Errors.make("IA-S305", "already there")
    end
    local behaviour = cur and "replace" or "fail"
    local match = cur and { ["If-Match"] = cur.eTag } or {}
    local it
    if size <= Onedrive.SIMPLE_MAX then
        match["Content-Type"] = "application/octet-stream"
        local reply, err = self:call({ url = item(rel, "/content") .. "?@microsoft.graph.conflictBehavior=" .. behaviour,
            method = "PUT", headers = match, body_file = src })
        if not reply then return nil, err end
        if reply.code ~= 200 and reply.code ~= 201 then return nil, replyError(reply) end
        it = Json.decode(reply.body)
    else
        local s, err = self:json("POST", item(rel, "/createUploadSession"),
            { item = { ["@microsoft.graph.conflictBehavior"] = behaviour } }, match)
        if not s then return nil, err end
        if not s.uploadUrl then return nil, Errors.make("IA-S304", "no upload address") end
        local serr2
        it, serr2 = self:sendSession(s.uploadUrl, src, size)
        if not it then return nil, serr2 end
    end
    if type(it) ~= "table" or not it.id then return nil, Errors.make("IA-S304", "upload reply") end
    return meta(it, rel)
end

-- Move `rel` to the recycle bin; `rev` (if given) must still be its revision.
function Onedrive:delete(rel, rev)
    local cur, err = self:stat(rel)
    if not cur then return nil, err or Errors.make("IA-S307", rel) end
    if rev and (cur.cTag or cur.eTag) ~= rev then return nil, Errors.make("IA-S305", "changed meanwhile") end
    local v, derr = self:json("DELETE", item(rel), nil, { ["If-Match"] = cur.eTag })
    if not v then return nil, derr end
    return true
end

-- The earlier versions of a file, newest first: { { rev, size, mtime, current } }.
function Onedrive:revisions(rel)
    local v, err = self:json("GET", item(rel, "/versions"))
    if not v then return nil, err end
    local out = {}
    for i, e in ipairs(v.value or {}) do
        out[#out + 1] = { rev = e.id, size = tonumber(e.size), mtime = Common.parseTime(e.lastModifiedDateTime), current = i == 1 }
    end
    return out
end

-- Make an earlier version the current one again (as a new version, so it syncs).
function Onedrive:restore(rel, rev)
    local cur, err = self:stat(rel)
    if not cur then return nil, err or Errors.make("IA-S307", rel) end
    local tmp = os.tmpname()
    local ok, ferr = self:fetch(item(rel, "/versions/" .. Common.urlencode(rev) .. "/content"), tmp)
    if not ok then os.remove(tmp); return nil, ferr end
    local m, uerr = self:upload(tmp, rel, cur.cTag or cur.eTag)
    os.remove(tmp)
    if not m then return nil, uerr end
    return m
end

-- The hash of a file here, the same kind OneDrive gave for the remote one `like`.
function Onedrive:hashFile(path, like)
    like = tostring(like or "")
    if like:sub(1, 5) == "sha1:" then
        local h = Hash.sha1(path)
        return h and ("sha1:" .. h:lower()) or nil
    end
    if like:sub(1, 3) == "qx:" then
        local h = Hash.quickXor(path)
        return h and ("qx:" .. h) or nil
    end
    return nil
end

return Onedrive
