--[[
The settings sheet (gear) and its sub-sheets: the grid and a list chooser. On a
colour screen it also sets the theme colour (see ink/accent.lua).
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Blitbuffer = require("ffi/blitbuffer")
local PenTest = require("ink/pentest")
local Theme = require("ink/ui/theme")
local Palette = require("ink/palette")
local Storage = require("ink/storage")
local SliderRow = require("ink/ui/controls").SliderRow
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"), iso = _("isometric"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank"), checklist = _("checklist"),
    twocol = _("2 columns"), weekly = _("weekly"), monthly = _("monthly"), storyboard = _("storyboard"),
    music = _("music"), handwriting = _("handwriting"), daily = _("daily"), weekcols = _("week columns"),
    meeting = _("meeting notes"), habits = _("habit tracker") }

local InkAwayView = {}

-- Choose the library folder. Picking Ink Away's own folder goes back to the
-- default.
function InkAwayView:chooseLibraryRoot()
    self:pickFolder(self:libraryDir(), function(dir)
        dir = dir:gsub("/+$", "")
        if dir == Storage.appRoot() then dir = nil end
        self:setSetting("inkaway_library_dir", dir)
        self:showNotice(string.format(_("Library folder: %s"), Storage.shortPath(self:libraryDir())))
    end)
end

-- Choose the folder exports go to. Picking "ink away/exports" goes back to the
-- default.
function InkAwayView:chooseExportRoot()
    self:pickFolder(self:defaultExportDir(), function(dir)
        dir = dir:gsub("/+$", "")
        if dir == Storage.appDir("exports") then dir = nil end
        self:setSetting("inkaway_export_dir", dir)
        self:showNotice(string.format(_("Export folder: %s"), Storage.shortPath(self:defaultExportDir())))
    end)
end

-- Use colour {r,g,b} for the buttons (black is {0,0,0}) and remember it; nil
-- goes back to the default, Ink Away green. Only the colour is kept; everything
-- drawn in it is drawn again as it is needed.
function InkAwayView:setAccent(rgb)
    self:setSetting("inkaway_accent", rgb and { rgb[1], rgb[2], rgb[3] } or nil)
    Accent.apply(rgb, self:colorScreen())
    -- what was built in the old colour: the Paste bubble, the text box's Done
    -- button and the active tool's icon (brush samples are kept by colour)
    if self._clip_widget then
        if self._clip_widget.free then self._clip_widget:free() end
        self._clip_widget = nil
    end
    local tm = self._text_btn_metrics
    if tm then
        for _, w in ipairs({ tm.fw, tm.dw }) do if w and w.free then w:free() end end
        self._text_btn_metrics = nil
    end
    -- only the toolbar shows the colour on the canvas (its active tool)
    self:updateToolbarActive()
    UIManager:setDirty(self, "ui", self.toolbar and self.toolbar.dimen or nil)
end

-- The colours last picked on the wheel, newest first (at most two). A colour in
-- use that is not among them (one chosen before they were kept) counts as the
-- newest; one that is stays where it is, so a box does not move when tapped.
function InkAwayView:accentRecent()
    local list = Accent.remember(self:getSetting("inkaway_accent_recent"), nil, 2)
    local cur = Accent.get().rgb
    if cur and not Accent.builtin(cur) then
        for _, c in ipairs(list) do if Accent.same(c, cur) then return list end end
        list = Accent.remember(list, cur, 2)
    end
    return list
end

-- Choose the theme colour on the colour wheel the pen uses; Use applies it,
-- keeps it among the last two picked, and the settings sheet comes back.
function InkAwayView:chooseAccent()
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    self:closeSheet("_settings_dialog")
    UIManager:show(ColorPicker:new{
        title = _("Theme Color"),
        color = Accent.get().rgb or Accent.PRESETS[1],
        on_pick = function(rgb)
            self:setSetting("inkaway_accent_recent", Accent.remember(self:accentRecent(), rgb, 2))
            self:setAccent(rgb)
            self:openSettings()
        end,
    })
end

