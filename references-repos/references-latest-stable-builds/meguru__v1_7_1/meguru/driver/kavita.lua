local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Kavita = {}

-- Matched against the lowercased feed-level <author>; Kavita signs its feeds.
Kavita.authorSignatures = { "kavita" }

-- chapterId is this driver's item_key, so a template bearing it is Kavita's.
Kavita.streamSignatures = { { "chapterId=" } }

local STORYLINE_SUFFIX = " - Storyline"

-- The "&" and "=" sentinels keep chapterId from matching inside subChapterId.
local function queryParam(url_str, name)
    local url = require("socket.url")
    local parsed = url.parse(url_str)
    local query = parsed and parsed.query
    if type(query) ~= "string" or query == "" then
        return nil
    end
    local value = ("&" .. query):match("&" .. name .. "=([^&]*)")
    if value == nil or value == "" then
        return nil
    end
    return value
end

-- Raw, not absolute: the query is the same, and no base URL may be given.
local function streamHref(entry)
    local link = Base.link(entry, PSE.STREAM_REL)
    return link and link.href
end

-- seriesId rides the stream URL, so no browsing context is needed to resolve.
function Kavita.discover(entry, stream, _ctx)
    local href = stream or streamHref(entry)
    if type(href) ~= "string" or href == "" then
        return nil
    end
    local remote_id = queryParam(href, "seriesId")
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        discovered_from = "stream",
    }
end

function Kavita.catalogURL(base_url, series_remote_id, _ctx)
    return string.format("%s/series/%s", base_url, series_remote_id)
end

-- A stream-less entry is skipped: keying it orders an unopenable chapter.
function Kavita.parseCatalogPage(feed, base_url, _ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local template, count, last_read = PSE.streamFromEntry(entry, base_url)
        local item_key = template and queryParam(template, "chapterId")
        if item_key then
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "chapterId",
                title           = entry.title,
                template        = template,
                page_count      = count,
                last_read       = last_read,
                -- Each entry carries its own cover; omitting it means page 1.
                cover_url       = Base.coverFromEntry(entry, base_url),
            })
        end
    end
    return items
end

-- An aggregate has no series feed, so the entry title is the fallback there.
function Kavita.seriesName(feed, entry, _ctx)
    local from_feed = Naming.stripSeriesLabel(
        Base.stripSuffix(feed and feed.title, STORYLINE_SUFFIX))
    if from_feed and from_feed ~= "" then
        return from_feed
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return derived
    end
    return nil
end

-- Left to base.lua's default: the stream arrives with the entry, no fetch.

Base.register("kavita", Kavita)

return Kavita
