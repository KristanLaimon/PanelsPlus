local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Geometry = require("src._geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Memory = require("src._memory")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Screenshoter = require("ui/widget/screenshoter")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local OcrDebug = require("src._ocrdebug")
local PageBitmap = require("src._pagebitmap")
local WordFinder = require("src._wordfinder")
local _ = require("gettext")
local logger = require("logger")

--- Default number of steps the smooth-navigation pan animation is split into,
--- used when a viewer has no `nav_transition_frames` of its own.
local NAV_TRANSITION_STEPS_DEFAULT = 1
--- Hard cap on the shared transition bitmap's area, as a multiple of the screen's
--- area, to bound the one-shot render/upscale cost when the destination panel
--- needs a much higher zoom than the two panels' combined bounding box.
local NAV_TRANSITION_MAX_AREA_MULTIPLIER = 16
--- Minimum free memory required before allocating a smooth-transition canvas
--- (up to `NAV_TRANSITION_MAX_AREA_MULTIPLIER`x screen area), matching the
--- threshold `ViewerController:hasMemoryForPrerender()` uses for comparably
--- sized panel-tile allocations.
local NAV_TRANSITION_MIN_FREE_BYTES = 40 * 1024 * 1024

--- Return the KOReader canvas-fit zoom for a native-page rectangle.
---
--- Mirrors `Document:drawPagePart()`'s own (non-rotated) best-fit formula, so
--- this tells us how big `rect` would render if `drawPagePart` drew it alone.
---
--- @param rect PPRect Native page rectangle.
--- @return number zoom Scale factor from page-space to screen-space.
local function canvasFitZoom(rect)
    return math.min(Screen:getWidth() / (rect.w or 1), Screen:getHeight() / (rect.h or 1))
end

--- ImageViewer subclass for navigating one page's ordered panel sequence.
---
--- @class PanelViewer : ImageViewer
--- @field reading_mode PPReadingMode Current left/right panel order.
--- @field crop_mode PPCropMode Current crop rendering mode.
--- @field margin_ratio number Zoom-out fraction "margin" crop mode applies to non-full-page panels.
--- @field bleed_ratio number Fraction of extra page area "loose" crop mode reveals around each panel.
--- @field panel_is_full_page boolean[]|nil Per-panel flag matching `_images_list`, true when a panel spans nearly the whole page.
--- @field detector PPDetector Detector the displayed panels came from.
--- @field detector_cycle_callback fun(viewer:PanelViewer):boolean|nil
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field tap_navigation boolean Whether tapping the left/right screen edges navigates between panels.
--- @field swipe_navigation boolean Whether horizontal swipes navigate between panels.
--- @field more_config_callback fun(viewer:PanelViewer):boolean|nil
--- @field progress_bar_visible boolean Whether the bottom progress bar is shown.
--- @field nav_transition_mode PPNavTransitionMode Instant swap vs. animated camera pan between panels.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field nav_transition_cross_page boolean Whether smooth navigation also animates across page boundaries.
--- @field nav_transition_frames integer Number of discrete steps a smooth camera pan is split into.
--- @field page number|nil Document page number represented by `panels`.
--- @field panels PPPanel[]|nil Ordered panel rectangles.
--- @field image_rects PPPanel[]|nil Crop rectangles matching `_images_list`, for prerendering.
--- @field reader_ui table|nil Reader UI that owns the normal document gesture zones.
--- @field panel_prerender_callback fun(viewer:PanelViewer, index:integer)|nil
--- @field boundary_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field mode_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field crop_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field margin_ratio_callback fun(viewer:PanelViewer, ratio:number, activate_margin_mode:boolean|nil):boolean|nil
--- @field bleed_ratio_callback fun(viewer:PanelViewer, ratio:number, activate_loose_mode:boolean|nil):boolean|nil
--- @field progress_bar_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field nav_transition_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field nav_transition_duration_callback fun(viewer:PanelViewer, seconds:number):boolean|nil
--- @field nav_transition_frames_callback fun(viewer:PanelViewer, frames:integer):boolean|nil
--- @field nav_transition_options_callback fun(viewer:PanelViewer):boolean|nil
--- @field nav_boundary_peek_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):PPBoundaryResolution|nil
--- @field nav_boundary_commit_callback fun(viewer:PanelViewer, direction:PPBoundaryDirection, resolved:PPBoundaryResolution):boolean|nil
--- @field buttons_visible boolean Whether controls are currently shown.
--- @field with_title_bar boolean Whether ImageViewer title bar is shown.
--- @field fullscreen boolean Whether the viewer is fullscreen.
--- @field images_keep_pan_and_zoom boolean Whether ImageViewer preserves pan/zoom.
local PanelViewer = ImageViewer:extend{
    name = "panels_plus_panel_viewer",
    reading_mode = "manga",
    crop_mode = "strict",
    margin_ratio = 0.12,
    bleed_ratio = 0.08,
    panel_is_full_page = nil,
    detector = "auto",
    invert_swipe = false,
    tap_navigation = false,
    swipe_navigation = true,
    more_config_callback = nil,
    progress_bar_visible = true,
    hold_text_selection = true,
    ocr_debug_mode = false,
    nav_transition_mode = "classic",
    nav_transition_duration = 0.4,
    nav_transition_cross_page = true,
    nav_transition_frames = NAV_TRANSITION_STEPS_DEFAULT,
    page = nil,
    panels = nil,
    image_rects = nil,
    reader_ui = nil,
    panel_prerender_callback = nil,
    detector_cycle_callback = nil,
    boundary_callback = nil,
    mode_toggle_callback = nil,
    crop_toggle_callback = nil,
    margin_ratio_callback = nil,
    bleed_ratio_callback = nil,
    progress_bar_toggle_callback = nil,
    nav_transition_toggle_callback = nil,
    nav_transition_duration_callback = nil,
    nav_transition_frames_callback = nil,
    nav_transition_options_callback = nil,
    nav_boundary_peek_callback = nil,
    nav_boundary_commit_callback = nil,
    buttons_visible = false,
    with_title_bar = false,
    fullscreen = true,
    images_keep_pan_and_zoom = false,
    mousewheel_zoom_step = 0.2,
}

--- Return whether the current image overflows its viewport and can be panned.
---
--- A smooth nav transition's synthetic canvas (`animateSwitchToImageNum()`/
--- `animateBoundaryTransition()`) is deliberately built larger than the
--- viewport to give the camera pan room to cross, which made this report
--- pannable while it plays even though the user isn't manually panning
--- anything. That falsely blocked tap/swipe navigation (they fall back to
--- pan handling, i.e. tap opened the options overlay instead of advancing)
--- for the animation's duration, so treat mid-transition frames as
--- unpannable -- `_panels_plus_transition_active` is already the guard
--- `animateSwitchToImageNum()`/`animateBoundaryTransition()` use to swallow
--- a re-entrant nav call, so a tap/swipe during the animation now reaches
--- `onShowNextImage()`/`onShowPrevImage()` again and is safely absorbed there
--- instead of misfiring the options toggle.
---
--- @return boolean pannable `true` when at least one axis is larger than the viewport.
function PanelViewer:isImagePannable()
    if not self._image_wg or self._panels_plus_transition_active then
        return false
    end

    self._image_wg:getSize()
    local viewport_w = self._image_wg.width
    local viewport_h = self._image_wg.height
    return (viewport_w and self._image_wg:getCurrentWidth() > viewport_w + 1)
        or (viewport_h and self._image_wg:getCurrentHeight() > viewport_h + 1)
end

--- Return whether this viewer is still registered as a top-level UIManager window.
---
--- ImageViewer schedules repaint-region callbacks that may run after a fast
--- panel/page switch has already closed the old viewer.
---
--- @return boolean open `true` while the viewer remains on the window stack.
function PanelViewer:isOpen()
    for _, window in ipairs(UIManager._window_stack or {}) do
        if window.widget == self then
            return true
        end
    end
    return false
end

--- Wrap ImageViewer's deferred repaint callbacks so stale viewers cannot crash.
---
--- @param widget any Widget passed to `UIManager:setDirty`.
--- @param refreshfunc function Deferred refresh callback from ImageViewer.
--- @return function refreshfunc Guarded callback.
function PanelViewer:guardRefreshFunc(widget, refreshfunc)
    return function()
        if widget == self and not self:isOpen() then
            return nil
        end
        if not self.main_frame or not self.main_frame.dimen then
            return nil
        end
        return refreshfunc()
    end
end

--- Run a base ImageViewer method while guarding the repaint callbacks it queues.
---
--- @param callback function Method body to execute.
function PanelViewer:withGuardedImageViewerRefresh(callback)
    local original_set_dirty = UIManager.setDirty
    UIManager.setDirty = function(manager, widget, refreshtype, refreshregion, refreshdither)
        if type(refreshtype) == "function"
                and (widget == self or (widget == nil and self._panels_plus_closing)) then
            refreshtype = self:guardRefreshFunc(widget, refreshtype)
        end
        return original_set_dirty(manager, widget, refreshtype, refreshregion, refreshdither)
    end

    local ok, err = pcall(callback)
    UIManager.setDirty = original_set_dirty
    if not ok then
        error(err)
    end
end

--- Return whether a reader touch zone should be passed through to KOReader.
---
--- Only user-configured gesture plugin zones (like multiswipe gestures) are
--- passed through to KOReader. Normal page navigation and highlight zones are
--- captured by PanelViewer.
---
--- @param zone_id string|nil KOReader touch zone id.
--- @param gestures table|nil Gestures plugin instance from the reader UI.
--- @return boolean is_gesture_zone `true` when this touch zone should be dispatched to KOReader.
function PanelViewer:isReaderGestureZone(zone_id, gestures)
    if not zone_id or not gestures then
        return false
    end
    -- Keep panel ImageViewer pinch/spread zooming local.
    if zone_id == "spread_gesture" or zone_id == "pinch_gesture" then
        return false
    end
    if zone_id == "multiswipe" then
        return true
    end
    return gestures.gestures and gestures.gestures[zone_id] ~= nil
end

