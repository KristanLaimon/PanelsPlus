--[[
Panels+
File: _meta.lua
Name: Plugin metadata
Description: Declares the KOReader plugin identifier, display metadata, author, and version.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local _ = require("gettext")

--- KOReader plugin metadata.
---
--- @return table metadata Localized plugin name and description.
return {
    id = "panelsplus",
    name = "panelsplus",
    fullname = _("Panels+"),
    description = _(
        [[Panel-focused reading for manga and comics with directional panel navigation, zoom controls, and screenshots.]]
    ),
    author = "KristanLaimon",
    version = "1.4.0",
}
