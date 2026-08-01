--- KOReader API mocks for testing `src/_panelviewer.lua` in isolation.
---
--- Loaded once (via `require`) before any spec requires `src._panelviewer`.
--- Installs `package.preload` stubs for every KOReader module the plugin
--- requires at file scope, modeled on the mocking pattern used by the
--- reference clone `kobo.koplugin/spec/helper.lua`. `src/_geometry.lua` and
--- `src/_timing.lua` are this plugin's own real, dependency-light modules
--- and are required for real (not mocked).

local function preload(name, factory)
    if not package.preload[name] then
        package.preload[name] = factory
    end
end

-- Event: `Event:new(name, ...)` -> `{name=..., args={...}}`, matching the
-- shape `ui/event` produces in real KOReader.
preload("ui/event", function()
    local Event = {}
    function Event:new(name, ...)
        local e = { name = name, args = { ... } }
        setmetatable(e, { __index = Event })
        return e
    end
    return Event
end)

-- Minimal prototype-chain base, shared by the ImageViewer mock below --
-- matches the `InputContainer` mock pattern from kobo.koplugin/spec/helper.lua.
local function newExtendableBase()
    local Base = {}
    function Base:extend(subclass)
        subclass = subclass or {}
        local parent = self
        setmetatable(subclass, { __index = parent })
        function subclass:new(obj) -- luacheck: ignore self
            obj = obj or {}
            setmetatable(obj, { __index = self })
            return obj
        end
        return subclass
    end
    return Base
end

-- ImageViewer: the plugin's `PanelViewer` extends this. Every method the
-- production code delegates to (`ImageViewer.onShowNextImage(self)`, etc.)
-- is a spy-friendly no-op returning `true`, so specs can assert on
-- `PanelViewer`'s own overrides without a real widget/rendering stack.
preload("ui/widget/imageviewer", function()
    local ImageViewer = newExtendableBase()
    local noop_methods = {
        "init", "onShowNextImage", "onShowPrevImage", "onSwipe", "onPan",
        "onPanRelease", "onHold", "onHoldPan", "onHoldRelease", "onHoldPanRelease",
        "onClose", "onZoomIn", "onZoomOut", "paintTo", "update", "isImagePannable",
    }
    for _, method_name in ipairs(noop_methods) do
        ImageViewer[method_name] = function() return true end
    end
    return ImageViewer
end)

-- device: only `.screen` is used by the functions under test
-- (`Screen:getWidth()`/`getHeight()` for edge-gesture and transform math).
preload("device", function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end)

-- ui/geometry: minimal `Geom:new{...}` constructor (rectangle table with a
-- prototype), enough for the handful of call sites that build one.
preload("ui/geometry", function()
    local Geom = {}
    function Geom:new(o)
        o = o or {}
        setmetatable(o, { __index = self })
        return o
    end
    return Geom
end)

-- ffi/blitbuffer: enough surface for `paintHighlights`'s fallback paint path.
preload("ffi/blitbuffer", function()
    local Blitbuffer = { COLOR_WHITE = 0xFF, COLOR_BLACK = 0x00 }
    function Blitbuffer.new() return {} end
    return Blitbuffer
end)

-- ffi: LuaJIT-only, unavailable under the plain-Lua test runner. Only
-- referenced inside function bodies of `src._pagebitmap`/`src._wordfinder`
-- (never at module scope), so a stub that's merely loadable is enough --
-- those functions aren't exercised by the current specs.
preload("ffi", function()
    return {
        new = function() return nil end,
        cast = function() return nil end,
    }
end)

-- document/document: only `Document.getNativePageDimensions` is used, by
-- `src._pagebitmap` and `src._wordfinder`, as a static (non-colon) call.
preload("document/document", function()
    local Document = {}
    -- Real KOReader calls this as `Document.getNativePageDimensions(doc, page)`
    -- (module-qualified, not `doc:getNativePageDimensions(page)`). Specs that
    -- need real dimensions supply their own `document.getNativePageDimensions`
    -- and this delegates to it; specs that don't care get nil, matching the
    -- "can't map this page" bail-out path.
    function Document.getNativePageDimensions(document, pageno)
        if document and document.getNativePageDimensions then
            return document.getNativePageDimensions(document, pageno)
        end
        return nil
    end
    return Document
end)

-- ui/uimanager: no-op stubs for every method the plugin calls; specs that
-- care about scheduling/painting can override `UIManager.<method>` with a
-- `framework.spy()` before requiring/exercising the code under test.
preload("ui/uimanager", function()
    local UIManager = { _window_stack = {} }
    for _, method_name in ipairs{ "sendEvent", "setDirty", "forceRePaint", "scheduleIn", "show", "tickAfterNext", "unschedule" } do
        UIManager[method_name] = function() return true end
    end
    return UIManager
end)

-- gettext: identity translation function.
preload("gettext", function()
    return function(s) return s end
end)

-- logger: no-op leveled logging.
preload("logger", function()
    local logger = {}
    for _, level in ipairs{ "dbg", "info", "warn", "err" } do
        logger[level] = function() end
    end
    return logger
end)

-- ui/time / util: only `_timing.lua` (required transitively via
-- `src._timing`) needs these, and only for its disabled-by-default spans.
preload("ui/time", function()
    local time = {}
    function time.now() return 0 end
    function time.since(t) return 0 end
    function time.to_ms(t) return 0 end
    return time
end)

preload("util", function()
    local util = {}
    function util.calcFreeMem() return 0 end
    return util
end)

-- Trivial stub tables: required at file scope but only exercised by
-- widget-construction methods no spec currently calls into.
for _, name in ipairs{
    "ui/widget/buttontable",
    "ui/widget/container/centercontainer",
    "ui/renderimage",
    "ui/widget/screenshoter",
} do
    preload(name, function() return {} end)
end
