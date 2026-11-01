-- Reference-backed integration checks: real Meguru document/spread geometry,
-- Panels+ gesture entry and panel selection; rendering/network/UI are fixtures.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, check = framework.describe, framework.it, framework.assert
local ViewerController = require("src.viewer_controller")
local Screen = require("device").screen
local Collector = require("src._panelcollector")
local HostDocument = require("document/document")
local Geom = require("ui/geometry")

return function(reference)
    local rotation = 0
    local base = {}
    function base:extend(fields)
        return setmetatable(fields, { __index = self })
    end
    function base:transformRect(rect, zoom)
        return Geom:new({ x = (rect.x or 0) * zoom, y = (rect.y or 0) * zoom, w = rect.w * zoom, h = rect.h * zoom })
    end
    local dependencies = {
        ["document/document"] = base,
        ["ui/geometry"] = Geom,
        ["document/canvascontext"] = {
            getSize = function()
                return { w = 1200, h = 800 }
            end,
        },
        ["ffi/drawcontext"] = {
            new = function()
                return {}
            end,
        },
        ["ffi"] = { C = {} },
        ["device"] = {
            screen = setmetatable({
                getRotationMode = function()
                    return rotation
                end,
            }, { __index = Screen }),
        },
        ["meguru/spread"] = assert(loadfile(reference .. "/meguru/spread.lua"))(),
    }
    -- Keep Meguru's base-class shims local to this fixture. Its actual document
    -- module is loaded in full, without executing native/network dependencies.
    local environment = setmetatable({
        require = function(name)
            return dependencies[name] or {}
        end,
    }, { __index = _G })
    local Document = assert(loadfile(reference .. "/meguru/doc/document.lua", "t", environment))()

    local function document(mode, rtl)
        local doc = setmetatable({
            configurable = { spread = mode, spread_gutter = 1, spread_offset = 1 },
            info = { number_of_pages = 8 },
            dims = { [2] = { w = 600, h = 1000 }, [3] = { w = 800, h = 1200 } },
            wide_list = {},
            dead_pages = {},
            fetch_failed = {},
            spread_rtl = rtl,
        }, { __index = Document })
        function doc:getPageDims(page)
            return self.dims[page]
        end
        function doc:getPageBBox(page)
            local size = self.dims[page]
            return { x0 = 40, y0 = 60, x1 = size.w - 30, y1 = size.h - 50 }
        end
        return doc
    end

    local function open(doc, point, expected_page, expected_index)
        local original = { page = point.page, x = point.x, y = point.y }
        local collected, shown
        local controller = setmetatable({
            ui = { document = doc },
            collectPanels = function(_, page, pos)
                collected = { page = page, x = pos.x, y = pos.y }
                local size = doc:getPageDims(page)
                return {
                    { x = 0, y = 0, w = size.w, h = size.h / 2 },
                    { x = 0, y = size.h / 2, w = size.w, h = size.h / 2 },
                }
            end,
            showPanelViewerForPage = function(_, page, _, index)
                shown = { page = page, index = index }
                return true
            end,
        }, { __index = ViewerController })
        local highlight = {
            clear = function() end,
            view = {
                screenToPageTransform = function(_, pos)
                    -- KOReader has already undone screen zoom and offsets here.
                    return { page = point.page, x = (pos.x - 17) / 0.5, y = (pos.y - 23) / 0.5 }
                end,
            },
        }
        check.is_true(
            controller:showPanelSequence(highlight, { pos = { x = point.x * 0.5 + 17, y = point.y * 0.5 + 23 } })
        )
        check.equals(expected_page, collected.page)
        check.equals(expected_page, shown.page)
        check.equals(expected_index, shown.index)
        check.equals(original.x, point.x)
        check.equals(original.y, point.y)
        return collected
    end

    describe("Meguru spread gesture integration (geometry with KOReader fixtures)", function()
        for _, mode in ipairs({ "on", "auto" }) do
            for _, rtl in ipairs({ false, true }) do
                it("selects both pages and panel rows: " .. mode .. ", RTL=" .. tostring(rtl), function()
                    rotation = 1
                    local doc = document(mode, rtl)
                    for _, gutter in ipairs({ 0, 1 }) do
                        for _, fit_type in ipairs({ 1, 2 }) do
                            doc.configurable.spread_gutter = gutter
                            doc.configurable.zoom_mode_genus = 3
                            doc.configurable.zoom_mode_type = fit_type
                            local layout = doc:_pairLayout(doc:spreadUnitFor(2))
                            for _, side in ipairs({ "left", "right" }) do
                                local half = layout[side]
                                local size = doc:getPageDims(half.page)
                                for index, fraction in ipairs({ 0.25, 0.75 }) do
                                    local x, y = size.w / 2, size.h * fraction
                                    local seam = side == "right" and layout.left.box.w * layout.left.scale or 0
                                    local pos = open(doc, {
                                        page = 2,
                                        x = seam + (x - half.box.x) * half.scale,
                                        y = (y - half.box.y) * half.scale,
                                    }, half.page, index)
                                    check.near(x, pos.x, 0.000001)
                                    check.near(y, pos.y, 0.000001)
                                end
                            end
                        end
                    end
                end)
            end
        end
        for _, scenario in ipairs({ "off", "portrait", "scroll", "wide", "unloaded" }) do
            it("preserves single-page mapping: " .. scenario, function()
                rotation = scenario == "portrait" and 0 or 1
                local doc = document(scenario == "off" and "off" or "auto", false)
                if scenario == "scroll" then
                    doc.configurable.page_scroll = 1
                end
                if scenario == "wide" then
                    doc.wide_list = { 2 }
                end
                if scenario == "unloaded" then
                    doc.dims[3] = nil
                end
                local pos = open(doc, { page = 2, x = 300, y = 750 }, 2, 2)
                check.equals(300, pos.x)
                check.equals(750, pos.y)
            end)
        end
        it("supports absent or older Meguru without a mapping API", function()
            local doc = document("off", false)
            doc.spreadPageAt = false
            open(doc, { page = 2, x = 300, y = 750 }, 2, 2)
            doc.provider = "other"
            doc.spreadPageAt = function()
                error("unrelated provider must not be mapped")
            end
            open(doc, { page = 2, x = 300, y = 750 }, 2, 2)
        end)
        for _, crop_mode in ipairs({ "none", "loose", "tight" }) do
            it("preserves bottom-right panels on both pages: " .. crop_mode, function()
                rotation = 1
                local doc = document("on", false)
                doc.dims[2] = { w = 800, h = 1200 }
                local panel = { x = 550, y = 900, w = 230, h = 280 }
                for _, page in ipairs({ 2, 3 }) do
                    local old_native = HostDocument.getNativePageDimensions
                    -- Use the actual shim installed by this Meguru document module.
                    HostDocument.getNativePageDimensions = base.getNativePageDimensions
                    local ok, images, rects = pcall(Collector.buildImages, { document = doc }, page, { panel }, {
                        crop_mode = crop_mode,
                        panel_bleed_ratio = 0.02,
                        panel_bleed_min = 5,
                        join_spread_fold = false,
                        auto_rotate_double_pages = false,
                    })
                    HostDocument.getNativePageDimensions = old_native
                    if not ok then
                        error(images)
                    end
                    check.is_true(rects[1].x <= panel.x)
                    check.is_true(rects[1].y <= panel.y)
                    check.is_true(rects[1].x + rects[1].w >= panel.x + panel.w)
                    check.is_true(rects[1].y + rects[1].h >= panel.y + panel.h)
                    check.is_true(rects[1].x + rects[1].w <= 800)
                    check.is_true(rects[1].y + rects[1].h <= 1200)
                end
            end)
        end
        it("ignores gestures outside the page", function()
            local controller = setmetatable({}, { __index = ViewerController })
            check.is_false(
                controller:showPanelSequence(
                    { clear = function() end, view = { screenToPageTransform = function() end } },
                    { pos = {} }
                )
            )
        end)
    end)
end
