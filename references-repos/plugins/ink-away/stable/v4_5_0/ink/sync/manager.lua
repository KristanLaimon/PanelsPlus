--[[
The cloud sync as the rest of Ink Away sees it (see ink/sync/): sign in and
out, start a run, say how things stand, and the little jobs around it (the
conflict copies, earlier versions). One place holds the answers, so the
screens only show them. It keeps no state of its own except what is going on
right now; everything else is in the sync's folder (ink/sync/state.lua).

The runs themselves happen in a background process (ink/sync/runner.lua).
Nothing here touches a notebook's file except through the engine, or, for a
conflict the person settles, with a safety copy first.
]]

local Account = require("ink/sync/account")
local Backup = require("ink/sync/backup")
local Config = require("ink/sync/config")
local Engine = require("ink/sync/engine")
local Errors = require("ink/sync/errors")
local Areas = require("ink/sync/areas")
local Prefs = require("ink/sync/prefs")
local BookIndex = require("ink/sync/bookindex")
local Providers = require("ink/sync/providers")
local Runner = require("ink/sync/runner")
local Schedule = require("ink/sync/schedule")
local State = require("ink/sync/state")
local Storage = require("ink/storage")

local Manager = {}

-- Right now: whether a run is on, what it is doing, the last result, a change
-- waiting to be sent, how many runs in a row failed.
local now_state = { running = false, dirty = false, failures = 0, listeners = {} }
Manager.live = now_state

------------------------------------------------------------------------------
-- Settings and places
------------------------------------------------------------------------------

function Manager.get(key)
    local G = rawget(_G, "G_reader_settings")
    if G and G.readSetting then return G:readSetting(key) end
end

function Manager.set(key, value)
    local G = rawget(_G, "G_reader_settings")
    if G and G.saveSetting then G:saveSetting(key, value) end
end

-- The sync's own folder (outside the library, so it is never synced).
function Manager.dir()
    local d = Storage.join(Storage.dataDir() or Storage.settingsDir(), "inkaway-sync")
    Storage.ensureDir(d)
    return d
end

function Manager.backupDir() return Storage.join(Manager.dir(), "backup") end

-- The library folder that is synced.
function Manager.root()
    local Library = require("ink/library")
    return Library.root(Manager.get("inkaway_library_dir"))
end

function Manager.options() return Schedule.options(Manager.get) end

function Manager.account() return Account.load(Manager.dir()) end

function Manager.connected() return Manager.account() ~= nil end

-- This reader's name among the person's readers.
function Manager.deviceName()
    local own = Manager.get("inkaway_sync_device")
    if type(own) == "string" and own ~= "" then return own end
    return Account.defaultDeviceName()
end

-- Tell the screen something changed: the one screen that is open listens.
function Manager.onChange(fn) now_state.listeners = { fn } end
local function changed()
    for _i, fn in ipairs(now_state.listeners) do pcall(fn) end
end
Manager.changed = changed

------------------------------------------------------------------------------
-- The log
------------------------------------------------------------------------------

local LOG_MAX = 96 * 1024

-- Add a line to the sync log (kept small).
function Manager.log(line)
    local path = Storage.join(Manager.dir(), "log.txt")
    local size = Storage.size(path) or 0
    if size > LOG_MAX then
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end
    local f = io.open(path, "ab")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ", os.time()), tostring(line):gsub("[\r\n]", " "), "\n")
        f:close()
    end
end

