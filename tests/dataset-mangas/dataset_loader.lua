--[[
Panels+
File: tests/dataset-mangas/dataset_loader.lua
Name: DatasetLoader
Description: Decodes dataset images and converts them into detector-compatible page maps.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Standalone image loader and PageMap builder for dataset evaluation.
---
--- Uses ImageMagick (`magick` or `convert`) to stream downscaled greyscale image bytes,
--- applying the same background estimation and ink mapping logic as `src/_pagebitmap.lua`.

local Settings = require("src._settings")
local has_ffi, ffi = pcall(require, "ffi")

local DatasetLoader = {
    _magick_cmd = nil,
    _cache = {},
}

--- Detect available ImageMagick command (`magick` or `convert`).
function DatasetLoader.getMagickCommand()
    if DatasetLoader._magick_cmd then
        return DatasetLoader._magick_cmd
    end

    local test_magick = os.execute("command -v magick >/dev/null 2>&1")
    if test_magick == 0 or test_magick == true then
        DatasetLoader._magick_cmd = "magick"
        return "magick"
    end

    local test_convert = os.execute("command -v convert >/dev/null 2>&1")
    if test_convert == 0 or test_convert == true then
        DatasetLoader._magick_cmd = "convert"
        return "convert"
    end

    return nil
end

--- Estimate page background luminance as median of the outer border ring.
--- Matching `src/_pagebitmap.lua`'s `estimateBackgroundGrey`.
---
--- @param raw string Raw 8-bit greyscale byte string
--- @param w integer Map width
--- @param h integer Map height
--- @return integer Median background luminance (0-255)
local function hasWhiteSeparator(raw, w, h)
    local x_margin = math.max(1, math.floor(w * 0.03))
    local y_margin = math.max(1, math.floor(h * 0.03))
    local row_required, col_required = math.ceil(w * 0.80), math.ceil(h * 0.80)
    for y = y_margin, h - 1 - y_margin do
        local bright = 0
        local base = y * w
        for x = 0, w - 1 do
            if raw:byte(base + x + 1) >= 245 then
                bright = bright + 1
            end
            if bright >= row_required then
                return true
            end
            if bright + w - 1 - x < row_required then
                break
            end
        end
    end
    for x = x_margin, w - 1 - x_margin do
        local bright = 0
        for y = 0, h - 1 do
            if raw:byte(y * w + x + 1) >= 245 then
                bright = bright + 1
            end
            if bright >= col_required then
                return true
            end
            if bright + h - 1 - y < col_required then
                break
            end
        end
    end
    return false
end

local function estimateBackground(raw, w, h)
    local histogram = {}
    for i = 0, 255 do
        histogram[i] = 0
    end

    local ring = math.max(1, math.floor(math.min(w, h) * 0.01))
    local total = 0

    local function tally(x, y)
        local idx = y * w + x + 1
        local val = raw:byte(idx)
        if val then
            histogram[val] = histogram[val] + 1
            total = total + 1
        end
    end

    for offset = 0, ring - 1 do
        for x = 0, w - 1 do
            tally(x, offset)
            tally(x, h - 1 - offset)
        end
        for y = ring, h - 1 - ring do
            tally(offset, y)
            tally(w - 1 - offset, y)
        end
    end

    if total == 0 then
        return 255
    end

    local half, seen = total / 2, 0
    for value = 0, 255 do
        seen = seen + histogram[value]
        if seen >= half then
            -- Cropped manga and comics can let gray artwork reach every outer
            -- edge while retaining white, nearly page-spanning gutters. In
            -- that case the border median describes panel fill, not paper.
            if value >= 32 and value < 224 and hasWhiteSeparator(raw, w, h) then
                return 255
            end
            return value
        end
    end
    return 255
end

--- Read PNG width and height directly from the 24-byte IHDR header in pure Lua.
local function readPngDimensions(image_path)
    local f = io.open(image_path, "rb")
    if not f then
        return nil, nil
    end
    local header = f:read(24)
    f:close()
    if not header or #header < 24 then
        return nil, nil
    end
    if header:sub(1, 8) ~= "\137PNG\r\n\026\n" then
        return nil, nil
    end
    local w = header:byte(17) * 16777216 + header:byte(18) * 65536 + header:byte(19) * 256 + header:byte(20)
    local h = header:byte(21) * 16777216 + header:byte(22) * 65536 + header:byte(23) * 256 + header:byte(24)
    if w > 0 and h > 0 then
        return w, h
    end
    return nil, nil
end

--- Load an image file into a PPPageMap.
---
--- @param image_path string Absolute or repo-relative image path
--- @param settings table|nil Plugin settings overrides
--- @return table PPPageMap ready for Segmenter.segment
function DatasetLoader.loadPageMap(image_path, settings)
    settings = settings or {}
    local defaults = Settings.defaults
    local target_w = settings.segment_target_width or defaults.segment_target_width or 480
    local cache_key = string.format(
        "%s:%d:%s:%s",
        image_path,
        target_w,
        tostring(settings.segment_ink_delta),
        tostring(settings.mode)
    )
    if DatasetLoader._cache[cache_key] then
        return DatasetLoader._cache[cache_key]
    end

    local cache_dir = "tests/dataset-mangas/.cache/pagemaps"
    local safe_name = image_path:gsub("[/\\]", "_")
    local disk_cache_path = string.format("%s/%s_w%d.bin", cache_dir, safe_name, target_w)

    local native_w, native_h, target_h, bg, raw
    local cache_needs_write = false
    local f_cache = io.open(disk_cache_path, "rb")
    if f_cache then
        local header_line = f_cache:read("*l")
        if header_line then
            local nw, nh, tw, th = header_line:match("^(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+%d+$")
            if nw and nh and tw and th and tonumber(tw) == target_w then
                native_w = tonumber(nw)
                native_h = tonumber(nh)
                target_h = tonumber(th)
                raw = f_cache:read("*a")
            end
        end
        f_cache:close()
    end

    if not raw or #raw < target_w * (target_h or 1) then
        local magick = DatasetLoader.getMagickCommand()
        if not magick then
            error("ImageMagick ('magick' or 'convert') is required to load test images.")
        end

        -- 1. Read native dimensions (pure Lua fast path for PNG, magick fallback for others)
        native_w, native_h = readPngDimensions(image_path)
        if not native_w or not native_h then
            local dim_pipe =
                io.popen(string.format('%s "%s" -format "%%w %%h" info: 2>/dev/null', magick, image_path), "r")
            if not dim_pipe then
                error("Failed to read image dimensions for: " .. image_path)
            end
            local dim_str = dim_pipe:read("*a")
            dim_pipe:close()

            native_w, native_h = dim_str:match("(%d+)%s+(%d+)")
            native_w, native_h = tonumber(native_w), tonumber(native_h)
        end
        if not native_w or not native_h or native_w == 0 or native_h == 0 then
            error(string.format("Invalid dimensions for image %s", image_path))
        end

        -- 2. Determine downscaled target dimensions
        target_h = math.max(1, math.floor(target_w * native_h / native_w))

        -- 3. Stream downscaled greyscale bytes
        local cmd =
            string.format('%s "%s" -resize %dx%d! -depth 8 gray:- 2>/dev/null', magick, image_path, target_w, target_h)
        local img_pipe = io.popen(cmd, "r")
        if not img_pipe then
            error("Failed to run magick stream command: " .. cmd)
        end
        raw = img_pipe:read("*a")
        img_pipe:close()

        if #raw < target_w * target_h then
            error(string.format("Truncated image data: expected %d bytes, got %d", target_w * target_h, #raw))
        end

        cache_needs_write = true
    end

    -- Background policy depends on reading material type, while the cached
    -- raster does not. Recompute it after reading the shared grayscale bytes
    -- so changing Manga/Comic metadata takes effect immediately.
    bg = estimateBackground(raw, target_w, target_h)

    if cache_needs_write then
        -- Save to disk cache for near-instant subsequent loads.
        os.execute("mkdir -p " .. cache_dir)
        -- Workers can load the same golden page concurrently. Publish complete
        -- cache files atomically using a unique temporary name per writer.
        local reserved = os.tmpname()
        local temporary = disk_cache_path .. reserved:match("[^/]+$")
        local f_out = io.open(temporary, "wb")
        if f_out then
            f_out:write(string.format("%d %d %d %d %d\n", native_w, native_h, target_w, target_h, bg))
            f_out:write(raw)
            f_out:close()
            os.rename(temporary, disk_cache_path)
        end
        os.remove(temporary)
        os.remove(reserved)
    end

    local inverted = bg < 128
    local ink_delta = settings.segment_ink_delta or defaults.segment_ink_delta or 30

    -- 5. Mark ink cells
    -- Match the reader's byte-per-cell storage under LuaJIT while keeping
    -- this standalone loader usable with plain Lua too.
    local ink_data = has_ffi and ffi.new("uint8_t[?]", target_w * target_h) or {}
    local total_ink = 0
    for y = 0, target_h - 1 do
        local row_base = y * target_w
        for x = 0, target_w - 1 do
            local idx = row_base + x + 1
            local val = raw:byte(idx)
            local diff = math.abs(val - bg)
            local is_ink = (diff > ink_delta) and 1 or 0
            ink_data[row_base + x] = is_ink
            if is_ink == 1 then
                total_ink = total_ink + 1
            end
        end
    end

    local map = {
        w = target_w,
        h = target_h,
        data = ink_data,
        ink = total_ink,
        native_w = native_w,
        native_h = native_h,
        scale_x = native_w / target_w,
        scale_y = native_h / target_h,
        background = bg,
        inverted = inverted,
        border = nil,
    }
    -- Full-volume runs visit hundreds of pages once. Keep only the latest
    -- map for repeated detector calls; the disk cache retains reusable rasters.
    DatasetLoader._cache = { [cache_key] = map }
    return map
end

return DatasetLoader
