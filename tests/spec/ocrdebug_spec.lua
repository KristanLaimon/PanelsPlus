--- Specs for the opt-in OCR debug review flow (`src._ocrdebug`): capturing
--- the tap/box/word an OCR read used, prompting for a verdict once the
--- dictionary popup closes, and turning a drawn rectangle into a page-space
--- box for the session log.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Blitbuffer = require("ffi/blitbuffer")
local OcrDebug = require("src._ocrdebug")
local PanelViewer = require("src._panelviewer")
local WordFinder = require("src._wordfinder")

--- Same fixture shape as `panelviewer_refineword_spec.lua`, plus a document
--- `file` field (real KOReader documents always have one; `_ocrdebug` uses it).
local function newViewer(box, word, ocr_debug_mode)
    local koreader_sboxes = { { x = 10, y = 200, w = 80, h = 60 } }
    local viewer = PanelViewer:new{
        page = 3,
        ocr_debug_mode = ocr_debug_mode,
        reader_ui = {
            document = {
                file = "/books/example.cbz",
                configurable = { text_wrap = 0 },
            },
            view = {
                highlight = { temp = { [3] = koreader_sboxes }, temp_drawer = "invert" },
            },
            highlight = {
                is_word_selection = true,
                selected_text = {
                    text = "wrong",
                    sboxes = koreader_sboxes,
                    pboxes = koreader_sboxes,
                },
            },
        },
    }

    local original_find, original_read = WordFinder.findWordBox, WordFinder.readWord
    WordFinder.findWordBox = function() return box, { w = 1000, h = 1000 } end
    WordFinder.readWord = function() return word end

    return viewer, function()
        WordFinder.findWordBox = original_find
        WordFinder.readWord = original_read
    end
end

describe("PanelViewer:_refineWordSelection OCR debug capture", function()
    it("captures the tap point, box, and both words when ocr_debug_mode is on", function()
        local refined = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, restore = newViewer(refined, "shift", true)
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30.5, y = 220.5 })
        restore()

        local pending = viewer._ocr_debug_pending
        assert.is_true(pending ~= nil, "expected a pending OCR debug record")
        assert.equals("/books/example.cbz", pending.document)
        assert.equals(3, pending.page)
        assert.equals(30.5, pending.tap.x, "must record the exact long-press point, not the snapped box")
        assert.equals(220.5, pending.tap.y)
        assert.equals(refined.x, pending.box.x)
        assert.equals(refined.y, pending.box.y)
        assert.equals(refined.w, pending.box.w)
        assert.equals(refined.h, pending.box.h)
        assert.equals("wrong", pending.koreader_word)
        assert.equals("shift", pending.ocr_word)
    end)

    it("does not capture anything when ocr_debug_mode is off", function()
        local refined = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, restore = newViewer(refined, "shift", false)
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        assert.is_true(viewer._ocr_debug_pending == nil)
    end)

    it("captures a 'no_box' failure record when WordFinder found no box at all", function()
        -- Regression coverage for "sometimes it's not prompting": a hold
        -- that OCR gave up on entirely used to leave `_ocr_debug_pending`
        -- unset, so the verdict prompt never appeared for exactly the taps
        -- where OCR failed hardest. It must now still capture something.
        local viewer, restore = newViewer(nil, nil, true)
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        local pending = viewer._ocr_debug_pending
        assert.is_true(pending ~= nil, "expected a failure record even though OCR found nothing")
        assert.equals("no_box", pending.ocr_failed)
        assert.is_true(pending.box == nil, "no_box means there is no box to record")
        assert.equals(30, pending.tap.x)
        assert.equals(220, pending.tap.y)
    end)

    it("captures a 'no_word' failure record when a box was found but OCR read nothing from it", function()
        local box = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, restore = newViewer(box, nil, true)
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        local pending = viewer._ocr_debug_pending
        assert.is_true(pending ~= nil, "expected a failure record even though OCR read nothing")
        assert.equals("no_word", pending.ocr_failed)
        assert.equals(12, pending.box.x)
    end)
end)

describe("OcrDebug.onDictClosed verdict prompt", function()
    it("logs a correct verdict without entering rectangle capture", function()
        local logged
        local original_write = OcrDebug.writeLog
        OcrDebug.writeLog = function(entry) logged = entry end

        local viewer = { _ocr_debug_pending = { ocr_word = "shift", koreader_word = "shitt" } }
        OcrDebug.onDictClosed(viewer)
        -- The stub ConfirmBox returns its option table verbatim (see helper.lua);
        -- `UIManager:show` is a no-op, so simulate the user tapping "Yes" by
        -- invoking the callback the production code built, same as the real
        -- widget would once shown.
        local shown = require("ui/uimanager")._last_shown
        assert.is_true(shown ~= nil, "expected onDictClosed to show a confirm dialog")
        shown.ok_callback()

        OcrDebug.writeLog = original_write
        assert.equals("correct", logged.verdict)
        assert.is_true(viewer._ocr_debug_pending == nil, "pending record must be cleared once consumed")
    end)

    it("enters rectangle capture mode on a wrong verdict", function()
        local viewer = { _ocr_debug_pending = { ocr_word = "shift" } }
        OcrDebug.onDictClosed(viewer)

        local shown = require("ui/uimanager")._last_shown
        shown.cancel_callback()

        assert.is_true(viewer._ocr_debug_rect ~= nil, "expected rectangle capture mode to start")
        assert.equals("shift", viewer._ocr_debug_rect.pending.ocr_word)
    end)

    it("does nothing when there is no pending record", function()
        local viewer = { _ocr_debug_pending = nil }
        require("ui/uimanager")._last_shown = nil
        OcrDebug.onDictClosed(viewer)
        assert.is_true(require("ui/uimanager")._last_shown == nil)
    end)
end)

