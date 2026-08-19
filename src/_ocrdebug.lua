local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Geom = require("ui/geometry")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local util = require("util")
local JSON = require("json")
local logger = require("logger")
local _ = require("gettext")

--- Opt-in OCR feedback loop for `PanelViewer`'s comic-lettering OCR path.
---
--- While `ocr_debug_mode` is on, every dictionary lookup that went through
--- `PanelViewer:_refineWordSelection` (i.e. OCR ran) is followed, once the
--- dictionary popup is closed, by a "was this right?" prompt. A "no" answer
--- asks the user to draw the correct word box and type the correct text, and
--- everything gathered -- including the exact long-press point, since where
--- inside a word a tap lands is a suspected source of inconsistent OCR -- is
--- appended as one JSON line to `OCR.debug.session.log`, for later review
--- across a whole scanning session.
---
--- @class PPOcrDebug
local OcrDebug = {}

--- Directory this file itself lives in (`<plugin_root>/src`), independent of
--- whatever directory KOReader happened to be launched from -- `debug.getinfo`
--- reports this module's own source path, which is always inside the plugin
--- install, so the log lands in one predictable, easy-to-find place instead
--- of wherever the launching process's cwd was.
---
--- @return string dir Plugin root directory, or "." if it could not be determined.
local function pluginRootDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)[/\\]src[/\\]_ocrdebug%.lua$") or "."
end

OcrDebug.LOG_PATHS = { pluginRootDir() .. "/OCR.debug.session.log" }
--- Folder the exact OCR crop for each "incorrect" verdict is saved into, so
--- a log entry's `image` field can be opened straight from the plugin root.
OcrDebug.IMAGES_DIR_NAME = "OCR.debug.session.images"
OcrDebug.IMAGES_DIR = pluginRootDir() .. "/" .. OcrDebug.IMAGES_DIR_NAME
-- Zoom the saved crop is rendered at, well above document resolution: OCR
-- crops are tiny (a word or two), and this is meant to be read by eye later.
local IMAGE_ZOOM = 4.0
-- Padding kept around the combined OCR box + user-drawn box, as a fraction
-- of the combined box's own size, so the saved crop shows surrounding
-- context (neighbouring words, bubble edge) instead of just bare ink.
local IMAGE_PAD_RATIO = 1.0

--- Append one JSON-encoded record to the session log.
---
--- A public field (not a local) so specs can stub it out and assert on the
--- record shape without touching the filesystem.
---
--- @param entry table Record to persist.
function OcrDebug.writeLog(entry)
    local ok, line = pcall(JSON.encode, entry)
    if not ok or not line then
        logger.warn("[Panels+ OCRDebug] failed to encode log entry:", line)
        return
    end
    for _, path in ipairs(OcrDebug.LOG_PATHS) do
        local f = io.open(path, "a")
        if f then
            f:write(line .. "\n")
            f:close()
        end
    end
end

--- Stash everything useful about an OCR read for later review, keyed to the
--- `PanelViewer` instance that produced it. Called right after
--- `WordFinder.readWord` succeeds, before the result reaches the dictionary.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param info table Fields: document (string), page (number), tap (table x/y,
---   the raw long-press point in page coordinates), box (table x/y/w/h, the
---   box OCR actually ran on), native (table w/h, native page size),
---   koreader_word (string|nil), ocr_word (string).
function OcrDebug.capture(panel_viewer, info)
    panel_viewer._ocr_debug_pending = {
        ts = os.date("%Y-%m-%d %H:%M:%S"),
        document = info.document,
        page = info.page,
        tap = info.tap,
        box = info.box,
        native = info.native,
        koreader_word = info.koreader_word,
        ocr_word = info.ocr_word,
        diagnostics = info.diagnostics,
    }
end

--- Stash a hold that never produced an OCR word to confirm/deny -- either
--- `WordFinder.findWordBox` found no box at all ("no_box"), or it found one
--- but `WordFinder.readWord` came back empty ("no_word"). Without this, a
--- long-press that OCR gave up on entirely never sets `_ocr_debug_pending`,
--- so the review prompt silently never appears for exactly the taps where
--- OCR failed hardest -- worth capturing at least as much as a wrong read.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param info table Fields: document, page, tap (as `OcrDebug.capture`),
---   box (table|nil, only set for "no_word"), native (table|nil),
---   reason ("no_box"|"no_word").
function OcrDebug.captureFailure(panel_viewer, info)
    panel_viewer._ocr_debug_pending = {
        ts = os.date("%Y-%m-%d %H:%M:%S"),
        document = info.document,
        page = info.page,
        tap = info.tap,
        box = info.box,
        native = info.native,
        koreader_word = nil,
        ocr_word = nil,
        ocr_failed = info.reason,
        diagnostics = info.diagnostics,
    }
