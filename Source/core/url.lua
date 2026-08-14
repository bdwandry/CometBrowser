-- URL Parser, Normalizer and Resolver for CometBrowser
URL = {}

-- URL Encode a string
function URL.encode(str)
    if not str then return "" end
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "+")
    return str
end

-- URL Decode a string
function URL.decode(str)
    if not str then return "" end
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

-- Check if an input looks like a search query vs a direct URL
function URL.isSearchQuery(input)
    if not input or input == "" then return false end
    input = string.gsub(input, "^%s*(.-)%s*$", "%1")
    
    -- If it starts with a known protocol or about:, it's a URL
    if string.match(input, "^https?://") or string.match(input, "^about:") or string.match(input, "^file://") then
        return false
    end
    
    -- If it contains spaces, it's a search query
    if string.find(input, "%s") then
        return true
    end
    
    -- If it's localhost or an IP address
    if string.match(input, "^localhost") or string.match(input, "^%d+%.%d+%.%d+%.%d+") then
        return false
    end
    
    -- If it contains a dot with common domain suffix / TLD or slashes
    if string.find(input, "%.") and not string.match(input, "^%.") and not string.match(input, "%.$") then
        return false
    end
    
    -- Otherwise treat as search query
    return true
end

-- Parse a URL string into components: { scheme, host, port, path, query, hash, isSsl }
function URL.parse(urlString)
    if not urlString or urlString == "" then
        return {
            raw = "",
            normalized = "about:blank",
            scheme = "about",
            host = "blank",
            port = 0,
            path = "/",
            query = "",
            hash = "",
            fullPath = "/",
            isSsl = true
        }
    end

    local raw = string.gsub(urlString, "^%s*(.-)%s*$", "%1")
    
    -- Handle special internal schemes
    if string.match(raw, "^about:") then
        local sub = string.sub(raw, 7)
        return {
            raw = raw,
            normalized = raw,
            scheme = "about",
            host = sub,
            port = 0,
            path = "/" .. sub,
            query = "",
            hash = "",
            fullPath = "/" .. sub,
            isSsl = true
        }
    end

    -- Default to https if no scheme provided
    local scheme, rest
    if string.match(raw, "^([a-zA-Z][%w+%-%.]*)://(.*)$") then
        scheme, rest = string.match(raw, "^([a-zA-Z][%w+%-%.]*)://(.*)$")
    else
        scheme = "https"
        rest = raw
    end
    scheme = string.lower(scheme)
    local isSsl = (scheme == "https")

    -- Split hash/anchor
    local hash = ""
    local hashIdx = string.find(rest, "#")
    if hashIdx then
        hash = string.sub(rest, hashIdx + 1)
        rest = string.sub(rest, 1, hashIdx - 1)
    end

    -- Split query string
    local query = ""
    local queryIdx = string.find(rest, "%?")
    if queryIdx then
        query = string.sub(rest, queryIdx + 1)
        rest = string.sub(rest, 1, queryIdx - 1)
    end

    -- Split host[:port] and path
    local hostPart, pathPart
    local slashIdx = string.find(rest, "/")
    if slashIdx then
        hostPart = string.sub(rest, 1, slashIdx - 1)
        pathPart = string.sub(rest, slashIdx)
    else
        hostPart = rest
        pathPart = "/"
    end

    if pathPart == "" then pathPart = "/" end

    -- Extract host and port
    local host = hostPart
    local port = isSsl and 443 or 80
    local colonIdx = string.find(hostPart, ":")
    if colonIdx then
        host = string.sub(hostPart, 1, colonIdx - 1)
        local customPort = tonumber(string.sub(hostPart, colonIdx + 1))
        if customPort and customPort > 0 then
            port = customPort
        end
    end
    host = string.lower(host)

    -- Normalized full URL
    local fullPath = pathPart
    if query ~= "" then fullPath = fullPath .. "?" .. query end
    if hash ~= "" then fullPath = fullPath .. "#" .. hash end
    
    local portStr = ""
    if (isSsl and port ~= 443) or (not isSsl and port ~= 80 and port ~= 0) then
        portStr = ":" .. tostring(port)
    end

    local normalized = string.format("%s://%s%s%s", scheme, host, portStr, fullPath)

    return {
        raw = raw,
        normalized = normalized,
        scheme = scheme,
        host = host,
        port = port,
        path = pathPart,
        query = query,
        hash = hash,
        fullPath = fullPath,
        isSsl = isSsl
    }
end

-- Resolve a relative URL against a base URL
function URL.resolve(baseUrlStr, relativeUrlStr)
    if not relativeUrlStr or relativeUrlStr == "" then
        return baseUrlStr
    end

    local rel = string.gsub(relativeUrlStr, "^%s*(.-)%s*$", "%1")
    
    -- Absolute URL with scheme
    if string.match(rel, "^[a-zA-Z][%w+%-%.]*://") or string.match(rel, "^about:") or string.match(rel, "^data:") or string.match(rel, "^javascript:") then
        return rel
    end

    local base = URL.parse(baseUrlStr)
    if base.scheme == "about" then
        return rel
    end

    -- Protocol-relative URL (e.g. //example.com/asset.png)
    if string.sub(rel, 1, 2) == "//" then
        return base.scheme .. ":" .. rel
    end

    -- Anchor-only URL (#section)
    if string.sub(rel, 1, 1) == "#" then
        return base.scheme .. "://" .. base.host .. (base.port ~= 80 and base.port ~= 443 and (":" .. base.port) or "") .. base.path .. (base.query ~= "" and ("?" .. base.query) or "") .. rel
    end

    -- Query-only URL (?key=val)
    if string.sub(rel, 1, 1) == "?" then
        return base.scheme .. "://" .. base.host .. (base.port ~= 80 and base.port ~= 443 and (":" .. base.port) or "") .. base.path .. rel
    end

    -- Root-relative URL (/path/to/page)
    if string.sub(rel, 1, 1) == "/" then
        local portStr = (base.port ~= 80 and base.port ~= 443) and (":" .. tostring(base.port)) or ""
        return string.format("%s://%s%s%s", base.scheme, base.host, portStr, rel)
    end

    -- Path-relative URL (sub/page.html or ../page.html)
    local basePath = base.path
    local dir = string.match(basePath, "^(.*/)") or "/"
    
    local combined = dir .. rel
    
    -- Normalize '.' and '..' segments
    local parts = {}
    for seg in string.gmatch(combined, "[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            table.insert(parts, seg)
        end
    end
    
    local resolvedPath = "/" .. table.concat(parts, "/")
    local portStr = (base.port ~= 80 and base.port ~= 443) and (":" .. tostring(base.port)) or ""
    return string.format("%s://%s%s%s", base.scheme, base.host, portStr, resolvedPath)
end

-- Build search query URL
function URL.buildSearchUrl(searchEngineUrl, queryText)
    return searchEngineUrl .. URL.encode(queryText)
end
