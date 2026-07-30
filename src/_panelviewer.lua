local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Geometry = require("src._geometry")
local ImageViewer = require("ui/widget/imageviewer")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Screenshoter = require("ui/widget/screenshoter")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

--- Steps the smooth-navigation pan animation is split into.
local NAV_TRANSITION_STEPS = 8
--- Hard cap on the shared transition bitmap's area, as a multiple of the screen's
--- area, to bound the one-shot render/upscale cost when the destination panel
--- needs a much higher zoom than the two panels' combined bounding box.
local NAV_TRANSITION_MAX_AREA_MULTIPLIER = 16

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
--- @field progress_bar_visible boolean Whether the bottom progress bar is shown.
--- @field nav_transition_mode PPNavTransitionMode Instant swap vs. animated camera pan between panels.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field nav_transition_cross_page boolean Whether smooth navigation also animates across page boundaries.
--- @field nav_transition_dummy_b boolean Second demo boolean configuration flag.
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
    progress_bar_visible = true,
    nav_transition_mode = "classic",
    nav_transition_duration = 0.4,
    nav_transition_cross_page = true,
    nav_transition_dummy_b = true,
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
--- @return boolean pannable `true` when at least one axis is larger than the viewport.
function PanelViewer:isImagePannable()
    if not self._image_wg then
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

--- Handle horizontal panel navigation before falling back to ImageViewer.
---
--- @param arg any KOReader gesture argument.
--- @param ges table Gesture event with `direction`.
--- @return boolean|nil handled Whether the gesture was consumed.
function PanelViewer:onSwipe(arg, ges)
    if self:isImagePannable() then
        return self:panBySwipe(ges)
    end

    if self._images_list and (ges.direction == "west" or ges.direction == "east") then
        if ges.direction == self:getNextSwipeDirection() then
            if self._images_list_cur < self._images_list_nb then
                self:onShowNextImage()
            elseif self.boundary_callback then
                return self:onPanelBoundary("next")
            end
        else
            if self._images_list_cur > 1 then
                self:onShowPrevImage()
            elseif self.boundary_callback then
                return self:onPanelBoundary("previous")
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

--- Advance to the next panel, animating a camera pan when smooth navigation is on.
---
--- @return boolean|nil handled Whether the image switch was handled.
function PanelViewer:onShowNextImage()
    if self.nav_transition_mode == "smooth" and self._images_list_cur < self._images_list_nb then
        return self:animateSwitchToImageNum(self._images_list_cur + 1)
    end
    return ImageViewer.onShowNextImage(self)
end

--- Return to the previous panel, animating a camera pan when smooth navigation is on.
---
--- @return boolean|nil handled Whether the image switch was handled.
function PanelViewer:onShowPrevImage()
    if self.nav_transition_mode == "smooth" and self._images_list_cur > 1 then
        return self:animateSwitchToImageNum(self._images_list_cur - 1)
    end
    return ImageViewer.onShowPrevImage(self)
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

--- Toggle controls on inside taps and close on taps outside the frame.
---
--- @param _ any Unused KOReader tap argument.
--- @param ges table Gesture event with a `pos` geometry object.
--- @return boolean handled Always true after processing a tap.
function PanelViewer:onTap(_, ges)
    local frame_dimen = self.main_frame and self.main_frame.dimen
    if frame_dimen and ges.pos:notIntersectWith(frame_dimen) then
        self:onClose()
        return true
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
    if not self._hide_progress_for_screenshot and self.progress_bar_visible ~= false then
        return self:withGuardedImageViewerRefresh(function()
            return ImageViewer.update(self)
        end)
    end

    local images_list_nb = self._images_list_nb
    self._images_list_nb = 1
    local ok, err = pcall(function()
        return self:withGuardedImageViewerRefresh(function()
            return ImageViewer.update(self)
        end)
    end)
    self._images_list_nb = images_list_nb
    if not ok then
        error(err)
    end
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
    local steps = NAV_TRANSITION_STEPS
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
    if canvas_w * canvas_h > screen_area * NAV_TRANSITION_MAX_AREA_MULTIPLIER then
        if tile_a_scaled ~= tile_a and tile_a_scaled.free then
            tile_a_scaled:free()
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
        return ImageViewer._new_image_wg(self)
    end

    local orig_width, orig_container_h = self.width, self.img_container_h
    self.width = orig_width * factor
    self.img_container_h = orig_container_h * factor
    ImageViewer._new_image_wg(self)
    self.width = orig_width
    self.img_container_h = orig_container_h
    self.image_container.dimen.w = orig_width
    self.image_container.dimen.h = orig_container_h
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

--- Return the button label for the detector currently in use.
---
--- Named for what each mode gives the reader rather than for how it works:
--- "Gutter" always uses the quick detector, "Outline" always uses KOReader's
--- slower but more literal one, and "Auto" runs Gutter and falls back to Outline.
---
--- @return string text Localized detector label.
function PanelViewer:getDetectorText()
    if self.detector == "fast" then
        return _("Gutter mode")
    elseif self.detector == "exact" then
        return _("Outline mode")
    end
    return _("Auto mode")
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
                text = self.rotated and _("No rotation") or _("Rotate"),
                callback = function()
                    self.rotated = not self.rotated and true or false
                    self:update()
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
