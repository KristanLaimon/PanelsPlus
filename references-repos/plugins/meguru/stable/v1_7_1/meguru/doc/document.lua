-- A virtual streaming document; ReaderUI's page N is OPDS-PSE's index N-1.

local Blitbuffer = require("ffi/blitbuffer")
local CanvasContext = require("document/canvascontext")
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local ffi = require("ffi")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Device = require("device")
-- MuPDF binding, guarded: a build without it degrades to the RenderImage path.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end
local logger = require("logger")
local ComicInfo = require("meguru/comicinfo")
local Derainbow = require("meguru/derainbow")
local FS = require("meguru/fs")
local Image = require("meguru/doc/image")
local Local = require("meguru/local")
local Marker = require("meguru/marker")
local Panel = require("meguru/panel")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")
local SeriesState = require("meguru/seriesstate")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")
local Spread = require("meguru/spread")
local util = require("util")
local ffiutil = require("ffi/util")

local C = ffi.C

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- Monotonic ms for log timing; os.clock is CPU time and misses network waits.
local function nowMs()
    local secs, usecs = ffiutil.gettime()
    return secs * 1000 + usecs / 1000
end

-- Auto page crop: ~128px scan then a native fine pass; crop lives in the bbox.
local AUTOCROP_SCAN_TARGET = 128 -- max dimension of the scanned downscale
-- Paper starts here; below the dark bound a margin is ink, whatever it is for.
local AUTOCROP_MIN_BG_LUMA = 170
local AUTOCROP_MAX_DARK_BG_LUMA = 85
-- How dark a bar has to be for the *letterbox* to take its colour: the bound
-- above is the crop's ink, this one is the frame a reader sees the page
-- against, and it sits well under a scan's shading, which must leave the paper.
local AUTOCROP_FRAME_MAX_LUMA = 120
local AUTOCROP_LUMA_DELTA = 26   -- how much a pixel may differ from the border
-- Never shrink a page below this fraction of its area (pathological scan).
local AUTOCROP_MIN_KEEP_FRAC = 0.02
-- Every edge is read for its own colour; three of them agreeing is a margin.
local AUTOCROP_EDGES = { "top", "bottom", "left", "right" }
-- A drawing can reach two sides of a page, so three in one colour are a margin.
local AUTOCROP_MAJORITY_SIDES = 3
-- Tighter than the content delta on purpose: a scanned margin drifts a little
-- from side to side, while a grey band and grey art must not pass for one colour.
local AUTOCROP_SAME_COLOR_DELTA = 12
-- How deep a bar of ink or colour may run and still be a margin, and how much of
-- a dimension any trim may take: a pale patch of drawing is paper to every test
-- there is, and the cap is what stops it eating the page. A bar down a side --
-- a scan bed, a platen edge, a page shot on a black desk -- reaches a quarter of
-- the way in. One *across* the top or bottom gets a tenth: panels run to those
-- edges, and their black is as uniform as a letterbox bar's.
local AUTOCROP_SIDE_MAX_FRAC = 0.25
local AUTOCROP_ACROSS_MAX_FRAC = 0.10
local AUTOCROP_MAX_TRIM_FRAC = 0.25

-- Blitbuffer type -> bytes per pixel; an unknown type bails out.

-- Page kept as-is because the crop refused; dbg, as it fires every page.
local function cropSkipLog(pageno, ...)
    if pageno then
        logger.dbg("Meguru: crop skip (page", pageno, "):", ...)
    else
        logger.dbg("Meguru: crop skip:", ...)
    end
end

-- A pixel is content when it differs from every margin colour the scan found.
local function differsFromAll(bgs, lum)
    for i = 1, #bgs do
        if math.abs(lum - bgs[i]) <= AUTOCROP_LUMA_DELTA then
            return false
        end
    end
    return true
end

