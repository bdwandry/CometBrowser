-- Bookmarks Manager View for CometBrowser
import "core/constants"
import "core/storage"
import "render/style"

BookmarksPage = {}
local gfx = playdate.graphics

BookmarksPage.selectedIndex = 1
BookmarksPage.scrollY = 0

function BookmarksPage.open()
    BookmarksPage.selectedIndex = 1
    BookmarksPage.scrollY = 0
end

function BookmarksPage.handleInput()
    local bms = Storage.bookmarks or {}
    local count = #bms
    if count == 0 then
        if playdate.buttonJustPressed(playdate.kButtonB) then
            return "close"
        end
        return nil
    end

    if playdate.buttonJustPressed(playdate.kButtonDown) then
        BookmarksPage.selectedIndex = math.min(count, BookmarksPage.selectedIndex + 1)
    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
        BookmarksPage.selectedIndex = math.max(1, BookmarksPage.selectedIndex - 1)
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        local sel = bms[BookmarksPage.selectedIndex]
        if sel then
            return sel.url
        end
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        return "close"
    end

    return nil
end

function BookmarksPage.draw(crankChange)
    local bms = Storage.bookmarks or {}
    local fontH = Style.fontHeading2 or gfx.getFont()
    local fontB = Style.fontBodyBold or gfx.getFont()
    local fontS = Style.fontSmall or Style.fontMono or gfx.getFont()

    if crankChange and crankChange ~= 0 then
        BookmarksPage.scrollY = math.max(0, BookmarksPage.scrollY + crankChange * 2)
    end

    local startY = Constants.CONTENT_Y + 10 - BookmarksPage.scrollY

    gfx.setColor(gfx.kColorBlack)
    gfx.setFont(fontH)
    gfx.drawText("BOOKMARKS & FAVORITES", 16, startY)
    gfx.drawLine(16, startY + 18, Constants.SCREEN_WIDTH - 16, startY + 18)

    local itemY = startY + 26
    local itemH = 34

    if #bms == 0 then
        gfx.setFont(fontB)
        gfx.drawText("No bookmarks saved yet. Use Menu to add bookmarks.", 16, itemY)
        return
    end

    for i, bm in ipairs(bms) do
        local isSel = (i == BookmarksPage.selectedIndex)
        local drawY = itemY + (i - 1) * (itemH + 4)

        if drawY + itemH >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
            if isSel then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(16, drawY, Constants.SCREEN_WIDTH - 32, itemH, 4)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
            else
                gfx.setColor(gfx.kColorWhite)
                gfx.fillRoundRect(16, drawY, Constants.SCREEN_WIDTH - 32, itemH, 4)
                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(16, drawY, Constants.SCREEN_WIDTH - 32, itemH, 4)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end

            gfx.setFont(fontB)
            local title = bm.title or bm.url
            if #title > 34 then title = string.sub(title, 1, 31) .. "..." end
            gfx.drawText(title, 24, drawY + 3)

            gfx.setFont(fontS)
            local u = bm.url or ""
            if #u > 46 then u = string.sub(u, 1, 43) .. "..." end
            gfx.drawText(u, 24, drawY + 18)

            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        end
    end
end
