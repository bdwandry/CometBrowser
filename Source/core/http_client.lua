-- HTTP/HTTPS Client for CometBrowser
-- Uses playdate.network.http.new(server, port, usessl, reason) per SDK 3.1.1 spec
import "core/url"
import "core/constants"

HttpClient = {}

local MAX_RESPONSE_SIZE = 2097152   -- 2 MB hard cap to prevent disk fill
local REQUEST_TIMEOUT_MS = 60000  -- 60 seconds total
local MAX_REDIRECTS       = 5

-- ── State ────────────────────────────────────────────────────────────────────
local activeConn      = nil
local activeCallbacks = nil
local activeUrl       = nil
local activeParsed    = nil

local requestState    = "idle"   -- idle | connecting | reading | done | error
local requestStatus   = 200
local requestBuffer   = ""
local activeFile      = nil
local cacheFilePath   = "cache/temp.html"
local requestHeaders  = {}
local errorMessage    = nil
local requestStart    = 0
local redirectCount   = 0
local bytesWritten    = 0

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
local function closeConn()
    if activeConn then
        local c = activeConn
        activeConn = nil
        pcall(function() c:close() end)
    end
end

local function reset()
    closeConn()
    activeCallbacks = nil
    activeUrl       = nil
    activeParsed    = nil
    requestHeaders  = {}
    if activeFile then
        pcall(function() activeFile:close() end)
        activeFile = nil
    end
    requestBuffer   = ""
    downloadPath = nil
    requestStatus   = 200
    requestState    = "idle"
    errorMessage    = nil
    redirectCount   = 0
end

-- ── Public API ───────────────────────────────────────────────────────────────
function HttpClient.cancel()
    reset()
end

function HttpClient.isLoading()
    return requestState == "connecting" or requestState == "reading"
end

