--[[
Panels+
File: src/viewer_controller.lua
Name: ViewerController
Description: Coordinates viewer creation, reading-mode changes, transitions, rotation, and page boundaries.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Event = require("ui/event")
local Device = require("device")
local Screen = Device.screen
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local DoubleSpread = require("src._doublespread")
local SpreadRotation = require("src.spread_rotation")
local Memory = require("src._memory")
local PanelCollector = require("src._panelcollector")
local PageRender = require("src._pagerender")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")
local NavCapabilities = require("src._navcapabilities")
local Timing = require("src._timing")
local WordFinder = require("src._wordfinder")
local UIManager = require("ui/uimanager")

--- Panel viewer orchestration methods mixed into `PanelsPlus`.
---
--- @class PPViewerControllerMethods
local ViewerController = {}

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
    if not next_rect or self.settings.mode == "manhwa" then
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

--- Toggle reading order from an open viewer and keep the current panel position.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerMode(viewer)
    local current_rect = viewer.panels and viewer.panels[viewer._images_list_cur]
    local next_mode = Settings.nextReadingMode(viewer.reading_mode or self.settings.mode)
    local focus_page = viewer.page
    local focus_x = current_rect and (current_rect.x + current_rect.w / 2)
    local focus_y = current_rect and (current_rect.y + current_rect.h / 2)
    if current_rect and viewer.reading_mode == "manhwa" then
        local layout = require("src.manhwa").layout(self.ui.document)
        local item = layout.pages[layout:owner(focus_y)]
        focus_page, focus_y = item.page, focus_y - item.y
    end
    self:setMode(next_mode)
    if current_rect and next_mode == "manhwa" then
        local layout = require("src.manhwa").layout(self.ui.document)
        local index = layout:indexForPage(focus_page)
        if not index then
            self:setMode(viewer.reading_mode)
            UIManager:show(require("ui/widget/infomessage"):new({
                text = require("gettext")("Manhwa mode could not obtain this document's source-page dimensions."),
                timeout = 3,
            }))
            return true
        end
        focus_y = focus_y + layout.pages[index].y
    end
    if not current_rect then
        viewer.reading_mode = self.settings.mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = self:collectPanels(focus_page)
    if #panels == 0 then
        viewer.reading_mode = self.settings.mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local start_idx = PanelCollector.startIndex(panels, {
        x = focus_x,
        y = focus_y,
    })

    UIManager:close(viewer)
    if focus_page ~= viewer.page and self.ui.handleEvent then
        local rotation = Screen:getRotationMode()
        self.ui:handleEvent(Event:new("GotoPage", focus_page))
        self:restoreDeviceRotation(rotation)
    end
    return self:showPanelViewerForPage(focus_page, panels, start_idx, { buttons_visible = true })
end

--- Order the crop-mode button cycles through on tap.
local CROP_MODE_CYCLE = { strict = "loose", loose = "margin", margin = "none", none = "strict" }

--- Toggle crop mode from an open viewer and reopen at the same image index.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerCropMode(viewer)
    self:setCropMode(CROP_MODE_CYCLE[self.settings.crop_mode] or "strict")
    if not viewer.panels or #viewer.panels == 0 then
        viewer.crop_mode = self.settings.crop_mode
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

--- Change panel finding mode and reopen this page at the nearest new panel.
function ViewerController:toggleViewerPanelFindingMode(viewer)
    if self.settings.mode == "manhwa" and not require("src.manhwa").smart_enabled then
        UIManager:show(require("ui/widget/infomessage"):new({
            text = require("gettext")("Manhwa Smart is not enabled yet. Safe is active."),
            timeout = 3,
        }))
        return true
    end
    local page = viewer.page
    local current = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
    local center = current and {
        x = current.x + current.w / 2,
        y = current.y + current.h / 2,
    }
    self:setPanelFindingMode(self.settings.panel_finding_mode == "smart" and "safe" or "smart")
    -- Close first: the displayed crop, scaled ImageWidget copy, and pending
    -- crops otherwise stay resident throughout the new page detection.
    UIManager:close(viewer)
    local panels = self:collectPanels(page)
    local start_idx = center and PanelCollector.startIndex(panels, center) or 1
    return self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = true })
end

--- Persist a new "With margin" zoom-out ratio from an open viewer's slider dialog.
---
--- Unlike crop mode itself, the ratio doesn't change any crop rectangle, so the
--- viewer is updated in place instead of being rebuilt.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param ratio number New margin ratio in [0, 1].
--- @param activate_margin_mode boolean|nil Also switch crop mode to "margin" so the change is visible.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerMarginRatio(viewer, ratio, activate_margin_mode)
    self:setMarginRatio(ratio)
    if activate_margin_mode then
        self:setCropMode("margin")
    end
    viewer.margin_ratio = self.settings.panel_margin_ratio
    viewer.crop_mode = self.settings.crop_mode
    viewer:replaceButtonTable()
    viewer:update()
    return true
end

--- Persist a new "Loose crop" bleed ratio from an open viewer's slider dialog.
---
--- Unlike the margin ratio, this changes the actual crop rectangle passed to
--- `drawPagePart()`, so the viewer is rebuilt the same way `toggleViewerCropMode`
--- rebuilds it after a mode change.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param ratio number New bleed ratio in [0, 1].
--- @param activate_loose_mode boolean|nil Also switch crop mode to "loose" so the change is visible.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerBleedRatio(viewer, ratio, activate_loose_mode)
    self:setBleedRatio(ratio)
    if activate_loose_mode then
        self:setCropMode("loose")
    end
    if not viewer.panels or #viewer.panels == 0 then
        viewer.crop_mode = self.settings.crop_mode
        viewer.bleed_ratio = self.settings.panel_bleed_ratio
        viewer:replaceButtonTable()
        viewer:update()
        return true
    end

    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(viewer.page, panels, start_idx, { buttons_visible = true })
