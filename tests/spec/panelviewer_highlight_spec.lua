--[[
Panels+
File: tests/spec/panelviewer_highlight_spec.lua
Name: PanelViewer highlight specs
Description: Verifies normal highlight fill and anomalous-box outline rendering.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `PanelViewer:paintHighlights`'s anomalous-box guard -- the fix
--- for the "big black square" bug: a highlight box that covers most/all of
--- the current panel crop (a coarse/oversized OCR word or line box, common
--- on manga/comic art whether from a PDF's own text layer or KOReader's
--- on-the-fly OCR fallback for CBZ/CBR) should be outlined, not filled.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")

--- A 300x400 native-page-space panel, rendered at 1:1 zoom (bb == rect),
--- with a spy-recording fake blitbuffer.
local function newViewerAndBB()
    local crop_rect = { x = 0, y = 0, w = 300, h = 400 }
    local wg = {
        getSize = function() end,
        getCurrentWidth = function()
            return 300
        end,
        getCurrentHeight = function()
            return 400
        end,
        dimen = { x = 0, y = 0 },
        _offset_x = 0,
        _offset_y = 0,
    }
    local invert_spy = spy()
    local darken_spy = spy()
    local bb = { invertRect = invert_spy, darkenRect = darken_spy }

    local viewer = PanelViewer:new({
        page = 1,
        _panels_plus_text_holding = true,
        _images_list_cur = 1,
        image_rects = { crop_rect, { x = 40, y = 0, w = 300, h = 400 } },
        rotated = false,
        _image_wg = wg,
        reader_ui = {
            view = {
                highlight = { temp = {}, temp_drawer = "invert" },
                -- drawHighlightRect intentionally absent: exercises the raw
                -- invertRect/darkenRect fallback path directly.
            },
            highlight = { selected_text = nil },
        },
    })
    return viewer, bb, invert_spy, darken_spy
end

describe("PanelViewer:paintHighlights anomalous box guard", function()
    it("fills a normal, small word-sized box with a single invertRect", function()
        local viewer, bb, invert_spy = newViewerAndBB()
        viewer.reader_ui.view.highlight.temp[1] = { { x = 50, y = 50, w = 30, h = 20 } }

        viewer:paintHighlights(bb, 0, 0)

        assert.equals(1, invert_spy:callCount(), "expected exactly one full-fill invertRect call")
        local call = invert_spy:lastCall()
        -- call = { n, self(bb), x, y, w, h }
        assert.equals(50, call[2])
        assert.equals(50, call[3])
        assert.equals(30, call[4])
        assert.equals(20, call[5])
    end)

    it("outlines instead of filling a box covering the whole panel crop", function()
        local viewer, bb, invert_spy = newViewerAndBB()
        -- Box exactly matches the crop rect: ratio 1.0, well past the anomaly threshold.
        viewer.reader_ui.view.highlight.temp[1] = { { x = 0, y = 0, w = 300, h = 400 } }

        viewer:paintHighlights(bb, 0, 0)

        assert.equals(4, invert_spy:callCount(), "expected 4 thin border strips, not a full fill")
        for _, call in ipairs(invert_spy.calls) do
            local w, h = call[4], call[5]
            assert.is_false(w == 300 and h == 400, "no single strip should cover the full panel")
        end
    end)

    it("does not outline a moderately large but still reasonable box", function()
        local viewer, bb, invert_spy = newViewerAndBB()
        -- 100x100 box against a 300x400 (120000 area) crop: ratio ~0.083, well under threshold.
        viewer.reader_ui.view.highlight.temp[1] = { { x = 10, y = 10, w = 100, h = 100 } }

        viewer:paintHighlights(bb, 0, 0)

        assert.equals(1, invert_spy:callCount())
    end)

    it("does not repaint a retained OCR box after the hold ends", function()
        local viewer, bb, invert_spy = newViewerAndBB()
        local box = { x = 50, y = 50, w = 30, h = 20 }
        viewer.reader_ui.view.highlight.temp[1] = { box }
        viewer.reader_ui.highlight.selected_text = { text = "word", sboxes = { box } }

        viewer:paintHighlights(bb, 0, 0)
        assert.equals(1, invert_spy:callCount())

        viewer.reader_ui.highlight.onHoldRelease = function() end
        viewer:onHoldRelease(nil, { pos = {} })
        viewer._images_list_cur = 2 -- The next panel overlaps the old word's page-space box.
        viewer:paintHighlights(bb, 0, 0)

        assert.equals(1, invert_spy:callCount(), "released selection must not reappear on a later redraw")
        assert.is_not_nil(viewer.reader_ui.view.highlight.temp[1], "reader-owned selection is left to KOReader")
    end)
end)

describe("PanelViewer document inversion", function()
    for _, night_mode in ipairs({ false, true }) do
        for _, setting in ipairs({ "no document", "unset", 0, 1 }) do
            it(
                "matches document inversion with night mode "
                    .. tostring(night_mode)
                    .. " and setting "
                    .. tostring(setting),
                function()
                    local viewer, bb, invert_spy = newViewerAndBB()
                    viewer._image_wg.dimen = { x = 10, y = 20, w = 300, h = 400 }
                    if setting ~= "no document" then
                        viewer.reader_ui.document = { configurable = {} }
                        if type(setting) == "number" then
                            viewer.reader_ui.document.configurable.nightmode_document = setting
                        end
                    end
                    local screen = require("device").screen
                    local old_night_mode = screen.night_mode
                    screen.night_mode = night_mode
                    viewer:paintTo(bb, 0, 0)
                    screen.night_mode = old_night_mode

                    assert.is_false(viewer._image_wg.original_in_nightmode)
                    local expected = night_mode and setting == 1 and 1 or 0
                    assert.equals(expected, invert_spy:callCount())
                    if expected == 1 then
                        local call = invert_spy:lastCall()
                        assert.equals(10, call[2])
                        assert.equals(20, call[3])
                        assert.equals(300, call[4])
                        assert.equals(400, call[5])
                    end
                end
            )
        end
    end

    it("preserves only image pixels inside a letterboxed viewport", function()
        local viewer, bb, invert_spy = newViewerAndBB()
        viewer.reader_ui.document = { configurable = { nightmode_document = 1 } }
        viewer._image_wg.dimen = { x = 10, y = 20, w = 600, h = 800 }
        viewer._image_wg._offset_x = -150
        viewer._image_wg._offset_y = -200
        local screen = require("device").screen
        local old_night_mode = screen.night_mode
        screen.night_mode = true
        viewer:paintTo(bb, 0, 0)
        screen.night_mode = old_night_mode

        assert.equals(1, invert_spy:callCount())
        local call = invert_spy:lastCall()
        assert.equals(160, call[2])
        assert.equals(220, call[3])
        assert.equals(300, call[4])
        assert.equals(400, call[5])
    end)

    it("matches blit rounding at the bottom and right of fractional Smooth margin frames", function()
        local screen = require("device").screen
        local old_night_mode = screen.night_mode
        for _, factor in ipairs({ 0.88, 0.879999999, 0.873, 0.8125 }) do
            local viewer, bb, invert_spy = newViewerAndBB()
            local width, height = 600 * factor, 800 * factor
            local frame_w, frame_h = math.floor(width), math.floor(height)
            local ox, oy = math.floor((frame_w - width) / 2), math.floor((frame_h - height) / 2)
            viewer.reader_ui.document = { configurable = { nightmode_document = 1 } }
            viewer._image_wg.dimen = { x = 10, y = 20, w = width, h = height }
            viewer._image_wg._offset_x, viewer._image_wg._offset_y = ox, oy
            viewer._image_wg.getCurrentWidth = function()
                return frame_w
            end
            viewer._image_wg.getCurrentHeight = function()
                return frame_h
            end
            screen.night_mode = true
            viewer:paintTo(bb, 0, 0)
            screen.night_mode = old_night_mode

            local call = invert_spy:lastCall()
            assert.equals(10 - ox, call[2])
            assert.equals(20 - oy, call[3])
            assert.equals(math.floor(width + ox), call[4])
            assert.equals(math.floor(height + oy), call[5])
        end
    end)
end)
