--[[
Updates, on screen: the Updates button in Settings, the Updates sheet (the
release and, apart from it, the prerelease, each with its notes), installing
one, and telling the reader when the once-a-day check found something new: a
small dot on the toolbar's Settings button until the sheet has been opened,
and a toast at the top, once per version, that goes at the first touch and
lets that touch through. The checking and installing are ink/update/*.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Policy = require("ink/update/policy")
local Updater = require("ink/update/updater")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local LABEL = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF)

local function S(px) return Screen:scaleBySize(px) end
-- A translated text with %1, %2... filled in (as KOReader's template).
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
local function vspan(px) return VerticalSpan:new{ width = S(px) } end

local InkAwayView = {}

-- The version running, from the plugin's own _meta.lua.
function InkAwayView:inkVersion()
    if not self._ink_version then self._ink_version = Updater.version(self:pluginDir()) or "0.0.0" end
    return self._ink_version
end

-- The plugin folder, without a trailing slash.
function InkAwayView:pluginFolder()
    return (self:pluginDir():gsub("/+$", ""))
end

-- A release's date as a reader reads it ("12 Oct 2026"), or "".
local function dateText(iso)
    local y, m, d = tostring(iso or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return "" end
    return os.date("%d %b %Y", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function sizeText(n)
    return n and (n >= 1024 * 1024 and string.format("%.1f MB", n / 1024 / 1024)
        or string.format("%d KB", math.floor(n / 1024 + 0.5))) or ""
end

------------------------------------------------------------------------------
-- Opening: tidying after an update, and the once-a-day check
------------------------------------------------------------------------------

-- When the canvas opens: remove the copy an update replaced (once the new
-- version runs), show the dot if there is news not yet looked at, and if a
-- check is due, run one a little later (so opening never waits on it). Not
-- over a book.
function InkAwayView:updatesOnOpen()
    if self.reader_mode or self.floating then return end
    local cur = self:inkVersion()
    Updater.cleanup(self:pluginFolder(), cur)
    self._update_dot = Updater.unseen(cur)
    if not Updater.due() then return end
    self._update_check_cb = self._update_check_cb or function() self:autoCheckUpdates() end
    UIManager:scheduleIn(10, self._update_check_cb)
end

function InkAwayView:autoCheckUpdates()
    if self.closing then return end
    Updater.autoCheck(self:inkVersion(), function(v)
        if self.closing then return end   -- the dot shows next time
        self._update_dot = true
        self:refreshToolbarStrip()
        self:showNotice(T(_("Ink Away %1 is available: Settings, Updates."), v), 6)
    end)
end

-- Stop a check waiting to start (the canvas is closing). One already running
-- finishes on its own and is remembered.
function InkAwayView:updatesOnClose()
    if self._update_check_cb then UIManager:unschedule(self._update_check_cb) end
end

-- Repaint the toolbar strip (the dot came or went).
function InkAwayView:refreshToolbarStrip()
    if self.closing or not self.view then return end
    self._area_only = false
    UIManager:setDirty(self, "ui", GeomUI:new{ x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

-- The dot on the Settings button: news not yet looked at.
function InkAwayView:paintUpdateDot(bb, ox, oy)
    self._update_dot_rect = nil
    if not (self._update_dot and self._btn_w and self._bar_h and self._toolbar_icons) or self._toolbar_hidden then return end
    local idx
    for i, e in ipairs(self._toolbar_icons) do if e.id == "menu" then idx = i end end
    if not idx then return end
    local isz = self._icon_sz or math.floor(self._bar_h * 0.6)
    local d = math.max(6, S(8))
    local cx = ox + self._btn_w * (idx - 1) + math.floor((self._btn_w + isz) / 2) - math.floor(d / 2)
    local cy = oy + math.floor((self._bar_h - isz) / 2) - math.floor(d / 4)
    cx, cy = math.min(cx, ox + self._btn_w * idx - d - 1), math.max(oy + 1, cy)
    Accent.paintRounded(bb, cx, cy, d, d, math.floor(d / 2))
    self._update_dot_rect = { x = cx, y = cy, w = d, h = d, r = math.floor(d / 2) }
end

------------------------------------------------------------------------------
-- Settings and the Updates sheet
------------------------------------------------------------------------------

-- What the Updates button says when there is news (an update found, or one
-- installed and waiting for a restart), or nil.
function InkAwayView:updateNews()
    if self.reader_mode or self.floating then return nil end
    if Updater.installed then return T(_("Restart KOReader to use %1"), Updater.installed) end
    local v = Updater.available(self:inkVersion())
    return v and T(_("Update available: %1"), v) or nil
end

-- The Updates button for Settings, w wide: the news, filled, or a plain
-- Updates.
function InkAwayView:updatesButton(w, before)
    local news = self:updateNews()
    return self:actionButton(news or _("Updates"), w, function()
        if before then before() end
        self:openUpdates()
    end, news ~= nil, nil, "update")
end

-- Start a check now, asking KOReader to connect first if it is offline, and
-- show the sheet again when it ends.
function InkAwayView:checkUpdatesNow()
    local cur = self:inkVersion()
    local function run()
        local started = Updater.check(cur, function()
            if self._updates then self:rebuildSheet("_updates") end
        end, true)
        if not started and not Updater.busy then
            Updater.error = Updater.error or _("a check could not start")
        end
        if self._updates then self:rebuildSheet("_updates") end
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then NetworkMgr:runWhenOnline(run) else run() end
end

-- A release's card: its kind, version and date, a line about it, What's new,
-- and its action (or a note that it is the one installed).
function InkAwayView:releaseCard(content_w, kind, rel, action, notes_of)
    local col = VerticalGroup:new{ align = "left" }
    col[#col + 1] = self:sheetLabel(kind, true)
    col[#col + 1] = vspan(4)
    local head = rel.version .. ((rel.date and rel.date ~= "") and ("  ·  " .. dateText(rel.date)) or "")
    col[#col + 1] = TextWidget:new{ text = head, face = Font:getFace("cfont", 20), bold = true, fgcolor = BLACK,
        max_width = content_w }
    local line
    if action == "update" then line = T(_("A newer release, %1 to download."), sizeText(rel.size))
    elseif action == "back" then line = T(_("Go back from this version to the latest release (%1)."), sizeText(rel.size))
    elseif action == "try" then line = T(_("A test build before the next release: newer things, maybe rough edges. You can go back to the release here any time. %1."), sizeText(rel.size))
    elseif action == "current" then line = _("You have this version.") end
    if line then
        col[#col + 1] = vspan(4)
        col[#col + 1] = self:sheetHint(line, content_w, 14)
    end
    col[#col + 1] = vspan(10)
    local gap = S(12)
    local half = math.floor((content_w - gap) / 2)
    local notes = self:actionButton(_("What's new"), (action == "current") and content_w or half, function()
        self:openReleaseNotes(notes_of, kind)
    end)
    if action == "current" then
        col[#col + 1] = notes
    else
        local label = (action == "back" and _("Go back to it")) or (action == "try" and _("Try it")) or _("Install")
        col[#col + 1] = HorizontalGroup:new{ align = "center", notes, HorizontalSpan:new{ width = gap },
            self:actionButton(label, half, function() self:confirmUpdate(rel, action) end, true) }
    end
    return col
end

-- The Updates sheet.
function InkAwayView:openUpdates()
    self:closeSheet("_settings_dialog")
    local cur = self:inkVersion()
    local content_w = self:sheetWidth()
    -- opening the sheet is looking at the news: the dot goes
    local avail = Updater.available(cur)
    if avail then Updater.set("seen", avail) end
    if self._update_dot then self._update_dot = false; self:refreshToolbarStrip() end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Updates"), content_w, _("Done"), function() self:closeSheet("_updates") end))
        add(vspan(12))
        local o = Updater.offers
        local kind = o and o.on_pre and (o.pre and Policy.compare(o.pre.version, cur) == 0 and _("a prerelease")
            or _("a test build")) or _("a release")
        add(TextWidget:new{ text = T(_("Ink Away %1"), cur) .. (o and ("  ·  " .. kind) or ""),
            face = Font:getFace("cfont", 17), bold = true, fgcolor = LABEL, max_width = content_w })
        add(vspan(12))
        if Updater.installed then
            add(self:sheetHint(T(_("%1 is installed. Restart KOReader to use it."), Updater.installed), content_w, 15))
            add(vspan(10))
            add(self:actionButton(_("Restart KOReader"), content_w, function() UIManager:askForRestart() end, true))
        elseif Updater.busy == "installing" then
            add(self:sheetHint(_("Downloading and checking the update…"), content_w, 15))
        elseif Updater.busy == "checking" then
            add(self:sheetHint(_("Asking GitHub what there is…"), content_w, 15))
        elseif o then
            if o.stable then
                add(self:releaseCard(content_w, _("Release"), o.stable, o.stable_action,
                    (o.stable_action == "update" and #o.since > 0) and o.since or { o.stable }))
            else
                add(self:sheetHint(_("No release found on GitHub."), content_w, 14))
            end
            if o.pre then
                add(vspan(18))
                add(self:releaseCard(content_w, _("Prerelease"), o.pre, o.pre_action, { o.pre }))
            end
        elseif Updater.error then
            add(self:sheetHint(T(_("Could not check: %1."), Updater.error), content_w, 15))
        end
        add(vspan(18))
        add(ToggleRow:new{ label = _("Check once a day"), is_on = Updater.autoOn(), width = content_w, parent = menu,
            callback = function(on) Updater.set("auto", on) end })
        add(vspan(4))
        add(ToggleRow:new{ label = _("Tell me about prereleases"), is_on = Updater.preOn(), width = content_w, parent = menu,
            callback = function(on) Updater.set("pre", on) end })
        add(vspan(6))
        local last = Updater.get("last")
        add(self:sheetHint((last and T(_("Last checked %1."), os.date("%d %b, %H:%M", last)) or _("Not checked yet."))
            .. " " .. _("On its own Ink Away looks once a day, when it opens on Wi-Fi; it never turns Wi-Fi on."), content_w, 13))
        if not Updater.busy and not Updater.installed then
            add(vspan(10))
            add(self:actionButton(_("Check now"), content_w, function() self:checkUpdatesNow() end))
        end
        return content
    end
    self:showSheet("_updates", build)
    -- nothing known this session: look now when already online
    if not Updater.offers and not Updater.busy and not Updater.installed then
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if ok and NetworkMgr and NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then self:checkUpdatesNow() end
    end
end

-- Release notes, newest first: each release's version and date, then its notes.
function InkAwayView:openReleaseNotes(list, kind)
    local content_w = self:sheetWidth()
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("What's new"), content_w, _("Back"), function()
            self:closeSheet("_release_notes")
            self:openUpdates()
        end))
        for i, rel in ipairs(list) do
            add(vspan(i == 1 and 12 or 22))
            add(TextWidget:new{ text = rel.version .. ((rel.date and rel.date ~= "") and ("  ·  " .. dateText(rel.date)) or ""),
                face = Font:getFace("cfont", 20), bold = true, fgcolor = BLACK, max_width = content_w })
            if rel.pre then add(self:sheetLabel(kind or _("Prerelease"))) end
            local blocks = Policy.notes(rel.notes)
            if #blocks == 0 then
                add(vspan(6))
                add(self:sheetHint(_("No notes for this version."), content_w, 14))
            end
            for _j, b in ipairs(blocks) do
                if b.kind == "h" then
                    add(vspan(10))
                    add(TextBoxWidget:new{ text = b.text, width = content_w, face = Font:getFace("cfont", 17),
                        bold = true, fgcolor = BLACK })
                elseif b.kind == "li" then
                    add(vspan(3))
                    local indent = S(6 + 16 * (b.depth or 0))
                    add(HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = indent },
                        TextBoxWidget:new{ text = "\u{2022}  " .. b.text, width = content_w - indent,
                            face = Font:getFace("cfont", 15), fgcolor = BLACK } })
                else
                    add(vspan(6))
                    add(TextBoxWidget:new{ text = b.text, width = content_w, face = Font:getFace("cfont", 15),
                        fgcolor = BLACK })
                end
            end
        end
        return content
    end
    self:closeSheet("_updates")
    self:showSheet("_release_notes", build)
end

-- Ask before installing `rel` (offered as `action`), then install it.
function InkAwayView:confirmUpdate(rel, action)
    local title = (action == "back" and T(_("Go back to %1?"), rel.version))
        or (action == "try" and T(_("Try %1?"), rel.version)) or T(_("Install %1?"), rel.version)
    local text = T(_("Ink Away downloads it from GitHub (%1) and checks it before it replaces this version; then KOReader restarts to use it. Your drawings, notebooks and settings stay as they are."), sizeText(rel.size))
    if action == "try" then
        text = text .. "\n\n" .. _("A prerelease is a test build. You can go back to the latest release from Settings, Updates.")
    end
    self:ask{ field = "_update_confirm", title = title, text = text,
        ok_text = (action == "back" and _("Go back")) or _("Install"), on_ok = function() self:installUpdate(rel) end }
end

function InkAwayView:installUpdate(rel)
    local function show()
        if self._updates then self:rebuildSheet("_updates") else self:openUpdates() end
    end
    Updater.install(rel, self:pluginFolder(), function(ok, why)
        if ok then
            show()
            UIManager:askForRestart(T(_("Ink Away %1 is installed. Restart KOReader to use it."), rel.version))
        else
            self:tell(T(_("The update was not installed: %1.\n\nNothing was changed."), tostring(why)),
                { title = _("Not installed"), field = "_update_failed" })
        end
    end)
    show()
end

return InkAwayView
