local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document/document")
local Geom = require("ui/geometry")
local ffi = require("ffi")
local logger = require("logger")

--- Comic-lettering-aware replacement for KOReader's native word-box finder.
---
--- KOReader locates a tapped word with a generic gap-detection pass tuned for
--- justified prose (`KoptInterface:getWordFromBoxes`), then OCRs whatever box
--- that pass produced. Stylized/bold comic lettering has irregular, often very
--- tight kerning, so that generic pass routinely finds the wrong gap and OCR
--- then faithfully transcribes the wrong crop -- a box that "looks about
--- right" on screen but contains half a word, two words, or worse.
---
--- This module redoes just the box-finding step, at native document
--- resolution and with thresholds relative to the local line height instead
--- of page-wide heuristics, then hands the resulting tight box to KOReader's
--- own OCR call (`document:getOCRWord`) exactly as it would have used its own
--- box.
---
--- @class PPWordFinder
local WordFinder = {}

-- Crop rendered around the tap point, as a fraction of native page size.
-- Wide enough to comfortably contain a full speech-bubble line either side
-- of the tap, tall enough for a couple of lines above/below it.
local CROP_HALF_W_FRAC = 0.15
local CROP_HALF_H_FRAC = 0.05
-- Rendered at 2x native pixel density so small lettering still resolves
-- enough separate ink columns for gap detection to be meaningful.
local CROP_ZOOM = 2.0
-- Half-extent, in native pixels, of the box background luminance is sampled
-- from around the tap point (see estimateBackground). Real comic panels are
-- art-dense right up to a speech bubble's edge, so a percentile over the
-- *whole* render crop (up to 30% of the page's width) routinely lands on
-- ink/art instead of the bubble's own paper colour, which then poisons every
-- ink/gap decision downstream. Anchoring the sample to a small, tap-centred
-- box instead makes "background" mean the bubble's own fill.
local BG_LOCAL_HALF_W = 30
-- Taller than the width half-extent so the box reliably spans a full text
-- line's height plus surrounding bubble padding even when the tap lands on a
-- bold glyph, without reaching past it into a neighbouring line or bubble.
local BG_LOCAL_HALF_H = 70
-- Luminance delta from the crop's background counted as "ink".
local INK_DELTA = 40
-- Fallback column-gap threshold, as a fraction of the text line's height,
-- used only when the line has too few internal gaps to calibrate one (see
-- MEDIAN_GAP_MULTIPLIER below).
local WORD_GAP_RATIO = 0.5
-- Floor for the calibrated threshold, as a fraction of line height. Guards
-- against a degenerate (near-zero) median gap on very tightly-set text.
-- Set to 0.15 (~5px on a 35px line at 2x zoom) so tight two-word phrases
-- like "my shift" are not over-thresholded and merged into one box.
local MIN_WORD_GAP_RATIO = 0.15
-- Ceiling for the calibrated threshold, as a fraction of line height. A
-- speech bubble's own edge produces one gap (bubble padding) that has
-- nothing to do with inter-word spacing; with only a couple of gaps to
-- median from, that single outlier can dominate and inflate the threshold
-- past the real word boundary. Past the bubble edge is unrelated panel
-- art/screentone, which is uniformly "ink" (darker than the bubble's own
-- background) with no further internal gaps -- so an inflated threshold
-- doesn't just miss the boundary, it sends the hunt straight to the crop
-- edge. Set well above ordinary inter-word spacing so real multi-word gaps
-- still calibrate normally.
local MAX_WORD_GAP_RATIO = 1.5
-- A column gap must be at least this many times the line's own median
-- inter-letter gap to count as a word boundary. Calibrating from the line
-- itself (rather than a fixed fraction of line height) matters for
-- x-height-only words (no ascenders/descenders, e.g. "eater"): their
-- `line_h` is short, so a fixed ratio of it can undercut normal kerning in
-- bold/wide comic fonts and split the word at every letter.
local MEDIAN_GAP_MULTIPLIER = 2.2
-- Consecutive blank rows that end a text line when hunting for its extent.
local LINE_BLANK_RUN = 2
-- Extra padding kept around the found word, as a fraction of its height.
-- Set to 0.05 (~1-2px native padding) so character stems ('h', 'd', 't', 'k')
-- are preserved cleanly without bleeding into adjacent words.
local PAD_RATIO = 0.05

--- @param bb table Rendered blitbuffer.
--- @return table bb Buffer to sample.
--- @return table|nil owned Buffer the caller must free, if one was allocated.
local function toGreyscale(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8
            and bb:getRotation() == 0
            and bb:getInverse() == 0 then
        return bb, nil
    end
    local ok, grey = pcall(function()
        local target = Blitbuffer.new(bb.w, bb.h, Blitbuffer.TYPE_BB8)
        target:blitFrom(bb, 0, 0, 0, 0, bb.w, bb.h)
        return target
    end)
    if ok and grey then
        return grey, grey
    end
    return bb, nil
end

--- @param bb table Buffer to sample.
--- @return fun(x:integer, y:integer):integer sample Luminance accessor.
local function makeSampler(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then
        local ok, data = pcall(ffi.cast, "uint8_t *", bb.data)
        if ok and data ~= nil then
            local stride = tonumber(bb.stride)
            return function(x, y)
                return data[y * stride + x]
            end
        end
    end
    return function(x, y)
        return bb:getPixel(x, y):getColor8().a
    end
end

--- Estimate background luminance and polarity from a bounded box, rather
--- than the whole render crop -- see BG_LOCAL_HALF_W/H above for why.
--- @param x0 integer Sample box left bound (inclusive).
--- @param x1 integer Sample box right bound (inclusive).
--- @param y0 integer Sample box top bound (inclusive).
--- @param y1 integer Sample box bottom bound (inclusive).
local function estimateBackground(sample, x0, x1, y0, y1)
    local histogram = {}
    for value = 0, 255 do
        histogram[value] = 0
    end
    local total = 0
    local box_w = x1 - x0 + 1
    local box_h = y1 - y0 + 1
    local step = math.max(1, math.floor(math.min(box_w, box_h) / 32))
    for y = y0, y1, step do
        for x = x0, x1, step do
            local value = sample(x, y)
            histogram[value] = histogram[value] + 1
            total = total + 1
        end
    end
    if total == 0 then
        return 255, false
    end

    local target = total * 0.75
    local seen, bg = 0, 255
    for value = 0, 255 do
        seen = seen + histogram[value]
        if seen >= target then
            bg = value
            break
        end
    end

    local is_inverted = bg < 128
    return bg, is_inverted
end

local function isInk(sample, x, y, background, is_inverted)
    local val = sample(x, y)
    if is_inverted then
        return (val - background) > INK_DELTA
    else
        return (background - val) > INK_DELTA
    end
end

--- Appends a diagnostic log entry to `./panels_wordfinder.log` and `/tmp/panels_wordfinder.log`.
--- @param msg string Main log message.
--- @param details table|nil Key-value details to format.
function WordFinder.logDiagnostic(msg, details)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] [Panels+ WordFinder] %s", timestamp, msg)
    if details then
        local parts = {}
        for k, v in pairs(details) do
            table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
        end
        table.sort(parts)
        line = line .. " | " .. table.concat(parts, ", ")
    end
    logger.info(line)
    for _, path in ipairs({ "./panels_wordfinder.log", "/tmp/panels_wordfinder.log" }) do
        local f = io.open(path, "a")
        if f then
            f:write(line .. "\n")
            f:close()
        end
    end
end

--- Save a greyscale crop tile as a binary PGM (P5) image with an optional box outline.
local function savePGM(filename, sample, w, h, x0, x1, y0, y1)
    pcall(function()
        local f = io.open(filename, "wb")
        if not f then return end
        f:write(string.format("P5\n%d %d\n255\n", w, h))
        local buf = {}
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local val = sample(x, y)
                if x0 and x1 and y0 and y1 then
                    if (y == y0 or y == y1) and (x >= x0 and x <= x1) then
                        val = 0
                    elseif (x == x0 or x == x1) and (y >= y0 and y <= y1) then
                        val = 0
                    end
                end
                table.insert(buf, string.char(val))
            end
        end
        f:write(table.concat(buf))
        f:close()
    end)
end

--- Purge any cached OCREngine instances in DocCache to release Tesseract C++ DAWGs
--- and prevent memory leak warnings on KOReader shutdown.
function WordFinder.cleanup()
    local ok_cache, DocCache = pcall(require, "document/doccache")
    if ok_cache and DocCache and DocCache.cache then
        pcall(function()
            if DocCache.cache.delete then
                DocCache.cache:delete("ocrengine")
            end
        end)
    end
end

--- Evict KOReader's own OCR-word cache entry for this exact box, before the
--- caller passes it to `document:getOCRWord()`.
---
--- `KoptInterface:getNativeOCRWord` builds its cache key by concatenating
--- pageno/rect.x/rect.y/rect.w/rect.h with no separators between them, so
--- two different boxes can hash to the identical string (e.g. pageno=1,
--- x=17,y=0.5 and pageno=1,x=1,y=70.5 both produce "1170.54..."). Its cache
--- lookup (`Cache:check`) is a blind string-key match with no value
--- comparison, so a collision silently returns a stale, unrelated word
--- instead of erroring or missing. This is called on every hold-word tap
--- with a wide variety of box values -- the render crop is re-centred per
--- tap, so even the same word's box can shift by a fraction of a pixel
--- between two taps on it -- which makes collisions with earlier session
--- activity a real, observed failure, not just a theoretical one. Evicting
--- our own upcoming key first guarantees a fresh, correct OCR read instead
--- of risking someone else's cached result.
---
--- @param document table KOReader document object.
--- @param pageno number Page number.
--- @param box table Box about to be passed as `{sbox = box}` to `getOCRWord`.
function WordFinder.evictOCRWordCache(document, pageno, box)
    local ok_cache, DocCache = pcall(require, "document/doccache")
    if not (ok_cache and DocCache and DocCache.cache and DocCache.cache.delete) then
        return
    end
    local ok_hash, hash = pcall(function()
        return "ocrword|" .. document.file .. "|" .. pageno .. box.x .. box.y .. box.w .. box.h
    end)
    if ok_hash and hash then
        pcall(function() DocCache.cache:delete(hash) end)
    end
end

--- Find the tight word box under a native-page-space point.
---
--- @param document table KOReader document object (paging backend).
--- @param pageno number Page number.
--- @param px number Native page x coordinate.
--- @param py number Native page y coordinate.
--- @return PPRect|nil box Tight word box in native page coordinates, or nil.
function WordFinder.findWordBox(document, pageno, px, py)
    if not (document and pageno and px and py) then
        return nil
    end

    local native = Document.getNativePageDimensions(document, pageno)
    if not native or not native.w or not native.h or native.w <= 0 or native.h <= 0 then
        return nil
    end

    local half_w = math.max(40, native.w * CROP_HALF_W_FRAC)
    local half_h = math.max(20, native.h * CROP_HALF_H_FRAC)

    local cx0 = math.max(0, px - half_w)
    local cy0 = math.max(0, py - half_h)
    local cx1 = math.min(native.w, px + half_w)
    local cy1 = math.min(native.h, py + half_h)
    local crop_w = cx1 - cx0
    local crop_h = cy1 - cy0
    if crop_w < 4 or crop_h < 4 then
        return nil
    end

    local rect = Geom:new{ x = cx0, y = cy0, w = crop_w, h = crop_h }
    rect.scaled_rect = document:transformRect(rect, CROP_ZOOM, 0)

    local tile
    local ok, err = pcall(function()
        tile = document:renderPage(pageno, rect, CROP_ZOOM, 0, 1.0, 1.0, false)
    end)
    if not ok or not tile or not tile.bb then
        logger.dbg("[Panels+] word finder render failed:", err)
        return nil
    end

    local work, owned = toGreyscale(tile.bb)
    local w, h = work.w, work.h
    if not w or not h or w < 4 or h < 4 then
        if owned then pcall(owned.free, owned) end
        return nil
    end
    local sample = makeSampler(work)

    local tap_x = math.max(0, math.min(w - 1, math.floor((px - cx0) * CROP_ZOOM)))
    local tap_y = math.max(0, math.min(h - 1, math.floor((py - cy0) * CROP_ZOOM)))

    local local_band_w = math.floor(BG_LOCAL_HALF_W * CROP_ZOOM)
    local lx0 = math.max(0, tap_x - local_band_w)
    local lx1 = math.min(w - 1, tap_x + local_band_w)

    local local_band_h = math.floor(BG_LOCAL_HALF_H * CROP_ZOOM)
    local bg_y0 = math.max(0, tap_y - local_band_h)
    local bg_y1 = math.min(h - 1, tap_y + local_band_h)

    local background, is_inverted = estimateBackground(sample, lx0, lx1, bg_y0, bg_y1)

    local row_ink = {}
    for y = 0, h - 1 do
        local count = 0
        for x = lx0, lx1 do
            if isInk(sample, x, y, background, is_inverted) then
                count = count + 1
            end
        end
        row_ink[y] = count
    end

    if row_ink[tap_y] == 0 then
        local best, best_dist
        for y = 0, h - 1 do
            if row_ink[y] > 0 then
                local dist = math.abs(y - tap_y)
                if not best_dist or dist < best_dist then
                    best, best_dist = y, dist
                end
            end
        end
        if not best then
            if owned then pcall(owned.free, owned) end
            return nil
        end
        tap_y = best
    end

    -- Expand the tap row into its full text line, tolerating a couple of
    -- blank rows (crossbars, gaps inside glyphs) but stopping at a real gap
    -- between lines. Max single-line height capped at ~70px (at 2x zoom).
    local max_half_h = math.floor(35 * CROP_ZOOM)
    local min_y_bound = math.max(0, tap_y - max_half_h)
    local max_y_bound = math.min(h - 1, tap_y + max_half_h)

    local y0, y1, blank = tap_y, tap_y, 0
    while y0 > min_y_bound do
        if row_ink[y0 - 1] == 0 then
            blank = blank + 1
            if blank >= LINE_BLANK_RUN then break end
        else
            blank = 0
        end
        y0 = y0 - 1
    end
    while y0 < tap_y and row_ink[y0] == 0 do y0 = y0 + 1 end
    blank = 0
    while y1 < max_y_bound do
        if row_ink[y1 + 1] == 0 then
            blank = blank + 1
            if blank >= LINE_BLANK_RUN then break end
        else
            blank = 0
        end
        y1 = y1 + 1
    end
    while y1 > tap_y and row_ink[y1] == 0 do y1 = y1 - 1 end

    local line_h = y1 - y0 + 1

    -- Column ink projection restricted to this text line only.
    local col_ink = {}
    for x = 0, w - 1 do
        local count = 0
        for y = y0, y1 do
            if isInk(sample, x, y, background, is_inverted) then
                count = count + 1
            end
        end
        col_ink[x] = count
    end

    if col_ink[tap_x] == 0 then
        local best, best_dist
        for x = 0, w - 1 do
            if col_ink[x] > 0 then
                local dist = math.abs(x - tap_x)
                if not best_dist or dist < best_dist then
                    best, best_dist = x, dist
                end
            end
        end
        if not best then
            if owned then pcall(owned.free, owned) end
            return nil
        end
        tap_x = best
    end

    -- Calibrate the word-gap threshold from this line's own letter spacing:
    -- collect every internal gap between ink runs across the whole line
    -- (not just around the tap), and require a real word boundary to be a
    -- clear outlier above the median of those (mostly inter-letter) gaps.
    local gaps = {}
    do
        local in_gap, gap_start, seen_ink = false, nil, false
        for x = 0, w - 1 do
            if col_ink[x] > 0 then
                if in_gap and seen_ink then
                    table.insert(gaps, x - gap_start)
                end
                in_gap = false
                seen_ink = true
            elseif seen_ink and not in_gap then
                in_gap = true
                gap_start = x
            end
        end
    end

    local gap_threshold
    if #gaps >= 2 then
        table.sort(gaps)
        local mid = math.floor(#gaps / 2)
        local median_gap = (#gaps % 2 == 1) and gaps[mid + 1] or (gaps[mid] + gaps[mid + 1]) / 2
        gap_threshold = math.max(
            math.floor(line_h * MIN_WORD_GAP_RATIO),
            math.floor(median_gap * MEDIAN_GAP_MULTIPLIER))
        gap_threshold = math.min(gap_threshold, math.ceil(line_h * MAX_WORD_GAP_RATIO))
    else
        gap_threshold = math.floor(line_h * WORD_GAP_RATIO)
    end
    gap_threshold = math.max(2, gap_threshold)

    local x0, x1, gap = tap_x, tap_x, 0
    while x0 > 0 do
        if col_ink[x0 - 1] == 0 then
            gap = gap + 1
            if gap >= gap_threshold then break end
        else
            gap = 0
        end
        x0 = x0 - 1
    end
    while x0 < tap_x and col_ink[x0] == 0 do x0 = x0 + 1 end
    gap = 0
    while x1 < w - 1 do
        if col_ink[x1 + 1] == 0 then
            gap = gap + 1
            if gap >= gap_threshold then break end
        else
            gap = 0
        end
        x1 = x1 + 1
    end
    while x1 > tap_x and col_ink[x1] == 0 do x1 = x1 - 1 end

    -- Retighten the vertical extent to this word's own ink, dropping any
    -- overflow from taller/shorter line-mates outside its column range.
    local ty0, ty1 = y0, y1
    while ty0 < y1 do
        local has_ink = false
        for x = x0, x1 do
            if isInk(sample, x, ty0, background, is_inverted) then
                has_ink = true
                break
            end
        end
        if has_ink then break end
        ty0 = ty0 + 1
    end
    while ty1 > ty0 do
        local has_ink = false
        for x = x0, x1 do
            if isInk(sample, x, ty1, background, is_inverted) then
                has_ink = true
                break
            end
        end
        if has_ink then break end
        ty1 = ty1 - 1
    end

    for _, dir in ipairs({ ".", "/tmp" }) do
        savePGM(dir .. "/wordfinder_crop.pgm", sample, w, h)
        savePGM(dir .. "/wordfinder_crop_box.pgm", sample, w, h, x0, x1, ty0, ty1)
    end

    if owned then pcall(owned.free, owned) end

    local word_h = ty1 - ty0 + 1
    local pad_x = math.max(0, math.floor(word_h * PAD_RATIO * 0.5))
    local pad_y = math.max(0, math.floor(word_h * PAD_RATIO))

    local px0 = math.max(0, x0 - pad_x)
    local px1 = math.min(w - 1, x1 + pad_x)
    local py0 = math.max(0, ty0 - pad_y)
    local py1 = math.min(h - 1, ty1 + pad_y)

    local map_start = math.max(0, x0 - 15)
    local map_end = math.min(w - 1, x1 + 15)
    local map_chars = {}
    for x = map_start, map_end do
        if x >= x0 and x <= x1 then
            table.insert(map_chars, col_ink[x] > 0 and "#" or ".")
        else
            table.insert(map_chars, col_ink[x] > 0 and "|" or " ")
        end
    end

    local box_res = {
        x = cx0 + px0 / CROP_ZOOM,
        y = cy0 + py0 / CROP_ZOOM,
        w = (px1 - px0 + 1) / CROP_ZOOM,
        h = (py1 - py0 + 1) / CROP_ZOOM,
    }

    local gap_str = "[" .. table.concat(gaps, ",") .. "]"
    WordFinder.logDiagnostic(string.format("findWordBox tap=(%.1f,%.1f) pg=%s -> box=(x=%.1f,y=%.1f,w=%.1f,h=%.1f)", px, py, tostring(pageno), box_res.x, box_res.y, box_res.w, box_res.h), {
        bg = background,
        inv = is_inverted,
        bg_box = string.format("(%d,%d)-(%d,%d)", lx0, bg_y0, lx1, bg_y1),
        line_h = line_h,
        gap_thresh = gap_threshold,
        all_gaps = gap_str,
        col_map = table.concat(map_chars),
    })

    return box_res
end

return WordFinder
