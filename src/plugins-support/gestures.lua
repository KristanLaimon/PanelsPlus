-- Keep configured Gestures actions available over the fullscreen panel viewer.
local Gestures = {}

function Gestures.attach(viewer_class)
    local is_reader_zone = viewer_class.isReaderGestureZone
    function viewer_class:isReaderGestureZone(zone_id, gestures)
        if is_reader_zone(self, zone_id) then
            return true
        end
        gestures = gestures or (self.reader_ui and self.reader_ui.gestures)
        if not zone_id or not gestures or zone_id == "spread_gesture" or zone_id == "pinch_gesture" then
            return false
        end
        return zone_id == "multiswipe" or gestures.gestures and gestures.gestures[zone_id] ~= nil
    end
end

return Gestures
