-- Real selected Kobo action definitions; Bluetooth hardware and Dispatcher are fixtures.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, check = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")

return function(reference)
    local environment = setmetatable({
        require = function(name)
            if name == "src/lib/bluetooth/dispatcher_helper" then
                return {
                    get_dispatcher_actions_ordered = function()
                        return nil
                    end,
                }
            elseif name == "dispatcher" then
                return nil
            end
            return require(name)
        end,
    }, { __index = _G })
    local Actions = assert(loadfile(reference .. "/src/lib/bluetooth/available_actions.lua", "t", environment))()
    local actions = {}
    for _, category in ipairs(Actions.get_all_actions()) do
        for _, action in ipairs(category.actions) do
            actions[action.id] = action
        end
    end
    describe("Kobo page-turner action integration", function()
        for _, name in ipairs({ "next_page", "prev_page" }) do
            it("routes the selected plugin's " .. name .. " action to panel navigation", function()
                local action = actions[name]
                check.is_not_nil(action)
                local direction
                local viewer = PanelViewer:new({
                    onShowNextImage = function()
                        direction = "next"
                        return true
                    end,
                    onShowPrevImage = function()
                        direction = "previous"
                        return true
                    end,
                })
                check.is_true(viewer["on" .. action.event](viewer, action.args))
                check.equals(name == "next_page" and "next" or "previous", direction)
            end)
        end
    end)
end
