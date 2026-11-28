--[[
Room in the text, in the annotation mode over a reflowing book (the rooms
themselves are in ink/reader/rooms.lua and ink/reader/book.lua):

  * a second tap on the Lasso opens its sheet: the Make room tool
    (ink/reader/roomtool.lua), whether the rooms show, and the list of them;
  * the selection's menu offers Make room: the text moves out of what is
    selected (a sticker, a picture, a shape, ink), and it goes into the room.

Making, changing or removing a room keeps the page's ink first and shows the
page laid out again after, on the room's page. Undo does not reach back past it
(as after a page turn).

Mixed into ReaderInkView, as the page-turn bar is (ink/reader/vbar.lua).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local Canvas = require("ink/canvas")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local S = function(px) return Screen:scaleBySize(px) end

local RoomsUI = {}

-- Can room be made here (a reflowing book, one page at a time)?
function RoomsUI:canMakeRoom()
    local book = self.book
    return book ~= nil and type(book.canRoom) == "function" and book:canRoom() == true
end

-- Everything in hand finished and the page's ink kept, before the layout changes.
function RoomsUI:settleForRooms()
    self:flushPending()
    self:cancelShape()
    if self.editing_text then self:finishTextEdit(true) end
    self:closeSelectionMenu()
    self:resetLasso()
    self:saveDocument()
end

-- Show the page again after the book was laid out again (on page `page`, if given).
function RoomsUI:reloadAfterRooms(page)
    local book = self.book
    if page and page ~= book:currentPage() then book:gotoPage(page) end
    self:loadBookPage()
    self._anchored_rev = self.canvas.rev
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui")
end

-- Change the book's rooms with `fn(book)`, which returns the room to show (or
-- nil and why it could not), then show its page laid out again. `keep(room)`
-- puts back what goes into the room (Make room for a selection), before the page
-- is saved. The book's first exact room loads the book again (Book:reloadForRooms):
-- the annotation mode closes, keeping everything, and opens again after it.
function RoomsUI:changeRooms(fn, keep)
    self:settleForRooms()
    local book = self.book
    if book._hidden_room then book._hidden_room = nil end
    local ok, room, why = pcall(fn, book)
    if not ok then
        logger.warn("Ink Away: could not change the rooms:", room)
        room, why = nil, "failed"
    end
    if why == "reload" and room then
        if keep then keep(room) end
        self:saveDocument()
        local id = room.id
        book:reloadForRooms(function(again)
            again:annotate()
            local view = again._view
            if view and view.afterRoomsReload then view:afterRoomsReload(id) end
        end)
        return room, why
    end
    local page = room and room.id and book:roomPage(room.id) or nil
    self:reloadAfterRooms(page)
    if keep then keep(room) end
    if why == "failed" then
        self:tell(_("This book's layout could not make room there. Try a box at another paragraph."))
    elseif why == "read_only" then
        self:tell(_("This book's annotations were saved by a newer Ink Away, so they can't be changed here."))
    elseif book:pinnedFrom(page or book:currentPage()) then
        self:showNotice(_("Items pinned to later pages may now sit over other text."))
    end
    return room, why
end

-- After the book was loaded again for its first exact room: is it there, with no
-- text across it? If not, it goes (what was put in it stays and follows the text).
function RoomsUI:afterRoomsReload(id)
    local book = self.book
    -- (on the room's page: KOReader keeps the place read, but the page numbers can
    -- move by one when the book is laid out with its markers)
    local page = book:roomPage(id)
    if page and book:currentPage() ~= page then book:gotoPage(page) end
    local room
    for _i, r in ipairs(book:rooms()) do if r.id == id then room = r end end
    -- (its column measured now that it is laid out)
    if room then book:fitBox(room) end
    if room and not book:boxTook(room, book:currentPage(), nil) then
        logger.warn("Ink Away: the room did not take in this book:", room.xp)
        book:removeRoom(id, "follow")
        room = nil
    end
    self:reloadAfterRooms()
    if not room then
        self:tell(_("This book's layout could not make room there. Try a box at another paragraph."))
    elseif book:pinnedFrom(book:currentPage()) then
        self:showNotice(_("Items pinned to later pages may now sit over other text."))
    end
end

-- Open the Make room tool (on `room`, to change it).
function RoomsUI:startRoomTool(room)
    if not self:canMakeRoom() then return end
    self:settleForRooms()
    require("ink/reader/roomtool").open(self, room)
end

------------------------------------------------------------------------------
-- The Lasso button's group: the Lasso and Make room
------------------------------------------------------------------------------

RoomsUI.GROUP_SETTING = "inkaway_lasso_group"

-- The tool the Lasso button stands for now: "room" when Make room was picked
-- last (and works in this book), else "lasso".
function RoomsUI:lassoGroupTool()
    if self:getSetting(RoomsUI.GROUP_SETTING) == "room" and self:canMakeRoom() then return "room" end
    return "lasso"
end

-- Make `tool` ("lasso" or "room") the one the button stands for, and its icon.
function RoomsUI:setLassoGroupTool(tool)
    local was = self:lassoGroupTool()
    self:setSetting(RoomsUI.GROUP_SETTING, tool == "room" and "room" or "lasso")
    if self:lassoGroupTool() ~= was and type(self.stickersBarChanged) == "function" then
        self:stickersBarChanged()
    end
end

-- A hold on the Lasso button: the two tools it holds, the one it stands for now
-- first in the accent; a tap picks one, uses it, and the button keeps it.
function RoomsUI:openLassoGroup()
    local field = "_lasso_group"
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet(field) end
    local now = self:lassoGroupTool()
    self:showSheet(field, function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Lasso"), content_w, _("Close"), closeSelf))
        add(VerticalSpan:new{ width = S(12) })
        add(self:actionTile("lasso", _("Lasso"), _("Loop ink, shapes or pictures to move, copy or change them"), content_w,
            function()
                closeSelf()
                self:setLassoGroupTool("lasso")
                self:setTool("lasso")
            end, nil, nil, now ~= "lasso" and "quiet" or nil))
        add(VerticalSpan:new{ width = S(10) })
        add(self:actionTile("room", _("Make room"), _("Draw a box and the text moves out of it"), content_w,
            function()
                closeSelf()
                self:setLassoGroupTool("room")
                self:startRoomTool()
            end, nil, nil, now ~= "room" and "quiet" or nil))
        add(VerticalSpan:new{ width = S(10) })
        add(self:sheetHint(_("The button keeps the one you pick. Hold it to switch again."), content_w))
        return content
    end)
end

------------------------------------------------------------------------------
-- The Lasso's sheet
------------------------------------------------------------------------------

function RoomsUI:openLassoMenu()
    if self:rebuildSheet("_lasso_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_lasso_dialog") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Lasso"), content_w, _("Done"), closeSelf))
        add(VerticalSpan:new{ width = S(12) })
        if self:canMakeRoom() then
            add(self:actionTile("room", _("Make room"), _("Draw a box and the text moves out of it"), content_w,
                function() closeSelf(); self:startRoomTool() end))
        else
            add(self:sheetHint(_("Make room works in books whose text reflows, shown one page at a time."), content_w, 15))
        end
        if self:canMakeRoom() and type(self.book.exactAvailable) == "function" then self:addExactRows(add, content_w, menu, closeSelf) end
        local rooms = self.book and type(self.book.rooms) == "function" and self.book:rooms() or {}
        if #rooms > 0 then
            add(VerticalSpan:new{ width = S(12) })
            add(ToggleRow:new{ label = _("Show the rooms"), is_on = self.book:roomsShown(), width = content_w,
                parent = menu, callback = function(on)
                    closeSelf()
                    self:changeRooms(function(book) book:showRooms(on) end)
                end })
            add(VerticalSpan:new{ width = S(4) })
            add(self:sheetHint(_("Hidden, the book reads as it was made, and what is in the rooms hides with them."), content_w))
            add(VerticalSpan:new{ width = S(10) })
            add(self:actionButton(string.format(_("Rooms in this book (%d)"), #rooms), content_w, function()
                closeSelf(); self:openRoomsList()
            end))
        end
        return content
    end
    self:showSheet("_lasso_dialog", build)
end

------------------------------------------------------------------------------
-- The list of rooms
------------------------------------------------------------------------------

local function kindLabel(r)
    if r.kind == "band" or r.side == "full" then return _("Band across the page") end
    if r.side == "left" then return _("Space on the left") end
    return _("Space on the right")
end

function RoomsUI:openRoomsList(pg)
    local field = "_rooms_dialog"
    self:closeSheet(field)
    local book = self.book
    local rooms = book:rooms()
    if #rooms == 0 then return end
    local content_w, gap = self:sheetWidth()
    local per = self:listRowsFit(content_w, gap)
    local pages = math.max(1, math.ceil(#rooms / per))
    pg = math.max(0, math.min(pages - 1, pg or 0))
    local shown = book:roomsShown()
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Rooms in this book"), content_w, _("Close"), closeSelf))
        add(VerticalSpan:new{ width = S(6) })
        add(self:sheetLabel(shown and _("Tap one to go to it and change it.") or _("The rooms are hidden: tap one to show them and go to it.")))
        for i = pg * per + 1, math.min(#rooms, (pg + 1) * per) do
            local r = rooms[i]
            local n = #book:roomItems(r.id)
            local p = shown and book:roomPage(r.id) or nil
            local notes = { p and string.format(_("Page %d"), p) or _("Hidden"),
                n == 0 and _("Nothing in it yet") or string.format(_("%d item(s) in it"), n) }
            add(VerticalSpan:new{ width = gap })
            add(self:listRow("room", kindLabel(r), notes, content_w, function()
                closeSelf(); self:goToRoom(r)
            end))
        end
        if pages > 1 then
            add(VerticalSpan:new{ width = gap })
            add(self:pagerRow(pg, pages, content_w, gap, function(d) self:openRoomsList(pg + d) end))
        end
        return content
    end
    self:showSheet(field, build)
end

-- What Exact lines does, said when it is switched on.
function RoomsUI.exactNotice()
    return _("Exact lines is on. A room can then start on any line of the text: Ink Away wraps one word of that line in an invisible mark, in a private copy of the book that it keeps in its own cache. The book's file is never changed, moved or sent, and the copy can always be made again from it. \"Back to the original book\" in this menu takes the marks away.")
end

-- Exact lines in the Lasso's sheet: the switch and its hint, and the way back to
-- the book as it is on the reader.
function RoomsUI:addExactRows(add, content_w, menu, closeSelf)
    local book = self.book
    local Exact = require("ink/reader/exactbook")
    add(VerticalSpan:new{ width = S(12) })
    if not book:exactAvailable() then
        add(self:sheetHint(_("Exact lines needs an EPUB shown in the Book or Web render mode."), content_w))
        return
    end
    add(ToggleRow:new{ label = _("Exact lines"), is_on = Exact.enabled(), width = content_w, parent = menu,
        callback = function(on)
            Exact.setEnabled(on)
            if on then self:tell(RoomsUI.exactNotice()) end
        end })
    add(VerticalSpan:new{ width = S(4) })
    add(self:sheetHint(_("Lets a room start on any line, not only at a paragraph. Works on a private copy of the book; the book's file is never changed."), content_w))
    add(VerticalSpan:new{ width = S(4) })
    add(self:sheetHint(_("Slower than ordinary rooms: when a room needs a line without a mark yet, the book is loaded again, which takes a while in a big book."), content_w))
    if book:hasExact() then
        add(VerticalSpan:new{ width = S(10) })
        add(self:actionButton(_("Back to the original book"), content_w, function()
            closeSelf(); self:restoreOriginalBook()
        end))
    end
end

-- Read the book as it is on the reader again: its marks go, and the book is loaded
-- from its own file. Not while a room hangs on one.
function RoomsUI:restoreOriginalBook()
    self:settleForRooms()
    local ok, why = self.book:removeExactMarks()
    if not ok then
        if why == "rooms" then
            self:tell(_("Remove the rooms made on exact lines first (Rooms in this book), then go back to the original book."))
        else
            self:tell(_("The book could not be put back."))
        end
        return
    end
    self.book:reloadForRooms(function(again) again:annotate() end)
end

-- Go to a room's page (the rooms shown first) and pick it in the Make room tool.
function RoomsUI:goToRoom(r)
    local book = self.book
    if not book:roomsShown() then
        self:changeRooms(function(b) b:showRooms(true) end)
    end
    local p = book:roomPage(r.id)
    if p and p ~= book:currentPage() then
        self:settleForRooms()
        self:reloadAfterRooms(p)
    end
    self:startRoomTool(r)
end

------------------------------------------------------------------------------
-- Room for what is selected
------------------------------------------------------------------------------

-- The text moves out of the selection's box: a band across the page, or, for a
-- selection at a side and not too wide, space beside the text. What was selected
-- goes into the room (the same distance from its edge as from the box's), and
-- stays selected there.
function RoomsUI:makeRoomForSelection()
    local sel = self.selection
    local b = sel and sel.bbox
    if not (b and self:canMakeRoom()) then return end
    local book = self.book
    -- (a hair of space, so the text does not touch it)
    local pad = S(4)
    local rect = { x = math.floor(b.x0) - pad, y = math.floor(b.y0) - pad,
                   w = math.ceil(b.x1 - b.x0) + 2 * pad, h = math.ceil(b.y1 - b.y0) + 2 * pad }
    local plan, pbox = book:planRoom(rect)
    -- where no room can start at its top, the nearest place one can (what is
    -- selected moves there with it, its size kept)
    local sok, snapped = pcall(book.snapRoomRect, book, rect, "height")
    if sok and snapped then plan, pbox = book:planRoom(snapped) end
    if not plan then
        self:tell(RoomsUI.whyNot(pbox))
        return
    end
    -- what is selected, lifted off the page while the text moves
    local copies = {}
    for _i, op in ipairs(self:selectionOps()) do copies[#copies + 1] = Canvas.cloneOp(nil, op) end
    self:closeSelectionMenu()
    self:selDelete()
    local idxs = {}
    -- back on the page: in the room (where it was, unless the room had to start
    -- lower), or where it was if no room could be made (the layout was put back)
    local function keep(room)
        local dx, dy = 0, 0
        if room and plan.kind == "box" and pbox and book._awaiting_reload == room.id then
            -- (the book's first room: laid out only once the book is loaded again,
            -- so what goes in it is kept with the box as planned)
            book:holdBox(room.id, pbox)
        end
        local box = room and book:roomBox(room.id)
        if box and plan.kind == "box" then
            dy = box.y - rect.y   -- (nothing, unless the room starts lower)
        elseif box then
            local w = b.x1 - b.x0
            if plan.kind == "band" then
                dy = (box.y + pad) - b.y0
            else
                local tx = plan.side == "right" and (box.x + pad) or (box.x + box.w - pad - w)
                dx = math.max(box.x, tx) - b.x0
                dy = (box.y + (b.y0 - pbox.y)) - b.y0
            end
        end
        for _i, c in ipairs(copies) do
            if dx ~= 0 or dy ~= 0 then Canvas.translateOp(c, dx, dy) end
            local _op, at = self.canvas:placeOp(c)
            idxs[#idxs + 1] = at
        end
        self:markDirty()
    end
    local _room, why = self:changeRooms(function(bk) return bk:addRoom(plan) end, keep)
    if why == "reload" then return end
    self:selectOps(idxs, "lasso")
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui")
    if self.selection then self:openSelectionMenu() end
end

-- What to say when a box makes no room (Rooms.planBox, Rooms.plan say why).
function RoomsUI.whyNot(why)
    if why == "small" then return _("Draw a bigger box.") end
    if why == "no_break" then return _("No paragraph starts on this page below the box's top, so the room has nowhere to start.") end
    if why == "overlap" then return _("Rooms can't overlap. Draw this one beside the other room or away from it.") end
    if why == "taken" then return _("This paragraph already holds a room. Draw this one where another paragraph begins, or change that room.") end
    return _("There is no text here to move.")
end

function RoomsUI.into(Class)
    for k, f in pairs(RoomsUI) do
        if k ~= "into" then Class[k] = f end
    end
end

return RoomsUI
