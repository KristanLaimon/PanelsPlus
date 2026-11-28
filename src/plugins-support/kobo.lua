-- Kobo page-turner aliases use the same navigation as KOReader page events.
local Kobo = {}

function Kobo.attach(viewer_class)
    for name, method in pairs(Kobo) do
        if name ~= "attach" then
            viewer_class[name] = method
        end
    end
end

--- Page-forward event handlers for physical buttons and Bluetooth page turners.
function Kobo:onGotoNextPage()
    return self:onShowNextImage()
end

function Kobo:onPageForward()
    return self:onShowNextImage()
end

function Kobo:onShowNextPage()
    return self:onShowNextImage()
end

function Kobo:onPhysicalPageForward()
    return self:onShowNextImage()
end

function Kobo:onNextPage()
    return self:onShowNextImage()
end

--- Page-backward event handlers for physical buttons and Bluetooth page turners.
function Kobo:onGotoPrevPage()
    return self:onShowPrevImage()
end

function Kobo:onPageBackward()
    return self:onShowPrevImage()
end

function Kobo:onShowPrevPage()
    return self:onShowPrevImage()
end

function Kobo:onPhysicalPageBackward()
    return self:onShowPrevImage()
end

function Kobo:onPrevPage()
    return self:onShowPrevImage()
end

--- Relative page and position jump event handlers.
function Kobo:onGotoPageRel(diff)
    return self:onGotoViewRel(diff)
end

function Kobo:onGotoPosRel(diff)
    return self:onGotoViewRel(diff)
end

return Kobo
