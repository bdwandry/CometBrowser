-- HTML Document Object Model Builder for CometBrowser
import "core/url"
import "html/tokenizer"
import "html/entities"
import "html/readability"

Document = {}

local MAX_BLOCKS = 400

function Document.parse(htmlString, baseUrl, mode)
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

    -- 3. HTML / Opera DS DOM Builder
    local doc = {
        title = pageTitle,
        baseUrl = baseUrl,
        rawHtml = htmlString,
        isReaderMode = false,
        mode = mode or Constants.MODE_RAW_HTML,
        blocks = {},
        links = {}
    }

    local currentBlock = nil
    local isBold = false
    local isItalic = false
    local isUnderline = false
    local isCode = false
    local inPre = false
    local preBuffer = ""
    local inBlockquote = false
    local currentHref = nil
    local currentLinkText = ""
    local currentFormAction = ""
    local currentFormMethod = "get"
    local inTextarea = false
    local textareaName = ""
    local textareaBuffer = ""
    local listStack = {}
    local currentTable = nil
    local currentTableRow = nil
    local currentFigure = nil

    local function flushCurrentBlock()
        if currentBlock then
            if currentBlock.type == "paragraph" and (#currentBlock.inlines == 0) then
                -- Skip empty
            else
                if #doc.blocks < MAX_BLOCKS then
                    table.insert(doc.blocks, currentBlock)
                end
            end
            currentBlock = nil
        end
    end

    local function addInline(inlineObj)
        if not currentBlock then
            currentBlock = {
                type = inBlockquote and "blockquote" or "paragraph",
                inlines = {}
            }
        end
        table.insert(currentBlock.inlines, inlineObj)
    end

    local function addInlineText(text)
        if not text or text == "" then return end
        text = Entities.decode(text)
        if not inPre then
            text = string.gsub(text, "[\r\n\t]+", " ")
        end
        if text == "" or text == " " then return end

        if currentHref then
            currentLinkText = currentLinkText .. text
        end

        addInline({
            type = "text",
            text = text,
            bold = isBold,
            italic = isItalic,
            underline = isUnderline or (currentHref ~= nil),
            code = isCode,
            href = currentHref
        })
    end

    for _, token in ipairs(tokens) do
        if token.type == "text" then
            if inPre then
                preBuffer = preBuffer .. (token.content or "")
            elseif inTextarea then
                textareaBuffer = textareaBuffer .. (token.content or "")
            elseif currentTableRow then
                local txt = Entities.decode(token.content or "")
                txt = string.gsub(txt, "^%s*(.-)%s*$", "%1")
                if txt ~= "" then
                    table.insert(currentTableRow.cells, { text = txt, href = currentHref })
                end
            elseif currentFigure and not currentFigure.hadCaption then
                currentFigure.caption = (currentFigure.caption or "") .. Entities.decode(token.content or "")
            else
                addInlineText(token.content)
            end

        elseif token.type == "tag" then
            local tag = token.name
            local isClosing = token.isClosing
            local attrs = token.attrs or {}

            if string.match(tag, "^h[1-6]$") then
                local level = tonumber(string.sub(tag, 2, 2)) or 1
                flushCurrentBlock()
                if not isClosing then
                    currentBlock = {
                        type = "heading",
                        level = level,
                        inlines = {}
                    }
                end

            elseif tag == "p" or tag == "div" or tag == "section" or tag == "article" or tag == "main" then
                flushCurrentBlock()

            elseif tag == "br" then
                if inPre then
                    preBuffer = preBuffer .. "\n"
                else
                    addInline({ type = "br" })
                end

            elseif tag == "hr" then
                flushCurrentBlock()
                if #doc.blocks < MAX_BLOCKS then
                    table.insert(doc.blocks, { type = "hr" })
                end

            elseif tag == "b" or tag == "strong" then
                isBold = not isClosing

            elseif tag == "i" or tag == "em" or tag == "cite" then
                isItalic = not isClosing

            elseif tag == "u" or tag == "ins" then
                isUnderline = not isClosing

            elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
                isCode = not isClosing

            elseif tag == "pre" then
                flushCurrentBlock()
                if not isClosing then
                    inPre = true
                    preBuffer = ""
                else
                    inPre = false
                    if preBuffer ~= "" and #doc.blocks < MAX_BLOCKS then
                        table.insert(doc.blocks, {
                            type = "code_block",
                            text = preBuffer
                        })
                        preBuffer = ""
                    end
                end

            elseif tag == "blockquote" then
                flushCurrentBlock()
                inBlockquote = not isClosing

            elseif tag == "ul" or tag == "ol" then
                flushCurrentBlock()
                if not isClosing then
                    table.insert(listStack, { type = tag, count = 0 })
                else
                    if #listStack > 0 then table.remove(listStack) end
                end

            elseif tag == "li" then
                flushCurrentBlock()
                if not isClosing then
                    local parent = listStack[#listStack] or { type = "ul", count = 0 }
                    parent.count = parent.count + 1
                    currentBlock = {
                        type = "list_item",
                        isOrdered = (parent.type == "ol"),
                        number = parent.count,
                        inlines = {}
                    }
                end

            elseif tag == "dt" then
                flushCurrentBlock()
                isBold = true
            elseif tag == "dd" then
                flushCurrentBlock()
                isBold = false
                addInlineText("  * ")

            elseif tag == "a" then
                if not isClosing then
                    local rawHref = attrs["href"] or ""
                    if rawHref ~= "" and not string.match(rawHref, "^#") and not string.match(rawHref, "^[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]:") then
                        currentHref = URL.resolve(baseUrl, rawHref)
                        currentLinkText = ""
                    end
                else
                    if currentHref then
                        table.insert(doc.links, {
                            href = currentHref,
                            text = currentLinkText ~= "" and currentLinkText or currentHref
                        })
                    end
                    currentHref = nil
                    currentLinkText = ""
                end

            elseif tag == "img" then
                local src = attrs["src"] or attrs["data-src"] or ""
                if src == "" and attrs["srcset"] then
                    src = string.match(attrs["srcset"], "^([^%s,]+)") or ""
                end
                local alt = attrs["alt"] or attrs["title"] or "Image"
                local w = tonumber(attrs["width"]) or 160
                local h = tonumber(attrs["height"]) or 80

                if src ~= "" and not string.match(src, "tracking") and not string.match(src, "beacon") then
                    if w > 360 then w = 360 end
                    if h > 180 then h = 180 end

                    local resolvedSrc = URL.resolve(baseUrl, src)
                    flushCurrentBlock()
                    if #doc.blocks < MAX_BLOCKS then
                        local imgBlock = {
                            type = "image",
                            src = resolvedSrc,
                            alt = alt,
                            width = w,
                            height = h,
                            href = currentHref
                        }
                        if currentFigure then
                            currentFigure.image = imgBlock
                        else
                            table.insert(doc.blocks, imgBlock)
                        end
                    end
                end

            elseif tag == "figure" then
                flushCurrentBlock()
                if not isClosing then
                    currentFigure = { type = "figure", caption = "" }
                else
                    if currentFigure and currentFigure.image and #doc.blocks < MAX_BLOCKS then
                        currentFigure.image.alt = (currentFigure.caption ~= "") and currentFigure.caption or currentFigure.image.alt
                        table.insert(doc.blocks, currentFigure.image)
                    end
                    currentFigure = nil
                end

            elseif tag == "figcaption" then
                if isClosing and currentFigure then
                    currentFigure.hadCaption = true
                end

            elseif tag == "form" then
                if not isClosing then
                    currentFormAction = URL.resolve(baseUrl, attrs["action"] or "")
                    currentFormMethod = string.lower(attrs["method"] or "get")
                else
                    currentFormAction = ""
                end

            elseif tag == "input" then
                local inputType = string.lower(attrs["type"] or "text")
                local inputName = attrs["name"] or "q"
                local inputVal  = attrs["value"] or ""
                local placeholder = attrs["placeholder"] or attrs["aria-label"] or ""

                if inputType == "text" or inputType == "search" or inputType == "email" or inputType == "url" or inputType == "number" then
                    flushCurrentBlock()
                    if #doc.blocks < MAX_BLOCKS then
                        table.insert(doc.blocks, {
                            type        = "input_field",
                            inputType   = inputType,
                            name        = inputName,
                            value       = inputVal,
                            placeholder = placeholder,
                            formAction  = currentFormAction,
                            formMethod  = currentFormMethod,
                        })
                    end
                elseif inputType == "submit" or inputType == "button" then
                    flushCurrentBlock()
                    if #doc.blocks < MAX_BLOCKS then
                        table.insert(doc.blocks, {
                            type       = "input_submit",
                            label      = inputVal ~= "" and inputVal or "Submit",
                            formAction = currentFormAction,
                            formMethod = currentFormMethod,
                        })
                    end
                end

            elseif tag == "textarea" then
                if not isClosing then
                    flushCurrentBlock()
                    inTextarea   = true
                    textareaName = attrs["name"] or "q"
                    textareaBuffer = ""
                else
                    inTextarea = false
                    if #doc.blocks < MAX_BLOCKS then
                        table.insert(doc.blocks, {
                            type        = "input_field",
                            inputType   = "textarea",
                            name        = textareaName,
                            value       = textareaBuffer,
                            placeholder = "",
                            formAction  = currentFormAction,
                            formMethod  = currentFormMethod,
                        })
                    end
                    textareaBuffer = ""
                end

            elseif tag == "button" then
                if not isClosing then
                    local btype = string.lower(attrs["type"] or "submit")
                    if btype == "submit" or btype == "button" then
                        flushCurrentBlock()
                        if #doc.blocks < MAX_BLOCKS then
                            table.insert(doc.blocks, {
                                type       = "input_submit",
                                label      = "Submit",
                                formAction = currentFormAction,
                                formMethod = currentFormMethod,
                            })
                        end
                    end
                end

            elseif tag == "table" then
                flushCurrentBlock()
                if not isClosing then
                    currentTable = { type = "table", rows = {} }
                else
                    if currentTable and #currentTable.rows > 0 and #doc.blocks < MAX_BLOCKS then
                        table.insert(doc.blocks, currentTable)
                    end
                    currentTable = nil
                end

            elseif tag == "tr" then
                if not isClosing and currentTable then
                    currentTableRow = { cells = {} }
                    table.insert(currentTable.rows, currentTableRow)
                else
                    currentTableRow = nil
                end
            end
        end
    end

    flushCurrentBlock()

    if #doc.blocks == 0 then
        table.insert(doc.blocks, {
            type = "paragraph",
            inlines = { { type = "text", text = "(Empty Web Page)", bold = false, italic = true } }
        })
    end

    return doc
end
