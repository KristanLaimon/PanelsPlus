--[[
InkAwayView: the fullscreen canvas. This file holds the widget itself (setup,
closing, gesture routing, undo and the paint order); each feature lives in a part
under ink/view/ whose methods are added to the class at the end of this file.

The ops are the source of truth (ink/canvas.lua). They are composed into a 1:1
master bitmap, and the visible crop of it is scaled into an on-screen buffer that
paintTo copies to the screen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Brushes = require("ink/brushes")
local Canvas = require("ink/canvas")
local Export = require("ink/export")
local InkGeom = require("ink/geom")
local Stylus = require("ink/stylus")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE

-- A full garbage collection, run shortly after the canvas closes.
local function deferredCollect() collectgarbage("collect") end

-- Sheets the emulator can open by name for scripted screenshots (INKAWAY_AUTOSHEET).
local function inNotebook(open)
    return function(v)
        if not v.notebook then
            v:beginDocument("notebook", nil, function()
                v:startNotebook({ style = "lines", size = v.grid_size or 40, strength = v.grid_strength or 45 })
            end)
        end
        open(v)
    end
end
local DEV_SHEETS = {
    pen = function(v) v:openPenSettings() end,
    eraser = function(v) v:openEraserSettings() end,
    text = function(v) v:openTextSettings() end,
    settings = function(v) v:openSettings() end,
    export = function(v) v:openExport() end,
    brush = function(v) v:openBrushMaker() end,
    shape = function(v) v:openShapePicker() end,
    shapeline = function(v) v:openShapePicker(); v:openShapeLineMenu() end,
    fill = function(v) v:openFillColor() end,
    grid = function(v) v:openGridSettings() end,
    background = function(v) v:openBackground() end,
    image = function(v) v:chooseImage() end,
    colorpicker = function(v) v:openColorPicker() end,
    format = function(v)
        v:setTool("text")
        v:newTextAt({ x = v.view.area_x + 40, y = v.view.area_y + 60 })
        v:openTextFormatMenu()
    end,
    newnotebook = function(v) v:openNotebookPaper() end,
    file = function(v) v:openDocumentSheet() end,
    library = function(v) v:openLibrary() end,
    overview = inNotebook(function(v) v:openOverview() end),
    notebook = inNotebook(function() end),
    nbexport = inNotebook(function(v) v:openExport() end),
    pagemenu = inNotebook(function(v) v:openPageMenu() end),
    ["goto"] = inNotebook(function(v) v:nbJumpPrompt() end),
}

local InkAwayView = InputContainer:extend{
    name = "inkaway_view",
    covers_fullscreen = true,
    -- Modal: gestures no toolbar button took (pinch, double tap, multiswipe) stop
    -- here instead of reaching the reader underneath.
    stop_events_propagation = true,
    deferredCollect = deferredCollect,   -- exposed for the tests; holds no reference to the view
    -- UIManager:close recomputes Input.disable_double_tap from the open widgets;
    -- keeping it off stops two quick strokes from merging into a double tap.
    disable_double_tap = true,
}

------------------------------------------------------------------------------
-- Settings (KOReader's global settings, so they persist)
------------------------------------------------------------------------------

function InkAwayView:getSetting(key, default)
    local G = rawget(_G, "G_reader_settings")
    if G and G.readSetting then
        local v = G:readSetting(key)
        if v ~= nil then return v end
    end
    return default
end

function InkAwayView:setSetting(key, value)
    local G = rawget(_G, "G_reader_settings")
    if G and G.saveSetting then G:saveSetting(key, value) end
end

-- Whether this is a colour screen (it offers the colour picker). INKAWAY_FORCE_MONO
-- previews the grey UI in the desktop emulator, which always reports colour; a real
-- device never reads it.
function InkAwayView:colorScreen()
    if Device.isEmulator and Device:isEmulator() and os.getenv("INKAWAY_FORCE_MONO") then
        return false
    end
    return (Device.hasColorScreen and Device:hasColorScreen()) and true or false
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function InkAwayView:init()
    -- Remember the reader's rotation (restored on close) and apply Ink Away's own
    -- before anything is sized, so a landscape session gets a landscape page.
    self.orig_rotation = self:currentRotation()
    self:applyStartupOrientation()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen = GeomUI:new{ x = 0, y = 0, w = W, h = H }
    self.closing = false
    self.tool = "pen"          -- pen | erase | shape | text | fill | lasso | pan
    self.capturing = false     -- a pen or eraser stroke is in progress
    self.pending_lift = nil    -- {x, y}: the finger lifted, the stroke is not committed yet
    self.pan_last = nil        -- last point of a pan drag (screen)

    -- Shapes: the chosen shape, whether it is filled, and the drag/preview state.
    self.shape = "rect"        -- line | curve | rect | ellipse | triangle
    self.shape_fill = false
    self.shape_drag = nil      -- {x0, y0, x1, y1} in screen coords while stretching
    self.curve_stage = nil     -- "bend" during a curve's second drag
    self.shape_preview = nil   -- the op being placed (screen coords), drawn by paintTo
    self._preview_rect = nil   -- last previewed screen rect, for tidy refreshes
    self.selection = nil       -- {idxs, bbox, from}: what is selected (see view/selection.lua)
    self.sel_drag = nil        -- a move, resize or turn of the selection in progress

    -- Widths are in canvas pixels, so a stroke keeps its thickness in the export
    -- whatever the zoom.
    self.pen_width = 15
    self.pen_alpha = 255
    self.pen_color = { 0x00, 0x00, 0x00 }   -- {r, g, b}
    self.fill_color = { 0x88, 0x88, 0x88 }  -- the paint bucket has its own colour
    self.fill_alpha = 255                   -- and opacity
    self.eraser_width = 40
    -- How close a new touch must land (screen px) to continue the same stroke.
    self.bridge_dist = math.max(24, math.floor(W / 22))

    -- Saved preferences. The reader's own brushes are registered first, so strokes
    -- drawn with them resolve.
    Brushes.loadAll(function(k) return self:getSetting(k) end)
    -- the pen in hand, as the reader left it (see ink/penset.lua)
    self:applyPen(self:penset().cur)
    self.stabilizer  = self:getSetting("inkaway_stabilizer", 40)       -- 0..100
    -- the pen's own pressure, a Beta and off until chosen (4.x's on by default
    -- "inkaway_pen_pressure" is left behind); see InkAwayView:realPressure
    self.pen_pressure = self:getSetting("inkaway_pen_pressure_beta", false) == true
    self.pressure_curve = self:getSetting("inkaway_pressure_curve", "medium")   -- soft | medium | firm
    self.grid_on     = self:getSetting("inkaway_grid", false)
    self.grid_style  = self:getSetting("inkaway_grid_style", "square")  -- square | dots | lines | iso | thirds
    self.grid_size   = self:getSetting("inkaway_grid_size", math.max(24, math.floor(W / 16)))
    self.grid_strength = self:getSetting("inkaway_grid_strength", 45)   -- 1..100, 100 = ink black
    -- Notebook ruling, remembered so a new notebook starts like the last one.
    self.nb_style    = self:getSetting("inkaway_nb_style", "lines")
    self.nb_size     = self:getSetting("inkaway_nb_size", nil)          -- nil = fall back to grid_size
    self.nb_strength = self:getSetting("inkaway_nb_strength", nil)      -- nil = fall back to grid_strength
    self.snap_grid   = self:getSetting("inkaway_snap_grid", false)
    self.snap_angle  = self:getSetting("inkaway_snap_angle", false)
    -- Colour screens: ink shows in its colour while it is drawn (on), or black
    -- until the pen rests (off; clearer for light colours on colour e-ink)
    self.live_colour = self:getSetting("inkaway_live_colour", true)
    -- Hold to straighten: a pen stroke held still at its end that reads as a line,
    -- rectangle, ellipse, triangle or an L becomes a clean shape.
    self.hold_straighten = self:getSetting("inkaway_hold_straighten", true)
    -- Palm rejection: draw from the pen's own events and ignore fingers while the
    -- pen is down. On by default only where KOReader reports a Wacom pen (Kindle
    -- Scribe, reMarkable); elsewhere it is opt-in. See ink/stylus.lua. Where
    -- KOReader can't hand over the pen (see penCapable) it stays off whatever was
    -- saved: fingers would move the page and the pen, a finger there, would too.
    self.palm_reject = self:getSetting("inkaway_palm_reject", self:deviceHasStylus())
        and self:penCapable() and true or false
    -- Pen taps menus and buttons: the pen also works the toolbar, menus and
    -- dialogs. Off keeps it for drawing and leaves the UI to fingers. Only matters
    -- with palm rejection on; without it the pen already arrives as a finger.
    self.pen_ui = self:getSetting("inkaway_pen_ui", true) and true or false
    -- Finger on the page, with palm rejection on (see fingerOnPage): "navigate"
    -- (scroll, turn pages, hold a picture or shape for its menu, while the pen
    -- does the writing) or "nothing". A finger never draws then: with the pen
    -- away a resting hand is a finger too. Earlier versions' "finger swipes turn
    -- pages" was a part of navigate, which is the default.
    local fmode = self:getSetting("inkaway_finger_mode")
    if fmode ~= "nothing" then fmode = "navigate" end
    self.finger_mode = fmode
    self._pen_state  = Stylus.new()
    self._pen_owner  = nil        -- slot drawing the current pen stroke
    self._palm_slots = {}         -- slot -> tracking id of each palm being ignored
    self._palm_count = 0
    self._reject_finger = false   -- set while a pen or palm is down, and briefly after
    -- After the debounce, accept fingers again and forget palms whose lift never
    -- arrived (a palm that turns back into a finger stops reaching the stylus callback).
    self._pen_clear  = function()
        self._reject_finger = false
        self._palm_slots = {}
        self._palm_count = 0
    end
    -- Ends the pass-through of a pen UI contact's gestures (see penUiFrame).
    self._pen_ui_end = function() self._pen_ui = nil end
    self.symmetry    = self:getSetting("inkaway_symmetry", "off")      -- off | vert | horiz | quad
    self.fab_side    = self:getSetting("inkaway_fab_side", "right")   -- zoom and Pan buttons: right | left | hidden
    self.ghost_clean = self:getSetting("inkaway_ghost", 0)             -- full refresh every this many strokes (0 = off)
    self.erase_bg    = self:getSetting("inkaway_erase_bg", false)      -- the eraser also removes pictures
    self.erase_whole = self:getSetting("inkaway_erase_whole", false)   -- the eraser removes whole strokes
    self.eraser_outline = self:getSetting("inkaway_eraser_outline", false)   -- a ring under the pen while erasing
    -- the colour of what is black by default: Ink Away green or a chosen one on a
    -- colour screen
    Accent.apply(self:getSetting("inkaway_accent"), self:colorScreen())
    self._strokes_since_full = 0
    -- The open document (see view/document.lua): its file, whether that file
    -- exists yet, and whether there are changes the canvas does not count.
    self.doc_path, self.doc_written = nil, false
    self.dirty = false
    self._autosave_tick = function() self:autosaveTick() end

    -- Arrows on line/curve shapes.
    self.shape_arrow = nil                                             -- nil | "end" | "both"
    self.arrow_head  = self:getSetting("inkaway_arrow_head", math.max(16, math.floor(W / 32)))

    -- Text notes: default font (nil = the reader's content font) and size.
    local tf = self:getSetting("inkaway_text_font", "")
    self.text_font = (tf ~= "" ) and tf or nil
    self.text_size = self:getSetting("inkaway_text_size", nil)
    -- Snap each typed line onto the notebook ruling (only affects ruled pages).
    self.text_grid_snap = self:getSetting("inkaway_text_grid_snap", false) and true or false
    -- Protect typed text from the eraser (on by default).
    self.text_erase_protect = self:getSetting("inkaway_text_erase_protect", true) and true or false
    -- Word-level undo history of committed text boxes, keyed weakly by op, so Undo
    -- can peel a box back a word at a time.
    self._text_hist = setmetatable({}, { __mode = "k" })

    -- Optional background picture the drawing sits on.
    self.bg_bb, self.bg_rgba, self.bg_path = nil, nil, nil
    self.save_area = nil           -- nil = whole page, or a crop rect in canvas px
    self.selecting_crop = false    -- dragging out an export area

    -- Notebook mode: nil for a single drawing. nb_bar_h is the height of the bottom
    -- page bar, 0 outside notebooks.
    self.notebook = nil
    self.nb_bar_h = 0

    -- The page is the size of the screen.
    self.canvas = Canvas.new(W, H)

    -- Bound once so it can be scheduled and unscheduled by identity.
    self._finalize = function() self:finalizeStroke() end
    self._live_flush_cb = function() self:liveFlush() end
    self._pdf_prefetch_cb = function() self:prefetchPdfPage() end
    self._pen_hold_cb = function()
        local at = self._pen_hold_at
        self._pen_hold_at = nil
        if at and not self._clip_press and self._pen_state and self._pen_state.down then
            self:textHoldAt(at)
        end
    end
    self._reconcile_cb = function() self:runReconcile() end
    self._straighten_cb = function() self:straightenNow() end
    -- Throttled refresh while dragging a lasso selection, so pan events never flood
    -- the panel.
    self:initFabs()
    -- The exporter has no fonts or image decoder; it renders text and pictures
    -- through these.
    Export.text_raster = function(op, paper, ink) return self:exportTextRaster(op, paper, ink) end
    Export.image_raster = function(op) return self:exportImageRaster(op) end

    self:initLayout(W, H)

    if Device:isTouchDevice() then
        local full = self.dimen
        -- Whole-screen ranges, so a lift is seen even off the drawing area; the
        -- handlers check the area and the tool.
        self.ges_events = {
            IaTouch      = { GestureRange:new{ ges = "touch",        range = full } },
            IaPan        = { GestureRange:new{ ges = "pan",          range = full } },
            IaHoldPan    = { GestureRange:new{ ges = "hold_pan",     range = full } },
            IaPanRelease = { GestureRange:new{ ges = "pan_release",  range = full } },
            IaHoldRel    = { GestureRange:new{ ges = "hold_release", range = full } },
            IaSwipe      = { GestureRange:new{ ges = "swipe",        range = full } },
            -- a fast stroke with 2+ direction legs ends as multiswipe, not swipe
            IaMultiSwipe = { GestureRange:new{ ges = "multiswipe",   range = full } },
            IaTap        = { GestureRange:new{ ges = "tap",          range = full } },
            IaHold       = { GestureRange:new{ ges = "hold",         range = full } },
            IaTwoPan     = { GestureRange:new{ ges = "two_finger_pan", range = full } },
            IaTwoPanRel  = { GestureRange:new{ ges = "two_finger_pan_release", range = full } },
            IaTwoTap     = { GestureRange:new{ ges = "two_finger_tap", range = full } },
            IaTwoSwipe   = { GestureRange:new{ ges = "two_finger_swipe", range = full } },
            IaPinch      = { GestureRange:new{ ges = "pinch",  range = full } },
            IaSpread     = { GestureRange:new{ ges = "spread", range = full } },
        }
    end
    if Device:hasKeys() then
        local g = Device.input.group
        self.key_events = { IaClose = { { g.Back } } }
        -- the reader's page turn buttons (KOReader turns them with the screen and
        -- the reader's own inverting): see InkAwayView:keyAction
        if g.PgFwd then self.key_events.IaKeyFwd = { { g.PgFwd } } end
        if g.PgBack then self.key_events.IaKeyBack = { { g.PgBack } } end
    end

    -- canvas_bb is the page at 1:1, where strokes are stamped once. area_bb is what
    -- the screen shows, a scaled crop of it, so zoom and pan cost the same however
    -- much is drawn.
    local bbtype = Screen.bb:getType()
    self.canvas_bb = Blitbuffer.new(self.view.canvas_w, self.view.canvas_h, bbtype)
    self.area_bb = self:newAreaBuffer()   -- in the panel's pixel order (see view/display.lua)

    self:openStartDocument()   -- the last document, or a new drawing
    self:composeCanvas()
    self:renderView()
    -- the library or the notebooks on top, when asked for (the library's gesture)
    -- or chosen in the settings; they open as the canvas is shown (see onShow)
    if not self.over_book and not self.open_path then
        local start = self:getSetting("inkaway_start")
        self._library_on_show = self.show_library or start == "library"
        self._overview_on_show = not self._library_on_show and start == "notebooks"
    end
    self:applyPalmReject()   -- hook the pen if palm rejection is on and supported
    -- Emulator hooks for scripted screenshots; the variables are never set on a
    -- device. INKAWAY_AUTOORIENT opens in an orientation, INKAWAY_AUTOSHEET opens a
    -- sheet from DEV_SHEETS and INKAWAY_AUTOSHOT saves the screen to a PNG.
    local autoorient = os.getenv("INKAWAY_AUTOORIENT")
    if autoorient == "landscape" or autoorient == "portrait" then
        UIManager:scheduleIn(0.4, function() self:setOrientation(autoorient) end)
    end
    local autosheet = DEV_SHEETS[os.getenv("INKAWAY_AUTOSHEET") or ""]
    if autosheet then
        UIManager:scheduleIn(0.7, function() autosheet(self) end)
    end
    local autoshot = os.getenv("INKAWAY_AUTOSHOT")
    if autoshot then
        UIManager:scheduleIn(1.7, function() pcall(function() Screen:shot(autoshot) end) end)
    end
end

-- The toolbar across the top and the drawing area under it, the page covering
-- the area: as far as it zooms out (zoom_min), since further out would only add
-- margins at the sides. The annotation mode over a book lays out its own (see
-- ink/reader/inkview.lua).
function InkAwayView:initLayout(W, H)
    self:buildToolbar()
    self.view = {
        canvas_w = W, canvas_h = H,
        zoom = 1, pan_x = 0, pan_y = 0,
    }
    self:fitBars(W, H)
    self.zoom_min = InkGeom.coverZoom(self.view)
    self.view.zoom = self.zoom_min
    InkGeom.clampPan(self.view)
    -- The toolbar is the child that receives taps; paintTo does all the painting.
    self[1] = self.toolbar
end

function InkAwayView:free()
    if self.area_bb then self.area_bb:free(); self.area_bb = nil end
    if self.canvas_bb then self.canvas_bb:free(); self.canvas_bb = nil end
    self:washFree()
    if self.canvas_panel_bb then self.canvas_panel_bb:free(); self.canvas_panel_bb = nil end
    self._cpanel_dirty = nil
    if self.bg_bb then self.bg_bb:free(); self.bg_bb = nil end
    self:freePdfCache()
    self._bg_src = nil
    if self._paper_bb then self._paper_bb:free(); self._paper_bb = nil end
    if self._bare_paper_bb then self._bare_paper_bb:free(); self._bare_paper_bb = nil end
    self:freePlainPaper()
    self:freeWaveCache()
    self:freePageThumbs()
    self:freeHandwriting()
    Accent.free()
    local ok_cp, ColorPicker = pcall(require, "ink/ui/colorpicker")   -- its colour wheel
    if ok_cp and ColorPicker.freeCache then ColorPicker.freeCache() end
    if self._reveal_text_bb then self._reveal_text_bb:free(); self._reveal_text_bb = nil end
    if self._reveal_pic_bb then self._reveal_pic_bb:free(); self._reveal_pic_bb = nil end
    self:layerCachesDrop()
    self:freeFabSprites()
    if self._nav_img then
        for _, ic in pairs(self._nav_img) do if ic then pcall(function() ic:free() end) end end
        self._nav_img = nil
    end
    self:freeImageCache()
    self.bg_rgba = nil
end

function InkAwayView:onShow()
    self:installRawFinger()
    self:startEinkDrive()
    self:startElipsaDrive()
    UIManager:setDirty(self, "full")
    -- opened here rather than a tick later, so its refresh joins the canvas's and
    -- the screen flashes once, not twice
    if self._library_on_show then
        self._library_on_show = nil
        self:openLibrary()
    elseif self._overview_on_show then
        self._overview_on_show = nil
        self:openOverview()
    end
    if self._note_on_show then   -- shown over the canvas (and the library)
        self:tell(self._note_on_show)
        self._note_on_show = nil
    elseif self:welcomeDue() then
        self:showWelcome()       -- once: the book features and their gestures
    elseif self:onAndroid() then
        self:deviceTips(false)   -- once, on readers that still need it
    end
    self:updatesOnOpen()         -- the once-a-day update check, when due
    return true
end

function InkAwayView:onSetDimensions()
    self:handleScreenResize()
    UIManager:setDirty(self, "full")
end

-- KOReader puts the reader to sleep: the Elipsa's display helper stops (see
-- startElipsaDrive) and so does sharing.
function InkAwayView:onSuspend()
    self:cancelOcrApi()
    self:stopElipsaDrive()
    self:stopSendForSleep()
end

-- The reader wakes with Ink Away open: the display helper comes back.
function InkAwayView:onResume()
    self:startElipsaDrive()
end

function InkAwayView:onCloseWidget()
    self.closing = true
    self:cancelOcrApi()
    self:updatesOnClose()
    self:uninstallRawFinger()
    self:stopEinkDrive()
    self:stopElipsaDrive()
    self:removePenBridge()
    self:releaseStylus()   -- the pen goes back to the view under this one, if any
    UIManager:unschedule(self._pen_clear)
    UIManager:unschedule(self._pen_ui_end)
    UIManager:unschedule(self._finalize)
    UIManager:unschedule(self._autosave_tick)
    UIManager:unschedule(self._live_flush_cb)
    UIManager:unschedule(self._reconcile_cb)
    UIManager:unschedule(self._pen_hold_cb)
    UIManager:unschedule(self._straighten_cb)
    UIManager:unschedule(self._pdf_prefetch_cb)
    if self._export_job then
        self._export_job.cancel()
        -- (and what it held open: a book's PDF handle, the reader's place)
        if self._export_finish then self._export_finish() end
        self._export_job = nil
    end
    self:stopSend()   -- the reader stops sharing over Wi-Fi with Ink Away
    if self._search_job then self._search_job.abort(); self._search_job = nil end
    self._clip_bubble, self._clip_press, self._pen_hold_at = nil, nil, nil
    local tm = self._text_btn_metrics
    if tm then
        for _, w in ipairs({ tm.fw, tm.dw }) do if w and w.free then w:free() end end
        self._text_btn_metrics = nil
    end
    if self._clip_widget then
        if self._clip_widget.free then self._clip_widget:free() end
        self._clip_widget = nil
    end
    self:cancelFabs()
    if self.editing_text then self:finishTextEdit(true) end   -- bake an open text box
    self:resetLasso()                                           -- drop any selection
    self:hideTextKeyboard()
    Export.text_raster = nil   -- drop the closures over this view
    Export.image_raster = nil
    self:saveDocument()
    self:shelfSnapshot()   -- before the page's buffers go
    self:freeThumbs()   -- release any decoded online-image thumbnails
    self:eraserCursorFree()
    -- Close any of our popups so nothing is left shown or referenced.
    for _, key in ipairs({ "_pen_dialog", "_shape_dialog", "_shape_line_dialog", "_fill_dialog", "_eraser_dialog", "_chooser_dialog", "_grid_dialog", "_bg_dialog", "_goto_dialog", "_paste_dialog", "_search_sheet", "_trash_sheet", "_trash_item", "_img_src_dialog", "_image_browser_dialog", "_img_search_dialog", "_settings_dialog", "_page_dialog", "_save_dialog", "_text_fmt", "_text_settings", "_doc_dialog", "_new_dialog", "_library", "_overview",
            "_peninput_dialog", "_pentypes_dialog", "_gestures_dialog", "_gesture_pick", "_penfav_menu" }) do
        self:closeSheet(key)
    end
    -- and every other sheet still open: one left over the reader would take
    -- the gestures meant for it
    for key in pairs(self._sheet_fields or {}) do self:closeSheet(key) end
    -- Release the large buffers and drop references so the GC can reclaim them.
    self:closeNotebookPDF()
    self:free()
    self.selection, self.sel_drag, self.shape_preview = nil, nil, nil
    if self.canvas then
        self.canvas.ops, self.canvas.undo_stack, self.canvas.redo_stack = {}, {}, {}
    end
    -- Collect just after closing rather than during it: with a big drawing the
    -- collection is a noticeable pause.
    UIManager:scheduleIn(0.5, deferredCollect)
    -- Remember the orientation for next time and give the reader back its own
    -- (over a book, the reader's orientation is the book's: nothing to keep).
    if self:orientationSupported() and not self.over_book then
        self:setSetting("inkaway_orientation", self:orientationClass())
        if self.orig_rotation ~= nil and self:currentRotation() ~= self.orig_rotation then
            pcall(function() Screen:setRotationMode(self.orig_rotation) end)
        end
    end
    -- Leave the screen clean (refresh avoids the slow full flash on colour panels);
    -- over a book the reader repaints its page, with the ink, under a plain one.
    if self.over_book then UIManager:setDirty("all", "ui") else self:refresh(nil, "full") end
    -- opened from a Bookshelf shelf: it redraws, as the saved notebook may
    -- have a new cover
    if self.after_close then
        pcall(self.after_close)
    elseif self._shelf_snapped then
        -- opened elsewhere: the shelf's cover follows the new snapshot
        local covers = self._shelf_snapped
        if type(covers) == "table" and covers.redraw and self.doc_path then pcall(covers.redraw, self.doc_path) end
    end
    self._shelf_snapped = nil
end

function InkAwayView:onIaClose()
    self:closeCanvas()
    return true
end

------------------------------------------------------------------------------
-- Gesture handlers: each gesture goes to the current interaction or tool
------------------------------------------------------------------------------

-- Pinch zooms out and spread zooms in, anchored between the fingers.
function InkAwayView:onIaPinch(_, ges)
    if self:fingerRejected() then return true end
    self:pinchZoom(ges, -1)
    return true
end

function InkAwayView:onIaSpread(_, ges)
    if self:fingerRejected() then return true end
    self:pinchZoom(ges, 1)
    return true
end

-- Touch down: start a stroke, a pan or the active tool's action, or continue a
-- stroke whose contact the panel dropped for a moment.
function InkAwayView:onIaTouch(_, ges)
    -- a pen or palm is down: keep fingers out until it lifts
    if self:fingerRejected(ges and ges.pos) then self:holdReject(); return true end
    -- a multi-touch that began as a raw stroke: its per-finger touches never draw
    if not self._pen_feeding and self._raw and self._raw.ignore_slot ~= nil then return true end
    local pos = ges.pos
    -- a new contact voids any press an earlier gesture left half-finished (the
    -- keyboard takes a key's tap but not its touch)
    self._fab_press, self._clip_press = nil, nil
    self._finger_nav = nil
    UIManager:unschedule(self._pdf_prefetch_cb)   -- never pre-render in the way of a touch
    self:showPendingKeyboard()   -- in case the lift that should have shown it was missed
    -- touches on the on-screen keyboard belong to the keyboard, never the canvas
    if self:inKeyboard(pos) then return false end
    -- the paste bubble: a press on it pastes on release; any other touch dismisses it
    if self._clip_bubble then
        if self:inClipBubble(pos) then self._clip_press = true; return true end
        self:hideClipBubble()
    end
    if not pos or not self:inArea(pos.x, pos.y) then return false end
    self._swallow = nil   -- a new touch: any straightened stroke's contact is over
    self._peel_op = nil   -- a new interaction ends any committed-text undo peel
    -- floating controls: a tap on one acts; a drag off it (below) draws instead
    -- (not the start of a pen stroke that landed on one: see penFabFrame)
    local fab = not self._pen_fab_stroke and self:fabHit(pos.x, pos.y)
    if fab then self._fab_press = fab; return true end
    if self.selecting_crop then return self:cropTouch(pos) end
    -- the selection's frame and handles, with any tool (a finger's hold can make
    -- one under the pen); a touch on its menu is the menu's (its buttons answer
    -- the tap), and a touch anywhere else drops it and does what the tool does
    if self.selection then
        if self:selTouch(pos) then return true end
        local m = self._sel_dialog
        if m and m.dimen and InkGeom.inRect(pos.x, pos.y, m.dimen) then return true end
        self:dropSelection()
    end
    -- an open text box is worked like a dialog: with the keyboard up the pen
    -- reaches the page as a UI contact, and Done, Format and the box take a
    -- finger too, so neither is a navigating finger here (see textToolTouch)
    if self.editing_text and self.tool == "text" then return self:textToolTouch(pos) end
    local fmode = self:fingerOnPage()
    if fmode then   -- a finger navigates (or does nothing) while the pen writes
        self._finger_nav = { mode = fmode, x = pos.x, y = pos.y, lx = pos.x, ly = pos.y }
        return true
    end
    if self.tool == "lasso" then return self:lassoTouch(pos) end
    if self.tool == "text" then return self:textToolTouch(pos) end
    if self.tool == "fill" then self:doFill(pos); return true end
    if self.tool == "shape" then return self:shapeTouch(pos) end
    if self.tool == "pan" then
        -- a tap on a link follows it (a drag from it still pans)
        local link = self:linkAtScreen(pos.x, pos.y)
        if link then
            self._link_press = link
            self.pan_last = { x = pos.x, y = pos.y }
            return true
        end
        -- a touch on a picture or a shape selects it and can drag it; its menu
        -- opens on the tap or hold, since opening it here would let the same
        -- gesture close it
        local hit = self:hitTestImage(pos.x, pos.y) or self:hitTestShape(pos.x, pos.y)
        if hit and self:selectOps({ hit.idx }, "pan") then
            self:selTouch(pos)
            return true
        end
        self.pan_last = { x = pos.x, y = pos.y }
        return true
    end
    if self.capturing and self.pending_lift then
        -- within the coalesce window: same stroke if the new contact is close
        local dx = pos.x - self.pending_lift.x
        local dy = pos.y - self.pending_lift.y
        if dx * dx + dy * dy <= self.bridge_dist * self.bridge_dist then
            UIManager:unschedule(self._finalize)
            self.pending_lift = nil
            self:addScreenPoint(pos.x, pos.y, false)  -- bridge the gap
            return true
        end
        self:finalizeStroke()   -- a new stroke elsewhere
    elseif self.capturing then
        self:finalizeStroke()   -- a lift was missed; don't lose the old stroke
    end
    self._finger_dot = not self._pen_feeding   -- a finger's own stroke (see onIaTwoTap)
    self:beginStroke(pos.x, pos.y)
    self:straightenWatch(pos.x, pos.y, true)
    return true
end

function InkAwayView:onIaPan(_, ges)
    if self:fingerRejected(ges and ges.pos) then self:holdReject(); return true end
    if self._finger_nav and not self._pen_feeding then return self:fingerNavPan(ges.pos) end
    if self._clip_press then return true end   -- the release decides (paste or cancel)
    local pos = ges.pos
    if self._fab_press then           -- a drag off a control is a draw, not a tap
        self._fab_press = nil
        if pos then self:fabProximity(pos.x, pos.y) end
        return true
    end
    if pos then self:fabProximity(pos.x, pos.y) end   -- fade controls the drawing comes near
    if self.selecting_crop then return self:cropMove(pos) end
    if self.sel_drag then return self:selPan(pos) end
    if self.tool == "text" then return self:textToolPan(pos) end
    if self.tool == "lasso" then return self:lassoPan(pos) end
    if self.tool == "fill" then return true end   -- fill is a tap, ignore drags
    if self.tool == "shape" then return self:shapeMove(pos) end
    if self.tool == "pan" then
        self._link_press = nil   -- a drag, not a tap on a link
        if self.pan_last then
            self:panByScreen(pos.x - self.pan_last.x, pos.y - self.pan_last.y)
            self.pan_last.x, self.pan_last.y = pos.x, pos.y
            return true
        end
        return false
    end
    if self._swallow then return true end   -- the rest of a touch whose stroke was straightened
    if not self.capturing then return false end
    if self.pending_lift then          -- movement resumes the held stroke
        UIManager:unschedule(self._finalize)
        self.pending_lift = nil
    end
    self:addScreenPoint(pos.x, pos.y, false)
    self:straightenWatch(pos.x, pos.y)
    return true
end
InkAwayView.onIaHoldPan = InkAwayView.onIaPan

function InkAwayView:onIaPanRelease(_, ges)
    if self:fingerRejected(ges and ges.pos) then return true end
    if self._finger_nav and not self._pen_feeding then return self:fingerNavEnd(ges and ges.pos) end
    if self._clip_press then
        self._clip_press = nil
        if self:inClipBubble(ges and ges.pos) then self:textPaste() end
        return true
    end
    if self._fab_press then self._fab_press = nil; return true end
    if self._swallow then self._swallow = nil; return true end
    if self.selecting_crop then return self:cropRelease(ges and ges.pos) end
    if self.sel_drag then
        if ges and ges.pos then self:selPan(ges.pos) end
        return self:selRelease()
    end
    if self.tool == "text" then return self:textToolRelease(ges and ges.pos) end
    if self.tool == "lasso" then return self:lassoRelease(ges and ges.pos) end
    if self.tool == "fill" then return true end
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    if self.tool == "pan" then
        self.pan_last = nil
        if self._view_stale then self:liveFlush() end   -- show where the pan ended
        return true
    end
    if not self.capturing then return false end
    -- the lift: the stroke ends where the pen left (see addScreenPoint)
    if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false, true) end
    self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                          ges and ges.pos and ges.pos.y or 0)
    return true
