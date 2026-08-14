-- Floating HUD & Scrollbar for CometBrowser
import "core/constants"
import "render/style"

Hud = {}
local gfx = playdate.graphics

function Hud.draw(scrollY, totalHeight, activeLink)
    if totalHeight > Constants.CONTENT_HEIGHT then
        local trackX = Constants.SCREEN_WIDTH - Constants.SCROLLBAR_WIDTH - 2
        local trackY = Constants.CONTENT_Y + 2
        local trackH = Constants.CONTENT_HEIGHT - 4

        gfx.setColor(gfx.kColorBlack)
        gfx.drawRect(trackX, trackY, Constants.SCROLLBAR_WIDTH, trackH)

        local thumbH = math.max(12, math.floor(trackH * (Constants.CONTENT_HEIGHT / totalHeight)))
        local maxScroll = totalHeight - Constants.CONTENT_HEIGHT
        local scrollRatio = math.min(1.0, math.max(0.0, scrollY / maxScroll))
        local thumbY = trackY + math.floor((trackH - thumbH) * scrollRatio)

        gfx.fillRect(trackX + 1, thumbY, Constants.SCROLLBAR_WIDTH - 2, thumbH)
    end

    if activeLink then
        local hudH = 20
        local hudY = Constants.SCREEN_HEIGHT - hudH
        
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(0, hudY, Constants.SCREEN_WIDTH, hudH)
        gfx.setColor(gfx.kColorWhite)
        gfx.drawLine(0, hudY, Constants.SCREEN_WIDTH, hudY)
        
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        local font = Style.fontSmall or Style.fontMono or gfx.getFont()
        gfx.setFont(font)
        
        local linkText = "-> " .. (activeLink.href or "")
        if #linkText > 56 then
            linkText = string.sub(linkText, 1, 53) .. "..."
        end
        gfx.drawText(linkText, 8, hudY + 3)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
end
