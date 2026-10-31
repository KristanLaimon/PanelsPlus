local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local FS = require("meguru/fs")
local Net = require("meguru/net")
local Paths = require("meguru/paths")

local Updater = {}

local GITHUB_OWNER = "Craftwork2720"
local GITHUB_REPO = "meguru"

-- The asset name the release workflow attaches; the two must agree.
local ASSET_NAME = "meguru.koplugin.zip"

-- Reused for an hour so a second tap does not spend a second API call.
local CACHE_TTL = 3600

-- Weekly: a courtesy, not a notification service.
local SILENT_INTERVAL = 7 * 24 * 60 * 60

-- The one top-level folder in the archive, staged by the workflow.
local ARCHIVE_ROOT = "meguru.koplugin"

-- More than main.lua: an entry point with no modules loads, then fails.
local REQUIRED_FILES = {
    "main.lua",
    "_meta.lua",
    "meguru/updater.lua",
    "meguru/net.lua",
}

-- Never defaulted: a version below every release makes each check offer one.
local installed_version

-- Once per process; init runs again for every book opened.
local startup_scheduled = false

local function apiUrl()
    return string.format("https://api.github.com/repos/%s/%s/releases/latest",
        GITHUB_OWNER, GITHUB_REPO)
end

local function cachePath()
    return DataStorage:getSettingsDir() .. "/meguru_update_cache.json"
end

-- All three live here, so one purgeDir clears a failed attempt.
-- Under the data dir so it shares a filesystem with the plugins folder (rename).
local function otaDir()
    return DataStorage:getFullDataDir() .. "/ota/meguru"
end

local function readCache()
    local handle = io.open(cachePath(), "r")
    if not handle then
        return nil
    end
    local raw = handle:read("*a")
    handle:close()
    local json = Net.jsonDecoder()
    if not json then
        return nil
    end
    local ok_decode, data = pcall(json.decode, raw)
    if not ok_decode or type(data) ~= "table" then
        return nil
    end
    return data
end

local function writeCache(data)
    local json = Net.jsonDecoder()
    if not json then
        return
    end
    local ok_encode, encoded = pcall(json.encode, data)
    if not ok_encode then
        return
    end
    if not FS.writeFile(cachePath(), encoded) then
        -- The next check just asks GitHub again; not worth telling the reader.
        logger.warn("Meguru: could not write the update cache")
    end
end

-- Written even on failure: the weekly gate reads this timestamp.
local function noteCheck(fields)
    local data = readCache() or {}
    data.checked_at = os.time()
    for key, value in pairs(fields or {}) do
        data[key] = value
    end
    writeCache(data)
end

local function cachedRelease()
    local data = readCache()
    if not data or not data.checked_at or not data.version then
        return nil
    end
    if (os.time() - data.checked_at) > CACHE_TTL then
        return nil
    end
    return data
end

local function silentCheckDue()
    local data = readCache()
    if not data or not data.checked_at then
        return true
    end
    return (os.time() - data.checked_at) > SILENT_INTERVAL
end

