--[[
Panels+
File: src/panelviewer/rendering.lua
Name: PanelViewer
Description: Focused viewer rendering methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local CenterContainer = require("ui/widget/container/centercontainer")
local FoldJoin = require("src._foldjoin")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Screen = require("device").screen
local QuickToolbar = require("src._quicktoolbar")
local _ = require("gettext")
local logger = require("logger")

return function(PanelViewer)
    --- Angle the current bitmap is drawn at.
    ---
    --- `rotated` is a number when Panels+ set it. `true` is ImageViewer's auto-rotation, which picks 90
    --- or 270 from the screen orientation and the invert settings, so the angle is read from the
    --- widget.
    ---
    --- `ImageWidget.rotation_angle` turns the bitmap counter-clockwise. At 90 the page's top edge is on
    --- the left of the view, at 270 on the right.
    ---
    --- @param viewer PanelViewer Viewer whose current image is being mapped.
    --- @return number angle 0, 90, 180 or 270.
    local function drawnAngle(viewer)
        if type(viewer.rotated) == "number" then
            return viewer.rotated
        end
        if viewer.rotated then
            return viewer._image_wg and viewer._image_wg.rotation_angle or 90
        end
        return 0
    end

    --- Fold strip removed from the current image, if any (see `FoldJoin.joinBitmap`).
    ---
    --- @return table|nil fold
    function PanelViewer:currentFold()
        local folds = self._images_list and self._images_list.folds
        return folds and folds[self._images_list_cur or 1]
    end

    --- Convert a screen coordinate inside this zoomed viewer to document page coordinates.
    ---
    --- @param pos table Screen position `{x = number, y = number}`.
    --- @return PPPagePosition|nil page_pos Unrotated document page position `{x, y, page}`.
    function PanelViewer:screenToPageTransform(pos)
        if not pos or not pos.x or not pos.y or not self.page then
            return nil
        end

        local cur_idx = self._images_list_cur or 1
        local rect = self.image_rects and self.image_rects[cur_idx]
        if not rect or not self._image_wg then
            return nil
        end

        self._image_wg:getSize()
        local bb_w = self._image_wg:getCurrentWidth()
        local bb_h = self._image_wg:getCurrentHeight()
        if not bb_w or bb_w <= 0 or not bb_h or bb_h <= 0 then
            return nil
        end

        local widget_x = self._image_wg.dimen and self._image_wg.dimen.x or 0
        local widget_y = self._image_wg.dimen and self._image_wg.dimen.y or 0
        local offset_x = self._image_wg._offset_x or 0
        local offset_y = self._image_wg._offset_y or 0

        local px = (pos.x - widget_x) + offset_x
        local py = (pos.y - widget_y) + offset_y

        local norm_x = math.max(0, math.min(1, px / bb_w))
        local norm_y = math.max(0, math.min(1, py / bb_h))

        -- `u` and `v` are the press as shares of the image, unrotated.
        local u, v
        local angle = drawnAngle(self)
        if angle == 90 then
            u, v = 1 - norm_y, norm_x
        elseif angle == 180 then
            u, v = 1 - norm_x, 1 - norm_y
        elseif angle == 270 then
            u, v = norm_y, 1 - norm_x
        else
            u, v = norm_x, norm_y
        end
        local page_x = (rect.x or 0) + FoldJoin.toSourceU(u, self:currentFold()) * (rect.w or 0)
        local page_y = (rect.y or 0) + v * (rect.h or 0)

        return {
            x = page_x,
            y = page_y,
            page = self.page,
        }
    end

    --- Convert a page-space rectangle on the current page to screen coordinates inside this zoomed viewer.
    ---
    --- @param box table Page-space rectangle `{x, y, w, h}` or `{x0, y0, x1, y1}`.
    --- @return PPRect|nil screen_rect Screen position `{x, y, w, h}` or nil if outside crop.
    function PanelViewer:pageToScreenTransform(box)
        if not box or not self.page then
            return nil
        end

        local cur_idx = self._images_list_cur or 1
        local rect = self.image_rects and self.image_rects[cur_idx]
        if not rect or not self._image_wg then
            return nil
        end

        local bx = box.x or box.x0 or 0
        local by = box.y or box.y0 or 0
        local bw = box.w or ((box.x1 or bx) - bx)
        local bh = box.h or ((box.y1 or by) - by)
        if bw <= 0 or bh <= 0 then
            return nil
        end

        local rx = rect.x or 0
        local ry = rect.y or 0
        local rw = rect.w or 1
        local rh = rect.h or 1

        local ix0 = math.max(bx, rx)
        local iy0 = math.max(by, ry)
        local ix1 = math.min(bx + bw, rx + rw)
        local iy1 = math.min(by + bh, ry + rh)

        if ix1 <= ix0 or iy1 <= iy0 then
            return nil
        end

        local fold = self:currentFold()
        local norm_x0 = FoldJoin.toJoinedU((ix0 - rx) / rw, fold)
        local norm_y0 = (iy0 - ry) / rh
        local norm_x1 = FoldJoin.toJoinedU((ix1 - rx) / rw, fold)
        local norm_y1 = (iy1 - ry) / rh

        self._image_wg:getSize()
        local bb_w = self._image_wg:getCurrentWidth()
        local bb_h = self._image_wg:getCurrentHeight()
        if not bb_w or bb_w <= 0 or not bb_h or bb_h <= 0 then
            return nil
        end

        local widget_x = self._image_wg.dimen and self._image_wg.dimen.x or 0
        local widget_y = self._image_wg.dimen and self._image_wg.dimen.y or 0
        local offset_x = self._image_wg._offset_x or 0
        local offset_y = self._image_wg._offset_y or 0

        local px0, py0, px1, py1
        local angle = drawnAngle(self)
        if angle == 90 then
            px0 = norm_y0 * bb_w
            py0 = (1 - norm_x1) * bb_h
            px1 = norm_y1 * bb_w
            py1 = (1 - norm_x0) * bb_h
        elseif angle == 180 then
            px0 = (1 - norm_x1) * bb_w
            py0 = (1 - norm_y1) * bb_h
            px1 = (1 - norm_x0) * bb_w
            py1 = (1 - norm_y0) * bb_h
        elseif angle == 270 then
            px0 = (1 - norm_y1) * bb_w
            py0 = norm_x0 * bb_h
            px1 = (1 - norm_y0) * bb_w
            py1 = norm_x1 * bb_h
        else
            px0 = norm_x0 * bb_w
            py0 = norm_y0 * bb_h
            px1 = norm_x1 * bb_w
            py1 = norm_y1 * bb_h
        end

        local screen_x0 = widget_x + px0 - offset_x
        local screen_y0 = widget_y + py0 - offset_y
        local screen_x1 = widget_x + px1 - offset_x
        local screen_y1 = widget_y + py1 - offset_y

        local sx = math.floor(math.min(screen_x0, screen_x1))
        local sy = math.floor(math.min(screen_y0, screen_y1))
        local sw = math.max(1, math.ceil(math.abs(screen_x1 - screen_x0)))
        local sh = math.max(1, math.ceil(math.abs(screen_y1 - screen_y0)))

        return { x = sx, y = sy, w = sw, h = sh }
    end

    --- Default: skip a full-fill highlight paint when a page-space box would
    --- cover this much or more of the current panel crop's area. A box this
    --- large relative to the visible panel is very likely a spurious/coarse
    --- text-layer bounding box -- OCR on comic/manga art (stylized fonts,
    --- speech bubbles, vertical text) commonly produces oversized word or line
    --- boxes, whether from the document's own embedded OCR text layer (PDF) or
    --- KOReader's on-the-fly OCR fallback (CBZ/CBR, which carry no text layer
    --- at all) -- rather than a genuine single word. Filling a box this size
    --- with the "invert" drawer would otherwise read as a big solid black
    --- rectangle over the panel art.
    local HIGHLIGHT_BOX_AREA_RATIO_THRESHOLD = 0.6

    --- Whether a page-space highlight box looks anomalously large relative to
    --- the currently displayed panel crop.
    ---
    --- @param box table Page-space box `{x,y,w,h}` or `{x0,y0,x1,y1}`.
    --- @param rect table Current panel crop rect `{x,y,w,h}`.
    --- @return boolean is_anomalous
    local function isAnomalousHighlightBox(box, rect)
        local bw = box.w or ((box.x1 or 0) - (box.x0 or box.x or 0))
        local bh = box.h or ((box.y1 or 0) - (box.y0 or box.y or 0))
        local rw, rh = rect.w or 0, rect.h or 0
        if bw <= 0 or bh <= 0 or rw <= 0 or rh <= 0 then
            return false
        end
        return (bw * bh) / (rw * rh) >= HIGHLIGHT_BOX_AREA_RATIO_THRESHOLD
    end

    --- Paint a thin border around a screen rect instead of a full fill, used
    --- when `isAnomalousHighlightBox` flags the source box as spurious --
    --- marks the selection's extent without obscuring the panel art beneath it.
    ---
    --- @param bb table Blitbuffer canvas.
    --- @param rect PPRect Screen rect `{x, y, w, h}`.
    local function paintHighlightOutline(bb, rect)
        local t = math.max(1, math.min(2, math.floor(rect.w / 3), math.floor(rect.h / 3)))
        bb:invertRect(rect.x, rect.y, rect.w, t)
        bb:invertRect(rect.x, rect.y + rect.h - t, rect.w, t)
        bb:invertRect(rect.x, rect.y, t, rect.h)
        bb:invertRect(rect.x + rect.w - t, rect.y, t, rect.h)
    end

    --- Render temporary text selection highlights over the zoomed panel.
    ---
    --- @param bb table Blitbuffer canvas.
    --- @param x number Canvas X offset.
    --- @param y number Canvas Y offset.
    function PanelViewer:paintHighlights(bb, x, y)
        -- ReaderHighlight may keep its last temporary boxes/selected_text while a
        -- dictionary popup is open (or after it closes). Only the active gesture
        -- owns a panel overlay; otherwise those page-space boxes can be painted
        -- again on a later panel that happens to overlap them.
        if not self._panels_plus_text_holding then
            return
        end
        local reader_ui = self.reader_ui
        if not reader_ui or not reader_ui.view or not reader_ui.highlight then
            return
        end

        local temp_highlights = not self.embedded_source_image
            and reader_ui.view.highlight
            and reader_ui.view.highlight.temp
        local selected_text = self._embedded_selection or (reader_ui.highlight and reader_ui.highlight.selected_text)

        local boxes_to_draw = {}

        if temp_highlights and self.page and temp_highlights[self.page] then
            for _, box in ipairs(temp_highlights[self.page]) do
                table.insert(boxes_to_draw, box)
            end
        end

        if #boxes_to_draw == 0 and selected_text then
            if selected_text.sboxes then
                for _, box in ipairs(selected_text.sboxes) do
                    table.insert(boxes_to_draw, box)
                end
            elseif selected_text.pboxes then
                for _, box in ipairs(selected_text.pboxes) do
                    table.insert(boxes_to_draw, box)
                end
            end
        end

        if #boxes_to_draw == 0 then
            return
        end

        local drawer = reader_ui.view.highlight and reader_ui.view.highlight.temp_drawer or "invert"
        local cur_idx = self._images_list_cur or 1
        local crop_rect = self.image_rects and self.image_rects[cur_idx]

        for _, box in ipairs(boxes_to_draw) do
            local rect = self:pageToScreenTransform(box)
            if rect then
                if crop_rect and isAnomalousHighlightBox(box, crop_rect) then
                    logger.dbg(
                        "[Panels+] anomalous highlight box, drawing outline only:",
                        "box=",
                        box.x or box.x0,
                        box.y or box.y0,
                        box.w,
                        box.h,
                        "crop=",
                        crop_rect.x,
                        crop_rect.y,
                        crop_rect.w,
                        crop_rect.h
                    )
                    paintHighlightOutline(bb, rect)
                elseif reader_ui.view.drawHighlightRect then
                    pcall(reader_ui.view.drawHighlightRect, reader_ui.view, bb, 0, 0, rect, drawer)
                else
                    if drawer == "invert" then
                        bb:invertRect(rect.x, rect.y, rect.w, rect.h)
                    else
                        bb:darkenRect(rect.x, rect.y, rect.w, rect.h, 0.3)
                    end
                end
            end
        end
    end

    --- Apply document inversion only to image pixels, leaving letterboxing to night mode.
    function PanelViewer:paintTo(bb, x, y)
        if self._image_wg then
            self._image_wg.original_in_nightmode = false
        end
        ImageViewer.paintTo(self, bb, x, y)
        local document = self.reader_ui and self.reader_ui.document
        local keep_original = document and document.configurable and document.configurable.nightmode_document == 1
        local image = self._image_wg
        if Screen.night_mode and keep_original and image and image.dimen then
            local d = image.dimen
            local ox, oy = image._offset_x or 0, image._offset_y or 0
            local dx, dy = math.max(0, -ox), math.max(0, -oy)
            -- Blits floor their bounds; invertRect rounds up and would invert a margin pixel.
            local w = math.floor(math.min(d.w, image:getCurrentWidth() - ox) - dx)
            local h = math.floor(math.min(d.h, image:getCurrentHeight() - oy) - dy)
            if w > 0 and h > 0 then
                bb:invertRect(d.x + dx, d.y + dy, w, h)
            end
        end
        self:paintHighlights(bb, x, y)
        local ink = self.reader_ui
            and (self.reader_ui.inkAwayIntegrationAPI or self.reader_ui["ink-away"] or self.reader_ui.inkaway)
        if
            ink
            and ink.document_surface_version == 1
            and type(ink.paintDocumentSurface) == "function"
            and not self._annotation_snapshot
        then
            local surface = self:getAnnotationSurface()
            if surface then
                local ok, err = pcall(ink.paintDocumentSurface, ink, surface, bb)
                if not ok then
                    logger.warn("[Panels+] Ink Away painting failed:", tostring(err))
                end
            end
        end
    end

    --- Return the button label for the crop mode currently in use.
    ---
    --- Loose and margin modes are hinted as configurable since long-pressing the
    --- button opens a slider for them; strict crop has nothing to configure.
    ---
    --- @return string text Localized crop-mode label.
    function PanelViewer:getCropModeText()
        if self.crop_mode == "loose" then
            return _("Loose crop") .. " " .. _("(Long press config)")
        elseif self.crop_mode == "margin" then
            return _("With margin") .. " " .. _("(Long press config)")
        elseif self.crop_mode == "none" then
            return _("No crop")
        end
        return _("Strict crop")
    end

    function PanelViewer:getPanelFindingModeText()
        if self.panel_finding_mode == "smart" then
            return _("Panels Finding: Smart")
        end
        return _("Panels Finding: Safe")
    end

    --- Return the button label for the panel navigation transition mode in use.
    ---
    --- @return string text Localized navigation-mode label.
    function PanelViewer:getNavTransitionText()
        if self.nav_transition_mode == "smooth" then
            return _("Nav. Smooth") .. " " .. _("(Long Press)")
        elseif self.nav_transition_mode == "animated" then
            return _("Nav. Animated") .. " " .. _("(Long Press)")
        end
        return _("Nav. Classic")
    end

    --- Return whether the panel currently shown spans nearly the whole page.
    ---
    --- @return boolean full_page `true` when the shown panel is a full-page/splash panel.
    function PanelViewer:isCurrentPanelFullPage()
        local flags = self.panel_is_full_page
        if not flags then
            return false
        end
        return flags[self._images_list_cur or 1] == true
    end

    --- Return the width/height multiplier margin mode should use for one panel.
    ---
    --- Full-page panels are excluded: shrinking a splash page to fake a margin
    --- would waste most of the screen for an effect the reader didn't ask for.
    --- Keeping the panel index explicit is important to smooth navigation: while
    --- its synthetic canvas is onscreen, `_images_list_cur` is still the panel it
    --- started from, but the canvas must be scaled like the panel it will land on.
    ---
    --- @param image_num integer|nil 1-based panel index; defaults to the current panel.
    --- @param is_full_page boolean|nil Explicit full-page flag, used for a target
    --- panel from an adjacent page that is not in this viewer's panel list.
    --- @return number|nil factor Multiplier in (0, 1), or nil when no shrink applies.
    function PanelViewer:getMarginShrinkFactorForPanel(image_num, is_full_page)
        if self.crop_mode ~= "margin" then
            return nil
        end
        if is_full_page == nil then
            local flags = self.panel_is_full_page
            is_full_page = flags and flags[image_num or self._images_list_cur or 1]
        end
        if is_full_page then
            return nil
        end
        local ratio = self.margin_ratio or 0.12
        if ratio <= 0 then
            return nil
        end
        return 1 - math.min(0.9, ratio)
    end

    --- Return the margin factor for the widget currently being built.
    ---
    --- A smooth transition temporarily displays a synthetic canvas but must use
    --- the destination panel's framing. The override exists only for that canvas;
    --- it is cleared immediately before the normal destination image is rebuilt.
    ---
    --- @return number|nil factor Multiplier in (0, 1), or nil when no shrink applies.
    function PanelViewer:getMarginShrinkFactor()
        if self._panels_plus_transition_margin_factor ~= nil then
            return self._panels_plus_transition_margin_factor
        end
        return self:getMarginShrinkFactorForPanel(self._images_list_cur)
    end

    --- Return the panel area before margins, excluding the visible controls.
    --- Keep animation framing and ImageViewer widget layout on the same geometry.
    function PanelViewer:getPanelViewportSize()
        local viewer_width = self.width or Screen:getWidth()
        local viewer_container_h = self.img_container_h or Screen:getHeight()
        local insets = self:getAnnotationViewportInsets()
        viewer_width = viewer_width - insets.left - insets.right
        viewer_container_h = viewer_container_h - insets.top - insets.bottom
        local portrait = (self.width or Screen:getWidth()) <= (self.height or Screen:getHeight())
        local row_height = self.buttons_visible
                and self.quick_controls
                and portrait
                and math.min(
                    QuickToolbar.rowHeight(self.quick_controls, viewer_width),
                    math.max(1, viewer_container_h - 1)
                )
            or 0
        local rail_width = self.buttons_visible
                and self.quick_controls
                and not portrait
                and QuickToolbar.width(viewer_width, function(value)
                    return Screen:scaleBySize(value)
                end)
            or 0
        return viewer_width - rail_width, viewer_container_h - row_height, row_height, rail_width, insets
    end

    --- Shrink the box ImageViewer renders the panel into, for "margin" crop mode.
    ---
    --- The base implementation sizes both the ImageWidget and the CenterContainer
    --- that centers it from `self.width`/`self.img_container_h`. Temporarily
    --- shrinking those before delegating, then restoring the container's `dimen`
    --- to the full area afterward, keeps the centering but renders a smaller
    --- image inside it -- a cheap zoom-out that reads as breathing room around
    --- the panel without touching the actual crop rectangle.
    function PanelViewer:_new_image_wg()
        QuickToolbar.free(self.quick_controls)
        local viewer_width = self.width
        local viewer_container_h = self.img_container_h
        local panel_w, panel_h, row_height, rail_width, insets = self:getPanelViewportSize()
        insets = insets or { left = 0, top = 0, right = 0, bottom = 0 }
        local body_w = viewer_width - insets.left - insets.right
        local body_h = viewer_container_h - insets.top - insets.bottom
        self.width = panel_w
        self.img_container_h = panel_h
        local factor = self:getMarginShrinkFactor()
        if not factor then
            ImageViewer._new_image_wg(self)
        else
            local orig_width, orig_container_h = self.width, self.img_container_h
            self.width = orig_width * factor
            self.img_container_h = orig_container_h * factor
            ImageViewer._new_image_wg(self)
            self.width = orig_width
            self.img_container_h = orig_container_h
            self.image_container.dimen.w = orig_width
            self.image_container.dimen.h = orig_container_h
        end
        self.width = viewer_width
        self.img_container_h = viewer_container_h

        -- Base ImageViewer only ever treats `self.rotated` as a boolean, picking
        -- 90 or 270 itself via a screen-orientation heuristic and never producing
        -- 180. When it holds a literal angle instead (set by the rotation
        -- picker's plugin-only rotate; see onSetImageRotation below), force the
        -- exact angle onto the ImageWidget it already built -- rotation_angle is
        -- only read lazily on first render, so this still lands before paint.
        if type(self.rotated) == "number" then
            self._image_wg.rotation_angle = self.rotated
        end
        if row_height > 0 then
            local VerticalGroup = require("ui/widget/verticalgroup")
            self.quick_rail = QuickToolbar.build(self.quick_controls, body_w, row_height, true)
            self.image_container = VerticalGroup:new({
                align = "center",
                self.image_container,
                CenterContainer:new({ dimen = Geom:new({ w = body_w, h = row_height }), self.quick_rail }),
            })
        elseif rail_width > 0 then
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            self.quick_rail = QuickToolbar.build(self.quick_controls, rail_width, body_h)
            self.image_container = HorizontalGroup:new({
                align = "top",
                allow_mirroring = false,
                self.image_container,
                self.quick_rail,
            })
        else
            self.quick_rail = nil
        end
        if insets.left > 0 or insets.right > 0 then
            self.image_container = require("ui/widget/horizontalgroup"):new({
                align = "top",
                allow_mirroring = false,
                require("ui/widget/horizontalspan"):new({ width = insets.left }),
                self.image_container,
                require("ui/widget/horizontalspan"):new({ width = insets.right }),
            })
        end
        if insets.top > 0 or insets.bottom > 0 then
            self.image_container = require("ui/widget/verticalgroup"):new({
                align = "left",
                require("ui/widget/verticalspan"):new({ width = insets.top }),
                self.image_container,
                require("ui/widget/verticalspan"):new({ width = insets.bottom }),
            })
        end
    end

    function PanelViewer:setInkAwayFitViewport(fit)
        local function reflow()
            self.inkaway_fit_viewport = fit
            self:update()
        end
        local surface = self._annotation_surface
        if surface and surface.refresh_layout then
            surface.refresh_layout(reflow)
        else
            reflow()
        end
    end

    function PanelViewer:getAnnotationViewportInsets()
        local insets = { left = 0, top = 0, right = 0, bottom = 0 }
        local rect = self._annotation_viewport
        if not rect or self.inkaway_fit_viewport == false then
            return insets
        end
        local w, h = self.width or Screen:getWidth(), self.img_container_h or Screen:getHeight()
        local x = math.floor((Screen:getWidth() - w) / 2)
        local y = math.floor((Screen:getHeight() - (self.height or Screen:getHeight())) / 2)
        if self.with_title_bar then
            local title = self.caption and self.caption_visible and self.captioned_title_bar or self.title_bar
            y = y + (title and title:getSize().h or 0)
        end
        insets.left = math.max(0, math.min(w - 1, rect.x - x))
        insets.top = math.max(0, math.min(h - 1, rect.y - y))
        insets.right = math.max(0, math.min(w - insets.left - 1, x + w - rect.x - rect.w))
        insets.bottom = math.max(0, math.min(h - insets.top - 1, y + h - rect.y - rect.h))
        return insets
    end

    function PanelViewer:annotationDrawnAngle()
        return drawnAngle(self)
    end
end
