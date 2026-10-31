-- Presentation only: `Reader.infoFields` gathers every field.

local ButtonDialog   = require("ui/widget/buttondialog")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Screen         = require("device").screen
local Size           = require("ui/size")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local _              = require("gettext")
local T              = require("ffi/util").template

local Info = {}

-- Description cap; ButtonDialog scrolls its buttons, never the title group.
local SUMMARY_LIMIT = 300

-- Total dropped when absent: `Page 12` is true; `Page 12 of 0` is not.
local function pageLine(page, total)
    if not page then
        return nil
    end
    if total then
        return T(_("Page %1 of %2"), page, total)
    end
    return T(_("Page %1"), page)
end

-- Trimmed and run-collapsed: a padded title would draw as an empty row.
-- A newline would break the row in the one TextBoxWidget.
local function plainText(value)
    if type(value) == "number" then
        value = tostring(value)
    end
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

-- Nil is ordinary (no author, no server); the caller drops the row entirely.
local function metaLine(label, value)
    local text = plainText(value)
    if not text then
        return nil
    end
    return T(_("%1: %2"), label, text)
end

-- The metadata rows, in the order they are read.
local function metaLines(fields)
    local lines = {}
    local function add(label, value)
        local text = metaLine(label, value)
        if text then
            lines[#lines + 1] = text
        end
    end
    add(_("Series"), fields.series)
    add(_("Volume"), fields.volume)
    add(_("Author"), fields.authors)
    add(_("Language"), fields.language)
    add(_("Server"), fields.server)
    -- Only where it says more than the server row: the caller decides that.
    add(_("Catalog"), fields.catalog)
    return lines
end

-- Cut back to a UTF-8 lead byte; half a character draws as anything at all.
local function excerpt(text)
    if #text <= SUMMARY_LIMIT then
        return text
    end
    text = text:sub(1, SUMMARY_LIMIT)
    while #text > 0 do
        local byte = text:byte(-1)
        if byte < 128 or byte >= 192 then
            break
        end
        text = text:sub(1, -2)
    end
    return text .. "…"
end

-- The description in KOReader's own TextViewer, over the popup.
local function showDescription(text)
    -- Required lazily: it drags in scroll widgets and an HTML view.
    -- A book without a tapped summary should not pay for those at startup.
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Description"),
        text = text,
        text_type = "book_info",
    })
end

-- A TextBoxWidget takes no events, so this wraps one to claim the tap.
local SummaryItem = InputContainer:extend{}

function SummaryItem:init()
    self[1] = TextBoxWidget:new{
        text = self.text,
        width = self.width,
        face = Font:getFace("smallinfofont"),
    }
    -- Own Geom because `paintTo` writes onto `self.dimen`, the range below.
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function SummaryItem:onTap()
    if self.tap_callback then
        self.tap_callback()
    end
    return true
end

-- The popup, or nil when there is nothing to show one for.
function Info.show(fields)
    if type(fields) ~= "table" then
        return nil
    end

    local page, total = tonumber(fields.page), tonumber(fields.total)
    if page then
        page = math.floor(page)
    end
    if total then
        total = math.floor(total)
    end
    -- Bar and percentage need both numbers and a non-zero total.
    local measured = page and total and total > 0
    local percent = measured and math.min(1, math.max(0, page / total)) or 0

    -- Declared first: both rows close the dialog they are buttons of.
    local dialog
    -- Offered only when handed one: a local book has no catalog to show.
    local buttons = {}
    if type(fields.show_in_opds) == "function" then
        buttons[#buttons + 1] = {
            {
                text = _("Show in OPDS"),
                callback = function()
                    UIManager:close(dialog)
                    fields.show_in_opds()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Close"),
            callback = function() UIManager:close(dialog) end,
        },
    }

    dialog = ButtonDialog:new{
        -- No derivable title: the header says what the popup is, not the book.
        title = (type(fields.title) == "string" and fields.title ~= "")
            and fields.title or _("Book info"),
        buttons = buttons,
    }

    -- Width from the dialog: the same answer its own title is wrapped to.
    local width = dialog:getAddedWidgetAvailableWidth()
    local body = VerticalGroup:new{ align = "left" }

    local current_line = pageLine(page, total)
    if current_line then
        table.insert(body, TextBoxWidget:new{
            text = current_line,
            width = width,
            face = Font:getFace("infofont"),
            alignment = "center",
        })
    end

    -- Without both numbers there is no bar, rather than an invented "0 %".
    if measured then
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, ProgressWidget:new{
            width = width,
            height = Screen:scaleBySize(10),
            percentage = percent,
        })
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, TextBoxWidget:new{
            text = T(_("%1 %"), math.floor(percent * 100 + 0.5)),
            width = width,
            face = Font:getFace("smallinfofont"),
            alignment = "center",
        })
    end

    local lines = metaLines(fields)
    if #lines > 0 then
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, TextBoxWidget:new{
            text = table.concat(lines, "\n"),
            width = width,
            face = Font:getFace("smallinfofont"),
        })
    end

    -- Description last, collapsed like the rows above: ComicInfo is free text.
    local description = plainText(fields.description)
    if description then
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, SummaryItem:new{
            text = excerpt(description),
            width = width,
            tap_callback = function() showDescription(description) end,
        })
    end

    -- `parent` stops a second reinit from freeing this group.
    -- `not_focusable` keeps the D-pad off text that is not a button.
    body.parent = dialog
    body.not_focusable = true
    dialog:addWidget(body)

    UIManager:show(dialog)
    return dialog
end

return Info
