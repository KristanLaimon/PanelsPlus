-- The one thing Meguru writes that is not a marker, for files outside KOReader.
-- KOReader never displays it; nothing here reads it back. It is not a cache.
-- Written once per series, never removed; a server switched off writes no more.
local logger = require("logger")

local FS = require("meguru/fs")
local Net = require("meguru/net")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

local SeriesCover = {}

SeriesCover.FILENAME = ".cover.jpg"

-- Closed: Settings.get warns on an unknown key, so gate on this first.
SeriesCover.KINDS = { "suwayomi", "kavita", "komga" }

local function settingFor(kind)
    return "folder_cover_" .. kind
end
SeriesCover.settingFor = settingFor

local function wanted(kind)
    for _, known in ipairs(SeriesCover.KINDS) do
        if known == kind then
            return Settings.get(settingFor(kind)) and true or false
        end
    end
    return false
end

-- Lazy: NetworkMgr is device state, absent where the UI is not up yet.
local function isConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr ~= nil and NetworkMgr:isConnected()
end

-- Every failure is survivable: this runs inside an open, cover is decoration.
-- Folder taken from marker_path, not Marker.dirFor; the marker sits in it too.
function SeriesCover.save(marker_path, desc)
    if type(desc) ~= "table" or type(marker_path) ~= "string" then
        return nil
    end
    if not wanted(desc.server_kind) then
        return nil
    end
    local url = desc.series_cover_url
    if type(url) ~= "string" or url == "" then
        -- No cover URL: an older marker, or a feed that published no artwork.
        return nil
    end
    local dir = marker_path:match("^(.*)/[^/]+$")
    if not dir then
        return nil
    end
    local path = dir .. "/" .. SeriesCover.FILENAME
    if FS.exists(path) then
        -- Already written: the ordinary case after the first volume; silent.
        return nil
    end
    if not isConnected() then
        logger.dbg("Meguru: no connection, leaving the series cover alone for", marker_path)
        return nil
    end

    local username, password = Sources.credentials(desc.server_name, marker_path)
    local code, _, body = Net.get(url, {
        username = username,
        password = password,
        accept = Net.IMAGE_ACCEPT,
        timeout = "page",
    })
    -- Check the empty body too: a 0-byte file would make FS.exists say done.
    if code ~= 200 or type(body) ~= "string" or #body == 0 then
        logger.info("Meguru: could not fetch the series cover for", marker_path,
            "(", tostring(code), ")")
        return nil
    end

    local written, err = FS.writeFile(path, body)
    if not written then
        -- The one fault here: the server answered and the disk refused it.
        logger.warn("Meguru: could not write the series cover to", path,
            "-", tostring(err))
        return nil, err
    end
    logger.dbg("Meguru: series cover written to", path)
    return written
end

return SeriesCover
