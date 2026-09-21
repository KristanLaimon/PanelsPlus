--[[
Panels+
File: tests/spec/reading_page_fold_spec.lua
Name: Reading page fold join specs
Description: Verifies that the fold strip of a double-page spread is removed from the page tile the reader draws.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src/reading_page_fold.lua`.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local ReadingPageFold = require("src.reading_page_fold")
local Settings = require("src._settings")

local SPREAD_PAGE = { w = 1692, h = 1200 }
local PORTRAIT_PAGE = { w = 1050, h = 1522 }

--- Fake tile bitmap, 1000x700, with a black strip at columns 490..510.
local function spreadBitmap()
    local bb = { blits = 0 }
    function bb.getWidth()
        return 1000
    end
    function bb.getHeight()
        return 700
    end
    function bb.getType()
        return 1
    end
    function bb.getPixel(_, x)
        local value = (x >= 490 and x <= 510) and 5 or 240
        return {
            getColor8 = function()
                return { a = value }
            end,
        }
    end
    function bb.blitFrom(self)
        self.blits = self.blits + 1
    end
    return bb
end

--- Plugin stub and a document whose `drawPage` and `renderPage` are recorded.
local function readerFor(page_size, settings, tile)
    tile = tile or { bb = spreadBitmap(), excerpt = { x = 0, y = 0, w = 1000, h = 700 } }
    local calls = { draw = 0, render = 0 }
    local document = {
        getNativePageDimensions = function()
            return page_size
        end,
        renderPage = function()
            calls.render = calls.render + 1
            return tile
        end,
        drawPage = function()
            calls.draw = calls.draw + 1
            -- KOReader's own draw fetches the cached tile again and blits from its bitmap.
            calls.bb_during_draw = tile.bb
        end,
    }
    local reader = setmetatable({
        settings = Settings.withDefaults(settings or {}),
        ui = { paging = {}, document = document },
        isEnabled = function()
            return true
        end,
    }, { __index = ReadingPageFold })
    return reader, document, tile, calls
end

local function draw(document)
    local target = { blits = 0 }

    function target:blitFrom(source)
        self.blits = self.blits + 1
        self.source = source
    end

    function target:ditherblitFrom(source)
        self.blits = self.blits + 1
        self.source = source
    end

    document:drawPage(target, 0, 0, { x = 0, y = 0, w = 1000, h = 700 }, 4, 0.59, 0, 1.0, 1.0)
    return target
end

describe("ReadingPageFold", function()
    it("lets KOReader draw the page, from a joined bitmap, without changing the cached tile", function()
        -- KOReader's draw path also inverts for night mode and dithers, so it has to stay in charge.
        local reader, document, tile, calls = readerFor(SPREAD_PAGE)
        local tile_bb = tile.bb
        reader:installReadingPageFold()

        draw(document)
        local first_joined = calls.bb_during_draw
        draw(document)

        assert.equals(2, calls.draw)
        assert.is_true(first_joined ~= tile_bb)
        assert.equals(first_joined, calls.bb_during_draw)
        assert.equals(tile_bb, tile.bb)
        assert.equals(0, tile_bb.blits)
        assert.is_nil(tile.pp_fold_checked)
    end)

    it("puts the tile's bitmap back when KOReader's draw raises", function()
        local reader, document, tile = readerFor(SPREAD_PAGE)
        local tile_bb = tile.bb
        document.drawPage = function()
            error("draw failed")
        end
        reader:installReadingPageFold()

        local ok = pcall(draw, document)

        assert.is_false(ok)
        assert.equals(tile_bb, tile.bb)
    end)

    it("keeps at most three joined bitmaps and frees the oldest", function()
        local FoldJoin = require("src._foldjoin")
        local old_join, freed = FoldJoin.joinBitmap, 0
        FoldJoin.joinBitmap = function(bb, opts)
            local joined, fold = old_join(bb, opts)
            if joined then
                joined.free = function()
                    freed = freed + 1
                end
            end
            return joined, fold
        end
        local reader, document = readerFor(SPREAD_PAGE)
        local tiles = {}
        document.renderPage = function(_, pageno)
            tiles[pageno] = tiles[pageno] or { bb = spreadBitmap(), excerpt = { x = 0, y = 0, w = 1000, h = 700 } }
            return tiles[pageno]
        end
        reader:installReadingPageFold()

        for pageno = 1, 5 do
            document:drawPage({}, 0, 0, { x = 0, y = 0, w = 1000, h = 700 }, pageno, 0.59, 0, 1.0, 1.0)
        end

        FoldJoin.joinBitmap = old_join
        assert.equals(2, freed)
    end)

    it("leaves a normal page alone without rendering anything itself", function()
        local reader, document, tile, calls = readerFor(PORTRAIT_PAGE)
        reader:installReadingPageFold()

        draw(document)

        assert.equals(0, tile.bb.blits)
        assert.equals(0, calls.render)
        assert.equals(1, calls.draw)
    end)

    it("does nothing while the option is off", function()
        local reader, document, tile = readerFor(SPREAD_PAGE, { join_spread_fold = false })
        reader:installReadingPageFold()

        draw(document)

        assert.equals(0, tile.bb.blits)
    end)

    it("still removes the strip while panel focusing is disabled", function()
        local reader, document, tile, calls = readerFor(SPREAD_PAGE)
        reader.isEnabled = function()
            return false
        end
        reader:installReadingPageFold()

        draw(document)

        assert.equals(1, calls.draw)
        assert.is_true(calls.bb_during_draw ~= tile.bb)
    end)

    it("leaves a tile that covers only part of the page alone", function()
        local partial = { bb = spreadBitmap(), excerpt = { x = 300, y = 0, w = 1000, h = 700 } }
        local reader, document, tile = readerFor(SPREAD_PAGE, nil, partial)
        reader:installReadingPageFold()

        draw(document)

        assert.equals(0, tile.bb.blits)
    end)

    it("leaves a tile narrower than the zoomed page alone", function()
        -- KOReader renders only the visible part when the whole page does not fit its cache.
        local reader, document, tile = readerFor(SPREAD_PAGE)
        reader:installReadingPageFold()

        document:drawPage({}, 0, 0, { x = 0, y = 0, w = 1000, h = 700 }, 4, 1.5, 0, 1.0, 1.0)

        assert.equals(0, tile.bb.blits)
    end)

    it("leaves a rotated document render alone", function()
        local reader, document, tile = readerFor(SPREAD_PAGE)
        reader:installReadingPageFold()

        document:drawPage({}, 0, 0, { x = 0, y = 0, w = 700, h = 1000 }, 4, 0.59, 90, 1.0, 1.0)

        assert.equals(0, tile.bb.blits)
    end)

    it("still draws the page when the tile cannot be processed", function()
        local reader, document, _, calls = readerFor(SPREAD_PAGE)
        document.renderPage = function()
            error("render failed")
        end
        reader:installReadingPageFold()

        draw(document)

        assert.equals(1, calls.draw)
    end)

    it("wraps a document once and restores it on removal", function()
        local reader, document = readerFor(SPREAD_PAGE)
        local original = document.drawPage
        reader:installReadingPageFold()
        local wrapped = document.drawPage
        reader:installReadingPageFold()

        assert.equals(wrapped, document.drawPage)
        reader:removeReadingPageFold()
        assert.equals(original, document.drawPage)
    end)

    it("is not installed for a reflowable document", function()
        local reader, document = readerFor(SPREAD_PAGE)
        local original = document.drawPage
        reader.ui.paging = nil

        reader:installReadingPageFold()

        assert.equals(original, document.drawPage)
    end)
end)
