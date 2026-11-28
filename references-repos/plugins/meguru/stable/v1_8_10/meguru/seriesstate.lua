-- The row answers a series shares, in one hidden file in the series' folder.

local LuaSettings = require("luasettings")
local logger = require("logger")

local FS = require("meguru/fs")

local SeriesState = {}

-- Beside the markers, or beside the .cbz files; never a .meguru name, which the
-- registry would offer as a book.
SeriesState.FILE_NAME = ".meguru-series.lua"

-- The series' folder and the identity its answers are filed under, or nothing
-- for a book that has no series of its own to share with.
local function location(doc)
    if not (type(doc) == "table" and doc.provider == "meguru") then
        return nil
    end
    local dir = type(doc.file) == "string"
        and doc.file:match("^(.*)[/\\][^/\\]*$")
    if not dir or dir == "" then
        return nil
    end

    if doc.local_cbz then
        -- A local book's series is its folder, and only with a second
        -- book in it.
        if type(doc.localSeries) ~= "function" or not doc:localSeries() then
            return nil
        end
        -- One fixed name, not the path: the file is already in the folder, and
        -- a copied library is at a new path with the same answers in it.
        return dir, "series"
    end

    -- A marker with no series name lands in the base folder, shared with every
    -- other such book: it has no folder of its own to keep answers in.
    local desc = doc.desc
    if type(desc) ~= "table" then
        return nil
    end
    local server, series, name = desc.server_name, desc.series_remote_id,
        desc.series_name
    if type(server) ~= "string" or server == ""
        or type(series) ~= "string" or series == ""
        or type(name) ~= "string" or name == "" then
        return nil
    end
    return dir, "s|" .. server .. "|" .. series
end

-- One folder can hold two series whose names sanitize the same way, and a
-- marker can fall back to an ancestor folder: the file belongs to the folder,
-- and the identity inside it is what keeps those apart.
local function fileFor(doc)
    local dir = location(doc)
    if not dir then
        return nil
    end
    return dir .. "/" .. SeriesState.FILE_NAME
end

-- nil for a book with no series: it keeps the sidecar-and-preference behaviour.
function SeriesState.keyFor(doc)
    local _, key = location(doc)
    return key
end

-- The reader's own answer for one series, and the escape from a folder of books
-- that were never a series: false is written, sharing on is the absence of it.
function SeriesState.sharedFor(doc)
    local file = fileFor(doc)
    local key = SeriesState.keyFor(doc)
    if not (file and key) then
        return false
    end
    local entry = LuaSettings:open(file):readSetting(key)
    return not (type(entry) == "table" and entry.share == false)
end

-- Writes that answer; the rows already in the file are kept either way, so
-- turning sharing back on restores what the series had.
function SeriesState.setShared(doc, shared)
    local file = fileFor(doc)
    local key = SeriesState.keyFor(doc)
    if not (file and key) then
        return false
    end
    local settings = LuaSettings:open(file)
    local entry = settings:readSetting(key)
    if type(entry) ~= "table" then
        entry = {}
    end
    -- Written out, never "shared and nil or false": that reads as false always.
    if shared then
        entry.share = nil
    else
        entry.share = false
    end
    settings:saveSetting(key, entry)
    settings:flush()
    if not FS.exists(file) then
        logger.warn("Meguru: could not write", file,
            "- the series still shares its settings")
        return false
    end
    logger.info("Meguru: series", key, shared
        and "shares settings again"
        or "keeps its books' settings apart")
    return true
end

-- The series' answers, read from the file beside its books; none while the
-- reader has taken this series out of the sharing.
function SeriesState.answersFor(doc)
    local file = fileFor(doc)
    local key = SeriesState.keyFor(doc)
    if not (file and key) then
        return nil
    end
    local stored = LuaSettings:open(file):readSetting(key)
    if type(stored) ~= "table" or stored.share == false then
        return nil
    end
    return stored
end

-- Read-modify-save, as a settings file holds no merge of its own; false when
-- there was nowhere to write, since a lost answer belongs to the reader.
function SeriesState.learn(doc, changes)
    local file = fileFor(doc)
    local key = SeriesState.keyFor(doc)
    if not (file and key) or type(changes) ~= "table" then
        return false
    end
    local named = {}
    for row, value in pairs(changes) do
        if value ~= nil then
            named[#named + 1] = row .. "=" .. tostring(value)
        end
    end
    if #named == 0 then
        return false
    end

    local settings = LuaSettings:open(file)
    local entry = settings:readSetting(key)
    if type(entry) ~= "table" then
        entry = {}
    end
    if entry.share == false then
        logger.dbg("Meguru: series", key,
            "keeps its books apart; nothing written")
        return false
    end
    for row, value in pairs(changes) do
        if value ~= nil then
            entry[row] = value
        end
    end
    settings:saveSetting(key, entry)
    settings:flush()

    if not FS.exists(file) then
        logger.warn("Meguru: could not write", file,
            "- the series' answers were not kept")
        return false
    end
    table.sort(named)
    logger.dbg("Meguru: series", key, "answers", table.concat(named, " "))
    return true
end

return SeriesState
