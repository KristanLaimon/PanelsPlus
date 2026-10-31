-- Reader-side graft for one Meguru book; see docs/menus-and-lifecycle.md.

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local KoptOptions = require("ui/data/koptoptions")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
local C_ = _.pgettext
local ffiutil = require("ffi/util")
local T = ffiutil.template

local Base = require("meguru/driver/base")
local Derainbow = require("meguru/derainbow")
local Feed = require("meguru/feed")
local Icons = require("meguru/icons")
local Defaults = require("meguru/doc/defaults")
local Image = require("meguru/doc/image")
local Catalog = require("meguru/ui/catalog")
local Info = require("meguru/ui/info")
local Local = require("meguru/local")
local Open = require("meguru/ui/open")
local Panel = require("meguru/panel")
local PanelZoom = require("meguru/ui/panelzoom")
local Progress = require("meguru/progress")
local Settings = require("meguru/settings")

local Reader = {}

-- Monotonic ms: os.clock would report CPU time, not the real wait.
local function nowMs()
    local secs, usecs = ffiutil.gettime()
    return secs * 1000 + usecs / 1000
end

-- Off / clockwise / counter-clockwise, as stored in `kopt_rotate_wide_pages`.
local ROTATE_OFF, ROTATE_RIGHT, ROTATE_LEFT = 0, 1, 2

-- Module level: a rotation a previous book left active outlives that ReaderUI.
local session_wide_rotate = {}


-- Current KOReader hangs the footer off ReaderView; older builds off ReaderUI.
local function getStatusBarFooter(ui)
    if not ui then
        return nil
    end
    local view = ui.view
    if view and view.footer then
        return view.footer
    end
    return ui.footer
end

-- Reclaim the bar: applyFooterMode skips it if the flag was already flipped.
local function hideStatusBar(footer)
    if not (footer and footer.mode_list and footer.view) then
        return
    end
    local was_visible = footer.view.footer_visible
    if type(footer.applyFooterMode) == "function" then
        footer:applyFooterMode(footer.mode_list.off)
    else
        footer.mode = footer.mode_list.off
        footer.view.footer_visible = false
    end
    if was_visible ~= nil and footer.view.footer_visible == was_visible then
        if type(footer.updateFooterContainer) == "function" then
            footer:updateFooterContainer()
        end
        if type(footer.resetLayout) == "function" then
            footer:resetLayout(true)
        end
        footer.visibility_change = true
    end
    if type(footer.onUpdateFooter) == "function" then
        footer:onUpdateFooter(true, true)
    end
end

-- Explicit show must always show: fall back to page progress, not "off".
local function showStatusBar(footer)
    if not (footer and footer.mode_list and footer.view) then
        return
    end
    local g = rawget(_G, "G_reader_settings")
    local mode = g and type(g.readSetting) == "function"
        and g:readSetting("reader_footer_mode")
    if mode == nil or mode == footer.mode_list.off then
        mode = footer.mode_list.page_progress
    end
    if type(footer.applyFooterMode) == "function" then
        footer:applyFooterMode(mode)
    else
        footer.mode = mode
        footer.view.footer_visible = mode ~= footer.mode_list.off
    end
    if type(footer.onUpdateFooter) == "function" then
        footer:onUpdateFooter(true, true)
    end
end

-- Once per process, on the class: ReaderZooming keeps a page number of its own,
-- and the asks that reach the document before ReaderPaging restores one come from
-- there. Seeded at init because ReadSettings runs its handlers in module order and
-- the KOPT listener's is ahead of this module's own.
local zoom_page_hook_installed = false

function Reader.installZoomPageHook()
    if zoom_page_hook_installed then
        return
    end
    local ok, ReaderZooming = pcall(require, "apps/reader/modules/readerzooming")
    if not ok or type(ReaderZooming) ~= "table"
        or type(ReaderZooming.init) ~= "function" then
        -- Deliberately left false so a later host can retry.
        return
    end
    zoom_page_hook_installed = true
    local orig = ReaderZooming.init
    ReaderZooming.init = function(self, ...)
        orig(self, ...)
        local ui = self.ui
        local doc = ui and ui.document
        local config = ui and ui.doc_settings
        local page = config and type(config.readSetting) == "function"
            and config:readSetting("last_page") or nil
        -- Only a Meguru book, and only a real resume: 1 and nil are its default
        -- already, and a stock document's page is stock's own business.
        if doc and doc.provider == "meguru" and page and page > 1 then
            logger.dbg("Meguru: zoom starts at page", page)
            self.current_page = page
        end
    end
end

-- Once per process: the hook is on the ReaderFooter class, not an instance.
local status_bar_hook_installed = false

function Reader.installStatusBarHook()
    if status_bar_hook_installed then
        return
    end
    local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
    if not ok or type(ReaderFooter) ~= "table"
        or type(ReaderFooter.onReaderReady) ~= "function" then
        -- Deliberately left false so a later host can retry.
        return
    end
    status_bar_hook_installed = true
    local orig = ReaderFooter.onReaderReady
    ReaderFooter.onReaderReady = function(self, ...)
        orig(self, ...)
        local doc = self.ui and self.ui.document
        -- Only Meguru documents, and only when asked: a PDF opens as stock.
        if not (doc and doc.provider == "meguru") then
            return
        end
        if not Settings.get("hide_status_bar") then
            return
        end
        -- pcall keeps a build-specific footer quirk from ever costing the open.
        pcall(hideStatusBar, self)
    end
end


local function wideRotateIsLeft(value)
    return value == ROTATE_LEFT or value == tostring(ROTATE_LEFT)
end

-- Rotation modes are quarters, so this is modular arithmetic on 0..3.
local function wideRotateTarget(base, left)
    return left and (base + 3) % 4 or (base + 1) % 4
end

-- ReaderUI has no getCurrentPage; paging holds it, absent if reflowed.
-- The paging module's own page, or the one the open is about to restore: before
-- ReadSettings its current_page is still 0, and a crop of page 0 is nothing.
local function currentPage(ui)
    local page = ui.paging and ui.paging.current_page
    if page and page > 0 then
        return page
    end
    local config = ui.doc_settings
    return config and config:readSetting("last_page") or nil
end

-- Asked live, so a reader turning the device to the same mode takes it over.
local function publishScreenRotation(ui)
    local doc = ui and ui.document
    local state = ui and ui._meguru_rotate_state
    if not (doc and type(doc.spreadActive) == "function") then
        return
    end
    doc.spread_rotated_by_plugin = state ~= nil and state.active ~= nil
        and Screen:getRotationMode() == state.active
end

-- Only a rotation or the row changes the answer; a page turn re-reads it live.
local function syncSpread(ui)
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru"
        and type(doc.spreadActive) == "function") then
        return
    end
    publishScreenRotation(ui)
    local active = doc:spreadActive() and true or false

    -- Warm even if nothing changed: the layout pass would fetch mid-paint.
    local warmed = active and doc:prepareSpread(currentPage(ui)) or false

    local changed = active ~= (ui._meguru_spread_active or false)
    if not (changed or warmed) then
        return
    end
    ui._meguru_spread_active = active
    -- Warm with no change: the pair became possible, so the old box must go.
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if changed then
        logger.dbg("Meguru: two-page view", active and "on" or "off")
    end
end

-- A parity change is real geometry; same parity is re-orientation in place.
local function rotateTo(ui, mode)
    local cur = Screen:getRotationMode()
    if mode == cur then
        return
    end
    Screen:setRotationMode(mode)
    UIManager:setDirty(nil, "full")
    if (mode % 2) ~= (cur % 2) and ui then
        local new_size = Screen:getSize()
        ui:handleEvent(Event:new("SetDimensions", new_size))
        if ui.onScreenResize then
            ui:onScreenResize(new_size)
        end
        ui:handleEvent(Event:new("InitScrollPageStates"))
    end
    -- A rotation starts or stops the pair, so the box must be re-derived.
    syncSpread(ui)
    logger.dbg("Meguru: wide page, screen rotation", cur, "->", mode)
end

-- Only restore while still on our mode; never fight the reader's own rotation.
local function restoreWideRotate(state, ui)
    local base, active = state.base, state.active
    state.base, state.active = nil, nil
    if base ~= nil and Screen:getRotationMode() == active then
        rotateTo(ui, base)
    end
end

-- Base captured lazily, so the reader's own rotation is inherited, not fought.
local function updatePageRotation(state, ui, page)
    local document = ui and ui.document
    local view = ui and ui.view
    local configurable = document and document.configurable
    if not (view and configurable and document.pageIsWide) then
        return
    end
        -- A flip or scroll means the page number is not settled yet.
    if view.flipping_visible or view.page_scroll then
        return
    end
    if view.state and view.state.page ~= nil and view.state.page ~= page then
        return
    end
    -- While a pair shows this does nothing: any turn or undo would flip-flop.
    if type(document.spreadActive) == "function" and document:spreadActive() then
        return
    end

    local value = configurable.rotate_wide_pages
    local enabled = configurable.text_wrap ~= 1
        and (value == ROTATE_RIGHT or value == ROTATE_LEFT
            or value == tostring(ROTATE_RIGHT) or value == tostring(ROTATE_LEFT))
    if not enabled or type(page) ~= "number" then
        restoreWideRotate(state, ui)
        return
    end

    -- pageIsWide, not getNativePageDimensions: a pair is wide by construction.
    if not document:pageIsWide(page) then
        restoreWideRotate(state, ui)
        return
    end

    local cur = Screen:getRotationMode()
    local left = wideRotateIsLeft(value)
    if cur % 2 == 1 then
        -- Already turned: reconcile against what this page expects instead.
        if state.active == cur then
            local expected = wideRotateTarget(state.base, left)
            if expected ~= cur then
                state.active = expected
                session_wide_rotate.base, session_wide_rotate.active = state.base, expected
                rotateTo(ui, expected)
            end
        else
            state.base, state.active = nil, nil
            session_wide_rotate.base, session_wide_rotate.active = nil, nil
        end
        return
    end

    if state.base == nil then
        state.base = cur
    end
    local target = wideRotateTarget(cur, left)
    state.active = target
    session_wide_rotate.base, session_wide_rotate.active = state.base, target
    if target ~= cur then
        rotateTo(ui, target)
    end
