--[[
Panels+
File: src/panelviewer/constants.lua
Name: PanelViewer
Description: Shared viewer navigation limits and warning lifetime.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local NavCapabilities = require("src._navcapabilities")

--- Default number of steps the smooth-navigation pan animation is split into,
--- used when a viewer has no `nav_transition_frames` of its own.
local NAV_TRANSITION_STEPS_DEFAULT = NavCapabilities.defaultFrames()
--- Hard cap on the shared transition bitmap's area, as a multiple of the screen's
--- area, to bound the one-shot render/upscale cost when the destination panel
--- needs a much higher zoom than the two panels' combined bounding box.
local NAV_TRANSITION_MAX_AREA_MULTIPLIER = 16
--- Minimum free memory required before allocating a smooth-transition canvas
--- (up to `NAV_TRANSITION_MAX_AREA_MULTIPLIER`x screen area), matching the
--- threshold `ViewerController:hasMemoryForPrerender()` uses for comparably
--- sized panel-tile allocations.
local NAV_TRANSITION_MIN_FREE_BYTES = 40 * 1024 * 1024
--- Standard lifetime for user-facing flow warnings and confirmations.
local FLOW_WARNING_TIMEOUT = 7

return {
    NAV_TRANSITION_STEPS_DEFAULT = NAV_TRANSITION_STEPS_DEFAULT,
    NAV_TRANSITION_MAX_AREA_MULTIPLIER = NAV_TRANSITION_MAX_AREA_MULTIPLIER,
    NAV_TRANSITION_MIN_FREE_BYTES = NAV_TRANSITION_MIN_FREE_BYTES,
    FLOW_WARNING_TIMEOUT = FLOW_WARNING_TIMEOUT,
}
