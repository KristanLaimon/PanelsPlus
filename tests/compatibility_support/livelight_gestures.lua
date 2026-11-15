-- Real LiveLight zones and light handlers; KOReader screen, power and timers are fixtures.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, check = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")

return function(reference)
    local function setup(pannable, options)
        options = options or {}
        local stored = { enabled = options.enabled ~= false, show_level = false, right_edge = options.right_edge }
        local tasks, zones = {}, {}
        local power =
            { fl_min = 0, fl_max = 100, fl_warmth_min = 0, fl_warmth_max = 10, intensity = 40, warmth = 5, saves = 0 }
        function power:frontlightIntensity()
            return self.intensity
        end
        function power:setIntensity(level)
            self.intensity = level
        end
        function power:turnOffFrontlight()
            self.intensity = 0
        end
        function power:frontlightWarmth()
            return self.warmth
        end
        function power:toNativeWarmth(level)
            return level
        end
        function power:fromNativeWarmth(level)
            return level
        end
        function power:setWarmth(level)
            self.warmth = level
        end
        function power:updateResumeFrontlightState()
            self.saves = self.saves + 1
        end
        local widget = {}
        function widget:extend(fields)
            return setmetatable(fields, { __index = self })
        end
        function widget:new(fields)
            local instance = setmetatable(fields, { __index = self })
            instance:init()
            return instance
        end
        local dependencies = {
            ["device"] = {
                screen = {
                    getWidth = function()
                        return 800
                    end,
                    getHeight = function()
                        return 1000
                    end,
                },
                hasFrontlight = function()
                    return options.frontlight ~= false
                end,
                isTouchDevice = function()
                    return options.touch ~= false
                end,
                hasNaturalLight = function()
                    return options.warmth ~= false
                end,
                getPowerDevice = function()
                    return power
                end,
            },
            ["ui/widget/container/widgetcontainer"] = widget,
            ["ui/widget/menu"] = {},
            ["optmath"] = {
                round = function(value)
                    return math.floor(value + 0.5)
                end,
            },
            ["gettext"] = function(value)
                return value
            end,
            ["ui/uimanager"] = {
                scheduleIn = function(_, delay, callback)
                    tasks[callback] = delay
                end,
                unschedule = function(_, callback)
                    tasks[callback] = nil
                end,
            },
        }
        local environment = setmetatable({
            G_reader_settings = {
                readSetting = function()
                    return stored
                end,
            },
            require = function(name)
                return dependencies[name] or {}
            end,
        }, { __index = _G })
        local LiveLight = assert(loadfile(reference .. "/main.lua", "t", environment))()
        if LiveLight.disabled then
            return nil, nil, nil, LiveLight
        end
        local ui = {
            document = {},
            menu = { registerToMainMenu = function() end },
            registerTouchZones = function(_, definitions)
                for _, definition in ipairs(definitions) do
                    zones[#zones + 1] = {
                        def = definition,
                        handler = definition.handler,
                        gs_range = {
                            match = function(_, gesture)
                                return gesture.ges == definition.ges
                            end,
                        },
                    }
                end
            end,
        }
        local plugin = LiveLight:new({ ui = ui })
        ui._ordered_touch_zones = zones
        local viewer = setmetatable({
            reader_ui = ui,
            isOpen = function()
                return true
            end,
            isImagePannable = function()
                return pannable
            end,
            onClose = function()
                error("LiveLight must not close Panels+")
            end,
        }, { __index = PanelViewer })
        return viewer, power, { plugin = plugin, tasks = tasks, zones = zones }
    end

    local function gesture(kind, x, y, start_x)
        return {
            ges = kind,
            start_pos = { x = start_x or x, y = 700 },
            pos = { x = x, y = y },
            end_pos = { x = x, y = y },
            relative = { x = 0, y = -70 },
            direction = "north",
        }
    end

    describe("LiveLight reference-backed Panels+ gestures", function()
        for _, pannable in ipairs({ false, true }) do
            for _, ending in ipairs({ "pan_release", "swipe", "multiswipe" }) do
                it("adjusts brightness and finishes " .. ending .. ", pannable=" .. tostring(pannable), function()
                    local viewer, power, state = setup(pannable)
                    check.is_true(viewer:onGesture(gesture("pan", 10, 600)))
                    -- Once claimed, a slide follows the finger away from the edge.
                    check.is_true(viewer:onGesture(gesture("pan", 400, 460, 10)))
                    check.equals(60, power.intensity)
                    check.is_true(viewer:onGesture(gesture(ending, 400, 390, 10)))
                    check.equals(70, power.intensity)
                    check.equals(1, power.saves)
                    state.plugin:onSuspend()
                    check.is_nil(next(state.tasks))
                end)
            end
            it("adjusts warmth while pannable=" .. tostring(pannable), function()
                local viewer, power, state = setup(pannable)
                check.is_true(viewer:onGesture(gesture("pan", 790, 600)))
                check.is_true(viewer:onGesture(gesture("pan_release", 790, 460)))
                check.equals(7, power.warmth)
                check.equals(40, power.intensity)
                check.equals(1, power.saves)
                state.plugin:onSuspend()
            end)
        end
        it("uses all four zones registered by the actual plugin", function()
            local viewer, _, state = setup(true)
            check.equals(4, #state.zones)
            for _, zone in ipairs(state.zones) do
                check.is_true(viewer:isReaderGestureZone(zone.def.id))
                check.is_true(viewer:allowsReaderGestureWhilePanning(zone.def.id))
                check.is_true(#zone.def.overrides > 0)
            end
            state.plugin:onSuspend()
        end)
        it("handles a quick edge flick without a preceding pan", function()
            local viewer, power, state = setup(true)
            local flick = gesture("swipe", 10, 600)
            flick.end_pos.y = 460
            check.is_true(viewer:onGesture(flick))
            check.equals(60, power.intensity)
            check.equals(1, power.saves)
            state.plugin:onSuspend()
        end)
        for _, scenario in ipairs({ "disabled", "center", "horizontal", "edge_off", "no_warmth" }) do
            it("leaves unclaimed gestures to Panels+: " .. scenario, function()
                local viewer, power, state = setup(true, {
                    enabled = scenario ~= "disabled",
                    right_edge = scenario == "edge_off" and "off" or nil,
                    warmth = scenario ~= "no_warmth",
                })
                local x = scenario == "center" and 400 or 10
                if scenario == "edge_off" or scenario == "no_warmth" then
                    x = 790
                end
                local pan = gesture("pan", x, 600)
                if scenario == "horizontal" then
                    pan.relative = { x = 70, y = 0 }
                end
                check.is_false(viewer:dispatchReaderGesture(pan))
                check.is_false(viewer:dispatchReaderGesture(gesture("pan_release", x, 460)))
                check.equals(40, power.intensity)
                check.equals(5, power.warmth)
                check.equals(0, power.saves)
                state.plugin:onSuspend()
                check.is_nil(next(state.tasks))
            end)
        end
        it("cancels slide state and timers on suspend", function()
            local viewer, power, state = setup(true)
            check.is_true(viewer:onGesture(gesture("pan", 10, 600)))
            state.plugin:onSuspend()
            check.is_nil(next(state.tasks))
            check.is_false(viewer:dispatchReaderGesture(gesture("pan_release", 10, 460)))
            check.equals(40, power.intensity)
        end)
        for _, capability in ipairs({ "frontlight", "touch" }) do
            it("disables itself without device capability: " .. capability, function()
                local _, _, _, plugin = setup(false, { [capability] = false })
                check.is_true(plugin.disabled)
            end)
        end
    end)
end
