--[[
The everyday dialogs, as sheets like the rest of Ink Away and built in one
place: a message, a question to confirm, a line of text to type, a choice from a
list, a number on a slider, and a file or folder to pick. Every part of Ink Away
asks through these, so they all look and behave alike.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end
local function vspan(px) return VerticalSpan:new{ width = S(px) } end

local InkAwayView = {}

-- A message, with OK to close it. `o` may hold a title (OK then sits beside
-- it), timeout (seconds until it closes by itself), wait (a "working on it"
-- note with no OK, closed by the caller) and field. Returns a function that
-- closes it.
function InkAwayView:tell(text, o)
    o = o or {}
    local field = o.field or "_message"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local function close() self:closeSheet(field) end
    local build = function()
        local g = VerticalGroup:new{ align = "left" }
        if o.title then
            table.insert(g, self:sheetTitle(o.title, content_w, _("OK"), close))
            table.insert(g, vspan(8))
        end
        table.insert(g, TextBoxWidget:new{ text = text, width = content_w, face = Font:getFace("cfont", 17) })
        if not (o.title or o.wait) then
            table.insert(g, vspan(14))
            table.insert(g, self:actionButton(_("OK"), content_w, close))
        end
        return g
    end
    local timer
    if o.timeout then timer = function() close() end end
    self:showSheet(field, build, { on_closed = timer and function() UIManager:unschedule(timer) end })
    -- (what it says, for whoever holds the sheet; one that closes by itself
    -- never holds on to a touch, see touchTarget)
    self[field].text, self[field].timeout = text, o.timeout
    if timer then UIManager:scheduleIn(o.timeout, timer) end
    return close
end

-- A question to confirm: a title, the question in full under it, and Cancel
-- beside the action. `o` holds title, text, ok_text, on_ok(), and optional
-- cancel_text, on_cancel(), on_dismiss() (a tap outside or Back: on_cancel
-- unless given), ok_icon and field.
function InkAwayView:ask(o)
    local field = o.field or "_ask"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local function cancel()
        self:closeSheet(field)
        if o.on_cancel then o.on_cancel() end
    end
    local function ok()
        self:closeSheet(field)
        o.on_ok()
    end
    local build = function()
        local w = math.floor((content_w - gap) / 2)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(o.title, content_w, _("Cancel"), cancel) }
        if o.text then
            table.insert(g, vspan(10))
            table.insert(g, TextBoxWidget:new{ text = o.text, width = content_w, face = Font:getFace("cfont", 16) })
        end
        table.insert(g, vspan(18))
        table.insert(g, HorizontalGroup:new{ align = "center",
            self:actionButton(o.cancel_text or _("Cancel"), w, cancel),
            HorizontalSpan:new{ width = gap },
            self:actionButton(o.ok_text, w, ok, true, nil, o.ok_icon) })
        return g
    end
    self:showSheet(field, build, { on_close = o.on_dismiss or o.on_cancel })
    -- (what it asks and its two answers, for whoever holds the sheet)
    local sheet = self[field]
    sheet.text = o.text and (o.title .. "\n" .. o.text) or o.title
    sheet.ok_callback, sheet.cancel_callback = ok, cancel
end

-- A line of text to type, on the keyboard. `o` holds title, input (the text to
-- start with), hint, description, input_type, ok_text and on_ok(text, on) (`on`:
-- the toggle's state), plus optional on_cancel(), `default` (the text on_ok
-- gets when the field is left empty), `extra` ({ text, callback(text) }: a
-- second button that gets what was typed so far) and `toggle` ({ label, is_on }:
-- a switch under the field) and field. Enter does what the main button does,
-- unless `lines` asks for a taller field of that many lines, where Enter
-- starts a new line.
function InkAwayView:promptText(o)
    local field = o.field or "_prompt"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local InputText = require("ui/widget/inputtext")
    local toggle_on = o.toggle and o.toggle.is_on and true or false
    local input
    local function cancel()
        self:closeSheet(field)
        if o.on_cancel then o.on_cancel() end
    end
    local function ok()
        if not self[field] then return end   -- (closed meanwhile: Enter acts a moment later)
        local text = input:getText()
        self:closeSheet(field)
        if o.default and (not text or text == "") then text = o.default end
        o.on_ok(text, toggle_on)
    end
    local pad, border = S(8), Size.border.inputtext or 2
    input = InputText:new{ text = o.input or "", hint = o.hint, input_type = o.input_type, text_type = o.text_type,
        face = Font:getFace("cfont", 20), width = content_w - 2 * (pad + border),
        padding = pad, margin = 0, bordersize = border, focused = true, scroll = o.lines ~= nil,
        height = o.lines and S(28) * o.lines or nil, allow_newline = o.lines ~= nil,
        enter_callback = not o.lines and ok or nil }
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(o.title, content_w, _("Cancel"), cancel) }
        if o.description then
            table.insert(g, vspan(4))
            table.insert(g, self:sheetHint(o.description, content_w, 15))
        end
        table.insert(g, vspan(12))
        table.insert(g, input)
        if o.toggle then
            local ToggleRow = require("ink/ui/controls").ToggleRow
            table.insert(g, vspan(8))
            table.insert(g, ToggleRow:new{ label = o.toggle.label, is_on = toggle_on, width = content_w, parent = menu,
                callback = function(on) toggle_on = on end })
        end
        table.insert(g, vspan(14))
        if o.extra then
            local w = math.floor((content_w - gap) / 2)
            table.insert(g, HorizontalGroup:new{ align = "center",
                self:actionButton(o.extra.text, w, function()
                    local text = input:getText()
                    self:closeSheet(field)
                    o.extra.callback(text)
                end),
                HorizontalSpan:new{ width = gap },
                self:actionButton(o.ok_text, w, ok, true) })
        else
            table.insert(g, self:actionButton(o.ok_text, content_w, ok, true))
        end
        return g
    end
    -- the on-screen keyboard comes up a moment later, once the tap that opened
    -- this has resolved (at once it can lose the field's focus), unless a
    -- physical keyboard is in use, as with KOReader's own fields
    local function keyboard()
        if self[field] and self[field] == input.parent and not self:physicalKeyboard() then input:onShowKeyboard() end
    end
    -- at the top, clear of the keyboard; the keyboard goes with the sheet
    self:showSheet(field, build, { top = true, on_close = o.on_cancel, on_closed = function()
        UIManager:unschedule(keyboard)
        input:onCloseKeyboard()
        input:onCloseWidget()
    end })
    input.parent = self[field]
    -- (its two answers, for whoever holds the sheet)
    self[field].ok_callback, self[field].cancel_callback = ok, cancel
    -- what the keyboard on top does not take (typed text, a physical keyboard's
    -- keys) comes on to the sheet and its field, as with KOReader's own text dialogs
    self[field].is_always_active = true
    UIManager:nextTick(keyboard)
end

-- A choice from a list: one wide button per item, a page at a time. `o` holds
-- title, items ({ label, cb, icon }, each closing the sheet before its cb),
-- and optional note, empty (said when there are none), footer (more buttons
-- under the list, the same shape), close_text and field.
function InkAwayView:chooseFromList(o)
    local field = o.field or "_list"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local per = o.per or 7
    local page = 0
    local function close() self:closeSheet(field) end
    local function button(it)
        return self:actionButton(it.label, content_w, function() close(); it.cb() end, it.dark, nil, it.icon)
    end
    local build = function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(o.title, content_w, o.close_text or _("Close"), close) }
        local function add(w) table.insert(g, w) end
        if o.note then add(vspan(6)); add(self:sheetLabel(o.note)) end
        local pages = math.max(1, math.ceil(#o.items / per))
        page = math.min(page, pages - 1)
        for i = page * per + 1, math.min(#o.items, (page + 1) * per) do
            add(vspan(8)); add(button(o.items[i]))
        end
        if #o.items == 0 and o.empty then add(vspan(10)); add(self:sheetHint(o.empty, content_w, 15)) end
        if pages > 1 then
            add(vspan(12))
            add(self:pagerRow(page, pages, content_w, gap, function(d)
                page = math.max(0, math.min(pages - 1, page + d))
                self:rebuildSheet(field)
            end))
        end
        for _i, it in ipairs(o.footer or {}) do add(vspan(12)); add(button(it)) end
        return g
    end
    self:showSheet(field, build)
end

-- A number on a slider. `o` holds title, value, min, max, step, on_done(value)
-- (on Done, a tap outside or Back), and optional note, label, format(v) (the
-- value as shown) and field.
function InkAwayView:askNumber(o)
    local field = o.field or "_number"
    self:closeSheet(field)
    local content_w = self:sheetWidth()
    local SliderRow = require("ink/ui/controls").SliderRow
    local value = o.value
    local function done() self:closeSheet(field); o.on_done(value) end
    local build = function(menu)
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(o.title, content_w, _("Done"), done) }
        if o.note then table.insert(g, vspan(4)); table.insert(g, self:sheetHint(o.note, content_w, 15)) end
        table.insert(g, vspan(12))
        table.insert(g, SliderRow:new{ label = o.label or "", value = value, min = o.min, max = o.max, step = o.step,
            width = content_w, parent = menu, format = o.format, on_set = function(v) value = v end })
        return g
    end
    self:showSheet(field, build, { on_close = function() o.on_done(value) end })
end

-- A job's progress: its title, a bar and Stop; taps beside it leave it open.
-- `o` holds title, max, on_stop() and optional note (under the title),
-- stop_ask (a question asked before stopping) and field. Returns
-- { report(n), close() }: how far the job got (up to max), and its end.
function InkAwayView:showProgress(o)
    local field = o.field or "_progress"
    local content_w = self:sheetWidth()
    local okp, ProgressWidget = pcall(require, "ui/widget/progresswidget")
    local bar = okp and ProgressWidget and ProgressWidget:new{ width = content_w, height = S(12), percentage = 0 }
    local handle, over, shown_at = {}, false, nil
    local show
    local function stopNow()
        handle.close()
        o.on_stop()
    end
    -- Stop, or Back: asked first when there is a question; "Keep going" goes on
    local function requestStop()
        if over then return end
        if not o.stop_ask then return stopNow() end
        self:ask{ field = field .. "_ask", title = _("Stop now?"), text = o.stop_ask,
            ok_text = _("Stop"), cancel_text = _("Keep going"),
            on_ok = stopNow, on_cancel = function() if not self[field] then show() end end }
    end
    local build = function()
        local g = VerticalGroup:new{ align = "left", self:sheetTitle(o.title, content_w, _("Stop"), requestStop) }
        if o.note then table.insert(g, vspan(4)); table.insert(g, self:sheetHint(o.note, content_w, 15)) end
        if bar then table.insert(g, vspan(14)); table.insert(g, bar) end
        return g
    end
    show = function()
        self:closeSheet(field)
        self:showSheet(field, build, { keep_open = true, on_close = requestStop })
    end
    function handle.report(n)
        if over or not bar or type(n) ~= "number" then return end
        bar:setPercentage(math.max(0, math.min(1, n / math.max(1, o.max or 1))))
        -- (an e-ink refresh a second at most)
        local now = os.time()
        if self[field] and shown_at ~= now then
            shown_at = now
            UIManager:setDirty(self[field], "ui")
        end
    end
    function handle.close()
        over = true
        self:closeSheet(field)
        self:closeSheet(field .. "_ask")
    end
    show()
    return handle
end

-- A message from where no Ink Away view is open (a book's ink, saved in the
-- background): the same sheet, from a stand-in for the view.
function InkAwayView.tellAnywhere(text)
    local host = setmetatable({}, { __index = require("ink/view") })
    host:tell(text)
end

local function isPicture(name)
    local l = name:lower()
    return l:match("%.png$") ~= nil or l:match("%.jpe?g$") ~= nil
end
InkAwayView.isPictureName = isPicture

-- Browse the reader's folders as a grid, from `o.start`: a tap goes into a
-- folder, the arrow goes up. With o.folders the header's button picks the
-- folder shown; otherwise a tap on a file picks it, of the files o.accept(name)
-- lets through (pictures show as thumbnails, the rest with o.file_icon).
-- o.on_pick(path) gets the choice; o.empty is said in a folder with nothing.
function InkAwayView:browseFiles(o)
    local grid, cur
    local function title(dir) return dir == "/" and "/" or Storage.baseName(dir) end
    local function items(dir)
        local folders, files = {}, {}
        for _i, e in ipairs(Storage.list(dir)) do
            if e.name:sub(1, 1) ~= "." then
                if e.mode == "directory" then
                    folders[#folders + 1] = { label = e.name, path = e.path, folder = true }
                elseif not o.folders and e.mode == "file" and (not o.accept or o.accept(e.name)) then
                    local pic = isPicture(e.name)
                    files[#files + 1] = { label = e.name, path = e.path, picture = pic or nil,
                        icon = not pic and self:iconPath(o.file_icon or "file") or nil }
                end
            end
        end
        local function byName(a, b) return a.label:lower() < b.label:lower() end
        table.sort(folders, byName); table.sort(files, byName)
        for _i, f in ipairs(files) do folders[#folders + 1] = f end
        return folders
    end
    local function up(dir)
        local d = Storage.dirName(dir)
        return (d == "" or d == ".") and "/" or d
    end
    local function go(dir)
        cur = dir
        grid.gpage = 0
        grid.on_back = dir ~= "/" and function() go(up(cur)) end or nil
        grid:setItems(items(dir), title(dir))
    end
    local start = (o.start and Storage.isDir(o.start)) and o.start:gsub("(.)/+$", "%1") or self:homeDir()
    cur = start
    grid = ThumbGrid:new{
        title = title(start),
        items = items(start),
        folder_icon = self:iconPath("folder"),
        flash_open = not self:colourPanel(),
        close_label = _("Cancel"),
        empty_text = o.empty,
        actions = o.folders and { { o.ok_text or _("Use this folder"), function()
            grid:close(); o.on_pick(cur)
        end, true } } or nil,
        on_back = start ~= "/" and function() go(up(cur)) end or nil,
        render = function(it, w, h) return it.picture and self:pictureThumb(it.path, w, h) or nil end,
        on_pick = function(it)
            if it.folder then return go(it.path) end
            grid:close()
            o.on_pick(it.path)
        end,
        on_close = function() self:uncovered() end,
    }
    UIManager:show(grid)
end

-- KOReader's own file list for choosing a file, starting in folder `path`: its
-- sorting, without the .sdr folders, and a tap on a file picks it. `title` is
-- shown above the list.
function InkAwayView:browseKoreaderFiles(path, on_pick, accept, title)
    local PathChooser = require("ui/widget/pathchooser")
    local chooser
    chooser = PathChooser:new{
        title = title or true,
        path = (path and Storage.isDir(path)) and path or self:homeDir(),
        select_directory = false, select_file = true,
        file_filter = accept and function(full) return accept(Storage.baseName(full)) end or nil,
        onConfirm = function(file) on_pick(file) end,
    }
    local select = chooser.onMenuSelect
    chooser.onMenuSelect = function(this, item)
        local file = item and item.path
        if file and not Storage.isDir(file) then
            UIManager:close(this)
            self:uncovered()
            on_pick(file)
            return true
        end
        return select(this, item)
    end
    UIManager:show(chooser)
end

-- Let the reader pick a file, starting in folder `path`: only the files
-- accept(name) lets through are shown (all with none), with `icon` on their
-- cards; `empty` is said in a folder without any. Pictures are chosen from a
-- grid of thumbnails, anything else from KOReader's own file list, under `title`.
function InkAwayView:pickFile(path, on_pick, accept, icon, empty, title)
    if accept ~= isPicture then return self:browseKoreaderFiles(path, on_pick, accept, title) end
    self:browseFiles{ start = path, on_pick = on_pick, accept = accept, file_icon = icon,
        empty = empty or _("No files or folders here.") }
end

-- Let the reader pick a folder, starting in `path`.
function InkAwayView:pickFolder(path, on_pick)
    self:browseFiles{ start = path, on_pick = on_pick, folders = true, empty = _("No folders in here.") }
end

-- Run fn(), asking first when a file at `path` would be replaced.
function InkAwayView:confirmReplace(path, fn)
    if not Storage.exists(path) then fn(); return end
    self:ask{ title = _("Replace it?"),
        text = string.format(_("\u{201C}%s\u{201D} already exists. Replace it?"), Storage.baseName(path)),
        ok_text = _("Replace"), on_ok = fn }
end

return InkAwayView
