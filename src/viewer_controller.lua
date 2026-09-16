--[[
Panels+
File: src/viewer_controller.lua
Name: ViewerController
Description: Coordinates viewer creation, reading-mode changes, transitions, rotation, and page boundaries.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Event = require("ui/event")
local Device = require("device")
local Screen = Device.screen
local Memory = require("src._memory")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")

--- Panel viewer orchestration methods mixed into `PanelsPlus`.
---
--- @class PPViewerControllerMethods
local ViewerController = {}

--- Restore the reader's device orientation when a page change replaced it.
---
--- A panel-boundary crossing goes through the regular `GotoPage` event so
--- KOReader can update its reading state. Some KOReader configurations and
--- third-party plugins also apply a document rotation while handling that
--- event. That used to undo a Device rotation chosen from the Panels+ picker
--- just before the next panel viewer was created. Keep the selected screen
--- mode across this internal page handoff; this is deliberately separate from
--- the per-image `image_rotation` setting.
---
--- @param expected_mode integer|nil Rotation mode active before the page handoff.
function ViewerController:restoreDeviceRotation(expected_mode)
    if expected_mode == nil or Screen:getRotationMode() == expected_mode then
        return
    end
    Timing.log("restoring device rotation after page handoff: %d -> %d", Screen:getRotationMode(), expected_mode)
    UIManager:broadcastEvent(Event:new("SetRotationMode", expected_mode))
    UIManager:onRotation()
end

--- Drop any panel prerender that has not run yet.
function ViewerController:cancelPanelPrerender()
    if self.panel_prerender_action then
        UIManager:unschedule(self.panel_prerender_action)
        self.panel_prerender_action = nil
    end
end

--- Return whether there is room to warm one more panel tile.
---
--- @return boolean allowed Whether prerendering should proceed.
function ViewerController:hasMemoryForPrerender()
    local minimum = self.settings.prerender_min_free_bytes or Settings.defaults.prerender_min_free_bytes
    local allowed = Memory.hasHeadroom(minimum)
    if not allowed then
        local free_bytes = Memory.freeBytes()
        Timing.log(
            "prerender skipped: low memory (free=%dMB min=%dMB)",
            math.floor((free_bytes or 0) / (1024 * 1024)),
            math.floor(minimum / (1024 * 1024))
        )
    end
    return allowed
end

--- Warm the render of the panel after `index` while the reader sits idle.
---
--- Swiping to a panel otherwise pays for a synchronous `drawPagePart()`, which
--- rasterizes that region of the page scaled up to the screen. Doing it ahead of
--- time leaves the tile in KOReader's `DocCache`, so the swipe becomes a cache
--- hit. The rendered buffer is deliberately discarded rather than kept: the
--- cache already owns it, and holding a second copy would spend the memory this
--- is meant to protect.
---
--- @param viewer PanelViewer Active panel viewer.
--- @param index integer 1-based index of the panel currently shown.
function ViewerController:prerenderNextPanel(viewer, index)
    self:cancelPanelPrerender()
    if self.settings.panel_prerender == false then
        return
    end

    local next_rect = viewer.image_rects and viewer.image_rects[index + 1]
    if not next_rect then
        return
    end

    local delay = self.settings.panel_prerender_delay or Settings.defaults.panel_prerender_delay
    local action
    action = function()
        if self.panel_prerender_action == action then
            self.panel_prerender_action = nil
        end
        if viewer._panels_plus_closed or not self:hasMemoryForPrerender() then
            return
        end
        local stop = Timing.span("prerender panel " .. (index + 1))
        pcall(function()
            self.ui.document:drawPagePart(viewer.page, next_rect, 0)
        end)
        stop()
    end

    self.panel_prerender_action = action
    UIManager:scheduleIn(delay, action)
end

--- Toggle reading order from an open viewer and keep the current panel position.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerMode(viewer)
    local current_rect = viewer.panels and viewer.panels[viewer._images_list_cur]
    local next_mode = (viewer.reading_mode or self.settings.mode) == "manga" and "comic" or "manga"
    self:setMode(next_mode)
    if not current_rect then
        viewer.reading_mode = self.settings.mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = self:collectPanels(viewer.page)
    if #panels == 0 then
        viewer.reading_mode = self.settings.mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local start_idx = PanelCollector.startIndex(panels, {
        x = (current_rect.x or 0) + (current_rect.w or 0) / 2,
        y = (current_rect.y or 0) + (current_rect.h or 0) / 2,
    })

    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

--- Order the crop-mode button cycles through on tap.
local CROP_MODE_CYCLE = { strict = "loose", loose = "margin", margin = "none", none = "strict" }

--- Toggle crop mode from an open viewer and reopen at the same image index.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerCropMode(viewer)
    self:setCropMode(CROP_MODE_CYCLE[self.settings.crop_mode] or "strict")
    if not viewer.panels or #viewer.panels == 0 then
        viewer.crop_mode = self.settings.crop_mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

--- Persist a new "With margin" zoom-out ratio from an open viewer's slider dialog.
---
--- Unlike crop mode itself, the ratio doesn't change any crop rectangle, so the
--- viewer is updated in place instead of being rebuilt.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param ratio number New margin ratio in [0, 1].
--- @param activate_margin_mode boolean|nil Also switch crop mode to "margin" so the change is visible.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerMarginRatio(viewer, ratio, activate_margin_mode)
    self:setMarginRatio(ratio)
    if activate_margin_mode then
        self:setCropMode("margin")
    end
    viewer.margin_ratio = self.settings.panel_margin_ratio
    viewer.crop_mode = self.settings.crop_mode
    viewer:replaceButtonTable()
    viewer:update()
    return true
end

--- Persist a new "Loose crop" bleed ratio from an open viewer's slider dialog.
---
--- Unlike the margin ratio, this changes the actual crop rectangle passed to
--- `drawPagePart()`, so the viewer is rebuilt the same way `toggleViewerCropMode`
--- rebuilds it after a mode change.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param ratio number New bleed ratio in [0, 1].
--- @param activate_loose_mode boolean|nil Also switch crop mode to "loose" so the change is visible.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerBleedRatio(viewer, ratio, activate_loose_mode)
    self:setBleedRatio(ratio)
    if activate_loose_mode then
        self:setCropMode("loose")
    end
    if not viewer.panels or #viewer.panels == 0 then
        viewer.crop_mode = self.settings.crop_mode
        viewer.bleed_ratio = self.settings.panel_bleed_ratio
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

--- Rotate the device/screen to `mode`, then reopen an equivalent viewer for
--- the same page/panel/index so the reader stays in zoom mode across the
--- rotation instead of dropping back to the plain page view.
---
--- Base `ImageViewer` has no live-reflow path for a screen-dimension change
--- while it's showing -- its outer region gets sized once at construction
--- and never revisited -- so closing and rebuilding, exactly like
--- `setViewerBleedRatio` above does for a crop-rectangle change, is the
--- reliable option. `PanelCollector.buildImages()`'s own `drawPagePart()`
--- sizing already fits whatever the *current* screen dimensions are, so the
--- rebuilt viewer comes out correctly sized/oriented for the new rotation
--- for free, once the rotation has actually applied.
---
--- @param viewer PanelViewer Viewer requesting the rotation.
--- @param mode integer Target `Screen.DEVICE_ROTATED_*` rotation mode.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setDeviceRotation(viewer, mode)
    local page = viewer.page
    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    local buttons_visible = viewer.buttons_visible
    UIManager:close(viewer)
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    UIManager:onRotation()
    self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = buttons_visible })
    return true
