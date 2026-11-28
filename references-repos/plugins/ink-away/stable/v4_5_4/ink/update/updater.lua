--[[
Updates: asking GitHub what there is, and installing it, for the Updates sheet
(ink/view/updates.lua) to show. What it learns is kept here and in the
settings, not in a view, so a check that ends after Ink Away has closed is
still known the next time it opens.

When it checks: when the reader asks, and on its own at most once a day, only
when Ink Away opens and Wi-Fi is already connected (it never turns Wi-Fi on).
A check is one request, run in a background process that ends with it (see
ink/update/net.lua); nothing keeps running between checks.

Settings (all "inkaway_update_*"):
  auto       check once a day (on by default)
  pre        tell about prereleases too (off by default)
  last       when the last check succeeded; tried: when one was last tried
  known      what the last check found, { stable, pre, current }, so the
             Settings button and the toolbar's dot show without a check
  told       the version the reader was last told about (told once)
  seen       the version whose offer the reader has opened the sheet on
  installed  the version just installed: once it runs, the previous copy goes
]]

local Install = require("ink/update/install")
local Net = require("ink/update/net")
local Policy = require("ink/update/policy")

local Updater = {
    busy = nil,          -- "checking" or "installing" while one runs
    offers = nil,        -- the last check's offers (see Policy.offers)
    error = nil,         -- why the last check failed
    installed = nil,     -- the version installed this session, waiting for a restart
}

local function G() return rawget(_G, "G_reader_settings") end
local function get(k)
    local g = G()
    return g and g:readSetting("inkaway_update_" .. k)
end
local function set(k, v)
    local g = G()
    if not g then return end
    if v == nil then g:delSetting("inkaway_update_" .. k) else g:saveSetting("inkaway_update_" .. k, v) end
end
Updater.get, Updater.set = get, set

-- The plugin's folder (with a trailing slash) and the version in its _meta.lua.
function Updater.version(plugin_dir)
    local f = io.open((plugin_dir or "./") .. "_meta.lua", "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s and s:match('version%s*=%s*"([^"]+)"') or nil
end

function Updater.autoOn() return get("auto") ~= false end
function Updater.preOn() return get("pre") == true end

-- The release (and, with prereleases on, the prerelease) newer than `current`
-- that the last check found, as a version string, or nil: what the dot and
-- the button tell about, without a check.
function Updater.available(current)
    local k = get("known")
    if type(k) ~= "table" or k.current ~= current then return nil end
    local best
    if type(k.stable) == "string" and Policy.compare(k.stable, current) == 1 then best = k.stable end
    if Updater.preOn() and type(k.pre) == "string" and Policy.compare(k.pre, current) == 1
            and (not best or Policy.compare(k.pre, best) == 1) then best = k.pre end
    return best
end

-- Has the reader yet to open the sheet on what is available?
function Updater.unseen(current)
    local v = Updater.available(current)
    return v ~= nil and get("seen") ~= v
end

local function remember(offers, current)
    set("last", os.time())
    set("known", { current = current, stable = offers.stable and offers.stable.version or nil,
        pre = offers.pre and offers.pre.version or nil })
end

-- Ask GitHub what there is for version `current`; done(offers) or
-- done(nil, why). `asked`: the reader asked (see Net.get's inline). Returns
-- false when a check could not start (one is running, or no background
-- process could be made).
function Updater.check(current, done, asked)
    if Updater.busy then return false end
    Updater.busy = "checking"
    Net.sweep()
    local started = Net.get(Policy.API, Policy.MAX_FEED, 40, function(path, why)
        Updater.busy = nil
        if not path then
            Updater.error = why or "no answer"
            return done(nil, Updater.error)
        end
        local f = io.open(path, "rb")
        local body = f and f:read("*a")
        if f then f:close() end
        os.remove(path)
        local ok, list = pcall(function() return require("json").decode(body or "") end)
        if not ok or type(list) ~= "table" then
            Updater.error = "GitHub's answer could not be read"
            return done(nil, Updater.error)
        end
        if list.message then   -- an error from the API (a rate limit, say)
            Updater.error = tostring(list.message)
            return done(nil, Updater.error)
        end
        Updater.offers, Updater.error = Policy.offers(list, current), nil
        remember(Updater.offers, current)
        done(Updater.offers)
    end, asked)
    if not started then
        Updater.busy = nil
        Updater.error = "a check could not start"
    end
    return started
end

-- Is an automatic check due now?
function Updater.due()
    return Updater.autoOn() and not Updater.busy and not Updater.installed
        and Policy.due(os.time(), get("last"), get("tried"))
end

-- Check on its own if one is due and Wi-Fi is already connected, then call
-- found(version) when there is something the reader has not been told about.
-- Returns true when a check started.
function Updater.autoCheck(current, found)
    if not Updater.due() then return false end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not (ok and NetworkMgr and NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then return false end
    set("tried", os.time())
    return Updater.check(current, function(offers)
        if not offers then return end
        local v = Updater.available(current)
        if v and get("told") ~= v then
            set("told", v)
            found(v)
        end
    end)
end

-- Download `release` (from offers) and put it in place of the plugin folder
-- `plugin` (no trailing slash); done(true) or done(nil, why). The new version
-- runs once KOReader restarts.
function Updater.install(release, plugin, done)
    if Updater.busy then return done(nil, "busy") end
    local stage, backup = Install.paths(plugin)
    if not stage then return done(nil, "the plugin folder was not found") end
    Updater.busy = "installing"
    local started = Net.get(release.url, release.size, 180, function(zip, why)
        if not zip then
            Updater.busy = nil
            return done(nil, why or "the download failed")
        end
        local ok, res, err = pcall(Install.prepare, zip, stage, release)
        os.remove(zip)
        if ok and res then ok, res, err = pcall(Install.swap, plugin, stage, backup) end
        Updater.busy = nil
        if not (ok and res) then
            Install.removeTree(stage)
            return done(nil, tostring(ok and err or res))
        end
        Updater.installed = release.version
        set("installed", release.version)
        local g = G()
        if g and g.flush then g:flush() end
        done(true)
    end, true)
    if not started then
        Updater.busy = nil
        done(nil, "the download could not start")
    end
end

-- At start: once the version just installed runs, its predecessor's folder
-- (and anything staged) goes.
function Updater.cleanup(plugin, current)
    local ok, cleaned = pcall(Install.cleanup, plugin, current, get("installed"))
    if ok and cleaned then set("installed", nil) end
end

return Updater
