local _ = require("gettext")

--- Main-menu methods mixed into `PanelsPlus`.
---
--- @class PPMenuMethods
local Menu = {}

--- Return the active detector, defaulting unset or unknown values to automatic.
---
--- @return PPDetector detector Current detector selection.
function Menu:getDetector()
    local detector = self.settings.detector
    if detector == "fast" or detector == "native" then
        return detector
    end
    return "auto"
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
                separator = true,
            },
            {
                text = _("Panel detection"),
                sub_item_table = {
                    {
                        text = _("Automatic"),
                        checked_func = function()
                            return self:getDetector() == "auto"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("auto")
                        end,
                        help_text = _("Use the fast Panels+ detector, falling back to KOReader's detector on layouts it cannot split."),
                    },
                    {
                        text = _("Fast only"),
                        checked_func = function()
                            return self:getDetector() == "fast"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("fast")
                        end,
                        help_text = _("Always use the Panels+ detector. Fastest, and the only one that works on pages with a dark background, but it cannot split interlocking panel layouts."),
                    },
                    {
                        text = _("KOReader detector only"),
                        checked_func = function()
                            return self:getDetector() == "native"
                        end,
                        radio = true,
                        callback = function()
                            self:setDetector("native")
                        end,
                        help_text = _("Always use KOReader's panel detector. Slower, and it cannot find panels on pages with a dark background."),
                    },
                },
            },
            {
                text = _("Pre-render next panel"),
                checked_func = function()
                    return self.settings.panel_prerender ~= false
                end,
                callback = function()
                    self:setPanelPrerender(self.settings.panel_prerender == false)
                end,
                help_text = _("Render the next panel while you read the current one, so swiping to it is instant. Skipped automatically when the device is low on memory."),
            },
            {
                text = _("Log panel timings"),
                checked_func = function()
                    return self.settings.debug_timing == true
                end,
                callback = function()
                    self:setDebugTiming(not self.settings.debug_timing)
                end,
                help_text = _("Write panel detection and render timings to KOReader's log. Useful for diagnosing slowness, otherwise leave off."),
            },
        },
    }
end

return Menu