end

--- Android's automatic rotation sends ScreenResize after changing the canvas.
--- The current panel bitmap and ImageViewer layout still use the old size.
function ViewerController:resizePanelViewer(viewer)
    local page = viewer.page
    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    local buttons_visible = viewer.buttons_visible
    UIManager:close(viewer)
    return self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = buttons_visible })
end

--- Persist a new plugin-only image rotation chosen from the rotation picker.
---
--- Unlike `setDeviceRotation`, this never rebuilds the viewer -- `viewer`
--- already applied the new angle to `self.rotated` itself (see
--- `PanelViewer:onSetImageRotation`), so this only needs to save it to
--- outlive this viewer instance: reused across panel switches within it
--- (`switchToImageNum` re-applies `image_rotation` after `self.rotated` gets
--- overwritten by document auto-rotation) and carried into whichever viewer
--- gets built next, including one rebuilt by a device rotation.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param value number|boolean New image rotation (`false` or 90/180/270).
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerImageRotation(viewer, value)
    self:setImageRotation(value)
    return true
end

function ViewerController:cycleViewerDetector(_viewer)
    return true
end

--- Toggle progress bar visibility from an open viewer.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerProgressBar(viewer)
    self:setProgressBarVisible(viewer.progress_bar_visible == false)
    viewer.progress_bar_visible = self.settings.progress_bar_visible ~= false
    viewer:replaceButtonTable()
    viewer:update()
    return true
