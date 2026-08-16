-- Pure Lua On-Device ICO Decoder for Playdate
-- Parses the ICO container, then delegates to the PNG decoder for PNG-compressed
-- entries or a small embedded-BMP reader for classic DIB entries. Classic icons
-- store their DIB height doubled (image + trailing 1bpp AND mask); rows are
-- bottom-up for a positive height. AND-mask bits set to 1 are fully transparent
-- (composited over white), matching Chromium's ICO handling.
import "render/decoders/dither"
import "render/decoders/png"

ICODecoder = {}

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

local function composite(gray, a)
    if a >= 255 then return gray end
    if a <= 0 then return 255 end
    return math.floor((gray * a + 255 * (255 - a)) / 255 + 0.5)
end

-- Decode a classic embedded DIB (BITMAPINFOHEADER with no "BM" file header).
local function decodeDIB(data, maxW, maxH)
    if not data or #data < 40 then return nil end

    local headerSize  = readUInt32LE(data, 1)
    local width       = readInt32LE(data, 5)
    local rawHeight   = readInt32LE(data, 9)
    local bpp         = readUInt16LE(data, 15)
    local compression = readUInt32LE(data, 17)

    if headerSize < 40 or width <= 0 or rawHeight == 0 or compression ~= 0 then
        return nil
    end
    if bpp ~= 1 and bpp ~= 4 and bpp ~= 8 and bpp ~= 24 and bpp ~= 32 then
        return nil
    end

    -- The stored height is doubled (image rows + AND mask rows).
    local isTopDown = (rawHeight < 0)
    local height = math.floor(math.abs(rawHeight) / 2)
    if height <= 0 then return nil end

    local palette = {}
    if bpp <= 8 then
        local numColors = (1 << bpp)
        local palOffset = headerSize + 1
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

    local rowBytes      = math.floor((bpp * width + 31) / 32) * 4
    local andRowBytes   = math.floor((width + 31) / 32) * 4
    local pixelOffset   = headerSize + 1 + ((bpp <= 8) and ((1 << bpp) * 4) or 0)
    local andMaskOffset = pixelOffset + rowBytes * height
    local hasMask = (andMaskOffset - 1 + andRowBytes * height) <= #data

    local scale = 1
    if width > maxW or height > maxH then
        scale = math.max(width / maxW, height / maxH)
    end
    local targetW = math.max(1, math.floor(width / scale))
    local targetH = math.max(1, math.floor(height / scale))

    local function getPixelGray(outX, outY)
        local srcX = math.min(width - 1, math.floor(outX * scale))
        local srcY = math.min(height - 1, math.floor(outY * scale))
        local bmpY = isTopDown and srcY or (height - 1 - srcY)
        local rowStart = pixelOffset + bmpY * rowBytes

        local gray, alpha
        if bpp == 32 then
            local pPos = rowStart + srcX * 4
            local b, g, r, a = string.byte(data, pPos, pPos + 3)
            gray  = Dither.rgbToGray(r or 0, g or 0, b or 0)
            alpha = a or 255
        elseif bpp == 24 then
            local pPos = rowStart + srcX * 3
            local b, g, r = string.byte(data, pPos, pPos + 2)
            gray  = Dither.rgbToGray(r or 0, g or 0, b or 0)
            alpha = 255
        elseif bpp == 8 then
            local idx = string.byte(data, rowStart + srcX) or 0
            gray  = palette[idx] or 0
            alpha = 255
        elseif bpp == 4 then
            local b = string.byte(data, rowStart + (srcX >> 1)) or 0
            local idx = (srcX % 2 == 0) and ((b >> 4) & 0x0F) or (b & 0x0F)
            gray  = palette[idx] or 0
            alpha = 255
        else
            local b = string.byte(data, rowStart + (srcX >> 3)) or 0
            local idx = (b >> (7 - (srcX % 8))) & 1
            gray  = palette[idx] or (idx == 1 and 255 or 0)
            alpha = 255
        end

        -- AND mask bit set means fully transparent.
        if hasMask then
            local mRow = andMaskOffset + bmpY * andRowBytes
            local mb = string.byte(data, mRow + (srcX >> 3)) or 0
            if ((mb >> (7 - (srcX % 8))) & 1) == 1 then return 255 end
        end

        if alpha < 255 then return composite(gray, alpha) end
        return gray
    end

    return Dither.toImage(getPixelGray, targetW, targetH)
end

function ICODecoder.decode(data, maxW, maxH)
    if not data or #data < 22 then return nil end

    -- ICONDIR: reserved(2)=0, type(2): 1 = icon, 2 = cursor, count(2)
    local reserved = readUInt16LE(data, 1)
    local fileType = readUInt16LE(data, 3)
    local count    = readUInt16LE(data, 5)
    if reserved ~= 0 or (fileType ~= 1 and fileType ~= 2) or count == 0 then
        return nil
    end

    maxW = maxW or 360
    maxH = maxH or 200

    local entries = {}
    for i = 0, count - 1 do
        local base = 7 + i * 16
        local w = string.byte(data, base) or 0
        local h = string.byte(data, base + 1) or 0
        if w == 0 then w = 256 end
        if h == 0 then h = 256 end
        local bitCount = (fileType == 1) and readUInt16LE(data, base + 6) or 0
        local byteSize = readUInt32LE(data, base + 8)
        local imageOffset = readUInt32LE(data, base + 12)
        if imageOffset > 0 and byteSize > 0 and imageOffset + byteSize <= #data then
            entries[#entries + 1] = {
                w = w, h = h, bpp = bitCount,
                offset = imageOffset, size = byteSize,
            }
        end
    end
    if #entries == 0 then return nil end

    -- Best entry: largest area, then highest bit depth (matches Chromium).
    table.sort(entries, function(a, b)
        if a.w * a.h == b.w * b.h then return a.bpp > b.bpp end
        return a.w * a.h > b.w * b.h
    end)

    -- Try each entry in order until one decodes successfully.
    for _, e in ipairs(entries) do
        local chunk = string.sub(data, e.offset + 1, e.offset + e.size)
        local a, b, c, d = string.byte(chunk, 1, 4)
        if a == 0x89 and b == 0x50 and c == 0x4E and d == 0x47 then
            local ok, img = pcall(function() return PNGDecoder.decode(chunk, maxW, maxH) end)
            if ok and img then return img end
        else
            local ok, img = pcall(function() return decodeDIB(chunk, maxW, maxH) end)
            if ok and img then return img end
        end
    end
    return nil
end