-- The theme colour row: Ink Away green (the default, captioned so), black, the
-- ready-made colours, the last two picked on the wheel (empty boxes until then)
-- and the wheel, each a box the size of a swatch, spread across `width`, the one
-- in use framed. A tap uses a colour at once.
function InkAwayView:accentRow(width)
    local sw, sh = Screen:scaleBySize(56), Screen:scaleBySize(48)
    local min_gap = Screen:scaleBySize(6)
    local n = math.max(6, math.floor((width + min_gap) / (sw + min_gap)))
    local gap = math.floor((width - n * sw) / (n - 1))
    local cur = Accent.get().rgb or { 0, 0, 0 }
    local function use(rgb)
        return function()
            self:setAccent(rgb)
            self:openSettings()
        end
    end
    local green = Accent.SIGNATURE
    local tiles = {
        VerticalGroup:new{ align = "center",
            self:swatchTile(green, Accent.same(cur, green), sw, use(green), nil, sh),
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            self:sheetLabel(_("Default")) },
        self:swatchTile({ 0, 0, 0 }, Accent.same(cur, { 0, 0, 0 }), sw, use({ 0, 0, 0 }), nil, sh),
    }
    for i = 1, math.min(#Accent.PRESETS, n - 5) do
        local p = Accent.PRESETS[i]
        tiles[#tiles + 1] = self:swatchTile(p, Accent.same(cur, p), sw, use(p), nil, sh)
    end
    local recent = self:accentRecent()
    for i = 1, 2 do
        local c = recent[i]
        tiles[#tiles + 1] = c and self:swatchTile(c, Accent.same(cur, c), sw, use(c), nil, sh)
            or self:emptySlot(sw, sh)
    end
    tiles[#tiles + 1] = self:wheelTile(sw, sh, function() self:chooseAccent() end)
    local row = HorizontalGroup:new{ align = "top" }   -- (the caption hangs below)
    for i, t in ipairs(tiles) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, t)
    end
    return row
end

-- A "pick one" sub-sheet: a stack of full-width buttons, the current one black.
-- `options` is a list of { value, label }; onpick(value) runs after it closes.
function InkAwayView:openChooserSheet(title, options, current, onpick)
    self:closeSheet("_chooser_dialog")
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_chooser_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(title, content_w, _("Done"), closeSelf))
        add(vspan(16))
        for i, o in ipairs(options) do
            if i > 1 then add(vspan(8)) end
            add(self:actionButton(o[2], content_w,
                function() closeSelf(); onpick(o[1]) end, current == o[1]))
        end
        return content
    end
    self:showSheet("_chooser_dialog", build)
end

-- The grid sub-sheet: type, size and opacity, opened from the settings sheet's
-- Grid button. Picking a type rebuilds it in place; the sliders refresh the grid
-- behind the sheet as they move.
function InkAwayView:openGridSettings()
    if self:rebuildSheet("_grid_dialog") then return end
    local content_w = self:sheetWidth()
    -- "Off" remembers the last style, so turning the grid back on restores it.
    -- Only the type switches the grid on; size and opacity are kept for next time.
    local function pick(v)
        if v == "off" then
            self.grid_on = false; self:setSetting("inkaway_grid", false)
        else
            self.grid_style = v; self:setSetting("inkaway_grid_style", v)
            self.grid_on = true; self:setSetting("inkaway_grid", true)
        end
        self:renderView(); self:refreshArea(); self:openGridSettings()
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Grid"), content_w, _("Done"),
            function() self:closeSheet("_grid_dialog"); self:openSettings() end))
        add(vspan(16))

        -- type: rows of three, Off first, then the guides and the planner pages
        local cur = self.grid_on and self.grid_style or "off"
        add(self:segmentedRow({ { "off", _("Off") }, { "square", _("Square") }, { "dots", _("Dots") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "lines", _("Lines") }, { "iso", _("Isometric") }, { "thirds", _("Thirds") } },
            cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "checklist", _("Checklist") }, { "twocol", _("2 columns") },
            { "weekly", _("Weekly") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "monthly", _("Monthly") }, { "storyboard", _("Storyboard") },
            { "music", _("Music") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "handwriting", _("Handwriting") }, { "daily", _("Daily") },
            { "weekcols", _("Week columns") } }, cur, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ { "meeting", _("Meeting notes") }, { "habits", _("Habit tracker") },
            { "cornell", _("Cornell") } }, cur, content_w, pick))
        add(vspan(16))

        -- size and opacity, refreshing the grid behind the sheet as they move
        add(SliderRow:new{ label = _("Size"), value = self.grid_size, min = 8, max = 200, step = 2,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.grid_size = v; self:setSetting("inkaway_grid_size", v)
                self:renderView(); self:refreshArea() end })
        add(vspan(12))
        add(SliderRow:new{ label = _("Opacity"), value = self.grid_strength, min = 5, max = 100, step = 5,
            width = content_w, parent = menu,
            on_set = function(v) self.grid_strength = v; self:setSetting("inkaway_grid_strength", v)
                self:renderView(); self:refreshArea() end })
        return content
    end
    self:showSheet("_grid_dialog", build)
end

