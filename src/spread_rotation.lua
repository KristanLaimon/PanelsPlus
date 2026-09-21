--[[
Panels+
File: src/spread_rotation.lua
Name: SpreadRotation
Description: Rotates the screen for double-page spreads on the reading page and restores it afterwards.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local DoubleSpread = require("src._doublespread")
local Event = require("ui/event")
local PanelCollector = require("src._panelcollector")
local Screen = require("device").screen
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")

--- Rotates the screen for double-page spreads on the reading page.
---
--- The viewer rotates a spread as an image (`auto_rotate_double_pages`). The reader cannot, so
--- with `rotate_screen_for_double_pages` the screen is rotated when a page turn lands on a spread
--- and restored on the next normal page.
---
--- State kept on the plugin instance:
---
--- - `spread_rotation`: `{ base, target }` while this module has rotated the screen, else `nil`.
--- - `spread_rotation_page`: the last page handled.
--- - `spread_rotation_declined_page`: a spread the user rotated back. It is skipped until the page
---   changes.
--- - `spread_rotation_ready`: set by `startSpreadRotation`.
---
--- Mixed into the plugin through `include()` in `main.lua`. `main.lua` owns `onReaderReady` and
--- `onSaveSettings` and calls into this module from them.
---
--- @class PPSpreadRotationMixin
local SpreadRotation = {}

--- Current page, or `nil` for a document without paging.
local function currentPage(self)
    return self.ui and self.ui.paging and self.ui.paging.current_page
end

--- Whether a Panels+ viewer for a document page is open.
---
--- @return boolean open
function SpreadRotation:isPanelViewerOpen()
    local viewer = self.active_panel_viewer
    return viewer ~= nil and not viewer._panels_plus_closed
end

--- Request a screen rotation through `SetRotationMode`, as KOReader's own menu does.
--- `_spread_rotation_busy` marks the request as coming from this module.
---
--- @param mode integer Target `Screen` rotation mode.
function SpreadRotation:setSpreadScreenRotation(mode)
    Timing.log("spread rotation: screen %d -> %d", Screen:getRotationMode(), mode)
    self._spread_rotation_busy = true
    local ok, err = pcall(function()
        UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
        UIManager:onRotation()
    end)
    self._spread_rotation_busy = nil
    if not ok then
        error(err)
    end
end

--- Native page size, or `nil` when the document cannot report one.
local function nativePageSize(document, page)
    if not document or not document.getNativePageDimensions then
        return nil
    end
    local ok, size = pcall(document.getNativePageDimensions, document, page)
    if not ok or type(size) ~= "table" then
        return nil
    end
    return size.w, size.h
end

--- Rotation mode for `page`, or `nil` for the base mode.
---
--- @param page integer Document page number.
--- @param base_mode integer Rotation the reader is in when no spread is rotated.
--- @return integer|nil rotation_mode
function SpreadRotation:spreadRotationModeFor(page, base_mode)
    -- Not tied to `isEnabled()`: that setting hands panel zoom back to KOReader, and the reading
    -- page has nothing to do with panel zoom.
    if self.settings.rotate_screen_for_double_pages ~= true then
        return nil
    end
    local page_w, page_h = nativePageSize(self.ui.document, page)
    return DoubleSpread.screenRotationFor(base_mode, page_w, page_h)
end

--- Rotate or restore the screen for `page`.
---
--- @param page integer|nil Document page number.
function SpreadRotation:syncSpreadRotation(page)
    if not self.spread_rotation_ready or self._spread_rotation_busy then
        return
    end
    if not page or not (self.ui and self.ui.paging) then
        return
    end
    if self:isPanelViewerOpen() then
        return
    end
    self.spread_rotation_page = page

    local current = Screen:getRotationMode()
    local hold = self.spread_rotation
    if hold and current ~= hold.target then
        -- The screen was rotated by something else. Drop the hold and skip
        -- this page.
        self.spread_rotation = nil
        self.spread_rotation_declined_page = page
        hold = nil
    end
    if self.spread_rotation_declined_page ~= page then
        self.spread_rotation_declined_page = nil
    end

    local base = hold and hold.base or current
    local target
    if self.spread_rotation_declined_page ~= page then
        target = self:spreadRotationModeFor(page, base)
    end

    if target then
        if current ~= target then
            self.spread_rotation = { base = base, target = target }
            self:setSpreadScreenRotation(target)
            if Screen:getRotationMode() ~= target then
                -- The request had no effect, so there is nothing to restore.
                self.spread_rotation = nil
            end
        end
    elseif hold then
        self:releaseSpreadRotation()
    end
end

--- Restore the rotation the screen had before a spread was shown.
function SpreadRotation:releaseSpreadRotation()
    local hold = self.spread_rotation
    if not hold then
        return
    end
    self.spread_rotation = nil
    if Screen:getRotationMode() == hold.target then
        self:setSpreadScreenRotation(hold.base)
    end
end

--- KOReader hook for a page change. It runs before the new page is painted, so the rotation and the
--- page share one refresh.
---
--- @param page integer Document page number.
function SpreadRotation:onPageUpdate(page)
    self:syncSpreadRotation(page)
end

--- KOReader hook for a rotation request. A request from elsewhere while a spread is rotated means
--- the user chose their own rotation: drop the hold and skip this page.
---
--- @param mode integer Requested rotation mode.
function SpreadRotation:onSetRotationMode(mode)
    local hold = self.spread_rotation
    if self._spread_rotation_busy or not hold or mode == hold.target then
        return
    end
    self.spread_rotation = nil
    self.spread_rotation_declined_page = self.spread_rotation_page
end

--- KOReader hook for closing the document. Restores the rotation and stops handling page changes.
function SpreadRotation:onCloseDocument()
    self:releaseSpreadRotation()
    self.spread_rotation_ready = nil
    self.spread_rotation_declined_page = nil
end

--- Start handling page changes. Called from `onReaderReady`.
---
--- KOReader sends the first `PageUpdate` while `ReaderUI` is still being built and cannot receive a
--- rotation request, so the first page is handled here.
function SpreadRotation:startSpreadRotation()
    self.spread_rotation_ready = true
    self:scheduleSpreadRotationSync()
end

--- Handle the current page on the next tick. Used when the caller is inside `ReaderReady` or
--- `UIManager:close()`.
function SpreadRotation:scheduleSpreadRotationSync()
    UIManager:nextTick(function()
        self:syncSpreadRotation(currentPage(self))
    end)
end

--- Apply a changed `rotate_screen_for_double_pages` to the current page.
function SpreadRotation:applySpreadRotationSetting()
    self.spread_rotation_declined_page = nil
    self:syncSpreadRotation(currentPage(self))
end

--- Keep the temporary rotation out of the document settings.
---
--- `ReaderView:onSaveSettings` saves the current screen rotation. If that happens while a spread is
--- rotated, the book reopens in landscape. Core modules handle `SaveSettings` before plugins, so
--- the base rotation is written over `kopt_rotation_mode` afterwards.
function SpreadRotation:keepSpreadRotationOutOfDocSettings()
    local hold = self.spread_rotation
    local doc_settings = self.ui and self.ui.doc_settings
    if not hold or not doc_settings or type(doc_settings.saveSetting) ~= "function" then
        return
    end
    -- KOReader does not save the rotation while it is locked.
    if G_reader_settings and G_reader_settings:isTrue("lock_rotation") then
        return
    end
    doc_settings:saveSetting("kopt_rotation_mode", hold.base)
end

--- Called before a viewer is built for `page`. Restores the base rotation so panels are shown
--- upright.
---
--- The landscape screen is kept when the rotated spread has a single panel or only whole-page
--- panels. The viewer would show the same picture, and restoring would cost two refreshes.
---
--- @param page integer Document page number the viewer is about to show.
--- @param panels PPPanel[]|nil Panels the viewer will show.
function SpreadRotation:prepareSpreadRotationForViewer(page, panels)
    local hold = self.spread_rotation
    if not hold then
        return
    end
    if SpreadRotation.spreadRotationModeFor(self, page, hold.base) == hold.target then
        local document = self.ui.document
        local page_size = document.getPageDimensions and document:getPageDimensions(page, 1, 0)
        local only_whole_page = page_size ~= nil and panels ~= nil and #panels > 0
        if only_whole_page and #panels > 1 then
            for _, rect in ipairs(panels) do
                if not PanelCollector.isFullPagePanel(rect, page_size, self.settings) then
                    only_whole_page = false
                    break
                end
            end
        end
        if only_whole_page then
            return
        end
    end
    SpreadRotation.releaseSpreadRotation(self)
end

--- Called when a viewer has closed. Ignored for a viewer that was replaced by the next page's
--- viewer. Deferred to the next tick because it runs inside `UIManager:close()`.
---
--- @param viewer PanelViewer The viewer that closed.
function SpreadRotation:onPanelViewerClosed(viewer)
    if self.active_panel_viewer ~= viewer then
        return
    end
    self.active_panel_viewer = nil
    SpreadRotation.scheduleSpreadRotationSync(self)
end

return SpreadRotation
