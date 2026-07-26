local Event = require("ui/event")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local util = require("util")

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
--- `util.calcFreeMem()` reports **bytes**, already discounted to 85% of
--- MemAvailable, despite parsing `/proc/meminfo`'s kB fields.
---
--- @return boolean allowed Whether prerendering should proceed.
function ViewerController:hasMemoryForPrerender()
    local ok, free_bytes = pcall(util.calcFreeMem)
    if not ok or not free_bytes then
        -- /proc/meminfo is Linux-only; elsewhere assume there is headroom.
        return true
    end
    local minimum = self.settings.prerender_min_free_bytes
        or Settings.defaults.prerender_min_free_bytes
    local allowed = free_bytes >= minimum
    if not allowed then
        Timing.log(string.format(
            "prerender skipped: low memory (free=%dMB min=%dMB)",
            math.floor(free_bytes / (1024 * 1024)),
            math.floor(minimum / (1024 * 1024))
        ))
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
local CROP_MODE_CYCLE = { strict = "loose", loose = "margin", margin = "strict" }

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

    local start_idx = viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, viewer.panels, start_idx, { buttons_visible = true })
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
        return false
    end

    local start_idx = PanelCollector.startIndex(panels, hold_pos)
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
        detector = self:getDetector(),
        invert_swipe = self.settings.invert_swipe == true,
        progress_bar_visible = self.settings.progress_bar_visible ~= false,
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
        progress_bar_toggle_callback = function(current_viewer)
            return self:toggleViewerProgressBar(current_viewer)
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
    if not next_page or next_page == 0 then
        current_viewer._panels_plus_boundary_pending = nil
        return true
    end

    local cached_panels = self:getCachedPanels(next_page)
    if cached_panels then
        if #cached_panels > 0 then
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            UIManager:close(current_viewer)
            local start_idx = direction == "next" and 1 or #cached_panels
            return self:showPanelViewerForPage(next_page, cached_panels, start_idx)
        end
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
