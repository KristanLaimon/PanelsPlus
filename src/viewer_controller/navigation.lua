--[[
Panels+
File: src/viewer_controller/navigation.lua
Name: ViewerController
Description: Viewer orchestration: navigation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Device = require("device")
local Event = require("ui/event")
local SpreadRotation = require("src.spread_rotation")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

return function(ViewerController)
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

        hold_pos = self:mapPanelPosition(hold_pos)

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
        -- Restore the reader's rotation first if the screen was rotated for a
        -- spread, so the viewer is laid out for it.
        SpreadRotation.prepareSpreadRotationForViewer(self, page, panels)
        local images, image_rects, full_page_flags = PanelCollector.buildImages(self.ui, page, panels, self.settings)
        local viewer
        viewer = PanelViewer:new({
            image = images,
            image_disposable = true,
            images_list_nb = #images,
            initial_image_num = start_idx,
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
            profile_name_callback = function()
                return require("src.profile_menu").getSettingsProfileName(self)
            end,
            settings_profile_callback = function(current_viewer)
                return self:showSettingsProfileMenu(current_viewer)
            end,
            panel_finding_mode = self.settings.panel_finding_mode,
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
            prefer_native_text_layer = self.settings.prefer_native_text_layer ~= false,
            ocr_bundled_language = self:getSelectedOcrModel(),
            image_rotation = self.settings.image_rotation,
            auto_rotate_double_pages = self.settings.auto_rotate_double_pages ~= false,
            spread_rotation_direction = self.settings.spread_rotation_direction,
            nav_transition_mode = self.settings.nav_transition_mode or "classic",
            nav_smooth_style = self.settings.nav_smooth_style or Settings.defaults.nav_smooth_style,
            nav_animated_panels = self.settings.nav_animated_panels ~= false,
            nav_animated_pages = self.settings.nav_animated_pages ~= false,
            nav_transition_duration = self.settings.nav_transition_duration
                or Settings.defaults.nav_transition_duration,
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
            panel_finding_toggle_callback = function(current_viewer)
                return self:toggleViewerPanelFindingMode(current_viewer)
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
            nav_smooth_style_callback = function(current_viewer, style)
                self:setNavSmoothStyle(style)
                current_viewer.nav_smooth_style = self.settings.nav_smooth_style
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
            ocr_language_callback = function(current_viewer)
                return self:showOcrLanguageMenu(current_viewer)
            end,
            closed_callback = function(closed_viewer)
                self:cancelPanelPrerender()
                SpreadRotation.onPanelViewerClosed(self, closed_viewer)
            end,
        })
        -- Set before the replaced viewer closes, so its close is not treated as
        -- leaving the viewer.
        self.active_panel_viewer = viewer

        if options.replace_viewer then
            self:armPageTurnAnimation(options.boundary_direction, options.replace_viewer)
            UIManager:close(options.replace_viewer)
        end
        UIManager:show(viewer)
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
            return current_viewer:confirmDocumentBoundary(direction, self.ui)
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

    require("src.plugins-support.meguru").attach(ViewerController)
end