end
InkAwayView.onIaHoldRel = InkAwayView.onIaPanRelease

function InkAwayView:onIaSwipe(_, ges)
    if self:diagonalGesture(ges) then return false end   -- KOReader's screenshot
    if self:fingerRejected(ges and ges.pos) then return true end
    if self._finger_nav and not self._pen_feeding then
        return self:fingerNavEnd(ges and (ges.end_pos or ges.pos), ges and ges.direction)
    end
    if self._clip_press then self._clip_press = nil; return true end   -- slid off: cancel
    if self._fab_press then self._fab_press = nil; return true end
    if self._swallow then self._swallow = nil; return true end
    if self.selecting_crop then return self:cropRelease(ges and (ges.end_pos or ges.pos)) end
    if self.sel_drag then
        -- a quick drag arrives as a swipe: its end is where the selection goes
        local p = ges and (ges.end_pos or ges.pos)
        if p then self:selPan(p) end
        return self:selRelease()
    end
    if self.tool == "lasso" then return self:lassoRelease(ges and (ges.end_pos or ges.pos)) end
    if self.tool == "fill" then return true end
    -- a swipe's start would collapse a shape to a dot, so use only its end (or the
    -- last dragged size)
    if self.tool == "shape" then return self:shapeRelease(ges and ges.end_pos) end
    if self.tool == "text" then return self:textToolRelease(ges and (ges.end_pos or ges.pos)) end
    if self.tool == "pan" then
        self.pan_last = nil
        if self._view_stale then self:liveFlush() end   -- show where the pan ended
        return true
    end
    if not self.capturing then return self:handBack(ges, ges and ges.ges == "swipe") end
    -- swipe reports the lift point separately as end_pos
    local p = ges and (ges.end_pos or ges.pos)
    if p then self:addScreenPoint(p.x, p.y, false, true) end
    self:scheduleFinalize(p and p.x or 0, p and p.y or 0)
    return true
