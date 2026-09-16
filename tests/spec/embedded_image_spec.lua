--[[
Panels+
File: tests/spec/embedded_image_spec.lua
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

describe("EmbeddedImage KEPUB compatibility", function()
    it("opens image panels for direct and Kobo-synced KEPUB filenames", function()
        for _, filename in ipairs({ "/books/manga.kepub", "/books/manga.kepub.epub", "/books/MANGA.KEPUB" }) do
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

    it("cancels every hidden search turn, including pages without an image", function()
        local handle = spy()
        local cancel_animation = spy()
        local old_tick = UIManager.tickAfterNext
        local old_set_swipe_animations = Screen.setSwipeAnimations
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
                handleEvent = handle,
            },
            findEmbeddedImageOnCurrentPage = function()
                return nil
            end,
            _embedded_search_generation = 7,
        }
        local viewer = {}
        plugin._embedded_search_viewer = viewer

        assert.is_true(EmbeddedImage.openNextEmbeddedImagePage(plugin, 5, "next", viewer, 7))
        assert.equals("GotoPage", handle:lastCall()[2].name)
        assert.equals(6, handle:lastCall()[2].args[1])
        assert.equals(1, cancel_animation:callCount())
        assert.equals(false, cancel_animation:lastCall()[2])

        UIManager.tickAfterNext = old_tick
        Screen.setSwipeAnimations = old_set_swipe_animations
    end)
end)

describe("EmbeddedImage native page animation", function()
    it("arms one normal page animation only when replacing the source viewer", function()
        local PageBitmap = require("src._pagebitmap")
        local ComponentDetector = require("src._componentdetector")
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
        UIManager.show = function() end

        local arm_animation = spy()
        local plugin = {
            settings = {
                mode = "manga",
                crop_mode = "strict",
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
    it("keeps a cross-image boundary classic while same-image smooth rendering is available", function()
        local boundary = spy()
        boundary.return_value = true
        local animated = spy()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_cross_page = true,
            image_union_renderer = function()
                return nil
            end,
            boundary_callback = boundary,
            animateBoundaryTransition = animated,
        })

        assert.is_true(viewer:onPanelBoundary("next"))
        assert.is_true(boundary:called())
        assert.is_false(animated:called())
    end)
end)

describe("EmbeddedImage source lifetime", function()
    it("releases the full source and lazy navigation closures during a boundary search", function()
        local free = spy()
        local viewer = PanelViewer:new({
            embedded_source_image = { free = free },
            image_union_renderer = function() end,
            _images_list = { function() end },
            image_rects = { {} },
            panels = { {} },
            panel_is_full_page = { false },
        })

        viewer:releaseEmbeddedSource(true)

        assert.is_true(free:called())
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
        assert.equals(600, show:lastCall()[3].start_point.x)
        assert.is_false(show:lastCall()[3].buttons_visible)
        assert.is_nil(viewer.embedded_source_image)
        UIManager.close = old_close
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
        assert.equals(600, show:lastCall()[3].start_point.x)
        assert.equals(300, show:lastCall()[3].start_point.y)
        assert.is_true(show:lastCall()[3].buttons_visible)

        UIManager.close, UIManager.broadcastEvent, UIManager.onRotation = old_close, old_broadcast, old_rotation
    end)
end)
