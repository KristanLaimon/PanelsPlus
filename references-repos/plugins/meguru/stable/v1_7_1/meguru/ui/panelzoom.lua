local _ = require("gettext")

local ButtonTable = require("ui/widget/buttontable")
local CanvasContext = require("document/canvascontext")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Settings = require("meguru/settings")
local UIManager = require("ui/uimanager")
local Viewport = require("meguru/viewport")
local logger = require("logger")

local Screen = Device.screen

local PanelZoom = {}

-- Delay so a fast swipe re-arms and unschedules before the warm runs.
local WARM_DELAY = 0.4

-- The book's direction, not BD.mirroredUILayout (the UI language) stock uses.
local function nextIsRight(mode)
    return mode ~= "manga"
end

-- Read from G_defaults as ReaderConfig does; the zones below are the fallback.
local BOTTOM_ZONE = { x = 0, y = 7 / 8, w = 1, h = 1 / 8 }
local BOTTOM_ZONE_EXT = { x = 1 / 4, y = 4 / 5, w = 2 / 4, h = 1 / 5 }

-- A KOReader global, absent on some builds; a missing store must cost nothing.
local function readGlobals(name)
    local store = rawget(_G, name)
    if store and type(store.readSetting) == "function" then
        return store
    end
    return nil
end

local function bottomZoneSetting(name, fallback)
    local defaults = readGlobals("G_defaults")
    local zone = defaults and defaults:readSetting(name)
    if type(zone) == "table" and type(zone.x) == "number" then
        return zone
    end
    return fallback
end

-- "swipe_tap" is the same default ReaderConfig falls back to.
local function activationMenu()
    local settings = readGlobals("G_reader_settings")
    return (settings and settings:readSetting("activate_menu")) or "swipe_tap"
end

local function inZone(zone, x, y)
    return x >= zone.x and x <= zone.x + zone.w
        and y >= zone.y and y <= zone.y + zone.h
end

local function inBottomMenuZone(pos)
    if not (pos and pos.x and pos.y) then
        return false
    end
    local x, y = pos.x / Screen:getWidth(), pos.y / Screen:getHeight()
    return inZone(bottomZoneSetting("DTAP_ZONE_CONFIG", BOTTOM_ZONE), x, y)
        or inZone(bottomZoneSetting("DTAP_ZONE_CONFIG_EXT", BOTTOM_ZONE_EXT), x, y)
end

local function bottomMenuTap(pos)
    return activationMenu() ~= "swipe" and inBottomMenuZone(pos)
end

local function bottomMenuSwipe(pos, direction)
    return activationMenu() ~= "tap" and direction == "north" and inBottomMenuZone(pos)
end

-- Clamps to the picture area: a function-image tile draws 1:1 under the row.
local function stepImage(doc, page, rect)
    return function(_, max_w, max_h)
        local tw, th = rect.out_w, rect.out_h
        if tw and th and max_w and max_h then
            local shrink = math.min(max_w / tw, max_h / th, 1)
            tw = math.max(1, math.floor(tw * shrink + 0.5))
            th = math.max(1, math.floor(th * shrink + 0.5))
        end
        return doc:drawPagePart(page, rect, 0, tw, th)
    end
end

-- The rotate button's states, in the order a tap walks them.
local ROTATE_MODES = { "off", "on", "auto" }

-- No panel, all of them, or only where the shapes disagree.
local function rotateMode()
    local mode = Settings.get("panel_rotate")
    if mode == "off" or mode == "on" or mode == "auto" then
        return mode
    end
    -- Unset: the reader's own stock answer stands until the button is tapped.
    local g = rawget(_G, "G_reader_settings")
    if g and type(g.isTrue) == "function"
        and g:isTrue("imageviewer_rotate_auto_for_best_fit") then
        return "auto"
    end
    return "off"
end

-- The button names the state the reader is in, the rule the view switch keeps.
local function rotateLabel(mode)
    local labels = {
        off = _("No rotate"),
        on = _("Rotate"),
        auto = _("Autorotate"),
    }
    return labels[mode] or labels.off
end

-- Only "auto" asks the shapes; the window and free views are never turned.
local function rotatedFor(viewer, image_num)
    if viewer.meguru_free or (viewer.view and viewer.view.window) then
        return false
    end
    local mode = viewer.rotate_mode
    if mode == "on" then
        return true
    end
    if mode ~= "auto" then
        return false
    end
    local step = viewer.steps and viewer.steps[image_num]
    if not (step and step.w and step.h) then
        return false
    end
    local canvas = CanvasContext:getSize()
    return (canvas.w > canvas.h) ~= (step.w > step.h)