end

InkAwayView.onIaMultiSwipe = InkAwayView.onIaSwipe

function InkAwayView:onIaTap(_, ges)
    if self:fingerRejected(ges and ges.pos) then return true end
    if self._finger_nav and not self._pen_feeding then   -- a navigating finger's tap follows a link
        local nav = self._finger_nav
        self._finger_nav = nil
        local link = nav.mode == "navigate" and ges and ges.pos and self:linkAtScreen(ges.pos.x, ges.pos.y)
        if link then self:followLink(link) end
        return true
    end
    if self._clip_press then
        self._clip_press = nil
        if self:inClipBubble(ges and ges.pos) then self:textPaste() end
        return true
    end
    -- floating controls: complete a tap begun on one of them
    if self._fab_press then
        local kind = self._fab_press; self._fab_press = nil
        self:fabAction(kind)
        return true
    end
    -- the notebook bar below the drawing area (toolbar buttons take their own taps)
    local p = ges and ges.pos
    if self.notebook and self.nb_bar_h > 0 and p then
        local function hit(r) return r and InkGeom.inRect(p.x, p.y, r) end
        if hit(self._nb_plus) then self:nbAddPage(); return true end
        if hit(self._nb_overview) then self:openOverview(); return true end
        if hit(self._nb_prev) then self:nbGo(-1); return true end
        if hit(self._nb_next) then self:nbGo(1); return true end
        if hit(self._nb_count) then self:openPageMenu(); return true end
        -- swallow taps anywhere on the strip so they never fall through to drawing
        local v = self.view
        if p.y >= v.area_y + v.area_h then return true end
    end
    if self.selecting_crop then return self:cropRelease(ges and ges.pos) end
    -- a tap on a link with Pan follows it
    if self._link_press then
        local link = self._link_press
        self._link_press, self.pan_last = nil, nil
        self:followLink(link)
        return true
    end
    -- a tap on the selection (its touch began a drag that never moved) opens its
    -- menu, on the completed tap, so the tap cannot close it again
    if self.sel_drag then return self:selRelease() end
    if self.tool == "text" then return self:textToolRelease(ges and ges.pos) end
    if self.tool == "lasso" then return self:lassoTap(ges and ges.pos) end
    if self.tool == "fill" then return true end   -- fill already happened on touch
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    -- a tap finishes the dot its touch started
    if self.capturing then
        if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
        self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                              ges and ges.pos and ges.pos.y or 0)
        return true
    end
    return false