describe("OcrDebug rectangle capture: tap-tap corner marking", function()
    local function viewerWithTransform()
        return {
            _ocr_debug_rect = { pending = { ocr_word = "shift" } },
            screenToPageTransform = function(_, pos)
                -- 2x screen-to-page scale, offset by (100, 50), matching how
                -- PanelViewer's real transform maps a zoomed screen rect back
                -- to page space.
                return { x = pos.x * 2 + 100, y = pos.y * 2 + 50 }
            end,
        }
    end

    it("marks the first tap as the top-left corner and waits for the second", function()
        local viewer = viewerWithTransform()
        local handled = OcrDebug.handleTap(viewer, { pos = { x = 10, y = 20 } })

        assert.is_true(handled)
        assert.is_true(viewer._ocr_debug_rect ~= nil, "capture mode must stay active after only one corner")
        assert.equals(10, viewer._ocr_debug_rect.p0.x)
        assert.equals(20, viewer._ocr_debug_rect.p0.y)
    end)

    it("converts the two tapped corners to a normalized page-space box regardless of tap order", function()
        local viewer = viewerWithTransform()
        OcrDebug.handleTap(viewer, { pos = { x = 40, y = 60 } }) -- bottom-right tapped first
        local captured
        local original_prompt = OcrDebug.promptCorrectText
        OcrDebug.promptCorrectText = function(pending) captured = pending end

        local handled = OcrDebug.handleTap(viewer, { pos = { x = 10, y = 20 } }) -- top-left tapped second

        OcrDebug.promptCorrectText = original_prompt

        assert.is_true(handled)
        assert.is_true(viewer._ocr_debug_rect == nil, "capture mode must end after the second corner")
        assert.is_true(captured ~= nil)
        -- (40,60)->page(180,170), (10,20)->page(120,90); box must be the
        -- top-left/bottom-right normalized form no matter which corner was
        -- tapped first.
        assert.equals(120, captured.user_box.x)
        assert.equals(90, captured.user_box.y)
        assert.equals(60, captured.user_box.w)
        assert.equals(80, captured.user_box.h)
    end)

    it("passes through to the caller's normal handling when not capturing", function()
        local viewer = { _ocr_debug_rect = nil }
        assert.is_true(OcrDebug.handleTap(viewer, {}) == false)
    end)
end)

