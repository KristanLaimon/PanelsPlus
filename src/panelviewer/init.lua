--[[
Panels+
File: src/panelviewer/init.lua
Name: PanelViewer
Description: Composes the focused-panel ImageViewer subclass.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local ImageViewer = require("ui/widget/imageviewer")

local NAV_TRANSITION_STEPS_DEFAULT = require("src.panelviewer.constants").NAV_TRANSITION_STEPS_DEFAULT

--- ImageViewer subclass for navigating one page's ordered panel sequence.
---
--- @class PanelViewer : ImageViewer
--- @field reading_mode PPReadingMode Current left/right panel order.
--- @field crop_mode PPCropMode Current crop rendering mode.
--- @field panel_finding_mode PPPanelFindingMode Current panel detector choice.
--- @field margin_ratio number Zoom-out fraction "margin" crop mode applies to non-full-page panels.
--- @field bleed_ratio number Fraction of extra page area "loose" crop mode reveals around each panel.
--- @field panel_is_full_page boolean[]|nil Per-panel flag matching `_images_list`, true when a panel spans nearly the whole page.
--- @field initial_image_num integer|nil Image list entry to render during initialization instead of rendering entry 1 first.
--- @field auto_rotate_double_pages boolean Whether wide full-page images rotate inside a portrait viewer.
--- @field detector PPDetector Detector the displayed panels came from.
--- @field detector_cycle_callback fun(viewer:PanelViewer):boolean|nil
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field invert_taps boolean Whether side tap direction is inverted.
--- @field tap_navigation boolean Whether tapping the left/right screen edges navigates between panels.
--- @field swipe_navigation boolean Whether horizontal swipes navigate between panels.
--- @field more_config_callback fun(viewer:PanelViewer):boolean|nil
--- @field ocr_language_callback fun(viewer:PanelViewer):boolean|nil
--- @field closed_callback fun(viewer:PanelViewer)|nil Called once the viewer has closed.
--- @field progress_bar_visible boolean Whether the bottom progress bar is shown.
--- @field nav_transition_mode PPNavTransitionMode Classic, Smooth camera-pan, or framebuffer Animated navigation.
--- @field nav_animated_panels boolean Whether Animated mode animates panel-to-panel switches.
--- @field nav_animated_pages boolean Whether Animated mode animates page-boundary switches.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field nav_transition_cross_page boolean Whether smooth navigation also animates across page boundaries.
--- @field nav_transition_frames integer Number of discrete steps a smooth camera pan is split into.
--- @field page number|nil Document page number represented by `panels`.
--- @field panels PPPanel[]|nil Ordered panel rectangles.
--- @field image_rects PPPanel[]|nil Crop rectangles matching `_images_list`, for prerendering.
--- @field embedded_source_image Blitbuffer|nil Decoded reflow image owned by this viewer.
--- @field image_union_renderer fun(union:PPRect, zoom:number):Blitbuffer|nil Optional image-space union renderer for smooth transitions.
--- @field screen_resize_callback fun(viewer:PanelViewer):boolean|nil Rebuild the viewer after Android changes the screen size.
--- @field embedded_cleanup_callback fun(viewer:PanelViewer):nil|nil Owner hook that cancels an embedded page search.
--- @field reader_ui table|nil Reader UI that owns the normal document gesture zones.
--- @field panel_prerender_callback fun(viewer:PanelViewer, index:integer)|nil
--- @field boundary_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field mode_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field crop_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field panel_finding_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field margin_ratio_callback fun(viewer:PanelViewer, ratio:number, activate_margin_mode:boolean|nil):boolean|nil
--- @field bleed_ratio_callback fun(viewer:PanelViewer, ratio:number, activate_loose_mode:boolean|nil):boolean|nil
--- @field progress_bar_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field nav_transition_toggle_callback fun(viewer:PanelViewer):boolean|nil
--- @field nav_smooth_style_callback fun(viewer:PanelViewer, style:string)|nil
--- @field nav_transition_duration_callback fun(viewer:PanelViewer, seconds:number):boolean|nil
--- @field nav_transition_frames_callback fun(viewer:PanelViewer, frames:integer):boolean|nil
--- @field nav_transition_options_callback fun(viewer:PanelViewer):boolean|nil
--- @field panel_animation_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil
--- @field nav_boundary_peek_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):PPBoundaryResolution|nil
--- @field nav_boundary_commit_callback fun(viewer:PanelViewer, direction:PPBoundaryDirection, resolved:PPBoundaryResolution):boolean|nil
--- @field buttons_visible boolean Whether controls are currently shown.
--- @field with_title_bar boolean Whether ImageViewer title bar is shown.
--- @field fullscreen boolean Whether the viewer is fullscreen.
--- @field images_keep_pan_and_zoom boolean Whether ImageViewer preserves pan/zoom.
local PanelViewer = ImageViewer:extend({
    name = "panels_plus_panel_viewer",
    reading_mode = "manga",
    crop_mode = "strict",
    panel_finding_mode = "safe",
    margin_ratio = 0.12,
    bleed_ratio = 0.08,
    panel_is_full_page = nil,
    initial_image_num = nil,
    auto_rotate_double_pages = true,
    spread_rotation_direction = nil,
    detector = "exact",
    invert_swipe = false,
    invert_taps = false,
    tap_navigation = true,
    swipe_navigation = true,
    more_config_callback = nil,
    ocr_language_callback = nil,
    closed_callback = nil,
    progress_bar_visible = true,
    hold_text_selection = true,
    prefer_native_text_layer = true,
    ocr_bundled_language = false,
    nav_transition_mode = "classic",
    nav_smooth_style = "ease",
    nav_animated_panels = true,
    nav_animated_pages = true,
    nav_transition_duration = 0.4,
    nav_transition_cross_page = true,
    nav_transition_frames = NAV_TRANSITION_STEPS_DEFAULT,
    page = nil,
    panels = nil,
    image_rects = nil,
    embedded_source_image = nil,
    image_union_renderer = nil,
    screen_resize_callback = nil,
    embedded_cleanup_callback = nil,
    reader_ui = nil,
    panel_prerender_callback = nil,
    detector_cycle_callback = nil,
    boundary_callback = nil,
    mode_toggle_callback = nil,
    crop_toggle_callback = nil,
    panel_finding_toggle_callback = nil,
    margin_ratio_callback = nil,
    bleed_ratio_callback = nil,
    progress_bar_toggle_callback = nil,
    nav_transition_toggle_callback = nil,
    nav_smooth_style_callback = nil,
    nav_transition_duration_callback = nil,
    nav_transition_frames_callback = nil,
    nav_transition_cross_page_callback = nil,
    nav_transition_options_callback = nil,
    panel_animation_callback = nil,
    nav_boundary_peek_callback = nil,
    nav_boundary_commit_callback = nil,
    buttons_visible = false,
    with_title_bar = false,
    fullscreen = true,
    images_keep_pan_and_zoom = false,
    mousewheel_zoom_step = 0.2,
})

require("src.panelviewer.input")(PanelViewer)
require("src.panelviewer.rendering")(PanelViewer)
require("src.panelviewer.selection")(PanelViewer)
require("src.panelviewer.lifecycle")(PanelViewer)
require("src.panelviewer.animations")(PanelViewer)
require("src.panelviewer.controls")(PanelViewer)

require("src.plugins-support.kobo").attach(PanelViewer)
require("src.plugins-support.gestures").attach(PanelViewer)
require("src.plugins-support.livelight").attach(PanelViewer)
require("src.plugins-support.ink-away").attach(PanelViewer)

return PanelViewer
