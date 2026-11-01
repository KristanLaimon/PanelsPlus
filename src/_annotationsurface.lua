-- Panels+ implements Ink Away's generic document-surface contract. Geometry
-- stays here; drawing tools and the persistent annotation format stay there.
local FoldJoin = require("src._foldjoin")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

local Surface = {}
Surface.__index = Surface

function Surface.new(viewer)
    return setmetatable({ version = 1, document = viewer.reader_ui.document, viewer = viewer }, Surface)
end

function Surface:geometry()
    local v = self.viewer
    local transition = self._transition_region or v._annotation_transition
    if not self._transition_region and transition and transition.image ~= v.image then
        transition = nil
    end
    local index = v._images_list_cur or 1
    local canvas_rects = v._images_list and v._images_list.canvas_rects
    local rect = (transition and transition.rect)
        or (canvas_rects and canvas_rects[index])
        or (v.image_rects and v.image_rects[index])
    local widget = v._image_wg
    if not rect or not widget or v._panels_plus_closed then
        return nil
    end
    widget:getSize()
    local w, h = widget:getCurrentWidth(), widget:getCurrentHeight()
    if not w or not h or w <= 0 or h <= 0 then
        return nil
    end
    local dimen = widget.dimen or {}
    local fold
    if not transition then
        fold = v:currentFold()
    end
    return {
        page = transition and transition.page or v.page,
        rect = rect,
        w = w,
        h = h,
        x = (dimen.x or 0) - (widget._offset_x or 0),
        y = (dimen.y or 0) - (widget._offset_y or 0),
        angle = v:annotationDrawnAngle(),
        fold = fold,
    }
end

function Surface:pages()
    local g = self:geometry()
    return { g and g.page or self.viewer.page }
end

function Surface:isAffine()
    local g = self:geometry()
    return g and not g.fold
end

function Surface:key()
    local g = self:geometry()
    if not g then
        return "closed"
    end
    local r, f = g.rect, g.fold or {}
    return table.concat({
        g.page,
        r.x,
        r.y,
        r.w,
        r.h,
        g.w,
        g.h,
        g.x,
        g.y,
        g.angle,
        f.u0 or 0,
        f.u1 or 0,
        f.pad or 0,
        g.shift or 0,
    }, ":")
end

function Surface:toPage(x, y, geometry)
    local g = geometry or self:geometry()
    if not g then
        return nil
    end
    local nx, ny = (x - g.x) / g.w, (y - g.y) / g.h
    local u, v = nx, ny
    if g.angle == 90 then
        u, v = 1 - ny, nx
    elseif g.angle == 180 then
        u, v = 1 - nx, 1 - ny
    elseif g.angle == 270 then
        u, v = ny, 1 - nx
    end
    local zoom = (g.angle % 180 == 0 and g.w or g.h) / g.rect.w
    if g.fold then
        u = u - g.fold.pad
        if u >= g.fold.u0 then
            u = u + g.fold.u1 - g.fold.u0
        end
    end
    u = u - (g.shift or 0)
    return g.page, g.rect.x + u * g.rect.w, g.rect.y + v * g.rect.h, zoom, -math.rad(g.angle)
end

function Surface:toScreen(page, x, y, geometry)
    local g = geometry or self:geometry()
    if not g or page ~= g.page then
        return nil
    end
    local u = FoldJoin.toJoinedU((x - g.rect.x) / g.rect.w, g.fold) + (g.shift or 0)
    local v = (y - g.rect.y) / g.rect.h
    local nx, ny = u, v
    if g.angle == 90 then
        nx, ny = v, 1 - u
    elseif g.angle == 180 then
        nx, ny = 1 - u, 1 - v
    elseif g.angle == 270 then
        nx, ny = 1 - v, u
    end
    return g.x + nx * g.w, g.y + ny * g.h, (g.angle % 180 == 0 and g.w or g.h) / g.rect.w, -math.rad(g.angle)
