--[[
A library folder's look: one of twelve colours, and an icon drawn on its front
in a deeper shade of that colour (KOReader's own icons, the ones in the
reader's koreader/icons folder, or Ink Away's). The look is kept with the
folder's name in its parent's binder file (see ink/folder.lua), so it lives
in the library, not in the plugin, and an update leaves it alone. An icon is
kept by where it comes from and its file name, so it is found again after
KOReader moves.

A folder is drawn once per look and size: two filled shapes (the back with its
tab, and the front) and the icon, each made into a mask once and coloured by
KOReader's C blitter. The pictures stay in memory until KOReader closes, so
opening the library again draws nothing.
]]

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("ink/l10n")
local Storage = require("ink/storage")

local FolderLook = {}

-- The colours, by key (the key is what is kept, so a shade can be tuned later).
FolderLook.COLORS = {
    { key = "red",      name = _("Red"),      rgb = { 0xE0, 0x56, 0x52 } },
    { key = "orange",   name = _("Orange"),   rgb = { 0xF0, 0x8C, 0x3E } },
    { key = "yellow",   name = _("Yellow"),   rgb = { 0xF2, 0xC9, 0x4C } },
    { key = "lime",     name = _("Lime"),     rgb = { 0xC8, 0xE0, 0x6C } },
    { key = "green",    name = _("Green"),    rgb = { 0x7C, 0xC4, 0x74 } },
    { key = "teal",     name = _("Teal"),     rgb = { 0x4F, 0xB5, 0xA6 } },
    { key = "sky",      name = _("Sky"),      rgb = { 0x72, 0xBA, 0xE8 } },
    { key = "blue",     name = _("Blue"),     rgb = { 0x50, 0x86, 0xDA } },
    { key = "purple",   name = _("Purple"),   rgb = { 0xA0, 0x88, 0xE0 } },
    { key = "pink",     name = _("Pink"),     rgb = { 0xEE, 0x90, 0xB8 } },
    { key = "brown",    name = _("Brown"),    rgb = { 0xAE, 0x82, 0x5E } },
    { key = "graphite", name = _("Graphite"), rgb = { 0x8E, 0x93, 0x9A } },
}
local BY_KEY = {}
for _i, c in ipairs(FolderLook.COLORS) do BY_KEY[c.key] = c end
-- a folder with an icon and no colour
local NEUTRAL = { 0xC4, 0xC4, 0xC4 }

-- The folder's proportions, width to height (the shapes' viewBox, 100 x 80).
FolderLook.ASPECT = 0.8

-- {r,g,b} of colour key `key`, or nil.
function FolderLook.rgb(key)
    return BY_KEY[key] and BY_KEY[key].rgb or nil
end

-- A look worth drawing (a colour or an icon), or nil: what the binder holds may
-- be anything.
function FolderLook.clean(look)
    if type(look) ~= "table" then return nil end
    local color = BY_KEY[look.color] and look.color or nil
    local icon = type(look.icon) == "string" and look.icon ~= "" and look.icon or nil
    if not (color or icon) then return nil end
    return { color = color, icon = icon }
end

------------------------------------------------------------------------------
-- Icons
------------------------------------------------------------------------------

local function pluginDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return (src:match("^(.*)/ink/folderlook%.lua$") or ".") .. "/"
end

