
local logger = require("logger")

local Open = require("meguru/ui/open")
local Sources = require("meguru/sources")

local Hook = {}

local installed = false

-- The wrapper installed for each method, so it can be recognised later.
-- A nil entry means that method was absent and never wrapped.
local m_showDownloads
local m_parseFeed
local m_genItemTableFromURL
local m_onMenuSelect

local browser_wrapped = false
local init_wrapped = false
local repatched_logged = false
local warned_showDownloads = false

-- Per method, not per set: re-wrapping an untouched one stacks two wrappers.
-- The row above a series feed would then appear twice.
local function stillOurs(current, ours)
    return ours ~= nil and current == ours
end

-- Re-wrap only methods no longer carrying our wrapper, capturing the value now.
-- A method we still own is untouched, so calling this twice is safe.
local function installBrowserWraps(OPDSBrowser)
    -- First pass is silent; only a later pass that repairs something logs.
    local repatched = browser_wrapped
    local changed = false

    -- showDownloads first, alone: without it there is nothing to extend at all.
    if not stillOurs(OPDSBrowser.showDownloads, m_showDownloads) then
        local orig_showDownloads = OPDSBrowser.showDownloads
        if type(orig_showDownloads) ~= "function" then
            -- Warned once, not per browser: the shape is constant.
            if not warned_showDownloads then
                warned_showDownloads = true
                logger.warn("Meguru: unexpected OPDSBrowser:showDownloads, integration disabled")
            end
            return false
        end

        m_showDownloads = function(browser, item, ...)
            -- Official dialog first, then extend it, pcall-guarded.
            orig_showDownloads(browser, item, ...)
            local ok_inject, err = pcall(Open.injectBookRow, browser, item)
            if not ok_inject then
                logger.warn("Meguru: could not inject book button:", err)
            end
        end
        OPDSBrowser.showDownloads = m_showDownloads
        changed = true

        logger.dbg("Meguru: hooked OPDSBrowser:showDownloads")
    end

    -- parseFeed must be wrapped: OPDSBrowser drops each entry's id and links.
    -- A driver needs both to name the series and the item.
    if not stillOurs(OPDSBrowser.parseFeed, m_parseFeed) then
        local orig_parseFeed = OPDSBrowser.parseFeed
        if type(orig_parseFeed) == "function" then
            m_parseFeed = function(browser, item_url, ...)
                local catalog = orig_parseFeed(browser, item_url, ...)
                -- pcall but loud: a swallowed error mimics an unretained feed.
                local ok_note, err = pcall(Open.noteFeed, browser, item_url, catalog)
                if not ok_note then
                    logger.warn("Meguru: could not retain the feed:", err)
                end
                local ok_author, err_author = pcall(Open.noteCatalogAuthor, browser, catalog)
                if not ok_author then
                    logger.warn("Meguru: could not sniff the catalog author:", err_author)
                end
                return catalog
            end
            OPDSBrowser.parseFeed = m_parseFeed
            changed = true

            logger.dbg("Meguru: hooked OPDSBrowser:parseFeed (feed retention, kind sniffing)")
        else
            m_parseFeed = nil
        end
    end

    -- Caught here: with no acquisitions it reads as a catalog link.
    -- Left alone, it would open a URL it does not have.
    if not stillOurs(OPDSBrowser.genItemTableFromURL, m_genItemTableFromURL) then
        local orig_genItemTableFromURL = OPDSBrowser.genItemTableFromURL
        if type(orig_genItemTableFromURL) == "function" then
            m_genItemTableFromURL = function(browser, item_url, ...)
                local item_table = orig_genItemTableFromURL(browser, item_url, ...)
                -- Wrap here, not switchItemTable: only this call gets the URL.
                -- The URL tells a series feed from a search or a catalog edit.
                -- A pagination append arrives on the same rel=next href.
                -- It folds our row into the on-screen list.
                -- The retained page's own `next` href identifies and skips it.
                local retained = browser.item_table
                local hrefs = type(retained) == "table" and retained.hrefs
                local is_append = type(hrefs) == "table" and hrefs.next == item_url
                if not is_append then
                    local ok, row = pcall(Open.seriesRow, browser, item_url)
                    if ok and row and type(item_table) == "table" then
                        table.insert(item_table, 1, row)
                    end
                end
                return item_table
            end
            OPDSBrowser.genItemTableFromURL = m_genItemTableFromURL
            changed = true
        else
            m_genItemTableFromURL = nil
        end
    end

    if not stillOurs(OPDSBrowser.onMenuSelect, m_onMenuSelect) then
        local orig_onMenuSelect = OPDSBrowser.onMenuSelect
        if type(orig_onMenuSelect) == "function" then
            m_onMenuSelect = function(browser, item)
                if type(item) == "table" and item.meguru then
                    -- pcall so a failure is loud, not a vanished row.
                    local ok, err = pcall(Open.openFirstUnread, browser, item.meguru)
                    if not ok then
                        logger.warn("Meguru: could not open the series:", err)
                    end
                    return true
                end
                return orig_onMenuSelect(browser, item)
            end
            OPDSBrowser.onMenuSelect = m_onMenuSelect
            changed = true
        else
            m_onMenuSelect = nil
        end
    end

    browser_wrapped = true

    if changed and repatched and not repatched_logged then
        -- Once per process; does not name the plugin that replaced us.
        repatched_logged = true
        logger.info("Meguru: OPDSBrowser re-patched since load; OPDS hooks re-installed")
    end

    return changed
