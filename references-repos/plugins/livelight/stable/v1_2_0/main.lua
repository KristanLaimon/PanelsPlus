--[[--
LiveLight.

KOReader's own edge swipes change the light once, after the finger lifts: it
waits for the whole swipe, measures it, then jumps. This plugin listens to the
"pan" events KOReader sends while the finger is still moving, and nudges the
light on each one, so brightness (left edge) and warmth (right edge) follow
the finger the way they do in Kobo's own software.

It takes over a vertical slide that starts in an edge strip by registering
touch zones that are ordered ahead of the reader's and of the Gestures
plugin's. Nothing in those is changed; anything that is not such a slide is
passed on to them untouched, and turning this plugin off hands the edges back.

Outside a book that is not enough: the file browser, History, Collections and
other full-screen lists are all built on KOReader's Menu widget, which
swallows every pan before any touch zone sees it (and does nothing with it,
unless it came from a mouse wheel). So the plugin also wraps Menu's three
gesture handlers, and offers each pan to the same code first.

While sliding, a small box shows the level. The box and its number are drawn
in the screen's fast black-and-white mode, so they are there at once and keep
up with the finger; the number is redrawn a few times a second at most. The
word beside the number is added a moment later in the normal, smooth mode.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Math = require("optmath")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

if not (Device:hasFrontlight() and Device:isTouchDevice()) then
    return { disabled = true }
end

local Screen = Device.screen

local SETTINGS_KEY = "livelight"
-- Width of each edge strip, as a share of the screen. Same as the strips
-- KOReader's own edge swipes use.
local EDGE = 1 / 8
-- Share of the screen height a finger travels to go from one end of the
-- range to the other.
local FULL_RANGE_TRAVEL = 0.7
-- The light itself changes on every step; only the box is held back, so
-- the e-ink screen is not asked to redraw faster than it can.
local DRAW_INTERVAL = 0.15
-- How long after the box appears its word is added. Long enough that the two
-- are separate screen updates: asked for together they would be merged into
-- one slow, smooth update of the whole box.
local WORD_AFTER = 0.1
local HIDE_AFTER = 1
-- A slide whose lift is never reported (a second finger joined, or the screen
-- underneath changed) is wound up after this long without news of it.
local GIVE_UP_AFTER = 5

local function settings()
    local stored = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(stored) ~= "table" then stored = {} end
    if stored.enabled == nil then stored.enabled = true end
    if stored.show_level == nil then stored.show_level = true end
    -- What each edge does: "brightness", "warmth" or "off". Before these
    -- existed there was only a swap_sides switch, which they start out from.
    if stored.left_edge == nil then
        stored.left_edge = stored.swap_sides and "warmth" or "brightness"
    end
    if stored.right_edge == nil then
        stored.right_edge = stored.swap_sides and "brightness" or "warmth"
    end
    return stored
end

local function saveSetting(key, value)
    local stored = settings()
    stored[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, stored)
end

-- ── The two things a slide can change ───────────────────────────────────────

local brightness = {
    range = function(powerd) return powerd.fl_min, powerd.fl_max end,
    get = function(powerd) return powerd:frontlightIntensity() end,
    set = function(powerd, level)
        -- Same rule as KOReader's own gesture: zero means off.
        if level <= 0 then
            powerd:turnOffFrontlight()
        else
            powerd:setIntensity(level)
        end
    end,
    name = _("Brightness"),
    -- The device's own level, as KOReader itself shows it: 0 to 100 on a
    -- Kobo, 0 to 24 on a Kindle.
    value = function(powerd, level) return tostring(level) end,
}

-- Warmth is handled in the device's own steps (0 to 10 on a Clara BW), as
-- KOReader's gesture and light dialog do, so that every step is a real change.
local warmth = {
    range = function(powerd) return powerd.fl_warmth_min, powerd.fl_warmth_max end,
    get = function(powerd) return powerd:toNativeWarmth(powerd:frontlightWarmth()) end,
    set = function(powerd, level) powerd:setWarmth(powerd:fromNativeWarmth(level)) end,
    name = _("Warmth"),
    value = function(powerd, level) return tostring(level) end,
}

local function controlAt(pos)
    local width = Screen:getWidth()
    local on_left = pos.x < width * EDGE
    if not on_left and pos.x < width * (1 - EDGE) then return end
    -- An edge that is off returns nothing, so its touches are passed on to
    -- whatever the gesture manager has there.
    local choice = settings()[on_left and "left_edge" or "right_edge"]
    if choice == "brightness" then
        return brightness
    elseif choice == "warmth" and Device:hasNaturalLight() then
        return warmth
    end
end

-- ── Level box ───────────────────────────────────────────────────────────────

-- A plain container, not an input one, and a toast: it never takes input, so
-- the slide that is driving it carries on reaching the zones underneath.
local LevelBox = WidgetContainer:extend{
    name = "",
    value = "",
    widest_value = "",
    toast = true,
}

function LevelBox:init()
    local face = Font:getFace("infofont")
    -- The word and the number each sit in a slot of fixed size, so that
    -- either can be drawn by itself without anything else in the box moving.
    local function slotFor(sample_text, widget)
        local sample = TextWidget:new{ text = sample_text, face = face }
        local size = sample:getSize()
        sample:free()
        return LeftContainer:new{
            dimen = Geom:new{ w = size.w, h = size.h },
            widget,
        }
    end
    self.word = TextWidget:new{ text = "", face = face }
    self.word_slot = slotFor(self.name, self.word)
    self.number = TextWidget:new{ text = self.value, face = face }
    self.number_slot = slotFor(self.widest_value, self.number)
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        margin = 0,
        padding = Size.padding.large,
        HorizontalGroup:new{
            self.word_slot,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            self.number_slot,
        },
    }
    self[1] = VerticalGroup:new{
        VerticalSpan:new{ width = math.floor(Screen:getHeight() / 8) },
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = self.frame:getSize().h },
            self.frame,
        },
    }
    self.add_word = function() self:addWord() end
