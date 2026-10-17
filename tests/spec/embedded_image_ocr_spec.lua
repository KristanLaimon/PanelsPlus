local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy
local PanelViewer = require("src._panelviewer")
local WordFinder = require("src._wordfinder")
local UIManager = require("ui/uimanager")

describe("Embedded image OCR selection", function()
    local function withViewer(callback)
        local find, read, phrase = WordFinder.findWordBox, WordFinder.readWord, WordFinder.readPhrase
        local schedule, unschedule = UIManager.scheduleIn, UIManager.unschedule
        local pending
        local lookup, translate, native_hold, native_pan, native_release = spy(), spy(), spy(), spy(), spy()
        local native_selection = { text = "EPUB text" }
        local source = {}
        local box = { x = 100, y = 200, w = 60, h = 20 }
        local viewer = PanelViewer:new({
            page = 1,
            hold_text_selection = true,
            embedded_source_image = { free = spy() },
            _embedded_ocr_document = source,
            ocr_bundled_language = "spa",
            reader_ui = {
                document = {},
                dictionary = { onLookupWord = lookup },
                highlight = {
                    selected_text = native_selection,
                    onHold = native_hold,
                    onHoldPan = native_pan,
                    onHoldRelease = native_release,
                    onTranslateText = translate,
                },
                view = { highlight = { temp = { [1] = { { x = 9 } } } } },
            },
            screenToPageTransform = function()
                return { page = 1, x = 120, y = 210 }
            end,
            pageToScreenTransform = function(_, rect)
                return { x = rect.x / 2, y = rect.y / 2, w = rect.w / 2, h = rect.h / 2 }
            end,
        })
        WordFinder.findWordBox = function(document, page, x, y)
            assert.equals(source, document)
            assert.equals(1, page)
            assert.equals(120, x)
            assert.equals(210, y)
            return box, { w = 800, h = 1200 }
        end
        WordFinder.readWord = function(document, _, selected, _, model)
            assert.equals(source, document)
            assert.equals(box, selected)
            assert.equals("spa", model)
            return "Hola"
        end
        WordFinder.readPhrase = function(document, _, seed, model)
            assert.equals(source, document)
            assert.equals(box, seed)
            assert.equals("spa", model)
            return "Hola mundo", { box }
        end
        UIManager.scheduleIn = function(_, _, action)
            pending = action
        end
        UIManager.unschedule = function(_, action)
            if pending == action then
                pending = nil
            end
        end
        local ok, err = pcall(callback, viewer, lookup, translate, function()
            pending()
        end)
        WordFinder.findWordBox, WordFinder.readWord, WordFinder.readPhrase = find, read, phrase
        UIManager.scheduleIn, UIManager.unschedule = schedule, unschedule
        if not ok then
            error(err)
        end
        assert.equals(native_selection, viewer.reader_ui.highlight.selected_text)
        assert.equals(9, viewer.reader_ui.view.highlight.temp[1][1].x)
        assert.is_false(native_hold:called())
        assert.is_false(native_pan:called())
        assert.is_false(native_release:called())
    end

    it("looks up the recognized word with screen boxes without using reflow selection APIs", function()
        withViewer(function(viewer, lookup)
            viewer:onHold(nil, { pos = { x = 60, y = 105 } })
            assert.equals("Hola", viewer._embedded_selection.text)
            viewer:onHoldRelease()
            assert.equals(1, lookup:callCount())
            assert.equals("Hola", lookup:lastCall()[2])
            assert.equals(50, lookup:lastCall()[4][1].x)
            assert.is_nil(viewer._embedded_selection)
        end)
    end)

    it("translates the dialogue after a longer hold", function()
        withViewer(function(viewer, lookup, translate, finish_hold)
            viewer:onHold(nil, { pos = {} })
            finish_hold()
            assert.equals("Hola mundo", viewer._embedded_selection.text)
            viewer:onHoldRelease()
            assert.is_false(lookup:called())
            assert.equals("Hola mundo", translate:lastCall()[2])
        end)
    end)

    it("consumes failed recognition and its release", function()
        withViewer(function(viewer, lookup)
            WordFinder.readWord = function()
                return nil
            end
            viewer:onHold(nil, { pos = {} })
            viewer:onHoldRelease()
            assert.is_false(lookup:called())
            assert.is_nil(viewer._embedded_selection)
        end)
    end)

    it("does not send image drag coordinates to ReaderRolling", function()
        withViewer(function(viewer)
            viewer:onHold(nil, { pos = {} })
            viewer:onHoldPan(nil, { pos = {} })
            viewer:onHoldPanRelease()
        end)
    end)

    it("cancels pending OCR and drops the borrowed source when navigating away", function()
        withViewer(function(viewer, lookup)
            viewer:onHold(nil, { pos = {} })
            viewer:releaseEmbeddedSource(true)
            assert.is_nil(viewer._phrase_hold_action)
            assert.is_nil(viewer._embedded_ocr_document)
            assert.is_nil(viewer._embedded_selection)
            assert.is_nil(viewer._panels_plus_text_holding)
            assert.is_false(lookup:called())
        end)
    end)
end)
