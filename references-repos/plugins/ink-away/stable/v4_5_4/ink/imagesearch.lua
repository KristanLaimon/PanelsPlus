--[[
Online image search for the image tool: a small client over keyless image APIs,
used only when the reader chooses to browse online.

The pure pieces (URL building, query encoding, JSON normalising) come first and
are unit-tested without KOReader. The network fetch and image decoding require
KOReader modules lazily, so the file still loads in the tests.

Providers (both keyless, HTTPS, safe for work):
  * openverse: api.openverse.org, a broad catalogue (Flickr, museums, galleries);
    PNG filter extension=png, mature=false by default.
  * commons: the Wikimedia Commons MediaWiki API (the one KOReader's Wikipedia
    lookup uses), with the most reliable thumbnails; PNG filter
    filemime:image/png.

Web search engines (DuckDuckGo, Bing, Google) sign their image endpoints with
in-page JavaScript, which a plain HTTP client cannot run, and answer 403.

"Transparent only" maps to a PNG filter: PNG results in these catalogues are
mostly transparent graphics. Real per-pixel alpha is only known after decoding
the full image, which is too costly for a grid.
]]

local ImageSearch = {}

ImageSearch.PAGE_SIZE = 6        -- results per page (a 3 by 2 grid; images are
                                 -- fetched one at a time in the main loop, so a
                                 -- small page stays responsive)
ImageSearch.THUMB_MAX = 240      -- px, longest side of a grid thumbnail
ImageSearch.FULL_MAX  = 1400     -- px cap on the added image when full resolution is off
ImageSearch.USER_AGENT = "InkAway/3 KOReader plugin (https://github.com/EmirErtorer/ink-away.koplugin)"
-- A browser-like agent for the image downloads: some image hosts reject or
-- throttle a plainly non-browser agent.
ImageSearch.BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

-- The two catalogues, in the order searchPage tries them when no provider is
-- given (Openverse first, for its broader mix).
ImageSearch.PROVIDERS = { "openverse", "commons" }

