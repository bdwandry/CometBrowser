-- HTTP/HTTPS Client for CometBrowser
-- Raw TCP implementation: the SDK's native playdate.network.http follows
-- redirects internally and CRASHES the WX Simulator on 3xx responses (known
-- Panic SDK bug, unfixed as of 3.1.1). So we speak HTTP/1.1 ourselves over
-- playdate.network.tcp and follow redirects entirely in Lua.
import "core/url"
import "core/constants"
import "core/logger"

HttpClient = {}

local MAX_RESPONSE_SIZE = 2097152   -- 2 MB hard cap to prevent memory growth
local REQUEST_TIMEOUT_MS = 60000    -- 60 seconds total
local MAX_REDIRECTS       = 5
local READ_CHUNK          = 32768

-- ── State ────────────────────────────────────────────────────────────────────
local activeTcp      = nil
local activeCallbacks = nil
local activeUrl      = nil
local activeParsed   = nil

local requestState    = "idle"   -- idle | connecting | reading | done | error
local requestStatus   = 200
local requestBuffer   = ""
local requestHeaders  = {}
local bodyStart       = nil      -- 1-based index of first body byte (nil until headers parsed)
local isChunked       = false
local contentLength   = -1
local connOpen        = false   -- open callback fired with connected=true
local openFailed      = false   -- open callback fired with connected=false
local connClosed      = false
local errorMessage    = nil
local requestStart    = 0
local requestId       = 0       -- bumped on every reset; stale opens close themselves

-- Deferred redirect: the next connection is opened on the following update()
-- tick, after the previous connection has fully been closed by us.
local pendingRedirectUrl = nil
local pendingRedirectCallbacks = nil
local redirectDepth = 0

-- ── Internal pages ───────────────────────────────────────────────────────────
local INTERNAL_PAGES = {
    ["about:home"] = {
        title = "CometBrowser",
        html  = [[<html><head><title>CometBrowser</title></head><body><h1>CometBrowser</h1><p>Ready.</p></body></html>]]
    },
    ["about:blank"] = {
        title = "Blank",
        html  = "<html><body></body></html>"
    }
}

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function closeTcp()
    if activeTcp then
        local t = activeTcp
        activeTcp = nil
        -- Only close once the open callback has resolved. Closing a socket
        -- that is STILL CONNECTING natively crashes the WX Simulator, so in
        -- that case we leave the connection to the open callback, which detects
        -- the stale request via requestId and closes itself.
        if connOpen or openFailed then
            pcall(function() t:close() end)
        end
    end
end

local function reset()
    closeTcp()
    requestId = requestId + 1
    activeCallbacks = nil
    activeUrl       = nil
    activeParsed    = nil
    requestHeaders  = {}
    requestBuffer   = ""
    requestStatus   = 200
    bodyStart       = nil
    isChunked       = false
    contentLength   = -1
    connOpen        = false
    openFailed      = false
    connClosed      = false
    errorMessage    = nil
    requestState    = "idle"
end

-- Build a minimal HTTP/1.1 GET request.
local function buildRequest(parsed)
    local portStr = ""
    if parsed.port and parsed.port ~= 80 and parsed.port ~= 443 then
        portStr = ":" .. tostring(parsed.port)
    end
    local req = "GET " .. parsed.fullPath .. " HTTP/1.1\r\n"
    req = req .. "Host: " .. parsed.host .. portStr .. "\r\n"
    req = req .. "User-Agent: CometBrowser/1.0 (Playdate)\r\n"
    req = req .. "Accept: text/html,text/plain;q=0.8\r\n"
    req = req .. "Accept-Language: en-US,en;q=0.9\r\n"
    req = req .. "Connection: close\r\n"
    req = req .. "\r\n"
    return req
end

-- Decode a chunked-encoded body. Returns nil while the chunk stream is still
-- incomplete (caller keeps buffering and retries).
local function decodeChunked(str)
    local body = {}
    local pos = 1
    while true do
        local lineEnd = string.find(str, "\r\n", pos, true)
        if not lineEnd then return nil end
        local sizeStr = string.sub(str, pos, lineEnd - 1)
        local ext = string.find(sizeStr, ";", 1, true)
        if ext then sizeStr = string.sub(sizeStr, 1, ext - 1) end
        sizeStr = string.match(sizeStr, "^%s*(.-)%s*$")
        local size = tonumber(sizeStr, 16)
        if not size then return nil end
        pos = lineEnd + 2
        if size == 0 then
            return table.concat(body)
        end
        if #str < pos + size + 2 then return nil end
        table.insert(body, string.sub(str, pos, pos + size - 1))
        pos = pos + size + 2
    end
