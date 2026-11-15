local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Komga = {}

-- Matched lowercased against the feed-level <author>; Komga signs every feed.
Komga.authorSignatures = { "komga" }

-- All three needles, because every Kavita template also contains "/opds/".
Komga.streamSignatures = { { "/opds/", "/books/", "/pages/{pageNumber}" } }

-- Anchored on the literal segment; cut at / or ? so ?page=2 still matches.
local SERIES_IN_PATH = "/series/([^/?]+)"

local BOOK_IN_TEMPLATE = "/books/([^/]+)/pages/"

-- Captures what precedes /opds/: a reverse proxy's prefix, kept not rebuilt.
local REST_IN_TEMPLATE = "^(.*)/opds/v1%.2/books/([^/]+)/pages/"

-- Series id comes from ctx.url, the feed URL: Komga puts none on a book entry.
-- No ctx.url refuses: guessing from a title would sync the wrong series.
-- An aggregate names no series here either; resolveSeries asks the server once.
function Komga.discover(entry, _stream, ctx)
    local feed_url = type(ctx) == "table" and ctx.url
    if type(feed_url) ~= "string" or feed_url == "" then
        return nil
    end
    local remote_id = feed_url:match(SERIES_IN_PATH)
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        discovered_from = "series",
    }
end

-- /catalog is stripped: callers pass either the catalogue URL or the root.
function Komga.catalogURL(base_url, series_remote_id, _ctx)
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    local base = base_url:gsub("/+$", ""):gsub("/catalog$", "")
    return string.format("%s/series/%s", base, series_remote_id)
end

-- last_read is absent until a book has progress; a fresh library looks empty.
-- Key is cut from the template, not entry.id, so key and stream cannot drift.
-- Cover is the entry's own: Komga emits a thumbnail on every book.
function Komga.parseCatalogPage(feed, base_url, _ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local template, count, last_read = PSE.streamFromEntry(entry, base_url)
        local item_key = template and template:match(BOOK_IN_TEMPLATE)
        if item_key then
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "bookId",
                title           = entry.title,
                template        = template,
                page_count      = count,
                last_read       = last_read,
                cover_url       = Base.coverFromEntry(entry, base_url),
            })
        end
    end
    return items
end

-- Komga publishes no series image in OPDS, so take the REST thumbnail.
-- Prefix before /opds/ is kept, not rebuilt; a proxied Komga would 404.
function Komga.seriesCover(_feed, _entry, base_url)
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    local prefix, remote_id = base_url:match("^(.*)/opds/v1%.2/series/([^/?]+)")
    if not prefix or not remote_id then
        return nil
    end
    return string.format("%s/api/v1/series/%s/thumbnail", prefix, remote_id)
end

-- REST, not OPDS: /api/v1/books/{id}/read-progress is what fills readProgress.
-- Page is one-based here; the stream URL is zero-based; neither is converted.
function Komga.progressRequest(desc, page)
    if type(desc) ~= "table" then
        return nil
    end
    local template = desc.template
    local total = tonumber(desc.count)
    local wanted = math.floor(tonumber(page) or 0)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    if wanted < 1 or not total or total < 1 then
        return nil
    end
    -- Clamp down: the last page is accepted, a page past it is 400.
    if wanted > total then
        wanted = total
    end
    local prefix, book_id = template:match(REST_IN_TEMPLATE)
    if not prefix or not book_id then
        return nil
    end
    return {
        url          = string.format("%s/api/v1/books/%s/read-progress", prefix, book_id),
        content_type = "application/json",
        body         = string.format('{"page":%d}', wanted),
    }
end

-- Trust feed <title> only for a series feed; an aggregate says "Latest books".
function Komga.seriesName(feed, entry, ctx)
    local feed_url = type(ctx) == "table" and ctx.url
    if type(feed_url) == "string" and feed_url:match(SERIES_IN_PATH) then
        local from_feed = feed and feed.title
        if type(from_feed) == "string" and from_feed ~= "" then
            -- No " - Storyline" suffix; only a leading "<word>:" is stripped.
            return Naming.stripSeriesLabel(from_feed)
        end
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return derived
    end
    return nil
end

-- One request per open: discover runs per entry and per driver, not per book.
-- Id comes from the stream template; the prefix is kept, not rebuilt.
-- Answers the server's own series title and book name so both routes agree.
function Komga.resolveSeries(entry, stream, ctx, fetch_json)
    local template = type(stream) == "string" and stream or nil
    if not template or type(fetch_json) ~= "function" then
        return nil
    end
    local prefix, book_id = template:match(REST_IN_TEMPLATE)
    if not prefix or not book_id then
        return nil
    end
    local book = fetch_json(string.format("%s/api/v1/books/%s", prefix, book_id))
    local series_id = type(book) == "table" and book.seriesId or nil
    if type(series_id) ~= "string" or series_id == "" then
        return nil
    end
    local name = type(book.seriesTitle) == "string" and book.seriesTitle or ""
    if name == "" then
        name = nil
    else
        name = Naming.stripSeriesLabel(name)
    end
    local title = type(book.name) == "string" and book.name or ""
    if title == "" then
        title = nil
    end
    return {
        series_remote_id = series_id,
        series_name      = name,
        title            = title,
        discovered_from  = "aggregate",
    }
end

-- resolveStream default: the stream arrives with the entry, nothing to fetch.
-- orderFromTitles unset: Komga sorts by metadata.numberSort; feed order wins.
-- unreadFilter unset: no unread feed; its flag is a per-book pse:lastRead.
Base.register("komga", Komga)

return Komga
