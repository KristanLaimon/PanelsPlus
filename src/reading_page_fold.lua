--[[
Panels+
File: src/reading_page_fold.lua
Name: ReadingPageFold
Description: Removes the fold strip of a double-page spread from the page tile KOReader draws on the reading page.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local FoldJoin = require("src._foldjoin")
local Timing = require("src._timing")
local logger = require("logger")

--- Fold strip removal on the reading page.
---
--- KOReader draws a page from a cached tile (`document:renderPage`, then a blit in
--- `document:drawPage`). This wraps the open document's `drawPage`: before a spread is drawn, the
--- tile it will be drawn from is looked up, and `FoldJoin.joinBitmap` is applied to it in place.
--- Each tile is processed once. The tile keeps its size, so page layout, zoom and panning are
--- unchanged. Positions right and left of the fold move by at most half the strip's width.
---
--- Only a tile that covers the whole page is processed. When the page is zoomed in so far that
--- KOReader renders it in parts, the strip stays. Renders for the panel viewer are prescaled and
--- never come through `drawPage`. They are handled in `PanelCollector.buildImages`.
---
--- Mixed into the plugin through `include()` in `main.lua`, which calls `installReadingPageFold`
--- from `onReaderReady` and `removeReadingPageFold` from `onCloseWidget`.
---
--- @class PPReadingPageFoldMixin
local ReadingPageFold = {}

--- Native size of `pageno` when it has the shape of a double-page spread, else `nil`.
local function spreadPageSize(document, pageno)
    if not document.getNativePageDimensions then
        return nil
    end
    local ok, size = pcall(document.getNativePageDimensions, document, pageno)
    if ok and DoubleSpread.isSpreadRect(size) then
        return size
    end
    return nil
end

--- Remove the fold strip from the tile `pageno` is about to be drawn from.
---
--- @param document table KOReader document instance.
--- @param render fun(...):table|nil The document's `renderPage`.
--- @param page_size table Native page size.
--- @param pageno integer Page number.
--- @param rect table Region of the zoomed page being drawn.
--- @param zoom number Zoom factor.
--- @param rotation number Document rotation.
--- @param gamma number Gamma.
--- @param saturation number|nil Saturation.
local function joinTile(document, render, page_size, pageno, rect, zoom, rotation, gamma, saturation)
    -- The same call `drawPage` makes, so this is the cached tile it will use.
    local tile = render(document, pageno, rect, zoom, rotation, gamma, saturation)
    if type(tile) ~= "table" or not tile.bb or tile.pp_fold_checked then
        return
    end
    tile.pp_fold_checked = true
    local excerpt = tile.excerpt
    if excerpt and ((excerpt.x or 0) ~= 0 or (excerpt.y or 0) ~= 0) then
        return
    end
    local bb = tile.bb
    -- KOReader renders only part of a page that does not fit its cache. Such a tile can start at
    -- the left edge too, so compare its width with the zoomed page.
    local page_w = page_size.w * zoom
    if math.abs(bb:getWidth() - page_w) > 0.01 * page_w then
        return
    end
    local joined = FoldJoin.joinBitmap(bb)
    if joined then
        bb:blitFrom(joined, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
        if joined.free then
            joined:free()
        end
        Timing.log("reading page fold: strip removed from page %d", pageno)
    end
end

--- Wrap the open document's `drawPage`. Safe to call more than once.
function ReadingPageFold:installReadingPageFold()
    local document = self.ui and self.ui.document
    if not document or not self.ui.paging or document.pp_fold_original_draw_page then
        return
    end
    if type(document.drawPage) ~= "function" or type(document.renderPage) ~= "function" then
        return
    end
    local plugin = self
    local original = document.drawPage
    document.pp_fold_original_draw_page = original
    document.pp_fold_had_own_draw_page = rawget(document, "drawPage") ~= nil
    document.drawPage = function(doc, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
        local page_size = plugin.settings.join_spread_fold ~= false
            and (rotation or 0) == 0
            and not (rect and rect.scaled_rect)
            and spreadPageSize(doc, pageno)
        if page_size then
            local ok, err =
                pcall(joinTile, doc, doc.renderPage, page_size, pageno, rect, zoom, rotation, gamma, saturation)
            if not ok then
                logger.warn("[Panels+] reading page fold:", tostring(err))
            end
        end
        return original(doc, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    end
end

--- Put the document's own `drawPage` back.
function ReadingPageFold:removeReadingPageFold()
    local document = self.ui and self.ui.document
    if not document or not document.pp_fold_original_draw_page then
        return
    end
    if document.pp_fold_had_own_draw_page then
        document.drawPage = document.pp_fold_original_draw_page
    else
        document.drawPage = nil
    end
    document.pp_fold_original_draw_page = nil
    document.pp_fold_had_own_draw_page = nil
end

return ReadingPageFold
