local Device = require("device")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Credential = require("meguru/credential")
local FS = require("meguru/fs")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

local Marker = {}

-- Also the "is this file ours" read test: a stray .meguru reads back nil.
Marker.SETTINGS_KEY = Paths.MARKER_EXT

Marker.VERSION = 2

-- In-memory descriptor: URLs stay live; saveAt redacts a copy on the way out.
function Marker.new(fields)
    return {
        version          = Marker.VERSION,
        server_name      = fields.server_name,
        series_remote_id = fields.series_remote_id,
        series_name      = fields.series_name,
        server_kind      = fields.server_kind,
        item_key         = fields.item_key,
        title            = fields.title,
        template         = fields.template,
        count            = fields.count,
        last_read        = fields.last_read,
        lang             = fields.lang,
        cover_url        = fields.cover_url,
        series_cover_url = fields.series_cover_url,
    }
end

-- A URL field missing here is written to disk with Kavita's API key in it.
local CREDENTIAL_FIELDS = { "template", "cover_url", "series_cover_url" }

-- The one place v1 fields may be nil; every caller falls back but server_kind.
function Marker.seriesContext(desc)
    if type(desc) ~= "table" then
        return nil
    end
    return {
        server_name      = desc.server_name,
        server_kind      = desc.server_kind,
        series_remote_id = desc.series_remote_id,
        series_name      = desc.series_name,
        item_key         = desc.item_key,
        lang             = desc.lang,
        cover_url        = desc.cover_url,
        series_cover_url = desc.series_cover_url,
    }
end

-- Doubles as "is this file ours"; no catalog still valid, just unfetchable.
function Marker.isValid(desc)
    return type(desc) == "table"
        and type(desc.template) == "string" and desc.template ~= ""
        and type(desc.item_key) == "string" and desc.item_key ~= ""
end

function Marker.naturalKey(desc)
    return table.concat({
        desc.server_name or "",
        desc.series_remote_id or "",
        desc.item_key or "",
    }, "|")
end

