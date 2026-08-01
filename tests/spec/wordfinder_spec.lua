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
local function newFakeDocument(native_w, native_h, pixels, zoom)
    return {
        getNativePageDimensions = function() return { w = native_w, h = native_h } end,
        transformRect = function(_, rect, z)
            return { w = math.floor(rect.w * z), h = math.floor(rect.h * z) }
        end,
        renderPage = function(_, _pageno, rect, z)
            local crop_w, crop_h = rect.scaled_rect.w, rect.scaled_rect.h
            local cx0, cy0 = rect.x, rect.y
            local bb = {
                w = crop_w,
                h = crop_h,
                getType = function() return nil end, -- matches the test Blitbuffer mock's nil TYPE_BB8
                getRotation = function() return 0 end,
                getInverse = function() return 0 end,
                getPixel = function(_, x, y)
                    local src_x = cx0 + x / z
                    local src_y = cy0 + y / z
                    local v = (pixels[math.floor(src_y)] or {})[math.floor(src_x)] or 255
                    return { getColor8 = function() return { a = v } end }
                end,
            }
            return { bb = bb }
        end,
    }
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

describe("WordFinder:findWordBox multi-word line isolation (e.g. 'what\'s for dinner?')", function()
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
    local word_my = { 100, 140 }     -- "my"
    local word_shift = { 148, 220 }  -- "shift" (tight gap of 8px)

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
            for x = 0, native_w - 1 do pixels[y][x] = 255 end
        end
        -- Line 1 at y=[50, 75], Line 2 at y=[100, 125], Line 3 at y=[150, 175]
        local lines = { {50, 75}, {100, 125}, {150, 175} }
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
        assert.is_true(box.x >= bubble.x0 - 5, "box should stay inside the bubble, not the surrounding art (x=" .. tostring(box.x) .. ")")
        assert.is_true(box.x + box.w <= bubble.x1 + 5, "box should not spill past the bubble's right edge (x+w=" .. tostring(box.x + box.w) .. ")")
        assert.is_true(box.w < (bubble.x1 - bubble.x0), "box should be word-sized, not swallow the whole bubble/art region (w=" .. tostring(box.w) .. ")")
    end)
end)

describe("WordFinder.cleanup OCR cache purging", function()
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
                    delete = function(_, key) table.insert(deleted_keys, key) end,
                },
            }
        end

        local document = { file = "book.cbz" }
        local box = { x = 17, y = 0.5, w = 41, h = 12 }
        WordFinder.evictOCRWordCache(document, 1, box)

        local expected_hash = "ocrword|" .. "book.cbz" .. "|" .. 1 .. 17 .. 0.5 .. 41 .. 12
        assert.is_true(#deleted_keys == 1, "expected exactly one cache delete call, got " .. #deleted_keys)
        assert.is_true(deleted_keys[1] == expected_hash,
            "deleted key should match KoptInterface's own hash exactly (got '" .. tostring(deleted_keys[1]) .. "', want '" .. expected_hash .. "')")
    end)

    it("executes safely without errors when document/doccache is unavailable", function()
        package.loaded["document/doccache"] = nil
        package.preload["document/doccache"] = nil
        local ok = pcall(WordFinder.evictOCRWordCache, { file = "book.cbz" }, 1, { x = 0, y = 0, w = 10, h = 10 })
        assert.is_true(ok, "expected evictOCRWordCache to execute without errors")
    end)
end)