--- Execute one normal reader gesture while this fullscreen viewer is on top.
---
--- Touch handlers and gesture plugins dispatch actions through `UIManager:sendEvent()`.
--- While Panels+ is open, those events would otherwise stop at this viewer, so this
--- temporarily routes dispatched actions to the reader UI first.
---
--- @param handler function Gesture zone handler from KOReader's reader UI.
--- @param ges table Gesture event to execute.
--- @return boolean handled Whether the gesture action consumed the event.
function PanelViewer:runReaderGestureHandler(handler, ges)
    local reader_ui = self.reader_ui
    if not reader_ui then
        return false
    end

    local page_before = reader_ui.page
        or (reader_ui.paging and reader_ui.paging.current_page)
        or (reader_ui.view and reader_ui.view.state and reader_ui.view.state.page)
        or (reader_ui.document and type(reader_ui.document.getCurrentPage) == "function" and reader_ui.document:getCurrentPage())
    local page_changed = false

    local original_send_event = UIManager.sendEvent
    UIManager.sendEvent = function(manager, event)
        if reader_ui:handleEvent(event) then
            if event and (event.cmd == "GotoNextPage" or event.cmd == "GotoPrevPage"
               or event.cmd == "PageForward" or event.cmd == "PageBackward"
               or event.cmd == "GotoPage") then
                page_changed = true
            end
            return
        end
        return original_send_event(manager, event)
    end

    local ok, handled = pcall(handler, ges)
    UIManager.sendEvent = original_send_event
    if not ok then
        logger.warn("[Panels+] reader touch zone / gesture handler failed:", tostring(handled))
        error(handled)
    end

    local page_after = reader_ui.page
        or (reader_ui.paging and reader_ui.paging.current_page)
        or (reader_ui.view and reader_ui.view.state and reader_ui.view.state.page)
        or (reader_ui.document and type(reader_ui.document.getCurrentPage) == "function" and reader_ui.document:getCurrentPage())
    if (page_changed or (page_after and page_before and page_after ~= page_before)) and self:isOpen() then
        Timing.log("reader gesture/touch zone triggered page turn (%s -> %s); closing viewer", tostring(page_before), tostring(page_after))
        self:onClose()
    end
    return handled == true
end

--- Try handling a gesture or touch zone through KOReader's normal reader UI touch zones.
---
--- @param ges table Gesture event.
--- @return boolean handled Whether a configured reader touch zone or gesture consumed it.
function PanelViewer:dispatchReaderGesture(ges)
    if self:isImagePannable() then
        return false
    end

    local reader_ui = self.reader_ui
    local gestures = reader_ui and reader_ui.gestures
    local zones = reader_ui and reader_ui._ordered_touch_zones
    if not gestures or not zones then
        return false
    end

    for _, zone in ipairs(zones) do
        local zone_id = zone.def and zone.def.id
        if self:isReaderGestureZone(zone_id, gestures)
                and zone.gs_range
                and zone.handler
                and zone.gs_range:match(ges) then
            Timing.log("dispatchReaderGesture: passing gesture (type=%s) to reader zone '%s'", tostring(ges and ges.type), tostring(zone_id))
            if self:runReaderGestureHandler(zone.handler, ges) then
                return true
            end
        end
    end
    return false
end

--- Let configured reader gestures run in focused-panel mode before local viewer gestures.
---
--- @param ges table Gesture event.
--- @return boolean|nil handled Whether the gesture was consumed.
function PanelViewer:onGesture(ges)
    if self:dispatchReaderGesture(ges) then
        return true
    end
    return ImageViewer.onGesture(self, ges)
end

--- Pan the zoomed image using KOReader's 8-direction swipe gesture values.
---
--- @param ges table Gesture event with `direction` and `distance`.
--- @return boolean handled Always true after processing a swipe.
function PanelViewer:panBySwipe(ges)
    local direction = ges.direction
    local distance = ges.distance or 0
    local sq_distance = math.sqrt(distance * distance / 2)

    if direction == "north" then
        self:panBy(0, distance)
    elseif direction == "south" then
        self:panBy(0, -distance)
    elseif direction == "east" then
        self:panBy(-distance, 0)
    elseif direction == "west" then
        self:panBy(distance, 0)
    elseif direction == "northeast" then
        self:panBy(-sq_distance, sq_distance)
    elseif direction == "northwest" then
        self:panBy(sq_distance, sq_distance)
    elseif direction == "southeast" then
        self:panBy(-sq_distance, -sq_distance)
    elseif direction == "southwest" then
        self:panBy(sq_distance, -sq_distance)
    end
    return true
end

--- Return which horizontal swipe direction advances to the next panel.
---
--- @return '"west"'|'"east"' direction Swipe direction treated as next.
function PanelViewer:getNextSwipeDirection()
    local direction
    if self.reading_mode == "comic" then
        direction = "east"
    else
        direction = "west"
    end
    if self.invert_swipe then
        return direction == "west" and "east" or "west"
    end
    return direction
end

--- Fraction of screen width, on each side, that counts as a tap-navigation
--- zone when `tap_navigation` is on. The remaining middle strip keeps the
--- default tap-to-toggle-controls behavior.
local TAP_NAV_ZONE_RATIO = 1 / 3

--- Return which screen side a tap must land on to advance to the next panel.
---
--- Manga (right-to-left) reads forward towards the left edge, so tapping the
--- left side advances; Comic (left-to-right) reads forward towards the right
--- edge, so tapping the right side advances. Unlike `getNextSwipeDirection()`,
--- this is independent of `invert_swipe`, which only affects the swipe
--- gesture, not tap zones.
---
--- @return '"left"'|'"right"' side Tap zone treated as next.
function PanelViewer:getNextTapSide()
    return self.reading_mode == "comic" and "right" or "left"
end

--- Return whether a tap position falls in the left tap-navigation zone.
---
--- @param pos table|nil Tap position `{x = number}`.
--- @return boolean is_left `true` when the tap lands within the left third of screen width.
local function isLeftTapZone(pos)
    if not pos or not pos.x then
        return false
    end
    return pos.x <= Screen:getWidth() * TAP_NAV_ZONE_RATIO
end

--- Return whether a tap position falls in the right tap-navigation zone.
---
--- @param pos table|nil Tap position `{x = number}`.
--- @return boolean is_right `true` when the tap lands within the right third of screen width.
local function isRightTapZone(pos)
    if not pos or not pos.x then
        return false
    end
    return pos.x >= Screen:getWidth() * (1 - TAP_NAV_ZONE_RATIO)
end

--- Return whether a gesture started near the left edge of the screen.
---
--- @param ges table Gesture event.
--- @return boolean is_left_edge `true` when the touch starts within the left 25% of screen width.
local function isLeftEdgeGesture(ges)
    if not ges or not ges.pos or not ges.pos.x then
        return false
    end
    local screen_w = Screen:getWidth()
    return ges.pos.x <= (screen_w * 0.25)
end

--- Handle horizontal panel navigation & left-edge vertical zoom before falling back to ImageViewer.
---
--- Swiping down on the left edge always zooms out (matching Kobo-style
--- one-handed zoom controls) and never closes the viewer -- it used to fall
--- back to `onClose()` once already at standard zoom, which meant the same
--- gesture used to zoom out could also unexpectedly exit the viewer.
---
--- @param arg any KOReader gesture argument.
--- @param ges table Gesture event with `direction`.
--- @return boolean|nil handled Whether the gesture was consumed.
function PanelViewer:onSwipe(arg, ges)
    if isLeftEdgeGesture(ges) then
        if ges.direction == "north" then
            self:onZoomIn(self.mousewheel_zoom_step or 0.2)
            return true
        elseif ges.direction == "south" then
            self:onZoomOut(self.mousewheel_zoom_step or 0.2)
            return true
        end
    end

    if self:isImagePannable() then
        return self:panBySwipe(ges)
    end

    if self.swipe_navigation ~= false and self._images_list and (ges.direction == "west" or ges.direction == "east") then
        if ges.direction == self:getNextSwipeDirection() then
            return self:onShowNextImage()
        else
            return self:onShowPrevImage()
        end
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

--- Advance to the next panel, animating a camera pan or crossing page boundary at the end.
---
--- @return boolean|nil handled Whether the image switch was handled.
function PanelViewer:onShowNextImage()
    if self._images_list_cur < self._images_list_nb then
        if self.nav_transition_mode == "smooth" then
            return self:animateSwitchToImageNum(self._images_list_cur + 1)
        end
        return ImageViewer.onShowNextImage(self)
    elseif self.boundary_callback then
        return self:onPanelBoundary("next")
    end
    return true
end

--- Return to the previous panel, animating a camera pan or crossing page boundary at the start.
---
--- @return boolean|nil handled Whether the image switch was handled.
function PanelViewer:onShowPrevImage()
    if self._images_list_cur > 1 then
        if self.nav_transition_mode == "smooth" then
            return self:animateSwitchToImageNum(self._images_list_cur - 1)
        end
        return ImageViewer.onShowPrevImage(self)
    elseif self.boundary_callback then
        return self:onPanelBoundary("previous")
    end
    return true
end

