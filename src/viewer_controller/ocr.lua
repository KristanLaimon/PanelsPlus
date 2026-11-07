--[[
Panels+
File: src/viewer_controller/ocr.lua
Name: ViewerController
Description: Viewer orchestration: ocr.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Device = require("device")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local WordFinder = require("src._wordfinder")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

return function(ViewerController)
    --- Resolve a saved OCR choice against models currently installed on this device.
    local function selectedOcrModel(settings, document)
        local choice = settings.ocr_bundled_language
        -- Older settings used "koreader" to mean the document's OCR language.
        if choice == "koreader" then
            local language = document and document.configurable and document.configurable.doc_language
            choice = language and ("user:" .. language) or nil
        end
        local bundled = WordFinder.availableBundledLanguages()
        for _, language in ipairs(bundled) do
            if choice == language then
                return choice
            end
        end
        local installed = WordFinder.availableUserLanguages()
        for _, language in ipairs(installed) do
            if choice == "user:" .. language then
                return choice
            end
        end
        if #bundled > 0 then
            return bundled[1]
        end
        return installed[1] and ("user:" .. installed[1]) or false
    end

    function ViewerController:getSelectedOcrModel()
        return selectedOcrModel(self.settings, self.ui and self.ui.document)
    end

    function ViewerController:setBundledOcrLanguage(viewer, language)
        if language ~= "koreader" and not WordFinder.selectedModel(language) then
            return
        end
        local previous = self:getSelectedOcrModel()
        if previous and previous ~= language then
            if previous:match("^user:") then
                self.settings.ocr_preferred_user_language = previous
            else
                self.settings.ocr_preferred_bundled_language = previous
            end
        end
        self.settings.ocr_bundled_language = language
        if language:match("^user:") then
            self.settings.ocr_preferred_user_language = language
        elseif language ~= "koreader" then
            self.settings.ocr_preferred_bundled_language = language
        end
        if viewer then
            viewer.ocr_bundled_language = self:getSelectedOcrModel()
        end
        self:saveSettings()
        if self.saveDocSettings then
            self:saveDocSettings(true)
        end
    end

    --- Show all installed OCR models in a scrollable KOReader menu over the viewer.
    function ViewerController:showOcrLanguageMenu(viewer)
        local Menu = require("ui/widget/menu")
        local _ = require("gettext")
        local labels = { eng = _("English"), spa = _("Spanish") }
        local items = {}
        local menu
        local container
        local active = self:getSelectedOcrModel()
        local active_index
        local bundled = WordFinder.availableBundledLanguages()
        local installed = WordFinder.availableUserLanguages()

        local function addChoice(id, label)
            local is_selected = active == id
            items[#items + 1] = {
                text = (is_selected and "◉ " or "○ ") .. label,
                bold = is_selected,
                mandatory = active == id and _("In use") or nil,
                callback = function()
                    self:setBundledOcrLanguage(viewer, id)
                    menu.close_callback = nil
                    UIManager:close(container)
                    self:showOcrLanguageMenu(viewer)
                end,
            }
            if active == id then
                active_index = #items
            end
        end

        if #bundled > 0 then
            items[#items + 1] = {
                text = _("Panels+ Fine-Tuned"),
                bold = true,
                select_enabled = false,
            }
            for _, language in ipairs(bundled) do
                addChoice(language, labels[language] or language)
            end
        end

        if #installed > 0 then
            items[#items + 1] = {
                text = _("KOReader User Installed"),
                bold = true,
                select_enabled = false,
                separator = #bundled > 0,
            }
            local ok, iso_language = pcall(require, "ui/data/isolanguage")
            for _, language in ipairs(installed) do
                local name = ok and iso_language:getLocalizedLanguage(language) or nil
                addChoice("user:" .. language, name and (name .. " (" .. language .. ")") or language)
            end
        end

        if #bundled == 0 and #installed == 0 then
            items[#items + 1] = {
                text = "",
                select_enabled = false,
            }
            items[#items + 1] = {
                text = _("Install Panels+ with OCR bundled, or install your own OCR models in /koreader/data/tessdata"),
                select_enabled = false,
            }
        end
        items[#items + 1] = {
            text = _("Close"),
            separator = true,
            callback = function()
                menu.close_callback = nil
                UIManager:close(container)
            end,
        }
        items.current = active_index
        local screen_width, screen_height = Screen:getWidth(), Screen:getHeight()
        container = CenterContainer:new({ dimen = Geom:new({ w = screen_width, h = screen_height }) })
        menu = Menu:new({
            title = _("Select OCR Model"),
            item_table = items,
            width = math.min(math.floor(screen_width * 0.88), math.floor(screen_height * 0.9)),
            height = math.floor(screen_height * 0.82),
            items_per_page = math.min(8, #items),
            show_parent = container,
        })
        menu.close_callback = function()
            UIManager:close(container)
        end
        container[1] = menu
        UIManager:show(container)
        return true
    end
end
