-- Blazing Fast Single-Pass HTML Tokenizer & Parser for CometBrowser
import "core/tasks"
import "html/entities"

Tokenizer = {}

local MAX_HTML_SIZE = 262144 -- 256KB max buffer size

-- Find the closing ">" of a tag, ignoring ">" that appear inside quoted
-- attribute values. Uses a single character-class find per scan segment
-- instead of walking byte-by-byte, which is much faster on the device CPU.
local function findTagEnd(html, startPos)
    local i = startPos
    local n = #html
    while i <= n do
        local m = string.find(html, "[>\"']", i)
        if not m then return nil end
        local b = string.byte(html, m)
        if b == 62 then  -- '>'
            return m
        end
        -- Inside a quoted value: skip ahead to the matching close quote.
        local close = string.find(html, string.char(b), m + 1, true)
        if not close then return nil end
        i = close + 1
    end
    return nil
end

-- Parse tag attribute string into key/value table. Single pass with byte
-- checks instead of several full-pattern passes: the old gmatch-based version
-- backtracked pathologically on long URLs inside quotes and leaked bogus
-- query-param attributes out of quoted values.
local function parseAttributes(attrStr)
    local attrs = {}
    if not attrStr or attrStr == "" then return attrs end
    local n = #attrStr
    local i = 1
    while i <= n do
        local s = string.find(attrStr, "%S", i)
        if not s then break end
        i = s
        local ke = string.find(attrStr, "[^%w%-_:]", s)
        if not ke then ke = n + 1 end
        if ke == s then i = s + 1 else
            local key = string.sub(attrStr, s, ke - 1)
            if string.find(attrStr, "^%s*=", ke) then
                local vs = string.find(attrStr, "%S", ke + 1)
                if not vs then
                    -- key= with nothing after it
                    local lk = string.lower(key)
                    if attrs[lk] == nil then attrs[lk] = "" end
                    break
                end
                local c = string.byte(attrStr, vs)
                local lk = string.lower(key)
                if c == 34 then
                    local ve = string.find(attrStr, '"', vs + 1, true)
                    if not ve then break end
                    if attrs[lk] == nil then attrs[lk] = Entities.decode(string.sub(attrStr, vs + 1, ve - 1)) end
                    i = ve + 1
                elseif c == 39 then
                    local ve = string.find(attrStr, "'", vs + 1, true)
                    if not ve then break end
                    if attrs[lk] == nil then attrs[lk] = Entities.decode(string.sub(attrStr, vs + 1, ve - 1)) end
                    i = ve + 1
                else
                    local ve = string.find(attrStr, "[^%w%-_%.%/%?%#]", vs)
                    if not ve then ve = n + 1 end
                    if attrs[lk] == nil then attrs[lk] = Entities.decode(string.sub(attrStr, vs, ve - 1)) end
                    i = ve
                end
            else
                -- Boolean attribute (checked, selected, disabled, open, ...)
                local lk = string.lower(key)
                if attrs[lk] == nil then attrs[lk] = true end
                i = ke
            end
        end
    end
    return attrs
end

