--[[
Drawing something turned: a text box at an angle (see ink/text.lua). The thing
is drawn upright in its own frame, onto a copy of the page under it as that
frame sees it, then put back on the page turned. Only the pixels the drawing
changed go back, so the page around and under it is never resampled: a quarter
turn is exact, any other angle is smoothed (bilinear) at the drawn pixels only.

  Turn.paint(dst, ox, oy, c, s, w, h, pad, draw, clip)

dst is the bitmap (any type, turned or not), (ox, oy) where the frame's origin
lands in it, (c, s) the cos and sin of the angle (clockwise on the y-down
page), w x h the frame's size with `pad` px around it included, and draw(bb,
x, y) draws the upright thing into bb with its origin at (x, y). clip, when
given, is a box { x0, y0, x1, y1 } of dst to stay inside.
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")

local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs

local Turn = {}

-- Pixel access to an upright bitmap of ours: BB8 as bytes, the rest as RGB32
-- words (r, g, b, a bytes).
local function view(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then
        return ffi.cast("uint8_t*", bb.data), tonumber(bb.stride), 1
    end
    return ffi.cast("uint32_t*", bb.data), tonumber(bb.stride) / 4, 4
end

function Turn.paint(dst, ox, oy, c, s, w, h, pad, draw, clip)
    pad = pad or 0
    local TW, TH = ceil(w) + 2 * pad, ceil(h) + 2 * pad
    if TW <= 0 or TH <= 0 then return end
    -- the page box the turned frame covers, inside dst (and the clip)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs({ { -pad, -pad }, { w + pad, -pad }, { -pad, h + pad }, { w + pad, h + pad } }) do
        local X, Y = ox + p[1] * c - p[2] * s, oy + p[1] * s + p[2] * c
        x0, y0, x1, y1 = min(x0, X), min(y0, Y), max(x1, X), max(y1, Y)
    end
    local ax0, ay0 = max(0, floor(x0)), max(0, floor(y0))
    local ax1, ay1 = min(dst:getWidth(), ceil(x1) + 1), min(dst:getHeight(), ceil(y1) + 1)
    if clip then
        ax0, ay0 = max(ax0, floor(clip.x0)), max(ay0, floor(clip.y0))
        ax1, ay1 = min(ax1, ceil(clip.x1)), min(ay1, ceil(clip.y1))
    end
    local AW, AH = ax1 - ax0, ay1 - ay0
    if AW <= 0 or AH <= 0 then return end

    -- an upright working copy of that part of dst, in a type we can address
    local typ = dst:getType() == Blitbuffer.TYPE_BB8 and Blitbuffer.TYPE_BB8 or Blitbuffer.TYPE_BBRGB32
    local work = Blitbuffer.new(AW, AH, typ)
    work:blitFrom(dst, 0, 0, ax0, ay0, AW, AH)
    local wp, ws, bpp = view(work)
    -- the frame: the page under it, as the frame sees it (nearest pixel)
    local tmp = Blitbuffer.new(TW, TH, typ)
    local tp, ts = view(tmp)
    local white = bpp == 1 and 0xFF or 0xFFFFFFFF
    local bx, by = ox - ax0, oy - ay0   -- the origin in work
    for j = 0, TH - 1 do
        local ly = j - pad + 0.5
        local row = j * ts
        for i = 0, TW - 1 do
            local lx = i - pad + 0.5
            local X = floor(bx + lx * c - ly * s)
            local Y = floor(by + lx * s + ly * c)
            if X >= 0 and X < AW and Y >= 0 and Y < AH then
                tp[row + i] = wp[Y * ws + X]
            else
                tp[row + i] = white
            end
        end
    end
    local orig = tmp:copy()
    local op_ = view(orig)
    draw(tmp, pad, pad)

    -- back onto the page: every work pixel looks up where it falls in the frame
    local quarter = abs(c) < 1e-9 or abs(s) < 1e-9
    local b8 = ffi.cast("uint8_t*", tmp.data)
    local tstride = tonumber(tmp.stride)
    for y = 0, AH - 1 do
        local Y = y + 0.5 - by
        local wrow = y * ws
        for x = 0, AW - 1 do
            local X = x + 0.5 - bx
            local fx = X * c + Y * s + pad - 0.5    -- the frame pixel (centres on integers)
            local fy = -X * s + Y * c + pad - 0.5
            if quarter then
                local i, j = floor(fx + 0.5), floor(fy + 0.5)
                if i >= 0 and i < TW and j >= 0 and j < TH then
                    local k = j * ts + i
                    if tp[k] ~= op_[k] then wp[wrow + x] = tp[k] end
                end
            elseif fx > -1 and fx < TW and fy > -1 and fy < TH then
                local i0, j0 = floor(fx), floor(fy)
                local tx, ty = fx - i0, fy - j0
                local i1, j1 = min(TW - 1, i0 + 1), min(TH - 1, j0 + 1)
                i0, j0 = max(0, i0), max(0, j0)
                local k00, k10 = j0 * ts + i0, j0 * ts + i1
                local k01, k11 = j1 * ts + i0, j1 * ts + i1
                if tp[k00] ~= op_[k00] or tp[k10] ~= op_[k10] or tp[k01] ~= op_[k01] or tp[k11] ~= op_[k11] then
                    local w00, w10 = (1 - tx) * (1 - ty), tx * (1 - ty)
                    local w01, w11 = (1 - tx) * ty, tx * ty
                    if bpp == 1 then
                        wp[wrow + x] = floor(tp[k00] * w00 + tp[k10] * w10 + tp[k01] * w01 + tp[k11] * w11 + 0.5)
                    else
                        -- per channel, from the bytes of the four words
                        local o = (wrow + x) * 4
                        local w8 = ffi.cast("uint8_t*", work.data)
                        local a00, a10 = (j0 * tstride) + i0 * 4, (j0 * tstride) + i1 * 4
                        local a01, a11 = (j1 * tstride) + i0 * 4, (j1 * tstride) + i1 * 4
                        for ch = 0, 2 do
                            w8[o + ch] = floor(b8[a00 + ch] * w00 + b8[a10 + ch] * w10
                                + b8[a01 + ch] * w01 + b8[a11 + ch] * w11 + 0.5)
                        end
                        w8[o + 3] = 0xFF
                    end
                end
            end
        end
    end
    dst:blitFrom(work, ax0, ay0, 0, 0, AW, AH)
    orig:free(); tmp:free(); work:free()
end

return Turn
