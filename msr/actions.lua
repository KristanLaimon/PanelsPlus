local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- Dispatcher action and event-handler methods mixed into `MangaComicSmoother`.
---
--- @class MCSActionMethods
local Actions = {}

--- Register gesture-manager actions exposed by this plugin.
function Actions:onDispatcherRegisterActions()
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

--- Toggle the plugin and show a short status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onMangaComicSmootherToggle()
    self:setEnabled(not self:isEnabled())
    UIManager:show(InfoMessage:new{
        text = self:isEnabled() and _("Manga/Comic Smoother enabled") or _("Manga/Comic Smoother disabled"),
        timeout = 2,
    })
    return true
end

--- Toggle between manga and comic reading order and show a status message.
---
--- @return boolean handled Always true for KOReader event dispatch.
function Actions:onMangaComicSmootherToggleMode()
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
function Actions:onMangaComicSmootherSetManga()
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
function Actions:onMangaComicSmootherSetComic()
    self:setMode("comic")
    UIManager:show(InfoMessage:new{
        text = _("Comic mode: left to right"),
        timeout = 2,
    })
    return true
end

return Actions