end

--- Cycle nav transition mode from an open viewer, in place.
--- Show a centered info message if Animated mode is selected on a device that doesn't support hardware swipe animations.
function ViewerController:notifyAnimatedModeUnsupported()
    if Device:canDoSwipeAnimation() then
        return
    end
    local _ = require("gettext")
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_info and InfoMessage and InfoMessage.new then
        pcall(function()
            UIManager:show(InfoMessage:new({
                text = _(
                    "Requires special e-ink devices swipe hardware support (Kindles, Kobos, etc..) not compatible with Android and Desktop (Linux)"
                ),
                timeout = 3,
            }))
        end)
    end
end

---
--- Unlike crop mode or detector, this doesn't change the panel list or any
--- rendered rectangle, so the viewer is updated in place instead of rebuilt.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerNavTransitionMode(viewer)
    local next_mode = { classic = "smooth", smooth = "animated", animated = "classic" }
    self:setNavTransitionMode(next_mode[self.settings.nav_transition_mode] or "classic")
    viewer.nav_transition_mode = self.settings.nav_transition_mode
    viewer:replaceButtonTable()
    viewer:update()
    if self.settings.nav_transition_mode == "animated" then
        self:notifyAnimatedModeUnsupported()
    end
    return true
end

--- Persist a new smooth-navigation pan duration from an open viewer's slider dialog.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param seconds number New transition duration in seconds.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerNavTransitionDuration(viewer, seconds)
    self:setNavTransitionDuration(seconds)
    viewer.nav_transition_duration = self.settings.nav_transition_duration
    return true
end

--- Persist a new smooth-navigation frame count from an open viewer's slider dialog.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param frames integer New step count the camera pan is split into.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerNavTransitionFrames(viewer, frames)
    self:setNavTransitionFrames(frames)
    viewer.nav_transition_frames = self.settings.nav_transition_frames
    return true
end