-- Scan a small buffer for the content box; page_w/h are the PAGE's, not bb's.
local function scanContentBounds(bb, pageno, page_w, page_h)
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w < 3 or h < 3 then
        return nil
    end
    if bb:getRotation() and bb:getRotation() ~= 0 then
        return nil -- raw rows are not axis-aligned; refuse rather than mis-scan
    end
    local bpp = Image.bytesPerPixel(bb:getType())
    if not bpp then
        return nil
    end
    local inverse = bb:getInverse() == true
    local data = Blitbuffer.tostring(bb)
    local stride = tonumber(bb.stride)
    if not stride or stride < w * bpp then
        stride = w * bpp
    end
    if #data < stride * h then
        -- Some builds omit per-row stride padding; use the compact layout.
        stride = w * bpp
        if #data < stride * h then
            return nil -- unexpected layout, refuse rather than mis-scan
        end
    end

    local function lumaAt(y, x)
        local off = y * stride + x * bpp
        local lum
        if bpp == 1 then
            lum = data:byte(off + 1)
        elseif bpp == 2 then
            -- BB8A: min(gray, alpha) keeps transparent texels as content.
            local a = data:byte(off + 1)
            local b = data:byte(off + 2)
            lum = a < b and a or b
        else
            -- Rec.601 luminance, not the mean (they differ up to 65 on tints).
            local r = data:byte(off + 1)
            local g = data:byte(off + 2)
            local b = data:byte(off + 3)
            lum = math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
        end
        if inverse then
            lum = 255 - lum
        end
        return lum
    end

    -- Sample: luma plus the channels the surround is painted with.
    local function sampleAt(y, x)
        local off = y * stride + x * bpp
        local l = lumaAt(y, x)
        local r, g, b = l, l, l
        if bpp == 3 or bpp == 4 then
            r, g, b = data:byte(off + 1), data:byte(off + 2), data:byte(off + 3)
            if inverse then
                r, g, b = 255 - r, 255 - g, 255 - b
            end
        end
        return { l = l, r = r, g = g, b = b }
    end

    -- The line `depth` in from one edge: its median sample when the whole line
    -- is one colour, nil when anything is drawn on it. `step` skips pixels: the
    -- page's own edge lines are read whole, a strip's depth is not so fine.
    local function lineColor(edge, depth, step)
        step = step or 1
        local line = {}
        local translucent = false
        local function push(y, x)
            if bpp == 2 and data:byte(y * stride + x * bpp + 2) < 255 then
                translucent = true -- BB8A: a transparent margin is not a margin
            end
            line[#line + 1] = sampleAt(y, x)
        end
        if edge == "top" then
            for x = 0, w - 1, step do push(depth, x) end
        elseif edge == "bottom" then
            for x = 0, w - 1, step do push(h - 1 - depth, x) end
        elseif edge == "left" then
            for y = 0, h - 1, step do push(y, depth) end
        else
            for y = 0, h - 1, step do push(y, w - 1 - depth) end
        end
        if translucent then
            return nil
        end
        table.sort(line, function(a, b) return a.l < b.l end)
        local m = #line
        local lo = line[math.max(1, math.floor(m * 0.15))]
        local hi = line[math.max(1, math.floor(m * 0.85))]
        if hi.l - lo.l > AUTOCROP_LUMA_DELTA then
            return nil -- the drawing reaches this line, so it is not a margin
        end
        return line[math.max(1, math.floor(m * 0.5))]
    end

    -- Paper: light and near-neutral, the one surface that is a margin on sight.
    local function isPaperSample(sample)
        return Image.isPaperColor(sample.r, sample.g, sample.b, AUTOCROP_MIN_BG_LUMA)
    end

    -- Whether a bar of one colour ends inside its own cap, in from an edge: a
    -- scan's bar does, a panel that bleeds off the page runs deeper.
    local function barIsShallow(edge, sample)
        local vertical = (edge == "left" or edge == "right")
        local far = vertical and w or h
        local frac = vertical and AUTOCROP_SIDE_MAX_FRAC or AUTOCROP_ACROSS_MAX_FRAC
        local cap = math.max(1, math.floor(far * frac))
        for depth = 1, cap do
            local line = lineColor(edge, depth, 4)
            if not line or math.abs(line.l - sample.l) > AUTOCROP_LUMA_DELTA then
                return true
            end
        end
        return false
    end

    local edge_colors = {}
    for _, edge in ipairs(AUTOCROP_EDGES) do
        edge_colors[edge] = lineColor(edge, 0)
    end

    -- The page's surface is asked of the ring, not of one line: its light pole
    -- is paper wherever any margin is, while a single line fails a uniformity
    -- test flat as soon as the drawing touches it -- and on a real page the
    -- drawing touches, so the margins are read from the whole ring's percentile.
    local samples = {}
    for x = 0, w - 1 do
        samples[#samples + 1] = sampleAt(0, x)
        samples[#samples + 1] = sampleAt(h - 1, x)
    end
    for y = 1, h - 2 do
        samples[#samples + 1] = sampleAt(y, 0)
        samples[#samples + 1] = sampleAt(y, w - 1)
    end
    table.sort(samples, function(a, b) return a.l < b.l end)
    local n = #samples
    local light = samples[math.max(1, math.floor(n * 0.85))]
    -- The letterbox wants the page's paper, not the dimmest thing that still
    -- passes for it: a scan's margins are shaded unevenly, and a flat fill of the
    -- 85th percentile reads as light grey beside a white margin on a colour
    -- screen. The crop's own background keeps the 85th.
    local paper = samples[math.max(1, math.floor(n * 0.95))]
    local surface
    if isPaperSample(light) then
        surface = light
    end
    -- The palest paper an edge line is drawn in is a surface too, and the taller
    -- of the two is the page's own: it is what the letterbox is painted in.
    local function noteSurface(sample)
        if sample and isPaperSample(sample)
            and (not surface or sample.l > surface.l) then
            surface = sample
        end
    end
    noteSurface(paper)

    -- A colour three sides are drawn in is the page's frame, not a drawing: a
    -- panel reaches two sides of a page and never three.
    local frame
    for _, edge in ipairs(AUTOCROP_EDGES) do
        local candidate = edge_colors[edge]
        if candidate then
            local agree = 0
            for _, other in ipairs(AUTOCROP_EDGES) do
                local line = edge_colors[other]
                if line and math.abs(line.l - candidate.l) <= AUTOCROP_SAME_COLOR_DELTA then
                    agree = agree + 1
                end
            end
            if agree >= AUTOCROP_MAJORITY_SIDES then
                frame = candidate
                break
            end
        end
    end

    -- Margins: the surface wherever it is, a frame's colour on the edges it is
    -- drawn on, and a bar that is one colour, clearly not the surface and shallow
    -- enough to be a scan's bar or a letterbox rather than the drawing. Nothing
    -- else is a margin, so a page whose drawing reaches every edge keeps it all.
    local bgs = {}
    local ink_bar
    local function addBackground(sample)
        if sample and differsFromAll(bgs, sample.l) then
            bgs[#bgs + 1] = sample.l
        end
    end
    addBackground(surface)
    for _, edge in ipairs(AUTOCROP_EDGES) do
        local candidate = edge_colors[edge]
        if candidate then
            noteSurface(candidate)
            local accepted = isPaperSample(candidate)
            if not accepted and frame
                and math.abs(frame.l - candidate.l) <= AUTOCROP_SAME_COLOR_DELTA then
                accepted = true
            end
            if not accepted
                and (not surface
                    or math.abs(candidate.l - surface.l) > AUTOCROP_LUMA_DELTA)
                and barIsShallow(edge, candidate) then
                accepted = true
            end
            if accepted then
                addBackground(candidate)
-- The frame the reader sees the page against: a black margin was asked to be
-- letterboxed in black, not in paper. Sides only, though -- a bar across the
-- top or bottom is trimmed like one, but the background is the reader's guess
-- at the page's ground, and a band across the page is the page's own banding.
                local side = edge == "left" or edge == "right"
                if side and not isPaperSample(candidate)
                    and candidate.l <= AUTOCROP_FRAME_MAX_LUMA then
                    ink_bar = ink_bar or candidate
                end
            end
        end
    end
    if not bgs[1] then
        -- Every edge is drawn on: nothing here is a margin.
        cropSkipLog(pageno, "no margin on any edge — page kept as-is")
        return nil
    end

    local bg = bgs[1]
    if bg <= AUTOCROP_MAX_DARK_BG_LUMA and bpp == 2 then
        -- BB8A: a transparent frame is not a black margin; only opaque is.
        for x = 0, w - 1 do
            if data:byte(x * bpp + 2) < 255
                or data:byte((h - 1) * stride + x * bpp + 2) < 255 then
                return nil
            end
        end
        for y = 1, h - 2 do
            if data:byte(y * stride + 2) < 255
                or data:byte(y * stride + (w - 1) * bpp + 2) < 255 then
                return nil
            end
        end
    end

    -- Project content pixels onto rows and columns.
    local row_cnt = {}
    local col_cnt = {}
    for y = 0, h - 1 do
        local base = y * stride
        local rcount = 0
        for x = 0, w - 1 do
            local off = base + x * bpp
            local lum
            if bpp == 1 then
                lum = data:byte(off + 1)
            elseif bpp == 2 then
                local a = data:byte(off + 1)
                local b = data:byte(off + 2)
                lum = a < b and a or b
            else
                -- Rec.601 luminance; see `lumaAt` above for why not the mean.
                local r = data:byte(off + 1)
                local g = data:byte(off + 2)
                local b = data:byte(off + 3)
                lum = math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
            end
            if inverse then
                lum = 255 - lum
            end
            if differsFromAll(bgs, lum) then
                rcount = rcount + 1
                col_cnt[x] = (col_cnt[x] or 0) + 1
            end
        end
        row_cnt[y] = rcount
    end

    -- A candidate row/column needs more than a couple of speck pixels.
    local row_min = math.max(2, math.floor(w * 0.02))
    local col_min = math.max(2, math.floor(h * 0.02))

    local left, top, right, bottom
    for y = 0, h - 1 do
        if row_cnt[y] >= row_min then
            top = y
            break
        end
    end
    for y = h - 1, 0, -1 do
        if row_cnt[y] >= row_min then
            bottom = y
            break
        end
    end
    for x = 0, w - 1 do
        if (col_cnt[x] or 0) >= col_min then
            left = x
            break
        end
    end
    for x = w - 1, 0, -1 do
        if (col_cnt[x] or 0) >= col_min then
            right = x
            break
        end
    end
    if not (left and top and right and bottom) then
        -- No row/column cleared the content bar anywhere: blank page.
        cropSkipLog(pageno, "no content found anywhere (page blank?)")
        return nil -- blank page
    end
    -- Whole-page box: nothing left to trim, i.e. the "frame stays" symptom.
    if left == 0 and top == 0 and right == w - 1 and bottom == h - 1 then
        -- Both sizes: page margin vs how coarsely the scan judged it.
        cropSkipLog(pageno, "detected content spans the whole page",
            "(bg=", math.floor(bg), ", page ", page_w, "x", page_h,
            ", scanned at ", w, "x", h, ") — nothing to trim")
    end
    -- Bg lumas for the fine pass. The letterbox is painted in the paper the crop
    -- took off, so the screen reads as the page's own margins; a trimmed black bar
    -- answers black and a framed page with its frame's colour, and a page with
    -- none of the three answers nothing.
    -- A frame answers only when it is dark. Three shaded margins of a scan agree
    -- with each other as readily as a drawn border does, and taking that for the
    -- page's frame letterboxed a white-margined page in their grey.
    local dark_frame
    if frame and frame.l <= AUTOCROP_FRAME_MAX_LUMA then
        dark_frame = frame
    end
    local chosen = ink_bar or dark_frame or surface
    return { left, top, right, bottom, bgs = bgs,
        color = chosen and { r = chosen.r, g = chosen.g, b = chosen.b, l = chosen.l } or nil }
end

-- Forward declaration: refineAutoCrop is defined below but used above.
local refineAutoCrop

-- Native auto content box, or nil to leave the page as-is; cached in crops.
local function computeContentBox(native_bb, full_w, full_h, pageno)
    -- The scan copy is malloc'd outside the Lua heap; free it unconditionally.
    local ok, box = pcall(function()
        local bw = native_bb:getWidth()
        local bh = native_bb:getHeight()
        if not bw or not bh or bw < 1 or bh < 1 then
            return nil
        end
        -- ~128px across the long edge is plenty to find a border.
        local sw, sh = bw, bh
        local scan_bb = native_bb
        if bw > AUTOCROP_SCAN_TARGET or bh > AUTOCROP_SCAN_TARGET then
            local scale = AUTOCROP_SCAN_TARGET / math.max(bw, bh)
            sw = math.max(1, math.floor(bw * scale + 0.5))
            sh = math.max(1, math.floor(bh * scale + 0.5))
            local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer,
                RenderImage, native_bb, sw, sh, false)
            if ok_scale and scaled and scaled ~= native_bb then
                scan_bb = scaled
            else
                return nil -- could not make the scan copy: leave the page as-is
            end
        end
        -- Its own pcall so `scan_bb` is freed even if the scanner throws.
        local bounds
        local ok_scan, scan_err = pcall(function()
            bounds = scanContentBounds(scan_bb, pageno, full_w, full_h)
        end)
        if scan_bb ~= native_bb then
            scan_bb:free()
        end
        if not ok_scan then
            logger.warn("Meguru: auto-crop scan failed:", scan_err)
            return nil
        end
        if not bounds then
            return nil
        end
        local left, top, right, bottom = bounds[1], bounds[2], bounds[3], bounds[4]
        local bgs = bounds.bgs
        local sc_x = full_w / sw
        local sc_y = full_h / sh
        local x0 = math.max(0, math.floor(left * sc_x))
        local y0 = math.max(0, math.floor(top * sc_y))
        local x1 = math.min(full_w, math.ceil((right + 1) * sc_x))
        local y1 = math.min(full_h, math.ceil((bottom + 1) * sc_y))

        if x0 == 0 and y0 == 0 and x1 == full_w and y1 == full_h then
            return nil
        end
        -- Pin each edge to the exact content pixel (see refineAutoCrop).
        x0, y0, x1, y1 = refineAutoCrop(native_bb, x0, y0, x1, y1, bgs,
            math.max(8, math.ceil(sc_x * 3)),
            math.max(8, math.ceil(sc_y * 3)))
        if x0 == 0 and y0 == 0 and x1 == full_w and y1 == full_h then
            return nil
        end
        -- No edge may lose more than its share, whatever the scan was sure of.
        local cap_x = math.floor(full_w * AUTOCROP_MAX_TRIM_FRAC)
        local cap_y = math.floor(full_h * AUTOCROP_MAX_TRIM_FRAC)
        if x0 > cap_x then
            x0 = cap_x
        end
        if y0 > cap_y then
            y0 = cap_y
        end
        if x1 < full_w - cap_x then
            x1 = full_w - cap_x
        end
        if y1 < full_h - cap_y then
            y1 = full_h - cap_y
        end
        if x0 == 0 and y0 == 0 and x1 == full_w and y1 == full_h then
            return nil
        end
        -- Last line of defence against a pathological scan.
        if (x1 - x0) * (y1 - y0) < AUTOCROP_MIN_KEEP_FRAC * full_w * full_h then
            return nil
        end
        return { x0 = x0, y0 = y0, x1 = x1, y1 = y1, bgs = bgs,
            color = bounds.color }
    end)
    if not ok then
        logger.warn("Meguru: auto-crop scan failed:", box)
        return nil
    end
    return box
end

-- Panel zoom wraps meguru/panel's recursive-cut detector; base method is nil.

-- Tighten the coarse box to the exact content edge; fall back on any hiccup.
refineAutoCrop = function(native_bb, x0, y0, x1, y1, bgs, pad_x, pad_y)
    if not (native_bb and native_bb.getWidth) then
        return x0, y0, x1, y1
    end
    if native_bb:getRotation() and native_bb:getRotation() ~= 0 then
        return x0, y0, x1, y1 -- rows not axis-aligned: keep coarse box
    end
    local fw, fh = native_bb:getWidth(), native_bb:getHeight()
    if fw < 2 or fh < 2 then
        return x0, y0, x1, y1
    end
    local w, h = fw, fh

    -- Rasterise only the band each walk reads, not the whole page.
    local function bandLuma(px, py, bw, bh)
        local band = Blitbuffer.new(bw, bh, native_bb:getType())
        band:blitFrom(native_bb, 0, 0, px, py, bw, bh)
        -- rasterFor reads this: an inverted page must keep reading inverted.
        band:setInverse(native_bb:getInverse())
        local raster = Image.rasterFor(band)
        band:free()
        return raster and raster.luma, px, py
    end

    -- A reader for one band: the walk's own coordinates, offset into it.
    local function contentReader(luma, ox, oy)
        return function(y, x)
            return differsFromAll(bgs, luma(y - oy, x - ox))
        end
    end
    -- ~0.2% of a row's span separates a real edge from isolated JPEG noise.
    local row_bar = math.max(2, math.floor(w * 0.002))
    local col_bar = math.max(2, math.floor(h * 0.002))

    -- Walk rows from the band edge; the first over the bar is the content top.
    local top_y0, top_y1 = math.max(0, y0 - pad_y), math.min(h - 1, y0 + pad_y)
    local top_luma, top_ox, top_oy = bandLuma(0, top_y0, w, top_y1 - top_y0 + 1)
    if not top_luma then
        return x0, y0, x1, y1
    end
    local isContent = contentReader(top_luma, top_ox, top_oy)
    local top = y0
    for y = top_y0, top_y1 do
        local cnt = 0
        for x = 0, w - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= row_bar then
                    break
                end
            end
        end
        if cnt >= row_bar then
            top = y
            break
        end
    end

    -- Bottom: the mirror walk, from below the coarse bottom edge upward.
    local bot_y0, bot_y1 = math.max(0, y1 - 1 - pad_y), math.min(h - 1, y1 - 1 + pad_y)
    local bot_luma, bot_ox, bot_oy = bandLuma(0, bot_y0, w, bot_y1 - bot_y0 + 1)
    if not bot_luma then
        return x0, y0, x1, y1
    end
    isContent = contentReader(bot_luma, bot_ox, bot_oy)
    local bottom = y1 - 1
    for y = bot_y1, bot_y0, -1 do
        local cnt = 0
        for x = 0, w - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= row_bar then
                    break
                end
            end
        end
        if cnt >= row_bar then
            bottom = y
            break
        end
    end

    -- Left: a column counts only when content runs down enough of its height.
    local lft_x0, lft_x1 = math.max(0, x0 - pad_x), math.min(w - 1, x0 + pad_x)
    local lft_luma, lft_ox, lft_oy = bandLuma(lft_x0, 0, lft_x1 - lft_x0 + 1, h)
    if not lft_luma then
        return x0, y0, x1, y1
    end
    isContent = contentReader(lft_luma, lft_ox, lft_oy)
    local left = x0
    for x = lft_x0, lft_x1 do
        local cnt = 0
        for y = 0, h - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= col_bar then
                    break
                end
            end
        end
        if cnt >= col_bar then
            left = x
            break
        end
    end

    -- Right: the mirror column walk, from the far side inward.
    local rgt_x0, rgt_x1 = math.max(0, x1 - 1 - pad_x), math.min(w - 1, x1 - 1 + pad_x)
    local rgt_luma, rgt_ox, rgt_oy = bandLuma(rgt_x0, 0, rgt_x1 - rgt_x0 + 1, h)
    if not rgt_luma then
        return x0, y0, x1, y1
    end
    isContent = contentReader(rgt_luma, rgt_ox, rgt_oy)
    local right = x1 - 1
    for x = rgt_x1, rgt_x0, -1 do
        local cnt = 0
        for y = 0, h - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= col_bar then
                    break
                end
            end
        end
        if cnt >= col_bar then
            right = x
            break
        end
    end

    local nx0, ny0 = math.max(0, left), math.max(0, top)
    local nx1, ny1 = math.min(w, right + 1), math.min(h, bottom + 1)
    if nx0 >= nx1 or ny0 >= ny1 then
        return x0, y0, x1, y1 -- sanity: fine pass went sideways, keep coarse
    end
    return nx0, ny0, nx1, ny1
end

-- pagenumbercrop calls the base renderPage slot, which crashes: redirect it.
local _render_page_shim_installed = false
local function installRenderPageShim()
    if _render_page_shim_installed then
        return
    end
    _render_page_shim_installed = true
    local base_render_page = Document.renderPage
    Document.renderPage = function(self, pageno, rect, zoom, rotation, ...)
        if self.provider == "meguru" then
            return self:renderPage(pageno, rect, zoom, rotation, ...)
        end
        return base_render_page(self, pageno, rect, zoom, rotation, ...)
    end
end
installRenderPageShim()

-- Panels+ calls the base getNativePageDimensions slot, which crashes: redirect.
local _native_page_dimensions_shim_installed = false
local function installNativePageDimensionsShim()
    if _native_page_dimensions_shim_installed then
        return
    end
    _native_page_dimensions_shim_installed = true
    local base_get_native_page_dimensions = Document.getNativePageDimensions
    Document.getNativePageDimensions = function(self, pageno, ...)
        if self.provider == "meguru" then
            -- One page, always: a pair is wide; do not turn for it.
            return Geom:new(self:_pageGeom(pageno))
        end
        return base_get_native_page_dimensions(self, pageno, ...)
    end
end
installNativePageDimensionsShim()

-- Captured before the class replaces it; the one-page answer stays reachable.
local base_get_used_bbox_dimensions = Document.getUsedBBoxDimensions

local MeguruDocument = Document:extend{
    -- Set in init: the OCR page shim; the book still has no engine instance.
    _document = nil,
    provider = "meguru",
    -- Provider label for KOReader's "Open with..." picker (both extensions).
    provider_name = "Meguru",
    dc_null = DrawContext.new(),

    -- .cbz through this engine: one MuPDF handle, no HTTP seams.
    local_cbz = false,
    mupdf_doc = nil,

    -- Pages warmed after a repaint, including the one hintPage is handed.
    prefetch_count = 1,
    -- Maximum number of decoded/scaled tiles kept in RAM per document.
    max_cached_tiles = 8,
    -- Max native decoded pages kept in RAM (for pan/zoom crops).
    max_cached_native = 3,
    -- Page-byte entries in RAM: the rendered page, hintPage's, and two ahead.
    max_cached_pages = 4,

    tiles = nil,    -- decoded tile LRU, key = "pageno|w x h"
    native = nil,   -- native decode LRU, key = pageno
    stamps = nil,   -- recency stamp for tiles and native only (not bytes)
    stamp = 0,
    page_bytes = nil, -- raw page bytes, most-recent first: { pageno, bytes }
    panels = nil,   -- detected panel lists, "<pageno>|<mode>", never stamped
    max_cached_panels = 4,
    dims = nil,     -- pageno -> {w=, h=} full (capped) native page size
    crops = nil,    -- pageno -> auto content box in native px; false = full
    desc = nil,     -- the stream descriptor read from the marker file

    -- Ascending pages found wider than tall; written only for decoded pages.
    wide_list = nil,

    -- Reads right-to-left (earlier page on the right); mirrors the key.
    spread_rtl = false,

    -- Set by this plugin's wide-page rotation, not by the reader turning.
    spread_rotated_by_plugin = false,
}

-- Open a local .cbz, or nil; mirrors stock DocumentMuPDF so order/count agree.
function MeguruDocument:_openLocalArchive()
    if not Mupdf then
        logger.warn("Meguru: MuPDF binding unavailable; cannot open a local CBZ")
        return nil
    end
    local ok_doc, doc = pcall(Mupdf.openDocument, self.file)
    if not ok_doc or not doc then
        logger.warn("Meguru: MuPDF cannot open", self.file, ":", tostring(doc))
        return nil
    end
    -- Same colour answer as the streamed decode, so both engines render alike.
    if doc.setColorRendering then
        doc:setColorRendering(Image.colorEnabled())
    end
    return doc
end

function MeguruDocument:init()
    self.tiles = {}
    self.native = {}
    self.stamps = {}
    self.stamp = 0
    self.page_bytes = {}
    self.dims = {}
    self.wide_list = {}
    self.crops = {}
    self.panels = {}
    -- Failed/refused decodes, so a doomed decode is not retried on every paint.
    self.dead_pages = {}

    -- Failed fetches and why; retried only by clearFetchFailures.
    self.fetch_failed = {}

    self.mod_time = FS.mtime(self.file)

    -- Mode by suffix before parsing; a .cbz must never reach LuaSettings.
    local desc
    if util.getFileNameSuffix(self.file):lower() == "cbz" then
        desc = nil
        self.local_cbz = true
        self.mupdf_doc = self:_openLocalArchive()
        if not self.mupdf_doc then
            -- Nothing opened, nothing to leak; DocumentRegistry catches it.
            error("Meguru: cannot open local CBZ as a Meguru book: "
                .. tostring(self.file))
        end
    else
        desc = Marker.load(self.file)
        if not desc then
            error("Meguru: not a valid stream marker: " .. tostring(self.file))
        end
    end
    self.desc = desc

    -- init never fetches (a dead server would hold the open).

    local count
    if self.local_cbz then
        -- The same 1-based numbers stock uses; a 0-page archive clamps to 1.
        local ok_pages, n = pcall(self.mupdf_doc.getPages, self.mupdf_doc)
        count = ok_pages and tonumber(n) or 1
        if not count or count < 1 then
            count = 1
        end
    else
        count = tonumber(desc.count)
        if not count or count < 1 then
            count = 1
        end
    end

    -- Non-nil koptinterface picks the KOpt option set; its OCR seam is added below.
    self.info = {
        has_pages = true,
        number_of_pages = count,
        configurable = true,
    }
    self.koptinterface = {}
    self.configurable.writing_direction = 0 -- LTR
    self.render_mode = 0
    self.is_open = true

    -- Pages' sizes are unknown until decoded, so buffers are scaled on request.
    self:updateColorRendering()
    -- Left to the device where the panel dithers or the pages are colour.
    local hw_dither = Device:canHWDither() and true or false
    local colour = Image.colorEnabled()
    if hw_dither or colour then
        self.sw_dithering = Screen.sw_dithering and true or false
        logger.info(string.format(
            "Meguru: page dithering left to the device (sw_dithering=%s; colour=%s, eink=%s, fb_bpp=%s, hw_dither=%s)",
            tostring(self.sw_dithering), tostring(colour),
            tostring(Image.einkScreen()), tostring(Screen.fb_bpp),
            tostring(hw_dither)))
    else
        self.sw_dithering = true
        logger.info(string.format(
            "Meguru: tile->screen dithering forced ON (sw_dithering; eink=%s, fb_bpp=%s, hw_dither=%s)",
            tostring(Image.einkScreen()), tostring(Screen.fb_bpp),
            tostring(hw_dither)))
    end

    if self.local_cbz then
        logger.info(string.format(
            "Meguru: local CBZ ready — \"%s\", %d page(s) at %s",
            self:_localTitle(), count, self.file))
    else
        logger.info(string.format(
            "Meguru: stream ready — \"%s\", %d page(s), cached at %s",
            desc.title or "?", count, self.file))
    end

    -- The series' direction must land here: stock reads this key at ReadSettings,
    -- before any seed of ours runs, and only here can it be written that early.
    -- Compared, never tested: "left to right" is a false answer, not a missing one.
    local answers = SeriesState.answersFor(self)
    local from_series = answers and answers.manga_order
    local direction = from_series
    if direction == nil then
        direction = Settings.get("manga_order")
    end
    -- Seed Reading direction only if absent; last_read only for a first open.
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds then
        local opened_before = DocSettings:hasSidecarFile(self.file)
        local ok_seed, err = pcall(function()
            local ds = DocSettings:open(self.file)
            if direction ~= nil
                and (ds:readSetting("inverse_reading_order") == nil
                    or from_series ~= nil) then
                ds:saveSetting("inverse_reading_order", direction)
                ds:flush()
            end
            -- Same key lays out a pair: RTL puts the earlier page on the right.
            if type(ds.isTrue) == "function" then
                self.spread_rtl = ds:isTrue("inverse_reading_order") and true or false
            end
            -- Used as recorded; another reader's position has no lead to trim.
            local page = not opened_before and desc and tonumber(desc.last_read) or nil
            if page and page > 1 and page <= count then
                ds.data.last_page = math.floor(page)
                ds:flush()
                logger.info("Meguru: starting", self.file, "at page", page,
                    "(the server's position)")
            end
        end)
        if not ok_seed then
            logger.warn("Meguru: could not seed the book's sidecar:", err)
        end
    end
    return true
end

function MeguruDocument:close()
    local DocumentRegistry = require("document/documentregistry")
    if self.is_open then
        local refcount
        local ok = pcall(function()
            refcount = DocumentRegistry:closeDocument(self.file)
        end)
        if not ok then
            refcount = 0
        end
        if refcount == 0 then
            self:clearCaches()
            -- Release the persistent MuPDF document; nil it (idempotent close).
            if self.local_cbz and self.mupdf_doc then
                pcall(self.mupdf_doc.close, self.mupdf_doc)
                self.mupdf_doc = nil
            end
            self.is_open = false
            return true
        end
        logger.dbg("Meguru: stream refcount down to", refcount, "for", self.file)
        return false
    end
    logger.warn("Tried to close an already closed document:", self.file)
    return nil
end

-- Free every BlitBuffer an LRU holds; dropping the table would leak it.
local function freeCacheEntries(cache)
    for _, item in pairs(cache or {}) do
        if item.bb and item.bb_free ~= true then
            item.bb:free()
            item.bb_free = true
        end
    end
end

function MeguruDocument:clearCaches()
    freeCacheEntries(self.tiles)
    freeCacheEntries(self.native)
    self.tiles = {}
    self.native = {}
    self.stamps = {}
    -- Byte store is Lua strings; dropping the table lets the GC reclaim them.
    self.page_bytes = {}
    -- Panel lists are plain numbers, so dropping the references frees them.
    self.panels = {}
end

-- Book's contrast from configurable, so panel zoom keeps it; 1.0 when unset.
function MeguruDocument:contrast()
    local value = self.configurable and self.configurable.contrast
    if type(value) == "number" and value > 0 then
        return value
    end
    return 1.0
end

-- Book's saturation; 1.0 when pages are not colour (adjustSaturation is no-op).
function MeguruDocument:saturation()
    local value = self.configurable and self.configurable.saturation
    if type(value) ~= "number" or value <= 0 then
        return 1.0
    end
    if not Image.colorEnabled() then
        return 1.0
    end
    return value
end

-- Book's moire choice AND availability; compared to 1 (0 is truthy).
function MeguruDocument:derainbow()
    if not Derainbow.available() then
        return false
    end
    return self.configurable ~= nil and self.configurable.derainbow == 1
end

-- Tone change stales tiles, crops, panels and memos; tiles are stamped.
function MeguruDocument:syncTone()
    local contrast, saturation = self:contrast(), self:saturation()
    local derainbow = self:derainbow()
    if contrast == self._tone_contrast and saturation == self._tone_saturation
            and derainbow == self._tone_derainbow then
        return contrast, saturation
    end
    -- The first call is the opening tone, not a change: nothing to drop yet.
    local first = self._tone_contrast == nil
    -- Only the tone pair costs a re-decode; the moire filter runs on the tile.
    local tone_moved = contrast ~= self._tone_contrast
        or saturation ~= self._tone_saturation
    self._tone_contrast, self._tone_saturation = contrast, saturation
    self._tone_derainbow = derainbow
    if tone_moved then
        freeCacheEntries(self.native)
        self.native = {}
        -- Memos are lazy, so nil and an empty table are the same answer here.
        self.crops = {}
        self.panels = {}
        self._meguru_pagenum_cache = nil
        self._meguru_pagenum_blank_cache = nil
        self._meguru_pagenum_history = nil
    end
    if not first then
        logger.dbg(string.format(
            "Meguru: render is now contrast %s, saturation %s, derainbow %s",
            tostring(contrast), tostring(saturation), tostring(derainbow)))
    end
    return contrast, saturation
end

local function bump(self, key)
    self.stamp = self.stamp + 1
    self.stamps[key] = self.stamp
end

local function evictOldest(self, cache, cap)
    local count = 0
    for _ in pairs(cache) do
        count = count + 1
    end
    while count >= cap do
        local oldest_key, oldest_stamp
        for k, _ in pairs(cache) do
            if oldest_key == nil or (self.stamps[k] or 0) < oldest_stamp then
                oldest_key = k
                oldest_stamp = self.stamps[k] or 0
            end
        end
        if oldest_key == nil then
            break
        end
        local item = cache[oldest_key]
        cache[oldest_key] = nil
        self.stamps[oldest_key] = nil
        if item and item.bb and item.bb_free ~= true then
            item.bb:free()
            item.bb_free = true
        end
        count = count - 1
    end
end

-- Cached tile for key, if still the tile that key means; tone is a stamp.
local function tileAtTone(self, key)
    local tile = self.tiles[key]
    if tile and tile.bb_free ~= true
            and tile.contrast == self._tone_contrast
            and tile.saturation == self._tone_saturation
            and tile.derainbow == self._tone_derainbow then
        return tile
    end
    -- Drop an already-freed entry; a live stale one stays for eviction.
    if tile and tile.bb_free == true then
        self.tiles[key] = nil
    end
    return nil
end

function MeguruDocument:cacheTile(key, tile)
    if self.tiles[key] then
        self.tiles[key].bb_free = true
        self.tiles[key].bb:free()
    end
    tile.bb_free = false
    -- The tone (both halves) and moire switch this tile was rendered at.
    tile.contrast = self._tone_contrast
    tile.saturation = self._tone_saturation
    tile.derainbow = self._tone_derainbow
    self.tiles[key] = tile
    bump(self, key)
    evictOldest(self, self.tiles, self.max_cached_tiles)
end

function MeguruDocument:cacheNative(pageno, bb)
    if self.native[pageno] then
        local old = self.native[pageno]
        if old.bb and old.bb_free ~= true then
            old.bb:free()
            old.bb_free = true
        end
    end
    self.native[pageno] = { bb = bb, bb_free = false }
    bump(self, pageno)
    evictOldest(self, self.native, self.max_cached_native)
end

-- True when the page's decoded native is already in the LRU.
function MeguruDocument:hasNative(pageno)
    local item = self.native and self.native[pageno]
    return item ~= nil and item.bb_free ~= true
end

-- Page bytes in RAM; page-number key is unambiguous (one book per document).
function MeguruDocument:readCachedPage(pageno)
    for i = 1, #self.page_bytes do
        local entry = self.page_bytes[i]
        if entry.pageno == pageno then
            if i > 1 then
                table.remove(self.page_bytes, i)
                table.insert(self.page_bytes, 1, entry)
            end
            return entry.bytes
        end
    end
    return nil
end

-- Keep bytes for one page; not evictOldest (it reads one low, shares stamps).
function MeguruDocument:cachePage(pageno, bytes)
    for i = 1, #self.page_bytes do
        if self.page_bytes[i].pageno == pageno then
            table.remove(self.page_bytes, i)
            break
        end
    end
    table.insert(self.page_bytes, 1, { pageno = pageno, bytes = bytes })
    -- Dropping the tail drops the last reference; the GC frees them.
    while #self.page_bytes > self.max_cached_pages do
        table.remove(self.page_bytes)
    end
end

-- Fetch credentials, resolved at use; no secret is stored in the marker.
function MeguruDocument:streamCredentials()
    local desc = self.desc or {}
    return Sources.credentials(desc.server_name, self.file)
end

-- Android's network check is a JNI call, and coverbrowser opens a document in a
-- fork where JNI aborts the process (koreader#14628): the parent asks live and
-- remembers, and only a fork on Android has to read what the parent left.
local posix_ok = pcall(require, "ffi/posix_h")
local getpid = posix_ok and C.getpid or nil
local parent_pid = getpid and tonumber(getpid()) or nil
local parent_connected = true

-- Device state, not a probe: Wi-Fi off can only fail, not detect a dead server.
function MeguruDocument:hasConnection()
    if self.local_cbz then
        return true
    end
    if parent_pid and tonumber(getpid()) ~= parent_pid
        and Device:isAndroid() then
        return parent_connected
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    local connected = ok and NetworkMgr ~= nil and NetworkMgr:isConnected() or false
    parent_connected = connected
    return connected
end

-- Forget fetch failures on a page turn or the connection returning.
function MeguruDocument:clearFetchFailures()
    local had = next(self.fetch_failed) ~= nil
    self.fetch_failed = {}
    return had
end

-- Ensure raw bytes for a page; a failure is remembered and not retried here.
function MeguruDocument:fetchPage(pageno)
    -- Pages are 1-based; pageno-1 is the server's zero-based index (0 invalid).
    if pageno < 1 then
        return nil
    end
    local data = self:readCachedPage(pageno)
    if data then
        return data
    end
    if self.fetch_failed[pageno] then
        return nil
    end
    local url = self.desc.template
        and PSE.pageURL(self.desc.template, pageno - 1,
            Screen:getWidth(), Screen:getHeight())
        or nil
    if not url then
        return nil
    end
    if not self:hasConnection() then
        self.fetch_failed[pageno] = { reason = "offline" }
        logger.warn("Meguru: no connection, cannot fetch page", pageno)
        return nil
    end
    local user, pass = self:streamCredentials()
    local ok, bytes, code = pcall(PSE.fetchPage, url, { username = user, password = pass })
    if not ok or not bytes then
        -- No code with ok = transport failure, not a server answer.
        local reason, detail
        if ok and code then
            reason, detail = "http", "(HTTP " .. tostring(code) .. ")"
        elseif ok then
            reason, detail = "network", "(no response)"
        else
            reason, detail = "network", "(error: " .. tostring(bytes) .. ")"
        end
        self.fetch_failed[pageno] = { reason = reason, code = code }
        logger.warn("Meguru: failed to fetch page", pageno, detail)
        return nil
    end
    -- Cleared only after success, so a failed fetch writes nothing.
    self.fetch_failed[pageno] = nil
    self:cachePage(pageno, bytes)
    return bytes
end

function MeguruDocument:prefetchPage(pageno)
    if pageno < 1 or pageno > self.info.number_of_pages then
        return
    end
    local ok, data = pcall(self.fetchPage, self, pageno)
    if ok and data then
        logger.dbg("Meguru: prefetched page", pageno, "to the page cache")
    end
end

-- Local cbz title is the archive's file name, as stock would report.
function MeguruDocument:_localTitle()
    local name = self.file:match("([^/\\]+)$") or self.file
    return (name:gsub("%.[^.]*$", ""))
end

-- Marker's series context, or nil (ordinary: local cbz and old markers).
function MeguruDocument:seriesContext()
    if not self.desc then
        return nil
    end
    return Marker.seriesContext(self.desc)
end

-- Folder shared with neighbours; separate from seriesContext by design.
function MeguruDocument:localSeries()
    if not self.local_cbz then
        return nil
    end
    return Local.seriesOf(self.file)
end

-- Local .cbz props from ComicInfo.xml, title falling back to the file name.
function MeguruDocument:_localComicProps()
    if not Settings.get("comic_info") then
        return { title = self:_localTitle() }
    end
    if self._comic_info == nil then
        self._comic_info = ComicInfo.read(self.file) or false
    end
    local props = {}
    for key, value in pairs(self._comic_info or {}) do
        props[key] = value
    end
    if type(props.title) ~= "string" or props.title == "" then
        props.title = self:_localTitle()
    end
    return props
end

function MeguruDocument:getDocumentProps()
    if self.local_cbz then
        return self:_localComicProps()
    end
    local desc = self.desc or {}
    -- Strip progress glyphs and resume prefixes, as the marker name does.
    local title = desc.title and Naming.cleanTitle(desc.title)

    -- Prefix the series name unless the title already starts with it.
    local name = desc.series_name
    if type(name) == "string" and name ~= ""
        and type(title) == "string" and title ~= ""
        and title:sub(1, #name) ~= name then
        title = name .. " - " .. title
    end

    -- No authors: both servers stamp placeholders worse than an empty field.
    return { title = title }
end

-- Cover BlitBuffer, nothing cached; falls back to page 1 so never cover-less.
function MeguruDocument:_localCoverPageImage()
    if self.dead_pages[1] then
        return nil
    end
    -- Must be Image.renderMupdfPage; a bare renderMuPDFPage is nil.
    local ok, bb = pcall(Image.renderMupdfPage, self.mupdf_doc, 1, nil)
    if not ok or not bb or bb == Image.DECODE_TOO_LARGE then
        logger.warn("Meguru: could not render local cbz cover")
        return nil
    end
    local w, h = bb:getWidth(), bb:getHeight()
    if w and h and (w > Screen:getWidth() or h > Screen:getHeight()) then
        local scale = math.min(Screen:getWidth() / w, Screen:getHeight() / h)
        local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
            math.max(1, math.floor(w * scale + 0.5)),
            math.max(1, math.floor(h * scale + 0.5)), false)
        if ok_s and scaled then
            if scaled ~= bb then
                bb:free() -- bounded cover made; release the full-res render
            end
            return scaled
        end
    end
    return bb
end

function MeguruDocument:getCoverPageImage()
    if self.local_cbz then
        return self:_localCoverPageImage()
    end
    -- No connection, no attempt: a cover is one request per book.
    if not self:hasConnection() then
        return nil
    end
    -- The book's cover wins over the series' (Kavita's gave every book one).
    local desc = self.desc or {}
    local cover_url
    for _, candidate in ipairs{ desc.cover_url, desc.series_cover_url } do
        if type(candidate) == "string" and candidate ~= "" then
            cover_url = candidate
            break
        end
    end

    local data
    if cover_url then
        local user, pass = self:streamCredentials()
        local ok, bytes, code = pcall(PSE.fetchPage, cover_url,
            { username = user, password = pass })
        if ok and bytes then
            data = bytes
        else
            -- Stored link unfetchable: fall through to page 1 (retried later).
            if ok then
                logger.warn("Meguru: failed to fetch cover (HTTP "
                    .. tostring(code) .. "), falling back to page 1")
            else
                logger.warn("Meguru: failed to fetch cover ("
                    .. tostring(bytes) .. "), falling back to page 1")
            end
        end
    end
    if not data then
        -- No stored link or it failed: page 1; no hasNative guard.
        data = self:fetchPage(1)
    end
    if not data then
        return nil
    end

    -- decodeNative caps oversized artwork, so a full-res cover stays bounded.
    local res = Image.decode(data)
    if not res or res == Image.DECODE_TOO_LARGE then
        logger.warn("Meguru: could not decode cover image")
        return nil
    end
    local bb = res
    -- Never hand back more pixels than the screen; free it only if copied.
    local w, h = bb:getWidth(), bb:getHeight()
    if w and h and (w > Screen:getWidth() or h > Screen:getHeight()) then
        local scale = math.min(Screen:getWidth() / w, Screen:getHeight() / h)
        local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
            math.max(1, math.floor(w * scale + 0.5)),
            math.max(1, math.floor(h * scale + 0.5)), false)
        if ok_s and scaled then
            if scaled ~= bb then
                bb:free() -- bounded cover made; release the full-res decode
            end
            return scaled
        end
    end
    return bb
end

function MeguruDocument:getToc()
    return {}
end

function MeguruDocument:getPageText()
    return nil
end

-- Two pages at once: the geometry; the pairing is meguru/spread (see the doc).

-- The page's own full size, never the pair's; the analyses measure one page.
function MeguruDocument:_pageGeom(pageno)
    local dims = self:getPageDims(pageno)
    return { w = dims.w, h = dims.h }
end

-- Whether two pages are shown now: read live, so install order cannot matter.
function MeguruDocument:spreadActive()
    local configurable = self.configurable
    local value = configurable and configurable.spread
    if value ~= "off" and value ~= "auto" and value ~= "on" then
        return false
    end
    -- Continuous scroll is a strip: two side by side would be two slots.
    if configurable.page_scroll == 1 or configurable.page_scroll == "1" then
        return false
    end
    if value == "on" then
        return true
    end
    if value == "off" then
        return false
    end
    -- "In landscape" means the reader's, not a screen this plugin turned.
    if self.spread_rotated_by_plugin then
        return false
    end
    return (Screen:getRotationMode() % 2) == 1
end

-- Offset anchor page, or 0 for off; compared because 0 and "0" are truthy.
function MeguruDocument:_spreadAnchor()
    local value = self.configurable and self.configurable.spread_offset
    if value == true then
        return 1
    end
    local anchor = tonumber(value)
    if not anchor or anchor < 1 then
        return 0
    end
    return math.floor(anchor)
end

-- Flexible gutter row (default on); nil means yes; compared (0 is truthy).
function MeguruDocument:_spreadGutterOn()
    local value = self.configurable and self.configurable.spread_gutter
    if value == nil then
        return true
    end
    return value == 1 or value == "1" or value == true
end

-- Whether the fit limits the pair by width (no room for Spread.grow).
function MeguruDocument:_spreadFitByWidth()
    local configurable = self.configurable
    local genus = configurable and tonumber(configurable.zoom_mode_genus)
    local kind = configurable and tonumber(configurable.zoom_mode_type)
    return not (genus == 3 and (kind == 2 or kind == 0))
end

-- Whether the offset covers this page's run; a wide page ends it by itself.
function MeguruDocument:spreadOffsetHere(pageno)
    local anchor = self:_spreadAnchor()
    if anchor <= 0 then
        return false
    end
    return Spread.runStart(anchor, self.wide_list)
        == Spread.runStart(pageno or 0, self.wide_list)
end

-- Unit shown: nil, {a=n} alone, or {a=n,b=m}; a pair needs both pages decoded.
function MeguruDocument:spreadUnitFor(pageno)
    if not self:spreadActive() then
        return nil
    end
    local count = self.info and self.info.number_of_pages
    if not count then
        return nil
    end
    local unit = Spread.unitFor(pageno, count, self.wide_list, self:_spreadAnchor())
    if unit and unit.b and not self.dims[unit.b] then
        return { a = unit.a }
    end
    return unit
end

-- Pair's pages in screen order, left first (RTL puts the earlier on the right).
function MeguruDocument:_pairSides(pair)
    if self.spread_rtl then
        return pair.b, pair.a
    end
    return pair.a, pair.b
end

-- Which page of the on-screen spread a point is in; drawPage's split inverse.
function MeguruDocument:spreadPageAt(pageno, x, y)
    local pair = self:spreadUnitFor(pageno)
    if not (pair and pair.b) then
        return pageno, x, y
    end
    local layout = self:_pairLayout(pair)
    local left, right = layout.left, layout.right
    -- A press on the blank gutter counts for the page whose margin it is.
    local seam = left.box.w * left.scale
    if x >= seam then
        return right.page, (x - seam) / right.scale + right.box.x,
            y / right.scale + right.box.y
    end
    return left.page, x / left.scale + left.box.x, y / left.scale + left.box.y
end

-- One page's content box; a degenerate box means the whole page.
function MeguruDocument:_pageBox(pageno)
    local geom = self:_pageGeom(pageno)
    local box = self:getPageBBox(pageno)
    if not (box and box.x1 and box.y1) or box.x0 >= box.x1 or box.y0 >= box.y1 then
        return { x = 0, y = 0, w = geom.w, h = geom.h }
    end
    return {
        x = box.x0,
        y = box.y0,
        w = box.x1 - box.x0,
        h = box.y1 - box.y0,
    }
end

-- Screen a pair is laid out against; the rotated surface, so landscape fits.
function MeguruDocument:_spreadScreen()
    local canvas = CanvasContext:getSize()
    if canvas and canvas.w and canvas.h and canvas.w > 0 and canvas.h > 0 then
        return { w = canvas.w, h = canvas.h }
    end
    return { w = Screen:getWidth(), h = Screen:getHeight() }
end

-- Pair's halves as drawn; the one place the pair's geometry is decided.
function MeguruDocument:_pairLayout(pair)
    local left_page, right_page = self:_pairSides(pair)
    local l, r = self:_pageBox(left_page), self:_pageBox(right_page)
    local screen = self:_spreadScreen()

    local scales = { left = 1, right = 1 }
    if not (self.dead_pages[left_page] or self.dead_pages[right_page]
        or self.fetch_failed[left_page] or self.fetch_failed[right_page]) then
        scales = Spread.grow(l.w, l.h, r.w, r.h,
            screen.w, screen.h, self:_spreadFitByWidth())
    end

    -- Gutter off: pair as crop and growth left it; measured at drawn scales.
    local gutter = { left = 0, right = 0 }
    if self:_spreadGutterOn() then
        local sl, sr = scales.left, scales.right
        local paper = Spread.gutter(
            l.w * sl + r.w * sr,
            math.max(l.h * sl, r.h * sr),
            math.max(0, self:_pageGeom(left_page).w - (l.x + l.w)) * sl,
            math.max(0, r.x) * sr,
            screen.w, screen.h)
        gutter = { left = paper.left / sl, right = paper.right / sr }
    end

    local left = { x = l.x, y = l.y, w = l.w + gutter.left, h = l.h }
    local right = { x = r.x - gutter.right, y = r.y, w = r.w + gutter.right, h = r.h }

    return {
        left = { page = left_page, box = left, scale = scales.left },
        right = { page = right_page, box = right, scale = scales.right },
        w = left.w * scales.left + right.w * scales.right,
        h = math.max(left.h * scales.left, right.h * scales.right),
    }
end

-- Pair's content box (what drawPage splits); stays inside the full-pages box.
function MeguruDocument:_pairGeom(pair)
    local layout = self:_pairLayout(pair)
    return Geom:new{ x = 0, y = 0, w = layout.w, h = layout.h }
end

-- Pair's full box at the drawn scales; the fit's ceiling; not memoised.
function MeguruDocument:_pairFullGeom(pair)
    local layout = self:_pairLayout(pair)
    local a = self:_pageGeom(layout.left.page)
    local b = self:_pageGeom(layout.right.page)
    return {
        w = a.w * layout.left.scale + b.w * layout.right.scale,
        h = math.max(a.h * layout.left.scale, b.h * layout.right.scale),
    }
end

-- Note a page wider than tall; only where getPageDims really decodes.
function MeguruDocument:_noteWide(pageno, dims)
    if not (dims and dims.w and dims.h and dims.w > dims.h) then
        return
    end
    local list = self.wide_list
    local n = #list
    if n > 0 and list[n] == pageno then
        return
    end
    if n == 0 or list[n] < pageno then
        list[n + 1] = pageno
        return
    end
    -- Out of order: warm-ahead may learn later pages; keep it ascending.
    local i = n
    while i >= 1 and list[i] > pageno do
        i = i - 1
    end
    if i >= 1 and list[i] == pageno then
        return
    end
    table.insert(list, i + 1, pageno)
end

-- Is this one page wider than tall? Not getNativePageDimensions (a pair).
function MeguruDocument:pageIsWide(pageno)
    local geom = self:_pageGeom(pageno)
    return geom.w > geom.h
end

-- Warm the page the pairing needs, keeping the fetch out of the layout pass.
function MeguruDocument:prepareSpread(pageno)
    if not self:spreadActive() then
        return false
    end
    local count = self.info and self.info.number_of_pages
    if not (count and pageno and pageno >= 1 and pageno <= count) then
        return false
    end
    if not self.local_cbz and not self:hasConnection() then
        return false
    end
    local warmed = false
    local candidates = { pageno + 1 }
    if self:spreadOffsetHere(pageno) then
        -- The offset pairs backwards, but only in its own run.
        candidates[#candidates + 1] = pageno - 1
    end
    for _, target in ipairs(candidates) do
        if target >= 1 and target <= count and not self.dims[target]
            and not self.dead_pages[target] then
            -- pcall: a throw here must cost a pair, not the page turn.
            pcall(self.getPageDims, self, target)
            pcall(self.analyseAhead, self, target)
            warmed = true
        end
    end
    return warmed
end

-- Where a page change lands with a pair shown; turn vs landing (see the doc).
function MeguruDocument:spreadSnap(number, current, turn)
    if not self:spreadActive() then
        return number, false
    end
    local count = self.info and self.info.number_of_pages
    number = math.floor(tonumber(number) or 0)
    current = tonumber(current) or 0
    if number < 1 then
        return number, false
    end
    if count and number > count then
        number = count
    end
    local anchor = self:_spreadAnchor()
    local here = self:spreadUnitFor(current)
    local there = self:spreadUnitFor(number)
    if turn and here and there and here.a == there.a and current ~= number then
        local target
        if number >= current then
            target = Spread.nextStart(current, count, self.wide_list, anchor)
        else
            target = Spread.prevStart(current, count, self.wide_list, anchor)
        end
        if target then
            return target, false
        end
        -- No unit that way: backwards spent; forwards is the end.
        return current, number >= current
    end
    return (there and there.a) or number, false
end

-- Page size as the reader asks: full pair, else one page; getZoom's ceiling.
function MeguruDocument:getNativePageDimensions(pageno)
    local pair = self:spreadUnitFor(pageno)
    if pair and pair.b then
        local geom = self:_pairFullGeom(pair)
        return Geom:new{ w = geom.w, h = geom.h }
    end
    local dims = self:getPageDims(pageno)
    return Geom:new{ w = dims.w, h = dims.h }
end

-- Pair's cropped box: getPageArea's no-bbox half, drawPage's space.
function MeguruDocument:getPageDimensions(pageno, zoom, rotation)
    local pair = self:spreadUnitFor(pageno)
    if pair and pair.b then
        return self:transformRect(self:_pairGeom(pair), zoom, rotation)
    end
    return Document.getPageDimensions(self, pageno, zoom, rotation)
end

-- Its bbox twin; both getPageArea halves must answer the same box.
function MeguruDocument:getUsedBBoxDimensions(pageno, zoom, rotation)
    local pair = self:spreadUnitFor(pageno)
    if pair and pair.b then
        return self:transformRect(self:_pairGeom(pair), zoom, rotation)
    end
    return base_get_used_bbox_dimensions(self, pageno, zoom, rotation)
end

-- Used-BBox is the full page; the crop lives only in getPageBBox's bbox.
function MeguruDocument:getUsedBBox(pageno)
    local dims = self:getPageDims(pageno)
    return { x0 = 0, y0 = 0, x1 = dims.w, y1 = dims.h }
end

-- Bbox the crop goes through; this seam is ours (takeBackPageBBox restores it).
function MeguruDocument:getPageBBox(pageno)
    -- The memos come from the rendered page, so a tone change invalidates them.
    self:syncTone()
    local bbox = self:_basePageBBox(pageno)
    if not bbox or self._meguru_pagenum_analysis_flag then
        -- Mirrors pagenumbercrop's guard against analysis re-entry.
        return bbox
    end
    local c = self.configurable
    if not c or c.text_wrap == 1 or c.trim_page ~= 1 then
        -- "Crop" at "none": the only gate the two rules below have.
        return bbox
    end
    -- Blank pages stay uncropped; asked before the strip to spare the render.
    if self:_meguruPageMostlyBlank(pageno) then
        local page_size = self:_pageGeom(pageno)
        return { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
    end
    local crop_y = self:_meguruPagenumStrip(pageno)
    if crop_y and crop_y > bbox.y0 and crop_y < bbox.y1 then
        -- These rules measure a printed page; a pair's box shifts the strip.
        local page_size = self:_pageGeom(pageno)
        local min_removal = page_size and math.max(1, page_size.h * 0.001) or 1
        if bbox.y1 - crop_y >= min_removal then
            local out = { x0 = bbox.x0, y0 = bbox.y0, x1 = bbox.x1, y1 = bbox.y1 }
            out.y1 = crop_y
            return out
        end
    end
    return bbox
end

-- Restore the crop seam from pagenumbercrop; empty its memos, not remove them.
function MeguruDocument:takeBackPageBBox()
    if rawget(self, "getPageBBox") == nil then
        return false
    end
    self.getPageBBox = nil
    self._pagenum_cache = {}
    self._pagenum_blank_cache = {}
    return true
end

-- Plain margin/full-page box; a fresh table each call (the base seam mutates).
function MeguruDocument:_basePageBBox(pageno)
    local configurable = self.configurable
    if configurable and configurable.trim_page == 1 then
        local crop = self:autoContentBox(pageno)
        if crop then
            return { x0 = crop.x0, y0 = crop.y0, x1 = crop.x1, y1 = crop.y1 }
        end
    end
    local dims = self:getPageDims(pageno)
    return { x0 = 0, y0 = 0, x1 = dims.w, y1 = dims.h }
end

-- Compute/cache the auto content box; no extra fetch; nil caches as no-margin.
function MeguruDocument:autoContentBox(pageno)
    local cached = self.crops[pageno]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    self:getPageDims(pageno) -- decodes & caches the native page into the LRU
    local item = self.native[pageno]
    if not (item and item.bb and item.bb_free ~= true) then
        return nil
    end
    local bb = item.bb
    local box = computeContentBox(bb, bb:getWidth(), bb:getHeight(), pageno)
    -- Cache false for "nothing trimmed", so a full-bleed page is scanned once.
    self.crops[pageno] = box or false
    return box
end

-- Margin colour of the trim, or nil; filled here so the first paint is right.
function MeguruDocument:cropMarginColor(pageno)
    if self.crops[pageno] == nil then
        self:autoContentBox(pageno)
    end
    local box = self.crops[pageno]
    if type(box) ~= "table" or not box.color then
        return nil
    end
    return box.color
end

-- The two finer crops, ported as _meguru*; consulted only from getPageBBox.

local MEGURU_BLANK_RENDER_MAX_PX = 256
local MEGURU_BLANK_MAX_CONTENT_AREA = 0.10

-- Margin polarity: light or dark; median of three bottom columns; safe default.
local function meguruMarginIsDark(bb, w, h, mid)
    if not w or not h or w < 16 or h < 4 then
        return false
    end
    local samples = {}
    for y = h - 1, math.max(0, h - 1 - math.floor(h * 0.08)), -1 do
        samples[#samples + 1] = bb:getPixel(0, y):getColor8().a
        samples[#samples + 1] = bb:getPixel(8, y):getColor8().a
        samples[#samples + 1] = bb:getPixel(w - 1, y):getColor8().a
    end
    table.sort(samples)
    return samples[math.max(1, math.floor(#samples * 0.5))] < mid
end

-- Bottom-strip page-number analysis, ported with three documented deviations.
local function meguruAnalyzeStrip(bb, y_start_override)
    local w, h = bb:getWidth(), bb:getHeight()
    if not w or not h or w < 20 or h < 40 then
        return 0, "tiny page"
    end

    local y_start = y_start_override
        or math.max(0, math.floor(h * (1 - 0.15)))

    local ink_threshold = 0.002
    local dark_threshold = 128
    local x_step = 2

    local ink_is_dark = not meguruMarginIsDark(bb, w, h, dark_threshold)

    local function isInk(color)
        local a = color:getColor8().a
        if ink_is_dark then
            return a < dark_threshold
        end
        return a >= dark_threshold
    end

    local ink = {}
    local span = {}
    local cols = math.ceil(w / x_step)
    local function scanRow(y)
        local count = 0
        local xmin, xmax = w, -1
        for x = 0, w - 1, x_step do
            if isInk(bb:getPixel(x, y)) then
                count = count + 1
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
            end
        end
        ink[y] = count / cols
        span[y] = (xmax >= xmin) and (xmax - xmin + 1) or 0
    end
    local function inkAt(y)
        if ink[y] == nil then
            scanRow(y)
        end
        return ink[y]
    end

    local max_row_ink = 0.30
    local max_band_span = w * 0.60
    local max_big_band_h = math.max(3, h * 0.15)
    local min_gutter_h = math.max(1, math.floor(h * 0.01))
    local min_band_span = math.max(3, math.floor(w * 0.005))
    -- Scale-invariant, so a wide band stays wide at fallback zoom.
    local max_number_span = w * 0.12

    -- Skip the empty run at the very bottom of the page.
    local y = h - 1
    while y >= y_start and inkAt(y) <= ink_threshold do
        y = y - 1
    end
    if y < y_start then
        return 0, "no ink at the bottom"
    end

    -- Walk ink bands from the bottom up.
    local bands = {}
    local descr = {}
    -- A too-wide band refuses the strip; panel_bottom marks an artwork stop.
    local saw_wide_band = false
    local panel_bottom
    while y >= y_start do
        local bottom = y
        local top = y
        local b_ink, b_span = 0, 0
        local panel_like = false
        while y >= y_start and inkAt(y) > ink_threshold do
            top = y
            if ink[y] > b_ink then b_ink = ink[y] end
            if span[y] > b_span then b_span = span[y] end
            if not panel_like and (b_ink > max_row_ink or b_span > max_band_span) then
                -- Artwork reaches the bottom: this is not a page-number band.
                panel_like = true
                y = y - 1
                break
            end
            y = y - 1
        end

        local h_str = tostring(bottom - top + 1)
        if panel_like then h_str = ">=" .. h_str end
        table.insert(descr, string.format("h=%s ink=%.2f span=%d%%%s",
            h_str, b_ink, math.floor(b_span / w * 100), panel_like and " PANEL" or ""))

        if b_span >= min_band_span then
            if panel_like then
                local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
                if saw_wide_band then
                    -- Text under artwork: nothing here a crop may discard.
                    return 0, "text in the bottom margin [" .. detail .. "]"
                end
                if #bands == 0 then
                    return 0, "panel reaches the bottom [" .. detail .. "]"
                end
                -- Under-artwork bands are number-shaped; run the usual tests.
                panel_bottom = bottom
                break
            end
            if b_span > max_number_span then
                -- Too wide for a number: page text, not furniture to cut.
                saw_wide_band = true
            else
                table.insert(bands, { top = top, bottom = bottom, row_ink = b_ink, span = b_span })
            end
        end

        while y >= y_start and inkAt(y) <= ink_threshold do
            y = y - 1
        end
    end

    local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
    if #bands == 0 then
        return 0, "only noise bands [" .. detail .. "]", true
    end
    if saw_wide_band then
        -- Wide band: no crop and no fallback (the span is a page fraction).
        return 0, "text in the bottom margin [" .. detail .. "]"
    end
    local first = bands[1]

    -- One number often renders as a few digit bands with sub-gutter gaps.
    local stack_top = first.top
    local prev_top = first.top
    for i = 2, #bands do
        local gap = prev_top - bands[i].bottom - 1
        if gap <= math.max(min_gutter_h, h * 0.02) then
            stack_top = bands[i].top
            prev_top = bands[i].top
        else
            break
        end
    end
    local band_h = first.bottom - stack_top + 1

    -- The clean gutter above the stack is the cut: number from page.
    local gutter_len = 0
    local yy = stack_top - 1
    while yy >= y_start and ink[yy] <= ink_threshold do
        gutter_len = gutter_len + 1
        yy = yy - 1
    end

    local fallback_detail = string.format("band_h=%d row_ink=%.2f span=%d%% gutter=%dpx",
        band_h, first.row_ink, math.floor(first.span / w * 100), gutter_len)

    -- One allowance, glued or not: the port flipped between decodes.
    if band_h > max_big_band_h then
        return 0, "band too tall (" .. band_h .. " px) [" .. fallback_detail .. "]"
    end

    -- Content above the band; skip the scan where the walk found artwork.
    local has_content = panel_bottom ~= nil
    if not has_content then
        for ry = y_start, math.max(y_start, yy) do
            if ink[ry] > ink_threshold then
                has_content = true
                break
            end
        end
    end
    if not has_content then
        return 0, "no content above the band [" .. fallback_detail .. "]"
    end

    -- The artwork cut is its own bottom edge, returned unchanged.
    local crop_y = panel_bottom or (stack_top - gutter_len)
    local log_detail = string.format("crop_y=%d %s", crop_y, fallback_detail)
    return crop_y, log_detail
end

-- Mostly-blank check (<10% content); content is what departs from the margin.
local function meguruPageMostlyBlank(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if not w or not h or w < 20 or h < 20 then
        return false
    end

    local dark_threshold = 128
    local margin_is_dark = meguruMarginIsDark(bb, w, h, dark_threshold)
    local x_step, y_step = 2, 2
    local total_area = w * h
    local max_blank_area = MEGURU_BLANK_MAX_CONTENT_AREA * total_area

    local found = false
    local xmin, ymin, xmax, ymax = w, h, -1, -1
    for y = 0, h - 1, y_step do
        for x = 0, w - 1, x_step do
            local a = bb:getPixel(x, y):getColor8().a
            if (margin_is_dark and a >= dark_threshold)
                or (not margin_is_dark and a < dark_threshold) then
                found = true
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
                if y < ymin then ymin = y end
                if y > ymax then ymax = y end
                -- Early exit: content already spans >= 10% of the page.
                if (xmax - xmin + 1) * (ymax - ymin + 1) >= max_blank_area then
                    return false
                end
            end
        end
    end
    if not found then
        return true
    end
    local content_area = (xmax - xmin + 1) * (ymax - ymin + 1) / total_area
    return content_area < MEGURU_BLANK_MAX_CONTENT_AREA
end

-- Ensure the per-page analysis memos exist on `self`.
local function meguruPagenumCaches(self)
    if self._meguru_pagenum_cache == nil then
        self._meguru_pagenum_cache = {}
        self._meguru_pagenum_blank_cache = {}
        self._meguru_pagenum_history = {}
    end
end

-- Render an analysis rectangle, or nil; no tile LRU; zoom vertical, x at 1:1.
function MeguruDocument:_meguruAnalysisBB(pageno, x, y, w, h, zoom)
    self._meguru_pagenum_analysis_flag = true
    local ok, bb = pcall(function()
        if self.dead_pages[pageno] then
            return nil -- a doomed page is never decoded again
        end
        local dims = self:getPageDims(pageno)
        if not (dims and dims.w > 0 and dims.h > 0) then
            return nil
        end
        local tw = math.max(1, math.floor(w * math.min(zoom, 1.0) + 0.5))
        local th = math.max(1, math.floor(h * zoom + 0.5))
        -- data is only for the decode path; nil is expected, render still runs.
        local data
        if not self.local_cbz and not self:hasNative(pageno) then
            data = self:fetchPage(pageno)
            if not data then
                return nil
            end
        end
        return self:decodeRegion(pageno, x, y, w, h, tw, th, data)
    end)
    self._meguru_pagenum_analysis_flag = false
    if ok and bb then
        return bb
    end
    return nil
end

-- Bottom-15% strip: the page-number band's top, or 0; ported from the plugin.
function MeguruDocument:_meguruPagenumStrip(pageno)
    meguruPagenumCaches(self)
    local cached = self._meguru_pagenum_cache[pageno]
    if cached ~= nil then
        return cached
    end
    self._meguru_pagenum_cache[pageno] = 0 -- "no verdict yet" mark
    local page_size = self:_pageGeom(pageno)
    if not (page_size and page_size.w > 0 and page_size.h > 0) then
        logger.dbg("Meguru: page", pageno, "no page number [no render: page size]")
        return 0
    end

    local strip_h_nat = math.max(1, math.floor(page_size.h * 0.15))
    local strip_y0_nat = page_size.h - strip_h_nat

    local function renderAndAnalyze(zoom)
        local bb = self:_meguruAnalysisBB(pageno, 0, strip_y0_nat,
            page_size.w, strip_h_nat, zoom)
        if not bb then
            return 0, "render returned no tile", false
        end
        local ok, rel_y, rel_detail, rel_suspicious = pcall(meguruAnalyzeStrip, bb, 0)
        bb:free()
        if not ok or type(rel_y) ~= "number" then
            return 0, "analysis error", false
        end
        if rel_y > 0 then
            rel_y = strip_y0_nat + rel_y / zoom -- strip pixels -> native page y
        end
        return rel_y, rel_detail or "", rel_suspicious or false
    end

    local zoom_fast = math.min(700 / strip_h_nat, 2.0)
    local crop_y, detail, suspicious = renderAndAnalyze(zoom_fast)
    local used_fallback = false

    if crop_y == 0 and suspicious then
        -- Only noise bands at the fast zoom: the number needs more rows.
        local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
        local crop_y2, detail2 = renderAndAnalyze(zoom_fallback)
        used_fallback = true
        if crop_y2 > 0 then
            crop_y, detail = crop_y2, detail2 .. " [fallback zoom]"
        else
            detail = detail .. " | fallback zoom: " .. detail2
        end
    end

    if crop_y > 0 then
        -- Cross-page sanity: an outlier band is re-checked, then dropped.
        local history = self._meguru_pagenum_history
        local frac = crop_y / page_size.h
        if #history >= 3 then
            local sorted = {}
            for _, f in ipairs(history) do
                sorted[#sorted + 1] = f
            end
            table.sort(sorted)
            local median = sorted[math.ceil(#sorted / 2)]
            local tolerance = 0.03
            if math.abs(frac - median) > tolerance then
                if not used_fallback then
                    local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
                    local crop_y2, detail2 = renderAndAnalyze(zoom_fallback)
                    local frac2 = crop_y2 > 0 and (crop_y2 / page_size.h) or nil
                    if frac2 and math.abs(frac2 - median) <= tolerance then
                        crop_y, detail, frac = crop_y2,
                            detail2 .. " [fallback zoom, matched history]", frac2
                    else
                        crop_y = 0
                    end
                else
                    crop_y = 0
                end
            end
        end
        if crop_y > 0 then
            table.insert(history, frac)
            if #history > 30 then
                table.remove(history, 1)
            end
        end
    end

    if crop_y > 0 then
        logger.dbg("Meguru: page", pageno, "page-number crop y =",
            string.format("%.1f", crop_y))
    else
        logger.dbg("Meguru: page", pageno, "no page number [", detail, "]")
    end
    self._meguru_pagenum_cache[pageno] = crop_y
    return crop_y
end

-- Mostly-blank check (<10% content); such a page is left entirely uncropped.
function MeguruDocument:_meguruPageMostlyBlank(pageno)
    meguruPagenumCaches(self)
    local cached = self._meguru_pagenum_blank_cache[pageno]
    if cached ~= nil then
        return cached
    end
    self._meguru_pagenum_blank_cache[pageno] = false
    local page_size = self:_pageGeom(pageno)
    if not (page_size and page_size.w > 0 and page_size.h > 0) then
        logger.dbg("Meguru: page", pageno, "blank check skipped [no render: page size]")
        return false
    end
    local zoom = math.min(
        MEGURU_BLANK_RENDER_MAX_PX / page_size.w,
        MEGURU_BLANK_RENDER_MAX_PX / page_size.h,
        1.0)
    local bb = self:_meguruAnalysisBB(pageno, 0, 0, page_size.w, page_size.h, zoom)
    if not bb then
        return false
    end
    local ok, mostly_blank = pcall(meguruPageMostlyBlank, bb)
    bb:free()
    if ok and type(mostly_blank) == "boolean" then
        self._meguru_pagenum_blank_cache[pageno] = mostly_blank
        if mostly_blank then
            logger.dbg("Meguru: page", pageno, "mostly blank -> no crop")
        end
        return mostly_blank
    end
    return false
end

-- drawPagePart writes and releasePanelTile frees: the two must agree exactly.
local function panelTileKey(pageno, rect, tw, th)
    local key = string.format("%d|panel|%d,%d+%dx%d",
        pageno, rect.x, rect.y, rect.w, rect.h)
    if tw and th then
        key = string.format("%s|%dx%d", key, tw, th)
    end
    local planes = rect.planes
    if planes then
        for i = 1, #planes do
            key = string.format("%s|%d,%d", key,
                math.floor(planes[i].A * 1000), math.floor(planes[i].B * 1000))
        end
    end
    return key
end

-- Page's decoded native, fetching if evicted; both panel entries start here.
local function panelNativeFor(doc, pageno)
    local data
    if not doc.local_cbz and not doc:hasNative(pageno) then
        data = doc:fetchPage(pageno)
        if not data then
            return nil
        end
    end
    return doc:ensureNativeBB(pageno, data)
end

-- Panel-list cache (4 entries); self-ordering, and keyed by reading direction.
local function panelCacheKey(pageno, manga)
    return string.format("%d|%s", pageno, manga and "m" or "c")
end

-- A hit moves the entry to the front; a miss is nil.
local function readCachedPanels(doc, key)
    local cache = doc.panels
    if not cache then
        return nil
    end
    for i, item in ipairs(cache) do
        if item.key == key then
            if i > 1 then
                table.remove(cache, i)
                table.insert(cache, 1, item)
            end
            return item
        end
    end
    return nil
end

-- Store the answer and trim the tail; a refusal is a real answer, so cache it.
local function cachePanels(doc, key, panels, accepted, reason)
    if not doc.panels then
        doc.panels = {}
    end
    table.insert(doc.panels, 1, {
        key = key,
        panels = panels,
        accepted = accepted,
        reason = reason,
    })
    while #doc.panels > doc.max_cached_panels do
        table.remove(doc.panels)
    end
end

-- All panels on a page in reading order; never nil for a readable page.
function MeguruDocument:getPanelsFromPage(pageno, manga)
    -- Panels come from the rendered page, so a tone change drops them.
    self:syncTone()
    local key = panelCacheKey(pageno, manga)
    local hit = readCachedPanels(self, key)
    if hit then
        return hit.panels, hit.accepted, hit.reason
    end
    local native_bb = panelNativeFor(self, pageno)
    if not native_bb then
        return nil, false, "page could not be decoded"
    end
    local panels, accepted, reason = Panel.detect(native_bb, manga)
    if panels then
        cachePanels(self, key, panels, accepted, reason)
    end
    return panels, accepted, reason
end

-- Drop the tile a panel render left; keeps the shared 8-entry LRU for pages.
function MeguruDocument:releasePanelTile(pageno, rect, tw, th)
    if not rect then
        return false
    end
    local key = panelTileKey(pageno, rect, tw, th)
    local tile = self.tiles[key]
    if not tile then
        return false
    end
    self.tiles[key] = nil
    self.stamps[key] = nil
    if tile.bb and tile.bb_free ~= true then
        tile.bb:free()
        tile.bb_free = true
    end
    return true
end

-- Panel under a touch, for stock's onPanelZoom (a missing method would crash).
function MeguruDocument:getPanelFromPage(pageno, pos)
    if not pos then
        return nil
    end
    local px, py = tonumber(pos.x), tonumber(pos.y)
    if not px or not py then
        return nil
    end
    local dims = self:getPageDims(pageno)
    if px < 0 or py < 0 or px >= dims.w or py >= dims.h then
        return nil
    end
    local panels = self:getPanelsFromPage(pageno, false)
    if not panels then
        return nil
    end
    local index = Panel.indexAt(panels, px, py)
    return index and panels[index] or nil
end

-- One line per prepared page; the fetch field is absent for a local cbz.
function MeguruDocument:_logPrepared(pageno, dims, t_start, fetch_ms, decode_ms)
    logger.dbg(string.format(
        "Meguru: page %d prepared in %d ms%s (decode %d ms, %dx%d)",
        pageno, nowMs() - t_start,
        fetch_ms and string.format(", fetch %d ms", fetch_ms) or "",
        decode_ms or 0, dims.w, dims.h))
end

function MeguruDocument:getPageDims(pageno)
    -- A tone change invalidates the decode this is about to make.
    self:syncTone()
    local cached = self.dims[pageno]
    if cached then
        return cached
    end
    -- What a page turn waits for: fetch then decode; size is the capped native.
    if self.local_cbz then
        -- One capped archive render feeds geometry, tiles and the box scan.
        local t_start, t0 = nowMs(), nowMs()
        local native_bb = self:ensureNativeBB(pageno)
        local decode_ms = nowMs() - t0
        if not native_bb then
            local fallback = { w = Screen:getWidth(), h = Screen:getHeight() }
            self.dims[pageno] = fallback
            return fallback
        end
        local dims = {
            w = math.max(1, native_bb:getWidth()),
            h = math.max(1, native_bb:getHeight()),
        }
        self.dims[pageno] = dims
        self:_noteWide(pageno, dims)
        -- Logged before the GC below, so the parts sum to the whole.
        self:_logPrepared(pageno, dims, t_start, nil, decode_ms)
        pcall(collectgarbage, "collect")
        return dims
    end
    -- Fetched unconditionally: this is the decoder; a live native answered.
    local t_start, t0 = nowMs(), nowMs()
    local data = self:fetchPage(pageno)
    local fetch_ms = nowMs() - t0
    local fallback = { w = Screen:getWidth(), h = Screen:getHeight() }
    if not data then
        self.dims[pageno] = fallback
        return fallback
    end
    t0 = nowMs()
    -- MuPDF applies the tone while rendering, so the decode carries it.
    local res = Image.decode(data, self:contrast(), self:saturation())
    local decode_ms = nowMs() - t0
    if res == nil or res == Image.DECODE_TOO_LARGE then
        if res == Image.DECODE_TOO_LARGE then
            logger.warn(string.format(
                "Meguru: page %d is a very large lossless image that MuPDF would have to decode at full size (above the %d-Mpx safety limit); skipping it",
                pageno, Image.MAX_LOSSLESS_NATIVE_PIXELS / 1024 / 1024))
        else
            logger.warn("Meguru: cannot decode page", pageno)
        end
        self.dead_pages[pageno] = true
        self.dims[pageno] = fallback
        return fallback
    end
    local bb = res
    local dims = {
        w = math.max(1, bb:getWidth()),
        h = math.max(1, bb:getHeight()),
    }
    self.dims[pageno] = dims
    -- Only really-decoded paths note wide; failure branches cache screen size.
    self:_noteWide(pageno, dims)

    -- Keep the capped decode so every later render reuses it.
    self:cacheNative(pageno, bb)
    self:_logPrepared(pageno, dims, t_start, fetch_ms, decode_ms)
    -- Drop the local bytes reference before the GC, or they are not reclaimed.
    data = nil
    -- Collect before the next decode; tight-RAM e-ink dies otherwise.
    pcall(collectgarbage, "collect")
    return dims
end

local function round(v)
    return math.floor(v + 0.5)
end

-- Ensure a working-resolution BlitBuffer, decoding data if not in the LRU.
function MeguruDocument:ensureNativeBB(pageno, data)
    if self.dead_pages[pageno] then
        return nil -- decode already failed once (or was refused as too large)
    end
    local item = self.native[pageno]
    if item and item.bb_free ~= true then
        bump(self, pageno)
        return item.bb
    end
    self.native[pageno] = nil
    local res
    if self.local_cbz then
        -- No raw bytes: render from the archive; huge PNGs keep MuPDF's decode.
        res = Image.renderMupdfPage(self.mupdf_doc, pageno, nil,
            self:contrast(), self:saturation())
    else
        res = Image.decode(data, self:contrast(), self:saturation())
    end
    if res == nil or res == Image.DECODE_TOO_LARGE then
        -- Remember it: the same bytes fail identically; no retry per paint.
        if res == Image.DECODE_TOO_LARGE then
            logger.warn(string.format(
                "Meguru: page %d skipped: its lossless source is above the %d-Mpx decode safety limit",
                pageno, Image.MAX_LOSSLESS_NATIVE_PIXELS / 1024 / 1024))
        else
            logger.warn("Meguru: decode failed for page", pageno)
        end
        self.dead_pages[pageno] = true
        return nil
    end
    self:cacheNative(pageno, res)
    return res
end

-- OCR needs the page at native size; a stream may not have decoded it yet.
function MeguruDocument:_ocrPageBB(pageno)
    if self:hasNative(pageno) or self.local_cbz then
        return self:ensureNativeBB(pageno)
    end
    local data = self:fetchPage(pageno)
    if not data then
        return nil
    end
    return self:ensureNativeBB(pageno, data)
end

-- Crop the page into a KOPT source bitmap: the engine takes pixels, not a document.
function MeguruDocument:_fillOcrContext(pageno, kc, bb)
    bb = bb or self:_ocrPageBB(pageno)
    if not bb then
        error("Meguru: page " .. tostring(pageno) .. " has no image for OCR")
    end

    local x0, y0, x1, y1 = kc:getBBox()
    local zoom = kc:getZoom() or 1
    local w, h = bb:getWidth(), bb:getHeight()
    x0 = clamp(math.floor(x0), 0, w - 1)
    y0 = clamp(math.floor(y0), 0, h - 1)
    x1 = clamp(math.ceil(x1), x0 + 1, w)
    y1 = clamp(math.ceil(y1), y0 + 1, h)
    local cw, ch = x1 - x0, y1 - y0
    local sw = math.max(1, math.ceil(cw * zoom))
    local sh = math.max(1, math.ceil(ch * zoom))

    -- KOPT wants 8-bit grey; blitFrom converts from the page's own format.
    local crop = Blitbuffer.new(cw, ch, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        crop:blitFrom(bb, 0, 0, x0, y0, cw, ch)
    end)
    if not ok then
        crop:free()
        error(err)
    end

    local scaled = crop
    if sw ~= cw or sh ~= ch then
        local ok_scale, res = pcall(RenderImage.scaleBlitBuffer, RenderImage,
            crop, sw, sh, true)
        if not ok_scale or not res then
            crop:free()
            error(res or "Meguru: cannot scale the OCR crop")
        end
        scaled = res
    end

    local ok_fill, fill_err = pcall(function()
        local k2 = require("ffi/koptcontext").k2pdfopt
        local bmp = kc.src
        bmp.width, bmp.height, bmp.bpp, bmp.type = scaled.w, scaled.h, 8, 0
        assert(k2.bmp_alloc(bmp) ~= 0, "OCR bitmap allocation failed")
        for i = 0, 255 do
            bmp.red[i], bmp.green[i], bmp.blue[i] = i, i, i
        end
        local stride = k2.bmp_bytewidth(bmp)
        for y = 0, scaled.h - 1 do
            ffi.copy(bmp.data + y * stride, scaled.data + y * scaled.stride, scaled.w)
        end
        kc.page_width, kc.page_height = scaled.w, scaled.h
    end)
    scaled:free()
    if not ok_fill then
        error(fill_err)
    end
end

-- The bitmap seam Panels+ OCR (and KOPT contexts) ask the document for.
function MeguruDocument:_installOcr()
    if self._document then
        return
    end
    local ok, Kopt = pcall(require, "ffi/koptcontext")
    if not ok or type(Kopt) ~= "table" or type(Kopt.new) ~= "function" then
        return
    end
    local doc = self
    local tess
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        tess = not os.getenv("TESSDATA_PREFIX")
            and (DataStorage:getDataDir() .. "/data/tessdata") or nil
    end
    self.koptinterface = {
        tessocr_data = tess,
        createContext = function(_, _, pageno, bbox)
            local kc = Kopt.new()
            if bbox and bbox.x0 and bbox.y0 and bbox.x1 and bbox.y1 then
                kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
            else
                local dims = doc:getPageDims(pageno)
                kc:setBBox(0, 0, dims.w, dims.h)
            end
            return kc
        end,
    }
    self._document = {
        openPage = function(_, pageno)
            return {
                getSize = function()
                    local dims = doc:getPageDims(pageno)
                    return dims.w, dims.h
                end,
                getPagePix = function(_, kc)
                    doc:_fillOcrContext(pageno, kc)
                end,
                close = function() end,
            }
        end,
        close = function() end,
    }
    if self.configurable and self.configurable.doc_language == nil then
        self.configurable.doc_language = "eng"
    end
end

-- Panels+ asks with the held word; stock selection asks without it and stays nil.
function MeguruDocument:getTextBoxes(pageno, seed)
    if not (seed and seed.x and seed.y and seed.w and seed.h) then
        return nil
    end
    local bb = self:_ocrPageBB(pageno)
    if not bb then
        return nil
    end
    local w, h = bb:getWidth(), bb:getHeight()
    local margin = math.max(seed.h * 12, 120)
    local x0 = clamp(math.floor(seed.x - margin), 0, w - 1)
    local y0 = clamp(math.floor(seed.y - margin), 0, h - 1)
    local x1 = clamp(math.ceil(seed.x + seed.w + margin), x0 + 1, w)
    local y1 = clamp(math.ceil(seed.y + seed.h + margin), y0 + 1, h)

    local ok_kopt, Kopt = pcall(require, "ffi/koptcontext")
    if not ok_kopt or type(Kopt) ~= "table" or type(Kopt.new) ~= "function" then
        return nil
    end
    local kc = Kopt.new()
    kc:setBBox(x0, y0, x1, y1)
    kc:setZoom(1)
    local ok, boxes = pcall(function()
        self:_fillOcrContext(pageno, kc, bb)
        return kc:getNativeWordBoxes("src", 0, 0,
            kc.page_width, kc.page_height)
    end)
    pcall(kc.free, kc)
    if not ok or type(boxes) ~= "table" then
        return nil
    end

    -- Native word boxes take the crop's origin; Panels+ wants page coordinates.
    for _, line in ipairs(boxes) do
        line.x0, line.y0 = line.x0 + x0, line.y0 + y0
        line.x1, line.y1 = line.x1 + x0, line.y1 + y0
        for _, word in ipairs(line) do
            word.x0, word.y0 = word.x0 + x0, word.y0 + y0
            word.x1, word.y1 = word.x1 + x0, word.y1 + y0
        end
    end
    return boxes
end

-- Open a MuPDF doc for the region; a streamed page opens from the byte LRU.
function MeguruDocument:_regionSource(pageno)
    if self.local_cbz then
        return self.mupdf_doc, false, pageno
    end
    local data = self:readCachedPage(pageno)
    if not data then
        return nil, nil, nil, "no bytes cached"
    end
    local magic = Image.magicFor(data)
    if not magic then
        return nil, nil, nil, "unrecognised image type"
    end
    local ok, doc = pcall(Mupdf.openDocumentFromText, data, magic)
    if not ok or not doc then
        return nil, nil, nil, "MuPDF cannot open the bytes"
    end
    -- Same colour answer as the decode, so a region and a decode look alike.
    if doc.setColorRendering then
        doc:setColorRendering(Image.colorEnabled())
    end
    -- Page 1, always: the doc holds one page, so use 1, not the book's number.
    return doc, true, 1
end

-- Render a region into tw x th in one pass; nil with a reason if no source.
function MeguruDocument:renderRegionDirect(pageno, cx, cy, cw, ch, tw, th, planes)
    -- Load-bearing: DECODE_TOO_LARGE would OOM inside the region render too.
    if self.dead_pages[pageno] then
        return nil, "page is dead"
    end
    local doc, owned, doc_pageno, reason = self:_regionSource(pageno)
    if not doc then
        return nil, reason
    end
    -- The tone: every panel tile comes through here, so panels follow it.
    local ok, bb = pcall(Image.renderRegion, doc, doc_pageno, cx, cy, cw, ch, tw, th, planes,
        self:contrast(), self:saturation())
    if owned then
        pcall(doc.close, doc)
    end
    if not ok then
        return nil, "render raised: " .. tostring(bb)
    end
    if not bb then
        return nil, "MuPDF produced no buffer"
    end
    return bb
end

-- Panel zoom hands the region at its own size; the tile goes through the LRU.
function MeguruDocument:drawPagePart(pageno, native_rect, rotation, tw, th)
    -- Panel zoom never passes through renderPage, so refresh the tone here.
    self:syncTone()
    if not native_rect then
        return nil, false
    end
    local rect = Geom:new(native_rect)

    local rotate = false
    local g = rawget(_G, "G_reader_settings")
    if g and type(g.isTrue) == "function" and g:isTrue("imageviewer_rotate_auto_for_best_fit") then
        local canvas = CanvasContext:getSize()
        rotate = (canvas.w > canvas.h) ~= (rect.w > rect.h)
    end

    local key = panelTileKey(pageno, native_rect, tw, th)
    local cached = tileAtTone(self, key)
    if cached then
        bump(self, key)
        return cached.bb, rotate
    end

    local bb = self:renderRegionDirect(pageno, rect.x, rect.y, rect.w, rect.h,
        tw, th, native_rect.planes)
    if not bb then
        -- No bytes to render: fall back to stock (softer, but still works).
        local ok, image, fallback_rotate = pcall(Document.drawPagePart,
            self, pageno, native_rect, rotation)
        if ok and image then
            return image, fallback_rotate
        end
        logger.warn("Meguru: no panel image for page", pageno)
        return nil, rotate
    end

    -- Filter here too, before cacheTile; the stock fallback stays unfiltered.
    if self._tone_derainbow then
        bb = Derainbow.apply(bb)
    end

    local tw, th = bb:getWidth(), bb:getHeight()
    -- Steepest edge of the crop; B for vertical sides, A for horizontal.
    local tilt = 0
    local planes = native_rect.planes
    if planes then
        for i = 1, #planes do
            local a = math.abs(i <= 2 and planes[i].B or planes[i].A)
            if a > tilt then
                tilt = a
            end
        end
    end
    logger.dbg(string.format(
        "Meguru: panel zoom on page %d, region %d,%d+%dx%d tilt %.3f rendered %dx%d",
        pageno, rect.x, rect.y, rect.w, rect.h, tilt, tw, th))
    self:cacheTile(key, {
        bb = bb,
        excerpt = Geom:new{ x = 0, y = 0, w = tw, h = th },
        pageno = pageno,
        doc_path = self.file,
    })
    return bb, rotate
end

-- Decode (crop+scale) a region from the saved decode; the paint's fallback.
function MeguruDocument:decodeRegion(pageno, cx, cy, cw, ch, tw, th, data)
    local dims = self.dims[pageno] or self:getPageDims(pageno)
    local whole_page = cx <= 0 and cy <= 0 and cx + cw >= dims.w and cy + ch >= dims.h
        and cw >= dims.w and ch >= dims.h

    -- No whole-page fast path: reuse the cached native; resolution goes direct.
    local native_bb = self:ensureNativeBB(pageno, data)
    if not native_bb then
        -- Failure memoised; a whole page gets one last-resort direct decode.
        if whole_page and not self.dead_pages[pageno] and data ~= nil then
            local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, tw, th)
            if ok and bb then
                return bb
            end
            logger.warn("Meguru: decode/scale failed for page", pageno)
            self.dead_pages[pageno] = true
        end
        return nil
    end
    local fw, fh = native_bb:getWidth(), native_bb:getHeight()
    local nx0 = clamp(round(cx), 0, fw)
    local ny0 = clamp(round(cy), 0, fh)
    local nx1 = clamp(round(cx + cw), nx0 + 1, fw)
    local ny1 = clamp(round(cy + ch), ny0 + 1, fh)
    local rw = nx1 - nx0
    local rh = ny1 - ny0
    -- Non-1:1 whole page scales on the cache; the 1:1 case copies.
    local cropped
    if nx0 == 0 and ny0 == 0 and rw == fw and rh == fh
            and (tw ~= fw or th ~= fh) then
        cropped = nil
    else
        cropped = Blitbuffer.new(rw, rh, native_bb:getType())
        cropped:blitFrom(native_bb, 0, 0, nx0, ny0, rw, rh)
    end
    -- Free the cropped intermediate explicitly; only when the scaler copied.
    local ok, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage,
        cropped or native_bb, tw, th, false)
    if cropped and scaled ~= cropped then
        cropped:free()
    end
    if not ok or not scaled then
        logger.warn("Meguru: crop/scale failed for page", pageno)
        return nil
    end
    return scaled
end

function MeguruDocument:renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    -- Refresh the tone before reading a cached tile (invalidated by stamp).
    self:syncTone()
    -- gamma/saturation ignored (tone from configurable); rotation is never set.

    local safe_zoom = (zoom and zoom > 0) and zoom or 1
    local is_prescaled = rect and rect.scaled_rect ~= nil or false

    -- Work out the native crop, the tile size, and the zoomed tile origin.
    local nx, ny, nw, nh  -- native region
    local tw, th          -- output tile size
    local excerpt_x, excerpt_y

    if is_prescaled then
        -- drawPagePart: rect is a native crop; scaled_rect is the output size.
        local sr = rect.scaled_rect
        nx, ny, nw, nh = rect.x, rect.y, rect.w, rect.h
        tw, th = sr.w, sr.h
        excerpt_x, excerpt_y = 0, 0
    elseif rect then
        -- ReaderView: rect is the visible area in zoomed page coordinates.
        nx = rect.x / safe_zoom
        ny = rect.y / safe_zoom
        nw = rect.w / safe_zoom
        nh = rect.h / safe_zoom
        tw, th = rect.w, rect.h
        excerpt_x, excerpt_y = rect.x, rect.y
    else
        -- No rect: whole page at the requested zoom, from the page's own size.
        local own = self:_pageGeom(pageno)
        local page_size = self:transformRect(
            Geom:new{ w = own.w, h = own.h }, safe_zoom, rotation or 0)
        nx = page_size.x / safe_zoom
        ny = page_size.y / safe_zoom
        nw = page_size.w / safe_zoom
        nh = page_size.h / safe_zoom
        tw, th = page_size.w, page_size.h
        excerpt_x, excerpt_y = 0, 0
    end

    -- Clamp the crop to the actual page dimensions.
    local dims = self.dims[pageno] or self:getPageDims(pageno)
    local cx = clamp(round(nx), 0, dims.w)
    local cy = clamp(round(ny), 0, dims.h)
    local cx2 = clamp(round(nx + nw), cx + 1, dims.w)
    local cy2 = clamp(round(ny + nh), cy + 1, dims.h)
    local cw = cx2 - cx
    local ch = cy2 - cy
    tw = math.max(1, round(tw))
    th = math.max(1, round(th))

    -- Key captures the actual crop, not just its size; tone is a lookup stamp.
    local key = string.format("%d|%dx%d|%d,%d+%dx%d", pageno, tw, th, cx, cy, cw, ch)
    local tile = tileAtTone(self, key)
    if tile then
        bump(self, key)
        return tile
    end

    -- Magnify (tw>cw): render direct once; else slice/scale the cached decode.
    local bb
    -- A wanted direct render's failure reason travels into the log below.
    local method, why = "scale", nil
    local paint_ms
    if tw > cw or th > ch then
        local t0 = nowMs()
        local direct, reason = self:renderRegionDirect(pageno, cx, cy, cw, ch, tw, th)
        paint_ms = nowMs() - t0
        if direct then
            bb, method = direct, "direct"
        else
            why = reason
        end
    end
    if not bb then
        -- data is only for the decode path; the render must still run.
        local data
        if not self.local_cbz and not self:hasNative(pageno) then
            data = self:fetchPage(pageno)
            if not data then
                return nil
            end
        end
        local t0 = nowMs()
        bb = self:decodeRegion(pageno, cx, cy, cw, ch, tw, th, data)
        paint_ms = nowMs() - t0
    end

    -- One line per rendered tile; page = retained size; region/tile = pair.
    logger.dbg(string.format(
        "Meguru: page %d paint %s%s in %d ms (zoom %.3f, page %dx%d, region %d,%d+%dx%d, tile %dx%d)",
        pageno,
        bb and ("via " .. method) or ("FAILED (" .. method .. ")"),
        why and (" [direct failed: " .. tostring(why) .. "]") or "",
        paint_ms or 0,
        safe_zoom, dims.w, dims.h, cx, cy, cw, ch, tw, th))

    if not bb then
        return nil
    end

    -- Moire filter runs on the tile before cacheTile; analyses stay unfiltered.
    if self._tone_derainbow then
        bb = Derainbow.apply(bb)
    end

    tile = {
        bb = bb,
        excerpt = Geom:new{
            x = excerpt_x,
            y = excerpt_y,
            w = tw,
            h = th,
        },
        pageno = pageno,
        doc_path = self.file,
    }
    self:cacheTile(key, tile)
    return tile
end

-- ReaderView calls this via nextTick (post-paint) and unschedules it on close.
function MeguruDocument:hintPage(pageno, zoom, rotation, gamma, saturation)
    -- Counted from pageno; pairs want one more of lead so the partner is ready.
    local lead = self.prefetch_count
    if self:spreadActive() and lead < 2 then
        lead = 2
    end
    for i = 0, lead - 1 do
        local target = pageno + i
        if target <= self.info.number_of_pages then
            -- No prefetch for a local cbz; the analysis still applies.
            if not self.local_cbz then
                self:prefetchPage(target)
            end
            self:analyseAhead(target)
        end
    end
    return true
end

-- Warm all of getPageBBox for pageno; skipped with the crop off or offline.
function MeguruDocument:analyseAhead(pageno)
    local c = self.configurable
    if not (c and c.text_wrap ~= 1 and c.trim_page == 1) then
        return
    end
    if self.dead_pages[pageno] then
        return
    end
    if not self:hasConnection() then
        return
    end
    -- pcall: a heuristic throw must cost a crop, not the book.
    pcall(self.getPageBBox, self, pageno)
end

-- Pair drawn as two pages: split rect at the seam, one drawOnePage per half.
function MeguruDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local pair = rect and self:spreadUnitFor(pageno) or nil
    if not (pair and pair.b) then
        return self:drawOnePage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    end

    local safe_zoom = (zoom and zoom > 0) and zoom or 1
    local layout = self:_pairLayout(pair)
    local left, right = layout.left, layout.right
    -- The seam carries the gutter and growth, so the split follows the layout.
    local left_zoom = safe_zoom * left.scale
    local right_zoom = safe_zoom * right.scale
    local seam = left.box.w * left_zoom
    local x0, x1 = rect.x, rect.x + rect.w

    -- origin is where the page begins, so from-origin lands in its own coords.
    local function half(page, box, half_zoom, origin, from, to)
        local width = to - from
        if width <= 0 then
            return
        end
        -- Clip to this page's own height: the pair's box is the taller page's.
        local bottom = math.min(rect.y + rect.h, box.h * half_zoom)
        local height = bottom - rect.y
        if height <= 0 then
            return
        end
        local src = Geom:new{
            x = (from - origin) + box.x * half_zoom,
            y = rect.y + box.y * half_zoom,
            w = width,
            h = height,
        }
        self:drawOnePage(target, x + (from - x0), y, src, page, half_zoom, rotation, gamma, saturation)
    end

    half(left.page, left.box, left_zoom, 0, x0, math.min(x1, seam))
    half(right.page, right.box, right_zoom, seam, math.max(x0, seam), x1)
end

-- Like drawPage; nil renderPage paints a neutral tile; night inverts target.
function MeguruDocument:drawOnePage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma, saturation)
    if not tile then
        self:paintMissingPage(target, rect, x, y, pageno)
        return
    end
    local dx = rect.x - tile.excerpt.x
    local dy = rect.y - tile.excerpt.y
    local configurable = self.configurable
    local invert = configurable and configurable.nightmode_document == 1 and Screen.night_mode
    -- `self.sw_dithering` is the whole switch (set in init); see the doc.
    if self.sw_dithering then
        target:ditherblitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    else
        target:blitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    end
    if invert then
        target:invertRect(x, y, rect.w, rect.h)
    end
end

-- Not pair-split on purpose: nothing calls it; night mode inverts via drawPage.
function MeguruDocument:drawPageInverted(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma, saturation)
    if not tile then
        self:paintMissingPage(target, rect, x, y, pageno)
        return
    end
    local dx = rect.x - tile.excerpt.x
    local dy = rect.y - tile.excerpt.y
    -- Same forced dither as drawPage; the invert is independent of it.
    if self.sw_dithering then
        target:ditherblitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    else
        target:blitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    end
    target:invertRect(x, y, rect.w, rect.h)
end

-- A page that could not render; box here, sentence from missing_painter.
function MeguruDocument:paintMissingPage(target, rect, x, y, pageno)
    if not rect then
        return
    end
    local w = rect.w or 1
    local h = rect.h or 1
    target:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    if self.missing_painter then
        self.missing_painter(target, rect, x, y, pageno and self.fetch_failed[pageno])
    end
end

return MeguruDocument
