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

local function normalizeAlign(a)
    if not a then return nil end
    a = string.lower(a)
    if a == "center" or a == "right" or a == "left" then return a end
    return nil
end

-- Ordered-list marker rendering: 1/a/A/i/I (ol type attribute).
local function toRoman(n)
    if not n or n <= 0 or n > 3999 then return tostring(n or 1) end
    local map = { {1000,"M"},{900,"CM"},{500,"D"},{400,"CD"},{100,"C"},{90,"XC"},{50,"L"},{40,"XL"},{10,"X"},{9,"IX"},{5,"V"},{4,"IV"},{1,"I"} }
    local out = ""
    for _, p in ipairs(map) do
        while n >= p[1] do
            out = out .. p[2]
            n = n - p[1]
        end
    end
    return out
end

local function toAlpha(n)
    local out = ""
    while n and n > 0 do
        local rem = (n - 1) % 26
        out = string.char(97 + rem) .. out
        n = math.floor((n - 1) / 26)
    end
    return out ~= "" and out or "1"
end

local function orderedMarker(number, markerType)
    markerType = markerType or "1"
    if markerType == "a" then return toAlpha(number)
    elseif markerType == "A" then return string.upper(toAlpha(number))
    elseif markerType == "i" then return toRoman(number)
    elseif markerType == "I" then return string.upper(toRoman(number))
    else return tostring(number or 1) end
end

