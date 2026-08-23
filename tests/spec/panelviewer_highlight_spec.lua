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
        _images_list_cur = 1,
        image_rects = { crop_rect },
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
end)
