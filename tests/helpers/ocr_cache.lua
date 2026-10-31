-- Durable raw OCR results. Accuracy decisions remain in the dataset spec.
local JSON = require("tests.helpers.json")
local Cache = {}

function Cache.load(path)
    local file = io.open(path, "rb")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()
    local ok, decoded = pcall(JSON.decode, content)
    return ok and type(decoded) == "table" and decoded or {}
end

function Cache.save(path, results)
    -- Reserve a unique suffix, then write beside the destination so rename is
    -- atomic even when /tmp and the cache directory use different filesystems.
    local reservation = os.tmpname()
    local temporary = path .. "." .. assert(reservation:match("[^/]+$"))
    os.remove(reservation)
    local file = assert(io.open(temporary, "wb"), "could not write the OCR result cache")
    local ok, err = file:write(JSON.encode(results), "\n")
    local closed, close_err = file:close()
    if not ok or not closed then
        os.remove(temporary)
        error(err or close_err or "could not flush the OCR result cache")
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        error(rename_err or "could not publish the OCR result cache")
    end
end

-- Drain errors too, letting the caller close/reap the worker before failing.
-- Successful results are checkpointed even if a later job or the stream fails.
function Cache.readStream(lines, key_by_id, results, checkpoint, interval)
    interval = interval or 64
    assert(interval >= 1, "checkpoint interval must be positive")
    local by_key, seen = {}, {}
    local dirty, reason = 0, nil
    for line in lines do
        local ok, item = pcall(JSON.decode, line)
        if not ok or type(item) ~= "table" then
            reason = reason or "Go OCR helper returned invalid JSON"
        else
            local key = key_by_id[item.id]
            if not key or seen[item.id] then
                reason = reason or "Go OCR helper returned an unknown or duplicate request"
            else
                seen[item.id] = true
                if item.error ~= "" or type(item.text) ~= "string" then
                    reason = reason or ("Go OCR request failed: " .. tostring(item.error))
                else
                    local value = item.text ~= "" and item.text or false
                    by_key[key], results[key] = value, value
                    dirty = dirty + 1
                    if dirty >= interval then
                        checkpoint(results)
                        dirty = 0
                    end
                end
            end
        end
    end
    if dirty > 0 then
        checkpoint(results)
    end
    for id in pairs(key_by_id) do
        if not seen[id] then
            reason = reason or "Go OCR helper returned an incomplete result stream"
        end
    end
    return by_key, reason
end

return Cache