-- Break a list of inline runs into wrapped lines. A line is a list of words
-- with their fonts; the word width excludes the trailing space, "advance"
-- includes it.
local function breakLines(inlines, maxW, opts)
    opts = opts or {}
    local lines = {}
    local cur = { words = {}, width = 0 }
    local firstWord = true
    local lineH = opts.lineH or 16

    local function push()
        if #cur.words > 0 then
            lines[#lines + 1] = cur
            cur = { words = {}, width = 0 }
            firstWord = true
        end
    end

    for _, inline in ipairs(inlines or {}) do
        if inline.type == "br" then
            push()
        else
            local font, lh
            if opts.font then
                font = opts.font
                lh = opts.lineH or 16
            elseif opts.bold then
                font = Style.fontBodyBold or gfx.getFont()
                lh = 16
            else
                font, lh = Style.getInlineFont(inline.bold, inline.code, inline.small, inline.sub, inline.sup, inline.big)
            end
            lineH = math.max(lineH, lh)
            local text = inline.text or ""
            for word in string.gmatch(text, "%S+") do
                local ww = Style.getTextWidth(font, word)
                local aw = ww + Style.getTextWidth(font, " ")
                if cur.width + aw > maxW and not firstWord then
                    push()
                end
                table.insert(cur.words, { text = word, font = font, w = ww, advance = aw, inline = inline })
                cur.width = cur.width + aw
                firstWord = false
            end
        end
    end
    push()

    return lines, lineH
end

-- Emit positioned text render-items for already-broken lines, honoring the
-- paragraph alignment (left / center / right). Also registers link hitboxes.
local function emitFlow(lines, lineH, startX, maxW, align, startY)
    local items = {}
    local y = startY
    for _, line in ipairs(lines) do
        local textW = 0
        for _, wd in ipairs(line.words) do textW = textW + wd.w end
        local x = startX
        if align == "center" then
            x = startX + math.floor((maxW - textW) / 2)
        elseif align == "right" then
            x = startX + math.max(0, maxW - textW)
        end
        for _, wd in ipairs(line.words) do
            local inline = wd.inline
            local dy = 0
            if inline.sub then dy = 3 elseif inline.sup then dy = -4 end
            local item = {
                type = "text",
                text = wd.text,
                font = wd.font,
                x = x,
                y = y + dy,
                w = wd.w,
                h = lineH,
                bold = inline.bold,
                italic = inline.italic,
                underline = inline.underline,
                code = inline.code,
                small = inline.small,
                big = inline.big,
                mark = inline.mark,
                strike = inline.strike,
                href = inline.href,
                anchorIndex = inline.anchorIndex
            }
            items[#items + 1] = item
            if inline.href then
                LinkManager.addLinkRect(inline.href, inline.text, {
                    x = x,
                    y = y,
                    w = wd.w,
                    h = lineH,
                    inert = inline.inert or false
                }, inline.anchorIndex)
            end
            x = x + wd.advance
        end
        y = y + lineH
    end
    return items, y
end

function Layout.build(doc)
    Layout.renderItems = {}
    Layout.selectedInputItem = nil
    Layout.cellLinksRegistered = false
    LinkManager.clear()

    if not doc or not doc.blocks or #doc.blocks == 0 then
        Layout.totalHeight = Constants.CONTENT_HEIGHT
        return
    end

    local currentY = Constants.CONTENT_Y + 8
    local marginX  = Constants.CONTENT_MARGIN + 2
    local maxWidth = Constants.CONTENT_TEXT_WIDTH - 4
    local boxStack = {}

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
            local align = normalizeAlign(block.align)

            local lines, lh = breakLines(block.inlines, maxWidth, { font = font, lineH = lineH })
            local items, endY = emitFlow(lines, lh, marginX, maxWidth, align, currentY)
            for _, it in ipairs(items) do
                it.bold = true
                table.insert(Layout.renderItems, it)
            end
            currentY = endY

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
            local align = normalizeAlign(block.align)

            local lines, lineH = breakLines(block.inlines, blockMaxW, {})
            local items, endY = emitFlow(lines, lineH, blockStartX, blockMaxW, align, currentY)
            for _, it in ipairs(items) do
                table.insert(Layout.renderItems, it)
            end
            currentY = endY + 10

            if isQuote then
                table.insert(Layout.renderItems, {
                    type = "quote_bar",
                    x = marginX + 3,
                    y1 = startQuoteY,
                    y2 = currentY - 4
                })
            end

        -- 4. Lists (ul / ol / dl)
        elseif block.type == "list_item" then
            local depth = block.depth or 1
            local isDt = block.dt
            local isDd = block.dd
            local indent = (depth - 1) * 14
            local bulletIndent = marginX + 4 + indent
            local textIndent = marginX + (isDd and 30 or 20) + indent
            local listMaxW = maxWidth - (textIndent - marginX) - 4
            local lineH = 18

            if not isDt and not isDd then
                local bulletStr
                if block.isOrdered then
                    bulletStr = orderedMarker(block.number or 1, block.markerType) .. "."
                else
                    bulletStr = "*"
                end
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
            end

            local align = normalizeAlign(block.align)
            local lines, lh = breakLines(block.inlines, listMaxW, { bold = isDt })
            local items, endY = emitFlow(lines, lh, textIndent, listMaxW, align, currentY)
            for _, it in ipairs(items) do
                table.insert(Layout.renderItems, it)
            end
            currentY = endY + 6

        -- 5. Code Blocks
        elseif block.type == "code_block" then
            local font = Style.fontMono or gfx.getFont()
            local rawText = block.text or ""
            local lines = block.lines or {}
            if #lines == 0 then
                for l in string.gmatch(rawText .. "\n", "(.-)\r?\n") do
                    table.insert(lines, l)
                end
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
            local align = normalizeAlign(block.align)
            local imgX = marginX
            if align == "center" then
                imgX = marginX + math.floor((maxWidth - imgW) / 2)
            elseif align == "right" then
                imgX = marginX + math.max(0, maxWidth - imgW)
            end
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

            if block.href and not block.inert then
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
            local rowCount = #(block.rows or {})
            local capH = (block.caption and block.caption ~= "") and 16 or 0
            local tableH = math.max(24, rowCount * 18 + 14) + capH

            local tblW = maxWidth
            if block.width then
                local w = tonumber(block.width)
                if not w and string.match(block.width, "%%") then
                    w = tonumber(string.gsub(block.width, "%%", "")) or 0
                    if w > 0 and w <= 100 then tblW = math.floor(maxWidth * w / 100) end
                elseif w and w > 0 then
                    tblW = math.min(w, maxWidth)
                end
            end
            local tblX = marginX
            local align = normalizeAlign(block.align)
            if align == "center" then
                tblX = marginX + math.floor((maxWidth - tblW) / 2)
            elseif align == "right" then
                tblX = marginX + math.max(0, maxWidth - tblW)
            end

            table.insert(Layout.renderItems, {
                type = "table_box",
                x = tblX,
                y = currentY,
                w = tblW,
                h = tableH,
                rows = block.rows,
                caption = block.caption,
                border = block.border ~= false
            })
            currentY = currentY + tableH + 10

        -- 9. Text Input Fields
        elseif block.type == "input_field" then
            local fieldH = 22
            local fieldW = maxWidth - 10
            if block.fieldWidth and block.fieldWidth > 0 then
                fieldW = math.min(maxWidth - 10, math.max(60, block.fieldWidth * 8))
            elseif block.inputType == "textarea" and block.fieldWidth and block.fieldWidth > 0 then
                fieldW = math.min(maxWidth - 10, math.max(80, block.fieldWidth * 8))
            end
            local fieldRows = block.inputType == "textarea" and (block.fieldRows or 2) or 1
            if fieldRows > 1 then fieldH = 18 + fieldRows * 16 end
            local item = {
                type = "input_field",
                x = marginX,
                y = currentY,
                w = fieldW,
                h = fieldH,
                inputType = block.inputType or "text",
                name = block.name or "q",
                value = block.value or "",
                placeholder = block.placeholder or "",
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get",
                disabled = block.disabled,
                readonly = block.readonly,
                required = block.required,
                maxlength = block.maxlength
            }
            table.insert(Layout.renderItems, item)

            if not block.disabled and not block.inert then
                LinkManager.addLinkRect(block.formAction or "#", "[Input: " .. (block.name or "q") .. "]", {
                    x = marginX,
                    y = currentY,
                    w = fieldW,
                    h = fieldH,
                    isFormInput = true,
                    inputBlock = item
                })
            end

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
                name = block.name,
                value = block.value,
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get",
                disabled = block.disabled
            }
            table.insert(Layout.renderItems, item)

            if not block.disabled and not block.inert then
                LinkManager.addLinkRect(block.formAction or "#", "[Button: " .. (block.label or "Submit") .. "]", {
                    x = marginX,
                    y = currentY,
                    w = btnW,
                    h = btnH,
                    isFormInput = true,
                    inputBlock = item
                })
            end

            currentY = currentY + btnH + 8

        -- 11. Checkboxes & Radio Buttons
        elseif block.type == "checkbox_field" then
            local boxH = 20
            local item = {
                type = "checkbox_field",
                x = marginX,
                y = currentY,
                w = boxH,
                h = boxH,
                radio = block.radio,
                checked = block.checked,
                name = block.name or "",
                value = block.value or "",
                label = block.label or "",
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get",
                disabled = block.disabled
            }
            table.insert(Layout.renderItems, item)

            local label = block.label or ""
            local font = Style.fontBody or gfx.getFont()
            local lx = marginX + boxH + 6
            if #label > 30 then label = string.sub(label, 1, 28) .. ".." end
            local lw = Style.getTextWidth(font, label)
            if label ~= "" then
                table.insert(Layout.renderItems, {
                    type = "text",
                    text = label,
                    font = font,
                    x = lx,
                    y = currentY + 2,
                    w = lw,
                    h = boxH,
                    bold = false
                })
            end

            if not block.disabled and not block.inert then
                LinkManager.addLinkRect("input:" .. (block.name or "q"), block.label or "", {
                    x = marginX,
                    y = currentY,
                    w = boxH + 8 + lw,
                    h = boxH,
                    isFormInput = true,
                    inputBlock = item
                })
            end

            currentY = currentY + boxH + 8

        -- 12. Select Dropdowns
        elseif block.type == "select_field" then
            local fieldH = 22
            local item = {
                type = "select_field",
                x = marginX,
                y = currentY,
                w = maxWidth - 10,
                h = fieldH,
                name = block.name or "q",
                options = block.options or {},
                selectedIndex = block.selectedIndex or 1,
                formAction = block.formAction or "",
                formMethod = block.formMethod or "get",
                disabled = block.disabled
            }
            table.insert(Layout.renderItems, item)

            if not block.disabled and not block.inert then
                LinkManager.addLinkRect("select:" .. (block.name or "q"), "[Select]", {
                    x = marginX,
                    y = currentY,
                    w = maxWidth - 10,
                    h = fieldH,
                    isFormInput = true,
                    inputBlock = item
                })
            end

            currentY = currentY + fieldH + 8

        -- 13. Media Placeholders (video / iframe / canvas / ...)
        elseif block.type == "placeholder" then
            local boxW = math.min(block.width or maxWidth, maxWidth)
            local boxH = math.min(block.height or 46, 120)
            table.insert(Layout.renderItems, {
                type = "placeholder",
                x = marginX,
                y = currentY,
                w = boxW,
                h = boxH,
                label = block.label or block.text or "Media"
            })
            currentY = currentY + boxH + 10

        -- 14. Progress / Meter Bars
        elseif block.type == "meter" then
            local boxH = 20
            table.insert(Layout.renderItems, {
                type = "meter",
                x = marginX,
                y = currentY,
                w = maxWidth,
                h = boxH,
                value = block.value or 0,
                min = block.min or 0,
                max = block.max or 100,
                low = block.low,
                high = block.high,
                optimum = block.optimum,
                label = block.label or ""
            })
            currentY = currentY + boxH + 10

        -- 15. Bordered Boxes (fieldset / details / dialog)
        elseif block.type == "box_open" then
            local item = {
                type = "box_frame",
                x = marginX,
                y = currentY,
                w = maxWidth,
                y2 = currentY,
                label = block.label or ""
            }
            table.insert(Layout.renderItems, item)
            table.insert(boxStack, item)
            currentY = currentY + 18

        elseif block.type == "box_close" then
            local frame = table.remove(boxStack)
            if frame then frame.y2 = currentY end
            currentY = currentY + 8
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
                local isSelLink = item.href and LinkManager.isHighlighted(item.href, item.x, item.y)
                local inverted = isSelLink or item.mark
                if inverted then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.fillRect(item.x - 1, drawY - 1, item.w + 2, item.h)
                    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                end

                gfx.setFont(item.font)
                gfx.drawText(item.text, item.x, drawY)

                if inverted then
                    gfx.setImageDrawMode(gfx.kDrawModeCopy)
                end

                if item.strike then
                    gfx.setColor(inverted and gfx.kColorWhite or gfx.kColorBlack)
                    gfx.drawLine(item.x, drawY + math.floor(item.h / 2), item.x + item.w, drawY + math.floor(item.h / 2))
                end

                if item.underline or item.href then
                    gfx.setColor(inverted and gfx.kColorWhite or gfx.kColorBlack)
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
                if item.border ~= false then
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRoundRect(item.x, drawY, item.w, item.h, 3)
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawRoundRect(item.x, drawY, item.w, item.h, 3)
                end

                local rows = item.rows or {}
                local colCount = 1
                for _, row in ipairs(rows) do
                    local n = 0
                    for _, cell in ipairs(row.cells or {}) do
                        n = n + (cell.colspan or 1)
                    end
                    if n > colCount then colCount = n end
                end
                local colW = (item.w - 16) / math.max(1, colCount)

                local capH = 0
                if item.caption and item.caption ~= "" then capH = 16 end
                if capH > 0 then
                    local font = Style.fontBodyBold or gfx.getFont()
                    gfx.setFont(font)
                    local cap = item.caption
                    if #cap > 30 then cap = string.sub(cap, 1, 28) .. ".." end
                    gfx.drawText(cap, item.x + 8, drawY + 2)
                end

                local rowY = drawY + 4 + capH
                for _, row in ipairs(rows) do
                    local cellX = item.x + 8
                    for _, cell in ipairs(row.cells or {}) do
                        local span = cell.colspan or 1
                        local cw = colW * span
                        local txt = ""
                        for _, inl in ipairs(cell.inlines or {}) do
                            txt = txt .. (inl.text or "")
                        end
                        txt = string.gsub(txt, "%s+", " ")
                        txt = string.gsub(txt, "^%s*(.-)%s*$", "%1")

                        local font = (cell.header and Style.fontBodyBold) or Style.fontSmall or gfx.getFont()
                        gfx.setFont(font)
                        local maxChars = math.max(2, math.floor(cw / 7))
                        if #txt > maxChars then
                            txt = string.sub(txt, 1, math.max(1, maxChars - 2)) .. ".."
                        end
                        local tw = Style.getTextWidth(font, txt)
                        local cellAlign = cell.align and string.lower(cell.align) or "left"
                        local tx = cellX
                        if cellAlign == "center" then
                            tx = cellX + math.floor((cw - tw) / 2)
                        elseif cellAlign == "right" then
                            tx = cellX + math.max(0, cw - tw)
                        end
                        gfx.drawText(txt, tx, rowY)

                        local hasLink = false
                        local linkHref, linkText = nil, ""
                        for _, inl in ipairs(cell.inlines or {}) do
                            if inl.href then
                                linkHref = inl.href
                                linkText = linkText .. (inl.text or "")
                                hasLink = true
                            end
                        end
                        if hasLink and linkHref and not Layout.cellLinksRegistered then
                            LinkManager.addLinkRect(linkHref, linkText ~= "" and linkText or linkHref, {
                                x = tx,
                                y = rowY + scrollY,
                                w = tw,
                                h = 16,
                                inert = inl.inert or false
                            })
                        end

                        cellX = cellX + cw
                    end
                    rowY = rowY + 18
                    if rowY < drawY + item.h - 4 then
                        gfx.setColor(gfx.kColorBlack)
                        gfx.drawLine(item.x, rowY - 2, item.x + item.w, rowY - 2)
                    end
                end
                Layout.cellLinksRegistered = true
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
                elseif item.disabled then
                    gfx.drawRoundRect(item.x, drawY, item.w, item.h, 4)
                    gfx.drawLine(item.x + 3, drawY + 1, item.x + item.w - 3, drawY + 1)
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
                if item.required then
                    gfx.drawText("*", item.x + item.w - 10, drawY + 3)
                end
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
                elseif item.disabled then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawLine(item.x + 4, drawY + 4, item.x + item.w - 4, drawY + 4)
                end
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end

        elseif item.type == "checkbox_field" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                local isSel = (Layout.selectedInputItem == item)
                gfx.setColor(gfx.kColorBlack)
                if item.radio then
                    gfx.drawCircleAtPoint(item.x + item.h / 2, drawY + item.h / 2, item.h / 2 - 1)
                    if item.checked then
                        gfx.fillCircleAtPoint(item.x + item.h / 2, drawY + item.h / 2, item.h / 2 - 3)
                    end
                else
                    gfx.drawRoundRect(item.x, drawY, item.h, item.h, 3)
                    if item.checked then
                        gfx.drawLine(item.x + 4, drawY + item.h / 2, item.x + item.h / 2, drawY + item.h - 4)
                        gfx.drawLine(item.x + item.h / 2, drawY + item.h - 4, item.x + item.h - 4, drawY + 3)
                    end
                end
                if isSel then
                    gfx.drawRoundRect(item.x - 2, drawY - 2, item.h + 4, item.h + 4, 4)
                elseif item.disabled then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawLine(item.x - 1, drawY - 1, item.x + item.h + 1, drawY + item.h + 1)
                end
            end

        elseif item.type == "select_field" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                local isSel = (Layout.selectedInputItem == item)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 4)

                local opt = item.options and item.options[item.selectedIndex]
                local val = (opt and opt.text) or ""
                local font = Style.fontBody or gfx.getFont()
                gfx.setFont(font)
                if #val > 30 then val = string.sub(val, 1, 28) .. ".." end
                gfx.drawText(val, item.x + 6, drawY + 3)

                local ax = item.x + item.w - 14
                local ay = drawY + item.h / 2
                gfx.drawLine(ax, ay - 3, ax + 5, ay - 3)
                gfx.drawLine(ax + 1, ay - 1, ax + 4, ay - 1)
                gfx.drawLine(ax + 2, ay + 1, ax + 3, ay + 1)

                if isSel then
                    gfx.drawRoundRect(item.x - 1, drawY - 1, item.w + 2, item.h + 2, 4)
                elseif item.disabled then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawLine(item.x + 4, drawY + 4, item.x + item.w - 4, drawY + 4)
                end
            end

        elseif item.type == "placeholder" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorWhite)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 4)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 4)

                local font = Style.fontSmall or gfx.getFont()
                gfx.setFont(font)
                local label = item.label or "Media"
                if #label > 40 then label = string.sub(label, 1, 38) .. ".." end
                local lw = Style.getTextWidth(font, label)
                gfx.drawText(label, item.x + math.floor((item.w - lw) / 2), drawY + math.floor((item.h - 10) / 2))
            end

        elseif item.type == "meter" then
            local drawY = item.y - scrollY
            if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 4)
                local min = item.min or 0
                local max = (item.max or 100)
                if max <= min then max = min + 1 end
                local function norm(v)
                    if v == nil then return nil end
                    return (v - min) / (max - min)
                end
                local frac = norm(item.value or 0)
                if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
                if frac > 0 then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.fillRoundRect(item.x + 2, drawY + 2, math.floor((item.w - 4) * frac), item.h - 4, 3)
                end

                -- optimum marker tick
                local opt = norm(item.optimum)
                if opt and opt >= 0 and opt <= 1 then
                    local ox = item.x + 2 + math.floor((item.w - 4) * opt)
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRect(ox - 1, drawY + 1, 2, item.h - 2)
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawLine(ox, drawY + 1, ox, drawY + item.h - 2)
                end

                local pct = tostring(math.floor((frac) * 100)) .. "%"
                local font = Style.fontSmall or gfx.getFont()
                local tw = Style.getTextWidth(font, pct)
                gfx.setFont(font)
                local tx = item.x + math.floor((item.w - tw) / 2)
                if frac > 0.5 then gfx.setColor(gfx.kColorWhite) else gfx.setColor(gfx.kColorBlack) end
                gfx.drawText(pct, tx, drawY + math.floor((item.h - 10) / 2))
            end

        elseif item.type == "box_frame" then
            local y = item.y - scrollY
            local y2 = item.y2 - scrollY
            if y2 >= Constants.CONTENT_Y and y <= Constants.SCREEN_HEIGHT then
                gfx.setColor(gfx.kColorBlack)
                gfx.drawLine(item.x, y, item.x + item.w, y)
                gfx.drawLine(item.x, y2, item.x + item.w, y2)
                gfx.drawLine(item.x, y, item.x, y2)
                gfx.drawLine(item.x + item.w, y, item.x + item.w, y2)

                if item.label and item.label ~= "" then
                    local font = Style.fontSmall or gfx.getFont()
                    gfx.setFont(font)
                    local label = item.label
                    local lw = Style.getTextWidth(font, label)
                    local maxLw = item.w - 14
                    if lw > maxLw then
                        label = string.sub(label, 1, math.max(1, math.floor(maxLw / 6))) .. ".."
                        lw = Style.getTextWidth(font, label)
                    end
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRect(item.x + 6, y - 4, lw + 4, 9)
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawText(label, item.x + 8, y - 5)
                end
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