end

-- The fast mode is black and white only, with no gray to smooth the edges of
-- text, which is why the number looks rough. It is the price of keeping up.
function LevelBox:redrawNumber(value)
    self.number:setText(value)
    UIManager:setDirty(self, function() return "fast", self.number_slot.dimen end)
end

-- The smooth mode only drives pixels whose content has changed since the last
-- screen update. So the word cannot be drawn fast and then smoothed over
-- (nothing would change, and nothing would happen); it has to be left out of
-- the box's first, fast appearance and drawn for the first time here.
function LevelBox:addWord()
    self.word:setText(self.name)
    UIManager:setDirty(self, function() return "ui", self.word_slot.dimen end)
end

function LevelBox:onShow()
    UIManager:setDirty(self, function() return "fast", self.frame.dimen end)
    UIManager:scheduleIn(WORD_AFTER, self.add_word)
    return true
end

function LevelBox:onCloseWidget()
    UIManager:unschedule(self.add_word)
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

-- ── Slide state ─────────────────────────────────────────────────────────────
-- Shared by the file browser's and the reader's instance of the plugin.

local slide = nil         -- { key, control, min, max, start, anchor_y, level }
local passed_on = nil     -- key of a touch that was looked at and left to others
local box = nil
local box_name, box_value, box_widest = nil, nil, nil
local draw_held = false   -- a redraw happened less than DRAW_INTERVAL ago
local draw_wanted = false -- the level changed while redraws were held

local releaseDraw

local function hideBox()
    if box then
        UIManager:close(box)
        box = nil
    end
end

local function drawBox()
    if not (settings().show_level and box_name) then return end
    UIManager:unschedule(hideBox)
    if box and box.name ~= box_name then
        -- Left over from a slide on the other edge a moment ago.
        hideBox()
    end
    if box then
        box:redrawNumber(box_value)
    else
        box = LevelBox:new{
            name = box_name,
            value = box_value,
            widest_value = box_widest,
        }
        UIManager:show(box)
    end
end

local function drawBoxHeld()
    drawBox()
    draw_held = true
    UIManager:scheduleIn(DRAW_INTERVAL, releaseDraw)
end

releaseDraw = function()
    draw_held = false
    if draw_wanted then
        draw_wanted = false
        drawBoxHeld()
    end
end

local function drawBoxSoon()
    if draw_held then
        draw_wanted = true
        return
    end
    drawBoxHeld()
end

local finish

local function begin(key, control, y)
    local powerd = Device:getPowerDevice()
    local min, max = control.range(powerd)
    local level = control.get(powerd)
    slide = {
        key = key,
        control = control,
        min = min,
        max = max,
        start = level,
        -- Measured from here rather than from where the finger landed, so the
        -- light does not jump by the distance it took to be seen as a slide.
        anchor_y = y,
        level = level,
    }
    box_name, box_value = control.name, control.value(powerd, level)
    -- What the number's slot is sized for: this control's own top value.
    box_widest = control.value(powerd, max)
    drawBoxSoon()
end

local function moveTo(y)
    local step = Screen:getHeight() * FULL_RANGE_TRAVEL / (slide.max - slide.min)
    local level = Math.round(slide.start + (slide.anchor_y - y) / step)
    -- Past either end, drag the anchor along with the finger, so that
    -- turning back takes effect at once instead of after retracing the excess.
    if level > slide.max then
        level = slide.max
        slide.anchor_y = y + (level - slide.start) * step
    elseif level < slide.min then
        level = slide.min
        slide.anchor_y = y + (level - slide.start) * step
    end
    if level == slide.level then return end
    slide.level = level
    local powerd = Device:getPowerDevice()
    slide.control.set(powerd, level)
    box_value = slide.control.value(powerd, level)
    drawBoxSoon()
