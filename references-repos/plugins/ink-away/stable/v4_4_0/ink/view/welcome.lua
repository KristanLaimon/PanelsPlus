--[[
The notice shown the first time Ink Away opens (the canvas, a book's annotation
or its notes): what annotating the book and book notes are and the gesture each
got, a warning for any that couldn't get one, and on an Android reader that
needs it the tip for faster drawing. Once closed it never shows again. The
words come from ink/welcome.lua.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local L10n = require("ink/l10n")
local _ = L10n
local Welcome = require("ink/welcome")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local GREY = Blitbuffer.ColorRGB32(0x55, 0x55, 0x55, 0xFF)

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function hspan(px) return HorizontalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

-- Has the notice yet to be shown?
function InkAwayView:welcomeDue()
    return not self:getSetting("inkaway_welcome_seen")
end

-- A wrapped line of text.
local function para(text, w, size, bold, color)
    return TextBoxWidget:new{ text = text, width = w, face = Font:getFace("cfont", size),
        bold = bold, fgcolor = color or BLACK }
end

-- One feature: its icon, its name and what it is, and the gesture that opens it
-- under a glyph of that gesture.
function InkAwayView:welcomeRow(row, w)
    local isz, gsz = Screen:scaleBySize(30), Screen:scaleBySize(32)
    local text_w = w - isz - Screen:scaleBySize(14)
    local col = VerticalGroup:new{ align = "left",
        para(_(row.feature.title), text_w, 18, true),
        vspan(2),
        para(_(row.feature.text), text_w, 15) }
    if row.gesture then
        col[#col + 1] = vspan(8)
        local glyph = row.glyph and self:tileIcon(row.glyph, gsz) or hspan(32)
        col[#col + 1] = HorizontalGroup:new{ align = "center", glyph, hspan(8),
            para(_(row.gesture), text_w - gsz - Screen:scaleBySize(8), 15, true) }
        if row.outside then
            col[#col + 1] = vspan(3)
            col[#col + 1] = para(row.outside, text_w, 13, false, GREY)
        end
    end
    return HorizontalGroup:new{ align = "top",
        self:tileIcon(row.feature.icon, isz) or hspan(30), hspan(14), col }
end

-- Show the notice, once: it is marked seen as it opens (and the device tip with
-- it, when it is part of it).
function InkAwayView:showWelcome()
    local c = Welcome.content(self:getSetting("inkaway_entry_gestures"),
        function(s, ...) return Welcome.fill(_(s), ...) end, L10n.code)
    local tip = not self:getSetting("inkaway_device_tip_shown") and self:deviceTipText(true) or nil
    if tip then tip = _(tip) end
    local content_w = self:sheetWidth()
    local function closeSelf() self:closeSheet("_welcome_sheet") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(wd) content[#content + 1] = wd end
        add(self:sheetTitle(_("Ink Away in your books"), content_w, _("Got it"), closeSelf))
        for _i, row in ipairs(c.rows) do
            add(vspan(18))
            add(self:welcomeRow(row, content_w))
        end
        if c.info then
            add(vspan(14))
            add(self:sheetHint(c.info, content_w))
        end
        if #c.warnings > 0 then
            add(vspan(16))
            local pad = Screen:scaleBySize(12)
            local inner = VerticalGroup:new{ align = "left",
                para(_("Not set up"), content_w - 2 * pad, 15, true) }
            for _i, line in ipairs(c.warnings) do
                inner[#inner + 1] = vspan(6)
                inner[#inner + 1] = para(line, content_w - 2 * pad, 14)
            end
            add(FrameContainer:new{ bordersize = Screen:scaleBySize(2), color = BLACK,
                radius = Screen:scaleBySize(12), padding = pad, margin = 0, inner })
        elseif #c.rows > 0 then
            add(vspan(14))
            add(self:sheetHint(_("Both are also in the reader menu: Tools, Ink Away."), content_w))
        end
        if tip then
            local title, body = tip:match("^(.-)\n\n(.*)$")
            add(vspan(18))
            add(para(title or tip, content_w, 17, true))
            add(vspan(4))
            add(para(body or "", content_w, 14))
        end
        return content
    end
    -- seen once shown, however it is closed (Got it, a tap outside, or Ink Away
    -- closing under it), so it never comes back
    self:setSetting("inkaway_welcome_seen", true)
    if tip then self:setSetting("inkaway_device_tip_shown", true) end
    self:showSheet("_welcome_sheet", build)
end

return InkAwayView
