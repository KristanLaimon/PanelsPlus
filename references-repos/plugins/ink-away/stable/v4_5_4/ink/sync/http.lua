--[[
The network of the cloud sync (see ink/sync/). One call, `Http.request`, makes
one HTTPS request and gives back what the service answered, or an error with
an IA-S code. It speaks only to the hosts it is told to (the provider's), over a
connection whose certificate is checked against KOReader's bundle (the OCR
feature's code, see ink/ocr/api.lua): a sign-in token never goes over a
connection that was not verified. A body can come from a file and a reply can go
to a file, so a big notebook is never held in memory.

The part that touches the network is `Http.transport`; the tests replace it
with a pretend service, so everything above it runs headless.
]]

local Errors = require("ink/sync/errors")

local Http = {}

Http.TIMEOUT_BLOCK = 20
Http.TIMEOUT_TOTAL = 300
Http.MAX_BODY = 4 * 1024 * 1024   -- the largest reply read into memory (files go to disk)

-- The error for a failure the socket library words in its own way.
function Http.classify(why)
    local s = tostring(why or ""):lower()
    if s:find("timed out", 1, true) or s:find("timeout", 1, true) then return Errors.make("IA-S102", why) end
    if s:find("tls", 1, true) or s:find("certificate", 1, true) or s:find("ssl", 1, true)
            or s:find("handshake", 1, true) or s:find("verification", 1, true) then
        return Errors.make("IA-S103", why)
    end
    return Errors.make("IA-S101", why)
end

-- The real transport. spec: { url, host, method, headers, body, body_file, sink_file }.
-- Returns { code, headers (lower-case names), body } or nil and an error.
local function realTransport(spec)
    local ok, mods = pcall(function()
        return { http = require("socket.http"), socket = require("socket"), ssl = require("ssl"),
            socketutil = require("socketutil"), ltn12 = require("ltn12"), Api = require("ink/ocr/api"),
            https = require("ssl.https") }
    end)
    if not ok then return nil, Errors.make("IA-S103", "HTTPS is not available") end
    local m = mods
    local ca = m.Api.caBundle(m.https)
    if not ca or type(m.ssl.wrap) ~= "function" or m.http.PROXY then
        return nil, Errors.make("IA-S103", "verified HTTPS is not available")
    end
    local sink_f, sink_t, size = nil, {}, 0
    local sink
    if spec.sink_file then
        local f, err = io.open(spec.sink_file, "wb")
        if not f then return nil, Errors.make("IA-S402", err) end
        sink_f = f
        sink = m.ltn12.sink.file(f)
    else
        sink = function(chunk)
            if chunk then
                size = size + #chunk
                if size > Http.MAX_BODY then return nil, "reply too large" end
                sink_t[#sink_t + 1] = chunk
            end
            return 1
        end
    end
    local source, length
    if spec.body_file then
        local f, err = io.open(spec.body_file, "rb")
        if not f then if sink_f then sink_f:close() end return nil, Errors.make("IA-S401", err) end
        length = f:seek("end")
        f:seek("set", 0)
        source = m.ltn12.source.file(f)
    elseif spec.body then
        source = m.ltn12.source.string(spec.body)
        length = #spec.body
    end
    local headers = {}
    for k, v in pairs(spec.headers or {}) do headers[k] = v end
    if length then headers["Content-Length"] = tostring(length) end
    pcall(m.socketutil.set_timeout, m.socketutil, Http.TIMEOUT_BLOCK, Http.TIMEOUT_TOTAL)
    local call_ok, result, code, rheaders = pcall(m.http.request, {
        url = spec.url, method = spec.method or "POST", redirect = false,
        create = m.Api.verifiedTLS(m.socket, m.ssl, ca, spec.host),
        source = source, sink = sink, headers = headers,
    })
    pcall(m.socketutil.reset_timeout, m.socketutil)
    if sink_f then pcall(sink_f.close, sink_f) end
    if not call_ok then
        if sink_f then os.remove(spec.sink_file) end
        return nil, Http.classify(result)
    end
    if result ~= 1 then
        if sink_f then os.remove(spec.sink_file) end
        return nil, Http.classify(code)
    end
    local lower = {}
    for k, v in pairs(type(rheaders) == "table" and rheaders or {}) do lower[tostring(k):lower()] = v end
    return { code = code, headers = lower, body = sink_f and "" or table.concat(sink_t) }
end

Http.transport = realTransport

-- Is `host` one of `hosts`? An entry "*.example.com" stands for any host below it.
function Http.hostAllowed(hosts, host)
    for _i, h in ipairs(hosts or {}) do
        if h == host then return true end
        if h:sub(1, 2) == "*." and #host > #h - 1 and host:sub(-(#h - 1)) == h:sub(2) then return true end
    end
    return false
end

-- Make a request: spec as for the transport, plus `hosts`, the hosts allowed.
-- Returns the reply, or nil and an error. A reply of any status is returned as
-- it is; the caller decides what a 409 or 429 means.
function Http.request(spec)
    local host = spec.url:match("^https://([^/:]+)")
    if not host then return nil, Errors.make("IA-S503", "not an https address") end
    host = host:lower()
    if not Http.hostAllowed(spec.hosts, host) then return nil, Errors.make("IA-S503", "host not allowed: " .. host) end
    spec.host = host
    return Http.transport(spec)
end

return Http