end

-- Keep a leftover rotation only if the page this book opens on wants it.
local function reconcileWideRotation(state, ui)
    local base, active = session_wide_rotate.base, session_wide_rotate.active
    session_wide_rotate.base, session_wide_rotate.active = nil, nil
    if base == nil or Screen:getRotationMode() ~= active then
        return
    end

    local document = ui and ui.document
    local view = ui and ui.view
    local configurable = document and document.configurable
    local page = ui and ui.paging and ui.paging.current_page
    local keep = false
    if document and configurable and page and view and not view.page_scroll then
        local value = configurable.rotate_wide_pages
        local enabled = configurable.text_wrap ~= 1
            and (value == ROTATE_RIGHT or value == ROTATE_LEFT
                or value == tostring(ROTATE_RIGHT) or value == tostring(ROTATE_LEFT))
        if enabled and type(document.pageIsWide) == "function" then
            keep = document:pageIsWide(page)
        end
    end
    if keep then
        state.base, state.active = base, active
    else
        pcall(rotateTo, ui, base)
    end
end

-- Installed once per ReaderUI so the two seams cannot double-wrap.
local function installWideRotate(state, ui)
    local paging, view = ui.paging, ui.view
    if not (paging and view) then
        return
    end
    if not paging._meguru_wide_rotate_patched then
        paging._meguru_wide_rotate_patched = true
        local orig = paging.onPageUpdate
        paging.onPageUpdate = function(pg, new_page, orig_mode)
            local ret = orig(pg, new_page, orig_mode)
            -- Only page turns carry a page; continuous scroll is handled below.
            if orig_mode ~= "scrolling" then
                updatePageRotation(state, ui, new_page)
            end
            return ret
        end
    end
    if not view._meguru_wide_rotate_view_patched then
        view._meguru_wide_rotate_view_patched = true
        local orig = view.onSetScrollMode
        view.onSetScrollMode = function(vw, page_scroll)
            local ret = orig(vw, page_scroll)
            local this_paging = ui.paging
            if not this_paging then
                return ret
            end
            if page_scroll then
                -- Rotation is per-page and meaningless while scrolling.
                restoreWideRotate(state, ui)
            else
                updatePageRotation(state, ui, this_paging.current_page)
            end
            return ret
        end
    end
end

-- Passes the target through spreadSnap so one gesture turns a whole spread.
local function installSpread(ui)
    local paging, view = ui and ui.paging, ui and ui.view
    if not (paging and view) then
        return false
    end
    if ui._meguru_spread_installed then
        return true
    end
    ui._meguru_spread_installed = true

    if not paging._meguru_spread_patched then
        paging._meguru_spread_patched = true

        -- Marks the two callers that mean a turn; everything else is a landing.
        -- pcall + re-raise so a throw cannot leave the turn mark set.
        local function marked(orig)
            return function(pg, ...)
                paging._meguru_spread_turn = true
                local ok, a, b = pcall(orig, pg, ...)
                paging._meguru_spread_turn = nil
                if not ok then
                    error(a, 0)
                end
                return a, b
            end
        end
        if type(paging.onGotoPageRel) == "function" then
            paging.onGotoPageRel = marked(paging.onGotoPageRel)
        end
        if type(paging.pageFlipping) == "function" then
            paging.pageFlipping = marked(paging.pageFlipping)
        end

        local orig_goto = paging._gotoPage
        paging._gotoPage = function(pg, number, orig_mode)
            local doc = ui.document
            if number ~= nil and doc and type(doc.spreadSnap) == "function" then
                -- Consumed here, so nothing later can read a stale mark.
                local turn = paging._meguru_spread_turn
                paging._meguru_spread_turn = nil
                local target, finished = doc:spreadSnap(number, pg.current_page, turn)
                if finished then
                    -- The last unit is a pair: nothing else announces the end.
                    ui:handleEvent(Event:new("EndOfBook"))
                    return true
                end
                if target ~= nil then
                    number = target
                    -- Warm before layout; a fetch there would freeze paint.
                    if type(doc.prepareSpread) == "function" then
                        doc:prepareSpread(number)
                    end
                end
            end
            return orig_goto(pg, number, orig_mode)
        end
    end

    if not view._meguru_spread_rotate_patched and type(view.rotate) == "function" then
        view._meguru_spread_rotate_patched = true
        local orig_rotate = view.rotate
        view.rotate = function(vw, ...)
            local ret = orig_rotate(vw, ...)
            syncSpread(ui)
            return ret
        end
    end

    -- Continuous scroll switches the pair off, so re-derive on the way out.
    if not view._meguru_spread_scroll_patched
        and type(view.onSetScrollMode) == "function" then
        view._meguru_spread_scroll_patched = true
        local orig_scroll = view.onSetScrollMode
        view.onSetScrollMode = function(vw, page_scroll)
            local ret = orig_scroll(vw, page_scroll)
            syncSpread(ui)
            return ret
        end
    end

    -- First look is at ReaderReady; ReadSettings has not run at this point.
    return true
end

-- Writes the live configurable and the sidecar; domain is off/auto/on.
local function setSpread(ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread ~= nil) then
        return false
    end
    configurable.spread = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread", value)
        ui.doc_settings:flush()
    end
    syncSpread(ui)
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

-- Repaint is the whole cost: the filter runs on the tile, not the decode.
local function setDerainbow(ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.derainbow ~= nil) then
        return false
    end
    -- `0` is truthy, so normalise a bool or string before storing.
    value = (value == 1 or value == "1" or value == true) and 1 or 0
    configurable.derainbow = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_derainbow", value)
        ui.doc_settings:flush()
    end
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

-- One function so the gesture and the row cannot describe it differently.
local function spreadOffsetNotice(on)
    return on and _("Pair offset: from here") or _("Pair offset: off")
end

-- Value is the anchor page (0 = off); the rule itself lives in meguru/spread.
local function setSpreadOffset(ui, anchor, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread_offset ~= nil) then
        return false
    end
    configurable.spread_offset = anchor
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread_offset", anchor)
        ui.doc_settings:flush()
    end
    -- Pairing from another page changes the unit; lay the page out again.
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

-- Decides whether Spread.gutter is asked, so the pair's box changes shape.
local function setSpreadGutter(ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread_gutter ~= nil) then
        return false
    end
    configurable.spread_gutter = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread_gutter", value)
        ui.doc_settings:flush()
    end
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

-- Writes the value, then re-evaluates the current page for the new rotation.
local function setWideRotate(state, ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.rotate_wide_pages ~= nil) then
        return false
    end
    configurable.rotate_wide_pages = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_rotate_wide_pages", value)
    end
    updatePageRotation(state, ui, currentPage(ui))
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end


-- Whether mode is one of the three views; off is not a view.
-- panelViewMode: the book's answer, seeded from the plugin-wide preference.
local function panelViewIsView(mode)
    return mode == "crop" or mode == "window" or mode == "zoom"
end

function Reader.panelViewMode(ui)
    local configurable = ui and ui.document and ui.document.configurable
    local mode = configurable and configurable.panel_view
    if panelViewIsView(mode) then
        return mode
    end
    local seeded = Settings.get("panel_view")
    if panelViewIsView(seeded) then
        return seeded
    end
    -- Unknown value; fall back to the default Settings.DEFAULTS.panel_view.
    return "window"
end

-- ui.view.inverse_reading_order is the resolved value a page turn obeys.
function Reader.panelZoomMode(ui)
    local view = ui and ui.view
    if view and view.inverse_reading_order ~= nil then
        return view.inverse_reading_order and "manga" or "comic"
    end
    local configurable = ui and ui.document and ui.document.configurable
    if configurable and configurable.opdsbook_manga ~= nil then
        return configurable.opdsbook_manga == 1 and "manga" or "comic"
    end
    return Settings.get("manga_order") and "manga" or "comic"
end

-- configurable, never the preference: the preference is only the floor.
function Reader.panelZoomDirection(ui)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.rotate_wide_pages ~= nil) then
        return nil
    end
-- The row's domain is 0/1/2, but a stored value can be the string form.
    local value = configurable.rotate_wide_pages
    if wideRotateIsLeft(value) then
        return "left"
    end
    if value == ROTATE_RIGHT or value == tostring(ROTATE_RIGHT) then
        return "right"
    end
    return nil
end

-- Read off the class, never the instance: rivals overwrite the instance field.
local function nativePanelZoom()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok and type(ReaderHighlight) == "table"
        and type(ReaderHighlight.onPanelZoom) == "function" then
        return ReaderHighlight.onPanelZoom
    end
    return nil
end

