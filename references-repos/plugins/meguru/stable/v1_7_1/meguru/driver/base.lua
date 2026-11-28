local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Base = {}

local registry = {}

local DRIVER_MODULES = {
    "meguru/driver/kavita",
    "meguru/driver/komga",
    "meguru/driver/suwayomi",
}

-- Not at load time: a driver may require this module, so a cycle is possible.
function Base.loadDrivers()
    for _, module in ipairs(DRIVER_MODULES) do
        require(module)
    end
end

function Base.register(kind, driver)
    driver.kind = kind
    -- Defaulted so a driver with no reason to override it cannot leave it nil.
    driver.resolveStream = driver.resolveStream or Base.resolveStream

    registry[kind] = driver
end

function Base.forKind(kind)
    return kind and registry[kind] or nil
end

function Base.kinds()
    local kinds = {}
    for kind in pairs(registry) do
        kinds[#kinds + 1] = kind
    end
    table.sort(kinds)
    return kinds
end

-- Not translated: a proper noun, so a translation names another product.
function Base.kindLabel(kind)
    return kind:sub(1, 1):upper() .. kind:sub(2)
end

-- One name/uri pair, or an array of them: newer parsers keep every <author>.
local function collectAuthor(value, parts)
    if type(value) == "string" then
        parts[#parts + 1] = value
    elseif type(value) == "table" then
        if type(value.name) == "string" then
            parts[#parts + 1] = value.name
        end
        if type(value.uri) == "string" then
            parts[#parts + 1] = value.uri
        end
        for _, nested in ipairs(value) do
            collectAuthor(nested, parts)
        end
    end
end

-- A feed names its software in <author>, the only clue to what lies behind it.
-- A newer OPDS parser keeps every author in an array, feed-level one included.
function Base.kindFromAuthor(author)
    if type(author) ~= "string" and type(author) ~= "table" then
        return nil
    end
    local parts = {}
    collectAuthor(author, parts)
    local blob = table.concat(parts, " "):lower()
    -- Sorted kinds: overlapping needles would otherwise resolve by pairs order.
    for _, kind in ipairs(Base.kinds()) do
        for _, needle in ipairs(registry[kind].authorSignatures or {}) do
            if blob:find(needle, 1, true) then
                return kind
            end
        end
    end
    return nil
end

-- Plain needles, not patterns: an unescaped character cannot throw a match.
function Base.kindFromTemplate(template)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    local claimed
    -- Sorted kinds: overlapping needles would otherwise resolve by pairs order.
    for _, kind in ipairs(Base.kinds()) do
        local signatures = registry[kind].streamSignatures or {}
        for _, needles in ipairs(signatures) do
            local all = #needles > 0
            for _, needle in ipairs(needles) do
                if not template:find(needle, 1, true) then
                    all = false
                    break
                end
            end
            if all then
                if claimed then
                    return nil
                end
                claimed = kind
                break
            end
        end
    end
    return claimed
end

-- Asks each driver's discover, not a second signature list that could drift.
-- discover must claim strictly; a false claim leaves another unattributable.
function Base.kindFor(entry, stream, ctx)
    local claimed
    for _, kind in ipairs(Base.kinds()) do
        local ok, found = pcall(registry[kind].discover, entry, stream, ctx)
        if ok and type(found) == "table" and found.series_remote_id then
            if claimed then
                return nil
            end
            claimed = kind
        end
    end
    return claimed
end

function Base.stripSuffix(text, suffix)
    if type(text) ~= "string" then
        return nil
    end
    if text:sub(-#suffix) == suffix then
        return text:sub(1, #text - #suffix)
    end
    return text
end

-- Argument order is the preference; Komga lists the small thumbnail first.
function Base.link(entry, ...)
    local links = entry and entry.link or {}
    for i = 1, select("#", ...) do
        local wanted = select(i, ...)
        for _, link in ipairs(links) do
            if type(link) == "table" and link.rel == wanted then
                return link
            end
        end
    end
    return nil
end

function Base.absolute(base_url, href)
    local url = require("socket.url")
    if type(href) ~= "string" or href == "" then
        return nil
    end
    return url.absolute(base_url, href)
end

local OPDS_IMAGE_REL = "http://opds-spec.org/image"
local OPDS_THUMBNAIL_REL = "http://opds-spec.org/image/thumbnail"

function Base.coverFromFeed(feed, entry, base_url, driver)
    if driver and driver.seriesCover then
        local url = driver.seriesCover(feed, entry, base_url)
        if type(url) == "string" and url ~= "" then
            return url
        end
    end
    local link = Base.link(feed, OPDS_IMAGE_REL, OPDS_THUMBNAIL_REL)
        or Base.link(entry, OPDS_IMAGE_REL, OPDS_THUMBNAIL_REL)
    if not link then
        return nil
    end
    return Base.absolute(base_url, link.href)
end

-- Always the entry's own image, not the feed's series cover every book shares.
-- The full image, not the thumbnail: Komga's is 211x300 against 844x1200.
function Base.coverFromEntry(entry, base_url)
    local link = Base.link(entry, OPDS_IMAGE_REL, OPDS_THUMBNAIL_REL)
    if not link then
        return nil
    end
    return Base.absolute(base_url, link.href)
end

-- Suwayomi's chapter entries link only a metadata feed, so this may be nil.
function Base.directStream(entry, base_url)
    return PSE.streamFromEntry(entry, base_url)
end

-- Display fields derived here so two drivers cannot disagree on a label.
function Base.item(fields)
    local title = fields.title or ""
    local display = Naming.cleanTitle(title)
    local _, label = Naming.deriveSeries(title)
    return {
        item_key        = fields.item_key,
        item_key_source = fields.item_key_source,
        title           = title,
        display_title   = display ~= "" and display or title,
        volume_label    = fields.volume_label or label,
        cover_url       = fields.cover_url,
        template        = fields.template,
        detail_url      = fields.detail_url,
        page_count      = fields.page_count,
        last_read       = fields.last_read,
        -- Never stored; Suwayomi scrapes it, and page_count must still win.
        progress_total  = fields.progress_total,
    }
end

-- The engine re-resolves on every open, since a stored template can go stale.
function Base.resolveStream(item, _fetch, _ctx)
    return item.template, item.page_count
end

return Base
