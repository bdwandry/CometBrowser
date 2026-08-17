-- HTML Document Object Model Builder for CometBrowser
import "core/tasks"
import "core/url"
import "html/tokenizer"
import "html/entities"
import "html/readability"
import "html/dom"
import "render/decoders/svg"

Document = {}

local MAX_BLOCKS = 1200
local MAX_INLINES = 900

-- ── Small parsing helpers ────────────────────────────────────────────────────
local function parseStyle(styleStr)
    local out = {}
    if not styleStr or styleStr == "" then return out end
    for k, v in string.gmatch(styleStr, "([%w%-]+)%s*:%s*([^;]+)") do
        out[string.lower(k)] = string.gsub(string.lower(v), "^%s*(.-)%s*$", "%1")
    end
    return out
end

local function parseAlign(attrs)
    if not attrs then return nil end
    local a = attrs["align"]
    local st = parseStyle(attrs["style"])
    if st["text-align"] then a = st["text-align"] end
    if not a then return nil end
    a = string.lower(a)
    if a == "center" or a == "right" or a == "left" then return a end
    return nil
end

-- CSS-driven visibility: hidden attribute, popover attribute, and the
-- style declarations display:none / visibility:hidden all suppress the
-- element AND its entire subtree.
local function isDisplayNone(attrs)
    if not attrs then return false end
    if attrs["hidden"] ~= nil then return true end
    if attrs["popover"] ~= nil then return true end
    local st = parseStyle(attrs["style"])
    local d = st["display"]
    if d and string.match(d, "none") then return true end
    local v = st["visibility"]
    if v and string.match(v, "hidden") then return true end
    return false
end

-- CSS-driven text inversion (1-bit approximation of color:white /
-- background-color:black). Returns true when text should render inverted.
local function isInvertedStyle(attrs)
    if not attrs then return false end
    local st = parseStyle(attrs["style"])
    local c = st["color"]
    local bg = st["background-color"] or st["background"]
    if c and (string.match(c, "white") or string.match(c, "%#fff") or string.match(c, "%#FFFF%w*")) then
        return true
    end
    if bg and (string.match(bg, "black") or string.match(bg, "%#000") or string.match(bg, "%#000000")) then
        return true
    end
    return false
end

