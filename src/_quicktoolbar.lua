-- Borderless SVG controls for the panel viewer's right-hand action rail.
local Toolbar = {}
local gettext = require("gettext")
local icon_dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "src/") .. "../assets/icons/"

Toolbar.order = { "rotate", "ocr_language", "screenshot", "progress_bar", "scale" }
local icons =
    { rotate = "rotate", ocr_language = "ocr", screenshot = "screenshot", progress_bar = "progress", scale = "scale" }

function Toolbar.caption(id, text)
    if id == "rotate" then
        return gettext("Rotate")
    end
    if id == "ocr_language" then
        return gettext("OCR")
    end
    if id == "screenshot" then
        return gettext("Shot")
    end
    if id == "progress_bar" then
        return text == gettext("Show progress") and gettext("Show") or gettext("Hide")
    end
    return text == gettext("Original size") and "1:1" or gettext("Fit")
end

function Toolbar.controls(actions)
    local controls = {}
    for _, id in ipairs(Toolbar.order) do
        local action = actions[id]
        local control = {
            id = id,
            callback = action.callback,
            hold_callback = action.hold_callback,
            icon_file = icon_dir .. icons[id] .. ".svg",
            width = 0,
        }
        function control:setText(text)
            self.text = Toolbar.caption(self.id, text)
        end
        control:setText(action.text)
        controls[id] = control
    end
    return controls
end

function Toolbar.width(viewer_width, scale)
    return math.max(1, math.min(scale(72), math.floor(viewer_width * 0.22)))
end

function Toolbar.free(controls)
    for _, control in pairs(controls or {}) do
        if control.widget then
            control.widget:free()
            control.widget = nil
        end
    end
end

function Toolbar.build(controls, width, height, horizontal)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local IconWidget = require("ui/widget/iconwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    local Screen = require("device").screen
    local Tile = InputContainer:extend({})
    function Tile:init()
        self.dimen = Geom:new({ w = self.width, h = self.height })
        -- Generic viewer events propagate to children without gesture hit-testing.
        -- Distinct names ensure actions run only after this tile's range matches.
        self.ges_events.QuickActionTap = { GestureRange:new({ ges = "tap", range = self.dimen }) }
        self.ges_events.QuickActionHold = { GestureRange:new({ ges = "hold", range = self.dimen }) }
        self.ges_events.QuickActionHoldRelease = { GestureRange:new({ ges = "hold_release", range = self.dimen }) }
    end
    function Tile:onQuickActionTap()
        self.control.callback()
        return true
    end
    function Tile:onQuickActionHold()
        if self.control.hold_callback then
            self.control.hold_callback()
        end
        return true
    end
    function Tile:onQuickActionHoldRelease()
        return true
    end
    local item_height =
        math.max(1, math.min(Screen:scaleBySize(64), horizontal and height or math.floor(height / #Toolbar.order)))
    local item_width = horizontal and math.max(1, math.min(Screen:scaleBySize(72), math.floor(width / #Toolbar.order)))
        or width
    local Group = horizontal and require("ui/widget/horizontalgroup") or VerticalGroup
    local rail = Group:new({ align = "center", allow_mirroring = false })
    for _, id in ipairs(Toolbar.order) do
        local control = controls[id]
        control.width = item_width
        local caption =
            TextWidget:new({ text = control.text, face = Font:getFace("cfont", 11), max_width = item_width - 4 })
        local icon_size = math.max(
            1,
            math.min(Screen:scaleBySize(40), item_width - Screen:scaleBySize(12), item_height - caption:getSize().h)
        )
        local content = VerticalGroup:new({
            align = "center",
            IconWidget:new({ file = control.icon_file, width = icon_size, height = icon_size, alpha = true }),
            caption,
        })
        local tile = Tile:new({
            width = item_width,
            height = item_height,
            control = control,
            CenterContainer:new({ dimen = Geom:new({ w = item_width, h = item_height }), content }),
        })
        control.widget = tile
        rail[#rail + 1] = tile
    end
    return rail
end

return Toolbar
