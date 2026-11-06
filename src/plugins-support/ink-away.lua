local logger = require("logger")
local InkAway = {}

function InkAway.attach(PanelViewer)
    function PanelViewer:configureInkAway(ink)
        if
            not self.page
            or self.embedded_source_image
            or self._panels_plus_closed
            or self._annotation_closing
            or self._annotation_provider_ink == ink
        then
            return
        end
        if
            ink.integration_api_version ~= 1
            or ink.document_surface_version ~= 1
            or type(ink.installPluginIntegration) ~= "function"
            or type(ink.paintDocumentSurface) ~= "function"
            or type(ink.releaseDocumentSurface) ~= "function"
        then
            return
        end
        if not self._annotation_surface then
            self._annotation_surface = require("src._annotationsurface").new(self)
        end
        if self._annotation_unregister then
            self._annotation_unregister(false)
        end
        self._annotation_unregister = ink:installPluginIntegration(self, self._annotation_surface)
        self._annotation_provider_ink = ink
    end

    function PanelViewer:getAnnotationSurface()
        if not self.page or self.embedded_source_image or not self.reader_ui or self._panels_plus_closed then
            return nil
        end
        if not self._annotation_surface then
            self._annotation_surface = require("src._annotationsurface").new(self)
        end
        local ui = self.reader_ui
        local ready = ui.inkAwayIntegrationAPI
        if ready then
            local ok, err = pcall(self.configureInkAway, self, ready)
            if not ok then
                logger.warn("[Panels+] Ink Away registration failed:", tostring(err))
            end
        else
            local ink = ui["ink-away"] or ui.inkaway
            if ink and not ink.installPluginIntegration and type(ink.registerRenderingView) == "function" then
                -- Compatibility with the earlier surface API, before readiness.
                if self._annotation_provider_ink ~= ink then
                    self._annotation_unregister = ink:registerRenderingView(self, function()
                        return self._annotation_surface
                    end)
                    self._annotation_provider_ink = ink
                end
            else
                ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
                ui.inkAwayPendingIntegrations[self] = true
            end
        end
        return self._annotation_surface
    end

    function PanelViewer:paintAnnotationBackground(bb)
        self._annotation_snapshot = true
        local ok, err = pcall(self.paintTo, self, bb, 0, 0)
        self._annotation_snapshot = nil
        if not ok then
            error(err)
        end
    end

    function PanelViewer:completeAnnotationNavigation(next_viewer)
        local surface = self._annotation_surface
        if not surface or not surface.navigation_done then
            return
        end
        surface:completeNavigation((next_viewer or self):getAnnotationSurface())
    end

    function PanelViewer:notifyAnnotationNavigationFrame()
        local surface = self._annotation_surface
        if surface and surface.navigation_frame then
            surface.navigation_frame(surface)
        end
    end

    local show = PanelViewer.onShow
    function PanelViewer:onShow()
        local result = show(self)
        local ui = self.reader_ui
        if ui and ui.document then
            if ui.inkAwayIntegrationAPI then
                local ok, err = pcall(self.configureInkAway, self, ui.inkAwayIntegrationAPI)
                if not ok then
                    logger.warn("[Panels+] Ink Away registration failed:", tostring(err))
                end
            elseif not self:getAnnotationSurface() then
                ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
                ui.inkAwayPendingIntegrations[self] = true
            end
        end
        return result
    end
end

return InkAway