end

-- The panel takes the quarter opposite the device turn the row names.
local function panelRotationAngle(turned, rotate)
    if not (turned and rotate) then
        return nil
    end
    local canvas = CanvasContext:getSize()
    -- A landscape screen has taken that quarter; the panel takes the other.
    local clockwise = rotate == "left"
    if canvas.w > canvas.h then
        clockwise = not clockwise
    end
    return clockwise and 270 or 90
end

local PanelViewer = ImageViewer:extend{
    ui = nil,             -- the ReaderUI; UIManager:show does not set it
    page = nil,
    -- What this viewer walks; a panel too big for the window is several steps.
    steps = nil,
    -- Kept so buttons can re-open here: steps cannot be walked back to panels.
    panel_rects = nil,
    mode = nil,           -- "manga" | "comic"
    view = nil,
    -- Present only in the free view; its presence switches every override below.
    meguru_free = nil,
    -- The book's Rotate wide pages; nil leaves every rotation decision to stock.
    rotate = nil,
    -- "off" | "on" | "auto", cycled by the row's button and stored plugin-wide.
    rotate_mode = nil,
    -- Our own button object, so a tap can re-letter it; stock's lookup is sunk.
    meguru_rotate_button = nil,
    _meguru_warm = nil,
    _meguru_handoff_pending = nil,
}

-- Bound unconditionally: a D-pad device answers hasDPad(), not hasKeys().
function PanelViewer:init()
    ImageViewer.init(self)
    -- The opening step, before any switch: stock's own answer is the seed.
    self.rotated = rotatedFor(self, 1)
    self.key_events = self.key_events or {}
    self.key_events.MeguruArrowLeft = { { "Left" } }
    self.key_events.MeguruArrowRight = { { "Right" } }
    self.key_events.MeguruArrowUp = { { "Up" } }
    self.key_events.MeguruArrowDown = { { "Down" } }
end

-- The size travels too: a window tile is filed under its rectangle and its size.
function PanelViewer:meguruRelease(index)
    local doc = self.ui and self.ui.document
    local rect = self.steps and self.steps[index]
    if not (doc and rect and type(doc.releasePanelTile) == "function") then
        return false
    end
    return doc:releasePanelTile(self.page, rect, rect.out_w, rect.out_h)
end

function PanelViewer:meguruArmWarm()
    if self.meguru_free then
        return
    end
    if self._meguru_warm then
        UIManager:unschedule(self._meguru_warm)
        self._meguru_warm = nil
    end
    local action = function()
        self:meguruWarm()
    end
    self._meguru_warm = action
    UIManager:scheduleIn(WARM_DELAY, action)
end

function PanelViewer:meguruWarm()
    self._meguru_warm = nil
    if not UIManager:isWidgetShown(self) then
        return
    end
    local doc = self.ui and self.ui.document
    if not (doc and self.steps) then
        return
    end
    local cur = self._images_list_cur
    if cur < #self.steps then
        if not doc.dead_pages[self.page] then
            local next_step = self.steps[cur + 1]
            local ok, err = pcall(doc.drawPagePart, doc, self.page, next_step, 0,
                next_step.out_w, next_step.out_h)
            if not ok then
                logger.dbg("Meguru: panel prewarm failed:", err)
            end
        end
        return
    end
    -- hasConnection() gate: offline the fetch would block the UI to its timeout.
    local next_page = doc:getNextPage(self.page)
    if next_page and next_page > 0 and not doc.dead_pages[next_page]
        and doc:hasConnection() then
        -- The bbox, not just the dims: the crossing's own page turn lays the page
        -- out, and the crop is what that layout asks for.
        pcall(doc.getPageBBox, doc, next_page)
        local ok, panels = pcall(doc.getPanelsFromPage, doc, next_page, self.mode)
        -- And the first panel's tile, the crossing's one fresh render. Only the
        -- crop view: a window step's rect comes from Viewport, so the key differs.
        if ok and panels and panels[1] and not (self.view and self.view.window) then
            pcall(doc.drawPagePart, doc, next_page, panels[1], 0)
        end
    end
end

-- Release the left step and re-arm; the tile LRU then stays at two.
function PanelViewer:switchToImageNum(image_num)
    local previous = self._images_list_cur
    self.rotated = rotatedFor(self, image_num)
    ImageViewer.switchToImageNum(self, image_num)
    if previous and previous ~= image_num then
        self:meguruRelease(previous)
    end
    self:meguruArmWarm()
end

local panel_rotate_warned = false

