local PanelCollector = require("src._panelcollector")
local Settings = require("src._settings")
local Timing = require("src._timing")
local UIManager = require("ui/uimanager")

--- Panel cache and prefetch methods mixed into `PanelsPlus`.
---
--- @class PPCacheMethods
local Cache = {}

--- Drop every prefetch that has been scheduled but has not run yet.
---
--- Prefetch closures capture the plugin and a page number, so leaving them on
--- UIManager's queue keeps stale work alive across page turns and past document
--- close. Turning pages quickly used to queue one detection per page visited and
--- then run all of them.
function Cache:cancelPanelPrefetch()
    for _, action in pairs(self.panel_prefetch_actions or {}) do
        UIManager:unschedule(action)
    end
    self.panel_prefetch_actions = {}
end

--- Clear all cached panel lists and pending prefetch work.
function Cache:clearPanelCache()
    self:cancelPanelPrefetch()
    self.panel_cache = {}
    self.panel_cache_order = {}
end

--- Build the cache key for a document page in the current reading mode and detector.
---
--- Mode changes panel order, detector changes the panel list itself, and the
--- drawn-border split changes how comic pages divide, so all three are part of
--- the key. Keying on them (instead of clearing the whole cache on every
--- switch) lets a page already detected under a given combination stay cached
--- when the reader switches away and back, and keeps other pages' cached
--- results alive across the switch.
---
--- @param page number Document page number.
--- @return string key Page, mode, detector, and border-split cache key.
function Cache:getPanelCacheKey(page)
    return tostring(page) .. ":" .. (self.settings.mode or "manga") .. ":" .. self:getDetector()
        .. (self.settings.segment_border_split == true and ":bs" or "")
end

--- Return cached panels for a page in the current reading mode.
---
--- @param page number Document page number.
--- @return PPPanel[]|nil panels Cached panel list, if present.
function Cache:getCachedPanels(page)
    return self.panel_cache[self:getPanelCacheKey(page)]
end

--- Store a page's ordered panel list and evict stale pages by LRU order.
---
--- @param page number Document page number.
--- @param panels PPPanel[] Ordered panel rectangles.
function Cache:cachePanels(page, panels)
    local key = self:getPanelCacheKey(page)
    self.panel_cache[key] = panels

    for idx = #self.panel_cache_order, 1, -1 do
        if self.panel_cache_order[idx] == key then
            table.remove(self.panel_cache_order, idx)
            break
        end
    end
    table.insert(self.panel_cache_order, key)

    local max_pages = self.settings.panel_cache_pages or Settings.defaults.panel_cache_pages
    while #self.panel_cache_order > max_pages do
        local stale_key = table.remove(self.panel_cache_order, 1)
        self.panel_cache[stale_key] = nil
        Timing.log("cache evict " .. stale_key .. string.format(" (%d pages cached)", #self.panel_cache_order))
    end
end

--- Collect panels for a page, reusing the cache when possible.
---
--- Hold-triggered collection can bypass an empty cached list so the exact hold
--- position gets a chance to seed the native detector.
---
--- @param page number Document page number.
--- @param hold_pos PPPagePosition|nil Optional hold position in page space.
--- @return PPPanel[] panels Ordered panel rectangles.
function Cache:collectPanels(page, hold_pos)
    local cached_panels = self:getCachedPanels(page)
    if cached_panels and (not hold_pos or #cached_panels > 0) then
        return cached_panels
    end

    local panels = PanelCollector.collect(self.ui, self.settings, page, hold_pos)
    self:cachePanels(page, panels)
    return panels
end

--- Schedule a delayed background panel collection for a page.
---
--- @param page number|nil Document page number; nil and zero are ignored.
function Cache:preloadPanels(page)
    if not page or page == 0 then
        return
    end

    if self:getCachedPanels(page) then
        return
    end

    local key = self:getPanelCacheKey(page)
    if self.panel_prefetch_actions[key] then
        return
    end

    local delay = self.settings.panel_prefetch_delay or Settings.defaults.panel_prefetch_delay
    local action
    action = function()
        if self.panel_prefetch_actions[key] == action then
            self.panel_prefetch_actions[key] = nil
        end
        if self:getCachedPanels(page) then
            return
        end
        self:collectPanels(page)
    end

    self.panel_prefetch_actions[key] = action
    UIManager:scheduleIn(delay, action)
end

--- Schedule delayed panel collection for the page after `page`.
---
--- @param page number Current document page number.
function Cache:preloadNextPanels(page)
    self:preloadPanels(self.ui.document:getNextPage(page))
end

return Cache
