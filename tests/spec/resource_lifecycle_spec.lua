local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local ImageViewer = require("ui/widget/imageviewer")
local Memory = require("src._memory")
local Cache = require("src.cache")
local UIManager = require("ui/uimanager")
local PanelsPlus = require("main")

describe("Low-memory resource lifecycle", function()
    it("reuses bounded Smart and Safe results across 300 finding-mode changes", function()
        local Collector = require("src._panelcollector")
        local original = Collector.collect
        local detections = 0
        Collector.collect = function(_, settings)
            detections = detections + 1
            return { { x = settings.panel_finding_mode == "smart" and 10 or 20, y = 0, w = 100, h = 100 } }
        end
        local instance = setmetatable({
            ui = { document = {} },
            settings = { panel_finding_mode = "smart" },
            panel_cache = {},
            panel_cache_order = {},
            panel_prefetch_actions = {},
            saveSettings = function() end,
            saveDocSettings = function() end,
        }, { __index = PanelsPlus })
        local ok, err = pcall(function()
            for i = 1, 300 do
                instance:setPanelFindingMode(i % 2 == 0 and "smart" or "safe")
                local panels = instance:collectPanels(7)
                assert.equals(i % 2 == 0 and 10 or 20, panels[1].x)
            end
            assert.equals(2, detections)
            assert.equals(2, #instance.panel_cache_order)
            instance:clearPanelCache()
            assert.is_nil(next(instance.panel_cache))
        end)
        Collector.collect = original
        assert.is_true(ok, tostring(err))
    end)

    it("frees every detached button container during repeated settings changes", function()
        local frees = 0
        local viewer = PanelViewer:new({ width = 600 })
        for _ = 1, 100 do
            viewer.button_container = {
                free = function()
                    frees = frees + 1
                end,
            }
            viewer:replaceButtonTable()
        end
        assert.equals(100, frees)
    end)

    it("disarms a pending hardware swipe when switching Animated navigation to Classic", function()
        local Controller = require("src.viewer_controller")
        local Screen = require("device").screen
        local original = Screen.setSwipeAnimations
        local animated = true
        Screen.setSwipeAnimations = function(_, enabled)
            animated = enabled
        end
        local controller = setmetatable({
            settings = { nav_transition_mode = "animated" },
            setNavTransitionMode = PanelsPlus.setNavTransitionMode,
            saveSettings = function() end,
            saveDocSettings = function() end,
        }, { __index = Controller })
        local viewer = { replaceButtonTable = function() end, update = function() end }
        local ok, err = pcall(controller.toggleViewerNavTransitionMode, controller, viewer)
        Screen.setSwipeAnimations = original
        assert.is_true(ok, tostring(err))
        assert.equals("classic", viewer.nav_transition_mode)
        assert.is_false(animated)
    end)

    it("skips optional fold copies before scanning when the full-page copy cannot fit", function()
        local FoldJoin = require("src._foldjoin")
        local original = Memory.freeBytes
        Memory.freeBytes = function()
            return 48 * 1024 * 1024
        end
        local ok, joined = pcall(FoldJoin.joinBitmap, {
            getWidth = function()
                return 3000
            end,
            getHeight = function()
                return 2000
            end,
            getPixel = function()
                error("must not scan or allocate the optional copy")
            end,
        })
        Memory.freeBytes = original
        assert.is_true(ok, tostring(joined))
        assert.is_nil(joined)
    end)

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

    it("defers next-page detection after a memory dip and rejects stale callbacks", function()
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
            assert.is_nil(instance.panel_prefetch_actions[instance:getPanelCacheKey(2)])
            enough = true
            instance:preloadPanels(2)
            UIManager._last_scheduled()
            assert.equals(1, calls)
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

    it("reserves the next panel tile before warming it and rechecks memory at execution", function()
        local ViewerController = require("src.viewer_controller")
        local PageRender = require("src._pagerender")
        local original_headroom = Memory.hasHeadroom
        local original_allocation_headroom = Memory.hasAllocationHeadroom
        local original_draw = PageRender.drawPagePart
        local rendered, enough = 0, false
        local requested_floor, requested_bytes
        Memory.hasHeadroom = function()
            return true
        end
        Memory.hasAllocationHeadroom = function(floor, bytes)
            requested_floor, requested_bytes = floor, bytes
            return enough
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
            assert.equals(0, rendered)
            assert.equals(40 * 1024 * 1024, requested_floor)
            assert.equals(600 * 800 * 4, requested_bytes)
            enough = true
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
