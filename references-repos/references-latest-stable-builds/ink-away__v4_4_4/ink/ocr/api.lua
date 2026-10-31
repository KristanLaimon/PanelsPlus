local Api = {}

local MAX_PNG = 4 * 1024 * 1024
local MAX_RESPONSE = 256 * 1024

local function hasControl(s)
    return s:find("[%z\1-\31\127]") ~= nil
end

local function parseURL(url)
    if type(url) ~= "string" or #url > 2048 or hasControl(url) then return nil end
    local authority, path = url:match("^https://([^/]*)(.*)$")
    if not authority or authority == "" or authority:find("[@?#\\%s]") then return nil end
    path = path == "" and "/" or path
    if path:find("[%c%s?#\\]") then return nil end

    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([%da-fA-F:.]+)%]:(%d+)$")
        if not host then host = authority:match("^%[([%da-fA-F:.]+)%]$") end
        if not host or not host:find(":", 1, true) then return nil end
    else
        host, port = authority:match("^([^:]+):(%d+)$")
        if not host then
            if authority:find(":", 1, true) then return nil end
            host = authority
        end
        if #host > 253 or host:sub(1, 1) == "." or host:sub(-1) == "." then return nil end
        for label in host:gmatch("[^.]+") do
            if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-"
                    or not label:match("^[%w%-]+$") then return nil end
        end
        if host:find("..", 1, true) then return nil end
    end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return nil end
    local base = path:gsub("/+$", "")
    if base == "" then base = "/v1" end
    if base:match("/chat/completions$") then
        if base:match("/chat/completions/chat/completions$") then return nil end
    else
        base = base .. "/chat/completions"
    end
    return "https://" .. authority .. base, host:lower()
end

function Api.validate(input)
    if type(input) ~= "table" then return nil, "Enter a valid HTTPS endpoint, API key, and model." end
    local endpoint, host = parseURL(input.url)
    if not endpoint or type(input.key) ~= "string" or input.key == ""
            or #input.key > 4096 or hasControl(input.key)
            or type(input.model) ~= "string" or input.model == ""
            or #input.model > 256 or hasControl(input.model) then
        return nil, "Enter a valid HTTPS endpoint, API key, and model."
    end
    return { url = endpoint, host = host, key = input.key, model = input.model }
end

local function caBundle(https)
    if type(https) ~= "table" or type(https.request) ~= "function"
            or not debug or not debug.getinfo then return nil end
    local ok, info = pcall(debug.getinfo, https.request, "S")
    local source = ok and info and info.source or ""
    -- KOReader's packaged package.path can be relative (the native runtime
    -- reports @./common/ssl/https.lua). Preserve that root: require() resolved
    -- the module from the process cwd, so its sibling data bundle is relative
    -- to the same runtime root. Never fall back to a host OS CA store.
    local root = source:match("^@(.*)/common/ssl/https%.lua$")
    if not root then
        root = source:match("^@(.*)common/ssl/https%.lua$")
        if root == "" then root = "." end
    end
    if not root then return nil end
    local path = root .. "/data/ca-bundle.crt"
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    return path
end

