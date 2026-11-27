--[[
Changing the colour of a highlight in the annotation mode. A tap on a highlight
opens a sheet of colours: with a finger that is navigating, with the lasso, with
the highlighter in hand (a single tap on text already highlighted), or with Pan.
A hold still offers to remove it (see ReaderInkView:highlightPromptAt). For a
single highlight the sheet also has Handwritten note (ink/reader/hlnotes.lua),
as KOReader's menu for selected words has: a highlight made with the pen's
button gets its note this way too.

The colours are the person's own list (ink/reader/hlpalette.lua): the reader's
colours to start with, any of them taken off by holding it, and any colour from
the colour wheel added to it. The change is one undo step. Where something the
reader should have is missing (an older KOReader), the sheet leaves out what it
cannot do and nothing is raised.

Mixed into ReaderInkView, as the page-turn bar is (ink/reader/vbar.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local Palette = require("ink/reader/hlpalette")

local Screen = Device.screen

local FIELD = "_hl_colours"
local LABELS_FIELD = "_hl_labels"
local GREY = { 176, 176, 176 }   -- "gray": the reader's own highlight in a light grey

local HLColour = {}

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- A single tap, not a stroke: the points of a highlighter stroke that stay within a
-- few pixels of each other.
function HLColour:isTapStroke(op)
    local pts = op and op.pts
    if not (pts and #pts >= 2) then return false end
    local x0, y0, x1, y1 = pts[1], pts[2], pts[1], pts[2]
    for i = 3, #pts - 1, 2 do
        if pts[i] < x0 then x0 = pts[i] elseif pts[i] > x1 then x1 = pts[i] end
        if pts[i + 1] < y0 then y0 = pts[i + 1] elseif pts[i + 1] > y1 then y1 = pts[i + 1] end
    end
    return (x1 - x0) <= Screen:scaleBySize(6) and (y1 - y0) <= Screen:scaleBySize(6)
end

-- The highlights under the screen point `pos`.
function HLColour:highlightsUnder(pos)
    if not (pos and pos.x and pos.y and self.book and self.book.highlightsAt) then return {} end
    local ok, items = pcall(self.book.highlightsAt, self.book, { pos.x, pos.y }, Screen:scaleBySize(3))
    return ok and type(items) == "table" and items or {}
end

-- A tap at `pos`: the colour sheet for the highlight there. Returns whether one opened.
function HLColour:highlightTap(pos)
    local items = self:highlightsUnder(pos)
    if #items == 0 then return false end
    return self:openHighlightColours(items)
end

-- The palette as the person has it.
function HLColour:highlightPalette()
    return Palette.list(function(k) return self:getSetting(k) end)
end

function HLColour:setHighlightPalette(list)
    self:setSetting(Palette.SETTING, list)
end

-- A palette entry as an rgb for a swatch, or nil.
local function entryRgb(entry, custom)
    if entry == "gray" then return GREY end
    local hex = Palette.hexOf(entry, custom) or Palette.hex(entry)
    if not hex then return nil end
    local r, g, b = Palette.toRgb(hex)
    return { r, g, b }
end

-- An entry's name, for a screen that shows no colours.
function HLColour:highlightColourLabel(entry)
    local hex = Palette.hex(entry)
    if hex then return hex end
    local hl = self.book and self.book.ui and self.book.ui.highlight
    if hl and hl.getHighlightColorString then
        local ok, s = pcall(hl.getHighlightColorString, hl, entry)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return entry:sub(1, 1):upper() .. entry:sub(2)
end

-- Give `items` (annotation items) the palette entry `entry`, as one undo step.
-- Returns whether any changed.
function HLColour:setHighlightsColour(items, entry)
    local custom = self.book:customColours()
    local name = Palette.nameFor(entry, custom)
    if not name then
        self:tell(_("This version of KOReader can't keep colours of your own on a highlight."))
        return false
    end
    local changes = {}
    for _i, it in ipairs(items) do
        local from = it.color
        if from ~= name and self.book:setHighlightColour(it, name) then
            changes[#changes + 1] = { item = it, from = from, to = name }
        end
    end
    if #changes == 0 then return false end
    self.canvas.redo_stack = {}
    self.canvas:pushMark({ recolour = changes })
    self:pageChanged()
    return true
end

-- Undo or redo a recolour: each highlight back to one colour, those since taken
-- away from the book left alone.
function HLColour:applyRecolour(changes, back)
    for _i, c in ipairs(changes) do
        if self.book:hasHighlight(c.item) then
            self.book:setHighlightColour(c.item, back and c.from or c.to, true)
        end
    end
    self:pageChanged()
end

-- Is every one of `items` in the colour `entry` (compared by the colour shown).
local function allIn(items, entry, custom)
    if #items == 0 then return false end
    local want = Palette.hexOf(entry, custom) or entry
    for _i, it in ipairs(items) do
        local have = it.color and (Palette.hexOf(it.color, custom) or it.color)
        if have ~= want then return false end
    end
    return true
end

-- The colour wheel for a colour of one's own: used for these highlights, or
-- (Save) added to the list too.
function HLColour:openHighlightWheel(items)
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    local custom = self.book:customColours()
    local start = items[1] and entryRgb(items[1].color, custom) or { 255, 235, 59 }
    local function apply(rgb) self:setHighlightsColour(items, Palette.fromRgb(rgb)) end
    UIManager:show(ColorPicker:new{
        color = start,
        on_pick = apply,
        on_save = function(rgb)
            self:setHighlightPalette(Palette.added(self:highlightPalette(), Palette.fromRgb(rgb)))
            apply(rgb)
        end,
    })
end

-- One highlight tapped: its place in the reader's list, when it can have a
-- handwritten note (ink/reader/hlnotes.lua); nil otherwise.
function HLColour:highlightNoteIndex(items)
    local book = self.book
    if not (items and #items == 1 and book and book.openHighlightNote and book.findHighlight) then return nil end
    local a = items[1]
    local ok, _anno, index = pcall(book.findHighlight, book, { dt = a.datetime, pos0 = a.pos0, pos1 = a.pos1 })
    return ok and index or nil
end

-- Its handwritten note, in the notes window over the book: the annotation mode
-- closes first, its ink saved (as Book notes from the gestures does).
function HLColour:openNoteOfHighlight(anno)
    local book = self.book
    local key = { dt = anno.datetime, pos0 = anno.pos0, pos1 = anno.pos1 }
    self:closeCanvas()
    UIManager:nextTick(function()
        local ok, _anno, index = pcall(book.findHighlight, book, key)
        if ok and index then book:openHighlightNote(index) end
    end)
end

-- The sheet of colours for the highlights `items`.
function HLColour:openHighlightColours(items)
    if not (items and #items > 0 and self.book) then return false end
    self:closeSheet(FIELD)
    local colour = self:colorScreen()
    local content_w, gap, col = self:sheetWidth(5)
    local function close() self:closeSheet(FIELD) end
    local function again() self:rebuildSheet(FIELD) end
    local function pick(entry)
        close()
        local ok, err = pcall(self.setHighlightsColour, self, items, entry)
        if not ok then logger.warn("Ink Away: highlight colour:", err) end
    end
    local get = function(k) return self:getSetting(k) end
    local build = function()
        local custom = self.book:customColours()
        local list = self:highlightPalette()
        local labelled = Palette.anyLabel(get)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Highlight colour"), content_w, _("Done"), close) }
        local function add(w) table.insert(g, w) end
        add(vspan(12))
        local function forget(entry)
            self:setHighlightPalette(Palette.removed(self:highlightPalette(), entry))
            again()
        end
        if colour then
            local swh = math.min(col, Screen:scaleBySize(44))
            local tiles = {}
            for _i, entry in ipairs(list) do
                local rgb = entryRgb(entry, custom)
                if rgb then
                    local tile = self:swatchTile(rgb, allIn(items, entry, custom), col,
                        function() pick(entry) end, function() forget(entry) end, swh)
                    -- (with labels: each under its colour, the row kept even)
                    if labelled then tile = self:labelledTile(tile, Palette.label(get, entry), col) end
                    tiles[#tiles + 1] = tile
                end
            end
            -- the wheel, as the last tile (where the reader keeps colours of one's own)
            if custom then
                local wheel = self:wheelTile(col, swh, function() close(); self:openHighlightWheel(items) end)
                if labelled then wheel = self:labelledTile(wheel, nil, col) end
                tiles[#tiles + 1] = wheel
            end
            for i = 1, #tiles, 5 do
                local row = HorizontalGroup:new{ align = "top" }
                for j = i, math.min(i + 4, #tiles) do
                    if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
                    table.insert(row, tiles[j])
                end
                if i > 1 then add(vspan(8)) end
                add(row)
            end
            add(vspan(10))
            add(self:sheetHint(_("Hold a colour to take it off this list. The wheel adds colours of your own."), content_w, 14))
        else
            -- a screen with no colours shows them as shades: the names say which is which
            local half = math.floor((content_w - gap) / 2)
            for i = 1, #list, 2 do
                local row = HorizontalGroup:new{ align = "top" }
                for j = i, math.min(i + 1, #list) do
                    if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
                    local entry = list[j]
                    local name, label = self:highlightColourLabel(entry), Palette.label(get, entry)
                    table.insert(row, self:actionButton(label and (label .. " \u{00B7} " .. name) or name, half,
                        function() pick(entry) end, allIn(items, entry, custom), "small"))
                end
                if i > 1 then add(vspan(8)) end
                add(row)
            end
        end
        add(vspan(14))
        local half = math.floor((content_w - gap) / 2)
        local function pair(a, b)
            add(HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b })
        end
        local remove = function(w)
            return self:actionButton(_("Remove highlight"), w, function()
                close(); self:removeHighlights(items)
            end, nil, nil, "trash")
        end
        local reset = not Palette.isDefault(get)
        local note = self:highlightNoteIndex(items)
        -- the buttons, two to a row: a handwritten note (one highlight), removing
        -- it, the colours' labels, and putting the reader's colours back
        local buttons = {}
        if note then
            buttons[#buttons + 1] = function(w) return self:actionButton(_("Handwritten note"), w, function()
                close(); self:openNoteOfHighlight(items[1])
            end) end
        end
        buttons[#buttons + 1] = remove
        buttons[#buttons + 1] = function(w) return self:actionButton(_("Labels"), w, function()
            close(); self:openHighlightLabels(items)
        end) end
        if reset then
            buttons[#buttons + 1] = function(w) return self:actionButton(_("Reset colours"), w, function()
                self:setSetting(Palette.SETTING, nil); again()
            end) end
        end
        for i = 1, #buttons, 2 do
            if i > 1 then add(vspan(8)) end
            if buttons[i + 1] then pair(buttons[i](half), buttons[i + 1](half)) else add(buttons[i](content_w)) end
        end
        return g
    end
    self:showSheet(FIELD, build)
    return true
end

-- A colour tile with its label under it (a blank line for one with none, so the
-- tiles of a row stay level).
function HLColour:labelledTile(tile, label, w)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local face = Font:getFace("cfont", 12)
    local text = TextWidget:new{ text = label or " ", face = face, max_width = w }
    return VerticalGroup:new{ align = "center", tile, vspan(2),
        CenterContainer:new{ dimen = Geom:new{ w = w, h = text:getSize().h }, text } }
end

-- What each highlight colour means (#81): a label for each colour of the list,
-- shown with it in the colour sheet. Done goes back to that sheet.
function HLColour:openHighlightLabels(items)
    self:closeSheet(LABELS_FIELD)
    local colour = self:colorScreen()
    local content_w, gap = self:sheetWidth()
    local get = function(k) return self:getSetting(k) end
    local function again() self:rebuildSheet(LABELS_FIELD) end
    local function back()
        self:closeSheet(LABELS_FIELD)
        if items then self:openHighlightColours(items) end
    end
    local function ask(entry)
        self:promptText({ title = _("Label for this colour"), input = Palette.label(get, entry) or "", ok_text = _("Save"),
            hint = _("Important, a word to look up, a question…"),
            on_ok = function(text)
                self:setSetting(Palette.LABELS, Palette.labelled(self:getSetting(Palette.LABELS), entry, text))
                again()
            end })
    end
    local build = function()
        local custom = self.book and self.book:customColours()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(_("Colour labels"), content_w, _("Done"), back) }
        local function add(w) table.insert(g, w) end
        add(vspan(6))
        add(self:sheetHint(_("What each colour means to you. It shows with the colour when you change a highlight's colour."), content_w, 14))
        local sw = Screen:scaleBySize(44)
        for _i, entry in ipairs(self:highlightPalette()) do
            add(vspan(gap))
            local label = Palette.label(get, entry)
            local text = label or _("Add a label")
            if colour then
                local rgb = entryRgb(entry, custom)
                local row = HorizontalGroup:new{ align = "center" }
                if rgb then
                    table.insert(row, self:swatchTile(rgb, false, sw, function() ask(entry) end, nil, sw))
                    table.insert(row, HorizontalSpan:new{ width = gap })
                end
                table.insert(row, self:actionButton(text, content_w - (rgb and (sw + gap) or 0), function() ask(entry) end, label ~= nil))
                add(row)
            else
                -- (no colours on the screen: the colour's name says which it is)
                add(self:actionButton(self:highlightColourLabel(entry) .. " \u{00B7} " .. text, content_w,
                    function() ask(entry) end, label ~= nil))
            end
        end
        return g
    end
    self:showSheet(LABELS_FIELD, build)
end

-- Mix the above into `Class`.
function HLColour.into(Class)
    for k, f in pairs(HLColour) do
        if k ~= "into" then Class[k] = f end
    end
end

return HLColour
