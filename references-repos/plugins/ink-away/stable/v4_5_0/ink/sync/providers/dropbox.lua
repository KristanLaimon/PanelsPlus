--[[
Dropbox, for the cloud sync (see ink/sync/providers.lua for what a provider is).

Sign-in is Dropbox's code flow with PKCE, which needs no server and no PC: the
reader shows an address (as a QR code), the person opens it on a phone, taps
Allow, and types the short code Dropbox shows into the reader. Ink Away keeps a
refresh token (never the password) and fetches short-lived access tokens with it.
The app has its own folder in the person's Dropbox ("Apps/Ink Away") and cannot
see anything else.

Everything goes through Http.request (ink/sync/http.lua), so the tests replace
the network with a pretend Dropbox.
]]

local Common = require("ink/sync/providers/common")
local Errors = require("ink/sync/errors")
local Hash = require("ink/sync/hash")
local Http = require("ink/sync/http")
local Json = require("ink/sync/json")

local Dropbox = {}
Dropbox.__index = Dropbox

Dropbox.id = "dropbox"
Dropbox.name = "Dropbox"
Dropbox.AUTH = "code"      -- the person types a code from the phone into the reader
Dropbox.HOSTS = { "api.dropboxapi.com", "content.dropboxapi.com" }
Dropbox.AUTH_URL = "https://www.dropbox.com/oauth2/authorize"
Dropbox.API = "https://api.dropboxapi.com"
Dropbox.CONTENT = "https://content.dropboxapi.com"
Dropbox.TOKEN_URL = "https://api.dropboxapi.com/oauth2/token"
Dropbox.SINGLE_MAX = 8 * 1024 * 1024      -- a bigger file goes up in pieces
Dropbox.CHUNK = 4 * 1024 * 1024

------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------

local form, randomBytes = Common.form, Common.randomBytes

-- (kept here for the tests and callers that had them)
Dropbox.base64url = Common.base64url
Dropbox.parseTime = Common.parseTime

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- Start a sign-in: returns { url, verifier }. `app_key` is Ink Away's app key.
function Dropbox.beginAuth(app_key)
    if type(app_key) ~= "string" or app_key == "" then return nil, Errors.make("IA-S204", "no app key") end
    local raw = randomBytes(48)
    local verifier = Dropbox.base64url(raw)
    local challenge = Dropbox.base64url(Hash.sha256bin(verifier))
    local url = Dropbox.AUTH_URL .. "?" .. form({
        client_id = app_key, response_type = "code", code_challenge = challenge,
        code_challenge_method = "S256", token_access_type = "offline",
    })
    return { url = url, verifier = verifier }
end

-- What a reply says went wrong, as an error.
local function replyError(reply, ctx)
    local code = reply.code
    local body = Json.decode(reply.body or "") or {}
    local summary = tostring(body.error_summary or body.error_description or body.error or "")
    local detail = string.format("HTTP %s %s", tostring(code), summary:sub(1, 120))
    if code == 429 then
        local after = tonumber(reply.headers["retry-after"]) or (type(body.error) == "table" and tonumber(body.error.retry_after)) or 5
        return Errors.make("IA-S302", detail, after)
    end
    if code == 401 then return Errors.make("IA-S202", detail) end
    if code == 403 then return Errors.make("IA-S204", detail) end
    if code >= 500 then return Errors.make("IA-S303", detail) end
    if code == 400 and (summary:find("invalid_grant", 1, true) or tostring(body.error) == "invalid_grant") then
        return Errors.make(ctx == "code" and "IA-S203" or "IA-S202", detail)
    end
    if code == 409 or code == 400 then
        if summary:find("insufficient_space", 1, true) then return Errors.make("IA-S301", detail) end
        if summary:find("too_many_write_operations", 1, true) or summary:find("too_many_requests", 1, true) then
            return Errors.make("IA-S302", detail, 3)
        end
        if summary:find("not_found", 1, true) then return Errors.make("IA-S307", detail) end
        if summary:find("conflict", 1, true) then return Errors.make("IA-S305", detail) end
        if summary:find("unsupported_file", 1, true) or summary:find("disallowed_name", 1, true)
                or summary:find("too_large", 1, true) then
            return Errors.make("IA-S306", detail)
        end
    end
    return Errors.make("IA-S304", detail)
end
Dropbox.replyError = replyError

