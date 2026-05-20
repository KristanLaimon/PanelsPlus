--[[--
Smooth panel reading for manga and comics.

The plugin intentionally reuses KOReader's native kopt panel detector
(`document:getPanelFromPage`) and replaces the default single-panel ImageViewer
with a sequenced viewer.  This keeps detection quality aligned with KOReader
while adding reading-direction navigation and quick zoom/screenshot controls.
--]]--

local Dispatcher = require("dispatcher")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTINGS_KEY = "manga_smooth_reading"

local DEFAULT_SETTINGS = {
    enabled = true,
    mode = "manga", -- manga = top-to-bottom, right-to-left; comic = top-to-bottom, left-to-right
    panel_grid_cols = 4,
    panel_grid_rows = 7,
}

local function copyDefaults(settings)
    settings = settings or {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    return settings
end

local function rectKey(rect)
    return table.concat({
        math.floor(rect.x or 0),
        math.floor(rect.y or 0),
        math.floor(rect.w or 0),
        math.floor(rect.h or 0),
    }, ":")
end

local function rectCenter(rect)
    return (rect.x or 0) + (rect.w or 0) / 2, (rect.y or 0) + (rect.h or 0) / 2
end

local function rectContains(rect, pos)
    return pos.x >= rect.x and pos.x <= rect.x + rect.w
        and pos.y >= rect.y and pos.y <= rect.y + rect.h
end

local function sameRow(a, b)
    local ay = (a.y or 0) + (a.h or 0) / 2
    local by = (b.y or 0) + (b.h or 0) / 2
    return math.abs(ay - by) <= math.max(a.h or 0, b.h or 0) * 0.45
end

local PanelImageViewer = ImageViewer:extend{
    name = "manga_smooth_panel_viewer",
    reading_mode = "manga",
    buttons_visible = true,
    with_title_bar = false,
    fullscreen = true,
    images_keep_pan_and_zoom = false,
}

function PanelImageViewer:onSwipe(arg, ges)
    if self._images_list and (ges.direction == "west" or ges.direction == "east") then
        local next_direction = self.reading_mode == "comic" and "east" or "west"
        if ges.direction == next_direction then
            self:onShowNextImage()
        else
            self:onShowPrevImage()
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

function PanelImageViewer:init()
    ImageViewer.init(self)

    local buttons = {
        {
            {
                id = "zoom_out",
                text = "-",
                callback = function()
                    self:onZoomOut()
                end,
            },
            {
                id = "zoom_in",
                text = "+",
                callback = function()
                    self:onZoomIn()
                end,
            },
            {
                id = "screenshot",
                text = _("Screenshot"),
                callback = function()
                    self:onSaveImageView()
                end,
            },
        },
    }

    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")

    self.extra_button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
    self.extra_button_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.extra_button_table:getSize().h,
        },
        self.extra_button_table,
    }
    self:update()
end

function PanelImageViewer:update()
    ImageViewer.update(self)
    if self.buttons_visible and self.extra_button_container then
        table.insert(self.frame_elements, self.extra_button_container)
        self.frame_elements:resetLayout()
        self.img_container_h = self.height - self.frame_elements:getSize().h
        self:_clean_image_wg()
        self:_new_image_wg()
        for idx, widget in ipairs(self.frame_elements) do
            if widget == self.image_container then
                table.remove(self.frame_elements, idx)
                break
            end
        end
        local image_container_idx = self.with_title_bar and 2 or 1
        if self._images_list and self._images_list_nb > 1 then
            image_container_idx = image_container_idx + 1
        end
        table.insert(self.frame_elements, image_container_idx, self.image_container)
        self.frame_elements:resetLayout()
        UIManager:setDirty(self, function()
            return "ui", self.main_frame.dimen, true
        end)
    end
end

function PanelImageViewer:onCloseWidget()
    if self.extra_button_container then
        self.extra_button_container:free()
        self.extra_button_container = nil
    end
    ImageViewer.onCloseWidget(self)
end

local MangaSmoothReading = WidgetContainer:extend{
    name = "mangasmoothreading",
    is_doc_only = true,
}

function MangaSmoothReading:init()
    self.settings = copyDefaults(G_reader_settings:readSetting(SETTINGS_KEY))
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:patchNativePanelZoom()
    self:applyNativePanelSetting()
end

function MangaSmoothReading:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
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

function MangaSmoothReading:collectPanels(page, hold_pos)
    local document = self.ui.document
    local page_size = document:getPageDimensions(page, 1, 0)
    if not page_size then
        return {}
    end
    local cols = self.settings.panel_grid_cols or DEFAULT_SETTINGS.panel_grid_cols
    local rows = self.settings.panel_grid_rows or DEFAULT_SETTINGS.panel_grid_rows
    local panels_by_key = {}
    local panels = {}

    local function addPanel(pos)
        local ok, rect = pcall(document.getPanelFromPage, document, page, pos)
        if ok and rect and rect.w and rect.h and rect.w > 0 and rect.h > 0 then
            local key = rectKey(rect)
            if not panels_by_key[key] then
                panels_by_key[key] = true
                table.insert(panels, rect)
            end
        end
    end

    addPanel(hold_pos)
    for row = 1, rows do
        for col = 1, cols do
            addPanel({
                page = page,
                x = page_size.w * (col - 0.5) / cols,
                y = page_size.h * (row - 0.5) / rows,
            })
        end
    end

    table.sort(panels, function(a, b)
        if sameRow(a, b) then
            if self.settings.mode == "comic" then
                return a.x < b.x
            end
            return a.x > b.x
        end
        return a.y < b.y
    end)

    return panels
end

function MangaSmoothReading:getStartPanelIndex(panels, hold_pos)
    local best_idx, best_dist = 1, math.huge
    for idx, rect in ipairs(panels) do
        if rectContains(rect, hold_pos) then
            return idx
        end
        local cx, cy = rectCenter(rect)
        local dist = (cx - hold_pos.x) ^ 2 + (cy - hold_pos.y) ^ 2
        if dist < best_dist then
            best_idx, best_dist = idx, dist
        end
    end
    return best_idx
end

function MangaSmoothReading:buildPanelImages(page, panels)
    local document = self.ui.document
    local images = {
        image_disposable = true,
        free = function(list)
            for _, image in ipairs(list) do
                if type(image) ~= "function" and image.free then
                    image:free()
                end
            end
        end,
    }
    for _, rect in ipairs(panels) do
        table.insert(images, function()
            local image, rotate = document:drawPagePart(page, rect, 0)
            images.rotated = rotate
            return image
        end)
    end
    return images
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

    local images = self:buildPanelImages(hold_pos.page, panels)
    local start_idx = self:getStartPanelIndex(panels, hold_pos)
    local viewer = PanelImageViewer:new{
        image = images,
        image_disposable = true,
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
