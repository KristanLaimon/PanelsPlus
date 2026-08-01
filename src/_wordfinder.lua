local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document/document")
local Geom = require("ui/geometry")
local Timing = require("src._timing")
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
-- Half-width of the window, as a multiple of line height, that inter-letter
-- gaps are calibrated from. The render crop reaches up to 15% of the page
-- width either side of the tap, which on a normal panel is mostly art rather
-- than lettering; ink runs out there contribute "gaps" that have nothing to
-- do with the tapped line's spacing and skew the median that the word-gap
-- threshold is derived from. Six line heights is several words of real
-- context on the tapped line while rarely reaching past the speech bubble.
local GAP_WINDOW_RATIO = 6
-- Consecutive blank rows that end a text line when hunting for its extent.
local LINE_BLANK_RUN = 2
-- Furthest, in multiples of the line height, a tap that landed on blank
-- background is allowed to snap sideways onto ink. Without a bound, the
-- nearest-ink search spans the whole render crop, so a tap in a bubble's
-- margin can silently jump to a word in a *different* bubble -- or onto
-- panel art -- 15% of a page away, and everything downstream then describes
-- the wrong word confidently. Two line heights covers the blank margin
-- around any word the user plausibly meant to hit.
local SNAP_X_RATIO = 2
-- Widest a single word can plausibly be, as a multiple of its line's ink
-- height. Long words in x-height-only lettering (no ascenders/descenders,
-- so a short `line_h`) reach about 11x, so this leaves headroom while still
-- rejecting a box that has clearly run past the word it started from.
local MAX_WORD_WIDTH_RATIO = 14
-- Extra padding kept around the found word, as a fraction of its height.
-- Set to 0.05 (~1-2px native padding) so character stems ('h', 'd', 't', 'k')
-- are preserved cleanly without bleeding into adjacent words.
local PAD_RATIO = 0.05
-- Extra margin, as a fraction of the word box's height, used for the retry
-- OCR pass (see WordFinder.readWord). `KoptInterface:getNativeOCRWord`
-- already pads its own crop by 30% of the box height, but a box tightened to
-- the word's own ink can still clip an anti-aliased stem or an accent, and
-- Tesseract reads a clipped glyph as a different letter -- or drops it,
-- which is what "it found only part of the word" looks like from outside.
local RETRY_PAD_RATIO = 0.25

--- @param value number Value to constrain.
--- @param low number Lower bound (inclusive).
--- @param high number Upper bound (inclusive).
--- @return number clamped
local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

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

--- Appends a diagnostic log entry to the KOReader log, and -- only while
--- `debug_mode` is on -- to `panels_wordfinder.log` next to the running
--- KOReader install and in `/tmp`.
---
--- The file writes are deliberately gated: this runs on *every* long-press,
--- so unconditional appends mean a synchronous open/write/close pair per tap
--- on device flash for output nobody is reading.
---
--- @param msg string Main log message.
--- @param details table|nil Key-value details to format.
function WordFinder.logDiagnostic(msg, details)
    if not Timing.enabled then
        return
    end
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

--- Collapse Tesseract's raw output into a single-line, trimmed string.
---
--- `getTOCRWord` returns the engine's transcription verbatim, which carries a
--- trailing newline and can carry stray control characters. `ReaderDictionary`
--- trims before looking a word up, but everything else the selection feeds --
--- "Copy", "Add note", Wikipedia, the highlight text saved to the annotation
--- list -- takes `selected_text.text` as-is, so the raw string leaks through.
---
--- @param text string|nil Raw OCR output.
--- @return string|nil word Normalized word, or nil if nothing was left.
function WordFinder.normalizeWord(text)
    if type(text) ~= "string" then
        return nil
    end
    -- %c is byte-wise but only ever matches 0x00-0x1F/0x7F, so UTF-8
    -- continuation bytes (>= 0x80) pass through untouched.
    local word = text:gsub("%c", " ")
    word = word:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if word == "" then
        return nil
    end
    return word
end

