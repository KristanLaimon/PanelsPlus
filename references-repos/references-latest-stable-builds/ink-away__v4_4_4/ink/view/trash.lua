--[[
Deleting into the trash, and its sheet: documents, folders and pages deleted
from the library, the overview or the page menu wait there for 30 days (see
ink/trash.lua) and can be put back where they were, or deleted for good. The
sheet opens from the library's menu.
Part of InkAwayView (see ink/view.lua).
]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local _ = require("ink/l10n")
local Folder = require("ink/folder")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")
local Trash = require("ink/trash")

local Screen = Device.screen

local InkAwayView = {}

------------------------------------------------------------------------------
-- Deleting
------------------------------------------------------------------------------

-- Move the document or folder at `path` to the trash. When it is or holds the
-- open document, that is saved first and a new drawing in `dir` takes its
-- place. Returns whether it went.
function InkAwayView:trashPath(path, is_folder, dir)
    local root = self:libraryDir()
    local holds_open = self.doc_path ~= nil and Storage.within(self.doc_path, path)
    if holds_open and self.doc_written then self:leaveDocument() end
    local item, err
    if is_folder then
        item, err = Trash.putFolder(root, path)
    elseif Library.isPicture(Storage.baseName(path)) then
        item, err = Trash.putPicture(root, path)
    elseif Storage.exists(path) then
        item, err = Trash.putDocument(root, path, Library.isNotebookFile(path))
    elseif not (holds_open and not self.doc_written) then
        err = "not there"
    end
    if err then
        self:tell(_("Could not delete it.\n") .. tostring(err))
        return false
    end
    if not is_folder then self:dropThumbs(path) end
    if holds_open then self:discardDocument(dir or Storage.dirName(path)) end
    if item then self:showNotice(_("Moved to the trash")) end
    return true
end

-- Keep page i of notebook `nb` (at `path`) in the trash before it is removed.
-- Returns whether it is kept; says so when it could not be.
function InkAwayView:trashPage(path, nb, i)
    local item, err = Trash.putPage(self:libraryDir(), path, nb, i)
    if not item then
        self:tell(_("Could not delete the page.\n") .. tostring(err))
        return false
    end
    self:showNotice(_("Moved to the trash"))
    return true
end

------------------------------------------------------------------------------
-- Putting back
------------------------------------------------------------------------------

-- Put a page from the trash back into the notebook at `nb_path`, between the
-- pages it sat between (a new notebook there when that one is gone). Returns
-- whether it worked.
function InkAwayView:putPageBack(nb_path, saved, item)
    local page = saved.page
    if Storage.exists(nb_path) or (nb_path == self.doc_path and self.notebook) then
        return self:editNotebookAt(nb_path, function(nb)
            nb:insertPage(page, Trash.pageSlot(nb, item))
        end) and true or false
    end
    local dir = Storage.dirName(nb_path)
    if not Storage.isDir(dir) and not Storage.ensureDir(dir) then return false end
    local nb = Notebook.new(saved.w or self.screen_w, saved.h or self.screen_h, saved.template)
    nb.pages, nb.next_id = {}, 1
    nb:insertPage(page, 1)
    if not Project.saveNotebook(nb, nb_path) then return false end
    Folder.update(dir, function(d) Folder.add(d, Storage.baseName(nb_path)) end)
    return true
end

-- Put item `it` back and show where it went.
function InkAwayView:restoreTrashItem(it)
    local root = self:libraryDir()
    local back, err = Trash.restore(root, it.id, function(nb_path, saved, item)
        return self:putPageBack(nb_path, saved, item)
    end)
    if not back then
        self:tell(_("Could not put it back.\n") .. tostring(err))
        return
    end
    if it.kind == "bookink" then
        self:bookInkBack(it)
        if it.book and not Storage.exists(it.book) then
            self:tell(string.format(
                _("The annotations of %s are back where the book was. They show again when the book is back in that place."),
                it.name or ""))
        else
            self:showNotice(string.format(_("Put back on %s"), it.name or ""))
        end
        return
    end
    if self._library then self:refreshLibrary() end
    if self._overview then
        if self._ov then
            for p in pairs(self._ov.docs) do if Storage.within(p, back) or p == back then self._ov.docs[p] = nil end end
        end
        self:refreshOverview()
    end
    self:dropThumbs(back)
    self:showNotice(string.format(_("Put back in %s"), self:searchPlace(Storage.dirName(back))
        .. " \u{203A} " .. Storage.stem(back)))
end

-- A book's annotations came back from the trash: if that book is open in the
-- reader, show them again.
function InkAwayView:bookInkBack(it)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    local plugin = ui and (ui["ink-away"] or ui.inkaway)
    local book = plugin and plugin.book
    if book and ui.document and ui.document.file == it.book then book:reload() end
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- The icon, title and grey lines an item is listed with.
function InkAwayView:trashRow(it)
    local days = math.max(0, Trash.KEEP_DAYS - math.floor((Trash.now() - (tonumber(it.when) or 0)) / 86400))
    local when = string.format(_("Deleted %s \u{00B7} gone for good in %d days"),
        os.date("%d %b %H:%M", tonumber(it.when) or 0), days)
    if it.kind == "page" then
        local title = (it.name and it.name ~= "") and it.name or string.format(_("Page %d"), it.page or 1)
        return "file", title, { string.format(_("Page %d of %s"), it.page or 1, it.notebook or "?"), when }
    end
    if it.kind == "bookink" then
        return "highlighter", it.name, { it.gone and _("Annotations of a deleted book") or _("Annotations on this book"), when }
    end
    local place = string.format(_("From %s"), self:searchPlace(Storage.dirName(it.from)))
    if it.kind == "folder" then return "folder", it.name, { place, when } end
    if it.kind == "picture" then return "image", it.name, { place, when } end
    return it.nb and "notebook" or "pen", it.name, { place, when }
end

-- The trash: what is in it, newest first, a page of them at a time; a tap on
-- one offers to put it back or delete it for good.
function InkAwayView:openTrash()
    local root = self:libraryDir()
    pcall(Trash.purge, root)
    local field = "_trash_sheet"
    local items = Trash.list(root)
    local page, per, pages = 0, nil, 1
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local S = function(px) return Screen:scaleBySize(px) end
        local content_w = self:sheetWidth()
        local gap = S(10)
        if not per then
            per = self:listRowsFit(content_w, gap)
            pages = math.max(1, math.ceil(#items / per))
        end
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Trash"), content_w, _("Close"), closeSelf))
        add(VerticalSpan:new{ width = S(6) })
        add(self:sheetLabel(#items == 0 and _("The trash is empty.")
            or string.format(_("Deleted things stay here for %d days."), Trash.KEEP_DAYS)))
        local first = page * per
        for k = first + 1, math.min(#items, first + per) do
            local it = items[k]
            local icon, title, notes = self:trashRow(it)
            add(VerticalSpan:new{ width = gap })
            add(self:listRow(icon, title, notes, content_w, function()
                closeSelf()
                self:openActionSheet("_trash_item", title, notes[1], {
                    { { _("Put back"), function() self:restoreTrashItem(it); self:openTrash() end, true },
                      { _("Delete for good"), function() self:confirmForget(it, title) end } },
                })
            end))
        end
        if pages > 1 then
            add(VerticalSpan:new{ width = gap })
            add(self:pagerRow(page, pages, content_w, gap, function(d)
                page = (page + d) % pages
                self:rebuildSheet(field)
            end))
        end
        if #items > 0 then
            add(VerticalSpan:new{ width = S(14) })
            add(self:actionButton(_("Empty the trash"), content_w, function()
                self:ask{ field = "_trash_ask", title = _("Empty the trash?"),
                    text = _("Everything in it is deleted for good."),
                    ok_text = _("Empty"), ok_icon = "trash",
                    on_ok = function()
                        Trash.empty(root)
                        closeSelf()
                        self:openTrash()
                    end }
            end, nil, nil, "trash"))
        end
        return content
    end
    self:closeSheet(field)
    self:showSheet(field, build)
end

function InkAwayView:confirmForget(it, title)
    self:ask{ title = string.format(_("Delete \u{201C}%s\u{201D} for good?"), title),
        text = _("It can't be brought back."),
        ok_text = _("Delete"), ok_icon = "trash",
        on_ok = function()
            Trash.forget(self:libraryDir(), it.id)
            self:openTrash()
        end,
        on_cancel = function() self:openTrash() end }
end

return InkAwayView