end

--- Rotate the device/screen to `mode`, then reopen an equivalent viewer for
--- the same page/panel/index so the reader stays in zoom mode across the
--- rotation instead of dropping back to the plain page view.
---
--- Base `ImageViewer` has no live-reflow path for a screen-dimension change
--- while it's showing -- its outer region gets sized once at construction
--- and never revisited -- so closing and rebuilding, exactly like
--- `setViewerBleedRatio` above does for a crop-rectangle change, is the
--- reliable option. `PanelCollector.buildImages()`'s own `drawPagePart()`
--- sizing already fits whatever the *current* screen dimensions are, so the
--- rebuilt viewer comes out correctly sized/oriented for the new rotation
--- for free, once the rotation has actually applied.
---
--- @param viewer PanelViewer Viewer requesting the rotation.
--- @param mode integer Target `Screen.DEVICE_ROTATED_*` rotation mode.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setDeviceRotation(viewer, mode)
    if self.settings.selected_profile_id then
        self.settings.selected_profile_id = nil
        self:saveSettings()
        self:saveDocSettings(true)
    end
    if viewer.embedded_source_image then
        return require("src.embedded_image").setDeviceRotation(self, viewer, mode)
    end
    local page = viewer.page
    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    local buttons_visible = viewer.buttons_visible
    UIManager:close(viewer)
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    UIManager:onRotation()
    self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = buttons_visible })
    return true
end

--- Android's automatic rotation sends ScreenResize after changing the canvas.
--- The current panel bitmap and ImageViewer layout still use the old size.
function ViewerController:resizePanelViewer(viewer)
    local page = viewer.page
    local panels = viewer.panels
    local start_idx = viewer._images_list_cur or 1
    local buttons_visible = viewer.buttons_visible
    UIManager:close(viewer)
    return self:showPanelViewerForPage(page, panels, start_idx, { buttons_visible = buttons_visible })
end

--- Persist a new plugin-only image rotation chosen from the rotation picker.
---
--- Usually the viewer applies the angle in place. A full spread needs a
--- rebuild so automatic rotation gets a source render at its proper fit size;
--- No crop also needs to swap between the source and padded canvas.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param value number|boolean|nil New image rotation (`nil` restores Auto).
--- @return boolean|string handled `"reopened"` when a new viewer replaced this one.
function ViewerController:setViewerImageRotation(viewer, value)
    self:setImageRotation(value)
    local index = viewer._images_list_cur or 1
    if
        DoubleSpread.shouldRotate(
            viewer.panels and viewer.panels[index],
            viewer.panel_is_full_page and viewer.panel_is_full_page[index],
            viewer.panels and #viewer.panels == 1
        )
    then
        local page, panels = viewer.page, viewer.panels
        local buttons_visible = viewer.buttons_visible
        UIManager:close(viewer)
        self:showPanelViewerForPage(page, panels, index, { buttons_visible = buttons_visible })
        return "reopened"
    end
    return true
end

function ViewerController:cycleViewerDetector(_viewer)
    return true
end

--- Toggle progress bar visibility from an open viewer.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerProgressBar(viewer)
    self:setProgressBarVisible(viewer.progress_bar_visible == false)
    viewer.progress_bar_visible = self.settings.progress_bar_visible ~= false
    viewer:replaceButtonTable()
    viewer:update()
    return true
end

---
--- Unlike crop mode or detector, this doesn't change the panel list or any
--- rendered rectangle, so the viewer is updated in place instead of rebuilt.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerNavTransitionMode(viewer)
    local mode = self.settings.mode == "manhwa" and (viewer.nav_transition_mode == "classic" and "smooth" or "classic")
        or NavCapabilities.nextMode(self.settings.nav_transition_mode)
    self:setNavTransitionMode(mode)
    viewer.nav_transition_mode = self.settings.nav_transition_mode
    viewer:replaceButtonTable()
    viewer:update()
    return true
end

--- Persist a new smooth-navigation pan duration from an open viewer's slider dialog.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param seconds number New transition duration in seconds.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerNavTransitionDuration(viewer, seconds)
    self:setNavTransitionDuration(seconds)
    viewer.nav_transition_duration = self.settings.nav_transition_duration
    return true
end

--- Persist a new smooth-navigation frame count from an open viewer's slider dialog.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @param frames integer New step count the camera pan is split into.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:setViewerNavTransitionFrames(viewer, frames)
    self:setNavTransitionFrames(frames)
    viewer.nav_transition_frames = self.settings.nav_transition_frames
    return true
end

--- Show a multi-options menu popup for navigation transition configuration.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:showNavTransitionOptionsMenu(viewer)
    return self:showAdvancedOptions(viewer, "animation")
end

