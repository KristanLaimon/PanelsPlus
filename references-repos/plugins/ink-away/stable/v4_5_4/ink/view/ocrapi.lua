-- Optional external recognition. Settings belong to KOReader, never a notebook.
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen
local _ = require("ink/l10n")
local InkAwayView = {}
local SETTING = "inkaway_ocr_api"
local function vspan(h) return VerticalSpan:new{ width = Screen:scaleBySize(h) } end

function InkAwayView:ocrApiConfig()
    local saved = self:getSetting(SETTING)
    if type(saved) ~= "table" then saved = {} end
    local config = { enabled = saved.enabled == true }
    for _, key in ipairs({ "url", "key", "model" }) do
        config[key] = type(saved[key]) == "string" and saved[key] or ""
    end
    return config
end

-- The Text sheet's rows for it: a switch, then, when on, a note on what is sent
-- and a button for each of the URL, key and model. The key is never shown.
function InkAwayView:addOcrApiRows(add, menu, width)
    local ToggleRow = require("ink/ui/controls").ToggleRow
    local config = self:ocrApiConfig()
    add(ToggleRow:new{ label = _("Convert to text online"), is_on = config.enabled,
        width = width, parent = menu,
        callback = function(on)
            config.enabled = on
            self:setSetting(SETTING, config)
            self:openTextSettings()
        end })
    if not config.enabled then
        add(self:sheetHint(_("Read handwriting with an AI service you have an account with, instead of on the reader."), width))
        return
    end
    local missing = config.url == "" or config.key == "" or config.model == ""
    add(self:sheetHint(missing
        and _("Experimental. Convert to text sends a picture of the lassoed writing to your AI service and puts back the text it reads. Set the three below from your service's account and documentation, then lasso some writing and choose Convert to text, with Wi-Fi on.")
        or _("Experimental. Convert to text sends a picture of the lassoed writing to the service below and puts back the text it reads. Wi-Fi has to be on."), width))
    add(vspan(4))
    add(self:sheetHint(_("Only the lassoed writing is sent. The key is kept unencrypted in KOReader's settings."), width))
    for _i, field in ipairs({
            { "url", _("Address"), _("Set the address"), "https://api.openai.com/v1",
                _("Your service's API address, from its documentation. It has to start with https://, for example https://api.openai.com/v1 or https://openrouter.ai/api/v1.") },
            { "key", _("Key"), _("Set the key"), "",
                _("The API key from your account on the service, usually under API keys. It is only sent to the address above.") },
            { "model", _("Model"), _("Set the model"), "gpt-4o-mini",
                _("The name of one of the service's models that can read pictures, as its model list writes it, for example gpt-4o-mini or paddleocr-vl.") } }) do
        local key, label, unset, hint, about = field[1], field[2], field[3], field[4], field[5]
        local value = config[key]
        local text
        if value == "" then text = unset
        elseif key == "key" then text = label .. ": ********"
        else text = label .. ": " .. value end
        add(vspan(8))
        add(self:actionButton(text, width, function()
            self:closeSheet("_text_settings")
            self:promptText{ field = "_ocr_config", title = label, input = config[key], hint = hint,
                description = about,
                text_type = key == "key" and "password" or nil, ok_text = _("Save"),
                on_cancel = function() self:openTextSettings() end,
                on_ok = function(typed)
                    config[key] = typed and typed:match("^%s*(.-)%s*$") or ""
                    self:setSetting(SETTING, config)
                    self:openTextSettings()
                end }
        end, value == "" and missing))
    end
end

function InkAwayView:hwrContext()
    return { canvas = self.canvas, revision = self.canvas.rev, doc = self.doc_path,
        notebook = self.notebook, page = self._shown_page, index = self.notebook and self.notebook.index,
        book = self.book, book_page = self.book and self.book:currentPage() }
end

function InkAwayView:hwrContextCurrent(context)
    return not self.closing and self.canvas == context.canvas and self.canvas.rev == context.revision
        and self.doc_path == context.doc and self.notebook == context.notebook and self._shown_page == context.page
        and (self.notebook and self.notebook.index) == context.index and self.book == context.book
        and (self.book and self.book:currentPage()) == context.book_page
end

function InkAwayView:hwrSelectionCurrent(ops)
    if not self.selection then return false end
    local current = select(2, self:writingOf(self.selection.idxs))
    if #current ~= #ops then return false end
    for i, op in ipairs(ops) do if current[i] ~= op then return false end end
    return true
end

function InkAwayView:cancelOcrApi()
    if self._ocr_cancel then self._ocr_cancel(); self._ocr_cancel = nil end
    if self._ocr_progress then self._ocr_progress.close(); self._ocr_progress = nil end
    self:closeSheet("_hwr_review")
    self:closeSheet("_ocr_config")
end

function InkAwayView:convertSelectionWithApi(strokes, ops)
    local Api = require("ink/ocr/api")
    local saved = self:ocrApiConfig()
    local config = Api.validate(saved)
    if not config then
        -- the Text sheet, with this on top saying what to set there
        self:openTextSettings()
        self:tell((saved.url == "" or saved.key == "" or saved.model == "")
            and _("Convert to text online needs your service's address, key and model. Set them in the Text sheet, or switch it off there to read on the reader.")
            or _("Check the address in the Text sheet: it has to be a full address starting with https://."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then self:tell(_("Turn on Wi-Fi to convert online.")); return end
    local context = self:hwrContext()
    local Image = require("ink/ocr/image")
    local snapshot, err = Image.snapshot(self.canvas, ops)
    if not snapshot then self:tell(err); return end
    local Job = require("ink/ocr/job")
    local cancel
    cancel, err = Job.start(function()
        local png, why = Image.png(snapshot)
        if not png then return nil, why end
        return Api.request(config, png)
    end, function(text, why)
        self._ocr_cancel = nil
        if self._ocr_progress then self._ocr_progress.close(); self._ocr_progress = nil end
        if not self:hwrContextCurrent(context) then return end
        if not text then self:tell(why); return end
        local reviewed = pcall(self.reviewWriting, self, text, strokes, ops, context)
        if not reviewed then
            self:cancelOcrApi()
            self:tell(_("The recognition preview could not be opened. Your handwriting was kept."))
        end
    end)
    if not cancel then self:tell(err); return end
    self._ocr_cancel = cancel
    self._ocr_progress = self:showProgress{ field = "_ocr_progress_sheet", title = _("Reading the writing"),
        note = _("External OCR. Stop discards the result; the request may still finish at the provider."),
        on_stop = function() self:cancelOcrApi() end }
end

return InkAwayView