function Tokenizer.tokenize(html)
    local tokens = {}
    local pageTitle = "Web Page"
    if not html or html == "" then return tokens, pageTitle end

    if #html > MAX_HTML_SIZE then
        -- Cut at the last complete tag boundary so we never start/end mid-tag
        local cut = MAX_HTML_SIZE
        local lastGt = string.find(html, ">", math.max(1, cut - 128))
        if lastGt then cut = lastGt end
        html = string.sub(html, 1, cut)
    end

    local pos = 1
    local len = #html

    while pos <= len do
        Tasks.yieldCheck()
        Tasks.reportProgress(0.5 * (pos / len))

        local tagStart = string.find(html, "<", pos, true)
        if not tagStart then
            local text = string.sub(html, pos)
            if text ~= "" then
                table.insert(tokens, { type = "text", content = Entities.decode(text) })
            end
            break
        end

        -- Text before this tag
        if tagStart > pos then
            local text = string.sub(html, pos, tagStart - 1)
            if text ~= "" then
                table.insert(tokens, { type = "text", content = Entities.decode(text) })
            end
        end

        -- Find closing bracket of tag (respecting quotes in attribute values)
        local tagEnd = findTagEnd(html, tagStart + 1)
        if not tagEnd then
            -- Unterminated tag at end of buffer: drop the broken remainder instead
            -- of leaking raw HTML source into the page content
            break
        end

        local rawInside = string.sub(html, tagStart + 1, tagEnd - 1)
        rawInside = string.gsub(rawInside, "^%s*(.-)%s*$", "%1")

        -- Lowercase the first few bytes once and dispatch with plain string
        -- comparisons instead of running several case-insensitive patterns
        -- against every tag (this is a hot path for tag-heavy pages).
        local head = string.lower(string.sub(rawInside, 1, 8))

        -- 1. HTML Comments: <!-- ... -->
        if string.sub(rawInside, 1, 3) == "!--" then
            local commentEnd = string.find(html, "-->", tagStart, true)
            if commentEnd then
                pos = commentEnd + 3
            else
                pos = tagEnd + 1
            end

        -- 2. Skip <script> ... </script>
        elseif string.sub(head, 1, 6) == "script" then
            local scriptClose = string.find(html, "</[sS][cC][rR][iI][pP][tT]>", tagEnd, false)
            if scriptClose then
                local nextGt = string.find(html, ">", scriptClose, true)
                pos = (nextGt or scriptClose) + 1
            else
                pos = len + 1
            end

        -- 3. Skip <style> ... </style>
        elseif string.sub(head, 1, 5) == "style" then
            local styleClose = string.find(html, "</[sS][tT][yY][lL][eE]>", tagEnd, false)
            if styleClose then
                local nextGt = string.find(html, ">", styleClose, true)
                pos = (nextGt or styleClose) + 1
            else
                pos = len + 1
            end

        -- 4. Skip <svg> ... </svg>  and  <math> ... </math>
        elseif string.sub(head, 1, 3) == "svg" then
            local svgClose = string.find(html, "</[sS][vV][gG]>", tagEnd, false)
            if svgClose then
                local nextGt = string.find(html, ">", svgClose, true)
                pos = (nextGt or svgClose) + 1
            else
                pos = len + 1
            end
        elseif string.sub(head, 1, 4) == "math" then
            local mathClose = string.find(html, "</[mM][aA][tT][hH]>", tagEnd, false)
            if mathClose then
                local nextGt = string.find(html, ">", mathClose, true)
                pos = (nextGt or mathClose) + 1
            else
                pos = len + 1
            end

        -- 5. Page <title>
        elseif string.sub(head, 1, 5) == "title" then
            local titleClose = string.find(html, "</[tT][iI][tT][lL][eE]>", tagEnd, false)
            if titleClose then
                local titleText = string.sub(html, tagEnd + 1, titleClose - 1)
                titleText = string.gsub(titleText, "%s+", " ")
                titleText = string.gsub(titleText, "^%s*(.-)%s*$", "%1")
                pageTitle = Entities.decode(titleText)
                pos = titleClose + 8
            else
                pos = tagEnd + 1
            end

        -- 7. Normal Tag
        else
            local isClosing = (string.sub(rawInside, 1, 1) == "/")
            local tagBody = isClosing and string.sub(rawInside, 2) or rawInside
            tagBody = string.gsub(tagBody, "^%s*(.-)%s*$", "%1")

            local isSelfClosing = (string.sub(tagBody, -1) == "/" or isClosing)
            if string.sub(tagBody, -1) == "/" then
                tagBody = string.sub(tagBody, 1, -2)
            end

            local tagName = string.match(tagBody, "^([%w%-:]+)")
            if tagName then
                tagName = string.lower(tagName)
                local attrStr = string.sub(tagBody, #tagName + 1)
                local attrs = parseAttributes(attrStr)

                table.insert(tokens, {
                    type = "tag",
                    name = tagName,
                    isClosing = isClosing,
                    isSelfClosing = isSelfClosing,
                    attrs = attrs
                })
            end

            pos = tagEnd + 1
        end
    end

    return tokens, pageTitle
end