--- Preview the edited Smooth settings, returning to the same panel and menu.
function ViewerController:previewSmoothSettings(viewer, menu_page, skip_preview)
    if
        not viewer
        or viewer.nav_transition_mode ~= "smooth"
        or not viewer.animateSwitchToImageNum
        or viewer._panels_plus_smooth_preview
        or viewer._panels_plus_transition_active
        or viewer._panels_plus_boundary_pending
        or viewer._panels_plus_closed
    then
        return false
    end
    viewer._panels_plus_smooth_preview = true
    local origin = viewer._images_list_cur
    local controls
    local function live()
        return not viewer._panels_plus_closed and viewer:isOpen()
    end
    local function hideControls()
        controls = {
            buttons_visible = viewer.buttons_visible,
            with_title_bar = viewer.with_title_bar,
            fullscreen = viewer.fullscreen,
            progress_bar_visible = viewer.progress_bar_visible,
        }
        viewer.buttons_visible = false
        viewer.with_title_bar = false
        viewer.fullscreen = true
        viewer.progress_bar_visible = false
        viewer:update()
    end
    local function reopen()
        viewer._panels_plus_smooth_preview = nil
        if live() then
            if controls then
                viewer.buttons_visible = controls.buttons_visible
                viewer.with_title_bar = controls.with_title_bar
                viewer.fullscreen = controls.fullscreen
                viewer.progress_bar_visible = controls.progress_bar_visible
                viewer:update()
            end
            self:showAdvancedOptions(viewer, "animation", menu_page)
        end
    end
    -- Setting callbacks run before KOReader dismisses their menu/spinner.
    -- Start on the next tick so trailing close handlers cannot dismiss the
    -- preview or the settings menu that will replace it.
    UIManager:nextTick(function()
        if not live() then
            viewer._panels_plus_smooth_preview = nil
            return
        end
        local reader_menu = self.ui and self.ui.menu
        local container = reader_menu and reader_menu.menu_container
        if container then
            container[1].close_callback()
        end
        local count = viewer._images_list_nb or #(viewer.image_rects or {})
        if skip_preview or self.settings.nav_smooth_preview == false or not origin then
            return reopen()
        end
        if count < 2 then
            local document = self.ui and self.ui.document
            local single_panel_book = false
            if not viewer.embedded_source_image and document and document.getNextPage and document.getPrevPage then
                local next_page = document:getNextPage(viewer.page)
                local previous_page = document:getPrevPage(viewer.page)
                next_page = next_page ~= 0 and next_page or nil
                previous_page = previous_page ~= 0 and previous_page or nil
                single_panel_book = not next_page and not previous_page
                local adjacent_page = next_page or previous_page
                if adjacent_page and viewer.nav_boundary_peek_callback then
                    -- A one-panel page is not a one-panel book. Warm the
                    -- adjacent layout and preview its canvas without turning
                    -- the document page or replacing the original viewer.
                    self:collectPanels(adjacent_page)
                    hideControls()
                    viewer:animateBoundaryTransition(next_page and "next" or "previous", function(played)
                        UIManager:nextTick(function()
                            reopen()
                            if not played and live() then
                                viewer:showSmoothPreviewUnavailableWarning()
                            end
                        end)
                    end)
                    return
                end
            end
            reopen()
            return viewer:showSmoothPreviewUnavailableWarning(single_panel_book)
        end
        -- At the end, preview backward first; always return to the original
        -- panel without leaving the document or opening boundary prompts.
        local target = origin < count and origin + 1 or origin - 1
        hideControls()
        viewer:animateSwitchToImageNum(target, function()
            -- Let the landing panel remain visible before reversing.
            UIManager:scheduleIn(0.15, function()
                if not live() then
                    viewer._panels_plus_smooth_preview = nil
                    return
                end
                viewer:animateSwitchToImageNum(origin, function()
                    UIManager:nextTick(reopen)
                end)
            end)
        end)
    end)
    return true
end

--- Toggle tapping the screen's left/right edges to navigate between panels,
--- from an open viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerTapNavigation(viewer)
    self:setTapNavigation(self.settings.tap_navigation ~= true)
    viewer.tap_navigation = self.settings.tap_navigation
    return true
end

--- Toggle swiping left/right to navigate between panels, from an open
--- viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerSwipeNavigation(viewer)
    self:setSwipeNavigation(self.settings.swipe_navigation == false)
    viewer.swipe_navigation = self.settings.swipe_navigation
    return true
end

--- Set whether Kobo-like vertical edge gestures for zooming in/out are enabled.
---
--- @param enabled any Truthy value enables Kobo-style left-edge vertical zoom.
function ViewerController:setKoboVerticalGesture(enabled)
    self.settings.kobo_vertical_gesture = enabled and true or false
    if self.saveSettings then
        self:saveSettings()
    end
end

--- Toggle Kobo-like vertical edge gestures for zooming in/out, from an open
--- viewer, in place.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:toggleViewerKoboVerticalGesture(viewer)
    self:setKoboVerticalGesture(self.settings.kobo_vertical_gesture == false)
    viewer.kobo_vertical_gesture = self.settings.kobo_vertical_gesture
    return true
end

--- Return whether Animated mode should play a framebuffer page transition.
function ViewerController:isPageTurnAnimationActive(viewer)
    return self.settings.mode ~= "manhwa"
        and Device:canDoSwipeAnimation()
        and viewer
        and viewer.nav_transition_mode == "animated"
        and viewer.nav_animated_pages ~= false
end

--- Return the physical direction expected by KOReader's framebuffer API.
--- `true` moves left (right-to-left); `false` moves right (left-to-right).
--- Forward Comic navigation moves left, while forward Manga navigation moves
--- right. Previous navigation reverses the matching direction.
local function animatedTransitionMovesLeft(direction, viewer)
    local moves_left = viewer.reading_mode == "comic"
    if direction == "previous" then
        moves_left = not moves_left
    end
    return moves_left
end

--- Arm one framebuffer page animation for the next refresh in Animated mode.
function ViewerController:armPageTurnAnimation(direction, viewer)
    if not self:isPageTurnAnimationActive(viewer) then
        return false
    end
    Screen:setSwipeAnimations(true)
    Screen:setSwipeDirection(animatedTransitionMovesLeft(direction, viewer))
    return true
end

--- Arm one framebuffer animation for a panel-to-panel switch in Animated mode.
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param viewer PanelViewer Active panel viewer.
--- @return boolean armed Whether an animation was armed.
function ViewerController:armPanelTransitionAnimation(direction, viewer)
    if
        self.settings.mode == "manhwa"
        or not Device:canDoSwipeAnimation()
        or not viewer
        or viewer.nav_transition_mode ~= "animated"
        or viewer.nav_animated_panels == false
    then
        return false
    end
    Screen:setSwipeAnimations(true)
    Screen:setSwipeDirection(animatedTransitionMovesLeft(direction, viewer))
    return true