end

function InkAwayView:onIaHold(_, ges)
    if self:fingerRejected(ges and ges.pos) then return true end
    if self._clip_press then return true end
    if self._fab_press then self._fab_press = nil; return true end
    -- a long press in the text box being edited offers to paste there
    if self.editing_text and self:textHoldAt(ges and ges.pos) then return true end
    -- swallow holds while drawing or placing, so they never become a long-press menu
    if self.capturing or self.shape_drag or self.curve_stage
       or (self.sel_drag and self.sel_drag.began) then return true end
    local pos = ges and ges.pos
    -- holding Prev or Next in a notebook's bar goes to the first or last page
    if pos and self.notebook and self.nb_bar_h > 0 then
        if self._nb_prev and InkGeom.inRect(pos.x, pos.y, self._nb_prev) then self:nbGoTo(1); return true end
        if self._nb_next and InkGeom.inRect(pos.x, pos.y, self._nb_next) then
            self:nbGoTo(self.notebook:count()); return true
        end
    end
    if not (pos and self:inArea(pos.x, pos.y)) then return false end
    -- a navigating finger opens a picture's or shape's menu, as the Move tool does
    if self._finger_nav and not self._pen_feeding then
        if self._finger_nav.mode == "navigate" then self:holdMenuAt(pos) end
        return true
    end
    -- a hold with the lasso picks out the picture or shape under it
    if self.tool == "lasso" and not self.sel_drag then
        self.lassoing, self.lasso_scr = false, nil
        self:selectAt(pos)
        return true
    end
    -- selecting only happens in Pan mode, so a hold never fights with drawing
    if self.tool == "pan" or self.sel_drag then
        -- a hold on the selection (or on a picture, shape or text box, which it
        -- selects) opens its menu; the drag its touch began is dropped
        if self.sel_drag then self:endSelectionDrag(true) end
        self._link_press = nil
        if not (self.selection and self:selHit(pos.x, pos.y)) then
            local _, link_idx = self:linkAtScreen(pos.x, pos.y)
            local hit = (link_idx and { idx = link_idx }) or self:hitTestImage(pos.x, pos.y)
                or self:hitTestShape(pos.x, pos.y) or self:hitTestText(pos.x, pos.y)
            if not (hit and self:selectOps({ hit.idx }, "pan")) then return true end
        end
        self:openSelectionMenu()
    end
    return true
