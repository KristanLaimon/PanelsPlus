-- Chapters carry no stream (resolved lazily); the entry.id URN is the item key.

local logger = require("logger")

local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Suwayomi = {}

-- Matched lowercased against the feed-level <author>.
Suwayomi.authorSignatures = { "suwayomi" }

-- Both needles required: each alone is a shape another server's URLs use.
Suwayomi.streamSignatures = { { "/manga/", "/chapter/" } }

-- Feed order is not reading order: recover position from the /chapter/ link.
-- Set only here: the other servers' feeds are already in reading order.
Suwayomi.orderFromTitles = true

local CHAPTER_URN = "^urn:suwayomi:chapter:(.+)$"
local MANGA_URN = "^urn:suwayomi:manga:(.+)$"

-- The two feeds spell one chapter id differently: the ":metadata" suffix.
-- Only this suffix, so an id with any other colon survives intact.
local METADATA_SUFFIX = ":metadata"

local function chapterKeyFromId(id)
    local key = type(id) == "string" and id:match(CHAPTER_URN)
    if not key then
        return nil
    end
    if key:sub(-#METADATA_SUFFIX) == METADATA_SUFFIX then
        key = key:sub(1, #key - #METADATA_SUFFIX)
    end
    return key ~= "" and key or nil
end
-- "/chapter" required: plain /series/{id}/ also matches a Kavita download path.
local SERIES_IN_PATH = "/series/(%d+)/chapter"
-- The manga id in the stream path is the only handle on a metadata-feed entry.
local MANGA_IN_STREAM = "/manga/(%d+)/chapter/"

local DEFAULT_LANG = "en"

local SERIES_SUFFIX = " Chapters"

-- ctx.lang (or "en") selects between translations of one manga.
local function lang(ctx)
    local value = ctx and ctx.lang
    if type(value) == "string" and value ~= "" then
        return value
    end
    return DEFAULT_LANG
end

-- Manga id from whatever the entry offers: URN, a link path, or its own stream.
-- The own-stream fallback is what kindFor (called with no cursor) depends on.
local function seriesIdFrom(entry, stream)
    local id = entry and entry.id
    if type(id) == "string" then
        local manga = id:match(MANGA_URN)
        if manga then
            return manga
        end
    end
    local links = entry and entry.link or {}
    for _, link in ipairs(links) do
        local href = type(link) == "table" and link.href
        if type(href) == "string" then
            local series = href:match(SERIES_IN_PATH)
            if series then
                return series
            end
        end
    end
    -- Bare href, never absolutized: url.absolute with no base is a footgun.
    local link = Base.link(entry, PSE.STREAM_REL)
    local own = link and link.href
    local series = type(own) == "string" and own:match(MANGA_IN_STREAM)
    if series then
        return series
    end
    if type(stream) == "string" then
        return stream:match(MANGA_IN_STREAM)
    end
    return nil
end

-- Never guesses: without a series id the caller must ask rather than sync.
function Suwayomi.discover(entry, stream, ctx)
    local remote_id = seriesIdFrom(entry, stream)
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        discovered_from = "stream",
        lang = lang(ctx),
    }
end

-- sort=number_asc is required: the default order is descending (newest first).
function Suwayomi.catalogURL(base_url, series_remote_id, ctx, filter)
    return string.format("%s/series/%s/chapters?lang=%s&sort=number_asc&filter=%s",
        base_url, series_remote_id, lang(ctx), filter or "all")
end

-- The server's own read flag; it disagrees with page progress both ways.
Suwayomi.unreadFilter = "unread"

-- Read the digits only, from the last | field; ?lang= does not touch them.
-- Suwayomi counts from zero, so add one back (Kavita counts from one).
-- Zero is exempt: an unread chapter reports 0, and +1 would mark it read.
-- The total is returned too, to tell a finished chapter from a started one.
local function progressFromSummary(summary)
    if type(summary) ~= "string" then
        return nil
    end
    -- The greedy class cannot cross a |, so this lands on the last field.
    local field = summary:match("|([^|]*)$") or summary
    local numbers = {}
    for value in field:gmatch("%d+") do
        numbers[#numbers + 1] = tonumber(value)
    end
    local read = numbers[#numbers - 1]
    local total = numbers[#numbers]
    if not read or not total then
        return nil, nil
    end

    -- Only zero is exempt: it is the one value that cannot be a page number.
    if read > 0 then
        read = read + 1
    end
    if read > total then
        return nil, nil
    end
    -- 0 is returned as 0, not nil: a recorded 0 is not "no progress".
    return read, total
end

-- Lazy: template and count are resolved on first open; covers fall back.
function Suwayomi.parseCatalogPage(feed, base_url, ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local item_key = chapterKeyFromId(entry.id)
        if item_key then
            local read, total = progressFromSummary(entry.summary)
            local detail = Base.link(entry, "subsection")
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "entry.id",
                title           = entry.title,
                detail_url      = detail and Base.absolute(base_url, detail.href) or nil,
                template        = nil,
                page_count      = nil,
                last_read       = read,
                -- Transient, never stored; pse:count is authoritative.
                progress_total  = total,
            })
        end
    end
    return items
end

-- Series title comes in two feed shapes: "<Manga> Chapters" or "<Manga> | …".
function Suwayomi.seriesName(feed, entry, _ctx)
    local title = feed and feed.title
    if type(title) == "string" then
        if #title > #SERIES_SUFFIX and title:sub(-#SERIES_SUFFIX) == SERIES_SUFFIX then
            local name = title:sub(1, #title - #SERIES_SUFFIX)
            if name ~= "" then
                return name
            end
        end
        local piped = title:match("^%s*(.-)%s*|")
        if piped and piped ~= "" then
            return Naming.stripSeriesLabel(piped)
        end
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return Naming.stripSeriesLabel(derived)
    end
    return nil
end

-- The only driver I/O; fetch keeps credentials and logging in the engine.
function Suwayomi.resolveStream(item, fetch, _ctx)
    -- A nil here is one of four, so log which; the call site sees only one.
    if not item.detail_url or not fetch then
        logger.warn("Meguru: cannot resolve a stream for", item.title,
            "(detail_url=" .. tostring(item.detail_url)
            .. ", fetch=" .. tostring(fetch ~= nil) .. ")")
        return nil
    end
    local feed = fetch(item.detail_url)
    if not feed then
        logger.warn("Meguru: no metadata feed for", item.title)
        return nil
    end
    local entry = feed.entry and feed.entry[1]
    if not entry then
        logger.warn("Meguru: metadata feed for", item.title, "has no entry")
        return nil
    end
    -- Stream href is path-only, made absolute against the metadata URL.
    local template, count = PSE.streamFromEntry(entry, item.detail_url)
    if not template then
        local links = {}
        for _, link in ipairs(entry.link or {}) do
            links[#links + 1] = tostring(link.rel)
        end
        logger.warn("Meguru: no PSE stream on the metadata entry for", item.title,
            "(rels: " .. table.concat(links, ", ") .. ")")
    end
    return template, count
end

Base.register("suwayomi", Suwayomi)

return Suwayomi
