--[[
Handwriting to text: lasso some printed writing, then "Convert to text" in the
selection's menu. The strokes are split into lines, words and characters
(ink/hwr.lua), each character read by the small network in ink/hwrnet.lua,
each word checked against the English word list (ink/hwrwords.lua), and the
writing replaced by one text box in the current text style, in one undo step.
Everything runs on the reader, unless Convert to text online is switched on in
the Text sheet (ink/view/ocrapi.lua).
Part of InkAwayView (see ink/view.lua).
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink/l10n")
local Hwr = require("ink/hwr")
local Cut = require("ink/cut")
local Canvas = require("ink/canvas")
local Symmetry = require("ink/symmetry")
local Text = require("ink/text")

local InkAwayView = {}

-- The model and the word list, loaded on first use and kept until Ink Away
-- closes (see freeHandwriting). Returns net, words, or nil and a message.
function InkAwayView:hwrModels()
    if self._hwr_net and self._hwr_words then return self._hwr_net, self._hwr_words end
    local dir = self:pluginDir() .. "ink/data/"
    local HwrNet = require("ink/hwrnet")
    local net, err = HwrNet.load(dir .. "hwr_en.bin")
    if not net then
        logger.warn("InkAway: handwriting model:", err)
        return nil, _("The handwriting model could not be loaded.")
    end
    local Words = require("ink/hwrwords")
    local words, werr = Words.load(dir .. "hwr_words_en.txt", net.classes)
    if not words then
        logger.warn("InkAway: word list:", werr)
        return nil, _("The word list could not be loaded.")
    end
    self._hwr_net, self._hwr_words = net, words
    return net, words
end

function InkAwayView:freeHandwriting()
    self._hwr_net, self._hwr_words = nil, nil
end

-- The strokes of the ops at `idxs` that can be read as writing: pen ink, and the
-- lines a hold to straighten may have made of single strokes. Returns the strokes (flat
-- point lists, in writing order) and their ops.
function InkAwayView:writingOf(idxs)
    local c, selected, ops, working = self.canvas, {}, {}, {}
    local function isWriting(op)
        return op.pts and #op.pts >= 2
            and (op.kind == "ink" or (op.kind == "shape" and op.shape == "line"))
    end
    local function hidden(op)
        return op.hidden or (c.layers and c.hidden_layers and c.hidden_layers[op.layer or 1])
    end
    local sorted = {}
    for i, idx in ipairs(idxs) do sorted[i] = idx end
    table.sort(sorted)
    for _, idx in ipairs(sorted) do
        local op = c.ops[idx]
        if op and isWriting(op) and not hidden(op) and not selected[op] then
            selected[op] = true
            ops[#ops + 1] = op
        end
    end
    for _, op in ipairs(c.ops) do
        if not hidden(op) then
            if op.kind == "erase" and op.pts and #op.pts >= 2 then
                for _, flip in ipairs(Symmetry.flips(op.sym)) do
                    working = Cut.ops(working, Symmetry.flipPoints(op.pts, flip,
                        self.view.canvas_w, self.view.canvas_h), (op.width or 1) / 2, {
                        only = function(target)
                            return target._hwr_source and selected[target._hwr_source]
                                and isWriting(target._hwr_source)
                                and (not c.layers or (target.layer or 1) == (op.layer or 1))
                        end,
                    })
                end
            elseif selected[op] and isWriting(op) then
                local copy = Canvas.cloneOp(nil, op)
                copy._hwr_source = op
                working[#working + 1] = copy
            end
        end
    end
    local strokes = {}
    for _, op in ipairs(working) do
        if selected[op._hwr_source] and isWriting(op) then strokes[#strokes + 1] = op.pts end
    end
    return strokes, ops
end

-- Does the selection hold anything that could be writing?
function InkAwayView:selectionHasWriting()
    if not self.selection then return false end
    local strokes = self:writingOf(self.selection.idxs)
    return #strokes > 0
end

-- Read `strokes` (flat point lists in writing order). Returns the text: words
-- joined by spaces, lines by new lines.
function InkAwayView:readWriting(strokes, net, words)
    return Hwr.read(strokes, net, words)
end

-- Convert the selected writing to text. Shows a message when there is none, or
-- when something fails, rather than letting an error reach KOReader.
function InkAwayView:convertSelectionToText()
    local ok, err = xpcall(function() self:convertSelectionToTextNow() end, debug.traceback)
    if not ok then
        self:cancelOcrApi()
        logger.warn("InkAway: converting handwriting failed:", err)
        self:tell(_("Something went wrong reading the writing."))
    end
end

function InkAwayView:convertSelectionToTextNow()
    if not self.selection then return end
    local strokes, ops = self:writingOf(self.selection.idxs)
    if #strokes == 0 then
        self:showNotice(_("There is no handwriting in the selection."), 2)
        return
    end
    if self:ocrApiConfig().enabled then return self:convertSelectionWithApi(strokes, ops) end
    local net, words = self:hwrModels()
    if not net then
        self:tell(words)
        return
    end
    -- a few lines take a second or two on a reader: say so first
    local closeNote
    if #strokes > 12 then
        closeNote = self:tell(_("Reading the writing\u{2026}"), { wait = true })
        if UIManager.forceRePaint then UIManager:forceRePaint() end
    end
    local ok, text = pcall(self.readWriting, self, strokes, net, words)
    if closeNote then closeNote() end
    if not ok then
        logger.warn("InkAway: reading handwriting failed:", text)
        self:tell(_("Something went wrong reading the writing."))
        return
    end
    if text:gsub("%s", "") == "" then
        self:showNotice(_("No writing could be read there."), 2)
        return
    end
    self:reviewWriting(text, strokes, ops, self:hwrContext())
end

function InkAwayView:reviewWriting(text, strokes, ops, context)
    if not self:hwrContextCurrent(context) or not self:hwrSelectionCurrent(ops) then return end
    local x0, y0 = math.huge, math.huge
    for _, pts in ipairs(strokes) do
        for i = 1, #pts - 1, 2 do
            if pts[i] < x0 then x0 = pts[i] end
            if pts[i + 1] < y0 then y0 = pts[i + 1] end
        end
    end
    -- what was read, to check and fix before it replaces the writing; Cancel
    -- keeps the writing as it is
    self:promptText{ field = "_hwr_review", title = _("Convert to text"), input = text, lines = 4,
        description = _("Fix anything misread, then convert."), ok_text = _("Convert"),
        on_ok = function(edited)
            if not self:hwrContextCurrent(context) then
                self:showNotice(_("The page changed. Please read the writing again."), 2)
            elseif not self:hwrSelectionCurrent(ops) then
                self:showNotice(_("The selection changed. Please read the writing again."), 2)
            elseif (edited or ""):gsub("%s", "") == "" then
                self:showNotice(_("No writing could be read there."), 2)
            else
                self:resetLasso()
                self:replaceWithText(edited, ops, x0, y0)
            end
        end }
end

-- Replace the ops `ink_ops` with one text box holding `text`, its top left at
-- canvas (x, y), in the current text style. One undo step.
function InkAwayView:replaceWithText(text, ink_ops, x, y)
    self.canvas:pushHistory()
    local gone = {}
    for _, op in ipairs(ink_ops) do gone[op] = true end
    for i = #self.canvas.ops, 1, -1 do
        if gone[self.canvas.ops[i]] then table.remove(self.canvas.ops, i) end
    end
    local v = self.view
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    x = math.max(margin, math.min(math.floor(x), v.canvas_w - margin - 10))
    local op = Text.new{ x = x, y = math.floor(y), w = v.canvas_w - x - margin,
        size = size, font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
    if self.text_grid_snap then self:snapTextBoxToGrid(op) end
    Text.insert(op, { p = 1, o = 0 }, text, nil)
    self.canvas:placeOp(op)
    self:markDirty()
    self:composeCanvas(); self:renderView()
    self:refresh(self, "ui", self:areaScreenRect())
end

return InkAwayView
