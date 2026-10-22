--[[
Device self-test for TelegramDownloader.koplugin.

Runs, on the actual device and with KOReader's own LuaJIT, LuaSocket and
LuaSec, the checks that cannot be done on a development machine:

  1. Exclusive file creation: io.open(path, "wbx") must refuse an existing
     file, a symlink and a dangling symlink, without touching anything.
     All test files are created inside a new private directory
     (tgdl-selftest-<random>), so no pre-existing file is ever modified.
  2. HTTPS to api.telegram.org through the plugin's own TLS code
     (telegramdownloader_tls.lua): chain and hostname verification succeed.
  3. Rejection of bad certificates: wrong hostname (valid chain), self-signed,
     untrusted root and expired, using the public test hosts of badssl.com.

No bot token is used and nothing is sent to Telegram besides a plain
"GET /" (which Telegram answers without authentication).

Usage, from KOReader's install directory (e.g. /mnt/us/koreader on Kindle),
in KOReader's terminal emulator or over SSH:

    ./luajit /path/to/device_selftest.lua [plugin_dir] [download_dir]

plugin_dir defaults to plugins/TelegramDownloader.koplugin and
download_dir to /mnt/us/documents (or the current directory if absent).
Exit code 0 means every check passed or was legitimately skipped.
]]

require("setupkoenv")

local plugin_dir = arg[1] or "plugins/TelegramDownloader.koplugin"
local download_dir = arg[2]
package.path = plugin_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local http = require("socket.http")
local ltn12 = require("ltn12")
local ssl = require("ssl")
local tls = require("telegramdownloader_tls")

ffi.cdef[[
int symlink(const char *target, const char *linkpath);
int mkdir(const char *, unsigned int);
]]

local EEXIST, EINVAL = 17, 22
local results = { pass = 0, fail = 0, skip = 0 }

local function report(status, name, detail)
    results[status:lower()] = results[status:lower()] + 1
    print(string.format("[%s] %s%s", status, name, detail and (" - " .. detail) or ""))
end

local function check(cond, name, detail)
    report(cond and "PASS" or "FAIL", name, detail)
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function isDirectory(path)
    local f = io.open(path .. "/.", "rb")
    if f then f:close() end
    return f ~= nil
end

--- 1. Exclusive file creation ---------------------------------------------

-- 16 hex digits from /dev/urandom, or nil and an error message. There is
-- deliberately no math.random fallback: a predictable name could be planted.
local function randomHex()
    local urandom = io.open("/dev/urandom", "rb")
    if not urandom then
        return nil, "cannot open /dev/urandom"
    end
    local ok, bytes = pcall(urandom.read, urandom, 8)
    urandom:close()
    if not ok or type(bytes) ~= "string" or #bytes ~= 8 then
        return nil, "cannot read 8 bytes from /dev/urandom"
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- Runs the checks inside `base`, a private directory created for them.
-- `created` records, in order, every path whose creation verifiably
-- succeeded; only those are removed afterwards.
local function runExclusiveChecks(base, label, created)
    local victim, fresh = base .. "/victim", base .. "/fresh"
    local link, dangling, dangling_target = base .. "/link", base .. "/dangling", base .. "/nowhere"

    local f, err, errno = io.open(fresh, "wbx")
    if f then
        table.insert(created, fresh)
        f:close()
    elseif errno == EINVAL then
        report("FAIL", label .. ": \"wbx\" mode", "rejected by the C library (" .. tostring(err)
            .. "); the plugin will refuse to download on this device")
        return
    end
    check(f ~= nil, label .. ": \"wbx\" creates a new file", not f and tostring(err) or nil)

    local v, verr = io.open(victim, "wbx")
    if not v then
        report("FAIL", label .. ": cannot create the test file", tostring(verr))
        return
    end
    table.insert(created, victim)
    local written = v:write("ORIGINAL")
    local closed, cerr = v:close()
    if not written or not closed then
        report("FAIL", label .. ": cannot write the test file", tostring(cerr))
        return
    end

    local g, gerr, gerrno = io.open(victim, "wbx")
    if g then g:close() end
    check(g == nil and gerrno == EEXIST and readAll(victim) == "ORIGINAL",
        label .. ": \"wbx\" refuses an existing file and leaves it intact",
        string.format("errno=%s, content=%q", tostring(gerrno), tostring(readAll(victim))))

    -- Link targets are relative: they resolve from the link's own directory,
    -- so a target built from `base` would be wrong whenever `base` is relative
    -- (and the "existing target" check would silently test a dangling link).
    if ffi.C.symlink("victim", link) ~= 0 then
        report("SKIP", label .. ": symlink checks",
            "this filesystem does not support symlinks, so symlink attacks are impossible here")
        return
    end
    table.insert(created, link)
    local h, __, herrno = io.open(link, "wbx")
    if h then h:close() end
    check(h == nil and herrno == EEXIST and readAll(victim) == "ORIGINAL",
        label .. ": \"wbx\" refuses a symlink and does not follow it",
        string.format("errno=%s, target content=%q", tostring(herrno), tostring(readAll(victim))))

    if ffi.C.symlink("nowhere", dangling) ~= 0 then
        report("FAIL", label .. ": cannot create a dangling symlink", "errno=" .. tostring(ffi.errno()))
        return
    end
    table.insert(created, dangling)
    local d, __, derrno = io.open(dangling, "wbx")
    if d then d:close() end
    -- The target must never exist. If the C library followed the link, it
    -- was created inside the private directory, so it is removed with it.
    local followed = exists(dangling_target)
    if followed then
        table.insert(created, dangling_target)
    end
    check(d == nil and derrno == EEXIST and not followed,
        label .. ": \"wbx\" refuses a dangling symlink and creates nothing behind it",
        "errno=" .. tostring(derrno) .. (followed and ", the link was followed and its target created" or ""))
