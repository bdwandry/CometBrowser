-- Cloud Render Layout Engine
import "core/constants"
import "render/style"
import "render/image_decoder"

CloudLayout = {}
local gfx = playdate.graphics

CloudLayout.renderItems = {}
CloudLayout.totalHeight = 0
CloudLayout.selectedInputItem = nil

function CloudLayout.parse(jsonString, baseUrl)
    -- json.decode is built into Playdate SDK
    local ok, data = pcall(function() return json.decode(jsonString) end)
    if not ok or not data then
        return { title = "Parse Error", elements = {}, totalHeight = 240 }
    end
    return {
        title = data.title or "Cloud Page",
        elements = data.elements or {},
        totalHeight = data.totalHeight or 240
    }
end

function CloudLayout.build(doc)
    CloudLayout.renderItems = {}
    CloudLayout.selectedInputItem = nil
    LinkManager.clear()
    
    if not doc or not doc.elements or #doc.elements == 0 then
        CloudLayout.totalHeight = Constants.CONTENT_HEIGHT
        return
    end

    CloudLayout.totalHeight = doc.totalHeight

    for _, el in ipairs(doc.elements) do
        -- Skip anything placed above the page (negative Y)
        if el.y >= 0 then
            local yOffset = Constants.CONTENT_Y + el.y
            
            if el.type == "text" then
                local font = Style.fontBody or gfx.getFont()
                if el.font == "large" then font = Style.fontHeading1 or gfx.getFont()
                elseif el.font == "bold" then font = Style.fontBodyBold or gfx.getFont()
                elseif el.font == "mono" then font = Style.fontMono or gfx.getFont() end
                
                table.insert(CloudLayout.renderItems, {
                    type = "text",
                    x = el.x, y = yOffset, w = el.w, h = el.h,
                    text = el.text, font = font
                })
            elseif el.type == "image" then
                table.insert(CloudLayout.renderItems, {
                    type = "image",
                    x = el.x, y = yOffset, w = el.w, h = el.h,
                    src = el.src, alt = "Image"
                })
            elseif el.type == "link" then
                -- Add to link manager
                LinkManager.addLink({
                    x = el.x, y = yOffset, w = el.w, h = el.h,
                    href = el.href
                })
            elseif el.type == "input" or el.type == "submit" then
                local item = {
                    type = el.type,
                    x = el.x, y = yOffset, w = el.w, h = el.h,
                    inputType = el.inputType,
                    name = el.name,
                    value = el.value,
                    placeholder = el.placeholder,
                    formAction = el.formAction,
                    label = el.label
                }
                table.insert(CloudLayout.renderItems, item)
                LinkManager.addLink({
                    x = el.x, y = yOffset, w = el.w, h = el.h,
                    isFormInput = true,
                    inputBlock = item
                })
            end
        end
    end
end

function CloudLayout.draw(scrollY)
    -- Background
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, Constants.CONTENT_Y, Constants.SCREEN_WIDTH, Constants.CONTENT_HEIGHT)

    gfx.pushContext()
    gfx.setClipRect(0, Constants.CONTENT_Y, Constants.SCREEN_WIDTH, Constants.CONTENT_HEIGHT)

    -- Draw Render Items
    for _, item in ipairs(CloudLayout.renderItems) do
        local drawY = item.y - scrollY
        -- Only draw if visible
        if drawY + item.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
            if item.type == "text" then
                gfx.setFont(item.font)
                gfx.drawTextInRect(item.text, item.x, drawY, item.w + 10, item.h + 10, nil, nil, kTextAlignment.left)
            elseif item.type == "image" then
                ImageDecoder.draw(item.x, drawY, item.w, item.h, item.alt, nil, false, item.src)
            elseif item.type == "input" then
                gfx.setColor(gfx.kColorWhite)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 3)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(item.x, drawY, item.w, item.h, 3)
                
                local font = Style.fontBody or gfx.getFont()
                gfx.setFont(font)
                local txt = (item.value and item.value ~= "") and item.value or item.placeholder
                gfx.drawTextInRect(txt, item.x + 4, drawY + 4, item.w - 8, item.h - 8)
            elseif item.type == "submit" then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(item.x, drawY, item.w, item.h, 3)
                gfx.setColor(gfx.kColorWhite)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                local font = Style.fontBodyBold or gfx.getFont()
                gfx.setFont(font)
                local lw = Style.getTextWidth(font, item.label)
                gfx.drawText(item.label, item.x + (item.w - lw) / 2, drawY + (item.h - 14) / 2)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end
        end
    end

    -- Draw Link Highlights
    local selLink = LinkManager.getSelectedLink()
    if selLink then
        local selY = selLink.y - scrollY
        if selY + selLink.h >= Constants.CONTENT_Y and selY <= Constants.SCREEN_HEIGHT then
            gfx.setColor(gfx.kColorBlack)
            gfx.setLineWidth(3)
            gfx.drawRoundRect(selLink.x - 2, selY - 2, selLink.w + 4, selLink.h + 4, 3)
            gfx.setLineWidth(1)
        end
    end

    gfx.popContext()

    -- Scrollbar
    local maxScroll = math.max(0, CloudLayout.totalHeight - Constants.CONTENT_HEIGHT)
    if maxScroll > 0 then
        local sbH = math.max(20, (Constants.CONTENT_HEIGHT / CloudLayout.totalHeight) * Constants.CONTENT_HEIGHT)
        local sbY = Constants.CONTENT_Y + (scrollY / maxScroll) * (Constants.CONTENT_HEIGHT - sbH)
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(Constants.SCREEN_WIDTH - Constants.SCROLLBAR_WIDTH, sbY, Constants.SCROLLBAR_WIDTH, sbH)
    end
end