end

--- Ask whether the OCR read was correct, once the dictionary popup that
--- looked it up has closed. When OCR produced no word at all
--- (`OcrDebug.captureFailure`), there is nothing to confirm, so this skips
--- straight to drawing the correct box instead of asking a "was it right?"
--- question that can only ever be "no".
---
--- @param panel_viewer table `PanelViewer` instance.
function OcrDebug.onDictClosed(panel_viewer)
    local pending = panel_viewer._ocr_debug_pending
    panel_viewer._ocr_debug_pending = nil
    if not pending then
        return
    end

    if pending.ocr_failed then
        UIManager:show(Notification:new{
            text = _("Panels+ OCR debug: no word was read here. Draw the correct box and type what it says."),
            timeout = 4,
        })
        OcrDebug.startRectCapture(panel_viewer, pending)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Panels+ OCR debug\n\nWas the OCR word correct?") .. "\n\n\"" .. tostring(pending.ocr_word) .. "\"",
        ok_text = _("Yes, correct"),
        cancel_text = _("No, wrong"),
        ok_callback = function()
            pending.verdict = "correct"
            OcrDebug.writeLog(pending)
        end,
        cancel_callback = function()
            OcrDebug.startRectCapture(panel_viewer, pending)
        end,
    })
end

--- Half-width, in screen pixels, of the crosshair marker drawn at the first
--- tapped corner while waiting for the second one.
local MARKER_HALF = 8

--- Enter rectangle-marking mode: the next two taps inside the viewer are
--- read as the word box's top-left and bottom-right corners instead of
--- triggering navigation or text selection.
---
--- A tap-tap flow (rather than a press-and-drag one) is used deliberately:
--- drawing a box by holding and dragging shares its gesture with this same
--- viewer's text-selection hold, which requires the touch/click to stay down
--- for a beat before it "arms" -- easy to get wrong, and on a mouse/emulator
--- a plain click-drag never arms it at all, so nothing visibly happens. Two
--- taps need no timing and work identically with touch or a mouse.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param pending table Record being annotated, from `OcrDebug.capture`.
function OcrDebug.startRectCapture(panel_viewer, pending)
    panel_viewer._ocr_debug_rect = { pending = pending }
    -- A toast `Notification` (unlike `InfoMessage`) registers no gesture
    -- handlers of its own and lets taps fall straight through to whatever is
    -- underneath, so it can't eat the very first corner tap it is telling
    -- the user to make.
    UIManager:show(Notification:new{
        text = _("Tap the correct word's top-left corner, then tap its bottom-right corner."),
        timeout = 4,
    })
end

--- Record one corner tap; on the second, finalize the box and prompt for the
--- correct transcription.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param ges table Gesture event with `pos`.
--- @return boolean handled Always true: consumes the tap while capturing.
function OcrDebug.handleTap(panel_viewer, ges)
    local rect = panel_viewer._ocr_debug_rect
    if not rect then
        return false
    end
    local pos = ges and ges.pos
    if not pos then
        return true
    end

    if not rect.p0 then
        rect.p0 = pos
        UIManager:setDirty(panel_viewer, "ui")
        UIManager:show(Notification:new{
            text = _("Top-left corner marked. Now tap the bottom-right corner."),
            timeout = 3,
        })
        return true
    end

    local p0 = rect.p0
    local pending = rect.pending
    panel_viewer._ocr_debug_rect = nil
    UIManager:setDirty(panel_viewer, "ui")

    if type(panel_viewer.screenToPageTransform) == "function" then
        local page0 = panel_viewer:screenToPageTransform(p0)
        local page1 = panel_viewer:screenToPageTransform(pos)
        if page0 and page1 then
            local x0, x1 = math.min(page0.x, page1.x), math.max(page0.x, page1.x)
            local y0, y1 = math.min(page0.y, page1.y), math.max(page0.y, page1.y)
            if (x1 - x0) >= 1 and (y1 - y0) >= 1 then
                pending.user_box = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
            end
        end
    end

    pending.image = OcrDebug.saveCropImage(panel_viewer, pending)
    OcrDebug.promptCorrectText(pending)
    return true
