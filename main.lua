local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local http = require("socket.http")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")
local tls = require("telegramdownloader_tls")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local ffiutil = require("ffi/util")
local T = ffiutil.template

local API_HOST = "api.telegram.org"
-- Bot API refuses getFile for anything larger than this.
local MAX_FILE_SIZE = 20 * 1024 * 1024
local MAX_API_RESPONSE_SIZE = 4 * 1024 * 1024
local MAX_FILENAME_BYTES = 200
-- Attempts at a failing update before it is skipped.
local MAX_ATTEMPTS = 3
-- Seconds after which a request still waiting for the network is considered
-- abandoned, so that another one can start (see downloadFiles).
local WAIT_NETWORK_TIMEOUT = 120

-- Never write files that KOReader (or the OS) might execute or load as code,
-- even if a document provider claims the extension.
local BLOCKED_EXTENSIONS = {
    lua = true, so = true, sh = true, py = true, js = true,
    apk = true, bin = true, elf = true, exe = true, ko = true,
}

local TelegramDownloader = WidgetContainer:extend{
    name = "TelegramDownloader",
    settings_file = DataStorage:getSettingsDir() .. "/telegramdownloader.lua",
    -- Offset and download in progress (see loadState).
    state_file = DataStorage:getSettingsDir() .. "/telegramdownloader_state.json",
    is_doc_only = false,
}

--- Helpers ---------------------------------------------------------------

local function isValidToken(token)
    return type(token) == "string" and token:match("^%d+:[%w_%-]+$") ~= nil
end

local function isValidUserId(user_id)
    return type(user_id) == "string" and user_id:match("^%d+$") ~= nil and tonumber(user_id) > 0
end

local function findCaFile(override)
    if override and override ~= "" then
        return lfs.attributes(override, "mode") == "file" and override or nil
    end
    for __, path in ipairs(tls.CA_FILE_CANDIDATES) do
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
end

-- Wraps an ltn12 sink: aborts the transfer once more than max_bytes have been
-- received or total_timeout seconds have passed since the first chunk.
local function guardedSink(sink, max_bytes, total_timeout)
    local received, started = 0, nil
    return function(chunk, err)
        if chunk then
            started = started or os.time()
            received = received + #chunk
            if received > max_bytes then
                return nil, "response too large"
            end
            if total_timeout and total_timeout > 0 and os.time() - started > total_timeout then
                return nil, socketutil.SINK_TIMEOUT_CODE
            end
        end
        return sink(chunk, err)
    end
end

-- Unlike ltn12.sink.file, propagates write errors and leaves closing the
-- handle to the caller, so that close/flush errors can be checked too.
-- LuaSocket only passes the error message on, so a write error and its errno
-- are also recorded in `failure` (if given) as `err` and `errno`.
local function fileSink(handle, failure)
    return function(chunk)
        if chunk == nil or chunk == "" then
            return 1
        end
        local ok, err, errno = handle:write(chunk)
        if not ok then
            if failure then
                failure.err, failure.errno = err, errno
            end
            return nil, err
        end
        return 1
    end
end

local function tableSink(t)
    return function(chunk)
        if chunk then
            table.insert(t, chunk)
        end
        return 1
    end
end

-- Flushes, optionally syncs to storage, and closes a file handle, reporting
-- the first flush or close error (nil, message, errno). Does nothing if the
-- handle is already closed.
-- fsyncOpenedFile() is only used if this KOReader version provides it, and
-- like KOReader's util.writeToFile(), a sync failure is not an error (some
-- storage, e.g. FUSE on Android, may not support it): it is only logged.
-- It returns only false and a strerror() message, no errno, so "not
-- supported here" (e.g. EINVAL) cannot be reliably told apart from a real
-- failure, and treating it as fatal would make such storage unusable.
-- Durability: every write is atomic (temporary file, then rename), but it
-- survives a sudden power loss only as far as syncing works. The order is:
-- the document is synced, then renamed into place, then the state is written
-- (see checkForNewFiles). So after a power loss the worst case is either a
-- missing newest file (downloaded again) or a saved file whose update was
-- not acknowledged, which the published-file detection in
-- cleanupInterruptedDownload() acknowledges without downloading it again.
local function closeChecked(handle, sync)
    if io.type(handle) ~= "file" then
        return true
    end
    local flushed, flush_err, flush_errno = handle:flush()
    if flushed and sync and type(ffiutil.fsyncOpenedFile) == "function" then
        local ok, synced, sync_err = pcall(ffiutil.fsyncOpenedFile, handle)
        if not ok or not synced then
            logger.warn("TelegramDownloader: cannot sync file:", ok and sync_err or synced)
        end
    end
    local closed, close_err, close_errno = handle:close()
    if not flushed then
        return nil, flush_err, flush_errno
    end
    if not closed then
        return nil, close_err, close_errno
    end
    return true
end

-- Makes a rename in `directory` durable, if this KOReader version can.
-- The file is already in place, so a failure is only logged (see
-- closeChecked about what that means after a power loss).
local function syncDirectory(directory)
    if type(ffiutil.fsyncDirectory) ~= "function" then
        return
    end
    local ok, synced, err = pcall(ffiutil.fsyncDirectory, directory)
    if not ok or not synced then
        logger.warn("TelegramDownloader: cannot sync folder:", ok and err or synced)
    end
end

