--[[
Panels+
File: src/_foldjoin.lua
Name: FoldJoin
Description: Finds the black strip between the two halves of a double-page spread and joins the halves without it.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Blitbuffer = require("ffi/blitbuffer")

--- Removal of the fold strip from a rendered double-page spread.
---
--- Some scans join the two pages of a spread with a solid black strip. The strip
--- is only removed when it is black over the full height, close to the centre
--- and narrow, so dark artwork across the fold is left alone.
---
--- @class PPFoldJoinModule
local FoldJoin = {}

-- Luminance below this counts as black.
local DARK_MAX = 40
-- Share of a column's sampled rows that must be black.
local DARK_SHARE = 0.97
-- The strip's centre must be this close to the image centre, as a share of the width.
local CENTRE_TOLERANCE = 0.03
-- Widest strip that is removed, as a share of the width.
local MAX_BAND_SHARE = 0.04
local MIN_BAND_PX = 2
-- Rows sampled per column.
local SAMPLE_ROWS = 200
-- A column next to the strip is part of its blurred edge when its mean luminance is below this
-- share of the column `EDGE_LOOKAHEAD` further out. At most `MAX_EDGE_TRIM` columns per side.
local EDGE_DARKER = 0.8
local EDGE_LOOKAHEAD = 3
local MAX_EDGE_TRIM = 3

--- Share of rows that are black in column `x`, and the column's mean luminance.
local function columnStats(x, height, step, sample)
    local dark, sum, total = 0, 0, 0
    for y = 0, height - 1, step do
        local value = sample(x, y)
        total = total + 1
        sum = sum + value
        if value < DARK_MAX then
            dark = dark + 1
        end
    end
    return dark / total, sum / total
end

--- Find a full-height black strip near the expected fold position.
---
--- @param width integer Image width in pixels.
--- @param height integer Image height in pixels.
--- @param sample fun(x:integer, y:integer):number Luminance (0-255) of a pixel.
--- @param opts table|nil `{ centre, reach, max_band }` in pixels. Defaults to the image centre,
---   3% of the width and 4% of the width, which fit an image of the whole spread.
--- @return integer|nil x0 First column of the strip.
--- @return integer|nil x1 Last column of the strip.
function FoldJoin.findBand(width, height, sample, opts)
    if width < 50 or height < 50 then
        return nil
    end
    opts = opts or {}
    local step = math.max(1, math.floor(height / SAMPLE_ROWS))
    local function isDark(x)
        return x >= 0 and x < width and columnStats(x, height, step, sample) >= DARK_SHARE
    end

    local centre = math.floor(opts.centre or width / 2)
    local reach = math.floor(opts.reach or width * CENTRE_TOLERANCE)
    local max_band = math.floor(opts.max_band or width * MAX_BAND_SHARE)
    local seed
    for offset = 0, reach do
        if isDark(centre + offset) then
            seed = centre + offset
            break
        elseif isDark(centre - offset) then
            seed = centre - offset
            break
        end
    end
    if not seed then
        return nil
    end

    local x0, x1 = seed, seed
    while isDark(x0 - 1) do
        x0 = x0 - 1
        if x1 - x0 + 1 > max_band then
            return nil
        end
    end
    while isDark(x1 + 1) do
        x1 = x1 + 1
        if x1 - x0 + 1 > max_band then
            return nil
        end
    end
    -- A strip that reaches the image edge is a dark border, not a fold.
    if x0 <= 0 or x1 >= width - 1 then
        return nil
    end
    if x1 - x0 + 1 < MIN_BAND_PX or math.abs((x0 + x1) / 2 - centre) > reach then
        return nil
    end
    return x0, x1
end

--- Join the two sides of a rendered image without its fold strip.
---
--- The strip's edges are blurred by scaling, so columns next to it that are much darker than the
--- artwork beyond them are removed as well. The result has the size of the source, with the two
--- sides centred on white. The viewer then shows it at the same scale, without resampling.
---
--- @param bb table Rendered blitbuffer.
--- @param opts table|nil Expected fold position, see `findBand`.
--- @return table|nil joined New blitbuffer, or `nil` when there is no strip.
--- @return table|nil fold `{ u0, u1, pad }` as shares of the width: the removed range, and the
---   white margin at each end of the joined image.
function FoldJoin.joinBitmap(bb, opts)
    local width, height = bb:getWidth(), bb:getHeight()
    local function sample(x, y)
        return bb:getPixel(x, y):getColor8().a
    end
    local x0, x1 = FoldJoin.findBand(width, height, sample, opts)
    if not x0 then
        return nil
    end

    local step = math.max(1, math.floor(height / SAMPLE_ROWS))
    local function meanLuminance(x)
        local _, mean = columnStats(x, height, step, sample)
        return mean
    end
    local function isBlurred(x, beyond)
        if x < 1 or x > width - 2 or beyond < 0 or beyond > width - 1 then
            return false
        end
        return meanLuminance(x) < EDGE_DARKER * meanLuminance(beyond)
    end
    for _ = 1, MAX_EDGE_TRIM do
        if isBlurred(x0 - 1, x0 - 1 - EDGE_LOOKAHEAD) then
            x0 = x0 - 1
        end
        if isBlurred(x1 + 1, x1 + 1 + EDGE_LOOKAHEAD) then
            x1 = x1 + 1
        end
    end

    local removed = x1 - x0 + 1
    local pad = math.floor(removed / 2)
    local right_w = width - x1 - 1
    local joined = Blitbuffer.new(width, height, bb:getType())
    joined:fill(Blitbuffer.COLOR_WHITE)
    joined:blitFrom(bb, pad, 0, 0, 0, x0, height)
    joined:blitFrom(bb, pad + x0, 0, x1 + 1, 0, right_w, height)
    return joined, { u0 = x0 / width, u1 = (x1 + 1) / width, pad = pad / width }
end

--- Map a horizontal position in the joined image to the source image.
---
--- @param u number Position in the joined image, 0 to 1.
--- @param fold table|nil Fold from `joinBitmap`.
--- @return number u Position in the source image, 0 to 1.
function FoldJoin.toSourceU(u, fold)
    if not fold then
        return u
    end
    local source = u - fold.pad
    if source >= fold.u0 then
        source = source + (fold.u1 - fold.u0)
    end
    return math.max(0, math.min(1, source))
end

--- Map a horizontal position in the source image to the joined image.
---
--- @param u number Position in the source image, 0 to 1.
--- @param fold table|nil Fold from `joinBitmap`.
--- @return number u Position in the joined image, 0 to 1.
function FoldJoin.toJoinedU(u, fold)
    if not fold then
        return u
    end
    if u >= fold.u1 then
        u = u - (fold.u1 - fold.u0)
    elseif u > fold.u0 then
        u = fold.u0
    end
    return u + fold.pad
end

return FoldJoin