--- Dispatch KOReader's standard relative page-turn event to panel navigation.
---
--- `GotoViewRel` is what physical page-turn keys (via `ImageViewer`'s own
--- key_events when `self.image` isn't a table), Bluetooth page-turner
--- plugins (e.g. `kobo.koplugin`'s "next_page"/"prev_page" bindings), the
--- dispatcher's "Turn pages" action, and `autoturn.koplugin` all actually
--- fire. `diff` isn't guaranteed to be exactly ±1 (the dispatcher action
--- allows -100..100, and autoturn can use other step sizes), so only its
--- sign is used: any positive value advances one panel (or crosses the
--- page boundary), any negative value goes back one.
---
--- @param diff number Signed relative page delta from the `GotoViewRel` event.
--- @return boolean|nil handled Whether the event was consumed.
function PanelViewer:onGotoViewRel(diff)
    if not diff or diff == 0 then
        return true
    end
    if diff > 0 then
        return self:onShowNextImage()
    end
    return self:onShowPrevImage()
end

--- Treat mouse-wheel pan events from KOReader/SDL as image zoom in panel mode.
---
--- @param arg any KOReader gesture argument.
--- @param ges table Gesture event.
--- @return boolean handled Whether the gesture was consumed.
function PanelViewer:onPan(arg, ges)
    if ges and ges.mousewheel_direction then
        if ges.mousewheel_direction > 0 then
            self:onZoomIn(self.mousewheel_zoom_step)
        elseif ges.mousewheel_direction < 0 then
            self:onZoomOut(self.mousewheel_zoom_step)
        end
        self._panels_plus_mousewheel_zoomed = true
        return true
    end
    return ImageViewer.onPan(self, arg, ges)
end

--- Consume the synthetic mouse-wheel pan release after zooming.
---
--- @param arg any KOReader gesture argument.
--- @param ges table Gesture event.
--- @return boolean handled Whether the gesture was consumed.
function PanelViewer:onPanRelease(arg, ges)
    if ges and ges.from_mousewheel then
        self._panels_plus_mousewheel_zoomed = nil
        return true
    end
    return ImageViewer.onPanRelease(self, arg, ges)
end

--- Zoom in (pinch/spread, mousewheel, or left-edge swipe) and leave "scale to fit".
---
--- Base `ImageViewer:onZoomIn()` changes `self.scale_factor` but never touches
--- `self._scale_to_fit`, so the bottom-bar button kept reading "Original size"
--- (i.e. still offering to leave fit mode) even after the image was manually
--- zoomed past it. Any manual zoom step means we're no longer at a clean fit,
--- so flip the flag first -- `replaceButtonTable()`/`update()` inside the base
--- method then pick up the corrected label.
---
--- @param inc number|nil Zoom-in increment forwarded to the base implementation.
--- @return boolean handled Always true after processing the zoom.
function PanelViewer:onZoomIn(inc)
    self._scale_to_fit = false
    return ImageViewer.onZoomIn(self, inc)
end

--- Zoom out (pinch/spread, mousewheel, or left-edge swipe) and leave "scale to fit".
---
--- See `PanelViewer:onZoomIn()` above for why `_scale_to_fit` needs updating here too.
---
--- @param dec number|nil Zoom-out decrement forwarded to the base implementation.
--- @return boolean handled Always true after processing the zoom.
function PanelViewer:onZoomOut(dec)
    self._scale_to_fit = false
    return ImageViewer.onZoomOut(self, dec)
end

--- Convert a screen coordinate inside this zoomed viewer to document page coordinates.
---
--- @param pos table Screen position `{x = number, y = number}`.
--- @return PPPagePosition|nil page_pos Unrotated document page position `{x, y, page}`.
function PanelViewer:screenToPageTransform(pos)
    if not pos or not pos.x or not pos.y or not self.page then
        return nil
    end

    local cur_idx = self._images_list_cur or 1
    local rect = self.image_rects and self.image_rects[cur_idx]
    if not rect or not self._image_wg then
        return nil
    end

    self._image_wg:getSize()
    local bb_w = self._image_wg:getCurrentWidth()
    local bb_h = self._image_wg:getCurrentHeight()
    if not bb_w or bb_w <= 0 or not bb_h or bb_h <= 0 then
        return nil
    end

    local widget_x = self._image_wg.dimen and self._image_wg.dimen.x or 0
    local widget_y = self._image_wg.dimen and self._image_wg.dimen.y or 0
    local offset_x = self._image_wg._offset_x or 0
    local offset_y = self._image_wg._offset_y or 0

    local px = (pos.x - widget_x) + offset_x
    local py = (pos.y - widget_y) + offset_y

    local norm_x = math.max(0, math.min(1, px / bb_w))
    local norm_y = math.max(0, math.min(1, py / bb_h))

    local page_x, page_y
    if self.rotated == 90 or self.rotated == true then
        page_x = (rect.x or 0) + norm_y * (rect.w or 0)
        page_y = (rect.y or 0) + (1 - norm_x) * (rect.h or 0)
    elseif self.rotated == 180 then
        page_x = (rect.x or 0) + (1 - norm_x) * (rect.w or 0)
        page_y = (rect.y or 0) + (1 - norm_y) * (rect.h or 0)
    elseif self.rotated == 270 then
        page_x = (rect.x or 0) + (1 - norm_y) * (rect.w or 0)
        page_y = (rect.y or 0) + norm_x * (rect.h or 0)
    else
        page_x = (rect.x or 0) + norm_x * (rect.w or 0)
        page_y = (rect.y or 0) + norm_y * (rect.h or 0)
    end

    return {
        x = page_x,
        y = page_y,
        page = self.page,
    }
end

--- Convert a page-space rectangle on the current page to screen coordinates inside this zoomed viewer.
---
--- @param box table Page-space rectangle `{x, y, w, h}` or `{x0, y0, x1, y1}`.
--- @return PPRect|nil screen_rect Screen position `{x, y, w, h}` or nil if outside crop.
function PanelViewer:pageToScreenTransform(box)
    if not box or not self.page then
        return nil
    end

    local cur_idx = self._images_list_cur or 1
    local rect = self.image_rects and self.image_rects[cur_idx]
    if not rect or not self._image_wg then
        return nil
    end

    local bx = box.x or box.x0 or 0
    local by = box.y or box.y0 or 0
    local bw = box.w or ((box.x1 or bx) - bx)
    local bh = box.h or ((box.y1 or by) - by)
    if bw <= 0 or bh <= 0 then
        return nil
    end

    local rx = rect.x or 0
    local ry = rect.y or 0
    local rw = rect.w or 1
    local rh = rect.h or 1

    local ix0 = math.max(bx, rx)
    local iy0 = math.max(by, ry)
    local ix1 = math.min(bx + bw, rx + rw)
    local iy1 = math.min(by + bh, ry + rh)

    if ix1 <= ix0 or iy1 <= iy0 then
        return nil
    end

    local norm_x0 = (ix0 - rx) / rw
    local norm_y0 = (iy0 - ry) / rh
    local norm_x1 = (ix1 - rx) / rw
    local norm_y1 = (iy1 - ry) / rh

    self._image_wg:getSize()
    local bb_w = self._image_wg:getCurrentWidth()
    local bb_h = self._image_wg:getCurrentHeight()
    if not bb_w or bb_w <= 0 or not bb_h or bb_h <= 0 then
        return nil
    end

    local widget_x = self._image_wg.dimen and self._image_wg.dimen.x or 0
    local widget_y = self._image_wg.dimen and self._image_wg.dimen.y or 0
    local offset_x = self._image_wg._offset_x or 0
    local offset_y = self._image_wg._offset_y or 0

    local px0, py0, px1, py1
    if self.rotated == 90 or self.rotated == true then
        px0 = (1 - norm_y1) * bb_w
        py0 = norm_x0 * bb_h
        px1 = (1 - norm_y0) * bb_w
        py1 = norm_x1 * bb_h
    elseif self.rotated == 180 then
        px0 = (1 - norm_x1) * bb_w
        py0 = (1 - norm_y1) * bb_h
        px1 = (1 - norm_x0) * bb_w
        py1 = (1 - norm_y0) * bb_h
    elseif self.rotated == 270 then
        px0 = norm_y0 * bb_w
        py0 = (1 - norm_x1) * bb_h
        px1 = norm_y1 * bb_w
        py1 = (1 - norm_x0) * bb_h
    else
        px0 = norm_x0 * bb_w
        py0 = norm_y0 * bb_h
        px1 = norm_x1 * bb_w
        py1 = norm_y1 * bb_h
    end

    local screen_x0 = widget_x + px0 - offset_x
    local screen_y0 = widget_y + py0 - offset_y
    local screen_x1 = widget_x + px1 - offset_x
    local screen_y1 = widget_y + py1 - offset_y

    local sx = math.floor(math.min(screen_x0, screen_x1))
    local sy = math.floor(math.min(screen_y0, screen_y1))
    local sw = math.max(1, math.ceil(math.abs(screen_x1 - screen_x0)))
    local sh = math.max(1, math.ceil(math.abs(screen_y1 - screen_y0)))

    return { x = sx, y = sy, w = sw, h = sh }
end

--- Default: skip a full-fill highlight paint when a page-space box would
--- cover this much or more of the current panel crop's area. A box this
--- large relative to the visible panel is very likely a spurious/coarse
--- text-layer bounding box -- OCR on comic/manga art (stylized fonts,
--- speech bubbles, vertical text) commonly produces oversized word or line
--- boxes, whether from the document's own embedded OCR text layer (PDF) or
--- KOReader's on-the-fly OCR fallback (CBZ/CBR, which carry no text layer
--- at all) -- rather than a genuine single word. Filling a box this size
--- with the "invert" drawer would otherwise read as a big solid black
--- rectangle over the panel art.
local HIGHLIGHT_BOX_AREA_RATIO_THRESHOLD = 0.6

--- Whether a page-space highlight box looks anomalously large relative to
--- the currently displayed panel crop.
---
--- @param box table Page-space box `{x,y,w,h}` or `{x0,y0,x1,y1}`.
--- @param rect table Current panel crop rect `{x,y,w,h}`.
--- @return boolean is_anomalous
local function isAnomalousHighlightBox(box, rect)
    local bw = box.w or ((box.x1 or 0) - (box.x0 or box.x or 0))
    local bh = box.h or ((box.y1 or 0) - (box.y0 or box.y or 0))
    local rw, rh = rect.w or 0, rect.h or 0
    if bw <= 0 or bh <= 0 or rw <= 0 or rh <= 0 then
        return false
    end
    return (bw * bh) / (rw * rh) >= HIGHLIGHT_BOX_AREA_RATIO_THRESHOLD
end

--- Paint a thin border around a screen rect instead of a full fill, used
--- when `isAnomalousHighlightBox` flags the source box as spurious --
--- marks the selection's extent without obscuring the panel art beneath it.
---
--- @param bb table Blitbuffer canvas.
--- @param rect PPRect Screen rect `{x, y, w, h}`.
local function paintHighlightOutline(bb, rect)
    local t = math.max(1, math.min(2, math.floor(rect.w / 3), math.floor(rect.h / 3)))
    bb:invertRect(rect.x, rect.y, rect.w, t)
    bb:invertRect(rect.x, rect.y + rect.h - t, rect.w, t)
    bb:invertRect(rect.x, rect.y, t, rect.h)
    bb:invertRect(rect.x + rect.w - t, rect.y, t, rect.h)
end