end

--- Rebuild an open viewer at the same panel after a spread option changed.
---
--- The options change how images are rendered (rotated size, fold strip) and which rotation the
--- screen is in, so the viewer is rebuilt like `toggleViewerCropMode` does. An embedded image
--- viewer has its own rebuild path and is kept.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return PanelViewer viewer The viewer now on screen.
function ViewerController:rebuildViewerForSpreadOptions(viewer)
    local panels = viewer.panels
    if viewer.embedded_source_image or not panels or #panels == 0 then
        return viewer
    end
    local page, index = viewer.page, viewer._images_list_cur or 1
    UIManager:close(viewer)
    return self:showPanelViewerForPage(page, panels, index, { buttons_visible = true, return_viewer = true })
end

local SPREAD_ROTATION_CYCLE = { off = "viewer", viewer = "reading", reading = "both", both = "off" }

--- Step the spread rotation choice from an open viewer.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return PanelViewer viewer The viewer now on screen.
function ViewerController:cycleViewerSpreadRotationMode(viewer)
    self:setSpreadRotationMode(SPREAD_ROTATION_CYCLE[DoubleSpread.rotationMode(self.settings)] or "viewer")
    viewer.auto_rotate_double_pages = self.settings.auto_rotate_double_pages ~= false
    return self:rebuildViewerForSpreadOptions(viewer)
end

--- Toggle `join_spread_fold` from an open viewer.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return PanelViewer viewer The viewer now on screen.
function ViewerController:toggleViewerJoinSpreadFold(viewer)
    self:setJoinSpreadFold(self.settings.join_spread_fold == false)
    return self:rebuildViewerForSpreadOptions(viewer)
end

--- Resolve a saved OCR choice against models currently installed on this device.
local function selectedOcrModel(settings, document)
    local choice = settings.ocr_bundled_language
    -- Older settings used "koreader" to mean the document's OCR language.
    if choice == "koreader" then
        local language = document and document.configurable and document.configurable.doc_language
        choice = language and ("user:" .. language) or nil
    end
    local bundled = WordFinder.availableBundledLanguages()
    for _, language in ipairs(bundled) do
        if choice == language then
            return choice
        end
    end
    local installed = WordFinder.availableUserLanguages()
    for _, language in ipairs(installed) do
        if choice == "user:" .. language then
            return choice
        end
    end
    if #bundled > 0 then
        return bundled[1]
    end
    return installed[1] and ("user:" .. installed[1]) or false
end

function ViewerController:getSelectedOcrModel()
    return selectedOcrModel(self.settings, self.ui and self.ui.document)
end

function ViewerController:setBundledOcrLanguage(viewer, language)
    if language ~= "koreader" and not WordFinder.selectedModel(language) then
        return
    end
    local previous = self:getSelectedOcrModel()
    if previous and previous ~= language then
        if previous:match("^user:") then
            self.settings.ocr_preferred_user_language = previous
        else
            self.settings.ocr_preferred_bundled_language = previous
        end
    end
    self.settings.ocr_bundled_language = language
    if language:match("^user:") then
        self.settings.ocr_preferred_user_language = language
    elseif language ~= "koreader" then
        self.settings.ocr_preferred_bundled_language = language
    end
    if viewer then
        viewer.ocr_bundled_language = self:getSelectedOcrModel()
    end
    self:saveSettings()
    if self.saveDocSettings then
        self:saveDocSettings(true)
    end
end

