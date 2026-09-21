--[[
Panels+
File: src/menu.lua
Name: Menu
Description: Builds the Panels+ main-menu entries and reports the active detector namespace.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local _ = require("gettext")

--- Main-menu methods mixed into `PanelsPlus`.
---
--- @class PPMenuMethods
local Menu = {}

--- Return the active component detector and cache namespace.
---
--- @return PPDetector detector Current detector selection.
function Menu:getDetector()
    return "components"
end

--- Return the spread rotation choice shown in the menus (see `DoubleSpread.rotationMode`).
---
--- @return string mode `"off"`, `"viewer"`, `"reading"` or `"both"`.
function Menu:getSpreadRotationMode()
    return DoubleSpread.rotationMode(self.settings)
end

--- Return the main-menu label for the current reading mode.
---
--- @return string text Localized menu label.
function Menu:getModeText()
    if self.settings.mode == "comic" then
        return _("Panels+: comic mode")
    end
    return _("Panels+: manga mode")
end

--- Add the plugin's submenu to KOReader's main menu.
---
--- @param menu_items table<string, table> Mutable KOReader menu item table.
function Menu:addToMainMenu(menu_items)
    menu_items.panels_plus = {
        text_func = function()
            return self:getModeText()
        end,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Disable plugin panel focusing"),
                checked_func = function()
                    return not self:isEnabled()
                end,
                callback = function()
                    self:setEnabled(not self:isEnabled())
                end,
                help_text = _("Use KOReader's native panel zoom instead of the Panels+ panel sequence viewer."),
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
                separator = true,
            },
            {
                text = _("Open panels with"),
                sub_item_table = {
                    {
                        text = _("Long press"),
                        checked_func = function()
                            return self.settings.panel_gesture ~= "two_finger_tap"
                        end,
                        radio = true,
                        callback = function()
                            self:setPanelGesture("hold")
                        end,
                        help_text = _(
                            "A long press on the page opens the panel under it. Panels+ takes over KOReader's long press on comic pages."
                        ),
                    },
                    {
                        text = _("Two-finger tap"),
                        checked_func = function()
                            return self.settings.panel_gesture == "two_finger_tap"
                        end,
                        radio = true,
                        callback = function()
                            self:setPanelGesture("two_finger_tap")
                        end,
                        help_text = _(
                            "A tap with two fingers opens the panel under them, and a long press is left to KOReader or other plugins. Needs a multi-touch screen."
                        ),
                    },
                },
                separator = true,
            },
            {
                text = _("Remove the fold line from double-page spreads"),
                checked_func = function()
                    return self.settings.join_spread_fold ~= false
                end,
                callback = function()
                    self:setJoinSpreadFold(self.settings.join_spread_fold == false)
                end,
                help_text = _(
                    "Some scans join the two pages of a spread with a black strip. In the panel viewer, remove that strip and join the two halves. The reading page is not changed."
                ),
            },
            {
                text = _("Rotate double-page spreads"),
                help_text = _(
                    "Rotate double-page spreads by a quarter turn so they fill a portrait screen. In the panel viewer the whole-spread image is rotated and the device stays as it is. While reading, the screen is rotated when a page turn lands on a spread and restored on the next normal page, in the same direction."
                ),
                sub_item_table = {
                    {
                        text = _("Off"),
                        checked_func = function()
                            return self:getSpreadRotationMode() == "off"
                        end,
                        radio = true,
                        callback = function()
                            self:setSpreadRotationMode("off")
                        end,
                    },
                    {
                        text = _("In the panel viewer"),
                        checked_func = function()
                            return self:getSpreadRotationMode() == "viewer"
                        end,
                        radio = true,
                        callback = function()
                            self:setSpreadRotationMode("viewer")
                        end,
                    },
                    {
                        text = _("While reading"),
                        checked_func = function()
                            return self:getSpreadRotationMode() == "reading"
                        end,
                        radio = true,
                        callback = function()
                            self:setSpreadRotationMode("reading")
                        end,
                    },
                    {
                        text = _("In the panel viewer and while reading"),
                        checked_func = function()
                            return self:getSpreadRotationMode() == "both"
                        end,
                        radio = true,
                        callback = function()
                            self:setSpreadRotationMode("both")
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Enable debugging logs"),
                checked_func = function()
                    return self.settings.debug_mode == true
                end,
                callback = function()
                    self:setDebugMode(not self.settings.debug_mode)
                end,
                help_text = _(
                    "Write panel detection, render timings, and memory usage to KOReader's log. Useful for diagnosing slowness or crashes, otherwise leave off."
                ),
            },
            {
                text = _("OCR debug review mode"),
                checked_func = function()
                    return self.settings.ocr_debug_mode == true
                end,
                callback = function()
                    self:setOcrDebugMode(self.settings.ocr_debug_mode ~= true)
                end,
                help_text = _(
                    "After each dictionary lookup that used OCR in a zoomed panel, ask whether the word was read correctly. If not, draw the correct word box and type what it actually says. Everything -- including the exact long-press point -- is appended to OCR.debug.session.log for later review. Off by default."
                ),
            },
        },
    }
end

return Menu
