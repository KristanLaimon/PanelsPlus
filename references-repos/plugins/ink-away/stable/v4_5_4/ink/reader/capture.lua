-- Copy a rectangle of the book into Ink Away's picture clipboard. The page is
-- painted without menus before selecting, so controls never enter the picture.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local Clipboard = require("ink/clipboard")
local Clips = require("ink/clips")
local Storage = require("ink/storage")
local logger = require("logger")
local _ = require("ink/l10n")

local Screen = Device.screen
local SHEET = "_capture_sheet"
local Capture = InputContainer:extend{ modal = true, covers_fullscreen = true }

-- Some KOReader builds return nothing after writing a PNG. Accept that only
-- when the newly created file has both its PNG header and final chunk.
local function pngWritten(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if not f then return false end
    local header = f:read(8)
    local tail
    if f:seek("end", -12) then tail = f:read(12) end
    f:close()
    return header == "\137PNG\r\n\26\n" and tail == "\0\0\0\0IEND\174\66\96\130"
end

-- Own a clean, logical screen-sized page, independent of framebuffer rotation.
function Capture:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local typ = Screen.bb:getType() == Blitbuffer.TYPE_BB8 and Blitbuffer.TYPE_BB8 or Blitbuffer.TYPE_BBRGB32
    self.page = Blitbuffer.new(self.dimen.w, self.dimen.h, typ)
    local ok, painted = pcall(self.book.snapshot, self.book, self.page, true)
    self.ready = ok and painted ~= false
    self.ges_events = {}
    for _, binding in ipairs({ { "touch", "DragStart" }, { "tap", "Corner" },
        { "hold", "DragStart" }, { "pan", "Drag" }, { "hold_pan", "Drag" },
        { "pan_release", "DragEnd" }, { "hold_pan_release", "DragEnd" },
        { "hold_release", "DragEnd" }, { "swipe", "DragEnd" } }) do
        local name, event = binding[1], binding[2]
        self.ges_events[event] = self.ges_events[event] or {}
        table.insert(self.ges_events[event],
            GestureRange:new{ ges = name,
                range = (name == "touch" or name == "tap" or name == "hold") and self.dimen or nil })
    end
    self.key_events = { Cancel = { { Device.input.group.Back } } }
end

-- Clamp touch and pen coordinates to the logical page, including a lift outside it.
function Capture:pagePoint(pos)
    return { x = math.max(0, math.min(self.dimen.w - 1, math.floor(pos.x))),
             y = math.max(0, math.min(self.dimen.h - 1, math.floor(pos.y))) }
end

-- A small, static capture symbol replaces the activation instructions. Its white
-- backing keeps it visible over a book; it is drawn only on screen, never saved.
function Capture:paintIndicator(bb, x, y)
    local size, inset = Screen:scaleBySize(30), Screen:scaleBySize(8)
    local left, top = x + self.dimen.w - inset - size, y + inset
    bb:paintRoundedRect(left, top, size, size, Blitbuffer.COLOR_WHITE, Screen:scaleBySize(4))
    local pad, leg, line = Screen:scaleBySize(6), Screen:scaleBySize(7), math.max(1, Screen:scaleBySize(1))
    for _, px in ipairs({ left + pad, left + size - pad - leg }) do
        bb:paintRect(px, top + pad, leg, line, Blitbuffer.COLOR_BLACK)
        bb:paintRect(px, top + size - pad - line, leg, line, Blitbuffer.COLOR_BLACK)
    end
    for _, py in ipairs({ top + pad, top + size - pad - leg }) do
        bb:paintRect(left + pad, py, line, leg, Blitbuffer.COLOR_BLACK)
        bb:paintRect(left + size - pad - line, py, line, leg, Blitbuffer.COLOR_BLACK)
    end
end

-- Keep the press separately from tap corners, so both ways of selecting work.
function Capture:onDragStart(_arg, ges)
    if not self.selection and not self.drag_origin then self.drag_origin = self:pagePoint(ges.pos) end
    return true
end

-- Update the live rectangle after moving beyond tap slop; refresh its old and
-- new bounds together so shrinking or reversing the drag leaves no stale frame.
function Capture:onDrag(_arg, ges)
    if self.selection then return true end
    local a = self.drag_origin
    if not a and ges.start_pos then a = self:pagePoint(ges.start_pos); self.drag_origin = a end
    if not a then return true end
    local p = self:pagePoint(ges.pos)
    local slop = Screen:scaleBySize(6)
    if not self.drag_box and (p.x - a.x)^2 + (p.y - a.y)^2 < slop^2 then return true end
    local r = { x = math.min(a.x, p.x), y = math.min(a.y, p.y),
        w = math.max(1, math.abs(a.x - p.x)), h = math.max(1, math.abs(a.y - p.y)) }
    local old = self.drag_box
    self.drag_box = r
    local dirty = Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
    if old then dirty = dirty:combine(old) end
    if self.corner then
        dirty = dirty:combine{ x = self.corner.x, y = self.corner.y,
            w = math.min(8, self.dimen.w - self.corner.x), h = math.min(8, self.dimen.h - self.corner.y) }
    end
    UIManager:setDirty(self, "fast", dirty)
    return true
end

-- A swipe reports its start as pos and its lift as end_pos. A slow drag reports
-- the lift as pos. Neither is cancellation; both finish only on a real drag.
function Capture:onDragEnd(_arg, ges)
    if self.selection then return true end
    if ges.end_pos then
        if not self.drag_origin then self.drag_origin = self:pagePoint(ges.pos) end
        self:onDrag(nil, { pos = ges.end_pos })
    elseif self.drag_origin then self:onDrag(nil, ges) end
    local a, moved = self.drag_origin, self.drag_box ~= nil
    self.drag_origin, self.drag_box = nil, nil
    if moved then
        self.corner = a
        self:onCorner(nil, { pos = ges.end_pos or ges.pos })
        if not self.selection then UIManager:setDirty(self, "ui") end
    end
    return true
end

-- Show the two-tap marker or the live/final rectangle over the clean snapshot.
function Capture:paintTo(bb, x, y)
    bb:blitFrom(self.page, x, y, 0, 0, self.dimen.w, self.dimen.h)
    if self.selection or self.drag_box then
        local r = self.selection or self.drag_box
        if r.w < 2 or r.h < 2 then
            bb:paintRect(x + r.x, y + r.y, r.w, r.h, Blitbuffer.COLOR_BLACK)
        else
            bb:paintBorder(x + r.x, y + r.y, r.w, r.h, 1, Blitbuffer.COLOR_BLACK)
        end
        if r.w >= 6 and r.h >= 6 then
            bb:paintBorder(x + r.x + 1, y + r.y + 1, r.w - 2, r.h - 2, 1, Blitbuffer.COLOR_WHITE)
        end
    elseif self.corner then
        local p = self.corner
        bb:paintBorder(x + p.x, y + p.y, math.min(8, self.dimen.w - p.x),
            math.min(8, self.dimen.h - p.y), 2, Blitbuffer.COLOR_BLACK)
    end
    self:paintIndicator(bb, x, y)
end

-- Normalise either selection direction and keep every pixel inside the page.
function Capture:onCorner(_arg, ges)
    if self.selection then return true end
    self.drag_origin, self.drag_box = nil, nil
    local p = self:pagePoint(ges.pos)
    if not self.corner then
        self.corner = p
        UIManager:setDirty(self, "ui", Geom:new{ x = p.x, y = p.y,
            w = math.min(8, self.dimen.w - p.x), h = math.min(8, self.dimen.h - p.y) })
        return true
    end
    local a = self.corner
    local x, y = math.min(a.x, p.x), math.min(a.y, p.y)
    local w, h = math.abs(a.x - p.x), math.abs(a.y - p.y)
    if w < 2 or h < 2 then return true end
    self.selection = { x = x, y = y, w = w, h = h }
    UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y,
        w = math.min(w + 8, self.dimen.w - x), h = math.min(h + 8, self.dimen.h - y) })
    self:confirmSelection()
    return true
