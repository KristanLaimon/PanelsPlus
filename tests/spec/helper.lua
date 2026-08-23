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
        "init",
        "onShowNextImage",
        "onShowPrevImage",
        "onSwipe",
        "onPan",
        "onPanRelease",
        "onHold",
        "onHoldPan",
        "onHoldRelease",
        "onHoldPanRelease",
        "onClose",
        "onZoomIn",
        "onZoomOut",
        "paintTo",
        "update",
        "isImagePannable",
    }
    for _, method_name in ipairs(noop_methods) do
        ImageViewer[method_name] = function()
            return true
        end
    end
    return ImageViewer
end)

-- device: only `.screen` is used by the functions under test
-- (`Screen:getWidth()`/`getHeight()` for edge-gesture and transform math).
preload("device", function()
    return {
        screen = {
            getWidth = function()
                return 600
            end,
            getHeight = function()
                return 800
            end,
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

-- ffi/blitbuffer: enough surface for `paintHighlights`'s fallback paint path,
-- plus a working-enough fake buffer for `src._ocrdebug`'s crop-image saving
-- (copy-on-write via `blitFrom`, box outlines via `invertRect`, `writePNG`).
-- Every `invertRect` call across every buffer instance also lands in the
-- shared `Blitbuffer._invert_log`, which specs reset and inspect directly --
-- simpler than threading a handle to whichever buffer ends up drawn on
-- (`saveCropImage` may draw on a copy of the tile it was handed, not the
-- tile itself).
preload("ffi/blitbuffer", function()
    local Blitbuffer = { COLOR_WHITE = 0xFF, COLOR_BLACK = 0x00, _invert_log = {} }
    local BB = {}
    BB.__index = BB
    function BB:getType()
        return self._type
    end
    function BB:invertRect(x, y, w, h)
        table.insert(Blitbuffer._invert_log, { x = x, y = y, w = w, h = h })
    end
    function BB:blitFrom() end
    function BB:writePNG(path)
        self.written_path = path
    end
    function BB:free() end
    function Blitbuffer.new(w, h, btype)
        return setmetatable({ w = w or 0, h = h or 0, _type = btype }, BB)
    end
    return Blitbuffer
end)

-- ffi: LuaJIT-only, unavailable under the plain-Lua test runner. Only
-- referenced inside function bodies (never at module scope), so a stub is
-- enough -- but `src._segmenter` genuinely runs under the specs, so
-- `ffi.new("<type>[?]", n)` has to behave like the array it stands in for:
-- zero-filled and 0-based, since every index the segmenter uses is a map cell
-- offset. The element type is irrelevant here; nothing the specs exercise
-- depends on width or overflow. `ffi.cast` stays a nil stub -- its only caller
-- is `_pagebitmap`'s raw-pointer sampler, which the specs never reach.
preload("ffi", function()
    return {
        new = function(_, count)
            local array = {}
            for index = 0, (count or 0) - 1 do
                array[index] = 0
            end
            return array
        end,
        cast = function()
            return nil
        end,
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
    for _, method_name in ipairs({ "sendEvent", "setDirty", "forceRePaint", "tickAfterNext", "unschedule", "close" }) do
        UIManager[method_name] = function()
            return true
        end
    end
    -- `show` also records the widget, so specs (e.g. `ocrdebug_spec.lua`) can
    -- hand-invoke a stored callback (`ok_callback`, a `Save` button's own
    -- callback, etc.) to simulate the user's choice.
    function UIManager:show(widget)
        UIManager._last_shown = widget
        return true
    end
    -- `scheduleIn` also records the callback (does not run it -- there is no
    -- real event loop here), so specs simulating time passing (e.g. the
    -- `pollForDictClose` fallback in `src._ocrdebug`) can hand-invoke
    -- `UIManager._last_scheduled()` themselves, once per simulated tick.
    function UIManager:scheduleIn(seconds, fn)
        UIManager._last_scheduled = fn
        return true
    end
    return UIManager
end)

-- gettext: identity translation function.
preload("gettext", function()
    return function(s)
        return s
    end
end)

-- logger: no-op leveled logging.
preload("logger", function()
    local logger = {}
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        logger[level] = function() end
    end
    return logger
end)

-- ui/time / util: only `_timing.lua` (required transitively via
-- `src._timing`) needs these, and only for its disabled-by-default spans.
preload("ui/time", function()
    local time = {}
    function time.now()
        return 0
    end
    function time.since(t)
        return 0
    end
    function time.to_ms(t)
        return 0
    end
    return time
end)

preload("util", function()
    local util = {}
    function util.calcFreeMem()
        return 0
    end
    -- `src._ocrdebug` uses this to create the debug-images folder; specs
    -- never exercise a real filesystem write, so a stub that always
    -- "succeeds" without touching disk is enough.
    function util.makePath()
        return true
    end
    return util
end)

-- json: only `src._ocrdebug` uses this, to encode session-log lines. No spec
-- currently exercises a real encode, so a stub that never gets called is enough.
preload("json", function()
    return {
        encode = function()
            return ""
        end,
    }
end)

-- Dialog widgets `src._ocrdebug` shows: `:new{...}` just returns the option
-- table, so specs can hand-invoke a stored `ok_callback`/`cancel_callback`
-- without a real widget/rendering stack, and without `UIManager:show` (a
-- no-op stub) ever calling them itself.
for _, name in ipairs({ "ui/widget/confirmbox", "ui/widget/notification" }) do
    preload(name, function()
        local Widget = {}
        function Widget:new(o)
            return o or {}
        end
        return Widget
    end)
end

preload("ui/widget/inputdialog", function()
    local InputDialog = {}
    function InputDialog:new(o)
        o = o or {}
        o.getInputText = function()
            return o._test_input or ""
        end
        o.onShowKeyboard = function() end
        return o
    end
    return InputDialog
end)

-- Trivial stub tables: required at file scope but only exercised by
-- widget-construction methods no spec currently calls into.
for _, name in ipairs({
    "ui/widget/buttontable",
    "ui/widget/container/centercontainer",
    "ui/renderimage",
    "ui/widget/screenshoter",
}) do
    preload(name, function()
        return {}
    end)
end
