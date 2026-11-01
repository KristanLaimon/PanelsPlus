-- Integration evidence uses the selected target's actual Book, Place, Canvas,
-- Transform, ReaderInkView and plugin entry points. Device/UI/persistence and
-- pixel painting are fixtures; this is not a live stylus/device test.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, check = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Collector = require("src._panelcollector")

return function(reference)
    local original_show = UIManager.show
    UIManager.show = function(_, widget)
        UIManager._window_stack[#UIManager._window_stack + 1] = { widget = widget }
    end
    local modules, rendered, saved = {}, {}, 0
    local noop = function() end
    local Base = {}
    function Base:extend(fields)
        return setmetatable(fields, { __index = self })
    end
    function Base:new(fields)
        setmetatable(fields, { __index = self })
        fields.view = { canvas_w = 600, canvas_h = 800 }
        fields.canvas = modules["ink/canvas"].new(600, 800)
        fields.screen_w, fields.screen_h, fields._toolbar_hidden = 600, 800, true
        fields:loadBookPage()
        return fields
    end
    Base.composeCanvas, Base.renderView, Base.flushPending = noop, noop, noop
    Base.cancelShape, Base.resetLasso, Base.markDirty, Base.onCloseWidget = noop, noop, noop, noop
    function Base:closeCanvas()
        self:saveDocument()
        self:onCloseWidget()
        self.closing = true
        for i = #UIManager._window_stack, 1, -1 do
            if UIManager._window_stack[i].widget == self then
                table.remove(UIManager._window_stack, i)
            end
        end
    end
    local BB = {}
    BB.__index = BB
    function BB:copy()
        return setmetatable({}, BB)
    end
    function BB:free()
        self.freed = true
    end
    function BB:blitFrom(_, x, y, _, _, w, h)
        self.blit = { x = x, y = y, w = w, h = h }
    end
    function BB:getType()
        return 1
    end
    local blitbuffer = {
        new = function()
            return setmetatable({}, BB)
        end,
    }
    local fixtures = {
        ["bit"] = {}, -- Raster's grain functions are outside these geometry tests.
        ["device"] = { screen = setmetatable({ bb = setmetatable({}, BB) }, { __index = Screen }) },
        ["ui/uimanager"] = UIManager,
        ["ui/widget/verticalgroup"] = {},
        ["ui/widget/verticalspan"] = {},
        ["ink/l10n"] = function(s)
            return s
        end,
        ["ink/reader/bookink"] = {
            locate = function()
                return { dir = "/tmp/inkaway-surface-fixture", dirs = {} }
            end,
            exists = function()
                return false
            end,
            new = function()
                return { items = {} }
            end,
            saveAny = function(dirs)
                saved = saved + 1
                return dirs[1]
            end,
            prunePictures = noop,
        },
        ["ink/view"] = Base,
        ["ink/reader/vbar"] = { into = noop },
        ["ink/ui/controls"] = {},
        ["ink/reader/paint"] = {
            ops = function(_, ops)
                rendered = ops
            end,
        },
        ["ffi/blitbuffer"] = blitbuffer,
    }
    local function targetRequire(name)
        if fixtures[name] then
            return fixtures[name]
        end
        if modules[name] then
            return modules[name]
        end
        if name:match("^ink/") then
            local env = setmetatable({ require = targetRequire }, { __index = _G })
            local chunk = assert(loadfile(reference .. "/" .. name .. ".lua", "t", env))
            local result = chunk()
            modules[name] = result
            return result
        end
        return require(name)
    end
    local env = setmetatable({ require = targetRequire }, { __index = _G })
    local Ink = assert(loadfile(reference .. "/main.lua", "t", env))()
    local Book = targetRequire("ink/reader/book")
    local Place = targetRequire("ink/reader/place")
    targetRequire("ink/canvas")
    local supports = Ink.document_surface_version == 1

    local function fixture(angle, fold)
        UIManager._window_stack = {}
        local ui = {
            document = { file = "/tmp/book.cbz" },
            paging = {},
            view = {
                state = { page = 2, zoom = 0.5, offset = { x = 0, y = 0 } },
                visible_area = { x = 0, y = 0 },
                paintTo = noop,
                screenToPageTransform = function(_, pos)
                    return { page = 2, x = pos.x * 2, y = pos.y * 2 }
                end,
            },
        }
        local book = Book.new(ui)
        local ink = setmetatable({ ui = ui, book = book }, { __index = Ink })
        -- KOReader registers plugins by folder name, ignoring _meta.lua.name.
        ui["ink-away"] = ink
        local quarter = (angle or 0) % 180 ~= 0
        local viewer = setmetatable({
            reader_ui = ui,
            page = 7,
            rotated = angle or 0,
            image_rects = { { x = 100, y = 200, w = 200, h = 100 }, { x = 300, y = 200, w = 200, h = 100 } },
            _images_list_cur = 1,
            _images_list_nb = 2,
            _images_list = { folds = fold and { fold } or nil },
            _image_wg = {
                dimen = { x = 10, y = 20, w = quarter and 200 or 400, h = quarter and 400 or 200 },
                getSize = noop,
                getCurrentWidth = function()
                    return quarter and 200 or 400
                end,
                getCurrentHeight = function()
                    return quarter and 400 or 200
                end,
            },
            paintAnnotationBackground = function(self)
                self.snapshots = (self.snapshots or 0) + 1
            end,
            switchToImageNum = function(self, i)
                self._images_list_cur = i
            end,
        }, { __index = PanelViewer })
        UIManager._window_stack[1] = { widget = viewer }
        return book, viewer, ink
    end

    local function noCropAcrossPanels(case)
        local source_bb = require("ffi/blitbuffer")
        local original_new = source_bb.new
        local function bitmap(w, h)
            local bb = { w = w, h = h }
            function bb:getWidth()
                return self.w
            end
            function bb:getHeight()
                return self.h
            end
            function bb:getType()
                return 1
            end
            function bb:fill() end
            function bb:free() end
            function bb:blitFrom(source, x, y)
                self.content = { source = source, x = x, y = y }
            end
            return bb
        end
        source_bb.new = bitmap
        local ok, err = pcall(function()
            for _, angle in ipairs({ 0, 90, 180, 270 }) do
                local book, viewer = fixture(angle)
                local doc = book.ui.document
                function doc:getNativePageDimensions()
                    return { w = 1200, h = 1600 }
                end
                function doc:transformRect(rect, zoom)
                    return { x = rect.x * zoom, y = rect.y * zoom, w = rect.w * zoom, h = rect.h * zoom }
                end
                function doc:renderPage(_, rect, zoom)
                    local bb = bitmap(math.floor(rect.w * zoom + 0.5), math.floor(rect.h * zoom + 0.5))
                    bb.native_rect = rect
                    return { bb = bb }
                end
                local images, rects = Collector.buildImages(book.ui, 7, case.panels, {
                    crop_mode = "none",
                    auto_rotate_double_pages = false,
                    join_spread_fold = false,
                })
                viewer._images_list, viewer.image_rects = images, rects
                local wg = viewer._image_wg
                -- Include widget positioning, panning and a changed display zoom.
                local quarter = angle % 180 ~= 0
                local w, h = quarter and 600 or 540, quarter and 450 or 720
                wg.getCurrentWidth, wg.getCurrentHeight =
                    function()
                        return w
                    end, function()
                        return h
                    end
                wg.dimen, wg._offset_x, wg._offset_y = { x = 13, y = 17, w = w, h = h }, 7, 11

                local function onCanvas(canvas, x, y)
                    local content = assert(canvas.content)
                    local r, tile = content.source.native_rect, content.source
                    local u = (content.x + (x - r.x) * tile.w / r.w) / canvas.w
                    local v = (content.y + (y - r.y) * tile.h / r.h) / canvas.h
                    local nx, ny = u, v
                    if angle == 90 then
                        nx, ny = v, 1 - u
                    elseif angle == 180 then
                        nx, ny = 1 - u, 1 - v
                    elseif angle == 270 then
                        nx, ny = 1 - v, u
                    end
                    return 6 + nx * w, 6 + ny * h
                end
                local first = images[1]()
                local x, y = onCanvas(first, case.points[1], case.points[2])
                local x2, y2 = onCanvas(first, case.points[3], case.points[4])
                local surface = viewer:getAnnotationSurface()
                book:setSurface(surface)
                local op = { kind = "ink", width = 3, pts = { x, y, x2, y2 } }
                local map = book:setPageOps({ op }, {}, {})
                local item = map[op]
                for i = 1, 4, 2 do
                    check.near(case.points[i], item.a.x + item.op.pts[i], 1e-6, "saved native x")
                    check.near(case.points[i + 1], item.a.y + item.op.pts[i + 1], 1e-6, "saved native y")
                end
                book:setSurface(nil)
                local second = images[2]()
                viewer._images_list_cur = 2
                book:setSurface(surface)
                local placed = book:pageOps().ops[1]
                check.is_not_nil(placed, "cross-panel ink remains visible")
                for i = 1, 4, 2 do
                    local expected_x, expected_y = onCanvas(second, case.points[i], case.points[i + 1])
                    check.near(expected_x, placed.pts[i], 1e-6, "ink follows the actual composited page x")
                    check.near(expected_y, placed.pts[i + 1], 1e-6, "ink follows the actual composited page y")
                end
                check.equals(item, book:data().items[1], "navigation must not rewrite the saved item")
                local panel = case.panels[1]
                check.is_true(
                    case.points[1] < panel.x
                        or case.points[1] > panel.x + panel.w
                        or case.points[2] < panel.y
                        or case.points[2] > panel.y + panel.h,
                    "the stroke extends outside the first panel"
                )
            end
        end)
        source_bb.new = original_new
        if not ok then
            error(err)
        end
    end

    describe(
        "Ink Away reference: " .. (supports and "surface integration" or "native coexistence; surface API absent"),
        function()
            it("preserves the reader's native coordinates and page with no surface", function()
                local book = fixture()
                local page, x, y, zoom = book:doc():toPage(20, 30)
                check.equals(2, page)
                check.equals(40, x)
                check.equals(60, y)
                check.equals(0.5, zoom)
                check.equals(2, book:visiblePages()[1])
            end)
            it("round-trips fixed-page ink through the actual storage placement model", function()
                local book = fixture()
                local op = { kind = "ink", width = 4, pts = { 20, 30, 40, 50 } }
                local item = Place.anchor(op, book:doc())
                local restored = Place.place(item, book:doc())
                for i, value in ipairs(op.pts) do
                    check.near(value, restored.pts[i], 1e-7)
                end
            end)
            it("creates an annotation canvas through the actual plugin action", function()
                local book, _, ink = fixture()
                ink:onInkAwayAnnotate()
                check.is_not_nil(book._view)
                check.equals(book._view, UIManager._window_stack[#UIManager._window_stack].widget)
                if supports then
                    check.is_not_nil(book.surface)
                else
                    check.is_nil(book.surface)
                end
                book._view:closeCanvas()
            end)
            it("does not inject a surface API into an unmodified target", function()
                if not supports then
                    check.is_nil(Ink.paintDocumentSurface)
                else
                    check.equals(1, Ink.document_surface_version)
                end
            end)
            it("keeps the panel paint path working with Ink Away absent or without the new API", function()
                local _, viewer = fixture()
                viewer:paintTo(setmetatable({}, BB), 0, 0)
                viewer.reader_ui["ink-away"] = nil
                viewer:paintTo(setmetatable({}, BB), 0, 0)
            end)
        end
    )
    if not supports then
        UIManager.show = original_show
        return
    end

    describe("Ink Away generic document-surface integration", function()
        for _, case in ipairs({
            {
                edge = "right",
                panels = { { x = 600, y = 500, w = 200, h = 600 }, { x = 950, y = 550, w = 200, h = 500 } },
                points = { 890, 700, 910, 730 },
            },
            {
                edge = "left",
                panels = { { x = 200, y = 500, w = 200, h = 600 }, { x = 0, y = 500, w = 200, h = 600 } },
                points = { 100, 700, 140, 730 },
            },
            {
                edge = "top",
                panels = { { x = 400, y = 450, w = 600, h = 200 }, { x = 400, y = 0, w = 600, h = 200 } },
                points = { 650, 180, 680, 210 },
            },
            {
                edge = "bottom",
                panels = { { x = 400, y = 1050, w = 600, h = 200 }, { x = 400, y = 1400, w = 600, h = 200 } },
                points = { 650, 1450, 680, 1470 },
            },
        }) do
            it("aligns cross-panel No crop ink with the composited page at the " .. case.edge .. " edge", function()
                noCropAcrossPanels(case)
            end)
        end
        it("anchors new ink to the focused page at every quarter rotation", function()
            for _, angle in ipairs({ 0, 90, 180, 270 }) do
                local book, viewer = fixture(angle)
                local surface = viewer:getAnnotationSurface()
                book:setSurface(surface)
                local x, y = surface:toScreen(7, 150, 230)
                local x2, y2 = surface:toScreen(7, 175, 245)
                local op = { kind = "ink", width = 4, pts = { x, y, x2, y2 } }
                local map = book:setPageOps({ op }, {}, {})
                local item = map[op]
                check.equals(7, item.a.page)
                local placed = book:pageOps().ops[1]
                for i, value in ipairs(op.pts) do
                    check.near(value, placed.pts[i], 1e-6)
                end
                book:setSurface(nil)
                local native = Place.place(item, book:doc())
                check.is_nil(native, "page 7 is not visible in the underlying reader")
            end
        end)
        it("maps crossing strokes through joined folds on both sides without drift", function()
            for _, angle in ipairs({ 0, 90, 180, 270 }) do
                local book, viewer = fixture(angle, { u0 = 0.48, u1 = 0.52, pad = 0.02 })
                local surface = viewer:getAnnotationSurface()
                book:setSurface(surface)
                local x, y = surface:toScreen(7, 170, 225)
                local x2, y2 = surface:toScreen(7, 230, 250)
                local op = { kind = "ink", width = 3, pts = { x, y, x2, y2 } }
                local item = Place.anchor(op, book:doc())
                local placed = Place.place(item, book:doc())
                check.equals(7, item.a.page)
                check.near(x, placed.pts[1], 1e-6)
                check.near(y, placed.pts[2], 1e-6)
                check.near(x2, placed.pts[#placed.pts - 1], 1e-6)
                check.near(y2, placed.pts[#placed.pts], 1e-6)
                check.is_true(#item.op.pts > 4, "seam vertices must be retained")
                for i = 1, #placed.pts - 1, 2 do
                    local cross = (placed.pts[i] - x) * (y2 - y) - (placed.pts[i + 1] - y) * (x2 - x)
                    check.near(0, cross, 1e-3, "the restored path must stay on the drawn line")
                end
            end
        end)
        it("paints existing ink using the panel transform and restores the reader context", function()
            local book, viewer = fixture()
            local item =
                { a = { page = 7, x = 150, y = 230 }, op = { kind = "ink", width = 2, pts = { 0, 0, 20, 10 } } }
            book:data().items = { item }
            rendered = {}
            local bb = setmetatable({}, BB)
            viewer:paintTo(bb, 0, 0)
            check.equals(1, #rendered)
            check.near(110, rendered[1].pts[1], 1e-6)
            check.near(80, rendered[1].pts[2], 1e-6)
            check.is_nil(book.surface)
            check.equals(400, bb.blit.w)
        end)
        it("keeps newly saved annotations visible after the annotator closes", function()
            local book, viewer, ink = fixture()
            ink:onInkAwayAnnotate()
            local view = book._view
            view.canvas:setOps({ { kind = "ink", width = 2, pts = { 110, 80, 140, 100 } } })
            view:saveDocument()
            view:closeCanvas()
            check.is_nil(book._view)
            check.is_nil(book.surface)
            rendered = {}
            viewer:paintTo(setmetatable({}, BB), 0, 0)
            check.equals(1, #rendered)
            check.near(110, rendered[1].pts[1], 1e-6)
            check.near(80, rendered[1].pts[2], 1e-6)
            check.equals(7, book:data().items[1].a.page)
        end)
        it("uses the panel background and keeps old ink items unchanged on close", function()
            local book, viewer, ink = fixture()
            local item =
                { a = { page = 7, x = 150, y = 230 }, op = { kind = "ink", width = 2, pts = { 0, 0, 20, 10 } } }
            book:data().items = { item }
            ink:onInkAwayAnnotate()
            check.is_true(viewer.snapshots > 0)
            local view = book._view
            view.canvas.rev = view.canvas.rev + 1
            view:saveDocument()
            check.equals(item, book:data().items[1])
            view:closeCanvas()
            check.is_nil(book.surface)
            check.is_nil(book._view)
            check.is_true(saved > 0)
        end)
        it("saves the old panel before turning and loads ink for the new one", function()
            local book, viewer, ink = fixture()
            ink:onInkAwayAnnotate()
            local view = book._view
            view.canvas:setOps({ { kind = "ink", width = 2, pts = { 110, 80, 120, 90 } } })
            view:turnPage(1)
            check.equals(2, viewer._images_list_cur)
            check.equals(7, book:data().items[1].a.page)
            check.equals(0, #view.canvas.ops)
            view:closeCanvas()
        end)
        it("hands an asynchronous page crossing to a replacement surface without closing the canvas", function()
            local book, viewer, ink = fixture()
            viewer._images_list_cur = 2
            -- The controller callback receives direction first, then viewer.
            viewer.boundary_callback = function(_, v)
                v._panels_plus_boundary_pending = true
            end
            ink:onInkAwayAnnotate()
            local view = book._view
            view:turnPage(1)
            check.is_not_nil(viewer._annotation_surface.navigation_done)
            local next_viewer = {}
            for k, value in pairs(viewer) do
                next_viewer[k] = value
            end
            setmetatable(next_viewer, getmetatable(viewer))
            next_viewer.page, next_viewer._annotation_surface = 8, nil
            next_viewer._images_list_cur, next_viewer._panels_plus_boundary_pending = 1, nil
            viewer._panels_plus_closed = true
            viewer:completeAnnotationNavigation(next_viewer)
            check.equals(view, book._view)
            check.equals(next_viewer, book.surface.viewer)
            check.equals(8, book:visiblePages()[1])
            view:closeCanvas()
        end)
        it("keeps annotation fold choices independent of reading mode and restores reading mode on close", function()
            for _, reading in ipairs({ true, false }) do
                for _, drawing in ipairs({ true, false }) do
                    local book, viewer, ink = fixture()
                    viewer.join_spread_fold, viewer.inkaway_join_spread_fold = reading, drawing
                    ink:onInkAwayAnnotate()
                    check.equals(drawing, viewer._images_list.annotation_join_spread_fold)
                    book._view:closeCanvas()
                    check.is_nil(viewer._images_list.annotation_join_spread_fold)
                    check.equals(reading, viewer.join_spread_fold)
                end
            end
        end)
        it("renders joined halves as clipped affine regions for non-path annotations", function()
            local book, viewer = fixture(0, { u0 = 0.48, u1 = 0.52, pad = 0.02 })
            local surface = viewer:getAnnotationSurface()
            local regions = surface:regions()
            check.equals(2, #regions)
            local x0 = regions[1]:toScreen(7, 196, 220)
            local x1 = regions[2]:toScreen(7, 204, 220)
            check.near(x0, x1, 1e-6, "the retained halves meet at one seam")
            check.near(regions[1]:clip().x + regions[1]:clip().w, regions[2]:clip().x, 1e-6)
            check.is_nil(book.surface)
        end)
        it("closes and saves the canvas when its surface is released", function()
            local book, viewer, ink = fixture()
            ink:onInkAwayAnnotate()
            ink:releaseDocumentSurface(viewer:getAnnotationSurface())
            check.is_nil(book.surface)
            check.is_nil(book._view)
        end)
        it("does not use a surface belonging to a different document", function()
            local book, viewer, ink = fixture()
            viewer:getAnnotationSurface().document = {}
            ink:onInkAwayAnnotate()
            check.is_nil(book.surface)
            book._view:closeCanvas()
        end)
        it("respects Show ink while reading when painting a panel", function()
            local book, viewer = fixture()
            book:data().items = {
                { a = { page = 7, x = 150, y = 230 }, op = { kind = "ink", width = 2, pts = { 0, 0, 20, 10 } } },
            }
            rendered = {}
            local original = G_reader_settings
            _G.G_reader_settings = {
                readSetting = function()
                    return false
                end,
            }
            local ok, err = pcall(viewer.paintTo, viewer, setmetatable({}, BB), 0, 0)
            _G.G_reader_settings = original
            check.is_true(ok, tostring(err))
            check.equals(0, #rendered)
        end)
        it("invalidates placement on crop, page, pan and zoom changes", function()
            local book, viewer = fixture()
            book:setSurface(viewer:getAnnotationSurface())
            local key = book:layoutKey()
            viewer._image_wg._offset_x = 20
            check.is_true(book:layoutKey() ~= key)
            key = book:layoutKey()
            viewer._images_list_cur = 2
            check.is_true(book:layoutKey() ~= key)
        end)
        it("accepts an unrelated viewer implementing the same contract", function()
            local book, _, ink = fixture()
            local surface = {
                version = 1,
                document = book.ui.document,
                pages = function()
                    return { 9 }
                end,
                key = function()
                    return "other-view"
                end,
                toPage = function(_, x, y)
                    return 9, x, y, 1, 0
                end,
                toScreen = function(_, _, x, y)
                    return x, y, 1, 0
                end,
                snapshot = noop,
                repaint = noop,
                clip = function()
                    return { x = 0, y = 0, w = 600, h = 800 }
                end,
            }
            UIManager._window_stack = {
                {
                    widget = {
                        getAnnotationSurface = function()
                            return surface
                        end,
                    },
                },
            }
            ink:onInkAwayAnnotate()
            check.equals(surface, book.surface)
            check.equals(9, book:visiblePages()[1])
            book._view:closeCanvas()
        end)
    end)
    UIManager.show = original_show
end
