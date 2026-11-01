-- The "Meguru this series" flow: a browsed entry becomes a marker and a book.
-- The series context comes from its own feed, not the page on screen.
-- A marker is written only for a book being opened, and planning is split.
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Association = require("meguru/association")
local Base = require("meguru/driver/base")
local Feed = require("meguru/feed")
local FS = require("meguru/fs")
local Marker = require("meguru/marker")
local Naming = require("meguru/naming")
local Net = require("meguru/net")
local PSE = require("meguru/pse")
local RowCover = require("meguru/rowcover")
local SeriesCover = require("meguru/seriescover")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")
local Catalog = require("meguru/ui/catalog")

Base.loadDrivers()

local Open = {}

-- The last feed each catalog displayed, keyed by catalog title: { url, feed }.
-- OPDSBrowser discards the entry <id> and <link> a driver needs; keep them.
-- One per catalog, replaced as the user navigates, so it cannot grow.
local last_feed = {}

-- Kinds sniffed from the feed-level <author>, keyed by catalog title.
-- Never persisted; the marker's server_kind is the durable record.
local sniffed = {}

-- A FileManager plugin instance used when the browser's own open path fails.
local fallback_host = nil

function Open.setFallbackHost(widget)
    if widget and widget.ui and not widget.ui.document then
        fallback_host = widget
    end
end

-- The marker path last handed to a reader, or nil.
-- One-shot keyed on the path: stops the showReader wrap re-asking the dialog.
local handed_off = nil

-- Arm the one-shot for `file`, immediately before handing it to a reader.
function Open.noteHandoff(file)
    handed_off = file
end

-- Read the one-shot and clear it. Returns the path armed, or nil.
-- Read-and-clear bounds the leak: one record suppresses at most one open.
function Open.takeHandoff()
    local file = handed_off
    handed_off = nil
    return file
end

local function catalogTitle(browser)
    local name = browser and browser.root_catalog_title
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

