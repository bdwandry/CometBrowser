-- HTML Entity Decoder & UTF-8 Sanitizer for Playdate ASCII Display
import "core/tasks"

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

    -- Fast path: the overwhelming majority of text runs and attribute values
    -- are plain ASCII with no entities. Skip all the gsub passes and the
    -- byte-by-byte loop below when there is nothing to decode.
    if not string.find(text, "[&\128-\255]") then
        return text
    end
    local hasAmp  = string.find(text, "&", 1, true)
    local hasHigh = string.find(text, "[\128-\255]")

    -- 1. Decode Decimal numeric entities &#123;
    if hasAmp then
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
        if not hasHigh then return text end
    end

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

    -- 5. Transliterate accented Latin characters to ASCII (keeps text readable
    --    on the Playdate font) and strip any remaining non-ASCII bytes.
    local T = {}
    local function M(cp, str) T[cp] = str end
    M(0xC0,"A") M(0xC1,"A") M(0xC2,"A") M(0xC3,"A") M(0xC4,"A") M(0xC5,"A") M(0xC6,"AE") M(0xC7,"C")
    M(0xC8,"E") M(0xC9,"E") M(0xCA,"E") M(0xCB,"E") M(0xCC,"I") M(0xCD,"I") M(0xCE,"I") M(0xCF,"I")
    M(0xD0,"D") M(0xD1,"N") M(0xD2,"O") M(0xD3,"O") M(0xD4,"O") M(0xD5,"O") M(0xD6,"O") M(0xD7,"x")
    M(0xD8,"O") M(0xD9,"U") M(0xDA,"U") M(0xDB,"U") M(0xDC,"U") M(0xDD,"Y") M(0xDE,"TH") M(0xDF,"ss")
    M(0xE0,"a") M(0xE1,"a") M(0xE2,"a") M(0xE3,"a") M(0xE4,"a") M(0xE5,"a") M(0xE6,"ae") M(0xE7,"c")
    M(0xE8,"e") M(0xE9,"e") M(0xEA,"e") M(0xEB,"e") M(0xEC,"i") M(0xED,"i") M(0xEE,"i") M(0xEF,"i")
    M(0xF0,"d") M(0xF1,"n") M(0xF2,"o") M(0xF3,"o") M(0xF4,"o") M(0xF5,"o") M(0xF6,"o") M(0xF7,"/")
    M(0xF8,"o") M(0xF9,"u") M(0xFA,"u") M(0xFB,"u") M(0xFC,"u") M(0xFD,"y") M(0xFE,"th") M(0xFF,"y")
    M(0x100,"A") M(0x101,"a") M(0x102,"A") M(0x103,"a") M(0x104,"A") M(0x105,"a")
    M(0x10C,"C") M(0x10D,"c") M(0x10E,"D") M(0x10F,"d") M(0x110,"D") M(0x111,"d")
    M(0x112,"E") M(0x113,"e") M(0x11A,"E") M(0x11B,"e")
    M(0x11E,"G") M(0x11F,"g") M(0x120,"G") M(0x121,"g")
    M(0x124,"H") M(0x125,"h") M(0x126,"H") M(0x127,"h")
    M(0x12A,"I") M(0x12B,"i") M(0x130,"I") M(0x131,"i")
    M(0x134,"J") M(0x135,"j") M(0x136,"K") M(0x137,"k") M(0x138,"k")
    M(0x13B,"L") M(0x13C,"l") M(0x13D,"L") M(0x13E,"l") M(0x141,"L") M(0x142,"l")
    M(0x143,"N") M(0x144,"n") M(0x145,"N") M(0x146,"n") M(0x147,"N") M(0x148,"n")
    M(0x150,"O") M(0x151,"o") M(0x152,"OE") M(0x153,"oe")
    M(0x154,"R") M(0x155,"r") M(0x158,"R") M(0x159,"r")
    M(0x15A,"S") M(0x15B,"s") M(0x15C,"S") M(0x15D,"s") M(0x15E,"S") M(0x15F,"s")
    M(0x160,"S") M(0x161,"s") M(0x162,"T") M(0x163,"t") M(0x164,"T") M(0x165,"t") M(0x166,"T") M(0x167,"t")
    M(0x16A,"U") M(0x16B,"u") M(0x16C,"U") M(0x16D,"u") M(0x16E,"U") M(0x16F,"u")
    M(0x170,"U") M(0x171,"u") M(0x172,"U") M(0x173,"u") M(0x174,"W") M(0x175,"w") M(0x176,"Y") M(0x177,"y") M(0x178,"Y")
    M(0x179,"Z") M(0x17A,"z") M(0x17B,"Z") M(0x17C,"z") M(0x17D,"Z") M(0x17E,"z")

    local cleanChars = {}
    local i = 1
    local n = #text
    while i <= n do
        Tasks.yieldCheck()

        local b = string.byte(text, i)
        if (b >= 32 and b <= 126) or b == 10 or b == 13 or b == 9 then
            table.insert(cleanChars, string.char(b))
            i = i + 1
        elseif b >= 192 and b <= 223 and i < n then
            local c = string.byte(text, i + 1)
            local cp = ((b % 0x20) * 64) + (c % 0x40)
            table.insert(cleanChars, T[cp] or " ")
            i = i + 2
        elseif b >= 224 and b <= 239 and i + 1 < n then
            table.insert(cleanChars, " ")
            i = i + 3
        else
            table.insert(cleanChars, " ")
            i = i + 1
        end
    end

    return table.concat(cleanChars)
end
