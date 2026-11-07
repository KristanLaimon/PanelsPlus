-- Panels+ implements Ink Away's generic document-surface contract. Geometry
-- stays here; drawing tools and the persistent annotation format stay there.
local FoldJoin = require("src._foldjoin")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

local logger = require("logger")
local InkAway = {}
local Surface = {}
Surface.__index = Surface

function Surface.new(viewer, paint_background)
    return setmetatable(
        { version = 1, document = viewer.reader_ui.document, viewer = viewer, paint_background = paint_background },
        Surface
    )
end

function Surface:geometry()
    local v = self.viewer
    local index = v._images_list_cur or 1
    local canvas_rects = v._images_list and v._images_list.canvas_rects
    local rect = (canvas_rects and canvas_rects[index]) or (v.image_rects and v.image_rects[index])
    local widget = v._image_wg
    if
        not rect
        or not v.page
        or rect.w <= 0
        or rect.h <= 0
        or not widget
        or v._panels_plus_closed
        or v.embedded_source_image
        or v._panels_plus_transition_active
    then
        return nil
    end
    widget:getSize()
    local w, h = widget:getCurrentWidth(), widget:getCurrentHeight()
    if not w or not h or w <= 0 or h <= 0 then
        return nil
    end
    local dimen = widget.dimen or {}
    local angle = type(v.rotated) == "number" and v.rotated or (v.rotated and (widget.rotation_angle or 90) or 0)
    return {
        page = v.page,
        rect = rect,
        w = w,
        h = h,
        x = (dimen.x or 0) - (widget._offset_x or 0),
        y = (dimen.y or 0) - (widget._offset_y or 0),
        angle = angle,
        fold = v:currentFold(),
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
    if not g then
        return out
    end
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
    if not d then
        return nil
    end
    local left, top, right, bottom = g.x, g.y, g.x + g.w, g.y + g.h
    local content = self.viewer.image_rects and self.viewer.image_rects[self.viewer._images_list_cur or 1]
    if self._region_box or content then
        local r = self._region_box or content
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
    if not self.viewer._panels_plus_closed then
        self.paint_background(self.viewer, bb, 0, 0)
    end
end

function Surface:repaint()
    if not self.viewer._panels_plus_closed then
        UIManager:setDirty(self.viewer, "ui")
    end
end

function Surface:readingDirection()
    return self.viewer.reading_mode == "comic" and "ltr" or "rtl"
end

-- Install once on the viewer class; all connection state belongs to each viewer.
function InkAway.attach(viewer_class)
    local show, paint, close = viewer_class.onShow, viewer_class.paintTo, viewer_class.onCloseWidget
    function viewer_class:configureInkAway(ink)
        if self._panels_plus_closed or self._inkaway then
            return
        end
        if
            ink.integration_api_version ~= 1
            or ink.document_surface_version ~= 1
            or type(ink.registerRenderingView) ~= "function"
            or type(ink.paintDocumentSurface) ~= "function"
            or type(ink.releaseDocumentSurface) ~= "function"
        then
            return
        end
        local surface = Surface.new(self, paint)
        local unregister = ink:registerRenderingView(self, function(_, context)
            if context.document == surface.document and surface:geometry() then
                return surface
            end
        end, function(err)
            logger.warn("[Panels+] Ink Away surface failed:", tostring(err))
        end)
        self._inkaway = { api = ink, surface = surface, unregister = unregister }
    end
    function viewer_class:onShow()
        local result = show(self)
        local ui = self.reader_ui
        if ui and ui.document then
            if ui.inkAwayIntegrationAPI then
                local ok, err = pcall(self.configureInkAway, self, ui.inkAwayIntegrationAPI)
                if not ok then
                    logger.warn("[Panels+] Ink Away registration failed:", tostring(err))
                end
            else
                ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
                ui.inkAwayPendingIntegrations[self] = true
            end
        end
        return result
    end
    function viewer_class:paintTo(bb, x, y)
        paint(self, bb, x, y)
        local connection = self._inkaway
        if connection and self.reader_ui.inkAwayIntegrationAPI == connection.api and connection.surface:geometry() then
            local ok, err = pcall(connection.api.paintDocumentSurface, connection.api, connection.surface, bb)
            if not ok then
                logger.warn("[Panels+] Ink Away painting failed:", tostring(err))
            end
        end
    end
    function viewer_class:onCloseWidget()
        local ui = self.reader_ui
        local pending = ui and ui.inkAwayPendingIntegrations
        if pending then
            pending[self] = nil
            if next(pending) == nil then
                ui.inkAwayPendingIntegrations = nil
            end
        end
        local connection = self._inkaway
        self._inkaway = nil
        if connection then
            local ok, err = pcall(connection.api.releaseDocumentSurface, connection.api, connection.surface)
            connection.unregister()
            if not ok then
                logger.warn("[Panels+] Ink Away release failed:", tostring(err))
            end
        end
        return close(self)
    end
end

return InkAway