-- The file's own answer; the live field may be a rival plugin's by now.
local function meguruPanelZoomWanted(hl)
    if hl._meguru_panel_zoom_pinned then
        return hl._meguru_panel_zoom_answer == true
    end
    return true
end

-- Shared by both wrappers; fallback is stock's handler, never a rival's.
local function meguruPanelZoom(self, arg, ges, fallback)
    local ui = self.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru"
        and type(doc.getPanelsFromPage) == "function") then
        fallback(self, arg, ges)
    end
    self:clear()
    local view = ui.view
    local pos = view and type(view.screenToPageTransform) == "function"
        and view:screenToPageTransform(ges.pos)
-- page as well as the point: the document would fetch page nil, a socket call.
    if not (pos and pos.page) then
        fallback(self, arg, ges)
    end
-- The press belongs to the page under the finger; map the pair point onto it.
    if pos and type(doc.spreadPageAt) == "function" then
        pos.page, pos.x, pos.y = doc:spreadPageAt(pos.page, pos.x, pos.y)
    end

    local mode = Reader.panelZoomMode(ui)
-- Resolved per press: the row can change with the viewer closed.
    local direction = Reader.panelZoomDirection(ui)
    local t_start = nowMs()
-- The free view asks no detector: it walks no steps; getPageDims is the fetch.
    if Reader.panelViewMode(ui) == "zoom" then
        local ok_dims, dims = pcall(doc.getPageDims, doc, pos.page)
        if not ok_dims or not dims then
            logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
                .. tostring(dims) .. ")")
            fallback(self, arg, ges)
        end
        logger.dbg(string.format(
            "Meguru: page %d panel zoom: free view (%s) in %d ms",
            pos.page, mode, nowMs() - t_start))
        local ok_free, shown_free = pcall(PanelZoom.open, ui, pos.page, nil, nil,
            mode, direction, {
                free = true,
                tap = { x = pos.x, y = pos.y },
                level = Settings.get("panel_zoom_level"),
            })
        if not ok_free or not shown_free then
            logger.warn("Meguru: panel zoom viewer failed:",
                ok_free and "not shown" or tostring(shown_free))
            fallback(self, arg, ges)
        end
        return
    end
-- Four return values: a missing slot shifts accepted into reason, not fails.
    local ok_detect, panels, accepted, reason = pcall(doc.getPanelsFromPage,
        doc, pos.page, mode)
    if not ok_detect then
        logger.warn("Meguru: panel zoom detection failed:", panels)
        fallback(self, arg, ges)
    end
    if not panels then
        -- nil panels means exactly one thing: the page would not decode.
        logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
            .. tostring(reason) .. ")")
        fallback(self, arg, ges)
    end
    -- The count cannot tell a real sequence from the whole-page fallback.
    logger.dbg(string.format(
        "Meguru: page %d panel zoom: %d panels%s (%s) in %d ms",
        pos.page, #panels,
        accepted and "" or (", whole page (" .. tostring(reason) .. ")"),
        mode, nowMs() - t_start))

    local start = Panel.indexAt(panels, pos.x, pos.y) or 1
    -- A refused page is shown cropped; window would cut it into two steps.
    local opts = {
        window = Reader.panelViewMode(ui) == "window" and accepted == true,
        -- In page coordinates: the window view opens centred on the finger.
        tap = { x = pos.x, y = pos.y },
        -- Multiple of the page width on screen; the store is the preference.
        level = Settings.get("panel_zoom_level"),
    }
    local ok_show, shown = pcall(PanelZoom.open, ui, pos.page, panels, start,
        mode, direction, opts)
    if not ok_show or not shown then
        logger.warn("Meguru: panel zoom viewer failed:",
            ok_show and "not shown" or tostring(shown))
        fallback(self, arg, ges)
    end
    return true
end

-- Tells yes only at stock's per-extension level; the per-file row is stock's.
local function installPanelZoom(ui)
    local hl = ui and ui.highlight
    if not (hl and ui.paging) then
        return false
    end
    if hl._meguru_panel_zoom_installed then
        return true
    end
    hl._meguru_panel_zoom_installed = true

    -- `config` is named: the cascade turns on `config:has()`.
    local orig_read = hl.onReadSettings
    hl.onReadSettings = function(self, config, ...)
        if type(orig_read) == "function" then
            orig_read(self, config, ...)
        end
        -- own: did this file answer for itself? Stock has just said so.
        local own = type(config) == "table" and type(config.has) == "function"
            and config:has("panel_zoom_enabled")
        -- Remembered for onSaveSettings, which asks whether a copy may be kept.
        self._meguru_panel_zoom_pinned = own and true or false
        -- The file's own answer, stashed: a rival overwrites the live field.
        if own then
            self._meguru_panel_zoom_answer = self.panel_zoom_enabled == true
        else
            self._meguru_panel_zoom_answer = nil
        end
        -- Written unconditionally: a rival pins it after every ReadSettings.
        if not own then
            -- Stock has no entry for these; unanswered files get yes.
            self.panel_zoom_enabled = true
        end
        -- No text on a streamed page: the fallback hits getImageFromPosition.
        self.panel_zoom_fallback_to_text_selection = false
    end

    -- The stock row flips the live field: the reader answering for this file.
    local orig_toggle = hl.onTogglePanelZoomSetting
    hl.onTogglePanelZoomSetting = function(self, ...)
        if type(orig_toggle) == "function" then
            orig_toggle(self, ...)
        end
        self._meguru_panel_zoom_pinned = true
        -- Mid-session answer; the stash above still holds the opening answer.
        self._meguru_panel_zoom_answer = self.panel_zoom_enabled
    end

    -- Delete the sidecar copy unless this file answered, or it pins forever.
    local orig_save = hl.onSaveSettings
    hl.onSaveSettings = function(self, ...)
        if type(orig_save) == "function" then
            orig_save(self, ...)
        end
        if not self._meguru_panel_zoom_pinned then
            local ds = self.ui and self.ui.doc_settings
            if ds and type(ds.delSetting) == "function" then
                ds:delSetting("panel_zoom_enabled")
            end
        end
    end

    -- Shows the sequence, falling back to stock's one-region viewer.
    local function press(self, arg, ges)
        if not meguruPanelZoomWanted(self) then
            -- false, not stock: the reader turned panel zoom off for this file.
            return false
        end
        local native = nativePanelZoom()
        if native == nil then
            -- No native handler to fall back to: doing nothing is honest.
            return false
        end
        return meguruPanelZoom(self, arg, ges, native)
    end
    hl.onPanelZoom = press
    -- Identity only: a rival patching later replaces this field with its own.
    hl._meguru_panel_zoom_press = press

    return true
end

-- The row's second answer while Panels+ owns the hold: on, with no view of ours.
local RIVAL_PANEL_ON = "panelsplus"

-- True while Panels+ sits above our wrapper and will answer the long-press.
function Reader.panelsPlusActive(ui)
    local hl = ui and ui.highlight
    local plugin = ui and ui.panelsplus
    if not (hl and type(plugin) == "table") then
        return false
    end
    -- Our wrapper still outermost: its views are what a reader gets.
    if hl.onPanelZoom == hl._meguru_panel_zoom_press then
        return false
    end
    local ok_enabled, enabled = pcall(function() return plugin:isEnabled() end)
    if not ok_enabled or not enabled then
        return false
    end
    local ok_hold, on_hold = pcall(function() return plugin:opensOnHold() end)
    return not ok_hold or on_hold ~= false
end

-- Panels+'s wrapper asks this field per press; nil hands the press back to us.
local function setPanelsPlusYield(ui, yielded)
    local hl = ui and ui.highlight
    local plugin = ui and ui.panelsplus
    if not (hl and plugin) then
        return
    end
    hl._meguru_panels_plus_yield = yielded and true or false
    if yielded then
        hl._panels_plus_plugin = nil
    else
        hl._panels_plus_plugin = plugin
    end
end