local function currentVersion()
    if installed_version then
        return installed_version
    end
    -- Fallback only; init hands the version over before anything asks.
    local dir = Paths.pluginDir()
    if not dir then
        return nil
    end
    local ok, meta = pcall(dofile, dir .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string"
        and meta.version ~= "" then
        return meta.version
    end
    return nil
end

-- `v1.2.0` and `1.2.0` must compare equal, so both sides come through here.
-- Parentheses drop gsub's second return (the replacement count).
local function canonical(version)
    return (tostring(version or ""):gsub("^v", ""))
end

-- Numeric per part, so 1.2.10 sorts above 1.2.9; a trailing suffix is ignored.
local function versionLessThan(a, b)
    local function parts(version)
        local out = {}
        for digits in tostring(version or ""):gmatch("(%d+)") do
            out[#out + 1] = tonumber(digits)
        end
        return out
    end
    local one, two = parts(a), parts(b)
    for i = 1, math.max(#one, #two) do
        local left, right = one[i] or 0, two[i] or 0
        if left < right then
            return true
        end
        if left > right then
            return false
        end
    end
    return false
end

local function toast(text, timeout)
    local widget = InfoMessage:new{ text = text, timeout = timeout or 4 }
    UIManager:show(widget)
    -- show only marks dirty; the fetch blocks before paint without this.
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then
        UIManager:close(widget)
    end
end

-- One sentence per reason: wifi and waiting fix different faults.
local function failureText(reason)
    if reason == "network" then
        return _("Couldn't reach GitHub. Check the connection and try again.")
    end
    if reason == "norelease" then
        return _("Meguru has no published release yet.")
    end
    if reason == "ratelimited" then
        return _("GitHub is refusing requests from this device right now. Try again later.")
    end
    if reason == "noasset" then
        return _("The latest release has no downloadable file.")
    end
    if reason == "unreadable" then
        return _("GitHub answered with something Meguru could not read.")
    end
    return _("Couldn't check for updates.")
end

local function parseRelease(body)
    local json = Net.jsonDecoder()
    if not json then
        return nil, "unreadable"
    end
    local ok_decode, data = pcall(json.decode, body)
    if not ok_decode or type(data) ~= "table" or type(data.tag_name) ~= "string" then
        return nil, "unreadable"
    end
    local download_url
    for _, asset in ipairs(data.assets or {}) do
        -- Exact name: the workflow attaches one asset under a fixed name.
        if asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end
    return {
        version = canonical(data.tag_name),
        download_url = download_url,
        html_url = data.html_url,
    }
end

local function fetchRelease(use_cache)
    if use_cache ~= false then
        local cached = cachedRelease()
        if cached then
            logger.dbg("Meguru: using the cached release info")
            return cached
        end
    end
    local code, _, body = Net.get(apiUrl(), {
        -- The API's media type; octet-stream is the asset type, not this one.
        accept = "application/vnd.github+json",
        timeout = "resume",
    })
    if code ~= 200 or not body then
        noteCheck()
        if not code then
            return nil, "network"
        end
        if code == 404 then
            -- 404 on releases/latest means no releases at all, not a network fault.
            return nil, "norelease"
        end
        if code == 403 then
            return nil, "ratelimited"
        end
        return nil, "http"
    end
    local release, reason = parseRelease(body)
    if not release then
        noteCheck()
        return nil, reason
    end
    noteCheck({
        version = release.version,
        download_url = release.download_url,
        html_url = release.html_url,
    })
    return release
end

-- Do not join ARCHIVE_ROOT: every entry path already begins with it.
-- Lazy require: a KOReader without libarchive loses the row, not the plugin.
local function extractInto(archive, staging)
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, _("This build of KOReader has no archive support.")
    end
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        return nil, tostring(reader.err or "could not open the archive")
    end
    for entry in reader:iterate() do
        -- Files only, no leading slash: libarchive stops `..` but not `/abs`.
        if entry.mode == "file" and entry.path:sub(1, 1) ~= "/" then
            local dest = staging .. "/" .. entry.path
            -- Create parents: libarchive's doing so is version/option dependent.
            local folder = util.splitFilePathName(dest)
            FS.ensureDir(folder)
            if not reader:extractToPath(entry.path, dest) then
                -- Advisory, not fatal: ARCHIVE_WARN is common on FAT cards.
                logger.warn("Meguru: could not extract", entry.path, ":",
                    tostring(reader.err))
            end
        end
    end
    reader:close()
    return true
end

local function stagedLooksRight(staging, expected_version)
    local root = staging .. "/" .. ARCHIVE_ROOT
    -- Not `_`: that is gettext here and would shadow the call in the loop body.
    for index, relative in ipairs(REQUIRED_FILES) do
        if not FS.exists(root .. "/" .. relative) then
            return nil, _("The downloaded file is not a Meguru release.")
        end
    end
    local ok, meta = pcall(dofile, root .. "/_meta.lua")
    if not ok or type(meta) ~= "table"
        or canonical(meta.version) ~= canonical(expected_version) then
        return nil, _("The downloaded file is not the release it was asked for.")
    end
    return true
end

local function install(release)
    local plugin_dir = Paths.pluginDir()
    if not plugin_dir then
        return nil, _("Meguru does not know where it is installed, so it cannot update itself.")
    end

    -- Symlinked dev install: renaming it would orphan the source; refuse first.
    local link = lfs.symlinkattributes(plugin_dir)
    if link and link.mode == "link" then
        return nil, _("Meguru is installed as a symlink to its source, so it cannot update itself. Update it there instead.")
    end

    local ota = otaDir()
    local staging = ota .. "/staging"
    local backup = ota .. "/backup"
    local archive = ota .. "/" .. ASSET_NAME
    local staged_plugin = staging .. "/" .. ARCHIVE_ROOT

    -- Cleared first: leftovers must never be mistaken for this attempt's.
    -- But not in the stranded path below: there the backup is the only copy.
    FFIUtil.purgeDir(ota)
    if not FS.ensureDir(staging) then
        return nil, T(_("Could not create %1."), staging)
    end

    if not Net.getToFile(release.download_url, archive,
        { accept = "application/octet-stream", timeout = "download" }) then
        -- getToFile removed its partial; this clears the staging dir it would use.
        FFIUtil.purgeDir(ota)
        return nil, _("Could not download the update.")
    end

    local ok_extract, extract_err = extractInto(archive, staging)
    if not ok_extract then
        FFIUtil.purgeDir(ota)
        return nil, T(_("Could not unpack the update: %1"), tostring(extract_err))
    end

    local ok_staged, staged_err = stagedLooksRight(staging, release.version)
    if not ok_staged then
        FFIUtil.purgeDir(ota)
        return nil, staged_err
    end

    local ok_backup, backup_err = os.rename(plugin_dir, backup)
    if not ok_backup then
        FFIUtil.purgeDir(ota)
        return nil, T(_("Could not move the installed copy aside: %1"), tostring(backup_err))
    end

    -- Nothing between these renames: the plugin does not exist in this window.
    local ok_swap, swap_err = os.rename(staged_plugin, plugin_dir)

    if ok_swap and not FS.exists(plugin_dir .. "/main.lua") then
        -- Clear it first: a rename onto a non-empty directory fails.
        FFIUtil.purgeDir(plugin_dir)
        ok_swap, swap_err = nil, "the unpacked copy was incomplete"
    end

    if not ok_swap then
        -- Expected to work; if not, the backup is still on disk, so name it.
        if not os.rename(backup, plugin_dir) then
            logger.warn("Meguru: the update failed and the previous copy could"
                .. " not be restored; it is at", backup)
            return nil, T(_("The update failed and the previous copy of Meguru could not be put back. It is in %1."), backup)
        end
        FFIUtil.purgeDir(ota)
        logger.warn("Meguru: update failed while installing:", tostring(swap_err))
        return nil, T(_("Could not install the update: %1"), tostring(swap_err))
    end

    -- Only once the swap is confirmed is anything deleted.
    FFIUtil.purgeDir(ota)
    noteCheck({
        version = release.version,
        download_url = release.download_url,
        html_url = release.html_url,
    })
    logger.info("Meguru: updated to", release.version)
    return true
end

local function installAndReport(release)
    local progress = toast(T(_("Downloading Meguru %1…"), release.version), 120)
    -- Deferred so the message is painted before the download blocks the UI.
    UIManager:nextTick(function()
        local ok, err = install(release)
        closeWidget(progress)
        if not ok then
            logger.warn("Meguru: update failed:", err)
            toast(err, 8)
            return
        end
        -- askForRestart, not restartKOReader: it broadcasts Restart first.
        UIManager:askForRestart(T(_("Meguru was updated to %1."), release.version))
    end)
end

-- A release worth offering, or nil; used only by the silent check.
local function offerIfNewer(release)
    local version = currentVersion()
    if not version then
        return nil
    end
    if not release or not release.download_url then
        return nil
    end
    if not versionLessThan(version, release.version) then
        return nil
    end
    return version
end

local function showInstallDialog(release, version)
    UIManager:show(ConfirmBox:new{
        text = T(_("Meguru %1 is available (you have %2).\n\nInstall it now?"),
            release.version, version),
        ok_text = _("Install now"),
        cancel_text = _("Later"),
        ok_callback = function()
            installAndReport(release)
        end,
    })
end

-- For the menu row: always answers, even to say it is up to date.
function Updater.checkForUpdates()
    local checking = toast(_("Checking for updates…"), 15)

    local function report(release, reason)
        closeWidget(checking)
        local version = currentVersion()
        if not version then
            toast(_("This build of Meguru does not declare a version, so there is nothing to compare."), 8)
            return
        end
        if not release then
            toast(failureText(reason), 8)
            return
        end
        if not release.download_url then
            -- No asset, but the release page is somewhere the reader can act.
            UIManager:show(ConfirmBox:new{
                text = failureText("noasset") .. "\n\n"
                    .. _("Open the release page?"),
                ok_text = _("Open"),
                cancel_text = _("Later"),
                ok_callback = function()
                    local Device = require("device")
                    local target = release.html_url or string.format(
                        "https://github.com/%s/%s/releases/latest",
                        GITHUB_OWNER, GITHUB_REPO)
                    -- pcall: a callback throw would vanish into the event loop.
                    pcall(function()
                        if Device:canOpenLink() then
                            Device:openLink(target)
                        end
                    end)
                end,
            })
            return
        end
        if not versionLessThan(version, release.version) then
            logger.dbg("Meguru: up to date (" .. version .. ")")
            toast(T(_("Meguru is up to date (%1)."), version), 4)
            return
        end
        logger.info("Meguru: a new version is available:", release.version)
        showInstallDialog(release, version)
    end

    local function run()
        -- false: bypass the cache, so a tap sees the real latest.
        local release, reason = fetchRelease(false)
        UIManager:nextTick(function()
            report(release, reason)
        end)
    end

    local ok_manager, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_manager and NetworkMgr and NetworkMgr.runWhenOnline then
        -- Asks for a connection; connected-but-offline drops the callback silently.
        NetworkMgr:runWhenOnline(run)
    else
        run()
    end
end

-- Background check: no UI of its own, speaks only when there is a version.
function Updater.checkSilentForUpdates()
    local ok_manager, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_manager and NetworkMgr and NetworkMgr.isConnected
        and not NetworkMgr:isConnected() then
        -- Never a wifi prompt: the reader just opened a book, not asked.
        return
    end
    local release = fetchRelease()
    local version = offerIfNewer(release)
    if not version then
        return
    end
    logger.info("Meguru: a new version is available:", release.version)
    showInstallDialog(release, version)
end

-- Once per process and once a week: without both, every book opened re-checks.
function Updater.checkAtStartup()
    if startup_scheduled then
        return
    end
    startup_scheduled = true
    if not Paths.pluginDir() then
        -- init sets pluginDir just before; no dir means a caller that did not.
        return
    end
    if not silentCheckDue() then
        return
    end
    -- Deferred, so the startup paint is not waiting on a socket.
    UIManager:scheduleIn(10, function()
        pcall(Updater.checkSilentForUpdates)
    end)
end

function Updater.setInstalledVersion(version)
    if type(version) == "string" and version ~= "" then
        installed_version = version
    end
end

return Updater