end

finish = function()
    UIManager:unschedule(finish)
    if not slide then return end
    slide = nil
    -- As KOReader's own gesture does, so waking from sleep restores this state.
    Device:getPowerDevice():updateResumeFrontlightState()
    UIManager:unschedule(releaseDraw)
    draw_held, draw_wanted = false, false
    -- The last change may still have been waiting its turn to be drawn.
    if not box or box.number.text ~= box_value then
        drawBox()
    else
        UIManager:unschedule(hideBox)
    end
    UIManager:scheduleIn(HIDE_AFTER, hideBox)
end

local function abandon()
    slide, passed_on = nil, nil
    UIManager:unschedule(finish)
    UIManager:unschedule(releaseDraw)
    UIManager:unschedule(hideBox)
    draw_held, draw_wanted = false, false
    hideBox()
end

-- ── Gesture handlers ────────────────────────────────────────────────────────
-- Each returns true to keep the gesture, or false to pass it on unchanged.

local function touchKey(pos)
    return pos.x .. ":" .. pos.y
end

local function onPan(ges)
    if not settings().enabled then return false end
    local key = touchKey(ges.start_pos)
    if slide and slide.key ~= key then
        -- The previous slide's lift never arrived (a second finger joined).
        finish()
    end
    if not slide then
        if passed_on == key then return false end
        local control = controlAt(ges.start_pos)
        if not control or math.abs(ges.relative.y) < math.abs(ges.relative.x) then
            -- Not on an edge, or heading sideways (a page turn): leave this
            -- touch alone until it lifts, even if it later turns vertical.
            passed_on = key
            return false
        end
        begin(key, control, ges.pos.y)
    end
    moveTo(ges.pos.y)
    UIManager:unschedule(finish)
    UIManager:scheduleIn(GIVE_UP_AFTER, finish)
    return true
end

local function onPanRelease(ges)
    passed_on = nil
    if not slide then return false end
    moveTo(ges.pos.y)
    finish()
    return true
end

-- A quick slide ends in a "swipe" rather than a "pan_release", and one that
-- changed direction on the way in a "multiswipe". Both are kept, so the
-- Gestures plugin does not add its own jump on top of what was just set.
local function onSwipe(ges)
    passed_on = nil
    if slide then
        if ges.end_pos then moveTo(ges.end_pos.y) end
        finish()
        return true
    end
    -- A flick too quick to have been seen as a slide first.
    if ges.ges ~= "swipe" or not settings().enabled then return false end
    if ges.direction ~= "north" and ges.direction ~= "south" then return false end
    local control = controlAt(ges.pos)
    if not control then return false end
    begin(touchKey(ges.pos), control, ges.pos.y)
    moveTo(ges.end_pos.y)
    finish()
    return true
end

-- ── Full-screen lists ───────────────────────────────────────────────────────
-- Wrapped once, for every Menu there is or will be. Each wrapper falls back to
-- the original handler for anything that is not an edge slide.

if not Menu._livelight_wrapped then
    Menu._livelight_wrapped = true

    -- Pop-up menus are narrower than the screen and are left alone.
    local function fillsScreen(menu)
        return menu.dimen ~= nil and menu.dimen.w == Screen:getWidth()
    end

    local menuOnPan = Menu.onPan
    function Menu:onPan(arg, ges)
        if fillsScreen(self) and not ges.mousewheel_direction and ges.start_pos and onPan(ges) then
            -- Menu does not listen for a finger lifting, and outside the file
            -- browser nothing else would hear it either.
            if not self.ges_events.LiveLightRelease then
                self.ges_events.LiveLightRelease = {
                    GestureRange:new{ ges = "pan_release", range = self.dimen },
                }
            end
            return true
        end
        return menuOnPan(self, arg, ges)
    end

    function Menu:onLiveLightRelease(arg, ges)
        return onPanRelease(ges)
    end

    -- Without these, lifting at the end of a quick slide downwards would also
    -- close the list, which is what a downward swipe means to a Menu.
    local menuOnSwipe = Menu.onSwipe
    function Menu:onSwipe(arg, ges)
        if slide then return onSwipe(ges) end
        return menuOnSwipe(self, arg, ges)
    end

    local menuOnMultiSwipe = Menu.onMultiSwipe
    function Menu:onMultiSwipe(arg, ges)
        if slide then return onSwipe(ges) end
        return menuOnMultiSwipe(self, arg, ges)
    end
end

-- ── Plugin ──────────────────────────────────────────────────────────────────

local LiveLight = WidgetContainer:extend{
    name = "livelight",
    is_doc_only = false,
}