-- Panels+ forces panel zoom back on while reading settings; the file wins.
-- The owner decides whether the press is ours (yield) or Panels+'s.
function Reader.applyPanelZoomAnswer(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return
    end
    -- Panels+ OCR reads the page through a bitmap seam the document installs.
    if ui.panelsplus and type(doc._installOcr) == "function" then
        doc:_installOcr()
    end
    local hl = ui.highlight
    if hl and hl._meguru_panel_zoom_pinned then
        hl.panel_zoom_enabled = hl._meguru_panel_zoom_answer == true
    end
    local active = Reader.panelsPlusActive(ui)
    ui._meguru_panels_plus_active = active
    if not active then
        return
    end
    local configurable = doc.configurable
    local owner = configurable and configurable.panel_owner
    setPanelsPlusYield(ui, owner == "meguru")
end

-- One sentence per reason: the fixes differ, so a generic one would mislead.
local function pageMessageBody(reason, code, server)
    if reason == "offline" then
        return _("You're offline right now.\nConnect to Wi-Fi and try again.")
    elseif reason == "http" and code then
        return T(_("%1 returned an error (%2).\nTry again in a moment."),
            server, tostring(code))
    elseif reason == "network" then
        return T(_("%1 isn't responding.\nMake sure the server is running, then try again."), server)
    end
    return _("Something went wrong loading this page.\nTry again in a moment.")
end

-- Built from pageMessageBody so the two cannot drift.
local function pageMessageText(reason, code, server)
    return _("Can't load this page") .. "\n\n" .. pageMessageBody(reason, code, server)
end

-- Rebuilt only when the message changes; this runs from a paint.
local function pageMessageWidget(state, key, text, width)
    local cached = state.message
    if cached and cached.key == key and cached.width == width then
        return cached.widget
    end
    local widget = TextBoxWidget:new{
        text = text,
        face = Font:getFace("cfont", 22),
        width = width,
        alignment = "center",
    }
    state.message = { key = key, width = width, widget = widget }
    return widget
end

-- A page turn is the retry: no button, no dialog, just the reason in the page.
local function installPageErrorPage(plugin)
    local ui = plugin.ui
    local doc = ui and ui.document
    if not (doc and type(doc.paintMissingPage) == "function") then
        return false
    end
    -- The painter's state: the laid-out sentence, alive with the document.
    local state = {}

    doc.missing_painter = function(target, rect, x, y, failure)
        local box_w = rect.w or Screen:getWidth()
        local box_h = rect.h or Screen:getHeight()
        local reason = failure and failure.reason
        local code = failure and failure.code
        local server = tostring((doc.desc and doc.desc.server_name) or _("The server"))
        -- A little narrower than the box, so no line ends at the page edge.
        local width = math.max(1, math.floor(box_w * 0.8))
        local widget = pageMessageWidget(state,
            table.concat({ tostring(reason), tostring(code), server }, "|"),
            pageMessageText(reason, code, server), width)
        local size = widget:getSize()
        widget:paintTo(target,
            x + math.floor((box_w - size.w) / 2),
            y + math.floor((box_h - size.h) / 2))
    end

    -- A page turn is the retry; onPageUpdate returns nothing, so it reaches us.
    plugin.onPageUpdate = function(self)
        local d = self.ui and self.ui.document
        if d and type(d.clearFetchFailures) == "function" then
            d:clearFetchFailures()
        end
    end

    -- Connection back: clear failures and repaint; fires once at startup too.
    plugin.onNetworkConnected = function(self)
        local d = self.ui and self.ui.document
        if not (d and type(d.clearFetchFailures) == "function") then
            return
        end
        if d:clearFetchFailures() then
            UIManager:nextTick(function()
                local u = self.ui
                if u and u.dialog then
                    UIManager:setDirty(u.dialog, "full")
                end
            end)
        end
    end

    return true
end


-- Collapses a burst to the newest page; a real delay, or it blocks the paint.
local PROGRESS_DEBOUNCE_S = 1.5

-- Per book: three consecutive failures retire reporting for this book.
local PROGRESS_MAX_FAILURES = 3

-- Nothing below may throw, and nothing below shows the reader anything.
local function reportPending(plugin, st)
    if st.sending or not st.pending then
        return
    end
    local page = st.pending
    if not Progress.moved(st.floor, page) then
        st.pending = nil
        return
    end
    st.sending = true
    -- pcall'd: a throw from a task or event breaks the book, not just a page.
    local ok, sent, reason = pcall(Progress.report, st.file, st.desc, page, st.total)
    st.sending = false
    if not ok then
        logger.warn("Meguru: could not report the position:", tostring(sent))
        return
    end
    if sent then
        -- The floor rises with the server, so the next turn below is a no-op.
        st.floor, st.pending, st.failures = page, nil, 0
        return
    end
    -- Refused: hold the position; off/offline/behind do not trip the breaker.
    if reason ~= "off" and reason ~= "offline" and reason ~= "behind" then
        st.failures = st.failures + 1
    end
end

-- Per book, on the plugin instance; declared after reportPending for st.pump.
local function progressState(plugin)
    local st = plugin._meguru_progress
    if st then
        return st
    end
    local doc = plugin.ui and plugin.ui.document
    if not (doc and doc.provider == "meguru" and type(doc.desc) == "table") then
        return nil
    end
    local total = doc.getPageCount and doc:getPageCount() or doc.desc.count
    total = tonumber(total)
    if not total or total < 1 then
        return nil
    end
    st = {
        file     = doc.file,
        desc     = doc.desc,
        total    = total,
        -- The server's position as the floor, so a report can never go back.
        floor    = Progress.floorFor(doc.desc, total),
        pending  = nil,
        -- The page the flush already tried, so one exit does not pay thrice.
        flushed  = nil,
        sending  = false,
        failures = 0,
    }
    -- One stable reference: unschedule matches by identity, not by closure.
    st.pump = function()
        reportPending(plugin, st)
    end
    plugin._meguru_progress = st
    return st
end

-- A page turn: remember where the reader is and arm the debounce.
local function notePageTurn(plugin, page)
    local st = progressState(plugin)
    if not st or st.failures >= PROGRESS_MAX_FAILURES then
        return
    end
    page = math.floor(tonumber(page) or 0)
    if page < 1 or page == st.pending then
        return
    end
    -- At or below the server's position: no report, so a finished book stays.
    if not Progress.moved(st.floor, page) then
        return
    end
    st.pending = page
    -- The reader moved on, so the closing flush has not tried this page.
    st.flushed = nil
    UIManager:unschedule(st.pump)
    UIManager:scheduleIn(PROGRESS_DEBOUNCE_S, st.pump)
end

-- Reads the page off screen; deduped since one exit reaches three seams.
local function flushProgress(plugin)
    local st = progressState(plugin)
    if not st then
        return
    end
    -- plugin.ui guarded: this path may never throw out of a close event.
    local ui = plugin.ui
    local page = math.floor(tonumber(ui and currentPage(ui)) or 0)
    if Progress.moved(st.floor, page) then
        st.pending = page
    end
    if not st.pending or st.pending == st.flushed then
        return
    end
    st.flushed = st.pending
    -- Also cleanup: a task armed 1.5s ago must not outlive the book.
    UIManager:unschedule(st.pump)
    st.failures = 0
    reportPending(plugin, st)
end


-- One stock KOpt row by name, or nil.
local function stockOptionRow(tab, name)
    for _, option in ipairs(tab and tab.options or {}) do
        if option.name == name then
            return option
        end
    end
    return nil
end

-- Only when pagenumbercrop is absent; values match its row exactly.
local ROTATE_WIDE_ROW = {
    name = "rotate_wide_pages",
    name_text = _("Rotate wide pages"),
    toggle = {
        C_("Rotate wide pages", "off"),
        C_("Rotate wide pages", "left 90°"),
        C_("Rotate wide pages", "right 90°"),
    },
    values = { ROTATE_OFF, ROTATE_LEFT, ROTATE_RIGHT },
    default_value = ROTATE_OFF,
    enabled_func = function(configurable)
        return configurable.text_wrap ~= 1
    end,
    event = "MeguruRotateWideUpdate",
    args = { ROTATE_OFF, ROTATE_LEFT, ROTATE_RIGHT },
    help_text = _([[Automatically rotates the whole view by 90° when the current page is wider than tall (e.g. a double-page spread stored as one big horizontal image), and back when a normal page is shown again.]]),
}

-- Stock's row apart from the presets; the value and event are stock's.
local CONTRAST_ROW = {
    name = "contrast",
    name_text = _("Contrast"),
    buttonprogress = true,
    values = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    args = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    labels = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    default_pos = 2,
    default_value = 1.0,
    event = "GammaUpdate",
    -- Fine-tune spinner; bounds match the presets, not stock's 0.8-50.
    more_options = true,
    more_options_param = {
        value_step = 0.1, value_hold_step = 0.5,
        value_min = 0.8, value_max = 3.0,
        precision = "%.1f",
    },
    help_text = _([[Page tone, applied by the renderer: above 1.0 darkens and hardens the page, below it lifts and flattens it. It applies to panels as well. Long-press this row to set what new Meguru books start at.]]),
}

-- Stock's row and event; args are booleans since 0 is truthy; not advanced.
local DITHERING_ROW = {
    name = "sw_dithering",
    name_text = _("Dithering"),
    toggle = { C_("Dithering", "off"), C_("Dithering", "on") },
    values = { 0, 1 },
    default_value = 0,
    event = "SWDitheringUpdate",
    args = { false, true },
    help_text = _([[Dithers the page into sixteen grey levels as it is written to the screen, which is how a scanned page has been shown here so far. Off writes each pixel flat instead — smoother on a screen whose controller dithers an 8-bit framebuffer itself, banded on one that does not. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
}

-- The row for a screen whose own controller dithers; stock's names, stock's event.
local HW_DITHERING_ROW = {
    name = "hw_dithering",
    name_text = _("Dithering"),
    toggle = { C_("Dithering", "off"), C_("Dithering", "on") },
    values = { 0, 1 },
    -- On where this row is offered: that panel dithers itself, so it is asked to.
    default_value = 1,
    event = "HWDitheringUpdate",
    args = { false, true },
    help_text = _([[Hands the page to the panel's controller to dither itself; on a colour Kobo it is also the flag that promotes the refresh to a colour waveform. On by default on a screen that offers this row, because these pages are dithered for every screen that cannot dither itself. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
}

-- Own event; derainbowify's switch is on KoptOptions, which this never reads.
-- Offered only when the libraries load and pages decode in colour.
local DERAINBOW_ROW = {
    name = "derainbow",
    name_text = _("Derainbow"),
    toggle = { C_("Derainbow", "off"), C_("Derainbow", "on") },
    values = { 0, 1 },
    args = { false, true },
    default_value = 0,
    event = "MeguruDerainbowUpdate",
    help_text = _([[Removes the rainbow shimmer that fine black-and-white artwork picks up on a colour e-ink screen, by filtering the page as it is painted. Needs the filter's native libraries, which ship with the plugin; without them this row is not offered. Costs a moment on each page's first paint. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
}

-- Stock's row and presets unchanged; offered only where pages decode in colour.
local SATURATION_ROW = {
    name = "saturation",
    name_text = _("Saturation"),
    buttonprogress = true,
    values = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    args = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    labels = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    default_pos = 3,
    default_value = 1.0,
    event = "SaturationUpdate",
    more_options = true,
    more_options_param = {
        value_step = 0.1, value_hold_step = 0.2,
        value_min = 0.2, value_max = 2.0,
        precision = "%.1f",
    },
    help_text = _([[Colour intensity of the page: below 1.0 the colours are drained towards grey, above it they are pushed further apart, and 1.0 is the file's own colour. It applies to panels as well. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
}

-- fb_bpp == 8: BB_dither_blit_to dithers an 8-bit destination only, read live.
local function ditheringOffered()
    return Screen ~= nil and Screen.fb_bpp == 8 and Device ~= nil
        and Device:hasEinkScreen() and not Defaults.panelDithers()
end

-- Pulls stock rows live from KoptOptions; keeps what the engine implements.
local function buildCuratedOptions(ui)
-- Stock tabs found by icon; a missing one costs only the rows lifted from it.
    local rotation_tab, pageview_tab
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.rotation" and not rotation_tab then
            rotation_tab = tab
        elseif tab.icon == "appbar.pageview" and not pageview_tab then
            pageview_tab = tab
        end
    end

    local rotation_options = {}
    local rotation_mode = stockOptionRow(rotation_tab, "rotation_mode")
    if rotation_mode then
        rotation_options[#rotation_options + 1] = rotation_mode
    end
    rotation_options[#rotation_options + 1] =
        stockOptionRow(rotation_tab, "rotate_wide_pages") or ROTATE_WIDE_ROW

-- Page: the page's own shape. The picture is the tone tab's business.
    local page_options = {
-- Computed live from the reader's zoom mode, falling back to the preference.
        {
            name = "opdsbook_fit",
            name_text = _("Fit"),
            toggle = {
                C_("Fit mode", "full"),
                C_("Fit mode", "width"),
                C_("Fit mode", "height"),
            },
            values = { "full", "width", "height" },
            args = { "full", "width", "height" },
            default_value = "full",
            event = "MeguruSetFit",
            current_func = function()
                local zooming = ui and ui.zooming
                local mode = zooming and zooming.zoom_mode
                if mode then
                    for fit, zoom_mode in pairs(Defaults.FIT_TO_ZOOM_MODE) do
                        if zoom_mode == mode then
                            return fit
                        end
                    end
                end
                return Settings.get("fit")
            end,
            help_text = _([[How a page is zoomed to the screen: full shows the whole cropped page, width fills the screen width, height fills the screen height.]]),
        },
-- Our own Crop row: stock's define-an-area flow needs a box a stream lacks.
        {
            name = "trim_page",
-- "Crop", not "Page Crop": the tab is already the page's.
            name_text = _("Crop"),
            toggle = { C_("Crop", "none"), C_("Crop", "auto") },
            values = { 3, 1 },
            args = { 3, 1 },
            default_value = 1,
            event = "ReZoom",
            help_text = _([[Trims the empty margins around the artwork. "auto" also removes a printed page number from the bottom gutter when one is found, and leaves an almost-blank page — a chapter divider, a title page — entirely uncropped instead of zooming into a small element. Nothing is cropped if nothing is found.]]),
        },
    }

-- Stock's page_scroll row, under Fit: the same question on the other axis.
    local page_view = stockOptionRow(pageview_tab, "page_scroll")
    if page_view then
        table.insert(page_options, 2, page_view)
    end

-- Tone: what the page looks like, not its shape; each row gated on the screen.
    local tone_options = { CONTRAST_ROW }
    if Image.colorEnabled() then
        tone_options[#tone_options + 1] = SATURATION_ROW
    end
    if Defaults.panelDithers() then
        tone_options[#tone_options + 1] = HW_DITHERING_ROW
    end
    if ditheringOffered() then
        tone_options[#tone_options + 1] = DITHERING_ROW
    end
    if Derainbow.available() and Image.colorEnabled() then
        tone_options[#tone_options + 1] = DERAINBOW_ROW
    end

-- Reading: what a page turn does, how many pages, and what a long-press does.
    local reading_options = {}
    reading_options[#reading_options + 1] = {
        name = "opdsbook_manga",
-- Named for the question, not one answer; values and args are unchanged.
        name_text = _("Reading direction"),
        toggle = {
            C_("Reading direction", "left to right"),
            C_("Reading direction", "manga (right to left)"),
        },
        values = { 0, 1 },
        args = { false, true },
        default_value = 1,
        event = "MeguruMangaRead",
        help_text = _([[Which way the pages are read. "left to right" is a western book; "manga (right to left)" is a Japanese one, where the pages turn the other way and the earlier page of a spread is the right-hand one. Remembered for this series; new Meguru books start in manga order — long-press this row to change that default.]]),
    }
-- Rows under Two pages are gated while it is off; the menu cannot indent them.
    reading_options[#reading_options + 1] = {
        name = "spread",
        name_text = _("Two pages"),
        toggle = {
            C_("Two pages", "off"),
            C_("Two pages", "in landscape"),
            C_("Two pages", "always"),
        },
        values = { "off", "auto", "on" },
        args = { "off", "auto", "on" },
        default_value = "off",
        event = "MeguruSpreadUpdate",
        help_text = _([[Shows two pages side by side, the way a printed book falls open. "in landscape" does it only while the screen is turned on its side, "always" in either orientation. A page the artist drew as one wide image is always shown whole and on its own, and the pairing starts again after it, so a printed spread never lands halfway through a pair. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
    }
    reading_options[#reading_options + 1] = {
        name = "spread_offset",
-- "Pair", not "Page": the row moves where a pair starts.
        name_text = _("Pair offset"),
        toggle = {
            C_("Pair offset", "off"),
            C_("Pair offset", "on"),
        },
        values = { 0, 1 },
        args = { 0, 1 },
        default_value = 0,
        event = "MeguruSpreadOffsetUpdate",
-- Shows the run the reader is in, not the stored page: a wide page ends it.
        current_func = function()
            local doc = ui and ui.document
            local page = ui and ui.paging and ui.paging.current_page
            if not (doc and page and type(doc.spreadOffsetHere) == "function") then
                return 0
            end
            return doc:spreadOffsetHere(page) and 1 or 0
        end,
-- Inert with one page on screen; a switch that changes nothing is kept out.
        enabled_func = function(configurable)
            return configurable.spread ~= nil and configurable.spread ~= "off"
        end,
        help_text = _([[Shifts the pairs of the run you are reading one page back: off pairs 1+2, 3+4; on leaves the run's first page standing alone and pairs 2+3, 4+5, so on page 7 you see 6+7 rather than 7+8. It applies from where you set it. A page the artist drew as one wide image ends it by itself — the pairs after a spread are as they fall unless you set it again there — which is also the row's way of telling you where you are. Turn it on for a book whose spreads read one page out: a cover or a title page that is its own page, or a printed spread the file counts as one.]]),
    }
    reading_options[#reading_options + 1] = {
        name = "spread_gutter",
        name_text = _("Flexible gutter"),
        toggle = { C_("Flexible gutter", "off"), C_("Flexible gutter", "on") },
        values = { 0, 1 },
        args = { 0, 1 },
        default_value = 1,
        event = "MeguruSpreadGutterUpdate",
-- Inert with nothing showing two pages, like the offset above.
        enabled_func = function(configurable)
            return configurable.spread ~= nil and configurable.spread ~= "off"
        end,
        help_text = _([[The crop trims each page's inner margin, which would butt the two pages of a spread together at the middle. With this on, the space left over once the artwork is fitted to the screen goes back into that gutter — never more than the margin the page itself has, and never enough to make the artwork smaller. With it off, a pair is drawn exactly as the crop left it. Remembered for this series; long-press this row to set what new Meguru books start at.]]),
    }

-- One row for the three views and Off; Off is KOReader's per-book answer.
    local panel_row = {
        name = "panel_view",
-- Named for what it sets, not the gesture; the viewer carries the same words.
        name_text = _("Panel view"),
        toggle = {
            C_("Panel view", "off"),
            C_("Panel view", "panel cut"),
            C_("Panel view", "pan & zoom"),
            C_("Panel view", "free view"),
        },
        values = { "off", "crop", "window", "zoom" },
        args = { "off", "crop", "window", "zoom" },
        default_value = "window",
        event = "MeguruPanelViewUpdate",
-- Two keys as one value: the file's panel-zoom answer, then the view.
        current_func = function()
            local hl = ui and ui.highlight
            if hl and not meguruPanelZoomWanted(hl) then
                return "off"
            end
            return Reader.panelViewMode(ui)
        end,
        help_text = _([[What holding on a page does. "panel cut" shows the panels the detector found, one at a time; "pan & zoom" keeps the page whole and moves a window over it; "free view" shows the page alone. "off" leaves the long-press to KOReader, and is remembered for the series like the views are. Long-press this row to make a view the default for new books. This is Meguru's own panel view — a panel plugin that answers the long-press itself is its own.]]),
    }
-- Panels+ sits above our wrapper: panels+ first, then every view of ours.
    if Reader.panelsPlusActive(ui) then
        panel_row = {
            name = "panel_view",
            name_text = _("Panel view"),
            toggle = {
                C_("Panel view", "panels+"),
                C_("Panel view", "off"),
                C_("Panel view", "panel cut"),
                C_("Panel view", "pan & zoom"),
                C_("Panel view", "free view"),
            },
            values = { RIVAL_PANEL_ON, "off", "crop", "window", "zoom" },
            args = { RIVAL_PANEL_ON, "off", "crop", "window", "zoom" },
            default_value = RIVAL_PANEL_ON,
            event = "MeguruPanelViewUpdate",
            current_func = function()
                local hl = ui and ui.highlight
                -- Stock's gate: it decides whether the press reaches either plugin.
                if hl and hl.panel_zoom_enabled ~= true then
                    return "off"
                end
                local c = ui and ui.document and ui.document.configurable
                if c and c.panel_owner == "meguru" then
                    return Reader.panelViewMode(ui)
                end
                return RIVAL_PANEL_ON
            end,
            help_text = _([[Panels+ answers the long-press by default; its own settings choose the panel view. "panels+" leaves the press to it, while any of Meguru's three views takes the press back. "off" turns panel zoom off for this book, and keeps it off when the book is reopened.]]),
        }
    end
    reading_options[#reading_options + 1] = panel_row

-- Four tabs plus the Info button; CURATED_PANELS counts only the panels.
    return {
        prefix = "kopt",
        { icon = Icons.tab("reading"), options = reading_options },
        { icon = Icons.tab("page"), options = page_options },
        { icon = Icons.tab("rotation"), options = rotation_options },
        { icon = Icons.tab("tone"), options = tone_options },
        { icon = Icons.tab("info"), options = {} },
    }
end

-- Counts panels, not entries: #config_options includes the Info button.
local CURATED_PANELS = 4

-- Redirects set-as-default onto the plugin preference, not a global kopt_*.
local function redirectDefaults(config)
    local dialog = config and config.config_dialog
    if not (dialog and type(dialog.onMakeDefault) == "function") then
        return
    end
    if dialog._meguru_defaults_hooked then
        return
    end
    dialog._meguru_defaults_hooked = true
    dialog.onMakeDefault = function(self, name, name_text, values, labels, position)
        local preference = Defaults.PREFERENCE_FOR[name]
        if not preference then
            return true
        end
        local value = values and values[position]
        local ui = config.ui
        local owner_row = name == "panel_view" and Reader.panelsPlusActive(ui)
-- Off is not a view; panels+ is an owner, stored beside the view preference.
        if name == "panel_view"
                and (value == "off"
                    or (value == RIVAL_PANEL_ON and not owner_row)) then
            UIManager:show(Notification:new{
                text = _("Only a Meguru view can be a default."),
                timeout = 2,
            })
            return true
        end
-- Each row in its own domain; the manga row converts 0/1 to the boolean stored.
        if name == "opdsbook_manga" then
            value = value == 1
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Set default %1 to %2?"), name_text or "",
                (labels and labels[position]) or ""),
            ok_text = _("Set as default"),
            ok_callback = function()
-- panels+ names an owner, not a view; the view preference stays the fallback.
                if owner_row and value == RIVAL_PANEL_ON then
                    Settings.set("panel_owner", "panelsplus")
                    Defaults.learnSeries(ui, "panel_owner", "panelsplus")
                else
                    Settings.set(preference, value)
                    -- Taught to the series too: its own answer would otherwise mask
                    -- the default the reader just set, in every book of it.
                    Defaults.learnSeries(ui, preference, value)
                    if owner_row then
                        Settings.set("panel_owner", "meguru")
                        Defaults.learnSeries(ui, "panel_owner", "meguru")
                    end
                end
            end,
        })
        return true
    end
end

-- Answers ShowConfigPanel for the Info button; writes no panel_index.
local function installInfoPanel(config)
    local dialog = config and config.config_dialog
    if not (dialog and type(dialog.onShowConfigPanel) == "function") then
        return
    end
-- The last icon, taken off the built table so button and icon cannot diverge.
    local info_index = #dialog.config_options
    local orig = dialog.onShowConfigPanel
    dialog.onShowConfigPanel = function(self, index, ...)
        if index == info_index then
-- config.ui is this ReaderUI, so the popup reads the document on screen now.
            Info.show(Reader.infoFields(config.ui))
            return true
        end
        return orig(self, index, ...)
    end
end

-- Reported once per process, not once per repair.
local config_menu_repair_logged = false

-- Guard is the wrapper, not a flag, so a foreign replacement is repaired.
local function curateConfigMenu(plugin)
    local config = plugin.ui and plugin.ui.config
    if not (config and type(config.onShowConfigMenu) == "function") then
        return false
    end
    if config._meguru_curated == config.onShowConfigMenu then
        return false
    end
    local orig = config.onShowConfigMenu
    local wrapper = function(cfg, ...)
        local stock_options = cfg.options
-- cfg.ui is this ReaderUI; options are swapped before orig builds the dialog.
        cfg.options = buildCuratedOptions(cfg.ui)
-- Clamped to panels, not entries: a stock index could land on the Info button.
        if type(cfg.last_panel_index) ~= "number" or cfg.last_panel_index < 1 then
            cfg.last_panel_index = 1
        elseif cfg.last_panel_index > CURATED_PANELS then
            cfg.last_panel_index = CURATED_PANELS
        end
        local ret = orig(cfg, ...)
        redirectDefaults(cfg)
        installInfoPanel(cfg)
-- Hand the module's stock options back so nothing else sees the subset.
        cfg.options = stock_options
        return ret
    end
    config._meguru_curated = wrapper
    config.onShowConfigMenu = wrapper
    return true
end


-- The item, series and server on screen; nil if it was never catalogued.
local function seriesContext(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.seriesContext) == "function") then
        return nil
    end
    local context = doc:seriesContext()
    if not (context and context.server_name) then
        return nil
    end
    return context
end

-- The shared folder for a local .cbz; exported so both surfaces use one guard.
function Reader.localSeriesOf(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.localSeries) == "function") then
        return nil
    end
    return doc:localSeries()
end

-- Shows only what the file carries; absent values are absent rows.
function Reader.infoFields(ui)
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return nil
    end
    local props = type(doc.getDocumentProps) == "function" and doc:getDocumentProps() or {}
    local fields = {
        title = props.title,
        page  = currentPage(ui),
        total = type(doc.getPageCount) == "function" and doc:getPageCount() or nil,
    }
    if doc.local_cbz then
        fields.series      = props.series
        fields.volume      = props.series_index
        fields.authors     = props.authors
        fields.language    = props.language
        fields.description = props.description
    else
        local desc = doc.desc or {}
        fields.series   = desc.series_name
        fields.language = desc.lang
-- server_kind, not the catalogue title: which server is a fact about the book.
        fields.server   = desc.server_kind and Base.kindLabel(desc.server_kind) or nil
-- Only when the kind cannot stand in for it: the OPDS entry's own name.
-- Trimmed and case-folded, so a catalog named after its server draws nothing.
        local name = type(desc.server_name) == "string"
            and desc.server_name:match("^%s*(.-)%s*$") or nil
        if name and name ~= ""
            and (not fields.server or name:lower() ~= fields.server:lower()) then
            fields.catalog = name
        end
    end
-- Only a catalogued book: the button opens its series on the server.
    local context = seriesContext(ui)
    if context and doc.desc then
        -- The marker itself, not the context: the template names the driver.
        local desc = doc.desc
        fields.show_in_opds = function() Catalog.showIn(ui, desc) end
    end
    return fields
end

-- One refusal wording for both directions, so the two cannot drift.
local function showNoNeighbor(which, name)
    UIManager:show(InfoMessage:new{
        text = which == "next"
            and T(_("%1 has no next chapter."), tostring(name or ""))
            or T(_("%1 has no previous chapter."), tostring(name or "")),
    })
end

-- The feed is the only source and is read on the ask; nothing is written.
local function neighborFromFeed(doc, context, which)
    local plan, reason = Feed.planForMarker(doc.desc, {
        max_pages = Feed.TAP_PAGES,
        timeout   = "resume",
        on_failure = function(why)
            logger.info("Meguru: cannot look for a neighbour of",
                tostring(context.series_name), "-", why)
        end,
    })
    if not plan then
        return nil, reason
    end
    local walker = Feed.walker(plan.url, plan.walker_opts)
    while walker:step() do end
    if not walker.complete then
        return nil, tostring(walker.reason)
    end
-- title_order comes off the driver: its answer, not this function's to guess.
    local sequence = Feed.ordered(Feed.collect(walker, plan),
        { title_order = plan.driver and plan.driver.orderFromTitles })
    return Feed.neighbor(sequence, context.item_key, which)
end

-- Replaces the document; never asks, because the tap named one specific book.
function Reader.openNeighbor(plugin, which)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document

-- Local first, before the connection test: a folder listing needs no network.
    local spot = Reader.localSeriesOf(ui)
    if spot then
        local path, why = Local.neighbor(doc.file, which)
        if not path then
            logger.info("Meguru: no local neighbour of", spot.name, "towards",
                which, "-", tostring(why))
            showNoNeighbor(which, spot.name)
            return false
        end
        return Open.openLocalFile(plugin, path) ~= nil
    end

    local context = seriesContext(ui)
-- No context: no series identity, so no feed URL; it reads without neighbours.
    if not context then
        return false
    end
-- A walk is HTTP, so it needs a connection; the manager prompts and re-runs.
    if not NetworkMgr:isConnected() then
        NetworkMgr:willRerunWhenConnected(function()
            Reader.openNeighbor(plugin, which)
        end)
        return false
    end
    local item, reason = neighborFromFeed(doc, context, which)
    if not item then
        logger.info("Meguru: no neighbour of", tostring(context.series_name),
            "towards", which, "-", tostring(reason))
        showNoNeighbor(which, context.series_name)
        return false
    end
-- openItemSilently reports its own failures; only whether it worked is wanted.
    return Open.openItemSilently(plugin, context, item) ~= nil
end


-- Shared by both branches so auto-mark cannot be dropped on one path only.
local function autoMarkFinished(ui, status)
    local g = rawget(_G, "G_reader_settings")
    if not (g and type(g.isTrue) == "function"
        and g:isTrue("end_document_auto_mark")) then
        return
    end
    pcall(function()
        if ui.doc_settings and ui.doc_settings:readSetting("summary")
            and type(status.markBook) == "function" then
            status:markBook(true)
        end
    end)
end

-- Deferred, once: switching mid-gesture would tear the reader down.
local function deferOpen(status, open)
    if status._meguru_auto_pending then
        return
    end
    status._meguru_auto_pending = true
    UIManager:nextTick(function()
        status._meguru_auto_pending = false
        open()
    end)
end

-- Installed on this ReaderUI's own ReaderStatus, so other books stay stock.
local function installEndOfBookHook(plugin)
    local ui = plugin.ui
    local status = ui and ui.status
    if not (status and type(status.onEndOfBook) == "function") then
        return
    end
    if status._meguru_eob_wrapped then
        return
    end
    status._meguru_eob_wrapped = true
    local orig = status.onEndOfBook
    status.onEndOfBook = function(status_self, ev)
        if not Settings.get("auto_next_item") then
            return orig(status_self, ev)
        end
-- The walk is asked for: auto_next_item is on and a volume finished.
-- Anything short of a next chapter falls through to KOReader's dialog.
        local spot = Reader.localSeriesOf(ui)
        if spot then
            local path = Local.neighbor(ui.document.file, "next")
            if not path then
                return orig(status_self, ev)
            end
            autoMarkFinished(ui, status_self)
            deferOpen(status_self, function()
                pcall(Open.openLocalFile, plugin, path)
            end)
            return true
        end

        local context = seriesContext(ui)
        if not (context and NetworkMgr:isConnected()) then
            return orig(status_self, ev)
        end
        local ok_walk, next_item = pcall(neighborFromFeed, ui.document, context, "next")
        if not (ok_walk and next_item) then
            return orig(status_self, ev)
        end
        autoMarkFinished(ui, status_self)
        deferOpen(status_self, function()
-- Opens the item the walk returned; do not switch again here.
            pcall(Open.openItemSilently, plugin, context, next_item)
        end)
        return true
    end
end


-- The same answer drawPage uses, or the surround reads as the page's negative.
local function pageIsInverted(document)
    local configurable = document and document.configurable
    return configurable ~= nil and configurable.nightmode_document == 1
        and Screen.night_mode == true
end

-- Rec.601, the same weights the document's lumaAt uses.
local function lumaOf(r, g, b)
    return math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
end

-- Paper: light on every channel and near-neutral; a colour is left alone.
-- Stricter than the crop's own bound on purpose: only paper this pale is worth
-- darkening in night mode (see Image.isPaperColor).
local PAPER_MIN_CHANNEL = 200
local function isPaper(r, g, b)
    return Image.isPaperColor(r, g, b, PAPER_MIN_CHANNEL)
end

-- Night mode takes paper to black, leaves a colour, then inverts the fill.
local function setCropMarginColor(plugin, ui, margin)
    local view = ui and ui.view
    local stock = plugin._meguru_view_color
    if not (view and stock and stock.outer) then
        return
    end
    local color
    plugin._meguru_surround = nil
    if margin then
-- Per page and unrounded: snapping to the dither grid made the letterbox jump.
        local r, g, b = margin.r, margin.g, margin.b
        if pageIsInverted(ui.document) then
            if isPaper(r, g, b) then
-- Paper goes to the black the screen already is.
                r, g, b = 255 - r, 255 - g, 255 - b
            end
-- A colour is left alone; the fill is inverted as the display will invert it.
            r, g, b = 255 - r, 255 - g, 255 - b
        end
-- The stock fields get a grey of the same brightness, for continuous mode.
        color = Blitbuffer.gray(1 - lumaOf(r, g, b) / 255)
        plugin._meguru_surround = { r = r, g = g, b = b }
    end
    view.outer_page_color = color or stock.outer
    view.page_bgcolor = color or stock.page
end

-- Asked on a turn, not in the paint: a cold crop is a decode.
local function applyCropMarginColor(plugin, ui, page)
    local document = ui and ui.document
    local configurable = document and document.configurable
    local margin
    if configurable and configurable.trim_page == 1 and type(page) == "number"
        and type(document.cropMarginColor) == "function" then
        margin = document:cropMarginColor(page)
    end
    plugin._meguru_margin_color = margin
    if margin then
        logger.dbg("Meguru: page surround from crop margin",
            lumaOf(margin.r, margin.g, margin.b),
            string.format("(%d,%d,%d)", margin.r, margin.g, margin.b),
            pageIsInverted(document) and "(night)" or "")
    end
    setCropMarginColor(plugin, ui, margin)
end

-- Asked per turn, so the row is live for the book already open; the ask rides
-- the repaint the turn causes, since "full" outranks the view's "partial".
local function flashPageTurn()
    if Settings.get("refresh_each_page") then
        UIManager:setDirty(nil, "full")
    end
end

-- Re-derived per paint, not per turn: night mode is toggled with no turn in it.
local function installCropMarginColor(plugin, ui)
    local view = ui and ui.view
    if not (view and type(view.paintTo) == "function") then
        return
    end
    local orig_paint_to = view.paintTo
    view.paintTo = function(self, ...)
        setCropMarginColor(plugin, ui, plugin._meguru_margin_color)
        return orig_paint_to(self, ...)
    end
end

-- outer_page_color paints grey via Color8; paintRectRGB32 carries the channels.
local function installCropMarginPaint(plugin, ui)
    local view = ui and ui.view
    if not (view and type(view.drawPageSurround) == "function") then
        return
    end
    local orig_draw_surround = view.drawPageSurround
    view.drawPageSurround = function(self, bb, x, y)
        orig_draw_surround(self, bb, x, y)
        local c = plugin._meguru_surround
        if c then
            bb:paintRectRGB32(x, y, self.dimen.w, self.dimen.h,
                Blitbuffer.ColorRGB32(c.r, c.g, c.b, 0xFF))
        end
    end
end

-- Only while one of our books is open: the Dispatcher's list is per process.
local PAIR_OFFSET_ACTION = "meguru_pair_offset"

local function registerPairOffsetAction()
    Dispatcher:registerAction(PAIR_OFFSET_ACTION, {
        category = "none",
        event = "MeguruPairOffsetToggle",
        -- Prefixed: the Fixed layout list is shared, and nothing else says whose.
        title = _("Meguru: toggle pair offset (two-page view)"),
        -- paging=true puts it in the fixed-layout section, a list not a gate.
        paging = true,
    })
end

local function unregisterPairOffsetAction()
    Dispatcher:removeAction(PAIR_OFFSET_ACTION)
end

-- Grafts everything reader-side; a no-op for any non-Meguru document.
function Reader.install(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return false
    end

-- Captured before anything writes them, as stock's own cropping module does.
    if ui.view and not plugin._meguru_view_color then
        plugin._meguru_view_color = {
            outer = ui.view.outer_page_color,
            page = ui.view.page_bgcolor,
        }
    end
    installCropMarginColor(plugin, ui)
    installCropMarginPaint(plugin, ui)

-- Offered to the gesture editor for as long as this book is the one open.
    registerPairOffsetAction()

    local rotate_state = {}
    plugin._meguru_rotate_state = rotate_state
-- Same table on the reader: syncSpread has to ask if a rotation is still ours.
    ui._meguru_rotate_state = rotate_state

-- Skip our rotation when pagenumbercrop owns the document; both markers probed.
    local pagenumbercrop_owns = doc._pagenum_cache ~= nil
        or (ui.paging and ui.paging._page_number_crop_patched)
    if not pagenumbercrop_owns then
        installWideRotate(rotate_state, ui)
        plugin._meguru_wide_rotate_installed = true
-- A previous book may have left the screen rotated; reconcile after layout.
        if session_wide_rotate.base ~= nil then
            UIManager:scheduleIn(0.1, function()
                pcall(reconcileWideRotation, rotate_state, ui)
-- Either way, tell the document before the first layout is trusted.
                syncSpread(ui)
            end)
        end
    end

-- Installed whatever else is: the pair is a question no other plugin asks.
    installSpread(ui)

-- Before ReadSettings, so our answer beats the one stock reads a moment later.
    installPanelZoom(ui)

-- Before the first paint: the painter stands between a failed page and a blank.
    installPageErrorPage(plugin)

-- Chained, not merged: a page turn is not a painter's business.
-- A turn with no page number falls back to the page on screen.
    local page_error_handler = plugin.onPageUpdate
    plugin.onPageUpdate = function(self, page)
        if type(page_error_handler) == "function" then
            page_error_handler(self, page)
        end
        local turned = page or (self.ui and currentPage(self.ui))
        notePageTurn(self, turned)
        applyCropMarginColor(plugin, self.ui or ui, turned)
        flashPageTurn()
    end

-- The page the book opens on, which no page turn announces.
    applyCropMarginColor(plugin, ui, currentPage(ui))

-- The Crop row fires ReZoom, not a turn, so the surround must be re-asked here.
-- On the handler that derives the box, so the crop is warm by then.
    local zooming = ui.zooming
    if zooming and type(zooming.onReZoom) == "function" then
        local zooming_rezoom = zooming.onReZoom
        zooming.onReZoom = function(self, ...)
            local handled = zooming_rezoom(self, ...)
            applyCropMarginColor(plugin, ui, currentPage(ui))
            return handled
        end
    end

    curateConfigMenu(plugin)

-- Re-installed at ReaderReady, provably later than a plugin's replacement.
    if type(ui.registerPostReaderReadyCallback) == "function" then
        ui:registerPostReaderReadyCallback(function()
            if curateConfigMenu(plugin) and not config_menu_repair_logged then
                config_menu_repair_logged = true
                logger.info("Meguru: the config menu was replaced since load;"
                    .. " curation re-installed")
            end
        end)

-- Take the crop seam back at ReaderReady, later than every plugin's init.
        ui:registerPostReaderReadyCallback(function()
            if type(doc.takeBackPageBBox) ~= "function" or not doc:takeBackPageBBox() then
                return
            end
            logger.info("Meguru: took the crop seam back from pagenumbercrop")
-- It may already be in the box derived during ReadSettings, so derive it again.
            ui:handleEvent(Event:new("ReZoom"))
        end)

-- First look at the pair; every plugin's seeding has run by now.
        ui:registerPostReaderReadyCallback(function()
            syncSpread(ui)
        end)
    end

    installEndOfBookHook(plugin)

    plugin.onMeguruRotateWideUpdate = function(self, value)
        if type(value) ~= "number" then
            value = ROTATE_OFF
        end
        local texts = {
            _("Rotate wide pages: off"),
            _("Rotate wide pages: right 90°"),
            _("Rotate wide pages: left 90°"),
        }
        setWideRotate(rotate_state, self.ui, value, texts[value + 1])
        return true
    end

    plugin.onMeguruSpreadUpdate = function(self, value)
        if value ~= "off" and value ~= "auto" and value ~= "on" then
            value = "off"
        end
        local texts = {
            off = _("Two pages: off"),
            auto = _("Two pages: in landscape"),
            on = _("Two pages: always"),
        }
        setSpread(self.ui, value, texts[value])
        return true
    end

-- "On" means from here; compared, never tested, since 0 is truthy.
    plugin.onMeguruSpreadOffsetUpdate = function(self, value)
        local ui = self.ui
        local anchor = 0
        if value == 1 or value == "1" or value == true then
            anchor = (ui and ui.paging and ui.paging.current_page) or 1
        end
        setSpreadOffset(ui, anchor, spreadOffsetNotice(anchor > 0))
        return true
    end

-- Same flip for the gesture action; installed per reader, inert elsewhere.
    plugin.onMeguruPairOffsetToggle = function(self)
        local ui = self.ui
        local doc = ui and ui.document
        local page = currentPage(ui)
        if not (doc and page and type(doc.spreadOffsetHere) == "function") then
            return true
        end
        local on = not doc:spreadOffsetHere(page)
        setSpreadOffset(ui, on and page or 0, spreadOffsetNotice(on))
        return true
    end

    plugin.onMeguruSpreadGutterUpdate = function(self, value)
-- Compared, never tested: 0 is truthy in Lua (see the row).
        value = (value == 1 or value == "1" or value == true) and 1 or 0
        setSpreadGutter(self.ui, value,
            value == 1 and _("Flexible gutter: on") or _("Flexible gutter: off"))
        return true
    end

-- Own row, own handler; the other plugin's needs a rolling view we lack.
    plugin.onMeguruDerainbowUpdate = function(self, value)
-- Compared, never tested: 0 is truthy in Lua (see the row).
        value = (value == 1 or value == "1" or value == true) and 1 or 0
        setDerainbow(self.ui, value,
            value == 1 and _("Derainbow: on") or _("Derainbow: off"))
        return true
    end

    plugin.onMeguruSetFit = function(self, key)
        if not Defaults.FIT_TO_ZOOM_MODE[key] then
            return true
        end
        local zooming = self.ui and self.ui.zooming
        if zooming and type(zooming.setZoomMode) == "function" then
            local desired = Defaults.FIT_TO_ZOOM_MODE[key]
            zooming:setZoomMode(desired)
            if self.ui.doc_settings then
                self.ui.doc_settings:saveSetting("zoom_mode", desired)
            end
        end
        return true
    end

    plugin.onMeguruMangaRead = function(self, enabled)
        enabled = enabled == true
        local configurable = self.ui and self.ui.document
            and self.ui.document.configurable
        if configurable then
            configurable.opdsbook_manga = enabled and 1 or 0
        end
        if self.ui.doc_settings then
            self.ui.doc_settings:saveSetting("inverse_reading_order", enabled)
            self.ui.doc_settings:flush()
        end
-- The built-in menu's live path: flips the flag, remaps touch zones, notifies.
        local view = self.ui.view
        if view and type(view.onToggleReadingOrder) == "function" then
            view:onToggleReadingOrder(enabled)
        end
-- The document keeps its own copy: it draws a pair and cannot read the view.
        local doc = self.ui and self.ui.document
        if doc then
            doc.spread_rtl = enabled
        end
        return true
    end

    plugin.onMeguruHideStatusBar = function(self, hide)
        local footer = getStatusBarFooter(self.ui)
        if hide then
            hideStatusBar(footer)
        else
            showStatusBar(footer)
        end
        return true
    end

-- panel_view holds the view, panel_zoom_enabled the on/off, panel_owner the owner.
-- Put panel_zoom_enabled where the stock flip must start, then flip it.
    plugin.onMeguruPanelViewUpdate = function(self, value)
        local ui = self.ui
        local doc = ui and ui.document
        local configurable = doc and doc.configurable
        if not (configurable and configurable.panel_view ~= nil) then
            return true
        end
        local rival = value == RIVAL_PANEL_ON
        local view = panelViewIsView(value) and value or nil
        if not view and value ~= "off" and not rival then
            return true
        end

        local hl = ui.highlight
        local want = view ~= nil or rival
        if hl and (meguruPanelZoomWanted(hl) ~= want
                or hl.panel_zoom_enabled ~= want) then
            hl.panel_zoom_enabled = not want
            hl:onTogglePanelZoomSetting()
        end

        local answers = Reader.panelsPlusActive(ui)
        local function saveOwner(owner)
            configurable.panel_owner = owner
            local ds = ui.doc_settings
            if ds then
                ds:saveSetting("kopt_panel_owner", owner)
                ds:flush()
            end
        end

        if view then
            configurable.panel_view = view
            if ui.doc_settings then
                ui.doc_settings:saveSetting("kopt_panel_view", view)
                ui.doc_settings:flush()
            end
            if answers then
                saveOwner("meguru")
                setPanelsPlusYield(ui, true)
            end
        elseif rival then
            if answers then
                saveOwner("panelsplus")
                setPanelsPlusYield(ui, false)
            end
            -- The dialog wrote panels+ into the view key; put a view back.
            local ds = ui.doc_settings
            local stored = ds and ds:readSetting("kopt_panel_view")
            if not panelViewIsView(stored) then
                stored = Settings.get("panel_view")
                if not panelViewIsView(stored) then
                    stored = "window"
                end
                if ds then
                    ds:saveSetting("kopt_panel_view", stored)
                    ds:flush()
                end
            end
            configurable.panel_view = stored
        else
            -- Off leaves the owner alone; turning the press back on returns to it.
            if answers then
                setPanelsPlusYield(ui, configurable.panel_owner == "meguru")
            end
            -- The dialog wrote off into the view key; put a view back.
            local ds = ui.doc_settings
            local stored = ds and ds:readSetting("kopt_panel_view")
            configurable.panel_view = panelViewIsView(stored) and stored
                or Reader.panelViewMode(ui)
        end
        return true
    end

-- Loud, not swallowed: a failure here would lose the reader's answers quietly.
local function publishSeries(plugin)
    local ok, err = pcall(Defaults.publishSeries, plugin.ui)
    if not ok then
        logger.warn("Meguru: could not publish the series' settings:", err)
    end
end

-- Rotation restored first, so the screen is right before a socket wait.
    plugin.onCloseDocument = function(self)
        unregisterPairOffsetAction()
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
        flushProgress(self)
        publishSeries(self)
    end

    plugin.onClose = function(self)
        unregisterPairOffsetAction()
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
        flushProgress(self)
        publishSeries(self)
    end

-- Both seams needed: flushSettings and Suspend arrive a moment apart.
-- Assigned, not chained: neither is assigned elsewhere in this plugin.
-- SaveSettings would be the seam, but ReaderKoptListener consumes that event
-- long before a plugin is reached (readerkoptlistener.lua:60).
    plugin.onFlushSettings = function(self)
        flushProgress(self)
        publishSeries(self)
    end

    plugin.onSuspend = function(self)
        flushProgress(self)
        publishSeries(self)
    end

    return true
end

return Reader