describe("OcrDebug.saveCropImage", function()
    local function pending()
        return {
            ts = "2026-08-19 08:00:00",
            page = 5,
            native = { w = 1000, h = 1200 },
            box = { x = 100, y = 200, w = 40, h = 20 },
            user_box = { x = 90, y = 190, w = 60, h = 30 },
        }
    end

    it("renders only the padded crop, not the whole page, draws both box outlines, and writes a PNG", function()
        Blitbuffer._invert_log = {}
        local render_args
        local viewer = {
            reader_ui = {
                document = {
                    -- Real `Document:transformRect` returns a copy of `rect`
                    -- scaled by `zoom`; only the identity (zoom-independent)
                    -- fact that matters here is that `rect.scaled_rect` ends
                    -- up set, which is what forces `renderPage` down the
                    -- "prescaled" (crop-only) path instead of rendering the
                    -- full page -- see the regression this guards against.
                    transformRect = function(document, rect, zoom, rotation)
                        return { x = math.floor(rect.x * zoom), y = math.floor(rect.y * zoom),
                                 w = rect.w * zoom, h = rect.h * zoom }
                    end,
                    renderPage = function(document, page, rect, zoom, rotation, gamma, contrast, dither)
                        render_args = { page = page, rect = rect, zoom = zoom }
                        return { bb = Blitbuffer.new(rect.scaled_rect.w, rect.scaled_rect.h, "bb8") }
                    end,
                },
            },
        }

        local relative_path = OcrDebug.saveCropImage(viewer, pending())

        assert.is_true(render_args ~= nil, "expected renderPage to be called")
        assert.equals(5, render_args.page)
        assert.is_true(render_args.rect.scaled_rect ~= nil,
            "rect must carry a scaled_rect, or renderPage silently renders the whole page instead of this crop")
        -- combined box spans x:[90,140] y:[190,220]; padded by its own size
        -- (>= 20px floor) on every side, then clamped to the native page.
        assert.is_true(render_args.rect.x < 90, "left padding must extend past the combined box")
        assert.is_true(render_args.rect.y < 190, "top padding must extend past the combined box")
        assert.is_true(render_args.rect.w < 1000, "crop must not span the whole native page width")
        -- One outline per box: 4 sides x 1px (OCR box) + 4 sides x 3px (user box).
        assert.equals(16, #Blitbuffer._invert_log, "expected both the OCR box and the user box outlined")
        assert.equals(OcrDebug.IMAGES_DIR_NAME .. "/20260819080000_p5_100_200.png", relative_path)
    end)

    it("returns nil without touching the document when there is no box/native/tap data", function()
        local viewer = { reader_ui = { document = { renderPage = function() error("must not be called") end } } }
        assert.is_true(OcrDebug.saveCropImage(viewer, { page = 5 }) == nil)
    end)

    it("falls back to a tap-centered crop, with no thin outline, for a 'no_box' failure record", function()
        Blitbuffer._invert_log = {}
        local render_args
        local viewer = {
            reader_ui = {
                document = {
                    transformRect = function(document, rect, zoom)
                        return { x = math.floor(rect.x * zoom), y = math.floor(rect.y * zoom),
                                 w = rect.w * zoom, h = rect.h * zoom }
                    end,
                    renderPage = function(document, page, rect)
                        render_args = { page = page, rect = rect }
                        return { bb = Blitbuffer.new(rect.scaled_rect.w, rect.scaled_rect.h, "bb8") }
                    end,
                },
            },
        }

        local relative_path = OcrDebug.saveCropImage(viewer, {
            ts = "2026-08-19 08:00:00",
            page = 5,
            tap = { x = 300, y = 400 },
            -- ocr_failed records have no `box` and often no `native` either
            -- (see the "no_box" capture site in `_panelviewer.lua`).
        })

        assert.is_true(render_args ~= nil, "expected a render centered on the tap point despite no box")
        assert.is_true(relative_path ~= nil)
        -- No real OCR box exists to outline; only the placeholder crop region
        -- was used to pick the render extent, so nothing should be drawn.
        assert.equals(0, #Blitbuffer._invert_log, "must not draw an outline for a synthetic (non-OCR) box")
    end)

    it("returns nil when the document can't render (e.g. reflow-mode backend)", function()
        local viewer = { reader_ui = { document = {} } }
        assert.is_true(OcrDebug.saveCropImage(viewer, pending()) == nil)
    end)
end)

describe("OcrDebug.hookDictClose window-stack poll fallback", function()
    -- Regression coverage for "sometimes it doesn't ask": KOReader threads
    -- `dict_close_callback` through the common lookup outcomes, but not every
    -- one -- most notably "No results found" dismissed any way other than its
    -- own Cancel button, which a garbled OCR read hits constantly. The poll
    -- fallback in `src._ocrdebug` is what catches those: it watches
    -- `UIManager._window_stack` return to its pre-lookup depth instead of
    -- trusting that one callback got threaded through correctly.
    local UIManager = require("ui/uimanager")

    it("fires the verdict prompt once the window stack drops back to baseline, even if dict_close_callback never ran", function()
        local viewer = { _ocr_debug_pending = { ocr_word = "shift" } }
        local reader_ui = {
            dictionary = {
                -- Simulates a dismissed "No results found" dialog: shows a
                -- widget but never calls (or is never given a working)
                -- dict_close_callback.
                onLookupWord = function() end,
            },
        }
        UIManager._window_stack = { "book" } -- baseline depth 1

        OcrDebug.hookDictClose(viewer, reader_ui)
        reader_ui.dictionary.onLookupWord() -- the lookup itself runs (unwraps back to orig)
        UIManager._window_stack = { "book", "no_results_dialog" } -- a dialog is now showing

        assert.is_true(UIManager._last_scheduled ~= nil, "expected a poll to be scheduled")
        UIManager._last_scheduled() -- tick: still open, must reschedule and not fire yet
        assert.is_true(viewer._ocr_debug_pending ~= nil, "must not fire while the dialog is still open")

        UIManager._window_stack = { "book" } -- dialog dismissed outside the Cancel button
        UIManager._last_scheduled() -- tick: back at baseline

        assert.is_true(viewer._ocr_debug_pending == nil, "expected the verdict prompt to fire once the dialog closed")
    end)

    it("does not fire twice when dict_close_callback already handled it", function()
        local viewer = { _ocr_debug_pending = { ocr_word = "shift" } }
        local seen_callback
        local reader_ui = {
            dictionary = {
                onLookupWord = function(dself, word, is_sane, boxes, hl, link, dict_close_callback)
                    seen_callback = dict_close_callback
                end,
            },
        }
        UIManager._window_stack = {}

        OcrDebug.hookDictClose(viewer, reader_ui)
        reader_ui.dictionary.onLookupWord(reader_ui.dictionary, "shift")
        seen_callback() -- the normal path: dict_close_callback fires first

        assert.is_true(viewer._ocr_debug_pending == nil, "the direct callback path must have already cleared it")

        -- The poll's own tick, arriving later, must be a no-op (idempotent).
        UIManager._last_scheduled()
        assert.is_true(viewer._ocr_debug_pending == nil)
    end)
end)
