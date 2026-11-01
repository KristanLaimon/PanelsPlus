-- HTTP for the engine; LuaSocket is synchronous, so nothing here may paint.

local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local Credential = require("meguru/credential")

local Net = {}

-- Tighter than socketutil.FILE_*: a sync walks tens of feed pages back to back.
Net.FEED_BLOCK_TIMEOUT = 10
Net.FEED_TOTAL_TIMEOUT = 30

Net.FEED_ACCEPT = "application/atom+xml;profile=opds-catalog, application/xml;q=0.9, */*;q=0.5"
Net.IMAGE_ACCEPT = "image/*;q=1, */*;q=0.5"

-- The only way a log line may print a URL: credential segment stripped.
function Net.redactUrl(str)
    local parsed = url.parse(str)
    if not parsed or not parsed.host then
        return "(invalid url)"
    end
    local shown = (parsed.scheme or "http") .. "://" .. parsed.host
    if parsed.port then
        shown = shown .. ":" .. parsed.port
    end
    shown = shown .. (parsed.path or "")
    if parsed.query and #parsed.query > 0 then
        shown = shown .. "?" .. #parsed.query .. " bytes of query"
    end
    return Credential.redact(shown)
end

-- A resume lookup runs while a dialog waits, so it gets tight limits.
Net.RESUME_BLOCK_TIMEOUT = 4
Net.RESUME_TOTAL_TIMEOUT = 8

-- Fired by a page turn, so it has to lose to the reader's thumb: 2s/4s.
Net.PROGRESS_BLOCK_TIMEOUT = 2
Net.PROGRESS_TOTAL_TIMEOUT = 4

local TIMEOUTS = {
    feed = { Net.FEED_BLOCK_TIMEOUT, Net.FEED_TOTAL_TIMEOUT },
    page = { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT },
    large = { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT },
    resume = { Net.RESUME_BLOCK_TIMEOUT, Net.RESUME_TOTAL_TIMEOUT },
    -- Only getToFile's total is enforced, being the one with a real sink.
    download = { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT },
    -- The block timeout is what bounds patch; the total is symmetry.
    progress = { Net.PROGRESS_BLOCK_TIMEOUT, Net.PROGRESS_TOTAL_TIMEOUT },
}

-- GET: (code, headers, body); nil on failure; (code, headers, nil) on non-200.
function Net.get(url_str, opts)
    opts = opts or {}
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil
    end

    local sink = {}
    local req = {
        url = url_str,
        headers = {
            ["Accept"] = opts.accept or "*/*",
            -- Body asked uncompressed: the sink is a plain byte table.
            ["Accept-Encoding"] = "identity",
        },
        sink = ltn12.sink.table(sink),
    }
    if opts.username and opts.username ~= "" then
        req.user = opts.username
        -- LuaSocket builds user..":"..password, so a nil password would raise.
        req.password = opts.password or ""
    end

    local timeout = TIMEOUTS[opts.timeout or "page"] or TIMEOUTS.page
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code, headers = pcall(function()
        -- socket.skip(1, ...) drops the leading connection status.
        return socket.skip(1, http.request(req))
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("Meguru: HTTP error for", Net.redactUrl(url_str), ":", tostring(code))
        return nil
    end
    if type(code) ~= "number" then
        logger.warn("Meguru: HTTP request failed for", Net.redactUrl(url_str),
            "(", tostring(code), ")")
        return nil
    end
    if code ~= 200 then
        logger.warn("Meguru: HTTP", code, "for", Net.redactUrl(url_str))
        return code, headers, nil
    end
    return 200, headers, table.concat(sink)
end

-- PATCH: 2xx is success (empty 204 is a write); no JSON encoder here.
-- PATCH not PUT: the endpoint answers PUT with 405 (see reading-position.md).
function Net.patch(url_str, body, opts)
    opts = opts or {}
    body = type(body) == "string" and body or ""
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil
    end

    local sink = {}
    local req = {
        url = url_str,
        method = "PATCH",
        headers = {
            ["Accept"] = opts.accept or "*/*",
            ["Accept-Encoding"] = "identity",
            ["Content-Type"] = opts.content_type or "application/json",
            -- Some servers and proxies answer 411 to a body with no length.
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }
    if opts.username and opts.username ~= "" then
        req.user = opts.username
        -- As in get: a nil password would raise inside http.request.
        req.password = opts.password or ""
    end

    local timeout = TIMEOUTS[opts.timeout or "progress"] or TIMEOUTS.progress
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code, headers = pcall(function()
        return socket.skip(1, http.request(req))
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("Meguru: HTTP error for", Net.redactUrl(url_str), ":", tostring(code))
        return nil
    end
    if type(code) ~= "number" then
        logger.warn("Meguru: HTTP request failed for", Net.redactUrl(url_str),
            "(", tostring(code), ")")
        return nil
    end
    if code < 200 or code > 299 then
        logger.warn("Meguru: HTTP", code, "for", Net.redactUrl(url_str))
        return code, headers, nil
    end
    return code, headers, table.concat(sink)
end

-- GET to a file: true, or nil plus "network"/"http"/"write".
-- Exists because get's total timeout cannot bound it (see updating.md).
-- A partial file is removed on failure, so it cannot read as complete.
function Net.getToFile(url_str, path, opts)
    opts = opts or {}
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil, "network"
    end
    local handle, open_err = io.open(path, "wb")
    if not handle then
        -- "wb": "w" would translate line endings and corrupt the archive.
        logger.warn("Meguru: cannot write to", path, ":", tostring(open_err))
        return nil, "write"
    end

    local timeout = TIMEOUTS[opts.timeout or "download"] or TIMEOUTS.download
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = url_str,
            headers = {
                ["Accept"] = opts.accept or "*/*",
                ["Accept-Encoding"] = "identity",
            },
            sink = socketutil.file_sink(handle),
        })
    end)
    socketutil:reset_timeout()

    -- Normally a no-op (file_sink closes); pcall because closing twice raises.
    pcall(handle.close, handle)

    if not ok or type(code) ~= "number" or code ~= 200 then
        logger.warn("Meguru: could not download", Net.redactUrl(url_str),
            "(", tostring(code), ")")
        pcall(os.remove, path)
        return nil, (type(code) == "number") and "http" or "network"
    end
    return true
