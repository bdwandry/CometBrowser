-- Cookie Jar for CometBrowser
-- RFC 6265 session management: parses Set-Cookie response headers, stores
-- cookies per domain/path, and re-attaches them to later requests so sites
-- (Wikipedia, forums, etc.) can keep you logged in across page loads.
import "core/logger"
import "core/storage"

CookieJar = {}

local MAX_COOKIES = 300

local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
}

local function trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

-- Howard Hinnant's days-from-civil algorithm, converted to epoch seconds.
local function makeTimestamp(year, month, day, hour, minute, second)
    year = math.max(0, math.floor(year))
    month = math.max(1, math.min(12, math.floor(month)))
    day = math.max(1, math.floor(day))
    local y = year - (month <= 2 and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = month + (month > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
end

-- Parse an RFC 6265 Expires date (IMF-fixdate / RFC 850 / asctime) into epoch
-- seconds, or nil if unrecognized.
local function parseDate(str)
    if not str or str == "" then return nil end
    str = trim(str)
    local d, mon, y, h, mi, s = string.match(str, "^%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
    if d then
        local m = MONTHS[mon]
        if m then
            return makeTimestamp(tonumber(y), m, tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
        end
    end
    d, mon, y, h, mi, s = string.match(str, "^%a+, (%d+)%-(%a+)%-(%d+) (%d+):(%d+):(%d+)")
    if d and MONTHS[mon] then
        local yy = tonumber(y)
        if yy < 70 then yy = yy + 2000 elseif yy < 100 then yy = yy + 1900 end
        return makeTimestamp(yy, MONTHS[mon], tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
    end
    mon, d, h, mi, s, y = string.match(str, "^%a+ (%a+) (%d+) (%d+):(%d+):(%d+) (%d+)")
    if y and MONTHS[mon] then
        return makeTimestamp(tonumber(y), MONTHS[mon], tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
    end
    return nil
end

local function nowSeconds()
    local ok, t = pcall(function() return playdate.getTime() end)
    if not ok or not t then return 0 end
    if t.secondsSinceEpoch then return t.secondsSinceEpoch end
    return makeTimestamp(t.year, t.month, t.day, t.hour, t.minute, t.second)
end

local function domainMatches(cookie, host)
    if cookie.hostOnly then return host == cookie.domain end
    local cd = cookie.domain
    return host == cd or string.sub(host, -#cd - 1) == "." .. cd
end

local function pathMatches(cookie, reqPath)
    local cpath = cookie.path or "/"
    local rp = reqPath or "/"
    if rp == cpath then return true end
    if string.sub(rp, 1, #cpath) == cpath then
        local tail = string.sub(rp, #cpath + 1, #cpath + 1)
        if string.sub(cpath, -1) == "/" or tail == "/" then return true end
    end
    return false
end

local function cookieKey(c)
    return ((c.hostOnly and "H:" or "D:") .. c.domain .. "|" .. (c.path or "/") .. "|" .. (c.name or ""))
end

-- Parse a single raw Set-Cookie header value into a cookie record, or nil if
-- it should be ignored entirely. Sets cookie.delete for Max-Age<=0 / past
-- Expires so the caller can remove the matching stored cookie.
function CookieJar.parseSetCookie(host, raw)
    if not host or not raw then return nil end
    local s = trim(raw)
    if s == "" then return nil end

    local first = s
    local rest = ""
    local semi = string.find(s, ";")
    if semi then
        first = string.sub(s, 1, semi - 1)
        rest = string.sub(s, semi + 1)
    end

    local name, value = string.match(first, "^%s*([^=;%s]+)%s*=%s*(.*)$")
    if not name then return nil end
    value = trim(value)
    -- Per RFC 6265, cookie names must be RFC 2616 tokens; values must be free
    -- of separators/control characters. Reject anything invalid outright.
    if string.find(name, "[^%w!#$%%&'*+%-%.%^_`|~]") then return nil end
    if string.find(value, "[;,%c]") or string.find(value, '["]') then return nil end

    local cookie = {
        name = name,
        value = value,
        domain = host,
        hostOnly = true,
        path = "/",
        secure = false,
        httpOnly = false,
        samesite = nil,
        expires = nil,
        delete = false
    }

    local domainRejected = false

    for attr in string.gmatch(rest, "[^;]+") do
        local a = trim(attr)
        if a ~= "" then
            local aname, avalue = string.match(a, "^%s*([^=%s]+)%s*=%s*(.-)%s*$")
            if not aname then
                aname = a
                avalue = ""
            end
            aname = string.lower(aname)
            if aname == "domain" then
                local d = string.lower(trim(avalue))
                d = string.gsub(d, "^%.", "")
                if d == host or string.sub(host, -#d - 1) == "." .. d then
                    if string.find(d, "%.") or d == "localhost" then
                        cookie.domain = d
                        cookie.hostOnly = false
                    end
                else
                    domainRejected = true
                end
            elseif aname == "path" then
                local p = avalue or "/"
                if string.sub(p, 1, 1) ~= "/" then p = "/" end
                cookie.path = p
            elseif aname == "secure" then
                cookie.secure = true
            elseif aname == "httponly" then
                cookie.httpOnly = true
            elseif aname == "samesite" then
                local ss = string.lower(avalue)
                if ss == "lax" or ss == "strict" or ss == "none" then cookie.samesite = ss end
            elseif aname == "max-age" then
                local ma = tonumber(avalue)
                if ma then
                    if ma <= 0 then
                        cookie.delete = true
                    else
                        cookie.expires = nowSeconds() + ma
                    end
                end
            elseif aname == "expires" then
                if not cookie.expires then
                    local ts = parseDate(avalue)
                    if ts then
                        if ts <= nowSeconds() then
                            cookie.delete = true
                        else
                            cookie.expires = ts
                        end
                    end
                end
            end
        end
    end
    if domainRejected then return nil end
    return cookie
end

-- Store (or delete) a cookie received from `host`.
function CookieJar.store(host, raw)
    local parsed = CookieJar.parseSetCookie(host, raw)
    if not parsed then return end

    local list = Storage.cookies or {}
    Storage.cookies = list
    local key = cookieKey(parsed)

    local i = 1
    while i <= #list do
        if cookieKey(list[i]) == key then
            if not parsed.delete and list[i].value == parsed.value and list[i].expires == parsed.expires then
                return
            end
            table.remove(list, i)
        else
            i = i + 1
        end
    end

    if not parsed.delete then
        list[#list + 1] = parsed
        while #list > MAX_COOKIES do table.remove(list, 1) end
    end
    Storage.save()
end

-- Process all Set-Cookie header values received in one response.
function CookieJar.processSetCookies(host, list)
    if not list or #list == 0 then return end
    for _, raw in ipairs(list) do
        CookieJar.store(host, raw)
    end
end

-- Build the value for a Cookie request header for the given host/path, or ""
-- when no cookies apply. Expired cookies are pruned lazily here.
function CookieJar.getHeader(host, path, isSsl)
    local now = nowSeconds()
    local list = Storage.cookies or {}
    local parts = {}
    local pruned = false
    local i = 1
    while i <= #list do
        local c = list[i]
        if (not c.name) or (not c.domain) or (c.expires and c.expires <= now) then
            table.remove(list, i)
            pruned = true
        else
            if domainMatches(c, host) and pathMatches(c, path or "/") and (not c.secure or isSsl) then
                parts[#parts + 1] = c.name .. "=" .. c.value
            end
            i = i + 1
        end
    end
    if pruned then Storage.save() end
    return table.concat(parts, "; ")
end

-- Drop expired / malformed cookies (called once at startup).
function CookieJar.prune()
    local list = Storage.cookies or {}
    local now = nowSeconds()
    local i = 1
    while i <= #list do
        local c = list[i]
        if (not c.name) or (not c.domain) or (c.expires and c.expires <= now) then
            table.remove(list, i)
        else
            i = i + 1
        end
    end
end

function CookieJar.clear()
    Storage.cookies = {}
    Storage.save()
end

function CookieJar.count()
    return #(Storage.cookies or {})
end
