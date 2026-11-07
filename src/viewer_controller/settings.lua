--[[
Panels+
File: src/viewer_controller/settings.lua
Name: ViewerController
Description: Viewer orchestration: settings.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Event = require("ui/event")
local Device = require("device")
local DoubleSpread = require("src._doublespread")
local PanelCollector = require("src._panelcollector")
local NavCapabilities = require("src._navcapabilities")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

return function(ViewerController)
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

    --- Change panel finding mode and reopen this page at the nearest new panel.
    function ViewerController:toggleViewerPanelFindingMode(viewer)
        local page = viewer.page
        local current = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
        local center = current
            and {
                x = current.x + current.w / 2,
                y = current.y + current.h / 2,
            }
        self:setPanelFindingMode(self.settings.panel_finding_mode == "smart" and "safe" or "smart")
        -- Close first: the displayed crop, scaled ImageWidget copy, and pending
        -- crops otherwise stay resident throughout the new page detection.
        UIManager:close(viewer)
        local panels = self:collectPanels(page)
        local start_idx = center and PanelCollector.startIndex(panels, center) or 1
        return self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = true })
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
        if self.settings.selected_profile_id then
            self.settings.selected_profile_id = nil
            self:saveSettings()
            self:saveDocSettings(true)
        end
        if viewer.embedded_source_image then
            return require("src.embedded_image").setDeviceRotation(self, viewer, mode)
        end
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
    --- Usually the viewer applies the angle in place. A full spread needs a
    --- rebuild so automatic rotation gets a source render at its proper fit size;
    --- No crop also needs to swap between the source and padded canvas.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @param value number|boolean|nil New image rotation (`nil` restores Auto).
    --- @return boolean|string handled `"reopened"` when a new viewer replaced this one.
    function ViewerController:setViewerImageRotation(viewer, value)
        self:setImageRotation(value)
        local index = viewer._images_list_cur or 1
        if
            DoubleSpread.shouldRotate(
                viewer.panels and viewer.panels[index],
                viewer.panel_is_full_page and viewer.panel_is_full_page[index],
                viewer.panels and #viewer.panels == 1
            )
        then
            local page, panels = viewer.page, viewer.panels
            local buttons_visible = viewer.buttons_visible
            UIManager:close(viewer)
            self:showPanelViewerForPage(page, panels, index, { buttons_visible = buttons_visible })
            return "reopened"
        end
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

    ---
    --- Unlike crop mode or detector, this doesn't change the panel list or any
    --- rendered rectangle, so the viewer is updated in place instead of rebuilt.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @return boolean handled Always true for viewer callback dispatch.
    function ViewerController:toggleViewerNavTransitionMode(viewer)
        self:setNavTransitionMode(NavCapabilities.nextMode(self.settings.nav_transition_mode))
        viewer.nav_transition_mode = self.settings.nav_transition_mode
        viewer:replaceButtonTable()
        viewer:update()
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
        return self:showAdvancedOptions(viewer, "animation")
    end

    --- Preview the edited Smooth settings, returning to the same panel and menu.
    function ViewerController:previewSmoothSettings(viewer, menu_page, skip_preview)
        if
            not viewer
            or viewer.nav_transition_mode ~= "smooth"
            or not viewer.animateSwitchToImageNum
            or viewer._panels_plus_smooth_preview
            or viewer._panels_plus_transition_active
            or viewer._panels_plus_boundary_pending
            or viewer._panels_plus_closed
        then
            return false
        end
        viewer._panels_plus_smooth_preview = true
        local origin = viewer._images_list_cur
        local controls
        local function live()
            return not viewer._panels_plus_closed and viewer:isOpen()
        end
        local function hideControls()
            controls = {
                buttons_visible = viewer.buttons_visible,
                with_title_bar = viewer.with_title_bar,
                fullscreen = viewer.fullscreen,
                progress_bar_visible = viewer.progress_bar_visible,
            }
            viewer.buttons_visible = false
            viewer.with_title_bar = false
            viewer.fullscreen = true
            viewer.progress_bar_visible = false
            viewer:update()
        end
        local function reopen()
            viewer._panels_plus_smooth_preview = nil
            if live() then
                if controls then
                    viewer.buttons_visible = controls.buttons_visible
                    viewer.with_title_bar = controls.with_title_bar
                    viewer.fullscreen = controls.fullscreen
                    viewer.progress_bar_visible = controls.progress_bar_visible
                    viewer:update()
                end
                self:showAdvancedOptions(viewer, "animation", menu_page)
            end
        end
        -- Setting callbacks run before KOReader dismisses their menu/spinner.
        -- Start on the next tick so trailing close handlers cannot dismiss the
        -- preview or the settings menu that will replace it.
        UIManager:nextTick(function()
            if not live() then
                viewer._panels_plus_smooth_preview = nil
                return
            end
            local reader_menu = self.ui and self.ui.menu
            local container = reader_menu and reader_menu.menu_container
            if container then
                container[1].close_callback()
            end
            local count = viewer._images_list_nb or #(viewer.image_rects or {})
            if skip_preview or self.settings.nav_smooth_preview == false or not origin then
                return reopen()
            end
            if count < 2 then
                local document = self.ui and self.ui.document
                local single_panel_book = false
                if not viewer.embedded_source_image and document and document.getNextPage and document.getPrevPage then
                    local next_page = document:getNextPage(viewer.page)
                    local previous_page = document:getPrevPage(viewer.page)
                    next_page = next_page ~= 0 and next_page or nil
                    previous_page = previous_page ~= 0 and previous_page or nil
                    single_panel_book = not next_page and not previous_page
                    local adjacent_page = next_page or previous_page
                    if adjacent_page and viewer.nav_boundary_peek_callback then
                        -- A one-panel page is not a one-panel book. Warm the
                        -- adjacent layout and preview its canvas without turning
                        -- the document page or replacing the original viewer.
                        self:collectPanels(adjacent_page)
                        hideControls()
                        viewer:animateBoundaryTransition(next_page and "next" or "previous", function(played)
                            UIManager:nextTick(function()
                                reopen()
                                if not played and live() then
                                    viewer:showSmoothPreviewUnavailableWarning()
                                end
                            end)
                        end)
                        return
                    end
                end
                reopen()
                return viewer:showSmoothPreviewUnavailableWarning(single_panel_book)
            end
            -- At the end, preview backward first; always return to the original
            -- panel without leaving the document or opening boundary prompts.
            local target = origin < count and origin + 1 or origin - 1
            hideControls()
            viewer:animateSwitchToImageNum(target, function()
                -- Let the landing panel remain visible before reversing.
                UIManager:scheduleIn(0.15, function()
                    if not live() then
                        viewer._panels_plus_smooth_preview = nil
                        return
                    end
                    viewer:animateSwitchToImageNum(origin, function()
                        UIManager:nextTick(reopen)
                    end)
                end)
            end)
        end)
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

    --- Rebuild an open viewer at the same panel after a spread option changed.
    ---
    --- The options change how images are rendered (rotated size, fold strip) and which rotation the
    --- screen is in, so the viewer is rebuilt like `toggleViewerCropMode` does. An embedded image
    --- viewer has its own rebuild path and is kept.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @return PanelViewer viewer The viewer now on screen.
    function ViewerController:rebuildViewerForSpreadOptions(viewer)
        local panels = viewer.panels
        if viewer.embedded_source_image or not panels or #panels == 0 then
            return viewer
        end
        local page, index = viewer.page, viewer._images_list_cur or 1
        UIManager:close(viewer)
        return self:showPanelViewerForPage(page, panels, index, { buttons_visible = true, return_viewer = true })
    end

    local SPREAD_ROTATION_CYCLE = { off = "viewer", viewer = "reading", reading = "both", both = "off" }

    --- Step the spread rotation choice from an open viewer.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @return PanelViewer viewer The viewer now on screen.
    function ViewerController:cycleViewerSpreadRotationMode(viewer)
        self:setSpreadRotationMode(SPREAD_ROTATION_CYCLE[DoubleSpread.rotationMode(self.settings)] or "viewer")
        viewer.auto_rotate_double_pages = self.settings.auto_rotate_double_pages ~= false
        return self:rebuildViewerForSpreadOptions(viewer)
    end

    --- Toggle `join_spread_fold` from an open viewer.
    ---
    --- @param viewer PanelViewer Active panel viewer instance.
    --- @return PanelViewer viewer The viewer now on screen.
    function ViewerController:toggleViewerJoinSpreadFold(viewer)
        self:setJoinSpreadFold(self.settings.join_spread_fold == false)
        return self:rebuildViewerForSpreadOptions(viewer)
    end
end
