--- Native panel-zoom integration methods mixed into `PanelsPlus`.
---
--- @class PPNativePanelZoomMethods
local NativePanelZoom = {}

--- Replace KOReader's native panel zoom handler while this plugin is active.
function NativePanelZoom:patchNativePanelZoom()
    local highlight = self.ui.highlight
    if not highlight then
        return
    end
    if highlight._panels_plus_original_panel_zoom then
        -- Already patched (e.g. a second init() without an intervening
        -- onCloseWidget): still refresh the plugin reference so the hook
        -- doesn't keep driving a stale PanelsPlus instance.
        highlight._panels_plus_plugin = self
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

--- KOReader hook: reapply the native panel-zoom override after document load.
---
--- `ReaderHighlight:onReadSettings` only defaults `panel_zoom_enabled` to true
--- for cbz/cbt (false for pdf/cbr) and `panel_zoom_fallback_to_text_selection`
--- to true for pdf, then assigns those onto `self.ui.highlight` from the
--- per-document/per-extension settings. That assignment runs as part of the
--- same `ReadSettings` broadcast that follows plugin init, and since
--- `highlight` is registered before plugins it always runs first -- so it
--- silently overwrites the values `applyNativePanelSetting` set in `init()`,
--- which made pdf/cbr hold gestures fall through to dictionary/OCR lookup
--- instead of ever reaching `onPanelZoom`. Reapplying here, after that
--- broadcast reaches this module, restores the override.
function NativePanelZoom:onReadSettings()
    self:applyNativePanelSetting()
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
