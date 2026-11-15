--[[
Ink Away's icon in KOReader's own top menu bar, next to the Tools tab, for the
quick menu (see ink/launcher.lua): one tap from any screen to annotate the book,
open the book's notes, copy part of the page, or open Ink Away, so nobody has to
set a gesture or dig through Tools, More tools.

The bar is drawn from each menu's `tab_item_table`, built again by
`setUpdateItemTable`; this wraps that to add one tab. KOReader finds a tab's icon
by name: IconWidget looks in the data folder's icons folder (only if it existed
when KOReader started) and in resources/icons, so the SVG is copied to both. It
is an SVG on purpose: KOReader draws it for the screen it is on, grey or colour,
so no bit depth or colour mode can go wrong. Plain Lua apart from the menu
classes handed in, so the headless tests drive it.
]]

local Topbar = {}

Topbar.SETTING = "inkaway_topbar_icon"   -- settings: show the icon (on unless false)
Topbar.ICON = "inkaway.tab"              -- the icon's name, a file inkaway.tab.svg in an icons folder
Topbar.SOURCE = "ink/icons/tab.svg"      -- where the plugin keeps it

-- Is the icon wanted? `get(key)` reads a setting.
function Topbar.enabled(get)
    return get(Topbar.SETTING) ~= false
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Copy `src` over `dst` unless `dst` already holds the same bytes. The file times
-- are no guide: a device clock can be wrong and a copied plugin keeps the old
-- times, so a stale icon from an earlier version would otherwise stay for good.
local function copyIfChanged(lfs, src, dst)
    if not lfs.attributes(src) then return true end
    local data = readAll(src)
    if not data then return false end
    if lfs.attributes(dst) and readAll(dst) == data then return true end
    local out = io.open(dst, "wb")
    if not out then return false end
    out:write(data)
    out:close()
    return true
end

-- Put the icon where KOReader looks for it: `data_dir`/icons (the persistent home,
-- picked up from the next start) and `cwd`/resources/icons (picked up at once).
-- Either may be missing or read-only: each is tried on its own. `lfs` is the file
-- system library. Returns how many copies are in place.
function Topbar.installIcon(lfs, plugin_dir, data_dir, cwd)
    local src = plugin_dir .. Topbar.SOURCE
    if not lfs.attributes(src) then return 0 end
    local n = 0
    for _i, dir in ipairs({ data_dir and (data_dir .. "/icons"), cwd and (cwd .. "/resources/icons") }) do
        if dir then
            pcall(function()
                if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
                if lfs.attributes(dir, "mode") == "directory"
                        and copyIfChanged(lfs, src, dir .. "/" .. Topbar.ICON .. ".svg") then
                    n = n + 1
                end
            end)
        end
    end
    return n
end

-- Add the tab to `tabs` (a menu's tab_item_table) just before the last one, the
-- main menu's. `callback` runs when it is tapped. Does nothing when it is there.
-- Returns whether it added it.
function Topbar.insertTab(tabs, callback)
    if type(tabs) ~= "table" then return false end
    for _i, t in ipairs(tabs) do
        if t.icon == Topbar.ICON then return false end
    end
    table.insert(tabs, math.max(1, #tabs), {
        icon = Topbar.ICON,
        remember = false,   -- the menu never opens on this tab
        callback = callback,
    })
    return true
end

-- Wrap `menu_class`.setUpdateItemTable so every menu built from it carries the
-- tab (while the setting is on). `get(key)` reads settings; `on_tap(menu)` is run
-- once the top menu is closed. Safe to call twice.
function Topbar.patch(menu_class, get, on_tap)
    if not menu_class or menu_class.__inkaway_topbar then return false end
    local orig = menu_class.setUpdateItemTable
    if type(orig) ~= "function" then return false end
    menu_class.__inkaway_topbar = true
    menu_class.setUpdateItemTable = function(self, ...)
        orig(self, ...)
        if not Topbar.enabled(get) then return end
        Topbar.insertTab(self.tab_item_table, function()
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                -- close the whole top menu first, so what opens sits over the book or
                -- the file browser, not over the menu
                local mc = self.menu_container
                if mc then
                    local tm = mc[1]
                    if tm and tm.close_callback then tm.close_callback() else UIManager:close(mc) end
                    self.menu_container = nil
                end
                on_tap(self)
            end)
        end)
    end
    return true
end

return Topbar