--- Show a multi-options menu popup for navigation transition configuration.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:showNavTransitionOptionsMenu(viewer)
    local Menu = require("ui/widget/menu")
    local _ = require("gettext")
    local controller = self
    local menu

    local menu_items
    if viewer.nav_transition_mode == "animated" then
        menu_items = {
            {
                text = _("Animate between panels (Actual: ")
                    .. (controller.settings.nav_animated_panels ~= false and _("true") or _("false"))
                    .. ")",
                checked_func = function()
                    return controller.settings.nav_animated_panels ~= false
                end,
                callback = function()
                    controller:setNavAnimatedPanels(controller.settings.nav_animated_panels == false)
                    viewer.nav_animated_panels = controller.settings.nav_animated_panels
                    UIManager:close(menu)
                    controller:showNavTransitionOptionsMenu(viewer)
                end,
            },
            {
                text = _("Animate between pages (Actual: ") .. (controller.settings.nav_animated_pages ~= false and _(
                    "true"
                ) or _("false")) .. ")",
                checked_func = function()
                    return controller.settings.nav_animated_pages ~= false
                end,
                callback = function()
                    controller:setNavAnimatedPages(controller.settings.nav_animated_pages == false)
                    viewer.nav_animated_pages = controller.settings.nav_animated_pages
                    UIManager:close(menu)
                    controller:showNavTransitionOptionsMenu(viewer)
                end,
            },
        }
    else
        menu_items = {
            {
                text = _("Pan animation duration..."),
                callback = function()
                    viewer:onAdjustNavTransitionDuration()
                end,
                help_text = _("Adjust how long the camera pan between panels takes in milliseconds."),
            },
            {
                text = _("Animate page-to-page transitions (Actual: ")
                    .. (controller.settings.nav_transition_cross_page == true and _("true") or _("false"))
                    .. ")",
                checked_func = function()
                    return controller.settings.nav_transition_cross_page == true
                end,
                callback = function()
                    controller:setNavTransitionCrossPage(not controller.settings.nav_transition_cross_page)
                    viewer.nav_transition_cross_page = controller.settings.nav_transition_cross_page
                    -- Rebuild the menu so the "(Actual: ...)" label in the text
                    -- reflects the new value immediately, not just the checkmark.
                    UIManager:close(menu)
                    controller:showNavTransitionOptionsMenu(viewer)
                end,
                help_text = _(
                    "Also pan across the boundary between the last panel of a page and the first panel of the next, instead of cutting instantly. Only animates when the adjacent page has already been detected in the background; otherwise the crossing stays an instant cut."
                ),
            },
            {
                text = _("Transition frames (Actual: ")
                    .. tostring(controller.settings.nav_transition_frames or Settings.defaults.nav_transition_frames)
                    .. _(" fps)"),
                callback = function()
                    viewer:onAdjustNavTransitionFrames(function()
                        -- Rebuild the menu so the "(Actual: ...)" label in the
                        -- text reflects the new value immediately.
                        UIManager:close(menu)
                        controller:showNavTransitionOptionsMenu(viewer)
                    end)
                end,
                help_text = _(
                    "How many discrete steps the smooth camera pan between panels is split into. More frames look smoother but schedule more work per transition."
                ),
            },
        }
    end

    menu = Menu:new({
        title = _("Navigation Transition Settings"),
        item_table = menu_items,
    })
    UIManager:show(menu)
    return true
end

--- Toggle tapping the screen's left/right edges to navigate between panels,
--- from an open viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerTapNavigation(viewer)
    self:setTapNavigation(self.settings.tap_navigation ~= true)
    viewer.tap_navigation = self.settings.tap_navigation
    return true
end

--- Toggle swiping left/right to navigate between panels, from an open
--- viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerSwipeNavigation(viewer)
    self:setSwipeNavigation(self.settings.swipe_navigation == false)
    viewer.swipe_navigation = self.settings.swipe_navigation
    return true
end

--- Set whether Kobo-like vertical edge gestures for zooming in/out are enabled.
---
--- @param enabled any Truthy value enables Kobo-style left-edge vertical zoom.
function ViewerController:setKoboVerticalGesture(enabled)
    self.settings.kobo_vertical_gesture = enabled and true or false
    if self.saveSettings then
        self:saveSettings()
    end
end

--- Toggle Kobo-like vertical edge gestures for zooming in/out, from an open
--- viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerKoboVerticalGesture(viewer)
    self:setKoboVerticalGesture(self.settings.kobo_vertical_gesture == false)
    viewer.kobo_vertical_gesture = self.settings.kobo_vertical_gesture
    return true
end

--- Return whether Animated mode should play a framebuffer page transition.
function ViewerController:isPageTurnAnimationActive(viewer)
    return Device:canDoSwipeAnimation()
        and viewer
        and viewer.nav_transition_mode == "animated"
        and viewer.nav_animated_pages ~= false
end

--- Return the physical direction expected by KOReader's framebuffer API.
--- `true` moves left (right-to-left); `false` moves right (left-to-right).
--- Forward Comic navigation moves left, while forward Manga navigation moves
--- right. Previous navigation reverses the matching direction.
local function animatedTransitionMovesLeft(direction, viewer)
    local moves_left = viewer.reading_mode == "comic"
    if direction == "previous" then
        moves_left = not moves_left
    end
    return moves_left
end

--- Arm one framebuffer page animation for the next refresh in Animated mode.
function ViewerController:armPageTurnAnimation(direction, viewer)
    if not self:isPageTurnAnimationActive(viewer) then
        return false
    end
    Screen:setSwipeAnimations(true)
    Screen:setSwipeDirection(animatedTransitionMovesLeft(direction, viewer))
    return true
end

