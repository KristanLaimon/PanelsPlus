--[[--
Manga/Comic Smoother.

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

local MangaComicSmoother = WidgetContainer:extend{
    name = "mangacomicsmoother",
    is_doc_only = true,
}

function MangaComicSmoother:init()
    self.settings = Settings.load()
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_cache_loading = {}
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

function MangaComicSmoother:saveSettings()
    Settings.save(self.settings)
end

function MangaComicSmoother:isEnabled()
    return self.settings.enabled ~= false
end

function MangaComicSmoother:setEnabled(enabled)
    self.settings.enabled = enabled and true or false
    self:saveSettings()
    self:applyNativePanelSetting()
end

function MangaComicSmoother:setMode(mode)
    self.settings.mode = mode == "comic" and "comic" or "manga"
    self:clearPanelCache()
    self:saveSettings()
end

function MangaComicSmoother:setCropMode(crop_mode)
    self.settings.crop_mode = crop_mode == "loose" and "loose" or "strict"
    self:saveSettings()
end

function MangaComicSmoother:setInvertSwipe(invert_swipe)
    self.settings.invert_swipe = invert_swipe and true or false
    self:saveSettings()
end

function MangaComicSmoother:clearPanelCache()
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_cache_loading = {}
end

function MangaComicSmoother:getPanelCacheKey(page)
    return tostring(page) .. ":" .. (self.settings.mode or "manga")
end

function MangaComicSmoother:getCachedPanels(page)
    return self.panel_cache[self:getPanelCacheKey(page)]
end

function MangaComicSmoother:cachePanels(page, panels)
    local key = self:getPanelCacheKey(page)
    self.panel_cache[key] = panels

    for idx = #self.panel_cache_order, 1, -1 do
        if self.panel_cache_order[idx] == key then
            table.remove(self.panel_cache_order, idx)
            break
        end
    end
    table.insert(self.panel_cache_order, key)

    local max_pages = self.settings.panel_cache_pages or Settings.defaults.panel_cache_pages
    while #self.panel_cache_order > max_pages do
        local stale_key = table.remove(self.panel_cache_order, 1)
        self.panel_cache[stale_key] = nil
    end
end

function MangaComicSmoother:collectPanels(page, hold_pos)
    local cached_panels = self:getCachedPanels(page)
    if cached_panels and (not hold_pos or #cached_panels > 0) then
        return cached_panels
    end

    local panels = PanelCollector.collect(self.ui, self.settings, page, hold_pos)
    if #panels > 0 then
        self:cachePanels(page, panels)
    end
    return panels
end

function MangaComicSmoother:preloadPanels(page)
    if not page or page == 0 then
        return
    end

    local cached_panels = self:getCachedPanels(page)
    if cached_panels then
        return
    end

    local key = self:getPanelCacheKey(page)
    if self.panel_cache_loading[key] then
        return
    end
    self.panel_cache_loading[key] = true

    local delay = self.settings.panel_prefetch_delay or Settings.defaults.panel_prefetch_delay
    UIManager:scheduleIn(delay, function()
        self.panel_cache_loading[key] = nil
        local scheduled_cached_panels = self:getCachedPanels(page)
        if scheduled_cached_panels then
            return
        end
        self:collectPanels(page)
    end)
end

function MangaComicSmoother:preloadNextPanels(page)
    self:preloadPanels(self.ui.document:getNextPage(page))
end

function MangaComicSmoother:toggleViewerMode(viewer)
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

    local start_idx = 1
    start_idx = PanelCollector.startIndex(panels, {
        x = (current_rect.x or 0) + (current_rect.w or 0) / 2,
        y = (current_rect.y or 0) + (current_rect.h or 0) / 2,
    })

    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

function MangaComicSmoother:toggleViewerCropMode(viewer)
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

function MangaComicSmoother:onDispatcherRegisterActions()
    Dispatcher:registerAction("mangacomicsmoother_toggle", {
        category = "none",
        event = "MangaComicSmootherToggle",
        title = _("Manga/Comic Smoother: toggle"),
        reader = true,
    })
    Dispatcher:registerAction("mangacomicsmoother_toggle_mode", {
        category = "none",
        event = "MangaComicSmootherToggleMode",
        title = _("Manga/Comic Smoother: manga/comic mode"),
        reader = true,
    })
    Dispatcher:registerAction("mangacomicsmoother_set_manga", {
        category = "none",
        event = "MangaComicSmootherSetManga",
        title = _("Manga/Comic Smoother: set manga mode"),
        reader = true,
    })
    Dispatcher:registerAction("mangacomicsmoother_set_comic", {
        category = "none",
        event = "MangaComicSmootherSetComic",
        title = _("Manga/Comic Smoother: set comic mode"),
        reader = true,
    })
end

function MangaComicSmoother:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight or highlight._mangacomicsmoother_original_panel_zoom then
        return
    end

    highlight._mangacomicsmoother_plugin = self
    highlight._mangacomicsmoother_original_panel_zoom = highlight.onPanelZoom
    highlight.onPanelZoom = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._mangacomicsmoother_plugin
        if plugin and plugin:isEnabled() then
            return plugin:showPanelSequence(reader_highlight, ges)
        end
        return reader_highlight:_mangacomicsmoother_original_panel_zoom(arg, ges)
    end
end

function MangaComicSmoother:applyNativePanelSetting()
    if self.ui.highlight and self.ui.paging then
        self.ui.highlight.panel_zoom_enabled = self:isEnabled()
        self.ui.highlight.panel_zoom_fallback_to_text_selection = false
    end
end

function MangaComicSmoother:onMangaComicSmootherToggle()
    self:setEnabled(not self:isEnabled())
    UIManager:show(InfoMessage:new{
        text = self:isEnabled() and _("Manga/Comic Smoother enabled") or _("Manga/Comic Smoother disabled"),
        timeout = 2,
    })
    return true
end

function MangaComicSmoother:onMangaComicSmootherToggleMode()
    self:setMode(self.settings.mode == "manga" and "comic" or "manga")
    UIManager:show(InfoMessage:new{
        text = self.settings.mode == "manga" and _("Manga mode: right to left") or _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

function MangaComicSmoother:onMangaComicSmootherSetManga()
    self:setMode("manga")
    UIManager:show(InfoMessage:new{
        text = _("Manga mode: right to left"),
        timeout = 2,
    })
    return true
end

function MangaComicSmoother:onMangaComicSmootherSetComic()
    self:setMode("comic")
    UIManager:show(InfoMessage:new{
        text = _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

function MangaComicSmoother:getModeText()
    if self.settings.mode == "comic" then
        return _("Manga/Comic Smoother: comic mode")
    end
    return _("Manga/Comic Smoother: manga mode")
end

function MangaComicSmoother:addToMainMenu(menu_items)
    menu_items.mangacomicsmoother = {
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
                help_text = _("Assign gestures to the Manga/Comic Smoother actions from the gesture manager. Available actions: toggle, toggle manga/comic mode, set manga mode, set comic mode."),
            },
        },
    }
end

function MangaComicSmoother:showPanelSequence(reader_highlight, ges)
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

function MangaComicSmoother:showPanelViewerForPage(page, panels, start_idx, options)
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

function MangaComicSmoother:onPanelViewerBoundary(direction, current_viewer)
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

function MangaComicSmoother:onSaveSettings()
    self:saveSettings()
end

function MangaComicSmoother:onCloseWidget()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight._mangacomicsmoother_original_panel_zoom then
        highlight.onPanelZoom = highlight._mangacomicsmoother_original_panel_zoom
        highlight._mangacomicsmoother_original_panel_zoom = nil
        highlight._mangacomicsmoother_plugin = nil
    end
end

return MangaComicSmoother
