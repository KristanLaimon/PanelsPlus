--[[
Panels+
File: tests/spec/wordfinder_spec.lua
Name: WordFinder specs
Description: Verifies comic word-box heuristics, OCR normalization, retries, and cache cleanup.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src._wordfinder`'s core claim: word boundaries should be found
--- by a gap threshold relative to the text line's own height, so tight
--- inter-letter kerning (common in stylized comic lettering) is not mistaken
--- for a word boundary, while a real gap between two words still is.
---
--- This is the fix for the bug where a tap on "VEN" returned "V" or "EN",
--- and a tap near "white rice" returned neither word intact.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local WordFinder = require("src._wordfinder")

--- Build a `pixels[y][x] -> luminance` grid, white (255) by default, with a
--- single text line made of one or more "words" -- each word a set of
--- letter-shaped ink blocks separated by tight kerning gaps, with a wide
--- blank gap between words.
---
--- @param w integer Grid width.
--- @param h integer Grid height.
--- @param words table List of `{x0, x1}` ink spans, one per word (each
---   internally subdivided into 30px letter blocks with 3px kerning gaps).
--- @param y0 integer First ink row of the text line.
--- @param y1 integer Last ink row of the text line.
--- @param letter_gap integer|nil Kerning gap between letter blocks (default 3).
local function buildLineGrid(w, h, words, y0, y1, letter_gap)
    letter_gap = letter_gap or 3
    local pixels = {}
    for y = 0, h - 1 do
        pixels[y] = {}
        for x = 0, w - 1 do
            pixels[y][x] = 255
        end
    end
    for _, word in ipairs(words) do
        local x = word[1]
        while x <= word[2] do
            local block_end = math.min(x + 29, word[2])
            for y = y0, y1 do
                for bx = x, block_end do
                    pixels[y][bx] = 0
                end
            end
            x = block_end + 1 + letter_gap
        end
    end
    return pixels
end

--- A fake KOReader paging document: `getNativePageDimensions` returns fixed
--- native page dimensions, and `renderPage`/`transformRect` produce a
--- greyscale-sampleable fake blitbuffer over `pixels`, cropped/zoomed the
--- same way `_wordfinder` expects a real `Document:renderPage()` call to.
--- `transformRect` and `renderPage` reproduce real KOReader's tile geometry
--- exactly, because the word finder depends on it: `Geom:transformByScale`
--- *floors* the scaled origin and `Document:renderPage` then draws the page
--- offset by that floored value, so tile pixel (x, y) is page pixel
--- ((scaled.x + x) / zoom, (scaled.y + y) / zoom) -- not (rect.x + x / zoom).
local function newFakeDocument(native_w, native_h, pixels)
    return {
        getNativePageDimensions = function()
            return { w = native_w, h = native_h }
        end,
        transformRect = function(_, rect, z)
            return {
                x = math.floor(rect.x * z + 0.001),
                y = math.floor(rect.y * z + 0.001),
                w = math.ceil(rect.w * z - 0.001),
                h = math.ceil(rect.h * z - 0.001),
            }
        end,
        renderPage = function(_, _pageno, rect, z)
            local scaled = rect.scaled_rect
            local origin_x, origin_y = scaled.x, scaled.y
            local bb = {
                w = scaled.w,
                h = scaled.h,
                getType = function()
                    return nil
                end, -- matches the test Blitbuffer mock's nil TYPE_BB8
                getRotation = function()
                    return 0
                end,
                getInverse = function()
                    return 0
                end,
                getPixel = function(_, x, y)
                    local src_x = (origin_x + x) / z
                    local src_y = (origin_y + y) / z
                    local v = (pixels[math.floor(src_y)] or {})[math.floor(src_x)] or 255
                    return {
                        getColor8 = function()
                            return { a = v }
                        end,
                    }
                end,
            }
            return { bb = bb }
        end,
    }
end

--- A `pixels[y][x]` grid of plain white, ready to draw ink blocks into.
local function blankPixels(w, h)
    local pixels = {}
    for y = 0, h - 1 do
        pixels[y] = {}
        for x = 0, w - 1 do
            pixels[y][x] = 255
        end
    end
    return pixels
end

--- Fill a rectangular block of `pixels` with ink.
local function fillInk(pixels, x0, y0, x1, y1, value)
    for y = y0, y1 do
        for x = x0, x1 do
            pixels[y][x] = value or 0
        end
    end
end

describe("WordFinder:findWordBox word-vs-letter gap threshold", function()
    -- A 1000x1000 native page; a text line at native y=[80,120] with two
    -- "words": a 4-letter word spanning native x=[100,228], then a real
    -- word-gap, then a second word at native x=[300,450].
    local native_w, native_h = 1000, 1000
    local line_y0, line_y1 = 80, 120
    local word_a = { 100, 228 }
    local word_b = { 300, 450 }

    it("does not split a word on tight inter-letter kerning", function()
        local pixels = buildLineGrid(native_w, native_h, { word_a, word_b }, line_y0, line_y1)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- Tap inside word A's third letter block, at its native centre.
        local box = WordFinder.findWordBox(document, 1, 150, 100)

        assert.is_not_nil(box, "expected a word box to be found")
        -- The whole word (all four kerned letter blocks) should be covered...
        assert.is_true(box.w > 60, "box should span multiple letter blocks, not just one (w=" .. tostring(box.w) .. ")")
        -- ...but the real word-gap should still keep word B out of the box.
        assert.is_true(box.x + box.w < word_b[1], "box should not reach into the next word")
        assert.is_true(box.x < word_a[1] + 15, "box should start at/near word A's own left edge")
    end)

    it("still separates two words across a real word-gap", function()
        local pixels = buildLineGrid(native_w, native_h, { word_a, word_b }, line_y0, line_y1)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- Tap inside word B this time.
        local box = WordFinder.findWordBox(document, 1, 375, 100)

        assert.is_not_nil(box, "expected a word box to be found")
        assert.is_true(box.x > word_a[2], "box should not reach back into the previous word")
        assert.is_true(box.x + box.w <= word_b[2] + 20, "box should not overshoot past word B")
    end)
end)

describe("WordFinder:findWordBox short lines inside a speech bubble", function()
    it("does not use the bubble margins as inter-letter spacing", function()
        local pixels = blankPixels(1000, 1000)
        fillInk(pixels, 325, 90, 326, 111)
        fillInk(pixels, 400, 90, 411, 111)
        fillInk(pixels, 420, 90, 439, 111)
        fillInk(pixels, 443, 90, 460, 111)
        fillInk(pixels, 530, 90, 531, 111)
        local document = newFakeDocument(1000, 1000, pixels)

        local first = WordFinder.findWordBox(document, 1, 406, 100)
        local second = WordFinder.findWordBox(document, 1, 430, 100)
        assert.is_not_nil(first)
        assert.is_not_nil(second)
        assert.is_true(first.x + first.w < 420, "first word must exclude the second")
        assert.is_true(second.x > 411, "second word must exclude the first")
        assert.is_true(second.x + second.w >= 460, "second word must retain both glyph groups")
    end)
end)

describe("WordFinder:findWordBox sparse and mixed spacing", function()
    it("separates connected short words when word gaps dominate the median", function()
        local pixels = blankPixels(1000, 1000)
        fillInk(pixels, 100, 90, 119, 112)
        fillInk(pixels, 122, 90, 139, 112)
        fillInk(pixels, 151, 90, 169, 112)
        fillInk(pixels, 182, 90, 200, 112)
        local box = WordFinder.findWordBox(newFakeDocument(1000, 1000, pixels), 1, 160, 100)
        assert.is_not_nil(box)
        assert.is_true(box.x > 139 and box.x + box.w < 182, "isolate the middle word")
    end)

    it("keeps a two-pixel internal gap in a sparsely connected word", function()
        local pixels = blankPixels(1000, 1000)
        fillInk(pixels, 100, 90, 119, 112)
        fillInk(pixels, 121, 90, 139, 112)
        fillInk(pixels, 142, 90, 170, 112)
        local box = WordFinder.findWordBox(newFakeDocument(1000, 1000, pixels), 1, 150, 100)
        assert.is_not_nil(box)
        assert.is_true(box.x <= 100 and box.x + box.w >= 171, "retain every glyph group")
    end)

    it("preserves a well-sampled tracked heading with a few tighter pairs", function()
        local pixels = blankPixels(1000, 1000)
        local x = 300
        for _, gap in ipairs({ 2, 3, 3, 3, 4, 4, 5, 5, 5 }) do
            fillInk(pixels, x, 90, x + 4, 109)
            x = x + 5 + gap
        end
        fillInk(pixels, x, 90, x + 4, 109)
        local next_word = x + 19
        fillInk(pixels, next_word, 90, next_word + 19, 109)
        local box = WordFinder.findWordBox(newFakeDocument(1000, 1000, pixels), 1, 340, 100)
        assert.is_not_nil(box)
        assert.is_true(box.x <= 300 and box.x + box.w >= x + 5, "retain the tracked letters")
        assert.is_true(box.x + box.w < next_word, "exclude the next word")
    end)
end)

describe("WordFinder:findWordBox on x-height-only text (regression: 'eater' -> 'a')", function()
    -- A short line (x-height only, no ascenders/descenders reaching further
    -- up or down -- e.g. "eater") with wider-than-usual letter kerning, as
    -- seen in bold/wide comic fonts. A fixed line_h-ratio threshold
    -- undercuts this: 0.5 * 20 = 10 < 12, so the old code split every
    -- letter apart and isolated whichever one the tap landed nearest.
    local native_w, native_h = 1000, 1000
    local line_y0, line_y1 = 90, 109 -- 20px tall: x-height only
    local word_a = { 100, 320 } -- 5 letter blocks, 12px kerning gaps
    local word_b = { 400, 450 } -- genuine word gap (80px) after word A

    it("keeps the whole word together despite wide inter-letter kerning", function()
        local pixels = buildLineGrid(native_w, native_h, { word_a, word_b }, line_y0, line_y1, 12)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- Tap inside the second letter block (native x=[142,171]), same
        -- spot that used to isolate a single letter (e.g. the "a" in
        -- "eater").
        local box = WordFinder.findWordBox(document, 1, 155, 100)

        assert.is_not_nil(box, "expected a word box to be found")
        assert.is_true(box.w > 80, "box should span the whole word, not one letter block (w=" .. tostring(box.w) .. ")")
        assert.is_true(box.x + box.w < word_b[1], "box should not reach into the next word")
    end)
end)

describe("WordFinder:findWordBox multi-word line isolation (e.g. 'what's for dinner?')", function()
    local native_w, native_h = 1000, 1000
    local line_y0, line_y1 = 100, 125
    local word1 = { 100, 180 } -- "what's"
    local word2 = { 210, 260 } -- "for"
    local word3 = { 290, 390 } -- "dinner?"

    it("isolates middle word 'for' without swallowing the entire line", function()
        local pixels = buildLineGrid(native_w, native_h, { word1, word2, word3 }, line_y0, line_y1)
        local document = newFakeDocument(native_w, native_h, pixels)

        local box = WordFinder.findWordBox(document, 1, 235, 110)

        assert.is_not_nil(box, "expected word box for 'for'")
        assert.is_true(box.x >= word1[2], "box should not reach back into 'what\\'s'")
        assert.is_true(box.x + box.w <= word3[1], "box should not reach forward into 'dinner?'")
        assert.is_true(box.w >= 45, "box should cover 'for'")
    end)
end)

describe("WordFinder:findWordBox tight two-word phrase (e.g. 'my shift')", function()
    local native_w, native_h = 1000, 1000
    local line_y0, line_y1 = 100, 135 -- line height 35px
    local word_my = { 100, 140 } -- "my"
    local word_shift = { 148, 220 } -- "shift" (tight gap of 8px)

    it("separates 'shift' from 'my' across a tight 8px inter-word gap", function()
        local pixels = buildLineGrid(native_w, native_h, { word_my, word_shift }, line_y0, line_y1)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- Tap inside "shift" at native x=180
        local box = WordFinder.findWordBox(document, 1, 180, 115)

        assert.is_not_nil(box, "expected word box for 'shift'")
        assert.is_true(box.x >= word_my[2], "box should not reach back into 'my' (box.x=" .. tostring(box.x) .. ")")
        assert.is_true(box.x + box.w <= word_shift[2] + 10, "box should stay within 'shift'")
    end)
end)

describe("WordFinder:findWordBox multi-line speech bubble line height isolation", function()
    local native_w, native_h = 1000, 1000

    it("restricts vertical extent to tapped line instead of merging all lines in bubble", function()
        -- Build a 3-line speech bubble grid
        local pixels = {}
        for y = 0, native_h - 1 do
            pixels[y] = {}
            for x = 0, native_w - 1 do
                pixels[y][x] = 255
            end
        end
        -- Line 1 at y=[50, 75], Line 2 at y=[100, 125], Line 3 at y=[150, 175]
        local lines = { { 50, 75 }, { 100, 125 }, { 150, 175 } }
        for _, l in ipairs(lines) do
            for y = l[1], l[2] do
                for x = 100, 300 do
                    pixels[y][x] = 0
                end
            end
        end

        local document = newFakeDocument(native_w, native_h, pixels)
        -- Tap line 2 at (200, 112)
        local box = WordFinder.findWordBox(document, 1, 200, 112)

        assert.is_not_nil(box, "expected word box")
        -- Height should be near single line height (~25px), not 125px (all 3 lines)
        assert.is_true(box.h < 40, "box height should be single-line height, got h=" .. tostring(box.h))
        assert.is_true(box.y >= 95 and box.y <= 105, "box should start near line 2 top")
    end)
end)

describe("WordFinder:findWordBox vertical runaway guard (regression: box spans multiple lines)", function()
    -- Regression for a real OCR debug session failure: in a speech bubble
    -- where consecutive lines' words happen to share the same columns (e.g.
    -- left-aligned dialogue), a stray bridging stroke -- a descender, an
    -- accidental touch between two glyphs, scan noise -- inside the tapped
    -- word's own x-span but *outside* the line-height band's narrower fixed
    -- x-band can mean the word's own-columns ink check never finds a blank
    -- run between the lines, even though the surrounding band correctly saw
    -- one. Without a sanity clamp, `growRowExtent` then grows straight
    -- through into the next line and keeps going, producing a box several
    -- lines tall that OCR reads as nothing.
    local native_w, native_h = 1000, 1000

    it("clamps back to the single-line height when the word's own columns bridge into the next line", function()
        local pixels = blankPixels(native_w, native_h)
        -- Line A (tapped line): y=[100,118], word spans x=[250,370].
        fillInk(pixels, 250, 100, 370, 118)
        -- Line B, directly below with a real ~31-row blank gap: y=[150,168],
        -- same x-span (left-aligned dialogue two lines in a row).
        fillInk(pixels, 250, 150, 370, 168)
        -- The bridging stroke: continuous ink well above line A's top
        -- straight through to line B's bottom, but confined to a narrow
        -- column (x=[250,260]) *outside* the +/-30 native px fixed band the
        -- whole line's own height is measured from (tap at x=305 -> band
        -- [275,335]), so the line-height measurement itself stays correct.
        -- Extending past line A on both sides means the word's-own-columns
        -- search runs all the way to its outer search bound (+/-35 native
        -- px from the tap) in both directions instead of just one, matching
        -- how far the real runaway case actually grew.
        fillInk(pixels, 250, 65, 260, 168)

        local document = newFakeDocument(native_w, native_h, pixels)
        local box = WordFinder.findWordBox(document, 1, 305, 109)

        assert.is_not_nil(box, "expected a word box")
        assert.is_true(
            box.h < 40,
            "box height should stay single-line (~19px + padding), not bridge into line B, got h=" .. tostring(box.h)
        )
        assert.is_true(box.y >= 95 and box.y <= 105, "box should start at line A, got y=" .. tostring(box.y))
    end)
end)

describe("WordFinder:findWordBox background estimation with dense surrounding art", function()
    -- Regression for the real-world failure the flat-white fixtures above
    -- can't catch: a small speech bubble sitting inside a much larger area
    -- of dense, dark panel art/screentone, so the *whole render crop* (up to
    -- 30% of the page's width) is mostly art, not bubble background. A
    -- percentile taken over the whole crop lands on the art's luminance and
    -- flips polarity -- the bubble's white reads as "ink" and the word's
    -- actual black ink reads as background, so the box comes out nonsensical
    -- instead of merely imprecise.
    local native_w, native_h = 1000, 1000
    local ART_VALUE = 50
    local bubble = { x0 = 170, y0 = 80, x1 = 270, y1 = 120 }
    local word_a = { 190, 230 }

    local function buildPixels()
        local pixels = {}
        for y = 0, native_h - 1 do
            pixels[y] = {}
            for x = 0, native_w - 1 do
                pixels[y][x] = ART_VALUE
            end
        end
        for y = bubble.y0, bubble.y1 do
            for x = bubble.x0, bubble.x1 do
                pixels[y][x] = 255
            end
        end
        local x = word_a[1]
        while x <= word_a[2] do
            local block_end = math.min(x + 29, word_a[2])
            for y = 95, 105 do
                for bx = x, block_end do
                    pixels[y][bx] = 0
                end
            end
            x = block_end + 1 + 3
        end
        return pixels
    end

    it("does not mistake surrounding art for background / invert polarity", function()
        local pixels = buildPixels()
        local document = newFakeDocument(native_w, native_h, pixels)

        -- Tap inside the word, well within the bubble.
        local box = WordFinder.findWordBox(document, 1, 210, 100)

        assert.is_not_nil(box, "expected a word box to be found")
        assert.is_true(
            box.x >= bubble.x0 - 5,
            "box should stay inside the bubble, not the surrounding art (x=" .. tostring(box.x) .. ")"
        )
        assert.is_true(
            box.x + box.w <= bubble.x1 + 5,
            "box should not spill past the bubble's right edge (x+w=" .. tostring(box.x + box.w) .. ")"
        )
        assert.is_true(
            box.w < (bubble.x1 - bubble.x0),
            "box should be word-sized, not swallow the whole bubble/art region (w=" .. tostring(box.w) .. ")"
        )
    end)
end)

describe("WordFinder:findWordBox ink that runs off the render crop", function()
    -- The failure behind "it looks up a word that isn't there": when the
    -- tapped line's rows are covered edge to edge by something the ink test
    -- can't tell from lettering (screentone, a solid bubble border, a black
    -- panel gutter), no gap ever reaches the word-boundary threshold and the
    -- horizontal hunt simply runs to both edges of the render crop. The old
    -- code returned that crop-wide box and OCRed it, and Tesseract dutifully
    -- transcribed the noise into a plausible-looking word.
    local native_w, native_h = 1000, 1000

    it("returns nil instead of a crop-wide box when nothing bounds the run", function()
        local pixels = blankPixels(native_w, native_h)
        -- A solid black band across the entire page width at the tapped rows.
        fillInk(pixels, 0, 100, native_w - 1, 125)
        local document = newFakeDocument(native_w, native_h, pixels)

        local box = WordFinder.findWordBox(document, 1, 500, 112)

        assert.is_nil(box, "unbounded ink should fall back to KOReader's own box, not be OCRed")
    end)

    it("still finds a word whose blank margin is narrower than the gap threshold", function()
        -- Distinguishes "ran off the edge still on ink" from "ended in blank
        -- space that merely happened to be short": a long word can legitimately
        -- reach close to the crop edge, and that must not be rejected.
        local pixels = blankPixels(native_w, native_h)
        fillInk(pixels, 100, 100, 200, 125)
        local document = newFakeDocument(native_w, native_h, pixels)

        local box = WordFinder.findWordBox(document, 1, 150, 112)

        assert.is_not_nil(box, "a word bounded by blank space should still be found")
        assert.is_true(
            box.x >= 95 and box.x <= 105,
            "box should start at the word's left edge (x=" .. tostring(box.x) .. ")"
        )
    end)
end)

describe("WordFinder:findWordBox ascender outside the tap band (regression: clipped glyphs)", function()
    -- The tapped line's vertical extent is measured over a fixed band around
    -- the tap (+/-30 native px), which is narrower than most words. A tall
    -- letter belonging to the same word but sitting outside that band was
    -- invisible to the measurement, so the box cropped straight through it --
    -- and Tesseract reads a beheaded glyph as a different letter, or drops
    -- it, which is what "it only found part of the word" looks like.
    local native_w, native_h = 1000, 1000

    it("covers a tall letter at the far end of the word", function()
        local pixels = blankPixels(native_w, native_h)
        -- x-height body across the whole word...
        fillInk(pixels, 100, 100, 200, 125)
        -- ...plus an ascender at the word's right end, 60 native px away from
        -- the tap and therefore outside the band the line height came from.
        fillInk(pixels, 170, 80, 200, 99)
        local document = newFakeDocument(native_w, native_h, pixels)

        local box = WordFinder.findWordBox(document, 1, 115, 112)

        assert.is_not_nil(box, "expected a word box")
        assert.is_true(box.y <= 85, "box should reach up to the ascender (y=" .. tostring(box.y) .. ")")
        assert.is_true(
            box.y + box.h >= 120,
            "box should still cover the x-height body (y+h=" .. tostring(box.y + box.h) .. ")"
        )
    end)
end)

describe("WordFinder:findWordBox bounded snapping onto ink", function()
    -- A tap that lands on background used to snap to the nearest ink anywhere
    -- in the render crop, so a tap in a bubble's margin could silently jump to
    -- a different line entirely and describe the wrong word with confidence.
    local native_w, native_h = 1000, 1000

    it("gives up rather than snapping to a line far from the tap", function()
        local pixels = blankPixels(native_w, native_h)
        fillInk(pixels, 100, 100, 250, 125)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- 40 native px below the line's last ink row: inside the render crop,
        -- but further than one maximum line height away.
        local box = WordFinder.findWordBox(document, 1, 150, 165)

        assert.is_nil(box, "a tap this far from any line should not be resolved to a word")
    end)

    it("still snaps to a line just above the tap", function()
        local pixels = blankPixels(native_w, native_h)
        fillInk(pixels, 100, 100, 250, 125)
        local document = newFakeDocument(native_w, native_h, pixels)

        -- 5 native px below the line: a normal "just missed the glyph" tap.
        local box = WordFinder.findWordBox(document, 1, 150, 130)

        assert.is_not_nil(box, "a near miss should still resolve to the line under it")
        assert.is_true(
            box.y + box.h <= 130,
            "box should be the line above the tap (y+h=" .. tostring(box.y + box.h) .. ")"
        )
    end)
end)

describe("WordFinder.normalizeWord Tesseract output cleanup", function()
    it("strips the trailing newline getTOCRWord returns", function()
        assert.equals("shift", WordFinder.normalizeWord("shift\n"))
    end)

    it("collapses embedded control characters and padding into single spaces", function()
        assert.equals("my shift", WordFinder.normalizeWord("  my\t\nshift  "))
    end)

    it("returns nil for output with nothing left in it", function()
        assert.is_nil(WordFinder.normalizeWord("\n \t"))
        assert.is_nil(WordFinder.normalizeWord(nil))
    end)

    it("leaves a clean word untouched", function()
        assert.equals("dinner", WordFinder.normalizeWord("dinner"))
    end)
end)

describe("WordFinder.isPlausibleWord OCR result validation", function()
    it("accepts ordinary words, including punctuated and accented ones", function()
        assert.is_true(WordFinder.isPlausibleWord("shift"))
        assert.is_true(WordFinder.isPlausibleWord("don't"))
        assert.is_true(WordFinder.isPlausibleWord("dinner?"))
        assert.is_true(WordFinder.isPlausibleWord("a"))
        -- Lua's %a is ASCII-only, so non-ASCII letters must not read as junk.
        assert.is_true(WordFinder.isPlausibleWord("año"))
        assert.is_true(WordFinder.isPlausibleWord("ここ"))
    end)

    it("rejects the punctuation soup Tesseract returns for an unreadable crop", function()
        assert.is_false(WordFinder.isPlausibleWord("|_-"))
        assert.is_false(WordFinder.isPlausibleWord("»«"))
        assert.is_false(WordFinder.isPlausibleWord(""))
        assert.is_false(WordFinder.isPlausibleWord(nil))
    end)

    it("rejects a multi-word result, which means the box straddled a boundary", function()
        assert.is_false(WordFinder.isPlausibleWord("my shift"))
    end)
end)

describe("WordFinder.readWord OCR retry on an unreadable tight box", function()
    local box = { x = 100, y = 100, w = 50, h = 20 }
    local native = { w = 1000, h = 1000 }

    --- A document whose OCR returns `results` in call order, recording the
    --- box each call was given.
    local function newOCRDocument(results)
        local seen = {}
        return {
            file = "book.cbz",
            getOCRWord = function(_, _pageno, wbox)
                table.insert(seen, wbox.sbox)
                return results[#seen]
            end,
        },
            seen
    end

    it("uses the tight box's result when it reads as a word", function()
        local document, seen = newOCRDocument({ "shift\n" })

        assert.equals("shift", WordFinder.readWord(document, 1, box, native))
        assert.equals(1, #seen, "a readable tight box should not pay for a second OCR pass")
    end)

    it("retries with a padded box when the tight crop comes back unreadable", function()
        local document, seen = newOCRDocument({ "|_", "shift\n" })

        assert.equals("shift", WordFinder.readWord(document, 1, box, native))
        assert.equals(2, #seen)
        assert.is_true(seen[2].w > seen[1].w, "retry box should be wider than the tight one")
        assert.is_true(seen[2].h > seen[1].h, "retry box should be taller than the tight one")
    end)

    it("returns nil when neither pass reads as a word, leaving the selection alone", function()
        local document = newOCRDocument({ "|_", "»«" })

        assert.is_nil(WordFinder.readWord(document, 1, box, native))
    end)

    it("keeps the retry box inside the page", function()
        local document, seen = newOCRDocument({ "", "edge" })
        local corner = { x = 0, y = 0, w = 40, h = 20 }

        WordFinder.readWord(document, 1, corner, { w = 30, h = 30 })

        assert.is_true(seen[2].x >= 0 and seen[2].y >= 0, "retry box must not start off-page")
        assert.is_true(seen[2].x + seen[2].w <= 30, "retry box must not extend past the page width")
        assert.is_true(seen[2].y + seen[2].h <= 30, "retry box must not extend past the page height")
    end)
end)

describe("WordFinder.ocrWord tight native OCR path", function()
    local function newNativeDocument()
        local observed = {}
        local context = {
            setZoom = function(_, zoom)
                observed.zoom = zoom
            end,
            getPageDim = function()
                return 120, 30
            end,
            getTOCRWord = function(_, source, x, y, w, h, datadir, lang, mode)
                observed.datadir = datadir
                observed.ocr = { source, x, y, w, h, lang, mode }
                return "GOOD\n"
            end,
            free = function()
                observed.context_freed = true
            end,
        }
        local page = {
            getPagePix = function()
                observed.rendered = true
            end,
            close = function()
                observed.page_closed = true
            end,
        }
        local document = {
            configurable = { doc_language = "eng", background_cleanup = 0 },
            render_mode = 0,
            koptinterface = {
                createContext = function(_, _, _, bbox)
                    observed.bbox = bbox
                    return context
                end,
            },
            _document = {
                openPage = function()
                    return page
                end,
            },
            getOCRWord = function()
                error("the padded document OCR path should not run")
            end,
        }
        return document, observed, context, page
    end

    local box = { x = 10, y = 20, w = 80, h = 20 }

    it("renders the found box without KOReader's added margin and uses single-word mode", function()
        local document, observed = newNativeDocument()
        assert.equals("GOOD", WordFinder.ocrWord(document, 1, box))
        assert.equals(10, observed.bbox.x0)
        assert.equals(90, observed.bbox.x1)
        assert.equals(20, observed.bbox.y0)
        assert.equals(40, observed.bbox.y1)
        assert.equals(1.5, observed.zoom)
        assert.equals(8, observed.ocr[7])
        assert.is_true(observed.rendered and observed.page_closed and observed.context_freed)
    end)
    it("uses a separate English model and a small horizontal margin when enabled", function()
        local document, observed = newNativeDocument()
        assert.equals("GOOD", WordFinder.readWord(document, 1, box, { w = 200, h = 200 }, "eng"))
        assert.equals("eng_fast", observed.ocr[6])
        assert.is_true(observed.datadir:match("/data/ocr$") ~= nil)
        assert.equals(9, observed.bbox.x0)
        assert.equals(91, observed.bbox.x1)
        assert.equals(20, observed.bbox.y0)
        assert.equals(40, observed.bbox.y1)
        assert.equals(1, observed.zoom, "the agreeing second read uses a 20px crop")
        assert.equals(10, box.x, "OCR margin must not move the highlight")
        assert.equals(80, box.w)
    end)

    it("clamps the horizontal OCR margin at both page edges", function()
        local document, observed = newNativeDocument()
        WordFinder.ocrWord(document, 1, { x = 0, y = 5, w = 30, h = 20 }, "eng", { w = 30, h = 30 })
        assert.equals(0, observed.bbox.x0)
        assert.equals(30, observed.bbox.x1)
    end)

    it("uses agreement to correct plausible English errors and preserves ties", function()
        local cases = {
            { reads = { "LOVE!", "Love" }, expected = "LOVE!", calls = 2 },
            { reads = { "Sove", "Love", "LOVE!" }, expected = "Love", calls = 3 },
            { reads = { "Sove", "Love", "Lone" }, expected = "Sove", calls = 3 },
            { reads = { "GOOD", "BAD" }, expected = "GOOD", calls = 1, language = "spa" },
        }
        for _, case in ipairs(cases) do
            local document, _, context = newNativeDocument()
            local calls = 0
            context.getTOCRWord = function()
                calls = calls + 1
                return case.reads[calls]
            end
            assert.equals(case.expected, WordFinder.readWord(document, 1, box, nil, case.language or "eng"))
            assert.equals(case.calls, calls)
        end
    end)

    it("reuses the tie-break crop and frees each context exactly once", function()
        for _, fail_tiebreak in ipairs({ false, true }) do
            local document, _, context, page = newNativeDocument()
            local renders, frees, reads, closes = 0, 0, 0, 0
            page.getPagePix = function()
                renders = renders + 1
            end
            page.close = function()
                closes = closes + 1
            end
            context.free = function()
                frees = frees + 1
            end
            context.getTOCRWord = function()
                reads = reads + 1
                if fail_tiebreak and reads == 3 then
                    error("OCR failure")
                end
                return ({ "Sove", "Love", "LOVE!" })[reads]
            end
            document.getOCRWord = function()
                return "Love"
            end
            assert.equals("Love", WordFinder.readWord(document, 1, box, nil, "eng"))
            assert.equals(3, reads)
            assert.equals(2, renders)
            assert.equals(2, frees)
            assert.equals(2, closes)
        end
    end)

    it("renders the tighter OCR crop without changing the highlight", function()
        local document, observed = newNativeDocument()
        local highlight = { x = 10, y = 20, w = 80, h = 20, ocr_box = { x = 12, y = 22, w = 76, h = 16 } }
        assert.equals("GOOD", WordFinder.readWord(document, 1, highlight))
        assert.equals(12, observed.bbox.x0)
        assert.equals(22, observed.bbox.y0)
        assert.equals(88, observed.bbox.x1)
        assert.equals(38, observed.bbox.y1)
        assert.equals(10, highlight.x)
        assert.equals(80, highlight.w)
    end)

    it("routes Spanish and Italian to their bundled models regardless of document language", function()
        for _, language in ipairs({ "spa", "ita" }) do
            local document, observed = newNativeDocument()
            document.configurable.doc_language = "eng+spa"
            WordFinder.ocrWord(document, 1, box, language)
            assert.equals(language .. "_fast", observed.ocr[6])
            assert.is_true(observed.datadir:match("/data/ocr$") ~= nil)
            assert.equals(10, observed.bbox.x0)
        end
    end)

    it("uses KOReader's configured model when the bundle is disabled", function()
        for _, language in ipairs({ "spa", "jpn", "eng+spa" }) do
            local document, observed = newNativeDocument()
            document.configurable.doc_language = language
            document.koptinterface.tessocr_data = "/reader/tessdata"
            WordFinder.ocrWord(document, 1, box, nil)
            assert.equals(language, observed.ocr[6])
            assert.equals("/reader/tessdata", observed.datadir)
            assert.equals(10, observed.bbox.x0)
        end
    end)

    it("uses installed English when the selected bundled model file is absent", function()
        local document, observed = newNativeDocument()
        local original_open = io.open
        io.open = function()
            return nil
        end
        local ok, result = pcall(WordFinder.ocrWord, document, 1, box, "eng")
        io.open = original_open
        assert.is_true(ok)
        assert.equals("GOOD", result)
        assert.equals("eng", observed.ocr[6])
        assert.equals(10, observed.bbox.x0)
    end)

    it("releases native resources and falls back after rendering or OCR errors", function()
        for _, failure in ipairs({ "render", "ocr", "empty" }) do
            local document, observed, context, page = newNativeDocument()
            if failure == "render" then
                page.getPagePix = function()
                    error("render unavailable")
                end
            elseif failure == "ocr" then
                context.getTOCRWord = function()
                    error("model unavailable")
                end
            else
                context.getTOCRWord = function()
                    return nil
                end
            end
            document.getOCRWord = function()
                return "fallback"
            end
            assert.equals("fallback", WordFinder.ocrWord(document, 1, box, "eng"))
            assert.is_true(observed.page_closed and observed.context_freed)
        end
    end)
end)

describe("WordFinder.cleanup OCR cache purging", function()
    it("does not load OCR libraries merely to close a viewer", function()
        local names = { "ffi/koptcontext", "document/doccache" }
        local saved = {}
        for _, name in ipairs(names) do
            saved[name] = { package.loaded[name], package.preload[name] }
            package.loaded[name] = nil
            package.preload[name] = function()
                error("unexpected library load")
            end
        end
        WordFinder.cleanup()
        for _, name in ipairs(names) do
            assert.is_nil(package.loaded[name])
            package.loaded[name], package.preload[name] = saved[name][1], saved[name][2]
        end
    end)

    it("executes safely without errors", function()
        local ok = pcall(WordFinder.cleanup)
        assert.is_true(ok, "expected WordFinder.cleanup to execute without errors")
    end)
end)

describe("WordFinder.evictOCRWordCache OCR cache-collision workaround", function()
    -- KoptInterface:getNativeOCRWord (koreader/frontend/document/koptinterface.lua)
    -- builds its cache key as "ocrword|"..doc.file.."|"..pageno..rect.x..rect.y..rect.w..rect.h,
    -- with no separators between the numeric fields, and Cache:check does a
    -- blind string-key lookup with no value comparison. Two different boxes
    -- can hash to the identical string (e.g. pageno=1,x=17,y=0.5 and
    -- pageno=1,x=1,y=70.5 both produce "1170.54..."), silently returning a
    -- stale, unrelated word instead of erroring. This is the bug behind the
    -- real repro: highlighting was correct on every tap, but OCR text came
    -- back wrong depending on exactly where in the same word you tapped
    -- (the render crop re-centres per tap, so even the same word's box can
    -- shift by a fraction of a pixel between two taps on it).
    it("deletes the exact key KoptInterface:getNativeOCRWord would use for this box", function()
        package.loaded["document/doccache"] = nil
        local deleted_keys = {}
        package.preload["document/doccache"] = function()
            return {
                cache = {
                    delete = function(_, key)
                        table.insert(deleted_keys, key)
                    end,
                },
            }
        end

        local document = { file = "book.cbz" }
        local box = { x = 17, y = 0.5, w = 41, h = 12 }
        WordFinder.evictOCRWordCache(document, 1, box)

        local expected_hash = "ocrword|" .. "book.cbz" .. "|" .. 1 .. 17 .. 0.5 .. 41 .. 12
        assert.is_true(#deleted_keys == 1, "expected exactly one cache delete call, got " .. #deleted_keys)
        assert.is_true(
            deleted_keys[1] == expected_hash,
            "deleted key should match KoptInterface's own hash exactly (got '"
                .. tostring(deleted_keys[1])
                .. "', want '"
                .. expected_hash
                .. "')"
        )
    end)

    it("executes safely without errors when document/doccache is unavailable", function()
        package.loaded["document/doccache"] = nil
        package.preload["document/doccache"] = nil
        local ok = pcall(WordFinder.evictOCRWordCache, { file = "book.cbz" }, 1, { x = 0, y = 0, w = 10, h = 10 })
        assert.is_true(ok, "expected evictOCRWordCache to execute without errors")
    end)
end)

describe("WordFinder memory headroom", function()
    it("skips crop allocation under memory pressure", function()
        local Memory = require("src._memory")
        local old = Memory.freeBytes
        Memory.freeBytes = function()
            return 40 * 1024 * 1024
        end
        local document = newFakeDocument(1264, 1680, {})
        local rendered = false
        document.renderPage = function()
            rendered = true
        end
        local ok, box = pcall(WordFinder.findWordBox, document, 1, 600, 800)
        Memory.freeBytes = old
        assert.is_true(ok)
        assert.is_nil(box)
        assert.is_false(rendered)
    end)
end)

describe("WordFinder grayscale ownership", function()
    it("frees a failed conversion and samples the transformed source through its API", function()
        local BB = require("ffi/blitbuffer")
        local ffi = require("ffi")
        local old_new, old_cast = BB.new, ffi.cast
        local freed, sampled, cast = 0, 0, false
        BB.new = function()
            return {
                blitFrom = function()
                    error("conversion failed")
                end,
                free = function()
                    freed = freed + 1
                end,
            }
        end
        ffi.cast = function()
            cast = true
            return nil
        end
        local document = newFakeDocument(200, 200, {})
        document.renderPage = function()
            return {
                bb = {
                    w = 120,
                    h = 80,
                    getType = function()
                        return BB.TYPE_BB8
                    end,
                    getRotation = function()
                        return 1
                    end,
                    getInverse = function()
                        return 0
                    end,
                    getPixel = function()
                        sampled = sampled + 1
                        return {
                            getColor8 = function()
                                return { a = 255 }
                            end,
                        }
                    end,
                },
            }
        end
        local ok = pcall(WordFinder.findWordBox, document, 1, 100, 100)
        BB.new, ffi.cast = old_new, old_cast
        assert.is_true(ok)
        assert.equals(1, freed)
        assert.is_true(sampled > 0)
        assert.is_false(cast)
    end)
end)
