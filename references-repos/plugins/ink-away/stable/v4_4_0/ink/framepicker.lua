--[[
The frame sheet of a drawing on a Bookshelf shelf (ink/drawingshelf.lua): its
twelve frames as previews of its own cover, the one in use marked, and a
second grid for the frame's finishes. Opened by a long press on the shelf and
from a drawing's menu in Ink Away's library.

The previews share the drawing's picture (its snapshot, see
DrawingShelf.takeSnapshot; no stroke is drawn) and each frame's pieces,
decoded once for the sheet and freed when it closes, so the sheet opens at
once and leaves nothing behind.
]]

local Library = require("ink/library")
local UIManager = require("ui/uimanager")
local _ = require("ink/l10n")
local DShelf = require("ink/drawingshelf")
local FrameCover = require("ink/framecover")
local Shelf = require("ink/bookshelf")
local Storage = require("ink/storage")

local FramePicker = {}

-- The drawing at `path`'s picture for the previews: its snapshot, else its
-- draft, else a draft drawn now (once).
local function pictureOf(path)
    local dir = DShelf.covers and DShelf.covers.dir()
    if not dir then
        dir = Storage.join(Storage.cacheDir(), DShelf.COVER_DIR)
        if not Storage.ensureDir(dir) then return nil end
    end
    local file = Shelf.pageFile(dir, path)
    if file then return file end
    local draft = Shelf.draftFile(dir, path)
    if DShelf.writeDraft(path, draft) then return draft end
    return nil
end

-- A cover preview fitting `maxw` x `maxh`, from the pieces kept in `keep`.
local function preview(look, keep, maxw, maxh)
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(FrameCover.render, look, keep)
    if not (ok and bb) then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local s = math.min(maxw / w, maxh / h)
    return RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * s)), math.max(1, math.floor(h * s)), true)
end

-- The frame grid: two pages of six, as the notebooks' cover sheet, opening on
-- the page of the frame in use. `o`: path (the drawing), open (opens it; shown
-- as a button when given), on_change.
function FramePicker.show(o)
    local ThumbGrid = require("ink/ui/thumbgrid")
    local path = o.path
    if not (path and Storage.exists(path)) or Library.isNotebookFile(path) then return end
    local picture = pictureOf(path)
    local keep = {}   -- the picture and the frames' pieces, decoded once for the sheet
    local look = DShelf.lookOf(path)
    local names = FrameCover.names()
    local grid
    local function items()
        local list = {}
        for _i, f in ipairs(FrameCover.frames()) do
            list[#list + 1] = { label = names[f], frame = f, selected = f == look.frame }
        end
        return list
    end
    local function changed()
        look = DShelf.lookOf(path)
        grid:setItems(items())
        if o.on_change then o.on_change() end
    end
    local actions = {
        { _("Finish"), function()
            if look.frame then FramePicker.finish(path, picture, keep, changed) end
        end },
    }
    if o.open then
        actions[#actions + 1] = { _("Open"), function() grid:close(); o.open() end, true }
    end
    local list = items()
    local start = 1
    for i, it in ipairs(list) do if it.selected then start = i end end
    grid = ThumbGrid:new{
        title = Storage.stem(path),
        items = list,
        start = start,
        cols = 3, rows = 2,
        flash_open = false,
        actions = actions,
        render = function(it, maxw, maxh)
            -- the frame in the finish in use, or in its first
            local opt = it.frame == look.frame and look.option or nil
            return preview({ frame = it.frame, option = opt, shape = look.shape, file = picture, name = Storage.stem(path) },
                keep, maxw, maxh)
        end,
        on_pick = function(it)
            DShelf.setLook(path, it.frame, it.frame == look.frame and look.option or nil)
            DShelf.lookChanged(path)
            changed()
        end,
        on_close = function() FrameCover.free(keep) end,
    }
    UIManager:show(grid)
    return grid
end

-- The finish grid for the frame of drawing `path` (its picture `picture`,
-- pieces shared in `keep`).
function FramePicker.finish(path, picture, keep, on_change)
    local ThumbGrid = require("ink/ui/thumbgrid")
    local look = DShelf.lookOf(path)
    local grid
    local function items()
        local list = {}
        for _i, opt in ipairs(FrameCover.options(look.frame)) do
            list[#list + 1] = { label = FrameCover.optionName(look.frame, opt), option = opt,
                selected = opt == look.option }
        end
        return list
    end
    grid = ThumbGrid:new{
        title = FrameCover.names()[look.frame] or _("Finish"),
        items = items(),
        cols = 3, rows = 2,
        flash_open = false,
        close_label = _("Done"),
        render = function(it, maxw, maxh)
            return preview({ frame = look.frame, option = it.option, shape = look.shape, file = picture,
                name = Storage.stem(path) },
                keep, maxw, maxh)
        end,
        on_pick = function(it)
            DShelf.setLook(path, look.frame, it.option)
            DShelf.lookChanged(path)
            look = DShelf.lookOf(path)
            grid:setItems(items())
            if on_change then on_change() end
        end,
    }
    UIManager:show(grid)
    return grid
end

return FramePicker
