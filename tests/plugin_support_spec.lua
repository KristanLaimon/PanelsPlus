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

    it("shows Draw only after successful Ink Away registration and opens annotation", function()
        local draws = 0
        local api = {
            integration_api_version = 1,
            document_surface_version = 1,
            installPluginIntegration = function()
                return function() end
            end,
            paintDocumentSurface = function() end,
            releaseDocumentSurface = function() end,
            onInkAwayAnnotate = function()
                draws = draws + 1
            end,
        }
        local v = PanelViewer:new({ page = 1, reader_ui = { document = {}, inkaway = api } })
        v:replaceButtonTable()
        assert.is_nil(v.quick_controls.draw_inkaway, "presence alone is insufficient")
        v.reader_ui.inkAwayIntegrationAPI = api
        v:onShow()
        local draw = v.quick_controls.draw_inkaway
        assert.is_not_nil(draw)
        assert.equals("Draw (Ink-away)", draw.text)
        draw.callback()
        assert.equals(1, draws)
        v:onCloseWidget()

        local annotate = api.onInkAwayAnnotate
        api.onInkAwayAnnotate = setmetatable({}, {
            __call = function(_, instance)
                return annotate(instance)
            end,
        })
        v = PanelViewer:new({ page = 1, reader_ui = { document = {}, inkAwayIntegrationAPI = api } })
        v:onShow()
        assert.is_not_nil(v.quick_controls.draw_inkaway, "KOReader wraps handlers in callable tables")
        v.quick_controls.draw_inkaway.callback()
        assert.equals(2, draws)
        v:onCloseWidget()

        api.installPluginIntegration = function()
            error("registration failed")
        end
        v = PanelViewer:new({ page = 1, reader_ui = { document = {}, inkAwayIntegrationAPI = api } })
        v:onShow()
        v:replaceButtonTable()
        assert.is_nil(v.quick_controls.draw_inkaway)
        v:onCloseWidget()
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