--- Show all installed OCR models in a scrollable KOReader menu over the viewer.
function ViewerController:showOcrLanguageMenu(viewer)
    local Menu = require("ui/widget/menu")
    local _ = require("gettext")
    local labels = { eng = _("English"), spa = _("Spanish") }
    local items = {}
    local menu
    local container
    local active = self:getSelectedOcrModel()
    local active_index
    local bundled = WordFinder.availableBundledLanguages()
    local installed = WordFinder.availableUserLanguages()

    local function chosenInGroup(candidates, prefix, preferred)
        for _, code in ipairs(candidates) do
            local id = prefix .. code
            if id == active then
                return id
            end
        end
        for _, code in ipairs(candidates) do
            local id = prefix .. code
            if id == preferred then
                return id
            end
        end
        return candidates[1] and (prefix .. candidates[1]) or nil
    end

    local chosen_bundled = chosenInGroup(bundled, "", self.settings.ocr_preferred_bundled_language)
    local chosen_user = chosenInGroup(installed, "user:", self.settings.ocr_preferred_user_language)

    local function addChoice(id, label, group_choice)
        local is_selected = group_choice == id
        items[#items + 1] = {
            text = (is_selected and "◉ " or "○ ") .. label,
            bold = is_selected,
            mandatory = active == id and _("In use") or nil,
            callback = function()
                self:setBundledOcrLanguage(viewer, id)
                menu.close_callback = nil
                UIManager:close(container)
                self:showOcrLanguageMenu(viewer)
            end,
        }
        if active == id then
            active_index = #items
        end
    end

    if #bundled > 0 then
        items[#items + 1] = {
            text = _("Panels+ Fine-Tuned"),
            bold = true,
            select_enabled = false,
        }
        for _, language in ipairs(bundled) do
            addChoice(language, labels[language] or language, chosen_bundled)
        end
    end

    if #installed > 0 then
        items[#items + 1] = {
            text = _("KOReader User Installed"),
            bold = true,
            select_enabled = false,
            separator = #bundled > 0,
        }
        local ok, iso_language = pcall(require, "ui/data/isolanguage")
        for _, language in ipairs(installed) do
            local name = ok and iso_language:getLocalizedLanguage(language) or nil
            addChoice("user:" .. language, name and (name .. " (" .. language .. ")") or language, chosen_user)
        end
    end

    if #bundled == 0 and #installed == 0 then
        items[#items + 1] = {
            text = "",
            select_enabled = false,
        }
        items[#items + 1] = {
            text = _("Install Panels+ with OCR bundled, or install your own OCR models in /koreader/data/tessdata"),
            select_enabled = false,
        }
    end
    items[#items + 1] = {
        text = _("Close"),
        separator = true,
        callback = function()
            menu.close_callback = nil
            UIManager:close(container)
        end,
    }
    items.current = active_index
    local screen_width, screen_height = Screen:getWidth(), Screen:getHeight()
    container = CenterContainer:new({ dimen = Geom:new({ w = screen_width, h = screen_height }) })
    menu = Menu:new({
        title = _("Select OCR Model"),
        item_table = items,
        width = math.min(math.floor(screen_width * 0.88), math.floor(screen_height * 0.9)),
        height = math.floor(screen_height * 0.82),
        items_per_page = math.min(8, #items),
        show_parent = container,
    })
    menu.close_callback = function()
        UIManager:close(container)
    end
    container[1] = menu
    UIManager:show(container)
    return true
end

--- Find a live viewer, including embedded-image viewers which are not tracked
--- by active_panel_viewer. The explicit context also supports menus in tests.
function ViewerController:getOpenPanelViewer()
    for i = #(UIManager._window_stack or {}), 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if
            widget
            and widget.reader_ui == self.ui
            and widget.name == PanelViewer.name
            and not widget._panels_plus_closed
        then
            return widget
        end
    end
    local viewer = self._panels_plus_config_viewer or self.active_panel_viewer
    return viewer and not viewer._panels_plus_closed and viewer or nil
end

local function submenuPath(items, predicate)
    for index, item in ipairs(items or {}) do
        item.idx = index
        if predicate(item) then
            return { item }
        end
        local children = item.sub_item_table or item
        if children ~= items then
            local path = submenuPath(children, predicate)
            if path then
                table.insert(path, 1, item)
                return path
            end
        end
    end
end

--- Enter the real reader menu before showing it; no translated labels or
--- hardcoded tab positions. Both TouchMenu and keyboard Menu keep their own
--- normal Back stack through onMenuSelect.
function ViewerController:showAdvancedOptions(viewer, section, page)
    local reader_menu = self.ui and self.ui.menu
    if not reader_menu then
        return false
    end
    self._panels_plus_config_viewer = viewer
    reader_menu:onShowMenu(nil, true)
    local container = reader_menu.menu_container
    local menu = container[1]
    local predicate = function(item)
        return section and item.panels_plus_section == section or (not section and item.panels_plus_menu)
    end
    local path
    if menu.switchMenuTab then
        for tab, items in ipairs(menu.tab_item_table) do
            path = submenuPath(items, predicate)
            if path then
                menu.bar:switchToTab(tab)
                break
            end
        end
    else
        path = submenuPath(menu.item_table, predicate)
    end
    if not path then
        reader_menu:onCloseReaderMenu()
        self._panels_plus_config_viewer = nil
        UIManager:show(require("ui/widget/infomessage"):new({
            text = require("gettext")("Panels+ advanced options are unavailable."),
        }))
        return false
    end
    for _, item in ipairs(path) do
        menu:onMenuSelect(item)
    end
    if page and page > 1 then
        menu.page = page
        menu:updateItems()
    end
    local original_close = menu.close_callback
    menu.close_callback = function()
        original_close()
        local current = self:getOpenPanelViewer()
        self._panels_plus_config_viewer = nil
        local rebuild = self._panels_plus_spread_options_changed
        self._panels_plus_spread_options_changed = nil
        if rebuild and current then
            self:rebuildViewerForSpreadOptions(current)
        end
    end
    menu.not_shown = false
    UIManager:show(container)
    return true
end

--- Show a multi-options menu popup for miscellaneous panel viewer settings
--- that don't need their own dedicated button.
---
--- @param viewer PanelViewer Active panel viewer instance.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:showMoreConfigMenu(viewer, page)
    local _ = require("gettext")
    local container = CenterContainer:new({
        dimen = Geom:new({ w = Screen:getWidth(), h = Screen:getHeight() }),
    })
    local menu
    local function close()
        -- A selection callback may open a replacement menu. Prevent KOReader's
        -- trailing close callback from closing or reopening that replacement.
        menu.close_callback = nil
        UIManager:close(container)
    end
    local function reopen(current_viewer)
        close()
        self:showMoreConfigMenu(current_viewer or viewer, menu.page)
    end
    local function toggle(id, text, key, callback)
        return {
            id = id,
            text = _(text),
            mandatory = self.settings[key] ~= false and _("On") or _("Off"),
            callback = function()
                callback()
                reopen()
            end,
        }
    end
    local tap = toggle("tap", "Tap screen sides to navigate", "tap_navigation", function()
        self:toggleViewerTapNavigation(viewer)
    end)
    tap.mandatory = self.settings.tap_navigation == true and _("On") or _("Off")
    local invert_swipe = toggle("invert_swipe", "Invert panel swipe direction", "invert_swipe", function()
        self:setInvertSwipe(self.settings.invert_swipe ~= true)
        viewer.invert_swipe = self.settings.invert_swipe
    end)
    invert_swipe.mandatory = self.settings.invert_swipe == true and _("On") or _("Off")
    local invert_taps = toggle("invert_taps", "Invert tap direction", "invert_taps", function()
        self:setInvertTaps(self.settings.invert_taps ~= true)
        viewer.invert_taps = self.settings.invert_taps
    end)
    invert_taps.mandatory = self.settings.invert_taps == true and _("On") or _("Off")
    local labels = { off = _("Off"), viewer = _("Viewer"), reading = _("Reading"), both = _("Viewer + reading") }
    local items = {
        tap,
        toggle("swipe", "Swipe to navigate", "swipe_navigation", function()
            self:toggleViewerSwipeNavigation(viewer)
        end),
        invert_swipe,
        invert_taps,
        {
            id = "panel_gesture",
            text = _("Open panels with"),
            mandatory = self.settings.panel_gesture == "two_finger_tap" and _("Two-finger tap") or _("Long press"),
            callback = function()
                close()
                local picker
                picker = require("ui/widget/menu"):new({
                    title = _("Open panels with"),
                    item_table = require("src.menu").panelGestureItems(self),
                    close_callback = function()
                        UIManager:close(picker)
                        self:showMoreConfigMenu(viewer, menu.page)
                    end,
                })
                UIManager:show(picker)
            end,
        },
        {
            id = "rotate",
            text = _("Rotate spreads"),
            mandatory = labels[DoubleSpread.rotationMode(self.settings)],
            callback = function()
                close()
                self:showMoreConfigMenu(self:cycleViewerSpreadRotationMode(viewer), menu.page)
            end,
        },
        {
            id = "fold",
            text = _("Remove spread fold line"),
            mandatory = self.settings.join_spread_fold ~= false and _("On") or _("Off"),
            callback = function()
                close()
                self:showMoreConfigMenu(self:toggleViewerJoinSpreadFold(viewer), menu.page)
            end,
        },
        toggle("text_selection", "Touch & hold text selection", "hold_text_selection", function()
            self:setHoldTextSelection(self.settings.hold_text_selection == false)
            viewer.hold_text_selection = self.settings.hold_text_selection
            viewer:replaceButtonTable()
            viewer:update()
        end),
        {
            id = "advanced",
            text = _("Open advanced options"),
            bold = true,
            mandatory = "›",
            separator = true,
            callback = function()
                close()
                self:showAdvancedOptions(viewer)
            end,
        },
    }
    menu = require("src._configmenu").new({
        title = _("More Config"),
        item_table = items,
        show_parent = container,
        close_callback = function()
            UIManager:close(container)
        end,
    })
    container[1] = menu
    if page and page > 1 then
        -- Menu:init() always starts at page one. Restore after construction;
        -- updateItems also clamps the page if a rotation changed pagination.
        menu.page = page
        menu:updateItems()
    end
    UIManager:show(container)
    return true
end

--- Start panel sequence viewing from a native panel-zoom hold gesture.
---
--- @param reader_highlight table KOReader reader highlight module.
--- @param ges table Gesture event containing a screen-space `pos`.
--- @return boolean handled `true` when the plugin opens a viewer.
function ViewerController:showPanelSequence(reader_highlight, ges)
    reader_highlight:clear()
    local hold_pos = reader_highlight.view:screenToPageTransform(ges.pos)
    if not hold_pos then
        return false
    end

    local panels = self:collectPanels(hold_pos.page, hold_pos)
    if #panels == 0 then
        Timing.log("showPanelSequence: page %d had no panels detected at hold position", hold_pos.page)
        return false
    end

    if self.settings and self.settings.mode == "manhwa" then
        local layout = require("src.manhwa").layout(self.ui.document)
        hold_pos.y = hold_pos.y + layout.pages[layout:indexForPage(hold_pos.page)].y
    end
    local start_idx = PanelCollector.startIndex(panels, hold_pos)
    Timing.log("showPanelSequence: page %d panels=%d start_idx=%d", hold_pos.page, #panels, start_idx)
    Timing.memory("show_panel_sequence")
    return self:showPanelViewerForPage(hold_pos.page, panels, start_idx)
end

--- Open a `PanelViewer` for an ordered page-panel sequence.
---
--- @param page number Document page number.
--- @param panels PPPanel[] Ordered panel rectangles.
--- @param start_idx number|nil 1-based panel index to display first.
--- @param options PPShowViewerOptions|nil Viewer behavior flags.
--- @return boolean|PanelViewer result `true` by default, or viewer when requested.
function ViewerController:showPanelViewerForPage(page, panels, start_idx, options)
    options = options or {}
    self:cancelPanelPrerender()
    Timing.log(
        "showPanelViewerForPage: page=%d panels=%d start_idx=%d crop_mode=%s transition_mode=%s",
        page,
        #panels,
        start_idx or 1,
        tostring(self.settings.crop_mode),
        tostring(self.settings.nav_transition_mode)
    )
    Timing.memory("show_panel_viewer")
    -- Restore the reader's rotation first if the screen was rotated for a
    -- spread, so the viewer is laid out for it.
    if self.settings.mode ~= "manhwa" then
        SpreadRotation.prepareSpreadRotationForViewer(self, page, panels)
    end
    local images, image_rects, full_page_flags = PanelCollector.buildImages(self.ui, page, panels, self.settings)
    local viewer
    viewer = PanelViewer:new({
        image = images,
        image_disposable = true,
        images_list_nb = #images,
        initial_image_num = start_idx,
        page = page,
        panels = panels,
        image_rects = image_rects,
        panel_is_full_page = full_page_flags,
        reader_ui = self.ui,
        image_union_renderer = self.settings.mode == "manhwa" and function(rect, zoom)
            return require("src.manhwa").render(self.ui, rect, zoom)
        end or nil,
        panel_prerender_callback = function(current_viewer, index)
            return self:prerenderNextPanel(current_viewer, index)
        end,
        reading_mode = self.settings.mode,
        crop_mode = self.settings.crop_mode,
        profile_name_callback = function()
            return require("src.profile_menu").getSettingsProfileName(self)
        end,
        settings_profile_callback = function(current_viewer)
            return self:showSettingsProfileMenu(current_viewer)
        end,
        panel_finding_mode = self.settings.panel_finding_mode,
        margin_ratio = self.settings.panel_margin_ratio,
        bleed_ratio = self.settings.panel_bleed_ratio,
        detector = "components",
        invert_swipe = self.settings.invert_swipe == true,
        invert_taps = self.settings.invert_taps == true,
        tap_navigation = self.settings.tap_navigation == true,
        swipe_navigation = self.settings.swipe_navigation ~= false,
        kobo_vertical_gesture = self.settings.kobo_vertical_gesture ~= false,
        progress_bar_visible = self.settings.progress_bar_visible ~= false,
        hold_text_selection = self.settings.hold_text_selection ~= false,
        prefer_native_text_layer = self.settings.prefer_native_text_layer ~= false,
        ocr_bundled_language = self:getSelectedOcrModel(),
        image_rotation = self.settings.mode == "manhwa" and 0 or self.settings.image_rotation,
        auto_rotate_double_pages = self.settings.mode ~= "manhwa" and self.settings.auto_rotate_double_pages ~= false,
        spread_rotation_direction = self.settings.spread_rotation_direction,
        nav_transition_mode = self.settings.mode == "manhwa"
                and self.settings.nav_transition_mode == "animated"
                and "smooth"
            or (self.settings.nav_transition_mode or "classic"),
        nav_smooth_style = self.settings.nav_smooth_style or Settings.defaults.nav_smooth_style,
        nav_animated_panels = self.settings.nav_animated_panels ~= false,
        nav_animated_pages = self.settings.nav_animated_pages ~= false,
        nav_transition_duration = self.settings.nav_transition_duration or Settings.defaults.nav_transition_duration,
        nav_transition_cross_page = self.settings.nav_transition_cross_page == true,
        nav_transition_frames = self.settings.nav_transition_frames or Settings.defaults.nav_transition_frames,
        buttons_visible = options.buttons_visible == true,
        boundary_callback = function(direction, current_viewer)
            return self:onPanelViewerBoundary(direction, current_viewer)
        end,
        mode_toggle_callback = function(current_viewer)
            return self:toggleViewerMode(current_viewer)
        end,
        crop_toggle_callback = function(current_viewer)
            return self:toggleViewerCropMode(current_viewer)
        end,
        panel_finding_toggle_callback = function(current_viewer)
            return self:toggleViewerPanelFindingMode(current_viewer)
        end,
        margin_ratio_callback = function(current_viewer, ratio, activate_margin_mode)
            return self:setViewerMarginRatio(current_viewer, ratio, activate_margin_mode)
        end,
        bleed_ratio_callback = function(current_viewer, ratio, activate_loose_mode)
            return self:setViewerBleedRatio(current_viewer, ratio, activate_loose_mode)
        end,
        progress_bar_toggle_callback = function(current_viewer)
            return self:toggleViewerProgressBar(current_viewer)
        end,
        nav_transition_toggle_callback = function(current_viewer)
            return self:toggleViewerNavTransitionMode(current_viewer)
        end,
        nav_smooth_style_callback = function(current_viewer, style)
            self:setNavSmoothStyle(style)
            current_viewer.nav_smooth_style = self.settings.nav_smooth_style
        end,
        nav_transition_duration_callback = function(current_viewer, seconds)
            return self:setViewerNavTransitionDuration(current_viewer, seconds)
        end,
        nav_transition_frames_callback = function(current_viewer, frames)
            return self:setViewerNavTransitionFrames(current_viewer, frames)
        end,
        nav_transition_cross_page_callback = function(current_viewer, enabled)
            self:setNavTransitionCrossPage(enabled)
            current_viewer.nav_transition_cross_page = self.settings.nav_transition_cross_page == true
            return true
        end,
        nav_transition_options_callback = function(current_viewer)
            return self:showNavTransitionOptionsMenu(current_viewer)
        end,
        panel_animation_callback = function(direction, current_viewer)
            return self:armPanelTransitionAnimation(direction, current_viewer)
        end,
        nav_boundary_peek_callback = function(direction, current_viewer)
            return self:resolveBoundaryTarget(direction, current_viewer)
        end,
        nav_boundary_commit_callback = function(current_viewer, direction, resolved)
            return self:commitBoundaryTransition(direction, current_viewer, resolved)
        end,
        device_rotate_callback = function(current_viewer, mode)
            return self:setDeviceRotation(current_viewer, mode)
        end,
        screen_resize_callback = function(current_viewer)
            return self:resizePanelViewer(current_viewer)
        end,
        image_rotation_callback = function(current_viewer, value)
            return self:setViewerImageRotation(current_viewer, value)
        end,
        more_config_callback = function(current_viewer)
            return self:showMoreConfigMenu(current_viewer)
        end,
        ocr_language_callback = function(current_viewer)
            return self:showOcrLanguageMenu(current_viewer)
        end,
        closed_callback = function(closed_viewer)
            self:cancelPanelPrerender()
            SpreadRotation.onPanelViewerClosed(self, closed_viewer)
        end,
    })
    -- Set before the replaced viewer closes, so its close is not treated as
    -- leaving the viewer.
    self.active_panel_viewer = viewer

    if options.replace_viewer then
        self:armPageTurnAnimation(options.boundary_direction, options.replace_viewer)
        UIManager:close(options.replace_viewer)
    end
    UIManager:show(viewer)
    if not options.defer_preload then
        self:preloadNextPanels(page)
    end
    if options.return_viewer then
        return viewer
    end
    return true
end

--- Look up the adjacent page's panels for a boundary crossing, if already
--- cached, without any side effects (no GotoPage, no closing/opening viewers,
--- no triggering detection).
---
--- Callers must fall back to the classic instant boundary crossing when this
--- returns `nil` -- it deliberately never waits for detection, so an animated
--- crossing only ever happens when `preloadNextPanels` has already warmed the
--- adjacent page in the background.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer.
--- @return PPBoundaryResolution|nil resolved `nil` when there is no next/prev
---   page, or its panels are not (yet) cached.
function ViewerController:resolveBoundaryTarget(direction, current_viewer)
    if self.settings and self.settings.mode == "manhwa" then
        local page, panels, index = require("src.manhwa").adjacent(self.ui, self.settings, current_viewer, direction)
        if not page then
            return nil
        end
        local images, rects, flags = PanelCollector.buildImages(self.ui, page, panels, self.settings)
        return {
            next_page = page,
            panels = panels,
            start_idx = index,
            target_rect = rects[index],
            target_is_full_page = flags[index],
            next_images = images,
        }
    end
    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    if not next_page or next_page == 0 then
        return nil
    end

    local cached_panels = self:getCachedPanels(next_page)
    if not cached_panels then
        return nil
    end
    if #cached_panels == 0 then
        cached_panels = PanelCollector.fullPage(self.ui.document, next_page)
        if #cached_panels == 0 then
            return nil
        end
    end

    local start_idx = direction == "next" and 1 or #cached_panels
    local next_images, image_rects, full_page_flags =
        PanelCollector.buildImages(self.ui, next_page, cached_panels, self.settings)
    return {
        next_page = next_page,
        panels = cached_panels,
        start_idx = start_idx,
        target_rect = image_rects[start_idx],
        target_is_full_page = full_page_flags and full_page_flags[start_idx] == true or false,
        next_images = next_images,
    }
end

--- Perform the actual page turn for a boundary crossing: GotoPage, close the
--- current viewer, open the adjacent one at the resolved panel.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer being replaced.
--- @param resolved PPBoundaryResolution Result of a prior `resolveBoundaryTarget` call.
--- @return boolean|PanelViewer result Whatever `showPanelViewerForPage` returns.
function ViewerController:commitBoundaryTransition(direction, current_viewer, resolved)
    -- Smooth crossings arrive here without going through
    -- `onPanelViewerBoundary`. Sample immediately before `GotoPage` so both
    -- paths preserve the user's current device orientation, including any
    -- change made while a deferred panel lookup was running.
    local rotation_mode = Screen:getRotationMode()
    Timing.log(
        "commitBoundaryTransition: direction=%s page=%d -> %d target_panel=%d",
        direction,
        current_viewer and current_viewer.page or -1,
        resolved.next_page,
        resolved.start_idx
    )
    self.ui:handleEvent(Event:new("GotoPage", resolved.next_page))
    self:restoreDeviceRotation(rotation_mode)
    return self:showPanelViewerForPage(resolved.next_page, resolved.panels, resolved.start_idx, {
        replace_viewer = current_viewer,
        boundary_direction = direction,
    })
end

--- Move to the adjacent page when panel navigation crosses viewer boundaries.
---
--- @param direction PPBoundaryDirection `"next"` or `"previous"`.
--- @param current_viewer PanelViewer Active panel viewer.
--- @return boolean handled Always true for viewer callback dispatch.
function ViewerController:onPanelViewerBoundary(direction, current_viewer)
    if current_viewer._panels_plus_boundary_pending then
        return true
    end
    current_viewer._panels_plus_boundary_pending = true
    if self.settings and self.settings.mode == "manhwa" then
        local resolved = self:resolveBoundaryTarget(direction, current_viewer)
        if resolved then
            return self:commitBoundaryTransition(direction, current_viewer, resolved)
        end
        current_viewer._panels_plus_boundary_pending = nil
        return current_viewer:confirmDocumentBoundary(direction, self.ui)
    end

    local next_page
    if direction == "next" then
        next_page = self.ui.document:getNextPage(current_viewer.page)
    else
        next_page = self.ui.document:getPrevPage(current_viewer.page)
    end
    Timing.log(
        "onPanelViewerBoundary: direction=%s page=%d next_page=%s",
        direction,
        current_viewer and current_viewer.page or -1,
        tostring(next_page)
    )
    if not next_page or next_page == 0 then
        current_viewer._panels_plus_boundary_pending = nil
        return current_viewer:confirmDocumentBoundary(direction, self.ui)
    end

    local resolved = self:resolveBoundaryTarget(direction, current_viewer)
    if resolved then
        return self:commitBoundaryTransition(direction, current_viewer, resolved)
    end

    local cached_panels = self:getCachedPanels(next_page)
    if cached_panels then
        -- The full-page fallback above also needs valid native dimensions.
        -- If the document cannot provide them, keep the current viewer open.
        current_viewer._panels_plus_boundary_pending = nil
        return true
    end

    UIManager:tickAfterNext(function()
        if current_viewer._panels_plus_closed then
            return
        end
        local loaded_panels = self:collectPanels(next_page)
        if #loaded_panels == 0 then
            loaded_panels = PanelCollector.fullPage(self.ui.document, next_page)
        end
        if #loaded_panels > 0 then
            local rotation_mode = Screen:getRotationMode()
            self.ui:handleEvent(Event:new("GotoPage", next_page))
            self:restoreDeviceRotation(rotation_mode)
            local start_idx = direction == "next" and 1 or #loaded_panels
            self:showPanelViewerForPage(next_page, loaded_panels, start_idx, {
                replace_viewer = current_viewer,
                boundary_direction = direction,
            })
        else
            current_viewer._panels_plus_boundary_pending = nil
        end
    end)
    return true
end

return ViewerController
