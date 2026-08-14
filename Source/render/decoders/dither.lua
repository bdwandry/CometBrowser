-- Fast 1-Bit Dithering Engine for Playdate
local gfx = playdate.graphics

Dither = {}

-- 4x4 Bayer Dither Matrix scaled to 0-255 threshold
local bayer4x4 = {
    {   0, 128,  32, 160 },
    { 192,  64, 224,  96 },
    {  48, 176,  16, 144 },
    { 240, 112, 208,  80 }
}

-- Fast luminance from RGB
function Dither.rgbToGray(r, g, b)
    -- Standard luminance: 0.299*R + 0.587*G + 0.114*B (scaled by 1024)
    return (r * 306 + g * 601 + b * 117) >> 10
end

-- Paint a 2D grayscale grid (or 1D array of [0..255]) into a new Playdate 1-bit image
-- Uses horizontal run-length batching with fillRect for high performance
function Dither.toImage(getPixelGray, width, height)
    if not width or not height or width <= 0 or height <= 0 then return nil end
    if width > 380 then width = 380 end
    if height > 240 then height = 240 end

    local img = gfx.image.new(width, height, gfx.kColorWhite)
    if not img then return nil end

    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)

    for y = 0, height - 1 do
        local bayerRow = bayer4x4[(y % 4) + 1]
        local runStart = nil

        for x = 0, width - 1 do
            local gray = getPixelGray(x, y)
            local threshold = bayerRow[(x % 4) + 1]
            local isBlack = (gray < threshold)

            if isBlack then
                if not runStart then runStart = x end
            else
                if runStart then
                    gfx.fillRect(runStart, y, x - runStart, 1)
                    runStart = nil
                end
            end
        end

        if runStart then
            gfx.fillRect(runStart, y, width - runStart, 1)
            runStart = nil
        end
    end

    gfx.popContext()
    return img
end
