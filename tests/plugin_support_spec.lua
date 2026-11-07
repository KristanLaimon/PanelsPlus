local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")

describe("Optional plugin support", function()
    it("opens and closes normally when Ink Away is absent", function()
        local ui = { document = {} }
        local viewer = PanelViewer:new({ reader_ui = ui })
        assert.is_true(viewer:onShow())
        assert.is_true(ui.inkAwayPendingIntegrations[viewer])
        viewer:onCloseWidget()
        assert.is_nil(ui.inkAwayPendingIntegrations)
    end)

    it("does not use an unavailable or incompatible Ink Away API", function()
        for _, api in ipairs({ {}, { integration_api_version = 2, document_surface_version = 1 } }) do
            local registrations = 0
            api.registerRenderingView = function()
                registrations = registrations + 1
                return function() end
            end
            local ui = { document = {}, inkAwayIntegrationAPI = api }
            local viewer = PanelViewer:new({ reader_ui = ui })
            assert.is_true(viewer:onShow())
            assert.equals(0, registrations)
            assert.is_nil(ui.inkAwayPendingIntegrations)
            viewer:paintTo({}, 0, 0)
            viewer:onCloseWidget()
        end
    end)
end)
