--[[
Panels+
File: src/viewer_controller/init.lua
Name: ViewerController
Description: Composes panel viewer orchestration methods.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Panel viewer orchestration methods mixed into `PanelsPlus`.
--- @class PPViewerControllerMethods
local ViewerController = {}

require("src.viewer_controller.prerender")(ViewerController)
require("src.viewer_controller.settings")(ViewerController)
require("src.viewer_controller.ocr")(ViewerController)
require("src.viewer_controller.menus")(ViewerController)
require("src.viewer_controller.navigation")(ViewerController)

return ViewerController