--- Render temporary text selection highlights over the zoomed panel.
---
--- @param bb table Blitbuffer canvas.
--- @param x number Canvas X offset.
--- @param y number Canvas Y offset.
function PanelViewer:paintHighlights(bb, x, y)
    local reader_ui = self.reader_ui
    if not reader_ui or not reader_ui.view or not reader_ui.highlight then
        return
    end

    local temp_highlights = reader_ui.view.highlight and reader_ui.view.highlight.temp
    local selected_text = reader_ui.highlight and reader_ui.highlight.selected_text

    local boxes_to_draw = {}

    if temp_highlights and self.page and temp_highlights[self.page] then
        for _, box in ipairs(temp_highlights[self.page]) do
            table.insert(boxes_to_draw, box)
        end
    end

    if #boxes_to_draw == 0 and selected_text then
        if selected_text.sboxes then
            for _, box in ipairs(selected_text.sboxes) do
                table.insert(boxes_to_draw, box)
            end
        elseif selected_text.pboxes then
            for _, box in ipairs(selected_text.pboxes) do
                table.insert(boxes_to_draw, box)
            end
        end
    end

    if #boxes_to_draw == 0 then
        return
    end

    local drawer = reader_ui.view.highlight and reader_ui.view.highlight.temp_drawer or "invert"
    local cur_idx = self._images_list_cur or 1
    local crop_rect = self.image_rects and self.image_rects[cur_idx]

    for _, box in ipairs(boxes_to_draw) do
        local rect = self:pageToScreenTransform(box)
        if rect then
            if crop_rect and isAnomalousHighlightBox(box, crop_rect) then
                logger.dbg("[Panels+] anomalous highlight box, drawing outline only:",
                    "box=", box.x or box.x0, box.y or box.y0, box.w, box.h,
                    "crop=", crop_rect.x, crop_rect.y, crop_rect.w, crop_rect.h)
                paintHighlightOutline(bb, rect)
            elseif reader_ui.view.drawHighlightRect then
                pcall(reader_ui.view.drawHighlightRect, reader_ui.view, bb, 0, 0, rect, drawer)
            else
                if drawer == "invert" then
                    bb:invertRect(rect.x, rect.y, rect.w, rect.h)
                else
                    bb:darkenRect(rect.x, rect.y, rect.w, rect.h, 0.3)
                end
            end
        end
    end
end

--- ImageViewer (and everything it paints: title bar, progress bar, button
--- table, the image itself, and any letterbox padding around it) is styled
--- with hardcoded light colors and has no night-mode awareness of its own.
--- Inverting the whole frame here, at the very end of every repaint, is the
--- only place that's guaranteed to cover the actual painted pixels no matter
--- how they got there -- panel content, padding, a resized button area, or a
--- mid-pan composited transition frame -- instead of chasing every place
--- that can produce that content.
function PanelViewer:paintTo(bb, x, y)
    ImageViewer.paintTo(self, bb, x, y)
    if Screen.night_mode and self.main_frame and self.main_frame.dimen then
        local d = self.main_frame.dimen
        bb:invertRect(d.x, d.y, d.w, d.h)
    end
    self:paintHighlights(bb, x, y)
    OcrDebug.paint(self, bb, x, y)
end

--- Re-locate the word KOReader's native `highlight.onHold` just selected,
--- using a comic-lettering-aware box finder, and re-point the selection at
--- the tighter box before OCR/dictionary lookup runs.
---
--- KOReader's own word box comes from a generic gap-detection pass tuned for
--- justified prose (see `src._wordfinder`); it routinely mis-splits or
--- merges words in stylized comic lettering. This only touches paging
--- documents that OCR on the fly in the first place -- reflow mode and
--- documents whose page-optimization pass is running are left untouched,
--- matching `PageBitmap.getBlockReason`'s guard for the same reason.
---
--- @param highlight table KOReader `ReaderHighlight` module instance.
--- @param page_pos PPPagePosition Tap position in unrotated page coordinates.
function PanelViewer:_refineWordSelection(highlight, page_pos)
    local reader_ui = self.reader_ui
    local document = reader_ui and reader_ui.document
    if not document or not page_pos or not page_pos.page then
        return
    end
    if PageBitmap.getBlockReason(document) then
        return
    end

    local ok, box, native = pcall(WordFinder.findWordBox, document, page_pos.page, page_pos.x, page_pos.y)
    if not ok or not box then
        if self.ocr_debug_mode then
            local ok_native, native_dims = pcall(document.getNativePageDimensions, document, page_pos.page)
            OcrDebug.captureFailure(self, {
                document = document.file,
                page = page_pos.page,
                tap = { x = page_pos.x, y = page_pos.y },
                native = ok_native and native_dims,
                reason = "no_box",
            })
        end
        return
    end

    local ok2, word = pcall(WordFinder.readWord, document, page_pos.page, box, native)
    if not ok2 or not word then
        if self.ocr_debug_mode then
            OcrDebug.captureFailure(self, {
                document = document.file,
                page = page_pos.page,
                tap = { x = page_pos.x, y = page_pos.y },
                box = { x = box.x, y = box.y, w = box.w, h = box.h },
                native = native and { w = native.w, h = native.h },
                reason = "no_word",
                diagnostics = WordFinder.last_diagnostics,
            })
        end
        return
    end

    local selected_text = highlight.selected_text
    if not selected_text then
        return
    end

    local orig_word = selected_text.text or ""
    selected_text.text = word
    selected_text.sboxes = { box }
    selected_text.pboxes = { box }

    -- Re-point ReaderView's temporary highlight at the refined box too.
    -- `ReaderHighlight:onHold` stored a *reference* to the selection's
    -- previous `sboxes` table in `view.highlight.temp[page]`, and that table
    -- -- not `selected_text.sboxes` -- is what `paintHighlights` draws.
    -- Replacing `sboxes` above therefore leaves the painted box behind on
    -- KOReader's original one, whose y/h come from the whole *text line*
    -- rather than the word (`KoptInterface:getWordFromBoxes` takes them from
    -- the line box), so the underline lands off the word it just looked up.
    local view_highlight = reader_ui.view and reader_ui.view.highlight
    if view_highlight and view_highlight.temp and view_highlight.temp[page_pos.page] then
        view_highlight.temp[page_pos.page] = selected_text.sboxes
    end

    if self.ocr_debug_mode then
        OcrDebug.capture(self, {
            document = document.file,
            page = page_pos.page,
            tap = { x = page_pos.x, y = page_pos.y },
            box = { x = box.x, y = box.y, w = box.w, h = box.h },
            native = native and { w = native.w, h = native.h },
            koreader_word = orig_word,
            ocr_word = word,
            diagnostics = WordFinder.last_diagnostics,
        })
    end

    if not Timing.enabled then
        return
    end

    WordFinder.logDiagnostic(string.format("Refined selection: '%s' -> '%s'", orig_word, tostring(word)), {
        box = string.format("(x=%.1f,y=%.1f,w=%.1f,h=%.1f)", box.x, box.y, box.w, box.h)
    })

    local ok_notif, Notification = pcall(require, "ui/widget/notification")
    if ok_notif and Notification and Notification.new then
        pcall(function()
            UIManager:show(Notification:new{
                text = string.format("[WordFinder] '%s' (%dx%d)", word, math.floor(box.w), math.floor(box.h)),
                timeout = 2,
            })
        end)
    end
end

--- Delegate touch and hold gestures to KOReader's native text selection / dictionary.
---
--- @param arg any Gesture argument.
--- @param ges table Gesture event with `pos`.
--- @return boolean handled Whether text selection or dictionary lookup consumed the event.
function PanelViewer:onHold(arg, ges)
    if self._ocr_debug_rect then
        -- Rectangle marking is tap-tap (see `_ocrdebug.lua`), not hold-drag;
        -- swallow hold gestures so they cannot start a text selection
        -- underneath while a corner tap is still pending.
        return true
    end

    if self.hold_text_selection == false then
        return ImageViewer.onHold and ImageViewer.onHold(self, arg, ges)
    end

    local reader_ui = self.reader_ui
    local highlight = reader_ui and reader_ui.highlight
    if not highlight or not reader_ui.view then
        return ImageViewer.onHold and ImageViewer.onHold(self, arg, ges)
    end

    local page_pos = self:screenToPageTransform(ges and ges.pos)
    if not page_pos then
        return true
    end

    local orig_screenToPage = reader_ui.view.screenToPageTransform
    local orig_panel_zoom_enabled = highlight.panel_zoom_enabled

    reader_ui.view.screenToPageTransform = function(view, pos)
        return page_pos
    end
    highlight.panel_zoom_enabled = false

    local ok, handled = pcall(highlight.onHold, highlight, arg, ges)

    reader_ui.view.screenToPageTransform = orig_screenToPage
    highlight.panel_zoom_enabled = orig_panel_zoom_enabled

    if ok and handled then
        self._panels_plus_text_holding = true
        if highlight.is_word_selection then
            self:_refineWordSelection(highlight, page_pos)
        end
        UIManager:setDirty(self, "ui")
        return true
    end

    return ImageViewer.onHold and ImageViewer.onHold(self, arg, ges)
end

--- Forward touch drag during text selection inside a zoomed panel.
---
--- @param arg any Gesture argument.
--- @param ges table Gesture event.
--- @return boolean handled Whether the drag was handled.
function PanelViewer:onHoldPan(arg, ges)
    if self._ocr_debug_rect then
        return true
    end

    if not self._panels_plus_text_holding then
        return ImageViewer.onHoldPan and ImageViewer.onHoldPan(self, arg, ges)
    end

    local reader_ui = self.reader_ui
    local highlight = reader_ui and reader_ui.highlight
    if not highlight or not reader_ui.view or type(highlight.onHoldPan) ~= "function" then
        return true
    end

    local page_pos = self:screenToPageTransform(ges and ges.pos)
    if not page_pos then
        return true
    end

    local orig_screenToPage = reader_ui.view.screenToPageTransform
    reader_ui.view.screenToPageTransform = function(view, pos)
        return page_pos
    end

    pcall(highlight.onHoldPan, highlight, arg, ges)

    reader_ui.view.screenToPageTransform = orig_screenToPage
    UIManager:setDirty(self, "ui")
    return true
end

