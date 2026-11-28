-- LiveLight owns the whole edge slide, including release, even while zoomed.
local LiveLight = {}
local TOUCH_ZONES = {
    livelight_pan = true,
    livelight_pan_release = true,
    livelight_swipe = true,
    livelight_multiswipe = true,
}

function LiveLight.attach(viewer_class)
    local is_reader_zone = viewer_class.isReaderGestureZone
    local allows_panning = viewer_class.allowsReaderGestureWhilePanning
    function viewer_class:isReaderGestureZone(zone_id, gestures)
        return TOUCH_ZONES[zone_id] == true or is_reader_zone(self, zone_id, gestures)
    end
    function viewer_class:allowsReaderGestureWhilePanning(zone_id)
        return TOUCH_ZONES[zone_id] == true or allows_panning(self, zone_id)
    end
end

return LiveLight
