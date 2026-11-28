-- The bottom menu's tab icons are meguru.* names, resolved by the wrap below.
-- Keep fill/stroke on each path; root-level attrs may render blank on device.
local FS = require("meguru/fs")
local Paths = require("meguru/paths")

local Icons = {}

-- The stock icon each tab wears when its own SVG is not shipped.
local FALLBACK = {
    reading  = "appbar.pageview",
    page     = "appbar.crop",
    rotation = "appbar.rotation",
    tone     = "appbar.contrast",
    info     = "info",
}

-- nil is ordinary: pluginDir may not be handed over yet, and art is optional.
function Icons.file(kind)
    if type(kind) ~= "string" then
        return nil
    end
    local path = Paths.asset("icons/" .. kind .. ".svg")
    if path and FS.exists(path) then
        return path
    end
    return nil
end

-- Same call site either way; the name is what the wrap below keys on.
function Icons.tab(kind)
    if Icons.file(kind) then
        return "meguru." .. kind
    end
    return FALLBACK[kind] or "appbar.pageview"
end

local installed = false

-- Wrap the class: IconWidget is built per tab from a name, none to hang on.
-- main.lua installs this before any book can be opened.
function Icons.install()
    if installed then
        return
    end
    local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if not ok or type(IconWidget) ~= "table" or type(IconWidget.init) ~= "function" then
        return
    end
    installed = true
    local orig_init = IconWidget.init
    IconWidget.init = function(self)
        local kind = type(self.icon) == "string"
            and self.icon:match("^meguru%.(%a+)$")
        if kind then
            local path = Icons.file(kind)
            if path then
                -- IconWidget uses self.file before its own name lookup.
                self.file = path
                return
            end
            -- Artwork gone after the tab was named: use the stock name.
            self.icon = FALLBACK[kind] or "appbar.pageview"
        end
        return orig_init(self)
    end
end

return Icons