--- Forward touch release after hold to complete text selection or dictionary lookup.
---
--- @param arg any Gesture argument.
--- @param ges table Gesture event.
--- @return boolean handled Whether the release was handled.
function PanelViewer:onHoldRelease(arg, ges)
    if self._ocr_debug_rect then
        return true
    end

    if not self._panels_plus_text_holding then
        return ImageViewer.onHoldRelease and ImageViewer.onHoldRelease(self, arg, ges)
    end

    self._panels_plus_text_holding = nil
    local reader_ui = self.reader_ui
    local highlight = reader_ui and reader_ui.highlight
    if self.ocr_debug_mode and self._ocr_debug_pending then
        OcrDebug.hookDictClose(self, reader_ui)
    end
    if highlight and type(highlight.onHoldRelease) == "function" then
        pcall(highlight.onHoldRelease, highlight, arg, ges)
    end
    UIManager:setDirty(self, "ui")
    return true
end

--- Forward touch release after dragging text selection inside a zoomed panel.
---
--- @param arg any Gesture argument.
--- @param ges table Gesture event.
--- @return boolean handled Whether the release was handled.
function PanelViewer:onHoldPanRelease(arg, ges)
    return self:onHoldRelease(arg, ges)
end

--- Toggle controls on inside taps, navigate on edge taps when enabled, and
--- close on taps outside the frame.
---
--- Edge taps only navigate while the image is at standard zoom: once zoomed
--- in (pannable), the same tap zones fall through to the default
--- toggle-controls behavior instead, matching how edge swipes hand off to
--- panning in `onSwipe`.
---
--- @param _ any Unused KOReader tap argument.
--- @param ges table Gesture event with a `pos` geometry object.
--- @return boolean handled Always true after processing a tap.
function PanelViewer:onTap(_, ges)
    if self._ocr_debug_rect then
        return OcrDebug.handleTap(self, ges)
    end

    local frame_dimen = self.main_frame and self.main_frame.dimen
    if frame_dimen and ges.pos:notIntersectWith(frame_dimen) then
        self:onClose()
        return true
    end

    if self.tap_navigation and not self:isImagePannable() then
        local next_side = self:getNextTapSide()
        if isLeftTapZone(ges.pos) then
            if next_side == "left" then
                return self:onShowNextImage()
            end
            return self:onShowPrevImage()
        elseif isRightTapZone(ges.pos) then
            if next_side == "right" then
                return self:onShowNextImage()
            end
            return self:onShowPrevImage()
        end
    end

    self.buttons_visible = not self.buttons_visible
    self:update()
    return true
end

--- Schedule the initial full repaint without assuming layout already happened.
function PanelViewer:onShow()
    self._panels_plus_closed = nil
    self.dithered = true
    UIManager:setDirty(self, function()
        if not self:isOpen() or not self.main_frame or not self.main_frame.dimen then
            return nil
        end
        return "full", self.main_frame.dimen, true
    end)
    self:requestPanelPrerender()
    return true
end

--- Redraw the viewer, optionally suppressing the progress bar.
function PanelViewer:update()
    local result
    if not self._hide_progress_for_screenshot and self.progress_bar_visible ~= false then
        result = self:withGuardedImageViewerRefresh(function()
            return ImageViewer.update(self)
        end)
    else
        local images_list_nb = self._images_list_nb
        self._images_list_nb = 1
        local ok, err = pcall(function()
            result = self:withGuardedImageViewerRefresh(function()
                return ImageViewer.update(self)
            end)
        end)
        self._images_list_nb = images_list_nb
        if not ok then
            error(err)
        end
    end

    -- Base ImageViewer:update() always relabels the "rotate" button itself
    -- (self.rotated and _("No rotation") or _("Rotate")), overwriting the
    -- static text replaceButtonTable() gave it -- that toggle-style label
    -- made sense for the base class's tap-to-toggle button, but ours opens
    -- the rotation picker instead, so its label should never change.
    if self.buttons_visible and self.button_table then
        local rotate_btn = self.button_table:getButtonById("rotate")
        if rotate_btn then
            rotate_btn:setText(_("Rotate"), rotate_btn.width)
        end
    end

    return result
end

--- Save a screenshot of the current panel view.
---
--- Temporarily hides controls and title chrome so screenshots contain only the
--- rendered panel, then restores the previous viewer state through KOReader's
--- screenshot callback.
---
--- @return boolean handled Always true for button callback dispatch.
function PanelViewer:onSaveImageView()
    self._hide_progress_for_screenshot = true

    local restore_settings_func
    if self.with_title_bar or self.buttons_visible or not self.fullscreen then
        local with_title_bar = self.with_title_bar
        local buttons_visible = self.buttons_visible
        local fullscreen = self.fullscreen
        restore_settings_func = function()
            self.with_title_bar = with_title_bar
            self.buttons_visible = buttons_visible
            self.fullscreen = fullscreen
            self._hide_progress_for_screenshot = false
            self:update()
        end
        self.with_title_bar = false
        self.buttons_visible = false
        self.fullscreen = true
        self:update()
        UIManager:forceRePaint()
    else
        restore_settings_func = function()
            self._hide_progress_for_screenshot = false
            self:update()
        end
        self:update()
        UIManager:forceRePaint()
    end

    local screenshot_dir = Screenshoter:getScreenshotDir()
    local screenshot_name = os.date(screenshot_dir .. "/ImageViewer_%Y-%m-%d_%H%M%S.png")
    UIManager:sendEvent(Event:new("Screenshot", screenshot_name, restore_settings_func))
    return true
end

--- Initialize ImageViewer state, controls, and first render.
function PanelViewer:init()
    ImageViewer.init(self)
    if self._images_list then
        self.rotated = self._images_list.rotated
    end
    self:replaceButtonTable()
    self:update()
end

--- Close ImageViewer resources while guarding its final dirty-region callback.
function PanelViewer:onCloseWidget()
    self._panels_plus_closed = true
    self._panels_plus_closing = true
    local active_image = self.image
    local ok, err = pcall(function()
        return self:withGuardedImageViewerRefresh(function()
            return ImageViewer.onCloseWidget(self)
        end)
    end)
    self._panels_plus_closing = nil
    if self.image_disposable and active_image and active_image.free then
        active_image:free()
    end
    self.image = nil
    self._images_list = nil
    self.image_rects = nil
    self.panels = nil
    self.panel_is_full_page = nil
    pcall(WordFinder.cleanup)
    collectgarbage("collect")
    if not ok then
        error(err)
    end
end

--- Free a superseded panel image after ImageViewer has rebuilt its widget tree.
---
--- `image:free()` releases the blitbuffer's C memory immediately, so there is
--- deliberately no `collectgarbage()` here: a full collection on every panel
--- switch stalls the UI for far longer than it reclaims.
---
--- @param image any Owned panel blitbuffer.
function PanelViewer:releasePreviousPanelImage(image)
    if not image or not image.free then
        return
    end

    UIManager:tickAfterNext(function()
        if image ~= self.image then
            image:free()
        end
    end)
end

--- Ask the owner to warm the following panel's render while the device is idle.
function PanelViewer:requestPanelPrerender()
    if self.panel_prerender_callback then
        self.panel_prerender_callback(self, self._images_list_cur or 1)
    end
end

--- Switch panel images after rendering the destination panel.
---
--- KOReader's base ImageViewer frees the current image before `update()`
--- removes the old ImageWidget. That can segfault with drawPagePart() buffers
--- on Kindle/SDL. This keeps the old buffer alive until the new widget is in
--- place, then releases it on the next UI tick.
---
--- @param image_num integer 1-based image index.
function PanelViewer:switchToImageNum(image_num)
    if image_num == self._images_list_cur then
        return
    end

    local old_image = self.image
    self.image = self._images_list[image_num]
    if type(self.image) == "function" then
        self.image = self.image()
        self.rotated = self._images_list.rotated
    end
    self._images_list_cur = image_num
    if not self.images_keep_pan_and_zoom then
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        self.scale_factor = self._images_orig_scale_factor
    end
    self:update()
    if self.image_disposable then
        self:releasePreviousPanelImage(old_image)
    end
    self:requestPanelPrerender()
end

