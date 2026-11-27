local DocumentRegistry = require("document/documentregistry")
local Settings = require("meguru/settings")
local logger = require("logger")

local Association = {}

-- The provider key main.lua registers; an entry naming no provider is ignored.
local PROVIDER = "meguru"

local EXTENSION = "cbz"

-- setProvider takes a file, not an extension: a bare name stands for .cbz.
local NAME = "book." .. EXTENSION

-- setProvider mutates without saving, so a fresh choice is flushed here.
local function save()
    local g = rawget(_G, "G_reader_settings")
    if g then
        g:flush()
    end
end

-- Asked of the registry: a key with no registered provider reads as nil here.
function Association.holds()
    return DocumentRegistry:getAssociatedProviderKey(NAME, true) == PROVIDER
end

function Association.taken()
    return DocumentRegistry:getAssociatedProviderKey(NAME, true) ~= nil
end

-- Exported so ui/open.lua need not respell the provider key.
function Association.provider()
    if type(DocumentRegistry.getProviderFromKey) ~= "function" then
        return nil
    end
    return DocumentRegistry:getProviderFromKey(PROVIDER)
end

function Association.claim()
    -- setProvider(file, nil, true) resets, so a missing provider is refused.
    local provider = Association.provider()
    if not provider then
        logger.warn("Meguru: the provider is not registered, so ." .. EXTENSION
            .. " cannot be claimed")
        return false
    end
    DocumentRegistry:setProvider(NAME, provider, true)
    save()
    logger.info("Meguru: is now the default reader for ." .. EXTENSION)
    return true
end

function Association.release()
    DocumentRegistry:setProvider(NAME, nil, true)
    save()
    logger.info("Meguru: released ." .. EXTENSION .. " to KOReader's own reader")
end

-- Written even if someone else already claimed: this is a one-time offer.
function Association.claimOnce()
    if Settings.get("cbz_default_claimed") then
        return
    end
    Settings.set("cbz_default_claimed", true)
    if Association.taken() then
        return
    end
    Association.claim()
end

return Association
