--[[
Panels+
File: src/_nativedetector.lua
Name: NativeDetector
Description: Implements the memory-guarded K2PDFOpt/Leptonica compatibility fallback for panel detection.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Document = require("document/document")
local Geometry = require("src._geometry")
local Memory = require("src._memory")
local Settings = require("src._settings")
local Timing = require("src._timing")
local logger = require("logger")

--- Panel detection through KOReader's native k2pdfopt detector.
---
--- KOReader exposes the detector as `Document:getPanelFromPage()`, which is the
--- only uncached probe in `KoptInterface`: every call creates a KOPTContext,
--- rasterizes the *whole* page at full resolution, probes one point, and throws
--- the rasterization away. Probing a grid therefore costs one full page render
--- per point.
---
--- This module drives the same primitives directly so a fixed page is rendered
--- once, then its KOPT components are extracted once for every panel. Its
--- compatibility fallback still probes that one shared raster. Both the shared
--- rasterization and the document-level per-probe fallback are skipped outright when free memory is below
--- `native_detect_min_free_bytes` -- a full-resolution render is this plugin's
--- single largest allocation, and on a low-memory device it is safer to report
--- no panels than to risk an OOM kill.
---
--- @class PPNativeDetectorModule
local NativeDetector = {}

--- Conservative bytes needed while KOPT turns a source page into a Leptonica
--- component map. This deliberately overestimates the one-bit threshold image
--- and component list: on a 300MB device skipping an oversized Deep pass is
--- preferable to leaving KOReader without enough memory to redraw the reader.
local function deepWorkingSetBytes(width, height, source_is_greyscale)
    local pixels = math.max(0, width or 0) * math.max(0, height or 0)
    local bytes_per_pixel = source_is_greyscale and 5 or 6
    return math.floor(pixels * bytes_per_pixel + 2 * 1024 * 1024)
end

--- Return a BlitBuffer's source dimensions without assuming a particular
--- backend's field layout.
local function imageDimensions(image)
    if not image then
        return nil, nil
    end
    local width = image.getWidth and image:getWidth() or image.w
    local height = image.getHeight and image:getHeight() or image.h
    return width, height
end

--- Copy an extracted image into a K2PDFOpt source bitmap.
---
--- KOReader's native detector ultimately calls `KOPTContext:getPanelFromPage`,
--- whose Lua implementation operates on `kc.src`. PDF/DjVu fill that source
--- through MuPDF's page rasterizer; EPUB/KEPUB/MOBI already supply a decoded
--- BlitBuffer, so we make the equivalent 8-bit KOPT source explicitly.
---
--- @return boolean ok Whether KOPT owns a completed copy of the image.
local function copyImageToKoptSource(kc, image, Blitbuffer, ffi, k2pdfopt)
    local width, height = imageDimensions(image)
    if not width or not height or width <= 0 or height <= 0 then
        return nil
    end

    -- Avoid a second full image buffer when CREngine already gave us greyscale.
    -- Other decoded formats are converted once here, then immediately released
    -- after their bytes have been copied into KOPT's owned source allocation.
    local source = image
    local temporary_grey
    if not (image.getType and image:getType() == Blitbuffer.TYPE_BB8) then
        temporary_grey = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
        source = temporary_grey
    end
    local ok, err = pcall(function()
        if temporary_grey then
            temporary_grey:blitFrom(image, 0, 0, 0, 0, width, height)
        end
        kc.src.width = width
        kc.src.height = height
        kc.src.bpp = 8
        kc.src.type = 0
        for value = 0, 255 do
            kc.src.red[value] = value
            kc.src.green[value] = value
            kc.src.blue[value] = value
        end
        k2pdfopt.bmp_alloc(kc.src)
        if kc.src.data == nil then
            error("K2PDFOpt source allocation failed")
        end
        local source_stride = tonumber(source.stride)
        local target_stride = tonumber(k2pdfopt.bmp_bytewidth(kc.src))
        if not source_stride or not target_stride or source_stride < width or target_stride < width then
            error("invalid grayscale bitmap stride")
        end
        for y = 0, height - 1 do
            ffi.copy(kc.src.data + y * target_stride, source.data + y * source_stride, width)
        end
    end)
    if temporary_grey and temporary_grey.free then
        temporary_grey:free()
    end
    if not ok then
        logger.warn("[Panels+] could not create KOPT image source:", err)
        return false
    end
    return true
end

--- Load the public Leptonica FFI needed to perform KOPT panel detection once.
--- The core KOPT module normally loads these itself; keeping this lazy lets
--- the ordinary Lua test runner and older KOReader builds retain the original
--- `kc:getPanelFromPage()` fallback.
local component_runtime_checked = false
local component_runtime
local function getComponentRuntime()
    if component_runtime_checked then
        return component_runtime
    end
    component_runtime_checked = true
    local ok, runtime = pcall(function()
        local ffi = require("ffi")
        require("ffi/koptcontext_h")
        require("ffi/leptonica_h")
        return {
            ffi = ffi,
            leptonica = ffi.loadlib("leptonica", "6"),
        }
    end)
    if ok and runtime.leptonica then
        component_runtime = runtime
    end
    return component_runtime
end

--- Run KOReader's exact KOPT/Leptonica panel algorithm once and return every
--- qualifying connected component.
---
--- KOReader's `getPanelFromPage()` performs these exact operations for one
--- probe: bitmap -> greyscale -> inverse/threshold/inverse -> 8-connected
--- components. It then scans those components only to find the one containing
--- that probe. Performing the shared work once and retaining all qualifying
--- boxes includes every result a probe could return (and no longer misses a
--- component between grid points), while avoiding up to a full probe grid of
--- complete Leptonica pipelines.
---
--- @return PPPanel[]|nil panels Nil when direct Leptonica access is unavailable.
local function collectKoptComponents(kc)
    local runtime = getComponentRuntime()
    if not runtime or not kc or not kc.src or kc.src.data == nil then
        return nil
    end

    local ffi, leptonica = runtime.ffi, runtime.leptonica
    local k2pdfopt = require("ffi/koptcontext").k2pdfopt
    local pixs, pixg, pix_inverted, pix_thresholded, boxes
    local function destroyPix(pix)
        if pix ~= nil then
            pcall(leptonica.pixDestroy, ffi.new("PIX *[1]", pix))
        end
    end
    local function destroyBoxes(boxa)
        if boxa ~= nil then
            pcall(leptonica.boxaDestroy, ffi.new("BOXA *[1]", boxa))
        end
    end

    local ok, panels_or_error = pcall(function()
        pixs = k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height)
        if pixs == nil then
            return {}
        end
        if leptonica.pixGetDepth(pixs) == 32 then
            pixg = leptonica.pixConvertRGBToGrayFast(pixs)
        else
            pixg = leptonica.pixClone(pixs)
        end
        if pixg == nil then
            return {}
        end
        pix_inverted = leptonica.pixInvert(nil, pixg)
        pix_thresholded = pix_inverted and leptonica.pixThresholdToBinary(pix_inverted, 50) or nil
        if pix_thresholded == nil then
            return {}
        end
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        boxes = leptonica.pixConnCompBB(pix_thresholded, 8)
        if boxes == nil then
            return {}
        end

        local image_width = leptonica.pixGetWidth(pixs)
        local image_height = leptonica.pixGetHeight(pixs)
        local geometry = ffi.new("l_int32[4]")
        local panels = {}
        for index = 0, leptonica.boxaGetCount(boxes) - 1 do
            leptonica.boxaGetBoxGeometry(boxes, index, geometry, geometry + 1, geometry + 2, geometry + 3)
            local x, y, width, height =
                tonumber(geometry[0]), tonumber(geometry[1]), tonumber(geometry[2]), tonumber(geometry[3])
            -- The original method clips the source to each box before checking
            -- these dimensions; a connected-component box already has exactly
            -- those dimensions, so no per-box PIX allocation is necessary.
            if width >= image_width / 8 and height >= image_height / 8 then
                table.insert(panels, { x = x, y = y, w = width, h = height })
            end
        end
        return panels
    end)
    destroyBoxes(boxes)
    destroyPix(pix_thresholded)
    destroyPix(pix_inverted)
    destroyPix(pixg)
    destroyPix(pixs)
    if not ok then
        logger.warn("[Panels+] one-pass native component collection failed:", panels_or_error)
        return nil
    end
    return panels_or_error
end

--- Add a detector probe point if its floored coordinate has not been used.
---
--- @param probes PPPagePosition[] Mutable probe list.
--- @param seen table<string, boolean> Coordinate-key set.
--- @param page number Document page number.
--- @param x number Page-space x coordinate.
--- @param y number Page-space y coordinate.
local function addProbe(probes, seen, page, x, y)
    local key = math.floor(x) .. ":" .. math.floor(y)
    if seen[key] then
        return
    end
    seen[key] = true
    table.insert(probes, {
        page = page,
        x = x,
        y = y,
    })
end

--- Add the center point of one probe-grid cell.
---
--- @param probes PPPagePosition[] Mutable probe list.
--- @param seen table<string, boolean> Coordinate-key set.
--- @param page number Document page number.
--- @param page_size PPPageSize Page dimensions.
--- @param col integer 1-based grid column.
--- @param row integer 1-based grid row.
--- @param cols integer Total grid columns.
--- @param rows integer Total grid rows.
local function addGridProbe(probes, seen, page, page_size, col, row, cols, rows)
    addProbe(probes, seen, page, page_size.w * (col - 0.5) / cols, page_size.h * (row - 0.5) / rows)
end

--- Build an ordered list of points to pass to the native detector.
---
--- The order favors the user's hold position, then the center, then likely
--- reading-path cells before falling back to the complete grid.
---
--- @param page number Document page number.
--- @param page_size PPPageSize Page dimensions.
--- @param settings PPSettings Plugin settings.
--- @param hold_pos PPPagePosition|nil Optional hold position.
--- @return PPPagePosition[] probes Ordered detector probe points.
function NativeDetector.buildProbePlan(page, page_size, settings, hold_pos)
    local cols = settings.panel_grid_cols
    if not cols or cols <= 0 then
        cols = Settings.defaults.panel_grid_cols
    end
    local rows = settings.panel_grid_rows
    if not rows or rows <= 0 then
        rows = Settings.defaults.panel_grid_rows
    end
    local probes, seen = {}, {}
    local center_col = math.ceil(cols / 2)
    local center_row = math.ceil(rows / 2)
    local x_order = {}

    if settings.mode == "comic" then
        for col = 1, cols do
            table.insert(x_order, col)
        end
    else
        for col = cols, 1, -1 do
            table.insert(x_order, col)
        end
    end

    if hold_pos then
        addProbe(probes, seen, page, hold_pos.x, hold_pos.y)
    end

    addGridProbe(probes, seen, page, page_size, center_col, center_row, cols, rows)

    for row = 1, rows do
        addGridProbe(probes, seen, page, page_size, x_order[1], row, cols, rows)
    end

    for _, col in ipairs(x_order) do
        addGridProbe(probes, seen, page, page_size, col, center_row, cols, rows)
    end

    for row = 1, rows do
        for _, col in ipairs(x_order) do
            addGridProbe(probes, seen, page, page_size, col, row, cols, rows)
        end
    end

    return probes
end

--- Return whether a probe point already falls inside a discovered panel.
---
--- @param panels PPPanel[] Panels found so far.
--- @param pos PPPagePosition Probe point.
--- @return boolean covered Whether the point can be skipped.
local function isCovered(panels, pos)
    for _, rect in ipairs(panels) do
        if Geometry.rectContains(rect, pos) then
            return true
        end
    end
    return false
end

--- Record a detector result, de-duplicating by rounded rectangle.
---
--- @param state {panels:PPPanel[], by_key:table<string, boolean>} Mutable accumulator.
--- @param rect PPPanel|nil Detector result.
local function record(state, rect)
    if not (rect and rect.w and rect.h and rect.w > 0 and rect.h > 0) then
        return
    end
    local key = Geometry.rectKey(rect)
    if state.by_key[key] then
        return
    end
    state.by_key[key] = true
    table.insert(state.panels, rect)
end

--- Run a probe plan through an arbitrary single-point probe function.
---
--- @param probes PPPagePosition[] Ordered probe points.
--- @param hold_pos PPPagePosition|nil Hold position; forces the first probe.
--- @param state {panels:PPPanel[], by_key:table<string, boolean>} Mutable accumulator.
--- @param probe fun(pos:PPPagePosition):PPPanel|nil Single-point detector.
local function runProbes(probes, hold_pos, state, probe)
    for idx, pos in ipairs(probes) do
        local force = hold_pos ~= nil and idx == 1
        if force or not isCovered(state.panels, pos) then
            local ok, rect = pcall(probe, pos)
            if ok then
                record(state, rect)
            end
        end
    end
end

--- Probe an entire plan against one shared, already-rasterized page context.
---
--- Mirrors `KoptInterface:getPanelFromPage()` with the probe loop moved *inside*
--- the rasterization, turning N full page renders into one.
---
--- @param document table KOReader document object.
--- @param page number Document page number.
--- @param probes PPPagePosition[] Ordered probe points.
--- @param hold_pos PPPagePosition|nil Optional hold position.
--- @param state {panels:PPPanel[], by_key:table<string, boolean>} Mutable accumulator.
--- @return boolean ok Whether the batched pass completed.
local function runBatchedProbes(document, page, probes, hold_pos, state)
    local koptinterface = document.koptinterface
    if not koptinterface or not document._document or #probes == 0 then
        return false
    end

    local page_size = Document.getNativePageDimensions(document, page)
    if not page_size then
        return false
    end

    local kc, native_page
    local ok, err = pcall(function()
        kc = koptinterface:createContext(document, page, {
            x0 = 0,
            y0 = 0,
            x1 = page_size.w,
            y1 = page_size.h,
        })
        kc:setZoom(1.0)
        native_page = document._document:openPage(page)
        native_page:getPagePix(kc, document.render_mode, document.configurable.background_cleanup)

        local components = collectKoptComponents(kc)
        if components then
            for _, rect in ipairs(components) do
                record(state, rect)
            end
        else
            -- Compatibility fallback for a KOReader build without the direct
            -- Leptonica symbols. It retains the prior, per-probe API path.
            runProbes(probes, hold_pos, state, function(pos)
                return kc:getPanelFromPage(pos)
            end)
        end
    end)

    -- Both handles own C memory; free explicitly immediately after probing.
    if native_page then
        pcall(native_page.close, native_page)
    end
    if kc then
        pcall(kc.free, kc)
    end

    if not ok then
        logger.warn("[Panels+] batched panel detection failed:", err)
        return false
    end
    return true
end

--- Collect page panels using KOReader's native detector.
---
--- @param ui table KOReader reader UI object.
--- @param settings PPSettings Plugin settings.
--- @param page number Document page number.
--- @param hold_pos PPPagePosition|nil Optional page-space position from the user's hold.
--- @return PPPanel[] panels Ordered panel rectangles.
function NativeDetector.collect(ui, settings, page, hold_pos)
    local document = ui.document
    -- Rasterization below always renders at true native page size (via
    -- KOPTContext + native_page:getPagePix()), regardless of the document's
    -- reflow (text_wrap) setting. getPageDimensions() returns the *reflowed*
    -- size when reflow is on, which would misalign every probe fraction
    -- against the actual raster; getNativePageDimensions() never reflows.
    local page_size = Document.getNativePageDimensions(document, page) or document:getPageDimensions(page, 1, 0)
    if not page_size then
        return {}
    end

    local min_free = settings.native_detect_min_free_bytes or Settings.defaults.native_detect_min_free_bytes

    -- A full-resolution page rasterization is the single largest allocation
    -- this plugin makes. On a low-memory device it is worth skipping outright
    -- rather than risking an OOM kill, which leaves no Lua traceback -- only
    -- the memory trend in the log, if debug_mode was already on.
    local working_set = deepWorkingSetBytes(page_size.w, page_size.h, false)
    if not Memory.hasAllocationHeadroom(min_free, working_set) then
        Timing.memory(
            "native detect skipped: low memory (need >=%dMB + %dMB working set)",
            math.floor(min_free / (1024 * 1024)),
            math.ceil(working_set / (1024 * 1024))
        )
        return {}
    end

    local probes = NativeDetector.buildProbePlan(page, page_size, settings, hold_pos)
    local state = { panels = {}, by_key = {} }
    local stop = Timing.span("native detect")

    if runBatchedProbes(document, page, probes, hold_pos, state) then
        stop(string.format("%d panels from %d probes, 1 page render", #state.panels, #probes))
        if not Memory.hasHeadroom(min_free) then
            collectgarbage("collect")
        end
        return Geometry.sortReadingOrder(state.panels, settings.mode)
    end

    -- Fallback: KOReader's own entry point, one full page render per probe --
    -- up to buildProbePlan's full grid size, each one its own full-resolution
    -- rasterization. Cascading into ~29 of these right after the single
    -- shared-context render above just failed is exactly how a low-memory
    -- device gets pushed from "tight" to "killed", so memory is re-checked
    -- here too rather than assuming the single-render check above still
    -- holds. Collecting first reflects the memory the failed attempt's
    -- kc:free()/native_page:close() just released, instead of a stale
    -- pre-attempt reading.
    collectgarbage("collect")
    if not Memory.hasAllocationHeadroom(min_free, working_set) then
        Timing.memory(
            "native detect fallback skipped: low memory after batched failure (need >=%dMB + %dMB working set)",
            math.floor(min_free / (1024 * 1024)),
            math.ceil(working_set / (1024 * 1024))
        )
        stop("skipped fallback: low memory")
        return {}
    end

    if not document.getPanelFromPage then
        stop("skipped fallback: document has no getPanelFromPage")
        return {}
    end

    Timing.memory("native detect fallback start (page %d, %d probes)", page, #probes)
    state.panels, state.by_key = {}, {}
    runProbes(probes, hold_pos, state, function(pos)
        return document:getPanelFromPage(page, pos)
    end)
    stop(string.format("%d panels from %d probes, per-probe renders", #state.panels, #probes))
    Timing.memory("native detect fallback end")
    if not Memory.hasHeadroom(min_free) then
        collectgarbage("collect")
    end
    return Geometry.sortReadingOrder(state.panels, settings.mode)
end

--- Collect panels from an already decoded image using KOReader's native
--- K2PDFOpt/Leptonica panel routine.
---
--- `KOPTContext:getPanelFromPage()` is the same routine PDF/DjVu use. It
--- thresholds at the native detector's value, finds 8-connected components,
--- and selects the component under each probe point. The only adaptation here
--- is supplying `kc.src` from a BlitBuffer instead of from a document page.
---
--- @param image table KOReader BlitBuffer extracted from a reflow document.
--- @param settings PPSettings Plugin settings.
--- @return PPPanel[] panels Ordered image-space rectangles; empty if unavailable.
function NativeDetector.collectFromBlitbuffer(image, settings)
    settings = settings or Settings.defaults
    local width, height = imageDimensions(image)
    if not width or not height or width <= 0 or height <= 0 then
        return {}
    end

    local min_free = settings.native_detect_min_free_bytes or Settings.defaults.native_detect_min_free_bytes
    local source_is_greyscale = image.getType and image:getType() == require("ffi/blitbuffer").TYPE_BB8
    local working_set = deepWorkingSetBytes(width, height, source_is_greyscale)
    if not Memory.hasAllocationHeadroom(min_free, working_set) then
        Timing.memory(
            "embedded native detect skipped: low memory (need >=%dMB + %dMB working set)",
            math.floor(min_free / (1024 * 1024)),
            math.ceil(working_set / (1024 * 1024))
        )
        return {}
    end

    -- These are loaded lazily: the plain-Lua test runner deliberately has no
    -- KOReader FFI runtime, while production KOReader ships both libraries.
    local ok_runtime, KOPTContext, Blitbuffer, ffi = pcall(function()
        return require("ffi/koptcontext"), require("ffi/blitbuffer"), require("ffi")
    end)
    if not ok_runtime or not KOPTContext or not KOPTContext.k2pdfopt then
        Timing.log("embedded native detect unavailable: KOPT runtime missing")
        return {}
    end

    local probes = NativeDetector.buildProbePlan(1, { w = width, h = height }, settings)
    local state = { panels = {}, by_key = {} }
    local kc
    local stop = Timing.span("embedded native detect")
    local ok, err = pcall(function()
        kc = KOPTContext.new()
        if not copyImageToKoptSource(kc, image, Blitbuffer, ffi, KOPTContext.k2pdfopt) then
            return
        end
        local components = collectKoptComponents(kc)
        if components then
            for _, rect in ipairs(components) do
                record(state, rect)
            end
        else
            runProbes(probes, nil, state, function(pos)
                return kc:getPanelFromPage(pos)
            end)
        end
    end)
    if kc and kc.free then
        kc:free()
    end
    if not ok then
        logger.warn("[Panels+] embedded native panel detection failed:", err)
        return {}
    end

    stop(string.format("%d panels from %d probes", #state.panels, #probes))
    if not Memory.hasHeadroom(min_free) then
        collectgarbage("collect")
    end
    return Geometry.sortReadingOrder(state.panels, settings.mode)
end

return NativeDetector
