-- Meguru reader coordinates refer to a spread; detection uses native pages.
local Meguru = {}

function Meguru.attach(controller_class)
    function controller_class:mapPanelPosition(position)
        local document = self.ui.document
        if document.provider == "meguru" and type(document.spreadPageAt) == "function" then
            position.page, position.x, position.y = document:spreadPageAt(position.page, position.x, position.y)
        end
        return position
    end
end

return Meguru
