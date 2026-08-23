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
--- This module drives the same primitives directly so a whole probe plan runs
--- against a single rasterization. Both the single shared rasterization and its
--- per-probe fallback are skipped outright when free memory is below
--- `native_detect_min_free_bytes` -- a full-resolution render is this plugin's
--- single largest allocation, and on a low-memory device it is safer to report
--- no panels than to risk an OOM kill.
---
--- @class PPNativeDetectorModule
local NativeDetector = {}

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

        local probe = function(pos)
            return kc:getPanelFromPage(pos)
        end

        runProbes(probes, hold_pos, state, probe)
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
    if not Memory.hasHeadroom(min_free) then
        Timing.memory("native detect skipped: low memory (need >=%dMB)", math.floor(min_free / (1024 * 1024)))
        return {}
    end

    local probes = NativeDetector.buildProbePlan(page, page_size, settings, hold_pos)
    local state = { panels = {}, by_key = {} }
    local stop = Timing.span("native detect")

    if runBatchedProbes(document, page, probes, hold_pos, state) then
        stop(string.format("%d panels from %d probes, 1 page render", #state.panels, #probes))
        collectgarbage("collect")
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
    if not Memory.hasHeadroom(min_free) then
        Timing.memory(
            "native detect fallback skipped: low memory after batched failure (need >=%dMB)",
            math.floor(min_free / (1024 * 1024))
        )
        stop("skipped fallback: low memory")
        return {}
    end

    Timing.memory("native detect fallback start (page %d, %d probes)", page, #probes)
    state.panels, state.by_key = {}, {}
    runProbes(probes, hold_pos, state, function(pos)
        return document:getPanelFromPage(page, pos)
    end)
    stop(string.format("%d panels from %d probes, per-probe renders", #state.panels, #probes))
    Timing.memory("native detect fallback end")
    collectgarbage("collect")
    return Geometry.sortReadingOrder(state.panels, settings.mode)
end

return NativeDetector
