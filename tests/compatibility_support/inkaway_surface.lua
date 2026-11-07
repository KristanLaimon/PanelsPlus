-- Uses the selected Ink Away facade and registry; device painting/storage are fixtures.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, check = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")

return function(reference)
    local Integration = assert(loadfile(reference .. "/ink/integration.lua"))()
    local environment = setmetatable({
        require = function(name)
            if name == "ink/integration" then
                return Integration
            elseif name == "ink/l10n" then
                return require("gettext")
            end
            return require(name)
        end,
    }, { __index = _G })
    local Target = assert(loadfile(reference .. "/main.lua", "t", environment))()

    local function fixture(run, late)
        local stack = UIManager._window_stack
        local ui = { document = {} }
        local registry = Integration.new()
        local paints, releases = 0, 0
        local book = {
            extensions = registry,
            paintSurface = function()
                paints = paints + 1
            end,
            closeViews = function()
                releases = releases + 1
            end,
            setSurface = function(self, surface)
                self.surface = surface
            end,
        }
        local ink = Target:new({ ui = ui, book = book })
        local viewer = PanelViewer:new({
            reader_ui = ui,
            page = 2,
            _images_list_cur = 1,
            image_rects = { { x = 100, y = 200, w = 300, h = 400 } },
            _image_wg = {
                dimen = { x = 10, y = 20, w = 500, h = 700 },
                _offset_x = 30,
                _offset_y = 40,
                getSize = function() end,
                getCurrentWidth = function()
                    return 600
                end,
                getCurrentHeight = function()
                    return 800
                end,
            },
        })
        UIManager._window_stack = { { widget = viewer } }
        local ok, err = pcall(function()
            if not late then
                registry:publish(ui, ink)
            end
            viewer:onShow()
            run(viewer, ui, ink, registry, function()
                return paints, releases
            end)
        end)
        local closed, close_error = pcall(viewer.onCloseWidget, viewer)
        registry:dispose()
        registry:unpublish(ui, ink)
        UIManager._window_stack = stack
        check.is_true(ok, tostring(err))
        check.is_true(closed, tostring(close_error))
    end

    describe("Ink Away optional document surface API", function()
        it("registers before or after Ink Away readiness and cleans up its own queue entry", function()
            for _, late in ipairs({ false, true }) do
                fixture(function(viewer, ui, ink, registry)
                    local other = { configureInkAway = function() end }
                    if late then
                        check.is_true(ui.inkAwayPendingIntegrations[viewer])
                        ui.inkAwayPendingIntegrations[other] = true
                        registry:publish(ui, ink)
                    end
                    local surface = registry:select(ui)
                    check.is_not_nil(surface)
                    check.equals(ui.document, surface.document)
                    viewer:configureInkAway(ink)
                    check.equals(surface, registry:select(ui))
                    viewer:onCloseWidget()
                    check.is_nil(registry:select(ui))
                    viewer:configureInkAway(ink)
                    check.is_nil(registry:select(ui))
                end, late)
            end
        end)

        it("cancels a closed viewer without removing another pending consumer", function()
            fixture(function(viewer, ui, ink, registry)
                local calls = 0
                local other = {
                    configureInkAway = function()
                        calls = calls + 1
                    end,
                }
                ui.inkAwayPendingIntegrations[other] = true
                viewer:onCloseWidget()
                check.is_true(ui.inkAwayPendingIntegrations[other])
                registry:publish(ui, ink)
                check.equals(1, calls)
                check.is_nil(registry:select(ui))
            end, true)
        end)

        it("releases the active surface before viewer destruction, exactly once", function()
            fixture(function(viewer, ui, ink, registry, counts)
                ink.book.surface = registry:select(ui)
                viewer:onCloseWidget()
                viewer:onCloseWidget()
                local _, releases = counts()
                check.equals(1, releases)
                check.is_nil(ink.book.surface)
                check.is_nil(registry:select(ui))
            end)
        end)

        it("unregisters even when releasing the editor fails", function()
            fixture(function(viewer, ui, ink, registry)
                ink.book.surface = registry:select(ui)
                ink.book.closeViews = function()
                    error("simulated save failure")
                end
                viewer:onCloseWidget()
                check.is_nil(registry:select(ui))
                check.is_true(viewer._panels_plus_closed)
            end)
        end)

        it("paints saved ink and snapshots the background without recursive ink", function()
            fixture(function(viewer, ui, _, registry, counts)
                local surface = registry:select(ui)
                viewer:paintTo({}, 0, 0)
                check.equals(1, counts())
                surface:snapshot({})
                check.equals(1, counts())
                ui.inkAwayIntegrationAPI = nil
                viewer:paintTo({}, 0, 0)
                check.equals(1, counts())
            end)
        end)

        for _, angle in ipairs({ 0, 90, 180, 270 }) do
            it("maps native coordinates without clamping through rotation " .. angle, function()
                fixture(function(viewer, ui, _, registry)
                    viewer.rotated = angle
                    local surface = registry:select(ui)
                    for _, point in ipairs({ { 100, 200 }, { 250, 400 }, { 50, 150 }, { 450, 700 } }) do
                        local x, y, zoom, rotation = surface:toScreen(2, point[1], point[2])
                        local page, px, py, inverse_zoom, inverse_rotation = surface:toPage(x, y)
                        check.equals(2, page)
                        check.near(point[1], px, 0.001)
                        check.near(point[2], py, 0.001)
                        check.equals(zoom, inverse_zoom)
                        check.equals(rotation, inverse_rotation)
                        check.equals(-math.rad(angle), rotation)
                    end
                    check.is_nil(surface:toScreen(3, 250, 400))
                    local key = surface:key()
                    viewer._image_wg._offset_x = 50
                    check.is_true(key ~= surface:key())
                    local clip = surface:clip()
                    check.is_true(clip.x >= 10 and clip.y >= 20)
                    check.is_true(clip.x + clip.w <= 510 and clip.y + clip.h <= 720)
                end)
            end)
        end

        it("maps joined folds as separate affine regions and splits crossing paths", function()
            fixture(function(viewer, ui, _, registry)
                viewer._images_list = { folds = { { u0 = 0.48, u1 = 0.52, pad = 0.02 } } }
                local surface = registry:select(ui)
                check.is_false(surface:isAffine())
                local regions = surface:regions()
                check.equals(2, #regions)
                for _, x in ipairs({ 160, 340 }) do
                    local sx, sy = surface:toScreen(2, x, 300)
                    local page, px, py = surface:toPage(sx, sy)
                    check.equals(2, page)
                    check.near(x, px, 0.001)
                    check.near(300, py, 0.001)
                end
                check.is_true(#surface:mapPath({ 160, 300, 340, 300 }, false, 2) > 4)
                for _, region in ipairs(regions) do
                    check.is_true(region:isAffine())
                    check.is_true(region:clip().w > 0)
                end
            end)
        end)

        it("maps the native content inside a padded No crop bitmap", function()
            local Collector = require("src._panelcollector")
            local PageRender = require("src._pagerender")
            local Blitbuffer = require("ffi/blitbuffer")
            local draw, allocate = PageRender.drawPagePart, Blitbuffer.new
            PageRender.drawPagePart = function()
                return {
                    getWidth = function()
                        return 600
                    end,
                    getHeight = function()
                        return 500
                    end,
                    getType = function()
                        return 0
                    end,
                }
            end
            Blitbuffer.new = function()
                return { fill = function() end, blitFrom = function() end }
            end
            local ok, err = pcall(function()
                fixture(function(viewer, ui, _, registry)
                    ui.document.getNativePageDimensions = function()
                        return { w = 960, h = 1280 }
                    end
                    local images, rects = Collector.buildImages(
                        ui,
                        2,
                        { { x = 0, y = 0, w = 300, h = 100 } },
                        { crop_mode = "none", auto_rotate_double_pages = false }
                    )
                    images[1]()
                    viewer._images_list, viewer.image_rects = images, rects
                    viewer._image_wg.dimen = { x = 0, y = 0, w = 600, h = 800 }
                    viewer._image_wg._offset_x, viewer._image_wg._offset_y = 0, 0
                    local surface = registry:select(ui)
                    local x, y = surface:toScreen(2, 0, 0)
                    check.near(0, x, 0.001)
                    check.near(300, y, 0.001)
                    local clip = surface:clip()
                    check.equals(300, clip.y)
                    check.equals(500, clip.h)
                end)
            end)
            PageRender.drawPagePart, Blitbuffer.new = draw, allocate
            check.is_true(ok, tostring(err))
        end)

        it("declines reflow images, transition canvases, and foreign documents", function()
            fixture(function(viewer, ui, _, registry)
                viewer.embedded_source_image = {}
                check.is_nil(registry:select(ui))
                viewer.embedded_source_image = nil
                viewer._panels_plus_transition_active = true
                check.is_nil(registry:select(ui))
                viewer._panels_plus_transition_active = nil
                check.is_not_nil(registry:select(ui))
                ui.document = {}
                check.is_nil(registry:select(ui))
            end)
        end)
    end)
end
