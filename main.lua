--[[--
Smooth panel reading for manga and comics.

This plugin keeps KOReader's native panel detector and replaces the default
single-panel zoom viewer with a direction-aware sequence viewer.
--]]--

local Dispatcher = require("dispatcher")
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
    self:saveSettings()
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

function MangaSmoothReading:addToMainMenu(menu_items)
    menu_items.manga_smooth_reading = {
        text = _("Manga smooth reading"),
        sorting_hint = "more_tools",
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
                text = _("Gesture actions available"),
                enabled = false,
                help_text = _("Assign gestures to 'Manga smooth reading: toggle' or 'Manga smooth reading: manga/comic mode' from the gesture manager."),
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

    local panels = PanelCollector.collect(self.ui, self.settings, hold_pos.page, hold_pos)
    if #panels == 0 then
        return false
    end

    local images = PanelCollector.buildImages(self.ui, hold_pos.page, panels)
    local start_idx = PanelCollector.startIndex(panels, hold_pos)
    local viewer = PanelViewer:new{
        image = images,
        image_disposable = false,
        images_list_nb = #images,
        reading_mode = self.settings.mode,
        rotated = images.rotated,
    }

    UIManager:show(viewer)
    if start_idx > 1 then
        viewer:switchToImageNum(start_idx)
    end
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