end

-- Release the decision sheet before resetting or closing its capture owner.
function Capture:closeConfirmation()
    local sheet = self._confirmation
    self._confirmation = nil
    if sheet then sheet:closeSheet(SHEET) end
end

-- Start another rectangle on the same clean page without changing the clipboard.
function Capture:selectAgain()
    self:closeConfirmation()
    self.corner, self.selection, self.drag_origin, self.drag_box = nil, nil, nil, nil
    if self.page then UIManager:setDirty(self, "ui") end
end

-- Keep the outlined rectangle on screen until it is copied, replaced or cancelled.
-- The decision is Ink Away's own sheet, shown through a stand-in for the view as
-- ink/view's tellAnywhere does. It is modal, so it stacks above the capture, and
-- it sits at the bottom when the rectangle is in the upper half of the page (at
-- the top otherwise), so it never covers what was just outlined. A tap outside it
-- selects again. `copy`, `again` and `cancel` are what its buttons do.
function Capture:confirmSelection()
    local host = setmetatable({}, { __index = require("ink/view") })
    local content_w, gap = host:sheetWidth()
    host.copy = function() self:copySelection() end
    host.again = function() self:selectAgain() end
    host.cancel = function() self:onCancel() end
    local build = function()
        local half = math.floor((content_w - gap) / 2)
        return VerticalGroup:new{ align = "left",
            host:sheetTitle(_("Copy this area?"), content_w, _("Cancel"), host.cancel),
            VerticalSpan:new{ width = Screen:scaleBySize(14) },
            HorizontalGroup:new{ align = "center",
                host:actionButton(_("Copy"), half, host.copy, true),
                HorizontalSpan:new{ width = gap },
                host:actionButton(_("Select again"), half, host.again) } }
    end
    local r = self.selection
    local upper = r.y + r.h / 2 < self.dimen.h / 2
    self._confirmation = host
    host:showSheet(SHEET, build, {
        bottom_y = upper and (Screen:getHeight() - Screen:scaleBySize(6)) or nil,
        on_close = function()
            if self._confirmation == host then self._confirmation = nil; self:selectAgain() end
        end })