end

-- Two-finger pan works with any tool: commit the stroke in progress, then pan by
-- how far the fingers' midpoint moved. On a notebook page with no room sideways a
-- mostly sideways move pans nothing: it is a page swipe (see onIaTwoSwipe).
function InkAwayView:onIaTwoPan(_, ges)
    if self:fingerRejected() then return true end   -- palm splayed under the pen
    self:flushPending()
    self:cancelShape()   -- a two-finger pan drops any half-placed shape
    self._finger_nav = nil
    local pos = ges.pos
    if not self.pan_last then
        self.pan_last = { x = pos.x, y = pos.y, x0 = pos.x, y0 = pos.y,
            px = self.view.pan_x, py = self.view.pan_y }   -- where the page was (see onIaTwoSwipe)
    else
        local dx, dy = pos.x - self.pan_last.x, pos.y - self.pan_last.y
        self.pan_last.x, self.pan_last.y = pos.x, pos.y
        local tx, ty = pos.x - (self.pan_last.x0 or pos.x), pos.y - (self.pan_last.y0 or pos.y)
        if not (self:pageSwipes() and math.abs(tx) > math.abs(ty)) then self:panByScreen(dx, dy) end
    end
    return true
end

function InkAwayView:onIaTwoPanRel()
    self.pan_last = nil
    if self._view_stale then self:liveFlush() end   -- show where the pan ended
    return true
