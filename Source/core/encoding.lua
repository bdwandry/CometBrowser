-- Character encoding detection & conversion for CometBrowser.
--
-- The HTML spec prescribes a specific order of precedence:
--   1. Byte order mark (BOM) for UTF-8 / UTF-16LE / UTF-16BE
--   2. Transport-layer charset from the HTTP Content-Type header
--   3. <meta charset="..."> declaration (scanned in the first 1024 bytes)
--   4. <meta http-equiv="Content-Type" content="...; charset=...">
--   5. Default: windows-1252 (super-set of ASCII; the practical web default)
--
-- Lua strings are byte strings, so decoding is only required when the page is
-- NOT UTF-8. This module normalizes those encodings to UTF-8 (the format the
-- rest of the renderer assumes).

Encoding = {}

-- ── windows-1252 code points for bytes 0x80-0x9F ────────────────────────────
-- (bytes outside this range decode as Latin-1: byte N -> U+00NN)
local CP1252 = {
    [0x80] = 0x20AC, [0x81] = 0x0081, [0x82] = 0x201A, [0x83] = 0x0192,
    [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021,
    [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039,
    [0x8C] = 0x0152, [0x8D] = 0x008D, [0x8E] = 0x017D, [0x8F] = 0x008F,
    [0x90] = 0x0090, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9D] = 0x009D, [0x9E] = 0x017E, [0x9F] = 0x0178
}

-- ── UTF-8 encoding of a single code point ───────────────────────────────────
local function utf8Encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp < 0x110000 then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + (math.floor(cp / 0x1000) % 0x40),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return "?"
end

-- windows-1252 / iso-8859-1 / ascii byte string -> UTF-8
local function fromSingleByte(data)
    local out = {}
    local n = 0
    for i = 1, #data do
        local b = string.byte(data, i)
        local cp
        if b < 0x80 then
            cp = b
        elseif b >= 0xA0 then
            cp = b -- Latin-1 range
        else
            cp = CP1252[b] or b
        end
        n = n + 1
        out[n] = utf8Encode(cp)
    end
    return table.concat(out)
end

-- UTF-16 (big or little endian) byte string -> UTF-8
local function fromUtf16(data, littleEndian)
    local out = {}
    local n = 0
    local i = 1
    local function readUnit()
        if i + 1 > #data then return nil end
        local lo = string.byte(data, i)
        local hi = string.byte(data, i + 1)
        i = i + 2
        if littleEndian then
            return lo + hi * 256
        else
            return hi + lo * 256
        end
    end
    while true do
        local u = readUnit()
        if not u then break end
        if u >= 0xD800 and u <= 0xDBFF then
            local lo = readUnit()
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                local cp = 0x10000 + ((u - 0xD800) * 0x400) + (lo - 0xDC00)
                n = n + 1
                out[n] = utf8Encode(cp)
            else
                n = n + 1
                out[n] = "?"
            end
        elseif u >= 0xDC00 and u <= 0xDFFF then
            n = n + 1
            out[n] = "?"
        else
            n = n + 1
            out[n] = utf8Encode(u)
        end
    end
    return table.concat(out)
end

-- Normalize a charset name to a lower-cased canonical token.
local function normalizeCharset(name)
    if not name then return nil end
    name = string.lower(string.gsub(name, "[^%w]", ""))
    if name == "utf8" or name == "utf8mb4" then return "utf-8" end
    if name == "cp1252" or name == "windows1252" or name == "latin1"
        or name == "iso88591" or name == "iso8859" then return "cp1252" end
    if name == "utf16" or name == "utf16le" or name == "utf16be" then return name end
    if name == "ascii" or name == "usascii" then return "ascii" end
    if name == "shiftjis" or name == "sjis" then return "shift_jis" end
    return name
end

-- Scan the first `limit` bytes of an HTML document for a charset declaration.
local function scanMetaCharset(data, limit)
    local head = string.sub(data, 1, limit or 1024)
    local m = string.match(head, '<meta[^>]*charset%s*=%s*["\']?([%w%+%-_%.]+)')
    if m then return normalizeCharset(m) end
    m = string.match(head, '<meta[^>]*content%s*=%s*["\']?[^"\'>]*charset%s*=%s*["\']?([%w%+%-_%.]+)')
    if m then return normalizeCharset(m) end
    return nil
end

-- Extract charset from an HTTP Content-Type header value.
local function charsetFromHeader(contentType)
    if not contentType then return nil end
    local m = string.match(string.lower(contentType), "charset%s*=%s*([%w%+%-_%.]+)")
    if m then return normalizeCharset(m) end
    return nil
end

-- ── Public API ──────────────────────────────────────────────────────────────

-- Detect the document's character encoding and return a UTF-8 normalized copy.
-- headers may be nil; contentTypeHeaders is the Content-Type value string.
function Encoding.toUtf8(data, contentType)
    if not data or data == "" then return data end

    -- 1. Byte order mark.
    local b1, b2, b3 = string.byte(data, 1), string.byte(data, 2), string.byte(data, 3)
    if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
        return string.sub(data, 4)
    end
    if b1 == 0xFF and b2 == 0xFE then
        return fromUtf16(string.sub(data, 3), true)
    end
    if b1 == 0xFE and b2 == 0xFF then
        return fromUtf16(string.sub(data, 3), false)
    end

    -- 2. Transport charset.
    local cs = charsetFromHeader(contentType)

    -- 3/4. In-document <meta> declarations.
    if not cs or cs == "utf-8" then
        local meta = scanMetaCharset(data, 1024)
        if meta then cs = meta end
    end

    -- Anything we can't decode stays as-is (assumed UTF-8).
    if not cs then return data end
    if cs == "utf-8" or cs == "ascii" then return data end
    if cs == "cp1252" then return fromSingleByte(data) end
    if cs == "utf16le" then return fromUtf16(data, true) end
    if cs == "utf16be" then return fromUtf16(data, false) end

    -- Fallback for exotic encodings we cannot handle: attempt a best-effort
    -- single-byte decode so non-ASCII text still shows something readable.
    if cs == "shift_jis" or cs == "eucjp" or cs == "gbk" or cs == "big5" then
        return fromSingleByte(data)
    end
    return data
end
