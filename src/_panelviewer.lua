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
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field page number|nil Document page number represented by `panels`.
--- @field panels PPPanel[]|nil Ordered panel rectangles.
--- @field reader_ui table|nil Reader UI that owns the normal document gesture zones.
--- @field boundary_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field mode_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field crop_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field buttons_visible boolean Whether controls are currently shown.
--- @field with_title_bar boolean Whether ImageViewer title bar is shown.
--- @field fullscreen boolean Whether the viewer is fullscreen.
--- @field images_keep_pan_and_zoom boolean Whether ImageViewer preserves pan/zoom.
local PanelViewer = ImageViewer:extend{
    name = "panels_plus_panel_viewer",
    reading_mode = "manga",
    crop_mode = "strict",
    invert_swipe = false,
    page = nil,
    panels = nil,
    reader_ui = nil,
    boundary_callback = nil,
    mode_toggle_callback = nil,
    crop_toggle_callback = nil,
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
    return true
end

--- Redraw the viewer, hiding the progress count during screenshot capture.
function PanelViewer:update()
    if not self._hide_progress_for_screenshot then
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
--- @param image any Owned panel blitbuffer.
function PanelViewer:releasePreviousPanelImage(image)
    if not image or not image.free then
        return
    end

    UIManager:tickAfterNext(function()
        if image ~= self.image then
            image:free()
            collectgarbage()
        end
    end)
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
                text = self.crop_mode == "loose" and _("Loose crop") or _("Strict crop"),
                callback = function()
                    if self.crop_toggle_callback then
                        self.crop_toggle_callback(self)
                    else
                        self.crop_mode = self.crop_mode == "loose" and "strict" or "loose"
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
