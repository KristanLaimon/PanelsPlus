--- Native panel-zoom integration methods mixed into `PanelsPlus`.
---
--- @class PPNativePanelZoomMethods
local NativePanelZoom = {}

--- Replace KOReader's native panel zoom handler while this plugin is active.
function NativePanelZoom:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight or highlight._panels_plus_original_panel_zoom then
        return
    end

    highlight._panels_plus_plugin = self
    highlight._panels_plus_original_panel_zoom = highlight.onPanelZoom
    highlight.onPanelZoom = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._panels_plus_plugin
        if plugin and plugin:isEnabled() then
            return plugin:showPanelSequence(reader_highlight, ges)
        end
        return reader_highlight:_panels_plus_original_panel_zoom(arg, ges)
    end
end

--- Keep KOReader panel zoom active so disabling Panels+ focusing falls back to native panel zoom.
function NativePanelZoom:applyNativePanelSetting()
    if self.ui.highlight and self.ui.paging then
        self.ui.highlight.panel_zoom_enabled = true
        self.ui.highlight.panel_zoom_fallback_to_text_selection = false
    end
end

--- Restore the original native panel zoom handler.
---
--- Called from `PanelsPlus:onCloseWidget` rather than being one itself: mixin
--- methods are copied by name, so only one module can own that hook.
function NativePanelZoom:restoreNativePanelZoom()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight._panels_plus_original_panel_zoom then
        highlight.onPanelZoom = highlight._panels_plus_original_panel_zoom
        highlight._panels_plus_original_panel_zoom = nil
        highlight._panels_plus_plugin = nil
    end
end

return NativePanelZoom
