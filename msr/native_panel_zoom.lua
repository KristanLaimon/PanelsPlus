--- Native panel-zoom integration methods mixed into `MangaComicSmoother`.
---
--- @class MCSNativePanelZoomMethods
local NativePanelZoom = {}

--- Replace KOReader's native panel zoom handler while this plugin is active.
function NativePanelZoom:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight or highlight._mangacomicsmoother_original_panel_zoom then
        return
    end

    highlight._mangacomicsmoother_plugin = self
    highlight._mangacomicsmoother_original_panel_zoom = highlight.onPanelZoom
    highlight.onPanelZoom = function(reader_highlight, arg, ges)
        local plugin = reader_highlight._mangacomicsmoother_plugin
        if plugin and plugin:isEnabled() then
            return plugin:showPanelSequence(reader_highlight, ges)
        end
        return reader_highlight:_mangacomicsmoother_original_panel_zoom(arg, ges)
    end
end

--- Synchronize KOReader's native panel-zoom flags with the plugin setting.
function NativePanelZoom:applyNativePanelSetting()
    if self.ui.highlight and self.ui.paging then
        self.ui.highlight.panel_zoom_enabled = self:isEnabled()
        self.ui.highlight.panel_zoom_fallback_to_text_selection = false
    end
end

--- KOReader close hook: restore the original native panel zoom handler.
function NativePanelZoom:onCloseWidget()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight._mangacomicsmoother_original_panel_zoom then
        highlight.onPanelZoom = highlight._mangacomicsmoother_original_panel_zoom
        highlight._mangacomicsmoother_original_panel_zoom = nil
        highlight._mangacomicsmoother_plugin = nil
    end
end

return NativePanelZoom