-- Finish a sign-in with the code the person typed. Returns the account record
-- (kept by the caller; holds the refresh token), or nil and an error.
function Dropbox.finishAuth(app_key, code, verifier)
    code = tostring(code or ""):gsub("%s", "")
    if code == "" then return nil, Errors.make("IA-S203", "empty code") end
    local reply, err = Http.request({
        url = Dropbox.API .. "/oauth2/token", method = "POST", hosts = Dropbox.HOSTS,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ code = code, grant_type = "authorization_code", code_verifier = verifier, client_id = app_key }),
    })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply, "code") end
    local t = Json.decode(reply.body)
    if type(t) ~= "table" or not t.refresh_token or not t.access_token then
        return nil, Errors.make("IA-S304", "token reply")
    end
    return { provider = "dropbox", refresh_token = t.refresh_token, access_token = t.access_token,
        expires_at = os.time() + (tonumber(t.expires_in) or 14400), account_id = t.account_id }
end

------------------------------------------------------------------------------
-- A signed-in provider
------------------------------------------------------------------------------

-- `account` is the record finishAuth made; `opts`: app_key, now(), save(account)
-- (called when the access token was renewed), sleep(s).
function Dropbox.new(account, opts)
    opts = opts or {}
    return setmetatable({ account = account, app_key = opts.app_key, now = opts.now or os.time,
        save = opts.save }, Dropbox)
end

-- The fields that renew the access token.
function Dropbox:refreshForm()
    return { grant_type = "refresh_token", refresh_token = self.account.refresh_token, client_id = self.app_key }
end

Common.client(Dropbox)

-- A call whose reply is JSON.
function Dropbox:rpc(path, arg)
    local body = arg ~= nil and Json.encode(arg) or "null"
    local reply, err = self:call({ url = Dropbox.API .. path, method = "POST",
        headers = { ["Content-Type"] = "application/json" }, body = body })
    if not reply then return nil, err end
    if reply.code ~= 200 then return nil, replyError(reply), reply end
    if reply.body == "" then return {} end
    local v = Json.decode(reply.body)
    if v == nil then return nil, Errors.make("IA-S304", "reply is not JSON") end
    return v
end

-- A file's record from Dropbox's metadata.
local function meta(m)
    return { rel = (m.path_display or ("/" .. tostring(m.name))):sub(2), rev = m.rev, size = m.size, hash = m.content_hash,
        mtime = Dropbox.parseTime(m.server_modified) }
end

-- Who is signed in: { id, name, email }.
function Dropbox:accountInfo()
    local v, err = self:rpc("/2/users/get_current_account", nil)
    if not v then return nil, err end
    return { id = v.account_id, name = v.name and v.name.display_name or "", email = v.email or "" }
end

