-- Blazing Fast Single-Pass HTML Tokenizer & Parser for CometBrowser
import "html/entities"

Tokenizer = {}

local MAX_HTML_SIZE = 131072 -- 128KB max buffer size

-- Find the closing ">" of a tag, ignoring ">" that appear inside quoted attribute values
local function findTagEnd(html, startPos)
    local i = startPos
    local quote = nil
    local n = #html
    while i <= n do
        local c = string.sub(html, i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == ">" then
            return i
        end
        i = i + 1
    end
    return nil
end

-- Parse tag attribute string into key/value table
local function parseAttributes(attrStr)
    local attrs = {}
    if not attrStr or attrStr == "" then return attrs end

    -- Match key="value", key='value', or key=value
    for key, val in string.gmatch(attrStr, '([%w%-_:]+)%s*=%s*"([^"]*)"') do
        attrs[string.lower(key)] = Entities.decode(val)
    end
    for key, val in string.gmatch(attrStr, "([%w%-_:]+)%s*=%s*'([^']*)'") do
        local lkey = string.lower(key)
        if not attrs[lkey] then
            attrs[lkey] = Entities.decode(val)
        end
    end
    for key, val in string.gmatch(attrStr, '([%w%-_:]+)%s*=%s*([%w%-_%.%/%?%#]+)') do
        local lkey = string.lower(key)
        if not attrs[lkey] then
            attrs[lkey] = Entities.decode(val)
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

        -- 1. HTML Comments: <!-- ... -->
        if string.sub(rawInside, 1, 3) == "!--" then
            local commentEnd = string.find(html, "-->", tagStart, true)
            if commentEnd then
                pos = commentEnd + 3
            else
                pos = tagEnd + 1
            end

        -- 2. Skip <script> ... </script>
        elseif string.match(rawInside, "^[sS][cC][rR][iI][pP][tT]") then
            local scriptClose = string.find(html, "</[sS][cC][rR][iI][pP][tT]>", tagEnd, false)
            if scriptClose then
                local nextGt = string.find(html, ">", scriptClose, true)
                pos = (nextGt or scriptClose) + 1
            else
                pos = len + 1
            end

        -- 3. Skip <style> ... </style>
        elseif string.match(rawInside, "^[sS][tT][yY][lL][eE]") then
            local styleClose = string.find(html, "</[sS][tT][yY][lL][eE]>", tagEnd, false)
            if styleClose then
                local nextGt = string.find(html, ">", styleClose, true)
                pos = (nextGt or styleClose) + 1
            else
                pos = len + 1
            end

        -- 4. Skip <svg> ... </svg>
        elseif string.match(rawInside, "^[sS][vV][gG]") then
            local svgClose = string.find(html, "</[sS][vV][gG]>", tagEnd, false)
            if svgClose then
                local nextGt = string.find(html, ">", svgClose, true)
                pos = (nextGt or svgClose) + 1
            else
                pos = len + 1
            end

        -- 5. Skip <noscript> ... </noscript>
        elseif string.match(rawInside, "^[nN][oO][sS][cC][rR][iI][pP][tT]") then
            local noscriptClose = string.find(html, "</[nN][oO][sS][cC][rR][iI][pP][tT]>", tagEnd, false)
            if noscriptClose then
                local nextGt = string.find(html, ">", noscriptClose, true)
                pos = (nextGt or noscriptClose) + 1
            else
                pos = len + 1
            end

        -- 6. Page <title>
        elseif string.match(rawInside, "^[tT][iI][tT][lL][eE]") then
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
