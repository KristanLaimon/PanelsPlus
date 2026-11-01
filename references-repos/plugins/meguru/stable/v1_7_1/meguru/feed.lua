-- Reading a series' canonical feed: walk it, order it, name a neighbour.

local logger = require("logger")

local Base = require("meguru/driver/base")
local Net = require("meguru/net")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Feed = {}

-- Bounds a `next` chain that never terminates; well past any real series.
Feed.MAX_PAGES = 25

-- A tap cannot spend half a minute of frozen e-ink; six pages is 600 chapters.
Feed.TAP_PAGES = 6

-- The href is relative to its own page, not the first page's path.
local function nextLink(feed, page_url)
    local url = require("socket.url")
    for _, link in ipairs(type(feed.link) == "table" and feed.link or {}) do
        if type(link) == "table" and link.rel == "next"
            and type(link.href) == "string" and link.href ~= "" then
            return url.absolute(page_url, link.href)
        end
    end
    return nil
end

-- Synchronous HTTP: the walk stops between pages and hands control back.
local Walker = {}
Walker.__index = Walker

function Feed.walker(url, opts)
    return setmetatable({
        url      = url,
        opts     = opts or {},
        visited  = {},
        pages    = {},
        count    = 0,
        -- The next page to fetch; nil here is the end of the chain.
        current  = url,
    }, Walker)
end

