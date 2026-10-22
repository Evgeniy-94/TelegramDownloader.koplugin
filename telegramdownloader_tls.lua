-- Verified TLS connections for LuaSocket's http client.
--
-- LuaSec's ssl.https defaults to verify = "none" and never checks the
-- hostname, and its request() refuses a custom "create" function, so the
-- plugin uses socket.http with the "create" function built here instead.
-- LuaSocket's http client calls it for https:// URLs and defaults to port 443.
--
-- Only depends on LuaSocket and LuaSec, so that tools/device_selftest.lua can
-- run this exact code on a device, outside of KOReader's UI.
local http = require("socket.http")
local socket = require("socket")
local ssl = require("ssl")

local M = {}

-- KOReader ships Mozilla's CA bundle (certifi) as data/ca-bundle.crt, relative
-- to its install dir, which is the working directory at runtime.
-- The system locations are fallbacks for emulator/desktop builds.
M.CA_FILE_CANDIDATES = {
    "data/ca-bundle.crt",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/cert.pem",
}

M.HOSTNAME_MISMATCH = "TLS certificate does not match"
-- What LuaSec's dohandshake() returns when the chain does not verify
-- (OpenSSL's reason string for SSL_R_CERTIFICATE_VERIFY_FAILED). The detailed
-- reason (expired, self-signed...) is not available after a failed handshake.
M.CERT_VERIFY_FAILED = "certificate verify failed"

-- Classifies a connection error: "hostname" for a certificate issued to
-- another name, "certificate" for a chain that does not verify, or nil for
-- anything else (DNS, timeouts, refused connections, other TLS errors).
function M.errorCategory(err)
    if type(err) ~= "string" then
        return nil
    end
    if err:find(M.HOSTNAME_MISMATCH, 1, true) then
        return "hostname"
    end
    if err:find(M.CERT_VERIFY_FAILED, 1, true) then
        return "certificate"
    end
    return nil
end

-- RFC 6125: compare case-insensitively; a wildcard may only be the whole
-- left-most label and matches exactly one label.
function M.hostnameMatches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then
        return true
    end
    local suffix = pattern:match("^%*(%.[^*]+%.[^*]+)$")
    if suffix then
        local label, rest = host:match("^([^.]+)(%..+)$")
        return label ~= nil and rest == suffix
    end
    return false
end

-- Only subjectAltName dNSName entries are considered (no CN fallback),
-- as required for publicly trusted certificates. LuaSec (x509.c) keys
-- extensions by OID and lists DNS names under "dNSName".
function M.certificateMatchesHost(cert, host)
    local ok, extensions = pcall(cert.extensions, cert)
    local san = ok and type(extensions) == "table" and extensions["2.5.29.17"]
    local names = type(san) == "table" and san.dNSName
    if type(names) ~= "table" then
        return false
    end
    host = host:lower()
    for __, name in ipairs(names) do
        if type(name) == "string" and M.hostnameMatches(name, host) then
            return true
        end
    end
    return false
end

-- Modelled on LuaSec's https.tcp(). Implements exactly the socket methods
-- LuaSocket's http client uses.
local TlsConnection = {}
TlsConnection.__index = TlsConnection

function TlsConnection:settimeout(value, mode)
    self.timeout = value
    return self.sock:settimeout(value, mode)
end

function TlsConnection:connect(host, port)
    local ok, err = self.sock:connect(host, port)
    if ok then
        ok, err = self:startTls(host)
    end
    if not ok then
        self:close()
        return nil, err
    end
    return 1
end

function TlsConnection:startTls(host)
    if type(host) ~= "string" or host == "" then
        return nil, "invalid host"
    end
    local tls, err = ssl.wrap(self.sock, self.params)
    if not tls then
        return nil, err
    end
    self.sock = tls
    self.tls = true
    -- In client mode, LuaSec's sni() returns nothing (the result of
    -- SSL_set_tlsext_host_name is ignored), so there is nothing to check here.
    -- If SNI is not sent, the server's default certificate is presented and
    -- the handshake or the hostname check below fails: that check, not SNI,
    -- is the security boundary.
    tls:sni(host)
    tls:settimeout(self.timeout)
    local ok, handshake_err = tls:dohandshake()
    if not ok then
        return nil, handshake_err
    end
    local cert = tls:getpeercertificate()
    if not cert or not M.certificateMatchesHost(cert, host) then
        return nil, M.HOSTNAME_MISMATCH .. " " .. tostring(host)
    end
    return 1
end

function TlsConnection:send(...)
    if not self.tls then return nil, "closed" end
    return self.sock:send(...)
end

function TlsConnection:receive(...)
    if not self.tls then return nil, "closed" end
    return self.sock:receive(...)
end

function TlsConnection:getfd()
    return self.sock:getfd()
end

function TlsConnection:dirty()
    return self.sock:dirty()
end

function TlsConnection:close()
    -- Closing the TLS wrapper also closes the underlying TCP socket.
    return self.sock:close()
end

-- Returns a LuaSocket "create" function for connections that verify the
-- certificate chain against `cafile` and the certificate's hostname.
function M.verifiedTlsCreate(cafile)
    local params = {
        mode = "client",
        protocol = "any",
        -- TLS 1.2 or newer only.
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = cafile,
    }
    return function()
        local sock, err = socket.tcp()
        if not sock then
            return nil, err
        end
        return setmetatable({ sock = sock, params = params, timeout = http.TIMEOUT }, TlsConnection)
    end
end

return M
