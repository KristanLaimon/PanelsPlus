local _ = require("gettext")

-- No name key: pluginloader derives it from the directory name and ignores it.
return {
    fullname = _("Meguru"),
    description = _([[Turns OPDS-PSE page streams (Kavita, Suwayomi) into
ordinary KOReader books: a small marker file stands in for the book, so it lands
in History and keeps normal reading progress, while pages are fetched one at a
time over HTTP — no CBZ/ZIP is ever downloaded.

The marker carries the identity of the book and of its series, and nothing else
is stored: no database, no page cache. What comes next in a series is read from
the server's own chapter list when you ask for it.]]),
-- Load-bearing: the updater compares releases to it, so bump before tagging.
-- A hyphen after the version marks a prerelease, which /releases/latest skips.
-- Only its digits compare, so a dev build is replaced by hand, not updated.
    version = "1.7.1",
}