--- Animate a camera pan from the panel currently shown to `target`, then hand off
--- to its crisp render.
---
--- Builds a synthetic canvas centered exactly on `target`'s own center, at the
--- zoom `target` itself would use if rendered alone -- so `target`'s final,
--- centered position on this canvas is pixel-identical to what the trailing
--- `switchToImageNum()` handoff will show, and the swap goes unnoticed. The
--- canvas is symmetric around that center by construction (equal half-extents
--- on every side), sized to whichever is larger: the half-screen (so `target`'s
--- own letterboxing, if any, matches its normal render) or the actual distance to
--- `rect_a`'s farthest edge (so the pan has real ground to cross). Real page
--- pixels (the union of both panels) are pasted into this canvas at their true
--- position; anything else -- including space beyond the actual page edges, when
--- centering `target` requires it -- is left blank, exactly like the blank
--- letterbox margins a normal single-panel view already shows. Falls back to an
--- instant swap on any failure, a missing rect pair, or when the canvas would be
--- an unreasonably large one-shot render.
---
--- @param target integer 1-based image index to end the transition on.
function PanelViewer:animateSwitchToImageNum(target)
    local cur = self._images_list_cur
    if target == cur or self._panels_plus_transition_active then
        return
    end
    local rect_a = self.image_rects and self.image_rects[cur]
    local rect_b = self.image_rects and self.image_rects[target]
    if not rect_a or not rect_b then
        return self:switchToImageNum(target)
    end

    Timing.log("animateSwitchToImageNum: panel %d -> %d (crop_mode=%s, duration=%.2fs)", cur, target, tostring(self.crop_mode), self.nav_transition_duration or 0)
    Timing.memory("smooth_transition")

    local union = Geometry.rectUnion(rect_a, rect_b)
    local target_zoom = canvasFitZoom(rect_b)

    local bx, by
    if self.crop_mode == "none" and self.panels and self.panels[target] then
        bx, by = Geometry.rectCenter(self.panels[target])
    else
        bx, by = Geometry.rectCenter(rect_b)
    end

    local ax, ay
    if self.crop_mode == "none" and self.panels and self.panels[cur] then
        ax, ay = Geometry.rectCenter(self.panels[cur])
    else
        ax, ay = Geometry.rectCenter(rect_a)
    end

    local half_w = math.max(
        Screen:getWidth() / (2 * target_zoom) + math.abs(ax - bx),
        bx - union.x,
        union.x + union.w - bx
    )
    local half_h = math.max(
        Screen:getHeight() / (2 * target_zoom) + math.abs(ay - by),
        by - union.y,
        union.y + union.h - by
    )

    local screen_area = Screen:getWidth() * Screen:getHeight()
    if (2 * half_w) * (2 * half_h) * target_zoom * target_zoom > screen_area * NAV_TRANSITION_MAX_AREA_MULTIPLIER then
        Timing.log("animateSwitchToImageNum: canvas area cap exceeded for panel %d -> %d, falling back to instant swap", cur, target)
        return self:switchToImageNum(target)
    end
    if not Memory.hasHeadroom(NAV_TRANSITION_MIN_FREE_BYTES) then
        Timing.log("animateSwitchToImageNum: low memory, falling back to instant swap for panel %d -> %d", cur, target)
        return self:switchToImageNum(target)
    end

    local ok, content_image = pcall(function()
        return self.reader_ui.document:drawPagePart(self.page, union, 0)
    end)
    if not ok or not content_image then
        logger.warn("[Panels+] smooth transition page draw failed, falling back to instant swap:", tostring(content_image))
        return self:switchToImageNum(target)
    end

    local zoom_union = canvasFitZoom(union)
    local scale = target_zoom / zoom_union -- applied once, below, via self.scale_factor

    local canvas_w = math.max(1, math.ceil(2 * half_w * zoom_union))
    local canvas_h = math.max(1, math.ceil(2 * half_h * zoom_union))
    local ok_canvas, canvas_image = pcall(function()
        local canvas = Blitbuffer.new(canvas_w, canvas_h, content_image:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        -- Clamp against float-rounding drift between this module's zoom math and
        -- drawPagePart()'s own internal rect scaling, so the blit never reads or
        -- writes a row/column past either buffer's actual allocated bounds.
        local paste_x = math.max(0, math.floor((union.x - (bx - half_w)) * zoom_union))
        local paste_y = math.max(0, math.floor((union.y - (by - half_h)) * zoom_union))
        local blit_w = math.min(content_image:getWidth(), canvas_w - paste_x)
        local blit_h = math.min(content_image:getHeight(), canvas_h - paste_y)
        if blit_w > 0 and blit_h > 0 then
            canvas:blitFrom(content_image, paste_x, paste_y, 0, 0, blit_w, blit_h)
        end
        return canvas
    end)
    if not ok_canvas or not canvas_image then
        return self:switchToImageNum(target)
    end
    -- content_image itself is a DocCache-owned tile (never copied out), so it is
    -- never freed here -- only its pixels were read into the newly-owned canvas.

    local ratio_ax, ratio_ay = (ax - (bx - half_w)) / (2 * half_w), (ay - (by - half_h)) / (2 * half_h)
    local ratio_bx, ratio_by = 0.5, 0.5 -- target's center sits at the canvas center by construction

    self._panels_plus_transition_active = true
    local old_image = self.image
    self.image = canvas_image
    self._center_x_ratio, self._center_y_ratio = ratio_ax, ratio_ay
    self.scale_factor = scale
    self:update()
    if self.image_disposable then
        self:releasePreviousPanelImage(old_image)
    end

    self:runNavPanAnimation(ratio_bx, ratio_by, function()
        self:switchToImageNum(target)
    end)
end

--- Run the smooth-navigation pan from the widget's current offset to a target
--- ratio, then invoke `on_complete`.
---
--- Assumes the caller has already set `self.image`/`self._center_x_ratio`/
--- `self._center_y_ratio`/`self.scale_factor` to the *starting* frame and
--- called `self:update()`. Each step re-targets an absolute offset for that
--- point in the animation, computed from the widget's *actual* current offset
--- rather than a fixed per-step delta. `panBy()` floors its result every call,
--- so fixed deltas silently lose a fraction of a pixel each step; over several
--- steps that drifts away from the target, and the final hand-off then has to
--- snap the last bit of distance in one jump. Recomputing the delta from the
--- real current offset each time folds any prior drift into the next step
--- instead of letting it accumulate, and the last step targets the exact final
--- offset, so the pan always lands precisely on the target ratio.
---
--- @param target_ratio_x number Final `center_x_ratio` to land on.
--- @param target_ratio_y number Final `center_y_ratio` to land on.
--- @param on_complete fun() Called on the last step, instead of a hardcoded handoff.
function PanelViewer:runNavPanAnimation(target_ratio_x, target_ratio_y, on_complete)
    self._image_wg:getSize() -- primes _render() so getCurrentWidth/Height are valid
    local bb_w, bb_h = self._image_wg:getCurrentWidth(), self._image_wg:getCurrentHeight()
    local viewport_w, viewport_h = self._image_wg.width, self._image_wg.height
    local start_offset_x, start_offset_y = self._image_wg._offset_x, self._image_wg._offset_y
    local target_offset_x = math.floor(target_ratio_x * bb_w - viewport_w / 2)
    local target_offset_y = math.floor(target_ratio_y * bb_h - viewport_h / 2)
    local steps = self.nav_transition_frames
    if not steps or steps <= 0 then
        steps = NAV_TRANSITION_STEPS_DEFAULT
    end
    local step_delay = (self.nav_transition_duration or 0.4) / steps

    local step_n = 0
    local walkStep
    walkStep = function()
        if not self._panels_plus_transition_active or self._panels_plus_closed or not self:isOpen() then
            self._panels_plus_transition_active = nil
            return
        end
        step_n = step_n + 1
        local progress = step_n / steps
        local desired_x, desired_y = target_offset_x, target_offset_y
        if step_n < steps then
            desired_x = start_offset_x + (target_offset_x - start_offset_x) * progress
            desired_y = start_offset_y + (target_offset_y - start_offset_y) * progress
        end
        self:panBy(desired_x - self._image_wg._offset_x, desired_y - self._image_wg._offset_y)
        if step_n < steps then
            UIManager:scheduleIn(step_delay, walkStep)
        else
            self._panels_plus_transition_active = nil
            on_complete()
        end
    end
    UIManager:scheduleIn(step_delay, walkStep)
end

--- Dispatch a first/last-panel boundary crossing, animating it when smooth
--- navigation and cross-page transitions are both enabled.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @return boolean|nil handled Whether the crossing was handled.
function PanelViewer:onPanelBoundary(direction)
    if self.nav_transition_mode == "smooth" and self.nav_transition_cross_page then
        return self:animateBoundaryTransition(direction)
    end
    return self.boundary_callback and self.boundary_callback(direction, self)
end

--- Animate a camera pan across a page boundary when the adjacent page's
--- panels are already cached; otherwise, or on any failure at any stage,
--- falls straight back to the classic instant boundary crossing.
---
--- Renders the current page's edge panel and the adjacent page's landing
--- panel independently (there is no shared coordinate space across pages),
--- rescales the current-page slice to the landing panel's own zoom (a single
--- one-shot rescale, not per-frame), and composites both into one canvas
--- side-by-side in the swipe direction -- continuing the pan and letting the
--- reveal read as one continuous strip rather than a distinct "page turn".
--- Both slices are centered vertically within a shared canvas height, so the
--- resulting pan is purely horizontal by construction. The actual page turn
--- (GotoPage, closing this viewer, opening the adjacent one) only happens
--- after the pan completes, via `nav_boundary_commit_callback`.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @return boolean|nil handled Whether the crossing was handled (always true
---   once a resolution exists, since failure paths fall back to the classic
---   callback which itself always handles the crossing).
function PanelViewer:animateBoundaryTransition(direction)
    if self._panels_plus_transition_active then
        return true -- swallow a re-entrant swipe while a pan is already in flight
    end
    if not self.nav_boundary_peek_callback then
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    local resolved = self.nav_boundary_peek_callback(direction, self)
    if not resolved then
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    local rect_a = self.image_rects and self.image_rects[self._images_list_cur]
    local rect_b = resolved.target_rect
    if not rect_a or not rect_b then
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    Timing.log("animateBoundaryTransition: direction=%s target_page=%s (crop_mode=%s)", direction, resolved and tostring(resolved.next_page) or "none", tostring(self.crop_mode))
    Timing.memory("smooth_boundary_transition")

    local target_zoom = canvasFitZoom(rect_b)

    local ok_a, tile_a, rotated_a = pcall(function()
        if self.crop_mode == "none" and self._images_list and self._images_list[self._images_list_cur] then
            local img = self._images_list[self._images_list_cur]
            if type(img) == "function" then return img() end
            return img
        end
        return self.reader_ui.document:drawPagePart(self.page, rect_a, 0)
    end)
    if not ok_a or not tile_a then
        logger.warn("[Panels+] boundary transition tile A render failed, falling back:", tostring(tile_a))
        return self.boundary_callback and self.boundary_callback(direction, self)
    end
    local ok_b, tile_b, rotated_b = pcall(function()
        if self.crop_mode == "none" and resolved.next_images and resolved.next_images[resolved.start_idx] then
            local img = resolved.next_images[resolved.start_idx]
            if type(img) == "function" then return img() end
            return img
        end
        return self.reader_ui.document:drawPagePart(resolved.next_page, rect_b, 0)
    end)
    if not ok_b or not tile_b then
        logger.warn("[Panels+] boundary transition tile B render failed, falling back:", tostring(tile_b))
        return self.boundary_callback and self.boundary_callback(direction, self)
    end
    if (rotated_a and true or false) ~= (rotated_b and true or false) then
        -- Mismatched auto-rotation between the two pages' slices can't be
        -- composited safely -- rare (differing panel aspect ratios right at
        -- the boundary); not worth reconciling for this iteration.
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    -- Bring page A's slice to the SAME zoom page B's slice already has
    -- (drawPagePart(rect_b) is bare, so tile_b is already at target_zoom).
    -- This is a single one-shot rescale, not a per-frame cost.
    local zoom_a = canvasFitZoom(rect_a)
    local scale_a = target_zoom / zoom_a
    local ok_scale, tile_a_scaled = pcall(function()
        if scale_a == 1 then
            return tile_a
        end
        local new_w = math.max(1, math.floor(tile_a:getWidth() * scale_a + 0.5))
        local new_h = math.max(1, math.floor(tile_a:getHeight() * scale_a + 0.5))
        return RenderImage:scaleBlitBuffer(tile_a, new_w, new_h, false)
    end)
    if not ok_scale or not tile_a_scaled then
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    -- Deliberately independent of `getNextSwipeDirection()`/`invert_swipe`: this
    -- is about which screen-side pages enter from, tied purely to manga (right
    -- to left) vs comic (left to right) reading order, not the swipe-gesture
    -- preference.
    local manga_next_is_west = self.reading_mode ~= "comic"
    local travel_west = (direction == "next") == manga_next_is_west

    local viewport_w, viewport_h = Screen:getWidth(), Screen:getHeight()
    local half_w_a = math.max(viewport_w / 2, tile_a_scaled:getWidth() / 2)
    local half_h_a = math.max(viewport_h / 2, tile_a_scaled:getHeight() / 2)
    local half_w_b = math.max(viewport_w / 2, tile_b:getWidth() / 2)
    local half_h_b = math.max(viewport_h / 2, tile_b:getHeight() / 2)

    local canvas_w = math.max(1, math.ceil(2 * half_w_a + 2 * half_w_b))
    local canvas_h = math.max(1, math.ceil(math.max(2 * half_h_a, 2 * half_h_b)))

    local screen_area = viewport_w * viewport_h
    if canvas_w * canvas_h > screen_area * NAV_TRANSITION_MAX_AREA_MULTIPLIER
        or not Memory.hasHeadroom(NAV_TRANSITION_MIN_FREE_BYTES) then
        if tile_a_scaled ~= tile_a and tile_a_scaled.free then
            tile_a_scaled:free()
        end
        if self.crop_mode == "none" then
            if tile_a and tile_a.free then
                tile_a:free()
            end
            if tile_b and tile_b.free then
                tile_b:free()
            end
        end
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    local a_left = travel_west and (2 * half_w_b) or 0
    local b_left = travel_west and 0 or (2 * half_w_a)

    local ok_canvas, canvas_image = pcall(function()
        local canvas = Blitbuffer.new(canvas_w, canvas_h, tile_b:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        local a_x = math.max(0, math.floor(a_left + half_w_a - tile_a_scaled:getWidth() / 2))
        local a_y = math.max(0, math.floor(canvas_h / 2 - tile_a_scaled:getHeight() / 2))
        local a_w = math.min(tile_a_scaled:getWidth(), canvas_w - a_x)
        local a_h = math.min(tile_a_scaled:getHeight(), canvas_h - a_y)
        if a_w > 0 and a_h > 0 then
            canvas:blitFrom(tile_a_scaled, a_x, a_y, 0, 0, a_w, a_h)
        end
        local b_x = math.max(0, math.floor(b_left + half_w_b - tile_b:getWidth() / 2))
        local b_y = math.max(0, math.floor(canvas_h / 2 - tile_b:getHeight() / 2))
        local b_w = math.min(tile_b:getWidth(), canvas_w - b_x)
        local b_h = math.min(tile_b:getHeight(), canvas_h - b_y)
        if b_w > 0 and b_h > 0 then
            canvas:blitFrom(tile_b, b_x, b_y, 0, 0, b_w, b_h)
        end
        return canvas
    end)
    if tile_a_scaled ~= tile_a and tile_a_scaled.free then
        tile_a_scaled:free() -- pixels already copied into canvas_image
    end
    if self.crop_mode == "none" then
        if tile_a and tile_a.free then
            tile_a:free()
        end
        if tile_b and tile_b.free then
            tile_b:free()
        end
    end
    if not ok_canvas or not canvas_image then
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    local ratio_ax = (a_left + half_w_a) / canvas_w
    local ratio_bx = (b_left + half_w_b) / canvas_w
    local ratio_ay, ratio_by = 0.5, 0.5 -- each slice is centered vertically in the shared canvas_h

    self._panels_plus_transition_active = true
    local old_image = self.image
    self.image = canvas_image
    self._center_x_ratio, self._center_y_ratio = ratio_ax, ratio_ay
    self.scale_factor = 1 -- both slices already share target_zoom; no further scale needed
    self:update()
    if self.image_disposable then
        self:releasePreviousPanelImage(old_image)
    end

    self:runNavPanAnimation(ratio_bx, ratio_by, function()
        if self.nav_boundary_commit_callback then
            self.nav_boundary_commit_callback(self, direction, resolved)
        end
    end)
    return true
end

--- Return the button label for the crop mode currently in use.
---
--- Loose and margin modes are hinted as configurable since long-pressing the
--- button opens a slider for them; strict crop has nothing to configure.
---
--- @return string text Localized crop-mode label.
function PanelViewer:getCropModeText()
    if self.crop_mode == "loose" then
        return _("Loose crop") .. " " .. _("(Long press config)")
    elseif self.crop_mode == "margin" then
        return _("With margin") .. " " .. _("(Long press config)")
    elseif self.crop_mode == "none" then
        return _("No crop")
    end
    return _("Strict crop")
end

--- Return the button label for the panel navigation transition mode in use.
---
--- @return string text Localized navigation-mode label.
function PanelViewer:getNavTransitionText()
    if self.nav_transition_mode == "smooth" then
        return _("Nav. Smooth") .. " " .. _("(Long Press)")
    end
    return _("Nav. Classic")
end

--- Return whether the panel currently shown spans nearly the whole page.
---
--- @return boolean full_page `true` when the shown panel is a full-page/splash panel.
function PanelViewer:isCurrentPanelFullPage()
    local flags = self.panel_is_full_page
    if not flags then
        return false
    end
    return flags[self._images_list_cur or 1] == true
end

--- Return the width/height multiplier "margin" crop mode should render at.
---
--- Full-page panels are excluded: shrinking a splash page to fake a margin
--- would waste most of the screen for an effect the reader didn't ask for.
---
--- @return number|nil factor Multiplier in (0, 1), or nil when no shrink applies.
function PanelViewer:getMarginShrinkFactor()
    if self.crop_mode ~= "margin" then
        return nil
    end
    if self:isCurrentPanelFullPage() then
        return nil
    end
    local ratio = self.margin_ratio or 0.12
    if ratio <= 0 then
        return nil
    end
    return 1 - math.min(0.9, ratio)
end

--- Shrink the box ImageViewer renders the panel into, for "margin" crop mode.
---
--- The base implementation sizes both the ImageWidget and the CenterContainer
--- that centers it from `self.width`/`self.img_container_h`. Temporarily
--- shrinking those before delegating, then restoring the container's `dimen`
--- to the full area afterward, keeps the centering but renders a smaller
--- image inside it -- a cheap zoom-out that reads as breathing room around
--- the panel without touching the actual crop rectangle.
function PanelViewer:_new_image_wg()
    local factor = self:getMarginShrinkFactor()
    if not factor then
        ImageViewer._new_image_wg(self)
    else
        local orig_width, orig_container_h = self.width, self.img_container_h
        self.width = orig_width * factor
        self.img_container_h = orig_container_h * factor
        ImageViewer._new_image_wg(self)
        self.width = orig_width
        self.img_container_h = orig_container_h
        self.image_container.dimen.w = orig_width
        self.image_container.dimen.h = orig_container_h
    end

    -- Base ImageViewer only ever treats `self.rotated` as a boolean, picking
    -- 90 or 270 itself via a screen-orientation heuristic and never producing
    -- 180. When it holds a literal angle instead (set by the rotation
    -- picker's plugin-only rotate; see onSetImageRotation below), force the
    -- exact angle onto the ImageWidget it already built -- rotation_angle is
    -- only read lazily on first render, so this still lands before paint.
    if type(self.rotated) == "number" then
        self._image_wg.rotation_angle = self.rotated
    end
end

--- Show a slider dialog to adjust how much "margin" crop mode zooms out.
---
--- Applying a value also switches crop mode to "margin" so the change is
--- visible immediately, since tuning a value you can't see would be useless.
---
--- @return boolean handled Always true for button hold-callback dispatch.
function PanelViewer:onAdjustMarginRatio()
    local SpinWidget = require("ui/widget/spinwidget")
    local viewer = self
    UIManager:show(SpinWidget:new{
        title_text = _("Panel margin"),
        info_text = _("Zooms panels out a little to leave breathing room around them. Has no effect on full-page panels."),
        value = math.floor((self.margin_ratio or 0.12) * 100 + 0.5),
        value_min = 0,
        value_max = 40,
        value_step = 1,
        value_hold_step = 5,
        unit = "%",
        default_value = 12,
        callback = function(spin)
            local ratio = spin.value / 100
            if viewer.margin_ratio_callback then
                viewer.margin_ratio_callback(viewer, ratio, true)
            else
                viewer.margin_ratio = ratio
                viewer.crop_mode = "margin"
                viewer:replaceButtonTable()
                viewer:update()
            end
        end,
    })
    return true
end

--- Show a slider dialog to adjust how much extra page area "loose" crop reveals.
---
--- Applying a value also switches crop mode to "loose" so the change is
--- visible immediately, since tuning a value you can't see would be useless.
---
--- @return boolean handled Always true for button hold-callback dispatch.
function PanelViewer:onAdjustBleedRatio()
    local SpinWidget = require("ui/widget/spinwidget")
    local viewer = self
    UIManager:show(SpinWidget:new{
        title_text = _("Loose crop bleed"),
        info_text = _("How much page area outside each panel's edges to reveal."),
        value = math.floor((self.bleed_ratio or 0.08) * 100 + 0.5),
        value_min = 0,
        value_max = 100,
        value_step = 1,
        value_hold_step = 5,
        unit = "%",
        default_value = 8,
        callback = function(spin)
            local ratio = spin.value / 100
            if viewer.bleed_ratio_callback then
                viewer.bleed_ratio_callback(viewer, ratio, true)
            else
                viewer.bleed_ratio = ratio
                viewer.crop_mode = "loose"
                viewer:replaceButtonTable()
                viewer:update()
            end
        end,
    })
    return true
end

--- Show a slider dialog to adjust how long the smooth-navigation camera pan takes.
---
--- @return boolean handled Always true for button hold-callback dispatch.
function PanelViewer:onAdjustNavTransitionDuration()
    local SpinWidget = require("ui/widget/spinwidget")
    local viewer = self
    UIManager:show(SpinWidget:new{
        title_text = _("Smooth navigation duration"),
        info_text = _("How long the camera pan between panels takes."),
        value = math.floor((self.nav_transition_duration or 0.4) * 1000 + 0.5),
        value_min = 150,
        value_max = 900,
        value_step = 50,
        value_hold_step = 100,
        unit = "ms",
        default_value = 400,
        callback = function(spin)
            local seconds = spin.value / 1000
            if viewer.nav_transition_duration_callback then
                viewer.nav_transition_duration_callback(viewer, seconds)
            else
                viewer.nav_transition_duration = seconds
            end
        end,
    })
    return true
end

--- Show a slider dialog to adjust how many steps the smooth-navigation camera
--- pan is split into.
---
--- @param on_committed fun()|nil Called after a new value is applied, so a
---   caller showing this from a settings menu can refresh a label reflecting
---   the current value.
--- @return boolean handled Always true for button hold-callback dispatch.
function PanelViewer:onAdjustNavTransitionFrames(on_committed)
    local SpinWidget = require("ui/widget/spinwidget")
    local viewer = self
    UIManager:show(SpinWidget:new{
        title_text = _("Smooth navigation frames"),
        info_text = _("How many steps the camera pan between panels is split into. More frames look smoother but schedule more work per transition."),
        value = self.nav_transition_frames or NAV_TRANSITION_STEPS_DEFAULT,
        value_min = 1,
        value_max = 24,
        value_step = 1,
        value_hold_step = 4,
        unit = _("frames"),
        default_value = NAV_TRANSITION_STEPS_DEFAULT,
        callback = function(spin)
            local frames = spin.value
            if viewer.nav_transition_frames_callback then
                viewer.nav_transition_frames_callback(viewer, frames)
            else
                viewer.nav_transition_frames = frames
            end
            if on_committed then
                on_committed()
            end
        end,
    })
    return true
end

--- Open the rotation picker: one 4-way control for KOReader's real screen
--- rotation, one for this plugin's own zoomed-view rotation.
---
--- Passes an explicit "full" refresh type: `Button:onTapSelectButton()`
--- (the tap that got us here) queues its own highlight/unhighlight refresh
--- scoped to just the button's small rectangle, and without an explicit
--- type here, this dialog's *content* still paints correctly but the
--- physical screen refresh stays clipped to that button-sized region --
--- same fix `ui/screensaver.lua` and `readerstatus.lua` use for the same
--- button-triggered full-screen-dialog situation.
---
--- @return boolean handled Always true for button callback dispatch.
function PanelViewer:onOpenRotationPicker()
    local RotationPickerDialog = require("src._rotationpicker")
    local viewer = self
    UIManager:show(RotationPickerDialog:new{
        on_device_rotate = function(direction)
            viewer:onSetDeviceRotation(direction)
        end,
        on_image_rotate = function(direction)
            viewer:onSetImageRotation(direction)
        end,
    }, "full")
    return true
end

--- Rotate the whole device/screen via KOReader's own rotation, exactly like
--- the built-in rotate control -- this moves menus, status bar, and
--- everything else, not just this viewer.
---
--- Mirrors `ui/elements/screen_rotation_menu_table.lua`'s own rotation menu
--- items, which broadcast this same event for the same reason: several
--- modules (e.g. `ReaderView:onSetRotationMode`) listen for it to update
--- their own layout alongside the screen itself.
---
--- Base `ImageViewer` has no `onScreenResize`/`onSetDimensions` handler of
--- its own (it's built for short-lived overlays, not ones that outlive a
--- screen rotation): its outer region gets sized once at construction from
--- `Screen:getWidth/getHeight()` and never revisited, so simply leaving it
--- open across a rotation leaves stale strips uncovered by the reader's own
--- full repaint. `device_rotate_callback` (wired up by `ViewerController`)
--- closes this viewer, performs the rotation, and reopens an equivalent one
--- for the same page/panel/index -- the same close-and-rebuild idiom
--- `setViewerBleedRatio` already uses for a crop-rectangle change -- so the
--- reader stays in zoom mode instead of dropping back to the plain page
--- view. Without a controller wired up (e.g. standalone use), falls back to
--- closing outright: `UIManager:onRotation()` (setDirty "all"/"full" +
--- forceRePaint) is the same belt-and-suspenders flash every built-in
--- rotation control in KOReader chains after broadcasting the event.
---
--- Each direction is a *relative* turn from wherever the screen currently
--- is, not a fixed absolute target -- pressing "right" while already
--- rotated clockwise turns another quarter further, like holding a D-pad,
--- rather than jumping back to a fixed clockwise orientation. KOReader's
--- rotation-mode integers are themselves sequential quarter-turn steps
--- (0=upright, 1=clockwise, 2=upside-down, 3=counter-clockwise), so adding
--- a quarter-turn count and wrapping mod 4 is exact.
---
--- @param direction "up"|"down"|"left"|"right"
function PanelViewer:onSetDeviceRotation(direction)
    local quarter_turns_by_direction = { up = 2, right = 1, down = 0, left = 3 }
    local turns = quarter_turns_by_direction[direction]
    if turns == nil then
        return
    end
    local mode = (Screen:getRotationMode() + turns) % 4
    if self.device_rotate_callback then
        self.device_rotate_callback(self, mode)
    else
        self:onClose()
        UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
        UIManager:onRotation()
    end
end

--- Rotate only this zoomed panel view, leaving KOReader's own screen
--- rotation untouched.
---
--- Reuses `self.rotated`, the same state ImageViewer already applies for
--- document-driven landscape auto-rotation (see `screenToPageTransform`/
--- `pageToScreenTransform` above) -- setting it here to a real 4-way angle
--- rotates the displayed image exactly like that existing mechanism, with
--- no separate pixel-rotation code needed.
---
--- Unlike `onSetDeviceRotation`, each direction here is an *absolute*
--- target angle, not a relative turn -- pressing "right" always means
--- "rotate this view to 90 degrees", regardless of its current angle.
---
--- @param direction "up"|"down"|"left"|"right"
function PanelViewer:onSetImageRotation(direction)
    local angle_by_direction = { up = 180, right = 90, down = false, left = 270 }
    self.rotated = angle_by_direction[direction]
    self:replaceButtonTable()
    self:update()
end

--- Return the button label for the detector currently in use.
---
--- Named for what each mode gives the reader rather than for how it works:
--- "Quick" always uses the fast detector, "Deep" always uses KOReader's
--- slower but more literal one, and "Smart" runs Quick and falls back to Deep.
---
--- @return string text Localized detector label.
function PanelViewer:getDetectorText()
    if self.detector == "fast" then
        return _("Quick mode")
    elseif self.detector == "exact" then
        return _("Deep mode")
    end
    return _("Smart Mode")
end

--- Rebuild the ImageViewer button table from current mode/crop state.
function PanelViewer:replaceButtonTable()
    local buttons = {
        {
            {
                id = "scale",
                text = self._scale_to_fit and _("Original size") or _("Scale"),
                callback = function()
                    self.scale_factor = self._scale_to_fit and 1 or 0
                    self._scale_to_fit = not self._scale_to_fit
                    self._center_x_ratio = 0.5
                    self._center_y_ratio = 0.5
                    self:update()
                end,
            },
            {
                id = "rotate",
                text = _("Rotate"),
                callback = function()
                    self:onOpenRotationPicker()
                end,
            },
            {
                id = "mode",
                text = self.reading_mode == "comic" and _("Comic mode") or _("Manga mode"),
                callback = function()
                    if self.mode_toggle_callback then
                        self.mode_toggle_callback(self)
                    else
                        self.reading_mode = self.reading_mode == "comic" and "manga" or "comic"
                        self:replaceButtonTable()
                        self:update()
                    end
                end,
            },
            {
                id = "close",
                text = _("Close"),
                callback = function()
                    self:onClose()
                end,
            },
        },
        {
            {
                id = "screenshot",
                text = _("Screenshot"),
                callback = function()
                    self:onSaveImageView()
                end,
            },
            {
                id = "progress_bar",
                text = self.progress_bar_visible == false and _("Show progress") or _("Hide progress"),
                callback = function()
                    if self.progress_bar_toggle_callback then
                        self.progress_bar_toggle_callback(self)
                    else
                        self.progress_bar_visible = not self.progress_bar_visible
                        self:replaceButtonTable()
                        self:update()
                    end
                end,
            },
            {
                id = "nav_transition",
                text = self:getNavTransitionText(),
                callback = function()
                    if self.nav_transition_toggle_callback then
                        self.nav_transition_toggle_callback(self)
                    else
                        self.nav_transition_mode = self.nav_transition_mode == "smooth" and "classic" or "smooth"
                        self:replaceButtonTable()
                        self:update()
                    end
                end,
                hold_callback = function()
                    if self.nav_transition_mode == "smooth" then
                        if self.nav_transition_options_callback then
                            self.nav_transition_options_callback(self)
                        else
                            self:onAdjustNavTransitionDuration()
                        end
                    end
                end,
            },
        },
        {
            {
                id = "more_config",
                text = _("More config..."),
                callback = function()
                    if self.more_config_callback then
                        self.more_config_callback(self)
                    end
                end,
            },
            {
                id = "detector",
                text = self:getDetectorText(),
                callback = function()
                    if self.detector_cycle_callback then
                        self.detector_cycle_callback(self)
                    end
                end,
            },
            {
                id = "crop",
                text = self:getCropModeText(),
                callback = function()
                    if self.crop_toggle_callback then
                        self.crop_toggle_callback(self)
                    else
                        local next_mode = { strict = "loose", loose = "margin", margin = "none", none = "strict" }
                        self.crop_mode = next_mode[self.crop_mode] or "strict"
                        self:replaceButtonTable()
                        self:update()
                    end
                end,
                hold_callback = function()
                    if self.crop_mode == "loose" then
                        self:onAdjustBleedRatio()
                    elseif self.crop_mode == "margin" then
                        self:onAdjustMarginRatio()
                    end
                end,
            },
        },
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
    self.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.button_table:getSize().h,
        },
        self.button_table,
    }
end

return PanelViewer
