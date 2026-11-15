--[[
The handwritten character model: a small convolutional network trained on
EMNIST and the UJI pen database (see NOTICE.md), stored in ink/data/hwr_en.bin
as 8-bit weights (about 100 KB). It reads one character at a time:

  * HwrNet.render(strokes)    a character's strokes as a 28x28 image
  * HwrNet.load(path)         the network, or nil, err
  * net:logProbs(image)       log-probabilities of the 47 classes

The 47 classes are the digits, the capitals, and the small letters whose shape
differs from the capital (a b d e f g h n q r t); c, o, s and the like share
their capital's class (net.classes lists them in order).

Rendering and the forward pass follow the training project's hwr/render.py and
export.py step for step, so the device sees what the model was trained on.
Plain LuaJIT with FFI arrays: about 2 million multiply-adds per character.
]]

local ffi = require("ffi")

local HwrNet = {}
HwrNet.__index = HwrNet

local SIZE = 28
HwrNet.SIZE = SIZE

local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt

-- Draw a character's strokes (a list of flat {x, y, x, y, ...} lists, any units,
-- y down) into a 28x28 float image, ink 1 on 0: the longer side of the strokes'
-- box spans `fit` pixels, centred, and each pixel is how far its centre lies
-- inside a round pen of radius `radius` drawn along them. `out` is reused when
-- given. Returns the image (a float[784], row by row).
function HwrNet.render(strokes, fit, radius, out)
    local img = out or ffi.new("float[?]", SIZE * SIZE)
    ffi.fill(img, SIZE * SIZE * ffi.sizeof("float"))
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, s in ipairs(strokes) do
        for i = 1, #s - 1, 2 do
            local x, y = s[i], s[i + 1]
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
    end
    if x0 > x1 then return img end
    local span = max(x1 - x0, y1 - y0, 1e-6)
    local scale = fit / span
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    local half = SIZE / 2
    local r = radius
    for _, s in ipairs(strokes) do
        local n = floor(#s / 2)
        if n >= 1 then
            local last = (n == 1) and 1 or (n - 1)
            for k = 1, last do
                local i = 2 * k - 1
                local ax, ay = (s[i] - cx) * scale + half, (s[i + 1] - cy) * scale + half
                local bx, by = ax, ay
                if n > 1 then bx, by = (s[i + 2] - cx) * scale + half, (s[i + 3] - cy) * scale + half end
                local lo_x = max(0, floor(min(ax, bx) - r - 1))
                local hi_x = min(SIZE, ceil(max(ax, bx) + r + 1))
                local lo_y = max(0, floor(min(ay, by) - r - 1))
                local hi_y = min(SIZE, ceil(max(ay, by) + r + 1))
                local dx, dy = bx - ax, by - ay
                local ll = dx * dx + dy * dy
                for py = lo_y, hi_y - 1 do
                    local qy = py + 0.5
                    for px = lo_x, hi_x - 1 do
                        local qx = px + 0.5
                        local t = 0
                        if ll > 0 then
                            t = ((qx - ax) * dx + (qy - ay) * dy) / ll
                            if t < 0 then t = 0 elseif t > 1 then t = 1 end
                        end
                        local ex, ey = qx - (ax + t * dx), qy - (ay + t * dy)
                        local v = r + 0.5 - sqrt(ex * ex + ey * ey)
                        if v > 0 then
                            if v > 1 then v = 1 end
                            local j = py * SIZE + px
                            if v > img[j] then img[j] = v end
                        end
                    end
                end
            end
        end
    end
    return img
end

-- Read the model file. Returns the network, or nil, err.
function HwrNet.load(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local raw = f:read("*a")
    f:close()
    local n = #raw
    local buf = ffi.new("uint8_t[?]", n)
    ffi.copy(buf, raw, n)
    local pos = 0
    local function need(k) if pos + k > n then error("hwr model file is cut short") end end
    -- Numbers sit at any byte offset in the file. ARM readers stop the whole
    -- program on an unaligned float load, so each one is copied into an aligned
    -- cell first.
    local cell_u, cell_f = ffi.new("uint32_t[1]"), ffi.new("float[1]")
    local function u32() need(4); ffi.copy(cell_u, buf + pos, 4); pos = pos + 4; return tonumber(cell_u[0]) end
    local function f32() need(4); ffi.copy(cell_f, buf + pos, 4); pos = pos + 4; return tonumber(cell_f[0]) end
    local ok, net = pcall(function()
        need(4)
        if ffi.string(buf, 4) ~= "IAHW" then error("not an Ink Away handwriting model") end
        pos = 4
        local version = u32()
        if version ~= 1 then error("unknown model version " .. version) end
        local ncls = u32()
        need(ncls)
        local classes = {}
        for i = 1, ncls do classes[i] = string.char(buf[pos + i - 1]) end
        pos = pos + ncls
        local fit, radius = f32(), f32()
        local nlayers = u32()
        local layers = {}
        for li = 1, nlayers do
            local kind, nin, nout = u32(), u32(), u32()
            need(8 * nout)
            local scale = ffi.new("float[?]", nout)
            ffi.copy(scale, buf + pos, 4 * nout); pos = pos + 4 * nout
            local bias = ffi.new("float[?]", nout)
            ffi.copy(bias, buf + pos, 4 * nout); pos = pos + 4 * nout
            local per = (kind == 1) and nin * 9 or nin
            local count = nout * per
            need(count)
            local q = ffi.cast("int8_t*", buf + pos)
            local w = ffi.new("float[?]", count)
            for o = 0, nout - 1 do
                local s = scale[o]
                local base = o * per
                for k = 0, per - 1 do w[base + k] = q[base + k] * s end
            end
            pos = pos + count + ((-count) % 4)
            layers[li] = { kind = kind, nin = nin, nout = nout, w = w, bias = bias }
        end
        return setmetatable({ classes = classes, fit = fit, radius = radius, layers = layers }, HwrNet)
    end)
    if not ok then return nil, net end
    net:allocate()
    return net
end

-- Working buffers, sized for the largest layer.
function HwrNet:allocate()
    local most = SIZE * SIZE
    local h = SIZE
    for _, L in ipairs(self.layers) do
        if L.kind == 1 then
            most = max(most, (h + 2) * (h + 2) * L.nin, L.nout * h * h)
            h = floor(h / 2)
        else
            most = max(most, L.nin, L.nout)
        end
    end
    self._a = ffi.new("float[?]", most)
    self._b = ffi.new("float[?]", most)
    self._pad = ffi.new("float[?]", most)
    self._img = ffi.new("float[?]", SIZE * SIZE)
end

-- 3x3 convolution with zero padding, ReLU and 2x2 max pooling (rounding down),
-- from `src` (nin x h x h) into `dst` (nout x h/2 x h/2), using `pad` and `tmp`.
local function convLayer(L, src, h, dst, pad, tmp)
    local nin, nout = L.nin, L.nout
    local w, bias = L.w, L.bias
    local hp = h + 2
    ffi.fill(pad, nin * hp * hp * ffi.sizeof("float"))
    for c = 0, nin - 1 do
        for y = 0, h - 1 do
            ffi.copy(pad + (c * hp + y + 1) * hp + 1, src + (c * h + y) * h, h * ffi.sizeof("float"))
        end
    end
    -- convolution + ReLU into tmp (nout x h x h)
    for o = 0, nout - 1 do
        local b = bias[o]
        local wo = o * nin * 9
        local to = o * h * h
        for y = 0, h - 1 do
            for x = 0, h - 1 do
                local acc = b
                for c = 0, nin - 1 do
                    local p = (c * hp + y) * hp + x
                    local k = wo + c * 9
                    acc = acc + w[k] * pad[p] + w[k + 1] * pad[p + 1] + w[k + 2] * pad[p + 2]
                        + w[k + 3] * pad[p + hp] + w[k + 4] * pad[p + hp + 1] + w[k + 5] * pad[p + hp + 2]
                        + w[k + 6] * pad[p + 2 * hp] + w[k + 7] * pad[p + 2 * hp + 1] + w[k + 8] * pad[p + 2 * hp + 2]
                end
                tmp[to + y * h + x] = acc > 0 and acc or 0
            end
        end
    end
    -- 2x2 max pooling
    local h2 = floor(h / 2)
    for o = 0, nout - 1 do
        local to = o * h * h
        for y = 0, h2 - 1 do
            for x = 0, h2 - 1 do
                local i = to + (2 * y) * h + 2 * x
                local m = tmp[i]
                if tmp[i + 1] > m then m = tmp[i + 1] end
                if tmp[i + h] > m then m = tmp[i + h] end
                if tmp[i + h + 1] > m then m = tmp[i + h + 1] end
                dst[(o * h2 + y) * h2 + x] = m
            end
        end
    end
    return h2
end

local function denseLayer(L, src, dst, relu)
    local nin, w, bias = L.nin, L.w, L.bias
    for o = 0, L.nout - 1 do
        local acc = bias[o]
        local base = o * nin
        for i = 0, nin - 1 do acc = acc + w[base + i] * src[i] end
        if relu and acc < 0 then acc = 0 end
        dst[o] = acc
    end
end

-- The 47 class scores (a Lua list) for a 28x28 image from HwrNet.render.
function HwrNet:logits(img)
    local a, b, pad = self._a, self._b, self._pad
    ffi.copy(a, img, SIZE * SIZE * ffi.sizeof("float"))
    local h = SIZE
    for _, L in ipairs(self.layers) do
        if L.kind == 1 then
            -- conv writes its pre-pool map into b, the pooled result back into a
            h = convLayer(L, a, h, a, pad, b)
        else
            denseLayer(L, a, b, L.kind == 2)
            a, b = b, a
        end
    end
    local out = {}
    for i = 0, self.layers[#self.layers].nout - 1 do out[i + 1] = a[i] end
    return out
end

-- Log-probabilities of the classes (a Lua list, net.classes order).
function HwrNet:logProbs(img)
    local z = self:logits(img)
    local m = -math.huge
    for i = 1, #z do if z[i] > m then m = z[i] end end
    local s = 0
    for i = 1, #z do s = s + math.exp(z[i] - m) end
    local lse = m + math.log(s)
    for i = 1, #z do z[i] = z[i] - lse end
    return z
end

-- Render a character's strokes with the model's own settings and score it.
function HwrNet:classify(strokes)
    HwrNet.render(strokes, self.fit, self.radius, self._img)
    return self:logProbs(self._img)
end

return HwrNet
