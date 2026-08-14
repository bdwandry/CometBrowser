-- Typography & Styling System for CometBrowser
Style = {}

local gfx = playdate.graphics

-- Font references
Style.fontHeading1 = nil
Style.fontHeading2 = nil
Style.fontHeading3 = nil
Style.fontBody = nil
Style.fontBodyBold = nil
Style.fontMono = nil
Style.fontSmall = nil

function Style.init()
    pcall(function()
        Style.fontHeading1 = gfx.font.new("fonts/Roobert-20-Medium")
    end)
    pcall(function()
        Style.fontHeading2 = gfx.font.new("fonts/Roobert-11-Bold")
    end)
    pcall(function()
        Style.fontHeading3 = gfx.font.new("fonts/Roobert-10-Bold")
    end)
    pcall(function()
        Style.fontBody = gfx.font.new("fonts/Roobert-11-Medium")
    end)
    pcall(function()
        Style.fontBodyBold = gfx.font.new("fonts/Roobert-11-Bold")
    end)
    pcall(function()
        Style.fontMono = gfx.font.new("fonts/Roobert-11-Mono-Condensed")
    end)

    local sysFont = gfx.getFont()
    Style.fontHeading1 = Style.fontHeading1 or sysFont
    Style.fontHeading2 = Style.fontHeading2 or sysFont
    Style.fontHeading3 = Style.fontHeading3 or sysFont
    Style.fontBody = Style.fontBody or sysFont
    Style.fontBodyBold = Style.fontBodyBold or sysFont
    Style.fontMono = Style.fontMono or sysFont
    Style.fontSmall = Style.fontSmall or sysFont
end

function Style.getTextWidth(font, text)
    if not text or text == "" then return 0 end
    font = font or Style.fontBody or gfx.getFont()
    if font and font.getTextWidth then
        local ok, w = pcall(function() return font:getTextWidth(text) end)
        if ok and w then return w end
    end
    local w, _ = gfx.getTextSize(text, font)
    return w or (#text * 8)
end

function Style.getHeadingFont(level)
    if level == 1 then
        return Style.fontHeading1, 24, 6
    elseif level == 2 then
        return Style.fontHeading2, 18, 5
    else
        return Style.fontHeading3, 16, 4
    end
end

function Style.getBodyFont(isBold, isCode)
    if isCode then
        return Style.fontMono, 15
    elseif isBold then
        return Style.fontBodyBold, 16
    else
        return Style.fontBody, 16
    end
end
