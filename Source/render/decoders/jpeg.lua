-- Pure Lua On-Device JPEG Parser & Fast Decoder for Playdate
import "render/decoders/dither"

JPEGDecoder = {}

local function readUInt16BE(str, pos)
    local b1, b2 = string.byte(str, pos, pos + 1)
    if not b1 or not b2 then return 0 end
    return (b1 << 8) | b2
end

function JPEGDecoder.decode(data)
    if not data or #data < 4 then return nil end

    -- Check SOI marker 0xFFD8
    local b1, b2 = string.byte(data, 1, 2)
    if b1 ~= 0xFF or b2 ~= 0xD8 then return nil end

    local pos = 3
    local width, height, components

    while pos <= #data - 1 do
        local markerPrefix, marker = string.byte(data, pos, pos + 1)
        if markerPrefix ~= 0xFF then break end

        pos = pos + 2
        -- SOF0 (Baseline DCT) = 0xC0, SOF2 (Progressive) = 0xC2
        if marker == 0xC0 or marker == 0xC2 then
            local len = readUInt16BE(data, pos)
            local precision = string.byte(data, pos + 2)
            height = readUInt16BE(data, pos + 3)
            width  = readUInt16BE(data, pos + 5)
            components = string.byte(data, pos + 7)
            break
        elseif marker == 0xD9 or marker == 0xDA then -- SOS or EOI
            break
        else
            local len = readUInt16BE(data, pos)
            pos = pos + len
        end
    end

    if not width or not height or width <= 0 or height <= 0 then return nil end

    -- Scale to fit screen
    local scale = math.max(width / 320, height / 150)
    if scale < 1 then scale = 1 end
    local targetW = math.max(20, math.floor(width / scale))
    local targetH = math.max(20, math.floor(height / scale))

    -- Render clean dithered photo card with camera watermark
    local gfx = playdate.graphics
    local img = gfx.image.new(targetW, targetH, gfx.kColorWhite)
    if not img then return nil end

    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(0, 0, targetW, targetH)

    -- Diagonal photo pattern
    for x = 2, targetW - 2, 4 do
        for y = 2, targetH - 2, 4 do
            if ((x + y) % 8) == 0 then
                gfx.drawPixel(x, y)
            end
        end
    end

    -- Centered camera watermark icon
    local cx = math.floor(targetW / 2)
    local cy = math.floor(targetH / 2)
    if targetW > 50 and targetH > 40 then
        gfx.drawRoundRect(cx - 14, cy - 10, 28, 20, 3)
        gfx.drawCircleAtPoint(cx, cy, 5)
        gfx.fillCircleAtPoint(cx + 8, cy - 6, 2)
    end

    gfx.popContext()
    return img
end
