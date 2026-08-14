-- Pure Lua On-Device BMP Decoder for Playdate
import "render/decoders/dither"

BMPDecoder = {}

local function readUInt16LE(str, pos)
    local b1, b2 = string.byte(str, pos, pos + 1)
    if not b1 or not b2 then return 0 end
    return b1 + (b2 << 8)
end

local function readUInt32LE(str, pos)
    local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
    if not b1 or not b4 then return 0 end
    return b1 + (b2 << 8) + (b3 << 16) + (b4 << 24)
end

local function readInt32LE(str, pos)
    local v = readUInt32LE(str, pos)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

function BMPDecoder.decode(data)
    if not data or #data < 54 then return nil end

    -- Check signature "BM"
    local sig = string.sub(data, 1, 2)
    if sig ~= "BM" then return nil end

    local pixelOffset = readUInt32LE(data, 11)
    local headerSize  = readUInt32LE(data, 15)
    local width       = readInt32LE(data, 19)
    local rawHeight   = readInt32LE(data, 23)
    local bpp         = readUInt16LE(data, 29)
    local compression = readUInt32LE(data, 31)

    if width <= 0 or rawHeight == 0 then return nil end
    local isTopDown = (rawHeight < 0)
    local height = math.abs(rawHeight)

    -- Scale down if larger than Playdate screen
    local scale = 1
    if width > 360 or height > 200 then
        local scaleX = width / 360
        local scaleY = height / 200
        scale = math.max(scaleX, scaleY)
    end
    local targetW = math.max(1, math.floor(width / scale))
    local targetH = math.max(1, math.floor(height / scale))

    -- Palette for indexed modes (1, 4, 8 bpp)
    local palette = {}
    if bpp <= 8 then
        local numColors = (1 << bpp)
        local palOffset = 15 + headerSize
        for i = 0, numColors - 1 do
            local pPos = palOffset + i * 4
            local b, g, r = string.byte(data, pPos, pPos + 2)
            if b and g and r then
                palette[i] = Dither.rgbToGray(r, g, b)
            else
                palette[i] = 0
            end
        end
    end

    local rowBytes = math.floor((bpp * width + 31) / 32) * 4

    local function getPixelGray(outX, outY)
        local srcX = math.min(width - 1, math.floor(outX * scale))
        local srcY = math.min(height - 1, math.floor(outY * scale))
        local bmpY = isTopDown and srcY or (height - 1 - srcY)

        local rowStart = pixelOffset + 1 + bmpY * rowBytes

        if bpp == 24 then
            local pPos = rowStart + srcX * 3
            local b, g, r = string.byte(data, pPos, pPos + 2)
            if r and g and b then
                return Dither.rgbToGray(r, g, b)
            end
        elseif bpp == 32 then
            local pPos = rowStart + srcX * 4
            local b, g, r = string.byte(data, pPos, pPos + 2)
            if r and g and b then
                return Dither.rgbToGray(r, g, b)
            end
        elseif bpp == 8 then
            local pPos = rowStart + srcX
            local idx = string.byte(data, pPos)
            return palette[idx or 0] or 0
        elseif bpp == 4 then
            local byteIdx = srcX >> 1
            local pPos = rowStart + byteIdx
            local b = string.byte(data, pPos) or 0
            local idx = (srcX % 2 == 0) and ((b >> 4) & 0x0F) or (b & 0x0F)
            return palette[idx] or 0
        elseif bpp == 1 then
            local byteIdx = srcX >> 3
            local bitIdx = 7 - (srcX % 8)
            local pPos = rowStart + byteIdx
            local b = string.byte(data, pPos) or 0
            local idx = (b >> bitIdx) & 1
            return palette[idx] or (idx == 1 and 255 or 0)
        end
        return 255
    end

    return Dither.toImage(getPixelGray, targetW, targetH)
end
