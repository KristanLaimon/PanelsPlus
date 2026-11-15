--[[
What the cloud sync needs to know about Ink Away's own registration with each
service. The keys are public (they identify the app, they are not a secret: the
sign-in holds no password or private key; Google's "client secret" for an app on a
device is published inside the app by design). A person who runs their own copy of
the plugin can enter their own in the sync settings, and those win.
]]

local _ = require("ink/l10n")

local Config = {}

-- Ink Away's registrations. Register an app at each service's developer site and
-- put its keys here:
--   Dropbox     dropbox.com/developers: "App folder" access, permissions
--               files.metadata.read (listing and versions), files.content.read,
--               files.content.write (upload, delete, restore), account_info.read
--   Google      console.cloud.google.com: enable the Drive API, an OAuth client of
--               the type "TVs and Limited Input devices", the scope drive.file, and
--               publish the consent screen (in testing it signs out after 7 days)
--   Microsoft   entra.microsoft.com: a registration for personal accounts, "Allow
--               public client flows" on, delegated permissions
--               Files.ReadWrite.AppFolder, offline_access and User.Read
Config.DROPBOX_APP_KEY = "terkf6o0m0ess2l"
-- (Google's are left out of the repository, as GitHub refuses a push with a Google
-- client secret in it: the release build carries them in ink/sync/localkeys.lua.)
Config.GDRIVE_CLIENT_ID = ""
Config.GDRIVE_CLIENT_SECRET = ""
Config.ONEDRIVE_CLIENT_ID = ""

Config.KEY_SETTING = "inkaway_sync_dropbox_key"   -- (the first one; kept as it was)

local function validKey(own) return type(own) == "string" and own:match("^%w+$") ~= nil and #own >= 8 and #own <= 64 end
local function validGoogleId(own) return type(own) == "string" and own:match("^[%w%-%._]+$") ~= nil and #own >= 16 and #own <= 128 end
local function validGoogleSecret(own) return type(own) == "string" and own:match("^[%w%-_]+$") ~= nil and #own >= 8 and #own <= 128 end
local function validGuid(own) return type(own) == "string" and own:lower():match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil and #own == 36 end

-- The fields a service's registration has, in the order they are asked: the
-- setting the person's own is kept in, a label, and a check on what they type.
local FIELDS = {
    dropbox = { { setting = Config.KEY_SETTING, label = _("App key"), valid = validKey } },
    gdrive = {
        { setting = "inkaway_sync_gdrive_key", label = _("Client ID"), valid = validGoogleId },
        { setting = "inkaway_sync_gdrive_secret", label = _("Client secret"), valid = validGoogleSecret },
    },
    onedrive = { { setting = "inkaway_sync_onedrive_key", label = _("Application (client) ID"), valid = validGuid } },
}

-- The registration fields of service `id`: { { setting, label, valid(text) } }.
function Config.fields(id)
    return FIELDS[id] or {}
end

-- Registrations kept out of the repository: ink/sync/localkeys.lua, which git
-- ignores and the release build carries (Ink Away's Google registration). The
-- tests switch it off.
local function localKeys()
    if rawget(_G, "INKAWAY_NO_LOCALKEYS") then return {} end
    local ok, t = pcall(require, "ink/sync/localkeys")
    return ok and type(t) == "table" and t or {}
end

local BUILT_IN = {
    dropbox = function() return localKeys().dropbox_key or Config.DROPBOX_APP_KEY, nil end,
    gdrive = function()
        local l = localKeys()
        return l.gdrive_id or Config.GDRIVE_CLIENT_ID, l.gdrive_secret or Config.GDRIVE_CLIENT_SECRET
    end,
    onedrive = function() return localKeys().onedrive_id or Config.ONEDRIVE_CLIENT_ID, nil end,
}

-- The key (and secret, where the service has one) to use: the person's own if
-- they entered them, else Ink Away's. `get(setting)` reads a setting. Returns
-- nil when there is no key.
function Config.appKey(provider_id, get)
    local f = FIELDS[provider_id]
    if not f then return nil end
    local own = get and get(f[1].setting)
    local own_secret = f[2] and get and get(f[2].setting)
    if f[1].valid(own) and (not f[2] or f[2].valid(own_secret)) then return own, own_secret end
    local key, secret = BUILT_IN[provider_id]()
    if key ~= "" and (not f[2] or secret ~= "") then return key, secret end
    return nil
end

return Config
