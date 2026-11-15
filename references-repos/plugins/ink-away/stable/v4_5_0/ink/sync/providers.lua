--[[
The cloud services the sync can use. A provider is a module with these
members (see ink/sync/providers/dropbox.lua, gdrive.lua and onedrive.lua, and
tests/sync/mockcloud.lua for a pretend one the tests use). Adding another service
means writing one more module like them and listing it here; the engine, the
settings and the screens do not change.

    id, name                     "dropbox", "Dropbox"
    AUTH                         "code": the person types a code from the phone into
                                 the reader; "device": the reader shows a code, the
                                 person types it on the phone, the reader waits
    HOSTS                        the hosts it may speak to ("*.example.com" for any below)
    beginAuth(app_key, app_secret) -> pending: { url, verifier } for "code" (an address
                                 to open on a phone), or { kind = "device", url,
                                 user_code, device_code, interval, expires_at }
    finishAuth(app_key, code, verifier) -> account record   ("code" only; what to keep)
    pollAuth(app_key, pending, app_secret) -> account record ("device" only), or
                                 nil and IA-S206 while the person has not allowed it yet
    new(account, opts)           -> an instance (opts: app_key, app_secret, now, save,
                                 dir for files of its own), which has:
      :accountInfo()             -> { id, name, email }
      :list(cursor)              -> { entries, cursor, reset }; an entry is
                                    { rel, rev, size, hash } or { rel, deleted = true }
      :download(rel, rev, dest)  -> { rev, size, hash }
      :upload(src, rel, expect)  -> { rev, size, hash }; `expect` is the revision the
                                    file builds on (nil: it must not exist yet), and a
                                    file changed meanwhile is refused with IA-S305
      :delete(rel, rev)
      :revisions(rel)            -> { { rev, size, mtime, current } }
      :restore(rel, rev)         -> { rev, size, hash }
      :hashFile(path, like)      -> (optional) the hash of a local file in the kind the
                                    service gives, `like` being one of its hashes;
                                    without it the file's Dropbox content hash is used

Every call returns its result, or nil and an error from ink/sync/errors.lua.
]]

local Providers = {}

local LIST = {
    { id = "dropbox", name = "Dropbox", module = "ink/sync/providers/dropbox" },
    { id = "gdrive", name = "Google Drive", module = "ink/sync/providers/gdrive" },
    { id = "onedrive", name = "OneDrive", module = "ink/sync/providers/onedrive" },
}

-- The services that can be chosen: { { id, name } }.
function Providers.list()
    local out = {}
    for _i, p in ipairs(LIST) do out[#out + 1] = { id = p.id, name = p.name } end
    return out
end

-- Services kept in the code but not offered yet (no registration for them). One
-- shows up on its own once Ink Away has a key for it (ink/sync/config.lua) or the
-- person already entered their own; delete it from this list to always offer it.
Providers.HIDDEN = { onedrive = true }

-- The services to offer on the connect screen: all of them, but a hidden one that
-- has no key. `get(setting)` reads a setting (the person's own keys are kept there).
function Providers.offered(get)
    local Config = require("ink/sync/config")
    local out = {}
    for _i, p in ipairs(Providers.list()) do
        if not Providers.HIDDEN[p.id] or Config.appKey(p.id, get) then out[#out + 1] = p end
    end
    return out
end

-- The module for service `id`, or nil.
function Providers.get(id)
    for _i, p in ipairs(LIST) do
        if p.id == id then
            local ok, mod = pcall(require, p.module)
            return ok and mod or nil
        end
    end
end

-- The display name of service `id`.
function Providers.name(id)
    for _i, p in ipairs(LIST) do if p.id == id then return p.name end end
    return tostring(id)
end

return Providers
