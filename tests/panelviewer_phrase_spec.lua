local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local WordFinder = require("src._wordfinder")
local UIManager = require("ui/uimanager")

local function fixture()
    local doc = {
        configurable = { text_wrap = 0 },
        getTextBoxes = function()
            return {
                {
                    y0 = 10,
                    y1 = 30,
                    { x0 = 10, x1 = 40, word = "Hello" },
                    { x0 = 45, x1 = 80, word = "there." },
                    { x0 = 180, x1 = 240, word = "Other" },
                },
                { y0 = 38, y1 = 58, { x0 = 20, x1 = 70, word = "Welcome!" } },
                { y0 = 100, y1 = 120, { x0 = 10, x1 = 70, word = "Distant" } },
            }
        end,
    }
    local highlight = {
        selected_text = { text = "Hello", sboxes = { { x = 10, y = 10, w = 30, h = 20 } } },
        is_word_selection = true,
        _resetHoldTimer = function(self)
            self.long_hold_reached = false
        end,
        onTranslateText = function(self, text)
            self.translated = text
        end,
        onHoldRelease = function(self)
            self.released = true
        end,
    }
    return PanelViewer:new({
        _panels_plus_text_holding = true,
        reader_ui = { document = doc, highlight = highlight, view = { highlight = { temp = {} } } },
    }),
        highlight
end

describe("Panel phrase translation", function()
    it("reads image-only lines in line mode using the chosen language", function()
        local viewer, highlight = fixture()
        local doc = viewer.reader_ui.document
        doc.getTextBoxes = function()
            return { { y0 = 10, y1 = 30, { x0 = 10, x1 = 80 } } }
        end
        local original = WordFinder.ocrWord
        local mode, language
        WordFinder.ocrWord = function(_, _, _, lang, _, options)
            mode, language = options.mode, lang
            return "Hello there."
        end
        local ok, text = pcall(WordFinder.readPhrase, doc, 1, highlight.selected_text.sboxes[1], "spa")
        WordFinder.ocrWord = original
        assert.is_true(ok)
        assert.equals("Hello there.", text)
        assert.equals(7, mode)
        assert.equals("spa", language)
    end)

    it("joins nearby lines without including adjacent or distant dialogue", function()
        local viewer, highlight = fixture()
        local text, boxes = WordFinder.readPhrase(viewer.reader_ui.document, 1, highlight.selected_text.sboxes[1])
        assert.equals("Hello there. Welcome!", text)
        assert.equals(2, #boxes)
    end)

    it("expands at the threshold and translates only on release", function()
        local viewer, highlight = fixture()
        viewer:_startPhraseHold(highlight, { page = 1 })
        UIManager._last_scheduled()
        assert.equals("Hello there. Welcome!", highlight.selected_text.text)
        assert.is_nil(highlight.translated)
        assert.equals(highlight.selected_text.sboxes, viewer.reader_ui.view.highlight.temp[1])
        viewer:onHoldRelease()
        assert.equals("Hello there. Welcome!", highlight.translated)
        assert.is_nil(highlight.released)
    end)

    it("keeps a shorter hold on the normal word lookup path", function()
        local viewer, highlight = fixture()
        viewer:_startPhraseHold(highlight, { page = 1 })
        viewer:onHoldRelease()
        assert.is_true(highlight.released)
        assert.is_nil(highlight.translated)
        assert.is_nil(viewer._phrase_hold_action)
    end)

    it("cancels automatic phrase selection when dragging", function()
        local viewer = fixture()
        viewer:_startPhraseHold(viewer.reader_ui.highlight, { page = 1 })
        viewer:onHoldPan(nil, {})
        assert.is_nil(viewer._phrase_hold_action)
    end)

    it("preserves the word if phrase recognition fails", function()
        local viewer, highlight = fixture()
        viewer.reader_ui.document.getTextBoxes = function()
            error("OCR failed")
        end
        viewer:_startPhraseHold(highlight, { page = 1 })
        UIManager._last_scheduled()
        viewer:onHoldRelease()
        assert.equals("Hello", highlight.selected_text.text)
        assert.is_true(highlight.released)
        assert.is_nil(highlight.translated)
    end)
end)
