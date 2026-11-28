local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelsPlus = require("main")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local Menu = require("src.menu")
local UIManager = require("ui/uimanager")

local function withPreview(options, check)
    local old_tick, old_schedule = UIManager.nextTick, UIManager.scheduleIn
    local old_spin = package.loaded["ui/widget/spinwidget"]
    local ticks, timers = {}, {}
    UIManager.nextTick = function(_, callback)
        ticks[#ticks + 1] = callback
    end
    UIManager.scheduleIn = function(_, delay, callback)
        timers[#timers + 1] = { delay, callback }
    end
    package.loaded["ui/widget/spinwidget"] = {
        new = function(_, data)
            return data
        end,
    }
    local moves, opened = {}, {}
    local viewer = {
        nav_transition_mode = "smooth",
        nav_smooth_style = "linear",
        buttons_visible = not options.hidden,
        with_title_bar = not options.hidden,
        fullscreen = options.hidden or false,
        progress_bar_visible = not options.hidden,
        update = function(self)
            self.updates = (self.updates or 0) + 1
        end,
        _images_list_cur = options.last and 2 or 1,
        _images_list_nb = options.single and 1 or 2,
        showSmoothPreviewUnavailableWarning = PanelViewer.showSmoothPreviewUnavailableWarning,
        isOpen = function(self)
            return not self._panels_plus_closed
        end,
        animateSwitchToImageNum = function(self, target, callback)
            moves[#moves + 1] = {
                target = target,
                frames = self.nav_transition_frames,
                duration = self.nav_transition_duration,
                style = self.nav_smooth_style,
            }
            self._panels_plus_transition_active = true
            self.complete = function()
                self._images_list_cur = target
                self._panels_plus_transition_active = nil
                callback()
            end
        end,
    }
    local plugin = setmetatable({
        settings = Settings.withDefaults({ nav_smooth_preview = not options.disabled, nav_smooth_style = "linear" }),
        ui = { menu = {} },
        active_panel_viewer = viewer,
        saveSettings = function(self)
            self.saves = (self.saves or 0) + 1
        end,
        showAdvancedOptions = function(_, current, section, page)
            opened[#opened + 1] = { viewer = current, section = section, page = page, panel = current._images_list_cur }
        end,
    }, { __index = PanelsPlus })
    local closed = 0
    local config = { page = 2, updateItems = function() end }
    config.close_callback = function()
        closed = closed + 1
        plugin.ui.menu.menu_container = nil
    end
    plugin.ui.menu.menu_container = { config }
    local function tick()
        local callback = table.remove(ticks, 1)
        assert.equals("function", type(callback))
        callback()
    end
    local function timer()
        local scheduled = table.remove(timers, 1)
        assert.is_not_nil(scheduled)
        assert.equals(0.15, scheduled[1])
        scheduled[2]()
    end
    local ok, err = pcall(check, plugin, viewer, config, moves, opened, tick, timer, ticks, function()
        return closed
    end)
    UIManager.nextTick, UIManager.scheduleIn = old_tick, old_schedule
    package.loaded["ui/widget/spinwidget"] = old_spin
    if not ok then
        error(err)
    end
end

describe("Smooth settings preview", function()
    it("previews duration, frames, and easing changes, then restores the panel and settings page", function()
        for _, choice in ipairs({ { 4, 650, "duration", 0.65 }, { 5, 17, "frames", 17 }, { 6, nil, "style", "ease" } }) do
            withPreview({}, function(plugin, viewer, config, moves, opened, tick, timer)
                -- Keyboard menus invoke input callbacks without an argument.
                if choice[2] then
                    Menu.animationItems(plugin)[choice[1]].callback()
                else
                    Menu.animationItems(plugin)[choice[1]].callback(config)
                end
                if choice[2] then
                    config.close_callback() -- KOReader dismisses the menu before showing the input.
                    tick()
                    UIManager._last_shown.callback({ value = choice[2] })
                end
                assert.equals(0, #moves, "the spinner/menu close must finish first")
                tick()
                assert.equals(2, moves[1].target)
                assert.equals(choice[4], moves[1][choice[3]])
                assert.equals(0, #opened)
                viewer.complete()
                assert.equals(2, viewer._images_list_cur)
                timer()
                assert.equals(1, moves[2].target)
                assert.equals(choice[4], moves[2][choice[3]])
                viewer.complete()
                tick()
                assert.equals(1, viewer._images_list_cur)
                assert.equals(1, #opened)
                assert.equals(viewer, opened[1].viewer)
                assert.equals("animation", opened[1].section)
                assert.equals(2, opened[1].page)
                assert.equals(1, opened[1].panel)
                assert.is_nil(viewer._panels_plus_smooth_preview)
            end)
        end
    end)

    it("saves the preview toggle and reopens settings without animating when disabled", function()
        withPreview({}, function(plugin, viewer, config, moves, opened, tick, _, ticks)
            local toggle = Menu.animationItems(plugin)[7]
            assert.is_true(toggle.checked_func())
            toggle.callback(config)
            assert.is_false(plugin.settings.nav_smooth_preview)
            assert.equals(1, plugin.saves)
            assert.equals(0, #ticks)
            assert.is_not_nil(plugin.ui.menu.menu_container)
            Menu.animationItems(plugin)[6].callback(config)
            tick()
            assert.equals(0, #moves)
            assert.equals(1, #opened)
            assert.equals(1, viewer._images_list_cur)
            toggle.callback(config)
            assert.is_true(plugin.settings.nav_smooth_preview)
        end)
    end)

    it("previews Classic in both directions without changing the chosen style", function()
        withPreview({}, function(plugin, viewer, config, moves, opened, tick, timer)
            plugin.settings.nav_smooth_style = "ease-in-out"
            viewer.nav_smooth_style = "ease-in-out"
            Menu.animationItems(plugin)[6].callback(config)
            tick()
            assert.equals("classic", moves[1].style)
            viewer.complete()
            timer()
            assert.equals("classic", moves[2].style)
            viewer.complete()
            tick()
            assert.equals("classic", plugin.settings.nav_smooth_style)
            assert.equals(1, opened[1].panel)
        end)
    end)

    it("hides all viewer controls on both preview legs and restores their previous visibility", function()
        for _, hidden in ipairs({ false, true }) do
            withPreview({ hidden = hidden }, function(plugin, viewer, config, _, opened, tick, timer)
                plugin:previewSmoothSettings(viewer, config.page)
                tick()
                assert.is_false(viewer.buttons_visible)
                assert.is_false(viewer.with_title_bar)
                assert.is_false(viewer.progress_bar_visible)
                assert.is_true(viewer.fullscreen)
                PanelViewer.onTap(viewer, nil, {})
                assert.is_false(viewer.buttons_visible, "taps cannot show controls during preview")
                viewer.complete()
                timer()
                assert.is_false(viewer.buttons_visible)
                assert.is_false(viewer.progress_bar_visible)
                viewer.complete()
                tick()
                assert.equals(not hidden, viewer.buttons_visible)
                assert.equals(not hidden, viewer.with_title_bar)
                assert.equals(not hidden, viewer.progress_bar_visible)
                assert.equals(hidden, viewer.fullscreen)
                assert.equals(2, viewer.updates)
                assert.equals(1, #opened)
                assert.is_true(plugin.settings.progress_bar_visible, "preview must not change saved display settings")
            end)
        end
    end)

    it("previews backward then forward at the last panel and restores its settings page", function()
        withPreview({ last = true }, function(plugin, viewer, config, moves, opened, tick, timer)
            plugin:previewSmoothSettings(viewer, config.page)
            tick()
            assert.equals(1, moves[1].target)
            assert.equals(0, #opened)
            viewer.complete()
            timer()
            assert.equals(2, moves[2].target)
            viewer.complete()
            tick()
            assert.equals(2, #moves)
            assert.equals(1, #opened)
            assert.equals(2, opened[1].page)
            assert.equals(2, viewer._images_list_cur)
            assert.is_nil(viewer._panels_plus_smooth_preview)
        end)
    end)

    it("shows the standard seven-second warning when only one panel is available", function()
        withPreview({ single = true }, function(plugin, viewer, config, moves, opened, tick)
            plugin:previewSmoothSettings(viewer, config.page)
            tick()
            assert.equals(0, #moves)
            assert.equals(1, #opened)
            assert.equals(1, viewer._images_list_cur)
            assert.is_nil(viewer._panels_plus_smooth_preview)
            assert.equals(7, UIManager._last_shown.timeout)
            assert.is_true(UIManager._last_shown.text:find("only one panel", 1, true) ~= nil)
            assert.is_true(UIManager._last_shown.text:find("Select another document/book", 1, true) ~= nil)
        end)
    end)

    it("identifies a truly single-panel book before describing the whole book in its warning", function()
        withPreview({ single = true }, function(plugin, viewer, config, moves, _, tick)
            viewer.page = 1
            plugin.ui.document = {
                getNextPage = function()
                    return 0
                end,
                getPrevPage = function()
                    return 0
                end,
            }
            plugin:previewSmoothSettings(viewer, config.page)
            tick()
            assert.equals(0, #moves)
            assert.equals(7, UIManager._last_shown.timeout)
            assert.is_true(
                UIManager._last_shown.text:find("this book because it contains only one panel", 1, true) ~= nil
            )
        end)
    end)

    it("previews adjacent pages at the first and last one-panel pages without changing the document", function()
        for _, last in ipairs({ false, true }) do
            withPreview({ single = true }, function(plugin, viewer, config, moves, opened, tick)
                viewer.page = last and 2 or 1
                plugin.ui.document = {
                    getNextPage = function()
                        return last and 0 or 2
                    end,
                    getPrevPage = function()
                        return last and 1 or 0
                    end,
                }
                local warmed
                plugin.collectPanels = function(_, page)
                    warmed = page
                end
                viewer.nav_boundary_peek_callback = function() end
                viewer.animateBoundaryTransition = function(_, direction, done)
                    moves[#moves + 1] = { direction = direction }
                    viewer.complete = function()
                        done(true)
                    end
                end
                plugin:previewSmoothSettings(viewer, config.page)
                tick()
                assert.equals(last and 1 or 2, warmed)
                assert.equals(last and "previous" or "next", moves[1].direction)
                viewer.complete()
                tick()
                assert.equals(1, #opened)
                assert.equals(1, viewer._images_list_cur)
                assert.equals(last and 2 or 1, viewer.page)
                assert.is_nil(viewer._panels_plus_smooth_preview)
            end)
        end
    end)

    it("does not show the one-panel warning when previews are disabled or input is canceled", function()
        for _, disabled in ipairs({ true, false }) do
            withPreview({ single = true, disabled = disabled }, function(plugin, viewer, config, moves, opened, tick)
                local previous = UIManager._last_shown
                plugin:previewSmoothSettings(viewer, config.page, not disabled)
                tick()
                assert.equals(0, #moves)
                assert.equals(1, #opened)
                assert.equals(previous, UIManager._last_shown)
            end)
        end
    end)

    it("returns to settings on input cancellation without playing a preview", function()
        withPreview({}, function(plugin, _, config, moves, opened, tick)
            Menu.animationItems(plugin)[4].callback(config)
            config.close_callback()
            tick()
            UIManager._last_shown.cancel_callback()
            tick()
            assert.equals(0, #moves)
            assert.equals(1, #opened)
        end)
    end)

    it("does not reopen settings if the viewer closes before or during preview", function()
        for _, close_before in ipairs({ true, false }) do
            withPreview({}, function(plugin, viewer, config, moves, opened, tick, timer)
                plugin:previewSmoothSettings(viewer, config.page)
                if close_before then
                    viewer._panels_plus_closed = true
                end
                tick()
                if not close_before then
                    viewer.complete()
                    viewer._panels_plus_closed = true
                    timer()
                end
                assert.equals(close_before and 0 or 1, #moves)
                assert.equals(0, #opened)
                assert.is_nil(viewer._panels_plus_smooth_preview)
            end)
        end
    end)

    it("ignores duplicate previews and non-Smooth modes", function()
        withPreview({}, function(plugin, viewer, config, _, _, _, _, ticks)
            viewer.nav_transition_mode = "animated"
            assert.is_false(plugin:previewSmoothSettings(viewer, config.page))
            assert.equals(0, #ticks)
            viewer.nav_transition_mode = "smooth"
            assert.is_true(plugin:previewSmoothSettings(viewer, config.page))
            assert.is_false(plugin:previewSmoothSettings(viewer, config.page))
            assert.equals(1, #ticks)
        end)
    end)

    it("blocks reading navigation during a round-trip preview", function()
        local viewer =
            PanelViewer:new({ _images_list_cur = 1, _images_list_nb = 2, _panels_plus_smooth_preview = true })
        local moves = 0
        viewer.animateSwitchToImageNum = function()
            moves = moves + 1
        end
        viewer:onShowNextImage()
        viewer:onShowPrevImage()
        assert.equals(0, moves)
        assert.equals(1, viewer._images_list_cur)
    end)
end)
