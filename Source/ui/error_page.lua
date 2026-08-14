-- Error Page Display for CometBrowser
import "core/constants"
import "render/style"

ErrorPage = {}
local gfx = playdate.graphics

ErrorPage.selectedIndex = 1
ErrorPage.errorMsg = "Unable to load webpage"
ErrorPage.failedUrl = ""

function ErrorPage.show(errorMsg, failedUrl)
    ErrorPage.errorMsg = errorMsg or "Unable to load webpage"
    ErrorPage.failedUrl = failedUrl or ""
    ErrorPage.selectedIndex = 1
end

function ErrorPage.handleInput()
    if playdate.buttonJustPressed(playdate.kButtonLeft) or playdate.buttonJustPressed(playdate.kButtonUp) then
        ErrorPage.selectedIndex = math.max(1, ErrorPage.selectedIndex - 1)
    elseif playdate.buttonJustPressed(playdate.kButtonRight) or playdate.buttonJustPressed(playdate.kButtonDown) then
        ErrorPage.selectedIndex = math.min(3, ErrorPage.selectedIndex + 1)
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        if ErrorPage.selectedIndex == 1 then
            return "retry"
        elseif ErrorPage.selectedIndex == 2 then
            return "search"
        elseif ErrorPage.selectedIndex == 3 then
            return "home"
        end
    end

    return nil
end

function ErrorPage.draw()
    local fontH = Style.fontHeading1 or gfx.getFont()
    local fontB = Style.fontBody or gfx.getFont()
    local fontBold = Style.fontBodyBold or gfx.getFont()
    local fontSmall = Style.fontSmall or Style.fontMono or gfx.getFont()

    local startY = Constants.CONTENT_Y + 16

    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(20, startY, Constants.SCREEN_WIDTH - 40, 120, 6)
    
    gfx.setFont(fontH)
    gfx.drawText("Connection Failed", 36, startY + 12)

    gfx.setFont(fontBold)
    local msg = ErrorPage.errorMsg
    if #msg > 48 then msg = string.sub(msg, 1, 45) .. "..." end
    gfx.drawText(msg, 36, startY + 40)

    gfx.setFont(fontSmall)
    local u = ErrorPage.failedUrl
    if #u > 50 then u = string.sub(u, 1, 47) .. "..." end
    gfx.drawText("Target: " .. u, 36, startY + 60)

    gfx.setFont(fontB)
    gfx.drawText("Check your Wi-Fi or try searching the web.", 36, startY + 82)

    local buttons = { "Try Again", "Search Web", "Go Home" }
    local btnW = 100
    local btnH = 28
    local btnY = startY + 136
    local startX = 36

    for i, label in ipairs(buttons) do
        local btnX = startX + (i - 1) * (btnW + 16)
        local isSel = (i == ErrorPage.selectedIndex)

        if isSel then
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRoundRect(btnX, btnY, btnW, btnH, 4)
            gfx.setColor(gfx.kColorWhite)
            gfx.drawRoundRect(btnX + 1, btnY + 1, btnW - 2, btnH - 2, 3)
            gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        else
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(btnX, btnY, btnW, btnH, 4)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(btnX, btnY, btnW, btnH, 4)
            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        end

        gfx.setFont(fontBold)
        local tw = Style.getTextWidth(fontBold, label)
        gfx.drawText(label, btnX + math.floor((btnW - tw) / 2), btnY + 6)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
end