end

------------------------------------------------------------------------------
-- Undo and exit
------------------------------------------------------------------------------

-- Undo the last change. Returns true when something was undone.
function InkAwayView:undo()
    if self.editing_text then self:textUndo(); return true end   -- undo within the box
    -- a committed text box is undone a word at a time; once its history is used up,
    -- the normal undo removes or restores the whole box
    local idx, h = self:topTextHist()
    if idx and #h.undo > 0 then
        self:commitTextStep(idx, h.undo, h.redo)
        return true
    end
    self._peel_op = nil   -- leaving any text-peel sequence
    self:flushPending()
    self:resetLasso()   -- a selection's indices do not survive the change
    local undone, mark = self.canvas:undo()
    if not undone then
        self:showNotice(_("Nothing to undo."), 1)
        return false
    end
    if mark ~= nil and self.undoMark then self:undoMark(mark) end
    self:markDirty()
    self:recompose()   -- rebuild the master from the restored ops
    return true
end

function InkAwayView:redo()
    if self.editing_text then return self:textRedo() end   -- redo within the box
    -- redo the words of the text box being peeled; any other redo restores the op
    -- the last undo removed
    local idx, h = self:topTextHist()
    if idx and h.redo and #h.redo > 0 and self.canvas.ops[idx] == self._peel_op then
        self:commitTextStep(idx, h.redo, h.undo)
        return
    end
    self._peel_op = nil
    self:flushPending()
    self:resetLasso()
    local redone, mark = self.canvas:redo()
    if not redone then
        self:showNotice(_("Nothing to redo."), 1)
        return
    end
    if mark ~= nil and self.redoMark then self:redoMark(mark) end
    self:markDirty()
    self:recompose()