--- Decode the UTF-8 codepoint starting at `index`, LuaJIT having no `utf8`.
---
--- @param text string Subject string.
--- @param index integer Byte index of a sequence's lead byte.
--- @return integer codepoint
--- @return integer next_index Byte index just past this sequence.
local function decodeUTF8(text, index)
    local lead = text:byte(index)
    local length, codepoint
    if lead < 0x80 then
        return lead, index + 1
    elseif lead >= 0xF0 then
        length, codepoint = 4, lead - 0xF0
    elseif lead >= 0xE0 then
        length, codepoint = 3, lead - 0xE0
    elseif lead >= 0xC0 then
        length, codepoint = 2, lead - 0xC0
    else
        -- Stray continuation byte: not a valid sequence start.
        return -1, index + 1
    end
    if index + length - 1 > #text then
        return -1, #text + 1
    end
    for offset = 1, length - 1 do
        local continuation = text:byte(index + offset)
        if continuation < 0x80 or continuation > 0xBF then
            return -1, index + offset
        end
        codepoint = codepoint * 64 + (continuation - 0x80)
    end
    return codepoint, index + length
end

--- Whether a non-ASCII codepoint reads as a letter rather than a symbol.
---
--- Only the ranges Tesseract actually emits as noise are excluded, so
--- accented Latin, Greek, Cyrillic and CJK all still count as letters --
--- Lua's `%a` class is ASCII-only and would reject every one of them.
---
--- @param codepoint integer
--- @return boolean is_letter
local function isLetterCodepoint(codepoint)
    if codepoint < 0x00C0 then
        -- C1 controls plus the Latin-1 punctuation and symbol block: the
        -- guillemets, inverted marks, degree/pilcrow/middot signs that an
        -- unreadable crop comes back as.
        return false
    end
    if codepoint == 0x00D7 or codepoint == 0x00F7 then
        return false -- multiplication and division signs
    end
    if codepoint >= 0x2000 and codepoint <= 0x206F then
        return false -- general punctuation (dashes, quotes, bullets, primes)
    end
    if codepoint >= 0x2190 and codepoint <= 0x2BFF then
        return false -- arrows, mathematical operators, box drawing, misc symbols
    end
    if codepoint >= 0x3000 and codepoint <= 0x303F then
        return false -- CJK symbols and punctuation
    end
    return true
end

