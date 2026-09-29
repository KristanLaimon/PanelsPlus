local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local ImageViewer = require("ui/widget/imageviewer")
local Memory = require("src._memory")
local Cache = require("src.cache")
local UIManager = require("ui/uimanager")

describe("Low-memory resource lifecycle", function()
    it("bounds tall fixed-page renders before allocating their raster", function()
        local PageBitmap = require("src._pagebitmap")
        local rendered_w, rendered_h
        PageBitmap.build({
            getNativePageDimensions = function()
                return { w = 1200, h = 12000 }
            end,
            transformRect = function(_, rect, zoom)
                return { w = rect.w * zoom, h = rect.h * zoom }
            end,
            renderPage = function(_, _, rect)
                rendered_w, rendered_h = rect.scaled_rect.w, rect.scaled_rect.h
                return nil
            end,
        }, 1, { segment_target_width = 480 })
        assert.equals(96, rendered_w)
        assert.equals(960, rendered_h)
    end)
    it("frees a viewer image exactly once when the base viewer owns cleanup", function()
        local original = ImageViewer.onCloseWidget
        local frees = 0
        local viewer = PanelViewer:new({
            image = {
                free = function()
                    frees = frees + 1
                end,
            },
            image_disposable = true,
        })
        ImageViewer.onCloseWidget = function(self)
            self.image:free()
            self.image = nil
        end
        local ok, err = pcall(viewer.onCloseWidget, viewer)
        ImageViewer.onCloseWidget = original
        assert.is_true(ok, tostring(err))
        assert.equals(1, frees)
    end)

    it("releases the owned first boundary tile when rendering the second fails", function()
        local frees, fallbacks = 0, 0
        local rect = { x = 0, y = 0, w = 100, h = 100 }
        local viewer = PanelViewer:new({
            crop_mode = "none",
            auto_rotate_double_pages = false,
            _images_list_cur = 1,
            image_rects = { rect },
            _images_list = {
                function()
                    return {
                        free = function()
                            frees = frees + 1
                        end,
                    }
                end,
            },
            nav_boundary_peek_callback = function()
                return {
                    target_rect = rect,
                    start_idx = 1,
                    next_images = {
                        function()
                            error("render failure")
                        end,
                    },
                }
            end,
            boundary_callback = function()
                fallbacks = fallbacks + 1
                return true
            end,
        })
        assert.is_true(viewer:animateBoundaryTransition("next"))
        assert.equals(1, frees)
        assert.equals(1, fallbacks)
    end)

    it("rechecks memory at execution and rejects canceled prefetch callbacks", function()
        local original = Memory.hasHeadroom
        local enough, calls = true, 0
        Memory.hasHeadroom = function()
            return enough
        end
        local instance = setmetatable({
            ui = { document = {} },
            settings = {},
            panel_prefetch_actions = {},
            panel_cache = {},
            getDetector = function()
                return "components"
            end,
            collectPanels = function()
                calls = calls + 1
            end,
        }, { __index = Cache })
        local ok, err = pcall(function()
            instance:preloadPanels(2)
            local pending = UIManager._last_scheduled
            enough = false
            pending()
            assert.equals(0, calls)
            enough = true
            instance:preloadPanels(2)
            pending = UIManager._last_scheduled
            instance:cancelPanelPrefetch()
            pending()
            assert.equals(0, calls)
            instance:preloadPanels(2)
            UIManager._last_scheduled()
            assert.equals(1, calls)
        end)
        Memory.hasHeadroom = original
        assert.is_true(ok, tostring(err))
    end)
end)
