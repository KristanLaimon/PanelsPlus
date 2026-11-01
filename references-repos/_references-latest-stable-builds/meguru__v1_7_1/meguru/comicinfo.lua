-- Reads a .cbz's ComicInfo.xml into doc_props terms; absent is ordinary.
-- Only "no entry" is silent; every other empty result logs at info.

local logger = require("logger")

local ComicInfo = {}

-- Five predefined entities; `&amp;` is the one that turns up in series names.
local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
    ["&quot;"] = '"', ["&apos;"] = "'",
}

local ENTRY = "ComicInfo.xml"

-- Ceiling so a huge entry under this name cannot be allocated.
-- The real entry is under a kilobyte.
local MAX_BYTES = 64 * 1024

-- Once per process: a build without libarchive fails for every book alike.
local archive_support_reported = false

-- Which ComicInfo element answers which doc_props key.
-- Names match case-insensitively: writers emit LanguageIso, not LanguageISO.
-- keywords takes Tags then Genre; authors takes Writer, both judgement calls.
local MAP = {
    { prop = "title",        tags = { "title" } },
    { prop = "series",       tags = { "series" } },
    { prop = "series_index", tags = { "number" }, numeric = true },
    { prop = "language",     tags = { "languageiso" } },
    { prop = "keywords",     tags = { "tags", "genre" } },
    { prop = "description",  tags = { "summary" } },
    { prop = "authors",      tags = { "writer" } },
}

-- Trim, decode entities, reject empty; non-text answers as an absent field.
local function text(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("&%a+;", ENTITIES):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

-- Flat schema: the closing tag must follow at once, which also skips the root.
-- An empty element then reads the same as an absent one.
local function elements(xml)
    local found = {}
    for tag, value in xml:gmatch("<([%w_]+)%s*>([^<]*)</%1>") do
        local name = tag:lower()
        local decoded = text(value)
        if decoded and found[name] == nil then
            found[name] = decoded
        end
    end
    return found
end

-- Nil is ordinary (no entry, or unreadable): metadata must never cost a book.
-- Every caller falls back to the file name.
function ComicInfo.read(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    -- Lazy: its body loads libarchive; lacking it degrades only this feature.
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or not Archiver.Reader then
        if not archive_support_reported then
            archive_support_reported = true
            logger.info("Meguru: cannot read .cbz metadata - this build of"
                .. " KOReader has no archive support")
        end
        return nil
    end
    local reader = Archiver.Reader:new()
    if not reader:open(file) then
        logger.info("Meguru: cannot open", file, "to read its metadata ("
            .. tostring(reader.err or "no reason given") .. ")")
        return nil
    end

    -- `entry.size` is cdata int64, so compare it directly.
    -- `type(...) == "number"` is false for `754LL`.
    local found, xml
    pcall(function()
        for entry in reader:iterate() do
            if entry.path == ENTRY and entry.mode == "file" then
                found = true
                if entry.size and entry.size > MAX_BYTES then
                    break
                end
                xml = reader:extractToMemory(entry.path)
                break
            end
        end
    end)
    reader:close()

    if not found then
        -- The ordinary case, deliberately silent.
        return nil
    end
    if type(xml) ~= "string" then
        logger.info("Meguru: " .. ENTRY .. " in", file, "could not be read")
        return nil
    end

    local fields = elements(xml)
    local props, count = {}, 0
    for _, rule in ipairs(MAP) do
        local value
        for _, tag in ipairs(rule.tags) do
            value = fields[tag]
            if value then
                break
            end
        end
        if value then
            -- Number is a schema string; keep a value that will not convert.
            props[rule.prop] = rule.numeric and (tonumber(value) or value) or value
            count = count + 1
        end
    end
    if count == 0 then
        logger.info("Meguru: " .. ENTRY .. " in", file,
            "carries none of the fields a book is shown by")
        return nil
    end
    logger.dbg("Meguru: .cbz metadata -", count, "field(s), title",
        props.title or "(none)")
    return props
end

return ComicInfo