end

--- Draw a crosshair at the first tapped corner, so there is visible
--- confirmation the tap registered while waiting for the second one.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param bb table Blitbuffer being painted to.
--- @param x number Paint offset x (unused: marker coordinates are already screen-absolute).
--- @param y number Paint offset y (unused: marker coordinates are already screen-absolute).
function OcrDebug.paint(panel_viewer, bb, x, y) -- luacheck: ignore x y
    local rect = panel_viewer._ocr_debug_rect
    if not rect or not rect.p0 then
        return
    end
    local cx, cy = rect.p0.x, rect.p0.y
    bb:invertRect(cx - MARKER_HALF, cy, MARKER_HALF * 2 + 1, 1)
    bb:invertRect(cx, cy - MARKER_HALF, 1, MARKER_HALF * 2 + 1)
end

--- Convert a native-page-space box to pixel coordinates inside the rendered
--- tile, using the same floor/scale rounding `Document:renderPage` itself
--- used to place `scaled_rect` (see `WordFinder.findWordBox`, which derives
--- its own tile-local coordinates the same way).
---
--- @param box PPRect Box in native page coordinates.
--- @param scaled_rect table Crop's `scaled_rect` (has `x`/`y` at `zoom`).
--- @param zoom number Zoom the tile was rendered at.
--- @return integer x, integer y, integer w, integer h Tile-local pixel box.
local function toTileRect(box, scaled_rect, zoom)
    local x = math.floor(box.x * zoom + 0.001) - scaled_rect.x
    local y = math.floor(box.y * zoom + 0.001) - scaled_rect.y
    local w = math.max(1, math.floor(box.w * zoom + 0.5))
    local h = math.max(1, math.floor(box.h * zoom + 0.5))
    return x, y, w, h
end

--- Invert a `thickness`-pixel-wide rectangle outline, clamped to the buffer.
---
--- @param bb table Blitbuffer to draw into.
--- @param x integer Box left, in bb pixels.
--- @param y integer Box top, in bb pixels.
--- @param w integer Box width, in bb pixels.
--- @param h integer Box height, in bb pixels.
--- @param thickness integer Border thickness, in bb pixels.
local function drawBoxOutline(bb, x, y, w, h, thickness)
    local bb_w, bb_h = bb.w, bb.h
    x = math.max(0, math.min(x, bb_w - 1))
    y = math.max(0, math.min(y, bb_h - 1))
    w = math.max(1, math.min(w, bb_w - x))
    h = math.max(1, math.min(h, bb_h - y))
    for t = 0, thickness - 1 do
        if y + t < bb_h then bb:invertRect(x, y + t, w, 1) end
        if y + h - 1 - t >= 0 then bb:invertRect(x, y + h - 1 - t, w, 1) end
        if x + t < bb_w then bb:invertRect(x + t, y, 1, h) end
        if x + w - 1 - t >= 0 then bb:invertRect(x + w - 1 - t, y, 1, h) end
    end
end

