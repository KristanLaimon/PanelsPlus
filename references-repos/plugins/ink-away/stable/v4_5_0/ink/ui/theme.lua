--[[
Light and dark: Ink Away's own controls (the toolbars, the sheets, the bars, the
floating buttons, the library) can be shown dark. The page and the canvas never
are, nor anything in a colour the reader chose (the theme colour, swatches, pen
samples, paper previews, thumbnails).

Dark is drawn as KOReader draws its night mode: everything is painted as in
light, then the control's area is inverted, and the parts that keep their
colours (marked with Theme.keep) are inverted back, so they come out exactly as
painted. An accent that is not a colour (black, the default) is inverted with the
rest and becomes white: the active tool, Done and the switches stay as easy to
read on a dark control as black ones are on a light one.

The mode is Light, Dark or System; System follows KOReader's night mode. When
KOReader's night mode is on it already inverts the whole screen, so the controls
are inverted here only when that would not give the look chosen.
]]

local Device = require("device")

local Theme = {}

Theme.SETTING = "inkaway_ui_mode"
Theme.MODES = { "light", "dark", "system" }

local function setting(k)
    local G = rawget(_G, "G_reader_settings")
    return G and G.readSetting and G:readSetting(k)
end

-- "light", "dark" or "system".
function Theme.mode()
    local m = setting(Theme.SETTING)
    if m == "dark" or m == "system" then return m end
    return "light"
end

-- Is KOReader's night mode on (the whole screen inverted)?
function Theme.nightMode()
    local s = Device.screen
    if s and s.night_mode ~= nil then return s.night_mode == true end
    local G = rawget(_G, "G_reader_settings")
    return G ~= nil and G.isTrue ~= nil and G:isTrue("night_mode") or false
end

-- Should the controls look dark?
function Theme.dark()
    local m = Theme.mode()
    if m == "system" then return Theme.nightMode() end
    return m == "dark"
end

-- Must the controls be inverted here to look as chosen? (KOReader's night mode
-- inverts them already.)
function Theme.invert()
    return Theme.dark() ~= Theme.nightMode()
end

-- Mark a widget whose colours are kept in dark (see Theme.restore); `r` is its
-- corner radius, so the panel shows round its corners as everywhere else.
function Theme.keep(w, r)
    if w then w._ia_keep, w._ia_keep_r = true, r or 0 end
    return w
end

-- Invert the rect, leaving out what lies outside its rounded corners of radius
-- r (the page around a rounded panel or button stays as it is).
function Theme.invertRounded(bb, x, y, w, h, r)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    if w <= 0 or h <= 0 then return end
    r = math.floor(math.min(r or 0, w / 2, h / 2))
    if r <= 0 then bb:invertRect(x, y, w, h); return end
    bb:invertRect(x, y + r, w, h - 2 * r)
    for j = 0, r - 1 do
        -- the row's half-width inside the corner's quarter circle
        local dy = r - j - 0.5
        local inset = math.ceil(r - math.sqrt(math.max(0, r * r - dy * dy)) - 0.5)
        if inset < 0 then inset = 0 end
        local span = w - 2 * inset
        if span > 0 then
            bb:invertRect(x + inset, y + j, span, 1)
            bb:invertRect(x + inset, y + h - 1 - j, span, 1)
        end
    end
end

-- KOReader's text buttons flash on a tap by painting themselves alone in their
-- light colours, which would leave a light button on a dark panel; on a dark
-- panel the button flashes by inverting what is shown instead (as KOReader's
-- icon buttons do), and back. A kept button flashes as it always has.
local function flip(b)
    local f = b[1]
    local d = f and f.dimen
    if not (d and d.w) then return end
    local Size = require("ui/size")
    Theme.invertRounded(Device.screen.bb, d.x, d.y, d.w, d.h, f.radius or Size.radius.button)
    require("ui/uimanager"):setDirty(nil, "fast", d)
end
local function darkFlash(b)
    if rawget(b, "_ia_flash") then return end
    b._ia_flash = true
    local orig_do, orig_undo = b._doFeedbackHighlight, b._undoFeedbackHighlight
    b._doFeedbackHighlight = function(self)
        self._ia_flipped = Theme.invert()
        if self._ia_flipped then flip(self) else orig_do(self) end
    end
    b._undoFeedbackHighlight = function(self, ...)
        if self._ia_flipped then self._ia_flipped = nil; flip(self) else orig_undo(self, ...) end
    end
end

-- Invert back every kept widget under `root` that was painted inside the rect
-- (x, y, w, h), so it shows as painted. The buttons on the way learn to flash on
-- a dark panel (see darkFlash).
function Theme.restore(bb, root, x, y, w, h)
    local seen = {}
    -- (x0, y0)-(x1, y1): what is shown of the widget's part of the screen (a
    -- scrolled list shows only its window)
    local function walk(t, x0, y0, x1, y1)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        if t._ia_keep and t.dimen and t.dimen.w and t.dimen.w > 0 then
            local d = t.dimen
            local ax, ay = math.max(x0, d.x), math.max(y0, d.y)
            local bx, by = math.min(x1, d.x + d.w), math.min(y1, d.y + d.h)
            if bx > ax and by > ay then
                -- whole and rounded, or the part shown
                if ax == d.x and ay == d.y and bx == d.x + d.w and by == d.y + d.h then
                    Theme.invertRounded(bb, d.x, d.y, d.w, d.h, t._ia_keep_r or 0)
                else
                    bb:invertRect(ax, ay, bx - ax, by - ay)
                end
            end
            return
        end
        if t._doFeedbackHighlight and t._undoFeedbackHighlight then darkFlash(t) end
        if t._is_scrollable and t.dimen and t.dimen.x then
            local d = t.dimen
            local sx = d.x + (t._crop_dx or 0)
            x0, y0 = math.max(x0, sx), math.max(y0, d.y)
            x1 = math.min(x1, sx + (t._crop_w or d.w))
            y1 = math.min(y1, d.y + (t._crop_h_limited or t._crop_h or d.h))
        end
        for k, c in pairs(t) do
            if type(c) == "table" and k ~= "show_parent" and k ~= "parent" and k ~= "dimen"
                    and k ~= "build" and not (type(k) == "string" and k:sub(1, 1) == "_") then
                walk(c, x0, y0, x1, y1)
            end
        end
    end
    walk(root, x, y, x + w, y + h)
end

-- Dark for a control painted at (x, y, w, h) with corner radius r: invert it
-- and give back the kept parts of `root`. Nothing in light.
function Theme.apply(bb, root, x, y, w, h, r)
    if not Theme.invert() then return false end
    Theme.invertRounded(bb, x, y, w, h, r)
    if root then Theme.restore(bb, root, x, y, w, h) end
    return true
end

return Theme
