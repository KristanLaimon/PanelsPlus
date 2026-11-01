local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local FS = require("meguru/fs")

local Sources = {}

-- Per-run, keyed by marker path: a catalog open can fetch before the flush.
-- It deliberately outranks the file, so a password changed now still wins.
local session = {}

function Sources.remember(marker_path, username, password)
    if marker_path and (username ~= nil or password ~= nil) then
        session[marker_path] = { username = username, password = password }
    end
end

-- The OPDS browser's live list: it holds an add or an edit before the flush.
-- Without it, a catalog added and browsed in one session names no server.
local session_servers

function Sources.rememberServers(servers)
    if type(servers) == "table" then
        session_servers = servers
    end
end

function Sources.settingsFile()
    return DataStorage:getSettingsDir() .. "/opds.lua"
end

function Sources.list()
    local file = Sources.settingsFile()
    if not FS.exists(file) then
        return {}
    end
    -- LuaSettings.open is a colon method; pcall needs a closure for the path.
    local ok, ls = pcall(function()
        return LuaSettings:open(file)
    end)
    if not ok or not ls then
        logger.warn("Meguru: could not read", file)
        return {}
    end
    local servers = ls:readSetting("servers")
    return type(servers) == "table" and servers or {}
end

function Sources.find(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    -- Session first: a catalog edited there is ahead of the file until exit.
    for _, entry in ipairs(session_servers or {}) do
        if type(entry) == "table" and entry.title == title then
            return entry
        end
    end
    for _, entry in ipairs(Sources.list()) do
        if type(entry) == "table" and entry.title == title then
            return entry
        end
    end
    return nil
end

-- Separate from find: the root URL is secret-bearing and must stay in a local.
function Sources.connection(title)
    local entry = Sources.find(title)
    if not entry then
        return nil
    end
    return {
        name     = entry.title,
        url      = entry.url,
        username = entry.username,
        password = entry.password,
    }
end

-- Session memory first, then the configured catalog; nil means no auth.
function Sources.credentials(server_name, marker_path)
    local cached = marker_path and session[marker_path]
    if cached then
        return cached.username, cached.password
    end
    local entry = Sources.find(server_name)
    if entry then
        return entry.username, entry.password
    end
    return nil
end

return Sources