--- Render the exact pixels an "incorrect" OCR read used -- padded to also
--- cover the box the user drew as correct -- and save it as a PNG next to
--- the session log, so a log entry can be matched to a picture instead of
--- just coordinates.
---
--- The two boxes are burned into the saved image as outlines so it is
--- self-describing in any plain image viewer, with no need to cross-reference
--- the log: a **thin (1px)** border is the box OCR actually read from, a
--- **thick (3px)** border is the box you drew as the correct one.
---
--- @param panel_viewer table `PanelViewer` instance (for `reader_ui.document`).
--- @param pending table Record being annotated; needs `page` and either `box`
---   (a real OCR box) or `tap` (from `OcrDebug.captureFailure`, when OCR
---   never produced a box to begin with).
--- @return string|nil relative_path Path under the plugin root, or nil on failure.
function OcrDebug.saveCropImage(panel_viewer, pending)
    local document = panel_viewer.reader_ui and panel_viewer.reader_ui.document
    local native = pending.native
    -- `pending.box` is nil for a `captureFailure("no_box")` record: OCR never
    -- found a box at all, so there is nothing to crop around except the raw
    -- long-press point. Fall back to a small placeholder region there purely
    -- to pick the crop's extent -- it is never drawn as an outline (only a
    -- *real* `pending.box` is, below), so it can't be mistaken for one.
    local crop_box = pending.box or (pending.tap and {
        x = pending.tap.x - 20, y = pending.tap.y - 10, w = 40, h = 20,
    })
    if not document or not crop_box or type(document.renderPage) ~= "function" then
        return nil
    end

    local x0, y0 = crop_box.x, crop_box.y
    local x1, y1 = crop_box.x + crop_box.w, crop_box.y + crop_box.h
    if pending.user_box then
        x0 = math.min(x0, pending.user_box.x)
        y0 = math.min(y0, pending.user_box.y)
        x1 = math.max(x1, pending.user_box.x + pending.user_box.w)
        y1 = math.max(y1, pending.user_box.y + pending.user_box.h)
    end

    local pad_x = math.max(20, (x1 - x0) * IMAGE_PAD_RATIO)
    local pad_y = math.max(20, (y1 - y0) * IMAGE_PAD_RATIO)
    local cx0 = math.max(0, x0 - pad_x)
    local cy0 = math.max(0, y0 - pad_y)
    local cx1 = native and math.min(native.w, x1 + pad_x) or (x1 + pad_x)
    local cy1 = native and math.min(native.h, y1 + pad_y) or (y1 + pad_y)
    local crop_w, crop_h = cx1 - cx0, cy1 - cy0
    if crop_w < 4 or crop_h < 4 then
        return nil
    end

    local rect = Geom:new{ x = cx0, y = cy0, w = crop_w, h = crop_h }
    -- `Document:renderPage` only actually renders `rect` when it is
    -- "prescaled" (carries its own `scaled_rect`); otherwise it renders the
    -- *whole page* whenever that fits in the tile cache (which a manga page
    -- always does) and `rect` is silently ignored. `WordFinder.findWordBox`
    -- avoids this the same way: pre-computing `scaled_rect` here is what
    -- actually makes this a crop instead of a full-page render.
    rect.scaled_rect = document:transformRect(rect, IMAGE_ZOOM, 0)
    local ok_render, tile = pcall(document.renderPage, document, pending.page, rect, IMAGE_ZOOM, 0, 1.0, 1.0, false)
    if not ok_render or not tile or not tile.bb then
        logger.warn("[Panels+ OCRDebug] failed to render debug crop:", tile)
        return nil
    end

    -- `tile.bb` may be a bitmap `DocCache` hands out again later for the
    -- exact same page/rect/zoom; draw onto a private copy instead of it
    -- directly, so annotating this debug snapshot can never leave stray
    -- outlines burned into a bitmap some other, unrelated render reuses.
    local draw_bb = tile.bb
    local ok_copy, copy = pcall(function()
        local target = Blitbuffer.new(tile.bb.w, tile.bb.h, tile.bb:getType())
        target:blitFrom(tile.bb, 0, 0, 0, 0, tile.bb.w, tile.bb.h)
        return target
    end)
    if ok_copy and copy then
        draw_bb = copy
    end

    pcall(function()
        -- Only a *real* OCR box gets the thin outline -- `crop_box` may be
        -- the synthetic tap-centered placeholder above, which was never an
        -- OCR result and would be misleading to draw as if it were one.
        if pending.box then
            local ox, oy, ow, oh = toTileRect(pending.box, rect.scaled_rect, IMAGE_ZOOM)
            drawBoxOutline(draw_bb, ox, oy, ow, oh, 1)
        end
        if pending.user_box then
            local ux, uy, uw, uh = toTileRect(pending.user_box, rect.scaled_rect, IMAGE_ZOOM)
            drawBoxOutline(draw_bb, ux, uy, uw, uh, 3)
        end
    end)

    if not util.makePath(OcrDebug.IMAGES_DIR) then
        if copy then pcall(copy.free, copy) end
        return nil
    end

    local filename = string.format("%s_p%s_%d_%d.png", pending.ts:gsub("[^%d]", ""),
        tostring(pending.page or "0"), math.floor(crop_box.x or 0), math.floor(crop_box.y or 0))
    local ok_write = pcall(draw_bb.writePNG, draw_bb, OcrDebug.IMAGES_DIR .. "/" .. filename)
    if copy then pcall(copy.free, copy) end
    if not ok_write then
        logger.warn("[Panels+ OCRDebug] failed to write debug crop PNG")
        return nil
    end

    return OcrDebug.IMAGES_DIR_NAME .. "/" .. filename
