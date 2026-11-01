-- OPDS-PSE: a rel=stream link whose href carries {pageNumber}.
-- Page numbers are zero based; PSE.pageURL is the one place that rule lives.
local url = require("socket.url")

local Net = require("meguru/net")

local PSE = {}

PSE.STREAM_REL = "http://vaemendis.net/opds-pse/stream"

-- Match by key suffix: the namespace prefix varies (p5: on Kavita, pse:).
-- lastRead 0 is returned as 0, not nil: Kavita writes 0 for an unread chapter.
-- The number is not normalised here; page bases differ per driver by design.
function PSE.attributesFromLink(link)
    local count, last_read
    for key, value in pairs(link) do
        if type(key) == "string" then
            if key:sub(-6) == ":count" then
                count = tonumber(value)
            elseif key:sub(-9) == ":lastRead" then
                last_read = tonumber(value)
            end
        end
    end
    return count, last_read
end

-- A template without {pageNumber} is rejected: every page would be one URL.
function PSE.streamFromEntry(entry, base_url)
    for _, link in ipairs(entry and entry.link or {}) do
        if type(link) == "table" and type(link.href) == "string"
            and link.rel == PSE.STREAM_REL then
            local template = url.absolute(base_url, link.href)
            if template:find("{pageNumber}", 1, true) then
                local count, last_read = PSE.attributesFromLink(link)
                if count then
                    return template, count, last_read
                end
            end
        end
    end
    return nil
end

-- template must be restored, not a marker's raw <redacted> field (fetches 404).
-- Height is substituted only when screen_h is given; else {height} stays as-is.
function PSE.pageURL(template, zero_based_index, screen_w, screen_h)
    local ret = template:gsub("{pageNumber}", tostring(zero_based_index))
    ret = ret:gsub("{width}", tostring(screen_w))
    ret = ret:gsub("{maxWidth}", tostring(screen_w))
    if screen_h then
        ret = ret:gsub("{height}", tostring(screen_h))
        ret = ret:gsub("{maxHeight}", tostring(screen_h))
    end
    return ret
end

-- 3 pages of lead still counts as the same place (prefetch adds one).
-- Never subtract the lead: a position from another reader has none.
local SERVER_PAGE_TOLERANCE = 3

-- A missing local page is never the same place: the recording is all there is.
function PSE.samePlace(recorded, local_page)
    recorded, local_page = tonumber(recorded), tonumber(local_page)
    if not recorded or not local_page then
        return false
    end
    return recorded - local_page <= SERVER_PAGE_TOLERANCE
end

function PSE.fetchPage(url_str, opts)
    opts = opts or {}
    local code, _, body = Net.get(url_str, {
        username = opts.username,
        password = opts.password,
        accept = opts.accept or Net.IMAGE_ACCEPT,
        timeout = opts.timeout or "page",
    })
    if code ~= 200 or not body then
        return nil, code
    end
    return body, code
end

return PSE
