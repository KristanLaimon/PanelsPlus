--[[
The font chooser: KOReader's Menu with each row drawn in its own font, so the list
previews the fonts.
]]

local Button = require("ui/widget/button")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Theme = require("ink/ui/theme")

local Screen = Device.screen

local FontMenu = Menu:extend{}
-- The base Menu paints its popup at the top left: InputContainer:paintTo resets
-- self.dimen to the paint origin, so a position set in init is lost. The popup is
-- painted centred inside `center_rect` (the drawing area, clear of the toolbar and
-- the notebook bar) instead, and self.dimen follows, so refreshes and hit boxes
-- match.
function FontMenu:init()
    Menu.init(self)
    local cr = self.center_rect
        or { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._ox = cr.x + math.floor((cr.w - self.dimen.w) / 2)
    self._oy = cr.y + math.floor((cr.h - self.dimen.h) / 2)
    self.dimen.x, self.dimen.y = self._ox, self._oy
end
function FontMenu:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x + (self._ox or 0), y + (self._oy or 0))
    -- dark (see ink/ui/theme.lua): the whole popup, each row in its font
    local d = self.dimen
    if d then Theme.apply(bb, self, d.x, d.y, d.w, d.h, self[1] and self[1].radius or 0) end
end
function FontMenu:updateItems(select_number, no_recalculate_dimen)
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)
    local idx0 = (self.page - 1) * self.perpage
    for i = 1, self.perpage do
        local item = self.item_table[idx0 + i]
        if not item then break end
        local btn = Button:new{
            text = item.text,
            text_font_face = item.preview_font or "smallinfofont",
            text_font_size = self.font_size,
            text_font_bold = false,
            align = "left",
            width = self.inner_dimen.w,
            max_width = self.inner_dimen.w,
            height = self.item_dimen.h,   -- fixed row height so a page never
                                          -- overflows onto the page buttons
            bordersize = 0,
            margin = 0,
            radius = 0,
            padding_v = 0,
            padding_h = Screen:scaleBySize(16),   -- some room at the left
            callback = item.callback,
            show_parent = self.show_parent,
        }
        table.insert(self.item_group, btn)
        table.insert(self.layout, { btn })
    end
    self:updatePageInfo(select_number)
    if self.mergeTitleBarIntoLayout then self:mergeTitleBarIntoLayout() end
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

return FontMenu