end

-- Parse the status line and headers once the \r\n\r\n separator has arrived.
local function parseHeaders()
    local hEnd = string.find(requestBuffer, "\r\n\r\n", 1, true)
    if not hEnd then return false end
    local headPart = string.sub(requestBuffer, 1, hEnd - 1)
    bodyStart = hEnd + 4

    local statusLine = string.match(headPart, "^[^\r\n]+")
    local st = tonumber(string.match(statusLine or "", "HTTP/%d+%.%d+ (%d+)"))
    if st then requestStatus = st end

    local headers = {}
    for line in string.gmatch(headPart .. "\n", "([^\n]+)\n") do
        local k, v = string.match(line, "^%s*([^:]+)%s*:%s*(.-)%s*$")
        if k and v then headers[string.lower(k)] = v end
    end
    requestHeaders = headers

    local te = string.lower(headers["transfer-encoding"] or "")
    isChunked = (string.find(te, "chunked") ~= nil)
    if isChunked then
        contentLength = -1
    else
        contentLength = tonumber(headers["content-length"]) or -1
    end
    return true
end

-- ── Public API ───────────────────────────────────────────────────────────────
function HttpClient.cancel()
    reset()
end

function HttpClient.isLoading()
    return requestState == "connecting" or requestState == "reading"
end

local function doGet(urlString, callbacks)
    Logger.log("doGet: " .. tostring(urlString))
    callbacks        = callbacks or {}
    activeCallbacks  = callbacks
    activeUrl        = urlString
    requestState     = "connecting"
    requestStart     = playdate.getCurrentTimeMilliseconds()
    requestBuffer    = ""
    requestStatus    = 200
    requestHeaders   = {}
    bodyStart        = nil
    isChunked        = false
    contentLength    = -1
    connOpen         = false
    openFailed       = false
    connClosed       = false
    errorMessage     = nil

    -- ── Internal about: pages ──────────────────────────────────────────────
    if string.match(urlString, "^about:") then
        local page = INTERNAL_PAGES[urlString]
        if page then
            playdate.timer.performAfterDelay(20, function()
                if callbacks.onProgress then callbacks.onProgress(100, 100) end
                if callbacks.onSuccess  then callbacks.onSuccess(200, {["content-type"]="text/html"}, page.html, urlString) end
                reset()
            end)
        else
            if callbacks.onError then callbacks.onError("Unknown internal page: " .. urlString) end
            reset()
        end
        return true
    end

    -- ── Parse URL ─────────────────────────────────────────────────────────
    local parsed = URL.parse(urlString)
    activeParsed  = parsed

    if not parsed.host or parsed.host == "" then
        Logger.log("doGet ERROR: invalid URL (no hostname): " .. tostring(urlString))
        if callbacks.onError then callbacks.onError("Invalid URL (no hostname): " .. urlString) end
        reset()
        return false
    end

    -- ── Network availability check ────────────────────────────────────────
    local net = playdate.network
    if not net or not net.tcp then
        Logger.log("doGet ERROR: networking not available")
        if callbacks.onError then callbacks.onError("Networking not available.") end
        reset()
        return false
    end

    -- ── Open TCP connection (with TLS if https) ───────────────────────────
    -- SDK: playdate.network.tcp.new(server, port, [usessl], [reason])
    local tcp
    local ok = pcall(function()
        tcp = net.tcp.new(parsed.host, parsed.port, parsed.isSsl, "CometBrowser Web Browsing")
    end)
    if not ok or not tcp then
        Logger.log("doGet ERROR: could not create connection to " .. tostring(parsed.host))
        if callbacks.onError then callbacks.onError("Could not open connection to " .. parsed.host) end
        reset()
        return false
    end

    activeTcp = tcp

    -- Generation id for this request: any callback that no longer matches is a
    -- stale event from a previous connection and must be ignored (the SDK
    -- delivers old connections' close callbacks asynchronously, and trusting
    -- them would make a fresh connection think the server already closed).
    local myId = requestId

    pcall(function() tcp:setConnectTimeout(10) end)
    pcall(function() tcp:setReadTimeout(10)    end)
    pcall(function() tcp:setReadBufferSize(16384) end)

    local regOk, regErr = pcall(function()
        tcp:setConnectionClosedCallback(function()
            pcall(function()
                if myId == requestId then
                    connClosed = true
                end
            end)
        end)
    end)
    if not regOk then
        print("ZQCONN-REGCB-ERR: " .. tostring(regErr))
        Logger.log("doGet ERROR: could not set up connection to " .. tostring(parsed.host) .. ": " .. tostring(regErr))
        if callbacks.onError then
            callbacks.onError("Could not set up connection to " .. parsed.host .. ": " .. tostring(regErr))
        end
        reset()
        return false
    end

    -- ── Open (async); the request is written from update() on a later frame ──
    local openOk, openErr = pcall(function()
        tcp:open(function(connected, err)
            pcall(function()
                if myId ~= requestId then
                    -- This connection was cancelled or superseded while still
                    -- connecting. It is now safe to close (open has resolved).
                    pcall(function() tcp:close() end)
                    return
                end
                if not connected then
                    Logger.log("doGet ERROR: connect failed for " .. tostring(parsed.host) .. ": " .. tostring(err))
                    openFailed = true
                    errorMessage = "Connection failed" .. (err and (": " .. tostring(err)) or ".")
                    requestState = "error"
                    return
                end
                connOpen = true
            end)
        end)
    end)
    if not openOk then
        print("ZQCONN-OPEN-ERR: " .. tostring(openErr))
        Logger.log("doGet ERROR: tcp:open failed for " .. tostring(parsed.host) .. ": " .. tostring(openErr))
        if callbacks.onError then callbacks.onError("Could not open connection to " .. parsed.host .. ": " .. tostring(openErr)) end
        reset()
        return false
    end

    return true