end

-- Add vertices on both sides of a discontinuity before mapping a path. This
-- keeps a stroke crossing a removed fold aligned on both halves of the scan.
function Surface:mapPath(points, to_page, page)
    local g = self:geometry()
    local out = {}
    local function map(x, y)
        local a, b
        if to_page then
            local _
            _, a, b = self:toPage(x, y, g)
        else
            a, b = self:toScreen(page, x, y, g)
        end
        out[#out + 1], out[#out + 2] = a, b
    end
    local function axis(x, y)
        if not to_page then
            return (x - g.rect.x) / g.rect.w
        end
        if g.angle == 90 then
            return 1 - (y - g.y) / g.h
        end
        if g.angle == 180 then
            return 1 - (x - g.x) / g.w
        end
        if g.angle == 270 then
            return (y - g.y) / g.h
        end
        return (x - g.x) / g.w
    end
    for i = 1, #points - 1, 2 do
        if i > 1 and g.fold then
            local x0, y0, x1, y1 = points[i - 2], points[i - 1], points[i], points[i + 1]
            local a, b = axis(x0, y0), axis(x1, y1)
            local seams = to_page and { g.fold.u0 + g.fold.pad } or { g.fold.u0, g.fold.u1 }
            local splits = {}
            for _, seam in ipairs(seams) do
                if a ~= b then
                    local t = (seam - a) / (b - a)
                    if t > 0 and t < 1 then
                        splits[#splits + 1] = t
                    end
                end
            end
            table.sort(splits)
            for _, t in ipairs(splits) do
                for _, epsilon in ipairs({ -1e-8, 1e-8 }) do
                    local s = math.max(0, math.min(1, t + epsilon))
                    map(x0 + (x1 - x0) * s, y0 + (y1 - y0) * s)
                end
            end
        end
        map(points[i], points[i + 1])
    end
    return out
end

function Surface:clip()
    local g = self:geometry()
    if not g then
        return nil
    end
    local d = self.viewer._image_wg.dimen
    local left, top, right, bottom = g.x, g.y, g.x + g.w, g.y + g.h
    if self._region_box or g.fold then
        local r = self._region_box or g.rect
        local x0, y0 = self:toScreen(g.page, r.x, r.y)
        local x1, y1 = self:toScreen(g.page, r.x + r.w, r.y + r.h)
        left, top, right, bottom = math.min(x0, x1), math.min(y0, y1), math.max(x0, x1), math.max(y0, y1)
    end
    local x, y = math.max(0, left, d.x), math.max(0, top, d.y)
    return {
        x = math.floor(x),
        y = math.floor(y),
        w = math.max(0, math.floor(math.min(Screen:getWidth(), right, d.x + d.w)) - math.floor(x)),
        h = math.max(0, math.floor(math.min(Screen:getHeight(), bottom, d.y + d.h)) - math.floor(y)),
    }
end

-- Each page slice or retained fold half is affine. Rendering native ops through
-- each region, clipped afterwards, also handles pictures, text and fills.
function Surface:regions()
    local transition = self.viewer._annotation_transition
    if not self._transition_region and transition and transition.image == self.viewer.image and transition.regions then
        local regions = {}
        for _, region in ipairs(transition.regions) do
            regions[#regions + 1] = setmetatable({
                version = 1,
                document = self.document,
                viewer = self.viewer,
                _transition_region = region,
                _region_box = region.clip,
            }, Surface)
        end
        return regions
    end
    local g = self:geometry()
    if not g or not g.fold then
        return { self }
    end
    local regions = {}
    for _, span in ipairs({ { 0, g.fold.u0, g.fold.pad }, { g.fold.u1, 1, g.fold.pad - g.fold.u1 + g.fold.u0 } }) do
        local geometry = {}
        for k, value in pairs(g) do
            geometry[k] = value
        end
        geometry.fold, geometry.shift = nil, span[3]
        regions[#regions + 1] = setmetatable({
            version = 1,
            document = self.document,
            viewer = self.viewer,
            geometry = function()
                return geometry
            end,
            _region_box = {
                x = g.rect.x + span[1] * g.rect.w,
                y = g.rect.y,
                w = (span[2] - span[1]) * g.rect.w,
                h = g.rect.h,
            },
        }, Surface)
    end
    return regions
