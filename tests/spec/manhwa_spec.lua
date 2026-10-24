local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy
local Manhwa = require("src.manhwa")
local Safe = require("src._manhwasafe")
local Settings = require("src._settings")
local Collector = require("src._panelcollector")
local Viewer = require("src._panelviewer")
local Controller = require("src.viewer_controller")
local Bitmap = require("src._manhwabitmap")

local function document(count)
    return {
        getNativePageDimensions = function()
            return { w = 100, h = 100 }
        end,
        getNextPage = function(_, page)
            return page < count and page + 1 or 0
        end,
        getPrevPage = function(_, page)
            return page > 1 and page - 1 or 0
        end,
    }
end

local function map(rects)
    local data = {}
    for i = 0, 9999 do
        data[i] = 0
    end
    for _, r in ipairs(rects) do
        for y = r.y, r.y + r.h - 1 do
            for x = r.x, r.x + r.w - 1 do
                data[y * 100 + x] = 1
            end
        end
    end
    return { data = data, w = 100, h = 100, native_w = 100, native_h = 100, scale_x = 1, scale_y = 1, ink = 5000 }
end

local function builder(maps)
    return function(_, page)
        return maps[page]
    end
end

describe("Manhwa isolated Safe pipeline", function()
    it("cycles the existing mode selector through all three modes", function()
        assert.equals("comic", Settings.nextReadingMode("manga"))
        assert.equals("manhwa", Settings.nextReadingMode("comic"))
        assert.equals("manga", Settings.nextReadingMode("manhwa"))
        local viewer = Viewer:new({ reading_mode = "comic" })
        viewer:replaceButtonTable()
        for _, row in ipairs(viewer.button_table.buttons) do
            for _, button in ipairs(row) do
                if button.id == "mode" then
                    button.callback()
                end
            end
        end
        assert.equals("manhwa", viewer.reading_mode)
        assert.is_false(Manhwa.smart_enabled)
        assert.equals(
            "safe",
            Settings.withDefaults({ mode = "manhwa", panel_finding_mode = "smart" }).panel_finding_mode
        )
    end)

    it("keeps the fork independent of Manga and Comic detector functions", function()
        assert.is_true(Safe.segment ~= require("src._safecomponentdetector").segment)
        assert.is_true(Safe.detectPage ~= require("src._safecomponentdetector").detectPage)
        local panels = Safe.detectPage(map({ { x = 20, y = 30, w = 60, h = 4 } }), {})
        assert.equals(1, #panels)
        assert.equals(4, panels[1].h)
        assert.equals(60, panels[1].w)
    end)

    it("joins early and late illustrations without treating file seams as gutters", function()
        local doc = document(3)
        local maps = {
            map({ { x = 0, y = 80, w = 100, h = 20 } }),
            map({ { x = 0, y = 0, w = 100, h = 100 } }),
            map({ { x = 0, y = 0, w = 100, h = 15 } }),
        }
        for page = 1, 3 do
            local panels = Manhwa.detect(doc, {}, page, builder(maps))
            assert.equals(1, #panels)
            assert.equals(80, panels[1].y)
            assert.equals(135, panels[1].h)
        end
    end)

    it("preserves detached narration and blank-page gaps without duplicate fallback panels", function()
        local doc = document(3)
        local maps = {
            map({ { x = 0, y = 70, w = 100, h = 30 } }),
            map({}),
            map({ { x = 20, y = 30, w = 60, h = 4 } }),
        }
        assert.equals(1, #Manhwa.detect(doc, {}, 1, builder(maps)))
        assert.equals(0, #Manhwa.detect(doc, {}, 2, builder(maps)))
        assert.equals(230, Manhwa.detect(doc, {}, 3, builder(maps))[1].y)
    end)

    it("subdivides tall illustrations into balanced, gapless reading sections", function()
        local panels = Manhwa.sections({ { x = 0, y = 80, w = 100, h = 501, manhwa = true } }, {})
        assert.is_true(#panels > 1)
        assert.equals(80, panels[1].y)
        for i = 2, #panels do
            assert.equals(panels[i - 1].y + panels[i - 1].h, panels[i].y)
            assert.is_true(math.abs(panels[i].h - panels[i - 1].h) <= 1)
        end
        assert.equals(581, panels[#panels].y + panels[#panels].h)
    end)

    it("moves forward and back across a seam without replaying already displayed content", function()
        local doc = document(3)
        local original = Bitmap.build
        local maps = {
            map({ { x = 0, y = 80, w = 100, h = 20 } }),
            map({ { x = 0, y = 0, w = 100, h = 20 }, { x = 10, y = 70, w = 70, h = 30 } }),
            map({ { x = 10, y = 0, w = 70, h = 30 } }),
        }
        Bitmap.build = builder(maps)
        local ui, settings = { document = doc }, { mode = "manhwa" }
        local first = Collector.collect(ui, settings, 1)
        local viewer = { page = 1, panels = first, _images_list_cur = #first }
        local page, panels, index = Manhwa.adjacent(ui, settings, viewer, "next")
        assert.equals(2, page)
        assert.equals(170, panels[index].y)
        local back_page, previous, previous_index =
            Manhwa.adjacent(ui, settings, { page = page, panels = panels, _images_list_cur = index }, "previous")
        Bitmap.build = original
        assert.equals(2, back_page)
        assert.equals(80, previous[previous_index].y)
    end)

    it("uses vertical swipes and preserves physical forward/backward events", function()
        local next_spy, previous_spy = spy(), spy()
        local viewer = Viewer:new({
            reading_mode = "manhwa",
            _images_list = {},
            isImagePannable = function()
                return false
            end,
            onShowNextImage = next_spy,
            onShowPrevImage = previous_spy,
        })
        assert.equals("north", viewer:getNextSwipeDirection())
        viewer:onSwipe(nil, { direction = "north", pos = { x = 200, y = 300 } })
        viewer:onSwipe(nil, { direction = "south", pos = { x = 200, y = 300 } })
        assert.is_true(next_spy:called())
        assert.is_true(previous_spy:called())
        viewer:onSwipe(nil, { direction = "west", pos = { x = 200, y = 300 } })
        viewer:onSwipe(nil, { direction = "east", pos = { x = 200, y = 300 } })
        assert.equals(1, next_spy:callCount())
        assert.equals(1, previous_spy:callCount())
        viewer.invert_swipe = true
        assert.equals("south", viewer:getNextSwipeDirection())
    end)

    it("does not arm horizontal framebuffer animations in manhwa mode", function()
        local controller = setmetatable({ settings = { mode = "manhwa" } }, { __index = Controller })
        assert.is_false(controller:armPanelTransitionAnimation("next", { nav_transition_mode = "animated" }))
    end)

    it("retains the fixed-layout Smart preference when cycling out of Manhwa", function()
        local Plugin = require("main")
        local plugin = setmetatable({
            settings = { mode = "comic", panel_finding_mode = "smart" },
            saveSettings = function() end,
            saveDocSettings = function() end,
        }, { __index = Plugin })
        plugin:setMode("manhwa")
        assert.equals("safe", plugin.settings.panel_finding_mode)
        plugin:setMode("manga")
        assert.equals("smart", plugin.settings.panel_finding_mode)
    end)

    it("allows cross-page smooth animation with the strip union renderer", function()
        local animate = spy()
        local viewer = Viewer:new({
            reading_mode = "manhwa",
            nav_transition_mode = "smooth",
            nav_transition_cross_page = true,
            image_union_renderer = function() end,
            animateBoundaryTransition = animate,
        })
        viewer:onPanelBoundary("next")
        assert.is_true(animate:called())
    end)

    it("maps OCR touches in a joined crop back to their actual source page", function()
        local doc = document(3)
        local viewer = Viewer:new({
            reading_mode = "manhwa",
            page = 1,
            reader_ui = { document = doc },
            _images_list_cur = 1,
            image_rects = { { x = 0, y = 80, w = 100, h = 50, manhwa = true } },
            _image_wg = {
                getSize = function() end,
                getCurrentWidth = function()
                    return 100
                end,
                getCurrentHeight = function()
                    return 50
                end,
                width = 100,
                height = 50,
                dimen = { x = 0, y = 0 },
                _offset_x = 0,
                _offset_y = 0,
            },
        })
        local pos = viewer:screenToPageTransform({ x = 50, y = 30 })
        assert.equals(2, pos.page)
        assert.equals(10, pos.y)
        local box = viewer:pageToScreenTransform({ x = 40, y = 5, w = 20, h = 10 })
        assert.is_not_nil(box)
    end)

    it("composites only intersecting page crops and owns the result", function()
        local BB = require("ffi/blitbuffer")
        local Render = require("src._pagerender")
        local old_new, old_draw = BB.new, Render.drawPagePart
        local drawn, pasted = {}, {}
        local function image(w, h)
            return {
                getWidth = function()
                    return w
                end,
                getHeight = function()
                    return h
                end,
                getType = function()
                    return 1
                end,
                fill = function() end,
                free = function() end,
                blitFrom = function(_, _, x, y, _, _, width, height)
                    pasted[#pasted + 1] = { x = x, y = y, w = width, h = height }
                end,
            }
        end
        BB.new = image
        Render.drawPagePart = function(_, page, rect, _, zoom)
            drawn[#drawn + 1] = { page = page, rect = rect }
            return image(rect.w * zoom, rect.h * zoom)
        end
        local result = Manhwa.render({ document = document(10) }, { x = 0, y = 80, w = 100, h = 50 }, 1)
        BB.new, Render.drawPagePart = old_new, old_draw
        assert.equals(2, #drawn)
        assert.equals(1, drawn[1].page)
        assert.equals(80, drawn[1].rect.y)
        assert.equals(20, drawn[1].rect.h)
        assert.equals(2, drawn[2].page)
        assert.equals(0, drawn[2].rect.y)
        assert.equals(30, drawn[2].rect.h)
        assert.equals(50, result:getHeight())
        assert.equals(20, pasted[2].y)
    end)

    it("stacks cross-page transition canvases vertically and frees owned tiles", function()
        local BB = require("ffi/blitbuffer")
        local old_new = BB.new
        local tiles, canvases, motion = {}, {}, {}
        local function image(w, h)
            local buffer = { w = w, h = h, frees = 0 }
            function buffer:getWidth()
                return self.w
            end
            function buffer:getHeight()
                return self.h
            end
            function buffer:getType()
                return 1
            end
            function buffer:fill() end
            function buffer:blitFrom() end
            function buffer:free()
                self.frees = self.frees + 1
            end
            return buffer
        end
        BB.new = function(w, h)
            local buffer = image(w, h)
            canvases[#canvases + 1] = buffer
            return buffer
        end
        local function tile()
            local buffer = image(600, 600)
            tiles[#tiles + 1] = buffer
            return buffer
        end
        local resolved = {
            next_page = 2,
            start_idx = 1,
            target_rect = { x = 0, y = 100, w = 100, h = 100 },
            next_images = { tile },
        }
        local viewer = Viewer:new({
            reading_mode = "manhwa",
            image_disposable = true,
            _images_list_cur = 1,
            _images_list = { tile },
            image_rects = { { x = 0, y = 0, w = 100, h = 100 } },
            nav_boundary_peek_callback = function()
                return resolved
            end,
            nav_boundary_commit_callback = function() end,
            update = function() end,
            runNavPanAnimation = function(self, x, y, done)
                motion = { start_x = self._center_x_ratio, start_y = self._center_y_ratio, x = x, y = y }
                done()
            end,
        })
        viewer:animateBoundaryTransition("next")
        BB.new = old_new
        assert.equals(600, canvases[1].w)
        assert.equals(1600, canvases[1].h)
        assert.equals(motion.start_x, motion.x)
        assert.is_true(motion.y > motion.start_y)
        assert.equals(1, tiles[1].frees)
        assert.equals(1, tiles[2].frees)
    end)

    it("bounds unbroken chapters and keeps continuation chunks stable", function()
        local doc = document(20)
        local old_build, calls = Bitmap.build, 0
        local full = map({ { x = 0, y = 0, w = 100, h = 100 } })
        Bitmap.build = function()
            calls = calls + 1
            return full
        end
        local settings = { mode = "manhwa", manhwa_max_join_pages = 3 }
        local panels = Manhwa.collect({ document = doc }, settings, 10)
        local page, following, index = Manhwa.adjacent(
            { document = doc },
            settings,
            { panels = panels, _images_list_cur = #panels },
            "next"
        )
        local _, previous, back = Manhwa.adjacent(
            { document = doc },
            settings,
            { panels = following, _images_list_cur = index },
            "previous"
        )
        Bitmap.build = old_build
        assert.equals(11, page)
        assert.is_true(calls <= 6)
        assert.equals(1000, following[index].y)
        assert.equals(1000, previous[back].y + previous[back].h)
        assert.equals(panels[1].y, previous[1].y)
    end)

    it("recognizes both black and white spacing in the isolated bitmap fork", function()
        local BB = require("ffi/blitbuffer")
        local buffer = {
            w = 100,
            h = 100,
            isRGB = function()
                return true
            end,
            getType = function()
                return BB.TYPE_BBRGB24
            end,
            getRotation = function()
                return 0
            end,
            getInverse = function()
                return 0
            end,
            getPixel = function(_, _, y)
                local value = y < 30 and 0 or (y < 50 and 120 or 255)
                return {
                    getColorRGB24 = function()
                        return { r = value, g = value, b = value }
                    end,
                }
            end,
        }
        local paper = Bitmap.buildFromBlitbuffer(buffer, { mode = "manhwa" })
        assert.equals(1, paper.paper[10 * paper.w + 50])
        assert.equals(0, paper.paper[40 * paper.w + 50])
        assert.equals(2, paper.paper[80 * paper.w + 50])
        local panels = Safe.detectPage(paper, {})
        assert.equals(1, #panels)
        assert.equals(30, panels[1].y)
        assert.equals(20, panels[1].h)
    end)

    it("loads remembered Manhwa settings without activating the disabled Smart fork", function()
        local Plugin = require("main")
        local plugin = setmetatable({
            settings = Settings.withDefaults({}),
            getDocSettings = function()
                return { mode = "manhwa", panel_finding_mode = "smart" }
            end,
        }, { __index = Plugin })
        plugin:loadDocSettings()
        assert.equals("manhwa", plugin.settings.mode)
        assert.equals("safe", plugin.settings.panel_finding_mode)
    end)

    it("still finds ordinary side-by-side framed panels", function()
        local panels =
            Safe.detectPage(map({ { x = 0, y = 10, w = 40, h = 50 }, { x = 60, y = 10, w = 40, h = 50 } }), {})
        assert.equals(2, #panels)
        assert.is_true(panels[1].x < panels[2].x)
    end)

    it("uses bottom/top tap zones for forward/backward Manhwa navigation", function()
        local next_spy, previous_spy = spy(), spy()
        local viewer = Viewer:new({
            reading_mode = "manhwa",
            tap_navigation = true,
            isImagePannable = function()
                return false
            end,
            update = function() end,
            onShowNextImage = next_spy,
            onShowPrevImage = previous_spy,
        })
        viewer:onTap(nil, { pos = { x = 300, y = 750 } })
        viewer:onTap(nil, { pos = { x = 300, y = 10 } })
        assert.equals(1, next_spy:callCount())
        assert.equals(1, previous_spy:callCount())
        viewer.invert_taps = true
        viewer:onTap(nil, { pos = { x = 300, y = 10 } })
        assert.equals(2, next_spy:callCount())
    end)

    it("joins fractional render crops without pixel gaps or freeing DocCache tiles", function()
        local BB = require("ffi/blitbuffer")
        local Render = require("src._pagerender")
        local Scale = require("ui/renderimage")
        local old_new, old_draw, old_scale = BB.new, Render.drawPagePart, Scale.scaleBlitBuffer
        local tiles, scaled, pasted = {}, {}, {}
        local function image(w, h)
            local buffer = { w = w, h = h, frees = 0 }
            function buffer:getWidth()
                return self.w
            end
            function buffer:getHeight()
                return self.h
            end
            function buffer:getType()
                return 1
            end
            function buffer:fill() end
            function buffer:free()
                self.frees = self.frees + 1
            end
            function buffer:blitFrom(source, _, y, _, _, width, height)
                if width > source.w or height > source.h then
                    error("out-of-bounds blit")
                end
                pasted[#pasted + 1] = { y = y, h = height }
            end
            return buffer
        end
        BB.new = image
        Render.drawPagePart = function(_, _, rect, _, zoom)
            local tile = image(math.floor(rect.w * zoom), math.floor(rect.h * zoom))
            tiles[#tiles + 1] = tile
            return tile
        end
        Scale.scaleBlitBuffer = function(_, _, w, h, free_original)
            if free_original ~= false then
                error("cannot transfer ownership of DocCache tile")
            end
            local tile = image(w, h)
            scaled[#scaled + 1] = tile
            return tile
        end
        local result = Manhwa.render({ document = document(3) }, { x = 0, y = 80.5, w = 100, h = 50 }, 0.75)
        BB.new, Render.drawPagePart, Scale.scaleBlitBuffer = old_new, old_draw, old_scale
        assert.is_not_nil(result)
        assert.equals(38, result:getHeight())
        assert.equals(2, #pasted)
        assert.equals(pasted[1].y + pasted[1].h, pasted[2].y)
        assert.equals(38, pasted[2].y + pasted[2].h)
        for _, tile in ipairs(tiles) do
            assert.equals(0, tile.frees)
        end
        for _, tile in ipairs(scaled) do
            assert.equals(1, tile.frees)
        end
    end)

    it("refuses an oversized render before allocating a chapter-sized bitmap", function()
        local BB = require("ffi/blitbuffer")
        local original, allocations = BB.new, 0
        BB.new = function(...)
            allocations = allocations + 1
            return original(...)
        end
        local image = Manhwa.render({ document = document(100) }, { x = 0, y = 0, w = 100, h = 10000 }, 100)
        BB.new = original
        assert.is_nil(image)
        assert.equals(0, allocations)
    end)

    it("routes extracted images to the manhwa fork and redetects when cycling modes", function()
        local Embedded = require("src.embedded_image")
        local UI = require("ui/uimanager")
        local Original = require("src._safecomponentdetector")
        local old_build, old_detect, old_original, old_show =
            Bitmap.buildFromBlitbuffer, Safe.detectPage, Original.detectPage, UI.show
        local original_calls, fork_calls, viewer = 0, 0, nil
        Bitmap.buildFromBlitbuffer = function()
            return {}
        end
        Safe.detectPage = function()
            fork_calls = fork_calls + 1
            return { { x = 0, y = 0, w = 100, h = 240 } }
        end
        Original.detectPage = function()
            original_calls = original_calls + 1
            return {}
        end
        UI.show = function(_, shown)
            viewer = shown
        end
        local reopened = spy()
        local plugin = {
            settings = { mode = "manhwa", panel_finding_mode = "safe", crop_mode = "strict" },
            ui = {},
            getSelectedOcrModel = function()
                return "eng"
            end,
            setMode = function(self, value)
                self.settings.mode = value
            end,
            reopenEmbeddedImagePanels = reopened,
        }
        local ok = Embedded.showEmbeddedImagePanelsForImage(plugin, {
            w = 100,
            h = 240,
            getType = function()
                return 1
            end,
        })
        Bitmap.buildFromBlitbuffer, Safe.detectPage, Original.detectPage, UI.show =
            old_build, old_detect, old_original, old_show
        assert.is_true(ok)
        assert.equals(1, fork_calls)
        assert.equals(0, original_calls)
        assert.equals(2, #viewer.panels)
        viewer.mode_toggle_callback(viewer)
        assert.equals("manga", plugin.settings.mode)
        assert.is_true(reopened:lastCall()[3].redetect)
        viewer.reading_mode, plugin.settings.mode = "comic", "comic"
        viewer.mode_toggle_callback(viewer)
        assert.equals("manhwa", plugin.settings.mode)
        assert.is_true(reopened:lastCall()[3].redetect)
    end)

    it("cancels queued old-mode work without discarding the detector caches", function()
        local Plugin = require("main")
        local prefetch, prerender = spy(), spy()
        local cache = { old = { { x = 0, y = 0, w = 10, h = 10 } } }
        local plugin = setmetatable({
            settings = { mode = "comic", panel_finding_mode = "smart" },
            panel_cache = cache,
            cancelPanelPrefetch = prefetch,
            cancelPanelPrerender = prerender,
            saveSettings = function() end,
            saveDocSettings = function() end,
        }, { __index = Plugin })
        plugin:setMode("manhwa")
        assert.is_true(prefetch:called())
        assert.is_true(prerender:called())
        assert.equals(cache, plugin.panel_cache)
    end)

    it("retains a tightly spaced ordinary framed grid inside a vertical band", function()
        local panels = Safe.detectPage(
            map({
                { x = 0, y = 10, w = 40, h = 30 },
                { x = 60, y = 10, w = 40, h = 30 },
                { x = 0, y = 42, w = 40, h = 30 },
                { x = 60, y = 42, w = 40, h = 30 },
            }),
            {}
        )
        assert.equals(4, #panels)
        assert.is_true(panels[1].y < panels[3].y)
    end)

    it("keeps stale render callbacks harmless after the document is gone", function()
        assert.is_nil(Manhwa.render(nil, { x = 0, y = 0, w = 100, h = 100 }))
        assert.equals(0, #Manhwa.detect(nil, {}, 1))
    end)
end)
