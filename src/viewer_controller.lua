local Event = require("ui/event")
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
    local minimum = self.settings.prerender_min_free_bytes
        or Settings.defaults.prerender_min_free_bytes
    local allowed = Memory.hasHeadroom(minimum)
    if not allowed then
        local free_bytes = Memory.freeBytes()
        Timing.log("prerender skipped: low memory (free=%dMB min=%dMB)",
            math.floor((free_bytes or 0) / (1024 * 1024)),
            math.floor(minimum / (1024 * 1024)))
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
    self:setMode(self.settings.mode == "manga" and "comic" or "manga")
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

--- Cycle Auto -> Gutter -> Outline from an open viewer and re-detect the page.
---
--- Changing detector changes the panel list, so the viewer is rebuilt. The
--- panel being read is kept by matching its centre against the new list, which
--- is the same trick the reading-order toggle uses.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:cycleViewerDetector(viewer)
    local order = { auto = "fast", fast = "exact", exact = "auto" }
    local next_detector = order[self:getDetector()] or "fast"
    Timing.memory("detector cycle -> " .. next_detector)
    self:setDetector(next_detector)

    local current_rect = viewer.panels and viewer.panels[viewer._images_list_cur]
    local panels = self:collectPanels(viewer.page)
    if #panels == 0 then
        viewer.detector = self.settings.detector
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local start_idx = 1
    if current_rect then
        start_idx = PanelCollector.startIndex(panels, {
            x = (current_rect.x or 0) + (current_rect.w or 0) / 2,
            y = (current_rect.y or 0) + (current_rect.h or 0) / 2,
        })
    end

    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
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
---
--- Unlike crop mode or detector, this doesn't change the panel list or any
--- rendered rectangle, so the viewer is updated in place instead of rebuilt.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerNavTransitionMode(viewer)
    self:setNavTransitionMode(self.settings.nav_transition_mode == "smooth" and "classic" or "smooth")
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
    local Menu = require("ui/widget/menu")
    local _ = require("gettext")
    local controller = self
    local menu

    local menu_items = {
        {
            text = _("Pan animation duration..."),
            callback = function()
                viewer:onAdjustNavTransitionDuration()
            end,
            help_text = _("Adjust how long the camera pan between panels takes in milliseconds."),
        },
        {
            text = _("Animate page-to-page transitions (Actual: ")
                .. (controller.settings.nav_transition_cross_page == true and _("true") or _("false")) .. ")",
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
            help_text = _("Also pan across the boundary between the last panel of a page and the first panel of the next, instead of cutting instantly. Only animates when the adjacent page has already been detected in the background; otherwise the crossing stays an instant cut."),
        },
        {
            text = _("Transition frames (Actual: ")
                .. tostring(controller.settings.nav_transition_frames or Settings.defaults.nav_transition_frames) .. _(" fps)"),
            callback = function()
                viewer:onAdjustNavTransitionFrames(function()
                    -- Rebuild the menu so the "(Actual: ...)" label in the
                    -- text reflects the new value immediately.
                    UIManager:close(menu)
                    controller:showNavTransitionOptionsMenu(viewer)
                end)
            end,
            help_text = _("How many discrete steps the smooth camera pan between panels is split into. More frames look smoother but schedule more work per transition."),
        },
    }

    menu = Menu:new{
        title = _("Navigation Transition Settings"),
        item_table = menu_items,
    }
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
    Timing.log("showPanelViewerForPage: page=%d panels=%d start_idx=%d crop_mode=%s transition_mode=%s", page, #panels, start_idx or 1, tostring(self.settings.crop_mode), tostring(self.settings.nav_transition_mode))
    Timing.memory("show_panel_viewer")
    local images, image_rects, full_page_flags = PanelCollector.buildImages(self.ui, page, panels, self.settings)
    local viewer
    viewer = PanelViewer:new{
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
        detector = self:getDetector(),
        invert_swipe = self.settings.invert_swipe == true,
        progress_bar_visible = self.settings.progress_bar_visible ~= false,
        nav_transition_mode = self.settings.nav_transition_mode or "classic",
        nav_transition_duration = self.settings.nav_transition_duration or Settings.defaults.nav_transition_duration,
        nav_transition_cross_page = self.settings.nav_transition_cross_page == true,
        nav_transition_frames = self.settings.nav_transition_frames or Settings.defaults.nav_transition_frames,
        buttons_visible = options.buttons_visible == true,
        rotated = images.rotated,
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
        nav_transition_options_callback = function(current_viewer)
            return self:showNavTransitionOptionsMenu(current_viewer)
        end,
        nav_boundary_peek_callback = function(direction, current_viewer)
            return self:resolveBoundaryTarget(direction, current_viewer)
        end,
        nav_boundary_commit_callback = function(current_viewer, direction, resolved)
            return self:commitBoundaryTransition(direction, current_viewer, resolved)
        end,
        detector_cycle_callback = function(current_viewer)
            return self:cycleViewerDetector(current_viewer)
        end,
    }

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
    if not cached_panels or #cached_panels == 0 then
        return nil
    end

    local start_idx = direction == "next" and 1 or #cached_panels
    local next_images, image_rects = PanelCollector.buildImages(self.ui, next_page, cached_panels, self.settings)
    return {
        next_page = next_page,
        panels = cached_panels,
        start_idx = start_idx,
        target_rect = image_rects[start_idx],
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
    Timing.log("commitBoundaryTransition: direction=%s page=%d -> %d target_panel=%d", direction, current_viewer and current_viewer.page or -1, resolved.next_page, resolved.start_idx)
    self.ui:handleEvent(Event:new("GotoPage", resolved.next_page))
    UIManager:close(current_viewer)
    return self:showPanelViewerForPage(resolved.next_page, resolved.panels, resolved.start_idx)
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
    Timing.log("onPanelViewerBoundary: direction=%s page=%d next_page=%s", direction, current_viewer and current_viewer.page or -1, tostring(next_page))
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
        -- cached, but empty: nothing detected on the adjacent page.
        current_viewer:onClose()
        self.ui:handleEvent(Event:new("GotoPage", next_page))
        self:preloadNextPanels(next_page)
        return true
    end

    UIManager:tickAfterNext(function()
        if current_viewer._panels_plus_closed then
            return
        end
        local loaded_panels = self:collectPanels(next_page)
        if #loaded_panels > 0 then
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            UIManager:close(current_viewer)
            local start_idx = direction == "next" and 1 or #loaded_panels
            self:showPanelViewerForPage(next_page, loaded_panels, start_idx)
        else
            current_viewer:onClose()
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            self:preloadNextPanels(next_page)
        end
    end)
    return true
end

return ViewerController
