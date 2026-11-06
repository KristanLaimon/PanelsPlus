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
    local modules, rendered, saved, paint_calls = {}, {}, 0, {}
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
    Base.drawFabs = noop
    Base.newAreaBuffer = function()
        return { free = noop }
    end
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
                paint_calls[#paint_calls + 1] = ops
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
        if type(ink.installPluginIntegration) == "function" then
            book.extensions:publish(ui, ink)
        end
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
            function bb:paintRect() end
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

    -- Track native points through the actual render/blit/scale calls, then
    -- compare Ink Away's overlay at each scheduled animation frame. Widget
    -- layout and framebuffer storage are fixtures; camera code is real.
    local function smoothAnnotations(options)
        local original_settings = G_reader_settings
        if options.hide_reading then
            _G.G_reader_settings = {
                readSetting = function()
                    return false
                end,
            }
        end
        local source_bb = require("ffi/blitbuffer")
        local renderer = require("ui/renderimage")
        local memory = require("src._memory")
        local draw = require("src._pagerender")
        local old_new, old_scale, old_schedule = source_bb.new, renderer.scaleBlitBuffer, UIManager.scheduleIn
        local old_headroom, old_allocation = memory.hasHeadroom, memory.hasAllocationHeadroom
        local timers, frames, visible = {}, 0, 0
        local function bitmap(w, h)
            local bb = { w = w, h = h, blits = {} }
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
            function bb:paintRect() end
            function bb:free()
                self.freed = true
            end
            function bb:copy()
                local copy = bitmap(self.w, self.h)
                copy.original = self
                return copy
            end
            function bb:blitFrom(source, x, y, sx, sy, w2, h2)
                self.blits[#self.blits + 1] = { source = source, x = x, y = y, sx = sx, sy = sy, w = w2, h = h2 }
            end
            return bb
        end
        local function locate(bb, page, x, y)
            if bb.native and bb.native.page == page then
                local r = bb.native.rect
                if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
                    return (x - r.x) * bb.w / r.w, (y - r.y) * bb.h / r.h
                end
            elseif bb.original then
                return locate(bb.original, page, x, y)
            elseif bb.scaled then
                local px, py = locate(bb.scaled, page, x, y)
                if px then
                    return px * bb.w / bb.scaled.w, py * bb.h / bb.scaled.h
                end
            end
            for _, blit in ipairs(bb.blits) do
                local px, py = locate(blit.source, page, x, y)
                if px and px >= blit.sx and px < blit.sx + blit.w and py >= blit.sy and py < blit.sy + blit.h then
                    return blit.x + px - blit.sx, blit.y + py - blit.sy
                end
            end
        end
        source_bb.new = bitmap
        renderer.scaleBlitBuffer = function(_, source, w, h)
            if options.fail_scale then
                error("fixture scale failure")
            end
            local frame = bitmap(w, h)
            frame.scaled = source
            return frame
        end
        memory.hasHeadroom = function()
            return not options.low_memory
        end
        memory.hasAllocationHeadroom = memory.hasHeadroom
        UIManager.scheduleIn = function(_, _, callback)
            timers[#timers + 1] = callback
        end
        local ok, err = pcall(function()
            local book, viewer, ink = fixture()
            local rects = options.row_transition
                    and { { x = 100, y = 100, w = 200, h = 350 }, { x = 100, y = 650, w = 600, h = 200 } }
                or options.far and {
                    { x = 100, y = 200, w = 200, h = 200 },
                    {
                        x = 6500,
                        y = 250,
                        w = 200,
                        h = 200,
                    },
                }
                or { { x = 100, y = 200, w = 200, h = 200 }, { x = 400, y = 250, w = 150, h = 200 } }
            local doc = book.ui.document
            function doc:getNativePageDimensions()
                return { w = 8000, h = 1600 }
            end
            function doc:transformRect(r, z)
                return { x = r.x * z, y = r.y * z, w = r.w * z, h = r.h * z }
            end
            function doc:renderPage(page, r, z)
                local bb = bitmap(math.ceil(r.w * z), math.ceil(r.h * z))
                bb.native = { page = page, rect = r }
                return { bb = bb }
            end
            local items, native = {}, {}
            for index, r in ipairs(rects) do
                local page = options.boundary and index + 6 or 7
                for _, u in ipairs({ 0.2, 0.5, 0.8 }) do
                    for _, v in ipairs({ 0.2, 0.5, 0.8 }) do
                        local id, x, y = #items + 1, r.x + r.w * u, r.y + r.h * v
                        items[id] = {
                            a = { page = page, x = x, y = y },
                            op = { kind = "ink", width = 2, pts = { 0, 0, 3, 2 }, test_id = id },
                        }
                        native[id] = { page = page, x = x, y = y }
                    end
                end
            end
            local unrelated = {
                { page = 7, x = 340, y = 360 }, -- neighboring panel in the source row
                { page = 7, x = 400, y = 530 }, -- gutter between the endpoint panels
                { page = 7, x = 250, y = 1000 }, -- another row outside the rendered union
            }
            if options.row_transition then
                for _, point in ipairs(unrelated) do
                    local id = #items + 1
                    items[id] = {
                        a = { page = point.page, x = point.x, y = point.y },
                        op = { kind = "ink", width = 2, pts = { 0, 0, 3, 2 }, test_id = id },
                    }
                    native[id] = point
                end
            end
            book:data().items = items
            viewer.crop_mode = options.no_crop and "none" or options.crop or "tight"
            viewer.panels = rects
            local images
            if options.no_crop then
                images, viewer.image_rects = Collector.buildImages(book.ui, 7, rects, {
                    crop_mode = "none",
                    auto_rotate_double_pages = false,
                    join_spread_fold = false,
                })
                viewer._images_list = images
            else
                viewer.image_rects = rects
                viewer._images_list = {}
            end
            viewer.image_disposable, viewer.rotated, viewer.auto_rotate_double_pages = false, 0, false
            viewer.nav_smooth_style, viewer.nav_transition_frames = options.style or "linear", 4
            viewer.nav_transition_mode, viewer.nav_transition_cross_page = "smooth", true
            viewer.nav_transition_duration = 0.4
            viewer.reading_mode = options.manga and "manga" or "comic"
            viewer.width, viewer.height, viewer.img_container_h = 600, 800, 800
            viewer.inkaway_fit_viewport = not options.full_viewport
            viewer.getPanelViewportSize = options.viewport_side and PanelViewer.getPanelViewportSize
                or function()
                    return 600, 800
                end
            viewer.getMarginShrinkFactorForPanel = function(_, index)
                return options.margin and (index == 1 and 0.9 or 0.7) or 1
            end
            viewer.shouldAutoRotateDoublePage = function()
                return false
            end
            viewer.isOpen = function(self)
                return not self._panels_plus_closed
            end
            local editor, editor_frames
            editor_frames = 0
            local function paintFrame(self)
                paint_calls = {}
                if editor and editor._surface_navigating then
                    editor_frames = editor_frames + 1
                    editor:paintTo(bitmap(600, 800), 0, 0)
                else
                    self:paintTo(bitmap(600, 800), 0, 0)
                end
                local wg, found = self._image_wg, {}
                if options.row_transition and self._annotation_transition and not options.no_crop then
                    for _, point in ipairs(unrelated) do
                        if options.check_background then
                            check.is_nil(
                                locate(self.image, point.page, point.x, point.y),
                                "cropped transitions must not expose neighboring panels or gutters"
                            )
                        else
                            for _, region in ipairs(self:getAnnotationSurface():regions()) do
                                local x, y = region:toScreen(point.page, point.x, point.y)
                                local clip = region:clip()
                                check.is_true(
                                    not x or x < clip.x or y < clip.y or x >= clip.x + clip.w or y >= clip.y + clip.h,
                                    "cropped ink regions must exclude unrelated panels and gutters"
                                )
                            end
                        end
                    end
                end
                for _, ops in ipairs(paint_calls) do
                    for _, op in ipairs(ops) do
                        local point = native[op.test_id]
                        if point then
                            local px, py = locate(self.image, point.page, point.x, point.y)
                            if px then
                                local sx = wg.dimen.x + px * self.scale_factor - wg._offset_x
                                local sy = wg.dimen.y + py * self.scale_factor - wg._offset_y
                                if
                                    sx >= wg.dimen.x
                                    and sx < wg.dimen.x + wg.width
                                    and sy >= wg.dimen.y
                                    and sy < wg.dimen.y + wg.height
                                then
                                    check.near(sx, op.pts[1], 1e-5, "ink must follow the frame's page pixels (x)")
                                    check.near(sy, op.pts[2], 1e-5, "ink must follow the frame's page pixels (y)")
                                    found[op.test_id], visible = true, visible + 1
                                end
                            end
                        end
                    end
                end
                for id, point in ipairs(native) do
                    local px, py = locate(self.image, point.page, point.x, point.y)
                    if px then
                        local x, y = px * self.scale_factor - wg._offset_x, py * self.scale_factor - wg._offset_y
                        if x >= 0 and x < wg.width and y >= 0 and y < wg.height then
                            check.is_true(found[id] == true, "each visible page's annotation must be painted")
                        end
                    end
                end
                frames = frames + 1
            end
            viewer.update = function(self)
                local scale = self.scale_factor or 1
                self.scale_factor = scale
                local w, h = self.image.w * scale, self.image.h * scale
                local margin = self._panels_plus_transition_margin_factor or 1
                local cw, ch, _, _, insets = self:getPanelViewportSize()
                local vw, vh = math.min(cw * margin, w), math.min(ch * margin, h)
                local ix, iy = insets and insets.left or 0, insets and insets.top or 0
                self._image_wg = {
                    dimen = { x = ix + (cw - vw) / 2, y = iy + (ch - vh) / 2, w = vw, h = vh },
                    width = vw,
                    height = vh,
                    _offset_x = math.max(0, math.min(w - vw, (self._center_x_ratio or 0.5) * w - vw / 2)),
                    _offset_y = math.max(0, math.min(h - vh, (self._center_y_ratio or 0.5) * h - vh / 2)),
                    getSize = noop,
                    getCurrentWidth = function()
                        return w
                    end,
                    getCurrentHeight = function()
                        return h
                    end,
                }
                paintFrame(self)
                self:notifyAnnotationNavigationFrame()
            end
            viewer.panBy = function(self, dx, dy)
                local wg = self._image_wg
                wg._offset_x, wg._offset_y = wg._offset_x + dx, wg._offset_y + dy
                paintFrame(self)
            end
            viewer.switchToImageNum = function(self, index)
                self._images_list_cur = index
                self.image = images and images[index]() or draw.drawPagePart(book.ui, self.page, rects[index], 0)
                self.scale_factor, self._center_x_ratio, self._center_y_ratio = 1, 0.5, 0.5
                self:update()
            end
            viewer.image = images and images[1]() or draw.drawPagePart(book.ui, 7, rects[1], 0)
            viewer.scale_factor = 1
            if options.boundary then
                local resolved = { next_page = 8, target_rect = rects[2], start_idx = 1, panels = { rects[2] } }
                if options.no_crop then
                    local next_rects
                    resolved.next_images, next_rects = Collector.buildImages(book.ui, 8, { rects[2] }, {
                        crop_mode = "none",
                        auto_rotate_double_pages = false,
                        join_spread_fold = false,
                    })
                    resolved.target_rect = next_rects[1]
                end
                viewer.nav_boundary_peek_callback = function()
                    return resolved
                end
                viewer.nav_boundary_commit_callback = function(self)
                    self.page, self.image_rects, self._images_list_cur = 8, { resolved.target_rect }, 1
                    self._images_list = resolved.next_images or {}
                    self.image = resolved.next_images and resolved.next_images[1]()
                        or draw.drawPagePart(book.ui, 8, rects[2], 0)
                    self.scale_factor = 1
                    self:update()
                    if editor then
                        self:completeAnnotationNavigation(self)
                    end
                end
                viewer.boundary_callback = function()
                    viewer.nav_boundary_commit_callback(viewer)
                end
            end
            if options.annotator then
                viewer.paintAnnotationBackground = PanelViewer.paintAnnotationBackground
                ink:onInkAwayAnnotate()
                editor = book._view
                editor._bar_toggle_hidden = true
                if options.viewport_side then
                    editor._toolbar_hidden, editor._bar_side, editor._vb_thick = false, options.viewport_side, 50
                    editor.toolbar = {
                        getSize = function()
                            local across = options.viewport_side == "top" or options.viewport_side == "bottom"
                            return { w = across and 600 or 50, h = across and 50 or 800 }
                        end,
                        paintTo = noop,
                    }
                    editor.paintBarMarks, editor.paintBarIcons, editor.darkToolbar = noop, noop, noop
                    editor:prepareSurfaceLayout()
                    editor:placeToolbar()
                    editor:areaChanged()
                    local w, h = viewer:getPanelViewportSize()
                    local across = options.viewport_side == "top" or options.viewport_side == "bottom"
                    check.equals(
                        (options.full_viewport or across) and 600 or 550,
                        w,
                        "toolbar space changes the real panel viewport"
                    )
                    check.equals((not options.full_viewport and across) and 750 or 800, h)
                    if options.toggle_fit then
                        viewer:setInkAwayFitViewport(false)
                        local full_w, full_h = viewer:getPanelViewportSize()
                        check.equals(600, full_w)
                        check.equals(800, full_h)
                        viewer:setInkAwayFitViewport(true)
                        local fit_w, fit_h = viewer:getPanelViewportSize()
                        check.equals(w, fit_w)
                        check.equals(h, fit_h)
                    end
                end
                editor:turnArrow(options.manga and "left" or "right")
                check.is_true(editor._surface_navigating, "the editor waits for the animation handoff")
                local committed = editor.canvas.rev
                editor:turnArrow(options.manga and "left" or "right")
                check.equals(committed, editor.canvas.rev, "repeated input cannot reload a moving canvas")
                if options.close_editor then
                    editor:closeCanvas()
                end
            elseif options.boundary then
                viewer:animateBoundaryTransition("next", options.preview and function()
                    viewer.preview_complete = true
                end or nil)
            else
                viewer:animateSwitchToImageNum(2)
            end
            if options.close_first then
                viewer._panels_plus_closed = true
            end
            local count = 0
            while #timers > 0 do
                count = count + 1
                check.is_true(count < 30, "animation must terminate")
                table.remove(timers, 1)()
            end
            check.is_true(frames > ((options.low_memory or options.fail_scale or options.close_first) and 0 or 2))
            check.is_true(visible > 0)
            check.is_nil(viewer._annotation_transition, "animation geometry must be released at handoff")
            if options.preview then
                check.is_true(viewer.preview_complete)
            end
            if editor then
                check.is_true(
                    editor_frames > (options.close_editor and 0 or 1),
                    "the editor displays the moving surface"
                )
                check.is_nil(editor._surface_navigating)
                check.is_nil(viewer:getAnnotationSurface().navigation_done)
                check.is_nil(viewer:getAnnotationSurface().navigation_frame)
                if options.close_editor then
                    check.is_nil(book.surface)
                else
                    editor:closeCanvas()
                end
            end
            for i, item in ipairs(items) do
                check.equals(item, book:data().items[i])
            end
        end)
        source_bb.new, renderer.scaleBlitBuffer, UIManager.scheduleIn = old_new, old_scale, old_schedule
        memory.hasHeadroom, memory.hasAllocationHeadroom = old_headroom, old_allocation
        _G.G_reader_settings = original_settings
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
        it("animates inside the annotator using physical arrows for Comic and Manga", function()
            smoothAnnotations({ annotator = true, style = "ease" })
            smoothAnnotations({ annotator = true, style = "classic", manga = true })
            smoothAnnotations({ annotator = true, hide_reading = true })
        end)
        it("keeps the annotator open through Smooth page boundaries and No crop movement", function()
            smoothAnnotations({ annotator = true, boundary = true, manga = true })
            smoothAnnotations({ annotator = true, no_crop = true })
        end)
        it("does not reactivate a closed annotator when its animation finishes", function()
            smoothAnnotations({ annotator = true, close_editor = true })
        end)
        it("keeps physical arrow direction separate from semantic next/previous actions", function()
            for _, mode in ipairs({ "manga", "comic" }) do
                local book, viewer, ink = fixture()
                viewer.reading_mode = mode
                ink:onInkAwayAnnotate()
                local view = book._view
                viewer._images_list_cur = 2
                view:turnArrow(mode == "manga" and "right" or "left")
                check.equals(1, viewer._images_list_cur)
                view:turnArrow(mode == "manga" and "left" or "right")
                check.equals(2, viewer._images_list_cur)
                view:runAction("prev_page")
                check.equals(1, viewer._images_list_cur)
                view:runAction("next_page")
                check.equals(2, viewer._images_list_cur)
                view:nbGo(mode == "manga" and 1 or -1)
                check.equals(1, viewer._images_list_cur, "physical swipe navigation follows reading flow")
                view:closeCanvas()
            end
        end)
        it("moves ink with every Smooth pan/zoom frame and margin change", function()
            smoothAnnotations({ style = "linear", margin = true })
            smoothAnnotations({ style = "ease", margin = true })
        end)
        it("moves ink with the Classic shared-canvas pan", function()
            smoothAnnotations({ style = "classic" })
        end)
        it("moves both pages' ink through cross-page Smooth transitions", function()
            smoothAnnotations({ boundary = true })
            smoothAnnotations({ boundary = true, manga = true })
        end)
        it("keeps No crop ink attached during panel and page animation", function()
            smoothAnnotations({ no_crop = true, style = "ease" })
            smoothAnnotations({ no_crop = true, style = "classic" })
            smoothAnnotations({ no_crop = true, boundary = true })
        end)
        it("maps ink through the bounded-frame fallback for a large Classic canvas", function()
            smoothAnnotations({ style = "classic", far = true })
        end)
        it("restores ink placement after an out-and-back page preview", function()
            smoothAnnotations({ boundary = true, preview = true })
        end)
        it("cleans up animation geometry on failure, low memory and close", function()
            smoothAnnotations({ low_memory = true })
            smoothAnnotations({ fail_scale = true })
            smoothAnnotations({ close_first = true })
            smoothAnnotations({ style = "classic", close_first = true })
        end)
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
        it("clips row-transition ink to the source and destination in cropped modes", function()
            for _, style in ipairs({ "ease", "classic" }) do
                for _, crop in ipairs({ "tight", "loose", "margin" }) do
                    smoothAnnotations({ row_transition = true, style = style, crop = crop })
                end
            end
        end)
        it("masks neighboring source-row panels out of cropped Smooth backgrounds", function()
            smoothAnnotations({ row_transition = true, style = "ease", check_background = true })
            smoothAnnotations({ row_transition = true, style = "classic", check_background = true })
        end)
        it("keeps Smooth geometry and ink aligned beside all annotator toolbar positions", function()
            for _, side in ipairs({ "left", "right", "top", "bottom" }) do
                smoothAnnotations({ annotator = true, viewport_side = side, style = "ease" })
                smoothAnnotations({ annotator = true, viewport_side = side, style = "classic" })
            end
        end)
        it("preserves No crop, margin framing and the full-viewport opt-out beside the toolbar", function()
            smoothAnnotations({ annotator = true, viewport_side = "right", no_crop = true, style = "classic" })
            smoothAnnotations({ annotator = true, viewport_side = "top", margin = true, style = "ease" })
            smoothAnnotations({ annotator = true, viewport_side = "left", full_viewport = true, style = "ease" })
            smoothAnnotations({ annotator = true, viewport_side = "left", toggle_fit = true, style = "ease" })
        end)
        it("fits annotator page-boundary animation into its remaining viewport", function()
            smoothAnnotations({ annotator = true, viewport_side = "left", boundary = true })
            smoothAnnotations({ annotator = true, viewport_side = "bottom", boundary = true, manga = true })
            smoothAnnotations({ annotator = true, viewport_side = "left", boundary = true, no_crop = true })
        end)
        it("uses the same cropped row regions while the annotator stays open", function()
            smoothAnnotations({ row_transition = true, annotator = true, style = "ease", manga = true })
            smoothAnnotations({ row_transition = true, annotator = true, style = "classic", check_background = true })
        end)
        it("preserves surrounding page and ink context for No crop row transitions", function()
            smoothAnnotations({ row_transition = true, no_crop = true, style = "ease" })
            smoothAnnotations({ row_transition = true, no_crop = true, style = "classic" })
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
    if Ink.integration_api_version == 1 then
        describe("Ink Away registered rendering provider", function()
            it("selects the Panels+ registration without widget discovery", function()
                local book, viewer, ink = fixture()
                local surface = viewer:getAnnotationSurface()
                -- This would hide the viewer from the old discovery mechanism.
                viewer.getAnnotationSurface = false
                local opened, closed = 0, 0
                local off_open = ink:onAnnotationOpened(function(payload)
                    check.equals(surface, payload.surface)
                    opened = opened + 1
                end)
                local off_close = ink:onAnnotationClosed(function()
                    closed = closed + 1
                end)
                ink:onInkAwayAnnotate()
                check.equals(surface, book.surface)
                check.equals(1, opened)
                book._view:closeCanvas()
                check.equals(1, closed)
                off_open()
                off_close()
                -- Exercise the actual source close path and its unregister handle.
                viewer:onCloseWidget()
                check.is_nil(viewer._annotation_unregister)
                check.is_nil(book.extensions:select(book.ui))
            end)
        end)
    end
    if type(Ink.installPluginIntegration) == "function" then
        describe("Ink Away readiness handshake with Panels+", function()
            it("configures the viewer with either plugin loading first", function()
                for _, consumer_first in ipairs({ true, false }) do
                    local book, viewer, ink = fixture()
                    local ui = book.ui
                    if consumer_first then
                        book.extensions:unpublish(ui, ink)
                    end
                    -- Directory-name registration can occur after Ink Away init.
                    ui["ink-away"] = nil
                    local surface = viewer:getAnnotationSurface()
                    if consumer_first then
                        check.is_true(ui.inkAwayPendingIntegrations[viewer])
                        book.extensions:publish(ui, ink)
                    end
                    check.equals(ink, viewer._annotation_provider_ink)
                    check.is_nil(ui.inkAwayPendingIntegrations)
                    local cleanup = viewer._annotation_unregister
                    viewer:getAnnotationSurface()
                    check.equals(cleanup, viewer._annotation_unregister)
                    viewer.getAnnotationSurface = false
                    ink:onInkAwayAnnotate()
                    check.equals(surface, book.surface)
                    viewer:onCloseWidget()
                    check.is_nil(book.surface)
                    check.is_nil(book._view)
                end
            end)
            it("cancels a viewer's queued setup before Ink Away becomes ready", function()
                local book, viewer, ink = fixture()
                book.extensions:unpublish(book.ui, ink)
                book.ui["ink-away"] = nil
                viewer:getAnnotationSurface()
                check.is_true(book.ui.inkAwayPendingIntegrations[viewer] ~= nil)
                viewer:onCloseWidget()
                check.is_nil(book.ui.inkAwayPendingIntegrations)
                book.extensions:publish(book.ui, ink)
                check.is_nil(viewer._annotation_unregister)
                check.is_nil(book.extensions:select(book.ui))
            end)
        end)
    end
    UIManager.show = original_show
end