end

--- Ask what is actually written in the drawn box, then persist the record.
---
--- @param pending table Record being annotated.
function OcrDebug.promptCorrectText(pending)
    pending.verdict = "incorrect"
    local dialog
    dialog = InputDialog:new{
        title = _("Panels+ OCR debug"),
        description = _("What is actually written in the box you drew?"),
        input = "",
        input_hint = _("Correct word/text"),
        buttons = {
            {
                {
                    text = _("Skip"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        OcrDebug.writeLog(pending)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        pending.correct_text = dialog:getInputText()
                        UIManager:close(dialog)
                        OcrDebug.writeLog(pending)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Poll interval and attempt cap for `pollForDictClose` below: 0.5s steps,
-- giving up after 2 minutes if the window stack never comes back down (the
-- panel viewer got closed out from under the lookup, KOReader hung, etc).
local POLL_INTERVAL_S = 0.5
local POLL_MAX_ATTEMPTS = 240

--- Fallback safety net for the `dict_close_callback` wrap in
--- `OcrDebug.hookDictClose`: KOReader threads that callback through the
--- *common* lookup outcomes (a result, "no dictionaries enabled", a
--- quick dismiss), but several less common ones do not -- most importantly
--- "No results found" dismissed by tapping outside it or a back gesture
--- rather than its own Cancel button -- which is exactly the outcome a
--- badly garbled OCR read tends to produce, i.e. precisely the cases this
--- feature most needs to catch. Watching KOReader's own window stack return
--- to the depth it was at just before the lookup started catches every one
--- of those too, since it observes actual UI state instead of trusting one
--- specific internal callback chain.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param baseline_depth integer `#UIManager._window_stack` just before the lookup started.
--- @param attempts_left integer Remaining poll attempts before giving up.
local function pollForDictClose(panel_viewer, baseline_depth, attempts_left)
    if not panel_viewer._ocr_debug_pending then
        return -- already handled via the direct dict_close_callback path
    end
    if #UIManager._window_stack > baseline_depth then
        if attempts_left <= 0 then
            logger.warn("[Panels+ OCRDebug] gave up waiting for the dictionary popup to close")
            panel_viewer._ocr_debug_pending = nil
            return
        end
        UIManager:scheduleIn(POLL_INTERVAL_S, function()
            pollForDictClose(panel_viewer, baseline_depth, attempts_left - 1)
        end)
        return
    end
    OcrDebug.onDictClosed(panel_viewer)
end

--- Wrap `reader_ui.dictionary.onLookupWord` for exactly one call so that,
--- once the popup it opens is closed, `OcrDebug.onDictClosed` runs -- but
--- only when there is a pending OCR record to review. Also starts the
--- `pollForDictClose` fallback above as a safety net, since `onDictClosed`
--- clearing `_ocr_debug_pending` makes both paths naturally idempotent:
--- whichever notices the popup closed first wins, the other is a no-op.
---
--- @param panel_viewer table `PanelViewer` instance.
--- @param reader_ui table KOReader reader UI object.
function OcrDebug.hookDictClose(panel_viewer, reader_ui)
    local pending = panel_viewer._ocr_debug_pending
    local dictionary = reader_ui and reader_ui.dictionary
    if not pending or not dictionary or type(dictionary.onLookupWord) ~= "function" then
        return
    end

    local orig_lookup = dictionary.onLookupWord
    dictionary.onLookupWord = function(dself, word, is_sane, boxes, hl, link, dict_close_callback)
        dictionary.onLookupWord = orig_lookup
        local wrapped_close = function()
            if dict_close_callback then
                pcall(dict_close_callback)
            end
            OcrDebug.onDictClosed(panel_viewer)
        end
        return orig_lookup(dself, word, is_sane, boxes, hl, link, wrapped_close)
    end

    local baseline_depth = #UIManager._window_stack
    UIManager:scheduleIn(POLL_INTERVAL_S, function()
        pollForDictClose(panel_viewer, baseline_depth, POLL_MAX_ATTEMPTS)
    end)
end

return OcrDebug
