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
            local viewer = PanelViewer:new({ page = 1, reader_ui = ui })
            assert.is_true(viewer:onShow())
            assert.equals(0, registrations)
            assert.is_nil(ui.inkAwayPendingIntegrations)
            viewer:paintTo({}, 0, 0)
            viewer:onCloseWidget()
        end
    end)

    it("still disposes the viewer when Ink Away painting or release fails", function()
        local released, unregistered = 0, 0
        local api = {
            integration_api_version = 1,
            document_surface_version = 1,
            installPluginIntegration = function()
                return function()
                    unregistered = unregistered + 1
                end
            end,
            paintDocumentSurface = function()
                error("paint failed")
            end,
            releaseDocumentSurface = function()
                released = released + 1
                error("release failed")
            end,
        }
        local viewer = PanelViewer:new({ page = 1, reader_ui = { document = {}, inkAwayIntegrationAPI = api } })
        assert.is_true(viewer:onShow())
        viewer:paintTo({}, 0, 0)
        viewer:onCloseWidget()
        assert.equals(1, released)
        assert.equals(1, unregistered)
        assert.is_true(viewer._panels_plus_closed)
        assert.is_nil(viewer._annotation_unregister)
    end)

    it("never registers extracted reflow images as fixed-page annotation surfaces", function()
        local registrations = 0
        local api = {
            integration_api_version = 1,
            document_surface_version = 1,
            installPluginIntegration = function()
                registrations = registrations + 1
                return function() end
            end,
            paintDocumentSurface = function() end,
            releaseDocumentSurface = function() end,
        }
        local viewer = PanelViewer:new({
            page = 1,
            embedded_source_image = {},
            reader_ui = { document = {}, inkAwayIntegrationAPI = api },
        })
        assert.is_true(viewer:onShow())
        assert.is_nil(viewer:getAnnotationSurface())
        assert.equals(0, registrations)
        viewer:onCloseWidget()
    end)
end)
