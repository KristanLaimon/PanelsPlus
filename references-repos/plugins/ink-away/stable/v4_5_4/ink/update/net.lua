--[[
Updates, the network: a request to GitHub runs in a short-lived background
process (KOReader's runInSubProcess), which writes what it fetched to a file
and exits; Ink Away only looks every half second whether it is done, and stops
looking once it is. So KOReader never waits on the network, nothing runs once
a check is over, and a dead connection costs one process that is stopped at
the deadline.

Only GitHub's hosts are spoken to (Policy.HOSTS), over HTTPS, following at most
five redirects, and a download stops at its size limit.
]]

local Policy = require("ink/update/policy")

local Net = {}

local POLL = 0.5          -- seconds between looks at a running request
local serial = 0

-- The folder requests write into: KOReader's cache, "ink away updates".
function Net.dir()
    local ok, DataStorage = pcall(require, "datastorage")
    local base = ok and DataStorage:getDataDir() or "."
    local dir = base .. "/cache/inkaway-update"
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok then
        if lfs.attributes(base .. "/cache", "mode") ~= "directory" then lfs.mkdir(base .. "/cache") end
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    end
    return dir
end

-- In the background process: fetch `url` into `path`, at most `limit` bytes.
-- Returns true, or nil and why not.
function Net.fetch(url, path, limit)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    for _hop = 1, 6 do
        if not Policy.allowed(url) then return nil, "not a GitHub address: " .. tostring(url) end
        local f, ferr = io.open(path, "wb")
        if not f then return nil, ferr end
        local got, over = 0, false
        local sink = function(chunk, err)
            if chunk then
                got = got + #chunk
                if got > limit then over = true; return nil, "too large" end
                return f:write(chunk) and 1 or nil
            end
            return err == nil and 1 or nil, err
        end
        socketutil:set_timeout(15, 90)
        local code, headers = socket.skip(1, http.request{
            url = url, method = "GET", redirect = false, sink = sink,
            headers = { ["User-Agent"] = "Ink-Away-KOReader-plugin", ["Accept"] = "application/vnd.github+json" },
        })
        socketutil:reset_timeout()
        f:close()
        if over then os.remove(path); return nil, "larger than expected" end
        if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
                and type(headers) == "table" and headers.location then
            os.remove(path)
            url = headers.location
        elseif code == 200 then
            return true
        else
            os.remove(path)
            return nil, (type(code) == "number" and ("HTTP " .. code)) or tostring(code or "no connection")
        end
    end
    os.remove(path)
    return nil, "too many redirects"
end

-- Fetch `url` into a new file in the background, then call done(path) or
-- done(nil, why). `timeout` (seconds) stops a request that hangs. With
-- `inline` (a check or download the reader asked for), a system that gives no
-- background process, or ends it before it reports, has the request made right
-- here instead, KOReader waiting on it as on its own update check; without it,
-- returns false when no background process could be started (done is not
-- called then).
function Net.get(url, limit, timeout, done, inline)
    local util = require("ffi/util")
    local UIManager = require("ui/uimanager")
    serial = serial + 1
    local path = string.format("%s/%d-%d", Net.dir(), os.time(), serial)
    local status = path .. ".status"
    os.remove(path); os.remove(status)
    local function here()
        UIManager:scheduleIn(0.2, function()   -- after the sheet shows it is busy
            local ok, res, why = pcall(Net.fetch, url, path, limit)
            if ok and res then return done(path) end
            os.remove(path)
            done(nil, tostring(ok and why or res))
        end)
        return true
    end
    local pid = util.runInSubProcess(function()
        local ok, res, why = pcall(Net.fetch, url, path, limit)
        local f = io.open(status .. ".part", "wb")
        if f then
            f:write((ok and res) and "ok" or tostring(ok and why or res))
            f:close()
            os.rename(status .. ".part", status)
        end
    end, false, false)
    if not pid then
        if inline then return here() end
        return false
    end
    local waited = 0
    local function finish(p, why)
        os.remove(status)
        done(p, why)
    end
    local function poll()
        if not util.isSubProcessDone(pid) then
            waited = waited + POLL
            if waited >= timeout then
                util.terminateSubProcess(pid)
                UIManager:scheduleIn(1, function() util.isSubProcessDone(pid) end)   -- collect it
                os.remove(path)
                return finish(nil, "timed out")
            end
            return UIManager:scheduleIn(POLL, poll)
        end
        local f = io.open(status, "rb")
        local s = f and f:read("*a")
        if f then f:close() end
        if s == "ok" then return finish(path) end
        os.remove(path)
        if not s and inline then return here() end   -- the process ended without a word
        finish(nil, s or "the request stopped")
    end
    UIManager:scheduleIn(POLL, poll)
    return true
end

-- Remove what earlier requests left in the folder (a crash, a dead battery):
-- anything older than a day.
function Net.sweep()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return end
    local dir = Net.dir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local now = os.time()
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" and now - (a.modification or now) > Policy.DAY then os.remove(p) end
        end
    end
end

return Net