function LiveLight:init()
    self.ui.menu:registerToMainMenu(self)

    local everywhere = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    -- The Gestures plugin's edge swipes, and the placeholders it registers
    -- beside each of them.
    local edge_swipes = {
        "one_finger_swipe_left_edge_down",
        "one_finger_swipe_left_edge_up",
        "one_finger_swipe_right_edge_down",
        "one_finger_swipe_right_edge_up",
    }
    local function ahead_of(ids, suffix)
        for _, id in ipairs(edge_swipes) do
            table.insert(ids, id .. suffix)
        end
        return ids
    end
    -- Home-screen plugins that sit on top of the file browser (Bookshelf, for
    -- one) hand it only the touches they do not use themselves, and only for
    -- zones they recognize as the file browser's, by this prefix. Without it
    -- the zones below would never be offered anything while such a home
    -- screen is showing.
    local prefix = self.ui.document and "livelight_" or "filemanager_livelight_"
    -- The zones cover the whole screen because a slide is recognized by where
    -- it started, and must be followed wherever the finger wanders after.
    self.ui:registerTouchZones({
        {
            id = prefix .. "pan",
            ges = "pan",
            screen_zone = everywhere,
            overrides = ahead_of({
                "rolling_pan",
                "paging_pan",
                "readermenu_pan",
                "readermenu_ext_pan",
                "readerconfigmenu_pan",
                "readerconfigmenu_ext_pan",
            }, "_pan"),
            handler = onPan,
        },
        {
            id = prefix .. "pan_release",
            ges = "pan_release",
            screen_zone = everywhere,
            overrides = ahead_of({
                "rolling_pan_release",
                "paging_pan_release",
            }, "_pan_release"),
            handler = onPanRelease,
        },
        {
            id = prefix .. "swipe",
            ges = "swipe",
            screen_zone = everywhere,
            overrides = ahead_of({
                "rolling_swipe",
                "paging_swipe",
                "swipe_link",
                "readermenu_swipe",
                "readermenu_ext_swipe",
                "readerconfigmenu_swipe",
                "readerconfigmenu_ext_swipe",
                "filemanager_swipe",
                "filemanager_ext_swipe",
            }, ""),
            handler = onSwipe,
        },
        {
            id = prefix .. "multiswipe",
            ges = "multiswipe",
            screen_zone = everywhere,
            overrides = { "multiswipe" },
            handler = onSwipe,
        },
    })
end

function LiveLight:onSuspend()
    abandon()
end

local EDGE_CHOICES = {
    { value = "brightness", text = _("Brightness") },
    { value = "warmth", text = _("Warmth"), needs_warmth = true },
    { value = "off", text = _("Off") },
}

-- What an edge actually does on this device: warmth counts as off where
-- there is no warmth to change.
local function edgeChoice(key)
    local choice = settings()[key]
    if choice == "warmth" and not Device:hasNaturalLight() then return "off" end
    return choice
end

-- One menu line per edge, showing its current choice, that opens a short
-- list to pick from.
local function edgeMenuItem(key, label)
    local choices = {}
    for _, choice in ipairs(EDGE_CHOICES) do
        if not choice.needs_warmth or Device:hasNaturalLight() then
            table.insert(choices, {
                text = choice.text,
                radio = true,
                keep_menu_open = true,
                checked_func = function() return edgeChoice(key) == choice.value end,
                callback = function() saveSetting(key, choice.value) end,
            })
        end
    end
    return {
        text_func = function()
            for _, choice in ipairs(EDGE_CHOICES) do
                if choice.value == edgeChoice(key) then
                    return label .. ": " .. choice.text
                end
            end
        end,
        help_text = _("Off leaves this edge to whatever is set in the gesture manager."),
        enabled_func = function() return settings().enabled end,
        sub_item_table = choices,
    }
end

function LiveLight:addToMainMenu(menu_items)
    menu_items.livelight = {
        text = _("LiveLight"),
        sorting_hint = "taps_and_gestures",
        sub_item_table = {
            {
                text = _("Enable LiveLight"),
                help_text = _("Slide a finger up or down the left edge for brightness, or the right edge for warmth (each edge can be changed below). The light follows your finger as it moves. When this is off, the edges go back to whatever is set in the gesture manager."),
                checked_func = function() return settings().enabled end,
                callback = function() saveSetting("enabled", not settings().enabled) end,
            },
            {
                text = _("Show level while sliding"),
                help_text = _("A small box near the top of the screen with the current brightness or warmth. It disappears a moment after you lift your finger."),
                enabled_func = function() return settings().enabled end,
                checked_func = function() return settings().show_level end,
                callback = function() saveSetting("show_level", not settings().show_level) end,
            },
            edgeMenuItem("left_edge", _("Left edge")),
            edgeMenuItem("right_edge", _("Right edge")),
        },
    }
end

return LiveLight
