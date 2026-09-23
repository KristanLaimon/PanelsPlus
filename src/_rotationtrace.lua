--[[
Panels+
File: src/_rotationtrace.lua
Name: RotationTrace
Description: Android panel-viewer geometry trace for KOReader bug reports.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local has_android, android = pcall(require, "android")

local RotationTrace = {
    enabled = Device.isAndroid and Device:isAndroid() or false,
}
local next_viewer_id = 0
local next_event_id = 0

local function value(v)
    return v == nil and "?" or tostring(v)
end

local function rect(r)
    if not r then
        return "?"
    end
    return string.format("%s,%s %sx%s", value(r.x), value(r.y), value(r.w), value(r.h))
end

local function dimensions(bb)
    if not bb then
        return "?"
    end
    local ok_w, w = pcall(function()
        return bb.getWidth and bb:getWidth() or bb.w
    end)
    local ok_h, h = pcall(function()
        return bb.getHeight and bb:getHeight() or bb.h
    end)
    return string.format("%sx%s", ok_w and value(w) or "error", ok_h and value(h) or "error")
end

local function read(object, method)
    if not object or type(object[method]) ~= "function" then
        return "?"
    end
    local ok, result = pcall(object[method], object)
    return ok and value(result) or "error"
end

local function logLine(message)
    next_event_id = next_event_id + 1
    logger.info(string.format("[Panels+ rotation #%d] %s", next_event_id, message))
end

--- Log a stage without a viewer, such as the owner's rebuild request.
function RotationTrace.note(stage, detail)
    if not RotationTrace.enabled then
        return
    end
    logLine(stage .. " " .. (detail or ""))
end

--- Capture the Android window, KOReader canvas, viewer crop, and paint bounds.
--- Values are split across short logcat records so Android does not truncate
--- the most useful numbers from a single overlong record.
function RotationTrace.snapshot(stage, viewer, event_dimen)
    if not RotationTrace.enabled then
        return
    end
    local ok, err = pcall(function()
        if viewer and not viewer._panels_plus_rotation_trace_id then
            next_viewer_id = next_viewer_id + 1
            viewer._panels_plus_rotation_trace_id = next_viewer_id
        end
        local id = viewer and viewer._panels_plus_rotation_trace_id or "?"
        local android_size = has_android
                and string.format("%sx%s", read(android, "getScreenWidth"), read(android, "getScreenHeight"))
            or "?"
        local android_available = has_android
                and string.format(
                    "%sx%s",
                    read(android, "getScreenAvailableWidth"),
                    read(android, "getScreenAvailableHeight")
                )
            or "?"
        local android_cached = has_android and android.screen or nil
        local sdk = has_android and android.app and android.app.activity and android.app.activity.sdkVersion
        logLine(
            string.format(
                "%s viewer=%s device=%s sdk=%s rotation=%s screen=%sx%s raw=%sx%s viewport=%s bb=%s android=%s available=%s cached=%sx%s event=%s",
                stage,
                value(id),
                value(Device.model),
                value(sdk),
                read(Screen, "getRotationMode"),
                read(Screen, "getWidth"),
                read(Screen, "getHeight"),
                read(Screen, "getScreenWidth"),
                read(Screen, "getScreenHeight"),
                rect(Screen.viewport),
                dimensions(Screen.bb),
                android_size,
                android_available,
                value(android_cached and android_cached.width),
                value(android_cached and android_cached.height),
                rect(event_dimen)
            )
        )
        if not viewer then
            return
        end
        local index = viewer._images_list_cur or viewer.initial_image_num or 1
        local panel = viewer.panels and viewer.panels[index]
        local crop = viewer.image_rects and viewer.image_rects[index]
        logLine(
            string.format(
                "%s viewer=%s state closed=%s page=%s index=%s/%s crop_mode=%s margin=%s bleed=%s buttons=%s progress=%s image_rotation=%s effective_rotation=%s scale=%s fit=%s panel=%s crop=%s source=%s image=%s",
                stage,
                value(id),
                value(viewer._panels_plus_closed),
                value(viewer.page),
                value(index),
                value(viewer._images_list_nb or viewer.images_list_nb),
                value(viewer.crop_mode),
                value(viewer.margin_ratio),
                value(viewer.bleed_ratio),
                value(viewer.buttons_visible),
                value(viewer.progress_bar_visible),
                value(viewer.image_rotation),
                value(viewer.rotated),
                value(viewer.scale_factor),
                value(viewer._scale_to_fit),
                rect(panel),
                rect(crop),
                dimensions(viewer.embedded_source_image),
                type(viewer.image) == "table" and "list" or dimensions(viewer.image)
            )
        )
        local image_widget = viewer._image_wg
        logLine(
            string.format(
                "%s viewer=%s layout region=%s frame=%s widget=%s image_container=%s outer=%sx%s content_height=%s widget_box=%sx%s rendered=%sx%s widget_rotation=%s offset=%s,%s center=%s,%s",
                stage,
                value(id),
                rect(viewer.region),
                rect(viewer.main_frame and viewer.main_frame.dimen),
                rect(image_widget and image_widget.dimen),
                rect(viewer.image_container and viewer.image_container.dimen),
                value(viewer.width),
                value(viewer.height),
                value(viewer.img_container_h),
                value(image_widget and image_widget.width),
                value(image_widget and image_widget.height),
                read(image_widget, "getCurrentWidth"),
                read(image_widget, "getCurrentHeight"),
                value(image_widget and image_widget.rotation_angle),
                value(image_widget and image_widget._offset_x),
                value(image_widget and image_widget._offset_y),
                value(viewer._center_x_ratio),
                value(viewer._center_y_ratio)
            )
        )
    end)
    if not ok then
        logger.warn("[Panels+ rotation] snapshot failed:", tostring(err))
    end
end

return RotationTrace
