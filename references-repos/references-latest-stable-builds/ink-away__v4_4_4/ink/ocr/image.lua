-- A cropped foreground-only OCR image. Replay the native pens and erasers;
-- never sample the book, paper, placed pictures, or unselected writing.
local Canvas = require("ink/canvas")
local Symmetry = require("ink/symmetry")
local Image = { MAX_PIXELS = 4000000, MAX_BYTES = 4 * 1024 * 1024 }

function Image.snapshot(canvas, ops)
    local selected, groups, order = {}, {}, {}
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, op in ipairs(ops) do
        local layer = canvas.layers and (op.layer or 1) or 1
        selected[op] = true
        if not groups[layer] then groups[layer] = {}; order[#order + 1] = layer end
        local pad = math.max(12, (op.width or 1) * 4)
        for _, flip in ipairs(Symmetry.flips(op.sym)) do
            local pts = Symmetry.flipPoints(op.pts, flip, canvas.w, canvas.h)
            for i = 1, #pts - 1, 2 do
                x0, y0 = math.min(x0, pts[i] - pad), math.min(y0, pts[i + 1] - pad)
                x1, y1 = math.max(x1, pts[i] + pad), math.max(y1, pts[i + 1] + pad)
            end
        end
    end
    x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
    x1, y1 = math.min(canvas.w, math.ceil(x1)), math.min(canvas.h, math.ceil(y1))
    local w, h = x1 - x0, y1 - y0
    if w < 1 or h < 1 or w * h > Image.MAX_PIXELS then
        return nil, "Select a smaller area of handwriting (maximum 4 megapixels)."
    end
    if canvas.layers then
        order = {}
        for _, layer in ipairs(canvas.layers) do
            if groups[layer.id] then order[#order + 1] = layer.id end
        end
    end
    for _, op in ipairs(canvas.ops) do
        local layer = canvas.layers and (op.layer or 1) or 1
        if groups[layer] and not op.hidden and not (canvas.hidden_layers or {})[layer]
                and (selected[op] or op.kind == "erase" or op.kind == "smudge") then
            local copy = Canvas.cloneOp(nil, op)
            -- A white pen on dark paper must remain legible on OCR's white page.
            if selected[op] then copy.color = { 0, 0, 0 } end
            groups[layer][#groups[layer] + 1] = copy
        end
    end
    local layers = {}
    for _, id in ipairs(order) do
        layers[#layers + 1] = { w = canvas.w, h = canvas.h, ops = groups[id] }
    end
    return { layers = layers, rect = { x = x0, y = y0, w = w, h = h } }
end

function Image.pixels(snapshot)
    local ffi = require("ffi")
    local Export = require("ink/export")
    local r = snapshot.rect
    local out = ffi.new("uint8_t[?]", r.w * r.h * 4)
    ffi.fill(out, r.w * r.h * 4, 255)
    for _, layer in ipairs(snapshot.layers) do
        local buf = Export.buildRGBA(layer, r)
        for i = 0, r.w * r.h - 1 do
            local p = i * 4
            local a = buf[p + 3] / 255
            for c = 0, 2 do out[p + c] = math.floor(buf[p + c] * a + out[p + c] * (1 - a) + 0.5) end
        end
    end
    return out, r.w, r.h
end

function Image.png(snapshot)
    local ffi = require("ffi")
    require("ffi/posix_h")
    require("ffi/lodepng_h")
    local png = ffi.loadlib("lodepng")
    local buf, w, h = Image.pixels(snapshot)
    local state = ffi.new("LodePNGState[1]")
    png.lodepng_state_init(state)
    state[0].info_raw.colortype, state[0].info_raw.bitdepth = png.LCT_RGBA, 8
    state[0].info_png.color.colortype, state[0].info_png.color.bitdepth = png.LCT_RGBA, 8
    local ptr, size = ffi.new("unsigned char*[1]"), ffi.new("size_t[1]")
    local err = png.lodepng_encode(ptr, size, buf, w, h, state)
    png.lodepng_state_cleanup(state)
    local text
    if err == 0 and size[0] <= Image.MAX_BYTES then text = ffi.string(ptr[0], size[0]) end
    if ptr[0] ~= nil then ffi.C.free(ptr[0]) end
    if err ~= 0 then return nil, "The handwriting image could not be encoded." end
    if not text then return nil, "Select less handwriting (maximum PNG size is 4 MiB)." end
    return text
end

return Image
