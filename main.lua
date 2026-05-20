--[[--
Smooth panel reading for manga and comics.

This plugin keeps KOReader's native panel detector and replaces the default
single-panel zoom viewer with a direction-aware sequence viewer.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PanelCollector = require("msr_panelcollector")
local PanelViewer = require("msr_panelviewer")
local Settings = require("msr_settings")
local _ = require("gettext")

local MangaSmoothReading = WidgetContainer:extend{
    name = "mangasmoothreading",
    is_doc_only = true,
}

function MangaSmoothReading:init()
    self.settings = Settings.load()
    self.panel_cache = {}
    self.panel_cache_loading = {}
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

function MangaSmoothReading:saveSettings()
    Settings.save(self.settings)
end

function MangaSmoothReading:isEnabled()
    return self.settings.enabled ~= false
end

function MangaSmoothReading:setEnabled(enabled)
    self.settings.enabled = enabled and true or false
    self:saveSettings()
    self:applyNativePanelSetting()
end

function MangaSmoothReading:setMode(mode)
    self.settings.mode = mode == "comic" and "comic" or "manga"
    self:clearPanelCache()
    self:saveSettings()
end

function MangaSmoothReading:setInvertSwipe(invert_swipe)
    self.settings.invert_swipe = invert_swipe and true or false
    self:saveSettings()
end

function MangaSmoothReading:clearPanelCache()
    self.panel_cache = {}
    self.panel_cache_loading = {}
end

function MangaSmoothReading:getPanelCacheKey(page)
    return tostring(page) .. ":" .. (self.settings.mode or "manga")
end

function MangaSmoothReading:getCachedPanels(page)
    return self.panel_cache[self:getPanelCacheKey(page)]
end

function MangaSmoothReading:cachePanels(page, panels)
    self.panel_cache[self:getPanelCacheKey(page)] = panels
end

function MangaSmoothReading:collectPanels(page, hold_pos)
    local panels = PanelCollector.collect(self.ui, self.settings, page, hold_pos)
    if #panels > 0 then
        self:cachePanels(page, panels)
    end
    return panels
end

function MangaSmoothReading:preloadPanels(page)
    if not page or page == 0 or self:getCachedPanels(page) then
        return
    end

    local key = self:getPanelCacheKey(page)
    if self.panel_cache_loading[key] then
        return
    end
    self.panel_cache_loading[key] = true

    UIManager:scheduleIn(0.25, function()
        self.panel_cache_loading[key] = nil
        if self:getCachedPanels(page) then
            return
        end
        self:collectPanels(page)
    end)
end

function MangaSmoothReading:preloadAdjacentPanels(page)
    self:preloadPanels(self.ui.document:getNextPage(page))
    self:preloadPanels(self.ui.document:getPrevPage(page))
end

function MangaSmoothReading:onDispatcherRegisterActions()
    Dispatcher:registerAction("manga_smooth_reading_toggle", {
        category = "none",
        event = "MangaSmoothReadingToggle",
        title = _("Manga smooth reading: toggle"),
        reader = true,
    })
    Dispatcher:registerAction("manga_smooth_reading_toggle_mode", {
        category = "none",
        event = "MangaSmoothReadingToggleMode",
        title = _("Manga smooth reading: manga/comic mode"),
        reader = true,
    })
    Dispatcher:registerAction("manga_smooth_reading_set_manga", {
        category = "none",
        event = "MangaSmoothReadingSetManga",
        title = _("Manga smooth reading: set manga mode"),
        reader = true,
    })
    Dispatcher:registerAction("manga_smooth_reading_set_comic", {
        category = "none",
        event = "MangaSmoothReadingSetComic",
        title = _("Manga smooth reading: set comic mode"),
        reader = true,
    })
end

function MangaSmoothReading:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight or highlight._manga_smooth_original_panel_zoom then
        return
    end

    highlight._manga_smooth_plugin = self
    highlight._manga_smooth_original_panel_zoom = highlight.onPanelZoom
    highlight.onPanelZoom = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._manga_smooth_plugin
        if plugin and plugin:isEnabled() then
            return plugin:showPanelSequence(reader_highlight, ges)
        end
        return reader_highlight:_manga_smooth_original_panel_zoom(arg, ges)
    end
end

function MangaSmoothReading:applyNativePanelSetting()
    if self.ui.highlight and self.ui.paging then
        self.ui.highlight.panel_zoom_enabled = self:isEnabled()
        self.ui.highlight.panel_zoom_fallback_to_text_selection = false
    end
end

function MangaSmoothReading:onMangaSmoothReadingToggle()
    self:setEnabled(not self:isEnabled())
    UIManager:show(InfoMessage:new{
        text = self:isEnabled() and _("Manga smooth reading enabled") or _("Manga smooth reading disabled"),
        timeout = 2,
    })
    return true
end

function MangaSmoothReading:onMangaSmoothReadingToggleMode()
    self:setMode(self.settings.mode == "manga" and "comic" or "manga")
    UIManager:show(InfoMessage:new{
        text = self.settings.mode == "manga" and _("Manga mode: right to left") or _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

function MangaSmoothReading:onMangaSmoothReadingSetManga()
    self:setMode("manga")
    UIManager:show(InfoMessage:new{
        text = _("Manga mode: right to left"),
        timeout = 2,
    })
    return true
end

function MangaSmoothReading:onMangaSmoothReadingSetComic()
    self:setMode("comic")
    UIManager:show(InfoMessage:new{
        text = _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

function MangaSmoothReading:getModeText()
    if self.settings.mode == "comic" then
        return _("Manga smooth reading: comic mode")
    end
    return _("Manga smooth reading: manga mode")
end

function MangaSmoothReading:addToMainMenu(menu_items)
    menu_items.manga_smooth_reading = {
        text_func = function()
            return self:getModeText()
        end,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable panel focus"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                end,
            },
            {
                text = _("Manga mode (right to left)"),
                checked_func = function()
                    return self.settings.mode == "manga"
                end,
                radio = true,
                callback = function()
                    self:setMode("manga")
                end,
            },
            {
                text = _("Comic mode (left to right)"),
                checked_func = function()
                    return self.settings.mode == "comic"
                end,
                radio = true,
                callback = function()
                    self:setMode("comic")
                end,
            },
            {
                text = _("Invert panel swipe direction"),
                checked_func = function()
                    return self.settings.invert_swipe == true
                end,
                callback = function()
                    self:setInvertSwipe(not self.settings.invert_swipe)
                end,
                help_text = _("Use this if panel navigation feels reversed on your device. It changes swipe direction only, not panel order."),
            },
            {
                text = _("Gesture actions"),
                enabled = false,
                help_text = _("Assign gestures to the Manga smooth reading actions from the gesture manager. Available actions: toggle, toggle manga/comic mode, set manga mode, set comic mode."),
            },
        },
    }
end

function MangaSmoothReading:showPanelSequence(reader_highlight, ges)
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

function MangaSmoothReading:showPanelViewerForPage(page, panels, start_idx)
    local images = PanelCollector.buildImages(self.ui, page, panels)
    local viewer
    viewer = PanelViewer:new{
        image = images,
        image_disposable = false,
        images_list_nb = #images,
        page = page,
        reading_mode = self.settings.mode,
        invert_swipe = self.settings.invert_swipe == true,
        rotated = images.rotated,
        boundary_callback = function(direction, current_viewer)
            return self:onPanelViewerBoundary(direction, current_viewer)
        end,
    }

    UIManager:show(viewer)
    if start_idx and start_idx > 1 then
        viewer:switchToImageNum(start_idx)
    end
    self:preloadAdjacentPanels(page)
    return true
end

function MangaSmoothReading:onPanelViewerBoundary(direction, current_viewer)
    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    if not next_page or next_page == 0 then
        return true
    end

    self.ui:handleEvent(Event:new("GotoPage", next_page))
    UIManager:close(current_viewer)
    local panels = self:getCachedPanels(next_page)
    if panels and #panels > 0 then
        local start_idx = direction == "next" and 1 or #panels
        return self:showPanelViewerForPage(next_page, panels, start_idx)
    end

    UIManager:tickAfterNext(function()
        local loaded_panels = self:collectPanels(next_page)
        if #loaded_panels > 0 then
            local start_idx = direction == "next" and 1 or #loaded_panels
            self:showPanelViewerForPage(next_page, loaded_panels, start_idx)
        end
    end)
    return true
end

function MangaSmoothReading:onSaveSettings()
    self:saveSettings()
end

function MangaSmoothReading:onCloseWidget()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight._manga_smooth_original_panel_zoom then
        highlight.onPanelZoom = highlight._manga_smooth_original_panel_zoom
        highlight._manga_smooth_original_panel_zoom = nil
        highlight._manga_smooth_plugin = nil
    end
end

return MangaSmoothReading
