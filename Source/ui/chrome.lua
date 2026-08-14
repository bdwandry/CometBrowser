-- Top Chrome / Navigation Toolbar for CometBrowser
import "core/constants"
import "render/style"

Chrome = {}
local gfx = playdate.graphics

local cometAnimFrame = 0

function Chrome.draw(urlObj, pageTitle, isLoading, progressCur, progressTot, isReaderMode)
    cometAnimFrame = cometAnimFrame + 1
    
    -- Draw top bar background
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, Constants.SCREEN_WIDTH, Constants.CHROME_HEIGHT)
    
    -- White bottom separator line
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(0, Constants.CHROME_HEIGHT - 1, Constants.SCREEN_WIDTH, Constants.CHROME_HEIGHT - 1)

    -- 1. SSL Lock Icon or Globe Icon
    local isSsl = urlObj and urlObj.isSsl
    gfx.setColor(gfx.kColorWhite)
    if isSsl then
        gfx.drawRoundRect(6, 6, 8, 8, 3)
        gfx.fillRect(5, 10, 10, 8)
        gfx.setColor(gfx.kColorBlack)
        gfx.fillCircleAtPoint(10, 14, 1)
        gfx.setColor(gfx.kColorWhite)
    else
        gfx.drawCircleAtPoint(10, 13, 6)
        gfx.drawLine(4, 13, 16, 13)
        gfx.drawLine(10, 7, 10, 19)
    end

    -- 2. URL / Title text
    local font = Style.fontBodyBold or gfx.getFont()
    local fontSmall = Style.fontSmall or Style.fontMono or gfx.getFont()
    gfx.setFont(font)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

    local displayHost = "CometBrowser"
    if urlObj then
        if urlObj.scheme == "about" then
            displayHost = "about:" .. (urlObj.host or "home")
        elseif urlObj.host and urlObj.host ~= "" then
            displayHost = urlObj.host
        end
    end
    if #displayHost > 28 then
        displayHost = string.sub(displayHost, 1, 25) .. "..."
    end
    gfx.drawText(displayHost, 22, 4)

    -- 3. Reader Mode Indicator Badge
    if urlObj and urlObj.scheme ~= "about" and not isLoading then
        local badgeText = isReaderMode and "[READ]" or "[WEB]"
        gfx.setFont(fontSmall)
        local badgeW = Style.getTextWidth(fontSmall, badgeText)
        gfx.drawText(badgeText, Constants.SCREEN_WIDTH - badgeW - 62, 6)
    end

    -- 4. Right Status: Loading Animation or Time
    if isLoading then
        -- Animated comet dots
        local baseX = Constants.SCREEN_WIDTH - 18
        local baseY = 13
        local phase = cometAnimFrame % 12
        gfx.setColor(gfx.kColorWhite)
        if phase < 4 then
            gfx.fillCircleAtPoint(baseX, baseY, 3)
        elseif phase < 8 then
            gfx.fillCircleAtPoint(baseX - 4, baseY, 2)
            gfx.fillCircleAtPoint(baseX, baseY, 1)
        else
            gfx.fillCircleAtPoint(baseX - 8, baseY, 1)
            gfx.fillCircleAtPoint(baseX - 4, baseY, 2)
            gfx.fillCircleAtPoint(baseX, baseY, 3)
        end

        -- Progress bar
        local pct = 0.0
        if progressTot and progressTot > 0 then
            pct = math.min(1.0, (progressCur or 0) / progressTot)
        else
            pct = ((cometAnimFrame * 3) % 100) / 100
        end
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, Constants.CHROME_HEIGHT - 2, math.floor(Constants.SCREEN_WIDTH * pct), 2)
    else
        -- Time display
        local timeFormatted = "--:--"
        pcall(function()
            local t = playdate.getTime()
            timeFormatted = string.format("%02d:%02d", t.hour, t.minute)
        end)
        local timeW = Style.getTextWidth(font, timeFormatted)
        gfx.setFont(font)
        gfx.drawText(timeFormatted, Constants.SCREEN_WIDTH - timeW - 6, 4)
    end

    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end
