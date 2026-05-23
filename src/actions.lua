local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- Dispatcher action and event-handler methods mixed into `PanelsPlus`.
---
--- @class PPActionMethods
local Actions = {}

--- Register gesture-manager actions exposed by this plugin.
function Actions:onDispatcherRegisterActions()
    Dispatcher:registerAction("panels_plus_toggle", {
        category = "none",
        event = "PanelsPlusToggle",
        title = _("Panels+: toggle"),
        reader = true,
    })
    Dispatcher:registerAction("panels_plus_toggle_mode", {
        category = "none",
        event = "PanelsPlusToggleMode",
        title = _("Panels+: manga/comic mode"),
        reader = true,
    })
    Dispatcher:registerAction("panels_plus_set_manga", {
        category = "none",
        event = "PanelsPlusSetManga",
        title = _("Panels+: set manga mode"),
        reader = true,
    })
    Dispatcher:registerAction("panels_plus_set_comic", {
        category = "none",
        event = "PanelsPlusSetComic",
        title = _("Panels+: set comic mode"),
        reader = true,
    })
end

--- Toggle the plugin and show a short status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onPanelsPlusToggle()
    self:setEnabled(not self:isEnabled())
    UIManager:show(InfoMessage:new{
        text = self:isEnabled() and _("Panels+ enabled") or _("Panels+ disabled"),
        timeout = 2,
    })
    return true
end

--- Toggle between manga and comic reading order and show a status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onPanelsPlusToggleMode()
    self:setMode(self.settings.mode == "manga" and "comic" or "manga")
    UIManager:show(InfoMessage:new{
        text = self.settings.mode == "manga" and _("Manga mode: right to left") or _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

--- Switch to manga reading order and show a status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onPanelsPlusSetManga()
    self:setMode("manga")
    UIManager:show(InfoMessage:new{
        text = _("Manga mode: right to left"),
        timeout = 2,
    })
    return true
end

--- Switch to comic reading order and show a status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onPanelsPlusSetComic()
    self:setMode("comic")
    UIManager:show(InfoMessage:new{
        text = _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

return Actions
