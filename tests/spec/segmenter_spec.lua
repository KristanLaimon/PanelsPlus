--- Specs for `src/_segmenter.lua`'s panel cut, driven through the real
--- `Segmenter.segment()` against synthetic page maps.
---
--- Maps are built at 480x720, the size `src/_pagebitmap.lua` actually produces
--- for a comic page at the default `segment_target_width`. That is not
--- incidental: every floor in the cut is a fraction of the map, so a toy-sized
--- map would exercise thresholds no real page ever sees. At this size the
--- defaults work out to min_side=14, min_gutter=2, min_area=1728 cells and
--- border_max_width=4.
---
--- `native_w`/`native_h` are set equal to the cell dimensions so results come
--- back in cell units and can be read directly against the drawing calls.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Segmenter = require("src._segmenter")
local Settings = require("src._settings")

local MAP_W, MAP_H = 480, 720

--- A page canvas in map cells, holding the two planes `_pagebitmap` produces.
---
--- On a light-background page the border plane is by construction a subset of
--- the ink plane: a cell dark enough to be a border candidate (luminance <=
--- `segment_border_luminance_max`) is necessarily far enough from a white
--- background to be ink (delta > `segment_ink_delta`). The drawing helpers
--- preserve that, so the maps stay reachable from a real page.
local Page = {}
Page.__index = Page

function Page.new()
    local page = setmetatable({ w = MAP_W, h = MAP_H, ink = {}, border = {} }, Page)
    for index = 0, MAP_W * MAP_H - 1 do
        page.ink[index] = 0
        page.border[index] = 0
    end
    return page
end

function Page:set(x, y, ink, border)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then
        return
    end
    local index = y * self.w + x
    self.ink[index] = ink
    self.border[index] = border
end

--- Fill a rect with mid-tone artwork: ink, but never dark enough to be a
--- border candidate. `density` leaves gaps so the region reads as drawn art
--- rather than a solid block, using a fixed seed so runs are reproducible.
function Page:art(x0, y0, w, h, density)
    density = density or 0.55
    local seed = 12345
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            if (seed / 2147483648) < density then
                self:set(x, y, 1, 0)
            end
        end
    end
end

--- Fill a rect with solid black: both ink and a border candidate.
function Page:black(x0, y0, w, h)
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            self:set(x, y, 1, 1)
        end
    end
end

--- Draw a hollow black panel frame `thickness` cells thick.
function Page:frame(x0, y0, w, h, thickness)
    thickness = thickness or 2
    self:black(x0, y0, w, thickness)
    self:black(x0, y0 + h - thickness, w, thickness)
    self:black(x0, y0, thickness, h)
    self:black(x0 + w - thickness, y0, thickness, h)
end

--- A framed panel filled with artwork.
function Page:panel(x0, y0, w, h)
    self:art(x0 + 2, y0 + 2, w - 4, h - 4)
    self:frame(x0, y0, w, h, 2)
end

function Page:toMap(with_border)
    local ink = 0
    for index = 0, self.w * self.h - 1 do
        if self.ink[index] == 1 then
            ink = ink + 1
        end
    end
    return {
        w = self.w,
        h = self.h,
        data = self.ink,
        border = with_border and self.border or nil,
        ink = ink,
        native_w = self.w,
        native_h = self.h,
        scale_x = 1,
        scale_y = 1,
        background = 255,
        inverted = false,
    }
end

local manga = Settings.withDefaults({ mode = "manga" })
local comic = Settings.withDefaults({ mode = "comic" })
local comic_border_split = Settings.withDefaults({
    mode = "comic",
    segment_border_split = true,
})

--- Segment a page the way `PanelCollector` would for a given settings table.
---
--- The border plane is only present when the reader has opted into the drawn
--- border split, mirroring `PageBitmap.build`'s own gate.
local function segment(page, settings)
    return Segmenter.segment(page:toMap(settings.segment_border_split == true), settings)
end

--- Build a page holding one framed panel over the full page, plus whatever
--- `decorate` draws inside it.
local function splashPage(decorate)
    local page = Page.new()
    page:panel(12, 12, MAP_W - 24, MAP_H - 24)
    if decorate then
        decorate(page)
    end
    return page
end

