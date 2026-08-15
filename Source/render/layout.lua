-- High-Performance On-Device Layout & Painting Engine for CometBrowser
import "core/constants"
import "render/style"
import "render/link_manager"
import "render/image_decoder"

Layout = {}
local gfx = playdate.graphics

Layout.renderItems = {}
Layout.totalHeight = 0
Layout.selectedInputItem = nil

function Layout.build(doc)
    Layout.renderItems = {}
    Layout.selectedInputItem = nil
    LinkManager.clear()

    if not doc or not doc.blocks or #doc.blocks == 0 then
        Layout.totalHeight = Constants.CONTENT_HEIGHT
        return
    end

    local currentY = Constants.CONTENT_Y + 8
    local marginX  = Constants.CONTENT_MARGIN + 2
    local maxWidth = Constants.CONTENT_TEXT_WIDTH - 4

    for _, block in ipairs(doc.blocks) do
        -- 1. Reader Header Banner
        if block.type == "reader_header" then
            local badgeH = 28
            table.insert(Layout.renderItems, {
                type = "reader_badge",
                x = marginX,
                y = currentY,
                w = maxWidth,
                h = badgeH,
                host = block.host or "WEB PAGE",
                readingTime = block.readingTime or ""
            })
            currentY = currentY + badgeH + 10

        -- 2. Headings (h1 - h6)
        elseif block.type == "heading" then
            currentY = currentY + (block.level == 1 and 12 or 8)
            local font, lineH, marginB = Style.getHeadingFont(block.level)

            local words = {}
            for _, inline in ipairs(block.inlines or {}) do
                local txt = inline.text or ""
                for w in string.gmatch(txt, "%S+") do
                    table.insert(words, w)
                end
            end

            local lineWords = {}
            local lineW = 0

            for _, word in ipairs(words) do
                local wordW = Style.getTextWidth(font, word .. " ")
                if lineW + wordW > maxWidth and #lineWords > 0 then
                    local lineStr = table.concat(lineWords, " ")
                    table.insert(Layout.renderItems, {
                        type = "text",
                        text = lineStr,
                        font = font,
                        x = marginX,
                        y = currentY,
                        w = lineW,
                        h = lineH,
                        bold = true
                    })
                    currentY = currentY + lineH
                    lineWords = { word }
                    lineW = wordW
                else
                    table.insert(lineWords, word)
                    lineW = lineW + wordW
                end
            end

            if #lineWords > 0 then
                local lineStr = table.concat(lineWords, " ")
                table.insert(Layout.renderItems, {
                    type = "text",
                    text = lineStr,
                    font = font,
                    x = marginX,
                    y = currentY,
                    w = lineW,
                    h = lineH,
                    bold = true
                })
                currentY = currentY + lineH
            end

            if block.level <= 2 then
                table.insert(Layout.renderItems, {
                    type = "line",
                    x1 = marginX,
                    y1 = currentY + 3,
                    x2 = marginX + maxWidth,
                    y2 = currentY + 3
                })
                currentY = currentY + 6
            end

            currentY = currentY + marginB

        -- 3. Paragraphs & Blockquotes
        elseif block.type == "paragraph" or block.type == "blockquote" then
            local isQuote = (block.type == "blockquote")
            local blockStartX = isQuote and (marginX + 14) or marginX
            local blockMaxW = isQuote and (maxWidth - 18) or maxWidth
            local startQuoteY = currentY

            local cursorX = blockStartX
            local lineH = 18
            local lineY = currentY

            for _, inline in ipairs(block.inlines or {}) do
                if inline.type == "br" then
                    cursorX = blockStartX
                    lineY = lineY + lineH
                else
                    local font = Style.getBodyFont(inline.bold, inline.code)
                    lineH = math.max(lineH, inline.code and 15 or 18)

                    local rawText = inline.text or ""
                    for word in string.gmatch(rawText, "%S+") do
                        local wordW = Style.getTextWidth(font, word .. " ")
                        if cursorX + wordW > blockStartX + blockMaxW and cursorX > blockStartX then
                            cursorX = blockStartX
                            lineY = lineY + lineH
                        end

                        local itemW = Style.getTextWidth(font, word)
                        local item = {
                            type = "text",
                            text = word,
                            font = font,
                            x = cursorX,
                            y = lineY,
                            w = itemW,
                            h = lineH,
                            bold = inline.bold,
                            italic = inline.italic,
                            underline = inline.underline,
                            code = inline.code,
                            href = inline.href
                        }
                        table.insert(Layout.renderItems, item)

                        if inline.href then
                            LinkManager.addLinkRect(inline.href, inline.text, {
                                x = cursorX,
                                y = lineY,
                                w = itemW,
                                h = lineH
                            })
                        end

                        cursorX = cursorX + wordW
                    end
                end
            end

            currentY = lineY + lineH + 10

            if isQuote then
                table.insert(Layout.renderItems, {
                    type = "quote_bar",
                    x = marginX + 3,
                    y1 = startQuoteY,
                    y2 = currentY - 4
                })
            end

        -- 4. Lists (ul / ol)
        elseif block.type == "list_item" then
            local bulletIndent = marginX + 4
            local textIndent   = marginX + 20
            local listMaxW     = maxWidth - 20
            local lineH        = 18

            local bulletStr = block.isOrdered and (tostring(block.number or 1) .. ".") or "*"
            table.insert(Layout.renderItems, {
                type = "text",
                text = bulletStr,
                font = Style.fontBodyBold or gfx.getFont(),
                x = bulletIndent,
                y = currentY,
                w = 14,
                h = lineH,
                bold = true
            })

            local cursorX = textIndent
            local lineY = currentY

            for _, inline in ipairs(block.inlines or {}) do
                if inline.type == "br" then
                    cursorX = textIndent
                    lineY = lineY + lineH
                else
                    local font = Style.getBodyFont(inline.bold, inline.code)
                    local rawText = inline.text or ""
                    for word in string.gmatch(rawText, "%S+") do
                        local wordW = Style.getTextWidth(font, word .. " ")
                        if cursorX + wordW > textIndent + listMaxW and cursorX > textIndent then
                            cursorX = textIndent
                            lineY = lineY + lineH
                        end

                        local itemW = Style.getTextWidth(font, word)
                        table.insert(Layout.renderItems, {
                            type = "text",
                            text = word,
                            font = font,
                            x = cursorX,
                            y = lineY,
                            w = itemW,
                            h = lineH,
                            bold = inline.bold,
                            italic = inline.italic,
                            underline = inline.underline,
                            code = inline.code,
                            href = inline.href
                        })

                        if inline.href then
                            LinkManager.addLinkRect(inline.href, inline.text, {
                                x = cursorX,
                                y = lineY,
                                w = itemW,
                                h = lineH
                            })
                        end

                        cursorX = cursorX + wordW
                    end
                end
            end

            currentY = lineY + lineH + 6

        -- 5. Code Blocks
        elseif block.type == "code_block" then
            local font = Style.fontMono or gfx.getFont()
            local rawText = block.text or ""
            local lines = {}
            for l in string.gmatch(rawText .. "\n", "(.-)\r?\n") do
                table.insert(lines, l)
            end

            local boxH = math.max(30, #lines * 14 + 12)
            table.insert(Layout.renderItems, {
                type = "code_box",
                x = marginX,
                y = currentY,
                w = maxWidth,
                h = boxH,
                lines = lines
            })
            currentY = currentY + boxH + 10

        -- 6. Horizontal Rule (hr)
        elseif block.type == "hr" then
            currentY = currentY + 6
            table.insert(Layout.renderItems, {
                type = "line",
                x1 = marginX + 20,
                y1 = currentY,
                x2 = marginX + maxWidth - 20,
                y2 = currentY
            })
            currentY = currentY + 10

        -- 7. Images (On-Device Dithered)
        elseif block.type == "image" then
            local imgW = math.min(block.width or 160, maxWidth)
            local imgH = math.min(block.height or 80, 160)
            local imgX = marginX + math.floor((maxWidth - imgW) / 2)
            if imgX < marginX then imgX = marginX end

            table.insert(Layout.renderItems, {
                type = "image",
                x = imgX,
                y = currentY,
                w = imgW,
                h = imgH,
                alt = block.alt,
                src = block.src,
                href = block.href
            })

            if block.href then
                LinkManager.addLinkRect(block.href, block.alt or "[Image Link]", {
                    x = imgX,
                    y = currentY,
                    w = imgW,
                    h = imgH
                })
            end

            currentY = currentY + imgH + 12

        -- 8. Tables
        elseif block.type == "table" then
            local font = Style.fontSmall or gfx.getFont()
            local rows = block.rows or {}
            local tableH = math.max(24, #rows * 20 + 8)

            table.insert(Layout.renderItems, {
                type = "table_box",
                x = marginX,
                y = currentY,
                w = maxWidth,
                h = tableH,
                rows = rows
            })
            currentY = currentY + tableH + 10

        -- 9. Text Input Fields
        elseif block.type == "input_field" then
            local fieldH = 22
            local item = {
                type = "input_field",
                x = marginX,
                y = currentY,
                w = maxWidth - 10,
                h = fieldH,
                inputType = block.inputType or "text",
                name = block.name or "q",
                value = block.value or "",
                placeholder = block.placeholder or "",
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get"
            }
            table.insert(Layout.renderItems, item)

            LinkManager.addLinkRect(block.formAction or "#", "[Input: " .. (block.name or "q") .. "]", {
                x = marginX,
                y = currentY,
                w = maxWidth - 10,
                h = fieldH,
                isFormInput = true,
                inputBlock = item
            })

            currentY = currentY + fieldH + 8

        -- 10. Submit Buttons
        elseif block.type == "input_submit" then
            local btnH = 22
            local btnW = 100
            local item = {
                type = "input_submit",
                x = marginX,
                y = currentY,
                w = btnW,
                h = btnH,
                label = block.label or "Submit",
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get"
            }
            table.insert(Layout.renderItems, item)

            LinkManager.addLinkRect(block.formAction or "#", "[Button: " .. (block.label or "Submit") .. "]", {
                x = marginX,
                y = currentY,
                w = btnW,
                h = btnH,
                isFormInput = true,
                inputBlock = item
            })

            currentY = currentY + btnH + 8
        end
    end

    Layout.totalHeight = math.max(currentY + 20, Constants.CONTENT_HEIGHT)
end

function Layout.draw(scrollY)
    -- White page canvas
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, Constants.CONTENT_Y, Constants.SCREEN_WIDTH, Constants.CONTENT_HEIGHT)

    gfx.pushContext()
    gfx.setClipRect(0, Constants.CONTENT_Y, Constants.CONTENT_WIDTH, Constants.CONTENT_HEIGHT)

    local selLink = LinkManager.getSelectedLink()

    for _, item in ipairs(Layout.renderItems) do
        if item.type == "text" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                local isSelLink = LinkManager.isHighlighted(item.href, item.x, item.y)
                if item.href and isSelLink then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.fillRoundRect(item.x - 2, drawY, item.w + 4, item.h, 2)
                    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                end

                gfx.setFont(item.font)
                gfx.drawText(item.text, item.x, drawY)

                if item.href and isSelLink then
                    gfx.setImageDrawMode(gfx.kDrawModeCopy)
                elseif item.underline or item.href then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawLine(item.x, drawY + item.h - 1, item.x + item.w, drawY + item.h - 1)
                end
            end

        elseif item.type == "reader_badge" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 4)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

                local fontBold = Style.fontBodyBold or gfx.getFont()
                local fontSmall = Style.fontSmall or Style.fontMono or gfx.getFont()

                gfx.setFont(fontBold)
                gfx.drawText("READER MODE  *  " .. item.host, item.x + 8, drawY + 3)

                gfx.setFont(fontSmall)
                gfx.drawText(item.readingTime, item.x + 8, drawY + 16)

                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end

        elseif item.type == "line" then
            local drawY1 = item.y1 - scrollY
            local drawY2 = item.y2 - scrollY
            if drawY1 >= Constants.CONTENT_Y - 2 and drawY1 <= Constants.SCREEN_HEIGHT + 2 then
                gfx.drawLine(item.x1, drawY1, item.x2, drawY2)
            end

        elseif item.type == "quote_bar" then
            local drawY1 = item.y1 - scrollY
            local drawY2 = item.y2 - scrollY
            if drawY2 >= Constants.CONTENT_Y and drawY1 <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRect(item.x, drawY1, 3, drawY2 - drawY1)
            end

        elseif item.type == "code_box" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorWhite)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 3)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 3)

                local font = Style.fontMono or gfx.getFont()
                gfx.setFont(font)
                local lineY = drawY + 6
                for _, l in ipairs(item.lines or {}) do
                    if lineY + 14 <= drawY + item.h then
                        gfx.drawText(l, item.x + 8, lineY)
                    end
                    lineY = lineY + 14
                end
            end

        elseif item.type == "table_box" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorWhite)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 3)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 3)

                local font = Style.fontSmall or gfx.getFont()
                gfx.setFont(font)
                local rowY = drawY + 4
                for _, row in ipairs(item.rows or {}) do
                    local cellX = item.x + 8
                    local colW = math.floor((item.w - 16) / math.max(1, #row.cells))
                    for _, cell in ipairs(row.cells) do
                        local txt = cell.text or ""
                        if #txt > 20 then txt = string.sub(txt, 1, 18) .. ".." end
                        gfx.drawText(txt, cellX, rowY)
                        cellX = cellX + colW
                    end
                    rowY = rowY + 18
                    if rowY < drawY + item.h - 4 then
                        gfx.drawLine(item.x, rowY - 2, item.x + item.w, rowY - 2)
                    end
                end
            end

        elseif item.type == "image" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                ImageDecoder.draw(item.x, drawY, item.w, item.h, item.alt, item.href, false, item.src)
            end

        elseif item.type == "input_field" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                local isSel = (Layout.selectedInputItem == item)
                gfx.setColor(gfx.kColorBlack)
                if isSel then
                    gfx.fillRoundRect(item.x, drawY, item.w, item.h, 4)
                    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                else
                    gfx.drawRoundRect(item.x, drawY, item.w, item.h, 4)
                end

                local font = Style.fontBody or gfx.getFont()
                gfx.setFont(font)
                local val = (item.value and item.value ~= "") and item.value or item.placeholder
                if item.inputType == "password" then
                    val = string.rep("*", #(item.value or ""))
                end
                if #val > 36 then val = string.sub(val, 1, 33) .. "..." end
                gfx.drawText(val, item.x + 6, drawY + 3)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end

        elseif item.type == "input_submit" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                local isSel = (Layout.selectedInputItem == item)
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 4)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

                local font = Style.fontBodyBold or gfx.getFont()
                gfx.setFont(font)
                local lw = Style.getTextWidth(font, item.label)
                gfx.drawText(item.label, item.x + math.floor((item.w - lw) / 2), drawY + 3)

                if isSel then
                    gfx.setColor(gfx.kColorWhite)
                    gfx.drawRoundRect(item.x + 1, drawY + 1, item.w - 2, item.h - 2, 3)
                end
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end
        end
    end

    -- Draw selected link outline
    LinkManager.drawSelectedHighlight(scrollY)

    gfx.popContext()

    -- Scrollbar
    local maxScroll = math.max(0, Layout.totalHeight - Constants.CONTENT_HEIGHT)
    if maxScroll > 0 then
        local barH = math.max(16, math.floor(Constants.CONTENT_HEIGHT * (Constants.CONTENT_HEIGHT / Layout.totalHeight)))
        local barY = Constants.CONTENT_Y + math.floor((scrollY / maxScroll) * (Constants.CONTENT_HEIGHT - barH))
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(Constants.SCREEN_WIDTH - Constants.SCROLLBAR_WIDTH, barY, Constants.SCROLLBAR_WIDTH, barH)
    end
end
