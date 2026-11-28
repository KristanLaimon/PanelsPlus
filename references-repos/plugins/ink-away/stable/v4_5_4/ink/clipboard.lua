--[[
The ink clipboard: what was cut or copied with the lasso, kept while KOReader
runs, so it can be pasted on another page or into another document.
Plain Lua, so the headless tests drive it.
]]

local Canvas = require("ink/canvas")
local Notebook = require("ink/notebook")

local deepcopy = Notebook.deepcopy
local translateOp = Canvas.translateOp

local Clipboard = {}

local held   -- { ops = { ... }, bbox = { x0, y0, x1, y1 } }

-- Keep copies of `ops`, whose box is `bbox` (canvas coords).
function Clipboard.put(ops, bbox)
    held = { ops = deepcopy(ops), bbox = { x0 = bbox.x0, y0 = bbox.y0, x1 = bbox.x1, y1 = bbox.y1 } }
end

-- How many ops it holds (0 when empty).
function Clipboard.count()
    return held and #held.ops or 0
end

-- Fresh copies of what it holds, moved so the middle of their box lands on
-- (cx, cy), or where they came from when no point is given.
function Clipboard.take(cx, cy)
    if not held then return {} end
    local b = held.bbox
    local dx, dy = 0, 0
    if cx and cy then
        dx = math.floor(cx - (b.x0 + b.x1) / 2 + 0.5)
        dy = math.floor(cy - (b.y0 + b.y1) / 2 + 0.5)
    end
    local out = {}
    for i, op in ipairs(held.ops) do
        local c = deepcopy(op)
        if dx ~= 0 or dy ~= 0 then translateOp(c, dx, dy) end
        out[i] = c
    end
    return out
end

function Clipboard.clear()
    held = nil
end

return Clipboard
