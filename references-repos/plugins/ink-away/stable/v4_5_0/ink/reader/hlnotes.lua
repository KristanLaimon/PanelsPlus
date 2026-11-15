--[[
Handwritten notes on the reader's highlights (#77). A highlight's handwritten
note is a page of the book's notes (ink/reader/booknotes.lua), written in the
notes window over the page (ink/reader/notesview.lua).

  * KOReader's menu for selected words gets "Handwritten note", next to "Add
    note": it makes the highlight as KOReader does (its style and colour, its
    prompt if it asks), then opens the note. The same menu, for a highlight made
    before (its "…" button), opens that highlight's note.
  * A tap on a highlight with a handwritten note opens the note (KOReader would
    show its typed note); anything amiss and KOReader shows its own.
  * KOReader's note on the highlight says "(Handwritten note)" while the note has
    ink and the highlight no other note, so its lists and exports show it as a
    highlight with a note (Book:linkHighlightNote).

The button goes in through KOReader's own way for plugins (addToHighlightDialog);
the tap is KOReader's function, followed once for every reader.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink/l10n")
local Book = require("ink/reader/book")

local HlNotes = {}

HlNotes.BUTTON = "04_inkaway_handwritten_note"   -- (KOReader orders by name: after "Add note")

-- The button, for KOReader's menu of selected words (`index`: a highlight made
-- before, from its "…").
local function button(book)
    return function(this, index)
        return {
            text = _("Handwritten note"),
            enabled = index ~= nil or this.hold_pos ~= nil,
            callback = function()
                if index then
                    if this.highlight_dialog then UIManager:close(this.highlight_dialog) end
                    this.highlight_dialog = nil
                    this:clear()
                    book:openHighlightNote(index)
                else
                    -- the highlight as KOReader makes it, then its note
                    this:showHighlightPrompt(function(new_index)
                        if new_index then book:openHighlightNote(new_index) end
                    end)
                end
            end,
        }
    end
end

-- A tap on a highlight with a handwritten note opens it (once, for every reader).
local function followTap()
    if HlNotes._tap then return end
    HlNotes._tap = true
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not (ok and type(ReaderHighlight.showHighlightNoteOrDialog) == "function") then return end
    local orig = ReaderHighlight.showHighlightNoteOrDialog
    ReaderHighlight.showHighlightNoteOrDialog = function(h, index, ...)
        local book = h.ui and Book.by_ui[h.ui]
        local list = h.ui and h.ui.annotation and h.ui.annotation.annotations
        local anno = list and list[index]
        if book and anno then
            local hok, has = pcall(book.hasHandNote, book, anno)
            if hok and has then
                local oko, err = pcall(book.openHighlightNote, book, index)
                if oko then return true end
                logger.warn("Ink Away: could not open the handwritten note:", err)
            end
        end
        return orig(h, index, ...)
    end
end

-- In a reader: the button on its highlight menu, and the tap.
function HlNotes.install(plugin)
    local ui, book = plugin.ui, plugin.book
    local h = ui and ui.highlight
    if not (book and h and type(h.addToHighlightDialog) == "function" and ui.annotation) then return end
    h:addToHighlightDialog(HlNotes.BUTTON, button(book))
    followTap()
end

return HlNotes