local function dnsMatch(host, pattern)
    host, pattern = host:lower(), pattern:lower()
    if pattern == host then return true end
    if pattern:sub(1, 2) ~= "*." then return false end
    local suffix = pattern:sub(2)
    local prefix = host:sub(1, #host - #suffix)
    return #prefix > 0 and prefix:sub(-1) ~= "." and prefix:find(".", 1, true) == nil
            and host:sub(-#suffix) == suffix
end

local function isIPHost(host)
    if host:find(":", 1, true) then return true end -- bracketed IPv6 is stripped by parseURL
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    return a ~= nil and tonumber(a) <= 255 and tonumber(b) <= 255
            and tonumber(c) <= 255 and tonumber(d) <= 255
end

local function certificateMatches(cert, host)
    if not cert or type(cert.extensions) ~= "function" then return false end
    local ok, extensions = pcall(cert.extensions, cert)
    local san = ok and type(extensions) == "table"
            and (extensions["2.5.29.17"] or extensions.subjectAltName)
    if type(san) ~= "table" then return false end
    if isIPHost(host) then
        local ips = san.iPAddress or san.IP
        if type(ips) == "table" then
            for _, ip in ipairs(ips) do
                if type(ip) == "string" and ip:lower() == host:lower() then return true end
            end
        end
    else
        local names = san.dNSName or san.DNS
        if type(names) == "table" then
            for _, name in ipairs(names) do
                if type(name) == "string" and dnsMatch(host, name) then return true end
            end
        end
    end
    return false
end

local function createTLS(socket, ssl, ca_path, expected_host)
    return function()
        local tcp = socket.tcp()
        local conn = { sock = tcp }
        function conn:settimeout(timeout, mode)
            if mode then return self.sock:settimeout(timeout, mode) end
            local block_ok, block_err = self.sock:settimeout(15, "b")
            if not block_ok then return nil, block_err end
            return self.sock:settimeout(90, "t")
        end
        function conn:close(...)
            if self.sock and type(self.sock.close) == "function" then
                return self.sock:close(...)
            end
            return 1
        end
        function conn:connect(host, port)
            if host:lower() ~= expected_host then return nil, "host mismatch" end
            local ok, err = self.sock:connect(host, port)
            if not ok then return nil, err end
            local tls, tls_err = ssl.wrap(self.sock, {
                mode = "client", protocol = "any",
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
                verify = { "peer" }, cafile = ca_path,
            })
            if not tls then return nil, tls_err end
            self.sock = tls
            local block_ok = tls:settimeout(15, "b")
            local total_ok = tls:settimeout(90, "t")
            if not block_ok or not total_ok then return nil, "TLS timeout setup failed" end
            if not isIPHost(host) then
                -- LuaSec's sni() sets the extension but returns nil on
                -- success in the bundled runtime, so only a thrown error is
                -- evidence of failure.
                local sni_ok = pcall(tls.sni, tls, host)
                if not sni_ok then return nil, "TLS SNI failed" end
            end
            local handshake_ok = tls:dohandshake()
            if not handshake_ok then return nil, "TLS verification failed" end
            local cert = tls:getpeercertificate()
            if not certificateMatches(cert, expected_host) then return nil, "TLS hostname mismatch" end
            local meta = getmetatable(tls)
            local methods = type(meta) == "table" and meta.__index
            if type(methods) == "table" then
                for name, method in pairs(methods) do
                    if type(method) == "function" and conn[name] == nil then
                        local fn = method
                        conn[name] = function(_, ...)
                            return fn(tls, ...)
                        end
                    end
                end
            end
            return 1
        end
        return conn
    end
end

local function encodeRequest(config, png, mime, json)
    local encoded = mime.b64(png):gsub("%s", "")
    local body = json.encode({
        model = config.model,
        messages = {{ role = "user", content = {
            { type = "text", text = "OCR:" },
            { type = "image_url", image_url = { url = "data:image/png;base64," .. encoded } },
        } }},
        stream = false,
        max_tokens = 2048,
    })
    if type(body) ~= "string" then return nil end
    return body
end

function Api.request(config, png_bytes)
    local normalized = Api.validate(config)
    if not normalized or normalized.url ~= config.url or normalized.host ~= config.host
            or type(png_bytes) ~= "string" or #png_bytes < 20 or #png_bytes > MAX_PNG
            or png_bytes:sub(1, 8) ~= "\137PNG\r\n\26\n"
            or png_bytes:sub(-8) ~= "IEND\174B\96\130" then
        return nil, "Invalid OCR request."
    end
    local ok_modules, http, socket, ssl, socketutil, mime, json, ltn12, https = pcall(function()
        return require("socket.http"), require("socket"), require("ssl"), require("socketutil"),
            require("mime"), require("json"), require("ltn12"), require("ssl.https")
    end)
    if not ok_modules then return nil, "HTTPS support is unavailable." end
    local ca_path = caBundle(https)
    if not ca_path or type(ssl.wrap) ~= "function" then return nil, "Verified HTTPS is unavailable." end
    if http.PROXY then return nil, "Verified HTTPS is unavailable." end

    local encoded, body = pcall(encodeRequest, config, png_bytes, mime, json)
    if not encoded or type(body) ~= "string" then return nil, "Could not prepare the OCR request." end
    local chunks, size, too_large = {}, 0, false
    local start = socket.gettime()
    local function sink(chunk)
        if chunk then
            size = size + #chunk
            if size > MAX_RESPONSE or socket.gettime() - start > 90 then
                too_large = size > MAX_RESPONSE
                return nil, too_large and "response too large" or "request timed out"
            end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local timeout_ok = pcall(socketutil.set_timeout, socketutil, 15, 90)
    if not timeout_ok then return nil, "Verified HTTPS is unavailable." end
    local call_ok, result, code, headers = pcall(http.request, {
        url = config.url, method = "POST", redirect = false,
        create = createTLS(socket, ssl, ca_path, config.host),
        source = ltn12.source.string(body), sink = sink,
        headers = {
            ["Authorization"] = "Bearer " .. config.key,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
    })
    pcall(socketutil.reset_timeout, socketutil)
    if not call_ok then return nil, "OCR request failed." end
    if too_large then return nil, "OCR response was too large." end
    if result ~= 1 or code ~= 200 or type(headers) ~= "table" then
        return nil, type(code) == "number" and ("OCR service returned HTTP " .. code .. ".")
                or "OCR request failed."
    end
    local length = headers["content-length"] or headers["Content-Length"]
    if length ~= nil then
        if type(length) ~= "string" or not length:match("^%d+$") or tonumber(length) ~= size then
            return nil, "OCR response was incomplete."
        end
    end
    local encoding = headers["content-encoding"] or headers["Content-Encoding"]
    if encoding ~= nil and (type(encoding) ~= "string" or encoding:lower() ~= "identity") then
        return nil, "Unsupported OCR response encoding."
    end
    local response = table.concat(chunks)
    if response == "" or #response > MAX_RESPONSE then return nil, "OCR response was empty or too large." end
    local decode_ok, decoded = pcall(json.decode, response)
    local extracted, text, finish_reason = pcall(function()
        local choice = type(decoded) == "table" and type(decoded.choices) == "table"
                and type(decoded.choices[1]) == "table" and decoded.choices[1]
        local message = choice and type(choice.message) == "table" and choice.message
        return message and message.content, choice and choice.finish_reason
    end)
    if not decode_ok or not extracted or finish_reason ~= "stop"
            or type(text) ~= "string" or text:gsub("%s", "") == "" then
        return nil, "OCR service returned an invalid response."
    end
    return text
end

return Api