--- Whether an OCR result is worth overwriting KOReader's own selection with.
---
--- Tesseract given a crop it cannot read does not fail -- it returns
--- confident-looking punctuation soup ("|_-", "»«") or a fragment. Taking
--- that over the document's own word makes the feature actively worse than
--- not running, so a result has to look like a word before it is accepted:
--- at least one letter, no more junk characters than letters, and a single
--- token (whitespace means the box straddled a word boundary, and a phrase
--- never resolves in a dictionary).
---
--- @param text string|nil Normalized OCR word.
--- @return boolean plausible
function WordFinder.isPlausibleWord(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    if text:find("%s") then
        return false
    end
    local letters, junk = 0, 0
    local index = 1
    while index <= #text do
        local codepoint, next_index = decodeUTF8(text, index)
        index = next_index
        if codepoint < 0 then
            junk = junk + 1
        elseif codepoint < 0x80 then
            local char = string.char(codepoint)
            if char:match("%a") then
                letters = letters + 1
            elseif not char:match("[%d'%-%.,!%?]") then
                junk = junk + 1
            end
        elseif isLetterCodepoint(codepoint) then
            letters = letters + 1
        else
            junk = junk + 1
        end
    end
    return letters > 0 and junk <= letters
end

--- Grow a word box outwards by a fraction of its height, clamped to the page.
---
--- @param box PPRect Word box in native page coordinates.
--- @param ratio number Margin to add on each side, as a fraction of `box.h`.
--- @param native PPPageSize|nil Native page dimensions to clamp against.
--- @return PPRect padded
function WordFinder.padBox(box, ratio, native)
    local margin = math.max(1, box.h * ratio)
    local x0 = box.x - margin
    local y0 = box.y - margin
    local x1 = box.x + box.w + margin
    local y1 = box.y + box.h + margin
    if native and native.w and native.h then
        x0 = clamp(x0, 0, native.w)
        y0 = clamp(y0, 0, native.h)
        x1 = clamp(x1, 0, native.w)
        y1 = clamp(y1, 0, native.h)
    else
        x0 = math.max(0, x0)
        y0 = math.max(0, y0)
    end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

--- OCR a single box through KOReader's own engine and normalize the result.
---
--- @param document table KOReader document object.
--- @param pageno number Page number.
--- @param box PPRect Box in native page coordinates.
--- @return string|nil word Normalized word, or nil if OCR produced nothing.
function WordFinder.ocrWord(document, pageno, box)
    WordFinder.evictOCRWordCache(document, pageno, box)
    local ok, raw = pcall(document.getOCRWord, document, pageno, { sbox = box })
    if not ok then
        return nil
    end
    return WordFinder.normalizeWord(raw)
end

--- Read the word inside a found box, retrying once with a looser crop.
---
--- The first pass uses the tight box, which is what makes OCR resolution
--- usable at all: `getNativeOCRWord` scales whatever box it is handed so its
--- *height* renders at 30px, so every pixel of slack above or below the
--- glyphs is resolution taken away from them. When that tight crop comes back
--- unreadable, the usual cause is the opposite problem -- a clipped stem or
--- accent -- so the retry trades some of that resolution back for margin
--- rather than giving up and leaving KOReader's own (usually wrong) word in
--- place.
---
--- @param document table KOReader document object.
--- @param pageno number Page number.
--- @param box PPRect Tight word box in native page coordinates.
--- @param native PPPageSize|nil Native page dimensions, to clamp the retry box.
--- @return string|nil word Plausible OCR word, or nil.
function WordFinder.readWord(document, pageno, box, native)
    local word = WordFinder.ocrWord(document, pageno, box)
    if WordFinder.isPlausibleWord(word) then
        return word
    end

    local retry_box = WordFinder.padBox(box, RETRY_PAD_RATIO, native)
    local retry_word = WordFinder.ocrWord(document, pageno, retry_box)
    WordFinder.logDiagnostic("retry OCR with padded box", {
        first = tostring(word),
        retry = tostring(retry_word),
        box = string.format("(x=%.1f,y=%.1f,w=%.1f,h=%.1f)", retry_box.x, retry_box.y, retry_box.w, retry_box.h),
    })
    if WordFinder.isPlausibleWord(retry_word) then
        return retry_word
    end
    return nil
end

--- Find the nearest row/column index carrying ink, within a bounded distance.
---
--- @param counts table Ink counts indexed by row or column.
--- @param origin integer Index to search out from.
--- @param limit integer Furthest distance to search, in either direction.
--- @param low integer Lowest valid index.
--- @param high integer Highest valid index.
--- @return integer|nil index Nearest index with ink, or nil if none is close enough.
local function nearestInk(counts, origin, limit, low, high)
    if (counts[origin] or 0) > 0 then
        return origin
    end
    for distance = 1, limit do
        local before = origin - distance
        if before >= low and (counts[before] or 0) > 0 then
            return before
        end
        local after = origin + distance
        if after <= high and (counts[after] or 0) > 0 then
            return after
        end
    end
    return nil
end

--- Grow a seed row outwards over a set of columns, stopping at a real gap.
---
--- @param has_ink table Row -> boolean ink presence over the columns of interest.
--- @param seed integer Row to grow from.
--- @param low integer Lowest row the extent may reach.
--- @param high integer Highest row the extent may reach.
--- @return integer top
--- @return integer bottom
local function growRowExtent(has_ink, seed, low, high)
    local top, blank = seed, 0
    while top > low do
        if not has_ink[top - 1] then
            blank = blank + 1
            if blank >= LINE_BLANK_RUN then break end
        else
            blank = 0
        end
        top = top - 1
    end
    while top < seed and not has_ink[top] do top = top + 1 end

    local bottom = seed
    blank = 0
    while bottom < high do
        if not has_ink[bottom + 1] then
            blank = blank + 1
            if blank >= LINE_BLANK_RUN then break end
        else
            blank = 0
        end
        bottom = bottom + 1
    end
    while bottom > seed and not has_ink[bottom] do bottom = bottom - 1 end

    return top, bottom
end

--- Find the tight word box under a native-page-space point.
---
--- @param document table KOReader document object (paging backend).
--- @param pageno number Page number.
--- @param px number Native page x coordinate.
--- @param py number Native page y coordinate.
--- @return PPRect|nil box Tight word box in native page coordinates, or nil.
--- @return PPPageSize|nil native Native page dimensions, when a box was found.
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

    -- The tile covers the crop starting at `scaled_rect`'s *integer* origin,
    -- not at `cx0 * CROP_ZOOM`: `Geom:transformByScale` floors x/y, and
    -- `Document:renderPage` draws the page offset by exactly those floored
    -- values. Deriving tile coordinates from `cx0` directly (and mapping the
    -- result back the same way) leaves the reported box shifted from the
    -- pixels that were actually measured, so anchor both directions to the
    -- origin the renderer used. `transformRect` always sets x/y; the fallback
    -- reproduces its rounding for stand-ins that only return a size.
    local scaled = rect.scaled_rect
    local origin_x = (scaled and scaled.x) or math.floor(cx0 * CROP_ZOOM + 0.001)
    local origin_y = (scaled and scaled.y) or math.floor(cy0 * CROP_ZOOM + 0.001)

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

    --- Release the greyscale copy, if one was allocated, and return nil.
    local function abort(reason)
        if owned then pcall(owned.free, owned) end
        WordFinder.logDiagnostic("findWordBox gave up, falling back to KOReader's own box", {
            reason = reason,
            tap = string.format("(%.1f,%.1f)", px, py),
        })
        return nil
    end

    local tap_x = clamp(math.floor(px * CROP_ZOOM) - origin_x, 0, w - 1)
    local tap_y = clamp(math.floor(py * CROP_ZOOM) - origin_y, 0, h - 1)

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

    -- A tap that landed between lines may snap onto the line above or below,
    -- but never further than one maximum line height away -- past that it is
    -- a different line, a different bubble, or panel art.
    local max_half_h = math.floor(35 * CROP_ZOOM)
    local snapped_y = nearestInk(row_ink, tap_y, max_half_h, 0, h - 1)
    if not snapped_y then
        return abort("no ink near the tap row")
    end
    tap_y = snapped_y

    -- Expand the tap row into its full text line, tolerating a couple of
    -- blank rows (crossbars, gaps inside glyphs) but stopping at a real gap
    -- between lines. Max single-line height capped at ~70px (at 2x zoom).
    local min_y_bound = math.max(0, tap_y - max_half_h)
    local max_y_bound = math.min(h - 1, tap_y + max_half_h)

    local band_has_ink = {}
    for y = min_y_bound, max_y_bound do
        band_has_ink[y] = row_ink[y] > 0
    end
    local y0, y1 = growRowExtent(band_has_ink, tap_y, min_y_bound, max_y_bound)

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

    local snapped_x = nearestInk(col_ink, tap_x, math.max(4, math.floor(line_h * SNAP_X_RATIO)), 0, w - 1)
    if not snapped_x then
        return abort("no ink near the tap column")
    end
    tap_x = snapped_x

    -- Calibrate the word-gap threshold from this line's own letter spacing:
    -- collect every internal gap between ink runs across a window of the line
    -- around the tap, and require a real word boundary to be a clear outlier
    -- above the median of those (mostly inter-letter) gaps.
    local gap_window = math.max(line_h, math.floor(line_h * GAP_WINDOW_RATIO))
    local gap_x0 = math.max(0, tap_x - gap_window)
    local gap_x1 = math.min(w - 1, tap_x + gap_window)
    local gaps = {}
    do
        local in_gap, gap_start, seen_ink = false, nil, false
        for x = gap_x0, gap_x1 do
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

    -- An ink run that reaches the edge of the render crop still going was
    -- never a word: nothing bounded it, so it is screentone, a bubble
    -- border, or panel art the ink test could not tell from lettering. The
    -- box would be arbitrary and OCR would transcribe the arbitrariness, so
    -- hand the tap back to KOReader instead of inventing an answer.
    if col_ink[0] > 0 and x0 <= 0 then
        return abort("ink runs off the left edge of the crop")
    end
    if col_ink[w - 1] > 0 and x1 >= w - 1 then
        return abort("ink runs off the right edge of the crop")
    end
    if (x1 - x0 + 1) > line_h * MAX_WORD_WIDTH_RATIO then
        return abort(string.format("box too wide for one word (%dpx over a %dpx line)", x1 - x0 + 1, line_h))
    end

    -- Re-derive the vertical extent from the word's *own* columns. The line
    -- extent above came from a fixed band around the tap (BG_LOCAL_HALF_W
    -- wide), which is narrower than many words: an ascender or descender
    -- belonging to this word but sitting outside that band was invisible to
    -- it, and cropping the glyph there is exactly what makes OCR return part
    -- of a word instead of the word.
    local word_has_ink = {}
    for y = min_y_bound, max_y_bound do
        local found = false
        for x = x0, x1 do
            if isInk(sample, x, y, background, is_inverted) then
                found = true
                break
            end
        end
        word_has_ink[y] = found
    end

    local seed_y = tap_y
    if not word_has_ink[seed_y] then
        for distance = 0, line_h do
            if word_has_ink[tap_y - distance] then
                seed_y = tap_y - distance
                break
            elseif word_has_ink[tap_y + distance] then
                seed_y = tap_y + distance
                break
            end
        end
    end
    if not word_has_ink[seed_y] then
        return abort("no ink in the word's own columns")
    end
    local ty0, ty1 = growRowExtent(word_has_ink, seed_y, min_y_bound, max_y_bound)

    if Timing.enabled then
        for _, dir in ipairs({ ".", "/tmp" }) do
            savePGM(dir .. "/wordfinder_crop.pgm", sample, w, h)
            savePGM(dir .. "/wordfinder_crop_box.pgm", sample, w, h, x0, x1, ty0, ty1)
        end
    end

    if owned then pcall(owned.free, owned) end

    local word_h = ty1 - ty0 + 1
    local pad_x = math.max(0, math.floor(word_h * PAD_RATIO * 0.5))
    local pad_y = math.max(0, math.floor(word_h * PAD_RATIO))

    local px0 = math.max(0, x0 - pad_x)
    local px1 = math.min(w - 1, x1 + pad_x)
    local py0 = math.max(0, ty0 - pad_y)
    local py1 = math.min(h - 1, ty1 + pad_y)

    local box_res = {
        x = (origin_x + px0) / CROP_ZOOM,
        y = (origin_y + py0) / CROP_ZOOM,
        w = (px1 - px0 + 1) / CROP_ZOOM,
        h = (py1 - py0 + 1) / CROP_ZOOM,
    }

    if Timing.enabled then
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
        WordFinder.logDiagnostic(string.format("findWordBox tap=(%.1f,%.1f) pg=%s -> box=(x=%.1f,y=%.1f,w=%.1f,h=%.1f)", px, py, tostring(pageno), box_res.x, box_res.y, box_res.w, box_res.h), {
            bg = background,
            inv = is_inverted,
            bg_box = string.format("(%d,%d)-(%d,%d)", lx0, bg_y0, lx1, bg_y1),
            line_h = line_h,
            gap_thresh = gap_threshold,
            all_gaps = "[" .. table.concat(gaps, ",") .. "]",
            col_map = table.concat(map_chars),
        })
    end

    return box_res, native
end

return WordFinder
