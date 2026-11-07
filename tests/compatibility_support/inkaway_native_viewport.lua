-- Headless SDL regression using real KOReader widgets, layout, blitter,
-- Panels+ and the selected Ink Away source. Only document pixels and timer
-- delivery are fixtures. Run from a KOReader runtime with an isolated KO_HOME:
-- SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software SDL_AUDIODRIVER=dummy \
-- KO_HOME=/tmp/inkaway-native-viewport ./luajit THIS_FILE SOURCE TARGET
io.stdout:setvbuf("line")
local source, target = assert(arg[1]), assert(arg[2])
local home = assert(os.getenv("KO_HOME"), "set an isolated KO_HOME under /tmp")
assert(home:sub(1, 5) == "/tmp/", "this regression must not use real reader settings")
require("setupkoenv")
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):wrap({
    sdl_window = { width = 600, height = 800 },
    inkaway_library_dir = home .. "/library",
    inkaway_welcome_seen = true,
    inkaway_session_migrated = true,
    inkaway_palm_reject = false,
    inkaway_book_toolbar_hidden = false,
})
local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/bidi").setup()
package.path = source .. "/?.lua;" .. target .. "/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local UI = require("ui/uimanager")
local Viewer = require("src._panelviewer")
local Book = require("ink/reader/book")
local Collector = require("src._panelcollector")
local BookInk = require("ink/reader/bookink")
local PluginLoader = require("pluginloader")
PluginLoader.enabled_plugins, PluginLoader.disabled_plugins = {}, {}
PluginLoader:_load({
    {
        main = target .. "/main.lua",
        meta = target .. "/_meta.lua",
        path = target,
        name = "ink-away",
        disabled = false,
    },
})
local InkAway = assert(PluginLoader.enabled_plugins[1], "Ink Away must load through KOReader's handler sandbox")
local checks, cases = 0, 0
local function check(c, message)
    checks = checks + 1
    assert(c, message)
end
local W, H = Device.screen:getWidth(), Device.screen:getHeight()
local function bitmap(rect, zoom)
    zoom = zoom or math.min(W / rect.w, H / rect.h)
    local b = BB.new(math.max(1, math.ceil(rect.w * zoom)), math.max(1, math.ceil(rect.h * zoom)))
    b:fill(BB.Color8(190))
    return b
