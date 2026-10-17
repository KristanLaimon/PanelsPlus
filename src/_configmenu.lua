-- Use KOReader's leading shortcut slot for SVGs, keeping its normal text,
-- right-hand values, focus navigation, pagination, and menu lifecycle.
local ConfigMenu = {}
local icon_dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "src/") .. "../assets/icons/"

function ConfigMenu.new(options)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local icon_size = Screen:scaleBySize(28)
    options.is_enable_shortcut = true
    options.item_shortcuts = { "Q", "W", "E", "R", "T", "Y", "U", "I", "O" }
    options.width = math.floor(Screen:getWidth() * 0.9)
    options.height = math.floor(Screen:getHeight() * 0.9)
    options.items_per_page = math.min(
        #options.item_table,
        math.max(4, math.floor((options.height - Screen:scaleBySize(120)) / Screen:scaleBySize(52)))
    )
    options.items_font_size = 18
    for _, item in ipairs(options.item_table) do
        item.shortcut_icon_width = icon_size
        item.icon_file = icon_dir .. item.id .. ".svg"
    end
    function options:getItemShortCutIcon(dimen, key)
        local slot
        for index, shortcut in ipairs(self.item_shortcuts) do
            if shortcut == key then
                slot = index
                break
            end
        end
        local item = self.item_table[(self.page - 1) * self.perpage + slot]
        local IconWidget = require("ui/widget/iconwidget")
        return require("ui/widget/container/centercontainer"):new({
            dimen = dimen,
            IconWidget:new({ file = item.icon_file, width = icon_size, height = icon_size, alpha = true }),
        })
    end
    return Menu:new(options)
end

return ConfigMenu
