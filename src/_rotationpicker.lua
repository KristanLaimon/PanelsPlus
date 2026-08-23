local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")

--- A tappable wrapper around one child widget.
---
--- @class TapTarget : InputContainer
local TapTarget = InputContainer:extend({})

function TapTarget:init()
    self.dimen = self[1]:getSize()
    self.ges_events.Tap = {
        GestureRange:new({
            ges = "tap",
            range = self.dimen,
        }),
    }
end

function TapTarget:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

--- Build one simplified "device" icon: a bordered rectangle with a short
--- solid bar marking whichever edge is "up" for `direction`, so the icon
--- reads as "this is how the device/page will look after picking me".
---
--- @param direction "up"|"down"|"left"|"right"
--- @param box integer Square bounding size the icon is centered inside.
--- @return CenterContainer icon
local function buildDeviceIcon(direction, box)
    local thick = Size.border.thick
    local long = math.floor(box * 0.62)
    local short = math.floor(box * 0.4)
    local notch_thickness = math.max(thick * 2, 3)
    local gap = Size.padding.small

    local portrait_dir = direction == "up" or direction == "down"
    local body_w = portrait_dir and short or long
    local body_h = portrait_dir and long or short

    -- FrameContainer sizes itself purely from its child's getSize() (its own
    -- width/height fields only affect paint-time clipping, not layout), so
    -- the child here must already report the exact interior size wanted.
    local body = FrameContainer:new({
        bordersize = thick,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        Widget:new({
            dimen = Geom:new({
                w = math.max(1, body_w - 2 * thick),
                h = math.max(1, body_h - 2 * thick),
            }),
        }),
    })

    local notch
    if portrait_dir then
        notch = LineWidget:new({
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new({ w = math.floor(body_w * 0.5), h = notch_thickness }),
        })
    else
        notch = LineWidget:new({
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new({ w = notch_thickness, h = math.floor(body_h * 0.5) }),
        })
    end

    local stacked
    if direction == "up" then
        stacked = VerticalGroup:new({ align = "center", notch, VerticalSpan:new({ width = gap }), body })
    elseif direction == "down" then
        stacked = VerticalGroup:new({ align = "center", body, VerticalSpan:new({ width = gap }), notch })
    elseif direction == "left" then
        stacked = HorizontalGroup:new({ align = "center", notch, HorizontalSpan:new({ width = gap }), body })
    else -- "right"
        stacked = HorizontalGroup:new({ align = "center", body, HorizontalSpan:new({ width = gap }), notch })
    end

    return CenterContainer:new({
        dimen = Geom:new({ w = box, h = box }),
        stacked,
    })
end

--- Modal dialog offering two independent 4-way rotation pickers: one for
--- KOReader's real screen rotation, one for this plugin's own zoomed-view
--- rotation. Stacks the two pickers top/bottom on a portrait screen, or
--- places them side by side on a landscape screen.
---
--- @class RotationPickerDialog : InputContainer
--- @field on_device_rotate fun(direction: "up"|"down"|"left"|"right")|nil
--- @field on_image_rotate fun(direction: "up"|"down"|"left"|"right")|nil
local RotationPickerDialog = InputContainer:extend({
    modal = true,
})

--- Build one labeled picker: a title plus a D-pad layout of 4 device icons.
---
--- @param title string
--- @param kind "device"|"image"
--- @param box_w integer Available width, used to wrap/truncate the title.
--- @param icon_box integer Square size of each direction icon.
--- @return VerticalGroup picker
function RotationPickerDialog:_buildRotationBox(title, kind, box_w, icon_box)
    local dialog = self
    local gap = Size.padding.default

    local function iconFor(direction)
        return TapTarget:new({
            callback = function()
                dialog:_onPick(kind, direction)
            end,
            buildDeviceIcon(direction, icon_box),
        })
    end

    local middle_row = HorizontalGroup:new({
        align = "center",
        iconFor("left"),
        HorizontalSpan:new({ width = icon_box }),
        iconFor("right"),
    })

    local title_widget = TextWidget:new({
        text = title,
        face = Font:getFace("cfont"),
        max_width = box_w,
    })

    return VerticalGroup:new({
        align = "center",
        title_widget,
        VerticalSpan:new({ width = gap }),
        iconFor("up"),
        VerticalSpan:new({ width = gap }),
        middle_row,
        VerticalSpan:new({ width = gap }),
        iconFor("down"),
    })
end

function RotationPickerDialog:_onPick(kind, direction)
    UIManager:close(self, "full")
    if kind == "device" and self.on_device_rotate then
        self.on_device_rotate(direction)
    elseif kind == "image" and self.on_image_rotate then
        self.on_image_rotate(direction)
    end
end

function RotationPickerDialog:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new({ x = 0, y = 0, w = screen_w, h = screen_h })

    local portrait = screen_h >= screen_w
    local outer_w = math.floor(screen_w * 0.9)
    local outer_h = math.floor(screen_h * 0.9)

    local gap = Size.padding.default
    -- Generous single-line estimate; the title is truncated to one line
    -- (TextWidget's default truncate_with_ellipsis), so this is a safe cap.
    local title_h = Screen:scaleBySize(24)
    local button_h = Size.item.height_default
    local frame_chrome_h = 2 * (Size.padding.large + Size.border.window)

    -- Budget left for the two picker boxes after the dialog's own frame
    -- padding/border, the inter-box gap, and the Close button below them.
    local boxes_budget_h = outer_h - frame_chrome_h - Size.padding.large - button_h
    local boxes_budget_w = outer_w - 2 * (Size.padding.large + Size.border.window)

    local box_w = portrait and boxes_budget_w or math.floor((boxes_budget_w - Size.padding.large) / 2)
    local box_h = portrait and math.floor((boxes_budget_h - Size.padding.large) / 2) or boxes_budget_h

    -- Each box stacks 3 icon-sized rows (up / left-right / down) plus a
    -- title line and 3 gaps; the D-pad's middle row is also 3 icons wide.
    local icon_box_by_h = math.floor((box_h - title_h - 3 * gap) / 3)
    local icon_box_by_w = math.floor(box_w / 3)
    local icon_box = math.max(Screen:scaleBySize(20), math.min(icon_box_by_h, icon_box_by_w))

    local device_box = self:_buildRotationBox(_("Device rotation"), "device", box_w, icon_box)
    local image_box = self:_buildRotationBox(_("Image rotation (this view only)"), "image", box_w, icon_box)

    local boxes
    if portrait then
        boxes = VerticalGroup:new({
            align = "center",
            device_box,
            VerticalSpan:new({ width = Size.padding.large }),
            image_box,
        })
    else
        boxes = HorizontalGroup:new({
            align = "center",
            device_box,
            HorizontalSpan:new({ width = Size.padding.large }),
            image_box,
        })
    end

    local close_button = Button:new({
        text = _("Close"),
        width = outer_w - 2 * Size.padding.large,
        callback = function()
            UIManager:close(self, "full")
        end,
    })

    local content = VerticalGroup:new({
        align = "center",
        boxes,
        VerticalSpan:new({ width = Size.padding.large }),
        close_button,
    })

    self[1] = CenterContainer:new({
        dimen = self.dimen,
        FrameContainer:new({
            -- FrameContainer sizes itself from its child, not this field (see
            -- the `body` comment above) -- close_button's forced width below
            -- is what actually drives how wide this ends up.
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            content,
        }),
    })
end

return RotationPickerDialog
