--[[
Panels+
File: tests/spec/panelcollector_spec.lua
Name: PanelCollector specs
Description: Verifies Deep detector integration and full-page continuity at page boundaries.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy
local Collector = require("src._panelcollector")
local Bitmap = require("src._pagebitmap")
local Native = require("src._nativedetector")
local Normal = require("src._componentdetector")
local Legacy = require("src._legacycomponentdetector")
local Controller = require("src.viewer_controller")
local Settings = require("src._settings")
local UIManager = require("ui/uimanager")

local function document()
    return {
        getNativePageDimensions = function()
            return { w = 960, h = 1280 }
        end,
        getNextPage = function(_, page)
            return page == 1 and 2 or 0
        end,
        getPrevPage = function(_, page)
            return page == 2 and 1 or 0
        end,
    }
end

describe("Reader component detector integration", function()
    it("routes maps to the selected detector", function()
        local old_build, old_legacy, old_normal = Bitmap.build, Legacy.detectPage, Normal.detectPage
        Bitmap.build = function()
            return { native_w = 960, native_h = 1280 }
        end
        Legacy.detectPage = function()
            return { { x = 10, y = 0, w = 100, h = 100 } }
        end
        Normal.detectPage = function()
            return { { x = 20, y = 0, w = 100, h = 100 } }
        end
        local legacy_panels = Collector.collect({ document = document() }, { panel_finding_mode = "legacy" }, 1)
        local normal_panels = Collector.collect({ document = document() }, { panel_finding_mode = "normal" }, 1)
        local default_panels = Collector.collect({ document = document() }, {}, 1)
        Bitmap.build, Legacy.detectPage, Normal.detectPage = old_build, old_legacy, old_normal
        assert.equals(10, legacy_panels[1].x)
        assert.equals(20, normal_panels[1].x)
        assert.equals(10, default_panels[1].x)
    end)

    it("activates the new detector for existing saved settings", function()
        local settings = Settings.withDefaults({ detector = "exact", embedded_detector = "exact" })
        assert.equals("components", settings.detector)
        assert.equals("components", settings.embedded_detector)
        assert.equals("legacy", settings.panel_finding_mode)
        assert.equals("legacy", Settings.withDefaults({ panel_finding_mode = "safe" }).panel_finding_mode)
        assert.equals("legacy", Settings.withDefaults({ panel_finding_mode = "classic" }).panel_finding_mode)
        assert.equals("normal", Settings.withDefaults({ panel_finding_mode = "aggressive" }).panel_finding_mode)
        assert.equals("normal", Settings.withDefaults({ panel_finding_mode = "detailed" }).panel_finding_mode)
    end)

    it("keeps a blank bitmap in panel view without probing the native detector", function()
        local old_build, old_collect = Bitmap.build, Native.collect
        Bitmap.build = function()
            local data = {}
            for i = 0, 15 do
                data[i] = 0
            end
            return { w = 4, h = 4, native_w = 960, native_h = 1280, scale_x = 240, scale_y = 320, data = data, ink = 0 }
        end
        local calls = 0
        Native.collect = function()
            calls = calls + 1
            return {}
        end
        local panels = Collector.collect({ document = document() }, { mode = "manga" }, 1)
        Bitmap.build, Native.collect = old_build, old_collect
        assert.equals(0, calls)
        assert.equals(1, #panels)
        assert.equals(960, panels[1].w)
        assert.equals(1280, panels[1].h)
    end)

    it("retains native fallback results and supplies a full page if native finds nothing", function()
        local old_build, old_collect = Bitmap.build, Native.collect
        Bitmap.build = function()
            return nil
        end
        local native_panels = { { x = 10, y = 20, w = 300, h = 400 } }
        Native.collect = function()
            return native_panels
        end
        local panels = Collector.collect({ document = document() }, {}, 1)
        native_panels = {}
        local blank = Collector.collect({ document = document() }, {}, 2)
        Bitmap.build, Native.collect = old_build, old_collect
        assert.equals(300, panels[1].w)
        assert.equals(1, #blank)
        assert.equals(1280, blank[1].h)
    end)
end)

describe("Viewer page boundaries with no detected panels", function()
    it("resolves an empty cached page to a full-page view in either direction", function()
        local old_build = Collector.buildImages
        Collector.buildImages = function(_, _, panels)
            return { {} }, panels, { true }
        end
        local controller = setmetatable({
            settings = {},
            ui = { document = document() },
            getCachedPanels = function()
                return {}
            end,
        }, { __index = Controller })
        local forward = controller:resolveBoundaryTarget("next", { page = 1 })
        local backward = controller:resolveBoundaryTarget("previous", { page = 2 })
        Collector.buildImages = old_build
        assert.equals(2, forward.next_page)
        assert.equals(1, backward.next_page)
        assert.is_true(forward.target_is_full_page)
        assert.equals(960, forward.target_rect.w)
        assert.equals(1280, backward.target_rect.h)
    end)

    it("opens an uncached blank page inside the viewer instead of exiting", function()
        local old_tick = UIManager.tickAfterNext
        UIManager.tickAfterNext = function(_, callback)
            callback()
        end
        local opened, closed = spy(), spy()
        local controller = setmetatable({
            ui = { document = document(), handleEvent = spy() },
            getCachedPanels = function() end,
            collectPanels = function()
                return {}
            end,
            showPanelViewerForPage = opened,
        }, { __index = Controller })
        controller:onPanelViewerBoundary("next", { page = 1, onClose = closed })
        UIManager.tickAfterNext = old_tick
        assert.is_false(closed:called())
        assert.equals(1, opened:callCount())
        assert.equals(2, opened:lastCall()[2])
        assert.equals(1280, opened:lastCall()[3][1].h)
    end)

    it("stays on the final page when there is no adjacent document page", function()
        local closed = spy()
        local viewer = { page = 2, onClose = closed }
        Controller.onPanelViewerBoundary({ ui = { document = document() } }, "next", viewer)
        assert.is_false(closed:called())
        assert.is_nil(viewer._panels_plus_boundary_pending)
    end)
end)

describe("Viewer panel finding selection", function()
    it("redetects and reopens at the panel nearest the current position", function()
        local old_close = UIManager.close
        local closed = spy()
        UIManager.close = closed
        local new_panels = {
            { x = 0, y = 0, w = 90, h = 100 },
            { x = 100, y = 0, w = 90, h = 100 },
        }
        local reopened = spy()
        local controller = setmetatable({
            settings = { panel_finding_mode = "normal" },
            setPanelFindingMode = function(self, mode)
                self.settings.panel_finding_mode = mode
            end,
            collectPanels = function()
                return new_panels
            end,
            showPanelViewerForPage = reopened,
        }, { __index = Controller })
        local viewer = {
            page = 3,
            _images_list_cur = 1,
            panels = { { x = 105, y = 5, w = 80, h = 80 } },
        }
        controller:toggleViewerPanelFindingMode(viewer)
        UIManager.close = old_close
        assert.equals("legacy", controller.settings.panel_finding_mode)
        assert.is_true(closed:called())
        assert.equals(viewer, closed:lastCall()[2])
        assert.equals(3, reopened:lastCall()[2])
        assert.equals(new_panels, reopened:lastCall()[3])
        assert.equals(2, reopened:lastCall()[4])
        assert.is_true(reopened:lastCall()[5].buttons_visible)
    end)
end)