-- Angle set after stock builds the widget; pre-layout that equals passing it.
function PanelViewer:_new_image_wg()
    ImageViewer._new_image_wg(self)
    local angle = panelRotationAngle(self.rotated, self.rotate)
    if not angle then
        return -- no direction from the book, or nothing to turn: stock's angle stands
    end
    if self._image_wg and not self._image_wg._bb then
        self._image_wg.rotation_angle = angle
        return
    end
    if not panel_rotate_warned then
        panel_rotate_warned = true
        logger.warn("Meguru: panel rotation angle could not be applied; "
            .. "ImageWidget rendered before _new_image_wg returned")
    end
end

-- The tap: mode on, stored, and applied to the panel under the finger.
function PanelViewer:meguruCycleRotateMode()
    local next_mode = ROTATE_MODES[1]
    for i, mode in ipairs(ROTATE_MODES) do
        if mode == self.rotate_mode then
            next_mode = ROTATE_MODES[i % #ROTATE_MODES + 1]
            break
        end
    end
    self.rotate_mode = next_mode
    Settings.set("panel_rotate", next_mode)
    self.rotated = rotatedFor(self, self._images_list_cur)
    if self.meguru_rotate_button then
        -- Width passed as stock does, so the row's geometry is not rebuilt.
        self.meguru_rotate_button:setText(rotateLabel(next_mode),
            self.meguru_rotate_button.width)
    end
    self:update()
    return true
end

-- Bounded by #self.steps: images_list_nb is the chrome switch, not a count.
function PanelViewer:onShowNextImage()
    if self.meguru_free then
        return true
    end
    if self._images_list_cur < #self.steps then
        self:switchToImageNum(self._images_list_cur + 1)
        return true
    end
    return self:meguruHandoff("next")
end

function PanelViewer:onShowPrevImage()
    if self.meguru_free then
        return true
    end
    if self._images_list_cur > 1 then
        self:switchToImageNum(self._images_list_cur - 1)
        return true
    end
    return self:meguruHandoff("previous")
end

-- Left/right walk the panels, the book decides next; up/down do nothing.
function PanelViewer:meguruArrow(direction)
    if self.meguru_free then
        return
    end
    if (direction == "right") == nextIsRight(self.mode) then
        return self:onShowNextImage()
    end
    return self:onShowPrevImage()
end

-- true even where nothing moved: an unconsumed key reaches the reader below.
function PanelViewer:onMeguruArrowLeft()
    self:meguruArrow("left")
    return true
end

function PanelViewer:onMeguruArrowRight()
    self:meguruArrow("right")
    return true
end

function PanelViewer:onMeguruArrowUp()
    return true
end

function PanelViewer:onMeguruArrowDown()
    return true
end

function PanelViewer:onShow()
    self:meguruArmWarm()
    return ImageViewer.onShow(self)
end

function PanelViewer:meguruShowButtons()
    if not self.buttons_visible then
        self.buttons_visible = true
        -- update(), not just the flag: it is what puts the row into the frame.
        self:update()
    end
    return true
end

-- Not button_container.dimen: its paint-time origin is never written back.
function PanelViewer:meguruOnButtons(pos)
    local row = self.buttons_visible and self.button_container
    if not (row and pos and type(row.getSize) == "function") then
        return false
    end
    local height = row:getSize().h or 0
    return height > 0 and pos.y >= Screen:getHeight() - height
end

function PanelViewer:onTap(arg, ges)
    if self.meguru_free then
        -- Strip first, so it summons the row rather than closing the view.
        if bottomMenuTap(ges.pos) then
            return self:meguruShowButtons()
        end
        -- A tap on the row is swallowed, not a tap on the page.
        if self:meguruOnButtons(ges.pos) then
            return true
        end
        -- No thirds here, so any other tap closes: the aim-free way out.
        self:onClose()
        return true
    end
    if self._images_list and ges.pos:intersectWith(self.main_frame.dimen) then
        local screen_w = Screen:getWidth()
        local screenshot_corner = not Device:hasMultitouch()
            and not self.buttons_visible
            and ges.pos.x < screen_w/10
            and ges.pos.y > Screen:getHeight()*9/10
        if not screenshot_corner then
            if bottomMenuTap(ges.pos) then
                return self:meguruShowButtons()
            end
            if ges.pos.x < screen_w/3 or ges.pos.x > screen_w*2/3 then
                local tapped_right = ges.pos.x > screen_w*2/3
                if tapped_right == nextIsRight(self.mode) then
                    self:onShowNextImage()
                else
                    self:onShowPrevImage()
                end
                return true
            end
        end
    end
    return ImageViewer.onTap(self, arg, ges)
end

-- Only at best fit: after a pinch a horizontal drag pans the panel instead.
function PanelViewer:onSwipe(arg, ges)
    local direction = ges.direction
    -- Tested at the gesture's start (ges.pos), before the pan and the chain.
    if bottomMenuSwipe(ges.pos, direction) then
        return self:meguruShowButtons()
    end
    if self.meguru_free then
        -- Read the finger's own path: compound names (northwest) express no axis.
        -- Every direction pans, south included; the way out is Close in the row.
        local from, to = ges.pos, ges.end_pos
        if from and to and (to.x ~= from.x or to.y ~= from.y) then
            return self:panBy(from.x - to.x, from.y - to.y)
        end
        -- No path on this event: fall back to the four single directions.
        local distance = ges.distance or 0
        if direction == "west" then
            return self:panBy(distance, 0)
        elseif direction == "east" then
            return self:panBy(-distance, 0)
        elseif direction == "north" then
            return self:panBy(0, distance)
        elseif direction == "south" then
            return self:panBy(0, -distance)
        end
        return true
    end
    if self.scale_factor == 0 and (direction == "west" or direction == "east") then
        local forward = (self.mode == "manga") and "east" or "west"
        if direction == forward then
            self:onShowNextImage()
        else
            self:onShowPrevImage()
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

-- Panels, then close, then GotoPage, then open: that order is load-bearing.
function PanelViewer:meguruHandoff(direction)
    if self._meguru_handoff_pending then
        return true
    end
    local ui = self.ui
    local doc = ui and ui.document
    if not doc then
        return true
    end
    local page = (direction == "next") and doc:getNextPage(self.page)
        or doc:getPrevPage(self.page)
    if not page or page == 0 then
        return true -- nothing that way: stay where we are, like stock does
    end
    self._meguru_handoff_pending = true

    local this = self
    local mode = self.mode
    -- Read outside the tick: this viewer is gone before it runs.
    local rotate = self.rotate
    local view = self.view and {
        window = self.view.window,
        level = self.view.level,
    } or nil
    local show_buttons = self.buttons_visible
    UIManager:tickAfterNext(function()
        local ok, err = pcall(function()
            if not UIManager:isWidgetShown(this) then
                return
            end
            -- hasConnection() gate: a fetch here would block the UI inside a tick.
            local panels, reason
            -- Not `_`: that is gettext here, and a bare assignment clobbers it.
            local accepted
            if doc:hasConnection() then
                panels, accepted, reason = doc:getPanelsFromPage(page, mode)
            else
                reason = "no connection"
            end
            UIManager:close(this)
            ui:handleEvent(Event:new("GotoPage", page))
            if panels then
                local index = (direction == "next") and 1 or #panels
                -- Coming back, open the last panel at its end; a crossing flag.
                local opts = view and {
                    window = view.window,
                    level = view.level,
                    at_end = direction == "previous",
                    buttons_visible = show_buttons,
                } or nil
                PanelZoom.open(ui, page, panels, index, mode, rotate, opts)
            else
                logger.dbg("Meguru: panel zoom crossed to page", page,
                    "with no page to show:", tostring(reason))
            end
        end)
        if not ok then
            logger.warn("Meguru: panel handoff failed:", err)
        end
    end)
    return true
end

function PanelViewer:onCloseWidget()
    if self._meguru_warm then
        UIManager:unschedule(self._meguru_warm)
        self._meguru_warm = nil
    end
    if self.meguru_free then
        Settings.set("free_zoom_scale", self.meguru_free.scale)
    end
    -- Stock first: it may still touch the widget holding the bytes we free next.
    ImageViewer.onCloseWidget(self)
    self:meguruRelease(self._images_list_cur)
end

-- The levels the zoom button cycles, in the order it cycles them.
local ZOOM_LEVELS = { 1.4, 1.7, 1.9 }

-- Walks up from where the reader is; a lookup would miss a level on no list.
local function levelAfter(list, level)
    for i = 1, #list do
        if list[i] > level + 0.001 then
            return list[i]
        end
    end
    return list[1]
end

-- Levels only: Original is a scale, not a multiple of the fit.
local FREE_LEVELS = { 1.5, 2, 2.5 }

-- Bounded by Viewport.scaleBounds, so the buttons cannot outrun a pinch.
local FREE_STEP = 0.25
local FREE_MIN_LEVEL = 1
local FREE_MAX_LEVEL = 4

-- Ceiling is the top of ZOOM_LEVELS, so + and the cycle button stop together.
local WINDOW_STEP = 0.1
local WINDOW_MIN_LEVEL = 1
local WINDOW_MAX_LEVEL = ZOOM_LEVELS[#ZOOM_LEVELS]

local function freeStepAfter(scale, fit)
    return levelAfter(FREE_LEVELS, scale / fit) * fit
end

-- %.2f minus one trailing zero: %.1f would render a 1.75 step as 1.8x.
local function freeLabel(scale, fit)
    if math.abs(scale - 1) < 0.001 then
        return "1×"
    end
    local text = string.format("%.2f", scale / fit):gsub("0$", "")
    return text .. "×"
end

-- Levels measure against the content; the window clamps to the page.
local function freeFit(free)
    return Viewport.fitScale(free.content or free.dims, free.screen)
end

-- The picture sits inside the picture area, not at the screen's corner.
function PanelViewer:meguruFreeMapping()
    local cur = self.steps and self.steps[1]
    if not cur then
        return nil
    end
    local padding = self.image_padding or 0
    local w = (self.width or Screen:getWidth()) - 2 * padding
    local h = (self.img_container_h or Screen:getHeight()) - 2 * padding
    local fit = math.min(w / cur.out_w, h / cur.out_h, 1)
    return fit,
        padding + (w - cur.out_w * fit) / 2,
        padding + (h - cur.out_h * fit) / 2
end

-- nil before the first layout.
function PanelViewer:meguruFreePageAt(pos)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    local fit, x0, y0 = self:meguruFreeMapping()
    if not (cur and fit and pos) then
        return nil
    end
    local drawn = free.scale * fit
    return cur.x + (pos.x - x0) / drawn, cur.y + (pos.y - y0) / drawn
end

-- Mutate in place: switchToImageNum would not re-resolve a fresh step.
function PanelViewer:meguruFreeWindow(scale, cx, cy)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return false
    end
    local lo, hi = Viewport.scaleBounds(free.dims, free.screen, free.content)
    free.scale = math.max(lo, math.min(hi, scale))
    local step = Viewport.windowAt(free.dims, free.screen, free.scale, cx, cy)
    if not step then
        return false
    end
    for key, value in pairs(step) do
        cur[key] = value
    end
    -- update() never re-resolves self.image; resolve the entry again here.
    local entry = self._images_list and self._images_list[self._images_list_cur]
    if type(entry) == "function" then
        local image = entry()
        if image then
            self.image = image
        end
    end
    self:meguruFreeLabel()
    self:update()
    return true
end

function PanelViewer:meguruFreeLabel()
    local free = self.meguru_free
    local buttons = self.button_table
    local button = buttons and type(buttons.getButtonById) == "function"
        and buttons:getButtonById("zoom_level")
    if free and type(button) == "table" then
        button:setText(freeLabel(free.scale, freeFit(free)), button.width)
    end
end

-- Takes the argument as-is, so the page moves with the finger, not against it.
function PanelViewer:panBy(x, y)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return ImageViewer.panBy(self, x, y)
    end
    local fit = self:meguruFreeMapping()
    local drawn = free.scale * (fit or 1)
    return self:meguruFreeWindow(free.scale,
        cur.x + cur.w / 2 + x / drawn,
        cur.y + cur.h / 2 + y / drawn)
end

-- Keeps its own scale: stock's field is what ImageWidget scales the tile by.
function PanelViewer:meguruFreeZoom(ges, closer)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur or not ges then
        return false
    end
    local dim
    if ges.direction == "vertical" then
        dim = free.screen.h
    elseif ges.direction == "horizontal" then
        dim = free.screen.w
    else
        dim = math.sqrt(free.screen.w ^ 2 + free.screen.h ^ 2)
    end
    local amount = (ges.distance or 0) / dim
    local target = free.scale * (closer and (1 - amount) or (1 + amount))
    local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
    if not closer and ges.pos then
        -- A spread keeps the page point under the fingers fixed.
        local lo, hi = Viewport.scaleBounds(free.dims, free.screen, free.content)
        local scale = math.max(lo, math.min(hi, target))
        local px, py = self:meguruFreePageAt(ges.pos)
        if px then
            cx = cx + (px - cx) * (1 - free.scale / scale)
            cy = cy + (py - cy) * (1 - free.scale / scale)
        end
        target = scale
    end
    return self:meguruFreeWindow(target, cx, cy)
end

function PanelViewer:onPinch(arg, ges)
    if self.meguru_free then
        return self:meguruFreeZoom(ges, true)
    end
    return ImageViewer.onPinch(self, arg, ges)
end

function PanelViewer:onSpread(arg, ges)
    if self.meguru_free then
        return self:meguruFreeZoom(ges, false)
    end
    return ImageViewer.onSpread(self, arg, ges)
end

function PanelViewer:meguruCycleFreeZoom()
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return
    end
    local fit = freeFit(free)
    logger.dbg("Meguru: free zoom", freeLabel(freeStepAfter(free.scale, fit), fit),
        "on page", self.page)
    self:meguruFreeWindow(freeStepAfter(free.scale, fit), cur.x + cur.w / 2,
        cur.y + cur.h / 2)
end

-- A quarter-level nudge from where the reader is, floored at the fit.
function PanelViewer:meguruFreeStepZoom(direction)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return
    end
    local fit = freeFit(free)
    local level = free.scale / fit + direction * FREE_STEP
    level = math.max(FREE_MIN_LEVEL, math.min(FREE_MAX_LEVEL, level))
    -- A line per button press, a deliberate act, not per-event gesture chatter.
    logger.dbg("Meguru: free zoom", freeLabel(level * fit, fit), "on page", self.page)
    self:meguruFreeWindow(level * fit, cur.x + cur.w / 2, cur.y + cur.h / 2)
end

-- One re-open for a step and a cycle, so they cannot drift apart.
function PanelViewer:meguruReopenAtLevel(level)
    local view = self.view
    local cur = self.steps and self.steps[self._images_list_cur]
    -- Read before the close: this viewer is gone by the next statement.
    local panels = self.panel_rects
    local ui, page = self.ui, self.page
    local mode, rotate = self.mode, self.rotate
    local show_buttons = self.buttons_visible
    if not (view and view.window and cur and panels and ui) then
        return
    end
    Settings.set("panel_zoom_level", level)
    UIManager:close(self)
    -- pcall'd: a viewer built and never painted leaves a repaint closure.
    local ok, err = pcall(PanelZoom.open, ui, page, panels, cur.panel, mode, rotate, {
        window = true,
        level = level,
        -- The window's start corner, which is what the stops are anchored to.
        keep = { x = cur.x, y = cur.y },
        buttons_visible = show_buttons,
    })
    if not ok then
        logger.warn("Meguru: the window view could not be re-opened:", err)
    end
end

function PanelViewer:meguruCycleZoomLevel()
    local level = self.view and self.view.level
    if level then
        self:meguruReopenAtLevel(levelAfter(ZOOM_LEVELS, level))
    end
end

-- The unit is the level; rounding to a tenth keeps + and the cycle agreeing.
function PanelViewer:meguruStepZoomLevel(direction)
    local view = self.view
    local level = view and (view.level or WINDOW_MIN_LEVEL)
    if not level then
        return
    end
    local current = level
    level = level + direction * WINDOW_STEP
    level = math.floor(level * 10 + 0.5) / 10
    level = math.max(WINDOW_MIN_LEVEL, math.min(WINDOW_MAX_LEVEL, level))
    -- A no-op press must not pay a close-and-reopen to land on the same page.
    if level == current then
        return
    end
    logger.dbg("Meguru: panel zoom", string.format("%.1f×", level), "on page", self.page)
    self:meguruReopenAtLevel(level)
end

-- Cycles crop/window/free by close-and-reopen; writes the book's own value.
function PanelViewer:meguruCycleView()
    local view = self.view
    local cur = self.steps and self.steps[self._images_list_cur]
    local panels = self.panel_rects
    local ui, page = self.ui, self.page
    local doc = ui and ui.document
    local mode, rotate = self.mode, self.rotate
    local show_buttons = self.buttons_visible
    if not (view and cur and ui and doc) then
        return
    end
    local kind = self.meguru_free and "zoom" or (view.window and "window" or "crop")
    kind = ({ crop = "window", window = "zoom", zoom = "crop" })[kind]
    -- Leaving the free view needs panels first, before anything is closed.
    if not panels and kind ~= "zoom" then
        local ok, got = pcall(doc.getPanelsFromPage, doc, page, mode)
        panels = ok and got or nil
        if not panels then
            logger.info("Meguru: cannot leave the free view for", kind,
                "- no panels for page", page)
            return
        end
    end
    local configurable = doc.configurable
    if configurable and configurable.panel_view ~= nil then
        configurable.panel_view = kind
        if ui.doc_settings then
            ui.doc_settings:saveSetting("kopt_panel_view", kind)
        end
    end
    -- Crop's step index is a panel index; a window step carries its own panel.
    local panel
    if not self.meguru_free then
        panel = view.window and cur.panel or self._images_list_cur
    end
    UIManager:close(self)
    local ok, err = pcall(PanelZoom.open, ui, page, panels, panel, mode, rotate, {
        window = kind == "window",
        free = kind == "zoom",
        level = view.level,
        buttons_visible = show_buttons,
        tap = kind ~= "crop" and { x = cur.x + cur.w / 2, y = cur.y + cur.h / 2 } or nil,
        keep = kind == "window" and { x = cur.x, y = cur.y } or nil,
    })
    if not ok then
        logger.warn("Meguru: the next view could not be opened:", err)
    end
end

-- Rebuild the row: stock builds it in init and cannot remove a button.
local buttons_warned = false

local function installRow(viewer)
    if type(viewer.button_table) ~= "table" then
        if not buttons_warned then
            buttons_warned = true
            logger.warn("Meguru: the viewer's button table was not found; "
                .. "the panel view keeps stock's row")
        end
        return false
    end
    local free = viewer.meguru_free ~= nil
    local window = not free and viewer.view and viewer.view.window
    -- or 1 matches the scale's own arithmetic: no level means fit-to-screen.
    local level = (viewer.view and viewer.view.level) or 1
    local close = {
        id = "close",
        text = _("Close"),
        callback = function()
            viewer:onClose()
        end,
    }
    local switch = {
        id = "view",
        -- Names the view the reader is in, in the row's own three words.
        text = free and _("free view")
            or (window and _("pan & zoom") or _("panel cut")),
        callback = function()
            viewer:meguruCycleView()
        end,
    }
    local entries = { switch }
    if free then
        entries[#entries + 1] = {
            id = "zoom_out",
            text = "-",
            callback = function()
                viewer:meguruFreeStepZoom(-1)
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_level",
            text = freeLabel(viewer.meguru_free.scale,
                freeFit(viewer.meguru_free)),
            callback = function()
                viewer:meguruCycleFreeZoom()
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_in",
            text = "+",
            callback = function()
                viewer:meguruFreeStepZoom(1)
            end,
        }
        entries[#entries + 1] = close
    elseif window then
        entries[#entries + 1] = {
            id = "zoom_out",
            text = "-",
            callback = function()
                viewer:meguruStepZoomLevel(-1)
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_level",
            text = string.format("%.1f×", level),
            callback = function()
                viewer:meguruCycleZoomLevel()
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_in",
            text = "+",
            callback = function()
                viewer:meguruStepZoomLevel(1)
            end,
        }
        entries[#entries + 1] = close
    else
        -- Scale dropped as in the window row; Rotate is ours, three states wide.
        entries[#entries + 1] = {
            id = "rotate",
            text = rotateLabel(viewer.rotate_mode),
            callback = function()
                viewer:meguruCycleRotateMode()
            end,
        }
        entries[#entries + 1] = close
    end

    local table_ = ButtonTable:new{
        width = viewer.width - 2 * viewer.button_padding,
        buttons = { entries },
        zero_sep = true,
        show_parent = viewer,
    }
    -- Stock re-letters scale/rotate by id; the sink answers buttons not here.
    local sink = { width = 0, setText = function() end }
    if window or free then
        table_.button_by_id.scale = sink
        table_.button_by_id.rotate = sink
    else
        -- Ours to letter: stock's two-state text would overwrite the mode's.
        viewer.meguru_rotate_button = table_.button_by_id.rotate
        table_.button_by_id.scale = sink
        table_.button_by_id.rotate = sink
    end
    viewer.button_table = table_
    viewer.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = viewer.width,
            h = table_:getSize().h,
        },
        table_,
    }
    -- Puts the new container into the frame init built; stock's own update call.
    viewer:update()
    return true
end

-- The reader's own crop box; nil with no crop, so callers measure as before.
local function contentDims(doc, page, dims)
    if not (doc and page and dims and type(doc.getPageBBox) == "function") then
        return nil
    end
    -- pcall'd: this seam is shared, and pagenumbercrop patches it.
    local ok, box = pcall(doc.getPageBBox, doc, page)
    if not ok or type(box) ~= "table" then
        return nil
    end
    local x0, y0 = tonumber(box.x0), tonumber(box.y0)
    local x1, y1 = tonumber(box.x1), tonumber(box.y1)
    if not (x0 and y0 and x1 and y1) then
        return nil
    end
    local w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 then
        return nil
    end
    if w >= dims.w and h >= dims.h then
        return nil
    end
    return { w = w, h = h }
end

-- mode, then rotate: two adjacent strings, and swapping them is silent.
-- Returns false when there is nothing to show; the caller falls back to stock.
function PanelZoom.open(ui, page, panels, index, mode, rotate, opts)
    local doc = ui and ui.document
    local free = opts and opts.free
    if not (doc and (free or (panels and #panels > 0))) then
        return false
    end
    local window = opts and opts.window
    local steps, start = panels, index
    local screen
    local free_state
    -- Every geometry number, so a wrong-shaped window can be told from a page.
    local geom
    if free then
        local dims = doc:getPageDims(page)
        screen = CanvasContext:getSize()
        if not (dims and screen) then
            return false
        end
        local content = contentDims(doc, page, dims)
        local lo, hi = Viewport.scaleBounds(dims, screen, content)
        local stored = Settings.get("free_zoom_scale")
        local scale = (type(stored) == "number" and stored > 0) and stored
            or Viewport.fitScale(content or dims, screen) * (opts.level or 1)
        scale = math.max(lo, math.min(hi, scale))
        local step = Viewport.windowAt(dims, screen, scale, opts.tap and opts.tap.x,
            opts.tap and opts.tap.y)
        if not step then
            return false
        end
        steps, start = { step }, 1
        free_state = { dims = dims, content = content, screen = screen, scale = scale }
        geom = { dims = dims, content = content, screen = screen, scale = scale }
    elseif window then
        -- Page size in panel space; the geometry takes mode for the side order.
        local dims
        dims, screen = doc:getPageDims(page), CanvasContext:getSize()
        local content = contentDims(doc, page, dims)
        local scale = Viewport.fitScale(content or dims, screen) * (opts.level or 1)
        steps, start = Viewport.steps(panels, dims, screen,
            index and { panel = index, at_end = opts.at_end },
            mode == "manga", scale)
        if not steps then
            return false
        end
        if opts.keep and index then
            start = Viewport.stepNearest(steps, index, opts.keep.x, opts.keep.y) or start
        end
        geom = { dims = dims, content = content, screen = screen, scale = scale }
    end
    local images = {}
    for i, rect in ipairs(steps) do
        images[i] = stepImage(doc, page, rect)
    end
    -- BlitBuffers are malloc'd outside the Lua heap; a free here would double-free.
    images.image_disposable = false

    local viewer = PanelViewer:new{
        ui = ui,
        page = page,
        steps = steps,
        panel_rects = panels,
        mode = mode,
        rotate = rotate,
        -- Read per viewer: a rebuild asks the store, so no state has to travel.
        rotate_mode = rotateMode(),
        -- The crop view carries opts too, and `meguruCycleView` reads this field
        -- for truthiness: nil here is a dead `panel cut` button.
        view = opts,
        meguru_free = free_state,
        image = images,
        -- Not a count: stock tests _images_list_nb > 1 to build the progress bar.
        images_list_nb = 1,
        image_disposable = false,
        images_keep_pan_and_zoom = false,
        with_title_bar = false,
        fullscreen = true,
        -- Hidden until the menu gesture summons it; state travels on re-open.
        buttons_visible = (opts and opts.buttons_visible == true) or false,
    }
    -- The row is cosmetic: a failure must cost the buttons, never the view.
    local ok, err = pcall(installRow, viewer)
    if not ok then
        logger.warn("Meguru: the panel view's button row was not built:", err)
    end

    -- Before show: nothing after it may throw and leave a viewer on the stack.
    if geom then
        -- The size the plugin was handed; a rotated screen here is the diagnosis.
        local c = geom.content
        logger.dbg("Meguru: window geometry page", page,
            "screen", geom.screen.w .. "x" .. geom.screen.h,
            "rotation", tostring(Screen:getRotationMode()),
            "page", geom.dims.w .. "x" .. geom.dims.h,
            "content", c and (c.w .. "x" .. c.h) or "none",
            "level", tostring(opts and opts.level),
            "scale", string.format("%.4f", geom.scale))
    end
    if free then
        logger.dbg("Meguru: free zoom opened on page", page,
            "(" .. tostring(mode) .. ", " .. freeLabel(free_state.scale,
                freeFit(free_state)) .. ")")
    else
        logger.dbg("Meguru: panel zoom opened on page", page, "panel", index or 1,
            "of", #panels, "(" .. tostring(mode) .. ")",
            window and ("window view, step " .. (start or 1) .. " of " .. #steps)
                or "cropped panels",
            rotate and ("turned " .. rotate) or "no turn direction")
    end

    -- Fill main_frame.dimen before show, or a never-painted viewer dies later.
    do
        local frame = viewer.main_frame
        if frame and not frame.dimen then
            local size = frame:getSize()
            frame.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
        end
    end
    -- show dispatches Show, which arms the pre-warm; nothing is armed here.
    UIManager:show(viewer)
    -- Land on the pressed step through the switch a swipe uses, releasing step 1.
    if start and start > 1 and start <= #steps then
        viewer:switchToImageNum(start)
    end
    return true
end

return PanelZoom