end
local old_schedule = UI.scheduleIn
local callbacks = {}
UI.scheduleIn = function(_, _, callback)
    callbacks[#callbacks + 1] = callback
end
local function drain(editor, bb)
    local n = 0
    while #callbacks > 0 do
        n = n + 1
        assert(n < 150, "navigation timers must terminate")
        table.remove(callbacks, 1)()
        if editor then
            editor:paintTo(bb, 0, 0)
        end
    end
end
for _, side in ipairs({ "left", "right", "top", "bottom" }) do
    for _, flow in ipairs({ "comic", "manga" }) do
        for _, style in ipairs({ "ease", "classic" }) do
            for _, crop in ipairs({ "tight", "margin", "none" }) do
                cases = cases + 1
                G_reader_settings:saveSetting("inkaway_book_toolbar_side", side)
                local rects = { { x = 0, y = 0, w = 300, h = 400 }, { x = 320, y = 200, w = 200, h = 500 } }
                if crop == "none" then
                    rects = { { x = 0, y = 0, w = 300, h = 800 }, { x = 0, y = 900, w = 200, h = 500 } }
                end
                local images = { image_disposable = true }
                for i, rect in ipairs(rects) do
                    images[i] = function()
                        return bitmap(rect)
                    end
                end
                local ui = {
                    document = { file = home .. "/book.cbz" },
                    paging = {},
                    view = {
                        state = { page = 1, zoom = 1, offset = { x = 0, y = 0 } },
                        visible_area = { x = 0, y = 0 },
                    },
                }
                ui.document.mod_time = 0
                ui.document._document = {
                    openPage = function()
                        return {
                            getSize = function()
                                return 1200, 1600
                            end,
                            close = function() end,
                        }
                    end,
                }
                function ui.document:drawPagePart(_, rect)
                    return bitmap(rect), false
                end
                local image_rects = rects
                if crop == "none" then
                    images, image_rects = Collector.buildImages(ui, 1, rects, {
                        crop_mode = crop,
                        auto_rotate_double_pages = false,
                    })
                end
                local book = Book.new(ui)
                ui["ink-away"] = setmetatable({ ui = ui, book = book }, { __index = InkAway })
                if type(ui["ink-away"].installPluginIntegration) == "function" then
                    book.extensions:publish(ui, ui["ink-away"])
                end
                book._data = BookInk.new()
                local ink = {
                    a = { page = 1, x = 100, y = 200 },
                    op = {
                        kind = "ink",
                        style = "solid",
                        alpha = 255,
                        width = 4,
                        color = { 0, 0, 255 },
                        pts = { 0, 0, 20, 30 },
                    },
                }
                book._data.items = { ink }
                local viewer = Viewer:new({
                    image = images,
                    image_rects = image_rects,
                    panels = rects,
                    page = 1,
                    reader_ui = ui,
                    auto_rotate_double_pages = false,
                    image_disposable = true,
                    nav_transition_mode = "smooth",
                    nav_smooth_style = style,
                    nav_transition_frames = 4,
                    crop_mode = crop,
                    reading_mode = flow,
                    margin_ratio = 0.12,
                    inkaway_fit_viewport = true,
                    buttons_visible = true,
                    progress_bar_visible = false,
                    image_union_renderer = function(rect, zoom)
                        return bitmap(rect, zoom)
                    end,
                })
                UI:show(viewer)
                local bb = BB.new(W, H)
                viewer:paintTo(bb, 0, 0)
                viewer:replaceButtonTable()
                check(viewer.quick_controls.draw_inkaway ~= nil, "successful integration offers Draw")
                viewer.quick_controls.draw_inkaway.callback()
                check(not viewer.buttons_visible, "Draw hides Panels+ options before editor layout")
                check(viewer.quick_rail == nil, "Draw releases the options rail's reserved space")
                local editor = assert(book._view)
                editor:paintTo(bb, 0, 0)
                drain(editor, bb)
                local original_update = viewer.update
                viewer.update = function(self)
                    local result = original_update(self)
                    if self._annotation_transition then
                        self:paintTo(bb, 0, 0)
                        local d = self._image_wg.dimen
                        local rect = assert(self._annotation_viewport)
                        check(d.x >= rect.x and d.y >= rect.y, "animation starts beside toolbar")
                        check(
                            d.x + d.w <= rect.x + rect.w and d.y + d.h <= rect.y + rect.h,
                            "animation remains inside toolbar-free viewport"
                        )
                    end
                    return result
                end
                local complete = viewer.completeNavTransition
                viewer.completeNavTransition = function(self, target_index, done)
                    self:paintTo(bb, 0, 0)
                    local moving = self:getAnnotationSurface():geometry()
                    complete(self, target_index, done)
                    self:paintTo(bb, 0, 0)
                    local landed = self:getAnnotationSurface():geometry()
                    check(
                        math.abs(moving.w / moving.rect.w - landed.w / landed.rect.w) < 0.025,
                        "Smooth lands at the stationary panel's toolbar-fit zoom"
                    )
                end
                for turn = 1, 4 do
                    local forward = turn % 2 == 1
                    local id = (forward == (flow == "comic")) and "next" or "prev"
                    local button
                    for _, entry in ipairs(editor._toolbar_icons) do
                        if entry.id == id then
                            button = entry.button
                        end
                    end
                    assert(button, "missing arrow button")
                    button.callback()
                    check(editor._surface_navigating == true, "toolbar arrow must start Smooth navigation")
                    drain(editor, bb)
                    check(viewer._images_list_cur == (forward and 2 or 1), "physical arrow reaches the expected panel")
                    check(not editor._surface_navigating, "handoff returns to editable mode")
                    check(viewer._image_wg.dimen ~= nil, "new image widget is painted before clip-dependent editing")
                    check(
                        book:data().items[1] == ink and ink.a.x == 100 and ink.a.y == 200,
                        "navigation preserves native ink and original item identity"
                    )
                    local clip = assert(book.surface:clip())
                    check(
                        editor.view.area_x >= clip.x and editor.view.area_y >= clip.y,
                        "editor reads the landed widget's current content clip"
                    )
                end
                editor:closeCanvas()
                check(viewer._annotation_viewport == nil, "closing restores the normal viewport")
                check(viewer.buttons_visible, "closing restores previously visible Panels+ options")
                UI:close(viewer)
                drain(nil, bb)
                bb:free()
                collectgarbage("collect")
                print(("native viewport case %d passed: %s / %s / %s / %s"):format(cases, side, flow, style, crop))
            end
        end
    end
end
UI.scheduleIn = old_schedule
print(("inkaway_native_viewport: %d cases, %d checks passed"):format(cases, checks))
