-- Pure Lua On-Device PNG Decoder for Playdate
-- Streams the zlib scanline data (never holding the full uncompressed image),
-- unfilters one row at a time and box-filters it down to ~screen size so a huge
-- PNG (e.g. 2000x1500) decodes in bounded memory. Adam7 interlaced PNGs are
-- decoded from their first pass, which samples every 8th pixel.
import "render/decoders/dither"
import "render/decoders/inflate"
import "render/decoders/scale"

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

-- Composite an 8-bit gray value over a white background given alpha in 0..255
local function composite(gray, a)
    if a >= 255 then return gray end
    if a <= 0 then return 255 end
    return math.floor((gray * a + 255 * (255 - a)) / 255 + 0.5)
end

function PNGDecoder.decode(data, maxW, maxH)
    if not data or #data < 24 then return nil end

    -- Check PNG signature
    local sig = string.sub(data, 1, 8)
    if sig ~= "\137PNG\r\n\026\n" and sig ~= "\x89PNG\r\n\x1a\n" then
        if string.byte(data, 1) ~= 0x89 or string.sub(data, 2, 4) ~= "PNG" then
            return nil
        end
    end

    local pos = 9
    local width, height, bitDepth, colorType, interlace
    local palette = {}   -- palette[i] = gray value (1-based)
    local paletteA = {}  -- paletteAlpha[i] = alpha (0..255), only if tRNS present
    local idatChunks = {}
    local tRNSdata = nil

    while pos <= #data do
        local chunkLen  = readUInt32BE(data, pos)
        local chunkType = string.sub(data, pos + 4, pos + 7)
        local chunkDataPos = pos + 8
        pos = pos + 12 + chunkLen
        if pos > #data + 12 then break end

        if chunkType == "IHDR" then
            width     = readUInt32BE(data, chunkDataPos)
            height    = readUInt32BE(data, chunkDataPos + 4)
            bitDepth  = string.byte(data, chunkDataPos + 8) or 8
            colorType = string.byte(data, chunkDataPos + 9) or 0
            interlace = string.byte(data, chunkDataPos + 12) or 0

        elseif chunkType == "PLTE" then
            local numColors = math.floor(chunkLen / 3)
            for i = 1, numColors do
                local p = chunkDataPos + (i - 1) * 3
                local r, g, b = string.byte(data, p, p + 2)
                palette[i] = Dither.rgbToGray(r or 0, g or 0, b or 0)
                paletteA[i] = 255
            end

        elseif chunkType == "tRNS" then
            tRNSdata = string.sub(data, chunkDataPos, chunkDataPos + chunkLen - 1)

        elseif chunkType == "IDAT" then
            table.insert(idatChunks, string.sub(data, chunkDataPos, chunkDataPos + chunkLen - 1))

        elseif chunkType == "IEND" then
            break
        end
    end

    if not width or not height or width <= 0 or height <= 0 then return nil end
    maxW = maxW or 360
    maxH = maxH or 200

    -- tRNS for palette: one alpha byte per entry
    if tRNSdata and colorType == 3 then
        for i = 1, #tRNSdata do
            paletteA[i] = string.byte(tRNSdata, i) or 255
        end
    end

    local channels = 1
    if colorType == 2 then channels = 3
    elseif colorType == 3 then channels = 1
    elseif colorType == 4 then channels = 2
    elseif colorType == 6 then channels = 4
    end

    -- For interlaced images decode only the first Adam7 pass (every 8th pixel).
    local srcW, srcH = width, height
    if interlace == 1 then
        srcW = math.max(1, math.ceil(width / 8))
        srcH = math.max(1, math.ceil(height / 8))
    end

    local rowBytes = math.floor((srcW * channels * bitDepth + 7) / 8)
    local bppBytes = math.max(1, math.floor(channels * bitDepth / 8))
    local sampleBytes = math.max(1, bitDepth // 8)

    local compressedData = table.concat(idatChunks)
    local inflate = Inflate.createStream(compressedData)
    if not inflate then return nil end

    local acc = Scale.newAccum(srcW, srcH, maxW, maxH)
    local _, _, targetW, targetH = Scale.boxSizes(srcW, srcH, maxW, maxH)

    local prevRow = {}
    local curRow  = {}
    local grayRow = {}
    for i = 1, rowBytes do prevRow[i] = 0 end

    local unpackMask = (bitDepth < 8) and ((1 << bitDepth) - 1) or 0
    local grayScale  = (bitDepth < 8) and (255 // unpackMask) or 1
    local perByte    = (bitDepth < 8) and (8 // bitDepth) or 1

    -- tRNS keys for grayscale / truecolor
    local tRNSkey  = nil   -- gray value (0..255) or {r,g,b}
    if tRNSdata then
        if colorType == 0 and #tRNSdata >= 2 then
            tRNSkey = string.byte(tRNSdata, 1)
        elseif colorType == 2 and #tRNSdata >= 6 then
            tRNSkey = { string.byte(tRNSdata, 1), string.byte(tRNSdata, 3), string.byte(tRNSdata, 5) }
        end
    end

    local done = false
    for y = 1, srcH do
        local header = inflate:read(1)
        if not header then done = true break end
        local filterType = string.byte(header, 1) or 0

        local rawChunk = inflate:read(rowBytes)
        if not rawChunk then done = true break end

        -- Unfilter the row byte-by-byte
        for x = 1, rowBytes do
            local xv = string.byte(rawChunk, x) or 0
            local a  = (x > bppBytes) and curRow[x - bppBytes] or 0
            local b  = prevRow[x] or 0
            local c  = (x > bppBytes) and prevRow[x - bppBytes] or 0
            if filterType == 0 then
                curRow[x] = xv
            elseif filterType == 1 then
                curRow[x] = (xv + a) & 0xFF
            elseif filterType == 2 then
                curRow[x] = (xv + b) & 0xFF
            elseif filterType == 3 then
                curRow[x] = (xv + ((a + b) >> 1)) & 0xFF
            elseif filterType == 4 then
                curRow[x] = (xv + paethPredictor(a, b, c)) & 0xFF
            else
                curRow[x] = xv
            end
        end

        -- Convert to grayscale row
        if colorType == 0 then
            if bitDepth == 16 then
                for x = 1, srcW do
                    grayRow[x] = curRow[(x - 1) * 2 + 1]
                end
            elseif bitDepth == 8 then
                for x = 1, srcW do grayRow[x] = curRow[x] end
            else
                for x = 1, srcW do
                    local byteIdx = (x - 1) // perByte + 1
                    local shift = 8 - bitDepth - ((x - 1) % perByte) * bitDepth
                    grayRow[x] = ((curRow[byteIdx] >> shift) & unpackMask) * grayScale
                end
            end
            if tRNSkey then
                for x = 1, srcW do
                    if grayRow[x] == tRNSkey then grayRow[x] = 255 end
                end
            end

        elseif colorType == 3 then
            -- Palette (indexed)
            for x = 1, srcW do
                local idx
                if bitDepth == 8 then
                    idx = curRow[x] + 1
                else
                    local byteIdx = (x - 1) // perByte + 1
                    local shift = 8 - bitDepth - ((x - 1) % perByte) * bitDepth
                    idx = ((curRow[byteIdx] >> shift) & unpackMask) + 1
                end
                local g = palette[idx] or 255
                local a = paletteA[idx] or 255
                grayRow[x] = composite(g, a)
            end

        elseif colorType == 2 or colorType == 6 then
            -- RGB / RGBA (sampleBytes = 1 or 2 for 16-bit). RGBA alpha is
            -- composited over white, matching the palette path.
            local step = 3
            if colorType == 6 then step = 4 end
            if tRNSkey then
                local kr, kg, kb = tRNSkey[1], tRNSkey[2], tRNSkey[3]
                for x = 1, srcW do
                    local p = (x - 1) * step * sampleBytes + 1
                    local r, g, b = curRow[p], curRow[p + sampleBytes], curRow[p + sampleBytes * 2]
                    if r == kr and g == kg and b == kb then
                        grayRow[x] = 255
                    else
                        local gv = Dither.rgbToGray(r or 0, g or 0, b or 0)
                        if colorType == 6 then
                            grayRow[x] = composite(gv, curRow[p + sampleBytes * 3] or 255)
                        else
                            grayRow[x] = gv
                        end
                    end
                end
            else
                for x = 1, srcW do
                    local p = (x - 1) * step * sampleBytes + 1
                    local gv = Dither.rgbToGray(curRow[p] or 0, curRow[p + sampleBytes] or 0, curRow[p + sampleBytes * 2] or 0)
                    if colorType == 6 then
                        grayRow[x] = composite(gv, curRow[p + sampleBytes * 3] or 255)
                    else
                        grayRow[x] = gv
                    end
                end
            end

        elseif colorType == 4 then
            -- Grayscale + alpha
            if bitDepth == 16 then
                for x = 1, srcW do
                    local p = (x - 1) * 4 + 1
                    grayRow[x] = composite(curRow[p] or 0, curRow[p + 2] or 255)
                end
            else
                for x = 1, srcW do
                    local p = (x - 1) * 2 + 1
                    grayRow[x] = composite(curRow[p] or 0, curRow[p + 1] or 255)
                end
            end
        end

        acc.addRow(grayRow)
        prevRow, curRow = curRow, prevRow
    end

    local rows = acc.finish()
    if acc.count == 0 then return nil end
    return Dither.toImage(function(x, y)
        local r = rows[y]
        if not r then return 255 end
        return r[x + 1] or 255
    end, targetW, targetH)
end
