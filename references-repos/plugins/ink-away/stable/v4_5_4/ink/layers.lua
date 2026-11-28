--[[
Layers in a drawing (never in a notebook or over a book). A drawing starts
without them; once they are turned on, everything drawn so far is the first
layer.

The ops stay one list, kept in the order they show on the page: each layer's
ops together, the layers from the bottom up. Everything that replays the list
(the screen, thumbnails, exports, and older versions of Ink Away) draws the
layers in order without knowing about them, and merging layers or turning them
off only relabels ops. An op's layer is op.layer, the layer's id (nil for the
first layer, whose id is 1).

  canvas.layers         nil, or { { id = n, name = <the reader's name, or nil> }, ... }
                        bottom to top (see Layers.label for what one is called)
                        (kept in the undo history)
  canvas.active_layer   the id that new ops go into, the only one edited
  canvas.hidden_layers  { [id] = true } for the layers not shown (not in the
                        history, as in most drawing apps)

The eraser of a layered drawing cuts strokes (ink/cut.lua), so a layer never
gets an erase op that would clear the layers under it too. Only the first layer
can hold erase ops, made before layers were turned on, and while it does it
stays at the bottom.

Plain Lua, so the headless tests drive it.
]]

local Canvas = require("ink/canvas")

local Layers = {}

Layers.MAX = 5   -- a few layers, not a stack: sketch, ink, colour, shading, background

-- Is the canvas layered?
function Layers.on(c) return c.layers ~= nil end

-- Note a change outside the active layer: the view's caches are made again.
local function touch(c) c.lrev = (c.lrev or 0) + 1 end
Layers.touch = touch

-- The layer id of an op.
local function of(op) return op.layer or 1 end
Layers.of = of

-- A copy of the layer list (each entry copied: renaming replaces an entry's name).
function Layers.copy(list)
    if not list then return nil end
    local out = {}
    for i, l in ipairs(list) do out[i] = { id = l.id, name = l.name } end
    return out
end

-- The position (1 = bottom) of layer `id`, or nil.
function Layers.pos(c, id)
    for i, l in ipairs(c.layers or {}) do if l.id == id then return i end end
    return nil
end

-- The layer entry with `id`, or nil.
function Layers.get(c, id)
    local p = Layers.pos(c, id)
    return p and c.layers[p] or nil
end

-- Make the active layer and the hidden set agree with the layer list (after an
-- undo or a load): an active layer that is gone becomes the top one.
function Layers.fix(c)
    touch(c)
    if not c.layers then
        c.active_layer, c.hidden_layers = nil, {}
        c._hid = (c._hid or 0) + 1
        return
    end
    if #c.layers == 0 then c.layers = { { id = 1 } } end
    if not Layers.pos(c, c.active_layer) then c.active_layer = c.layers[#c.layers].id end
    local hidden = {}
    for id in pairs(c.hidden_layers or {}) do
        if Layers.pos(c, id) then hidden[id] = true end
    end
    c.hidden_layers = hidden
    c._hid = (c._hid or 0) + 1
end

-- A layer's own name, or nil when it has none: "Layer n" is not a name of its
-- own but its place (drawings saved before kept those as names).
local function ownName(name)
    if type(name) ~= "string" or name == "" or name:match("^Layer %d+$") then return nil end
    return name
end
Layers.ownName = ownName

-- What a layer is called: the name the reader gave it, else "Layer n" with n its
-- place from the bottom, so the numbers always run 1, 2, 3 after a merge, a
-- move or a delete.
function Layers.label(c, id)
    local p = Layers.pos(c, id)
    if not p then return "" end
    return ownName(c.layers[p].name) or ("Layer " .. p)
end

-- Turn layers on: everything drawn so far is the first layer, and the active one.
function Layers.enable(c)
    touch(c)
    if c.layers then return false end
    c:pushHistory()
    -- (an op still labelled from another drawing joins the first layer)
    for i, op in ipairs(c.ops) do
        if op.layer ~= nil then
            op = Canvas.cloneOp(nil, op)
            op.layer = nil
            c.ops[i] = op
        end
    end
    c.layers = { { id = 1 } }
    c.active_layer = 1
    c.hidden_layers = {}
    c._hid = (c._hid or 0) + 1
    return true
end

-- Where a new op of layer `id` goes in the list: after the last op of that
-- layer, or of the layers under it when it is empty.
function Layers.insertIndex(c, id)
    local want = Layers.pos(c, id)
    if not want then return #c.ops + 1 end
    local pos = {}
    for i, l in ipairs(c.layers) do pos[l.id] = i end
    local ops = c.ops
    -- the list is in layer order: search from the end for the first op at or
    -- under the layer (the top layer, the usual one, finds it at once)
    for i = #ops, 1, -1 do
        local p = pos[of(ops[i])] or 1
        if p <= want then return i + 1 end
    end
    return 1
end

-- Can an op be edited (picked, moved, erased) now? Only the active layer's.
function Layers.editable(c, op)
    if not c.layers then return true end
    return of(op) == c.active_layer
end

-- Is layer `id` shown?
function Layers.shown(c, id)
    return not (c.hidden_layers and c.hidden_layers[id])
end

-- The ops to draw: all of them, or without the hidden layers' (a new list,
-- kept until the ops or the hidden set change).
function Layers.visible(c)
    if not c.layers or not next(c.hidden_layers or {}) then return c.ops end
    local key = c.rev .. ":" .. (c._hid or 0)
    if c._vis_key == key and c._vis_ops == c.ops then return c._vis end
    local out, hidden = {}, c.hidden_layers
    for _i, op in ipairs(c.ops) do
        if not hidden[of(op)] then out[#out + 1] = op end
    end
    c._vis, c._vis_key = out, key
    c._vis_ops = c.ops
    return out
end

-- The shown ops of the layers above the active one, and of all layers but the
-- active one, for the view's caches (empty lists when there are none).
function Layers.above(c)
    if not c.layers then return {} end
    local p = Layers.pos(c, c.active_layer) or #c.layers
    local pos = {}
    for i, l in ipairs(c.layers) do pos[l.id] = i end
    local out, hidden = {}, c.hidden_layers or {}
    for _i, op in ipairs(c.ops) do
        local id = of(op)
        if (pos[id] or 1) > p and not hidden[id] then out[#out + 1] = op end
    end
    return out
end
function Layers.others(c)
    if not c.layers then return {} end
    local out, hidden, act = {}, c.hidden_layers or {}, c.active_layer
    for _i, op in ipairs(c.ops) do
        local id = of(op)
        if id ~= act and not hidden[id] then out[#out + 1] = op end
    end
    return out
end

-- How many ops each layer holds: { [id] = n }.
function Layers.counts(c)
    local n = {}
    for _i, op in ipairs(c.ops) do local id = of(op); n[id] = (n[id] or 0) + 1 end
    return n
end

-- Does layer `id` hold an erase op from before layers were on?
function Layers.hasPixelErase(c, id)
    for _i, op in ipairs(c.ops) do
        if op.kind == "erase" and of(op) == id then return true end
    end
    return false
end

-- A new empty layer above the active one, made active. Returns its id, or nil
-- when there are as many as there can be.
function Layers.add(c)
    touch(c)
    if not c.layers or #c.layers >= Layers.MAX then return nil end
    c:pushHistory()
    local id = 0
    for _i, l in ipairs(c.layers) do id = math.max(id, l.id) end
    id = id + 1
    local at = (Layers.pos(c, c.active_layer) or #c.layers) + 1
    local layers = Layers.copy(c.layers)
    table.insert(layers, at, { id = id })
    c.layers = layers
    c.active_layer = id
    return id
end

-- The ops in layer order (each layer's ops in their own order), for a new
-- order of the layers.
local function regroup(c, layers)
    local by = {}
    for _i, l in ipairs(layers) do by[l.id] = {} end
    for _i, op in ipairs(c.ops) do
        local list = by[of(op)] or by[layers[1].id]
        list[#list + 1] = op
    end
    local out = {}
    for _i, l in ipairs(layers) do
        for _j, op in ipairs(by[l.id]) do out[#out + 1] = op end
    end
    return out
end

-- Can layer `id` move one place up (dir 1) or down (-1)? Returns ok, and the
-- reason when not: "edge" (nowhere to go) or "erase" (the first layer keeps
-- erasing from before layers were on, and has to stay at the bottom).
function Layers.canMove(c, id, dir)
    local p = Layers.pos(c, id)
    if not p then return false, "edge" end
    local q = p + dir
    if q < 1 or q > #c.layers then return false, "edge" end
    local low = math.min(p, q)
    if low == 1 and Layers.hasPixelErase(c, c.layers[1].id) then return false, "erase" end
    return true
end

-- Move layer `id` one place up or down.
function Layers.move(c, id, dir)
    touch(c)
    if not Layers.canMove(c, id, dir) then return false end
    local p = Layers.pos(c, id)
    c:pushHistory()
    local layers = Layers.copy(c.layers)
    layers[p], layers[p + dir] = layers[p + dir], layers[p]
    c.ops = regroup(c, layers)
    c.layers = layers
    return true
end

-- Rename layer `id`.
function Layers.rename(c, id, name)
    local p = Layers.pos(c, id)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not p or name == "" or Layers.label(c, id) == name then return false end
    c:pushHistory()
    local layers = Layers.copy(c.layers)
    layers[p].name = ownName(name)   -- ("Layer n" again: named by its place)
    c.layers = layers
    return true
end

-- Show or hide layer `id`.
function Layers.setHidden(c, id, hidden)
    touch(c)
    if not Layers.pos(c, id) then return false end
    c.hidden_layers = c.hidden_layers or {}
    if (c.hidden_layers[id] or false) == (hidden and true or false) then return false end
    c.hidden_layers[id] = hidden and true or nil
    c._hid = (c._hid or 0) + 1
    return true
end

-- The ops relabelled into layer `to` (copies of the ones that change, so the
-- undo history keeps the originals).
local function relabel(ops, from, to)
    local out, label = {}, (to ~= 1) and to or nil
    for i, op in ipairs(ops) do
        if from == nil or of(op) == from then
            if op.layer ~= label then
                op = Canvas.cloneOp(nil, op)
                op.layer = label
            end
        end
        out[i] = op
    end
    return out
end

-- Delete layer `id` and everything on it (not the last layer).
function Layers.remove(c, id)
    touch(c)
    local p = Layers.pos(c, id)
    if not p or #c.layers < 2 then return false end
    c:pushHistory()
    local out = {}
    for _i, op in ipairs(c.ops) do
        if of(op) ~= id then out[#out + 1] = op end
    end
    c.ops = out
    local layers = Layers.copy(c.layers)
    table.remove(layers, p)
    c.layers = layers
    if c.active_layer == id then c.active_layer = layers[math.max(1, p - 1)].id end
    if c.hidden_layers then c.hidden_layers[id] = nil end
    c._hid = (c._hid or 0) + 1
    return true
end

-- Merge layer `id` into the one under it: its ops go on top of that layer's,
-- which shows the page exactly as before (the list is already in that order).
-- The merged layer is shown and active. Returns the id merged into, or nil.
function Layers.mergeDown(c, id)
    touch(c)
    local p = Layers.pos(c, id)
    if not p or p < 2 then return nil end
    local to = c.layers[p - 1].id
    c:pushHistory()
    c.ops = relabel(c.ops, id, to)
    local layers = Layers.copy(c.layers)
    table.remove(layers, p)
    c.layers = layers
    c.active_layer = to
    if c.hidden_layers then c.hidden_layers[id] = nil; c.hidden_layers[to] = nil end
    c._hid = (c._hid or 0) + 1
    return to
end

-- Turn layers off: every layer, hidden ones too, merged into one drawing that
-- looks as the layers did together.
function Layers.flatten(c)
    touch(c)
    if not c.layers then return false end
    c:pushHistory()
    c.ops = relabel(c.ops, nil, 1)
    c.layers = nil
    Layers.fix(c)
    return true
end

-- The ops of a drawing file to draw, without its hidden layers' (`saved` as
-- Layers.save made it): for its thumbnail and for exports made from the file.
function Layers.drawnOfFile(ops, saved)
    if type(ops) ~= "table" or type(saved) ~= "table" or type(saved.hidden) ~= "table"
            or #saved.hidden == 0 then
        return ops
    end
    local hidden = {}
    for _i, id in ipairs(saved.hidden) do hidden[id] = true end
    local out = {}
    for _i, op in ipairs(ops) do
        if not hidden[of(op)] then out[#out + 1] = op end
    end
    return out
end

-- The fields a drawing file keeps (nil without layers).
function Layers.save(c)
    if not c.layers then return nil end
    local hidden = {}
    for _i, l in ipairs(c.layers) do
        if c.hidden_layers and c.hidden_layers[l.id] then hidden[#hidden + 1] = l.id end
    end
    return { list = Layers.copy(c.layers), active = c.active_layer, hidden = hidden }
end

-- Restore them from a drawing file (`saved` as Layers.save made it, or nil),
-- checking what it holds. Ops of a layer the list does not know go to the first.
function Layers.load(c, saved)
    c.layers, c.active_layer, c.hidden_layers = nil, nil, {}
    if type(saved) == "table" and type(saved.list) == "table" then
        local list, seen = {}, {}
        for _i, l in ipairs(saved.list) do
            local id = type(l) == "table" and tonumber(l.id)
            if id and id >= 1 and id == math.floor(id) and not seen[id] and #list < Layers.MAX then
                seen[id] = true
                list[#list + 1] = { id = id, name = ownName(l.name) }
            end
        end
        if #list > 0 then
            c.layers = list
            c.active_layer = tonumber(saved.active)
            for _i, id in ipairs(type(saved.hidden) == "table" and saved.hidden or {}) do
                c.hidden_layers[id] = true
            end
            -- ops of a layer that is not in the list (a damaged file) join the first
            local known = {}
            for _i, l in ipairs(list) do known[l.id] = true end
            for i, op in ipairs(c.ops) do
                if not known[of(op)] then
                    op = Canvas.cloneOp(nil, op)
                    op.layer = list[1].id ~= 1 and list[1].id or nil
                    c.ops[i] = op
                end
            end
            -- and the list is put back in layer order, as it is drawn
            c.ops = regroup(c, list)
        end
    end
    Layers.fix(c)
end

return Layers
