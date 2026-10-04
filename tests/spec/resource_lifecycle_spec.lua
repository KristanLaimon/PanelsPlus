local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local ImageViewer = require("ui/widget/imageviewer")
local Memory = require("src._memory")
local Cache = require("src.cache")
local UIManager = require("ui/uimanager")
local PanelsPlus = require("main")

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

    it("releases deferred old panel images if the viewer closes before the next UI tick", function()
        local original_close = ImageViewer.onCloseWidget
        local original_tick = UIManager.tickAfterNext
        local callbacks, frees = {}, 0
        UIManager.tickAfterNext = function(_, callback)
            callbacks[#callbacks + 1] = callback
        end
        ImageViewer.onCloseWidget = function(self)
            self.image:free()
            self.image = nil
        end
        local viewer = PanelViewer:new({
            image_disposable = true,
            image = {
                free = function()
                    frees = frees + 1
                end,
            },
        })
        viewer:releasePreviousPanelImage({
            free = function()
                frees = frees + 1
            end,
        })
        viewer:releasePreviousPanelImage({
            free = function()
                frees = frees + 1
            end,
        })
        local ok, err = pcall(viewer.onCloseWidget, viewer)
        for _, callback in ipairs(callbacks) do
            callback()
        end
        ImageViewer.onCloseWidget = original_close
        UIManager.tickAfterNext = original_tick
        assert.is_true(ok, tostring(err))
        assert.equals(3, frees)
        assert.is_nil(viewer._pending_panel_images)
    end)

    it("closes all reader-owned panel windows before disposing the document", function()
        local original_stack, original_close = UIManager._window_stack, UIManager.close
        local reader = { document = {} }
        local other_reader = {}
        local closed = {}
        local first = { name = PanelViewer.name, reader_ui = reader }
        local embedded = { name = PanelViewer.name, reader_ui = reader }
        local unrelated = { name = PanelViewer.name, reader_ui = other_reader }
        UIManager._window_stack = {
            { widget = first },
            { widget = unrelated },
            { widget = embedded },
        }
        UIManager.close = function(_, viewer)
            closed[#closed + 1] = viewer
            for i = #UIManager._window_stack, 1, -1 do
                if UIManager._window_stack[i].widget == viewer then
                    table.remove(UIManager._window_stack, i)
                end
            end
        end
        local plugin = setmetatable({
            ui = reader,
            settings = {},
            active_panel_viewer = first,
            cancelEmbeddedImageSearch = function() end,
            cancelPanelPrefetch = function() end,
            cancelPanelPrerender = function() end,
            clearPanelCache = function() end,
            removePanelGestureZones = function() end,
            restoreNativePanelZoom = function() end,
            removeReadingPageFold = function()
                assert.is_not_nil(reader.document)
                assert.equals(2, #closed)
            end,
        }, { __index = PanelsPlus })
        local remaining
        local ok, err = pcall(function()
            plugin:onCloseDocument()
            remaining = UIManager._window_stack[1].widget
            reader.document = nil
            plugin:onCloseWidget()
        end)
        UIManager._window_stack = original_stack
        UIManager.close = original_close
        assert.is_true(ok, tostring(err))
        assert.equals(2, #closed)
        assert.equals(embedded, closed[1])
        assert.equals(first, closed[2])
        assert.equals(unrelated, remaining)
        assert.is_nil(plugin.active_panel_viewer)
    end)

    it("closes a panel window on reader teardown even without CloseDocument", function()
        local original_stack, original_close = UIManager._window_stack, UIManager.close
        local reader = {}
        local viewer = { name = PanelViewer.name, reader_ui = reader }
        local closed = 0
        UIManager._window_stack = { { widget = viewer } }
        UIManager.close = function()
            closed = closed + 1
            UIManager._window_stack = {}
        end
        local plugin = setmetatable({
            ui = reader,
            settings = {},
            cancelEmbeddedImageSearch = function() end,
            cancelPanelPrefetch = function() end,
            cancelPanelPrerender = function() end,
            clearPanelCache = function() end,
            removePanelGestureZones = function() end,
            restoreNativePanelZoom = function() end,
            removeReadingPageFold = function() end,
        }, { __index = PanelsPlus })
        local ok, err = pcall(plugin.onCloseWidget, plugin)
        UIManager._window_stack = original_stack
        UIManager.close = original_close
        assert.is_true(ok, tostring(err))
        assert.equals(1, closed)
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

    it("keeps queued next-page detection after a memory dip and rejects stale callbacks", function()
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
            assert.equals(1, calls)
            enough = true
            instance:preloadPanels(3)
            pending = UIManager._last_scheduled
            instance:cancelPanelPrefetch()
            pending()
            assert.equals(1, calls)
            instance:preloadPanels(4)
            instance.ui.document = {}
            UIManager._last_scheduled()
            assert.equals(1, calls)
            enough = false
            instance:preloadPanels(5)
            assert.equals(1, calls)
        end)
        Memory.hasHeadroom = original
        assert.is_true(ok, tostring(err))
    end)

    it("drops obsolete prefetches while moving quickly between pages", function()
        local calls = {}
        local instance = setmetatable({
            ui = {
                document = {
                    getNextPage = function(_, page)
                        return page + 1
                    end,
                },
            },
            settings = {},
            panel_prefetch_actions = {},
            panel_cache = {},
            getDetector = function()
                return "components"
            end,
            collectPanels = function(_, page)
                calls[#calls + 1] = page
            end,
        }, { __index = Cache })
        instance:preloadNextPanels(1)
        local stale = UIManager._last_scheduled
        instance:preloadNextPanels(2)
        local current = UIManager._last_scheduled
        assert.is_nil(instance.panel_prefetch_actions[instance:getPanelCacheKey(2)])
        assert.is_not_nil(instance.panel_prefetch_actions[instance:getPanelCacheKey(3)])
        stale()
        current()
        assert.equals(1, #calls)
        assert.equals(3, calls[1])
    end)

    it("warms the next panel with the stable 40MB memory floor", function()
        local ViewerController = require("src.viewer_controller")
        local PageRender = require("src._pagerender")
        local original_headroom = Memory.hasHeadroom
        local original_allocation_headroom = Memory.hasAllocationHeadroom
        local original_draw = PageRender.drawPagePart
        local rendered = 0
        Memory.hasHeadroom = function()
            return true
        end
        Memory.hasAllocationHeadroom = function()
            return false
        end
        PageRender.drawPagePart = function()
            rendered = rendered + 1
        end
        local document = {}
        local controller = setmetatable({
            settings = {},
            ui = { document = document },
        }, { __index = ViewerController })
        local ok, err = pcall(function()
            controller:prerenderNextPanel({
                page = 1,
                image_rects = { { x = 0, y = 0, w = 10, h = 10 }, { x = 10, y = 0, w = 10, h = 10 } },
            }, 1)
            UIManager._last_scheduled()
            assert.equals(1, rendered)
        end)
        Memory.hasHeadroom = original_headroom
        Memory.hasAllocationHeadroom = original_allocation_headroom
        PageRender.drawPagePart = original_draw
        assert.is_true(ok, tostring(err))
    end)
end)