function Walker:step()
    if self.finished then
        return false
    end
    local opts = self.opts

    local function stop(complete, reason)
        self.finished, self.complete, self.reason = true, complete, reason
        return false
    end

    if not self.current then
        return stop(true, nil)
    end
    if self.visited[self.current] then
        -- A looping `next` chain would otherwise page forever.
        return stop(false, "next-loop")
    end
    if self.count >= (opts.max_pages or Feed.MAX_PAGES) then
        return stop(false, "page-cap")
    end
    if opts.is_cancelled and opts.is_cancelled() then
        return stop(false, "cancelled")
    end
    self.visited[self.current] = true

    local page_url = self.current
    local feed, reason = Net.fetchFeed(page_url, {
        username = opts.username,
        password = opts.password,
        -- A tap passes "resume" (4s/8s); nil stays "feed" in Net.fetchFeed.
        timeout = opts.timeout,
    })
    self.count = self.count + 1
    if not feed then
        return stop(false, reason or "network")
    end

    -- Kept per page: hrefs resolve against their own page, not the first's.
    self.pages[#self.pages + 1] = { feed = feed, url = page_url }
    if opts.on_page then
        opts.on_page(self.count, page_url)
    end

    self.current = nextLink(feed, page_url)
    if not self.current then
        return stop(true, nil)
    end
    return true
end

function Feed.walk(url, opts)
    local walker = Feed.walker(url, opts)
    while walker:step() do end
    return walker.pages, walker.complete, walker.reason, walker.count
end

-- A page outranks none; between equals the head copy is the shortcut.
local function displaces(held, item, index)
    if held.item.last_read == nil and item.last_read ~= nil then
        return true
    end
    return held.index == 1 and index ~= 1
        and held.item.last_read == item.last_read
end

-- A copy carrying `last_read` is the book; one without it is only a shortcut.
-- `replaced` is the copies given up for the one that states the book better.
function Feed.dedupe(items)
    local at, kept, dropped, replaced = {}, {}, 0, {}
    for index, item in ipairs(items or {}) do
        local key = item.item_key
        -- No item_key names no book, so it is dropped like a duplicate.
        if not key then
            dropped = dropped + 1
        else
            local slot = at[key]
            if not slot then
                at[key] = #kept + 1
                kept[#kept + 1] = { item = item, index = index }
            else
                dropped = dropped + 1
                if displaces(kept[slot], item, index) then
                    replaced[#replaced + 1] = kept[slot].item
                    kept[slot] = { item = item, index = index }
                end
            end
        end
    end
    -- Sorted by the index each survivor was found at: the feed's own order.
    table.sort(kept, function(a, b) return a.index < b.index end)
    local unique = {}
    for i, entry in ipairs(kept) do
        unique[i] = entry.item
    end
    return unique, dropped, replaced
end

-- The collapse spans the walk, not one page: a chapter can repeat across pages.
function Feed.collect(walker, plan)
    local all = {}
    for _, page in ipairs(walker.pages or {}) do
        for _, item in ipairs(plan.driver.parseCatalogPage(
                page.feed, page.url, plan.ctx) or {}) do
            all[#all + 1] = item
        end
    end
    local unique, duplicates = Feed.dedupe(all)
    return unique, duplicates
end

-- A title number only when the driver vouches; else the server's list order.
-- Everything after `positioned` has no position and stays in feed order.
function Feed.ordered(parsed, opts)
    local Naming = require("meguru/naming")
    opts = opts or {}
    local ordered, fallback_position = {}, {}
    for index, item in ipairs(parsed or {}) do
        local path_position = type(item.detail_url) == "string"
            and tonumber(item.detail_url:match("/chapter/(%d+)/")) or nil
        -- Skipped unless a driver vouches; `Naming` is the one lazy require.
        local title_number
        if opts.title_order then
            local _, _, number = Naming.deriveSeries(item.title or "")
            title_number = number
        end
        local position = path_position or title_number
        if position then
            ordered[#ordered + 1] = { item = item, position = position }
        else
            fallback_position[#fallback_position + 1] = { item = item, index = index }
        end
    end
    table.sort(ordered, function(a, b) return a.position < b.position end)

    local sequence = {}
    for _, entry in ipairs(ordered) do
        sequence[#sequence + 1] = entry.item
    end
    local positioned = #sequence
    -- The unpositioned tail keeps feed order, which is Kavita's reading order.
    table.sort(fallback_position, function(a, b) return a.index < b.index end)
    for _, entry in ipairs(fallback_position) do
        sequence[#sequence + 1] = entry.item
    end

    return sequence, positioned
end

-- No count or no read means unfinished: re-offering beats skipping one.
function Feed.isFinished(item)
    local total = tonumber(item.page_count) or tonumber(item.progress_total)
    local read = tonumber(item.last_read)
    return (total and read and read >= total) and true or false
end

-- Reads forward: the unpositioned tail at the end cannot win, so no guard.
function Feed.firstUnfinished(sequence, _positioned)
    for _, item in ipairs(sequence) do
        if not Feed.isFinished(item) then
            return item
        end
    end
    return nil
end

-- The ordered prefix first: its last entry is furthest along; feed tail last.
function Feed.lastIn(sequence, positioned)
    for pass = 1, 2 do
        local first, last
        if pass == 1 then
            first, last = 1, positioned
        else
            first, last = positioned + 1, #sequence
        end
        if last >= first then
            return sequence[last]
        end
    end
    return nil
end

-- A finished series still answers: the reader who finished the last is at it.
function Feed.firstUnfinishedOrLast(sequence, positioned)
    return Feed.firstUnfinished(sequence) or Feed.lastIn(sequence, positioned)
end

-- On a filtered feed the flag wins: only the server knows what it flags unread.
function Feed.firstIn(sequence, _positioned)
    return sequence[1]
end

-- Absent key means no neighbour; guessing from position offers an unasked one.
function Feed.neighbor(sequence, item_key, which)
    if type(item_key) ~= "string" or item_key == "" then
        return nil
    end
    local index
    for i, item in ipairs(sequence or {}) do
        if item.item_key == item_key then
            index = i
            break
        end
    end
    if not index then
        return nil
    end
    return sequence[which == "previous" and (index - 1) or (index + 1)]
end

-- Trailing slashes stripped so joining a path never doubles them.
local function baseURL(configured_url)
    if type(configured_url) ~= "string" or configured_url == "" then
        return nil
    end
    return (configured_url:gsub("/+$", ""))
end

-- The one I/O a driver causes: credentials, timeouts and redaction stay here.
local function makeFetch(conn)
    return function(url_str)
        if type(url_str) ~= "string" or url_str == "" then
            return nil
        end
        local feed = Net.fetchFeed(url_str, {
            username = conn.username,
            password = conn.password,
        })
        return feed
    end
end

-- A JSON answer, decoded here so no driver needs a decoder.
-- "resume" (4s/8s), not makeFetch's "feed": the reader awaits this dialog.
local function makeJsonFetch(conn)
    return function(url_str)
        if type(url_str) ~= "string" or url_str == "" then
            return nil
        end
        local code, _, body = Net.get(url_str, {
            username = conn.username,
            password = conn.password,
            accept   = "application/json",
            timeout  = "resume",
        })
        if code ~= 200 or type(body) ~= "string" or body == "" then
            logger.dbg("Meguru: no JSON answer from", Net.redactUrl(url_str),
                "(", tostring(code), ")")
            return nil
        end
        -- Lazy: a build without a decoder costs this hook, not the module.
        -- Net.jsonDecoder knows several names; one gave nothing on a device.
        local json = Net.jsonDecoder()
        if not json then
            return nil
        end
        local ok_decode, decoded = pcall(json.decode, body)
        if not ok_decode or type(decoded) ~= "table" then
            logger.dbg("Meguru: could not decode the answer from",
                Net.redactUrl(url_str), "-", tostring(decoded))
            return nil
        end
        return decoded
    end
end

-- Refusals go through `opts.on_failure`: this module writes nothing, and an
-- unknown kind and an unconfigured server need different repairs.
function Feed.plan(server, opts)
    opts = opts or {}
    local function refuse(reason)
        if opts.on_failure then
            opts.on_failure(reason)
        end
        return nil, reason
    end

    local driver = Base.forKind(server and server.kind)
    if not driver then
        return refuse("unknown server kind")
    end

    local conn = Sources.connection(server.name)
    local base = conn and baseURL(conn.url)
    if not base then
        return refuse("server not configured")
    end

    -- Defaulting lang would fetch the wrong translation of the right series.
    local ctx = { lang = opts.lang }
    local url = driver.catalogURL(base, opts.remote_id, ctx)
    if type(url) ~= "string" or url == "" then
        return refuse("no catalog feed for this series")
    end

    return {
        driver = driver,
        ctx    = ctx,
        url    = url,
        -- Bound here so no caller rebuilds them and passes another server's.
        walker_opts = {
            username     = conn.username,
            password     = conn.password,
            max_pages    = opts.max_pages,
            on_page      = opts.on_page,
            is_cancelled = opts.is_cancelled,
            timeout      = opts.timeout,
        },
    }
end

-- The one place a marker becomes a server.
-- A v1 marker has no server_kind, so its stream template is asked instead.
function Feed.planForMarker(desc, opts)
    if type(desc) ~= "table" then
        return nil, "no marker"
    end
    local kind = desc.server_kind
    if not kind then
        kind = Base.kindFromTemplate(desc.template)
        if kind then
            logger.dbg("Meguru: this marker names no server kind; its stream"
                .. " template says", kind)
        end
    end
    return Feed.plan({
        name = desc.server_name,
        kind = kind,
    }, {
        remote_id    = desc.series_remote_id,
        lang         = desc.lang,
        max_pages    = opts and opts.max_pages,
        on_page      = opts and opts.on_page,
        is_cancelled = opts and opts.is_cancelled,
        timeout      = opts and opts.timeout,
        on_failure   = opts and opts.on_failure,
    })
end

-- For Suwayomi a refresh is correctness, not speed: a stored position may be
-- renumbered, and a stale one fetches a different chapter while answering 200.
function Feed.resolveStream(item, server, opts)
    opts = opts or {}
    local driver = server and Base.forKind(server.kind)
    if not driver then
        -- The early return hands back a stored template lazy items do not have,
        -- so the failure surfaces later as an unnamed "no page stream".
        logger.warn("Meguru: no driver for server", tostring(server and server.name),
            "(kind=" .. tostring(server and server.kind) .. ")",
            "- cannot resolve the stream for", item.title)
        return item.template, item.page_count
    end
    local conn = Sources.connection(server.name)
    if not conn then
        logger.warn("Meguru: no configured catalog named",
            tostring(server and server.name), "in settings/opds.lua")
        return item.template, item.page_count
    end
    local template, count = driver.resolveStream(item, makeFetch(conn), opts)
    if template then
        return template, count or item.page_count
    end
    -- Refresh failed: the stored template still opens the book.
    return item.template, item.page_count
end

-- Asked once per open, not per entry: `discover` stays pure by doing no I/O.
-- Pcall'd: the caller is a UI callback, and a throw would cost the open.
-- No cache: the marker's path depends on this answer, so it cannot store it.
function Feed.resolveSeries(entry, stream, server, ctx)
    local driver = server and Base.forKind(server.kind)
    if not (driver and type(driver.resolveSeries) == "function") then
        return nil
    end
    local conn = Sources.connection(server.name)
    if not conn then
        logger.warn("Meguru: no configured catalog named",
            tostring(server and server.name), "in settings/opds.lua")
        return nil
    end
    local ok, found = pcall(driver.resolveSeries, entry, stream, ctx, makeJsonFetch(conn))
    if not ok then
        logger.warn("Meguru: could not resolve the series for",
            tostring(server and server.name), "-", tostring(found))
        return nil
    end
    if type(found) ~= "table" or type(found.series_remote_id) ~= "string"
        or found.series_remote_id == "" then
        return nil
    end
    -- Logged: a flat book must distinguish never-run, failed, and refused.
    logger.info("Meguru: resolved the series for", tostring(entry and entry.title),
        "-", tostring(found.series_remote_id),
        found.series_name and ("(" .. tostring(found.series_name) .. ")") or "")
    return found
end

return Feed