-- URL-encode one component (keep RFC 3986 unreserved, percent-escape the rest).
function ImageSearch.urlencode(s)
    return (tostring(s or ""):gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build the search request URL.
--   opts = { png_only = bool, page = N (1-based), page_size = N }
function ImageSearch.buildURL(provider, query, opts)
    opts = opts or {}
    local page = math.max(1, tonumber(opts.page) or 1)
    local size = tonumber(opts.page_size) or ImageSearch.PAGE_SIZE
    if provider == "commons" then
        local search = query or ""
        if opts.png_only then search = search .. " filemime:image/png" end
        local offset = (page - 1) * size
        return table.concat({
            "https://commons.wikimedia.org/w/api.php",
            "?action=query&format=json&generator=search",
            "&gsrsearch=", ImageSearch.urlencode(search),
            "&gsrnamespace=6&gsrlimit=", tostring(size),
            "&gsroffset=", tostring(offset),
            "&prop=imageinfo&iiprop=url|size|mime",
            "&iiurlwidth=", tostring(ImageSearch.THUMB_MAX),
        })
    end
    -- default: Openverse
    local url = table.concat({
        "https://api.openverse.org/v1/images/",
        "?q=", ImageSearch.urlencode(query or ""),
        "&mature=false",
        "&page=", tostring(page),
        "&page_size=", tostring(size),
    })
    if opts.png_only then url = url .. "&extension=png" end
    return url
end

-- The JSON decoder: rapidjson if present (fast C), else KOReader's bundled json.
-- Cached. Tests pass their own decoder to parse() and never hit this.
function ImageSearch._decoder()
    if ImageSearch.__decode then return ImageSearch.__decode end
    local ok, rj = pcall(require, "rapidjson")
    if ok and type(rj) == "table" and rj.decode then
        ImageSearch.__decode = function(s) return rj.decode(s) end
    else
        local j = require("json")
        ImageSearch.__decode = function(s) return j.decode(s) end
    end
    return ImageSearch.__decode
end

-- Normalise a provider's JSON body into a uniform shape:
--   { results = { { thumb, full, w, h, mime, title, license, source } ... },
--     page_count = N or nil, total = N }
-- `decode` is optional (an injected decoder for tests). Returns nil, err on
-- failure. Never throws.
function ImageSearch.parse(provider, body, decode)
    if type(body) ~= "string" or body == "" then return nil, "empty response" end
    decode = decode or ImageSearch._decoder()
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then return nil, "bad json" end
    local out = { results = {}, total = 0 }
    if provider == "commons" then
        local pages = data.query and data.query.pages
        if type(pages) == "table" then
            for _, pg in pairs(pages) do
                local ii = pg.imageinfo and pg.imageinfo[1]
                if type(ii) == "table" and ii.thumburl and ii.url then
                    out.results[#out.results + 1] = {
                        thumb = ii.thumburl, full = ii.url,
                        w = tonumber(ii.width), h = tonumber(ii.height), mime = ii.mime,
                        title = pg.title, source = ii.descriptionurl,
                    }
                end
            end
        end
        return out   -- commons has no clean page_count; caller pages until empty
    end
    -- openverse
    out.total = tonumber(data.result_count) or 0
    out.page_count = tonumber(data.page_count)
    if type(data.results) == "table" then
        for _, r in ipairs(data.results) do
            if type(r) == "table" and r.url then
                out.results[#out.results + 1] = {
                    thumb = r.thumbnail or r.url, full = r.url,
                    w = tonumber(r.width), h = tonumber(r.height),
                    mime = r.filetype and ("image/" .. tostring(r.filetype)) or nil,
                    title = r.title, license = r.license, source = r.foreign_landing_url,
                }
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Network and decoding (lazy KOReader requires; not exercised by the unit tests)
------------------------------------------------------------------------------

-- A blocking but time-bounded HTTPS GET into memory, like KOReader's Wikipedia
-- fetch (socket.http routes https, socketutil bounds the time). Falls back to
-- curl where LuaSec is unreliable. Returns body, or nil and an error.
function ImageSearch.httpGet(url, block_to, total_to, headers)
    headers = headers or { ["User-Agent"] = ImageSearch.USER_AGENT, ["Accept"] = "*/*" }
    local ok_http, http = pcall(require, "socket/http")
    local ok_su, socketutil = pcall(require, "socketutil")
    local ok_sk, socket = pcall(require, "socket")
    if ok_http and ok_su and ok_sk and http and socketutil and socket then
        local sink_t = {}
        socketutil:set_timeout(block_to or socketutil.LARGE_BLOCK_TIMEOUT,
            total_to or socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return socket.skip(1, http.request{
                url = url, method = "GET", headers = headers,
                sink = socketutil.table_sink(sink_t),
            })
        end)
        socketutil:reset_timeout()
        if ok and type(code) == "number" then          -- a real HTTP response arrived
            local body = table.concat(sink_t)
            if code >= 200 and code <= 299 and body ~= "" then return body end
            return nil, "http " .. tostring(code)       -- a valid non-2xx: no point trying curl
        end
        -- only a socket or SSL failure (an error, or no numeric code) falls through
    end
    return ImageSearch._curlGet(url, headers)
end

-- A last-resort GET through the system curl. Fully guarded, so it returns nil
-- where there is no shell.
function ImageSearch._curlGet(url, headers)
    local ok, body = pcall(function()
        local ua = (headers and headers["User-Agent"]) or ImageSearch.USER_AGENT
        local ref = headers and headers["Referer"]
        local refarg = ref and string.format(" -H %q", "Referer: " .. ref) or ""
        local cmd = string.format(
            "curl -fsSL --connect-timeout 10 --max-time 30 -A %q%s %q 2>/dev/null", ua, refarg, url)
        local h = io.popen(cmd, "r")
        if not h then return nil end
        local data = h:read("*a")
        h:close()
        return data
    end)
    if ok and type(body) == "string" and body ~= "" then return body end
    return nil, "network unavailable"
end

-- Decode image bytes to a BlitBuffer, scaled so its longest side is at most
-- max_side (nil for no scaling). Returns the buffer or nil.
function ImageSearch.decode(bytes, max_side)
    if type(bytes) ~= "string" or bytes == "" then return nil end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return nil end
    local ok, bb = pcall(function() return RenderImage:renderImageData(bytes, #bytes, false) end)
    if not ok or not bb then return nil end
    if max_side then
        local w, h = bb:getWidth(), bb:getHeight()
        local m = math.max(w, h)
        if m > max_side and m > 0 then
            local s = max_side / m
            local sok, sbb = pcall(function()
                return RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * s)),
                    math.max(1, math.floor(h * s)), true)
            end)
            if sok and sbb then return sbb end
        end
    end
    return bb
end

-- Fetch and parse one page of search results in the caller's process, under
-- Trapper. opts.provider ("openverse" or "commons") queries just that catalogue;
-- without it both are tried in PROVIDERS order. Returns
--   { net_ok, provider, page_count, results = { {thumb, full, w, h, mime,
--     title, source} ... } }
-- with plain URLs; the caller downloads the thumbnails. It runs in the main
-- process because LuaSec's SSL can crash a forked one on some builds (beyond
-- pcall's reach); small pages and short timeouts keep it responsive.
function ImageSearch.searchPage(query, opts)
    opts = opts or {}
    local order
    if opts.provider == "openverse" or opts.provider == "commons" then
        order = { opts.provider }
    else
        order = ImageSearch.PROVIDERS
    end
    local any_response = false
    for _, provider in ipairs(order) do
        local body = ImageSearch.httpGet(ImageSearch.buildURL(provider, query, opts))
        if type(body) == "string" then
            any_response = true
            local parsed = ImageSearch.parse(provider, body)
            if parsed and #parsed.results > 0 then
                return { net_ok = true, provider = provider,
                    page_count = parsed.page_count, results = parsed.results }
            end
        end
    end
    return { net_ok = any_response, results = {} }
end

return ImageSearch
