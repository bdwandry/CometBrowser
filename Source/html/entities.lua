-- HTML Entity Decoder & UTF-8 Sanitizer for Playdate ASCII Display
Entities = {}

local NAMED_ENTITIES = {
    ["quot"] = '"',
    ["amp"] = '&',
    ["apos"] = "'",
    ["lt"] = '<',
    ["gt"] = '>',
    ["nbsp"] = ' ',
    ["iexcl"] = '!',
    ["cent"] = 'c',
    ["pound"] = 'L',
    ["curren"] = '$',
    ["yen"] = 'Y',
    ["brvbar"] = '|',
    ["sect"] = '#',
    ["uml"] = '..',
    ["copy"] = '(c)',
    ["ordf"] = 'a',
    ["laquo"] = '<<',
    ["not"] = '~',
    ["shy"] = '',
    ["reg"] = '(R)',
    ["macr"] = '-',
    ["deg"] = ' deg',
    ["plusmn"] = '+/-',
    ["sup2"] = '^2',
    ["sup3"] = '^3',
    ["acute"] = "'",
    ["micro"] = 'u',
    ["para"] = 'P',
    ["middot"] = '*',
    ["cedil"] = ',',
    ["sup1"] = '^1',
    ["ordm"] = 'o',
    ["raquo"] = '>>',
    ["frac14"] = '1/4',
    ["frac12"] = '1/2',
    ["frac34"] = '3/4',
    ["iquest"] = '?',
    ["Agrave"] = 'A', ["Aacute"] = 'A', ["Acirc"] = 'A', ["Atilde"] = 'A', ["Auml"] = 'A', ["Aring"] = 'A',
    ["Egrave"] = 'E', ["Eacute"] = 'E', ["Ecirc"] = 'E', ["Euml"] = 'E',
    ["Igrave"] = 'I', ["Iacute"] = 'I', ["Icirc"] = 'I', ["Iuml"] = 'I',
    ["Ograve"] = 'O', ["Oacute"] = 'O', ["Ocirc"] = 'O', ["Otilde"] = 'O', ["Ouml"] = 'O',
    ["Ugrave"] = 'U', ["Uacute"] = 'U', ["Ucirc"] = 'U', ["Uuml"] = 'U',
    ["agrave"] = 'a', ["aacute"] = 'a', ["acirc"] = 'a', ["atilde"] = 'a', ["auml"] = 'a', ["aring"] = 'a',
    ["egrave"] = 'e', ["eacute"] = 'e', ["ecirc"] = 'e', ["euml"] = 'e',
    ["igrave"] = 'i', ["iacute"] = 'i', ["icirc"] = 'i', ["iuml"] = 'i',
    ["ograve"] = 'o', ["oacute"] = 'o', ["ocirc"] = 'o', ["otilde"] = 'o', ["ouml"] = 'o',
    ["ugrave"] = 'u', ["uacute"] = 'u', ["ucirc"] = 'u', ["uuml"] = 'u',
    ["mdash"] = ' -- ',
    ["ndash"] = ' - ',
    ["lsquo"] = "'",
    ["rsquo"] = "'",
    ["ldquo"] = '"',
    ["rdquo"] = '"',
    ["hellip"] = '...',
    ["prime"] = "'",
    ["Prime"] = '"',
    ["trade"] = '(TM)',
    ["bull"] = '*',
    ["euro"] = 'EUR',
    ["check"] = '[v]',
    ["cross"] = '[x]'
}

function Entities.decode(text)
    if not text or text == "" then return "" end

    -- 1. Decode Decimal numeric entities &#123;
    text = string.gsub(text, "&#(%d+);", function(dec)
        local num = tonumber(dec)
        if num == 160 or num == 8239 or num == 8201 or num == 8200 then return " " end
        if num == 8211 then return " - " end
        if num == 8212 then return " -- " end
        if num == 8216 or num == 8217 or num == 8218 then return "'" end
        if num == 8220 or num == 8221 or num == 8222 then return '"' end
        if num == 8230 then return "..." end
        if num == 8226 then return "*" end
        if num and num >= 32 and num <= 126 then
            return string.char(num)
        end
        return " "
    end)

    -- 2. Decode Hex numeric entities &#x1F;
    text = string.gsub(text, "&#[xX](%x+);", function(hex)
        local num = tonumber(hex, 16)
        if num == 0xA0 or num == 0x202F or num == 0x2009 then return " " end
        if num == 0x2013 then return " - " end
        if num == 0x2014 then return " -- " end
        if num == 0x2018 or num == 0x2019 then return "'" end
        if num == 0x201C or num == 0x201D then return '"' end
        if num == 0x2026 then return "..." end
        if num == 0x2022 then return "*" end
        if num and num >= 32 and num <= 126 then
            return string.char(num)
        end
        return " "
    end)

    -- 3. Decode Named entities &name;
    text = string.gsub(text, "&(%a+);", function(name)
        return NAMED_ENTITIES[name] or (" " .. name .. " ")
    end)

    -- 4. Clean common UTF-8 multi-byte sequences into ASCII
    text = string.gsub(text, "\xef\xbb\xbf", "")        -- BOM
    text = string.gsub(text, "\xc2\xa0", " ")           -- non-breaking space
    text = string.gsub(text, "\xe2\x80\x93", " - ")     -- en dash
    text = string.gsub(text, "\xe2\x80\x94", " -- ")    -- em dash
    text = string.gsub(text, "\xe2\x80\x98", "'")       -- left single quote
    text = string.gsub(text, "\xe2\x80\x99", "'")       -- right single quote
    text = string.gsub(text, "\xe2\x80\x9c", '"')       -- left double quote
    text = string.gsub(text, "\xe2\x80\x9d", '"')       -- right double quote
    text = string.gsub(text, "\xe2\x80\xa6", "...")     -- horizontal ellipsis
    text = string.gsub(text, "\xe2\x80\xa2", "*")       -- bullet
    text = string.gsub(text, "\xc2\xb7", "*")           -- middle dot

    -- 5. Strip any leftover unprintable non-ASCII bytes to keep Playdate text 100% clean
    local cleanChars = {}
    for i = 1, #text do
        local b = string.byte(text, i)
        if (b >= 32 and b <= 126) or b == 10 or b == 13 or b == 9 then
            table.insert(cleanChars, string.char(b))
        elseif b >= 192 then
            -- UTF-8 start byte: replace with space
            table.insert(cleanChars, " ")
        end
    end

    return table.concat(cleanChars)
end
