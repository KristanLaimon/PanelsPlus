--[[
Panels+
File: src/panelviewer/animations.lua
Name: PanelViewer
Description: Focused viewer animations methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Blitbuffer = require("ffi/blitbuffer")
local DoubleSpread = require("src._doublespread")
local Geometry = require("src._smartgeometry")
local Memory = require("src._memory")
local NavEasing = require("src._naveasing")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local PanelViewport = require("src._panelviewport")
local PageRender = require("src._pagerender")
local logger = require("logger")

local Constants = require("src.panelviewer.constants")
local NAV_TRANSITION_STEPS_DEFAULT = Constants.NAV_TRANSITION_STEPS_DEFAULT
local NAV_TRANSITION_MAX_AREA_MULTIPLIER = Constants.NAV_TRANSITION_MAX_AREA_MULTIPLIER
local NAV_TRANSITION_MIN_FREE_BYTES = Constants.NAV_TRANSITION_MIN_FREE_BYTES

return function(PanelViewer)
    local function transitionAnnotations(image, page, rect, clips)
        local transition = { image = image, page = page, rect = rect }
        if clips then
            transition.regions = {}
            for _, clip in ipairs(clips) do
                transition.regions[#transition.regions + 1] = { page = page, rect = rect, clip = clip }
            end
        end
        return transition
    end

    local function maskTransitionSource(source, union, clips, background)
        local masked
        local ok, result = pcall(function()
            local w, h = source:getWidth(), source:getHeight()
            masked = Blitbuffer.new(w, h, source:getType())
            masked:fill(background)
            for _, r in ipairs(clips) do
                local x0 = math.max(0, math.floor((r.x - union.x) * w / union.w))
                local y0 = math.max(0, math.floor((r.y - union.y) * h / union.h))
                local x1 = math.min(w, math.ceil((r.x + r.w - union.x) * w / union.w))
                local y1 = math.min(h, math.ceil((r.y + r.h - union.y) * h / union.h))
                if x1 > x0 and y1 > y0 then
                    masked:blitFrom(source, x0, y0, x0, y0, x1 - x0, y1 - y0)
                end
            end
            return masked
        end)
        if not ok then
            if masked then
                masked:free()
            end
            return nil
        end
        return result
    end

    --- Return the KOReader canvas-fit zoom for a native-page rectangle.
    ---
    --- Mirrors `Document:drawPagePart()`'s own (non-rotated) best-fit formula, so
    --- this tells us how big `rect` would render if `drawPagePart` drew it alone.
    ---
    --- @param rect PPRect Native page rectangle.
    --- @return number zoom Scale factor from page-space to screen-space.
    local function canvasFitZoom(rect)
        return math.min(Screen:getWidth() / (rect.w or 1), Screen:getHeight() / (rect.h or 1))
    end

    local function panelFitZoom(viewer, rect, viewport_w, viewport_h)
        if viewer.crop_mode == "none" then
            -- No crop pads its native render to a screen-sized canvas before fitting.
            return canvasFitZoom(rect) * math.min(viewport_w / Screen:getWidth(), viewport_h / Screen:getHeight())
        end
        return math.min(viewport_w / rect.w, viewport_h / rect.h)
    end

    --- Complete a navigation handoff before notifying a settings preview.
    function PanelViewer:completeNavTransition(target, on_complete)
        self._annotation_transition = nil
        self:switchToImageNum(target)
        if on_complete then
            on_complete()
        end
    end

    --- Animate a camera pan from the panel currently shown to `target`, then hand off
    --- to its crisp render.
    ---
    --- CSS styles interpolate the center and zoom with viewport-sized frames. Classic
    --- pans a shared canvas at the destination's zoom, using viewport frames when
    --- that canvas would be oversized. Both hand off to the destination's crisp render
    --- and fall back to an instant swap on render failure, missing rectangles, or low memory.
    ---
    --- @param target integer 1-based image index to end the transition on.
    --- @param on_complete function|nil Called after the final panel render.
    function PanelViewer:animateSwitchToImageNum(target, on_complete)
        local cur = self._images_list_cur
        if target == cur or self._panels_plus_transition_active then
            return
        end
        -- The synthetic pan canvas is built in unrotated page coordinates.
        if self:shouldAutoRotateDoublePage(cur) or self:shouldAutoRotateDoublePage(target) then
            return self:completeNavTransition(target, on_complete)
        end
        local rect_a = self.image_rects and self.image_rects[cur]
        local rect_b = self.image_rects and self.image_rects[target]
        if not rect_a or not rect_b then
            return self:completeNavTransition(target, on_complete)
        end

        Timing.log(
            "animateSwitchToImageNum: panel %d -> %d (crop_mode=%s, duration=%.2fs)",
            cur,
            target,
            tostring(self.crop_mode),
            self.nav_transition_duration or 0
        )
        Timing.memory("smooth_transition")

        local union = Geometry.rectUnion(rect_a, rect_b)
        local clips = self.crop_mode ~= "none" and PanelViewport.transitionClips(rect_a, rect_b) or nil
        -- Margin mode does not alter `rect_b`; it renders the same pixels inside a
        -- smaller viewport. Match that smaller destination scale here as well, or
        -- ImageWidget clamps the camera to the full-size canvas and the animation
        -- appears stationary before snapping to the margin-sized panel.
        local target_margin_factor = self:getMarginShrinkFactorForPanel(target) or 1
        local viewport_w, viewport_h = self:getPanelViewportSize()
        local target_zoom = panelFitZoom(self, rect_b, viewport_w, viewport_h) * target_margin_factor

        local bx, by
        if self.crop_mode == "none" and self.panels and self.panels[target] then
            bx, by = Geometry.rectCenter(self.panels[target])
        else
            bx, by = Geometry.rectCenter(rect_b)
        end

        local ax, ay
        if self.crop_mode == "none" and self.panels and self.panels[cur] then
            ax, ay = Geometry.rectCenter(self.panels[cur])
        else
            ax, ay = Geometry.rectCenter(rect_a)
        end

        local half_w =
            math.max(viewport_w / (2 * target_zoom) + math.abs(ax - bx), bx - union.x, union.x + union.w - bx)
        local half_h =
            math.max(viewport_h / (2 * target_zoom) + math.abs(ay - by), by - union.y, union.y + union.h - by)

        local screen_area = viewport_w * viewport_h
        -- CSS styles interpolate zoom. Classic keeps the earlier fixed-zoom
        -- canvas pan, with the bounded-frame fallback for oversized canvases.
        local use_viewport_frames = self.nav_smooth_style ~= "classic"
            or (2 * half_w) * (2 * half_h) * target_zoom * target_zoom
                > screen_area * NAV_TRANSITION_MAX_AREA_MULTIPLIER
        if not Memory.hasHeadroom(NAV_TRANSITION_MIN_FREE_BYTES) then
            Timing.log(
                "animateSwitchToImageNum: low memory, falling back to instant swap for panel %d -> %d",
                cur,
                target
            )
            return self:completeNavTransition(target, on_complete)
        end

        local zoom_union = canvasFitZoom(union)
        local canvas_w = math.max(1, math.ceil(2 * half_w * zoom_union))
        local canvas_h = math.max(1, math.ceil(2 * half_h * zoom_union))
        -- `content_image` and `canvas_image` coexist while compositing. Estimate
        -- four bytes per pixel even on an e-ink device: this remains safe for
        -- colour EPUB images and makes smooth navigation yield before it can evict
        -- the reader's current tile on a 300MB device.
        local source_pixels = math.max(1, math.ceil(union.w * zoom_union))
            * math.max(1, math.ceil(union.h * zoom_union))
        -- Classic's ImageWidget also allocates a zoomed copy of the shared canvas.
        -- The union-fit bitmap can be small while that copy approaches sixteen
        -- screens, so reserve both before rendering on low-memory devices.
        local transition_pixels = use_viewport_frames and screen_area * 4
            or canvas_w * canvas_h
                + math.ceil(canvas_w * target_zoom / zoom_union) * math.ceil(canvas_h * target_zoom / zoom_union)
        -- Cropped modes briefly hold both the rendered union and its masked copy.
        local transition_bytes = (source_pixels * (clips and 2 or 1) + transition_pixels) * 4 + 2 * 1024 * 1024
        if not Memory.hasAllocationHeadroom(NAV_TRANSITION_MIN_FREE_BYTES, transition_bytes) then
            Timing.log("animateSwitchToImageNum: transition working set is too large, falling back to instant swap")
            return self:completeNavTransition(target, on_complete)
        end
        local ok, content_image, content_image_owned = pcall(function()
            if self.image_union_renderer then
                return self.image_union_renderer(union, zoom_union), true
            end
            return PageRender.drawPagePart(self.reader_ui, self.page, union, 0), false
        end)
        if not ok or not content_image then
            logger.warn(
                "[Panels+] smooth transition page draw failed, falling back to instant swap:",
                tostring(content_image)
            )
            return self:completeNavTransition(target, on_complete)
        end

        if clips then
            local masked = maskTransitionSource(content_image, union, clips, PageRender.getBackground(self.reader_ui))
            if content_image_owned then
                content_image:free()
            end
            if not masked then
                return self:completeNavTransition(target, on_complete)
            end
            content_image, content_image_owned = masked, true
        end

        if use_viewport_frames then
            return self:runNavViewportAnimation(
                target,
                union,
                content_image,
                content_image_owned,
                zoom_union,
                ax,
                ay,
                bx,
                by,
                target_zoom,
                target_margin_factor,
                on_complete,
                clips
            )
        end

        local scale = target_zoom / zoom_union -- applied once, below, via self.scale_factor

        local canvas, annotation_rect
        local ok_canvas, canvas_image = pcall(function()
            canvas = Blitbuffer.new(canvas_w, canvas_h, content_image:getType())
            canvas:fill(PageRender.getBackground(self.reader_ui))
            -- Clamp against float-rounding drift between this module's zoom math and
            -- drawPagePart()'s own internal rect scaling, so the blit never reads or
            -- writes a row/column past either buffer's actual allocated bounds.
            local paste_x = math.max(0, math.floor((union.x - (bx - half_w)) * zoom_union))
            local paste_y = math.max(0, math.floor((union.y - (by - half_h)) * zoom_union))
            local blit_w = math.min(content_image:getWidth(), canvas_w - paste_x)
            local blit_h = math.min(content_image:getHeight(), canvas_h - paste_y)
            if blit_w > 0 and blit_h > 0 then
                canvas:blitFrom(content_image, paste_x, paste_y, 0, 0, blit_w, blit_h)
            end
            annotation_rect = PanelViewport.canvasRect(
                union,
                content_image:getWidth(),
                content_image:getHeight(),
                canvas_w,
                canvas_h,
                paste_x,
                paste_y
            )
            return canvas
        end)
        if content_image_owned and content_image and content_image.free then
            content_image:free()
        end
        if not ok_canvas or not canvas_image then
            if canvas then
                canvas:free()
            end
            return self:completeNavTransition(target, on_complete)
        end
        -- Document renders are DocCache-owned; image-union renderers return an
        -- owned temporary buffer, released after its pixels have been copied.

        local ratio_ax, ratio_ay = (ax - (bx - half_w)) / (2 * half_w), (ay - (by - half_h)) / (2 * half_h)
        local ratio_bx, ratio_by = 0.5, 0.5 -- target's center sits at the canvas center by construction

        self._panels_plus_transition_active = true
        local old_image = self.image
        self.image = canvas_image
        self._annotation_transition = transitionAnnotations(canvas_image, self.page, annotation_rect, clips)
        self._center_x_ratio, self._center_y_ratio = ratio_ax, ratio_ay
        self.scale_factor = scale
        self._panels_plus_transition_margin_factor = target_margin_factor
        self:update()
        if self.image_disposable then
            self:releasePreviousPanelImage(old_image)
        end

        self:runNavPanAnimation(ratio_bx, ratio_by, function()
            self._panels_plus_transition_margin_factor = nil
            self:completeNavTransition(target, on_complete)
        end)
    end

    --- Animate pan and zoom by scaling only the visible crop of a screen-fit union.
    --- Interpolate both endpoints' framing, including their margin mode factors.
    function PanelViewer:runNavViewportAnimation(
        target,
        union,
        source,
        owned,
        source_zoom,
        ax,
        ay,
        bx,
        by,
        target_zoom,
        margin_factor,
        on_complete,
        clips
    )
        -- Document tiles belong to DocCache and can be evicted by an idle render
        -- between animation ticks. Retain our own pixels until the pan completes.
        if not owned then
            local ok, copy = pcall(source.copy, source)
            if not ok or not copy then
                return self:completeNavTransition(target, on_complete)
            end
            source, owned = copy, true
        end
        local style = NavEasing.normalize(self.nav_smooth_style)
        local start_margin_factor = self:getMarginShrinkFactorForPanel(self._images_list_cur) or 1
        local container_w, container_h = self:getPanelViewportSize()
        local start_rect = self.image_rects[self._images_list_cur]
        local start_zoom = panelFitZoom(self, start_rect, container_w, container_h) * start_margin_factor
        if style == "classic" then
            -- Match Classic's shared canvas even when only viewport crops fit in
            -- memory: pan at the destination's zoom and framing throughout.
            start_margin_factor = margin_factor
            start_zoom = target_zoom
        end
        local steps = math.max(1, self.nav_transition_frames or NAV_TRANSITION_STEPS_DEFAULT)
        local delay = (self.nav_transition_duration or 0.4) / steps
        local step = 0
        local function cleanup()
            if owned then
                source:free()
                owned = false
            end
        end
        local function finish()
            cleanup()
            self._panels_plus_transition_cleanup = nil
            self._panels_plus_transition_active = nil
            self._panels_plus_transition_margin_factor = nil
            self:completeNavTransition(target, on_complete)
        end
        local function showFrame(progress)
            progress = NavEasing.progress(style, progress)
            local frame_margin = start_margin_factor + (margin_factor - start_margin_factor) * progress
            local viewport_w = math.max(1, math.floor(container_w * frame_margin))
            local viewport_h = math.max(1, math.floor(container_h * frame_margin))
            local zoom = start_zoom + (target_zoom - start_zoom) * progress
            local x = ax + (bx - ax) * progress
            local y = ay + (by - ay) * progress
            local crop_w = math.max(1, math.ceil(viewport_w * source_zoom / zoom))
            local crop_h = math.max(1, math.ceil(viewport_h * source_zoom / zoom))
            local left = math.floor((x - union.x) * source_zoom - crop_w / 2)
            local top = math.floor((y - union.y) * source_zoom - crop_h / 2)
            local crop, frame
            local ok = pcall(function()
                crop = Blitbuffer.new(crop_w, crop_h, source:getType())
                crop:fill(PageRender.getBackground(self.reader_ui))
                local sx, sy = math.max(0, left), math.max(0, top)
                local dx, dy = math.max(0, -left), math.max(0, -top)
                local w = math.min(source:getWidth() - sx, crop_w - dx)
                local h = math.min(source:getHeight() - sy, crop_h - dy)
                if w > 0 and h > 0 then
                    crop:blitFrom(source, dx, dy, sx, sy, w, h)
                end
                frame = RenderImage:scaleBlitBuffer(crop, viewport_w, viewport_h, false)
            end)
            if crop and crop ~= frame then
                crop:free()
            end
            if not ok or not frame then
                return false
            end
            local old_image = self.image
            self.image = frame
            self._annotation_transition = transitionAnnotations(
                frame,
                self.page,
                PanelViewport.canvasRect(union, source:getWidth(), source:getHeight(), crop_w, crop_h, -left, -top),
                clips
            )
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self.scale_factor = 1
            self._panels_plus_transition_margin_factor = frame_margin
            self:update()
            if self.image_disposable then
                self:releasePreviousPanelImage(old_image)
            end
            return true
        end
        self._panels_plus_transition_active = true
        self._panels_plus_transition_margin_factor = margin_factor
        self._panels_plus_transition_cleanup = cleanup
        if not showFrame(0) then
            return finish()
        end
        local walkStep
        walkStep = function()
            self._panels_plus_transition_action = nil
            if not self._panels_plus_transition_active or self._panels_plus_closed or not self:isOpen() then
                cleanup()
                self._panels_plus_transition_cleanup = nil
                self._panels_plus_transition_active = nil
                self._panels_plus_transition_margin_factor = nil
                if self._panels_plus_closed or not self:isOpen() then
                    self._annotation_transition = nil
                end
                return
            end
            step = step + 1
            if not showFrame(step / steps) or step >= steps then
                finish()
            else
                self._panels_plus_transition_action = walkStep
                UIManager:scheduleIn(delay, walkStep)
            end
        end
        self._panels_plus_transition_action = walkStep
        UIManager:scheduleIn(delay, walkStep)
    end

    --- Run the smooth-navigation pan from the widget's current offset to a target
    --- ratio, then invoke `on_complete`.
    ---
    --- Assumes the caller has already set `self.image`/`self._center_x_ratio`/
    --- `self._center_y_ratio`/`self.scale_factor` to the *starting* frame and
    --- called `self:update()`. Each step re-targets an absolute offset for that
    --- point in the animation, computed from the widget's *actual* current offset
    --- rather than a fixed per-step delta. `panBy()` floors its result every call,
    --- so fixed deltas silently lose a fraction of a pixel each step; over several
    --- steps that drifts away from the target, and the final hand-off then has to
    --- snap the last bit of distance in one jump. Recomputing the delta from the
    --- real current offset each time folds any prior drift into the next step
    --- instead of letting it accumulate, and the last step targets the exact final
    --- offset, so the pan always lands precisely on the target ratio.
    ---
    --- @param target_ratio_x number Final `center_x_ratio` to land on.
    --- @param target_ratio_y number Final `center_y_ratio` to land on.
    --- @param on_complete fun() Called on the last step, instead of a hardcoded handoff.
    function PanelViewer:runNavPanAnimation(target_ratio_x, target_ratio_y, on_complete)
        self._image_wg:getSize() -- primes _render() so getCurrentWidth/Height are valid
        local bb_w, bb_h = self._image_wg:getCurrentWidth(), self._image_wg:getCurrentHeight()
        local viewport_w, viewport_h = self._image_wg.width, self._image_wg.height
        local start_offset_x, start_offset_y = self._image_wg._offset_x, self._image_wg._offset_y
        local target_offset_x = math.floor(target_ratio_x * bb_w - viewport_w / 2)
        local target_offset_y = math.floor(target_ratio_y * bb_h - viewport_h / 2)
        local steps = self.nav_transition_frames
        if not steps or steps <= 0 then
            steps = NAV_TRANSITION_STEPS_DEFAULT
        end
        local step_delay = (self.nav_transition_duration or 0.4) / steps
        local style = NavEasing.normalize(self.nav_smooth_style)

        local step_n = 0
        local walkStep
        walkStep = function()
            self._panels_plus_transition_action = nil
            if not self._panels_plus_transition_active or self._panels_plus_closed or not self:isOpen() then
                self._panels_plus_transition_active = nil
                if self._panels_plus_closed or not self:isOpen() then
                    self._annotation_transition = nil
                end
                return
            end
            step_n = step_n + 1
            local progress = NavEasing.progress(style, step_n / steps)
            local desired_x, desired_y = target_offset_x, target_offset_y
            if step_n < steps then
                desired_x = start_offset_x + (target_offset_x - start_offset_x) * progress
                desired_y = start_offset_y + (target_offset_y - start_offset_y) * progress
            end
            self:panBy(desired_x - self._image_wg._offset_x, desired_y - self._image_wg._offset_y)
            self:notifyAnnotationNavigationFrame()
            if step_n < steps then
                self._panels_plus_transition_action = walkStep
                UIManager:scheduleIn(step_delay, walkStep)
            else
                self._panels_plus_transition_active = nil
                on_complete()
            end
        end
        self._panels_plus_transition_action = walkStep
        UIManager:scheduleIn(step_delay, walkStep)
    end

    --- Dispatch a first/last-panel boundary crossing, animating it when smooth
    --- navigation and cross-page transitions are both enabled.
    ---
    --- @param direction PPBoundaryDirection `"next"` or `"previous"`.
    --- @return boolean|nil handled Whether the crossing was handled.
    function PanelViewer:onPanelBoundary(direction)
        if
            self.nav_transition_mode == "smooth"
            and self.nav_transition_cross_page
            and not self.image_union_renderer
        then
            return self:animateBoundaryTransition(direction)
        end
        return self.boundary_callback and self.boundary_callback(direction, self)
    end

    --- Animate a camera pan across a page boundary when the adjacent page's
    --- panels are already cached; otherwise, or on any failure at any stage,
    --- falls straight back to the classic instant boundary crossing.
    ---
    --- Renders the current page's edge panel and the adjacent page's landing
    --- panel independently (there is no shared coordinate space across pages),
    --- rescales the current-page slice to the landing panel's own zoom (a single
    --- one-shot rescale, not per-frame), and composites both into one canvas
    --- side-by-side in the swipe direction -- continuing the pan and letting the
    --- reveal read as one continuous strip rather than a distinct "page turn".
    --- Both slices are centered vertically within a shared canvas height, so the
    --- resulting pan is purely horizontal by construction. The actual page turn
    --- (GotoPage, closing this viewer, opening the adjacent one) only happens
    --- after the pan completes, via `nav_boundary_commit_callback`.
    ---
    --- @param direction PPBoundaryDirection `"next"` or `"previous"`.
    --- @return boolean|nil handled Whether the crossing was handled (always true
    ---   once a resolution exists, since failure paths fall back to the classic
    ---   callback which itself always handles the crossing).
    -- With preview_complete, pan out and back on the temporary canvas while
    -- retaining the original image, viewer, page, and framing.
    function PanelViewer:animateBoundaryTransition(direction, preview_complete)
        local function fallback()
            if preview_complete then
                preview_complete(false)
                return true
            end
            return self.boundary_callback and self.boundary_callback(direction, self)
        end
        if self._panels_plus_transition_active then
            return true -- swallow a re-entrant swipe while a pan is already in flight
        end
        if not self.nav_boundary_peek_callback then
            return fallback()
        end

        local resolved = self.nav_boundary_peek_callback(direction, self)
        if not resolved then
            return fallback()
        end
        if
            self:shouldAutoRotateDoublePage(self._images_list_cur)
            or (self.auto_rotate_double_pages ~= false and self.image_rotation == nil)
                and DoubleSpread.shouldRotate(
                    resolved.target_rect,
                    resolved.target_is_full_page,
                    resolved.panels and #resolved.panels == 1
                )
        then
            return fallback()
        end

        local rect_a = self.image_rects and self.image_rects[self._images_list_cur]
        local rect_b = resolved.target_rect
        if not rect_a or not rect_b then
            return fallback()
        end

        Timing.log(
            "animateBoundaryTransition: direction=%s target_page=%s (crop_mode=%s)",
            direction,
            resolved and tostring(resolved.next_page) or "none",
            tostring(self.crop_mode)
        )
        Timing.memory("smooth_boundary_transition")

        local target_zoom = canvasFitZoom(rect_b)
        local target_margin_factor = self:getMarginShrinkFactorForPanel(nil, resolved.target_is_full_page) or 1
        local owned_a, owned_b
        local function releaseTiles()
            if owned_a then
                owned_a:free()
                owned_a = nil
            end
            if owned_b then
                owned_b:free()
                owned_b = nil
            end
        end

        local ok_a, tile_a, rotated_a = pcall(function()
            if self.crop_mode == "none" and self._images_list and self._images_list[self._images_list_cur] then
                local img = self._images_list[self._images_list_cur]
                if type(img) == "function" then
                    owned_a = img()
                    return owned_a
                end
                return img
            end
            return PageRender.drawPagePart(self.reader_ui, self.page, rect_a, 0)
        end)
        if not ok_a or not tile_a then
            logger.warn("[Panels+] boundary transition tile A render failed, falling back:", tostring(tile_a))
            return fallback()
        end
        -- Rendering the destination can evict the first tile from DocCache.
        if not owned_a then
            local bytes = tile_a:getWidth() * tile_a:getHeight() * 4
            if not Memory.hasAllocationHeadroom(NAV_TRANSITION_MIN_FREE_BYTES, bytes) then
                return fallback()
            end
            local ok_copy, copy = pcall(tile_a.copy, tile_a)
            if not ok_copy or not copy then
                return fallback()
            end
            owned_a, tile_a = copy, copy
        end
        local ok_b, tile_b, rotated_b = pcall(function()
            if self.crop_mode == "none" and resolved.next_images and resolved.next_images[resolved.start_idx] then
                local img = resolved.next_images[resolved.start_idx]
                if type(img) == "function" then
                    owned_b = img()
                    return owned_b
                end
                return img
            end
            return PageRender.drawPagePart(self.reader_ui, resolved.next_page, rect_b, 0)
        end)
        if not ok_b or not tile_b then
            releaseTiles()
            logger.warn("[Panels+] boundary transition tile B render failed, falling back:", tostring(tile_b))
            return fallback()
        end
        if (rotated_a and true or false) ~= (rotated_b and true or false) then
            releaseTiles()
            -- Mismatched auto-rotation between the two pages' slices can't be
            -- composited safely -- rare (differing panel aspect ratios right at
            -- the boundary); not worth reconciling for this iteration.
            return fallback()
        end

        -- Bring page A's slice to the SAME zoom page B's slice already has
        -- (drawPagePart(rect_b) is bare, so tile_b is already at target_zoom).
        -- This is a single one-shot rescale, not a per-frame cost.
        local zoom_a = canvasFitZoom(rect_a)
        local scale_a = target_zoom / zoom_a
        local scaled_pixels = math.max(1, math.ceil(tile_a:getWidth() * scale_a))
            * math.max(1, math.ceil(tile_a:getHeight() * scale_a))
        if not Memory.hasAllocationHeadroom(NAV_TRANSITION_MIN_FREE_BYTES, scaled_pixels * 4) then
            releaseTiles()
            return fallback()
        end
        local ok_scale, tile_a_scaled = pcall(function()
            if scale_a == 1 then
                return tile_a
            end
            local new_w = math.max(1, math.floor(tile_a:getWidth() * scale_a + 0.5))
            local new_h = math.max(1, math.floor(tile_a:getHeight() * scale_a + 0.5))
            return RenderImage:scaleBlitBuffer(tile_a, new_w, new_h, false)
        end)
        if not ok_scale or not tile_a_scaled then
            releaseTiles()
            return fallback()
        end

        -- Deliberately independent of `getNextSwipeDirection()`/`invert_swipe`: this
        -- is about which screen-side pages enter from, tied purely to manga (right
        -- to left) vs comic (left to right) reading order, not the swipe-gesture
        -- preference.
        local manga_next_is_west = self.reading_mode ~= "comic"
        local travel_west = (direction == "next") == manga_next_is_west

        local viewport_w, viewport_h = Screen:getWidth(), Screen:getHeight()
        local half_w_a = math.max(viewport_w / 2, tile_a_scaled:getWidth() / 2)
        local half_h_a = math.max(viewport_h / 2, tile_a_scaled:getHeight() / 2)
        local target_pixel_w, target_pixel_h = tile_b:getWidth(), tile_b:getHeight()
        local half_w_b = math.max(viewport_w / 2, target_pixel_w / 2)
        local half_h_b = math.max(viewport_h / 2, target_pixel_h / 2)

        local canvas_w = math.max(1, math.ceil(2 * half_w_a + 2 * half_w_b))
        local canvas_h = math.max(1, math.ceil(math.max(2 * half_h_a, 2 * half_h_b)))

        local screen_area = viewport_w * viewport_h
        if
            canvas_w * canvas_h > screen_area * NAV_TRANSITION_MAX_AREA_MULTIPLIER
            or not Memory.hasAllocationHeadroom(NAV_TRANSITION_MIN_FREE_BYTES, canvas_w * canvas_h * 4)
        then
            if tile_a_scaled ~= tile_a and tile_a_scaled.free then
                tile_a_scaled:free()
            end
            releaseTiles()
            return fallback()
        end

        local a_left = travel_west and (2 * half_w_b) or 0
        local b_left = travel_west and 0 or (2 * half_w_a)

        local canvas, annotation_regions
        local ok_canvas, canvas_image = pcall(function()
            canvas = Blitbuffer.new(canvas_w, canvas_h, tile_b:getType())
            canvas:fill(PageRender.getBackground(self.reader_ui))
            local a_x = math.max(0, math.floor(a_left + half_w_a - tile_a_scaled:getWidth() / 2))
            local a_y = math.max(0, math.floor(canvas_h / 2 - tile_a_scaled:getHeight() / 2))
            local a_w = math.min(tile_a_scaled:getWidth(), canvas_w - a_x)
            local a_h = math.min(tile_a_scaled:getHeight(), canvas_h - a_y)
            if a_w > 0 and a_h > 0 then
                canvas:blitFrom(tile_a_scaled, a_x, a_y, 0, 0, a_w, a_h)
            end
            local b_x = math.max(0, math.floor(b_left + half_w_b - tile_b:getWidth() / 2))
            local b_y = math.max(0, math.floor(canvas_h / 2 - tile_b:getHeight() / 2))
            local b_w = math.min(tile_b:getWidth(), canvas_w - b_x)
            local b_h = math.min(tile_b:getHeight(), canvas_h - b_y)
            if b_w > 0 and b_h > 0 then
                canvas:blitFrom(tile_b, b_x, b_y, 0, 0, b_w, b_h)
            end
            local canvas_rects_a = self._images_list and self._images_list.canvas_rects
            local canvas_rects_b = resolved.next_images and resolved.next_images.canvas_rects
            local native_a = (canvas_rects_a and canvas_rects_a[self._images_list_cur]) or rect_a
            local native_b = (canvas_rects_b and canvas_rects_b[resolved.start_idx]) or rect_b
            annotation_regions = {
                {
                    page = self.page,
                    clip = native_a,
                    rect = PanelViewport.canvasRect(
                        native_a,
                        tile_a_scaled:getWidth(),
                        tile_a_scaled:getHeight(),
                        canvas_w,
                        canvas_h,
                        a_x,
                        a_y
                    ),
                },
                {
                    page = resolved.next_page,
                    clip = native_b,
                    rect = PanelViewport.canvasRect(
                        native_b,
                        tile_b:getWidth(),
                        tile_b:getHeight(),
                        canvas_w,
                        canvas_h,
                        b_x,
                        b_y
                    ),
                },
            }
            return canvas
        end)
        if tile_a_scaled ~= tile_a and tile_a_scaled.free then
            tile_a_scaled:free() -- pixels already copied into canvas_image
        end
        releaseTiles()
        if not ok_canvas or not canvas_image then
            if canvas then
                canvas:free()
            end
            return fallback()
        end

        local ratio_ax = (a_left + half_w_a) / canvas_w
        local ratio_bx = (b_left + half_w_b) / canvas_w
        local ratio_ay, ratio_by = 0.5, 0.5 -- each slice is centered vertically in the shared canvas_h

        self._panels_plus_transition_active = true
        local old_image = self.image
        local old_x, old_y, old_scale = self._center_x_ratio, self._center_y_ratio, self.scale_factor
        local old_margin = self._panels_plus_transition_margin_factor
        if preview_complete then
            -- Retain the original image for the return leg; release it if the
            -- viewer closes while the temporary cross-page canvas is displayed.
            self._panels_plus_transition_cleanup = function()
                if self.image_disposable and old_image and old_image.free then
                    old_image:free()
                end
            end
        end
        self.image = canvas_image
        self._annotation_transition = { image = canvas_image, regions = annotation_regions }
        self._center_x_ratio, self._center_y_ratio = ratio_ax, ratio_ay
        -- Fit the landing tile's actual pixels, including No crop padding, into
        -- the available viewport. Toolbar space and margins must match the final
        -- stationary panel instead of snapping back to screen-sized framing.
        local available_w, available_h = self:getPanelViewportSize()
        self.scale_factor = target_margin_factor * math.min(available_w / target_pixel_w, available_h / target_pixel_h)
        self._panels_plus_transition_margin_factor = target_margin_factor
        self:update()
        if self.image_disposable and not preview_complete then
            self:releasePreviousPanelImage(old_image)
        end

        self:runNavPanAnimation(ratio_bx, ratio_by, function()
            if preview_complete then
                self._panels_plus_transition_active = true
                local returnStep = function()
                    self._panels_plus_transition_action = nil
                    if self._panels_plus_closed or not self:isOpen() then
                        return
                    end
                    self:runNavPanAnimation(ratio_ax, ratio_ay, function()
                        self._panels_plus_transition_cleanup = nil
                        self.image = old_image
                        self._annotation_transition = nil
                        self._center_x_ratio, self._center_y_ratio = old_x, old_y
                        self.scale_factor = old_scale
                        self._panels_plus_transition_margin_factor = old_margin
                        self:update()
                        if self.image_disposable then
                            self:releasePreviousPanelImage(canvas_image)
                        end
                        preview_complete(true)
                    end)
                end
                self._panels_plus_transition_action = returnStep
                UIManager:scheduleIn(0.15, returnStep)
                return
            end
            self._panels_plus_transition_margin_factor = nil
            self._annotation_transition = nil
            if self.nav_boundary_commit_callback then
                self.nav_boundary_commit_callback(self, direction, resolved)
            end
        end)
        return true
    end
end
