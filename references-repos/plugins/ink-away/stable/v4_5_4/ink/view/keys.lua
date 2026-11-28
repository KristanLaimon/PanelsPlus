--[[
Typing into a text box from a physical keyboard: a Bluetooth or USB keyboard
KOReader has set up (its External keyboard plugin, or Android's own), or the
computer's in the emulator. KOReader sends each key to the widget on top, and
while a box is open the canvas also gets what the on-screen keyboard leaves
(see showTextKeyboard). Keys type only into an open box; otherwise they go on
to the canvas's own key bindings (page turn buttons, Back).
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local Text = require("ink/text")

local InkAwayView = {}

-- Device:isSDL() and the like, false where a device does not say.
local function deviceIs(name)
    local f = Device[name]
    if type(f) ~= "function" then return false end
    local ok, yes = pcall(f, Device)
    return ok and yes == true
end

-- What a key types with Shift held, on a US layout.
local SHIFTED = {
    ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%",
    ["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
    ["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}", ["\\"] = "|",
    [";"] = ":", ["'"] = "\"", [","] = "<", ["."] = ">", ["/"] = "?", ["`"] = "~",
}

-- Keys KOReader's map for full size keyboards leaves out (minus, equals, the
-- brackets and the backtick), lent to it while a box is open.
local EXTRA_CODES = { [12] = "-", [13] = "=", [26] = "[", [27] = "]", [41] = "`" }

-- Is KOReader's full size keyboard map in use (its External keyboard plugin
-- merges it in when a keyboard connects)?
local function fullKeyboardMap(map)
    return type(map) == "table" and map[57] == " " and map[14] == "Backspace"
end

-- Does KOReader count a physical keyboard here, and keep its on-screen one
-- away? The rule KOReader's own text fields follow; it can be turned back on in
-- KOReader's keyboard settings. Not in the emulator, which always has a
-- keyboard.
function InkAwayView:physicalKeyboard()
    if not (deviceIs("hasKeyboard") or deviceIs("hasScreenKB")) or deviceIs("isSDL") then return false end
    local ok, off = pcall(function() return G_reader_settings:nilOrFalse("virtual_keyboard_enabled") end)
    return ok and off == true
end

-- Lend the missing keys to KOReader's key map while a box is open, and take
-- them back after.
function InkAwayView:lendKeys()
    local map = Device.input and Device.input.event_map
    if self._lent_keys or not fullKeyboardMap(map) then return end
    local lent = {}
    for code, name in pairs(EXTRA_CODES) do
        if map[code] == nil then map[code] = name; lent[code] = name end
    end
    self._lent_keys = { map = map, codes = lent }
end

function InkAwayView:returnKeys()
    local l = self._lent_keys
    if not l then return end
    for code, name in pairs(l.codes) do
        if l.map[code] == name then l.map[code] = nil end
    end
    self._lent_keys = nil
end

-- Delete the character after the caret (Del on a full size keyboard).
function InkAwayView:textDelNext()
    if not self.editing_text then return end
    self:textMark("delete")
    if not self:textDeleteSelIfAny() then
        local op, cur = self.editing_text, self.text_cur
        if cur.o < Text.paraLen(op.paras[cur.p]) then
            Text.deleteRange(op, { a = cur, b = { p = cur.p, o = cur.o + 1 } })
        elseif cur.p < #op.paras then
            Text.deleteRange(op, { a = cur, b = { p = cur.p + 1, o = 0 } })
        end
    end
    self:afterTextEdit()
end

-- What the character key `k` types, with Shift and Caps Lock.
function InkAwayView:keyChar(key)
    local k = key.key
    if k:match("^%a$") then
        if (key.Shift and true or false) ~= (self._caps_lock and true or false) then return k:upper() end
        return k:lower()
    end
    -- the full size map names the semicolon key by its shifted sign
    if k == ":" and fullKeyboardMap(Device.input and Device.input.event_map) then k = ";" end
    if key.Shift and SHIFTED[k] then return SHIFTED[k] end
    return k
end

-- Type `key` into the open box. Returns whether the key was used.
function InkAwayView:typeKey(key)
    local k = key.key
    if k == "LCtrl" then self._left_ctrl = true; return true end
    if k == "CapsLock" then self._caps_lock = not self._caps_lock; return true end
    if key.Ctrl or self._left_ctrl then
        if k == "Z" then
            if key.Shift then self:textRedo() else self:textUndo() end
        elseif k == "Y" then self:textRedo()
        elseif k == "A" then self:textSelectAll()
        elseif k == "C" then self:textCopy()
        elseif k == "X" then self:textCopy(true)
        elseif k == "V" then self:textPaste()
        else return false end
        return true
    end
    if key.Alt or key.Meta then return false end
    -- Android names Backspace "Del"
    if k == "Backspace" or (k == "Del" and deviceIs("isAndroid")) then self:textDelChar()
    elseif k == "Del" then self:textDelNext()
    elseif k == "Left" then self:textMove(-1, 0)
    elseif k == "Right" then self:textMove(1, 0)
    elseif k == "Up" then self:textMove(0, -1)
    elseif k == "Down" then self:textMove(0, 1)
    elseif k == "Home" or k == "KeyHome" then self:textHome()
    elseif k == "End" then self:textEnd()
    elseif k == "Press" then self:textAddChars("\n")
    elseif k == "Tab" then self:textAddChars("    ")
    elseif k == "Back" then self:finishTextEdit(true)   -- Esc: done with the box
    elseif #k == 1 then
        -- the emulator types letters through TextInput (onTextInput) instead
        if not deviceIs("isSDL") then self:textAddChars(self:keyChar(key)) end
    else
        return false
    end
    return true
end

-- Then the canvas's own key bindings, as any KOReader widget.
local function bindings(self, name, key)
    local f = InputContainer[name]
    if f then return f(self, key) end
end

function InkAwayView:onKeyPress(key)
    if self.editing_text and self:typeKey(key) then return true end
    return bindings(self, "onKeyPress", key)
end

-- KOReader repeats only the arrow and page turn keys.
function InkAwayView:onKeyRepeat(key)
    if self.editing_text and (key.Left or key.Right or key.Up or key.Down) then return self:typeKey(key) end
    return bindings(self, "onKeyRepeat", key)
end

function InkAwayView:onKeyRelease(key)
    if key and key.key == "LCtrl" then self._left_ctrl = nil end
    return false
end

-- Text the emulator's window typed (SDL sends letters this way).
function InkAwayView:onTextInput(text)
    if not (self.editing_text and text and text ~= "") then return false end
    self:textAddChars(text)
    return true
end

return InkAwayView
