--[[
KOReader up to 2026.07 cannot sort a book's highlights when one of them points at
nothing in the book: its order function then answers "first" for both of a pair, and
opening the book stops with "invalid order function for sorting", every time, so the
book can no longer be opened at all. KOReader fixed this in September 2026 (#15994,
"Annotations: fix invalid XPointers order"): such highlights go to the start. Where
that fix is missing, it is put in here, word for word, so nothing Ink Away or anyone
else leaves in a book can lock it.
]]

local AnnotationOrder = {}

-- KOReader's ReaderAnnotation:getInvalidXPointersOrder (#15994).
local function getInvalidXPointersOrder(self, a, b, key)
    local is_a_valid = self.document:isXPointerInDocument(a[key])
    local is_b_valid = self.document:isXPointerInDocument(b[key])
    if is_a_valid and is_b_valid then return end
    -- sort highlights with invalid xpointer to page 1
    if is_a_valid then
        return false
    elseif is_b_valid then
        return true
    else -- both invalid
        return tostring(a.datetime or "") < tostring(b.datetime or "")
    end
end

-- KOReader's ReaderAnnotation:isItemInPositionOrderRolling (#15994).
local function isItemInPositionOrderRolling(self, a, b)
    local order = self:getInvalidXPointersOrder(a, b, "page")
    if order ~= nil then
        return order
    end
    local a_page = self.document:getPageFromXPointer(a.page)
    local b_page = self.document:getPageFromXPointer(b.page)
    if a_page ~= b_page then
        return a_page < b_page
    end
    -- same page
    if (not a.drawer) ~= (not b.drawer) then -- comparing a page bookmark and a highlight
        return not a.drawer -- sort page bookmark before highlights
    end
    local compare_xp = self.document:compareXPointers(a.page, b.page)
    if a.drawer and compare_xp == 0 then -- both highlights with the same start, compare ends
        order = self:getInvalidXPointersOrder(a, b, "pos1")
        if order ~= nil then
            return order
        end
        return self.document:compareXPointers(a.pos1, b.pos1) > 0
    end
    return (compare_xp or 0) > 0
end

-- Put the fix into `ReaderAnnotation` (KOReader's module) when it is not there.
-- Returns true when it was put in.
function AnnotationOrder.install(ReaderAnnotation)
    if type(ReaderAnnotation) ~= "table" or ReaderAnnotation.getInvalidXPointersOrder ~= nil then return false end
    if type(ReaderAnnotation.isItemInPositionOrderRolling) ~= "function" then return false end
    ReaderAnnotation.getInvalidXPointersOrder = getInvalidXPointersOrder
    ReaderAnnotation.isItemInPositionOrderRolling = isItemInPositionOrderRolling
    return true
end

return AnnotationOrder