-- Inverse of saveAt's redaction; a marker with no catalog still loads.
local function restoreCredential(desc)
    -- Up front and once: the common marker has no placeholder and needs no log line.
    local pending = false
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        local value = desc[field]
        if type(value) == "string" and value:find(Credential.PLACEHOLDER, 1, true) then
            pending = true
            break
        end
    end
    if not pending then
        return desc
    end

    local conn = Sources.connection(desc.server_name)
    -- Warn once per marker, not per field: three alerts would read as three faults.
    local stuck = {}
    local restored_count = 0
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        local value = desc[field]
        if type(value) == "string" and value:find(Credential.PLACEHOLDER, 1, true) then
            local restored, count = Credential.restoreTemplate(value, conn and conn.url)
            if count == 0 then
                stuck[#stuck + 1] = field
            else
                desc[field] = restored
                restored_count = restored_count + count
            end
        end
    end
    if #stuck > 0 then
        -- Pasteable diagnosis: a stuck cover costs a cover, a stuck template the book.
        logger.warn("Meguru: the marker for", desc.title or "?", "still has"
            .. " redacted URLs in", table.concat(stuck, ", "), "and no usable"
            .. " catalog named", tostring(desc.server_name),
            "- it opens, but those fetches cannot")
    end
    if restored_count > 1 then
        -- The credential sat in more than one path position, each filled the same.
        logger.dbg("Meguru: restored", restored_count, "credentials in the"
            .. " marker for", desc.title or "?")
    end
    return desc
end

function Marker.load(path)
    if not FS.exists(path) then
        return nil
    end
    -- Colon method: a bare pcall would bind path to self and read an empty table.
    local ok, ls = pcall(function()
        return LuaSettings:open(path)
    end)
    if not ok or not ls then
        return nil
    end
    local desc = ls:readSetting(Marker.SETTINGS_KEY)
    if not Marker.isValid(desc) then
        return nil
    end
    return restoreCredential(desc)
end

function Marker.matches(path, desc)
    local existing = Marker.load(path)
    return existing ~= nil and Marker.naturalKey(existing) == Marker.naturalKey(desc)
end

-- A stale choice (media unplugged) falls back rather than losing the marker.
function Marker.baseDir()
    local dir = Settings.get("marker_dir")
    if type(dir) == "string" and dir ~= "" then
        if FS.ensureDir(dir) then
            return dir
        end
        logger.warn("Meguru: marker folder unusable (", dir,
            "), falling back to the home folder")
    end
    return Marker.homeDir()
end

-- Falls back to the cache dir, not KOReader's bare "." (the process CWD).
function Marker.homeDir()
    local dir
    local g = rawget(_G, "G_reader_settings")
    local configured = g and type(g.readSetting) == "function" and g:readSetting("home_dir")
    if type(configured) == "string" and configured ~= "" then
        dir = configured
    elseif type(Device.home_dir) == "string" and Device.home_dir ~= "" then
        dir = Device.home_dir
    end
    if type(dir) == "string" and dir ~= "" and FS.ensureDir(dir) then
        return dir
    end
    logger.warn("Meguru: home folder unusable, falling back to the plugin cache dir")
    return FS.ensureDir(Paths.cacheDir()) or Paths.cacheDir()
end

-- Falls back to the home folder so a stored folder on dead media never starts the picker.
function Marker.pickerStartDir()
    local dir = Settings.get("marker_dir")
    if type(dir) == "string" and dir ~= "" and FS.isDir(dir) then
        return dir
    end
    return Marker.homeDir()
end

-- Pure: creates nothing, so a dismissed dialog leaves no empty folder behind.
function Marker.dirFor(desc, opts)
    opts = opts or {}
    local dir = opts.base_dir or Marker.baseDir()

    if opts.server_folder and type(desc.server_name) == "string" and desc.server_name ~= "" then
        local server = Naming.sanitizeComponent(desc.server_name)
        if server ~= "stream" then
            dir = dir .. "/" .. server
        end
    end

    if type(desc.series_name) == "string" and desc.series_name ~= "" then
        local component = Naming.sanitizeComponent(desc.series_name)
        if component ~= "stream" then
            -- Two series may share a folder; pathFor disambiguates the file.
            dir = dir .. "/" .. component
        end
    end

    return dir
end

-- A different book on the title gets a natural-key suffix so neither clobbers.
function Marker.pathFor(dir, desc)
    local base = Naming.markerBaseName(desc.title)
    local plain = dir .. "/" .. base .. "." .. Paths.MARKER_EXT
    if not FS.exists(plain) or Marker.matches(plain, desc) then
        return plain
    end
    return dir .. "/" .. Naming.disambiguated(base, Marker.naturalKey(desc))
        .. "." .. Paths.MARKER_EXT
end

-- Climbs to the nearest makeable ancestor, stopping at the baseDir.
local function ensureDirOrAncestor(dir)
    local base = Marker.baseDir()
    local candidate = dir
    while true do
        if FS.ensureDir(candidate) then
            return candidate
        end
        if #candidate <= #base then
            return nil
        end
        candidate = candidate:match("^(.*)/[^/]+$") or base
    end
end

-- Folder is made at write time, so a dismissed dialog leaves nothing behind.
function Marker.saveAt(path, desc)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        local usable = ensureDirOrAncestor(dir)
        if not usable then
            logger.warn("Meguru: no usable folder for", path, "- the marker was not written")
            return nil
        end
        if usable ~= dir then
            logger.warn("Meguru: could not create", dir,
                "- the marker goes in", usable)
            path = usable .. "/" .. (path:match("([^/]+)$") or path)
        end
    end
    -- Copy via pairs: LuaSettings holds the table by reference until flush().
    local stored = {}
    for key, value in pairs(desc) do
        stored[key] = value
    end
    -- Redact every URL field: Kavita's key rides in cover URLs too.
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        if type(stored[field]) == "string" then
            stored[field] = Credential.redactTemplate(stored[field])
        end
    end
    local ls = LuaSettings:open(path)
    ls:saveSetting(Marker.SETTINGS_KEY, stored)
    ls:flush()
    logger.info("Meguru: marker written to", path)
    return path
end

return Marker
