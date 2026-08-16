-- Pure Lua On-Device GIF Decoder for Playdate
--
-- Decodes the first frame of a GIF87a/89a, streaming LZW output straight into
-- the box-filter downscaler so a full-resolution pixel buffer is never
-- allocated (memory stays bounded on the ~16MB Playdate). Pixels are converted
-- to grayscale as they are produced; the logical screen is used as the source
-- canvas (white background), so small frames composited at an offset are laid
-- out correctly. Animated GIFs render as their first frame. The decode loop
-- calls Tasks.yieldCheck() so large images decode cooperatively.
import "render/decoders/dither"
import "render/decoders/scale"
import "core/tasks"

GIFDecoder = {}

local function readUInt16LE(str, pos)
    local b1, b2 = string.byte(str, pos, pos + 1)
    if not b1 or not b2 then return 0 end
    return b1 + (b2 << 8)
end

function GIFDecoder.decode(data, maxW, maxH)
    if not data or #data < 14 then return nil end

    local sig = string.sub(data, 1, 6)
    if sig ~= "GIF87a" and sig ~= "GIF89a" then return nil end

    maxW = maxW or 360
    maxH = maxH or 200

    local screenW = readUInt16LE(data, 7)
    local screenH = readUInt16LE(data, 9)
    local packed  = string.byte(data, 11) or 0

    local hasGlobalPal = (packed & 0x80) ~= 0
    local globalPalCount = 1 << ((packed & 0x07) + 1)

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
    local transparentIndex = nil

    while pos <= #data do
        local b = string.byte(data, pos)
        if not b or b == 0x3B then -- Trailer
            return nil
        elseif b == 0x21 then -- Extension block
            local extType = string.byte(data, pos + 1)
            pos = pos + 2
            if extType == 0xF9 then -- Graphic Control Extension (transparency)
                local gcePacked = string.byte(data, pos + 1) or 0
                if (gcePacked & 1) ~= 0 then
                    transparentIndex = string.byte(data, pos + 4)
                end
            end
            while pos <= #data do
                local blockSize = string.byte(data, pos) or 0
                pos = pos + 1
                if blockSize == 0 then break end
                pos = pos + blockSize
            end
        elseif b == 0x2C then -- Image Descriptor!
            local imgLeft   = readUInt16LE(data, pos + 1)
            local imgTop    = readUInt16LE(data, pos + 3)
            local imgW      = readUInt16LE(data, pos + 5)
            local imgH      = readUInt16LE(data, pos + 7)
            local imgPacked = string.byte(data, pos + 9) or 0
            pos = pos + 10

            local palette = globalPal

            if (imgPacked & 0x80) ~= 0 then -- local palette
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

            -- Concatenate LZW sub-blocks into a single bitstream
            local lzwChunks = {}
            while pos <= #data do
                local blockSize = string.byte(data, pos) or 0
                pos = pos + 1
                if blockSize == 0 then break end
                table.insert(lzwChunks, string.sub(data, pos, pos + blockSize - 1))
                pos = pos + blockSize
            end
            local lzwData = table.concat(lzwChunks)

            -- LZW state (GIF variant: codes widen from minCodeSize+1 to 12)
            local clearCode = 1 << minCodeSize
            local endCode   = clearCode + 1
            local codeSize  = minCodeSize + 1
            local maxCode   = 1 << codeSize

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
            local oldCode  = -1
            local firstChar = 0

            local bitPos = 0

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

            -- Stream decoded frame rows into the box-filter downscaler. The
            -- LZW stream emits rows in a non-linear order for interlaced
            -- frames, so those rows are buffered and replayed in linear order.
            local acc = Scale.newAccum(screenW, screenH, maxW, maxH)
            local rowBuf = {}
            local canvasRow = {}
            local rowIdx = 0
            local x = 0
            local pixelCounter = 0
            local interlaced = (imgPacked & 0x40) ~= 0

            local interlaceRows
            local bufferedRows
            local blankRow
            if interlaced then
                interlaceRows = {}
                for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
                    local r = pass[1]
                    while r < imgH do
                        interlaceRows[#interlaceRows + 1] = r
                        r = r + pass[2]
                    end
                end
                bufferedRows = {}
                blankRow = {}
                for i = 1, screenW do blankRow[i] = 255 end
            end

            local function flushRow()
                for cx = x, imgW - 1 do rowBuf[cx + 1] = 255 end
                for i = 1, screenW do canvasRow[i] = 255 end
                for cx = 0, imgW - 1 do
                    canvasRow[imgLeft + cx + 1] = rowBuf[cx + 1]
                end
                if interlaced then
                    local linearRow = interlaceRows[rowIdx + 1]
                    local copy = {}
                    for i = 1, screenW do copy[i] = canvasRow[i] end
                    bufferedRows[linearRow + 1] = copy
                else
                    acc.addRow(canvasRow)
                end
                rowIdx = rowIdx + 1
                x = 0
            end

            local function endStream()
                for cx = x, imgW - 1 do rowBuf[cx + 1] = 255 end
                flushRow()
                while rowIdx < imgH do flushRow() end
            end

            while rowIdx < imgH do
                local code = readCode()
                if not code or code == endCode then
                    endStream()
                    break
                end

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
                            endStream()
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

                    -- Emit the decoded run into rowBuf, flushing rows as they
                    -- fill so runs that span a row boundary survive it.
                    while top > 0 and rowIdx < imgH do
                        local palIdx = stack[top]
                        top = top - 1
                        if palIdx == transparentIndex then
                            rowBuf[x + 1] = 255
                        else
                            rowBuf[x + 1] = palette[palIdx] or 255
                        end
                        x = x + 1
                        if x >= imgW then
                            flushRow()
                            pixelCounter = pixelCounter + 1
                            if pixelCounter % 8 == 0 then Tasks.yieldCheck() end
                        end
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

            if interlaced then
                for y = 0, imgH - 1 do
                    acc.addRow(bufferedRows[y + 1] or blankRow)
                end
            end

            local out, targetW, targetH = acc.finish()
            local function getPixelGray(outX, outY)
                local row = out[outY]
                return row and row[outX + 1] or 255
            end
            return Dither.toImage(getPixelGray, targetW, targetH)
        else
            pos = pos + 1
        end
    end

    return nil
end
