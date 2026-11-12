--[[
Panels+
File: src/panelviewer/input.lua
Name: PanelViewer
Description: Focused viewer input methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Event = require("ui/event")
local ImageViewer = require("ui/widget/imageviewer")
local Screen = require("device").screen
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local Constants = require("src.panelviewer.constants")
local FLOW_WARNING_TIMEOUT = Constants.FLOW_WARNING_TIMEOUT

return function(PanelViewer)
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
            if
                type(refreshtype) == "function" and (widget == self or (widget == nil and self._panels_plus_closing))
            then
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

    --- Reader touch zones that always pass through to KOReader, regardless of
    --- whether the user has configured a Gestures plugin action for them.
    ---
    --- These open KOReader's own top menu (its swipe zone sits in the same top
    --- strip a viewer swipe-down would otherwise treat as zoom-out/close), so
    --- swallowing them locally would make the menu unreachable while a panel is
    --- open -- the same top-of-screen swipe that shows the menu when reading
    --- normally would instead exit the viewer.
    local ALWAYS_PASSTHROUGH_ZONES = {
        readermenu_tap = true,
        readermenu_ext_tap = true,
        readermenu_swipe = true,
        readermenu_ext_swipe = true,
    }

    --- Return whether a reader touch zone should be passed through to KOReader.
    ---
    --- User-configured gesture plugin zones (like multiswipe gestures) and
    --- KOReader's own top-menu zones are passed through. Normal page navigation
    --- and highlight zones are captured by PanelViewer.
    ---
    --- @param zone_id string|nil KOReader touch zone id.
    --- @return boolean is_gesture_zone `true` when this touch zone should be dispatched to KOReader.
    function PanelViewer:isReaderGestureZone(zone_id)
        if not zone_id then
            return false
        end
        -- Keep panel ImageViewer pinch/spread zooming local.
        if zone_id == "spread_gesture" or zone_id == "pinch_gesture" then
            return false
        end
        if ALWAYS_PASSTHROUGH_ZONES[zone_id] then
            return true
        end
        return false
    end

    --- Reader-owned controls that stay available while the image is zoomed.
    function PanelViewer:allowsReaderGestureWhilePanning(zone_id)
        return ALWAYS_PASSTHROUGH_ZONES[zone_id] == true
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
        if not reader_ui.document then
            -- A document can be closed while this fullscreen viewer is still on
            -- the window stack (for example through a reader-menu action). Its
            -- cached touch zones then outlive the ReaderUI document they target.
            -- Swallow this stale input and dismiss the viewer rather than letting
            -- a KOReader menu handler dereference the missing document.
            if self:isOpen() then
                self:onClose()
            end
            return true
        end

        local page_before = reader_ui.page
            or (reader_ui.paging and reader_ui.paging.current_page)
            or (reader_ui.view and reader_ui.view.state and reader_ui.view.state.page)
            or (
                reader_ui.document
                and type(reader_ui.document.getCurrentPage) == "function"
                and reader_ui.document:getCurrentPage()
            )
        local page_changed = false

        local original_send_event = UIManager.sendEvent
        UIManager.sendEvent = function(manager, event)
            if reader_ui:handleEvent(event) then
                if
                    event
                    and (
                        event.cmd == "GotoNextPage"
                        or event.cmd == "GotoPrevPage"
                        or event.cmd == "PageForward"
                        or event.cmd == "PageBackward"
                        or event.cmd == "GotoPage"
                    )
                then
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
            -- This is reader-owned code, not a Panels+ operation. Keeping the
            -- stale overlay alive (or rethrowing its error) turns a failed menu
            -- action into a KOReader-wide crash. Dismiss the viewer instead.
            if self:isOpen() then
                self:onClose()
            end
            return true
        end

        local page_after = reader_ui.page
            or (reader_ui.paging and reader_ui.paging.current_page)
            or (reader_ui.view and reader_ui.view.state and reader_ui.view.state.page)
            or (
                reader_ui.document
                and type(reader_ui.document.getCurrentPage) == "function"
                and reader_ui.document:getCurrentPage()
            )
        if (page_changed or (page_after and page_before and page_after ~= page_before)) and self:isOpen() then
            Timing.log(
                "reader gesture/touch zone triggered page turn (%s -> %s); closing viewer",
                tostring(page_before),
                tostring(page_after)
            )
            self:onClose()
        end
        return handled == true
    end

    --- Try handling a gesture or touch zone through KOReader's normal reader UI touch zones.
    ---
    --- While the image is pannable (actually zoomed in past the viewport), a
    --- swipe is normally a pan and stays local. Reader controls with passthrough zones
    --- still receive it so menus and live edge-light controls work while zoomed.
    ---
    --- @param ges table Gesture event.
    --- @return boolean handled Whether a configured reader touch zone or gesture consumed it.
    function PanelViewer:dispatchReaderGesture(ges)
        local pannable = self:isImagePannable()

        local reader_ui = self.reader_ui
        local zones = reader_ui and reader_ui._ordered_touch_zones
        if not zones then
            return false
        end
        if not reader_ui.document then
            -- Do not forward an old reader-menu zone after its document closed.
            if self:isOpen() then
                self:onClose()
            end
            return true
        end

        for _, zone in ipairs(zones) do
            local zone_id = zone.def and zone.def.id
            if
                self:isReaderGestureZone(zone_id)
                and (not pannable or self:allowsReaderGestureWhilePanning(zone_id))
                and zone.gs_range
                and zone.handler
                and zone.gs_range:match(ges)
            then
                Timing.log(
                    "dispatchReaderGesture: passing gesture (type=%s) to reader zone '%s'",
                    tostring(ges and ges.type),
                    tostring(zone_id)
                )
                if self:runReaderGestureHandler(zone.handler, ges) then
                    return true
                end
            end
        end
        return false
    end

    --- Toggle magnification around the touched image position, restoring the prior view.
    function PanelViewer:toggleGestureZoom(pos)
        if
            self._panels_plus_transition_active
            or self._panels_plus_boundary_pending
            or self._panels_plus_smooth_preview
            or not self._image_wg
        then
            return true
        end
        local saved = self._gesture_zoom_restore
        if saved then
            self.scale_factor = saved.scale
            self._scale_to_fit = saved.fit
            self._center_x_ratio, self._center_y_ratio = saved.x, saved.y
            self._gesture_zoom_restore = nil
            self:update()
            return true
        end
        if not pos then
            return true
        end
        local image = self._image_wg
        image:getSize()
        local width, height = image:getCurrentWidth(), image:getCurrentHeight()
        if not width or not height or width <= 0 or height <= 0 then
            return true
        end
        self._gesture_zoom_restore = {
            scale = self.scale_factor,
            fit = self._scale_to_fit,
            x = self._center_x_ratio,
            y = self._center_y_ratio,
        }
        local dimen = image.dimen or { x = 0, y = 0 }
        self._center_x_ratio = math.max(0, math.min(1, (pos.x - dimen.x + (image._offset_x or 0)) / width))
        self._center_y_ratio = math.max(0, math.min(1, (pos.y - dimen.y + (image._offset_y or 0)) / height))
        local factor = self.panel_zoom_settings.panel_gesture_zoom_factor
        if factor ~= 1.25 and factor ~= 1.5 and factor ~= 1.75 and factor ~= 2 then
            factor = 1.5
        end
        self:onZoomIn(factor - 1)
        return true
    end

    --- Let configured reader gestures run in focused-panel mode before local viewer gestures.
    ---
    --- @param ges table Gesture event.
    --- @return boolean|nil handled Whether the gesture was consumed.
    function PanelViewer:onGesture(ges)
        if self._gesture_zoom_holding and (ges.ges == "hold_release" or ges.ges == "hold_pan_release") then
            self._gesture_zoom_holding = nil
            return true
        end
        if self._gesture_zoom_holding and ges.ges == "hold_pan" then
            return true
        end
        local settings = self.panel_zoom_settings
        local zoom_gesture = settings and settings.panel_zoom_gesture == "hold" and "hold" or "two_finger_tap"
        if settings and settings.panel_gesture_zoom == true and ges.ges == zoom_gesture then
            self._gesture_zoom_holding = ges.ges == "hold" or nil
            return self:toggleGestureZoom(ges.pos)
        end
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
    --- A next-page-style gesture moves the visible content opposite the reading
    --- flow: west for Comic mode and east for Manga mode.
    ---
    --- @return '"west"'|'"east"' direction Swipe direction treated as next.
    function PanelViewer:getNextSwipeDirection()
        local direction
        direction = self.reading_mode == "comic" and "west" or "east"
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
    --- edge, so tapping the right side advances. Inverting tap navigation flips
    --- these side assignments.
    ---
    --- @return '"left"'|'"right"' side Tap zone treated as next.
    function PanelViewer:getNextTapSide()
        local side = self.reading_mode == "comic" and "right" or "left"
        if self.invert_taps then
            return side == "right" and "left" or "right"
        end
        return side
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
        if self.kobo_vertical_gesture ~= false and isLeftEdgeGesture(ges) then
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

        if
            self.swipe_navigation ~= false
            and self._images_list
            and (ges.direction == "west" or ges.direction == "east")
        then
            if ges.direction == self:getNextSwipeDirection() then
                return self:onShowNextImage()
            else
                return self:onShowPrevImage()
            end
        end
        return ImageViewer.onSwipe(self, arg, ges)
    end

    --- Offer a timed, explicit handoff to KOReader at either end of the document.
    function PanelViewer:confirmDocumentBoundary(direction, reader_ui)
        if self._document_boundary_dialog or self._panels_plus_closed then
            return true
        end
        local forward = direction == "next"
        local dialog = require("ui/widget/confirmbox"):new({
            text = forward
                    and _("This is the last panel of the last page. Continue to KOReader’s end-of-book action?")
                or _("This is the first panel of the first page. Continue to KOReader’s beginning of the book?"),
            ok_text = _("Continue"),
            cancel_text = _("Stay here"),
        })
        self._document_boundary_dialog = dialog
        local expire = function()
            UIManager:close(dialog)
        end
        local original_close = dialog.onCloseWidget
        dialog.onCloseWidget = function(widget)
            UIManager:unschedule(expire)
            if self._document_boundary_dialog == dialog then
                self._document_boundary_dialog = nil
            end
            if original_close then
                return original_close(widget)
            end
        end
        dialog.ok_callback = function()
            if self._panels_plus_closed or self._document_boundary_dialog ~= dialog then
                return
            end
            UIManager:unschedule(expire)
            self._document_boundary_dialog = nil
            self:onClose()
            -- The document has no next page: dispatch its normal end-of-book
            -- event directly, including when the reader is zoomed into a page.
            reader_ui:handleEvent(forward and Event:new("EndOfBook") or Event:new("GotoViewRel", -1))
        end
        UIManager:show(dialog)
        UIManager:scheduleIn(FLOW_WARNING_TIMEOUT, expire)
        return true
    end

    --- Advance to the next panel, animating a camera pan or crossing page boundary at the end.
    ---
    --- @return boolean|nil handled Whether the image switch was handled.
    function PanelViewer:onShowNextImage()
        if self._panels_plus_boundary_pending or self._panels_plus_smooth_preview then
            return true
        end
        if self._images_list_cur < self._images_list_nb then
            if self.nav_transition_mode == "smooth" then
                return self:animateSwitchToImageNum(self._images_list_cur + 1)
            end
            if
                self.nav_transition_mode == "animated"
                and self.nav_animated_panels ~= false
                and self.panel_animation_callback
            then
                self.panel_animation_callback("next", self)
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
        if self._panels_plus_boundary_pending or self._panels_plus_smooth_preview then
            return true
        end
        if self._images_list_cur > 1 then
            if self.nav_transition_mode == "smooth" then
                return self:animateSwitchToImageNum(self._images_list_cur - 1)
            end
            if
                self.nav_transition_mode == "animated"
                and self.nav_animated_panels ~= false
                and self.panel_animation_callback
            then
                self.panel_animation_callback("previous", self)
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

    --- Move to the next or previous panel when navigating left ("A" or Arrow Left),
    --- respecting the active reading mode (manga vs comic).
    ---
    --- In Manga mode (right-to-left), moving left advances to the next panel.
    --- In Comic mode (left-to-right), moving left retreats to the previous panel.
    ---
    --- @return boolean|nil handled Whether the navigation event was consumed.
    function PanelViewer:onPanelNavLeft()
        if self.reading_mode == "manga" then
            return self:onShowNextImage()
        end
        return self:onShowPrevImage()
    end

    --- Move to the next or previous panel when navigating right ("D" or Arrow Right),
    --- respecting the active reading mode (manga vs comic).
    ---
    --- In Manga mode (right-to-left), moving right retreats to the previous panel.
    --- In Comic mode (left-to-right), moving right advances to the next panel.
    ---
    --- @return boolean|nil handled Whether the navigation event was consumed.
    function PanelViewer:onPanelNavRight()
        if self.reading_mode == "manga" then
            return self:onShowPrevImage()
        end
        return self:onShowNextImage()
    end

    --- Intercept cursor pan events so left/right navigation navigates panels while zoomed.
    ---
    --- @param direction string Panning direction ("left", "right", "up", "down").
    --- @return boolean handled Whether the event was handled.
    function PanelViewer:onCursorPan(direction)
        if direction == "left" then
            return self:onPanelNavLeft()
        elseif direction == "right" then
            return self:onPanelNavRight()
        end
        if ImageViewer.onCursorPan then
            return ImageViewer.onCursorPan(self, direction)
        end
        return true
    end

    --- Keyboard handler for panel navigation with "A", "D", and left/right arrow keys.
    ---
    --- @param key string|table Key name or KOReader Key event object.
    --- @return boolean|nil handled
    function PanelViewer:onKeyPress(key)
        local key_name
        local has_modifier = false
        if type(key) == "string" then
            key_name = key
        elseif type(key) == "table" then
            key_name = key.key
            if key.modifiers then
                for _, pressed in pairs(key.modifiers) do
                    if pressed then
                        has_modifier = true
                        break
                    end
                end
            end
        end
        if not has_modifier and key_name then
            if key_name == "Left" or key_name == "a" or key_name == "A" then
                return self:onPanelNavLeft()
            elseif key_name == "Right" or key_name == "d" or key_name == "D" then
                return self:onPanelNavRight()
            elseif key_name == "LPgFwd" or key_name == "RPgFwd" or key_name == "PageDown" or key_name == " " then
                return self:onShowNextImage()
            elseif key_name == "LPgBack" or key_name == "RPgBack" or key_name == "PageUp" then
                return self:onShowPrevImage()
            end

            local ok_dev, Device = pcall(require, "device")
            if ok_dev and Device and Device.input and Device.input.group then
                if Device.input.group.PgFwd then
                    for _, code in ipairs(Device.input.group.PgFwd) do
                        if key_name == code then
                            return self:onShowNextImage()
                        end
                    end
                end
                if Device.input.group.PgBack then
                    for _, code in ipairs(Device.input.group.PgBack) do
                        if key_name == code then
                            return self:onShowPrevImage()
                        end
                    end
                end
            end
        end
        if ImageViewer.onKeyPress then
            return ImageViewer.onKeyPress(self, key)
        end
        return true
    end

    --- Forward key repeat events identically to key press.
    ---
    --- @param key string|table Key name or KOReader Key event object.
    --- @return boolean|nil handled
    function PanelViewer:onKeyRepeat(key)
        return self:onKeyPress(key)
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
        if self._panels_plus_smooth_preview then
            return true
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
end
