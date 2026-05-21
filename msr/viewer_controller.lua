local Event = require("ui/event")
local PanelCollector = require("msr_panelcollector")
local PanelViewer = require("msr_panelviewer")
local UIManager = require("ui/uimanager")

--- Panel viewer orchestration methods mixed into `MangaComicSmoother`.
---
--- @class MCSViewerControllerMethods
local ViewerController = {}

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

--- Toggle crop mode from an open viewer and reopen at the same image index.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerCropMode(viewer)
    self:setCropMode(self.settings.crop_mode == "loose" and "strict" or "loose")
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
--- @param panels MCSPanel[] Ordered panel rectangles.
--- @param start_idx number|nil 1-based panel index to display first.
--- @param options MCSShowViewerOptions|nil Viewer behavior flags.
--- @return boolean|PanelViewer result `true` by default, or viewer when requested.
function ViewerController:showPanelViewerForPage(page, panels, start_idx, options)
    options = options or {}
    local images = PanelCollector.buildImages(self.ui, page, panels, self.settings)
    local viewer
    viewer = PanelViewer:new{
        image = images,
        image_disposable = false,
        images_list_nb = #images,
        page = page,
        panels = panels,
        reading_mode = self.settings.mode,
        crop_mode = self.settings.crop_mode,
        invert_swipe = self.settings.invert_swipe == true,
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
--- @param direction MCSBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:onPanelViewerBoundary(direction, current_viewer)
    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    if not next_page or next_page == 0 then
        return true
    end

    local panels = self:getCachedPanels(next_page)
    if panels and #panels > 0 then
        self.ui:handleEvent(Event:new("GotoPage", next_page))
        UIManager:close(current_viewer)
        local start_idx = direction == "next" and 1 or #panels
        return self:showPanelViewerForPage(next_page, panels, start_idx)
    end

    UIManager:tickAfterNext(function()
        local loaded_panels = self:collectPanels(next_page)
        if #loaded_panels > 0 then
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            UIManager:close(current_viewer)
            local start_idx = direction == "next" and 1 or #loaded_panels
            self:showPanelViewerForPage(next_page, loaded_panels, start_idx)
        else
            current_viewer:onClose()
            self.ui:handleEvent(Event:new("GotoPage", next_page))
        end
    end)
    return true
end

return ViewerController
