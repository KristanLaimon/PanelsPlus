local PanelCollector = require("msr_panelcollector")
local Settings = require("msr_settings")
local UIManager = require("ui/uimanager")

--- Panel cache and prefetch methods mixed into `MangaComicSmoother`.
---
--- @class MCSCacheMethods
local Cache = {}

--- Clear all cached panel lists and pending prefetch guards.
function Cache:clearPanelCache()
    self.panel_cache = {}
    self.panel_cache_order = {}
    self.panel_cache_loading = {}
end

--- Build the cache key for a document page in the current reading mode.
---
--- @param page number Document page number.
--- @return string key Page-and-mode cache key.
function Cache:getPanelCacheKey(page)
    return tostring(page) .. ":" .. (self.settings.mode or "manga")
end

--- Return cached panels for a page in the current reading mode.
---
--- @param page number Document page number.
--- @return MCSPanel[]|nil panels Cached panel list, if present.
function Cache:getCachedPanels(page)
    return self.panel_cache[self:getPanelCacheKey(page)]
end

--- Store a page's ordered panel list and evict stale pages by LRU order.
---
--- @param page number Document page number.
--- @param panels MCSPanel[] Ordered panel rectangles.
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
    end
end

--- Collect panels for a page, reusing the cache when possible.
---
--- Hold-triggered collection can bypass an empty cached list so the exact hold
--- position gets a chance to seed the native detector.
---
--- @param page number Document page number.
--- @param hold_pos MCSPagePosition|nil Optional hold position in page space.
--- @return MCSPanel[] panels Ordered panel rectangles.
function Cache:collectPanels(page, hold_pos)
    local cached_panels = self:getCachedPanels(page)
    if cached_panels and (not hold_pos or #cached_panels > 0) then
        return cached_panels
    end

    local panels = PanelCollector.collect(self.ui, self.settings, page, hold_pos)
    if #panels > 0 then
        self:cachePanels(page, panels)
    end
    return panels
end

--- Schedule a delayed background panel collection for a page.
---
--- @param page number|nil Document page number; nil and zero are ignored.
function Cache:preloadPanels(page)
    if not page or page == 0 then
        return
    end

    local cached_panels = self:getCachedPanels(page)
    if cached_panels then
        return
    end

    local key = self:getPanelCacheKey(page)
    if self.panel_cache_loading[key] then
        return
    end
    self.panel_cache_loading[key] = true

    local delay = self.settings.panel_prefetch_delay or Settings.defaults.panel_prefetch_delay
    UIManager:scheduleIn(delay, function()
        self.panel_cache_loading[key] = nil
        local scheduled_cached_panels = self:getCachedPanels(page)
        if scheduled_cached_panels then
            return
        end
        self:collectPanels(page)
    end)
end

--- Schedule delayed panel collection for the page after `page`.
---
--- @param page number Current document page number.
function Cache:preloadNextPanels(page)
    self:preloadPanels(self.ui.document:getNextPage(page))
end

return Cache