--- Arm one framebuffer animation for a panel-to-panel switch in Animated mode.
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param viewer PanelViewer Active panel viewer.
--- @return boolean armed Whether an animation was armed.
function ViewerController:armPanelTransitionAnimation(direction, viewer)
    if
        not Device:canDoSwipeAnimation()
        or not viewer
        or viewer.nav_transition_mode ~= "animated"
        or viewer.nav_animated_panels == false
    then
        return false
    end
    Screen:setSwipeAnimations(true)
    Screen:setSwipeDirection(animatedTransitionMovesLeft(direction, viewer))
    return true
end

--- Show a multi-options menu popup for miscellaneous panel viewer settings
--- that don't need their own dedicated button.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:showMoreConfigMenu(viewer)
    local Menu = require("ui/widget/menu")
    local _ = require("gettext")
    local controller = self
    local menu

    local function categorizedText(category, label)
        return "[" .. category .. "]: " .. label
    end

    local menu_items = {
        {
            text = categorizedText(
                _("Navigation"),
                _("Tap screen sides to navigate (Actual: ")
                    .. (controller.settings.tap_navigation == true and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.tap_navigation == true
            end,
            callback = function()
                controller:toggleViewerTapNavigation(viewer)
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Tap the left or right edge of the screen to move to the previous or next panel, instead of only showing/hiding the controls. Which side advances depends on reading mode: right side in Comic mode, left side in Manga mode. Only active at standard zoom."
            ),
        },
        {
            text = categorizedText(
                _("Navigation"),
                _("Swipe to navigate (Actual: ")
                    .. (controller.settings.swipe_navigation ~= false and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.swipe_navigation ~= false
            end,
            callback = function()
                controller:toggleViewerSwipeNavigation(viewer)
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Swipe left/right to move between panels. Turning this off leaves panel navigation to taps, buttons, or physical page-turn keys only."
            ),
        },
        {
            text = categorizedText(
                _("Navigation"),
                _("Invert panel swipe direction (Actual: ")
                    .. (controller.settings.invert_swipe == true and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.invert_swipe == true
            end,
            callback = function()
                controller:setInvertSwipe(not controller.settings.invert_swipe)
                viewer.invert_swipe = controller.settings.invert_swipe
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Use this if panel navigation feels reversed on your device. It changes swipe direction only, not panel order."
            ),
        },
        {
            text = categorizedText(
                _("Navigation"),
                _("Invert tap screens direction (Actual: ")
                    .. (controller.settings.invert_taps == true and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.invert_taps == true
            end,
            callback = function()
                controller:setInvertTaps(not controller.settings.invert_taps)
                viewer.invert_taps = controller.settings.invert_taps
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Use this if side tap navigation feels reversed on your device. It changes tap direction only, not panel order."
            ),
        },
        {
            text = categorizedText(
                _("Navigation"),
                _("Kobo-like edge vertical gesture (Actual: ")
                    .. (controller.settings.kobo_vertical_gesture ~= false and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.kobo_vertical_gesture ~= false
            end,
            callback = function()
                controller:toggleViewerKoboVerticalGesture(viewer)
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Swipe vertically within the left 25% of the screen to zoom in (swipe up) or zoom out (swipe down), similar to Kobo's edge gesture. Only active at standard zoom."
            ),
        },
        {
            text = categorizedText(
                _("Navigation"),
                _("Remember per-document settings (Actual: ")
                    .. (controller.settings.remember_doc_settings ~= false and _("true") or _("false"))
                    .. ")"
            ),
            checked_func = function()
                return controller.settings.remember_doc_settings ~= false
            end,
            callback = function()
                controller:setRememberDocSettings(controller.settings.remember_doc_settings == false)
                UIManager:close(menu)
                controller:showMoreConfigMenu(viewer)
            end,
            help_text = _(
                "Save and restore reading mode, navigation mode, crop mode, and progress bar visibility automatically for each document."
            ),
            separator = true,
        },
    }

    table.insert(menu_items, {
        text = categorizedText(
            _("Performance"),
            _("Pre-render next panel (Actual: ")
                .. (controller.settings.panel_prerender ~= false and _("true") or _("false"))
                .. ")"
        ),
        checked_func = function()
            return controller.settings.panel_prerender ~= false
        end,
        callback = function()
            controller:setPanelPrerender(controller.settings.panel_prerender == false)
            UIManager:close(menu)
            controller:showMoreConfigMenu(viewer)
        end,
        help_text = _(
            "Render the next panel while you read the current one, so swiping to it is instant. Skipped automatically when the device is low on memory."
        ),
        separator = true,
    })
    table.insert(menu_items, {
        text = categorizedText(
            _("Text Selection"),
            _("Touch & hold (Actual: ")
                .. (controller.settings.hold_text_selection ~= false and _("true") or _("false"))
                .. ")"
        ),
        checked_func = function()
            return controller.settings.hold_text_selection ~= false
        end,
        callback = function()
            controller:setHoldTextSelection(controller.settings.hold_text_selection == false)
            if not viewer.embedded_source_image then
                viewer.hold_text_selection = controller.settings.hold_text_selection
            end
            UIManager:close(menu)
            controller:showMoreConfigMenu(viewer)
        end,
        help_text = _(
            "Allow touch and hold on text inside zoomed panels to select text and trigger OCR-based dictionary lookups. On by default; turn off if the OCR word detection misfires often on your comics."
        ),
    })

    menu = Menu:new({
        title = _("More Panel Viewer Settings"),
        item_table = menu_items,
    })
    UIManager:show(menu)
    return true
end

--- Start panel sequence viewing from a native panel-zoom hold gesture.
---
--- @param reader_highlight table KOReader reader highlight module.
--- @param ges table Gesture event containing a screen-space `pos`.
--- @return boolean handled `true` when the plugin opens a viewer.
function ViewerController:showPanelSequence(reader_highlight, ges)
    reader_highlight:clear()
    local hold_pos = reader_highlight.view:screenToPageTransform(ges.pos)
    if not hold_pos then
        return false
    end

    local panels = self:collectPanels(hold_pos.page, hold_pos)
    if #panels == 0 then
        Timing.log("showPanelSequence: page %d had no panels detected at hold position", hold_pos.page)
        return false
    end

    local start_idx = PanelCollector.startIndex(panels, hold_pos)
    Timing.log("showPanelSequence: page %d panels=%d start_idx=%d", hold_pos.page, #panels, start_idx)
    Timing.memory("show_panel_sequence")
    return self:showPanelViewerForPage(hold_pos.page, panels, start_idx)
end

--- Open a `PanelViewer` for an ordered page-panel sequence.
---
--- @param page number Document page number.
--- @param panels PPPanel[] Ordered panel rectangles.
--- @param start_idx number|nil 1-based panel index to display first.
--- @param options PPShowViewerOptions|nil Viewer behavior flags.
--- @return boolean|PanelViewer result `true` by default, or viewer when requested.
function ViewerController:showPanelViewerForPage(page, panels, start_idx, options)
    options = options or {}
    self:cancelPanelPrerender()
    Timing.log(
        "showPanelViewerForPage: page=%d panels=%d start_idx=%d crop_mode=%s transition_mode=%s",
        page,
        #panels,
        start_idx or 1,
        tostring(self.settings.crop_mode),
        tostring(self.settings.nav_transition_mode)
    )
    Timing.memory("show_panel_viewer")
    local images, image_rects, full_page_flags = PanelCollector.buildImages(self.ui, page, panels, self.settings)
    local viewer
    viewer = PanelViewer:new({
        image = images,
        image_disposable = true,
        images_list_nb = #images,
        page = page,
        panels = panels,
        image_rects = image_rects,
        panel_is_full_page = full_page_flags,
        reader_ui = self.ui,
        panel_prerender_callback = function(current_viewer, index)
            return self:prerenderNextPanel(current_viewer, index)
        end,
        reading_mode = self.settings.mode,
        crop_mode = self.settings.crop_mode,
        margin_ratio = self.settings.panel_margin_ratio,
        bleed_ratio = self.settings.panel_bleed_ratio,
        detector = "components",
        invert_swipe = self.settings.invert_swipe == true,
        invert_taps = self.settings.invert_taps == true,
        tap_navigation = self.settings.tap_navigation == true,
        swipe_navigation = self.settings.swipe_navigation ~= false,
        kobo_vertical_gesture = self.settings.kobo_vertical_gesture ~= false,
        progress_bar_visible = self.settings.progress_bar_visible ~= false,
        hold_text_selection = self.settings.hold_text_selection ~= false,
        ocr_debug_mode = self.settings.ocr_debug_mode == true,
        image_rotation = self.settings.image_rotation,
        nav_transition_mode = self.settings.nav_transition_mode or "classic",
        nav_animated_panels = self.settings.nav_animated_panels ~= false,
        nav_animated_pages = self.settings.nav_animated_pages ~= false,
        nav_transition_duration = self.settings.nav_transition_duration or Settings.defaults.nav_transition_duration,
        nav_transition_cross_page = self.settings.nav_transition_cross_page == true,
        nav_transition_frames = self.settings.nav_transition_frames or Settings.defaults.nav_transition_frames,
        buttons_visible = options.buttons_visible == true,
        boundary_callback = function(direction, current_viewer)
            return self:onPanelViewerBoundary(direction, current_viewer)
        end,
        mode_toggle_callback = function(current_viewer)
            return self:toggleViewerMode(current_viewer)
        end,
        crop_toggle_callback = function(current_viewer)
            return self:toggleViewerCropMode(current_viewer)
        end,
        margin_ratio_callback = function(current_viewer, ratio, activate_margin_mode)
            return self:setViewerMarginRatio(current_viewer, ratio, activate_margin_mode)
        end,
        bleed_ratio_callback = function(current_viewer, ratio, activate_loose_mode)
            return self:setViewerBleedRatio(current_viewer, ratio, activate_loose_mode)
        end,
        progress_bar_toggle_callback = function(current_viewer)
            return self:toggleViewerProgressBar(current_viewer)
        end,
        nav_transition_toggle_callback = function(current_viewer)
            return self:toggleViewerNavTransitionMode(current_viewer)
        end,
        nav_transition_duration_callback = function(current_viewer, seconds)
            return self:setViewerNavTransitionDuration(current_viewer, seconds)
        end,
        nav_transition_frames_callback = function(current_viewer, frames)
            return self:setViewerNavTransitionFrames(current_viewer, frames)
        end,
        nav_transition_cross_page_callback = function(current_viewer, enabled)
            self:setNavTransitionCrossPage(enabled)
            current_viewer.nav_transition_cross_page = self.settings.nav_transition_cross_page == true
            return true
        end,
        nav_transition_options_callback = function(current_viewer)
            return self:showNavTransitionOptionsMenu(current_viewer)
        end,
        panel_animation_callback = function(direction, current_viewer)
            return self:armPanelTransitionAnimation(direction, current_viewer)
        end,
        nav_boundary_peek_callback = function(direction, current_viewer)
            return self:resolveBoundaryTarget(direction, current_viewer)
        end,
        nav_boundary_commit_callback = function(current_viewer, direction, resolved)
            return self:commitBoundaryTransition(direction, current_viewer, resolved)
        end,
        device_rotate_callback = function(current_viewer, mode)
            return self:setDeviceRotation(current_viewer, mode)
        end,
        screen_resize_callback = function(current_viewer)
            return self:resizePanelViewer(current_viewer)
        end,
        image_rotation_callback = function(current_viewer, value)
            return self:setViewerImageRotation(current_viewer, value)
        end,
        more_config_callback = function(current_viewer)
            return self:showMoreConfigMenu(current_viewer)
        end,
    })

    if options.replace_viewer then
        self:armPageTurnAnimation(options.boundary_direction, options.replace_viewer)
        UIManager:close(options.replace_viewer)
    end
    UIManager:show(viewer)
    if start_idx and start_idx > 1 then
        viewer:switchToImageNum(start_idx)
    end
    if not options.defer_preload then
        self:preloadNextPanels(page)
    end
    if options.return_viewer then
        return viewer
    end
    return true
end

--- Look up the adjacent page's panels for a boundary crossing, if already
--- cached, without any side effects (no GotoPage, no closing/opening viewers,
--- no triggering detection).
---
--- Callers must fall back to the classic instant boundary crossing when this
--- returns `nil` -- it deliberately never waits for detection, so an animated
--- crossing only ever happens when `preloadNextPanels` has already warmed the
--- adjacent page in the background.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer.
--- @return PPBoundaryResolution|nil resolved `nil` when there is no next/prev
---   page, or its panels are not (yet) cached.
function ViewerController:resolveBoundaryTarget(direction, current_viewer)
    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    if not next_page or next_page == 0 then
        return nil
    end

    local cached_panels = self:getCachedPanels(next_page)
    if not cached_panels then
        return nil
    end
    if #cached_panels == 0 then
        cached_panels = PanelCollector.fullPage(self.ui.document, next_page)
        if #cached_panels == 0 then
            return nil
        end
    end

    local start_idx = direction == "next" and 1 or #cached_panels
    local next_images, image_rects, full_page_flags =
        PanelCollector.buildImages(self.ui, next_page, cached_panels, self.settings)
    return {
        next_page = next_page,
        panels = cached_panels,
        start_idx = start_idx,
        target_rect = image_rects[start_idx],
        target_is_full_page = full_page_flags and full_page_flags[start_idx] == true or false,
        next_images = next_images,
    }
end

--- Perform the actual page turn for a boundary crossing: GotoPage, close the
--- current viewer, open the adjacent one at the resolved panel.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer being replaced.
--- @param resolved PPBoundaryResolution Result of a prior `resolveBoundaryTarget` call.
--- @return boolean|PanelViewer result Whatever `showPanelViewerForPage` returns.
function ViewerController:commitBoundaryTransition(direction, current_viewer, resolved)
    -- Smooth crossings arrive here without going through
    -- `onPanelViewerBoundary`. Sample immediately before `GotoPage` so both
    -- paths preserve the user's current device orientation, including any
    -- change made while a deferred panel lookup was running.
    local rotation_mode = Screen:getRotationMode()
    Timing.log(
        "commitBoundaryTransition: direction=%s page=%d -> %d target_panel=%d",
        direction,
        current_viewer and current_viewer.page or -1,
        resolved.next_page,
        resolved.start_idx
    )
    self.ui:handleEvent(Event:new("GotoPage", resolved.next_page))
    self:restoreDeviceRotation(rotation_mode)
    return self:showPanelViewerForPage(resolved.next_page, resolved.panels, resolved.start_idx, {
        replace_viewer = current_viewer,
        boundary_direction = direction,
    })
end

--- Move to the adjacent page when panel navigation crosses viewer boundaries.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:onPanelViewerBoundary(direction, current_viewer)
    if current_viewer._panels_plus_boundary_pending then
        return true
    end
    current_viewer._panels_plus_boundary_pending = true

    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    Timing.log(
        "onPanelViewerBoundary: direction=%s page=%d next_page=%s",
        direction,
        current_viewer and current_viewer.page or -1,
        tostring(next_page)
    )
    if not next_page or next_page == 0 then
        current_viewer._panels_plus_boundary_pending = nil
        return true
    end

    local resolved = self:resolveBoundaryTarget(direction, current_viewer)
    if resolved then
        return self:commitBoundaryTransition(direction, current_viewer, resolved)
    end

    local cached_panels = self:getCachedPanels(next_page)
    if cached_panels then
        -- The full-page fallback above also needs valid native dimensions.
        -- If the document cannot provide them, keep the current viewer open.
        current_viewer._panels_plus_boundary_pending = nil
        return true
    end

    UIManager:tickAfterNext(function()
        if current_viewer._panels_plus_closed then
            return
        end
        local loaded_panels = self:collectPanels(next_page)
        if #loaded_panels == 0 then
            loaded_panels = PanelCollector.fullPage(self.ui.document, next_page)
        end
        if #loaded_panels > 0 then
            local rotation_mode = Screen:getRotationMode()
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            self:restoreDeviceRotation(rotation_mode)
            local start_idx = direction == "next" and 1 or #loaded_panels
            self:showPanelViewerForPage(next_page, loaded_panels, start_idx, {
                replace_viewer = current_viewer,
                boundary_direction = direction,
            })
        else
            current_viewer._panels_plus_boundary_pending = nil
        end
    end)
    return true
end

return ViewerController
