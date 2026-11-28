--[[
Panels+
File: src/panelviewer/selection.lua
Name: PanelViewer
Description: Focused viewer selection methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local ImageViewer = require("ui/widget/imageviewer")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local PageBitmap = require("src._pagebitmap")
local WordFinder = require("src._wordfinder")
local _ = require("gettext")

local Constants = require("src.panelviewer.constants")
local FLOW_WARNING_TIMEOUT = Constants.FLOW_WARNING_TIMEOUT

return function(PanelViewer)
    --- Check KOReader's raw document text boxes without triggering its OCR fallback.
    --- KOReader treats a page as having a usable text layer when it has multiple
    --- lines, but its normal lookup can select the nearest word across the page.
    --- Only a word covering the hold position should win over OCR here.
    local function nativeTextAtPosition(document, page_pos)
        if
            not document
            or type(document.getPageTextBoxes) ~= "function"
            or not page_pos
            or PageBitmap.getBlockReason(document)
        then
            return false, false
        end
        local ok, lines = pcall(document.getPageTextBoxes, document, page_pos.page)
        if not ok or type(lines) ~= "table" or #lines == 0 then
            return false, false
        end
        local koreader_uses_layer = #lines > 1
        for _, line in ipairs(lines) do
            if type(line) == "table" then
                for _, word in ipairs(line) do
                    if
                        type(word) == "table"
                        and type(word.word) == "string"
                        and word.word:match("%S")
                        and type(word.x0) == "number"
                        and type(word.y0) == "number"
                        and type(word.x1) == "number"
                        and type(word.y1) == "number"
                        and word.x1 > word.x0
                        and word.y1 > word.y0
                        and word.x0 <= page_pos.x
                        and page_pos.x <= word.x1
                        and word.y0 <= page_pos.y
                        and page_pos.y <= word.y1
                    then
                        return koreader_uses_layer,
                            true,
                            {
                                word = word.word,
                                box = {
                                    x = word.x0,
                                    y = line.y0 or word.y0,
                                    w = word.x1 - word.x0,
                                    h = (line.y1 or word.y1) - (line.y0 or word.y0),
                                },
                            }
                    end
                end
            end
        end
        return koreader_uses_layer, false
    end

    --- Re-locate the word KOReader's native `highlight.onHold` just selected,
    --- using a comic-lettering-aware box finder, and re-point the selection at
    --- the tighter box before OCR/dictionary lookup runs.
    ---
    --- KOReader's own word box comes from a generic gap-detection pass tuned for
    --- justified prose (see `src._wordfinder`); it routinely mis-splits or
    --- merges words in stylized comic lettering. This only touches paging
    --- documents that OCR on the fly in the first place -- reflow mode and
    --- documents whose page-optimization pass is running are left untouched,
    --- matching `PageBitmap.getBlockReason`'s guard for the same reason.
    ---
    --- @param highlight table KOReader `ReaderHighlight` module instance.
    --- @param page_pos PPPagePosition Tap position in unrotated page coordinates.
    function PanelViewer:_refineWordSelection(highlight, page_pos, native_hit)
        local reader_ui = self.reader_ui
        local document = reader_ui and reader_ui.document
        if not document or not page_pos or not page_pos.page then
            return
        end
        if PageBitmap.getBlockReason(document) then
            return
        end

        if
            self.prefer_native_text_layer ~= false
            and (not document.configurable or document.configurable.forced_ocr ~= 1)
        then
            if native_hit == nil then
                local _, hit = nativeTextAtPosition(document, page_pos)
                native_hit = hit
            end
            if native_hit then
                return
            end
        end

        local ok, box, native = pcall(WordFinder.findWordBox, document, page_pos.page, page_pos.x, page_pos.y)
        if not ok or not box then
            return
        end

        local ok2, word = pcall(WordFinder.readWord, document, page_pos.page, box, native, self.ocr_bundled_language)
        if not ok2 or not word then
            return
        end

        local selected_text = highlight.selected_text
        if not selected_text then
            return
        end

        local orig_word = selected_text.text or ""
        selected_text.text = word
        selected_text.sboxes = { box }
        selected_text.pboxes = { box }

        -- Re-point ReaderView's temporary highlight at the refined box too.
        -- `ReaderHighlight:onHold` stored a *reference* to the selection's
        -- previous `sboxes` table in `view.highlight.temp[page]`, and that table
        -- -- not `selected_text.sboxes` -- is what `paintHighlights` draws.
        -- Replacing `sboxes` above therefore leaves the painted box behind on
        -- KOReader's original one, whose y/h come from the whole *text line*
        -- rather than the word (`KoptInterface:getWordFromBoxes` takes them from
        -- the line box), so the underline lands off the word it just looked up.
        local view_highlight = reader_ui.view and reader_ui.view.highlight
        if view_highlight and view_highlight.temp and view_highlight.temp[page_pos.page] then
            view_highlight.temp[page_pos.page] = selected_text.sboxes
        end

        if not Timing.enabled then
            return
        end

        WordFinder.logDiagnostic(string.format("Refined selection: '%s' -> '%s'", orig_word, tostring(word)), {
            box = string.format("(x=%.1f,y=%.1f,w=%.1f,h=%.1f)", box.x, box.y, box.w, box.h),
        })

        local ok_notif, Notification = pcall(require, "ui/widget/notification")
        if ok_notif and Notification and Notification.new then
            pcall(function()
                UIManager:show(Notification:new({
                    text = string.format("[WordFinder] '%s' (%dx%d)", word, math.floor(box.w), math.floor(box.h)),
                    timeout = 2,
                }))
            end)
        end
    end

    function PanelViewer:_cancelPhraseHold()
        if self._phrase_hold_action then
            UIManager:unschedule(self._phrase_hold_action)
            self._phrase_hold_action = nil
        end
    end

    function PanelViewer:_startPhraseHold(highlight, page_pos)
        self:_cancelPhraseHold()
        self._phrase_selected = nil
        -- Replace the reader's long-hold menu timer within this viewer only.
        if highlight._resetHoldTimer then
            highlight:_resetHoldTimer(true)
        end
        self._phrase_hold_action = function()
            self._phrase_hold_action = nil
            if not self._panels_plus_text_holding or self._panels_plus_closed then
                return
            end
            local selection = highlight.selected_text
            local seed = selection and selection.sboxes and selection.sboxes[1]
            local document = self._embedded_ocr_document or self.reader_ui.document
            if not seed or PageBitmap.getBlockReason(document) then
                return
            end
            local ok, text, boxes =
                pcall(WordFinder.readPhrase, document, page_pos.page, seed, self.ocr_bundled_language)
            if not ok or not text then
                return
            end
            selection.text, selection.sboxes, selection.pboxes = text, boxes, boxes
            highlight.is_word_selection = false
            self._phrase_selected = true
            local painted = not self.embedded_source_image and self.reader_ui.view.highlight
            if painted and painted.temp then
                painted.temp[page_pos.page] = boxes
            end
            UIManager:setDirty(self, "ui")
        end
        -- The initial hold gesture normally takes half a second to arrive.
        local settings = G_reader_settings
        local initial_ms = settings and settings:readSetting("ges_hold_interval_ms") or 500
        UIManager:scheduleIn(math.max(0, 4 - initial_ms / 1000), self._phrase_hold_action)
    end

    --- Explain why a transition preview has no second panel to visit.
    function PanelViewer:showSmoothPreviewUnavailableWarning(single_panel_book)
        UIManager:show(require("ui/widget/infomessage"):new({
            text = single_panel_book
                    and _(
                        "Preview can't be shown in this book because it contains only one panel. Select another document/book."
                    )
                or _(
                    "Preview can't be shown because only one panel is available in the current panel view. Select another document/book."
                ),
            timeout = FLOW_WARNING_TIMEOUT,
        }))
        return true
    end

    --- Explain why OCR selection and its model picker are unavailable.
    function PanelViewer:showTextSelectionDisabledWarning()
        local text = _(
            "OCR text selection is disabled. Enable ‘Touch & hold text selection’ in ‘More Config…’ to use OCR and select an OCR model."
        )
        UIManager:show(require("ui/widget/infomessage"):new({ text = text, timeout = FLOW_WARNING_TIMEOUT }))
        return true
    end

    --- OCR extracted images without passing image positions to ReaderRolling's XPointer API.
    function PanelViewer:_holdEmbeddedImage(ges)
        local pos = self:screenToPageTransform(ges and ges.pos)
        if not pos then
            return true
        end
        self._embedded_selection = nil
        self._panels_plus_text_holding = nil
        self._embedded_ocr_document = self._embedded_ocr_document
            or require("src._imagedocument").new(self.embedded_source_image)
        local document = self._embedded_ocr_document
        local ok, box, native = pcall(WordFinder.findWordBox, document, 1, pos.x, pos.y)
        if not ok or not box then
            return true
        end
        local read_ok, word = pcall(WordFinder.readWord, document, 1, box, native, self.ocr_bundled_language)
        if not read_ok or not word then
            return true
        end
        local selection = { text = word, sboxes = { box }, pboxes = { box } }
        self._embedded_selection = selection
        self._panels_plus_text_holding = true
        self:_startPhraseHold({ selected_text = selection }, pos)
        UIManager:setDirty(self, "ui")
        return true
    end

    --- Delegate touch and hold gestures to KOReader's native text selection / dictionary.
    ---
    --- @param arg any Gesture argument.
    --- @param ges table Gesture event with `pos`.
    --- @return boolean handled Whether text selection or dictionary lookup consumed the event.
    function PanelViewer:onHold(arg, ges)
        self:_cancelPhraseHold()
        self._phrase_selected = nil
        if self.hold_text_selection == false then
            self._panels_plus_hold_consumed = true
            return self:showTextSelectionDisabledWarning()
        end
        -- Once text selection is enabled, a stationary hold belongs to the OCR
        -- path even if neither KOReader nor WordFinder can find a word. Remember
        -- that fact so its paired release cannot reach ImageViewer's deliberate
        -- full-refresh-on-hold behavior.
        self._panels_plus_hold_consumed = true

        if self.embedded_source_image then
            return self:_holdEmbeddedImage(ges)
        end

        local reader_ui = self.reader_ui
        local highlight = reader_ui and reader_ui.highlight
        if not highlight or not reader_ui.view then
            return ImageViewer.onHold and ImageViewer.onHold(self, arg, ges)
        end

        local page_pos = self:screenToPageTransform(ges and ges.pos)
        if not page_pos then
            return true
        end

        local orig_screenToPage = reader_ui.view.screenToPageTransform
        local orig_panel_zoom_enabled = highlight.panel_zoom_enabled

        reader_ui.view.screenToPageTransform = function(view, pos)
            return page_pos
        end
        highlight.panel_zoom_enabled = false

        -- KOReader performs its first word lookup inside onHold. Point that
        -- lookup at the selected bundle too, so a fresh install can select text
        -- without language files in KOReader's data/tessdata directory.
        local document = reader_ui.document
        local interface = document and document.koptinterface
        local configurable = document and document.configurable
        local bundled_dir, bundled_model = WordFinder.selectedModel(self.ocr_bundled_language)
        local original_language = configurable and configurable.doc_language
        local original_dir = interface and rawget(interface, "tessocr_data")
        local original_forced_ocr = configurable and configurable.forced_ocr
        local native_layer, native_hit, native_word = nativeTextAtPosition(document, page_pos)
        if self.prefer_native_text_layer ~= false and native_hit and not native_layer and original_forced_ocr ~= 1 then
            -- KOReader's getTextBoxes ignores a valid text layer with just one
            -- line, so carry that word into its usual release/dictionary flow.
            if type(highlight.clear) == "function" then
                highlight:clear()
            end
            highlight.hold_pos = page_pos
            highlight.allow_hold_pan_corner_scroll = false
            highlight.is_word_selection = true
            highlight.selected_link = nil
            highlight.selected_text = {
                text = native_word.word,
                pos0 = page_pos,
                pos1 = page_pos,
                sboxes = { native_word.box },
                pboxes = { native_word.box },
            }
            local painted = reader_ui.view.highlight
            if painted and painted.temp then
                painted.temp[page_pos.page] = highlight.selected_text.sboxes
            end
            if type(highlight._resetHoldTimer) == "function" then
                highlight:_resetHoldTimer()
            end
            self._panels_plus_text_holding = true
            UIManager:setDirty(self, "ui")
            reader_ui.view.screenToPageTransform = orig_screenToPage
            highlight.panel_zoom_enabled = orig_panel_zoom_enabled
            return true
        end
        if configurable and native_layer and (self.prefer_native_text_layer == false or not native_hit) then
            configurable.forced_ocr = 1
        end
        if bundled_dir and configurable and interface then
            configurable.doc_language = bundled_model
            interface.tessocr_data = bundled_dir
        end
        local ok, handled = pcall(highlight.onHold, highlight, arg, ges)
        if bundled_dir and configurable and interface then
            configurable.doc_language = original_language
            interface.tessocr_data = original_dir
        end
        if configurable then
            configurable.forced_ocr = original_forced_ocr
        end

        reader_ui.view.screenToPageTransform = orig_screenToPage
        highlight.panel_zoom_enabled = orig_panel_zoom_enabled

        -- Current KOReader returns true here after it has selected a word. Older
        -- releases have also existed where the return value was not reliable, so
        -- accept their state-based success signal as well. Do *not* treat a bare
        -- true as text selection: ReaderHighlight also returns true after opening
        -- its ImageViewer for an image, which has no selected_text to release to
        -- the dictionary.
        local selected_text = highlight.selected_text
        local selected_word = selected_text
            and type(selected_text.text) == "string"
            and selected_text.text:match("%S") ~= nil
        if ok and selected_word and handled ~= false then
            self._panels_plus_text_holding = true
            if highlight.is_word_selection then
                if self.prefer_native_text_layer == false or not native_hit or original_forced_ocr == 1 then
                    self:_startPhraseHold(highlight, page_pos)
                end
                self:_refineWordSelection(highlight, page_pos, native_hit)
            end
            UIManager:setDirty(self, "ui")
            return true
        end

        -- KOReader's own word detection failed (getWordFromPosition returned nil).
        -- This is common on Kindle/e-ink for image-only pages (CBZ, manga) where
        -- k2pdfopt's generic word-box finder cannot detect comic lettering.
        -- Fall back to Panels+'s own WordFinder, which is built for this case.
        if not PageBitmap.getBlockReason(document) and page_pos and page_pos.page then
            local wf_ok, box, native = pcall(WordFinder.findWordBox, document, page_pos.page, page_pos.x, page_pos.y)
            if wf_ok and box then
                local word_ok, word =
                    pcall(WordFinder.readWord, document, page_pos.page, box, native, self.ocr_bundled_language)
                if word_ok and word then
                    -- Build a synthetic selection identical to what ReaderHighlight
                    -- would have built, so onHoldRelease triggers dictionary lookup.
                    highlight.hold_pos = page_pos
                    highlight.is_word_selection = true
                    highlight.selected_text = {
                        text = word,
                        pos0 = { page = page_pos.page, x = page_pos.x, y = page_pos.y },
                        pos1 = { page = page_pos.page, x = page_pos.x, y = page_pos.y },
                        sboxes = { box },
                        pboxes = { box },
                    }
                    if reader_ui.view and reader_ui.view.highlight and reader_ui.view.highlight.temp then
                        reader_ui.view.highlight.temp[page_pos.page] = highlight.selected_text.sboxes
                    end
                    self._panels_plus_text_holding = true
                    self:_startPhraseHold(highlight, page_pos)
                    UIManager:setDirty(self, "ui")
                    return true
                end
            end
        end

        -- A failed OCR lookup must not fall through to ImageViewer:onHold. Its
        -- release handler deliberately issues a full e-ink refresh for an
        -- unmoved hold, which is the Kindle-only-looking flash users see instead
        -- of a lookup. A native handler that returned true already owns the
        -- gesture (for example, it opened an image viewer); otherwise consume the
        -- unsuccessful text-selection gesture quietly.
        return true
    end

    --- Forward touch drag during text selection inside a zoomed panel.
    ---
    --- @param arg any Gesture argument.
    --- @param ges table Gesture event.
    --- @return boolean handled Whether the drag was handled.
    function PanelViewer:onHoldPan(arg, ges)
        self:_cancelPhraseHold()
        self._phrase_selected = nil
        if not self._panels_plus_text_holding then
            return ImageViewer.onHoldPan and ImageViewer.onHoldPan(self, arg, ges)
        end

        if self.embedded_source_image then
            return true
        end
        local reader_ui = self.reader_ui
        local highlight = reader_ui and reader_ui.highlight
        if not highlight or not reader_ui.view or type(highlight.onHoldPan) ~= "function" then
            return true
        end

        local page_pos = self:screenToPageTransform(ges and ges.pos)
        if not page_pos then
            return true
        end

        local orig_screenToPage = reader_ui.view.screenToPageTransform
        reader_ui.view.screenToPageTransform = function(view, pos)
            return page_pos
        end

        pcall(highlight.onHoldPan, highlight, arg, ges)

        reader_ui.view.screenToPageTransform = orig_screenToPage
        UIManager:setDirty(self, "ui")
        return true
    end

    --- Forward touch release after hold to complete text selection or dictionary lookup.
    ---
    --- @param arg any Gesture argument.
    --- @param ges table Gesture event.
    --- @return boolean handled Whether the release was handled.
    function PanelViewer:onHoldRelease(arg, ges)
        self:_cancelPhraseHold()
        if not self._panels_plus_text_holding then
            if self._panels_plus_hold_consumed then
                self._panels_plus_hold_consumed = nil
                return true
            end
            return ImageViewer.onHoldRelease and ImageViewer.onHoldRelease(self, arg, ges)
        end

        self._panels_plus_text_holding = nil
        self._panels_plus_hold_consumed = nil
        if self.embedded_source_image then
            local selection = self._embedded_selection
            self._embedded_selection = nil
            local ui = self.reader_ui
            if selection and self._phrase_selected and ui.highlight then
                pcall(ui.highlight.onTranslateText, ui.highlight, selection.text)
            elseif selection and ui.dictionary then
                local boxes = {}
                for _, box in ipairs(selection.sboxes) do
                    local screen_box = self:pageToScreenTransform(box)
                    if screen_box then
                        boxes[#boxes + 1] = screen_box
                    end
                end
                pcall(ui.dictionary.onLookupWord, ui.dictionary, selection.text, false, boxes)
            end
            self._phrase_selected = nil
            UIManager:setDirty(self, "ui")
            return true
        end
        local reader_ui = self.reader_ui
        local highlight = reader_ui and reader_ui.highlight
        if self._phrase_selected and highlight and type(highlight.onTranslateText) == "function" then
            self._phrase_selected = nil
            if highlight._resetHoldTimer then
                highlight:_resetHoldTimer(true)
            end
            pcall(highlight.onTranslateText, highlight, highlight.selected_text.text)
        elseif highlight and type(highlight.onHoldRelease) == "function" then
            pcall(highlight.onHoldRelease, highlight, arg, ges)
        end
        UIManager:setDirty(self, "ui")
        return true
    end

    --- Forward touch release after dragging text selection inside a zoomed panel.
    ---
    --- @param arg any Gesture argument.
    --- @param ges table Gesture event.
    --- @return boolean handled Whether the release was handled.
    function PanelViewer:onHoldPanRelease(arg, ges)
        return self:onHoldRelease(arg, ges)
    end
end
