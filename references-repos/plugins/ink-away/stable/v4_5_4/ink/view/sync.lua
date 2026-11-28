--[[
Cloud sync, on screen: the Cloud sync sheet (connect, status, when to sync, this
reader's name), the sign-in with a QR code and a code to type, the preview of a
first sync, the result of a sync with its error codes, conflicts, earlier
versions, the log, and disconnecting. The syncing itself is ink/sync/*; this
file only shows it. Everything is done on the reader: no PC is needed.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("ink/l10n")
local Config = require("ink/sync/config")
local Errors = require("ink/sync/errors")
local Manager = require("ink/sync/manager")
local Providers = require("ink/sync/providers")
local Schedule = require("ink/sync/schedule")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local GREY = Blitbuffer.COLOR_DARK_GRAY

local function S(px) return Screen:scaleBySize(px) end
local function vspan(px) return VerticalSpan:new{ width = S(px) } end
-- A translated text with %1, %2... filled in.
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local InkAwayView = {}

local SHEET = "_sync"

-- "5 min ago" for a time `at`.
local function ago(at)
    local d = os.time() - at
    if d < 60 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return os.date("%d %b", at)
end

-- A line for an error: "IA-S101  No connection".
local function codeLine(code) return Errors.line(code) end

local function para(_self, text, width, size, grey)
    return TextBoxWidget:new{ text = text, width = width, face = Font:getFace("cfont", size or 16),
        fgcolor = grey and GREY or nil }
end

------------------------------------------------------------------------------
-- How things stand, in words
------------------------------------------------------------------------------

-- What the sync is doing now, as a sentence.
function InkAwayView:syncProgressText(p)
    if not p then return _("Starting\u{2026}") end
    if p.phase == "check" then return _("Checking the cloud\u{2026}") end
    if p.phase == "cloud" then return _("Looking for changes\u{2026}") end
    if p.phase == "reader" then return _("Looking at this reader\u{2026}") end
    if p.phase == "files" then
        return T(_("%1 of %2: %3"), (p.done or 0) + 1, p.total or 0, Storage.baseName(p.rel or ""))
    end
    return _("Finishing\u{2026}")
end

-- Where things stand, in one or two sentences: { text, error = code }.
function InkAwayView:syncStatusLine(s)
    if s.running then return { text = self:syncProgressText(s.progress) } end
    local r = s.result
    if r and r.fatal then
        return { text = T(_("Stopped: %1"), Errors.info(r.fatal.code).title), error = r.fatal.code }
    end
    if s.last then
        local line
        if s.last.errors and s.last.errors > 0 then
            line = T(_("Synced %1, with %2 problem(s)"), ago(s.last.at), s.last.errors)
        else
            line = T(_("Synced %1"), ago(s.last.at))
        end
        if s.dirty then line = line .. "\n" .. _("Changes are waiting to be sent.") end
        return { text = line, error = s.last.errors and s.last.errors > 0 and s.last.first_error or nil }
    end
    return { text = s.dirty and _("Changes are waiting to be sent.") or _("Not synced yet.") }
end

-- A short line for the library menu's hint.
function InkAwayView:syncMenuHint()
    local s = Manager.status()
    if not s.connected then
        return _("Keep your notebooks the same on all your readers, through your own cloud account.")
    end
    return T(_("%1, %2"), s.provider_name, self:syncStatusLine(s).text:gsub("\n.*", ""))
end

-- Watch the sync: when something changes, rebuild the open sheet (at most every
-- couple of seconds, as e-ink redraws the sheet).
function InkAwayView:syncWatch()
    Manager.onChange(function()
        if self.closing or not self[SHEET] or self._sync_tick then return end
        self._sync_tick = function()
            self._sync_tick = nil
            if self[SHEET] then self:rebuildSheet(SHEET) end
        end
        UIManager:scheduleIn(Manager.live.running and 1.5 or 0.2, self._sync_tick)
    end)
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

local PAUSES = { { 0, _("Off") }, { 30, _("30 s") }, { 60, _("1 min") }, { 120, _("2 min") }, { 300, _("5 min") } }
local EVERY = { { 0, _("Off") }, { 15, _("15m") }, { 30, _("30m") }, { 60, _("1h") }, { 180, _("3h") },
    { 720, _("12h") }, { 1440, _("Day") } }

function InkAwayView:openSync()
    self:syncWatch()
    self:closeSheet(SHEET)
    local content_w, gap = self:sheetWidth()
    local function close() self:closeSheet(SHEET) end
    local build = function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Cloud sync"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        local s = Manager.status()
        add(vspan(10))
        if not s.connected then
            add(para(self, _("Keep your notebooks and drawings the same on all your readers."), content_w, 17))
            add(vspan(8))
            add(self:sheetHint(_("Each notebook is copied to your own cloud account. Nothing is replaced or removed without a safety copy, and when two readers change the same notebook, both versions are kept."), content_w, 14))
            add(vspan(8))
            add(self:sheetHint(_("Syncing by itself can slow the reader and use battery. You choose when it runs, and \"Sync now\" runs only when you ask."), content_w, 14))
            add(vspan(14))
            for _i, p in ipairs(Providers.offered(Manager.get)) do
                add(self:actionButton(T(_("Connect %1"), p.name), content_w, function() self:syncSignIn(p.id) end, true, nil, "cloud"))
                add(vspan(6))
            end
            add(self:sheetHint(_("Ink Away only uses its own folder in your account and cannot see anything else in it. Syncing stays off until you connect."), content_w, 13))
            return g
        end
        -- the account and how things stand
        add(self:sheetLabel(s.provider_name, true))
        add(vspan(2))
        add(para(self, (s.name ~= "" and s.name or s.email), content_w, 17))
        add(vspan(8))
        local line = self:syncStatusLine(s)
        add(para(self, line.text, content_w, 15, not line.error))
        if line.error then
            add(vspan(2))
            add(para(self, T(_("Code %1"), line.error), content_w, 14, true))
        end
        add(vspan(10))
        if s.running then
            add(self:actionButton(_("Stop"), content_w, function() Manager.stop() end))
        else
            local half = math.floor((content_w - gap) / 2)
            if line.error then
                add(HorizontalGroup:new{ align = "center",
                    self:actionButton(_("Sync now"), half, function() self:syncNow() end, true, nil, "refresh"),
                    HorizontalSpan:new{ width = gap },
                    self:actionButton(_("Details"), half, function() self:syncErrorSheet(line.error) end) })
            else
                add(self:actionButton(_("Sync now"), content_w, function() self:syncNow() end, true, nil, "refresh"))
            end
        end
        -- the choices live on two sheets of their own, so this one never scrolls
        add(vspan(16))
        add(self:actionButton(_("Sync automatically"), content_w, function() self:syncWhenSheet() end))
        add(vspan(8))
        add(self:actionButton(_("What to sync"), content_w, function() self:syncWhatSheet() end))
        if Schedule.automatic(Manager.options()) then
            add(vspan(6))
            add(self:sheetHint(_("Automatic sync can slow the reader and use battery. \"Sync now\" runs only when you ask."), content_w, 13))
        end
        -- this reader, conflicts, versions, log, disconnect
        add(vspan(8))
        add(self:actionButton(T(_("Name: %1"), s.device), content_w, function() self:syncRename() end, nil, nil, "rename"))
        if s.conflicts > 0 then
            add(vspan(8))
            add(self:actionButton(T(_("Conflicts (%1)"), s.conflicts), content_w, function() self:syncConflicts() end, true))
            add(vspan(4))
            add(self:sheetHint(_("Notebooks changed on two readers. Both versions are kept."), content_w, 13))
        end
        if self.doc_path and Manager.relOf(self.doc_path) then
            add(vspan(8))
            add(self:actionButton(_("Earlier versions of this notebook"), content_w, function() self:syncVersions() end, nil, nil, "page"))
        end
        add(vspan(8))
        local half2 = math.floor((content_w - gap) / 2)
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("Sync log"), half2, function() self:syncLog() end, nil, nil, "file"),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Disconnect"), half2, function() self:syncDisconnect() end, nil, nil, "exit") })
        return g
    end
    self:showSheet(SHEET, build)
end

-- When it syncs by itself: the triggers, the pause after drawing, the timer, Wi-Fi.
function InkAwayView:syncWhenSheet()
    local field = "_sync_when"
    self:closeSheet(field)
    self:closeSheet(SHEET)   -- (the sync sheet comes back with Back; two sheets never show at once)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); self:openSync() end
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Sync automatically"), content_w, _("Back"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        local o = Manager.options()
        add(self:sheetHint(_("Syncing by itself runs in the background but uses the processor, Wi-Fi and battery, and can slow the reader. If it does, tap Manual only and use Sync now."), content_w, 13))
        add(vspan(6))
        add(self:actionButton(_("Manual only"), content_w, function()
            for _i, k in ipairs({ "inkaway_sync_on_close", "inkaway_sync_on_open", "inkaway_sync_on_sleep" }) do Manager.set(k, false) end
            Manager.set("inkaway_sync_pause", 0)
            Manager.set("inkaway_sync_interval", 0)
            Manager.armInterval()
            self:rebuildSheet(field)
        end))
        add(vspan(6))
        add(ToggleRow:new{ label = _("After closing a notebook"), is_on = o.on_close, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_close", on) end })
        add(self:sheetHint(_("Starts a sync in the background each time you close a notebook that changed."), content_w, 12))
        add(vspan(6))
        add(ToggleRow:new{ label = _("Get the latest when opening one"), is_on = o.on_open, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_open", on) end })
        add(self:sheetHint(_("Opening a notebook or book can wait up to 6 seconds for the cloud."), content_w, 12))
        add(vspan(6))
        add(ToggleRow:new{ label = _("When the reader goes to sleep"), is_on = o.on_sleep, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_on_sleep", on) end })
        add(self:sheetHint(_("Syncs just before the reader sleeps, which uses Wi-Fi and battery."), content_w, 12))
        add(vspan(6))
        add(self:sheetLabel(_("After I stop drawing")))
        add(vspan(4))
        add(self:segmentedRow(PAUSES, o.pause_s, content_w, function(v)
            Manager.set("inkaway_sync_pause", v); self:rebuildSheet(field)
        end))
        add(vspan(6))
        add(self:sheetLabel(_("Also every")))
        add(vspan(4))
        add(self:segmentedRow(EVERY, o.interval_min, content_w, function(v)
            Manager.set("inkaway_sync_interval", v); Manager.armInterval(); self:rebuildSheet(field)
        end))
        add(vspan(6))
        add(ToggleRow:new{ label = _("Allow turning on Wi-Fi"), is_on = o.wifi_on, width = content_w, parent = menu,
            callback = function(on) Manager.set("inkaway_sync_wifi_on", on) end })
        add(vspan(6))
        add(self:sheetHint(_("Syncing by itself uses Wi-Fi only when it is already on, unless you allow this. \"Sync now\" may always turn it on."), content_w, 13))
        return g
    end
    self:showSheet(field, build)
end

-- What is carried: each part on its own, with a line on what it holds.
function InkAwayView:syncWhatSheet()
    local field = "_sync_what"
    self:closeSheet(field)
    self:closeSheet(SHEET)   -- (the sync sheet comes back with Back; two sheets never show at once)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); self:openSync() end
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("What to sync"), content_w, _("Back"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        for _i, a in ipairs(Manager.areas()) do
            add(ToggleRow:new{ label = a.label, is_on = a.on, width = content_w, parent = menu,
                callback = function(on) Manager.setArea(a.id, on) end })
            add(vspan(2))
            add(self:sheetHint(a.hint, content_w, 12))
            add(vspan(6))
        end
        add(self:sheetHint(_("The first sync of ink on book pages, imports, exports and screen clips can be large and slow."), content_w, 12))
        return g
    end
    self:showSheet(field, build)
end

------------------------------------------------------------------------------
-- Signing in
------------------------------------------------------------------------------

-- The QR code of `url`, centred, as wide as fits.
local function qrCode(url, content_w)
    local side = math.floor(math.min(content_w * 0.7, math.min(Screen:getWidth(), Screen:getHeight()) * 0.55,
        Screen:getHeight() * 0.4))   -- (short enough that a landscape screen needs no scrolling)
    local okq, QRWidget = pcall(require, "ui/widget/qrwidget")
    if not (okq and QRWidget) then return nil end
    return CenterContainer:new{ dimen = Geom:new{ w = content_w, h = side },
        QRWidget:new{ text = url, width = side, height = side } }
end

-- Connect to service `id`: a QR code to open on a phone, then the code to type (or,
-- for a service that shows a code, the code to type on the phone).
function InkAwayView:syncSignIn(id)
    local pending, err = Manager.beginSignIn(id)
    if not pending then
        if err and err.code == "IA-S204" and #Config.fields(id) > 0 and not Config.appKey(id, Manager.get) then
            return self:syncAskAppKey(id)
        end
        return self:syncErrorSheet(err and err.code or "IA-S503", { again = function() self:syncSignIn(id) end })
    end
    if pending.kind == "device" then return self:syncSignInDevice(pending) end
    if self:syncSignInPaste(pending) then return end
    return self:syncSignInTyped(pending)
end

-- The sign-in where the long code is pasted on a phone: the QR code leads to a page
-- the reader serves on the Wi-Fi (see ink/view/codepage.lua). False when the reader
-- can't serve one, and the code is typed instead.
function InkAwayView:syncSignInPaste(pending)
    local name = Providers.name(pending.provider)
    local field = "_sync_signin"
    local token = {}
    local url = self:startCodePage(name, pending.url, function(code)
        UIManager:nextTick(function()
            if self._sync_pending ~= token then return end
            self._sync_pending = nil
            self:stopCodePage()
            self:closeSheet(field)
            self:syncFinishCode(pending, code)
        end)
    end)
    if not url then return false end
    self._sync_pending = token
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self._sync_pending = nil; self:stopCodePage(); self:closeSheet(field) end
    local build = function()
        local g = VerticalGroup:new{ align = "center", self:sheetTitle(T(_("Connect %1"), name), content_w, _("Cancel"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, _("1. Scan this with your phone's camera. The phone must be on the same Wi-Fi as the reader."), content_w, 16))
        add(vspan(10))
        add(qrCode(url, content_w) or vspan(0))
        add(vspan(10))
        add(para(self, T(_("2. On the page, tap Open %1, tap Allow, then paste the code there. This screen carries on by itself."), name), content_w, 16))
        add(vspan(12))
        add(self:actionButton(_("Type the code instead"), content_w, function()
            close()
            self:syncSignInTyped(pending)
        end, false, nil, "text"))
        add(vspan(8))
        add(self:sheetHint(_("No camera? Open this address in any browser:") .. "\n" .. url, content_w, 11))
        return g
    end
    self:showSheet(field, build)
    return true
end

-- The sign-in where the code is typed on the reader.
function InkAwayView:syncSignInTyped(pending)
    local name = Providers.name(pending.provider)
    local field = "_sync_signin"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    local build = function()
        local g = VerticalGroup:new{ align = "center", self:sheetTitle(T(_("Connect %1"), name), content_w, _("Cancel"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, T(_("1. Scan this with your phone's camera."), name), content_w, 16))
        add(vspan(10))
        add(qrCode(pending.url, content_w) or vspan(0))
        add(vspan(10))
        add(para(self, T(_("2. Sign in to %1 and tap Allow."), name), content_w, 16))
        add(vspan(6))
        add(para(self, T(_("3. %1 shows a code. Type it here."), name), content_w, 16))
        add(vspan(12))
        add(self:actionButton(_("Type the code"), content_w, function()
            close()
            self:syncAskCode(pending)
        end, true, nil, "text"))
        add(vspan(8))
        add(self:sheetHint(_("No camera? Open this address in any browser:") .. "\n" .. pending.url, content_w, 11))
        return g
    end
    self:showSheet(field, build)
end

-- Asking whether a sign-in was allowed: a failure to reach the network that
-- many times in a row ends it (about two minutes); fewer are waited out.
InkAwayView.SIGNIN_NET_MISSES = 24

-- Can this reader open the sign-in page itself (a phone or tablet: its own browser)?
local function canOpenLink()
    return type(Device.canOpenLink) == "function" and Device:canOpenLink() == true and type(Device.openLink) == "function"
end

-- The sign-in where the reader shows a code: the person types it on the phone, and
-- the reader asks every few seconds whether that has been done. A reader with a
-- browser of its own (Android) can open the page itself, the code copied to paste
-- there; meanwhile the reader is in the background and may come back to the
-- network a moment late, so failures to reach it are waited out, not shown.
function InkAwayView:syncSignInDevice(pending)
    local name = Providers.name(pending.provider)
    local field = "_sync_signin"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local token = {}
    self._sync_pending = token
    local function stop() if self._sync_pending == token then self._sync_pending = nil end end
    local function close() stop(); self:closeSheet(field) end
    local build = function()
        local g = VerticalGroup:new{ align = "center", self:sheetTitle(T(_("Connect %1"), name), content_w, _("Cancel"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, _("1. Scan this with your phone's camera."), content_w, 16))
        add(vspan(10))
        add(qrCode(pending.url, content_w) or vspan(0))
        add(vspan(10))
        add(para(self, T(_("2. Sign in to %1 and type this code:"), name), content_w, 16))
        add(vspan(8))
        add(TextBoxWidget:new{ text = pending.user_code, width = content_w, face = Font:getFace("cfont", 34),
            alignment = "center", bold = true })
        add(vspan(8))
        add(para(self, _("3. Tap Allow. This screen carries on by itself."), content_w, 16))
        add(vspan(8))
        add(self:sheetHint(_("No camera? Open this address in any browser:") .. "\n" .. pending.url, content_w, 11))
        if canOpenLink() then
            add(vspan(10))
            add(self:actionButton(_("Open the sign-in page"), content_w, function()
                local inp = Device.input
                if inp and inp.setClipboardText then pcall(inp.setClipboardText, pending.user_code) end
                self:showNotice(_("The code is copied: paste it on the sign-in page."))
                pcall(Device.openLink, Device, pending.url)
            end, true))
        end
        return g
    end
    self:showSheet(field, build)
    local misses = 0
    local function poll()
        if self._sync_pending ~= token or self.closing or not self[field] then return stop() end
        local who, perr = Manager.pollSignIn(pending)
        if self._sync_pending ~= token then return end
        if who then
            close()
            return self:syncPreview()
        end
        if perr and perr.code == "IA-S206" then
            misses = 0
            return UIManager:scheduleIn(math.max(pending.interval or 5, perr.retry_after or 0), poll)
        end
        -- (the network not reached this once: asked again, unless it keeps failing)
        if perr and (perr.code == "IA-S101" or perr.code == "IA-S102") and misses < InkAwayView.SIGNIN_NET_MISSES then
            misses = misses + 1
            Manager.log("sign-in: the network was not reached (" .. perr.code .. "), asking again")
            return UIManager:scheduleIn(pending.interval or 5, poll)
        end
        close()
        self:syncErrorSheet(perr and perr.code or "IA-S503", { again = function() self:syncSignIn(pending.provider) end })
    end
    UIManager:scheduleIn(pending.interval or 5, poll)
end

-- The code from the cloud service, typed on the reader's keyboard.
function InkAwayView:syncAskCode(pending)
    local name = Providers.name(pending.provider)
    self:promptText{
        title = T(_("%1 code"), name),
        description = T(_("Type the code %1 showed after you tapped Allow."), name),
        ok_text = _("Connect"),
        on_cancel = function() end,
        on_ok = function(text) self:syncFinishCode(pending, text) end,
    }
end

-- Finish the sign-in with `code` (typed on the reader or pasted on the phone).
function InkAwayView:syncFinishCode(pending, code)
    local name = Providers.name(pending.provider)
    local close_wait = self:tell(T(_("Connecting to %1\u{2026}"), name), { wait = true, field = "_sync_wait" })
    UIManager:scheduleIn(0.3, function()
        local who, err = Manager.finishSignIn(pending, code)
        close_wait()
        if not who then
            return self:syncErrorSheet(err and err.code or "IA-S503", { again = function() self:syncSignIn(pending.provider) end })
        end
        self:syncPreview()
    end)
end

-- This copy of Ink Away is not registered with the service: the person can enter
-- their own registration (one or two values), one after the other.
function InkAwayView:syncAskAppKey(id)
    local name = Providers.name(id)
    local fields, got = Config.fields(id), {}
    local function ask(i)
        local f = fields[i]
        self:promptText{
            title = f.label, description = T(_("The %1 of your %2 app."), f.label, name), ok_text = i < #fields and _("Next") or _("Save"),
            on_ok = function(text)
                text = (text or ""):gsub("%s", "")
                if not f.valid(text) then
                    return self:tell(T(_("That does not look right. Copy it exactly as the %1 developer site shows it."), name))
                end
                got[i] = text
                if i < #fields then return ask(i + 1) end
                for n, fld in ipairs(fields) do Manager.set(fld.setting, got[n]) end
                self:syncSignIn(id)
            end,
        }
    end
    self:ask{
        title = T(_("%1 is not set up here"), name), field = "_sync_key",
        text = T(_("This copy of Ink Away is not registered with %1 yet. If you made an app of your own at the %1 developer site, enter its details to continue."), name),
        ok_text = _("Enter details"),
        on_ok = function() ask(1) end,
    }
end

------------------------------------------------------------------------------
-- Syncing, and what it says
------------------------------------------------------------------------------

-- Sync now, with the result shown when it ends.
function InkAwayView:syncNow(extra)
    self:leaveDocument()   -- the open notebook's latest changes go out too
    local o = extra or {}
    o.on_done = function(res) self:syncShowResult(res) end
    -- (a run that is already going, such as the one the notebook's closing began,
    -- is not an error: the sheet below shows it going)
    Manager.run("manual", o)
    if self[SHEET] then self:rebuildSheet(SHEET) end
end

-- The first sync, looked at before it is done: what would go where.
function InkAwayView:syncPreview()
    self:openSync()
    local close_wait = self:tell(_("Looking at what there is to sync\u{2026}"), { wait = true, field = "_sync_wait" })
    local _started, why = Manager.run("manual", { dry = true, on_done = function(res)
        close_wait()
        if res.fatal then return self:syncErrorSheet(res.fatal.code) end
        local n = { upload = 0, download = 0, conflict = 0, delete_remote = 0, delete_local = 0 }
        for _i, p in ipairs(res.plan or {}) do if n[p.action] then n[p.action] = n[p.action] + 1 end end
        local field = "_sync_preview"
        local content_w = self:sheetWidth()
        local function close() self:closeSheet(field) end
        local total = n.upload + n.download + n.conflict + n.delete_remote + n.delete_local
        self:showSheet(field, function()
            local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Ready to sync"), content_w, _("Not now"), close) }
            local function add(w) table.insert(g, w) end
            add(vspan(12))
            if total == 0 then
                add(para(self, _("Everything is already the same here and in the cloud."), content_w, 17))
            else
                if n.upload > 0 then add(para(self, T(_("%1 to send to the cloud"), n.upload), content_w, 17)); add(vspan(4)) end
                if n.download > 0 then add(para(self, T(_("%1 to download to this reader"), n.download), content_w, 17)); add(vspan(4)) end
                if n.conflict > 0 then
                    add(para(self, T(_("%1 changed in both places: both versions are kept"), n.conflict), content_w, 17)); add(vspan(4))
                end
                if n.delete_remote + n.delete_local > 0 then
                    add(para(self, T(_("%1 removed, with a safety copy"), n.delete_remote + n.delete_local), content_w, 17)); add(vspan(4))
                end
                add(vspan(6))
                add(self:sheetHint(_("Nothing on this reader is replaced or removed without a safety copy first."), content_w, 14))
            end
            add(vspan(16))
            add(self:actionButton(total == 0 and _("Done") or _("Start syncing"), content_w, function()
                close()
                if total > 0 then self:syncNow() end
            end, true))
            return g
        end)
    end })
    -- (a run already going never calls back: the waiting note must not stay)
    if why == "busy" then close_wait() end
end

-- The result of a sync that was asked for.
function InkAwayView:syncShowResult(res)
    if self.closing then return end
    self:closeSheet("_sync_wait")
    if res.fatal then return self:syncErrorSheet(res.fatal.code, { detail = res.fatal.detail }) end
    local field = "_sync_result"
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    local errs = res.errors or {}
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(#errs > 0 and _("Synced, with problems") or _("Synced"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(12))
        local any = false
        local function line(n, text) if n and n > 0 then any = true; add(para(self, T(text, n), content_w, 17)); add(vspan(4)) end end
        line(res.uploaded, _("%1 sent to the cloud"))
        line((res.downloaded or 0) - (res.conflicts or 0) - (res.merged or 0), _("%1 received"))
        line(res.merged, _("%1 combined from two readers"))
        line(res.conflicts, _("%1 kept in two versions"))
        line(res.deleted, _("%1 removed"))
        line(res.waiting, _("%1 will wait until closed"))
        if not any and #errs == 0 then add(para(self, _("Everything is already in sync."), content_w, 17)) end
        if #errs > 0 then
            add(vspan(8))
            add(self:sheetLabel(_("Problems"), true))
            add(vspan(4))
            for i, e in ipairs(errs) do
                if i > 6 then add(self:sheetHint(T(_("and %1 more, see the sync log"), #errs - 6), content_w, 13)); break end
                add(para(self, codeLine(e.code) .. (e.rel ~= "" and ("\n" .. Storage.baseName(e.rel)) or "")
                    .. (e.detail and e.detail ~= "" and ("\n" .. tostring(e.detail):sub(1, 90)) or ""), content_w, 14))
                add(vspan(4))
            end
            add(vspan(4))
            add(self:sheetHint(_("Each one is tried again at the next sync. Tap Details on the sync sheet for what to do."), content_w, 13))
        end
        if res.blocked_deletes then
            add(vspan(8))
            add(self:actionButton(_("Delete anyway\u{2026}"), content_w, function()
                close(); self:syncErrorSheet("IA-S505")
            end))
        end
        if (res.conflicts or 0) > 0 then
            add(vspan(10))
            add(self:actionButton(_("Look at the conflicts"), content_w, function() close(); self:syncConflicts() end, true))
        end
        return g
    end)
end

-- What an error means and what to do about it. `o`: again (a function for a retry), detail.
function InkAwayView:syncErrorSheet(code, o)
    o = o or {}
    local info = Errors.info(code)
    local field = "_sync_error"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(info.title, content_w, _("Close"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(10))
        add(para(self, info.what, content_w, 17))
        add(vspan(10))
        add(self:sheetLabel(_("What to do"), true))
        add(vspan(4))
        add(para(self, info.fix, content_w, 16))
        add(vspan(12))
        add(para(self, T(_("Code %1"), code), content_w, 14, true))
        if o.detail and o.detail ~= "" then add(self:sheetHint(tostring(o.detail):sub(1, 160), content_w, 11)) end
        add(vspan(14))
        if code == "IA-S505" then
            add(self:actionButton(_("Delete anyway\u{2026}"), content_w, function()
                close()
                self:ask{ title = _("Delete anyway?"), ok_text = _("Delete"), ok_icon = "trash",
                    text = _("A large part of your notebooks will be removed in the cloud or on this reader. A safety copy is kept on this reader for 30 days."),
                    on_ok = function() self:syncNow{ allow_mass_delete = true } end }
            end))
        elseif code == "IA-S506" then
            add(self:actionButton(_("Sync this folder as a new library"), content_w, function()
                close(); self:syncNow{ rebase = true }
            end))
        elseif code == "IA-S202" or code == "IA-S204" then
            add(self:actionButton(_("Connect again"), content_w, function()
                close(); Manager.signOut(); self:openSync()
            end, true))
        elseif o.again or info.retry then
            add(self:actionButton(o.again and _("Start again") or _("Try again"), content_w, function()
                close()
                if o.again then o.again() else self:syncNow() end
            end, true))
        end
        return g
    end)
end

------------------------------------------------------------------------------
-- This reader, conflicts, earlier versions, the log, disconnecting
------------------------------------------------------------------------------

function InkAwayView:syncRename()
    self:promptText{
        title = _("Name of this reader"), input = Manager.deviceName(),
        description = _("Shown in the names of conflict copies, so you can tell which reader a version came from."),
        ok_text = _("Save"),
        on_ok = function(text)
            text = (text or ""):gsub("[/\\:%c]", ""):sub(1, 24)
            if text == "" then text = nil end
            Manager.set("inkaway_sync_device", text)
            if self[SHEET] then self:rebuildSheet(SHEET) end
        end,
    }
end

-- The conflicts to settle, one button each.
function InkAwayView:syncConflicts()
    local field = "_sync_conflicts"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field); if self[SHEET] then self:rebuildSheet(SHEET) end end
    local list = Manager.conflicts()
    if #list == 0 then close(); return self:showNotice(_("No conflicts.")) end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Conflicts"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(8))
        add(self:sheetHint(_("These notebooks were changed on two readers. Both versions were kept: the one already in the cloud under its own name, and the one from this reader as a copy."), content_w, 14))
        for _i, c in ipairs(Manager.conflicts()) do
            add(vspan(10))
            add(self:actionButton(Storage.stem(c.orig), content_w, function() self:syncConflict(c) end, nil, nil, "notebook"))
        end
        return g
    end)
end

-- One conflict: keep this reader's version (the copy), the other reader's (the original
-- name, which now holds what the cloud had), or both.
function InkAwayView:syncConflict(c)
    local field = "_sync_conflict"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    local function settle(how)
        close()
        local ok, err = Manager.resolveConflict(c.copy, how)
        if not ok then return self:syncErrorSheet(err and err.code or "IA-S503") end
        self:refreshLibrary()
        self:syncConflicts()
    end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(Storage.stem(c.orig), content_w, _("Back"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(8))
        local root = Manager.root()
        local function size(rel)
            local n = Storage.size(Storage.join(root, rel))
            return n and string.format("%.1f KB", n / 1024) or "?"
        end
        add(para(self, _("Edited on this reader and on another reader since the last sync, so there are two versions. Nothing was lost."), content_w, 15))
        add(vspan(8))
        add(para(self, T(_("This reader's version: %1, %2"), Storage.stem(c.copy), size(c.copy)), content_w, 14))
        add(vspan(2))
        add(para(self, T(_("The other reader's version: %1, %2"), Storage.stem(c.orig), size(c.orig)), content_w, 14))
        add(vspan(14))
        add(self:actionButton(_("Keep this reader's version"), content_w, function() settle("copy") end, true))
        add(vspan(4))
        add(self:sheetHint(_("It replaces the other reader's version, here and on the other reader at the next sync. The version it replaces is kept in the backup folder."), content_w, 13))
        add(vspan(10))
        add(self:actionButton(_("Keep the other reader's version"), content_w, function() settle("original") end))
        add(vspan(4))
        add(self:sheetHint(_("This reader's version is removed, here and on the other reader at the next sync. It is kept in the backup folder."), content_w, 13))
        add(vspan(10))
        add(self:actionButton(_("Keep both"), content_w, function() settle("both") end))
        add(vspan(4))
        add(self:sheetHint(_("Nothing is removed. Both stay as separate notebooks, here and on the other reader."), content_w, 13))
        return g
    end)
end

-- The earlier versions of the open notebook.
function InkAwayView:syncVersions()
    local rel = Manager.relOf(self.doc_path)
    if not rel then return end
    local close_wait = self:tell(_("Asking the cloud\u{2026}"), { wait = true, field = "_sync_wait" })
    UIManager:scheduleIn(0.2, function()
        local list, err = Manager.versions(rel)
        close_wait()
        if not list then return self:syncErrorSheet(err and err.code or "IA-S503") end
        local field = "_sync_versions"
        local content_w = self:sheetWidth()
        local function close() self:closeSheet(field) end
        self:showSheet(field, function()
            local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Earlier versions"), content_w, _("Done"), close) }
            local function add(w) table.insert(g, w) end
            add(vspan(8))
            add(self:sheetHint(Storage.baseName(rel), content_w, 15))
            if #list == 0 then add(vspan(10)); add(para(self, _("The cloud has no other versions."), content_w, 16)) end
            for _i, v in ipairs(list) do
                add(vspan(8))
                local label = (v.mtime and os.date("%d %b %Y, %H:%M", v.mtime) or v.rev) .. (v.current and ("  \u{00B7}  " .. _("now")) or "")
                add(self:actionButton(label, content_w, function()
                    if v.current then return self:showNotice(_("This is the version you have.")) end
                    close()
                    self:ask{ title = _("Bring back this version?"), ok_text = _("Bring it back"),
                        text = T(_("The notebook becomes the version from %1. What is on this reader now is saved in the backup folder first."),
                            v.mtime and os.date("%d %b %Y, %H:%M", v.mtime) or v.rev),
                        on_ok = function()
                            local m, rerr = Manager.restoreVersion(rel, v.rev)
                            if not m then return self:syncErrorSheet(rerr and rerr.code or "IA-S503") end
                            self:syncNow()
                        end }
                end, nil, "small"))
            end
            return g
        end)
    end)
end

function InkAwayView:syncLog()
    local field = "_sync_log"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    self:showSheet(field, function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Sync log"), content_w, _("Done"), close) }
        table.insert(g, vspan(8))
        local lines = Manager.logTail(20)
        table.insert(g, TextBoxWidget:new{ text = #lines > 0 and table.concat(lines, "\n") or _("Nothing yet."),
            width = content_w, face = Font:getFace("cfont", 12) })
        return g
    end)
end

function InkAwayView:syncDisconnect()
    local name = Manager.status().provider_name or ""
    self:ask{
        title = T(_("Disconnect %1?"), name), ok_text = _("Disconnect"), ok_icon = "exit",
        text = _("Notebooks on this reader and in the cloud stay as they are. This reader stops syncing. You can connect again at any time."),
        on_ok = function()
            Manager.signOut()
            self:closeSheet(SHEET)
            self:openSync()
        end,
    }
end

------------------------------------------------------------------------------
-- Hooks from the rest of Ink Away
------------------------------------------------------------------------------

-- The open notebook was saved.
function InkAwayView:syncNoteSaved()
    pcall(Manager.noteChanged)
end

-- A notebook is no longer open (it was saved just before).
function InkAwayView:syncNoteLeft()
    pcall(Manager.setOpen, {})
    pcall(Manager.noteClosed)
end

-- A notebook is open.
function InkAwayView:syncNoteOpened(path)
    local rel = Manager.relOf(path)
    pcall(Manager.setOpen, rel and { rel } or {})
end

-- A notebook was tapped in the library: look for a newer version of it first
-- (a few seconds at most), then open it. Returns whether the opening was taken over.
function InkAwayView:syncPreOpen(path, open)
    local opts = Manager.options()
    if not (opts.enabled and opts.on_open and Manager.connected() and Manager.relOf(path)) then return false end
    local close_wait = self:tell(_("Looking for a newer version\u{2026}"), { wait = true, field = "_sync_wait" })
    Manager.preOpen(path, function()
        close_wait()
        if not self.closing then open() end
    end)
    return true
end

return InkAwayView