-- Put the zoom and Pan buttons at the "right" or "left", or hide them.
function InkAwayView:setFabSide(side)
    self.fab_side = side
    self:setSetting("inkaway_fab_side", side)
    self._blit_rect = nil
    UIManager:setDirty(self, "ui")
    self:openSettings()
end

-- The settings sheet (gear): orientation, the grid or notebook paper, the
-- symmetry and ghosting options, and where files are kept.
function InkAwayView:openSettings()
    self:resetLasso()   -- drop any selection first
    -- the field may hold a dialog without a rebuild; close it and open fresh
    if self:rebuildSheet("_settings_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_settings_dialog") end
    local function act(label, w, cb, dark, icon)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark, nil, icon)
    end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Settings"), content_w, _("Done"), closeSelf, nil, {
            { icon = "coffee", cb = function() self:openSupport() end },
            { icon = "appearance", cb = function() self:openAppearance() end },
            { label = _("Guide"), cb = function() self:openGuide() end } }))
        add(vspan(16))
        -- news from the update check, on top (where a long sheet never hides it)
        if self:updateNews() then
            add(self:updatesButton(content_w, closeSelf))
            add(vspan(16))
        end

        -- orientation: picking one closes the sheet, as the screen size changes
        if self:orientationSupported() then
            add(self:sheetLabel(_("Orientation"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "portrait", _("Portrait") }, { "landscape", _("Landscape") } },
                self:orientationClass(), content_w,
                function(v) closeSelf(); self:setOrientation(v) end))
            add(vspan(16))
        end

        -- the toolbar: across the top, or down the left or right of the screen
        add(self:sheetLabel(_("Toolbar side"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "top", _("Top") }, { "left", _("Left") }, { "right", _("Right") } },
            self:canvasBarSide(), content_w, function(side)
                closeSelf(); self:setCanvasBarSide(side); self:openSettings()
            end))
        add(vspan(16))

        -- the zoom and Pan buttons: at either side, or none (pinch and two
        -- fingers do the same)
        add(self:sheetLabel(_("Zoom and Pan buttons"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "right", _("Right") }, { "left", _("Left") }, { "hidden", _("Hidden") } },
            self.fab_side, content_w, function(side) self:setFabSide(side) end))
        if self.fab_side == "hidden" then
            add(vspan(4))
            add(self:sheetHint(_("Pinch to zoom, and drag with two fingers to move around the page."), content_w))
        end
        add(vspan(16))

        -- the theme colour, on a colour screen
        if self:colorScreen() then
            add(self:sheetLabel(_("Theme Color"), true))
            add(vspan(6))
            add(self:accentRow(content_w))
            add(vspan(16))
            add(ToggleRow:new{ label = _("Colour while drawing"), is_on = self.live_colour,
                width = content_w, parent = menu,
                callback = function(on) self.live_colour = on; self:setSetting("inkaway_live_colour", on) end })
            add(vspan(4))
            add(self:sheetHint(_("Off: colour ink shows black until the pen rests, which reads more clearly on some colour e-ink screens."), content_w))
            add(vspan(16))
            add(ToggleRow:new{ label = _("Keep colours in night mode"),
                is_on = self:getSetting("inkaway_night_colours", true) ~= false,
                width = content_w, parent = menu, callback = function(on)
                    self:setSetting("inkaway_night_colours", on)
                    self:nightModeChanged(true)
                end })
            add(vspan(4))
            add(self:sheetHint(_("In KOReader's night mode, ink keeps its colour: blue stays blue, and dark ink turns light so it reads on the dark page."), content_w))
            add(vspan(16))
        end

        -- grid (canvas) or paper (notebook), and beside it the paper's colour
        local half = math.floor((content_w - Screen:scaleBySize(12)) / 2)
        local paper_name = Palette.paperName(self:paperRGB())
        if self.notebook then
            local t = self.notebook.template
            add(HorizontalGroup:new{ align = "center",
                act(string.format(_("Paper: %s"), TEMPLATE_LABEL[t.style or "lines"] or t.style), half, function()
                    self:openPaperSheet{ title = _("Notebook paper"), current = t.style, onpick = function(v)
                        t.style = v; self.nb_style = v; self:setSetting("inkaway_nb_style", v); self:markDirty()
                        self:composeCanvas(); self:renderView(); self:refreshArea(); self:openSettings()
                    end }
                end, nil, "page"),
                HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                self:paperColourButton(string.format(_("Colour: %s"), paper_name), half, function() self:openPaperColour() end) })
            add(vspan(12))
            add(SliderRow:new{ label = _("Line spacing"), value = t.size or 40, min = 12, max = 200, step = 2,
                width = content_w, parent = menu, format = pxfmt,
                on_set = function(v) t.size = v; self.nb_size = v; self:setSetting("inkaway_nb_size", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(SliderRow:new{ label = _("Line strength"), value = t.strength or 45, min = 5, max = 100, step = 5,
                width = content_w, parent = menu,
                on_set = function(v) t.strength = v; self.nb_strength = v; self:setSetting("inkaway_nb_strength", v)
                    self:markDirty(); self:composeCanvas(); self:renderView(); self:refreshArea() end })
        else
            -- one button to the grid sub-sheet, labelled with the current grid
            local GRID_LABEL = { off = _("Off"), square = _("Square"), dots = _("Dots"),
                lines = _("Lines"), iso = _("Isometric"), thirds = _("Thirds"), checklist = _("Checklist"),
                twocol = _("2 columns"), weekly = _("Weekly"), monthly = _("Monthly"),
                storyboard = _("Storyboard"), music = _("Music"), handwriting = _("Handwriting"),
                daily = _("Daily"), weekcols = _("Week columns"), meeting = _("Meeting notes"),
                habits = _("Habit tracker"), cornell = _("Cornell") }
            local cur = self.grid_on and self.grid_style or "off"
            add(HorizontalGroup:new{ align = "center",
                act(string.format(_("Grid: %s"), GRID_LABEL[cur] or cur), half, function() self:openGridSettings() end, nil, "grid"),
                HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                self:paperColourButton(string.format(_("Paper: %s"), paper_name), half, function() self:openPaperColour() end) })
        end
        add(vspan(16))

        -- symmetry rebuilds the sheet in place with the highlight moved
        add(self:sheetLabel(_("Symmetry"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "off", _("Off") }, { "vert", _("Vertical") }, { "horiz", _("Horizontal") },
                { "quad", _("Four-way") } }, self.symmetry, content_w,
            function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v); self:openSettings() end))
        add(vspan(14))

        -- ghosting cleanup: a full refresh every N strokes, 0 (off) to 50 in steps of 5
        add(SliderRow:new{ label = _("Ghosting"), value = math.min(50, self.ghost_clean or 0), min = 0, max = 50, step = 5,
            width = content_w, parent = menu,
            format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
            on_set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                self._strokes_since_full = 0 end })
        add(vspan(4))
        add(self:sheetHint(_("Fast strokes leave faint marks; a full refresh clears them this often."), content_w))
        add(vspan(10))
        -- one full refresh now, as the "Refresh the screen" gesture does
        add(act(_("Refresh the screen"), content_w, function() self:refreshScreen() end, nil, "refresh"))
        add(vspan(16))

        -- where documents are kept, and what opening Ink Away shows
        add(self:sheetLabel(_("Files"), true))
        add(vspan(6))
        -- the library and export folders side by side, each named for its folder
        add(HorizontalGroup:new{ align = "center",
            act(string.format(_("Library: %s"), Storage.baseName(self:libraryDir())), half,
                function() self:chooseLibraryRoot() end, nil, "library"),
            HorizontalSpan:new{ width = Screen:scaleBySize(12) },
            act(string.format(_("Exports: %s"), Storage.baseName(self:defaultExportDir())), half,
                function() self:chooseExportRoot() end, nil, "export") })
        add(vspan(10))
        add(self:sheetLabel(_("When Ink Away opens")))
        add(vspan(6))
        add(self:segmentedRow({ { "last", _("Last document") }, { "library", _("Library") },
                { "notebooks", _("Notebooks") } },
            self:getSetting("inkaway_start", "last"), content_w,
            function(v) self:setSetting("inkaway_start", v); self:openSettings() end))
        -- (palm rejection, the stabilizer and the pen test are in the Pen
        -- sheet's Pen and input, set from where the pen is)
        add(vspan(16))
        -- the gestures, and beside them Updates (what is new, when there is news)
        add(HorizontalGroup:new{ align = "center",
            act(_("Gestures and pen buttons"), half, function()
                self:closeSheet("_settings_dialog"); self:openGestureSettings() end, nil, "ges_tap"),
            HorizontalSpan:new{ width = Screen:scaleBySize(12) },
            self:actionButton(_("Updates"), half, function() closeSelf(); self:openUpdates() end, nil, nil, "update") })
        return content
    end
    self:showSheet("_settings_dialog", build)
end

-- Light, dark or as KOReader's night mode: Ink Away's own controls (see
-- ink/ui/theme.lua). The page is never changed.
function InkAwayView:openAppearance()
    self:closeSheet("_settings_dialog")
    local content_w = self:sheetWidth()
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Appearance"), content_w, _("Done"), function() self:closeSheet("_appearance") end))
        add(vspan(12))
        add(self:segmentedRow({ { "light", _("Light") }, { "dark", _("Dark") }, { "system", _("System") } },
            Theme.mode(), content_w, function(m)
                self:setSetting(Theme.SETTING, m)
                self._paint_all = true
                self:rebuildSheet("_appearance")
                UIManager:setDirty("all", "ui")
            end))
        add(vspan(6))
        add(self:sheetHint(_("Dark turns Ink Away's toolbars and menus dark; the page stays as it is. System follows KOReader's night mode."), content_w))
        return content
    end
    self:showSheet("_appearance", build)
end

-- A quiet note from the maker, one tap from Settings: a QR code for the coffee
-- page and a few plain words. The code is black on white so it always scans; the
-- rest takes the theme colour.
local SUPPORT_URL = "https://buymeacoffee.com/emirertorer"
function InkAwayView:openSupport()
    self:closeSheet("_settings_dialog")
    local content_w = self:sheetWidth()
    local build = function()
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local Font = require("ui/font")
        local content = VerticalGroup:new{ align = "center" }
        local function add(w) table.insert(content, w) end
        local function para(text, size, bold, color)
            return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold,
                fgcolor = color, width = content_w, alignment = "center" }
        end
        add(self:sheetTitle(_("Support"), content_w, _("Done"), function() self:closeSheet("_support") end))
        add(vspan(14))
        local side = math.floor(math.min(content_w * 0.34, math.min(Screen:getWidth(), Screen:getHeight()) * 0.28))
        local okq, QRWidget = pcall(require, "ui/widget/qrwidget")
        if okq and QRWidget then
            add(CenterContainer:new{ dimen = Geom:new{ w = content_w, h = side },
                QRWidget:new{ text = SUPPORT_URL, width = side, height = side } })
            add(vspan(12))
        end
        local a = Accent.get()
        local FrameContainer = require("ui/widget/container/framecontainer")
        local TextWidget = require("ui/widget/textwidget")
        add(CenterContainer:new{ dimen = Geom:new{ w = content_w, h = Screen:scaleBySize(34) },
            FrameContainer:new{ background = a.fill, bordersize = 0, radius = Screen:scaleBySize(11),
                padding = Screen:scaleBySize(6), padding_left = Screen:scaleBySize(14), padding_right = Screen:scaleBySize(14),
                margin = 0, TextWidget:new{ text = _("Scan with your phone"), face = Font:getFace("cfont", 14),
                    bold = true, fgcolor = a.text } } })
        add(vspan(4))
        add(para("buymeacoffee.com/emirertorer", 14, false, Blitbuffer.COLOR_DARK_GRAY))
        add(vspan(14))
        add(para(_("Ink Away is free and made by one person. If it makes your writing better, a coffee helps keep it going."), 15))
        return content
    end
    self:showSheet("_support", build)
end

-- The faster-drawing tip for this reader, or nil: none where KOReader drives
-- the panel fully. When `auto` (shown unasked), none on a Boox either, where Ink
-- Away asks for the fast refresh itself (unless the reader turned that off).
function InkAwayView:deviceTipText(auto)
    if not self:onAndroid() then return nil end
    local ok, facts = pcall(function() return require("ink/ui/pentestscreen").deviceFacts() end)
    if not ok then return nil end
    if auto and facts.boox and self:getSetting("inkaway_boox_fast", true) ~= false then return nil end
    return PenTest.androidTip(facts)
end

-- The faster-drawing tip for Android readers whose panel KOReader can't fully
-- drive: shown once by itself where it is still needed, or again on request
-- (`again`).
function InkAwayView:deviceTips(again)
    if not again and self:getSetting("inkaway_device_tip_shown") then return end
    local tip = self:deviceTipText(not again)
    if not tip then
        if again then self:tell(_("This reader needs no special settings for Ink Away.")) end
        return
    end
    self:setSetting("inkaway_device_tip_shown", true)
    self:tell(_(tip))
end

-- The pen and touch test, full screen. The canvas stops drawing from fingers
-- while it is open (the test watches them itself), and gets its pen back after.
function InkAwayView:openPenTest()
    self:closeSheet("_settings_dialog")
    local PenTestScreen = require("ink/ui/pentestscreen")
    local raw = self._raw_installed
    if raw then self:uninstallRawFinger() end
    UIManager:show(PenTestScreen:new{ on_close = function()
        if raw and not self.closing then self:installRawFinger() end
        self:applyPalmReject()
    end })
end

return InkAwayView