-- Reduce a sender-controlled name to a single safe path component.
local function sanitizeFileName(name)
    if type(name) ~= "string" then
        return nil
    end
    name = util.fixUtf8(name, "_")
    name = name:gsub("[%c/\\:*?\"<>|]", "_")  -- separators, control chars, VFAT-reserved chars
    name = name:gsub("^[%s%.]+", "")          -- no hidden files, no "." / ".."
    name = name:gsub("[%s%.]+$", "")          -- VFAT strips these anyway
    if #name > MAX_FILENAME_BYTES then
        local base, ext = util.splitFileNameSuffix(name)
        if ext ~= "" and #ext <= 10 then
            name = util.fixUtf8(base:sub(1, MAX_FILENAME_BYTES - #ext - 1), "") .. "." .. ext
        else
            name = util.fixUtf8(name:sub(1, MAX_FILENAME_BYTES), "")
        end
    end
    if name == "" then
        return nil
    end
    return name
end

local function isAllowedFileName(name)
    local ext = util.getFileNameSuffix(name):lower()
    if ext == "" or BLOCKED_EXTENSIONS[ext] then
        return false
    end
    return DocumentRegistry:hasProvider(name)
end

-- Removes `path` only if it is a regular file (not a directory or symlink),
-- optionally only if it is empty.
local function removeRegularFile(path, only_if_empty)
    if lfs.symlinkattributes(path, "mode") ~= "file" then
        return
    end
    if only_if_empty and lfs.symlinkattributes(path, "size") ~= 0 then
        return
    end
    os.remove(path)
end

-- Linux errno values.
local EPERM, ENOENT, EIO, ENXIO, EACCES, EEXIST, ENODEV, ENOTDIR, EINVAL, ENFILE, EMFILE, ENOSPC, EROFS =
    1, 2, 5, 6, 13, 17, 19, 20, 22, 23, 24, 28, 30
local ESTALE, EDQUOT = 116, 122

-- A folder that is gone or unreachable (e.g. a removed SD card, an unmounted
-- or stale network share). Only for writes: loadState() treats ENOENT when
-- reading the state file as "missing".
local function isUnavailableErrno(errno)
    return errno == ENOENT or errno == ENXIO or errno == ENODEV or errno == ENOTDIR or errno == ESTALE
end

-- Creates `path` only if nothing (not even a dangling symlink) exists there.
-- The "x" mode maps to O_CREAT | O_EXCL on glibc and bionic, which makes the
-- check atomic and refuses to follow a symlink. The lstat() check before it
-- covers a libc that would silently ignore "x". A libc that rejects "x"
-- (EINVAL) gets no non-atomic fallback: the error is returned as is.
-- Returns the open handle, or nil, an error message and errno.
local function createExclusive(path)
    if lfs.symlinkattributes(path, "mode") then
        return nil, path .. ": File exists", EEXIST
    end
    return io.open(path, "wbx")
end

-- 16 random hex digits, for temporary file names that cannot be predicted
-- (see cleanupInterruptedDownload). There is no math.random fallback: its
-- output is predictable, so without /dev/urandom nothing is created.
-- Returns the token, or nil and an error message.
local function randomToken()
    local urandom = io.open("/dev/urandom", "rb")
    if not urandom then
        return nil, "cannot open /dev/urandom"
    end
    local ok, bytes = pcall(urandom.read, urandom, 8)
    urandom:close()
    if not ok or type(bytes) ~= "string" or #bytes ~= 8 then
        return nil, "cannot read /dev/urandom"
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Returned by reserveDestination() in place of errno when no secure random
-- token could be generated.
local NO_RANDOM = "no random source"

-- Matches the temporary file names generated for `name` by reserveDestination().
local function isTempNameFor(temp_name, name)
    return type(temp_name) == "string"
        and temp_name:sub(1, #name + 1) == name .. "."
        and temp_name:sub(#name + 2):match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%.part$") ~= nil
end

-- Atomically reserves a destination that never overwrites anything:
-- "book.epub" -> "book (1).epub" -> "book (2).epub" ...
-- The destination is created as an empty placeholder, and the download goes
-- to an exclusively created "<destination>.<random>.part" file that is later
-- renamed over the placeholder (rename replaces a symlink rather than
-- following it).
-- This assumes no other process tampers with the placeholder meanwhile:
-- rename() itself always replaces its destination, and the no-replace
-- alternatives (renameat2, link + unlink) are unavailable on VFAT/exFAT.
-- Returns the destination path, the open temporary file handle and its path,
-- or nil, an error message and errno (or NO_RANDOM, in which case nothing
-- was created).
-- MAX_FILENAME_BYTES leaves room for " (999)" and ".<16 hex digits>.part"
-- within the usual 255-byte file name limit.
local function reserveDestination(directory, name)
    local base, ext = util.splitFileNameSuffix(name)
    for i = 0, 999 do
        local path = i == 0 and (directory .. "/" .. name)
            or string.format("%s/%s (%d).%s", directory, base, i, ext)
        -- Before creating anything, so that a failure leaves nothing behind.
        local token, token_err = randomToken()
        if not token then
            return nil, token_err, NO_RANDOM
        end
        local placeholder, err, errno = createExclusive(path)
        if placeholder then
            local no_error, closed, close_err, close_errno = pcall(placeholder.close, placeholder)
            if not no_error or not closed then
                os.remove(path)
                if not no_error then
                    return nil, closed
                end
                return nil, close_err, close_errno
            end
            local temp_path = path .. "." .. token .. ".part"
            local temp_handle
            temp_handle, err, errno = createExclusive(temp_path)
            if temp_handle then
                return path, temp_handle, temp_path
            end
            os.remove(path)
        end
        if errno ~= EEXIST then
            return nil, err, errno
        end
    end
    return nil, "too many files with the same name"
end

--- Plugin ----------------------------------------------------------------

function TelegramDownloader:init()
    -- "idle", "waiting_network" or "downloading" (see downloadFiles).
    self.run_state = "idle"
    self:onDispatcherRegisterActions()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

-- Expose "Download files" as a Dispatcher action so it can be bound to a
-- gesture or used by alternative UIs (e.g. quick-access panels) without the
-- Tools menu being visible.
function TelegramDownloader:onDispatcherRegisterActions()
    Dispatcher:registerAction("telegram_download_files", {
        category = "none",
        event = "TelegramDownloadFiles",
        title = _("Telegram: download files"),
        general = true,
    })
end

-- Shared entry point used by both the menu item and the Dispatcher action.
-- self.run_state makes sure runs never overlap:
--   "idle":            nothing going on.
--   "waiting_network": a request waits for runWhenConnected() to call back
--                      (since self.waiting_since).
--   "downloading":     a run is in progress.
-- runWhenConnected() may never call back: if Wi-Fi is off, it goes through
-- beforeWifiAction(), and e.g. promptWifiOn() drops the callback when the
-- prompt is cancelled, as does a connection attempt that times out (see
-- KOReader's ui/network/manager.lua). So a wait expires after
-- WAIT_NETWORK_TIMEOUT seconds, and the next request starts again: the state
-- can never get stuck. Only the latest request's callback runs (an expired
-- one that arrives late is ignored), and only if no run is in progress.
function TelegramDownloader:downloadFiles()
    if self.run_state == "downloading" then
        return
    end
    if self.run_state == "waiting_network" then
        local waited = os.time() - (self.waiting_since or 0)
        -- A clock set backwards (e.g. by a network time sync) ends the wait too.
        if waited >= 0 and waited < WAIT_NETWORK_TIMEOUT then
            return
        end
    end
    self.run_state, self.waiting_since, self.run_request = "idle", nil, nil
    self:loadSettings()
    if not isValidToken(self.token) or not isValidUserId(self.user_id) then
        self:showMessage(_("Please set a valid bot token and user ID in \"Telegram Bot configuration\" first."))
        return
    end
    if lfs.attributes(self.directory, "mode") ~= "directory" then
        self:showMessage(T(_("Download folder does not exist:\n%1"), self.directory))
        return
    end
    local request = {}
    self.run_state, self.waiting_since, self.run_request = "waiting_network", os.time(), request
    NetworkMgr:runWhenConnected(function()
        if self.run_state == "downloading" or self.run_request ~= request then
            return
        end
        self.run_state, self.waiting_since, self.run_request = "downloading", nil, nil
        local ok, err = pcall(self.checkForNewFiles, self)
        self.run_state = "idle"
        if not ok then
            logger.err("TelegramDownloader: unexpected error:", self:redact(err))
            self:showMessage(_("Unexpected error while downloading files. See crash.log for details."))
        end
    end)
end

function TelegramDownloader:onTelegramDownloadFiles()
    self:downloadFiles()
    return true
end

function TelegramDownloader:loadSettings()
    self.settings = LuaSettings:open(self.settings_file)
    self.directory = self.settings:readSetting("directory")
        or G_reader_settings:readSetting("home_dir")
        or filemanagerutil.getDefaultDir()
    self.token = tostring(self.settings:readSetting("token") or "")
    self.user_id = tostring(self.settings:readSetting("user_id") or "")
    -- Advanced: path to a PEM CA bundle, only needed if none is found automatically.
    self.ca_file = self.settings:readSetting("ca_file")
end

function TelegramDownloader:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

-- Removes the bot token from text that may end up in logs or on screen.
function TelegramDownloader:redact(text)
    text = tostring(text)
    local token = self.token
    if type(token) ~= "string" or token == "" then
        return text
    end
    local parts, pos = {}, 1
    while true do
        local first, last = text:find(token, pos, true)
        if not first then
            break
        end
        table.insert(parts, text:sub(pos, first - 1))
        table.insert(parts, "[REDACTED]")
        pos = last + 1
    end
    table.insert(parts, text:sub(pos))
    return table.concat(parts)
end

-- Performs a verified HTTPS GET to the Telegram API host, streaming the body
-- into `sink`. Returns the HTTP status code, or nil, an error message and
-- whether the failure was local (a write error or an oversized response)
-- rather than a network problem.
-- The URL contains the bot token, so it is never logged or shown, and errors
-- are redacted in case a library includes it.
-- socket.http (not LuaSec's ssl.https) is used on purpose: it accepts https
-- URLs and uses the given `create` function instead of its own, whereas
-- ssl.https.request() refuses a custom `create` and its default connection
-- does not verify the certificate (verify = "none") or the hostname.
function TelegramDownloader:httpsGet(path, sink, max_bytes, block_timeout, total_timeout)
    local cafile = findCaFile(self.ca_file)
    if not cafile then
        return nil, _("No CA certificate bundle found, cannot verify the connection to Telegram.")
    end
    local guarded = guardedSink(sink, max_bytes, total_timeout)
    local sink_err
    local function recordingSink(chunk, err)
        local res, chunk_err = guarded(chunk, err)
        if not res then
            sink_err = chunk_err
        end
        return res, chunk_err
    end
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, res, code = pcall(http.request, {
        url = "https://" .. API_HOST .. path,
        method = "GET",
        sink = recordingSink,
        redirect = false,
        create = tls.verifiedTlsCreate(cafile),
        headers = { ["user-agent"] = socketutil.USER_AGENT },
    })
    socketutil:reset_timeout()
    if not ok or not res then
        local err = self:redact(ok and code or res)
        logger.warn("TelegramDownloader: request failed:", err)
        -- A Lua error (as opposed to a returned one) is a bug, not a network problem.
        local local_failure = not ok or (sink_err ~= nil and sink_err ~= socketutil.SINK_TIMEOUT_CODE)
        if ok and tls.errorCategory(err) then
            -- Rejected certificate (chain or hostname): most likely a captive
            -- portal or an intercepting proxy, so say so explicitly.
            return nil, T(_("Could not verify Telegram's certificate (%1). The connection may be intercepted."), err),
                local_failure
        end
        return nil, socketutil.describe_error(err, block_timeout, total_timeout) or err, local_failure
    end
    return code
end

-- Failure kinds, used to decide whether an update is retried:
-- RETRY_WAIT:  not the document's fault: no usable connection (including TLS
--              failures), Telegram being overloaded or rate limiting (HTTP 429
--              and 5xx), a device that cannot create files safely, or a
--              storage problem (full, read-only, no permission, I/O error,
--              folder not available; see storageErrorMessage). The run stops
--              and the update is retried without limit, as nothing can be
--              done about it from here.
-- RETRY_ERROR: anything else that may be transient (Lua errors, other write
--              errors, oversized or invalid responses, size mismatch); retried
--              MAX_ATTEMPTS times.
-- nil:         permanent; the update is acknowledged.
local RETRY_WAIT, RETRY_ERROR = "wait", "error"

-- Returns a message for a local storage problem that is not the document's
-- fault, or nil if `errno` is not one of them. Only errno is compared: the
-- message may be localized.
local function storageErrorMessage(errno, err)
    if errno == ENOSPC or errno == EDQUOT then
        return _("Not enough storage space")
    elseif errno == EROFS then
        return _("The download folder is read-only")
    elseif errno == EACCES or errno == EPERM then
        return _("No permission to write to the download folder")
    elseif errno == EIO or errno == EMFILE or errno == ENFILE then
        return T(_("Cannot write file: %1"), tostring(err))
    elseif isUnavailableErrno(errno) then
        return _("The download folder is not available")
    end
end

-- Describes a failure to write the download folder. Returns the message and
-- the failure kind: RETRY_WAIT for a storage problem, RETRY_ERROR otherwise.
local function writeFailure(err, errno)
    local message = storageErrorMessage(errno, err)
    if message then
        logger.warn("TelegramDownloader: storage error:", err)
        return message, RETRY_WAIT
    end
    return T(_("Cannot write file: %1"), tostring(err)), RETRY_ERROR
end

--- Download state ----------------------------------------------------------

-- The offset, the download in progress and the failed attempt counter are
-- kept in their own JSON file rather than in the settings file: KOReader's
-- LuaSettings:flush() rewrites that file in place and ignores write errors
-- (util.writeToFile()), so a failed or interrupted write could go unnoticed,
-- or even empty the settings file, bot token included. The state file is
-- written atomically and every failure is reported. Being JSON, it cannot
-- execute code when read, unlike the settings file.
local STATE_KEYS = { "offset", "pending_download", "failed_update" }

-- An integer that is a valid update ID (or offset) and at least `min`.
-- KOReader's JSON encoder (luajson) writes numbers with about 14 significant
-- digits, so only integers below 1e14 survive a save and load exactly; real
-- update IDs are far smaller.
local function isUpdateId(value, min)
    return type(value) == "number" and value >= min and value < 1e14 and value == math.floor(value)
end

-- An update ID that may be saved (in the offset, a pending download record
-- or a failed attempt record): at least `min`, and acknowledging it (offset
-- id + 1) must give a valid offset too, or the next run would find the
-- state file damaged.
local function isStorableUpdateId(value, min)
    return isUpdateId(value, min) and isUpdateId(value + 1, 1)
end

-- Logs and describes an update ID that cannot be saved (see isStorableUpdateId).
local function unexpectedUpdateIdMessage(value)
    -- Shortened, in case it is a huge string.
    local text = tostring(value):sub(1, 40)
    logger.err("TelegramDownloader: unexpected update ID:", type(value), text)
    return T(_("Telegram sent an unexpected update number (%1); nothing more was downloaded."), text)
end

-- Returns the state if the offset is valid, or nil: a wrong offset could
-- skip files or download them again. Not every damaged file makes
-- json.decode() fail (luajson returns nil for an empty file, and a function
-- for null), so the types are what this checks. Other fields of the wrong type are
-- dropped: a pending download record that is not a table could not be used
-- anyway (the fields of a table are validated where it is used, see
-- cleanupInterruptedDownload), and dropping a failed attempt record at worst
-- gives an update its attempts back.
-- The second result is true if a pending download record was dropped (the
-- caller warns about it, see addDamagedRecordWarning).
local function validState(state)
    if type(state) ~= "table" or not isUpdateId(state.offset, 0) then
        return nil
    end
    local pending, pending_dropped = state.pending_download, false
    if pending ~= nil and type(pending) ~= "table" then
        logger.warn("TelegramDownloader: ignoring invalid pending download record")
        pending, pending_dropped = nil, true
    end
    local failed = state.failed_update
    if type(failed) ~= "table" or not isUpdateId(failed.id, 0) or not isUpdateId(failed.attempts, 1) then
        failed = nil
    end
    return { offset = state.offset, pending_download = pending, failed_update = failed }, pending_dropped
end

-- Writes `data` to `path` atomically: to an exclusively created temporary
-- file next to it (synced if possible), then renamed over it, so that `path`
-- always holds either the old or the new content. Returns true, or nil, an
-- error message and errno (or NO_RANDOM); the temporary file is then removed.
local function writeFileAtomic(path, data)
    local token, token_err = randomToken()
    if not token then
        return nil, token_err, NO_RANDOM
    end
    local temp_path = path .. "." .. token .. ".tmp"
    local handle, err, errno = createExclusive(temp_path)
    if not handle then
        return nil, err, errno
    end
    local ok, written, write_err, write_errno = pcall(handle.write, handle, data)
    local exception = not ok and written or nil
    local closed, close_err, close_errno
    if ok and written then
        ok, closed, close_err, close_errno = pcall(closeChecked, handle, true)
        exception = not ok and closed or nil
    end
    if exception or not written or not closed then
        -- Not closeChecked(): if flushing is what failed, it must not stop the close.
        if io.type(handle) == "file" then
            pcall(handle.close, handle)
        end
        removeRegularFile(temp_path)
        if exception then
            return nil, tostring(exception)
        elseif not written then
            return nil, write_err, write_errno
        end
        return nil, close_err, close_errno
    end
    local renamed, rename_err, rename_errno = os.rename(temp_path, path)
    if not renamed then
        removeRegularFile(temp_path)
        return nil, rename_err, rename_errno
    end
    syncDirectory(path:match("^(.*)/[^/]*$") or ".")
    return true
end

-- Removes the temporary files that a state write interrupted by a crash or
-- power loss left next to `state_file` (regular files with exactly the names
-- writeFileAtomic() uses; nothing else). No state write can be in progress
-- meanwhile, as runs never overlap.
local function removeStateTemps(state_file)
    local directory, base = state_file:match("^(.*)/([^/]+)$")
    if not directory then
        return
    end
    local pattern = "^" .. base:gsub("%p", "%%%0") .. "%." .. string.rep("%x", 16) .. "%.tmp$"
    local leftovers = {}
    local ok, err = pcall(function()
        for entry in lfs.dir(directory) do
            if entry:match(pattern) then
                table.insert(leftovers, entry)
            end
        end
    end)
    if not ok then
        logger.warn("TelegramDownloader: cannot list the settings folder:", err)
    end
    for __, entry in ipairs(leftovers) do
        logger.info("TelegramDownloader: removing interrupted state write", entry)
        removeRegularFile(directory .. "/" .. entry)
    end
end

-- Saves `state`. Returns as writeFileAtomic().
local function writeState(path, state)
    local ok, data = pcall(json.encode, {
        offset = state.offset,
        pending_download = state.pending_download,
        failed_update = state.failed_update,
    })
    if not ok or type(data) ~= "string" then
        return nil, "cannot encode the download state: " .. tostring(data)
    end
    return writeFileAtomic(path, data)
end

-- Describes a failure to save the download state, which always stops the
-- run without counting anything (like RETRY_WAIT).
local function stateWriteFailure(err, errno)
    logger.err("TelegramDownloader: cannot save download state:", err)
    if errno == ENOSPC or errno == EDQUOT then
        return T(_("Cannot save download progress: %1"), _("Not enough storage space"))
    elseif errno == EROFS then
        return _("Cannot save download progress: the settings folder is read-only")
    elseif errno == EACCES or errno == EPERM then
        return _("Cannot save download progress: no permission to write to the settings folder")
    elseif errno == EIO or errno == EMFILE or errno == ENFILE then
        return T(_("Cannot save download progress: %1"), tostring(err))
    elseif isUnavailableErrno(errno) then
        return _("Cannot save download progress: the settings folder is not available")
    end
    return _("Cannot save download progress")
end

local function isRemoteTransient(code)
    return code == 429 or (code >= 500 and code <= 599)
end

-- Describes a 429 response, using the delay Telegram asks for if there is one.
-- `response` is the decoded JSON body, if any.
local function rateLimitMessage(response)
    local parameters = type(response) == "table" and response.parameters
    local retry_after = type(parameters) == "table" and tonumber(parameters.retry_after)
    if retry_after and retry_after >= 0 and retry_after < 1e6 then
        return T(_("Telegram asks to wait %1 seconds"), math.ceil(retry_after))
    end
    return _("Too many requests to Telegram, please try again later")
end

-- Calls a Bot API method. Returns the decoded `result` field, or nil, an
-- error message and the failure kind.
function TelegramDownloader:apiCall(method, params)
    local query = {}
    for key, value in pairs(params or {}) do
        table.insert(query, url.escape(key) .. "=" .. url.escape(tostring(value)))
    end
    table.sort(query)
    local path = "/bot" .. self.token .. "/" .. method
    if #query > 0 then
        path = path .. "?" .. table.concat(query, "&")
    end

    local chunks = {}
    local code, err, local_failure = self:httpsGet(path, tableSink(chunks), MAX_API_RESPONSE_SIZE,
        socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if not code then
        return nil, err, local_failure and RETRY_ERROR or RETRY_WAIT
    end

    -- Telegram returns a JSON error description with non-200 codes too.
    local ok, response = pcall(json.decode, table.concat(chunks))
    if not ok or type(response) ~= "table" then
        response = nil
    end
    if isRemoteTransient(code) then
        -- Telegram's side, whatever the body says (a proxy may send HTML).
        if code == 429 then
            return nil, rateLimitMessage(response), RETRY_WAIT
        end
        return nil, response and T(_("Telegram API error: %1"), self:redact(response.description or code))
            or T(_("Invalid response from Telegram API (HTTP %1)"), code), RETRY_WAIT
    end
    if not response then
        return nil, T(_("Invalid response from Telegram API (HTTP %1)"), code), RETRY_ERROR
    end
    if response.ok ~= true then
        return nil, T(_("Telegram API error: %1"), self:redact(response.description or code)), nil
    end
    return response.result
end

-- Reads the download state into self.state. A missing file means the
-- defaults, taken once from the settings file where older versions kept them
-- (see migrateState). An unreadable or damaged file is left in place and
-- stops the run: silently starting again from offset 0 could download
-- everything that Telegram still has again, as duplicates.
-- Returns true, or nil and a message for the user.
function TelegramDownloader:loadState()
    removeStateTemps(self.state_file)
    local file, err, errno = io.open(self.state_file, "rb")
    if not file and errno == ENOENT then
        return self:migrateState()
    end
    local state, pending_dropped
    if file then
        local ok, data = pcall(file.read, file, "*a")
        file:close()
        if ok and type(data) == "string" then
            local decoded
            ok, decoded = pcall(json.decode, data)
            if ok then
                state, pending_dropped = validState(decoded)
            end
        end
    end
    if not state then
        logger.err("TelegramDownloader: cannot read download state:", err or (self.state_file .. ": damaged"))
        return nil, T(_("Cannot read the download progress file, so nothing was downloaded:\n%1\nDeleting it starts over, but files may then be downloaded again."),
            self.state_file)
    end
    if pending_dropped then
        self:addDamagedRecordWarning()
    end
    self.state = state
    return true
end

-- Creates the state file from the values older versions kept in the
-- settings file (or the defaults).
-- Those values are left in the settings file on purpose: removing them would
-- mean rewriting it with LuaSettings:flush(), which ignores write errors and
-- could lose the bot token (see STATE_KEYS). Leaving them is safe:
-- - they are only read when the state file does not exist;
-- - a stale offset then only makes Telegram return the updates it still
--   holds;
-- - a stale pending download record goes through the same validated cleanup
--   as any other (cleanupInterruptedDownload).
function TelegramDownloader:migrateState()
    local offset = tonumber(self.settings:readSetting("offset"))
    local state, pending_dropped = validState({
        offset = isUpdateId(offset, 0) and offset or 0,
        pending_download = self.settings:readSetting("pending_download"),
        failed_update = self.settings:readSetting("failed_update"),
    })
    local saved, err, errno = writeState(self.state_file, state)
    if not saved then
        return nil, stateWriteFailure(err, errno)
    end
    if pending_dropped then
        self:addDamagedRecordWarning()
    end
    logger.info("TelegramDownloader: download state file created:", self.state_file)
    self.state = state
    return true
end

-- Adds, once per run, the warning shown with the run's result when a damaged
-- pending download record was dropped. The plugin only writes valid records,
-- so the state file was edited or damaged. The run goes on rather than stops:
-- stopping would block every run until the user deletes the file, whereas
-- dropping the record risks at most a leftover temporary file or one
-- duplicate.
function TelegramDownloader:addDamagedRecordWarning()
    self.run_warnings = self.run_warnings or {}
    local warning = _("A damaged record of an interrupted download was ignored; a leftover temporary file or a duplicate may remain in the download folder.")
    for __, existing in ipairs(self.run_warnings) do
        if existing == warning then
            return
        end
    end
    table.insert(self.run_warnings, warning)
end

-- Shows `text` followed by this run's warnings, if any (for runs that end
-- before reportResults).
function TelegramDownloader:showWithWarnings(text)
    local lines = { text }
    for __, warning in ipairs(self.run_warnings or {}) do
        table.insert(lines, warning)
    end
    self:showMessage(table.concat(lines, "\n"))
end

-- Applies `change` to a copy of the state and saves it. The state in memory
-- only changes once it is saved. Returns true, or nil and a message for the
-- user; the caller must then stop the run (nothing is counted), never go on
-- as if the state had been saved.
function TelegramDownloader:updateState(change)
    local state = {}
    for __, key in ipairs(STATE_KEYS) do
        state[key] = self.state[key]
    end
    change(state)
    local saved, err, errno = writeState(self.state_file, state)
    if not saved then
        return nil, stateWriteFailure(err, errno)
    end
    self.state = state
    return true
end

-- Remembers the download in progress (folder and file names), so that its
-- leftovers can be removed after a crash or power loss. Only one download
-- runs at a time. `update_id` is the update it comes from, so that a file
-- saved just before a crash can be acknowledged. Returns as updateState().
function TelegramDownloader:setPendingDownload(name, temp_name, update_id)
    if name and not isStorableUpdateId(update_id, self.state.offset) then
        -- checkForNewFiles() never gets here with one; this keeps the check
        -- next to every place an update ID is saved.
        return nil, unexpectedUpdateIdMessage(update_id)
    end
    return self:updateState(function(state)
        state.pending_download = name and {
            directory = self.directory,
            name = name,
            temp_name = temp_name,
            update_id = update_id,
        } or nil
    end)
end

-- Removes the files of a download interrupted by a crash or power loss: the
-- temporary file and, if still empty, the placeholder reserved for it. This
-- happens in the folder the download went to, even if the download folder
-- was changed since, as long as that folder still exists.
-- The record is validated, so that a damaged state file cannot make it
-- delete anything outside that folder or any non-book file. The temporary
-- file name contains a random part chosen when it was created: it is an
-- ownership marker against accidental matches (e.g. a user's own
-- "book.epub.part"), not a security boundary: anyone able to modify the
-- state file can also modify the settings file, which is Lua that KOReader's
-- LuaSettings executes with dofile(), so this does not try to defend
-- against them.
-- If the temporary file is gone and the destination is a non-empty file, the
-- rename (which is atomic) completed: the file was saved, but the offset was
-- not. Nothing is removed then, and the update is acknowledged, so that it is
-- not downloaded again as "name (1)".
-- Returns as updateState().
function TelegramDownloader:cleanupInterruptedDownload()
    local pending = self.state.pending_download
    if pending == nil then
        return true
    end
    local acknowledged
    if type(pending) == "table" and type(pending.directory) == "string"
            and lfs.attributes(pending.directory, "mode") == "directory"
            and type(pending.name) == "string" and sanitizeFileName(pending.name) == pending.name
            and isAllowedFileName(pending.name) and isTempNameFor(pending.temp_name, pending.name) then
        local temp_path = pending.directory .. "/" .. pending.temp_name
        local target = pending.directory .. "/" .. pending.name
        if lfs.symlinkattributes(temp_path, "mode") == nil
                and lfs.symlinkattributes(target, "mode") == "file"
                and (lfs.symlinkattributes(target, "size") or 0) > 0 then
            if isStorableUpdateId(pending.update_id, self.state.offset) then
                logger.info("TelegramDownloader: acknowledging update", pending.update_id, "saved before an interruption")
                acknowledged = pending.update_id
            elseif pending.update_id ~= nil then
                -- Records of older versions have none; any other value is damage.
                logger.warn("TelegramDownloader: ignoring invalid update ID in pending download record")
                self:addDamagedRecordWarning()
            end
        else
            removeRegularFile(temp_path)
            removeRegularFile(target, true)
        end
    else
        logger.warn("TelegramDownloader: ignoring invalid pending download record")
        self:addDamagedRecordWarning()
    end
    -- One write. If it fails, the record stays and is handled again next time.
    return self:updateState(function(state)
        state.pending_download = nil
        if acknowledged then
            state.offset = acknowledged + 1
            state.failed_update = nil
        end
    end)
end

-- Counts consecutive failed attempts at the same update across runs.
-- Returns the number of attempts, or nil and a message (see updateState).
function TelegramDownloader:recordFailedAttempt(update_id)
    if not isStorableUpdateId(update_id, self.state.offset) then
        -- As in setPendingDownload().
        return nil, unexpectedUpdateIdMessage(update_id)
    end
    local failed = self.state.failed_update
    local attempts = 1
    if type(failed) == "table" and failed.id == update_id then
        attempts = (tonumber(failed.attempts) or 0) + 1
    end
    local saved, err = self:updateState(function(state)
        state.failed_update = { id = update_id, attempts = attempts }
    end)
    if not saved then
        return nil, err
    end
    return attempts
end

-- Reads and decodes a small JSON error body saved to `path`, or returns nil.
local function readJsonFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read(4096)
    file:close()
    local ok, response = pcall(json.decode, data or "")
    return ok and type(response) == "table" and response or nil
end

-- Downloads a Telegram file into the download folder, never overwriting
-- anything. Returns true and the saved path, or nil, an error message and
-- the failure kind (see RETRY_WAIT). `update_id` is stored in the pending
-- record. On success, that record is left for the caller to clear in the same
-- state write that saves the offset (see checkForNewFiles).
function TelegramDownloader:downloadFile(file_id, name, expected_size, update_id)
    local file_info, err, kind = self:apiCall("getFile", { file_id = file_id })
    if not file_info then
        return nil, err, kind
    end
    local file_path = type(file_info) == "table" and file_info.file_path
    if type(file_path) ~= "string" or not file_path:match("^[%w_%-%./]+$") or file_path:find("..", 1, true) then
        return nil, _("Unexpected file path in Telegram response"), nil
    end

    local target, handle, temp_path = reserveDestination(self.directory, name)
    if not target then
        local errno = temp_path
        if errno == EINVAL then
            -- The C library rejects exclusive creation; without it, a file or
            -- symlink created meanwhile could be overwritten or followed.
            logger.warn("TelegramDownloader: exclusive file creation not supported:", handle)
            return nil, _("This device does not support safe file creation"), RETRY_WAIT
        end
        if errno == NO_RANDOM then
            -- Same as above: a device problem, not the document's fault.
            logger.warn("TelegramDownloader: no secure random source:", handle)
            return nil, _("This device has no secure random number source"), RETRY_WAIT
        end
        -- "Too many files with the same name" has no errno: counted.
        return nil, writeFailure(handle, errno)
    end

    -- From here on, everything runs protected, and the cleanup below always
    -- runs: the handle is closed and, unless the file was saved, the temporary
    -- file and the placeholder are removed. Unless the file was saved, the
    -- pending record is cleared last, once the files are in a consistent state.
    local saved = false
    kind = RETRY_ERROR
    local ok, exception = pcall(function()
        local recorded, record_err = self:setPendingDownload(target:sub(#self.directory + 2),
            temp_path:sub(#self.directory + 2), update_id)
        if not recorded then
            err, kind = record_err, RETRY_WAIT
            return
        end
        local write_failure = {}
        local code, get_err, local_failure = self:httpsGet("/file/bot" .. self.token .. "/" .. file_path,
            fileSink(handle, write_failure), MAX_FILE_SIZE, socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        if not code then
            if write_failure.err then
                err, kind = writeFailure(write_failure.err, write_failure.errno)
            else
                err, kind = get_err, local_failure and RETRY_ERROR or RETRY_WAIT
            end
            return
        end
        local closed, close_err, close_errno = closeChecked(handle, code == 200)
        if code ~= 200 then
            if code == 429 then
                err = rateLimitMessage(readJsonFile(temp_path))
            else
                err = T(_("Download failed (HTTP %1)"), code)
            end
            kind = isRemoteTransient(code) and RETRY_WAIT or nil
            return
        end
        if not closed then
            err, kind = writeFailure(close_err, close_errno)
            return
        end
        local size = lfs.attributes(temp_path, "size")
        if not size or size == 0 or (expected_size and size ~= expected_size) then
            err = _("Downloaded file is incomplete")
            return
        end
        local renamed, rename_err, rename_errno = os.rename(temp_path, target)
        if not renamed then
            err, kind = writeFailure(rename_err, rename_errno)
            return
        end
        saved = true
        syncDirectory(self.directory)
    end)

    if io.type(handle) == "file" then
        -- Not closeChecked(): if flushing is what failed, it must not stop the close.
        pcall(handle.close, handle)
    end
    if not ok then
        logger.err("TelegramDownloader: download failed:", self:redact(exception))
        err, kind = _("unexpected error"), RETRY_ERROR
    end
    if saved then
        -- The record is cleared by the caller (see above). Should that not
        -- happen, the next run's cleanup keeps the file and acknowledges it.
        return true, target
    end
    removeRegularFile(temp_path)
    removeRegularFile(target, true)
    if self.state.pending_download ~= nil then
        local no_error, cleared, clear_err = pcall(self.setPendingDownload, self, nil)
        if not no_error or not cleared then
            -- The record stays, and the next run's cleanup handles it. This
            -- run stops, as the state could not be saved.
            logger.err("TelegramDownloader: cannot clear pending download:", self:redact(no_error and clear_err or cleared))
            return nil, no_error and clear_err or _("Cannot save download progress"), RETRY_WAIT
        end
    end
    return nil, err, kind
end

-- Returns one of:
--   "ignored"                        (not a document)
--   "unauthorized", details          (a document from another account or
--                                     chat; see describeIgnoredSender)
--   "saved", path
--   "rejected", file name, reason   (permanent, the update is acknowledged)
--   "retry", file name, reason      (may be transient, retried MAX_ATTEMPTS times)
--   "wait", file name, reason       (not the document's fault, retried without limit)
-- What is shown and logged about a document ignored by handleUpdate():
-- sender ID, chat ID and chat type as strings ("none" if missing), and the
-- file name, sanitized for display.
local function describeIgnoredSender(message)
    local from = type(message.from) == "table" and message.from or {}
    local chat = type(message.chat) == "table" and message.chat or {}
    local function field(value)
        return value ~= nil and tostring(value) or "none"
    end
    return {
        from_id = field(from.id),
        chat_id = field(chat.id),
        chat_type = field(chat.type),
        name = sanitizeFileName(message.document.file_name) or "?",
    }
end

function TelegramDownloader:handleUpdate(update)
    local message = update.message
    if type(message) ~= "table" or type(message.document) ~= "table" then
        return "ignored"
    end
    -- Only accept files the owner sent in their private chat with the bot.
    local from, chat = message.from, message.chat
    if type(from) ~= "table" or type(chat) ~= "table"
            or tostring(from.id) ~= self.user_id or tostring(chat.id) ~= self.user_id then
        local details = describeIgnoredSender(message)
        -- IDs only, never the token: they tell the user which ID to configure.
        logger.info("TelegramDownloader: ignoring message: sender", details.from_id,
            "chat", details.chat_id, details.chat_type, "file", details.name)
        return "unauthorized", details
    end

    local document = message.document
    local original_name = type(document.file_name) == "string" and document.file_name or "?"
    local name = sanitizeFileName(document.file_name)
    if not name or not isAllowedFileName(name) then
        return "rejected", original_name, _("unsupported file type")
    end
    local size = tonumber(document.file_size)
    if size and size > MAX_FILE_SIZE then
        return "rejected", name, _("file is larger than 20 MB")
    end
    if type(document.file_id) ~= "string" or document.file_id == "" then
        return "rejected", name, _("missing file ID")
    end

    local ok, result, kind = self:downloadFile(document.file_id, name, size, update.update_id)
    if ok then
        return "saved", result
    end
    if kind == RETRY_WAIT then
        return "wait", name, result
    end
    return kind and "retry" or "rejected", name, result
end

function TelegramDownloader:checkForNewFiles()
    -- Warnings shown with this run's result (see addDamagedRecordWarning).
    self.run_warnings = {}
    local ready, state_err = self:loadState()
    if ready then
        ready, state_err = self:cleanupInterruptedDownload()
    end
    if not ready then
        self:showWithWarnings(state_err)
        return
    end

    local updates, err = self:apiCall("getUpdates", {
        offset = self.state.offset,
        limit = 100,
        timeout = 0,
        allowed_updates = '["message"]',
    })
    if not updates then
        self:showWithWarnings(err)
        return
    end
    if type(updates) ~= "table" or #updates == 0 then
        self:showWithWarnings(_("There are no new files"))
        return
    end

    self:showMessage(_("Downloading. This might take a moment."), 1)
    UIManager:forceRePaint()

    local saved, failed = {}, {}
    local stopped_early = false
    -- Documents ignored because of their sender or chat, so that the user
    -- learns why nothing was downloaded. Two kinds:
    --   other_account: sent by another account (whatever the chat);
    --   outside_chat:  sent by the configured account, but not in its
    --                  private chat with the bot (a group or channel).
    -- Each keeps a count and the first one's details (describeIgnoredSender).
    local ignored = {}
    for __, update in ipairs(updates) do
        local update_id = type(update) == "table" and update.update_id or nil
        if not isStorableUpdateId(update_id, self.state.offset) then
            -- Telegram never sends one (IDs only grow, from the offset asked
            -- for). It cannot be acknowledged or counted, so nothing is saved
            -- for it, and the run stops here.
            table.insert(failed, unexpectedUpdateIdMessage(update_id))
            break
        end
        local ok, status, info, reason = pcall(self.handleUpdate, self, update)
        if not ok then
            -- Not necessarily the document's fault, so retry rather than drop it.
            logger.err("TelegramDownloader: failed to process update:", self:redact(status))
            status, info, reason = "retry", "?", _("unexpected error")
        end
        local state_err
        if status == "retry" then
            -- Bounded, so that one bad update cannot block all later ones forever.
            local attempts
            attempts, state_err = self:recordFailedAttempt(update_id)
            if not attempts then
                -- Not counted: stop, as for any failure to save the state.
                status = "wait"
            elseif attempts >= MAX_ATTEMPTS then
                status = "rejected"
                reason = T(_("%1 (skipped after %2 attempts, please send it again)"), reason, attempts)
                logger.warn("TelegramDownloader: skipping update", update_id, "file", info, "after", attempts, "attempts")
            end
        end
        if status == "saved" then
            table.insert(saved, info)
        elseif status == "unauthorized" then
            local kind = info.from_id == self.user_id and "outside_chat" or "other_account"
            if ignored[kind] then
                ignored[kind].count = ignored[kind].count + 1
            else
                ignored[kind] = { count = 1, first = info }
            end
        elseif status ~= "ignored" then
            table.insert(failed, T("%1: %2", info, reason))
        end
        if state_err then
            table.insert(failed, state_err)
        end
        if status == "retry" or status == "wait" then
            -- Keep this update (and later ones) on the server so the next run retries them.
            stopped_early = true
            break
        end
        -- Acknowledge each update as soon as it is handled, so a crash or
        -- power loss does not cause already saved files to be downloaded again.
        -- A saved file's pending record is cleared in the same state write; a
        -- crash before it is handled by cleanupInterruptedDownload(). If the
        -- write fails, the run stops here: the next run starts from the state
        -- last saved, and its cleanup acknowledges a file saved meanwhile.
        local acknowledged
        acknowledged, state_err = self:updateState(function(state)
            state.offset = update_id + 1
            state.failed_update = nil
            if status == "saved" then
                state.pending_download = nil
            end
        end)
        if not acknowledged then
            table.insert(failed, state_err)
            stopped_early = true
            break
        end
    end

    self:reportResults(saved, failed, stopped_early, ignored)

    if #saved > 0 then
        UIManager:scheduleIn(0.5, function()
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:onRefresh()
                UIManager:setDirty(FileManager.instance, "ui")
            end
        end)
    end
end

-- `ignored` is as in checkForNewFiles() (optional).
function TelegramDownloader:reportResults(saved, failed, stopped_early, ignored)
    local lines = {}
    -- Shown whatever else happened: otherwise a file sent from the wrong
    -- account or chat just disappears with "There are no new files".
    local ignored_lines = {}
    ignored = ignored or {}
    if ignored.other_account then
        table.insert(ignored_lines, T(_("%1 file(s) from another Telegram account were ignored (sender ID %2). If that is you, set this ID in \"Telegram Bot configuration\" and send the file again."),
            ignored.other_account.count, ignored.other_account.first.from_id))
    end
    if ignored.outside_chat then
        table.insert(ignored_lines, T(_("%1 file(s) you sent outside your private chat with the bot were ignored. Send files directly to the bot."),
            ignored.outside_chat.count))
    end
    if #failed > 0 then
        table.insert(lines, _("Some files were not downloaded:"))
        for __, line in ipairs(failed) do
            table.insert(lines, line)
        end
        if stopped_early then
            table.insert(lines, _("Remaining files will be retried next time."))
        end
    end
    for __, line in ipairs(ignored_lines) do
        table.insert(lines, line)
    end
    for __, warning in ipairs(self.run_warnings or {}) do
        table.insert(lines, warning)
    end

    if #saved == 1 then
        local file_path = saved[1]
        table.insert(lines, 1, T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), file_path))
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Read now"),
            ok_callback = function()
                if self.ui.document then
                    self.ui:switchDocument(file_path)
                else
                    self.ui:openFile(file_path)
                end
            end,
        })
    elseif #saved > 1 then
        table.insert(lines, 1, T(_("%1 files saved to:\n%2"), #saved, self.directory))
        self:showMessage(table.concat(lines, "\n"))
    else
        if #failed == 0 and #ignored_lines == 0 then
            table.insert(lines, 1, _("There are no new files"))
        end
        self:showMessage(table.concat(lines, "\n"))
    end
end

function TelegramDownloader:addToMainMenu(menu_items)
    menu_items.telegram_downloader = {
        text = _("TelegramDownloader"),
        keep_menu_open = true,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Choose folder (%1)"), self.directory)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    require("ui/downloadmgr"):new{
                        onConfirm = function(path)
                            self.directory = path
                            self.settings:saveSetting("directory", path)
                            self.settings:flush()
                            touchmenu_instance:updateItems()
                        end,
                    }:chooseDir(self.directory)
                end,
            },
            {
                text = _("Telegram Bot configuration"),
                keep_menu_open = true,
                callback = function()
                    self:showConfigurationDialog()
                end,
            },
            {
                text = _("Download files"),
                callback = function()
                    self:downloadFiles()
                end,
            },
        },
    }
end

function TelegramDownloader:showConfigurationDialog()
    self:loadSettings()
    local configuration_window
    configuration_window = require("ui/widget/multiinputdialog"):new{
        title = _("Telegram Bot configuration"),
        fields = {
            {
                description = _("Bot token"),
                text = self.token,
                hint = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
                text_type = "password",
            },
            {
                description = _("Your user ID"),
                text = self.user_id,
                hint = "12345678",
                input_type = "number",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(configuration_window)
                    end,
                },
                {
                    text = _("Info"),
                    callback = function()
                        self:showMessage(T(_("You can also change these settings in the file: %1"), self.settings_file))
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = configuration_window:getFields()
                        local token = util.trim(fields[1] or "")
                        local user_id = util.trim(fields[2] or "")
                        if isValidToken(token) and isValidUserId(user_id) then
                            self.token = token
                            self.user_id = user_id
                            self.settings:saveSetting("token", token)
                            self.settings:saveSetting("user_id", user_id)
                            self.settings:flush()
                            self:showMessage(_("Settings saved successfully"))
                            UIManager:close(configuration_window)
                        else
                            self:showMessage(_("Error. Invalid value."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(configuration_window)
    configuration_window:onShowKeyboard()
end

-- Exposed for unit tests only.
TelegramDownloader._private = {
    sanitizeFileName = sanitizeFileName,
    isAllowedFileName = isAllowedFileName,
    hostnameMatches = tls.hostnameMatches,
    certificateMatchesHost = tls.certificateMatchesHost,
    isValidToken = isValidToken,
    isValidUserId = isValidUserId,
    reserveDestination = reserveDestination,
    isTempNameFor = isTempNameFor,
    guardedSink = guardedSink,
    fileSink = fileSink,
    closeChecked = closeChecked,
}

return TelegramDownloader
