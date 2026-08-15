-- Smart Article Extractor & Reader Mode Distiller for CometBrowser
import "core/url"
import "html/entities"

Readability = {}

local STRIP_TAGS = {
    script = true, style = true, noscript = true, svg = true,
    nav = true, footer = true, aside = true, header = true,
    iframe = true
}

local function trimStr(s)
    if not s then return "" end
    return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

local function wordCount(str)
    if not str or str == "" then return 0 end
    local count = 0
    for _ in string.gmatch(str, "%S+") do
        count = count + 1
    end
    return count
end

-- Merge consecutive tiny paragraph fragments (e.g. text split across many
-- <div> wrappers like "Welcome to Wikipedia" / "," / "the free encyclopedia")
-- back into one flowing paragraph, so they don't each render on their own line.
local function mergeParagraphFragments(blocks)
    local out = {}
    for _, blk in ipairs(blocks) do
        local merged = false
        if blk.type == "paragraph" then
            local last = out[#out]
            if last and last.type == "paragraph" then
                local lastText = ""
                for _, inl in ipairs(last.inlines or {}) do
                    lastText = lastText .. (inl.text or "")
                end
                lastText = trimStr(lastText)
                local curText = ""
                for _, inl in ipairs(blk.inlines or {}) do
                    curText = curText .. (inl.text or "")
                end
                curText = trimStr(curText)
                -- Only join when the previous block does not end a sentence and
                -- the combined text stays small (i.e. this is a continuation).
                if not string.match(lastText, "[%.%?!%:]%s*$") and
                   #(lastText .. curText) <= 200 and wordCount(curText) <= 40 then
                    print("ZQMERGE OK [" .. lastText .. "] + [" .. curText .. "]")
                    for _, inl in ipairs(blk.inlines or {}) do
                        table.insert(last.inlines, inl)
                    end
                    merged = true
                else
                    print("ZQMERGE SKIP [" .. lastText .. "] + [" .. curText .. "]")
                end
            end
        end
        if not merged then
            table.insert(out, blk)
        end
    end
    return out
end

function Readability.distill(tokens, rawTitle, baseUrl)
    local parsedUrl = URL.parse(baseUrl or "")
    local hostName  = string.upper(parsedUrl.host or "WEB PAGE")
    local pageTitle = rawTitle or "Untitled Article"

    local containers = {}
    table.insert(containers, {
        score = 0,
        textLen = 0,
        wordCount = 0,
        imageCount = 0,
        blocks = {},
        linkWords = 0,
        isContent = false,
        isNav = false
    })
    local currentContainerIdx = 1

    local function currentContainer()
        return containers[currentContainerIdx]
    end

    local stripDepth = 0
    local isBold = false
    local isItalic = false
    local isCode = false
    local currentHref = nil
    local currentLinkText = ""
    local listStack = {}
    local inPre = false
    local preBuffer = ""
    local inBlockquote = false
    local pendingBlock = nil
    local currentFormAction = ""
    local currentFormMethod = "get"
    local inTextarea = false
    local textareaName = ""
    local textareaBuffer = ""
    local inButton = false
    local buttonLabel = ""
    local buttonFormAction = ""

    local function flushBlock(block)
        if not block then return end
        local c = currentContainer()
        if block.type == "hr" or block.type == "image" or block.type == "input_field" or block.type == "input_submit" then
            table.insert(c.blocks, block)
            if block.type == "image" then
                c.imageCount = (c.imageCount or 0) + 1
            end
            return
        end

        local fullText = ""
        for _, inl in ipairs(block.inlines or {}) do
            fullText = fullText .. (inl.text or "")
        end
        fullText = trimStr(fullText)
        if fullText == "" and block.type ~= "code_block" then return end

        local wc = wordCount(fullText)
        c.wordCount = c.wordCount + wc
        c.textLen = c.textLen + #fullText

        for _, inl in ipairs(block.inlines or {}) do
            if inl.href then
                c.linkWords = c.linkWords + wordCount(inl.text or "")
            end
        end
        table.insert(c.blocks, block)
    end

    local function commitBlock()
        if pendingBlock then
            flushBlock(pendingBlock)
            pendingBlock = nil
        end
    end

    local function ensureBlock(blockType)
        if not pendingBlock then
            pendingBlock = {
                type = blockType or (inBlockquote and "blockquote" or "paragraph"),
                inlines = {}
            }
        end
    end

    local function addText(text)
        if stripDepth > 0 then return end
        if not text or text == "" then return end
        text = Entities.decode(text)
        if not inPre then
            text = string.gsub(text, "[\r\n\t]+", " ")
        end
        if text == "" or text == " " then return end

        ensureBlock()
        local inline = {
            type = "text",
            text = text,
            bold = isBold,
            italic = isItalic,
            code = isCode,
            underline = (currentHref ~= nil),
            href = currentHref
        }
        table.insert(pendingBlock.inlines, inline)
        if currentHref then
            currentLinkText = currentLinkText .. text
        end
    end

    local function pushContainer(isContent, isNav)
        commitBlock()
        table.insert(containers, {
            score = 0,
            textLen = 0,
            wordCount = 0,
            imageCount = 0,
            blocks = {},
            linkWords = 0,
            isContent = isContent or false,
            isNav = isNav or false
        })
        currentContainerIdx = #containers
    end

    local function popContainer()
        commitBlock()
        if currentContainerIdx > 1 then
            currentContainerIdx = currentContainerIdx - 1
        end
    end

    for _, token in ipairs(tokens) do
        if token.type == "text" then
            if stripDepth == 0 then
                if inPre then
                    preBuffer = preBuffer .. (token.content or "")
                elseif inTextarea then
                    textareaBuffer = textareaBuffer .. (token.content or "")
                elseif inButton then
                    buttonLabel = buttonLabel .. (token.content or "")
                else
                    addText(token.content)
                end
            end

        elseif token.type == "tag" then
            local tag = token.name
            local isClosing = token.isClosing

            if STRIP_TAGS[tag] then
                if not isClosing then
                    stripDepth = stripDepth + 1
                else
                    if stripDepth > 0 then stripDepth = stripDepth - 1 end
                end

            elseif stripDepth == 0 then
                if tag == "article" or tag == "main" then
                    if not isClosing then pushContainer(true, false) else popContainer() end

                elseif tag == "nav" or tag == "header" or tag == "footer" or tag == "aside" then
                    if not isClosing then pushContainer(false, true) else popContainer() end

                elseif string.match(tag, "^h[1-6]$") then
                    commitBlock()
                    local level = tonumber(string.sub(tag, 2, 2)) or 2
                    if not isClosing then
                        pendingBlock = { type = "heading", level = level, inlines = {} }
                    else
                        commitBlock()
                    end

                elseif tag == "p" or tag == "div" or tag == "section" then
                    commitBlock()

                elseif tag == "br" then
                    if inPre then
                        preBuffer = preBuffer .. "\n"
                    else
                        if pendingBlock then
                            table.insert(pendingBlock.inlines, { type = "br" })
                        else
                            commitBlock()
                        end
                    end

                elseif tag == "hr" then
                    commitBlock()
                    flushBlock({ type = "hr" })

                elseif tag == "b" or tag == "strong" then
                    isBold = not isClosing

                elseif tag == "i" or tag == "em" or tag == "cite" then
                    isItalic = not isClosing

                elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
                    isCode = not isClosing

                elseif tag == "pre" then
                    commitBlock()
                    if not isClosing then
                        inPre = true
                        preBuffer = ""
                    else
                        inPre = false
                        if preBuffer ~= "" then
                            flushBlock({ type = "code_block", text = preBuffer })
                            preBuffer = ""
                        end
                    end

                elseif tag == "blockquote" then
                    commitBlock()
                    inBlockquote = not isClosing

                elseif tag == "ul" or tag == "ol" then
                    commitBlock()
                    if not isClosing then
                        table.insert(listStack, { type = tag, count = 0 })
                    else
                        if #listStack > 0 then table.remove(listStack) end
                    end

                elseif tag == "li" then
                    commitBlock()
                    if not isClosing then
                        local parent = listStack[#listStack] or { type = "ul", count = 0 }
                        parent.count = parent.count + 1
                        pendingBlock = {
                            type = "list_item",
                            isOrdered = (parent.type == "ol"),
                            number = parent.count,
                            inlines = {}
                        }
                    else
                        commitBlock()
                    end

                elseif tag == "a" then
                    if not isClosing then
                        local rawHref = token.attrs and token.attrs["href"] or ""
                        if rawHref ~= "" and not string.match(rawHref, "^#") and not string.match(rawHref, "^[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]:") then
                            currentHref = URL.resolve(baseUrl, rawHref)
                            currentLinkText = ""
                        end
                    else
                        currentHref = nil
                        currentLinkText = ""
                    end

                elseif tag == "form" then
                    if not isClosing then
                        currentFormAction = URL.resolve(baseUrl, token.attrs and token.attrs["action"] or "")
                        currentFormMethod = string.lower(token.attrs and token.attrs["method"] or "get")
                    else
                        currentFormAction = ""
                    end

                elseif tag == "input" then
                    local attrs = token.attrs or {}
                    local inputType   = string.lower(attrs["type"] or "text")
                    local inputName   = attrs["name"] or "q"
                    local inputVal    = attrs["value"] or ""
                    local placeholder = attrs["placeholder"] or attrs["aria-label"] or ""

                    if inputType == "text" or inputType == "search" or inputType == "email" or inputType == "url" or inputType == "number" or inputType == "password" then
                        commitBlock()
                        flushBlock({
                            type        = "input_field",
                            inputType   = inputType,
                            name        = inputName,
                            value       = inputVal,
                            placeholder = placeholder,
                            formAction  = currentFormAction,
                            formMethod  = currentFormMethod,
                        })
                    elseif inputType == "submit" or inputType == "button" then
                        commitBlock()
                        flushBlock({
                            type       = "input_submit",
                            label      = inputVal ~= "" and inputVal or "Submit",
                            formAction = currentFormAction,
                            formMethod = currentFormMethod,
                        })
                    end

                elseif tag == "textarea" then
                    if not isClosing then
                        commitBlock()
                        inTextarea   = true
                        textareaName = token.attrs and token.attrs["name"] or "q"
                        textareaBuffer = ""
                    else
                        inTextarea = false
                        flushBlock({
                            type        = "input_field",
                            inputType   = "textarea",
                            name        = textareaName,
                            value       = textareaBuffer,
                            placeholder = "",
                            formAction  = currentFormAction,
                            formMethod  = currentFormMethod,
                        })
                        textareaBuffer = ""
                    end

                elseif tag == "button" then
                    if not isClosing then
                        local btype = string.lower(token.attrs and token.attrs["type"] or "submit")
                        if btype == "submit" or btype == "button" then
                            commitBlock()
                            inButton = true
                            buttonLabel = ""
                            buttonFormAction = currentFormAction
                        end
                    else
                        if inButton then
                            inButton = false
                            local label = trimStr(buttonLabel)
                            flushBlock({
                                type       = "input_submit",
                                label      = label ~= "" and label or "Submit",
                                formAction = buttonFormAction,
                                formMethod = currentFormMethod,
                            })
                            buttonLabel = ""
                        end
                    end

                elseif tag == "img" and token.attrs then
                    local src = token.attrs["src"] or token.attrs["data-src"] or ""
                    if src == "" and token.attrs["srcset"] then
                        src = string.match(token.attrs["srcset"], "^([^%s,]+)") or ""
                    end
                    local alt = token.attrs["alt"] or token.attrs["title"] or "Image"
                    local w   = tonumber(token.attrs["width"]) or 160
                    local h   = tonumber(token.attrs["height"]) or 80

                    if src ~= "" and not string.match(src, "tracking") and not string.match(src, "beacon") then
                        if w > 360 then w = 360 end
                        if h > 180 then h = 180 end
                        commitBlock()
                        flushBlock({
                            type   = "image",
                            src    = URL.resolve(baseUrl, src),
                            alt    = alt ~= "" and alt or "Image",
                            width  = w,
                            height = h,
                            href   = currentHref
                        })
                    end
                end
            end
        end
    end

    commitBlock()

    -- Score containers and pick the best article content
    for _, c in ipairs(containers) do
        local score = (c.wordCount or 0) + ((c.imageCount or 0) * 30)
        local linkDensity = (c.wordCount > 0) and ((c.linkWords or 0) / c.wordCount) or 0
        if linkDensity > 0.5 then
            score = score * 0.2
        elseif linkDensity > 0.33 then
            score = score * 0.6
        end
        if c.isContent then score = score * 3 end
        if c.isNav then score = score * 0.05 end
        c.score = score
    end

    table.sort(containers, function(a, b) return a.score > b.score end)

    local best = containers[1]
    local bestBlocks = {}

    if best and #best.blocks > 0 then
        local threshold = best.score * 0.15
        -- Walk containers in DOCUMENT order so paragraph fragments stay
        -- contiguous and the merge pass can rejoin them; include every
        -- non-nav container that carries a meaningful share of content.
        for _, c in ipairs(containers) do
            if not c.isNav and #c.blocks > 0 and (c == best or c.score >= threshold) then
                for _, blk in ipairs(c.blocks) do
                    table.insert(bestBlocks, blk)
                end
            end
        end
    end

    -- If no container scored well, fallback to all non-nav blocks
    if #bestBlocks == 0 then
        for _, c in ipairs(containers) do
            if not c.isNav then
                for _, blk in ipairs(c.blocks) do
                    table.insert(bestBlocks, blk)
                end
            end
        end
    end

    local totalWords = 0
    for _, blk in ipairs(bestBlocks) do
        for _, inl in ipairs(blk.inlines or {}) do
            totalWords = totalWords + wordCount(inl.text or "")
        end
    end
    local readingMins = math.max(1, math.ceil(totalWords / 180))
    local readTimeStr = string.format("%d min read (%d words)", readingMins, totalWords)

    local finalBlocks = {}

    table.insert(finalBlocks, {
        type = "reader_header",
        host = hostName,
        title = pageTitle,
        readingTime = readTimeStr
    })

    table.insert(finalBlocks, {
        type = "heading",
        level = 1,
        inlines = { { type = "text", text = pageTitle, bold = true } }
    })

    table.insert(finalBlocks, { type = "hr" })

    for _, blk in ipairs(mergeParagraphFragments(bestBlocks)) do
        table.insert(finalBlocks, blk)
    end

    return {
        title = pageTitle,
        baseUrl = baseUrl,
        isReaderMode = true,
        blocks = finalBlocks,
        wordCount = totalWords,
        readingTime = readTimeStr
    }
end