end

-- Leave Ink Away. Nothing to ask: the document saves itself on the way out.
function InkAwayView:closeCanvas()
    self:flushPending()
    UIManager:close(self)
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

function InkAwayView:paintTo(bb, x, y)
    local v = self.view
    -- rebuild area_bb if the screen's pixel order changed (see view/display.lua)
    self:matchAreaTarget()
    -- During a stroke or shape drag only `_blit_rect` changed, and an area-only
    -- refresh (areaScreenRect) never covers the toolbar or the notebook bar, so
    -- both skip the chrome; on a software-rotated screen redrawing it is slow.
    local br = self._blit_rect
    -- the area was rebuilt since the last full blit, or a sheet over it went away
    if self._full_blit or self._paint_all then br = nil end
    local paint_chrome = not br and (self._paint_all or not self._area_only)
    self._area_only, self._paint_all = false, false
    if paint_chrome then
        self:paintSurround(bb, x, y)
        -- the toolbar and its hairline, unless collapsed (it sits at the top left,
        -- or where a mode puts it)
        if not self._toolbar_hidden then
            local tx, ty = x + (self._bar_x or 0), y + (self._bar_y or 0)
            self:paintBarMarks(bb, tx, ty)   -- black pill behind the active tool
            self.toolbar:paintTo(bb, tx, ty)
            self:paintBarIcons(bb, tx, ty)
            self:darkToolbar(bb, tx, ty)
        end
    end
    -- the drawing area
    if br then
        local rx0 = math.max(0, math.floor(br.x0)); local ry0 = math.max(0, math.floor(br.y0))
        local rx1 = math.min(v.area_w, math.ceil(br.x1)); local ry1 = math.min(v.area_h, math.ceil(br.y1))
        if rx1 > rx0 and ry1 > ry0 then
            -- only the changed region; blitAreaRect copies in panel order, so it stays
            -- fast in landscape
            self:blitAreaRect(bb, x + v.area_x + rx0, y + v.area_y + ry0, rx0, ry0, rx1 - rx0, ry1 - ry0)
        end
    else
        self:blitAreaFull(bb, x + v.area_x, y + v.area_y)
        self._full_blit = false
    end
    self._blit_rect = nil   -- consumed; default back to a full blit next paint
    -- The grid is painted on the screen, never into the drawing, so it can't be
    -- erased and stays out of the export. A notebook has its own ruling instead.
    if self.grid_on and not self.notebook then
        -- during a region blit only that region is redrawn
        self:drawGrid(bb, x + v.area_x, y + v.area_y, br)
    end
    -- page edges that fall inside the drawing area (a region blit may cross one)
    self:paintPageEdges(bb, x, y)
    if self.shape_preview then self:paintShapePreview(bb, x, y) end
    if self.selecting_crop and self._crop_screen then self:paintCropOverlay(bb, x, y) end
    if self.lassoing then self:paintLassoLoop(bb, x, y) end
    self:paintLinks(bb, x, y, br)
    if self.selection then self:paintSelection(bb, x, y) end

    -- the text box being edited: glyphs, frame, caret and selection
    if self.editing_text then self:paintTextOverlay(bb, x, y) end
    if self._clip_bubble and self.editing_text then
        local b = self._clip_bubble
        self:clipBubbleWidget():paintTo(bb, x + b.x, y + b.y)
    end

    -- the notebook's bottom bar is chrome, so it is skipped on region blits and
    -- area-only paints like the toolbar
    if paint_chrome and self.notebook and self.nb_bar_h > 0 then
        self:paintNotebookBar(bb, x, y)
        if Theme.invert() then
            bb:invertRect(x, y + v.area_y + v.area_h, self.screen_w, self.nb_bar_h)
        end
    end

    -- the floating controls, on top (a region blit paints the ones it reaches)
    self:drawFabs(bb, x, y, br)
