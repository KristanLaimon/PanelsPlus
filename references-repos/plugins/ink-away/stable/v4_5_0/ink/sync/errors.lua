--[[
The errors of the cloud sync, each with a code the person can read out, what
happened, and what to do about it (see ink/sync/). Codes are IA-S plus three
digits: 1xx the connection, 2xx the account, 3xx the cloud's answer, 4xx this
reader's files, 5xx the sync itself. `retry` says whether trying again soon can
help, and `fatal` whether a run stops (otherwise only that one file is skipped).

An error is a table { code, detail, retry_after }; `detail` is for the log, the
texts shown come from the catalogue (and are translated there).
]]

local _ = require("ink/l10n")

local Errors = {}

-- code -> { title, what, fix, retry, fatal }
local C = {}
local function def(code, title, what, fix, retry, fatal)
    C[code] = { title = title, what = what, fix = fix, retry = retry, fatal = fatal }
end

def("IA-S101", _("No connection"), _("The reader could not reach the cloud."),
    _("Turn on Wi-Fi and try again. Your notebooks are safe and nothing was lost."), true, true)
def("IA-S102", _("The connection timed out"), _("The cloud did not answer in time."),
    _("Move closer to the router and try again. Syncing carries on where it stopped."), true, true)
def("IA-S103", _("Secure connection failed"), _("The reader could not make a secure connection to the cloud. Its clock may be wrong."),
    _("Check the date and time on this reader, then try again."), false, true)
def("IA-S104", _("Wi-Fi is off"), _("Syncing waits for Wi-Fi, and Ink Away is set not to turn it on by itself."),
    _("Connect to Wi-Fi, or allow Ink Away to turn it on in the sync settings."), true, true)
def("IA-S201", _("Not signed in"), _("This reader is not connected to a cloud account."),
    _("Open Cloud sync and connect your account."), false, true)
def("IA-S202", _("Sign in again"), _("The cloud no longer accepts this reader's sign-in. It was removed or has expired."),
    _("Open Cloud sync and connect again. Your notebooks stay as they are."), false, true)
def("IA-S203", _("The code was not accepted"), _("The code you typed is wrong or has already been used."),
    _("Start again to get a new code, and type it exactly as shown."), false, true)
def("IA-S204", _("Not allowed"), _("The cloud refused this request. Ink Away may be missing a permission."),
    _("Disconnect and connect again, and tap Allow when asked."), false, true)
def("IA-S206", _("Waiting for you"), _("The sign-in has not been allowed yet."),
    _("Enter the code on your phone and tap Allow. This screen carries on by itself."), true, false)
def("IA-S207", _("The sign-in timed out"), _("Nobody allowed the sign-in in time, or it was refused."),
    _("Start again to get a new code."), false, true)
def("IA-S301", _("The cloud is full"), _("There is no room left in the cloud account."),
    _("Free some space in your account or buy more. Nothing was lost on this reader."), false, true)
def("IA-S302", _("Too many requests"), _("The cloud asked Ink Away to slow down."),
    _("Wait a few minutes. Syncing will carry on by itself."), true, true)
def("IA-S303", _("The cloud had a problem"), _("The cloud service reported an error on its side."),
    _("Try again later. Your notebooks are safe."), true, true)
def("IA-S304", _("Unexpected answer"), _("The cloud answered in a way Ink Away does not understand."),
    _("Try again. If it keeps happening, update Ink Away."), true, false)
def("IA-S305", _("Changed meanwhile"), _("The file was changed in the cloud while it was being sent, so nothing was overwritten."),
    _("It will be checked again on the next sync."), true, false)
def("IA-S306", _("Too large"), _("This file is larger than the cloud sync can send."),
    _("Make the notebook smaller, for example by splitting it. It stays on this reader."), false, false)
def("IA-S307", _("Not found in the cloud"), _("The file is no longer in the cloud."),
    _("It will be sent again on the next sync."), true, false)
def("IA-S308", _("Not available here"), _("This cloud service does not offer that."),
    _("Everything else works as usual."), false, false)
def("IA-S401", _("Cannot read a file"), _("A file on this reader could not be read."),
    _("Check that the reader's storage is not full or damaged."), false, false)
def("IA-S402", _("Cannot write a file"), _("A file on this reader could not be written, so nothing was replaced."),
    _("Free some space on the reader and try again."), false, false)
def("IA-S403", _("Damaged download"), _("What arrived was incomplete or damaged, so it was thrown away."),
    _("It will be downloaded again on the next sync."), true, false)
def("IA-S404", _("Two names look the same"), _("Two files differ only in capital letters, which the cloud treats as one."),
    _("Rename one of them."), false, false)
def("IA-S405", _("Picture or PDF is missing"), _("A file used by a notebook is not on this reader and could not be found."),
    _("The notebook is synced anyway. The picture shows when its file arrives."), false, false)
def("IA-S501", _("Newer version needed"), _("The cloud holds notebooks saved by a newer Ink Away."),
    _("Update Ink Away on this reader, then sync again. Nothing was changed."), false, true)
def("IA-S502", _("Stopped"), _("Syncing was stopped."), _("Start it again whenever you like."), true, true)
def("IA-S503", _("Unexpected problem"), _("Something went wrong inside Ink Away. Nothing was overwritten."),
    _("Try again. If it keeps happening, report the code and the sync log."), true, false)
def("IA-S505", _("Many files seem to be missing"), _("Syncing would delete a large part of your notebooks in the cloud, so it stopped before deleting anything."),
    _("Check that the reader's storage and the library folder are in place. Nothing was deleted."), false, true)
def("IA-S506", _("The library folder changed"), _("The library folder is not the one that was last synced."),
    _("Choose the old folder again, or start syncing this folder as a new library."), false, true)
def("IA-S504", _("Busy"), _("A notebook was being written, so it is skipped for now."),
    _("It will be synced next time."), true, false)

Errors.CATALOGUE = C

-- An error with `code` and a `detail` for the log.
function Errors.make(code, detail, retry_after)
    return { code = C[code] and code or "IA-S503", detail = detail and tostring(detail) or nil, retry_after = retry_after }
end

-- The catalogue entry for an error (or a code).
function Errors.info(err)
    local code = type(err) == "table" and err.code or err
    return C[code] or C["IA-S503"]
end

function Errors.isFatal(err) return Errors.info(err).fatal == true end
function Errors.isRetryable(err) return Errors.info(err).retry == true end

-- "IA-S101  No connection" for a list or a log.
function Errors.line(err)
    local code = type(err) == "table" and err.code or err
    return string.format("%s  %s", code or "IA-S503", Errors.info(err).title)
end

return Errors