-- The last `n` lines of the log, newest last.
function Manager.logTail(n)
    local f = io.open(Storage.join(Manager.dir(), "log.txt"), "rb")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    local lines = {}
    for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local out = {}
    for i = math.max(1, #lines - (n or 30) + 1), #lines do out[#out + 1] = lines[i] end
    return out
end

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- Start signing in to service `id`. Returns { url, provider, ... } (for a service
-- where the person types a code into the reader: a verifier; for one where the
-- reader shows a code: kind = "device", user_code, interval), or nil and an error
-- (no app key set up).
function Manager.beginSignIn(id)
    local mod = Providers.get(id)
    if not mod then return nil, Errors.make("IA-S503", "no such service") end
    local key, secret = Config.appKey(id, Manager.get)
    if not key then return nil, Errors.make("IA-S204", "no app key") end
    local a, err = mod.beginAuth(key, secret)
    if not a then return nil, err end
    a.provider = id
    return a
end

-- A sign-in that worked: keep the account, and start afresh if it is a different
-- one than before. Returns { name, email }, or nil and an error.
local function signedIn(mod, acct, key, secret)
    local dir = Manager.dir()
    local inst = mod.new(acct, { app_key = key, app_secret = secret, dir = dir })
    local who = inst:accountInfo()
    acct.name = who and who.name or ""
    acct.email = who and who.email or ""
    acct.account_id = who and who.id or acct.account_id
    local ok, serr = Account.save(dir, acct)
    if not ok then return nil, Errors.make("IA-S402", serr) end
    -- a different account than before starts afresh: what was agreed with the other
    local st = State.load(dir)
    if st.data.account_id and st.data.account_id ~= acct.account_id then st:clear() end
    st.data.account_id = acct.account_id
    st:save()
    Manager.set("inkaway_sync_enabled", true)
    Manager.log("signed in as " .. tostring(acct.name))
    changed()
    return { name = acct.name, email = acct.email }
end

-- Finish signing in with the code the person typed. Blocks for a moment (two
-- requests). Returns { name, email } of the account, or nil and an error.
function Manager.finishSignIn(pending, code)
    local mod = Providers.get(pending.provider)
    local key, secret = Config.appKey(pending.provider, Manager.get)
    local acct, err = mod.finishAuth(key, code, pending.verifier)
    if not acct then return nil, err end
    return signedIn(mod, acct, key, secret)
end

-- Ask whether the person has allowed a sign-in that shows a code on the reader.
-- Returns { name, email } when it has, or nil and an error; IA-S206 means not yet.
function Manager.pollSignIn(pending)
    local mod = Providers.get(pending.provider)
    local key, secret = Config.appKey(pending.provider, Manager.get)
    local acct, err = mod.pollAuth(key, pending, secret)
    if not acct then return nil, err end
    return signedIn(mod, acct, key, secret)
end

-- Disconnect: forget the account and what was agreed. The notebooks on this reader
-- and in the cloud stay as they are.
function Manager.signOut()
    local dir = Manager.dir()
    Account.clear(dir)
    State.load(dir):clear()
    os.remove(Storage.join(dir, State.FILE))
    for _i, id in ipairs({ "gdrive", "onedrive" }) do os.remove(Storage.join(dir, id .. "-index.json")) end
    Manager.set("inkaway_sync_enabled", false)
    now_state.dirty, now_state.failures = false, 0
    Manager.log("signed out")
    changed()
end

------------------------------------------------------------------------------
-- Running
------------------------------------------------------------------------------

-- Which notebooks are open in the editor (lower-case paths in the library), kept
-- in a file the background process reads before replacing anything.
local open_slots = {}
function Manager.setOpen(rels, slot)
    open_slots[slot or "notebook"] = rels or {}
    local lines = {}
    for _name, list in pairs(open_slots) do
        for _i, r in ipairs(list) do lines[#lines + 1] = r:lower() end
    end
    Storage.writeAtomic(Storage.join(Manager.dir(), "open.txt"), table.concat(lines, "\n"))
end

local function openSet(dir)
    local f = io.open(Storage.join(dir, "open.txt"), "rb")
    local set = {}
    if f then
        for l in f:lines() do set[l] = true end
        f:close()
    end
    return set
end

-- The path of a file inside the library, relative to it (nil if outside).
function Manager.relOf(path)
    local root = Manager.root():gsub("/+$", "")
    if path and path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
end

-- What a run hands back: small enough to pass between processes.
local function summarize(res)
    local out = { uploaded = res.uploaded, downloaded = res.downloaded, conflicts = res.conflicts, merged = res.merged,
        deleted = res.deleted, waiting = res.waiting, started = res.started, finished = res.finished,
        dry = res.dry, blocked_deletes = res.blocked_deletes, errors = {}, warnings = {}, plan = {} }
    if res.fatal then out.fatal = { code = res.fatal.code, detail = res.fatal.detail, retry_after = res.fatal.retry_after } end
    for i, e in ipairs(res.errors) do
        if i > 50 then break end
        out.errors[#out.errors + 1] = { rel = e.rel, code = e.err.code, detail = e.err.detail }
    end
    for i, w in ipairs(res.warnings) do
        if i > 50 then break end
        out.warnings[#out.warnings + 1] = { rel = w.rel, code = w.err.code, detail = w.err.detail }
    end
    if res.dry then
        for i, p in ipairs(res.plan or {}) do
            if i > 500 then break end
            out.plan[#out.plan + 1] = { rel = p.rel, action = p.action }
        end
    end
    return out
end

------------------------------------------------------------------------------
-- The parts of the sync
------------------------------------------------------------------------------

-- The parts, each { id, label, hint, on }, in the order they are shown.
function Manager.areas()
    local out = {}
    for _i, d in ipairs(Areas.DEFS) do
        out[#out + 1] = { id = d.id, label = d.label, hint = d.hint, on = Areas.enabled(d.id, Manager.get) }
    end
    return out
end

-- Turn a part on or off. What is waiting is sent the next time.
function Manager.setArea(id, on)
    Areas.setEnabled(id, on, Manager.set)
    now_state.dirty = true
    changed()
end

-- The books in the reading history (their files), newest first.
local function historyFiles()
    local ok, ReadHistory = pcall(require, "readhistory")
    local out = {}
    if ok and ReadHistory and type(ReadHistory.hist) == "table" then
        for _i, item in ipairs(ReadHistory.hist) do
            if item.file then out[#out + 1] = item.file end
        end
    end
    return out
end

-- A book's checksum, as KOReader keeps it.
local function bookChecksum(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings then
        local good, md5 = pcall(function()
            if not DocSettings:hasSidecarFile(file) then return nil end
            return DocSettings:open(file):readSetting("partial_md5_checksum")
        end)
        if good and md5 then return md5 end
    end
    local uok, util = pcall(require, "util")
    if uok and util and util.partialMD5 then return util.partialMD5(file) end
end

-- The folder that holds (or will hold) a book's ink.
local function bookFolder(file)
    local BookInk = require("ink/reader/bookink")
    return BookInk.find(file) or BookInk.dirsFor(file)[1]
end

-- The parts as the engine takes them, for the library at `root`, with the sync's
-- own folder `dir`. Looks through the reading history for books when their ink is on.
function Manager.buildAreas(root, dir)
    if Areas.enabled("bookink", Manager.get) then
        pcall(BookIndex.scan, dir, historyFiles(), bookChecksum, bookFolder, os.time())
    end
    return Areas.build({
        get = Manager.get, root = root,
        appPath = function(name) return Storage.join(Storage.appRootPath() or Storage.join(Storage.dataDir() or "/tmp", "ink away"), name) end,
        books = function() return BookIndex.list(dir) end,
        merge = function(first, second) return require("ink/reader/bookink").merge(first, second) end,
        prefsPath = Manager.prefsPath(), mergePrefs = Prefs.merge,
    })
end

------------------------------------------------------------------------------
-- Preferences
------------------------------------------------------------------------------

-- The file the preferences are written to for a run (and come back in).
function Manager.prefsPath()
    local d = Storage.join(Manager.dir(), "prefs")
    Storage.ensureDir(d)
    return Storage.join(d, "preferences.json")
end

local function readText(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Before a run: the chosen preferences into their file (nothing is written for
-- none, or when the file already says the same). Returns the text now in the file.
function Manager.writePrefs()
    if not Areas.enabled("settings", Manager.get) then return nil end
    local path = Manager.prefsPath()
    local have = readText(path)
    local mine = Prefs.export(Manager.get)
    if next(mine) == nil and not have then return nil end
    -- a file that came from another reader and was not applied yet is not written over
    local current = have and Prefs.decode(have)
    local text = Prefs.encode(mine)
    if current and next(mine) == nil then return have end
    if have ~= text then Storage.writeAtomic(path, text) end
    return text
end

-- After a run: preferences that came from another reader go into the settings.
-- `before` is the text written before the run.
function Manager.readPrefs(before)
    if not Areas.enabled("settings", Manager.get) then return end
    local text = readText(Manager.prefsPath())
    if not text or text == before then return end
    local tbl = Prefs.decode(text)
    if tbl then
        local n = Prefs.apply(tbl, Manager.set)
        Manager.log("preferences from another reader: " .. n)
    end
end

------------------------------------------------------------------------------
-- Books
------------------------------------------------------------------------------

local function bookKey(md5) return Areas.PREFIX .. "/books/" .. md5:lower() .. "/inkaway.lua" end

-- A book was opened: list it (so its ink can be matched with the other readers'),
-- and keep the sync's hands off its ink while it is open.
function Manager.bookOpened(md5, sidecar, file)
    if not (md5 and Areas.enabled("bookink", Manager.get)) then return end
    BookIndex.note(Manager.dir(), md5, sidecar, file)
    Manager.setOpen({ bookKey(md5) }, "book")
end

-- The book was closed (its ink was saved just before).
function Manager.bookClosed()
    Manager.setOpen({}, "book")
    if Areas.enabled("bookink", Manager.get) then Manager.noteClosed() end
end

-- A book's ink was saved.
function Manager.bookSaved()
    if Areas.enabled("bookink", Manager.get) then Manager.noteChanged() end
end

-- Before a book is shown: look for newer ink for it in the cloud (a few seconds at
-- most). `proceed(fetched)` is called once, with whether newer ink came.
function Manager.preOpenBook(md5, sidecar, file, proceed)
    local opts = Manager.options()
    if not (md5 and Areas.enabled("bookink", Manager.get) and opts.enabled and opts.on_open and Manager.connected()) then
        return proceed(false)
    end
    BookIndex.note(Manager.dir(), md5, sidecar, file)
    if now_state.last_started and os.time() - now_state.last_started < 60 then return proceed(false) end
    local done = false
    local function go(res) if not done then done = true; proceed(res and (res.downloaded or 0) + (res.merged or 0) > 0 or false) end end
    local started = Manager.run("open", { only = { [bookKey(md5)] = true }, on_done = go })
    if not started then return go() end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok then UIManager:scheduleIn(6, function() go() end) end
end

-- The work of one run, as it is done in the background process.
local function makeWork(o)
    local dir, root, device = Manager.dir(), Manager.root(), Manager.deviceName()
    local backup = Manager.backupDir()
    local Project = require("ink/project")
    local key, secret = Config.appKey(o.provider, Manager.get)
    return function(report, stop)
        local acct = Account.load(dir)
        if not acct then return { fatal = { code = "IA-S201" }, errors = {}, warnings = {}, plan = {} } end
        local mod = Providers.get(acct.provider)
        if not mod then return { fatal = { code = "IA-S503", detail = "no such service" }, errors = {}, warnings = {}, plan = {} } end
        local inst = mod.new(acct, { app_key = key, app_secret = secret, dir = dir, save = function(a) Account.save(dir, a) end })
        local st = State.load(dir)
        local areas = Manager.buildAreas(root, dir)
        local res = Engine.run({
            root = root, provider = inst, state = st, backup_dir = backup, device = device, areas = areas,
            now = os.time, sleep = function(s) os.execute("sleep " .. math.floor(s)) end,
            stop = stop, report = report, dry = o.dry, rebase = o.rebase, allow_mass_delete = o.allow_mass_delete,
            only = o.only,
            skip = function(k) return openSet(dir)[k] == true end,
            validate = function(rel, path)
                if rel == Prefs.REL then return Prefs.valid(path) end
                if rel:match("/inkaway%.lua$") then return require("ink/reader/bookink").valid(path) end
                if not rel:match("%.inkaway$") then return true end
                local data, err = Project.load(path)
                if data then return true end
                return false, err or "not a notebook"
            end,
            log = Manager.log,
        })
        return summarize(res)
    end
end

-- Make sure there is a network. cb(true) or cb(false, error). With `allow_wifi`
-- the reader may turn Wi-Fi on; without it a reader that is offline is an error.
local function withNetwork(allow_wifi, cb)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return cb(true) end
    local online = NetworkMgr.isOnline and NetworkMgr:isOnline()
    if online then return cb(true) end
    if not allow_wifi then return cb(false, Errors.make("IA-S104")) end
    local done = false
    local function go() if not done then done = true; cb(true) end end
    if NetworkMgr.turnOnWifiAndWaitForConnection then
        NetworkMgr:turnOnWifiAndWaitForConnection(go)
    elseif NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(go)
    else
        cb(false, Errors.make("IA-S104"))
    end
end

-- Start a run for `event` (see ink/sync/schedule.lua). `o`: dry, only, rebase,
-- allow_mass_delete, on_done(result). Returns whether a run started, and when it
-- did not, why: "account" (not signed in), "busy" (a run is going) or "not due".
function Manager.run(event, o)
    o = o or {}
    local acct = Manager.account()
    if not acct then
        if o.on_done and event == "manual" then o.on_done({ fatal = { code = "IA-S201" }, errors = {}, warnings = {}, plan = {} }) end
        return false, "account"
    end
    local opts = Manager.options()
    local st = { last = now_state.last_started, failures = now_state.failures, dirty = now_state.dirty, running = now_state.running }
    if not Schedule.due(opts, event, os.time(), st) then return false, now_state.running and "busy" or "not due" end
    o.provider = acct.provider
    now_state.running = true
    now_state.progress = { phase = "start" }
    now_state.last_started = os.time()
    changed()
    local started_dirty_mark = now_state.change_serial or 0
    local function begin()
        local wrote = Manager.writePrefs()
        local handle = Runner.start({
            dir = Manager.dir(), work = makeWork(o),
            on_progress = function(info) now_state.progress = info; changed() end,
            on_done = function(res)
                now_state.running, now_state.progress, now_state.handle = false, nil, nil
                now_state.result = res
                if res.crashed then res.fatal = res.fatal or { code = "IA-S503", detail = res.crashed } end
                -- (a run the person stopped is neither a failure to back off from nor a success)
                local stopped = res.fatal and res.fatal.code == "IA-S502"
                if res.fatal and Errors.isFatal(res.fatal) and not stopped then
                    now_state.failures = now_state.failures + 1
                elseif not res.dry and not stopped then now_state.failures = 0 end
                if not res.dry and not res.fatal and (now_state.change_serial or 0) == started_dirty_mark then
                    now_state.dirty = false
                end
                Manager.log(string.format("%s: up %s down %s conflicts %s deleted %s errors %s%s", event,
                    tostring(res.uploaded), tostring(res.downloaded), tostring(res.conflicts), tostring(res.deleted),
                    tostring(res.errors and #res.errors or 0), res.fatal and (" FATAL " .. tostring(res.fatal.code)) or ""))
                if res.fatal and res.fatal.detail then Manager.log("  detail: " .. tostring(res.fatal.detail):sub(1, 300)) end
                for i, e in ipairs(res.errors or {}) do
                    if i > 5 then break end
                    Manager.log(string.format("  error %s %s %s", tostring(e.code), tostring(e.rel), tostring(e.detail or ""):sub(1, 200)))
                end
                if not res.dry and not res.fatal then pcall(Manager.readPrefs, wrote) end
                changed()
                if o.on_done then o.on_done(res) end
            end,
        })
        now_state.handle = handle
    end
    withNetwork(opts.wifi_on or event == "manual", function(okn, err)
        if not okn then
            now_state.running, now_state.progress = false, nil
            local res = { fatal = { code = err.code }, errors = {}, warnings = {}, plan = {} }
            now_state.result = res
            changed()
            if o.on_done then o.on_done(res) end
            return
        end
        begin()
    end)
    return true
end

-- A notebook is about to open: look in the cloud for a newer version of just that
-- notebook first (when the person has this on), then call `proceed`. Never makes
-- the person wait more than a few seconds, and never when nothing is set up.
function Manager.preOpen(path, proceed)
    local rel = Manager.relOf(path)
    local opts = Manager.options()
    if not (rel and opts.enabled and opts.on_open and Manager.connected()) then return proceed() end
    if now_state.last_started and os.time() - now_state.last_started < 60 then return proceed() end
    local done = false
    local function go() if not done then done = true; proceed() end end
    local started = Manager.run("open", { only = { [rel:lower()] = true }, on_done = go })
    if not started then return go() end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok then UIManager:scheduleIn(6, go) end
end

-- Stop the run that is going.
function Manager.stop()
    if now_state.handle then now_state.handle:stop() end
end

-- A notebook was saved: a change is waiting; after a pause in drawing it is sent.
function Manager.noteChanged()
    now_state.dirty = true
    now_state.change_serial = (now_state.change_serial or 0) + 1
    local opts = Manager.options()
    if opts.enabled and opts.pause_s > 0 then
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then
            UIManager:unschedule(Manager._pauseFire)
            UIManager:scheduleIn(opts.pause_s, Manager._pauseFire)
        end
    end
end

function Manager._pauseFire() Manager.run("pause") end

-- A notebook was closed.
function Manager.noteClosed() Manager.run("close") end

-- The reader is going to sleep.
function Manager.noteSleep() Manager.run("sleep") end

-- The timer for "every so often": call once at start and when the choice changes.
function Manager.armInterval()
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    UIManager:unschedule(Manager._intervalTick)
    local opts = Manager.options()
    if opts.enabled and opts.interval_min > 0 then
        UIManager:scheduleIn(math.max(60, math.min(opts.interval_min * 60, 900)), Manager._intervalTick)
    end
end

function Manager._intervalTick()
    Manager.run("interval")
    Manager.armInterval()
end

-- Set the sync up for this session (once): notebooks from other readers find their
-- pictures here, the timer for "every so often" starts, and a run that is overdue
-- happens a little after start-up. Nothing at all happens until the person has
-- connected an account.
function Manager.start()
    if Manager.started then return end
    Manager.started = true
    require("ink/sync/portable").root = function() return Manager.root() end
    if not Manager.connected() then return end
    Manager.setOpen({})
    Manager.armInterval()
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok then UIManager:scheduleIn(20, function() Manager.run("start") end) end
end

------------------------------------------------------------------------------
-- How things stand
------------------------------------------------------------------------------

-- A snapshot for the screens.
function Manager.status()
    local acct = Manager.account()
    local st = State.load(Manager.dir())
    local last = st.data.last
    local s = {
        connected = acct ~= nil,
        provider = acct and acct.provider, provider_name = acct and Providers.name(acct.provider),
        name = acct and acct.name or "", email = acct and acct.email or "",
        enabled = Manager.options().enabled,
        running = now_state.running, progress = now_state.progress,
        dirty = now_state.dirty, last = last, failures = now_state.failures,
        conflicts = #st.data.conflicts, result = now_state.result,
        device = Manager.deviceName(),
    }
    return s
end

------------------------------------------------------------------------------
-- Conflict copies
------------------------------------------------------------------------------

-- The conflicts to settle: { { orig, copy, at, device, has_orig, has_copy } }.
function Manager.conflicts()
    local st = State.load(Manager.dir())
    local root = Manager.root()
    local out = {}
    for _i, c in ipairs(st.data.conflicts) do
        local has_copy = Storage.exists(Storage.join(root, c.copy))
        if has_copy then
            out[#out + 1] = { orig = c.orig, copy = c.copy, at = c.at, device = c.device,
                has_orig = Storage.exists(Storage.join(root, c.orig)) }
        end
    end
    return out
end

local function dropConflict(st, copy)
    local keep = {}
    for _i, c in ipairs(st.data.conflicts) do if c.copy ~= copy then keep[#keep + 1] = c end end
    st.data.conflicts = keep
end

-- Settle a conflict: "copy" (the copy replaces the original), "original" (the
-- copy is thrown away) or "both" (nothing changes; the copy becomes an ordinary
-- notebook). The file about to be lost is saved in the backup folder first.
-- Returns ok, error.
function Manager.resolveConflict(copy, how)
    if now_state.running then return nil, Errors.make("IA-S504", "a sync is running") end
    local dir, root = Manager.dir(), Manager.root()
    local st = State.load(dir)
    local entry
    for _i, c in ipairs(st.data.conflicts) do if c.copy == copy then entry = c end end
    if not entry then return true end
    local copy_path, orig_path = Storage.join(root, entry.copy), Storage.join(root, entry.orig)
    if how == "both" then
        dropConflict(st, copy)
    elseif how == "original" then
        local b, berr = Backup.put(Manager.backupDir(), entry.copy, copy_path, os.time())
        if not b then return nil, Errors.make("IA-S402", berr) end
        os.remove(copy_path)
        dropConflict(st, copy)
    elseif how == "copy" then
        if Storage.exists(orig_path) then
            local b, berr = Backup.put(Manager.backupDir(), entry.orig, orig_path, os.time())
            if not b then return nil, Errors.make("IA-S402", berr) end
        end
        if not os.rename(copy_path, orig_path) then
            os.remove(orig_path)
            if not os.rename(copy_path, orig_path) then return nil, Errors.make("IA-S402", "rename") end
        end
        dropConflict(st, copy)
    else
        return nil, Errors.make("IA-S503", "unknown choice")
    end
    st:save()
    now_state.dirty = true
    changed()
    return true
end

------------------------------------------------------------------------------
-- Earlier versions
------------------------------------------------------------------------------

local function instance()
    local acct = Manager.account()
    if not acct then return nil, Errors.make("IA-S201") end
    local mod = Providers.get(acct.provider)
    if not mod then return nil, Errors.make("IA-S503") end
    local key, secret = Config.appKey(acct.provider, Manager.get)
    return mod.new(acct, { app_key = key, app_secret = secret, dir = Manager.dir(),
        save = function(a) Account.save(Manager.dir(), a) end })
end

-- The earlier versions of the notebook at library path `rel`, newest first.
function Manager.versions(rel)
    local inst, err = instance()
    if not inst then return nil, err end
    return inst:revisions(rel)
end

-- Bring an earlier version back: it becomes the cloud's current one, and the
-- next sync puts it on this reader (the notebook now here is backed up first).
function Manager.restoreVersion(rel, rev)
    local inst, err = instance()
    if not inst then return nil, err end
    local m, rerr = inst:restore(rel, rev)
    if not m then return nil, rerr end
    return m
end

return Manager
