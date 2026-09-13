local _ = require("gettext")

--- KOReader plugin metadata.
---
--- @return table metadata Localized plugin name and description.
return {
    id = "panels_plus.koplugin",
    name = "panels_plus",
    fullname = _("Panels+"),
    description = _(
        [[Panel-focused reading for manga and comics with directional panel navigation, zoom controls, and screenshots.]]
    ),
    author = "KristanLaimon",
    version = "1.4.0",
}
