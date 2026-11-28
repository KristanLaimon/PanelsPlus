local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local ImageViewer = require("ui/widget/imageviewer")

describe("PanelViewer annotator viewport", function()
    local function viewer()
        return PanelViewer:new({
            width = 600,
            height = 800,
            img_container_h = 800,
            _images_list_cur = 1,
            image_rects = { { x = 0, y = 0, w = 600, h = 800 } },
            reader_ui = { document = {} },
            page = 1,
        })
    end

    it("hides options for annotation and restores their prior visibility once", function()
        for _, visible in ipairs({ true, false }) do
            local v = viewer()
            v.buttons_visible = visible
            local updates = 0
            v.update = function()
                updates = updates + 1
            end
            local surface = v:getAnnotationSurface()
            surface:begin()
            surface:begin() -- Navigation can begin the same surface again.
            assert.is_false(v.buttons_visible)
            assert.equals(visible and 1 or 0, updates)
            surface:finish() -- Also used when creating the editor fails.
            assert.equals(visible, v.buttons_visible)
            assert.equals(visible and 2 or 0, updates)
            surface:finish()
            assert.equals(visible and 2 or 0, updates)
        end
    end)

    it("reserves each available screen edge and restores it when the editor closes", function()
        for _, rect in ipairs({
            { x = 50, y = 0, w = 550, h = 800 },
            { x = 0, y = 0, w = 550, h = 800 },
            { x = 0, y = 50, w = 600, h = 750 },
            { x = 0, y = 0, w = 600, h = 750 },
        }) do
            local v = viewer()
            local updates = 0
            v.update = function()
                updates = updates + 1
            end
            local surface = v:getAnnotationSurface()
            assert.is_true(surface:setViewport(rect))
            local w, h = v:getPanelViewportSize()
            assert.equals(rect.w, w)
            assert.equals(rect.h, h)
            assert.is_false(surface:setViewport(rect), "unchanged toolbar geometry must not trigger another reflow")
            surface:finish()
            w, h = v:getPanelViewportSize()
            assert.equals(600, w)
            assert.equals(800, h)
            assert.equals(2, updates)
            assert.is_nil(surface.refresh_layout)
        end
    end)

    it("combines toolbar space with existing bottom controls without subtracting overlap twice", function()
        local v = viewer()
        v.img_container_h = 680 -- settings and progress already consume the bottom
        v._annotation_viewport = { x = 0, y = 0, w = 600, h = 750 }
        local w, h = v:getPanelViewportSize()
        assert.equals(600, w)
        assert.equals(680, h)
        v._annotation_viewport = { x = 40, y = 30, w = 560, h = 770 }
        w, h = v:getPanelViewportSize()
        assert.equals(560, w)
        assert.equals(650, h)
    end)

    it("respects the full-viewport preference and refreshes through the editor transaction", function()
        local v = viewer()
        local updates, refreshes = 0, 0
        v.update = function()
            updates = updates + 1
        end
        local surface = v:getAnnotationSurface()
        surface:setViewport({ x = 50, y = 0, w = 550, h = 800 }, function(reflow)
            refreshes = refreshes + 1
            assert.is_true(v.inkaway_fit_viewport ~= false, "edits are anchored before changing the preference")
            reflow()
        end)
        v:setInkAwayFitViewport(false)
        local w, h = v:getPanelViewportSize()
        assert.equals(600, w)
        assert.equals(800, h)
        assert.equals(1, refreshes)
        assert.equals(2, updates)
    end)

    it("fits and offsets the image container on all four sides, preserving crop margins", function()
        local original = ImageViewer._new_image_wg
        local saved = {}
        for _, name in ipairs({ "horizontalgroup", "verticalgroup", "horizontalspan", "verticalspan" }) do
            local key = "ui/widget/" .. name
            saved[key] = package.loaded[key]
            package.loaded[key] = {
                new = function(_, o)
                    o.kind = name
                    return o
                end,
            }
        end
        ImageViewer._new_image_wg = function(v)
            v._image_wg = { width = v.width, height = v.img_container_h }
            v.image_container = { dimen = { w = v.width, h = v.img_container_h } }
        end
        local ok, err = pcall(function()
            for _, rect in ipairs({
                { x = 50, y = 0, w = 550, h = 800 },
                { x = 0, y = 0, w = 550, h = 800 },
                { x = 0, y = 50, w = 600, h = 750 },
                { x = 0, y = 0, w = 600, h = 750 },
            }) do
                for _, mode in ipairs({ "tight", "loose", "margin", "none" }) do
                    local v = viewer()
                    v._annotation_viewport, v.crop_mode, v.margin_ratio = rect, mode, 0.2
                    v:_new_image_wg()
                    local factor = mode == "margin" and 0.8 or 1
                    assert.near(rect.w * factor, v._image_wg.width, 0.001)
                    assert.near(rect.h * factor, v._image_wg.height, 0.001)
                    local container = v.image_container
                    assert.equals(rect.x > 0 and rect.x or rect.y, container[1].width)
                    assert.equals(rect.w, container[2].dimen.w)
                    assert.equals(rect.h, container[2].dimen.h)
                    assert.equals(600, v.width)
                    assert.equals(800, v.img_container_h)
                end
            end
        end)
        ImageViewer._new_image_wg = original
        for key, value in pairs(saved) do
            package.loaded[key] = value
        end
        -- nil entries do not survive pairs(), so explicitly restore unloaded modules.
        for _, name in ipairs({ "horizontalgroup", "verticalgroup", "horizontalspan", "verticalspan" }) do
            local key = "ui/widget/" .. name
            if saved[key] == nil then
                package.loaded[key] = nil
            end
        end
        if not ok then
            error(err)
        end
    end)
end)
