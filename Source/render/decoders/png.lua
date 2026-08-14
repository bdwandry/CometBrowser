-- Pure Lua On-Device PNG Decoder for Playdate
import "render/decoders/dither"
import "render/decoders/inflate"

PNGDecoder = {}

local function readUInt32BE(str, pos)
    local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
    if not b1 or not b4 then return 0 end
    return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
end

local function paethPredictor(a, b, c)
    local p = a + b - c
    local pa = math.abs(p - a)
    local pb = math.abs(p - b)
    local pc = math.abs(p - c)
    if pa <= pb and pa <= pc then return a
    elseif pb <= pc then return b
    else return c end
end

function PNGDecoder.decode(data)
    if not data or #data < 24 then return nil end

    -- Check PNG signature
    local sig = string.sub(data, 1, 8)
    if sig ~= "\137PNG\r\n\026\n" and sig ~= "\x89PNG\r\n\x1a\n" then
        if string.byte(data, 1) ~= 0x89 or string.sub(data, 2, 4) ~= "PNG" then
            return nil
        end
    end

    local pos = 9
    local width, height, bitDepth, colorType
    local palette = {}
    local idatChunks = {}

    while pos <= #data do
        local chunkLen  = readUInt32BE(data, pos)
        local chunkType = string.sub(data, pos + 4, pos + 7)
        local chunkDataPos = pos + 8
        pos = pos + 12 + chunkLen

        if chunkType == "IHDR" then
            width     = readUInt32BE(data, chunkDataPos)
            height    = readUInt32BE(data, chunkDataPos + 4)
            bitDepth  = string.byte(data, chunkDataPos + 8)
            colorType = string.byte(data, chunkDataPos + 9)

        elseif chunkType == "PLTE" then
            local numColors = math.floor(chunkLen / 3)
            for i = 0, numColors - 1 do
                local r, g, b = string.byte(data, chunkDataPos + i * 3, chunkDataPos + i * 3 + 2)
                palette[i] = Dither.rgbToGray(r or 0, g or 0, b or 0)
            end

        elseif chunkType == "IDAT" then
            table.insert(idatChunks, string.sub(data, chunkDataPos, chunkDataPos + chunkLen - 1))

        elseif chunkType == "IEND" then
            break
        end
    end

    if not width or not height or width <= 0 or height <= 0 then return nil end

    -- Decompress IDAT stream
    local compressedData = table.concat(idatChunks)
    local rawData = Inflate.decompress(compressedData)
    if not rawData or #rawData == 0 then return nil end

    -- Determine bytes per pixel (BPP)
    local channels = 1
    if colorType == 2 then channels = 3      -- Truecolor RGB
    elseif colorType == 3 then channels = 1  -- Indexed (palette)
    elseif colorType == 4 then channels = 2  -- Grayscale with alpha
    elseif colorType == 6 then channels = 4  -- Truecolor RGBA
    end

    local bytesPerPixel = math.max(1, math.floor(channels * (bitDepth / 8)))
    local rowBytes = math.floor((width * channels * bitDepth + 7) / 8)

    -- Unfilter scanlines
    local uncompressedRows = {}
    local prevRow = {}
    for i = 1, rowBytes do prevRow[i] = 0 end

    local rawPos = 1
    for y = 0, height - 1 do
        if rawPos > #rawData then break end
        local filterType = string.byte(rawData, rawPos) or 0
        rawPos = rawPos + 1

        local curRow = {}
        for x = 1, rowBytes do
            local xVal = string.byte(rawData, rawPos) or 0
            rawPos = rawPos + 1

            local a = (x > bytesPerPixel) and curRow[x - bytesPerPixel] or 0
            local b = prevRow[x] or 0
            local c = (x > bytesPerPixel) and prevRow[x - bytesPerPixel] or 0

            if filterType == 0 then -- None
                curRow[x] = xVal
            elseif filterType == 1 then -- Sub
                curRow[x] = (xVal + a) & 0xFF
            elseif filterType == 2 then -- Up
                curRow[x] = (xVal + b) & 0xFF
            elseif filterType == 3 then -- Average
                curRow[x] = (xVal + ((a + b) >> 1)) & 0xFF
            elseif filterType == 4 then -- Paeth
                curRow[x] = (xVal + paethPredictor(a, b, c)) & 0xFF
            else
                curRow[x] = xVal
            end
        end

        uncompressedRows[y] = curRow
        prevRow = curRow
    end

    -- Scale down if larger than Playdate screen
    local scale = 1
    if width > 360 or height > 200 then
        scale = math.max(width / 360, height / 200)
    end
    local targetW = math.max(1, math.floor(width / scale))
    local targetH = math.max(1, math.floor(height / scale))

    local function getPixelGray(outX, outY)
        local srcX = math.min(width - 1, math.floor(outX * scale))
        local srcY = math.min(height - 1, math.floor(outY * scale))
        local row = uncompressedRows[srcY]
        if not row then return 255 end

        if colorType == 2 then -- RGB
            local p = srcX * 3 + 1
            local r = row[p] or 0
            local g = row[p + 1] or 0
            local b = row[p + 2] or 0
            return Dither.rgbToGray(r, g, b)
        elseif colorType == 6 then -- RGBA
            local p = srcX * 4 + 1
            local r = row[p] or 0
            local g = row[p + 1] or 0
            local b = row[p + 2] or 0
            local a = row[p + 3] or 255
            if a < 64 then return 255 end -- Transparent background is white
            local gray = Dither.rgbToGray(r, g, b)
            return math.floor(gray * (a / 255) + 255 * (1 - a / 255))
        elseif colorType == 3 then -- Indexed Palette
            local idx = row[srcX + 1] or 0
            return palette[idx] or 0
        elseif colorType == 0 then -- Grayscale
            return row[srcX + 1] or 0
        elseif colorType == 4 then -- Grayscale + Alpha
            local p = srcX * 2 + 1
            local gray = row[p] or 0
            local a = row[p + 1] or 255
            if a < 64 then return 255 end
            return math.floor(gray * (a / 255) + 255 * (1 - a / 255))
        end
        return 255
    end

    return Dither.toImage(getPixelGray, targetW, targetH)
end