describe("Segmenter.segment panel cut", function()
    it("splits a clean grid on its blank gutters", function()
        local page = Page.new()
        -- 2*219 + 3*14 = 480 across, 3*220 + 4*15 = 720 down.
        for row = 0, 2 do
            for col = 0, 1 do
                page:panel(14 + col * 233, 15 + row * 235, 219, 220)
            end
        end

        assert.equals(6, #segment(page, manga))
        assert.equals(6, #segment(page, comic))
    end)

    it("keeps a splash page as a single panel", function()
        local page = splashPage()

        assert.equals(1, #segment(page, manga))
        assert.equals(1, #segment(page, comic))
    end)
end)

describe("Segmenter.segment sliver rejection", function()
    -- A scanlation credit strip clears both size floors comfortably: at
    -- 182x20 it is 3640 cells against a 1728-cell area floor, and both sides
    -- beat the 14-cell side floor. It takes being *both* elongated (9:1) and
    -- nearly empty (~1% of the page's ink) to identify it -- the three cases
    -- below are the ones that make each half necessary.
    it("drops a credit strip that clears the size floors", function()
        local page = Page.new()
        page:panel(14, 14, MAP_W - 28, 640)
        page:art(150, 676, 180, 18, 0.5)

        assert.equals(1, #segment(page, manga))
        assert.equals(1, #segment(page, comic))
    end)

    it("keeps a compact inset panel holding less ink than the floor", function()
        -- 1.5% of the page's ink, under `segment_sliver_ink` and less than the
        -- 182x20 credit strip's own margin over it, but square. An ink floor
        -- applied on its own would drop this panel; the aspect test is what
        -- saves it. Verified load-bearing: forcing the aspect test to fire
        -- (`segment_sliver_aspect = 1`) drops it back to one panel.
        local page = Page.new()
        page:panel(14, 14, MAP_W - 28, 560)
        page:panel(200, 600, 60, 60)

        assert.equals(2, #segment(page, manga))
    end)

    it("keeps a wide letterbox panel", function()
        -- 7.6:1, elongated well past the aspect test, but ink-rich. An aspect
        -- limit applied on its own would drop this; the ink floor is what
        -- saves it. Verified load-bearing: forcing the ink test to fire
        -- (`segment_sliver_ink = 1.0`) drops it back to one panel.
        local page = Page.new()
        page:panel(14, 14, MAP_W - 28, 560)
        page:panel(11, 600, 458, 60)

        assert.equals(2, #segment(page, manga))
    end)

    it("keeps a lone small panel on an otherwise blank page", function()
        -- The ink floor is a share of the page's own ink, not an absolute
        -- count, so the only drawing on a near-empty page survives it.
        local page = Page.new()
        page:panel(150, 300, 180, 120)

        assert.equals(1, #segment(page, manga))
    end)
end)

describe("Segmenter.segment drawn border split", function()
    -- Off by default because the pattern is not unique to a panel border: a
    -- horizon, a caption rule or a pole drawn inside one panel produces the
    -- same thin, full-span, densely dark run as a stroke shared between two
    -- bled panels. These four cases are that ambiguity, pinned.
    local drawn = {
        ["a full-width caption rule"] = function(page)
            page:black(14, 120, MAP_W - 28, 3)
        end,
        ["a black horizon line"] = function(page)
            page:black(14, 400, MAP_W - 28, 2)
        end,
        ["a full-height pole"] = function(page)
            page:black(230, 14, 3, MAP_H - 28)
        end,
    }

    for label, decorate in pairs(drawn) do
        it("keeps one panel containing " .. label .. " intact by default", function()
            assert.equals(1, #segment(splashPage(decorate), comic))
        end)

        it("splits one panel containing " .. label .. " when enabled", function()
            assert.equals(2, #segment(splashPage(decorate), comic_border_split))
        end)
    end

    it("merges two bled panels by default, and splits them when enabled", function()
        local page = Page.new()
        page:art(12, 12, MAP_W - 24, MAP_H - 24, 0.6)
        page:black(12, 350, MAP_W - 24, 3)
        page:frame(12, 12, MAP_W - 24, MAP_H - 24, 2)

        assert.equals(1, #segment(page, comic))
        assert.equals(2, #segment(page, comic_border_split))
    end)
end)