end

local function testExclusiveCreation(dir, label)
    local token, token_err = randomHex()
    if not token then
        report("FAIL", label .. ": private test directory", token_err .. "; nothing was created")
        return
    end
    -- mkdir() is atomic and fails if anything (even a symlink) already exists
    -- under that name: then nothing is touched.
    local base = dir .. "/tgdl-selftest-" .. token
    if ffi.C.mkdir(base, 448) ~= 0 then -- 0700
        local errno = ffi.errno()
        report("FAIL", label .. ": private test directory", string.format("cannot create %s (errno=%d%s); nothing was touched",
            base, errno, errno == EEXIST and ", already exists" or ""))
        return
    end

    local created = {}
    local ok, err = pcall(runExclusiveChecks, base, label, created)
    if not ok then
        report("FAIL", label .. ": exclusive creation checks raised an error", tostring(err))
    end

    local clean = true
    for i = #created, 1, -1 do
        local removed, remove_err = os.remove(created[i])
        if not removed then
            clean = false
            report("FAIL", label .. ": cleanup", "cannot remove " .. created[i] .. ": " .. tostring(remove_err))
        end
    end
    local removed, remove_err = os.remove(base)
    if not removed then
        clean = false
        report("FAIL", label .. ": cleanup", "cannot remove " .. base .. ": " .. tostring(remove_err))
    end
    if clean then
        report("PASS", label .. ": test files removed")
    end
end

--- 2./3. TLS ---------------------------------------------------------------

local function findCaFile()
    for __, path in ipairs(tls.CA_FILE_CANDIDATES) do
        if readAll(path) then
            return path
        end
    end
end

-- Returns the HTTP status code, or nil and the error.
local function get(host, cafile)
    local res, code = http.request{
        url = "https://" .. host .. "/",
        method = "GET",
        sink = ltn12.sink.null(),
        redirect = false,
        create = tls.verifiedTlsCreate(cafile),
    }
    if not res then
        return nil, code
    end
    return code
end

local function testTls()
    print("LuaSec " .. tostring(ssl._VERSION) .. ", LuaSocket " .. tostring(require("socket")._VERSION))
    local cafile = findCaFile()
    check(cafile ~= nil, "CA bundle found", cafile or "none of: " .. table.concat(tls.CA_FILE_CANDIDATES, ", "))
    if not cafile then
        return
    end
    http.TIMEOUT = 20

    local code, err = get("api.telegram.org", cafile)
    local category = not code and tls.errorCategory(err)
    check(code ~= nil, "HTTPS to api.telegram.org (port 443, chain + hostname verified)",
        code and ("HTTP " .. code) or (tostring(err) .. (category and (" [" .. category .. " error]") or "")))

    -- Each bad host must be rejected for the expected reason: a DNS failure,
    -- a timeout or any other error proves nothing about verification.
    -- wrong.host has a valid chain, so only the hostname check can reject it.
    local negative = {
        { host = "wrong.host.badssl.com", category = "hostname" },
        { host = "self-signed.badssl.com", category = "certificate" },
        { host = "untrusted-root.badssl.com", category = "certificate" },
        { host = "expired.badssl.com", category = "certificate" },
    }

    -- Control: a correctly configured host on the same test service must
    -- work, otherwise the rejection checks below would prove nothing. They
    -- then fail rather than being skipped: a release must not be judged on
    -- skipped TLS checks.
    local control, control_err = get("badssl.com", cafile)
    check(control ~= nil, "control: valid certificate on badssl.com accepted",
        control and ("HTTP " .. control) or tostring(control_err))
    for __, case in ipairs(negative) do
        local name = string.format("%s rejected (%s error)", case.host, case.category)
        if not control then
            report("FAIL", name, "badssl.com unreachable, re-run when online")
        else
            code, err = get(case.host, cafile)
            category = not code and tls.errorCategory(err)
            if code then
                report("FAIL", name, "accepted: HTTP " .. code)
            else
                check(category == case.category, name, category == case.category and tostring(err)
                    or string.format("expected a %s error, got: %s", case.category, tostring(err)))
            end
        end
    end
end

--- Run ---------------------------------------------------------------------

if not download_dir then
    download_dir = isDirectory("/mnt/us/documents") and "/mnt/us/documents" or "."
end

print("== Exclusive file creation")
testExclusiveCreation(download_dir, download_dir)
local tmp = os.getenv("TMPDIR") or "/tmp"
if isDirectory(tmp) and tmp ~= download_dir then
    -- tmpfs supports symlinks, so the C library's behaviour is always tested.
    testExclusiveCreation(tmp, tmp)
end

print("== TLS")
local ok, err = pcall(testTls)
if not ok then
    report("FAIL", "TLS checks raised an error", tostring(err))
end

print(string.format("== %d passed, %d failed, %d skipped", results.pass, results.fail, results.skip))
os.exit(results.fail == 0 and 0 or 1)