-- The changes since `cursor` (everything if nil or if Dropbox no longer knows
-- the cursor): { entries = { {rel, rev, size, hash} | {rel, deleted = true} },
-- cursor, reset }.
function Dropbox:list(cursor)
    local entries, reset = {}, false
    local v, err, reply
    if cursor then
        v, err, reply = self:rpc("/2/files/list_folder/continue", { cursor = cursor })
        if not v and reply and reply.code == 409 and tostring(reply.body):find("reset", 1, true) then
            reset, cursor, v = true, nil, nil
        elseif not v then
            return nil, err
        end
    end
    if not cursor then
        v, err = self:rpc("/2/files/list_folder", { path = "", recursive = true, include_deleted = true,
            include_media_info = false, limit = 2000 })
        if not v then return nil, err end
    end
    while true do
        for _i, e in ipairs(v.entries or {}) do
            local tag = e[".tag"]
            if tag == "file" then entries[#entries + 1] = meta(e)
            elseif tag == "deleted" then
                entries[#entries + 1] = { rel = (e.path_display or e.name and ("/" .. e.name) or "/"):sub(2), deleted = true }
            end
        end
        if not v.has_more then break end
        v, err = self:rpc("/2/files/list_folder/continue", { cursor = v.cursor })
        if not v then return nil, err end
    end
    return { entries = entries, cursor = v.cursor, reset = reset or cursor == nil }
end

-- Fetch a file (a given revision, or the latest) into `dest`.
function Dropbox:download(rel, rev, dest)
    local reply, err = self:call({ url = Dropbox.CONTENT .. "/2/files/download", method = "POST",
        headers = { ["Dropbox-API-Arg"] = Json.encode({ path = rev and ("rev:" .. rev) or ("/" .. rel) }) },
        sink_file = dest })
    if not reply then return nil, err end
    if reply.code ~= 200 then
        local f = io.open(dest, "rb")
        reply.body = f and f:read(4096) or ""
        if f then f:close() end
        os.remove(dest)
        return nil, replyError(reply)
    end
    local m = Json.decode(reply.headers["dropbox-api-result"] or "")
    if type(m) ~= "table" then os.remove(dest); return nil, Errors.make("IA-S304", "no file record") end
    local r = meta(m)
    r.rel = rel
    return r
end

local function writeMode(expect)
    if expect then return { [".tag"] = "update", update = expect } end
    return { [".tag"] = "add" }
end

-- Send the file at `src` as `rel`. `expect` is the revision this builds on (the
-- file must still be at it), or nil for a file that must not exist yet.
function Dropbox:upload(src, rel, expect)
    local f, ferr = io.open(src, "rb")
    if not f then return nil, Errors.make("IA-S401", ferr) end
    local size = f:seek("end")
    f:close()
    local arg = { path = "/" .. rel, mode = writeMode(expect), autorename = false, mute = true, strict_conflict = true }
    if size <= Dropbox.SINGLE_MAX then
        local reply, err = self:call({ url = Dropbox.CONTENT .. "/2/files/upload", method = "POST",
            headers = { ["Dropbox-API-Arg"] = Json.encode(arg), ["Content-Type"] = "application/octet-stream" },
            body_file = src })
        if not reply then return nil, err end
        if reply.code ~= 200 then return nil, replyError(reply) end
        local m = Json.decode(reply.body)
        if type(m) ~= "table" then return nil, Errors.make("IA-S304", "upload reply") end
        return meta(m)
    end
    return self:uploadInPieces(src, size, arg)
end

-- A big file: a session, the file in pieces, then the commit.
function Dropbox:uploadInPieces(src, size, arg)
    local inf = io.open(src, "rb")
    if not inf then return nil, Errors.make("IA-S401") end
    local piece = src .. ".piece"
    local function send(path, header, data)
        local out = io.open(piece, "wb")
        if not out then return nil, Errors.make("IA-S402", "piece") end
        out:write(data)
        out:close()
        local err
        for _try = 1, 3 do
            local reply, e = self:call({ url = Dropbox.CONTENT .. path, method = "POST",
                headers = { ["Dropbox-API-Arg"] = Json.encode(header), ["Content-Type"] = "application/octet-stream" },
                body_file = piece })
            if reply and reply.code == 200 then os.remove(piece); return reply end
            err = e or replyError(reply)
            if not Errors.isRetryable(err) then break end
        end
        os.remove(piece)
        return nil, err
    end
    local first = inf:read(Dropbox.CHUNK) or ""
    local reply, err = send("/2/files/upload_session/start", { close = false }, first)
    if not reply then inf:close(); return nil, err end
    local sid = (Json.decode(reply.body) or {}).session_id
    if not sid then inf:close(); return nil, Errors.make("IA-S304", "no session") end
    local offset = #first
    while size - offset > Dropbox.CHUNK do
        local data = inf:read(Dropbox.CHUNK)
        local r2, e2 = send("/2/files/upload_session/append_v2",
            { cursor = { session_id = sid, offset = offset }, close = false }, data)
        if not r2 then inf:close(); return nil, e2 end
        offset = offset + #data
    end
    local rest = inf:read(Dropbox.CHUNK) or ""
    inf:close()
    local r3, e3 = send("/2/files/upload_session/finish",
        { cursor = { session_id = sid, offset = offset }, commit = arg }, rest)
    if not r3 then return nil, e3 end
    local m = Json.decode(r3.body)
    if type(m) ~= "table" then return nil, Errors.make("IA-S304", "finish reply") end
    return meta(m)
end

-- Delete `rel`; `rev` (if given) must still be its revision. Dropbox keeps it
-- recoverable for 30 days or more.
function Dropbox:delete(rel, rev)
    local v, err = self:rpc("/2/files/delete_v2", { path = "/" .. rel, parent_rev = rev })
    if not v then return nil, err end
    return true
end

-- The earlier versions of a file, newest first: { { rev, size, mtime, current } }.
function Dropbox:revisions(rel)
    local v, err = self:rpc("/2/files/list_revisions", { path = "/" .. rel, mode = { [".tag"] = "path" }, limit = 20 })
    if not v then return nil, err end
    local out = {}
    for i, e in ipairs(v.entries or {}) do
        out[#out + 1] = { rev = e.rev, size = e.size, mtime = Dropbox.parseTime(e.server_modified), current = i == 1 }
    end
    return out
end

-- Make an earlier version the current one again (a new revision, so it syncs).
function Dropbox:restore(rel, rev)
    local v, err = self:rpc("/2/files/restore", { path = "/" .. rel, rev = rev })
    if not v then return nil, err end
    return meta(v)
end

return Dropbox
