-- Pure Lua On-Device GIF Decoder for Playdate
import "render/decoders/dither"

GIFDecoder = {}

local function readUInt16LE(str, pos)
    local b1, b2 = string.byte(str, pos, pos + 1)
    if not b1 or not b2 then return 0 end
    return b1 + (b2 << 8)
end

function GIFDecoder.decode(data)
    if not data or #data < 14 then return nil end

    local sig = string.sub(data, 1, 6)
    if sig ~= "GIF87a" and sig ~= "GIF89a" then return nil end

    local screenW = readUInt16LE(data, 7)
    local screenH = readUInt16LE(data, 9)
    local packed  = string.byte(data, 11) or 0

    local hasGlobalPal = (packed & 0x80) ~= 0
    local palSizePower  = (packed & 0x07)
    local globalPalCount = 1 << (palSizePower + 1)

    local pos = 14
    local globalPal = {}

    if hasGlobalPal then
        for i = 0, globalPalCount - 1 do
            local r, g, b = string.byte(data, pos, pos + 2)
            if r and g and b then
                globalPal[i] = Dither.rgbToGray(r, g, b)
            else
                globalPal[i] = 0
            end
            pos = pos + 3
        end
    end

    -- Process blocks until we find the first Image Descriptor (0x2C)
    while pos <= #data do
        local b = string.byte(data, pos)
        if not b or b == 0x3B then -- Trailer
            break
        elseif b == 0x21 then -- Extension block
            local extType = string.byte(data, pos + 1)
            pos = pos + 2
            -- Skip sub-blocks
            while pos <= #data do
                local blockSize = string.byte(data, pos) or 0
                pos = pos + 1
                if blockSize == 0 then break end
                pos = pos + blockSize
            end
        elseif b == 0x2C then -- Image Descriptor!
            local imgLeft = readUInt16LE(data, pos + 1)
            local imgTop  = readUInt16LE(data, pos + 3)
            local imgW    = readUInt16LE(data, pos + 5)
            local imgH    = readUInt16LE(data, pos + 7)
            local imgPacked = string.byte(data, pos + 9) or 0
            pos = pos + 10

            local hasLocalPal = (imgPacked & 0x80) ~= 0
            local palette = globalPal

            if hasLocalPal then
                local localPalSize = 1 << ((imgPacked & 0x07) + 1)
                palette = {}
                for i = 0, localPalSize - 1 do
                    local r, g, b = string.byte(data, pos, pos + 2)
                    if r and g and b then
                        palette[i] = Dither.rgbToGray(r, g, b)
                    else
                        palette[i] = 0
                    end
                    pos = pos + 3
                end
            end

            local minCodeSize = string.byte(data, pos) or 2
            pos = pos + 1

            -- Gather all LZW sub-blocks into a single stream
            local lzwChunks = {}
            while pos <= #data do
                local blockSize = string.byte(data, pos) or 0
                pos = pos + 1
                if blockSize == 0 then break end
                table.insert(lzwChunks, string.sub(data, pos, pos + blockSize - 1))
                pos = pos + blockSize
            end
            local lzwData = table.concat(lzwChunks)

            -- LZW Decompression
            local clearCode = 1 << minCodeSize
            local endCode   = clearCode + 1
            local codeSize  = minCodeSize + 1
            local maxCode   = 1 << codeSize

            -- Initialize code table
            local prefix = {}
            local suffix = {}
            local stack  = {}

            local function initCodeTable()
                codeSize = minCodeSize + 1
                maxCode  = 1 << codeSize
                for i = 0, clearCode - 1 do
                    prefix[i] = -1
                    suffix[i] = i
                end
            end
            initCodeTable()

            local nextCode = endCode + 1
            local oldCode = -1

            local bitPos = 0
            local totalBits = #lzwData * 8

            local function readCode()
                local bytePos = (bitPos >> 3) + 1
                local bitOffset = bitPos & 7
                if bytePos > #lzwData then return end

                local b1 = string.byte(lzwData, bytePos) or 0
                local b2 = string.byte(lzwData, bytePos + 1) or 0
                local b3 = string.byte(lzwData, bytePos + 2) or 0
                local val = (b1 | (b2 << 8) | (b3 << 16)) >> bitOffset
                bitPos = bitPos + codeSize
                return val & ((1 << codeSize) - 1)
            end

            local decodedPixels = {}
            local pixelCount = imgW * imgH

            while #decodedPixels < pixelCount do
                local code = readCode()
                if not code or code == endCode then break end

                if code == clearCode then
                    initCodeTable()
                    nextCode = endCode + 1
                    oldCode = -1
                else
                    local inCode = code
                    local top = 0

                    if code >= nextCode then
                        if oldCode >= 0 then
                            top = top + 1
                            stack[top] = firstChar
                            code = oldCode
                        else
                            break
                        end
                    end

                    while code >= 0 and code < 4096 do
                        if prefix[code] ~= nil and prefix[code] >= 0 then
                            top = top + 1
                            stack[top] = suffix[code]
                            code = prefix[code]
                        else
                            top = top + 1
                            stack[top] = suffix[code] or code
                            break
                        end
                    end

                    firstChar = stack[top] or 0
                    while top > 0 do
                        table.insert(decodedPixels, stack[top])
                        top = top - 1
                    end

                    if oldCode >= 0 and nextCode < 4096 then
                        prefix[nextCode] = oldCode
                        suffix[nextCode] = firstChar
                        nextCode = nextCode + 1
                        if nextCode >= maxCode and codeSize < 12 then
                            codeSize = codeSize + 1
                            maxCode = 1 << codeSize
                        end
                    end

                    oldCode = inCode
                end
            end

            -- Scale down if larger than Playdate screen
            local width = imgW
            local height = imgH
            local scale = 1
            if width > 360 or height > 200 then
                scale = math.max(width / 360, height / 200)
            end
            local targetW = math.max(1, math.floor(width / scale))
            local targetH = math.max(1, math.floor(height / scale))

            local function getPixelGray(outX, outY)
                local srcX = math.min(imgW - 1, math.floor(outX * scale))
                local srcY = math.min(imgH - 1, math.floor(outY * scale))
                local idx = srcY * imgW + srcX + 1
                local palIdx = decodedPixels[idx] or 0
                return palette[palIdx] or 255
            end

            return Dither.toImage(getPixelGray, targetW, targetH)
        else
            pos = pos + 1
        end
    end

    return nil
end
