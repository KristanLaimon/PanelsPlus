local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Screenshoter = require("ui/widget/screenshoter")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- ImageViewer subclass for navigating one page's ordered panel sequence.
---
--- @class PanelViewer : ImageViewer
--- @field reading_mode PPReadingMode Current left/right panel order.
--- @field crop_mode PPCropMode Current crop rendering mode.
--- @field margin_ratio number Zoom-out fraction "margin" crop mode applies to non-full-page panels.
--- @field panel_is_full_page boolean[]|nil Per-panel flag matching `_images_list`, true when a panel spans nearly the whole page.
--- @field detector PPDetector Detector the displayed panels came from.
--- @field detector_cycle_callback fun(viewer:PanelViewer):boolean|nil
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field progress_bar_visible boolean Whether the bottom progress bar is shown.
--- @field page number|nil Document page number represented by `panels`.
--- @field panels PPPanel[]|nil Ordered panel rectangles.
--- @field image_rects PPPanel[]|nil Crop rectangles matching `_images_list`, for prerendering.
--- @field reader_ui table|nil Reader UI that owns the normal document gesture zones.
--- @field panel_prerender_callback fun(viewer:PanelViewer, index:integer)|nil
--- @field boundary_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field mode_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field crop_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field margin_ratio_callback fun(viewer:PanelViewer, ratio:number, activate_margin_mode:boolean|nil):boolean|nil
--- @field progress_bar_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field buttons_visible boolean Whether controls are currently shown.
--- @field with_title_bar boolean Whether ImageViewer title bar is shown.
--- @field fullscreen boolean Whether the viewer is fullscreen.
--- @field images_keep_pan_and_zoom boolean Whether ImageViewer preserves pan/zoom.
local PanelViewer = ImageViewer:extend{
    name = "panels_plus_panel_viewer",
    reading_mode = "manga",
    crop_mode = "strict",
    margin_ratio = 0.12,
    panel_is_full_page = nil,
    detector = "auto",
    invert_swipe = false,
    progress_bar_visible = true,
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
    progress_bar_toggle_callback = nil,
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

--- Return whether a reader touch zone belongs to the configurable gestures plugin.
---
--- Built-in reading zones such as page-turn taps are intentionally excluded so
--- a normal panel tap still toggles controls instead of turning the hidden page.
---
--- @param zone_id string|nil KOReader touch zone id.
--- @param gestures table Gestures plugin instance from the reader UI.
--- @return boolean is_gesture_zone `true` when this is a user-configurable reader gesture.
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
--- The gestures plugin dispatches actions through `UIManager:sendEvent()`. While
--- Panels+ is open, those events would otherwise stop at this viewer, so this
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

    local original_send_event = UIManager.sendEvent
    UIManager.sendEvent = function(manager, event)
        if reader_ui:handleEvent(event) then
            return
        end
        return original_send_event(manager, event)
    end

    local ok, handled = pcall(handler, ges)
    UIManager.sendEvent = original_send_event
    if not ok then
        error(handled)
    end
    return handled == true
end

--- Try handling a gesture through KOReader's normal reader gesture plugin.
---
--- @param ges table Gesture event.
--- @return boolean handled Whether a configured reader gesture consumed it.
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
                and zone.gs_range:match(ges)
                and self:runReaderGestureHandler(zone.handler, ges) then
            return true
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
                return self.boundary_callback("next", self)
            end
        else
            if self._images_list_cur > 1 then
                self:onShowPrevImage()
            elseif self.boundary_callback then
                return self.boundary_callback("previous", self)
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
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
    local ok, err = pcall(function()
        return self:withGuardedImageViewerRefresh(function()
            return ImageViewer.onCloseWidget(self)
        end)
    end)
    self._panels_plus_closing = nil
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

--- Return the button label for the crop mode currently in use.
---
--- @return string text Localized crop-mode label.
function PanelViewer:getCropModeText()
    if self.crop_mode == "loose" then
        return _("Loose crop")
    elseif self.crop_mode == "margin" then
        return _("With margin")
    end
    return _("Strict crop")
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
                id = "crop",
                text = self:getCropModeText(),
                callback = function()
                    if self.crop_toggle_callback then
                        self.crop_toggle_callback(self)
                    else
                        local next_mode = { strict = "loose", loose = "margin", margin = "strict" }
                        self.crop_mode = next_mode[self.crop_mode] or "strict"
                        self:replaceButtonTable()
                        self:update()
                    end
                end,
                hold_callback = function()
                    self:onAdjustMarginRatio()
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
                id = "detector",
                text = self:getDetectorText(),
                callback = function()
                    if self.detector_cycle_callback then
                        self.detector_cycle_callback(self)
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
