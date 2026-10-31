local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy
local PanelViewer = require("src._panelviewer")
local ViewerController = require("src.viewer_controller")
local EmbeddedImage = require("src.embedded_image")
local UIManager = require("ui/uimanager")
local ImageViewer = require("ui/widget/imageviewer")

describe("Panel viewer document boundary warnings", function()
    local function atBoundary(direction, callback)
        local old_close, old_schedule = UIManager.close, UIManager.scheduleIn
        local expired, delay
        UIManager.close = function(_, widget)
            if widget.onCloseWidget then
                widget:onCloseWidget()
            end
        end
        UIManager.scheduleIn = function(_, seconds, action)
            delay, expired = seconds, action
        end
        local handled, closed = spy(), spy()
        local ui = {
            document = {
                getNextPage = function()
                    return 0
                end,
                getPrevPage = function()
                    return nil
                end,
            },
            handleEvent = handled,
        }
        local viewer = PanelViewer:new({ page = 1, onClose = closed })
        local controller = setmetatable({ ui = ui }, { __index = ViewerController })
        local ok, err = pcall(function()
            assert.is_true(controller:onPanelViewerBoundary(direction, viewer))
            assert.is_nil(viewer._panels_plus_boundary_pending)
            assert.equals(7, delay)
            assert.is_false(handled:called())
            assert.is_false(closed:called())
            callback(viewer, UIManager._last_shown, expired, handled, closed, controller)
        end)
        UIManager.close, UIManager.scheduleIn = old_close, old_schedule
        if not ok then
            error(err)
        end
    end

    it("confirms the final panel before dispatching KOReader's end-of-book event once", function()
        atBoundary("next", function(viewer, dialog, _, handled, closed, controller)
            assert.is_true(dialog.text:find("last panel of the last page", 1, true) ~= nil)
            controller:onPanelViewerBoundary("next", viewer)
            assert.equals(dialog, UIManager._last_shown)
            dialog.ok_callback()
            dialog.ok_callback()
            assert.equals(1, closed:callCount())
            assert.equals(1, handled:callCount())
            assert.equals("EndOfBook", handled:lastCall()[2].name)
        end)
    end)

    it("confirms the first panel before returning a backward turn to KOReader", function()
        atBoundary("previous", function(_, dialog, _, handled, closed)
            assert.is_true(dialog.text:find("first panel of the first page", 1, true) ~= nil)
            dialog.ok_callback()
            assert.equals(1, closed:callCount())
            assert.equals("GotoViewRel", handled:lastCall()[2].name)
            assert.equals(-1, handled:lastCall()[2].args[1])
        end)
    end)

    it("stays in Panels+ after seven seconds and allows a fresh confirmation", function()
        atBoundary("next", function(viewer, dialog, expire, handled, closed, controller)
            expire()
            assert.is_nil(viewer._document_boundary_dialog)
            dialog.ok_callback()
            assert.is_false(handled:called())
            assert.is_false(closed:called())
            controller:onPanelViewerBoundary("next", viewer)
            assert.is_true(dialog ~= UIManager._last_shown)
        end)
    end)

    it("stays in Panels+ when the confirmation is dismissed", function()
        atBoundary("previous", function(viewer, dialog, _, handled, closed)
            UIManager:close(dialog)
            assert.is_nil(viewer._document_boundary_dialog)
            dialog.ok_callback()
            assert.is_false(handled:called())
            assert.is_false(closed:called())
        end)
    end)

    it("ignores confirmation after the viewer has closed", function()
        atBoundary("next", function(viewer, dialog, _, handled)
            viewer._panels_plus_closed = true
            dialog.ok_callback()
            assert.is_false(handled:called())
        end)
    end)

    it("uses the same confirmation at an embedded-image document boundary", function()
        local confirm = spy()
        local plugin = {
            ui = {
                document = {
                    getCurrentPage = function()
                        return 1
                    end,
                    getNextPage = function()
                        return 0
                    end,
                },
            },
        }
        local viewer = { confirmDocumentBoundary = confirm }
        EmbeddedImage.onEmbeddedImageBoundary(plugin, "next", viewer)
        assert.is_nil(viewer._panels_plus_boundary_pending)
        assert.equals("next", confirm:lastCall()[2])
        assert.equals(plugin.ui, confirm:lastCall()[3])
    end)
end)

describe("Panel viewer disabled OCR guidance", function()
    it("warns on hold and consumes release without OCR or ImageViewer's refresh", function()
        local native_hold, base_hold, base_release = spy(), spy(), spy()
        local old_hold, old_release = ImageViewer.onHold, ImageViewer.onHoldRelease
        ImageViewer.onHold, ImageViewer.onHoldRelease = base_hold, base_release
        local viewer = PanelViewer:new({
            hold_text_selection = false,
            reader_ui = { highlight = { onHold = native_hold } },
        })
        viewer:onHold(nil, { pos = { x = 100, y = 100 } })
        viewer:onHoldRelease(nil, {})
        ImageViewer.onHold, ImageViewer.onHoldRelease = old_hold, old_release
        assert.is_false(native_hold:called())
        assert.is_false(base_hold:called())
        assert.is_false(base_release:called())
        assert.equals(7, UIManager._last_shown.timeout)
        assert.is_true(UIManager._last_shown.text:find("More Config", 1, true) ~= nil)
    end)

    it("dims the disabled OCR control, explains how to enable it, and restores the picker", function()
        local open_picker = spy()
        local viewer =
            PanelViewer:new({ width = 600, hold_text_selection = false, ocr_language_callback = open_picker })
        viewer:replaceButtonTable()
        assert.is_true(viewer.quick_controls.ocr_language.dim)
        viewer.quick_controls.ocr_language.callback()
        assert.is_false(open_picker:called())
        assert.equals(7, UIManager._last_shown.timeout)
        assert.is_true(UIManager._last_shown.text:find("Touch & hold text selection", 1, true) ~= nil)
        viewer.hold_text_selection = true
        viewer:replaceButtonTable()
        assert.is_false(viewer.quick_controls.ocr_language.dim)
        viewer.quick_controls.ocr_language.callback()
        assert.equals(1, open_picker:callCount())
    end)
end)
