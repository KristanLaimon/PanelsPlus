--[[
The lasso: loop around anything on the page (pen strokes, shapes, fills,
pictures, text boxes) to select it, and a lasso tap pastes what was cut or
copied, on any page of any document. What a loop selects is handled by
ink/view/selection.lua: its frame, handles and menu.
Part of InkAwayView (see ink/view.lua).
]]

local GeomUI = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("ink/l10n")
local Canvas = require("ink/canvas")
local Clipboard = require("ink/clipboard")
local InkGeom = require("ink/geom")

local opInPoly = Canvas.opInPoly

local Screen = Device.screen

local InkAwayView = {}

------------------------------------------------------------------------------
-- Lasso select. A drawing and a notebook page are both op lists, so it works the
-- same on either.
------------------------------------------------------------------------------

-- How close (canvas px) to the lasso's line writing still counts as inside it:
-- about 2.5 mm on screen, whatever the zoom.
function InkAwayView:lassoSlop()
    return Screen:scaleBySize(16) / ((self.view and self.view.zoom) or 1)
end

-- Pick every op the lasso loop holds (canvas coords; see Canvas.opInPoly).
function InkAwayView:computeSelection(poly)
    local idxs = {}
    local slop = self:lassoSlop()
    for i, op in ipairs(self.canvas.ops) do
        if op.kind ~= "erase" and op.kind ~= "smudge" and self:editableOp(op) and opInPoly(op, poly, slop) then
            idxs[#idxs + 1] = i
        end
    end
    return self:selectOps(idxs, "lasso")
end

-- Close the lasso loop, select what it encircled, and show its frame and menu.
function InkAwayView:lassoFinish()
    self.lassoing = false
    local scr = self.lasso_scr
    self.lasso_scr = nil
    if not scr or #scr < 6 then    -- need at least 3 points for an area
        self:redraw()
        return
    end
    local poly = {}
    for i = 1, #scr, 2 do
        local cx, cy = InkGeom.toCanvas(self.view, scr[i], scr[i + 1])
        poly[#poly + 1] = cx; poly[#poly + 1] = cy
    end
    local got = self:computeSelection(poly)
    self:redraw()
    if got then
        self:openSelectionMenu()
    else
        self:showNotice(_("Nothing inside the loop."), 2)
    end
end

-- Paste the clipboard: centred on screen point `pos`, or where it was cut from.
-- The pasted ops become the selection, ready to be dragged into place.
function InkAwayView:pasteAt(pos)
    if Clipboard.count() == 0 then return end
    local cx, cy
    if pos then cx, cy = InkGeom.toCanvas(self.view, pos.x, pos.y) end
    self:flushPending()
    self:layerReady()
    self.canvas:pushHistory()
    local idxs = {}
    for _, op in ipairs(Clipboard.take(cx, cy)) do
        local _op, at = self.canvas:placeOp(op)   -- (onto the active layer)
        idxs[#idxs + 1] = at
    end
    if self.tool ~= "lasso" then self.tool = "lasso"; self:refreshToolLabels() end
    self:selectOps(idxs, "lasso")
    self:markDirty()
    self:composeCanvas(); self:renderView()
    self:refresh(self, "full")
    self:openSelectionMenu()
end

-- A lasso tap on empty canvas with something on the clipboard: offer to paste
-- it there.
function InkAwayView:openPasteMenu(pos)
    self:openActionSheet("_paste_dialog", _("Paste"),
        string.format(_("%d item(s) on the clipboard"), Clipboard.count()), {
            { { _("Paste here"), function() self:pasteAt(pos) end, true },
              { _("Paste where it was"), function() self:pasteAt(nil) end } },
        })
end

-- Gesture entry points for the lasso tool, dispatched from the main handlers. A
-- touch on a selection is the selection's (see onIaTouch); any other starts a
-- loop.
function InkAwayView:lassoTouch(pos)
    self.lassoing = true
    self.lasso_scr = { pos.x, pos.y }
    return true
end

function InkAwayView:lassoPan(pos)
    if self.lassoing and self.lasso_scr then
        self.lasso_scr[#self.lasso_scr + 1] = pos.x
        self.lasso_scr[#self.lasso_scr + 1] = pos.y
        -- refresh only a small box around the new point (a whole segment of a
        -- fast stroke is huge and floods the panel); earlier points stay shown
        if self:onAndroid() then
            self:liveBox("fast", pos.x - 14, pos.y - 14, pos.x + 14, pos.y + 14)
        else
            UIManager:setDirty(self, "fast", GeomUI:new{ x = pos.x - 14, y = pos.y - 14, w = 28, h = 28 })
        end
    end
    return true
end

-- A loop that never strayed past the pen's tap slop from where it began is a
-- tap. The pen reaches the lasso only as touch, moves and a lift (never as a
-- tap gesture), and with palm rejection on a finger's tap navigates, so this is
-- how the pen pastes and picks a picture, shape or text box out.
function InkAwayView:lassoWasTap()
    local scr = self.lasso_scr
    if not scr then return false end
    local slop = self:penTapSlop()
    for i = 3, #scr - 1, 2 do
        local dx, dy = scr[i] - scr[1], scr[i + 1] - scr[2]
        if dx * dx + dy * dy > slop * slop then return false end
    end
    return true
end

function InkAwayView:lassoRelease(pos)
    if self.lassoing then
        if pos then self.lasso_scr[#self.lasso_scr + 1] = pos.x; self.lasso_scr[#self.lasso_scr + 1] = pos.y end
        if self:lassoWasTap() then
            local scr = self.lasso_scr
            self.lassoing, self.lasso_scr = false, nil
            if #scr > 4 then self:redraw() end   -- the dots its moves left
            return self:lassoTap({ x = scr[1], y = scr[2] })
        end
        self:lassoFinish()
    end
    return true
end

function InkAwayView:lassoTap(pos)
    local scr = self.lasso_scr
    if self.lassoing and scr and #scr >= 6 then self:lassoFinish(); return true end
    self.lassoing, self.lasso_scr = false, nil   -- a tap, not a loop
    if pos and self:selectAt(pos) then return true end
    if pos and Clipboard.count() > 0 then self:openPasteMenu(pos) end
    return true
end

-- Select the picture, shape or text box at screen `pos`, if there is one, and
-- open its menu: a tap or hold with the lasso picks one out as a hold with Pan
-- does (over a book, where there is no Pan, this is how they are picked again).
function InkAwayView:selectAt(pos)
    if not (pos and self:inArea(pos.x, pos.y)) then return false end
    local hit = self:hitTestImage(pos.x, pos.y) or self:hitTestShape(pos.x, pos.y)
        or self:hitTestText(pos.x, pos.y)
    if not (hit and self:selectOps({ hit.idx }, "lasso")) then return false end
    self:redraw()
    self:openSelectionMenu()
    return true
end

-- The lasso loop being drawn.
function InkAwayView:paintLassoLoop(bb, x, y)
    local v = self.view
    local pts = self.lasso_scr
    if not pts then return end
    local BLACKC = self:textInk()   -- black, white on a dark paper
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local function dot(px, py)
        if px >= ax0 and px < ax1 - 3 and py >= ay0 and py < ay1 - 3 then
            bb:paintRect(px, py, 3, 3, BLACKC)
        end
    end
    dot(pts[1], pts[2])
    for i = 3, #pts, 2 do           -- draw each segment as a connected line
        local x0s, y0s = pts[i - 2], pts[i - 1]
        local dxs, dys = pts[i] - x0s, pts[i + 1] - y0s
        local steps = math.max(1, math.floor(math.max(math.abs(dxs), math.abs(dys)) / 3))
        for s = 1, steps do
            dot(math.floor(x0s + dxs * s / steps), math.floor(y0s + dys * s / steps))
        end
    end
end

return InkAwayView
