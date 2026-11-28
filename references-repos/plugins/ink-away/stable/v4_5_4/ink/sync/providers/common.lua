--[[
What the cloud providers share (see ink/sync/providers.lua): form encoding, random
bytes, times, and the signed-in client that keeps its access token fresh. A
provider module sets HOSTS and TOKEN_URL, and gives `replyError(reply, ctx)` (what
a reply means as an error) and `refreshForm(self)` (the fields that renew a
token); `Common.client(Class)` then gives it :refresh() and :call(spec).
]]

local Errors = require("ink/sync/errors")
local Http = require("ink/sync/http")
local Json = require("ink/sync/json")

local Common = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- Bytes as URL-safe base64 without padding.
function Common.base64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
        if b then out[#out + 1] = B64:sub(c3 + 1, c3 + 1) end
        if c then out[#out + 1] = B64:sub(c4 + 1, c4 + 1) end
    end
    return table.concat(out)
end

-- Random bytes: the system's source if there is one.
function Common.randomBytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

function Common.urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- A path with each part encoded and the slashes kept.
function Common.urlpath(p)
    return (tostring(p):gsub("[^/]+", Common.urlencode))
end

-- A table as a form body (or query string), keys in order.
function Common.form(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do parts[#parts + 1] = Common.urlencode(k) .. "=" .. Common.urlencode(t[k]) end
    return table.concat(parts, "&")
end

-- "2026-11-03T12:30:00Z" (a fraction of a second is ignored) as seconds since 1970 (UTC).
function Common.parseTime(s)
    local y, mo, d, h, mi, se = tostring(s or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    local a = math.floor((14 - mo) / 12)
    local yy, mm = y + 4800 - a, mo + 12 * a - 3
    local jdn = d + math.floor((153 * mm + 2) / 5) + 365 * yy + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) - 32045
    return (jdn - 2440588) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end

-- A reply's JSON body as a table ({} when it is not JSON).
function Common.body(reply)
    local v = Json.decode(reply and reply.body or "")
    return type(v) == "table" and v or {}
end

-- Give `Class` the signed-in client: :refresh() and :call(spec).
function Common.client(Class)
    -- Renew the access token from the refresh token.
    function Class:refresh()
        local a = self.account
        if not (a and a.refresh_token) then return nil, Errors.make("IA-S201") end
        local reply, err = Http.request({
            url = Class.TOKEN_URL, method = "POST", hosts = Class.HOSTS,
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
            body = Common.form(self:refreshForm()),
        })
        if not reply then return nil, err end
        if reply.code ~= 200 then return nil, Class.replyError(reply, "refresh") end
        local t = Json.decode(reply.body)
        if type(t) ~= "table" or not t.access_token then return nil, Errors.make("IA-S304", "token reply") end
        a.access_token = t.access_token
        if t.refresh_token then a.refresh_token = t.refresh_token end   -- (some services hand out a new one)
        a.expires_at = self.now() + (tonumber(t.expires_in) or 3600)
        if self.save then pcall(self.save, a) end
        return true
    end

    -- Make a request with the access token (`spec.no_auth` leaves it off); renew
    -- it first if it ran out, and once more if the service says it did.
    function Class:call(spec)
        local a = self.account
        if not a then return nil, Errors.make("IA-S201") end
        if not spec.no_auth and (not a.access_token or (a.expires_at or 0) <= self.now() + 60) then
            local ok, err = self:refresh()
            if not ok then return nil, err end
        end
        for attempt = 1, 2 do
            spec.hosts = Class.HOSTS
            spec.headers = spec.headers or {}
            if not spec.no_auth then spec.headers["Authorization"] = "Bearer " .. a.access_token end
            local reply, err = Http.request(spec)
            if not reply then return nil, err end
            if reply.code == 401 and attempt == 1 and not spec.no_auth then
                local ok, rerr = self:refresh()
                if not ok then return nil, rerr end
            else
                return reply
            end
        end
    end
end

return Common
