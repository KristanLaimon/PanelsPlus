--[[
Panels+
File: src/viewer_controller/prerender.lua
Name: ViewerController
Description: Viewer orchestration: prerender.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Device = require("device")
local Event = require("ui/event")
local Memory = require("src._memory")
local PageRender = require("src._pagerender")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

return function(ViewerController)
    --- Restore the reader's device orientation when a page change replaced it.
    ---
    --- A panel-boundary crossing goes through the regular `GotoPage` event so
    --- KOReader can update its reading state. Some KOReader configurations and
    --- third-party plugins also apply a document rotation while handling that
    --- event. That used to undo a Device rotation chosen from the Panels+ picker
    --- just before the next panel viewer was created. Keep the selected screen
    --- mode across this internal page handoff; this is deliberately separate from
    --- the per-image `image_rotation` setting.
    ---
    --- @param expected_mode integer|nil Rotation mode active before the page handoff.
    function ViewerController:restoreDeviceRotation(expected_mode)
        if expected_mode == nil or Screen:getRotationMode() == expected_mode then
            return
        end
        Timing.log("restoring device rotation after page handoff: %d -> %d", Screen:getRotationMode(), expected_mode)
        UIManager:broadcastEvent(Event:new("SetRotationMode", expected_mode))
        UIManager:onRotation()
    end

    --- Drop any panel prerender that has not run yet.
    function ViewerController:cancelPanelPrerender()
        if self.panel_prerender_action then
            UIManager:unschedule(self.panel_prerender_action)
            self.panel_prerender_action = nil
        end
    end

    --- Return whether there is room to warm one more panel tile.
    ---
    --- @return boolean allowed Whether prerendering should proceed.
    function ViewerController:hasMemoryForPrerender()
        local minimum = self.settings.prerender_min_free_bytes or Settings.defaults.prerender_min_free_bytes
        -- A canvas-fit tile is at most one screen. Reserve its worst-case colour
        -- storage as well as the safety floor before warming the document cache.
        local tile_bytes = Screen:getWidth() * Screen:getHeight() * 4
        local allowed = Memory.hasAllocationHeadroom(minimum, tile_bytes)
        if not allowed then
            local free_bytes = Memory.freeBytes()
            Timing.log(
                "prerender skipped: low memory (free=%dMB min=%dMB)",
                math.floor((free_bytes or 0) / (1024 * 1024)),
                math.floor(minimum / (1024 * 1024))
            )
        end
        return allowed
    end

    --- Warm the render of the panel after `index` while the reader sits idle.
    ---
    --- Swiping to a panel otherwise pays for a synchronous `drawPagePart()`, which
    --- rasterizes that region of the page scaled up to the screen. Doing it ahead of
    --- time leaves the tile in KOReader's `DocCache`, so the swipe becomes a cache
    --- hit. The rendered buffer is deliberately discarded rather than kept: the
    --- cache already owns it, and holding a second copy would spend the memory this
    --- is meant to protect.
    ---
    --- @param viewer PanelViewer Active panel viewer.
    --- @param index integer 1-based index of the panel currently shown.
    function ViewerController:prerenderNextPanel(viewer, index)
        self:cancelPanelPrerender()
        if self.settings.panel_prerender == false then
            return
        end

        local next_rect = viewer.image_rects and viewer.image_rects[index + 1]
        if not next_rect then
            return
        end

        local delay = self.settings.panel_prerender_delay or Settings.defaults.panel_prerender_delay
        local document = self.ui and self.ui.document
        local action
        action = function()
            if self.panel_prerender_action ~= action then
                return
            end
            self.panel_prerender_action = nil
            if
                not self.ui
                or self.ui.document ~= document
                or viewer._panels_plus_closed
                or not self:hasMemoryForPrerender()
            then
                return
            end
            local stop = Timing.span("prerender panel " .. (index + 1))
            pcall(function()
                PageRender.drawPagePart(self.ui, viewer.page, next_rect, 0)
            end)
            stop()
        end

        self.panel_prerender_action = action
        UIManager:scheduleIn(delay, action)
    end
end
