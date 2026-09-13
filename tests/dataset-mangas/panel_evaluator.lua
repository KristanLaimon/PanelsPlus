--[[
Panels+
File: tests/dataset-mangas/panel_evaluator.lua
Name: PanelEvaluator
Description: Computes IoU matching, precision, recall, F1, and reading-order metrics.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Evaluation and benchmark metrics for panel segmentation.
---
--- Computes IoU (Intersection over Union), Precision, Recall, F1 score,
--- mean IoU, reading order accuracy, and failure classifications.

local PanelEvaluator = {}

--- Calculate Intersection over Union (IoU) between two bounding boxes {x, y, w, h}.
---
--- @param a table {x:number, y:number, w:number, h:number}
--- @param b table {x:number, y:number, w:number, h:number}
--- @return number IoU in range [0.0, 1.0]
function PanelEvaluator.boxIoU(a, b)
    local x1 = math.max(a.x, b.x)
    local y1 = math.max(a.y, b.y)
    local x2 = math.min(a.x + a.w, b.x + b.w)
    local y2 = math.min(a.y + a.h, b.y + b.h)

    local inter_w = math.max(0, x2 - x1)
    local inter_h = math.max(0, y2 - y1)
    local inter_area = inter_w * inter_h

    local area_a = a.w * a.h
    local area_b = b.w * b.h
    local union_area = area_a + area_b - inter_area

    if union_area <= 0 then
        return 0
    end
    return inter_area / union_area
end

--- Check whether box `b` matches box `a` within an IoU threshold or a coordinate gap tolerance.
---
--- @param a table {x:number, y:number, w:number, h:number}
--- @param b table {x:number, y:number, w:number, h:number}
--- @param iou_threshold number|nil Threshold for a true positive match (defaults to 0.5)
--- @param gap_tolerance number|nil Coordinate gap tolerance in pixels (e.g. 35)
--- @return boolean matches True if matched
--- @return number iou IoU between boxes
function PanelEvaluator.boxMatch(a, b, iou_threshold, gap_tolerance)
    local iou = PanelEvaluator.boxIoU(a, b)
    if iou >= (iou_threshold or 0.5) then
        return true, iou
    end
    if gap_tolerance and gap_tolerance > 0 then
        local dx1 = math.abs((a.x or 0) - (b.x or 0))
        local dy1 = math.abs((a.y or 0) - (b.y or 0))
        local dx2 = math.abs(((a.x or 0) + (a.w or 0)) - ((b.x or 0) + (b.w or 0)))
        local dy2 = math.abs(((a.y or 0) + (a.h or 0)) - ((b.y or 0) + (b.h or 0)))
        if dx1 <= gap_tolerance and dy1 <= gap_tolerance and dx2 <= gap_tolerance and dy2 <= gap_tolerance then
            return true, math.max(iou, iou_threshold or 0.5)
        end
    end
    return false, iou
end

--- Evaluate detected panels against ground-truth panels.
---
--- @param ground_truth table Array of {x, y, w, h} in annotated reading order
--- @param detected table Array of {x, y, w, h} in detected reading order
--- @param iou_threshold number|nil Threshold for a true positive match (defaults to 0.5)
--- @param gap_tolerance number|nil Coordinate difference tolerance in pixels (e.g. 35)
--- @return table Detailed evaluation metrics
function PanelEvaluator.evaluate(ground_truth, detected, iou_threshold, gap_tolerance)
    iou_threshold = iou_threshold or 0.5
    local n_gt = #ground_truth
    local n_det = #detected

    -- Build match matrix
    local pairs = {}
    for g_idx, g_box in ipairs(ground_truth) do
        for d_idx, d_box in ipairs(detected) do
            local matched, iou = PanelEvaluator.boxMatch(g_box, d_box, iou_threshold, gap_tolerance)
            if matched then
                table.insert(pairs, {
                    g_idx = g_idx,
                    d_idx = d_idx,
                    iou = iou,
                })
            end
        end
    end

    -- Sort candidates by descending IoU for greedy bipartite matching
    table.sort(pairs, function(a, b)
        return a.iou > b.iou
    end)

    local matched_gt = {}
    local matched_det = {}
    local matches = {}
    local total_iou = 0

    for _, pair in ipairs(pairs) do
        if not matched_gt[pair.g_idx] and not matched_det[pair.d_idx] then
            matched_gt[pair.g_idx] = pair.d_idx
            matched_det[pair.d_idx] = pair.g_idx
            total_iou = total_iou + pair.iou
            table.insert(matches, pair)
        end
    end

    local tp = #matches
    local fp = n_det - tp
    local fn = n_gt - tp

    local precision = n_det > 0 and (tp / n_det) or 0
    local recall = n_gt > 0 and (tp / n_gt) or 0
    local f1 = (precision + recall > 0) and (2 * precision * recall / (precision + recall)) or 0
    local m_iou = tp > 0 and (total_iou / tp) or 0

    -- Reading order check: if all panels matched, verify order consistency
    local order_correct = (tp == n_gt and tp == n_det)
    if order_correct then
        for g_idx = 1, n_gt do
            if matched_gt[g_idx] ~= g_idx then
                order_correct = false
                break
            end
        end
    end

    -- Failure analysis
    local failures = {}
    if tp < n_gt or tp < n_det then
        if n_det < n_gt then
            table.insert(failures, "merged_panels")
        elseif n_det > n_gt then
            table.insert(failures, "split_panels")
        end

        for g_idx = 1, n_gt do
            if not matched_gt[g_idx] then
                table.insert(failures, string.format("missed_gt_panel_%d", g_idx))
            end
        end
        for d_idx = 1, n_det do
            if not matched_det[d_idx] then
                table.insert(failures, string.format("ghost_det_panel_%d", d_idx))
            end
        end
    elseif not order_correct then
        table.insert(failures, "reading_order_mismatch")
    end

    return {
        ground_truth_count = n_gt,
        detected_count = n_det,
        true_positives = tp,
        false_positives = fp,
        false_negatives = fn,
        precision = precision,
        recall = recall,
        f1 = f1,
        mean_iou = m_iou,
        reading_order_correct = order_correct,
        matches = matches,
        failures = failures,
    }
end

return PanelEvaluator
