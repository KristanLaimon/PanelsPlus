--- Specs for `PanelViewer:_refineWordSelection` -- specifically that the box
--- the underline is painted from stays the box the word was read from.
---
--- `ReaderHighlight:onHold` stores a *reference* to the selection's `sboxes`
--- table in `view.highlight.temp[page]`, and `PanelViewer:paintHighlights`
--- draws from `temp` in preference to the selection. Refinement replaces
--- `selected_text.sboxes` with a new table, so without re-pointing `temp` the
--- underline keeps being painted from KOReader's original box -- whose y and
--- h come from the whole *text line*, not the word
--- (`KoptInterface:getWordFromBoxes` takes them from the line box). That is
--- the "the underline is offset vertically from the word it looked up" bug.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PanelViewer = require("src._panelviewer")
local WordFinder = require("src._wordfinder")

--- A viewer whose word finder is stubbed to return `box`/`word`, wired to a
--- reader UI in the state `ReaderHighlight:onHold` leaves behind: a word
--- selection whose `sboxes` table is also what `view.highlight.temp` holds.
---
--- @param box table|nil Box the stubbed finder returns.
--- @param word string|nil Word the stubbed reader returns.
local function newViewer(box, word)
    local koreader_sboxes = { { x = 10, y = 200, w = 80, h = 60 } }
    local viewer = PanelViewer:new({
        page = 3,
        reader_ui = {
            document = {
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
    })

    local original_find, original_read = WordFinder.findWordBox, WordFinder.readWord
    WordFinder.findWordBox = function()
        return box, { w = 1000, h = 1000 }
    end
    WordFinder.readWord = function()
        return word
    end

    return viewer,
        koreader_sboxes,
        function()
            WordFinder.findWordBox = original_find
            WordFinder.readWord = original_read
        end
end

describe("PanelViewer:_refineWordSelection highlight/lookup box sync", function()
    it("re-points the painted temp highlight at the refined box", function()
        local refined = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, koreader_sboxes, restore = newViewer(refined, "shift")
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        local painted = viewer.reader_ui.view.highlight.temp[3]
        assert.equals(1, #painted, "expected exactly the refined box to be painted")
        assert.equals(refined, painted[1], "temp highlight must be the box the word was read from")
        assert.is_true(painted ~= koreader_sboxes, "temp must not still point at KOReader's original boxes")
        assert.equals(
            highlight.selected_text.sboxes,
            painted,
            "temp and the selection must share one table, as ReaderHighlight leaves them"
        )
        assert.equals("shift", highlight.selected_text.text)
    end)

    it("leaves the selection and the painted box alone when OCR finds nothing", function()
        local refined = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, koreader_sboxes, restore = newViewer(refined, nil)
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        assert.equals("wrong", highlight.selected_text.text, "an unreadable crop must not overwrite the word")
        assert.equals(
            koreader_sboxes,
            viewer.reader_ui.view.highlight.temp[3],
            "the painted box must stay consistent with the word still selected"
        )
    end)

    it("leaves the selection alone when no box could be found", function()
        local viewer, koreader_sboxes, restore = newViewer(nil, "shift")
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        assert.equals("wrong", highlight.selected_text.text)
        assert.equals(koreader_sboxes, viewer.reader_ui.view.highlight.temp[3])
    end)

    it("does not refine in reflow mode, where the box space is not the page's", function()
        local refined = { x = 12, y = 214, w = 44, h = 26 }
        local viewer, koreader_sboxes, restore = newViewer(refined, "shift")
        viewer.reader_ui.document.configurable.text_wrap = 1
        local highlight = viewer.reader_ui.highlight

        viewer:_refineWordSelection(highlight, { page = 3, x = 30, y = 220 })
        restore()

        assert.equals("wrong", highlight.selected_text.text)
        assert.equals(koreader_sboxes, viewer.reader_ui.view.highlight.temp[3])
    end)
end)