-- CSS margin/padding extraction (pixel approximation). Returns top/bottom
-- spacing in px and left/right indent in px for a block element.
local function parseBoxSpacing(attrs)
    local out = { top = 0, bottom = 0, left = 0, right = 0 }
    if not attrs then return out end
    local st = parseStyle(attrs["style"])
    local function num(v)
        if not v then return nil end
        v = string.gsub(v, "%%", "")
        local n = tonumber(v)
        if not n then return nil end
        return math.floor(n / 2)
    end
    -- margin: all | v h | t r b l
    local m = st["margin"]
    if m then
        local t, r, b, l
        local parts = {}
        for p in string.gmatch(m, "[^%s,]+") do parts[#parts + 1] = p end
        if #parts == 1 then t, r, b, l = num(parts[1]), num(parts[1]), num(parts[1]), num(parts[1])
        elseif #parts == 2 then t, r, b, l = num(parts[1]), num(parts[2]), num(parts[1]), num(parts[2])
        elseif #parts == 3 then t, r, b, l = num(parts[1]), num(parts[2]), num(parts[3]), num(parts[2])
        elseif #parts == 4 then t, r, b, l = num(parts[1]), num(parts[2]), num(parts[3]), num(parts[4]) end
        if t then out.top = t end
        if b then out.bottom = b end
        if l then out.left = l end
        if r then out.right = r end
    else
        if st["margin-top"] then out.top = num(st["margin-top"]) or 0 end
        if st["margin-bottom"] then out.bottom = num(st["margin-bottom"]) or 0 end
        if st["margin-left"] then out.left = num(st["margin-left"]) or 0 end
        if st["margin-right"] then out.right = num(st["margin-right"]) or 0 end
    end
    local p = st["padding"]
    if p then
        local parts = {}
        for part in string.gmatch(p, "[^%s,]+") do parts[#parts + 1] = part end
        if #parts == 1 then
            out.left = out.left + (num(parts[1]) or 0)
        elseif #parts == 2 then
            out.left = out.left + (num(parts[2]) or 0)
        elseif #parts == 4 then
            out.left = out.left + (num(parts[4]) or 0)
        end
    else
        if st["padding-left"] then out.left = out.left + (num(st["padding-left"]) or 0) end
    end
    return out
end

-- Concatenate all descendant text of an element node (used for captions,
-- legends, summaries and option labels).
local function concatNodeText(node)
    local parts = {}
    local function rec(n)
        if n.kind == "text" then
            table.insert(parts, n.text or "")
        elseif n.kind == "element" then
            for _, c in ipairs(n.children) do rec(c) end
        end
    end
    rec(node)
    return table.concat(parts)
end

local function validHref(raw)
    if not raw or raw == "" then return false end
    if string.match(raw, "^#") then return false end
    if string.match(raw, "^[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]:") then return false end
    if string.match(raw, "^[Dd][Aa][Tt][Aa]:") then return false end
    return true
end

-- Serialize an inline <svg> DOM subtree back to XML for the SVG rasterizer.
local function serializeSvgNode(n)
    if n.kind == "text" then
        return Entities.encode(n.text or "")
    end
    if n.kind == "element" then
        local parts = { "<", n.tag }
        for k, v in pairs(n.attrs or {}) do
            local vv = string.gsub(v or "", '["<]', function(c)
                return (c == '"') and "&quot;" or "&lt;"
            end)
            parts[#parts + 1] = " " .. k .. '="' .. vv .. '"'
        end
        local children = n.children or {}
        if #children == 0 then
            parts[#parts + 1] = "/>"
        else
            parts[#parts + 1] = ">"
            for _, c in ipairs(children) do
                parts[#parts + 1] = serializeSvgNode(c)
            end
            parts[#parts + 1] = "</" .. n.tag .. ">"
        end
        return table.concat(parts)
    end
    return ""
end

function Document.parse(htmlString, baseUrl, mode, opts)
    opts = opts or {}
    if not htmlString or htmlString == "" then
        return {
            title = "Blank Page",
            baseUrl = baseUrl or "about:blank",
            rawHtml = "",
            isReaderMode = false,
            blocks = {},
            links = {}
        }
    end

    -- 1. Tokenize HTML
    local tokens, extractedTitle = Tokenizer.tokenize(htmlString)
    local pageTitle = extractedTitle or "Web Page"

    -- 2. If Reader Mode is requested, distill article using readability
    if mode == Constants.MODE_READER then
        local readerDoc = Readability.distill(tokens, pageTitle, baseUrl)
        readerDoc.rawHtml = htmlString
        return readerDoc
    end

    -- 3. HTML Mode: build a DOM tree and render every element in flow.
    local tree = DOM.build(tokens)

    -- Honor <base href="..."> when it points at an absolute URL.
    -- (Scanned from tokens: <head> is pruned during tree building.)
    local baseHref = nil
    for _, tok in ipairs(tokens) do
        if tok.type == "tag" and tok.name == "base" and not tok.isClosing then
            baseHref = (tok.attrs and tok.attrs["href"]) or ""
            if baseHref ~= "" then break end
        end
    end
    if baseHref and string.match(baseHref, "^[a-zA-Z][%w+%-%.]*://") then
        baseUrl = baseHref
    end

    -- Scan <meta http-equiv="refresh" content="N;url=..."> from tokens
    -- (same reason as <base>: <head> is pruned during tree building)
    local metaRefresh = nil
    for _, tok in ipairs(tokens) do
        if tok.type == "tag" and tok.name == "meta" and not tok.isClosing then
            local httpEquiv = tok.attrs and tok.attrs["http-equiv"]
            if httpEquiv and string.lower(httpEquiv) == "refresh" then
                local content = tok.attrs["content"] or ""
                local delayStr, urlStr = string.match(content, "^(%d+%.?%d*)%s*;%s*[Uu][Rr][Ll]=%s*(.+)$")
                if not delayStr then
                    delayStr = string.match(content, "^(%d+%.?%d*)%s*$")
                end
                if delayStr then
                    local refreshUrl = urlStr and string.match(urlStr, "^%s*(.-)%s*$") or nil
                    if refreshUrl and refreshUrl ~= "" then
                        refreshUrl = URL.resolve(baseUrl, refreshUrl)
                    else
                        refreshUrl = nil
                    end
                    metaRefresh = {
                        delay = tonumber(delayStr) or 0,
                        url = refreshUrl,
                    }
                    break
                end
            end
        end
    end

    local doc = {
        title = pageTitle,
        baseUrl = baseUrl,
        rawHtml = htmlString,
        isReaderMode = false,
        mode = mode or Constants.MODE_RAW_HTML,
        blocks = {},
        links = {},
        maps = {}
    }

    -- ── Walker state ───────────────────────────────────────────────────────
    local state = {
        blocks = doc.blocks,
        links = doc.links,

        -- Current inline formatting flags
        bold = false,
        italic = false,
        underline = false,
        code = false,
        small = false,
        big = false,
        sub = false,
        sup = false,
        mark = false,
        strike = false,
        invert = false,

        -- Link context
        currentHref = nil,
        currentAnchorIndex = nil,
        currentLinkText = "",
        anchorCounter = 0,

        -- Preformatted text
        inPre = false,
        preBuffer = "",

        -- Textareas
        inTextarea = false,
        textareaName = "",
        textareaBuffer = "",

        -- Lists & definition lists
        listContext = nil,
        dlDepth = 0,

        -- Tables
        table = nil,
        currentTableCell = nil,
        cellFirstText = false,

        -- Figures
        figure = nil,
        figureCaptionDone = false,

        -- Interactivity flags: inert subtree (non-interactive), disabled
        -- subtree (form controls disabled), truncated-page tracking
        inert = 0,
        disabledDepth = 0,
        truncated = false,

        -- Forms
        formAction = "",
        formMethod = "get",

        -- Nested bordered boxes (fieldset / details / dialog)
        boxStack = {},

        -- Interactive <details> elements: deterministic per-walk counter.
        -- opts.detailsOpen maps counter -> open override.
        detailsIndex = 0,

        -- MathML: linearized text fallback collected while inside <math>.
        inMath = false,
        mathParts = {},

        -- Meta refresh redirect: { delay = N, url = "..." }
        metaRefresh = nil,
    }

    local currentBlock = nil

    -- Forward declarations (mutually recursive walker)
    local walk
    local handleRow

    -- ── Block helpers ──────────────────────────────────────────────────────
    local function addBlock(blk)
        if blk and #doc.blocks < MAX_BLOCKS then
            table.insert(doc.blocks, blk)
            return true
        end
        state.truncated = state.truncated or (blk ~= nil)
        return false
    end

    local function flushCurrentBlock()
        if currentBlock then
            if currentBlock.type ~= "paragraph" or #currentBlock.inlines > 0 then
                addBlock(currentBlock)
            end
            currentBlock = nil
        end
    end

    local function ensureBlock()
        if not currentBlock then
            currentBlock = { type = "paragraph", inlines = {} }
        end
    end

    local function addInline(inlineObj)
        ensureBlock()
        if #currentBlock.inlines >= MAX_INLINES then return end
        table.insert(currentBlock.inlines, inlineObj)
    end

    local function snapshotStyle()
        return {
            bold = state.bold, italic = state.italic, underline = state.underline,
            code = state.code, small = state.small, big = state.big,
            sub = state.sub, sup = state.sup, mark = state.mark, strike = state.strike,
            invert = state.invert
        }
    end

    local function restoreStyle(s)
        state.bold = s.bold
        state.italic = s.italic
        state.underline = s.underline
        state.code = s.code
        state.small = s.small
        state.big = s.big
        state.sub = s.sub
        state.sup = s.sup
        state.mark = s.mark
        state.strike = s.strike
        state.invert = s.invert
    end

    local function addInlineText(raw)
        if not raw or raw == "" then return end
        local text = raw
        if not state.inPre then
            text = string.gsub(text, "[\r\n\t]+", " ")
        end
        if text == "" or string.match(text, "^%s+$") then return end

        if state.currentHref then
            state.currentLinkText = state.currentLinkText .. text
        end

        addInline({
            type = "text",
            text = text,
            bold = state.bold,
            italic = state.italic,
            underline = state.underline or (state.currentHref ~= nil),
            code = state.code,
            small = state.small,
            big = state.big,
            sub = state.sub,
            sup = state.sup,
            mark = state.mark,
            strike = state.strike,
            invert = state.invert,
            href = state.currentHref,
            anchorIndex = state.currentAnchorIndex,
            inert = (state.inert > 0)
        })
    end

    local function walkChildren(node)
        for _, c in ipairs(node.children or {}) do walk(c) end
    end

    -- ── Element / text handlers ────────────────────────────────────────────
    local function handleTextNode(node)
        local text = node.text or ""
        if state.inPre then
            state.preBuffer = state.preBuffer .. text
        elseif state.inTextarea then
            state.textareaBuffer = state.textareaBuffer .. text
        elseif state.currentTableCell then
            local txt = text
            if state.cellFirstText then
                txt = string.gsub(txt, "^%s+", "")
                state.cellFirstText = false
            end
            txt = string.gsub(txt, "[\r\n\t]+", " ")
            if txt ~= "" then
                table.insert(state.currentTableCell.inlines, {
                    type = "text",
                    text = txt,
                    bold = state.bold,
                    italic = state.italic,
                    underline = state.underline or (state.currentHref ~= nil),
                    code = state.code,
                    invert = state.invert,
                    href = state.currentHref,
                    anchorIndex = state.currentAnchorIndex,
                    inert = (state.inert > 0)
                })
                if state.currentHref then
                    state.currentLinkText = state.currentLinkText .. txt
                end
            end
        elseif state.figure and not state.figureCaptionDone then
            state.figure.caption = (state.figure.caption or "") .. text
        elseif state.inMath then
            state.mathParts[#state.mathParts + 1] = text
        else
            addInlineText(text)
        end
    end

    local function handleImage(attrs, node)
        local src = attrs["src"] or attrs["data-src"] or ""
        if src == "" and attrs["srcset"] then
            src = string.match(attrs["srcset"], "^([^%s,]+)") or ""
        end
        local alt = attrs["alt"] or attrs["title"] or "Image"
        local w = tonumber(attrs["width"]) or 160
        local h = tonumber(attrs["height"]) or 80
        if w <= 0 then w = 160 end
        if h <= 0 then h = 80 end

        if src ~= "" and not string.match(src, "tracking") and not string.match(src, "beacon") then
            if w > 360 then w = 360 end
            if h > 180 then h = 180 end
            local usemap = attrs["usemap"] or ""
            usemap = string.gsub(usemap, "^#", "")
            local imgBlock = {
                type = "image",
                src = URL.resolve(baseUrl, src),
                alt = alt,
                width = w,
                height = h,
                href = state.currentHref,
                align = parseAlign(attrs),
                usemap = usemap,
                inert = (state.inert > 0)
            }
            if state.figure then
                state.figure.image = imgBlock
            else
                flushCurrentBlock()
                addBlock(imgBlock)
            end
        end
    end

    local function collectSelectOptions(node, out)
        for _, c in ipairs(node.children or {}) do
            if c.kind == "element" then
                if c.tag == "option" then
                    local text = string.gsub(concatNodeText(c), "%s+", " ")
                    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
                    local label = c.attrs and c.attrs["label"] or ""
                    if label ~= "" then text = label end
                    table.insert(out, {
                        text = text,
                        value = (c.attrs and c.attrs["value"]) or text,
                        selected = (c.attrs and c.attrs["selected"]) ~= nil,
                        disabled = (c.attrs and c.attrs["disabled"]) ~= nil
                    })
                elseif c.tag == "optgroup" then
                    local groupLabel = c.attrs and c.attrs["label"] or ""
                    local childrenBefore = #out
                    collectSelectOptions(c, out)
                    if groupLabel ~= "" then
                        table.insert(out, childrenBefore + 1, {
                            text = groupLabel,
                            value = "",
                            group = true,
                            disabled = true
                        })
                    end
                end
            end
        end
    end

    local function handleElement(node)
        local tag = node.tag
        local attrs = node.attrs or {}

        -- ── Flow containers / paragraph-like blocks ───────────────────────
        if string.match(tag, "^h[1-6]$") then
            flushCurrentBlock()
            local level = tonumber(string.sub(tag, 2, 2)) or 1
            if state.currentTableCell then
                walkChildren(node)
            else
                local sp = parseBoxSpacing(attrs)
                currentBlock = {
                    type = "heading",
                    level = level,
                    inlines = {},
                    align = parseAlign(attrs),
                    spacingTop = sp.top,
                    spacingBottom = sp.bottom,
                    indent = sp.left,
                    invert = isInvertedStyle(attrs)
                }
                walkChildren(node)
                flushCurrentBlock()
            end

        elseif tag == "p" or tag == "div" or tag == "section" or tag == "article"
            or tag == "main" or tag == "header" or tag == "footer" or tag == "nav"
            or tag == "aside" or tag == "address" or tag == "hgroup" or tag == "noindex"
            or tag == "search" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            flushCurrentBlock()
            local sp = parseBoxSpacing(attrs)
            currentBlock = {
                type = "paragraph",
                inlines = {},
                align = parseAlign(attrs),
                spacingTop = sp.top,
                spacingBottom = sp.bottom,
                indent = sp.left,
                invert = isInvertedStyle(attrs)
            }
            walkChildren(node)
            flushCurrentBlock()

        elseif tag == "blockquote" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            flushCurrentBlock()
            local sp = parseBoxSpacing(attrs)
            currentBlock = {
                type = "blockquote", inlines = {}, align = parseAlign(attrs),
                spacingTop = sp.top, spacingBottom = sp.bottom,
                indent = sp.left + 12, invert = isInvertedStyle(attrs)
            }
            walkChildren(node)
            flushCurrentBlock()

        elseif tag == "center" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            flushCurrentBlock()
            currentBlock = { type = "paragraph", inlines = {}, align = "center",
                spacingTop = 0, spacingBottom = 0, indent = 0 }
            walkChildren(node)
            flushCurrentBlock()

        elseif tag == "marquee" then
            flushCurrentBlock()
            currentBlock = { type = "paragraph", inlines = {}, align = "center",
                spacingTop = 0, spacingBottom = 0, indent = 0 }
            walkChildren(node)
            flushCurrentBlock()

        -- ── Line breaks & rules ────────────────────────────────────────────
        elseif tag == "br" then
            if state.inPre then
                state.preBuffer = state.preBuffer .. "\n"
            elseif state.currentTableCell then
                table.insert(state.currentTableCell.inlines, { type = "br" })
            else
                addInline({ type = "br" })
            end

        elseif tag == "wbr" then
            -- Potential break point: treated as a soft space-less break hint.
            addInline({ type = "wbr" })

        elseif tag == "hr" then
            if not state.currentTableCell then
                flushCurrentBlock()
                addBlock({ type = "hr" })
            end

        -- ── Preformatted text & inline code ────────────────────────────────
        elseif tag == "pre" or tag == "xmp" or tag == "listing" or tag == "plaintext" then
            flushCurrentBlock()
            state.inPre = true
            state.preBuffer = ""
            if tag == "pre" then
                walkChildren(node)
            else
                -- Legacy raw-text blocks: concatenate all descendant text.
                state.preBuffer = concatNodeText(node)
            end
            state.inPre = false
            if state.preBuffer ~= "" then
                local lines = {}
                for l in string.gmatch(state.preBuffer .. "\n", "(.-)\r?\n") do
                    table.insert(lines, l)
                end
                addBlock({ type = "code_block", text = state.preBuffer, lines = lines })
                state.preBuffer = ""
            end

        -- ── Script fallback / inert containers ─────────────────────────────
        -- Scripting is disabled, so noscript content is shown (per spec);
        -- noembed and noframes are fallbacks we also render since we can't
        -- run embeds or frames. slot/flight fall through to render children.
        elseif tag == "noscript" or tag == "noembed" or tag == "noframes" or tag == "slot" then
            walkChildren(node)

        -- ── Inline formatting ──────────────────────────────────────────────
        elseif tag == "b" or tag == "strong" then
            local s = snapshotStyle(); state.bold = true; walkChildren(node); restoreStyle(s)
        elseif tag == "i" or tag == "em" or tag == "cite" or tag == "var" or tag == "dfn" then
            local s = snapshotStyle(); state.italic = true; walkChildren(node); restoreStyle(s)
        elseif tag == "u" or tag == "ins" then
            local s = snapshotStyle(); state.underline = true; walkChildren(node); restoreStyle(s)
        elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
            local s = snapshotStyle(); state.code = true; walkChildren(node); restoreStyle(s)
        elseif tag == "mark" then
            local s = snapshotStyle(); state.mark = true; state.bold = true; walkChildren(node); restoreStyle(s)
        elseif tag == "small" then
            local s = snapshotStyle(); state.small = true; walkChildren(node); restoreStyle(s)
        elseif tag == "big" then
            local s = snapshotStyle(); state.big = true; walkChildren(node); restoreStyle(s)
        elseif tag == "sub" then
            local s = snapshotStyle(); state.sub = true; state.small = true; walkChildren(node); restoreStyle(s)
        elseif tag == "sup" then
            local s = snapshotStyle(); state.sup = true; state.small = true; walkChildren(node); restoreStyle(s)
        elseif tag == "del" or tag == "s" or tag == "strike" then
            local s = snapshotStyle(); state.strike = true; walkChildren(node); restoreStyle(s)
        elseif tag == "q" then
            local function qQuote()
                if state.currentTableCell then
                    table.insert(state.currentTableCell.inlines, {
                        type = "text", text = '"', bold = state.bold, italic = state.italic,
                        href = state.currentHref, anchorIndex = state.currentAnchorIndex
                    })
                else
                    addInline({ type = "text", text = '"', bold = state.bold, italic = state.italic })
                end
            end
            qQuote()
            walkChildren(node)
            qQuote()
        elseif tag == "abbr" or tag == "acronym" then
            walkChildren(node)

        -- Elements that carry style attributes (span, font, time, data, ...)
        elseif tag == "span" or tag == "font" or tag == "time" or tag == "data"
            or tag == "bdi" or tag == "bdo" or tag == "label" or tag == "output"
            or tag == "legend" or tag == "summary" then
            local s = snapshotStyle()
            local st = parseStyle(attrs["style"])
            if st["font-weight"] == "bold" or st["font-weight"] == "bolder" or st["font-weight"] == "700" then
                state.bold = true
            end
            if st["font-style"] == "italic" then state.italic = true end
            if st["text-decoration"] then
                if string.find(st["text-decoration"], "underline") then state.underline = true end
                if string.find(st["text-decoration"], "line%-through") then state.strike = true end
            end
            if tag == "font" and attrs["size"] then
                local sz = attrs["size"]
                local n = tonumber(sz)
                if sz == "+1" or (n and n >= 5) then
                    state.big = true
                elseif sz == "-1" or sz == "-2" or (n and n <= 3) then
                    state.small = true
                end
            end
            if isInvertedStyle(attrs) then state.invert = true end
            local hadInline = #(currentBlock and currentBlock.inlines or {})
            walkChildren(node)
            -- <time datetime> and <data value> show their machine value when
            -- the element carries no visible text.
            local fallback = (tag == "time" and attrs["datetime"]) or (tag == "data" and attrs["value"])
            if fallback and (not currentBlock or #currentBlock.inlines == hadInline) then
                addInline({ type = "text", text = fallback, bold = state.bold, italic = state.italic })
            end
            restoreStyle(s)

        elseif tag == "ruby" then
            walkChildren(node)
        elseif tag == "rt" then
            local s = snapshotStyle(); state.small = true; walkChildren(node); restoreStyle(s)
        elseif tag == "rp" then
            -- Ruby fallback punctuation: shown as-is when ruby annotations are
            -- not supported (we render rt inline, so rp shows the parens).
            walkChildren(node)
        elseif tag == "rb" or tag == "rtc" then
            walkChildren(node)

        -- ── Links ──────────────────────────────────────────────────────────
        elseif tag == "a" then
            local rawHref = attrs["href"]
            if validHref(rawHref) then
                state.currentHref = URL.resolve(baseUrl, rawHref)
                state.anchorCounter = state.anchorCounter + 1
                state.currentAnchorIndex = state.anchorCounter
                state.currentLinkText = ""
            end
            walkChildren(node)
            if state.currentHref then
                local linkText = state.currentLinkText
                if linkText == "" and attrs["title"] then
                    linkText = attrs["title"]
                end
                table.insert(doc.links, {
                    href = state.currentHref,
                    text = linkText ~= "" and linkText or state.currentHref,
                    target = attrs["target"] or nil
                })
            end
            state.currentHref = nil
            state.currentAnchorIndex = nil
            state.currentLinkText = ""

        -- ── Lists ──────────────────────────────────────────────────────────
        elseif tag == "ul" or tag == "ol" or tag == "menu" or tag == "dir" then
            local saved = state.listContext
            local ordered = (tag == "ol")
            local ctx = {
                type = tag,
                ordered = ordered,
                count = 0,
                depth = (saved and saved.depth or 0) + 1
            }
            if ordered then
                ctx.start = tonumber(attrs["start"]) or 1
                ctx.reversed = (attrs["reversed"] ~= nil)
                local t = attrs["type"] or "1"
                if t == "a" or t == "A" or t == "i" or t == "I" or t == "1" then
                    ctx.markerType = t
                else
                    ctx.markerType = "1"
                end
            else
                ctx.start = 1
                ctx.reversed = false
                ctx.markerType = "1"
            end
            state.listContext = ctx
            walkChildren(node)
            state.listContext = saved

        elseif tag == "li" then
            flushCurrentBlock()
            local ctx = state.listContext or { type = "ul", ordered = false, count = 0, depth = 1 }
            local number
            if attrs["value"] then
                number = tonumber(attrs["value"]) or (ctx.start or 1)
                -- Per spec the value attr renumbers this and subsequent items.
                ctx.start = (ctx.reversed and (number - 1)) or (number + 1)
                ctx.count = 0
            else
                ctx.count = ctx.count + 1
                number = ctx.reversed and (ctx.start - (ctx.count - 1)) or (ctx.start + ctx.count - 1)
            end
            currentBlock = {
                type = "list_item",
                isOrdered = ctx.ordered,
                number = number,
                markerType = ctx.markerType or "1",
                depth = ctx.depth,
                inlines = {}
            }
            walkChildren(node)
            flushCurrentBlock()

        elseif tag == "dl" then
            state.dlDepth = state.dlDepth + 1
            walkChildren(node)
            state.dlDepth = state.dlDepth - 1

        elseif tag == "dt" then
            flushCurrentBlock()
            currentBlock = {
                type = "list_item",
                isOrdered = false,
                number = nil,
                depth = state.dlDepth,
                dt = true,
                inlines = {}
            }
            walkChildren(node)
            flushCurrentBlock()

        elseif tag == "dd" then
            flushCurrentBlock()
            currentBlock = {
                type = "list_item",
                isOrdered = false,
                number = nil,
                depth = state.dlDepth,
                dd = true,
                inlines = {}
            }
            walkChildren(node)
            flushCurrentBlock()

        -- ── Images & figures ───────────────────────────────────────────────
        elseif tag == "img" then
            handleImage(attrs, node)

        elseif tag == "picture" then
            walkChildren(node)

        elseif tag == "figure" then
            flushCurrentBlock()
            local saved = state.figure
            state.figure = { caption = "", image = nil }
            state.figureCaptionDone = true
            walkChildren(node)
            if state.figure and state.figure.image then
                local cap = string.gsub(state.figure.caption or "", "%s+", " ")
                cap = string.gsub(cap, "^%s*(.-)%s*$", "%1")
                if cap ~= "" then
                    state.figure.image.alt = cap
                    state.figure.image.caption = cap
                end
                flushCurrentBlock()
                addBlock(state.figure.image)
            elseif state.figure and state.figure.caption and string.gsub(state.figure.caption, "%s", "") ~= "" then
                flushCurrentBlock()
                addBlock({
                    type = "paragraph",
                    align = "center",
                    inlines = { { type = "text", text = state.figure.caption, italic = true } }
                })
            end
            state.figure = saved

        elseif tag == "figcaption" then
            state.figureCaptionDone = false
            walkChildren(node)
            state.figureCaptionDone = true

        -- ── Tables ─────────────────────────────────────────────────────────
        elseif tag == "table" then
            flushCurrentBlock()
            if state.currentTableCell then
                return
            end
            local tbl = {
                type = "table",
                rows = {},
                caption = "",
                align = parseAlign(attrs),
                border = (attrs["border"] ~= nil and attrs["border"] ~= "0"),
                width = attrs["width"]
            }
            state.table = tbl

            for _, c in ipairs(node.children or {}) do
                if c.kind == "element" then
                    if c.tag == "caption" then
                        local cap = string.gsub(concatNodeText(c), "%s+", " ")
                        tbl.caption = string.gsub(cap, "^%s*(.-)%s*$", "%1")
                    elseif c.tag == "tr" then
                        handleRow(c, tbl)
                    elseif c.tag == "thead" or c.tag == "tbody" or c.tag == "tfoot" then
                        for _, r in ipairs(c.children or {}) do
                            if r.kind == "element" and r.tag == "tr" then
                                handleRow(r, tbl)
                            end
                        end
                    end
                end
            end

            state.table = nil
            if #tbl.rows > 0 then
                addBlock(tbl)
            end

        elseif tag == "tr" then
            if state.table then handleRow(node, state.table) end

        elseif tag == "td" or tag == "th" then
            -- Cells are processed by handleRow; stray cells are ignored.

        -- ── Forms ──────────────────────────────────────────────────────────
        elseif tag == "form" then
            local savedAction = state.formAction
            local savedMethod = state.formMethod
            state.formAction = URL.resolve(baseUrl, attrs["action"] or "")
            state.formMethod = string.lower(attrs["method"] or "get")
            walkChildren(node)
            state.formAction = savedAction
            state.formMethod = savedMethod

        elseif tag == "input" then
            local inputType = string.lower(attrs["type"] or "text")
            local inputName = attrs["name"] or "q"
            local inputVal  = attrs["value"] or ""
            local placeholder = attrs["placeholder"] or attrs["aria-label"] or ""
            local isChecked = (attrs["checked"] ~= nil)
            local disabled = (attrs["disabled"] ~= nil) or (state.disabledDepth > 0)
            local readonly = (attrs["readonly"] ~= nil) or disabled
            local required = (attrs["required"] ~= nil)
            local maxlength = tonumber(attrs["maxlength"])
            local size = tonumber(attrs["size"])
            local formAction = state.formAction
            local formMethod = state.formMethod
            if attrs["formaction"] then formAction = URL.resolve(baseUrl, attrs["formaction"]) end
            if attrs["formmethod"] then formMethod = string.lower(attrs["formmethod"]) end

            local function common(extra)
                extra.formAction = formAction
                extra.formMethod = formMethod
                extra.disabled = disabled
                extra.readonly = readonly
                extra.required = required
                extra.maxlength = maxlength
                extra.inert = (state.inert > 0) or disabled
                return extra
            end

            if inputType == "hidden" then
                flushCurrentBlock()
                addBlock(common({
                    type = "hidden_field",
                    name = inputName,
                    value = inputVal,
                }))
                return
            elseif inputType == "checkbox" or inputType == "radio" then
                flushCurrentBlock()
                addBlock(common({
                    type = "checkbox_field",
                    radio = (inputType == "radio"),
                    checked = isChecked,
                    name = inputName,
                    value = inputVal,
                    label = attrs["label"] or attrs["title"] or placeholder or inputName
                }))
            elseif inputType == "text" or inputType == "search" or inputType == "email"
                or inputType == "url" or inputType == "number" or inputType == "password"
                or inputType == "tel" or inputType == "date" or inputType == "time"
                or inputType == "month" or inputType == "week" or inputType == "datetime-local"
                or inputType == "color" then
                flushCurrentBlock()
                addBlock(common({
                    type = "input_field",
                    inputType = inputType,
                    name = inputName,
                    value = inputVal,
                    placeholder = placeholder,
                    fieldWidth = size
                }))
            elseif inputType == "submit" or inputType == "button" then
                flushCurrentBlock()
                addBlock(common({
                    type = "input_submit",
                    name = inputName,
                    value = inputVal,
                    label = inputVal ~= "" and inputVal or (inputType == "button" and "Button" or "Submit")
                }))
            elseif inputType == "file" or inputType == "reset" or inputType == "image" then
                flushCurrentBlock()
                addBlock(common({
                    type = "input_submit",
                    name = inputName,
                    value = inputVal,
                    label = inputVal ~= "" and inputVal or (inputType == "file" and "Choose File" or (inputType == "reset" and "Reset" or "Submit"))
                }))
            end

        elseif tag == "textarea" then
            flushCurrentBlock()
            state.inTextarea = true
            state.textareaName = attrs["name"] or "q"
            state.textareaBuffer = ""
            walkChildren(node)
            state.inTextarea = false
            local disabled = (attrs["disabled"] ~= nil) or (state.disabledDepth > 0)
            addBlock({
                type = "input_field",
                inputType = "textarea",
                name = state.textareaName,
                value = state.textareaBuffer,
                placeholder = attrs["placeholder"] or "",
                fieldWidth = tonumber(attrs["cols"]),
                fieldRows = tonumber(attrs["rows"]),
                disabled = disabled,
                readonly = (attrs["readonly"] ~= nil) or disabled,
                required = (attrs["required"] ~= nil),
                maxlength = tonumber(attrs["maxlength"]),
                formAction = state.formAction,
                formMethod = state.formMethod,
                inert = (state.inert > 0) or disabled
            })
            state.textareaBuffer = ""

        elseif tag == "button" then
            local btype = string.lower(attrs["type"] or "submit")
            if btype == "submit" or btype == "button" then
                local label = string.gsub(concatNodeText(node), "%s+", " ")
                label = string.gsub(label, "^%s*(.-)%s*$", "%1")
                local disabled = (attrs["disabled"] ~= nil) or (state.disabledDepth > 0)
                flushCurrentBlock()
                addBlock({
                    type = "input_submit",
                    name = attrs["name"],
                    value = attrs["value"],
                    label = label ~= "" and label or (btype == "button" and "Button" or "Submit"),
                    disabled = disabled,
                    formAction = attrs["formaction"] and URL.resolve(baseUrl, attrs["formaction"]) or state.formAction,
                    formMethod = attrs["formmethod"] and string.lower(attrs["formmethod"]) or state.formMethod,
                    inert = (state.inert > 0) or disabled
                })
            end

        elseif tag == "select" then
            flushCurrentBlock()
            local opts = {}
            collectSelectOptions(node, opts)
            local selIndex = 1
            for i, o in ipairs(opts) do
                if o.selected and not o.disabled then selIndex = i end
            end
            if #opts > 0 then
                addBlock({
                    type = "select_field",
                    name = attrs["name"] or "q",
                    options = opts,
                    selectedIndex = selIndex,
                    multiple = (attrs["multiple"] ~= nil),
                    disabled = (attrs["disabled"] ~= nil) or (state.disabledDepth > 0),
                    required = (attrs["required"] ~= nil),
                    formAction = state.formAction,
                    formMethod = state.formMethod,
                    inert = (state.inert > 0) or (attrs["disabled"] ~= nil)
                })
            end

        -- ── Bordered boxes ─────────────────────────────────────────────────
        elseif tag == "fieldset" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            flushCurrentBlock()
            local label = ""
            for _, c in ipairs(node.children or {}) do
                if c.kind == "element" and c.tag == "legend" then
                    label = string.gsub(concatNodeText(c), "%s+", " ")
                    label = string.gsub(label, "^%s*(.-)%s*$", "%1")
                    break
                end
            end
            addBlock({ type = "box_open", label = label })
            local wasDisabled = state.disabledDepth
            if attrs["disabled"] ~= nil then state.disabledDepth = state.disabledDepth + 1 end
            for _, c in ipairs(node.children or {}) do
                if not (c.kind == "element" and c.tag == "legend") then walk(c) end
            end
            state.disabledDepth = wasDisabled
            addBlock({ type = "box_close" })

        elseif tag == "details" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            flushCurrentBlock()
            state.detailsIndex = state.detailsIndex + 1
            local dkey = "d" .. tostring(state.detailsIndex)
            local label = ""
            for _, c in ipairs(node.children or {}) do
                if c.kind == "element" and c.tag == "summary" then
                    label = string.gsub(concatNodeText(c), "%s+", " ")
                    label = string.gsub(label, "^%s*(.-)%s*$", "%1")
                    break
                end
            end
            local defaultOpen = (attrs["open"] ~= nil)
            local isOpen = defaultOpen
            if opts.detailsOpen and opts.detailsOpen[dkey] ~= nil then
                isOpen = opts.detailsOpen[dkey]
            end
            addBlock({
                type = "box_open",
                label = (label ~= "" and ("> " .. label) or ""),
                toggleKey = dkey,
                toggleOpen = isOpen
            })
            if isOpen then
                for _, c in ipairs(node.children or {}) do
                    if not (c.kind == "element" and c.tag == "summary") then walk(c) end
                end
            end
            addBlock({ type = "box_close", toggleKey = dkey, toggleOpen = isOpen })

        elseif tag == "dialog" then
            if state.currentTableCell then
                walkChildren(node)
                return
            end
            -- A dialog without the open attribute is not rendered at all.
            if attrs["open"] == nil then
                return
            end
            flushCurrentBlock()
            addBlock({ type = "box_open", label = "" })
            walkChildren(node)
            addBlock({ type = "box_close" })

        -- ── Media placeholders ─────────────────────────────────────────────
        elseif tag == "video" or tag == "audio" or tag == "iframe" or tag == "canvas"
            or tag == "object" or tag == "embed" or tag == "portal" then
            flushCurrentBlock()
            local src = attrs["src"] or attrs["data"]
            if src == "" or not src then
                -- Look for the first <source src="..."> child.
                for _, c in ipairs(node.children or {}) do
                    if c.kind == "element" and c.tag == "source" and c.attrs and c.attrs["src"] then
                        src = c.attrs["src"]
                        break
                    end
                end
            end
            local label = attrs["title"] or attrs["alt"] or ""
            if label == "" then
                if src and src ~= "" then
                    local base = string.match(src, "([^/]+)/?$") or src
                    label = "[" .. tag .. ": " .. base .. "]"
                else
                    label = "[" .. tag .. "]"
                end
            end
            local w = tonumber(attrs["width"]) or 160
            local h = tonumber(attrs["height"]) or 60
            if w > 360 then w = 360 end
            if h > 120 then h = 120 end
            local ph = { type = "placeholder", label = label, width = w, height = h, tag = tag }
            if (tag == "iframe" or tag == "portal") and src and src ~= "" and validHref(src) then
                ph.href = URL.resolve(baseUrl, src)
            end
            addBlock(ph)

        elseif tag == "progress" or tag == "meter" then
            flushCurrentBlock()
            local value = tonumber(attrs["value"]) or 0
            local max = tonumber(attrs["max"]) or 1
            if max <= 0 then max = 1 end
            addBlock({
                type = "meter",
                value = value,
                max = max,
                min = tonumber(attrs["min"]) or 0,
                low = tonumber(attrs["low"]) or 0,
                high = tonumber(attrs["high"]) or max,
                optimum = tonumber(attrs["optimum"]) or 0,
                label = attrs["title"] or ""
            })

        elseif tag == "map" then
            -- Image map: not rendered, but its <area> regions are collected so
            -- images referencing it via usemap can be made clickable.
            local name = string.gsub(attrs["name"] or "", "^#", "")
            if name ~= "" then
                local regions = {}
                local function collectAreas(n)
                    for _, c in ipairs(n.children or {}) do
                        if c.kind == "element" and c.tag == "area" then
                            local a = c.attrs or {}
                            local shape = a["shape"] or "rect"
                            local coords = {}
                            for v in string.gmatch(a["coords"] or "", "%d+") do
                                coords[#coords + 1] = tonumber(v) or 0
                            end
                            local href = validHref(a["href"]) and URL.resolve(baseUrl, a["href"]) or nil
                            table.insert(regions, {
                                shape = shape,
                                coords = coords,
                                href = href,
                                alt = a["alt"] or ""
                            })
                        end
                    end
                end
                collectAreas(node)
                doc.maps[name] = regions
            end

        elseif tag == "datalist" then
            -- Suggestion list for <input list="...">: options are metadata,
            -- never rendered in flow.
            local id = attrs["id"] or ""
            if id ~= "" then
                local opts = {}
                for _, c in ipairs(node.children or {}) do
                    if c.kind == "element" and c.tag == "option" then
                        local text = string.gsub(concatNodeText(c), "%s+", " ")
                        table.insert(opts, { text = text, value = (c.attrs and c.attrs["value"]) or text })
                    end
                end
                doc.datalists = doc.datalists or {}
                doc.datalists[id] = opts
            end

        elseif tag == "template" or tag == "menuitem" or tag == "content" or tag == "shadow"
            or tag == "geolocation" then
            -- Inert / non-rendered. template holds inert content by spec;
            -- menuitem, content, shadow, geolocation are obsolete/experimental.

        elseif tag == "fencedframe" then
            -- Experimental replacement for iframes: render a placeholder box
            -- like other embedded content.
            flushCurrentBlock()
            local w = tonumber(attrs["width"]) or 160
            local h = tonumber(attrs["height"]) or 60
            if w > 360 then w = 360 end
            if h > 120 then h = 120 end
            addBlock({ type = "placeholder", label = "[fencedframe]", width = w, height = h })

        elseif tag == "source" or tag == "track" or tag == "col" or tag == "colgroup"
            or tag == "area" or tag == "param" or tag == "frameset" or tag == "frame" then
            -- Void / non-rendered.

        elseif tag == "svg" then
            -- Inline SVG: serialize the subtree and rasterize it on-device.
            flushCurrentBlock()
            local xml = serializeSvgNode(node)
            local w = tonumber(attrs["width"]) or 0
            local h = tonumber(attrs["height"]) or 0
            if w <= 0 or h <= 0 then
                local vbW, vbH = string.match(attrs["viewBox"] or "", "^%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
                if w <= 0 then w = tonumber(vbW) or 0 end
                if h <= 0 then h = tonumber(vbH) or 0 end
            end
            if w <= 0 then w = 120 end
            if h <= 0 then h = 40 end
            if w > 360 then w = 360 end
            if h > 180 then h = 180 end
            local ok, svgImg = pcall(function()
                return SVGDecoder.decode(xml, w, h)
            end)
            if ok and svgImg then
                addBlock({
                    type = "image",
                    img = svgImg,
                    width = w,
                    height = h,
                    alt = attrs["role"] == "img" and (attrs["aria-label"] or attrs["title"] or "") or "",
                    href = state.currentHref,
                    align = parseAlign(attrs),
                    inert = (state.inert > 0)
                })
            end

        elseif tag == "math" then
            -- MathML: no on-device formula rendering, so linearize the
            -- expression to text (fractions become "a / b", scripts "x^2",
            -- roots "√(...)") and show it as a centered math block.
            flushCurrentBlock()
            local wasMath = state.inMath
            state.inMath = true
            state.mathParts = {}
            walkChildren(node)
            state.inMath = wasMath
            local s = table.concat(state.mathParts)
            s = string.gsub(s, "%s+", " ")
            s = string.gsub(s, "^%s*(.-)%s*$", "%1")
            if s ~= "" then
                addBlock({ type = "math", text = s })
            end

        elseif tag == "mfrac" then
            local kids = node.children or {}
            for i, c in ipairs(kids) do
                if i > 1 then state.mathParts[#state.mathParts + 1] = " / " end
                walk(c)
            end

        elseif tag == "msup" then
            local kids = node.children or {}
            for i, c in ipairs(kids) do
                if i > 1 then state.mathParts[#state.mathParts + 1] = "^" end
                walk(c)
            end

        elseif tag == "msub" then
            local kids = node.children or {}
            for i, c in ipairs(kids) do
                if i > 1 then state.mathParts[#state.mathParts + 1] = "_" end
                walk(c)
            end

        elseif tag == "msubsup" then
            local kids = node.children or {}
            for i, c in ipairs(kids) do
                if i == 2 then state.mathParts[#state.mathParts + 1] = "_" end
                if i == 3 then state.mathParts[#state.mathParts + 1] = "^" end
                walk(c)
            end

        elseif tag == "msqrt" then
            state.mathParts[#state.mathParts + 1] = "sqrt("
            walkChildren(node)
            state.mathParts[#state.mathParts + 1] = ")"

        elseif tag == "mroot" then
            local kids = node.children or {}
            state.mathParts[#state.mathParts + 1] = "sqrt("
            for i, c in ipairs(kids) do
                if i > 1 then state.mathParts[#state.mathParts + 1] = "^(1/" end
                if i == #kids then state.mathParts[#state.mathParts + 1] = ")" end
                walk(c)
            end
            state.mathParts[#state.mathParts + 1] = ")"

        elseif tag == "mfenced" then
            local open = Entities.decode(attrs["open"] or "(")
            local close = Entities.decode(attrs["close"] or ")")
            local sep = Entities.decode(attrs["separators"] or ",")
            state.mathParts[#state.mathParts + 1] = open
            local n = 0
            for _, c in ipairs(node.children or {}) do
                if n > 0 then state.mathParts[#state.mathParts + 1] = sep end
                walk(c)
                n = n + 1
            end
            state.mathParts[#state.mathParts + 1] = close

        elseif tag == "mspace" then
            state.mathParts[#state.mathParts + 1] = " "

        elseif tag == "script" or tag == "style"
            or tag == "title" then
            -- Non-rendered: content is stripped by the tokenizer; the DOM tree
            -- still contains the element (for possible future CSS/JS support)
            -- but we must not walk its children into the visible document.

        elseif tag == "meta" then
            local httpEquiv = attrs["http-equiv"]
            if httpEquiv and string.lower(httpEquiv) == "refresh" then
                local content = attrs["content"] or ""
                -- Match: "5;url=..." or "5; url=..." (with optional decimal seconds)
                local delayStr, urlStr = string.match(content, "^(%d+%.?%d*)%s*;%s*[Uu][Rr][Ll]=%s*(.+)$")
                if not delayStr then
                    delayStr = string.match(content, "^(%d+%.?%d*)%s*$")
                end
                if delayStr then
                    local refreshUrl = urlStr and string.match(urlStr, "^%s*(.-)%s*$") or nil
                    if refreshUrl and refreshUrl ~= "" then
                        refreshUrl = URL.resolve(baseUrl, refreshUrl)
                    else
                        refreshUrl = nil
                    end
                    state.metaRefresh = {
                        delay = tonumber(delayStr) or 0,
                        url = refreshUrl,
                    }
                end
            end

        else
            -- Unknown element: render its children in normal flow.
            walkChildren(node)
        end
    end

    -- ── Table row helper ───────────────────────────────────────────────────
    handleRow = function(trNode, tbl)
        local row = { cells = {} }
        for _, cell in ipairs(trNode.children or {}) do
            if cell.kind == "element" and (cell.tag == "td" or cell.tag == "th") then
                local cAttrs = cell.attrs or {}
                local savedHref = state.currentHref
                local savedAnchor = state.currentAnchorIndex
                local savedLinkText = state.currentLinkText

                state.currentTableCell = {
                    inlines = {},
                    header = (cell.tag == "th"),
                    colspan = tonumber(cAttrs["colspan"]) or 1,
                    rowspan = tonumber(cAttrs["rowspan"]) or 1,
                    abbr = cAttrs["abbr"] or cAttrs["title"] or "",
                    align = parseAlign(cAttrs)
                }
                state.cellFirstText = true
                state.currentHref = nil
                state.currentAnchorIndex = nil
                state.currentLinkText = ""
                walkChildren(cell)
                if #state.currentTableCell.inlines == 0 then
                    table.insert(state.currentTableCell.inlines, { type = "text", text = " " })
                end
                table.insert(row.cells, state.currentTableCell)

                state.currentTableCell = nil
                state.currentHref = savedHref
                state.currentAnchorIndex = savedAnchor
                state.currentLinkText = savedLinkText
            end
        end
        table.insert(tbl.rows, row)
    end

    -- ── Recursive walker ───────────────────────────────────────────────────
    walk = function(node)
        if not node then return end
        Tasks.yieldCheck()
        if node.kind == "text" then
            handleTextNode(node)
        elseif node.kind == "element" then
            local attrs = node.attrs or {}
            -- Global attributes: hidden / popover / display:none elements are
            -- not rendered; inert elements render but nothing inside is
            -- interactive.
            if isDisplayNone(attrs) then
                return
            end
            local wasInert = state.inert
            if attrs["inert"] ~= nil then state.inert = state.inert + 1 end
            handleElement(node)
            state.inert = wasInert
        end
    end

    for _, child in ipairs(tree.children or {}) do
        walk(child)
    end

    flushCurrentBlock()

    if state.truncated then
        table.insert(doc.blocks, {
            type = "paragraph",
            align = "center",
            inlines = { { type = "text", text = "(Page too large - rest not rendered)", bold = true } }
        })
    end

    if #doc.blocks == 0 then
        table.insert(doc.blocks, {
            type = "paragraph",
            inlines = { { type = "text", text = "(Empty Web Page)", bold = false, italic = true } }
        })
    end

    doc.metaRefresh = state.metaRefresh or metaRefresh

    return doc
end