end

-- Save and copy only an explicitly confirmed rectangle, without its outline.
function Capture:copySelection()
    if not (self.page and self.selection) then return true end
    self:closeConfirmation()
    local x, y, w, h = self.selection.x, self.selection.y, self.selection.w, self.selection.h
    local dir = Clips.dir()
    local path
    if dir then
        local n = 1
        repeat
            path = string.format("%s/clip-%d-%d.png", dir, os.time(), n)
            n = n + 1
        until not Storage.exists(path)
    end
    local crop = Blitbuffer.new(w, h, self.page:getType())
    local ok, saved, err = pcall(function()
        crop:blitFrom(self.page, 0, 0, x, y, w, h)
        if path then return crop:writePNG(path) end
        return false
    end)
    crop:free()
    local detail = ok and err or saved
    if ok and saved == nil then saved = pngWritten(path) end
    if ok and saved then
        -- (old clips go as the person's settings say, with each new one)
        local G = rawget(_G, "G_reader_settings")
        pcall(Clips.sweepAuto, function(k) return G and G.readSetting and G:readSetting(k) end)
        Clipboard.put({ { kind = "image", path = path, x = 0, y = 0,
            w = w, h = h, natw = w, nath = h } }, { x0 = 0, y0 = 0, x1 = w, y1 = h })
    elseif path then os.remove(path) end
    UIManager:close(self)
    local message
    if ok and saved then
        message = string.format(_("Copied %d item(s). Tap with the lasso to paste."), 1)
    else
        logger.warn("Ink Away: screen clip save failed:", path, detail)
        message = path and _("Couldn't save the image.") or _("Couldn't prepare a folder for the image.")
        if detail then message = message .. "\n\n" .. tostring(detail) end
    end
    require("ink/view").tellAnywhere(message)
    return true
end

-- Cancel or Back leaves the previous clipboard untouched.
function Capture:onCancel()
    UIManager:close(self)
    return true
end

-- Rotation and document closure cancel a selection made for the old page.
Capture.onSetDimensions = Capture.onCancel
Capture.onCloseDocument = Capture.onCancel

-- Release the sole full-page buffer on every way out.
function Capture:onCloseWidget()
    self:closeConfirmation()
    if self.page then self.page:free(); self.page = nil end
    if self.book._capture == self then self.book._capture = nil end
    UIManager:setDirty(nil, "ui")
end

-- Enter capture immediately; the corner symbol is the only activation feedback.
function Capture.open(book)
    if book._capture then return end
    local capture = Capture:new{ book = book }
    if not capture.ready then
        capture:onCloseWidget()
        require("ink/view").tellAnywhere(_("Couldn't save the image."))
        return
    end
    book._capture = capture
    UIManager:show(capture)
    UIManager:setDirty(capture, "ui")
end

return Capture