-- Where each kind of icon lives: the reader's own icons folder (koreader/icons),
-- Ink Away's, and KOReader's (its paths are relative to KOReader's folder).
local function sourceDir(kind)
    if kind == "user" then
        local data = Storage.dataDir()
        return data and data .. "/icons" or nil
    elseif kind == "ink" then
        return pluginDir() .. "ink/icons"
    elseif kind == "ko" then
        return "resources/icons/mdlight"
    end
end

-- Icons left out of the choice: the variants of KOReader's state icons
-- (rotations, reading directions, Wi-Fi strengths...), and Ink Away's own
-- toolbar parts. Ink Away's copies in koreader/icons are offered as its own.
local SKIP = {
    ko = { "^rotation%.", "^direction%.", "^dogear", "^cre%.render", "^wifi%.open%.", "^wifi%.secure%.",
        "^zoom%.", "^column%.", "^align%.", "^chevron%.", "^position%.marker", "^back%.top", "^control%.",
        "^move%.", "^icon%-not%-found", "^texture%-box" },
    ink = { "^ges_", "^sh_", "^nav_", "^folder$", "^caret$", "^menu$", "^exit$", "^fullscreen$",
        "^zoomin$", "^zoomout$", "^undo$", "^redo$", "^newpage$" },
    user = { "^inkaway%." },
}

local function skipped(kind, stem)
    for _i, pat in ipairs(SKIP[kind]) do if stem:match(pat) then return true end end
    return false
end

-- A name to show for an icon file's stem: "appbar.settings" reads "Settings".
function FolderLook.iconLabel(stem)
    local s = stem:gsub("^appbar%.", ""):gsub("[._-]+", " ")
    return (s:gsub("^%l", string.upper))
end

-- Every icon on offer, the reader's own first: a list of { id, path, label }.
-- An id is "kind/file name".
function FolderLook.icons()
    local out = {}
    for _i, kind in ipairs({ "user", "ink", "ko" }) do
        local dir = sourceDir(kind)
        local found = {}
        for _j, e in ipairs(dir and Storage.list(dir) or {}) do
            local stem, ext = e.name:match("^(.+)%.(%a+)$")
            ext = ext and ext:lower()
            if e.mode == "file" and stem and (ext == "svg" or (ext == "png" and kind == "user"))
                    and not skipped(kind, stem) then
                found[#found + 1] = { id = kind .. "/" .. e.name, path = e.path, label = FolderLook.iconLabel(stem) }
            end
        end
        table.sort(found, function(a, b) return a.label:lower() < b.label:lower() end)
        for _j, f in ipairs(found) do out[#out + 1] = f end
    end
    return out
end

-- The file of icon `id`, or nil when it is no longer there.
function FolderLook.iconPath(id)
    local kind, name = tostring(id):match("^(%a+)/([^/]+)$")
    local dir = kind and sourceDir(kind)
    if not dir or name:sub(1, 1) == "." then return nil end
    local path = dir .. "/" .. name
    return Storage.exists(path) and path or nil
end

-- The label of icon `id`.
function FolderLook.iconName(id)
    local name = tostring(id):match("/([^/]+)$")
    return name and FolderLook.iconLabel(name:match("^(.+)%.%a+$") or name) or ""
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local RenderImage   -- KOReader's, loaded when first drawn
local function renderer()
    RenderImage = RenderImage or require("ui/renderimage")
    return RenderImage
end

-- The picture at `path` fitted into w x h (kept in proportion, centred), as a
-- mask (BB8, 255 where it is dark): an icon's ink, whatever its colours, on
-- whatever it is drawn on.
local function mask(path, w, h)
    local RI = renderer()
    local raw, straight
    if path:lower():match("%.svg$") then
        raw, straight = RI:renderSVGImageFile(path, w, h)
    else
        local img = RI:renderImageFile(path, false)
        if img then
            local s = math.min(w / img:getWidth(), h / img:getHeight())
            raw = RI:scaleBlitBuffer(img, math.max(1, math.floor(img:getWidth() * s)),
                math.max(1, math.floor(img:getHeight() * s)))
            straight = true
        end
    end
    if not raw then return nil end
    local m = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    m:fill(Blitbuffer.COLOR_WHITE)
    local rw, rh = raw:getWidth(), raw:getHeight()
    local x, y = math.floor((w - rw) / 2), math.floor((h - rh) / 2)
    if raw:getType() == Blitbuffer.TYPE_BBRGB32 or raw:getType() == Blitbuffer.TYPE_BB8A then
        if straight then m:alphablitFrom(raw, x, y, 0, 0, rw, rh)
        else m:pmulalphablitFrom(raw, x, y, 0, 0, rw, rh) end
    else
        m:blitFrom(raw, x, y, 0, 0, rw, rh)
    end
    raw:free()
    m:invertRect(0, 0, w, h)
    return m
end

-- The two shapes of a folder (ink/data), in a 100 x 80 box: the back with its
-- tab on the left, and the front.
local function shapeFile(name)
    return pluginDir() .. "ink/data/folder-" .. name .. ".svg"
end

-- Masks kept for the session: shapes by size, icons by id and size.
local masks = {}
local function cachedMask(key, make)
    if masks[key] == nil then
        local ok, m = pcall(make)
        masks[key] = ok and m or false
    end
    return masks[key] or nil
end

-- Drawn folders, the newest last, and how many are kept.
local tiles, order = {}, {}
FolderLook.KEEP = 48

local function remember(key, bb)
    tiles[key] = bb
    order[#order + 1] = key
    while #order > FolderLook.KEEP do
        local old = table.remove(order, 1)
        if tiles[old] then tiles[old]:free(); tiles[old] = nil end
    end
end

local function shade(rgb, f)
    return Blitbuffer.ColorRGB32(math.floor(rgb[1] * f), math.floor(rgb[2] * f), math.floor(rgb[3] * f), 0xFF)
end

-- The folder of look `look` drawn `w` wide on grey `bg` (0..255, what is
-- around it), or nil when the look draws nothing (the plain folder icon goes
-- there). The picture belongs to this module: draw it, never free it.
function FolderLook.tile(look, w, bg)
    look = FolderLook.clean(look)
    if not look or not w or w < 8 then return nil end
    w = math.floor(w)
    bg = bg or 0xE6
    local icon_path = look.icon and FolderLook.iconPath(look.icon)
    local key = table.concat({ look.color or "-", icon_path and look.icon or "-", w, bg }, "|")
    local held = tiles[key]
    if held then return held end
    local h = math.floor(w * FolderLook.ASPECT + 0.5)
    local back = cachedMask("back|" .. w, function()
        return mask(shapeFile("back"), w, h) end)
    local front = cachedMask("front|" .. w, function()
        return mask(shapeFile("front"), w, h) end)
    if not (back and front) then return nil end
    local rgb = FolderLook.rgb(look.color) or NEUTRAL
    local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    tile:fill(Blitbuffer.Color8(bg))
    tile:colorblitFromRGB32(back, 0, 0, 0, 0, w, h, shade(rgb, 0.80))
    tile:colorblitFromRGB32(front, 0, 0, 0, 0, w, h, shade(rgb, 1))
    if icon_path then
        -- on the front's middle, a little under half its height
        local front_y, front_h = math.floor(h * 17 / 80), h - math.floor(h * 17 / 80)
        local isz = math.max(4, math.floor(front_h * 0.56))
        local m = cachedMask("icon|" .. look.icon .. "|" .. isz, function() return mask(icon_path, isz, isz) end)
        if m then
            tile:colorblitFromRGB32(m, math.floor((w - isz) / 2), front_y + math.floor((front_h - isz) / 2),
                0, 0, isz, isz, shade(rgb, 0.52))
        end
    end
    remember(key, tile)
    return tile
end

-- Icon `path` drawn `sz` square on grey `bg`, for the icon chooser: a new
-- picture the caller frees.
function FolderLook.iconPreview(path, sz, bg)
    local ok, m = pcall(mask, path, sz, sz)
    if not (ok and m) then return nil end
    local t = Blitbuffer.new(sz, sz, Blitbuffer.TYPE_BBRGB32)
    t:fill(Blitbuffer.Color8(bg or 0xE6))
    t:colorblitFromRGB32(m, 0, 0, 0, 0, sz, sz, Blitbuffer.ColorRGB32(0x22, 0x22, 0x22, 0xFF))
    m:free()
    return t
end

-- Free every kept picture (tests, and when memory is short).
function FolderLook.free()
    for k, bb in pairs(tiles) do bb:free(); tiles[k] = nil end
    order = {}
    for k, m in pairs(masks) do if m then m:free() end; masks[k] = nil end
end

return FolderLook