end

-- opdsparser names the result after the root element, so unwrap .feed.
function Net.feedFrom(root)
    if type(root) ~= "table" then
        return nil
    end
    if type(root.feed) == "table" then
        return root.feed
    end
    return root
end

-- Several names: KOReader ships json or rapidjson, never guaranteed both.
-- Looked up once and remembered: what a build can decode does not change.
-- encode required too, for the updater's release cache.
local json_decoder, json_looked
function Net.jsonDecoder()
    if json_looked then
        return json_decoder
    end
    json_looked = true
    for _, name in ipairs({ "rapidjson", "json", "cjson" }) do
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table"
            and type(mod.decode) == "function" and type(mod.encode) == "function" then
            json_decoder = mod
            logger.dbg("Meguru: JSON through", name)
            return json_decoder
        end
    end
    logger.warn("Meguru: this build has no JSON decoder"
        .. " (tried rapidjson, json, cjson) - anything that reads a server's JSON"
        .. " answer will do nothing")
    return nil
end

-- Parses an Atom body to the flat feed shape; opdsparser required at call time.
function Net.parseFeed(body)
    if type(body) ~= "string" or body == "" or body:match("^%s*{") then
        return nil
    end
    local ok, OPDSParser = pcall(require, "opdsparser")
    if not ok or type(OPDSParser) ~= "table" or type(OPDSParser.parse) ~= "function" then
        logger.warn("Meguru: built-in OPDS feed parser unavailable")
        return nil
    end
    local ok_parse, root = pcall(OPDSParser.parse, OPDSParser, body)
    if not ok_parse or type(root) ~= "table" then
        return nil
    end
    -- A valid empty feed is returned as one, not called a parse failure.
    return Net.feedFrom(root)
end

-- Returns feed, or nil plus "network"/"http"/"empty" so a caller can decide.
function Net.fetchFeed(url_str, opts)
    if type(url_str) ~= "string" or url_str == "" then
        return nil, "network"
    end
    opts = opts or {}
    local code, _, body = Net.get(url_str, {
        username = opts.username,
        password = opts.password,
        accept = opts.accept or Net.FEED_ACCEPT,
        timeout = opts.timeout or "feed",
    })
    if code ~= 200 or not body then
        return nil, (code and "http") or "network"
    end
    local feed = Net.parseFeed(body)
    if not feed then
        return nil, "http" -- 200 with an unparseable body: a truncated response
    end
    if type(feed.entry) ~= "table" then
        -- "empty" is its own reason: a filtered feed is legitimately empty.
        return nil, "empty"
    end
    return feed
end

return Net