end

function HttpClient.get(urlString, callbacks)
    -- Cancel any previous request cleanly
    HttpClient.cancel()

    -- A fresh top-level request starts a new redirect chain and must not be
    -- pre-empted by a stale redirect enqueued for the previous request.
    pendingRedirectUrl = nil
    pendingRedirectCallbacks = nil
    redirectDepth = 0
    Logger.log("HttpClient.get: " .. tostring(urlString))

    return doGet(urlString, callbacks)
end

-- ── Update: called every frame from main playdate.update() ───────────────────
function HttpClient.update()
    -- A deferred redirect (from a prior tick) opens the next connection now,
    -- well after the previous connection was closed by us.
    if pendingRedirectUrl then
        local u  = pendingRedirectUrl
        local cb = pendingRedirectCallbacks
        pendingRedirectUrl = nil
        pendingRedirectCallbacks = nil
        print("ZQREDIRECT " .. redirectDepth .. " -> " .. tostring(u))
        Logger.log("redirect -> " .. tostring(u))
        doGet(u, cb)
        return
    end

    if requestState == "idle" then return end

    local now = playdate.getCurrentTimeMilliseconds()

    -- Timeout watchdog
    if requestState == "connecting" or requestState == "reading" then
        if now - requestStart > REQUEST_TIMEOUT_MS then
            print("ZQ watchdog fired state=" .. requestState .. " buf=" .. #requestBuffer)
            Logger.log("watchdog fired state=" .. tostring(requestState) .. " buf=" .. tostring(#requestBuffer))
            if #requestBuffer > 512 then
                -- We got some data — treat as done rather than fail silently
                requestState = "done"
            else
                errorMessage = "Connection timed out after 60 seconds."
                requestState = "error"
            end
        end
    end

    -- ── Send the HTTP request once the connection is open ──────────────────
    -- Written from a later update() frame (not from inside the SDK's open
    -- callback) so the TLS handshake has fully settled first.
    if requestState == "connecting" and connOpen and activeTcp then
        local wok, wsent, werr = pcall(function()
            return activeTcp:write(buildRequest(activeParsed))
        end)
        if wok and wsent then
            requestState = "reading"
        else
            Logger.log("doGet ERROR: write failed for " .. tostring(activeUrl) .. ": " .. tostring(werr or "?"))
            errorMessage = "Send failed: " .. tostring(werr or "?")
            requestState = "error"
        end
    end

    -- ── Pump incoming data ────────────────────────────────────────────────
    if requestState == "reading" and activeTcp and connOpen then
        local avail = nil
        pcall(function() avail = activeTcp:getBytesAvailable() end)
        if avail and avail > 0 then
            local chunk
            local okR = pcall(function() chunk = activeTcp:read(math.min(avail, READ_CHUNK)) end)
            if okR and type(chunk) == "string" and #chunk > 0 then
                if #requestBuffer < MAX_RESPONSE_SIZE then
                    requestBuffer = requestBuffer .. chunk
                end
                local tot = contentLength
                if not tot or tot < 0 then tot = 0 end
                if activeCallbacks and activeCallbacks.onProgress then
                    pcall(activeCallbacks.onProgress, #requestBuffer, tot)
                end
            else
                local terr = nil
                pcall(function() terr = activeTcp:getError() end)
                if terr and terr ~= "" and terr ~= "Connection closed" then
                    Logger.log("read error: " .. tostring(terr))
                end
            end
        end
    end

    -- ── Parse headers once they've fully arrived ──────────────────────────
    if requestState == "reading" and not bodyStart then
        if string.find(requestBuffer, "\r\n\r\n", 1, true) then
            parseHeaders()

            -- Redirect handling entirely in Lua (this is why we're on raw TCP)
            local loc = requestHeaders["location"]
            if requestStatus >= 300 and requestStatus < 400 and loc and loc ~= "" then
                redirectDepth = redirectDepth + 1
                if redirectDepth <= MAX_REDIRECTS then
                    pendingRedirectUrl = URL.resolve(activeUrl, loc)
                    pendingRedirectCallbacks = activeCallbacks
                    Logger.log("redirect " .. redirectDepth .. " -> " .. tostring(pendingRedirectUrl))
                else
                    Logger.log("redirect too many -> " .. tostring(activeUrl))
                    errorMessage = "Too many redirects to " .. tostring(activeUrl)
                    requestState = "error"
                end
                reset()  -- closes the TCP connection; redirect opens next tick
                return
            end
        end
    end

    -- ── Detect a complete body ────────────────────────────────────────────
    if requestState == "reading" and bodyStart then
        local bodyBytes = #requestBuffer - bodyStart + 1
        if isChunked then
            local dec = decodeChunked(string.sub(requestBuffer, bodyStart))
            if dec then requestState = "done" end
        elseif contentLength and contentLength >= 0 then
            if bodyBytes >= contentLength then requestState = "done" end
        end
        if #requestBuffer >= MAX_RESPONSE_SIZE then requestState = "done" end
    end

    -- ── Server closed the connection ──────────────────────────────────────
    if requestState == "reading" and connClosed then
        if #requestBuffer == 0 then
            errorMessage = "Connection closed before any data was received."
            requestState = "error"
        else
            requestState = "done"
        end
    end

    -- ── Handle completed request ─────────────────────────────────────────
    if requestState == "done" then
        local savedCallbacks = activeCallbacks
        local savedUrl       = activeUrl
        local savedStatus    = requestStatus
        local savedHeaders   = requestHeaders

        local body = requestBuffer
        if bodyStart then body = string.sub(requestBuffer, bodyStart) end
        if isChunked then
            local dec = decodeChunked(body)
            if dec then body = dec end
        end
        local savedBody = body

        reset()

        Logger.log("request done status=" .. tostring(savedStatus) .. " bytes=" .. tostring(#savedBody) .. " url=" .. tostring(savedUrl))

        if savedCallbacks and savedCallbacks.onSuccess then
            local ok, err = pcall(savedCallbacks.onSuccess, savedStatus, savedHeaders, savedBody, savedUrl)
            if not ok then
                print("ZQCB-ERR (onSuccess): " .. tostring(err))
                Logger.error("onSuccess dispatch: " .. tostring(err))
            end
        end

    elseif requestState == "error" then
        local savedCallbacks = activeCallbacks
        local savedUrl       = activeUrl
        local savedErr       = errorMessage or "Connection failed."

        reset()

        Logger.log("request ERROR: " .. tostring(savedErr) .. " url=" .. tostring(savedUrl))

        if savedCallbacks and savedCallbacks.onError then
            local ok, err = pcall(savedCallbacks.onError, savedErr)
            if not ok then
                print("ZQCB-ERR (onError): " .. tostring(err))
                Logger.error("onError dispatch: " .. tostring(err))
            end
        end
    end
end
