--[[
Panels+
File: tests/embedded_image_spec.lua
Name: Embedded image specs
Description: Verifies reflow-image detection, navigation, animation, rotation, and source lifetime.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Reflow image-panel flow: cross a reader-page boundary and keep seeking.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local EmbeddedImage = require("src.embedded_image")
local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

describe("EmbeddedImage panel finding selection", function()
    it("passes the source image back through detection when switching modes", function()
        local old_close = UIManager.close
        local closed = spy()
        UIManager.close = closed
        local opened = spy()
        local image = {}
        local viewer = {
            embedded_source_image = image,
            panels = { { x = 10, y = 20, w = 100, h = 80 } },
            _images_list_cur = 1,
        }
        local plugin = { showEmbeddedImagePanelsForImage = opened }
        EmbeddedImage.reopenEmbeddedImagePanels(plugin, viewer, { redetect = true })
        UIManager.close = old_close
        assert.is_true(closed:called())
        assert.is_nil(viewer.embedded_source_image)
        assert.equals(image, opened:lastCall()[2])
        assert.is_nil(opened:lastCall()[3].panels)
        assert.equals(60, opened:lastCall()[3].start_point.x)
        assert.is_true(opened:lastCall()[3].buttons_visible)
    end)
end)

describe("EmbeddedImage reflow format compatibility", function()
    it("opens image panels for EPUB, MOBI, and direct and Kobo-synced KEPUB filenames", function()
        local filenames = {
            "/books/manga.epub",
            "/books/manga.mobi",
            "/books/manga.kepub",
            "/books/manga.kepub.epub",
            "/books/MANGA.KEPUB",
        }
        for _, filename in ipairs(filenames) do
            local opened = spy()
            opened.return_value = true
            local image = {
                getType = function()
                    return 1
                end,
            }
            local plugin = {
                ui = {
                    rolling = true,
                    document = {
                        file = filename,
                        getImageFromPosition = function()
                            return image
                        end,
                    },
                },
                showEmbeddedImagePanelsForImage = opened,
            }
            local cleared = spy()
            local highlight = {
                view = {
                    screenToPageTransform = function()
                        return { x = 10, y = 20 }
                    end,
                },
                clear = cleared,
            }

            assert.is_true(EmbeddedImage.showEmbeddedImagePanels(plugin, highlight, { pos = { x = 1, y = 1 } }))
            assert.equals(image, opened:lastCall()[2], filename .. " should use the embedded-image panel path")
            assert.is_true(cleared:called())
        end
    end)
end)

describe("EmbeddedImage boundary flow", function()
    it("turns the reader page, keeps the viewer up, and seeks the next image", function()
        local close = spy()
        local handle = spy()
        local seek = spy()
        local cancel_animation = spy()
        local old_close, old_tick = UIManager.close, UIManager.tickAfterNext
        local old_set_swipe_animations = Screen.setSwipeAnimations
        UIManager.close = close
        Screen.setSwipeAnimations = function(...)
            return cancel_animation(...)
        end
        UIManager.tickAfterNext = function(_, callback)
            UIManager._embedded_image_test_callback = callback
            return true
        end

        local plugin = {
            ui = {
                document = {
                    getCurrentPage = function()
                        return 4
                    end,
                    getNextPage = function(_, page)
                        return page == 4 and 5 or 0
                    end,
                },
                handleEvent = handle,
            },
            openNextEmbeddedImagePage = seek,
        }
        local release_source = spy()
        local viewer = {
            releaseEmbeddedSource = release_source,
        }

        assert.is_true(EmbeddedImage.onEmbeddedImageBoundary(plugin, "next", viewer))
        assert.is_false(close:called(), "old panel viewer must stay up while the next image is being found")
        assert.equals("GotoPage", handle:lastCall()[2].name)
        assert.equals(5, handle:lastCall()[2].args[1])
        assert.equals(false, cancel_animation:lastCall()[2])
        assert.is_true(release_source:called())
        assert.equals(true, release_source:lastCall()[2])

        UIManager._embedded_image_test_callback()
        assert.equals(5, seek:lastCall()[2])
        assert.equals("next", seek:lastCall()[3])
        assert.equals(viewer, seek:lastCall()[4], "the found image should replace this viewer without a reader flash")

        UIManager.close, UIManager.tickAfterNext = old_close, old_tick
        Screen.setSwipeAnimations = old_set_swipe_animations
    end)

    it("suppresses refresh requests and hardware swipes on hidden search turns", function()
        local handle = spy()
        local cancel_animation = spy()
        local repaint = spy()
        local old_tick, old_dirty = UIManager.tickAfterNext, UIManager.setDirty
        local old_set_swipe_animations = Screen.setSwipeAnimations
        UIManager.setDirty = repaint
        UIManager.tickAfterNext = function(_, callback)
            UIManager._embedded_image_test_callback = callback
            return true
        end
        Screen.setSwipeAnimations = function(...)
            return cancel_animation(...)
        end

        local plugin = {
            ui = {
                document = {
                    getNextPage = function(_, page)
                        return page + 1
                    end,
                },
                handleEvent = function(ui, event)
                    handle(ui, event)
                    UIManager:setDirty(ui, "partial") -- ReaderView:recalculate()
                    UIManager:setDirty(nil, function()
                        return "ui"
                    end)
                end,
            },
            findEmbeddedImageOnCurrentPage = function()
                return nil
            end,
            _embedded_search_generation = 7,
        }
        local viewer = {}
        plugin._embedded_search_viewer = viewer

        local handled = EmbeddedImage.openNextEmbeddedImagePage(plugin, 5, "next", viewer, 7)
        local dirty_restored = UIManager.setDirty == repaint
        UIManager.tickAfterNext, UIManager.setDirty = old_tick, old_dirty
        Screen.setSwipeAnimations = old_set_swipe_animations

        assert.is_true(handled)
        assert.equals("GotoPage", handle:lastCall()[2].name)
        assert.equals(6, handle:lastCall()[2].args[1])
        assert.equals(1, cancel_animation:callCount())
        assert.equals(false, cancel_animation:lastCall()[2])

        assert.is_false(repaint:called())
        assert.is_true(dirty_restored)
    end)
end)

describe("EmbeddedImage native page animation", function()
    it("arms one normal page animation only when replacing the source viewer", function()
        local PageBitmap = require("src._pagebitmap")
        local ComponentDetector = require("src._smartcomponentdetector")
        local old_build = PageBitmap.buildFromBlitbuffer
        local old_detect = ComponentDetector.detectPage
        local old_close, old_show = UIManager.close, UIManager.show
        PageBitmap.buildFromBlitbuffer = function()
            return {}
        end
        ComponentDetector.detectPage = function()
            return { { x = 0, y = 0, w = 600, h = 800 } }
        end
        UIManager.close = function() end
        local opened_viewer
        UIManager.show = function(_, viewer)
            opened_viewer = viewer
        end

        local arm_animation = spy()
        local plugin = {
            getSelectedOcrModel = function()
                return "eng"
            end,
            settings = {
                mode = "manga",
                crop_mode = "strict",
                panel_finding_mode = "smart",
                embedded_nav_transition_mode = "classic",
            },
            ui = {},
            armPageTurnAnimation = arm_animation,
        }
        local function image()
            return {
                w = 600,
                h = 800,
                getType = function()
                    return 1
                end,
            }
        end

        assert.is_true(EmbeddedImage.showEmbeddedImagePanelsForImage(plugin, image()))
        assert.is_false(arm_animation:called(), "initial opens must not look like page turns")
        assert.equals(nil, next(opened_viewer.panel_zoom_settings))
        assert.equals(nil, opened_viewer.panel_zoom_settings.mode)
        opened_viewer.panel_zoom_settings.panel_zoom_factor = 2.25
        assert.equals(2.25, plugin.settings.panel_zoom_factor)
        local zoom_calls = 0
        opened_viewer.toggleGestureZoom = function()
            zoom_calls = zoom_calls + 1
            return true
        end
        plugin.settings.panel_zoom_enabled = true
        plugin.settings.panel_zoom_gesture_type = "two_finger_tap"
        assert.is_true(opened_viewer:onGesture({ ges = "two_finger_tap", pos = { x = 100, y = 100 } }))
        assert.equals(1, zoom_calls)

        local source_viewer = {}
        assert.is_true(EmbeddedImage.showEmbeddedImagePanelsForImage(plugin, image(), {
            replace_viewer = source_viewer,
            boundary_direction = "next",
        }))
        assert.equals(1, arm_animation:callCount())
        assert.equals("next", arm_animation:lastCall()[2])
        assert.equals(source_viewer, arm_animation:lastCall()[3])

        PageBitmap.buildFromBlitbuffer = old_build
        ComponentDetector.detectPage = old_detect
        UIManager.close, UIManager.show = old_close, old_show
    end)
end)

describe("EmbeddedImage smooth boundaries", function()
    local function crossBoundary(direction, enabled, finish)
        local Blitbuffer = require("ffi/blitbuffer")
        local Memory = require("src._memory")
        local RenderImage = require("ui/renderimage")
        local new_buffer, scale = Blitbuffer.new, RenderImage.scaleBlitBuffer
        local memory_check = Memory.hasAllocationHeadroom
        local close, tick = UIManager.close, UIManager.tickAfterNext
        Blitbuffer.new = function(w, h, kind)
            local bb = new_buffer(w, h, kind)
            bb.getWidth = function()
                return w
            end
            bb.getHeight = function()
                return h
            end
            bb.free = spy()
            return bb
        end
        Memory.hasAllocationHeadroom = function()
            return finish ~= "low memory"
        end
        RenderImage.scaleBlitBuffer = function(_, _, w, h)
            return Blitbuffer.new(w, h, 0)
        end
        UIManager.close = function(_, viewer)
            viewer:onCloseWidget()
        end
        UIManager.tickAfterNext = spy()

        local source = Blitbuffer.new(600, 800, 0)
        local outgoing = Blitbuffer.new(400, 800, 0)
        local target = Blitbuffer.new(800, 1200, 0)
        local page = 4
        local plugin = setmetatable({
            settings = {
                mode = "manga",
                crop_mode = "strict",
                embedded_nav_transition_mode = "smooth",
                nav_transition_cross_page = enabled,
            },
            ui = {
                document = {
                    getCurrentPage = function()
                        return page
                    end,
                    getNextPage = function(_, current)
                        return current + 1
                    end,
                    getPrevPage = function(_, current)
                        return current - 1
                    end,
                },
                handleEvent = function(_, event)
                    page = event.args[1]
                end,
            },
            getSelectedOcrModel = function()
                return "eng"
            end,
            armPageTurnAnimation = function() end,
            findEmbeddedImageOnCurrentPage = function()
                if page == 2 or page == 6 then
                    return target
                end
            end,
            showEmbeddedImagePanelsForImage = function(self, image, options)
                options.panels = { { x = 0, y = 0, w = 800, h = 600 }, { x = 0, y = 600, w = 800, h = 600 } }
                return EmbeddedImage.showEmbeddedImagePanelsForImage(self, image, options)
            end,
        }, { __index = EmbeddedImage })
        local pan = spy()
        local viewer = PanelViewer:new({
            page = 1,
            image = outgoing,
            image_disposable = true,
            embedded_source_image = source,
            nav_transition_mode = "smooth",
            nav_transition_cross_page = enabled,
            image_union_renderer = function() end,
            _image_wg = { width = 600, height = 800 },
            _images_list_nb = 1,
            _images_list_cur = 1,
            boundary_callback = function(next_direction, current)
                return plugin:onEmbeddedImageBoundary(next_direction, current)
            end,
            runNavPanAnimation = pan,
        })

        UIManager:show(viewer)
        local handled = direction == "next" and viewer:onShowNextImage() or viewer:onShowPrevImage()
        local released_before_search = source.free:called()
        UIManager.tickAfterNext:lastCall()[2]()
        local stayed_on_text_page = UIManager._last_shown == viewer and not pan:called()
        UIManager.tickAfterNext:lastCall()[2]()
        local still_visible = UIManager._last_shown == viewer
        local canvas = viewer.image
        local starting_ratio = viewer._center_x_ratio
        if finish == "close" then
            UIManager:close(viewer)
        elseif pan:called() then
            pan:lastCall()[4]()
        end
        local shown = UIManager._last_shown
        Blitbuffer.new, RenderImage.scaleBlitBuffer = new_buffer, scale
        Memory.hasAllocationHeadroom = memory_check
        UIManager.close, UIManager.tickAfterNext = close, tick

        assert.is_true(handled)
        assert.is_true(released_before_search)
        assert.is_true(stayed_on_text_page)
        assert.equals(direction == "next" and 6 or 2, page)
        assert.equals(enabled ~= false and finish ~= "low memory", pan:called())
        if pan:called() then
            assert.is_true(still_visible)
            assert.equals(1200, canvas.w)
            assert.equals(800, canvas.h)
            assert.equals(direction == "next" and 0.75 or 0.25, starting_ratio)
            assert.equals(1 - starting_ratio, pan:lastCall()[2])
            assert.equals(1, canvas.free:callCount())
            assert.equals(1, outgoing.free:callCount())
        end
        if finish == "close" then
            assert.equals(viewer, shown)
            assert.equals(1, target.free:callCount())
        else
            assert.equals(direction == "next" and 1 or 2, shown.initial_image_num)
            assert.equals(enabled ~= false, shown.nav_transition_cross_page)
            assert.equals(target, shown.embedded_source_image)
            assert.is_false(target.free:called())
        end
    end

    it("pans forward and backward after skipping text, then opens the correct landing panel", function()
        crossBoundary("next", nil, "land")
        crossBoundary("previous", true, "land")
    end)

    it("releases the destination when the viewer closes during the pan", function()
        crossBoundary("next", true, "close")
    end)

    it("opens the destination immediately with the option off or the animation over budget", function()
        crossBoundary("next", false, "land")
        crossBoundary("previous", true, "low memory")
    end)
end)

describe("EmbeddedImage source lifetime", function()
    it("releases the full source and lazy navigation closures during a boundary search", function()
        local free = spy()
        local viewer = PanelViewer:new({
            page = 1,
            embedded_source_image = { free = free },
            image_union_renderer = function() end,
            _images_list = { function() end },
            image_rects = { {} },
            panels = { {} },
            panel_is_full_page = { false },
        })

        viewer:releaseEmbeddedSource(true)

        assert.is_true(free:called())
        assert.is_nil(viewer.page)
        assert.equals(nil, viewer.embedded_source_image)
        assert.equals(nil, viewer.image_union_renderer)
        assert.equals(nil, viewer._images_list)
        assert.equals(nil, viewer.image_rects)
        assert.equals(nil, viewer.panels)
    end)

    it("consumes navigation while its source has been released for a boundary search", function()
        local viewer = PanelViewer:new({
            _panels_plus_boundary_pending = true,
            _images_list_cur = 2,
            _images_list_nb = 2,
        })

        assert.is_true(viewer:onShowNextImage())
        assert.is_true(viewer:onShowPrevImage())
    end)
end)

describe("EmbeddedImage backward landing", function()
    it("marks a previous-page image to open on its last panel", function()
        local show = spy()
        show.return_value = true
        local image = {}
        local plugin = {
            ui = {
                document = {},
            },
            findEmbeddedImageOnCurrentPage = function()
                return image
            end,
            showEmbeddedImagePanelsForImage = show,
        }

        assert.is_true(EmbeddedImage.openNextEmbeddedImagePage(plugin, 4, "previous", {}))
        assert.equals(image, show:lastCall()[2])
        assert.equals("previous", show:lastCall()[3].boundary_direction)
    end)
end)

describe("EmbeddedImage device rotation", function()
    it("reopens an embedded crop after auto-rotation without losing its panel or controls state", function()
        local old_close = UIManager.close
        local close = spy()
        local show = spy()
        show.return_value = true
        UIManager.close = function(_, viewer)
            close(viewer)
        end

        local image = { w = 800, h = 1200 }
        local plugin = setmetatable({ showEmbeddedImagePanelsForImage = show }, { __index = EmbeddedImage })
        local viewer = PanelViewer:new({
            region = { w = 824, h = 1648 },
            panels = { { x = 0, y = 0, w = 400, h = 600 }, { x = 400, y = 0, w = 400, h = 600 } },
            _images_list_cur = 2,
            embedded_source_image = image,
            buttons_visible = false,
            screen_resize_callback = function(current_viewer)
                return plugin:reopenEmbeddedImagePanels(current_viewer, {
                    buttons_visible = current_viewer.buttons_visible,
                })
            end,
        })

        assert.is_true(viewer:onScreenResize({ w = 1648, h = 824 }))
        assert.equals(1, close:callCount())
        assert.equals(1, show:callCount())
        assert.equals(image, show:lastCall()[2])
        assert.equals(viewer.panels, show:lastCall()[3].panels)
        assert.equals(600, show:lastCall()[3].start_point.x)
        assert.is_false(show:lastCall()[3].buttons_visible)
        assert.is_nil(viewer.embedded_source_image)
        UIManager.close = old_close
    end)

    it("reuses detected panels when auto-rotation rebuilds an embedded viewer", function()
        local PageBitmap = require("src._pagebitmap")
        local ComponentDetector = require("src._smartcomponentdetector")
        local old_build = PageBitmap.buildFromBlitbuffer
        local old_detect = ComponentDetector.detectPage
        local old_width, old_height = Screen.getWidth, Screen.getHeight
        local screen_w, screen_h = 600, 800
        local detection_count = 0
        Screen.getWidth = function()
            return screen_w
        end
        Screen.getHeight = function()
            return screen_h
        end
        PageBitmap.buildFromBlitbuffer = function()
            detection_count = detection_count + 1
            return {}
        end
        ComponentDetector.detectPage = function()
            return {
                { x = 0, y = 0, w = 800, h = 600 },
                { x = 0, y = 600, w = 800, h = 600 },
            }
        end

        local plugin = setmetatable({
            getSelectedOcrModel = function()
                return "eng"
            end,
            settings = {
                mode = "manga",
                crop_mode = "strict",
                panel_finding_mode = "smart",
                embedded_nav_transition_mode = "classic",
            },
            ui = {},
        }, { __index = EmbeddedImage })
        local image = {
            w = 800,
            h = 1200,
            getType = function()
                return 1
            end,
        }

        assert.is_true(plugin:showEmbeddedImagePanelsForImage(image, { start_point = { x = 400, y = 900 } }))
        local portrait_viewer = UIManager._last_shown
        -- The lightweight ImageViewer test stub does not call init from new().
        portrait_viewer:init()
        portrait_viewer.region = { w = screen_w, h = screen_h }
        assert.equals(2, portrait_viewer._images_list_cur)
        assert.equals(1, detection_count)

        screen_w, screen_h = 800, 600
        assert.is_true(portrait_viewer:onScreenResize({ w = screen_w, h = screen_h }))
        local landscape_viewer = UIManager._last_shown
        landscape_viewer:init()
        assert.is_true(landscape_viewer ~= portrait_viewer)
        assert.equals(2, landscape_viewer._images_list_cur)
        assert.equals(1, detection_count)

        PageBitmap.buildFromBlitbuffer = old_build
        ComponentDetector.detectPage = old_detect
        Screen.getWidth, Screen.getHeight = old_width, old_height
    end)

    it("reopens the viewer at the current panel across screen rotation", function()
        local show = spy()
        show.return_value = true
        local close = spy()
        local broadcast = spy()
        local rotated = spy()
        local old_close, old_broadcast, old_rotation = UIManager.close, UIManager.broadcastEvent, UIManager.onRotation
        UIManager.close = close
        UIManager.broadcastEvent = broadcast
        UIManager.onRotation = rotated

        local image = { w = 800, h = 1200 }
        local plugin = {
            showEmbeddedImagePanelsForImage = show,
        }
        local viewer = {
            panels = { { x = 0, y = 0, w = 400, h = 600 }, { x = 400, y = 0, w = 400, h = 600 } },
            _images_list_cur = 2,
            embedded_source_image = image,
            buttons_visible = true,
        }

        assert.is_true(EmbeddedImage.setDeviceRotation(plugin, viewer, 1))
        assert.is_true(close:called())
        assert.is_true(broadcast:called())
        assert.equals("SetRotationMode", broadcast:lastCall()[2].name)
        assert.equals(1, broadcast:lastCall()[2].args[1])
        assert.is_true(rotated:called())
        assert.equals(image, show:lastCall()[2])
        assert.equals(viewer.panels, show:lastCall()[3].panels)
        assert.equals(600, show:lastCall()[3].start_point.x)
        assert.equals(300, show:lastCall()[3].start_point.y)
        assert.is_true(show:lastCall()[3].buttons_visible)

        UIManager.close, UIManager.broadcastEvent, UIManager.onRotation = old_close, old_broadcast, old_rotation
    end)
end)