end

-- Install the wraps; safe to call more than once (see `installed`).
function Hook.install()
    if installed then
        return true
    end
    installed = true

    local ok, OPDSBrowser = pcall(require, "opdsbrowser")
    if not ok or type(OPDSBrowser) ~= "table" then
        logger.info("Meguru: built-in OPDS plugin not available, integration disabled")
        return false
    end

    -- Re-install on construction: the last moment the class is settled.
    -- It runs on `init`, not an event, since OPDS gets no broadcast.
    if not init_wrapped then
        init_wrapped = true
        local orig_init = OPDSBrowser.init
        if type(orig_init) == "function" then
            OPDSBrowser.init = function(browser, ...)
                installBrowserWraps(OPDSBrowser)
                local result = orig_init(browser, ...)
                -- The browser's list is ahead of settings/opds.lua until exit.
                Sources.rememberServers(browser.servers)
                return result
            end
        end
    end

    installBrowserWraps(OPDSBrowser)

    -- showReader opens every document, a marker from the file manager included.
    -- That open has no other moment to ask where to start.
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_ui and type(ReaderUI) == "table"
        and type(ReaderUI.showReader) == "function" then
        local orig_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(...)
            local n = select("#", ...)
            local args = { n = n, ... }
            -- Called both ways: the file is whichever first arg is a string.
            local file = type(args[1]) == "string" and args[1] or args[2]

            local opened = false
            local function open_instead(other)
                if opened then
                    return
                end
                opened = true
                local forwarded = { }
                for i = 1, n do
                    forwarded[i] = args[i]
                end
                if type(forwarded[1]) == "string" then
                    forwarded[1] = other or forwarded[1]
                else
                    forwarded[2] = other or forwarded[2]
                end
                return orig_showReader(unpack(forwarded, 1, n))
            end

            -- Clear the one-shot first, whatever this open turns out to be.
            local decided = Open.takeHandoff()

            if type(file) ~= "string" or file:sub(-7) ~= ".meguru" then
                return open_instead()
            end

            -- Just answered by the dialog; asking again is a second dialog.
            if decided == file then
                return open_instead()
            end

            local ok_offer, err = pcall(Open.offerResumeForFile, file,
                -- Host-shaped shim so the offer hands a file to our opener.
                { ui = { openFile = function(_, other) return open_instead(other) end } },
                open_instead)
            if not ok_offer then
                logger.warn("Meguru: resume offer failed, opening normally:", err)
                open_instead()
            end
        end
        logger.dbg("Meguru: hooked ReaderUI:showReader (resume on file open)")
    else
        logger.warn("Meguru: unexpected ReaderUI:showReader, resume-on-open disabled")
    end

    return true
end

return Hook