end

function Surface:snapshot(bb)
    self.viewer:paintAnnotationBackground(bb)
end

function Surface:repaint()
    if not self.viewer._panels_plus_closed then
        UIManager:setDirty(self.viewer, "ui")
    end
end

function Surface:setJoined(joined)
    local v = self.viewer
    if not v._images_list or v._panels_plus_closed or v._annotation_closing then
        return
    end
    local previous = v._images_list.annotation_join_spread_fold
    if previous == nil then
        previous = v.join_spread_fold ~= false
    end
    v._images_list.annotation_join_spread_fold = joined
    local effective = joined
    if effective == nil then
        effective = v.join_spread_fold ~= false
    end
    if previous == effective then
        return
    end
    local index = v._images_list_cur
    if v._images_list.folds then
        v._images_list.folds[index] = nil
    end
    v._images_list_cur = nil
    v:switchToImageNum(index)
end

function Surface:begin()
    self:setJoined(self.viewer.inkaway_join_spread_fold ~= false)
end

-- The editor supplies screen space left free by its own chrome. Panels+ owns
-- fitting the image into it; no toolbar-side knowledge belongs in this adapter.
function Surface:setViewport(rect, refresh)
    local v = self.viewer
    if v._panels_plus_closed or v._annotation_closing then
        return false
    end
    self.refresh_layout = refresh
    local old = v._annotation_viewport
    if old and old.x == rect.x and old.y == rect.y and old.w == rect.w and old.h == rect.h then
        return false
    end
    local before = v:getAnnotationViewportInsets()
    v._annotation_viewport = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    local after = v:getAnnotationViewportInsets()
    if
        before.left ~= after.left
        or before.top ~= after.top
        or before.right ~= after.right
        or before.bottom ~= after.bottom
    then
        v:update()
        return true
    end
    return false
end

function Surface:finish()
    self.navigation_done = nil
    self.navigation_frame = nil
    self.refresh_layout = nil
    local v = self.viewer
    local insets = v:getAnnotationViewportInsets()
    local resized = insets.left > 0 or insets.top > 0 or insets.right > 0 or insets.bottom > 0
    v._annotation_viewport = nil
    self:setJoined(nil)
    if resized and not v._panels_plus_closed and not v._annotation_closing then
        v:update()
    end
    self:repaint()
end

function Surface:readingDirection()
    return self.viewer.reading_mode == "comic" and "ltr" or "rtl"
end

function Surface:completeNavigation(surface)
    local done = self.navigation_done
    self.navigation_done, self.navigation_frame = nil, nil
    if done then
        done(surface or self)
    end
end

function Surface:turn(dir, done, frame)
    local v = self.viewer
    if self.navigation_done then
        return
    end
    self.navigation_done, self.navigation_frame = done, frame
    local index = v._images_list_cur + dir
    if index >= 1 and index <= v._images_list_nb then
        if v.nav_transition_mode == "smooth" then
            v:animateSwitchToImageNum(index, function()
                self:completeNavigation()
            end)
        else
            v:switchToImageNum(index)
            self:completeNavigation()
        end
    elseif v.boundary_callback then
        if v.nav_transition_mode == "smooth" then
            v:onPanelBoundary(dir > 0 and "next" or "previous")
        else
            v.boundary_callback(dir > 0 and "next" or "previous", v)
        end
        if not v._panels_plus_boundary_pending and not v._panels_plus_transition_active and self.navigation_done then
            self:completeNavigation()
        end
    else
        self:completeNavigation()
    end
end

return Surface
