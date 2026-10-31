
-- The row bookshelf shows for a catalog record: the same book, the same marker
-- and the same open as the browser's own dialog row, through the registry
-- bookshelf offers other plugins instead of a wrap on its window.

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("meguru/driver/base")
local Feed = require("meguru/feed")
local Net = require("meguru/net")
local Open = require("meguru/ui/open")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Bookshelf = {}

-- One row per feature: registering the same id again replaces it.
local ROW_ID = "meguru"

local registered = false
local retried = false

-- Kept from install: the window this row appears in lives on the file manager,
-- and its ui is what opens the marker.
local open_host = nil

-- Asked for every remote record bookshelf shows, so it does no I/O at all.
-- Everything that reaches the network happens on the tap.
local function provider(book, ctx)
    -- Bookshelf keeps the stream out of acquisitions, so findStream would find
    -- nothing here: opds.stream is the only place the template survives.
    local stream = type(book) == "table" and type(book.opds) == "table"
        and book.opds.stream or nil
    if type(stream) ~= "table" or type(stream.href) ~= "string"
        or not tonumber(stream.count) then
        return nil
    end
    -- The rule PSE.streamFromEntry applies and bookshelf does not: without
    -- {pageNumber} every page of the book would be one and the same URL.
    if not stream.href:find("{pageNumber}", 1, true) then
        return nil
    end
    -- A stream bearing a driver's signature names a server this can read, and
    -- names the driver the tap will use: one answer decides both, so a row
    -- cannot be offered on one server's stream and opened with another's.
    local kind = Base.kindFromTemplate(stream.href)
    if not kind then
        return nil
    end
    -- The catalog's own title: what the marker, and the credentials, key on.
    local server = type(ctx) == "table" and ctx.server or nil
    if type(server) ~= "table" or not Sources.find(server.title) then
        return nil
    end

    return {
        {
            text = "\u{25B6} " .. _("Meguru this series"),
            callback = function()
                Bookshelf.open(book, ctx, stream, kind)
            end,
        },
    }
end

-- The entry as the feed's own chain lists it. The entry carries the identity:
-- Suwayomi keys it on entry.id, and the feed's own title is the series name
-- where the entry's is bare. Bookshelf paginates a long series, so the page it
-- drew the record from is not always the first.
local function walkForEntry(feed_url, stream, conn)
    local walker = Feed.walker(feed_url, {
        username = conn.username,
        password = conn.password,
        timeout = "resume",
        max_pages = Feed.TAP_PAGES,
    })
    while true do
        local more = walker:step()
        local page = walker.pages[#walker.pages]
        if page then
            local entry = Open.entryFor(page.feed, page.url, stream)
            if entry then
                -- That page is the feed the marker is planned from, as the
                -- page the browser navigated to would have been.
                return entry, { url = page.url, feed = page.feed }
            end
        end
        if not more then
            return nil, nil, walker.reason
        end
    end
end

local function cannotOpen(title)
    return T(_("could not open “%1” in Meguru."), tostring(title))
end

-- The tap, with a connection: identify the book in its own feed, then hand it
-- to the one path both windows end at.
local function openConnected(book, stream, server_name, kind)
    -- Re-resolved at the tap: the catalog can be gone since the shelf was drawn.
    local conn = Sources.connection(server_name)
    if not conn then
        UIManager:show(InfoMessage:new{
            text = T(_("no catalog entry with this title in settings/opds.lua: %1"),
                tostring(server_name)),
        })
        return
    end

    local feed_url = book.opds and book.opds.feed_url
    if type(feed_url) ~= "string" or feed_url == "" then
        logger.warn("Meguru: this bookshelf record names no feed to identify it in")
        UIManager:show(InfoMessage:new{ text = cannotOpen(book.title) })
        return
    end

    local entry, retained, reason = walkForEntry(feed_url, stream, conn)
    if not retained then
        -- Refused rather than written flat: with the feed in hand, "no series"
        -- is the driver's answer about the book, and without it, our guess.
        logger.warn("Meguru: could not identify", tostring(book.title), "in the feed",
            Net.redactUrl(feed_url), "-", tostring(reason or "no entry for this stream"))
        UIManager:show(InfoMessage:new{ text = cannotOpen(book.title) })
        return
    end

    Open.openInFeed(open_host, server_name, kind, entry, stream, retained, {
        title = book.title,
        credentials = { username = conn.username, password = conn.password },
    })
end

-- The tap: the window goes first, then the work waits for a connection.
-- kind is the provider's, so the driver that opens the book is the one whose
-- signature offered the row.
function Bookshelf.open(book, ctx, stream, kind)
    -- Closed before the resume dialog, which opens over where this one was.
    if type(ctx.close) == "function" then
        ctx.close()
    end
    local server_name = type(ctx.server) == "table" and ctx.server.title or nil
    NetworkMgr:runWhenConnected(function()
        openConnected(book, stream, server_name, kind)
    end)
end

-- Without the stock plugin's parser no feed can be read at all, so a row here
-- could only ever offer a failure. The browser wraps go the same way.
local function hasParser()
    local ok = pcall(require, "opdsparser")
    if not ok then
        logger.info("Meguru: no OPDS feed parser, so no bookshelf record button")
    end
    return ok
end

-- host is the file-manager plugin instance: both the window this row appears
-- in and the ui that opens the marker are the file manager's.
function Bookshelf.install(host)
    if registered then
        return true
    end
    local ui = host and host.ui
    -- A reader-side instance has a document, and would swap documents instead
    -- of opening the book out of the shelf that asked for it.
    if not (ui and not ui.document) then
        return false
    end

    local bs = ui.bookshelf
    -- The API number, never the version: the hook and the release land apart.
    if type(bs) == "table" and (tonumber(bs.RECORD_ACTIONS_API) or 0) >= 1
        and type(bs.registerRecordActions) == "function" then
        if not hasParser() then
            return false
        end
        local ok, err = pcall(function()
            return bs:registerRecordActions(ROW_ID, provider)
        end)
        if not ok then
            logger.warn("Meguru: bookshelf refused the record action:", err)
            return false
        end
        registered = true
        open_host = host
        logger.dbg("Meguru: registered the bookshelf record action for OPDS books")
        return true
    end

    -- Plugins are sorted by path, so one living under a root that sorts after
    -- ours has no instance yet; after the plugin loop it does. Once is all
    -- this may ask: the list is set to nil the moment it has been drained.
    if not retried and type(ui.registerPostInitCallback) == "function" then
        retried = true
        ui:registerPostInitCallback(function()
            Bookshelf.install(host)
        end)
        return false
    end
    logger.info("Meguru: no bookshelf plugin to add the OPDS record button to")
    return false
end

return Bookshelf
