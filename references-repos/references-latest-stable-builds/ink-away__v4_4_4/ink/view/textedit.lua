--[[
Editing a text box: opening and committing it, the keyboard, caret and typing,
per-box undo, and dragging to move, resize or select.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local InkGeom = require("ink/geom")
local Notebook = require("ink/notebook")
local Paint = require("ink/paint")
local Text = require("ink/text")
local Turn = require("ink/turn")

local Screen = Device.screen
local TILE_BG = Paint.TILE_BG

-- A length in millimetres as screen pixels, so the box's grips are as big under
-- a finger on any reader.
local TEXT_DOUBLE_TAP_MS = 400   -- a second tap this soon on the same spot selects the word

local function mm(v)
    local px = v * 160 / 25.4
    if Screen.scaleByDPI then return math.max(1, math.floor(Screen:scaleByDPI(px) + 0.5)) end
    return Screen:scaleBySize(px)
end

local InkAwayView = {}

------------------------------------------------------------------------------
-- Word-level undo of a committed text box
------------------------------------------------------------------------------

-- Apply one stored word-level step to a committed text box (the op at ops[idx]),
-- without reopening it or bringing up the keyboard. `from` is the stack to pop,
-- `to` the stack that receives the current state (undo and redo swap them). The
-- op is cloned and replaced, so canvas snapshots holding the previous op are
-- never changed. Returns true if a step was applied.
function InkAwayView:commitTextStep(idx, from, to)
    local ops = self.canvas.ops
    local op = ops[idx]
    local h = op and self._text_hist[op]
    if not (h and from and #from > 0) then return false end
    local snap = table.remove(from)
    to[#to + 1] = { paras = Notebook.deepcopy(op.paras), cur = { p = 1, o = 0 } }
    local nop = self.canvas:cloneOp(op)   -- shallow copy; shares nothing we mutate
    nop.paras = snap.paras                -- a fresh, deep-copied paragraph list
    ops[idx] = nop
    self._text_hist[nop] = h              -- carry the history onto the new identity
    self._text_hist[op] = nil
    self._peel_op = nop                   -- we are actively peeling this box
    self:markDirty()
    self:recompose()
    return true
end

-- Is the most recent op a committed text box that still has word-level history to
-- peel back (or, for redo, to replay)? Returns idx, hist or nil.
function InkAwayView:topTextHist()
    local ops = self.canvas.ops
    local idx = #ops
    if self.canvas.layers then
        -- in a layered drawing the newest op can sit under another layer's: the
        -- one placed last, or the box being peeled (a new op at each step)
        local want = { [self.canvas.last_placed or false] = true, [self._peel_op or false] = true }
        idx = nil
        for i = #ops, 1, -1 do
            if want[ops[i]] then idx = i; break end
        end
        if not idx then return nil end
    end
    local top = ops[idx]
    local h = top and top.kind == "text" and self._text_hist[top]
    if h then return idx, h end
end

------------------------------------------------------------------------------
-- Editing a text box. The box being edited is kept off the ops list and drawn as
-- a live overlay, so typing refreshes only the box. On finish it is baked into
-- the master and added to the ops, so it saves, undoes and exports like ink.
------------------------------------------------------------------------------

-- Invalidate the cached layout, after any edit that changes the text, the wrap
-- width, the font or the size.
function InkAwayView:invalidateLayout() self._lay_ver = (self._lay_ver or 0) + 1 end

-- Lay the editing op out at the current zoom (so the overlay is crisp) and grow
-- an auto-height box to fit. Returns the layout, ctx and the width-scaled proxy
-- it was measured against. Cached by op, zoom and an edit version, as one
-- keystroke needs the layout several times.
function InkAwayView:editTextLayout()
    local op = self.editing_text
    local zoom = self.view.zoom
    local ver = self._lay_ver or 0
    local c = self._lay_cache
    if c and c.op == op and c.ver == ver and c.zoom == zoom then
        return c.lay, c.ctx, c.proxy
    end
    local ctx = self:textCtx(op, zoom)
    local proxy = setmetatable({ w = op.w * zoom }, { __index = op })
    local lay = Text.layout(proxy, ctx)
    if op.auto_h then op.h = math.max(1, lay.height / zoom) end
    self._lay_cache = { op = op, ver = ver, zoom = zoom, lay = lay, ctx = ctx, proxy = proxy }
    return lay, ctx, proxy
end

-- The box being edited in its own frame: x along its lines and y down them, in
-- screen px from its top-left corner (op.x, op.y), turned by op.angle (degrees,
-- clockwise) about that corner. These map a point between that frame and the
-- screen. InkGeom.toScreen already includes the area origin.
function InkAwayView:textToScreen(lx, ly)
    local op, v = self.editing_text, self.view
    local ox, oy = InkGeom.toScreen(v, op.x, op.y)
    local a = op.angle or 0
    if a == 0 then return ox + lx, oy + ly end
    local r = math.rad(a)
    local c, s = math.cos(r), math.sin(r)
    return ox + lx * c - ly * s, oy + lx * s + ly * c
end

function InkAwayView:textLocal(sx, sy)
    local op, v = self.editing_text, self.view
    local ox, oy = InkGeom.toScreen(v, op.x, op.y)
    local dx, dy = sx - ox, sy - oy
    local a = op.angle or 0
    if a == 0 then return dx, dy end
    local r = math.rad(a)
    local c, s = math.cos(r), math.sin(r)
    return dx * c + dy * s, -dx * s + dy * c
end

-- The screen box around the box being edited (the box itself while it is not
-- turned).
function InkAwayView:textBoxScreenRect()
    local op, z = self.editing_text, self.view.zoom
    local bw, bh = op.w * z, op.h * z
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs({ { 0, 0 }, { bw, 0 }, { 0, bh }, { bw, bh } }) do
        local x, y = self:textToScreen(p[1], p[2])
        x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
    end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Lay out the two edit buttons, Format and Done, at the top right. This runs on
-- every overlay paint and touch, so the labels are measured once and cached.
function InkAwayView:textEditButtons()
    local v = self.view
    local m = self._text_btn_metrics
    if not m then
        -- the sheets' look: a grey rounded "Format" button and the "Done" pill in
        -- the accent
        local face = Font:getFace("cfont", 15)
        local fw = TextWidget:new{ text = _("Format"), face = face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local dw = TextWidget:new{ text = _("Done"), face = face, bold = true, fgcolor = Accent.get().text }
        local fs, ds = fw:getSize(), dw:getSize()
        local hpad = Screen:scaleBySize(16)
        local h = math.max(Screen:scaleBySize(34), math.max(fs.h, ds.h) + Screen:scaleBySize(12))
        m = { fw = fw, dw = dw, h = h, fwid = fs.w + 2 * hpad,
              dwid = math.max(Screen:scaleBySize(84), ds.w + 2 * hpad),
              radius = Screen:scaleBySize(11), gap = Screen:scaleBySize(8) }
        self._text_btn_metrics = m
    end
    local edge = Screen:scaleBySize(8)
    local y = v.area_y + edge
    local dx = v.area_x + v.area_w - m.dwid - edge
    local fx = dx - m.fwid - m.gap
    return {
        done   = { x = dx, y = y, w = m.dwid, h = m.h, dark = true },
        format = { x = fx, y = y, w = m.fwid, h = m.h },
    }
end

-- The grips around the box being edited, in screen px: each grip's radius as
-- drawn (r) and as a finger finds it (reach), the band around the frame that
-- moves the box when dragged (band), and how far above the box the turning
-- grip stands (stem). Sized in millimetres.
function InkAwayView:textGrips()
    local g = self._text_grips
    if not g then
        g = { r = mm(2.2), reach = mm(4.5), band = mm(3), stem = mm(8) }
        g.pad = g.stem + g.reach   -- how far anything drawn reaches past the frame
        self._text_grips = g
    end
    return g
end

-- Where the grips sit, in the box's own frame (see textLocal): move at the
-- top-left corner and resize at the bottom-right, each just outside the box,
-- and the turning grip on a stem above the middle of its top.
function InkAwayView:textGripSpots()
    local op, z, g = self.editing_text, self.view.zoom, self:textGrips()
    local bw, bh = op.w * z, op.h * z
    local off = math.floor(g.r * 0.7)
    return { move = { x = -off, y = -off }, resize = { x = bw + off, y = bh + off },
        turn = { x = bw / 2, y = -g.stem } }, bw, bh
end

-- The grips on the screen: each spot turned with the box, and kept inside the
-- drawing area so a box running to the page's edge still shows them whole.
function InkAwayView:textGripPoints()
    local g, v = self:textGrips(), self.view
    local out = {}
    for name, p in pairs(self:textGripSpots()) do
        local x, y = self:textToScreen(p.x, p.y)
        x = math.max(v.area_x + g.r + 1, math.min(v.area_x + v.area_w - g.r - 2, x))
        y = math.max(v.area_y + g.r + 1, math.min(v.area_y + v.area_h - g.r - 2, y))
        out[name] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
    end
    return out
end

-- Which part of the box a screen point falls on: "inside", "turn", "resize" or
-- "move" (its grips), "frame" (the band around it, which moves it when dragged)
-- or "outside". The inside wins over a grip, so the caret can reach every letter.
function InkAwayView:textZone(sx, sy)
    local lx, ly = self:textLocal(sx, sy)
    local _spots, bw, bh = self:textGripSpots()
    if lx >= 0 and lx <= bw and ly >= 0 and ly <= bh then return "inside" end
    local g = self:textGrips()
    local pts = self:textGripPoints()
    local function near(p)
        local dx, dy = sx - p.x, sy - p.y
        return dx * dx + dy * dy <= g.reach * g.reach
    end
    if near(pts.turn) then return "turn" end
    if near(pts.resize) then return "resize" end
    if near(pts.move) then return "move" end
    if lx >= -g.band and lx <= bw + g.band and ly >= -g.band and ly <= bh + g.band then return "frame" end
    return "outside"
end

-- The screen box the editing overlay draws in: the box with its frame and grips.
function InkAwayView:textOverlayRect()
    local r, g = self:textBoxScreenRect(), self:textGrips()
    local p = g.pad
    local x0, y0, x1, y1 = r.x - p, r.y - p, r.x + r.w + p, r.y + r.h + p
    for _, q in pairs(self:textGripPoints()) do
        x0, y0 = math.min(x0, q.x - g.r - 2), math.min(y0, q.y - g.r - 2)
        x1, y1 = math.max(x1, q.x + g.r + 2), math.max(y1, q.y + g.r + 2)
    end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Refresh just the box's rectangle, with a margin for the frame and grips.
function InkAwayView:refreshTextBox(mode)
    self:hideClipBubble()   -- any change to the box (typing, caret, selection) dismisses it
    local r = self:textOverlayRect()
    self:refreshRectUnion(r, r, 2, mode or "ui")
end

-- Every few edits, clear the fast-refresh ghosting the box leaves behind.
function InkAwayView:afterTextEdit()
    self:invalidateLayout()   -- the text just changed
    self:ensureCaretVisible()
    self._text_edits = (self._text_edits or 0) + 1
    if self._text_edits >= 24 then
        self._text_edits = 0
        self:refreshTextBox("flashui")
    else
        self:refreshTextBox("ui")
    end
end

-- Screen y of the top of the on-screen keyboard (or the screen bottom if none).
function InkAwayView:keyboardTop()
    local kb = self._text_kb
    if kb and kb.dimen and kb.dimen.h then return self.screen_h - kb.dimen.h end
    return self.screen_h
end

-- Scroll the page vertically so the caret line sits between the toolbar and the
-- keyboard.
function InkAwayView:ensureCaretVisible()
    if not self.editing_text then return end
    local v = self.view
    local lay, ctx = self:editTextLayout()
    local op = self.editing_text
    local c = Text.caret(op, lay, self.text_cur, ctx)   -- op-local, scale=zoom
    -- the caret's ends on the page (canvas coords), however the box is turned
    local _x1, y1 = Text.toPage(op, c.x / v.zoom, c.y / v.zoom)
    local _x2, y2 = Text.toPage(op, c.x / v.zoom, (c.y + c.h) / v.zoom)
    local caret_top, caret_bot = math.min(y1, y2), math.max(y1, y2)
    local margin = 12
    local top_lim = v.area_y + margin
    local bot_lim = self:keyboardTop() - margin
    local top_scr = v.area_y + (caret_top - v.pan_y) * v.zoom
    local bot_scr = v.area_y + (caret_bot - v.pan_y) * v.zoom
    local new_pan = v.pan_y
    if bot_scr > bot_lim then
        new_pan = caret_bot - (bot_lim - v.area_y) / v.zoom
    elseif top_scr < top_lim then
        new_pan = caret_top - (top_lim - v.area_y) / v.zoom
    end
    new_pan = math.max(0, math.min(math.max(0, v.canvas_h - 1), new_pan))
    if math.abs(new_pan - v.pan_y) >= 1 then
        v.pan_y = new_pan
        self:renderView()
        UIManager:setDirty(self, "ui")
    end
end

-- Default size and width for a new box on this page.
function InkAwayView:newTextAt(pos)
    local v = self.view
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- span the full page (the grid runs edge to edge) with only a small margin
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local op = Text.new{ x = margin, y = cy, w = v.canvas_w - 2 * margin, size = size,
        font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
    -- snap the box origin to the ruling when grid alignment is on
    if self.text_grid_snap then self:snapTextBoxToGrid(op) end
    self._text_tap_at = { op = op, x = cx, y = cy }   -- where a turn on end starts it
    self:startTextEdit(op, { p = 1, o = 0 }, true, nil)
end

-- Build the on-screen keyboard and point it at this view's text methods.
function InkAwayView:showTextKeyboard()
    if self._text_kb then return end
    self:lendKeys()   -- (see ink/view/keys.lua)
    -- With the keyboard on top, UIManager only delivers gestures to lower
    -- widgets that are is_always_active; this keeps the toolbar and canvas alive
    -- while typing. It is turned off again when editing ends.
    self.is_always_active = true
    -- a physical keyboard types instead, as in KOReader's own text fields
    if self:physicalKeyboard() then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local view = self
    local inputbox = {
        parent = self,
        addChars = function(_, s) view:textAddChars(s) end,
        delChar = function() view:textDelChar() end,
        delWord = function() view:textDelChar() end,
        delToStartOfLine = function() view:textDelToBOL() end,
        leftChar = function() view:textMove(-1, 0) end,
        rightChar = function() view:textMove(1, 0) end,
        upLine = function() view:textMove(0, -1) end,
        downLine = function() view:textMove(0, 1) end,
        goToStartOfLine = function() view:textHome() end,
        goToEndOfLine = function() view:textEnd() end,
        scrollUp = function() end,
        scrollDown = function() end,
    }
    local kb = VirtualKeyboard:new{ keyboard_layer = 2, inputbox = inputbox }
    -- the keyboard closes itself on Back (Esc on a keyboard): forget it then,
    -- so the box knows it is gone and a physical keyboard types on
    local closed = kb.onCloseWidget
    kb.onCloseWidget = function(w, ...)
        if view._text_kb == w then view._text_kb = nil end
        if closed then return closed(w, ...) end
    end
    self._text_kb = kb
    UIManager:show(kb)
end

function InkAwayView:hideTextKeyboard()
    self.is_always_active = false
    self:returnKeys()
    self._left_ctrl = nil
    if self._text_kb then
        UIManager:close(self._text_kb)
        self._text_kb = nil
    end
end

-- Enter edit mode on `op`. For an existing op we edit a deep copy and hide the
-- original, so an Undo after editing restores the text as it was.
function InkAwayView:startTextEdit(op, cur, is_new, idx, hit_pos)
    self:flushPending(); self:flushShape()
    if self.selection or self.lassoing then self:clearSelection() end
    if is_new then
        self.editing_text = op
    else
        self._text_orig = self.canvas.ops[idx]
        -- copy before hiding the original, so the copy is not marked hidden
        self.editing_text = Notebook.deepcopy(op)
        self.editing_text.hidden = nil
        self._text_orig.hidden = true
        self:composeCanvas()
    end
    self.editing_idx = idx
    self.editing_is_new = is_new
    self.text_cur = cur or { p = 1, o = 0 }
    self.text_sel = nil
    self._text_edits = 0
    self._text_undo, self._text_redo, self._text_coalesce = {}, {}, nil
    -- Opened by a touch: wait for the finger to lift before showing the keyboard,
    -- or a box low on the page brings the keyboard up under the finger and the
    -- lift types whatever key is there.
    if self._kb_defer then self._kb_pending = true else self:showTextKeyboard() end
    -- Place the caret at the tapped point before the scroll-into-view pass, so
    -- opening a box does not pan (the tap is above the keyboard). pan_y is not
    -- restored afterwards, so closing the keyboard does not jump either.
    if hit_pos then
        local lay = self:editTextLayout()
        local lx, ly = self:textLocal(hit_pos.x, hit_pos.y)
        self.text_cur = Text.hit(self.editing_text, lay, lx, ly,
            self:textCtx(self.editing_text, self.view.zoom))
    end
    self:ensureCaretVisible()           -- only pans if the caret is actually hidden
    self:renderView()
    self:refresh(self, "full")
end

-- Leave edit mode, baking the box in (commit) or dropping the edit (cancel).
function InkAwayView:finishTextEdit(commit)
    if not self.editing_text then return end
    self._kb_pending = nil
    self:hideClipBubble()
    if commit == nil then commit = true end
    local op = self.editing_text
    local committed_op   -- the op that ended up on the ops list (for undo history)
    if self.editing_is_new then
        if commit and not Text.isEmpty(op) then
            self:layerReady()
            self.canvas:pushHistory()
            self.canvas:placeOp(op)
            committed_op = op
        end
    else
        local orig = self._text_orig
        orig.hidden = nil
        if commit then
            if Text.isEmpty(op) then
                self.canvas:pushHistory()
                table.remove(self.canvas.ops, self.editing_idx)   -- emptied: delete it
            else
                op.hidden = nil   -- make sure the committed box is drawn
                self.canvas:pushHistory()
                self.canvas.ops[self.editing_idx] = op
                committed_op = op
            end
        end
    end
    -- keep this box's word-level history, so a later Undo takes it back a word
    -- at a time (see undo) rather than removing the whole box
    if committed_op and self._text_undo and #self._text_undo > 0 then
        self._text_hist[committed_op] = { undo = self._text_undo, redo = self._text_redo or {} }
    end
    self._peel_op = nil
    self._text_tap_at = nil
    self.editing_text, self._text_orig = nil, nil
    self.editing_idx, self.editing_is_new = nil, nil
    self.text_cur, self.text_sel = nil, nil
    self._text_pending_style = nil
    self._lay_cache = nil
    self:closeSheet("_text_fmt")
    self:markDirty()
    self:hideTextKeyboard()
    -- typing may have scrolled past the page end to keep the line above the
    -- keyboard (see ensureCaretVisible); bring the view back inside the page
    InkGeom.clampPan(self.view)
    self:composeCanvas()
    self:renderView()
    self:refresh("all", "full")
end

------------------------------------------------------------------------------
-- Undo inside the box being edited, without recomposing the page per keystroke.
-- Steps coalesce: a run of typed letters is one word, a run of deletions is one
-- step, and each format change is its own. A space or newline, a caret move or a
-- different kind of edit starts a new step.
------------------------------------------------------------------------------

function InkAwayView:pushTextHistory()
    if not self.editing_text then return end
    self._text_undo = self._text_undo or {}
    self._text_undo[#self._text_undo + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    if #self._text_undo > 80 then table.remove(self._text_undo, 1) end
    self._text_redo = {}
end

-- Call before a mutating edit. Pushes a snapshot only when a new undo step
-- should begin, so typing a word is a single step.
function InkAwayView:textMark(kind)
    if self._text_coalesce ~= kind then self:pushTextHistory() end
    self._text_coalesce = kind
end

function InkAwayView:textBreakCoalesce() self._text_coalesce = nil end

function InkAwayView:textRestore(stack, other)
    if not (self.editing_text and stack and #stack > 0) then return end
    other[#other + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    local snap = table.remove(stack)
    self.editing_text.paras = snap.paras
    local np = #self.editing_text.paras
    local cp = math.max(1, math.min(np, snap.cur.p))
    self.text_cur = { p = cp, o = math.min(snap.cur.o, Text.paraLen(self.editing_text.paras[cp])) }
    self.text_sel = nil
    self._text_coalesce = nil
    self:invalidateLayout()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textUndo() self:textRestore(self._text_undo, self._text_redo) end
function InkAwayView:textRedo() self:textRestore(self._text_redo, self._text_undo) end

------------------------------------------------------------------------------
-- Typing (driven by the keyboard)
------------------------------------------------------------------------------

function InkAwayView:textDeleteSelIfAny()
    if self.text_sel and not Text.selEmpty(self.text_sel) then
        self.text_cur = Text.deleteRange(self.editing_text, self.text_sel)
        self.text_sel = nil
        return true
    end
    self.text_sel = nil
    return false
end

function InkAwayView:textAddChars(s)
    if not self.editing_text then return end
    -- a space or newline ends the word, so the next one is its own step
    self:textMark("type")
    if s == " " or s == "\n" then self._text_coalesce = nil end
    self:textDeleteSelIfAny()
    local style = self._text_pending_style or nil
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, style)
    self._text_pending_style = nil
    self:afterTextEdit()
end

function InkAwayView:textDelChar()
    if not self.editing_text then return end
    self:textMark("delete")
    if not self:textDeleteSelIfAny() then
        self.text_cur = Text.deleteBack(self.editing_text, self.text_cur)
    end
    self:afterTextEdit()
end

function InkAwayView:textDelToBOL()
    if not self.editing_text then return end
    self:textMark("delete")
    self.text_cur = Text.deleteRange(self.editing_text,
        { a = { p = self.text_cur.p, o = 0 }, b = self.text_cur })
    self.text_sel = nil
    self:afterTextEdit()
end

-- Move the caret: dx by one character, dy by one line (-1 or +1).
function InkAwayView:textMove(dx, dy)
    if not self.editing_text then return end
    local op, cur = self.editing_text, self.text_cur
    self.text_sel = nil
    if dx ~= 0 then
        local o = cur.o + dx
        if o < 0 then
            if cur.p > 1 then cur = { p = cur.p - 1, o = Text.paraLen(op.paras[cur.p - 1]) } end
        elseif o > Text.paraLen(op.paras[cur.p]) then
            if cur.p < #op.paras then cur = { p = cur.p + 1, o = 0 } end
        else
            cur = { p = cur.p, o = o }
        end
    end
    if dy ~= 0 then
        local lay = self:editTextLayout()
        local c = Text.caret(op, lay, cur, self:textCtx(op, self.view.zoom))
        local ny = c.y + (dy > 0 and c.h * 1.5 or -c.h * 0.5)
        cur = Text.hit(op, lay, c.x, ny, self:textCtx(op, self.view.zoom))
    end
    self.text_cur = cur
    self:textBreakCoalesce()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textHome()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = 0 }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

function InkAwayView:textEnd()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = Text.paraLen(self.editing_text.paras[self.text_cur.p]) }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

------------------------------------------------------------------------------
-- Touch handling for the text tool
------------------------------------------------------------------------------

-- Find a committed text op under a canvas point (topmost first), turned or not.
function InkAwayView:textOpAt(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "text" and self:editableOp(op) and op.h and Text.contains(op, cx, cy) then
            return op, i
        end
    end
end

-- The text box at screen (sx, sy) as { op, idx }, for picking it out as a
-- picture or a shape is (a hold, or the lasso's tap), or nil.
function InkAwayView:hitTestText(sx, sy)
    local cx, cy = self:toCanvasClamped(sx, sy)
    local op, idx = self:textOpAt(cx, cy)
    if op then return { op = op, idx = idx } end
end

-- Does a gesture land on the on-screen keyboard? The view is is_always_active
-- while editing, so a key tap the keyboard does not swallow would otherwise reach
-- the canvas and create or commit a box.
function InkAwayView:inKeyboard(pos)
    return self._text_kb ~= nil and pos ~= nil and pos.y >= self:keyboardTop()
end

function InkAwayView:textToolTouch(pos)
    if self:inKeyboard(pos) then return true end
    if self.editing_text then
        local btns = self:textEditButtons()
        if InkGeom.inRect(pos.x, pos.y, btns.done) then self:finishTextEdit(true); return true end
        if InkGeom.inRect(pos.x, pos.y, btns.format) then
            -- open on release, so the same tap cannot close the new menu as a
            -- tap outside it
            self._text_drag = { kind = "format" }
            return true
        end
        local zone = self:textZone(pos.x, pos.y)
        if zone == "resize" then
            self._text_drag = { kind = "resize", sx = pos.x, sy = pos.y,
                w0 = self.editing_text.w, h0 = self.editing_text.h }
            return true
        elseif zone == "move" or zone == "frame" then
            -- the band around the frame moves the box too, but a tap there
            -- closes it like a tap away (see textToolRelease)
            self._text_drag = { kind = "move", sx = pos.x, sy = pos.y, frame = zone == "frame",
                x0 = self.editing_text.x, y0 = self.editing_text.y }
            return true
        elseif zone == "turn" then
            -- turned about the box's middle, by how far the finger goes round it
            local cx, cy = Text.centre(self.editing_text)
            local sx, sy = InkGeom.toScreen(self.view, cx, cy)
            self._text_drag = { kind = "turn", sx = pos.x, sy = pos.y, cx = sx, cy = sy,
                grab = math.atan2(pos.y - sy, pos.x - sx), a0 = self.editing_text.angle or 0 }
            return true
        elseif zone == "inside" then
            local lay = self:editTextLayout()
            local lx, ly = self:textLocal(pos.x, pos.y)
            -- a checklist's box ticks or unticks its item
            local pi = Text.checkAt(lay, lx, ly)
            if pi then
                self:pushTextHistory(); self:textBreakCoalesce()
                local p = self.editing_text.paras[pi]
                p.checked = (not p.checked) or nil
                self:invalidateLayout()
                self:refreshTextBox("ui")
                self._text_drag = { kind = "tick" }
                return true
            end
            -- place the caret; a following pan turns it into a selection
            local cur = Text.hit(self.editing_text, lay, lx, ly,
                self:textCtx(self.editing_text, self.view.zoom))
            -- a second tap on the same spot soon after selects the word there
            local now, last = self:nowMs(), self._text_last_tap
            local again = last and now - last.t <= TEXT_DOUBLE_TAP_MS
                and math.abs(pos.x - last.x) + math.abs(pos.y - last.y) <= mm(3)
            self._text_last_tap = not again and { t = now, x = pos.x, y = pos.y } or nil
            self.text_cur = cur
            self.text_sel = nil
            self._text_drag = { kind = "select", anchor = cur }
            if again then
                local w = self:wordSelAtCursor()
                if w then
                    self.text_sel = w
                    self.text_cur = w.b
                    self._text_drag.word = true   -- (the release does not open Format)
                end
            end
            self:textBreakCoalesce()   -- typing at a new spot is a new undo step
            self:refreshTextBox("ui")
            return true
        else
            self:finishTextEdit(true)   -- tapped away: commit and leave
            -- a finger that palm rejection keeps from writing only closes the box
            if self:navFinger(pos) then return true end
            -- a tap on another box opens it; anywhere else it only closes this
            -- one, so the keyboard does not come straight back
            local cx, cy = self:toCanvasClamped(pos.x, pos.y)
            if not self:textOpAt(cx, cy) then return true end
        end
    end
    -- not editing (or just finished): tick a checklist's box, edit an existing
    -- box, or start a new one
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    local op, idx = self:textOpAt(cx, cy)
    if op and self:tickCheckAt(op, idx, cx, cy) then return true end
    self._kb_defer = true   -- the keyboard appears when this finger lifts
    if op then
        -- pass the tap so the caret lands there before the first scroll pass
        self:startTextEdit(op, { p = 1, o = 0 }, false, idx, pos)
        self._text_last_tap = { t = self:nowMs(), x = pos.x, y = pos.y }   -- (a second selects the word)
    else
        self:newTextAt(pos)
    end
    self._kb_defer = nil
    return true
end

-- Show the keyboard a box was opened with, now that the opening finger has lifted,
-- and scroll the caret clear of it.
function InkAwayView:showPendingKeyboard()
    if not self._kb_pending then return end
    self._kb_pending = nil
    if self.editing_text then
        self:showTextKeyboard()
        self:ensureCaretVisible()
    end
end

function InkAwayView:textToolPan(pos)
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    if not d then return true end
    if d.kind == "move" or d.kind == "resize" or d.kind == "turn" then
        if not d.moved then
            -- a finger's wobble is not a drag yet (a tap on the band closes the box)
            if math.abs(pos.x - d.sx) + math.abs(pos.y - d.sy) < mm(1.5) then return true end
            d.moved = true
        else
            -- each refresh covers the whole box: on colour e-ink the next waits
            -- for the panel, so the moves made meanwhile go out as one
            self:waitForPanel()
        end
    end
    if d.kind == "move" then
        local dx = (pos.x - d.sx) / self.view.zoom
        local dy = (pos.y - d.sy) / self.view.zoom
        local old = self:textOverlayRect()
        self.editing_text.x = d.x0 + dx
        self.editing_text.y = d.y0 + dy
        -- refresh the union of the old and new positions so no ghost is left
        self:refreshRectUnion(old, self:textOverlayRect(), 2, "fast", true)
    elseif d.kind == "turn" then
        local old = self:textOverlayRect()
        local a = d.a0 + math.deg(math.atan2(pos.y - d.cy, pos.x - d.cx) - d.grab)
        local q = math.floor(a / 90 + 0.5) * 90
        if math.abs(a - q) < 4 then a = q end   -- quarter turns snap
        Text.turnTo(self.editing_text, a)
        self:refreshRectUnion(old, self:textOverlayRect(), 2, "fast", true)
    elseif d.kind == "resize" then
        -- the drag along the box's lines, however it is turned
        local c, s = Text.turn(self.editing_text)
        local dw = ((pos.x - d.sx) * c + (pos.y - d.sy) * s) / self.view.zoom
        local old = self:textOverlayRect()
        -- only the width is dragged; the height follows the re-wrapped text, so
        -- the text never overflows the box
        self.editing_text.w = math.max(40, d.w0 + dw)
        self:invalidateLayout()   -- width changed: re-wrap (and grow the height)
        self:editTextLayout()     -- recompute now so op.h reflects the new wrap
        -- refresh the union of the old and new box, so a shrink leaves no ghost
        self:refreshRectUnion(old, self:textOverlayRect(), 2, "fast", true)
    elseif d.kind == "select" then
        local lay = self:editTextLayout()
        local lx, ly = self:textLocal(pos.x, pos.y)
        local cur = Text.hit(self.editing_text, lay, lx, ly,
            self:textCtx(self.editing_text, self.view.zoom))
        -- act only when the caret lands somewhere new: a pen held still sends
        -- frames with a pixel of jitter, and each refresh would also dismiss the
        -- paste bubble
        local last = d.last or d.anchor
        if cur.p == last.p and cur.o == last.o then return true end
        d.last = cur
        self.text_cur = cur
        self.text_sel = { a = d.anchor, b = cur }
        self:refreshTextBox("ui")
    end
    return true
end

function InkAwayView:textToolRelease(pos)
    self:showPendingKeyboard()   -- the finger that opened the box has lifted
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    self._text_drag = nil
    if not d then return true end
    if d.kind == "format" then
        -- open the format menu on release, so the same tap cannot close it again
        -- as a tap outside
        self:openTextFormatMenu()
    elseif d.kind == "move" and d.frame and not d.moved then
        -- a tap on the band around the frame: as a tap away, it closes the box
        self:finishTextEdit(true)
    elseif d.kind == "turn" then
        self:invalidateLayout()
        self:refreshTextBox(d.moved and "flashui" or "ui")
    elseif d.kind == "move" or d.kind == "resize" then
        -- re-align to the ruling once the drag ends (grid-snap boxes only), with a
        -- flashing refresh to clear what the fast waveform left
        if d.kind == "move" and self.editing_text and self.editing_text.grid_snap then
            self:snapTextBoxToGrid(self.editing_text)
            self:invalidateLayout()
            self:refreshTextBox("flashui")
        else
            self:refreshTextBox("ui")
        end
    elseif d.kind == "select" then
        if self.text_sel and Text.selEmpty(self.text_sel) then
            self.text_sel = nil
        elseif self:textHasSel() and not (d.word and not d.last) then
            -- a dragged selection: offer the format menu (a word picked by a
            -- double tap keeps the keyboard, to type over it)
            self:openTextFormatMenu()
        end
    end
    return true
end

-- A tap at canvas (cx, cy) on a saved box `op` (ops[idx]): on a checklist's box
-- it ticks or unticks the item, as one undo step, without opening the box.
-- Returns whether it did.
function InkAwayView:tickCheckAt(op, idx, cx, cy)
    local has
    for _, p in ipairs(op.paras or {}) do if p.bullet == "check" then has = true; break end end
    if not has then return false end
    local lay = self:layoutText(op, 1)
    local lx, ly = Text.toLocal(op, cx, cy)
    local pi = Text.checkAt(lay, lx, ly)
    if not pi then return false end
    self:editOp(idx, op, function(c)
        c.paras = Notebook.deepcopy(op.paras)
        c.paras[pi].checked = (not c.paras[pi].checked) or nil
    end)
    self:recompose()
    return true
end

------------------------------------------------------------------------------
-- Painting the box being edited
------------------------------------------------------------------------------

-- A filled disc of radius r centred on (x, y), as rows.
local function disc(bb, x, y, r, c)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    for dy = -r, r do
        local half = math.floor(math.sqrt(r * r - dy * dy))
        bb:paintRect(x - half, y + dy, 2 * half + 1, 1, c)
    end
end

-- A line of squares t px wide from (x0, y0) to (x1, y1).
local function stroke(bb, x0, y0, x1, y1, t, c)
    local n = math.max(1, math.floor(math.max(math.abs(x1 - x0), math.abs(y1 - y0))))
    local h = math.floor(t / 2)
    for i = 0, n do
        bb:paintRect(math.floor(x0 + (x1 - x0) * i / n + 0.5) - h, math.floor(y0 + (y1 - y0) * i / n + 0.5) - h, t, t, c)
    end
end

-- The grips, drawn on the screen bitmap bb whose origin is at (x, y): a disc in
-- the ink with a mark in the paper's colour, a cross to move, a double arrow
-- along the lines to resize, and a ring on a stem to turn.
function InkAwayView:paintTextGrips(bb, x, y, ink, mark)
    local g = self:textGrips()
    local pts = self:textGripPoints()
    local t = math.max(2, math.floor(g.r / 5))
    local a = math.floor(g.r * 0.55)
    local m = pts.move
    local mx, my = m.x + x, m.y + y
    disc(bb, mx, my, g.r, ink)
    bb:paintRect(mx - a, my - math.floor(t / 2), 2 * a + 1, t, mark)
    bb:paintRect(mx - math.floor(t / 2), my - a, t, 2 * a + 1, mark)
    local rz = pts.resize
    local rx, ry = rz.x + x, rz.y + y
    disc(bb, rx, ry, g.r, ink)
    -- the turning grip: a ring on a stem from the middle of the box's top
    local tx0, ty0 = self:textToScreen(self:textGripSpots().turn.x, 0)
    local tn = pts.turn
    stroke(bb, tx0 + x, ty0 + y, tn.x + x, tn.y + y, math.max(2, math.floor(t * 0.75)), ink)
    disc(bb, tn.x + x, tn.y + y, g.r, ink)
    disc(bb, tn.x + x, tn.y + y, math.floor(g.r * 0.5), mark)
    -- the arrow lies along the box's lines, turned with it
    local r = math.rad(self.editing_text.angle or 0)
    local c, s = math.cos(r), math.sin(r)
    local function at(u, w) return rx + u * c - w * s, ry + u * s + w * c end
    local ax0, ay0 = at(-a, 0)
    local ax1, ay1 = at(a, 0)
    stroke(bb, ax0, ay0, ax1, ay1, t, mark)
    local hd = math.floor(a / 2)
    for _, e in ipairs({ { -a, 1 }, { a, -1 } }) do   -- the arrowheads
        local tx, ty = at(e[1], 0)
        for _, w in ipairs({ -hd, hd }) do
            local hx, hy = at(e[1] + e[2] * hd, w)
            stroke(bb, tx, ty, hx, hy, t, mark)
        end
    end
end

function InkAwayView:paintTextOverlay(bb, x, y)
    local op = self.editing_text
    local lay, ctx = self:editTextLayout()
    local z = self.view.zoom
    local bw, bh = op.w * z, op.h * z
    local BLACKC = self:textInk()        -- black, white on a dark paper
    local on_dark = BLACKC == Blitbuffer.COLOR_WHITE
    local paints = self:textPaints(BLACKC, self:colorScreen(), self:paperRGB())
    -- the box upright, its top-left at (ox, oy) in dst
    local function body(dst, ox, oy)
        -- selection highlight (behind the glyphs)
        if self.text_sel and not Text.selEmpty(self.text_sel) then
            local a, b = Text.orderSel(self.text_sel)
            for _, ln in ipairs(lay.lines) do
                local lo = (ln.para > a.p or (ln.para == a.p and ln.o_end >= a.o)) and true or false
                local hi = (ln.para < b.p or (ln.para == b.p and ln.o_start <= b.o)) and true or false
                if lo and hi and ln.para >= a.p and ln.para <= b.p then
                    local xa = (ln.para == a.p) and math.max(ln.text_x, Text.caretX(ln, a.o, ctx)) or ln.text_x
                    local xb = (ln.para == b.p) and Text.caretX(ln, b.o, ctx) or (ln.text_x + Text.lineContentWidth(ln))
                    if xb > xa then
                        dst:paintRect(math.floor(ox + xa), math.floor(oy + ln.top),
                            math.ceil(xb - xa), math.ceil(ln.height),
                            on_dark and Blitbuffer.Color8(0x55) or Blitbuffer.COLOR_LIGHT_GRAY)
                    end
                end
            end
        end
        -- the glyphs
        Text.render(op, lay, dst, ox, oy, ctx, paints)
        -- the frame
        Paint.outline(dst, math.floor(ox), math.floor(oy), math.ceil(bw), math.ceil(bh), BLACKC)
        -- caret
        if not (self.text_sel and not Text.selEmpty(self.text_sel)) then
            local c = Text.caret(op, lay, self.text_cur, ctx)
            dst:paintRect(math.floor(ox + c.x), math.floor(oy + c.y), 2, math.ceil(c.h), BLACKC)
        end
    end
    local sx, sy = self:textToScreen(0, 0)
    if Text.turned(op) then
        -- drawn upright, then put on the screen turned (see ink/turn.lua)
        local c, s = Text.turn(op)
        Turn.paint(bb, sx + x, sy + y, c, s, bw, bh, math.ceil(self:textOverhang(op) * z) + 3, body)
    else
        body(bb, sx + x, sy + y)
    end
    -- the grips, upright on the screen
    self:paintTextGrips(bb, x, y, BLACKC, on_dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
    -- the always-visible Format and Done buttons (above the keyboard): rounded,
    -- Color8 fills so the corners are drawn in C (a colour accent is a cached
    -- image), and labels cached in the metrics
    local btns = self:textEditButtons()
    local m = self._text_btn_metrics
    local function drawBtn(rr, label)
        local bx, by = rr.x + x, rr.y + y
        if rr.dark then Accent.paintRounded(bb, bx, by, rr.w, rr.h, m.radius)
        else bb:paintRoundedRect(bx, by, rr.w, rr.h, TILE_BG, m.radius) end
        local sz = label:getSize()
        label:paintTo(bb, math.floor(bx + (rr.w - sz.w) / 2), math.floor(by + (rr.h - sz.h) / 2))
    end
    drawBtn(btns.format, m.fw)
    drawBtn(btns.done, m.dw)
end

return InkAwayView
