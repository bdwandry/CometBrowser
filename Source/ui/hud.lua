-- Floating HUD & Scrollbar for CometBrowser
import "core/constants"
import "render/style"

Hud = {}
local gfx = playdate.graphics

local hoverFont = nil
pcall(function() hoverFont = gfx.font.new("fonts/Roobert-10-Bold-Halved") end)
hoverFont = hoverFont or gfx.getFont()

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

-- Small status bar at bottom-left showing hovered link URL (like desktop browsers)
function Hud.drawHoverStatus(url)
    if not url or url == "" then return end

    local label = url
    if #label > 50 then
        label = string.sub(label, 1, 47) .. "..."
    end

    local font = hoverFont
    local fontH = font:getHeight()
    local tw = font:getTextWidth(label)
    local pad = 6
    local barW = math.min(Constants.SCREEN_WIDTH, tw + pad * 2)
    local barH = fontH + 4
    local barX = 0
    local barY = Constants.CONTENT_Y + Constants.CONTENT_HEIGHT - barH

    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(barX, barY, barW, barH)

    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.setFont(font)
    gfx.drawText(label, barX + pad, barY + 2)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end