function HttpClient.get(urlString, callbacks)
    -- Cancel any previous request cleanly
    HttpClient.cancel()

    callbacks        = callbacks or {}
    activeCallbacks  = callbacks
    activeUrl        = urlString
    requestState     = "connecting"
    requestStart     = playdate.getCurrentTimeMilliseconds()

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
        if callbacks.onError then callbacks.onError("Invalid URL (no hostname): " .. urlString) end
        reset()
        return false
    end

    -- ── Network availability check ────────────────────────────────────────
    local net = playdate.network
    if not net then
        if callbacks.onError then callbacks.onError("Networking not available.") end
        reset()
        return false
    end

    -- ── Open connection using correct SDK API ─────────────────────────────
    -- SDK: playdate.network.http.new(server, [port], [usessl], [reason])
    -- usessl = true enables TLS/HTTPS; default port 443 when usessl=true, else 80
    local conn, connErr
    local ok = pcall(function()
        -- Always use the single http.new API with the usessl flag
        conn = net.http.new(parsed.host, parsed.port, parsed.isSsl, "CometBrowser Web Browsing")
    end)

    if not ok or not conn then
        if callbacks.onError then
            callbacks.onError("Could not open connection to " .. parsed.host .. (connErr and (": " .. tostring(connErr)) or ""))
        end
        reset()
        return false
    end

    activeConn = conn

    -- Tune connection (do NOT setKeepAlive true — we close after each page)
    pcall(function() conn:setConnectTimeout(10) end)
    pcall(function() conn:setReadTimeout(40)    end)
    pcall(function() conn:setKeepAlive(false)   end)

    -- ── Callbacks (no close/blocking inside them) ─────────────────────────
    conn:setHeadersReadCallback(function()
        pcall(function()
            local st = conn:getResponseStatus()
            if st then requestStatus = st end
            local hdrs = conn:getResponseHeaders()
            if hdrs then requestHeaders = hdrs end
        end)
    end)

    conn:setRequestCallback(function()
        -- Called each time new data arrives; read available bytes
        pcall(function()
            requestState = "reading"
            local avail = conn:getBytesAvailable()
            if avail and avail > 0 then
                local chunk = conn:read(avail)
                if chunk then
                    if activeFile then
                        activeFile:write(chunk)
                    elseif #requestBuffer < MAX_RESPONSE_SIZE then
                        requestBuffer = requestBuffer .. chunk
                    end
                end
            end
            local cur, tot = conn:getProgress()
            if activeCallbacks and activeCallbacks.onProgress then
                activeCallbacks.onProgress(cur or #requestBuffer, tot or 0)
            end
        end)
    end)

    conn:setRequestCompleteCallback(function()
        -- Drain any remaining bytes
        pcall(function()
            local avail = conn:getBytesAvailable()
            if avail and avail > 0 then
                local chunk = conn:read(avail)
                if chunk then
                    if activeFile then
                        activeFile:write(chunk)
                    elseif #requestBuffer < MAX_RESPONSE_SIZE then
                        requestBuffer = requestBuffer .. chunk
                    end
                end
            end
        end)

        local err = pcall(function()
            local e = conn:getError()
            if e and e ~= "Connection closed" and e ~= "" and #requestBuffer == 0 then
                errorMessage = "Server error: " .. tostring(e)
                requestState = "error"
            else
                requestState = "done"
            end
        end)
        if not err then
            requestState = "done"
        end
    end)

    conn:setConnectionClosedCallback(function()
        if requestState ~= "done" and requestState ~= "error" then
            requestState = "done"
        end
    end)

    -- ── Send GET request ──────────────────────────────────────────────────
    local path = parsed.fullPath
    if not path or path == "" then path = "/" end

    -- NOTE: Do NOT include Host or Connection headers here.
    -- The Playdate SDK's http.new() adds Host automatically.
    -- Adding Host again causes duplicate headers → 400 Bad Request on strict servers.
    local headers = {
        ["User-Agent"]      = "CometBrowser/1.0 (Playdate)",
        ["Accept"]          = "text/html,text/plain;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9"
    }

    local sentOk, sendErr = conn:get(path, headers)
    if not sentOk then
        if callbacks.onError then
            callbacks.onError("GET failed for " .. parsed.host .. path .. ": " .. tostring(sendErr))
        end
        reset()
        return false
    end

    return true
end

-- ── Update: called every frame from main playdate.update() ───────────────────
function HttpClient.update()
    if requestState == "idle" then return end

    local now = playdate.getCurrentTimeMilliseconds()

    -- Timeout watchdog
    if requestState == "connecting" or requestState == "reading" then
        if now - requestStart > REQUEST_TIMEOUT_MS then
            if #requestBuffer > 512 then
                -- We got some data — treat as done rather than fail silently
                requestState = "done"
            else
                errorMessage = "Connection timed out after 20 seconds."
                requestState = "error"
            end
        end
    end

    -- ── Handle completed request ─────────────────────────────────────────
    if requestState == "done" then
        local savedConn      = activeConn
        local savedCallbacks = activeCallbacks
        local savedUrl       = activeUrl
        local savedBuffer    = requestBuffer
        local savedStatus    = requestStatus
        local savedHeaders   = requestHeaders

        -- Close file if saving
        if activeFile then
            pcall(function() activeFile:close() end)
            activeFile = nil
        end

        -- Close conn before dispatching callbacks
        activeConn = nil
        pcall(function() if savedConn then savedConn:close() end end)
        requestState = "idle"
        activeCallbacks = nil

        -- Follow redirects (301/302/303/307/308)
        if (savedStatus == 301 or savedStatus == 302 or savedStatus == 303 or savedStatus == 307 or savedStatus == 308) and redirectCount < MAX_REDIRECTS then
            local loc = savedHeaders["Location"] or savedHeaders["location"] or ""
            if loc ~= "" then
                redirectCount = redirectCount + 1
                local target = URL.resolve(savedUrl, loc)
                HttpClient.get(target, savedCallbacks)
                return
            end
        end

        if savedCallbacks and savedCallbacks.onSuccess then
            savedCallbacks.onSuccess(savedStatus, savedHeaders, savedBuffer, savedUrl)
        end

    elseif requestState == "error" then
        local savedConn      = activeConn
        local savedCallbacks = activeCallbacks
        local savedErr       = errorMessage or "Connection failed."

        activeConn = nil
        pcall(function() if savedConn then savedConn:close() end end)
        requestState    = "idle"
        activeCallbacks = nil

        if savedCallbacks and savedCallbacks.onError then
            savedCallbacks.onError(savedErr)
        end
    end
end
