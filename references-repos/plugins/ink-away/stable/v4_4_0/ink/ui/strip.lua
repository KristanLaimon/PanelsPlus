--[[
A strip of paper showing a picture of a tool at its real size on screen: the pen
in hand in the Pen sheet, the eraser in the Eraser sheet. Its picture is
replaced in place while a slider moves; a tool shown smaller than it really is
says so in a note in the corner; a tap calls on_tap.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local LABEL = Blitbuffer.Color8(0x55)

local Strip = InputContainer:extend{ w = 0, h = 0, bb = nil, on_tap = nil, note = nil }

function Strip:init()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.w, h = self.h }
    Theme.keep(self)   -- the tool at its size and colour, in dark too
    if Device:isTouchDevice() then
        self.ges_events = { StripTap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
    end
end

function Strip:getSize() return GeomUI:new{ w = self.w, h = self.h } end

function Strip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.w, self.h, WHITE)
    if self.bb then bb:blitFrom(self.bb, x, y, 0, 0, self.w, self.h) end
    if self.note then
        -- a tool too big for the strip is shown smaller, and says so
        local t = TextWidget:new{ text = self.note, face = Font:getFace("cfont", 12), fgcolor = LABEL }
        local sz = t:getSize()
        local m = Screen:scaleBySize(3)
        bb:paintRect(x + self.w - sz.w - 2 * m, y + self.h - sz.h - m, sz.w + 2 * m, sz.h + m, WHITE)
        t:paintTo(bb, x + self.w - sz.w - m, y + self.h - sz.h)
        t:free()
    end
end

-- Show `new` (a BlitBuffer the strip now owns) in place of the picture.
function Strip:setImage(new)
    if self.bb then self.bb:free() end
    self.bb = new
end

function Strip:onStripTap()
    if self.on_tap then self.on_tap() end
    return true
end

function Strip:onCloseWidget()
    if self.bb then self.bb:free(); self.bb = nil end
end

return Strip