-- Keep the raw Atom of the feed the browser just parsed, for showDownloads.
-- Called from the parseFeed wrap, which runs on every navigation.
-- The OpenSearch descriptor is parsed through here after the real feed.
-- Skip it rather than clearing: an unmatched entry is worse than no match.
function Open.noteFeed(browser, feed_url, catalog)
    local name = catalogTitle(browser)
    -- The parser wraps the document: entries are on `.feed.entry`.
    local feed = Net.feedFrom(catalog)
    -- Through Net.redactUrl: Kavita's key is a path segment of every feed URL.
    -- Guarded: a throw here would be swallowed by the caller's pcall.
    local shown_url = feed_url
    if type(feed_url) == "string" then
        shown_url = Net.redactUrl(feed_url)
    end
    logger.dbg("Meguru: feed parsed", shown_url,
        "(catalog=" .. tostring(name)
        .. ", entries=" .. tostring(feed and #(feed.entry or {}) or "not a table") .. ")")
    if not name then
        return
    end
    if type(feed) ~= "table" then
        last_feed[name] = nil
    elseif type(feed.OpenSearchDescription) == "table" then
        -- A search descriptor, not a feed; leave the retained record.
        return
    elseif type(feed.entry) == "table" then
        last_feed[name] = { url = feed_url, feed = feed }
    else
        last_feed[name] = nil
    end
end

-- Record the server kind from the name the feed signs itself with.
-- Best-effort: an unrecognised author leaves the kind unknown.
-- <author> is a child of <feed>, so read the unwrapped feed like the entries.
-- Re-asked of every feed: a catalog repointed at another server changes answer.
function Open.noteCatalogAuthor(browser, catalog)
    local name = catalogTitle(browser)
    if not name then
        return
    end
    local feed = Net.feedFrom(catalog)
    local kind = Base.kindFromAuthor(feed and feed.author)
    if kind and kind ~= sniffed[name] then
        sniffed[name] = kind
        -- Logged on change: this line is how a repointed catalog shows up.
        logger.dbg("Meguru: catalog", name, "looks like", kind)
    end
end

-- The driver kind sniffed this session; the marker carries it once opened.
function Open.serverKindFor(browser)
    local name = catalogTitle(browser)
    if not name then
        return nil
    end
    return sniffed[name], sniffed[name] and "author" or nil
end

-- The language a URL was fetched with: Suwayomi picks the translation by it.
-- Several URLs, because a record's stream and its own feed name the same one.
local function langFrom(urls)
    for _, url in ipairs(urls or {}) do
        if type(url) == "string" then
            local lang = url:match("[?&]lang=([%w%-]+)")
            if lang then
                return lang
            end
        end
    end
    return nil
end

-- The language being browsed: Suwayomi selects translations by ?lang=.
-- It publishes no default, so read it off the URLs actually navigated.
local function langFromBrowser(browser)
    local paths = browser and browser.paths
    if type(paths) ~= "table" then
        return nil
    end
    -- Reversed: the URL navigated last is the one being browsed.
    local urls = {}
    for i = #paths, 1, -1 do
        local entry = paths[i]
        urls[#urls + 1] = type(entry) == "table" and entry.url or entry
    end
    return langFrom(urls)
end

-- The entry behind a resolved stream, matched by the template it resolves to.
-- A feed with one entry needs no matching at all.
function Open.entryFor(feed, feed_url, stream)
    if type(feed) ~= "table" or type(feed.entry) ~= "table" then
        return nil
    end
    local wanted = stream and stream.href
    for _, entry in ipairs(feed.entry) do
        local template = PSE.streamFromEntry(entry, feed_url or "")
        if template and template == wanted then
            return entry
        end
    end
    if #feed.entry == 1 then
        return feed.entry[1]
    end
    return nil
end

-- The raw Atom entry behind a browsed item, from the feed this catalog showed.
local function rawEntryFor(browser, stream)
    local name = catalogTitle(browser)
    local record = name and last_feed[name]
    return Open.entryFor(record and record.feed, record and record.url, stream)
end

-- The item a sync builds for this stream, via the same parseCatalogPage.
local function driverItemFor(driver, feed, feed_url, stream, ctx)
    local items = driver.parseCatalogPage(feed, feed_url, ctx)
    if type(items) ~= "table" then
        return nil
    end
    -- No position stored: reading order belongs to Feed.ordered, per walk.
    local wanted = stream and stream.href
    for _, item in ipairs(items) do
        if wanted and item.template == wanted then
            return item
        end
    end
    return #items == 1 and items[1] or nil
end

-- Log why registration bailed, then return nil.
-- Every bail is a supported outcome, so silence hid the several causes.
local function why(reason, detail)
    logger.info("Meguru: not catalogued:", reason,
        detail ~= nil and ("(" .. tostring(detail) .. ")") or "")
    return nil
end

-- Feed.ordered and its selectors, aliased so call sites here read as before.
local readingOrder = Feed.ordered
local firstUnfinished = Feed.firstUnfinished
local lastIn = Feed.lastIn
local firstUnfinishedOrLast = Feed.firstUnfinishedOrLast
local firstIn = Feed.firstIn

-- The items a feed page describes; a repeated item_key collapses.
-- Dedupe keeps the entry the feed places for the book (see Feed.dedupe).
-- The one place entries become items; driverItemFor does not come through it.
local function itemsFrom(driver, feed, feed_url, ctx)
    local items, _, replaced = Feed.dedupe(
        driver.parseCatalogPage(feed, feed_url, ctx))
    for _, lost in ipairs(replaced) do
        logger.info("Meguru: dropped duplicate feed entry",
            lost.display_title or lost.title,
            "- the feed's own entry for that book is the one kept")
    end
    return items
end

-- The chapter the server's own position points at, in reading order.
-- Read from the feed the browser just fetched.
-- Entries not claiming this series are dropped, never filed under it.
-- select picks the entry (firstIn for a feed the server filtered to unread).
-- Returns a catalog row; nothing is written and no order is stored.
local function freshResumeTarget(driver, feed, feed_url, ctx, context, select)
    select = select or firstUnfinishedOrLast
    -- ctx.url names the series on Komga; fill it from the feed URL if need be.
    ctx = { lang = ctx and ctx.lang, url = ctx and ctx.url or feed_url }
    local mine = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local found = driver.discover(entry, nil, ctx)
        if found and found.series_remote_id == context.series_remote_id then
            mine[#mine + 1] = entry
        end
    end
    if #mine == 0 then
        logger.info("Meguru: no entry in this feed belongs to series",
            context.series_remote_id, "- the dialog offers no server position")
        return nil
    end

    -- Through itemsFrom, not the driver: the feed can carry one book twice.
    -- This picks one entry out of the sequence.
    local parsed = itemsFrom(driver, { entry = mine }, feed_url, ctx)
    -- Driver flag: whether its titles carry a usable position (Suwayomi only).
    local sequence, positioned = readingOrder(parsed,
        { title_order = driver and driver.orderFromTitles })
    local best = select(sequence, positioned)
    if not best then
        -- No entry of this series (or none the driver could build).
        -- The caller may then ask the canonical feed.
        logger.info("Meguru: no entry of series", context.series_remote_id,
            "in this feed - no resume point from it")
        return nil
    end

    logger.info("Meguru: the feed says", best.display_title or best.title,
        "is the resume point in series", context.series_remote_id)

    return best
end

-- The { name, kind } pair Feed.resolveStream and Feed.resolveSeries take.
-- Built once so both callers cannot spell it twice.
local function serverShim(name, kind)
    return { name = name, kind = kind }
end

-- Work out the series an opened book belongs to and return it with the item.
-- Nil when neither can be built; a book with no series still opens and reads.
-- retained is the feed the entry came from, in last_feed's own shape.
local function registerBook(server_name, kind, raw_entry, stream, lang, retained)
    local conn = Sources.connection(server_name)
    if not conn then
        return why("no catalog entry with this title",
            "in settings/opds.lua: " .. tostring(server_name))
    end

    local driver = kind and Base.forKind(kind)
    if not driver then
        -- The kind can come only from the sniff, the inference or the marker.
        -- Naming the server is the most the message can do.
        return why("no driver for this server's kind", "kind=" .. tostring(kind))
    end

    -- ctx.url is the only place a Komga entry's series id exists.
    -- Built fresh so no other reader of the caller's context is surprised.
    local feed, feed_url = retained and retained.feed, retained and retained.url
    local ctx = { lang = lang, url = feed_url }

    -- Before discover: a book with no retained feed then spends no request.
    if type(feed) ~= "table" then
        return why("no feed retained for this catalog",
            "nothing was parsed since the hook was installed")
    end

    local found = driver.discover(raw_entry, stream.href, ctx)

    -- An aggregate (books/latest, ondeck) names no series: ask the server.
    -- For this one book; a driver without the hook answers nil.
    local resolved_remotely
    if not found or not found.series_remote_id then
        found = Feed.resolveSeries(raw_entry, stream.href,
            serverShim(server_name, kind), ctx)
        resolved_remotely = found ~= nil
    end
    if not found or not found.series_remote_id then
        return why("driver could not identify the series",
            tostring(raw_entry and raw_entry.title))
    end

    -- A server-supplied series name outranks the derivation.
    -- DirFor keys the folder on that name, so two names are two folders.
    local series_name = found.series_name
    if type(series_name) ~= "string" or series_name == "" then
        series_name = driver.seriesName(feed, raw_entry, ctx)
    end
    if type(series_name) ~= "string" or series_name == "" then
        return why("driver could not name the series",
            tostring(raw_entry and raw_entry.title))
    end

    local item = driverItemFor(driver, feed, feed_url, stream, ctx)
    if not item then
        return why("driver could not build the item from the retained feed",
            tostring(#(feed.entry or {})) .. " entry(ies) in it")
    end

    -- An aggregate URL names no series: build the canonical feed for the cover.
    -- A mistake here only falls through; it cannot regress.
    local cover_base = feed_url or stream.href
    if resolved_remotely then
        cover_base = driver.catalogURL(conn.url, found.series_remote_id, ctx)
            or cover_base
    end

    -- The context a marker would give, so downstream takes one shape.
    local series = {
        server_name      = server_name,
        server_kind      = kind,
        series_remote_id = found.series_remote_id,
        series_name      = series_name,
        -- Driver supplied so Komga, whose feed carries no artwork, can answer.
        series_cover_url = Base.coverFromFeed(feed, raw_entry, cover_base, driver),
        item_key         = item.item_key,
        lang             = ctx and ctx.lang,
    }

    -- The browsed feed cannot answer when the server flags chapters read.
    -- Nor when the series was resolved remotely.
    local server_target = (driver.unreadFilter or resolved_remotely) and true or nil

    -- Asked only when the browsed feed can answer where the reader is.
    local resume
    if not server_target then
        resume = freshResumeTarget(driver, feed, feed_url, ctx, series)
    end

    local registered = {
        context = series,
        item    = item,
        resume        = resume,
        server_target = server_target,
        -- The book's own title, when the server was asked; not a context field.
        title         = found.title,
    }
    -- Logged because every failure path speaks.
    -- Every field through tostring, so a status line cannot break the report.
    logger.info("Meguru: identified", item.display_title or item.title,
        "(series " .. tostring(series.series_remote_id)
        .. ", kind " .. tostring(kind)
        .. ", key " .. tostring(item.item_key) .. ")")
    return registered
end

-- Hand `file` to `opener` with the one-shot armed, disarmed again if it throws.
-- `arm` false only for openLocalFile: a non-marker never reaches the wrap.
local function handOff(file, opener, arm)
    if arm ~= false then
        Open.noteHandoff(file)
    end
    local ok, err = pcall(opener)
    if not ok then
        Open.takeHandoff()
        logger.warn("Meguru: the reader refused to open", file, ":", err)
        return false
    end
    return true
end

-- Open a marker in whichever host we have: a reader swaps documents.
-- The file browser opens a file via openFile.
-- Must sit above callers, or the local name resolves to a global.
local function handToReader(host, file)
    if not (host and host.ui) then
        return false
    end
    -- Already asked by offerResume, so tell the wrap not to repeat it.
    if host.ui.document then
        return handOff(file, function() host.ui:switchDocument(file) end)
    end
    return handOff(file, function() host.ui:openFile(file) end)
end

-- Hand a prepared marker over, reporting the one failure that matters.
-- Used by both catalog open paths so message and arming cannot drift.
local function openPrepared(host, file)
    -- Before the handoff: nothing left to be revealed by the reader's exit.
    Catalog.closeBrowser(host)
    if handToReader(host, file) then
        return file
    end
    logger.err("Meguru: no opener available for", file)
    UIManager:show(InfoMessage:new{
        text = T(_("could not open the book.\nMarker written to:\n%1"), file),
    })
    return nil
end

-- Open a local archive already on disk as one of our books.
-- The other half of "open next in series": nothing written, no feed asked.
-- Forces the Meguru provider so a sibling .cbz opens in this engine.
-- Not whatever .cbz is associated with; the association is left as set.
-- FS.exists first: switchDocument closes the reader before it opens anything.
function Open.openLocalFile(host, path)
    if type(path) ~= "string" or not FS.exists(path) then
        logger.warn("Meguru: the local book is gone", tostring(path))
        return nil
    end
    if not (host and host.ui) then
        logger.err("Meguru: no opener available for", path)
        return nil
    end
    if not host.ui.document then
        -- A file-manager host takes no provider; both callers are reader-side.
        return handOff(path, function() host.ui:openFile(path) end, false)
            and path or nil
    end
    local provider = Association.provider()
    if not provider then
        logger.warn("Meguru: the provider is not registered, so", path,
            "cannot be opened as a Meguru book")
        return nil
    end
    local ok = handOff(path, function()
        host.ui:switchDocument(path, nil, nil, provider, true)
    end, false)
    return ok and path or nil
end

-- True when this book has never been opened here.
-- Must be asked before DocSettings:open, which creates that sidecar.
local function neverOpened(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or type(DocSettings.hasSidecarFile) ~= "function" then
        return false
    end
    local ok_has, has = pcall(DocSettings.hasSidecarFile, DocSettings, file)
    return ok_has and not has
end

-- Write last_page to the sidecar before the reader opens it.
-- The only value reaching the first paint; showReader takes no page.
function Open.seedLastPage(file, page)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then
        return false
    end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok_open or not ds then
        logger.warn("Meguru: could not open the sidecar to seed a page")
        return false
    end
    ds.data.last_page = math.floor(page)
    local ok_flush, err = pcall(function() ds:flush() end)
    if not ok_flush then
        logger.warn("Meguru: could not seed the reader page:", err)
        return false
    end
    logger.info("Meguru: starting", file, "at page", page)
    return true
end

-- The short form ("Volume 2"): the full title overflows a button with a page.
function Open.bookLabel(subject)
    if type(subject) ~= "table" then
        return _("this book")
    end
    if subject.volume_label then
        return subject.volume_label
    end
    -- select(2, ...): a local `_` would shadow this file's gettext.
    local token = select(2, Naming.deriveSeries(subject.title or ""))
    return token or subject.display_title or subject.title or _("this book")
end

-- A recorded page past page 1 and within the count; page 1 is not a position.
local function usablePage(page, count)
    page = tonumber(page)
    if page and page > 1 and count and page <= count then
        return page
    end
    return nil
end

-- The series, because the question is where in the series to carry on.
local function dialogTitle(context, item)
    local name = context and context.series_name
    if type(name) == "string" and name:find("%S") then
        return T(_("Meguru: %1"), name)
    end
    return T(_("Meguru: %1"), Open.bookLabel(item))
end

-- Four whole templates, not a suffix, so a translator can reorder the parts.
local function buttonLabel(verb, subject, page, from_server)
    local name = Open.bookLabel(subject)
    if from_server and page then
        return "\u{25B6} " .. T(_("%1 — %2, page %3 (Server)"), verb, name, page)
    elseif from_server then
        return "\u{25B6} " .. T(_("%1 — %2 (Server)"), verb, name)
    elseif page then
        return T(_("%1 — %2, page %3"), verb, name, page)
    end
    return T(_("%1 — %2"), verb, name)
end

-- Where a book's marker sits: the same dirFor then pathFor planMarker uses.
-- So "already on disk" cannot disagree with the write.
local function markerPathFor(context, item)
    if not (context and context.server_name and item and item.item_key) then
        return nil
    end
    local dir = Marker.dirFor(context, {
        base_dir      = Marker.baseDir(),
        server_folder = Settings.get("marker_server_dir") and true or false,
    })
    return Marker.pathFor(dir, {
        server_name      = context.server_name,
        series_remote_id = context.series_remote_id,
        item_key         = item.item_key,
        title            = item.title,
    })
end

-- Nil when the target has a sidecar: it resumes where KOReader left it.
-- Kept in step with MeguruDocument:init's silent seed.
local function jumpPage(target, series)
    -- Recomputed from identity: a marker's path is a pure function of it.
    local marker = series and markerPathFor(series, target) or nil
    if type(marker) == "string" and marker ~= "" and FS.exists(marker)
        and not neverOpened(marker) then
        return nil
    end
    local count = tonumber(target.page_count)
    return usablePage(target.last_read, count)
end

-- The page in a book's sidecar, or nil.
-- Only for a book that has one: DocSettings:open creates that file.
local function localLastPage(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then
        return nil
    end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok_open or not ds then
        return nil
    end
    local ok_read, page = pcall(function()
        return tonumber(ds:readSetting("last_page"))
    end)
    if not ok_read or not page or page < 1 then
        return nil
    end
    return page
end

-- The one series this feed describes, or nil; freshResumeTarget's test.
local function feedSeries(browser)
    local name = catalogTitle(browser)
    local kind, kind_source = Open.serverKindFor(browser)
    local driver = kind and Base.forKind(kind)
    if not name or not driver then
        return nil
    end
    local record = last_feed[name]
    local feed = record and record.feed
    if type(feed) ~= "table" or type(feed.entry) ~= "table" or #feed.entry == 0 then
        return nil
    end

    -- url carried as registerBook carries it, for the Komga series id.
    local ctx = { lang = langFromBrowser(browser), url = record and record.url }
    local remote_id
    for _, entry in ipairs(feed.entry) do
        local found = driver.discover(entry, nil, ctx)
        if not found or not found.series_remote_id then
            return nil
        end
        if remote_id and found.series_remote_id ~= remote_id then
            return nil -- more than one series here; "this series" names nothing
        end
        remote_id = found.series_remote_id
    end
    if not remote_id then
        return nil
    end

    return {
        server_name  = name,
        kind         = kind,
        kind_source  = kind_source,
        driver       = driver,
        remote_id    = remote_id,
        ctx          = ctx,
        feed         = feed,
        feed_url     = record.url,
        first_entry  = feed.entry[1],
    }
end

-- The row at the top of a series feed, or nil.
-- item_url keeps it off other lists the browser draws through the same path.
function Open.seriesRow(browser, item_url)
    local info = feedSeries(browser)
    if not info or item_url ~= info.feed_url then
        return nil
    end
    return {
        text      = "\u{25B6} " .. _("Meguru this series"),
        mandatory = tostring(#info.feed.entry),
        -- The row's own mark, not the series' artwork: this row is not a book.
        cover_bb  = RowCover.bitmap(),
        -- Keys the onMenuSelect wrap; without it the row reads as a link.
        meguru    = info,
    }
end

-- The first item in reading order the server says is unread.
-- Nil when none is, which is not "offer the last one".
local function firstUnread(parsed, filtered, driver)
    local sequence = readingOrder(parsed,
        { title_order = driver and driver.orderFromTitles })
    if filtered then
        -- Server already filtered by read status: earliest entry, no counter.
        return firstIn(sequence)
    end
    return firstUnfinished(sequence)
end

-- Bounded because the walk is synchronous on a tap; six pages is 600 chapters.
local FIRST_UNREAD_PAGES = 6

-- The series in reading order, from the canonical feed, to the page cap.
-- The page on screen is one page of one order; fall back to it if needed.
local function seriesItems(info, conn)
    local driver, remote_id, ctx = info.driver, info.remote_id, info.ctx
    local feed, feed_url = info.feed, info.feed_url

    -- Returns items, basis: "flag"/"empty"/"counters" says what it rests on.
    local function fallback(reason)
        logger.info("Meguru: series walk unusable (", reason,
            ") - the row falls back to the page on screen")
        return itemsFrom(driver, feed, feed_url, ctx), "counters"
    end

    if not conn then
        return fallback("no saved catalog for this server")
    end
    if not NetworkMgr:isConnected() then
        return fallback("no connection")
    end

    local function walk(which, walk_ctx)
        local url = driver.catalogURL(conn.url, remote_id, walk_ctx, which)
        local pages, complete, reason = Feed.walk(url, {
            username  = conn.username,
            password  = conn.password,
            timeout   = "resume",
            max_pages = FIRST_UNREAD_PAGES,
        })
        return pages, complete, reason
    end

    -- What the answer may rest on: "flag" (server filtered), "empty"
    -- (filtered and listed nothing), or "counters" (no flag).
    local basis = driver.unreadFilter and "flag" or "counters"
    local pages, complete, reason = walk(driver.unreadFilter, ctx)

    -- The filtered feed can fail or come back empty.
    -- Both routes then fetch the canonical feed for the page counters.
    if #pages == 0 and driver.unreadFilter and reason == "empty" then
        -- The server listed nothing unread: that is the answer, no walk.
        logger.info("Meguru: the server lists nothing unread in series", remote_id)
        return {}, "empty"
    end
    if #pages == 0 and driver.unreadFilter then
        logger.info("Meguru: filtered series walk yielded nothing (", tostring(reason),
            ") - asking the canonical feed")
        pages, complete, reason = walk(nil, { lang = info.ctx and info.ctx.lang })
        -- The canonical feed carries no read flag: counters only.
        basis = "counters"
    end

    local items = {}
    for _, page in ipairs(pages) do
        -- Each page against its own URL: entry hrefs are relative.
        for _, item in ipairs(itemsFrom(driver, page.feed, page.url, ctx)) do
            items[#items + 1] = item
        end
    end
    if #items == 0 then
        -- A walk with no items is not an answer; do not suppress the page.
        return fallback(reason or "the feed carried no entry")
    end

    logger.info("Meguru: walked", #pages, "page(s) for series", remote_id, "-",
        #items, "items,", complete and "complete" or ("stopped: " .. tostring(reason)),
        basis)
    return items, basis
end

-- Open the first unread volume of the series the row was offered for.
-- Writes nothing and starts no walk; mirrors registerBook's series resolution.
-- No resolveSeries step: feedSeries proved one series, no request may follow.
function Open.openFirstUnread(browser, info)
    local conn = Sources.connection(info.server_name)
    if not conn then
        UIManager:show(InfoMessage:new{
            text = T(_("no catalog entry with this title in settings/opds.lua: %1"),
                tostring(info.server_name)),
        })
        return
    end

    local series_name = info.driver.seriesName(info.feed, info.first_entry, info.ctx)
    if type(series_name) ~= "string" or series_name == "" then
        logger.warn("Meguru: could not name the series behind this feed")
        return
    end
    -- The context a marker would give, for a series that has no marker yet.
    local series = {
        server_name      = info.server_name,
        server_kind      = info.kind,
        series_remote_id = info.remote_id,
        series_name      = series_name,
        series_cover_url = Base.coverFromFeed(info.feed, info.first_entry,
            info.feed_url, info.driver),
        lang             = info.ctx and info.ctx.lang,
    }

    -- From the canonical feed, not the page on screen.
    -- basis says what its answer rests on; see seriesItems.
    local parsed, basis = seriesItems(info, conn)

    -- A finished series has no chapter; "empty" collapses into "no target".
    local target
    if basis ~= "empty" then
        target = firstUnread(parsed, basis == "flag", info.driver)
    end
    if not target then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 has nothing unread."), series_name),
        })
        return
    end

    local manager = browser and browser._manager
    local host = (manager and manager.ui) and manager or fallback_host
    -- target twice: the book to open and the answer to "where is this reader".
    Open.openCatalogItem(host, series, target, target)
end

-- Offer a starting point, then open; calls opts.open() either way.
-- Asked only when there is a choice — the server's or the reader's own.
function Open.offerResume(host, context, item, opts)
    local file, open = opts.file, opts.open

    -- Read here before changes the wording and the page, not whether to ask.
    local opened_before = not neverOpened(file)

    -- The reader's own place, from the sidecar KOReader restores from.
    local local_page = opened_before and localLastPage(file) or nil

    -- The server's position: here a page, elsewhere a book to open.
    local position = opts.target

    local server_page, jump
    if position and item and position.item_key == item.item_key then
        -- In this book: a page, when different from the reader's own.
        -- A lead inside PSE.samePlace is the prefetch artefact, not a position.
        if not PSE.samePlace(position.last_read, local_page) then
            server_page = usablePage(position.last_read, opts.count)
        end
    else
        jump = position
    end

    -- Asked only when the server has an opinion; no answer means no dialog.
    if not server_page and not jump then
        open()
        return
    end

    -- The clicked book's own page: always offered.
    -- Page 1 must be written, or the silent seed would open at the server's.
    local here_page
    if opened_before then
        here_page = local_page
    else
        here_page = 1
    end

    -- The server's answers carry the glyph our own row uses.
    -- A tap past the dialog cancels — nothing opens; once stops a double tap.
    -- noteHandoff, not once, stops the showReader wrap re-asking.
    local acted = false
    local function once(action)
        if acted then
            return
        end
        acted = true
        action()
    end

    -- The verb follows the situation: an unread book starts, not "page 1".
    local here_verb = opened_before and _("Continue") or _("Start reading")
    local here_shown_page = opened_before and here_page or nil

    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {
        {
            -- No glyph: the glyph marks the server's answers only.
            text = buttonLabel(here_verb, item, here_shown_page, false),
            callback = function()
                UIManager:close(dialog)
                if opened_before then
                    -- KOReader restores their own position unaided.
                    once(open)
                else
                    -- No position to restore: this button writes page 1.
                    -- Without it, the silent seed opens at the server's page.
                    once(function()
                        Open.seedLastPage(file, here_page)
                        open()
                    end)
                end
            end,
        },
    }
    if server_page then
        buttons[#buttons + 1] = {
            {
                -- Same verb and book as above, with the server's page instead.
                text = buttonLabel(_("Continue"), item, server_page, true),
                callback = function()
                    UIManager:close(dialog)
                    once(function()
                        Open.seedLastPage(file, server_page)
                        open()
                    end)
                end,
            },
        }
    end
    if jump then
        buttons[#buttons + 1] = {
            {
                -- Names the book too, so it is not confused with the page one.
                text = buttonLabel(_("Continue"), jump, jumpPage(jump, context), true),
                callback = function()
                    UIManager:close(dialog)
                    -- Silent on purpose: the reader named this book already.
                    -- Reopening it is what openItemSilently avoids.
                    local open_target = opts.open_item or function(chosen)
                        Open.openItemSilently(host, context, chosen)
                    end
                    once(function() open_target(jump) end)
                end,
            },
        }
    end

    dialog = ButtonDialog:new{
        -- The series named once; each button names its own book and page.
        title = dialogTitle(context, item),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Everything a marker needs, worked out but not written.
-- The dialog needs the path before the file exists; dismissal leaves no book.
local function planMarker(context, item)
    -- The path recomputed from identity, before resolveStream.
    -- It costs no request and cannot drift from the write's own path.
    local identity = {
        server_name      = context.server_name,
        series_remote_id = context.series_remote_id,
        -- One of the fields dirFor/pathFor read; another changes the path.
        series_name      = context.series_name,
        item_key         = item.item_key,
        title            = item.title,
    }
    local dir = Marker.dirFor(identity, {
        base_dir      = Marker.baseDir(),
        server_folder = Settings.get("marker_server_dir") and true or false,
    })
    local path = Marker.pathFor(dir, identity)
    if FS.exists(path) and Marker.matches(path, identity) then
        -- Count read back from the marker, not resolved: no request.
        -- The server's page button keeps its count on later opens.
        local existing = Marker.load(path)
        return {
            item        = item,
            server_name = context.server_name,
            path        = path,
            existing    = true,
            count       = existing and tonumber(existing.count) or nil,
        }
    end

    -- The pair serverShim builds, so a second caller spells it the same way.
    local server = serverShim(context.server_name, context.server_kind)
    local template, count = Feed.resolveStream(item, server)
    if type(template) ~= "string" or template == "" then
        logger.warn("Meguru: no page stream for", item.title)
        UIManager:show(InfoMessage:new{
            text = T(_("could not find a page stream for “%1”."),
                item.display_title or item.title),
        })
        return nil
    end

    -- Everything the marker needs to name its series, with no query.
    local desc = Marker.new{
        server_name      = context.server_name,
        series_remote_id = context.series_remote_id,
        series_name      = context.series_name,
        server_kind      = context.server_kind,
        item_key         = item.item_key,
        title            = item.title,
        template         = template,
        count            = count,
        last_read        = item.last_read,
        lang             = context.lang,
        cover_url        = item.cover_url,
        series_cover_url = context.series_cover_url,
    }
    -- dir and path reused: pathFor consults the directory it writes into.
    return {
        item        = item,
        server_name = context.server_name,
        desc        = desc,
        path        = path,
        existing    = false,
        count       = count,
    }
end

-- Write the marker a plan describes, and return its path.
-- Idempotent for an existing plan, which writes nothing.
function commitMarker(plan)
    if plan.existing then
        return plan.path
    end
    local file = Marker.saveAt(plan.path, plan.desc)
    if not file then
        return nil
    end
    -- Nothing kept about where it went: markerPathFor recomputes it.
    -- Credentials in memory only, so the first page does not race the flush.
    local conn = Sources.connection(plan.server_name)
    if conn then
        Sources.remember(file, conn.username, conn.password)
    end

    -- Left beside the markers for whatever outside KOReader reads the folder.
    -- A cover that cannot be fetched never fails the book.
    SeriesCover.save(file, plan.desc)
    return file
end

-- Commit, then hand over; shared so the write cannot be forgotten on one path.
local function openPlanned(host, plan)
    local file = commitMarker(plan)
    if not file then
        return nil
    end
    return openPrepared(host, file)
end

-- The marker for a catalog item, handed over without a word.
-- The asking already happened in offerResume; exported to cross order.
function Open.openItemSilently(host, context, item)
    local plan = planMarker(context, item)
    if not plan then
        return nil
    end
    return openPlanned(host, plan)
end

-- The series' furthest-read item, fetched (never cached).
-- Both entry points end here at one current answer.
-- The file-manager path has no feed, so it needs this.
-- The filtered feed is asked first, the canonical second; lang travels along.
local function currentResumeTarget(context)
    -- context is Marker.seriesContext's shape, from a marker or a fresh browse.
    local kind = context and context.server_kind
    local driver = kind and Base.forKind(kind)
    local conn = context and Sources.connection(context.server_name)
    local why = "no driver for this server's kind"
    if not conn then
        why = "no saved catalog for this server"
    elseif not NetworkMgr:isConnected() then
        why = "no connection"
    elseif driver then
        why = "the feed could not be fetched"
        -- The book's own lang, not a defaulted per-server one.
        local ctx = { lang = context.lang }
        -- Ask as a filter: the flag is not in the feed's data.
        -- The page counter can disagree with it.
        local filter = driver.unreadFilter

        -- ctx.url for Komga: no browsed feed, so build the canonical one.
        ctx.url = driver.catalogURL(conn.url, context.series_remote_id, ctx, filter)

        local function fetch(which)
            local url = driver.catalogURL(conn.url, context.series_remote_id, ctx, which)
            local ok, feed = pcall(Net.fetchFeed, url, {
                username = conn.username,
                password = conn.password,
                timeout = "resume",
            })
            return ok and feed or nil, url
        end

        -- The filtered feed is only an optimisation.
        -- "Empty": the server answered; ask the canonical feed for the end.
        -- "failed": counters are the only evidence (firstUnfinishedOrLast).
        local filtered_why, server_says_all_read
        if filter then
            local feed, url, reason = fetch(filter)
            if feed then
                -- firstIn returns sequence[1]; nil means the feed was empty.
                local ok_fresh, target = pcall(freshResumeTarget,
                    driver, feed, url, ctx, context, firstIn)
                if ok_fresh and target then
                    return target
                end
                filtered_why = "nothing unread in the filtered feed"
                server_says_all_read = true
            elseif reason == "empty" then
                server_says_all_read = true
            else
                filtered_why = "the filtered feed could not be fetched"
            end
        end

        local feed, url = fetch(nil)
        if feed then
            local ok_fresh, target = pcall(freshResumeTarget, driver, feed, url, ctx, context,
                -- lastIn when the server said nothing is unread.
                server_says_all_read and lastIn or nil)
            if ok_fresh and target then
                return target
            end
            why = "the feed carried no entry for this series"
        else
            why = filtered_why or "the feed could not be fetched"
        end
    end

    -- No degraded answer: with no catalog there is nothing to be stale from.
    -- So the honest answer is none, and the reason is logged.
    logger.info("Meguru: no resume point from the server (", why, ")")
    return nil
end

-- Open a catalog item already known.
-- An existing marker, or one whose Suwayomi stream is resolved here.
-- target is the caller's fresh answer; a rederivation could differ.
function Open.openCatalogItem(host, context, item, target)
    local plan = planMarker(context, item)
    if not plan then
        return nil
    end

    Open.offerResume(host, context, item, {
        count = plan.count,
        -- Path, not file: offerResume reads the sidecar, found by path.
        file = plan.path,
        target = target,
        open = function()
            openPlanned(host, plan)
        end,
    })
    -- Reports "planned", not "opened": the book opens on the reader's tap.
    -- Callers must not assume the file is there.
    return plan.path
end

-- The resume offer for a marker opened from the file manager or History.
-- No feed and no caller to hand back to, so it starts the reader itself.
function Open.offerResumeForFile(file, host, proceed)
    -- No early "is it new?" test: a book already read must still be askable.
    -- neverOpened decides only the wording.
    -- pcall: a foreign marker must cost a dialog at most, never the book.
    local ok, desc = pcall(Marker.load, file)
    if not ok or type(desc) ~= "table" then
        proceed()
        return
    end

    -- The marker answers for itself.
    -- A book from History with no network still knows its series.
    local context = Marker.seriesContext(desc)

    Open.offerResume(host, context, desc, {
        -- The page is in the marker, free and offline.
        -- The chapter target is a series fact, so it is fetched (nil offline).
        count = tonumber(desc.count),
        file = file,
        target = currentResumeTarget(context),
        open = proceed,
        -- No feed behind this one, and deliberately not via handToReader.
        -- proceed is the wrap's own unwrapped opener.
        open_item = function(target)
            local plan = planMarker(context, target)
            if not plan then
                return
            end
            local other = commitMarker(plan)
            if other then
                proceed(other)
            end
        end,
    })
end

-- Ask for a folder with KOReader's own picker, then run on_chosen(dir).
-- Cancelling changes nothing: no callback, and the stored folder stands.
function Open.chooseMarkerDir(on_chosen)
    local ok, DownloadMgr = pcall(require, "ui/downloadmgr")
    if not ok or type(DownloadMgr) ~= "table"
        or type(DownloadMgr.new) ~= "function"
        or type(DownloadMgr.chooseDir) ~= "function" then
        logger.warn("Meguru: no folder picker available; using the default marker folder")
        on_chosen(Marker.pickerStartDir())
        return
    end
    DownloadMgr:new{
        onConfirm = function(dir)
            if type(dir) ~= "string" or dir == "" then
                return
            end
            Settings.set("marker_dir", dir)
            logger.info("Meguru: marker folder chosen:", dir)
            on_chosen(dir)
        end,
    }:chooseDir(Marker.pickerStartDir())
end

-- The OPDS-PSE stream among an entry's acquisitions: one with {pageNumber}.
function Open.findStream(item)
    for _, acq in ipairs(item and item.acquisitions or {}) do
        if type(acq) == "table" and acq.count
            and type(acq.href) == "string"
            and acq.href:find("{pageNumber}", 1, true) then
            return acq
        end
    end
    return nil
end

-- The one path both entry points end at: an entry, the feed it came from, and
-- a reader. retained is that feed in last_feed's shape, so the identity the
-- marker is planned from cannot depend on which window asked for the book.
function Open.openInFeed(host, server_name, kind, raw_entry, stream, retained, opts)
    opts = opts or {}
    -- The book's own lang travels in the marker; not remembered per server.
    -- The caller's answer first: a browser saw every URL that was navigated.
    local lang = opts.lang or langFrom({ retained and retained.url, stream.href })

    local registered
    if raw_entry then
        registered = registerBook(server_name, kind, raw_entry, stream, lang, retained)
    else
        -- Distinct from registerBook's bails: nothing there was reached.
        -- Naming the retained feed tells a hook from one replaced under it.
        local entries = retained and retained.feed and retained.feed.entry
        local shown = entries
            and (#entries .. " entry(ies) from " .. tostring(retained.url))
            or "nothing"
        logger.info("Meguru: not catalogued: no retained entry matches this stream",
            "(catalog=" .. tostring(server_name) .. ", retained=" .. shown .. ")")
    end

    -- registered.context is already Marker.seriesContext's shape.
    -- kind is the fallback when a book could not be identified.
    local context = registered and registered.context or {}
    local desc = Marker.new{
        server_name      = context.server_name or server_name,
        series_remote_id = context.series_remote_id,
        series_name      = context.series_name,
        server_kind      = context.server_kind or kind,
        item_key         = registered and registered.item.item_key or nil,
        -- The server's own title, so both routes name one marker, not two.
        -- An aggregate titles a book differently from its series feed.
        title            = Naming.stripAliasPrefix(
            (registered and registered.title) or opts.title),
        template         = stream.href,
        count            = tonumber(stream.count) or 0,
        last_read        = tonumber(stream.last_read) or nil,
        lang             = context.lang or lang,
        cover_url        = registered and registered.item.cover_url or nil,
        series_cover_url = context.series_cover_url,
    }

    -- A flat key from the stream URL is safe only here: nothing looks it up.
    -- 64 bits carry the identity, so a collision cannot merge two books.
    if not desc.item_key then
        desc.item_key = "flat:" .. Naming.digest64(stream.href)
        logger.info("Meguru: book has no catalog identity; marker stays flat")
    end

    local dir = Marker.dirFor(desc, {
        -- No base_dir: default Marker.baseDir(), as planMarker uses too.
        server_folder = Settings.get("marker_server_dir") and true or false,
    })
    -- Planned here, written on the answer; the marker shelves the book.
    -- Cannot use commitMarker: it looks credentials up in sources.
    -- That catalogue is not flushed yet on this path.
    local path = Marker.pathFor(dir, desc)
    local count = tonumber(desc.count)

    -- A host that needs its own last step says so; the rest open it here.
    local handover = opts.handover or function(file)
        return openPrepared(host, file)
    end
    local credentials = opts.credentials or {}

    -- Resolved before the dialog, only when registerBook declined to answer.
    -- Nil means the dialog offers no server position.
    local resume_target = registered and registered.resume or nil
    if not resume_target and registered and registered.server_target then
        resume_target = currentResumeTarget(registered.context)
    end

    -- The resume question comes before the handoff: both handoffs are terminal.
    Open.offerResume(host, registered and registered.context,
        -- or desc so a flat book names itself, not "this book".
        registered and registered.item or desc, {
            count = count,
            file = path,
            -- What registerBook just read off the feed it was handed.
            -- Fetched when the server flags chapters read.
            target = resume_target,
            open = function()
                -- All the write does now, here on the answer: the file.
                -- Credentials stay in memory; nothing more in the marker.
                local file = Marker.saveAt(path, desc)
                if not file then
                    -- Nothing written: say so rather than open a dead path.
                    UIManager:show(InfoMessage:new{
                        text = T(_("could not write the book file.\n%1"), path),
                    })
                    return
                end
                Sources.remember(file, credentials.username, credentials.password)

                -- Repeated because this path skips commitMarker.
                -- A cover hung only off commitMarker would be missing here.
                SeriesCover.save(file, desc)

                handover(file)
                -- No walk follows: a neighbour is fetched when the reader asks.
                -- The new marker carries what the removed walk needed.
            end,
        })
end

-- Turn a browsed stream into a marker and open it.
-- Takes no destination folder, so every entry point lands in the same place.
function Open.openAsBook(browser, item, stream)
    local server_name = catalogTitle(browser)
    if not server_name then
        return
    end
    local kind = Open.serverKindFor(browser)
    -- The book's own lang travels in the marker; not remembered per server.
    local lang = langFromBrowser(browser)
    -- The browsed feed, kept per catalog by the parseFeed hook.
    local retained = last_feed[server_name]
    local ctx = { lang = lang, url = retained and retained.url }

    local raw_entry = rawEntryFor(browser, stream)
    if raw_entry and not kind then
        -- No sniff and no recorded kind: ask the drivers.
        -- The last chance to give this book a series.
        kind = Base.kindFor(raw_entry, stream.href, ctx)
        if kind then
            logger.info("Meguru: catalog", server_name,
                "signs itself with no known author; detected", kind, "from the entry")
        end
    end

    -- The browser's own manager closes it and opens what it downloaded;
    -- without one the fallback host opens the marker as the file manager does.
    local manager = browser._manager
    local host = (manager and manager.ui) and manager or fallback_host

    Open.openInFeed(host, server_name, kind, raw_entry, stream, retained, {
        lang = lang,
        title = item.title or item.text,
        credentials = {
            username = browser.root_catalog_username,
            password = browser.root_catalog_password,
        },
        handover = function(file)
            -- Prefer the built-in open path: it closes the browser cleanly.
            if manager and type(manager.openDownloadedFile) == "function"
                and manager.opds_browser then
                -- Arm the one-shot: the dialog above already asked.
                handOff(file, function() manager:openDownloadedFile(file) end)
            else
                openPrepared(host, file)
            end
        end,
    })
end

-- Add the "Meguru this series" row to the browser's own dialog.
-- Silently no-op unless the shape and stream are there; it is not ours.
function Open.injectBookRow(browser, item)
    local dialog = browser and browser.download_dialog
    if not dialog or type(dialog.buttons) ~= "table" then
        return
    end
    local stream = Open.findStream(item)
    if not stream then
        return
    end

    local buttons = dialog.buttons
    -- Inserted first, above everything: this row is why the dialog opened.
    -- It assumes nothing about the rows already present.
    table.insert(buttons, 1, {}) -- separator, under our row
    table.insert(buttons, 1, {
        {
            text = "\u{25B6} " .. _("Meguru this series"),
            font_bold = true,
            callback = function()
                UIManager:close(dialog)
                -- Needs a connection for the first pages, not a destination.
                -- The manager prompts for one instead of failing.
                NetworkMgr:runWhenConnected(function()
                    Open.openAsBook(browser, item, stream)
                end)
            end,
        },
    })
    dialog:reinit()
    UIManager:setDirty("all", "ui")
    logger.dbg("Meguru: added \"Meguru this series\" button for", item.text)
end

return Open
