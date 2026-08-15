-- CometBrowser Start Page / Speed Dial View
import "core/constants"
import "core/storage"
import "render/style"

HomePage = {}
local gfx = playdate.graphics

HomePage.selectedIndex = 1
HomePage.scrollY = 0

-- Per-card marquee scroll state so oversized title/desc text scrolls within
-- its card box instead of overflowing outside it.
local marqueeState = {}

local function nowMs()
    if playdate.getCurrentTimeMilliseconds then
        return playdate.getCurrentTimeMilliseconds()
    end
    return 0
end

-- Draw text inside a maxW-wide box, clipping it and horizontally scrolling
-- (oscillating) when the text is wider than the box.
local function drawMarquee(text, x, y, maxW, font, key)
    gfx.setFont(font)
    local tw = Style.getTextWidth(font, text)
    if tw <= maxW then
        gfx.drawText(text, x, y)
        return
    end

    local range = tw - maxW
    local st = marqueeState[key]
    if not st then
        st = { startMs = nowMs() }
        marqueeState[key] = st
    end
    local elapsed = math.max(0, (nowMs() - st.startMs) / 1000)
    local speed = 50
    local dwell = 1.0
    local travel = range / speed
    local cycle = 2 * (dwell + travel)
    local t = elapsed % cycle
    local offset
    if t < dwell then
        offset = 0
    elseif t < dwell + travel then
        offset = (t - dwell) * speed
    elseif t < dwell + travel + dwell then
        offset = range
    else
        offset = range - (t - dwell - travel - dwell) * speed
    end

    gfx.setClipRect(x, y, maxW, 15)
    gfx.drawText(text, x - math.floor(offset), y)
    gfx.clearClipRect()
end

function HomePage.reset()
    HomePage.selectedIndex = 1
    HomePage.scrollY = 0
    marqueeState = {}
end

function HomePage.handleInput()
    local bookmarks = Storage.bookmarks or {}
    local count = #bookmarks
    if count == 0 then return nil end

    if playdate.buttonJustPressed(playdate.kButtonDown) then
        if HomePage.selectedIndex + 2 <= count then
            HomePage.selectedIndex = HomePage.selectedIndex + 2
        elseif HomePage.selectedIndex < count then
            HomePage.selectedIndex = HomePage.selectedIndex + 1
        end
    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
        if HomePage.selectedIndex - 2 >= 1 then
            HomePage.selectedIndex = HomePage.selectedIndex - 2
        elseif HomePage.selectedIndex > 1 then
            HomePage.selectedIndex = HomePage.selectedIndex - 1
        end
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        if HomePage.selectedIndex % 2 == 1 and HomePage.selectedIndex + 1 <= count then
            HomePage.selectedIndex = HomePage.selectedIndex + 1
        end
    elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
        if HomePage.selectedIndex % 2 == 0 then
            HomePage.selectedIndex = HomePage.selectedIndex - 1
        end
    end

    if playdate.buttonJustPressed(playdate.kButtonA) then
        local bm = bookmarks[HomePage.selectedIndex]
        if bm then
            return bm.url
        end
    end

    return nil
end

function HomePage.draw(crankChange)
    local bookmarks = Storage.bookmarks or {}
    local fontHeading = Style.fontHeading1 or gfx.getFont()
    local fontBold = Style.fontBodyBold or gfx.getFont()
    local fontBody = Style.fontBody or gfx.getFont()
    local fontSmall = Style.fontSmall or Style.fontMono or gfx.getFont()

    if crankChange and crankChange ~= 0 then
        HomePage.scrollY = math.max(0, HomePage.scrollY + crankChange * 1.5)
    end

    -- Auto-scroll to selected index
    local count = #bookmarks
    if count > 0 then
        local row = math.floor((HomePage.selectedIndex - 1) / 2)
        local cardY = (Constants.CONTENT_Y + 12 + 86 + 24) + row * (46 + 8)
        local displayY = cardY - HomePage.scrollY
        if displayY > Constants.SCREEN_HEIGHT - 60 then
            HomePage.scrollY = cardY - Constants.SCREEN_HEIGHT + 60
        elseif displayY < Constants.CONTENT_Y + 10 then
            HomePage.scrollY = math.max(0, cardY - Constants.CONTENT_Y - 10)
        end
    end

    local startY = Constants.CONTENT_Y + 12 - HomePage.scrollY

    -- 1. Comet Browser Logo Header
    -- Black background header bar
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, startY - 4, Constants.SCREEN_WIDTH, 54)

    -- Draw comet icon (pixel art: nucleus + tail)
    local cx = 30
    local cy = startY + 16
    -- Tail lines
    gfx.setColor(gfx.kColorWhite)
    for i = 0, 12 do
        if (i % 2 == 0) then
            gfx.drawLine(cx - i * 3, cy - i, cx - i * 3 - 4, cy - i + 2)
        end
    end
    -- Nucleus circle
    gfx.fillCircleAtPoint(cx, cy, 7)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(cx, cy, 4)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(cx - 1, cy - 2, 2)

    -- Title text
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.setFont(fontHeading)
    gfx.drawText("COMET BROWSER", 48, startY + 4)
    gfx.setFont(fontSmall)
    gfx.drawText("The Web on Playdate", 50, startY + 32)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    -- Address bar prompt pill
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(20, startY + 50, Constants.SCREEN_WIDTH - 40, 24, 4)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.setFont(fontBold)
    gfx.drawText("Press (B) to Type URL or Search Web", 32, startY + 54)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    -- Speed Dial Section Title
    local gridStartY = startY + 86
    gfx.setColor(gfx.kColorBlack)
    gfx.setFont(fontBold)
    gfx.drawText("SPEED DIAL / BOOKMARKS", 20, gridStartY)
    gfx.drawLine(20, gridStartY + 16, Constants.SCREEN_WIDTH - 20, gridStartY + 16)

    -- Speed Dial 2-Column Grid
    local cardW = 172
    local cardH = 46
    local gapX = 16
    local gapY = 8
    local cardsStartY = gridStartY + 24

    for i, bm in ipairs(bookmarks) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local cardX = 20 + col * (cardW + gapX)
        local cardY = cardsStartY + row * (cardH + gapY)

        local isSelected = (i == HomePage.selectedIndex)

        if isSelected then
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRoundRect(cardX, cardY, cardW, cardH, 5)
            gfx.setColor(gfx.kColorWhite)
            gfx.drawRoundRect(cardX + 1, cardY + 1, cardW - 2, cardH - 2, 4)
            gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        else
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(cardX, cardY, cardW, cardH, 5)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(cardX, cardY, cardW, cardH, 5)
            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        end

        local textAreaW = cardW - 16

        gfx.setFont(fontBold)
        drawMarquee(bm.title or bm.url, cardX + 8, cardY + 6, textAreaW, fontBold, "t" .. i)

        gfx.setFont(fontSmall)
        drawMarquee(bm.desc or bm.url, cardX + 8, cardY + 24, textAreaW, fontSmall, "d" .. i)

        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end

    local bottomY = cardsStartY + math.ceil(#bookmarks / 2) * (cardH + gapY) + 12
    gfx.setFont(fontSmall)
    gfx.drawText("(A) Open  •  (B) Search/URL  •  Crank Scroll", 24, bottomY)
end