end

-- White around the drawing area (the area itself is blitted over it). A mode
-- shown as a window over something else paints that instead.
function InkAwayView:paintSurround(bb, x, y)
    local v = self.view
    local ay0, ay1 = v.area_y, v.area_y + v.area_h
    local ax0, ax1 = v.area_x, v.area_x + v.area_w
    -- white as in light: the toolbar and bars painted over it are inverted for
    -- dark, these bands with them (see darkToolbar)
    if ay0 > 0 then bb:paintRect(x, y, self.screen_w, ay0, WHITE) end
    if ay1 < self.screen_h then bb:paintRect(x, y + ay1, self.screen_w, self.screen_h - ay1, WHITE) end
    if ax0 > 0 then bb:paintRect(x, y + ay0, ax0, ay1 - ay0, WHITE) end
    if ax1 < self.screen_w then bb:paintRect(x + ax1, y + ay0, self.screen_w - ax1, ay1 - ay0, WHITE) end
end

-- Dark (see ink/ui/theme.lua): the toolbar at (tx, ty) inverted, the pen in
-- hand's colour and an active tool in a theme colour given back.
function InkAwayView:darkToolbar(bb, tx, ty)
    if not (Theme.invert() and self.toolbar) then return end
    local sz = self.toolbar:getSize()
    local w = self._vb_side and sz.w or self.screen_w
    local x = self._vb_side and tx or 0
    bb:invertRect(x, ty, w, sz.h)
    local m = self._pen_mark_rect
    if m then bb:invertRect(m.x, m.y, m.w, m.h) end
    local p = self._pill_rect
    if p and Accent.get().custom then Theme.invertRounded(bb, p.x, p.y, p.w, p.h, p.r) end
    local d = self._update_dot_rect
    if d and Accent.get().custom then Theme.invertRounded(bb, d.x, d.y, d.w, d.h, d.r) end
end

-- Add the methods of every part (ink/view/*.lua) to the class.
local PARTS = { "viewport", "display", "compose", "stroke", "shapes", "images", "imagebrowser",
    "textedit", "textformat", "lasso", "notebook", "overview", "export", "exportbook", "document", "library", "input", "toolbar", "menus",
    "settings", "sheetkit", "handwriting", "ocrapi", "wipe", "jobs", "search", "trash", "selection", "links", "wash", "smudge", "pencase", "gestures", "welcome", "guide",
    "paper", "updates", "layers", "keys", "share", "receive", "dialogs", "erasecursor" }
for _, part in ipairs(PARTS) do
    for name, fn in pairs(require("ink/view/" .. part)) do
        assert(rawget(InkAwayView, name) == nil, "two definitions of InkAwayView." .. name)
        InkAwayView[name] = fn
    end
end

return InkAwayView
