-- Pure Lua On-Device WebP Decoder for CometBrowser
--
-- Implements the WebP container (RIFF), the lossless (VP8L) image codec and
-- the lossy (VP8) image codec, ported from libwebp's vp8l_dec.c /
-- huffman_utils.c / lossless.c and vp8_dec.c / frame_dec.c / tree_dec.c /
-- quant_dec.c / dsp/dec.c. VP8 output matches `dwebp -ppm` byte-for-byte
-- (MODE_RGB, fancy upsampling). Decoded output is composited over
-- white and box-filtered down to the target size with the shared Scale module.
import "render/decoders/dither"
import "render/decoders/scale"
import "render/decoders/webp_vp8_data"
import "core/tasks"

if WebPDecoder ~= nil then return end

WebPDecoder = {}

-- ---------------------------------------------------------------------------
-- Constants (from libwebp format_constants.h / huffman_utils.h)

local VP8L_MAGIC_BYTE          = 0x2F
local VP8L_IMAGE_SIZE_BITS     = 14
local HUFFMAN_CODES_PER_META   = 5
local MAX_CACHE_BITS           = 11
local DEFAULT_CODE_LENGTH      = 8
local MAX_ALLOWED_CODE_LENGTH  = 15
local NUM_LITERAL_CODES        = 256
local NUM_LENGTH_CODES         = 24
local NUM_DISTANCE_CODES       = 40
local NUM_CODE_LENGTH_CODES    = 19
local CODE_TO_PLANE_CODES      = 120
local MIN_HUFFMAN_BITS         = 2
local NUM_HUFFMAN_BITS         = 3
local MIN_TRANSFORM_BITS       = 2
local NUM_TRANSFORM_BITS       = 3
local HUFFMAN_TABLE_BITS       = 8
local HUFFMAN_TABLE_MASK       = (1 << HUFFMAN_TABLE_BITS) - 1
local LENGTHS_TABLE_BITS       = 7
local LENGTHS_TABLE_MASK       = (1 << LENGTHS_TABLE_BITS) - 1
local ARGB_BLACK               = 0xFF000000

local PREDICTOR_TRANSFORM      = 0
local CROSS_COLOR_TRANSFORM    = 1
local SUBTRACT_GREEN_TRANSFORM = 2
local COLOR_INDEXING_TRANSFORM = 3

local kCodeLengthLiterals        = 16
local kCodeLengthRepeatCode      = 16
local kCodeLengthExtraBits       = { 2, 3, 7 }
local kCodeLengthRepeatOffsets   = { 3, 3, 11 }
local kCodeLengthCodeOrder       = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
local kCodeToPlane               = { 0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a,
    0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a, 0x25, 0x2b, 0x48, 0x04,
    0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45,
    0x4b, 0x34, 0x3c, 0x03, 0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d,
    0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e,
    0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f, 0x64, 0x6c, 0x42, 0x4e,
    0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e,
    0x00, 0x74, 0x7c, 0x41, 0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d,
    0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70 }

local kAlphabetSize = {
    NUM_LITERAL_CODES + NUM_LENGTH_CODES,  -- green + lengths + cache
    NUM_LITERAL_CODES,                     -- red
    NUM_LITERAL_CODES,                     -- blue
    NUM_LITERAL_CODES,                     -- alpha
    NUM_DISTANCE_CODES,                    -- distance
}
local kLiteralMap = { 0, 1, 1, 1, 0 }

-- ---------------------------------------------------------------------------
-- Little-endian bit reader (VP8L reads bits LSB-first)

local function newBitReader(data, startPos)
    return { data = data, len = #data, pos = startPos, window = 0, nbits = 0, eos = false }
end

local function brPrefetch(br, want)
    local w = br.window
    local nb = br.nbits
    local pos = br.pos
    local data = br.data
    while nb < want and pos <= br.len do
        w = w | (data:byte(pos) << nb)
        pos = pos + 1
        nb = nb + 8
    end
    br.window = w
    br.nbits = nb
    br.pos = pos
    return w & ((1 << want) - 1)
end

local function brAdvance(br, n)
    br.nbits = br.nbits - n
    br.window = br.window >> n
    if br.nbits < 0 then
        br.eos = true
        br.nbits = 0
    end
end

local function brReadBits(br, n)
    if n == 0 then return 0 end
    local v = brPrefetch(br, n)
    if br.nbits < n then
        br.eos = true
        return 0
    end
    brAdvance(br, n)
    return v
end

-- Read one symbol from a Huffman table. Tables are flat arrays of
-- (bits << 16) | value, built with a two-level scheme mirroring libwebp.
local function readSymbol(table, br)
    local val = brPrefetch(br, 16)
    local low = val & HUFFMAN_TABLE_MASK
    local entry = table[low]
    local nbits = (entry >> 16) - HUFFMAN_TABLE_BITS
    if nbits > 0 then
        brAdvance(br, HUFFMAN_TABLE_BITS)
        local val2 = brPrefetch(br, nbits)
        entry = table[low + (entry & 0xFFFF) + (val2 & ((1 << nbits) - 1))]
        brAdvance(br, entry >> 16)
    else
        brAdvance(br, entry >> 16)
    end
    return entry & 0xFFFF
end

local function readSymbol7(table, br)
    local val = brPrefetch(br, 15)
    local low = val & LENGTHS_TABLE_MASK
    local entry = table[low]
    local nbits = (entry >> 16) - LENGTHS_TABLE_BITS
    if nbits > 0 then
        brAdvance(br, LENGTHS_TABLE_BITS)
        local val2 = brPrefetch(br, nbits)
        entry = table[low + (entry & 0xFFFF) + (val2 & ((1 << nbits) - 1))]
        brAdvance(br, entry >> 16)
    else
        brAdvance(br, entry >> 16)
    end
    return entry & 0xFFFF
end

-- ---------------------------------------------------------------------------
-- Huffman table construction (port of BuildHuffmanTable from huffman_utils.c)

local function replicateValue(table, base, step, end_, code)
    local currentEnd = end_
    repeat
        currentEnd = currentEnd - step
        table[base + currentEnd] = code
    until currentEnd <= 0
end

local function getNextKey(key, len)
    local step = 1 << (len - 1)
    while (key & step) ~= 0 do
        step = step >> 1
    end
    if step == 0 then return key end
    return (key & (step - 1)) + step
end

local function nextTableBitSize(count, len, rootBits)
    local left = 1 << (len - rootBits)
    while len < MAX_ALLOWED_CODE_LENGTH do
        left = left - count[len]
        if left <= 0 then break end
        len = len + 1
        left = left << 1
    end
    return len - rootBits
end

-- Returns the flat lookup table, or nil on error (invalid code).
local function buildHuffmanTable(codeLengths, codeLengthsSize, rootBits)
    local totalSize = 1 << rootBits
    local count = {}
    local offset = {}
    for i = 0, MAX_ALLOWED_CODE_LENGTH do
        count[i] = 0
        offset[i] = 0
    end

    for symbol = 0, codeLengthsSize - 1 do
        local cl = codeLengths[symbol]
        if cl > MAX_ALLOWED_CODE_LENGTH then return nil end
        count[cl] = count[cl] + 1
    end
    if count[0] == codeLengthsSize then return nil end

    offset[1] = 0
    for len = 1, MAX_ALLOWED_CODE_LENGTH - 1 do
        if count[len] > (1 << len) then return nil end
        offset[len + 1] = offset[len] + count[len]
    end

    local sorted = {}
    for symbol = 0, codeLengthsSize - 1 do
        local cl = codeLengths[symbol]
        if cl > 0 then
            if offset[cl] >= codeLengthsSize then return nil end
            sorted[offset[cl]] = symbol
            offset[cl] = offset[cl] + 1
        end
    end

    if offset[MAX_ALLOWED_CODE_LENGTH] == 1 then
        local table = {}
        replicateValue(table, 0, 1, totalSize, sorted[0])
        return table
    end

    local table = {}
    local low = 0xFFFFFFFF
    local mask = totalSize - 1
    local key = 0
    local numNodes = 1
    local numOpen = 1
    local symbol = 0
    local tableBits = rootBits
    local tableSize = 1 << tableBits

    -- Fill in root table.
    for len = 1, rootBits do
        numOpen = numOpen << 1
        numNodes = numNodes + numOpen
        numOpen = numOpen - count[len]
        if numOpen < 0 then return nil end
        local step = 2 << (len - 1)
        while count[len] > 0 do
            count[len] = count[len] - 1
            local code = (len << 16) | sorted[symbol]
            symbol = symbol + 1
            replicateValue(table, key, step, tableSize, code)
            key = getNextKey(key, len)
        end
    end

    -- Fill in 2nd level tables and add pointers to root table.
    local tablePos = 0
    for len = rootBits + 1, MAX_ALLOWED_CODE_LENGTH do
        numOpen = numOpen << 1
        numNodes = numNodes + numOpen
        numOpen = numOpen - count[len]
        if numOpen < 0 then return nil end
        local step = 2 << (len - rootBits - 1)
        while count[len] > 0 do
            count[len] = count[len] - 1
            if (key & mask) ~= low then
                tablePos = tablePos + tableSize
                tableBits = nextTableBitSize(count, len, rootBits)
                tableSize = 1 << tableBits
                totalSize = totalSize + tableSize
                low = key & mask
                table[low] = ((tableBits + rootBits) << 16) | (tablePos - low)
            end
            local code = ((len - rootBits) << 16) | sorted[symbol]
            symbol = symbol + 1
            replicateValue(table, tablePos + (key >> rootBits), step, tableSize, code)
            key = getNextKey(key, len)
        end
    end

    if numNodes ~= 2 * offset[MAX_ALLOWED_CODE_LENGTH] - 1 then return nil end
    return table
end

-- ---------------------------------------------------------------------------
-- Code length code / Huffman code reading

local function readHuffmanCodeLengths(br, codeLengthCodeLengths, numSymbols, codeLengths)
    local table = buildHuffmanTable(codeLengthCodeLengths, NUM_CODE_LENGTH_CODES, LENGTHS_TABLE_BITS)
    if not table then return false end

    local maxSymbol
    if brReadBits(br, 1) == 1 then
        local lengthNbits = 2 + 2 * brReadBits(br, 3)
        maxSymbol = 2 + brReadBits(br, lengthNbits)
        if maxSymbol > numSymbols then return false end
    else
        maxSymbol = numSymbols
    end

    local symbol = 0
    local prevCodeLen = DEFAULT_CODE_LENGTH
    while symbol < numSymbols do
        if maxSymbol == 0 then break end
        maxSymbol = maxSymbol - 1
        local val = brPrefetch(br, 15)
        if br.nbits < LENGTHS_TABLE_BITS then br.eos = true return false end
        local p = table[val & LENGTHS_TABLE_MASK]
        brAdvance(br, p >> 16)
        local codeLen = p & 0xFFFF
        if codeLen < kCodeLengthLiterals then
            codeLengths[symbol] = codeLen
            symbol = symbol + 1
            if codeLen ~= 0 then prevCodeLen = codeLen end
        else
            local usePrev = (codeLen == kCodeLengthRepeatCode)
            local slot = codeLen - kCodeLengthLiterals
            local repeatCount = brReadBits(br, kCodeLengthExtraBits[slot + 1]) + kCodeLengthRepeatOffsets[slot + 1]
            if symbol + repeatCount > numSymbols then return false end
            local length = usePrev and prevCodeLen or 0
            for i = 1, repeatCount do
                codeLengths[symbol] = length
                symbol = symbol + 1
            end
        end
    end
    return true
end

local codeLengthCodeLengths = {}

local function readHuffmanCode(alphabetSize, br, codeLengths)
    for i = 0, alphabetSize - 1 do codeLengths[i] = 0 end
    if brReadBits(br, 1) == 1 then
        local numSymbols = brReadBits(br, 1) + 1
        local firstSymbolLenCode = brReadBits(br, 1)
        local symbol = brReadBits(br, (firstSymbolLenCode == 0) and 1 or 8)
        codeLengths[symbol] = 1
        if numSymbols == 2 then
            symbol = brReadBits(br, 8)
            codeLengths[symbol] = 1
        end
    else
        local numCodes = brReadBits(br, 4) + 4
        for i = 0, NUM_CODE_LENGTH_CODES - 1 do codeLengthCodeLengths[i] = 0 end
        for i = 0, numCodes - 1 do
            codeLengthCodeLengths[kCodeLengthCodeOrder[i + 1]] = brReadBits(br, 3)
        end
        if not readHuffmanCodeLengths(br, codeLengthCodeLengths, alphabetSize, codeLengths) then
            return nil
        end
    end
    if br.eos then return nil end
    return buildHuffmanTable(codeLengths, alphabetSize, HUFFMAN_TABLE_BITS)
end

-- ---------------------------------------------------------------------------
-- Meta Huffman codes / htree groups

local decodeImageStream  -- forward declaration (defined below)

local function readHuffmanCodes(br, xsize, ysize, colorCacheBits, allowRecursion, ctx)
    local huffmanImage = nil
    local numHtreeGroups = 1
    local numHtreeGroupsMax = 1
    local mapping = nil

    if allowRecursion and brReadBits(br, 1) == 1 then
        local huffmanPrecision = MIN_HUFFMAN_BITS + brReadBits(br, NUM_HUFFMAN_BITS)
        local huffmanXsize = (xsize + (1 << huffmanPrecision) - 1) >> huffmanPrecision
        local huffmanYsize = (ysize + (1 << huffmanPrecision) - 1) >> huffmanPrecision
        local huffmanPixs = huffmanXsize * huffmanYsize
        local subCtx = {}
        huffmanImage = decodeImageStream(huffmanXsize, huffmanYsize, false, br, subCtx)
        if not huffmanImage then return false end
        ctx.huffmanSubsampleBits = huffmanPrecision
        for i = 0, huffmanPixs - 1 do
            local group = (huffmanImage[i] >> 8) & 0xFFFF
            huffmanImage[i] = group
            if group >= numHtreeGroupsMax then numHtreeGroupsMax = group + 1 end
        end
        if numHtreeGroupsMax > 1000 or numHtreeGroupsMax > xsize * ysize then
            mapping = {}
            for i = 0, numHtreeGroupsMax - 1 do mapping[i] = -1 end
            numHtreeGroups = 0
            for i = 0, huffmanPixs - 1 do
                local g = huffmanImage[i]
                local mapped = mapping[g]
                if mapped == -1 then
                    mapping[g] = numHtreeGroups
                    mapped = numHtreeGroups
                    numHtreeGroups = numHtreeGroups + 1
                end
                huffmanImage[i] = mapped
            end
        else
            numHtreeGroups = numHtreeGroupsMax
        end
    end

    if br.eos then return false end

    local htreeGroups = {}
    local codeLengths = {}
    for i = 0, numHtreeGroupsMax - 1 do
        if mapping and mapping[i] == -1 then
            for j = 1, HUFFMAN_CODES_PER_META do
                local alphaSize = kAlphabetSize[j]
                if j == 1 and colorCacheBits > 0 then alphaSize = alphaSize + (1 << colorCacheBits) end
                if not readHuffmanCode(alphaSize, br, codeLengths) then return false end
            end
        else
            local gi = (mapping == nil) and i or mapping[i]
            local group = { htrees = {} }
            local totalSize = 0
            local isTrivialLiteral = true
            for j = 1, HUFFMAN_CODES_PER_META do
                local alphaSize = kAlphabetSize[j]
                if j == 1 and colorCacheBits > 0 then alphaSize = alphaSize + (1 << colorCacheBits) end
                local t = readHuffmanCode(alphaSize, br, codeLengths)
                if not t then return false end
                group.htrees[j] = t
                local firstBits = t[0] >> 16
                totalSize = totalSize + firstBits
                if kLiteralMap[j] == 1 and firstBits ~= 0 then isTrivialLiteral = false end
            end
            if isTrivialLiteral then
                local red   = group.htrees[2][0] & 0xFFFF
                local blue  = group.htrees[3][0] & 0xFFFF
                local alpha = group.htrees[4][0] & 0xFFFF
                group.literalArb = (alpha << 24) | (red << 16) | blue
                if totalSize == 0 then
                    local greenVal = group.htrees[1][0] & 0xFFFF
                    if greenVal < NUM_LITERAL_CODES then
                        group.isTrivialCode = true
                        group.literalArgb = group.literalArb | (greenVal << 8)
                    end
                end
            end
            htreeGroups[gi] = group
        end
    end

    ctx.huffmanImage = huffmanImage
    ctx.numHtreeGroups = numHtreeGroups
    ctx.htreeGroups = htreeGroups
    return true
end

-- ---------------------------------------------------------------------------
-- LZ77 helpers

local function getCopyDistance(distanceSymbol, br)
    if distanceSymbol < 4 then return distanceSymbol + 1 end
    local extraBits = (distanceSymbol - 2) >> 1
    local offset = (2 + (distanceSymbol & 1)) << extraBits
    return offset + brReadBits(br, extraBits) + 1
end

local function getCopyLength(lengthSymbol, br)
    return getCopyDistance(lengthSymbol, br)
end

local function planeCodeToDistance(xsize, planeCode)
    if planeCode > CODE_TO_PLANE_CODES then return planeCode - CODE_TO_PLANE_CODES end
    local distCode = kCodeToPlane[planeCode]
    local yoffset = distCode >> 4
    local xoffset = 8 - (distCode & 0xF)
    local dist = yoffset * xsize + xoffset
    if dist < 1 then return 1 end
    return dist
end

-- ---------------------------------------------------------------------------
-- Color cache

local kHashMul = 0x1e35a7bd

local function newColorCache(bits)
    local size = 1 << bits
    local colors = {}
    for i = 0, size - 1 do colors[i] = 0 end
    return { colors = colors, hashShift = 32 - bits }
end

local function colorCacheInsert(cc, argb)
    local key = ((argb * kHashMul) & 0xFFFFFFFF) >> cc.hashShift
    cc.colors[key] = argb
end

local function colorCacheLookup(cc, key)
    return cc.colors[key]
end

-- ---------------------------------------------------------------------------
-- Image data (LZ77) decoding

local function decodeImageData(br, ctx, data, width, height)
    local row = 0
    local col = 0
    local src = 0
    local lenCodeLimit = NUM_LITERAL_CODES + NUM_LENGTH_CODES
    local colorCacheLimit = lenCodeLimit + ctx.colorCacheSize
    local srcEnd = width * height
    local huffmanBits = ctx.huffmanSubsampleBits
    local huffmanImage = ctx.huffmanImage
    local huffmanXsize = ctx.huffmanXsize
    local htreeGroups = ctx.htreeGroups
    local colorCache = ctx.colorCache
    local mask = (huffmanBits == 0) and 0xFFFFFFFF or ((1 << huffmanBits) - 1)
    local group = nil
    local lastCached = 0

    while src < srcEnd do
        Tasks.yieldCheck()
        if (col & mask) == 0 then
            local metaIndex = 0
            if huffmanBits ~= 0 then
                metaIndex = huffmanImage[huffmanXsize * (row >> huffmanBits) + (col >> huffmanBits)]
            end
            group = htreeGroups[metaIndex]
        end
        if not group then return false end
        if group.isTrivialCode then
            data[src] = group.literalArgb
            src = src + 1
            col = col + 1
            if col >= width then
                col = 0
                row = row + 1
            end
            if colorCache then
                while lastCached < src do
                    colorCacheInsert(colorCache, data[lastCached])
                    lastCached = lastCached + 1
                end
            end
        else
            local code = readSymbol(group.htrees[1], br)
            if code < NUM_LITERAL_CODES then
                local pixel
                if group.isTrivialLiteral then
                    pixel = group.literalArb | (code << 8)
                else
                    local red = readSymbol(group.htrees[2], br)
                    local blue = readSymbol(group.htrees[3], br)
                    local alpha = readSymbol(group.htrees[4], br)
                    pixel = (alpha << 24) | (red << 16) | (code << 8) | blue
                end
                data[src] = pixel
                src = src + 1
                col = col + 1
                if col >= width then
                    col = 0
                    row = row + 1
                end
                if colorCache then
                    while lastCached < src do
                        colorCacheInsert(colorCache, data[lastCached])
                        lastCached = lastCached + 1
                    end
                end
            elseif code < lenCodeLimit then
                local length = getCopyLength(code - NUM_LITERAL_CODES, br)
                local distSymbol = readSymbol(group.htrees[5], br)
                local dist = planeCodeToDistance(width, getCopyDistance(distSymbol, br))
                if src - dist < 0 or src + length > srcEnd then return false end
                for i = 0, length - 1 do
                    data[src + i] = data[src + i - dist]
                end
                src = src + length
                col = col + length
                while col >= width do
                    col = col - width
                    row = row + 1
                end
                if (col & mask) ~= 0 then
                    local metaIndex = 0
                    if huffmanBits ~= 0 then
                        metaIndex = huffmanImage[huffmanXsize * (row >> huffmanBits) + (col >> huffmanBits)]
                    end
                    group = htreeGroups[metaIndex]
                end
                if colorCache then
                    while lastCached < src do
                        colorCacheInsert(colorCache, data[lastCached])
                        lastCached = lastCached + 1
                    end
                end
            elseif code < colorCacheLimit then
                while lastCached < src do
                    colorCacheInsert(colorCache, data[lastCached])
                    lastCached = lastCached + 1
                end
                data[src] = colorCacheLookup(colorCache, code - lenCodeLimit)
                src = src + 1
                col = col + 1
                if col >= width then
                    col = 0
                    row = row + 1
                end
                if colorCache then
                    while lastCached < src do
                        colorCacheInsert(colorCache, data[lastCached])
                        lastCached = lastCached + 1
                    end
                end
            else
                return false
            end
        end
        if br.eos then return false end
    end
    if br.eos then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Color cache helpers are above; transforms below.

local function subSampleSize(v, n)
    return (v + (1 << n) - 1) >> n
end

-- ---------------------------------------------------------------------------
-- Inverse transforms (ports from lossless.c)

local function addPixels(a, b)
    local ag = (a & 0xFF00FF00) + (b & 0xFF00FF00)
    local rb = (a & 0x00FF00FF) + (b & 0x00FF00FF)
    return (ag & 0xFF00FF00) | (rb & 0x00FF00FF)
end

local function average2(a0, a1)
    return (((a0 ~ a1) & 0xFEFEFEFE) >> 1) + (a0 & a1)
end

local function average3(a0, a1, a2)
    return average2(average2(a0, a2), a1)
end

local function average4(a0, a1, a2, a3)
    return average2(average2(a0, a1), average2(a2, a3))
end

local function clip255(a)
    a = a & 0xFFFFFFFF
    if a < 256 then return a end
    return (~a >> 24) & 0xFF
end

local function div2trunc(x)
    if x >= 0 then return x >> 1 end
    return -((-x) >> 1)
end

local function sub3(a, b, c)
    return math.abs(b - c) - math.abs(a - c)
end

local function selectP(a, b, c)
    local paMinusPb =
        sub3(a >> 24, b >> 24, c >> 24) +
        sub3((a >> 16) & 0xFF, (b >> 16) & 0xFF, (c >> 16) & 0xFF) +
        sub3((a >> 8) & 0xFF, (b >> 8) & 0xFF, (c >> 8) & 0xFF) +
        sub3(a & 0xFF, b & 0xFF, c & 0xFF)
    if paMinusPb <= 0 then return a end
    return b
end

local function clampedAddSubtractFull(c0, c1, c2)
    local a = clip255(((c0 >> 24) & 0xFF) + ((c1 >> 24) & 0xFF) - ((c2 >> 24) & 0xFF))
    local r = clip255(((c0 >> 16) & 0xFF) + ((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    local g = clip255(((c0 >> 8) & 0xFF) + ((c1 >> 8) & 0xFF) - ((c2 >> 8) & 0xFF))
    local b = clip255((c0 & 0xFF) + (c1 & 0xFF) - (c2 & 0xFF))
    return (a << 24) | (r << 16) | (g << 8) | b
end

local function addSubHalf(a, b)
    return clip255(a + div2trunc(a - b))
end

local function clampedAddSubtractHalf(c0, c1, c2)
    local ave = average2(c0, c1)
    local a = addSubHalf((ave >> 24) & 0xFF, (c2 >> 24) & 0xFF)
    local r = addSubHalf((ave >> 16) & 0xFF, (c2 >> 16) & 0xFF)
    local g = addSubHalf((ave >> 8) & 0xFF, (c2 >> 8) & 0xFF)
    local b = addSubHalf(ave & 0xFF, c2 & 0xFF)
    return (a << 24) | (r << 16) | (g << 8) | b
end

local predictorFunctions = {}
predictorFunctions[0]  = function() return ARGB_BLACK end
predictorFunctions[1]  = function(left) return left end
predictorFunctions[2]  = function(left, top) return top end
predictorFunctions[3]  = function(left, top, top1) return top1 end
predictorFunctions[4]  = function(left, top, top1, topm1) return topm1 end
predictorFunctions[5]  = function(left, top, top1) return average3(left, top, top1) end
predictorFunctions[6]  = function(left, top, top1, topm1) return average2(left, topm1) end
predictorFunctions[7]  = function(left, top) return average2(left, top) end
predictorFunctions[8]  = function(left, top, top1, topm1) return average2(topm1, top) end
predictorFunctions[9]  = function(left, top, top1) return average2(top, top1) end
predictorFunctions[10] = function(left, top, top1, topm1) return average4(left, topm1, top, top1) end
predictorFunctions[11] = function(left, top, top1, topm1) return selectP(top, left, topm1) end
predictorFunctions[12] = function(left, top, top1, topm1) return clampedAddSubtractFull(left, top, topm1) end
predictorFunctions[13] = function(left, top, top1, topm1) return clampedAddSubtractHalf(left, top, topm1) end

local function predictorAdd(mode, in_, iIn, out, oOut, x, count, width)
    local func = predictorFunctions[mode]
    local baseIn = iIn + x
    local baseOut = oOut + x
    for i = 0, count - 1 do
        local px = baseOut + i
        local pred = func(out[px - 1], out[px - width], out[px - width + 1], out[px - width - 1])
        out[px] = addPixels(in_[baseIn + i], pred)
    end
end

local function predictorInverse(t, in_, out, rows)
    local width = t.xsize
    local tileWidth = 1 << t.bits
    local mask = tileWidth - 1
    local tilesPerRow = subSampleSize(width, t.bits)
    local tdata = t.data

    out[0] = addPixels(in_[0], ARGB_BLACK)
    for x = 1, width - 1 do
        out[x] = addPixels(in_[x], out[x - 1])
    end

    local iIn = width
    local oOut = width
    local y = 1
    while y < rows do
        Tasks.yieldCheck()
        local predModeBase = (y >> t.bits) * tilesPerRow
        local predModeSrc = predModeBase
        out[oOut] = addPixels(in_[iIn], out[oOut - width])
        local x = 1
        while x < width do
            local mode = (tdata[predModeSrc] >> 8) & 0xF
            predModeSrc = predModeSrc + 1
            local xEnd = (x & ~mask) + tileWidth
            if xEnd > width then xEnd = width end
            predictorAdd(mode, in_, iIn, out, oOut, x, xEnd - x, width)
            x = xEnd
        end
        iIn = iIn + width
        oOut = oOut + width
        y = y + 1
    end
end

local function toInt8(v)
    if v >= 128 then return v - 256 end
    return v
end

local function colorTransformDelta(colorPred, color)
    return (colorPred * color) >> 5
end

local function transformColorInverse(m, src, srcPos, num, dst, dstPos)
    for i = 0, num - 1 do
        local argb = src[srcPos + i]
        local green = toInt8((argb >> 8) & 0xFF)
        local newRed = (argb >> 16) & 0xFF
        local newBlue = argb & 0xFF
        newRed = (newRed + colorTransformDelta(m[1], green)) & 0xFF
        newBlue = (newBlue + colorTransformDelta(m[2], green)) & 0xFF
        newBlue = (newBlue + colorTransformDelta(m[3], toInt8(newRed))) & 0xFF
        dst[dstPos + i] = (argb & 0xFF00FF00) | (newRed << 16) | newBlue
    end
end

local function colorSpaceInverse(t, in_, out, rows)
    local width = t.xsize
    local tileWidth = 1 << t.bits
    local mask = tileWidth - 1
    local safeWidth = width & ~mask
    local remainingWidth = width - safeWidth
    local tilesPerRow = subSampleSize(width, t.bits)
    local tdata = t.data
    local predRow = 0
    local y = 0
    while y < rows do
        Tasks.yieldCheck()
        local predIdx = predRow
        local m = { 0, 0, 0 }
        local srcPos = y * width
        local dstPos = y * width
        local safeEnd = srcPos + safeWidth
        local endPos = srcPos + width
        while srcPos < safeEnd do
            local code = tdata[predIdx]
            predIdx = predIdx + 1
            m[1] = toInt8(code & 0xFF)
            m[2] = toInt8((code >> 8) & 0xFF)
            m[3] = toInt8((code >> 16) & 0xFF)
            transformColorInverse(m, in_, srcPos, tileWidth, out, dstPos)
            srcPos = srcPos + tileWidth
            dstPos = dstPos + tileWidth
        end
        if srcPos < endPos then
            local code = tdata[predIdx]
            m[1] = toInt8(code & 0xFF)
            m[2] = toInt8((code >> 8) & 0xFF)
            m[3] = toInt8((code >> 16) & 0xFF)
            transformColorInverse(m, in_, srcPos, remainingWidth, out, dstPos)
        end
        y = y + 1
        if (y & mask) == 0 then predRow = predRow + tilesPerRow end
    end
end

local function addGreenToBlueAndRed(src, num, dst)
    for i = 0, num - 1 do
        Tasks.yieldCheck()
        local argb = src[i]
        local green = (argb >> 8) & 0xFF
        local redBlue = (argb & 0x00FF00FF) + ((green << 16) | green)
        redBlue = redBlue & 0x00FF00FF
        dst[i] = (argb & 0xFF00FF00) | redBlue
    end
end

local function colorIndexInverse(t, in_, out, rows)
    local bitsPerPixel = 8 >> t.bits
    local width = t.xsize
    local colorMap = t.data
    if bitsPerPixel < 8 then
        local ppb = 1 << t.bits
        local bitMask = (1 << bitsPerPixel) - 1
        local idx = 0
        for y = 0, rows - 1 do
            Tasks.yieldCheck()
            local x = 0
            local oBase = y * width
            while x + ppb <= width do
                local packed = (in_[idx] >> 8) & 0xFF
                idx = idx + 1
                for p = 1, ppb do
                    out[oBase + x] = colorMap[packed & bitMask]
                    packed = packed >> bitsPerPixel
                    x = x + 1
                end
            end
            if x < width then
                local packed = (in_[idx] >> 8) & 0xFF
                idx = idx + 1
                while x < width do
                    out[oBase + x] = colorMap[packed & bitMask]
                    packed = packed >> bitsPerPixel
                    x = x + 1
                end
            end
        end
    else
        for i = 0, rows * width - 1 do
            Tasks.yieldCheck()
            out[i] = colorMap[(in_[i] >> 8) & 0xFF]
        end
    end
end

local function expandColorMap(numColors, t)
    local finalNum = 1 << (8 >> t.bits)
    local newData = {}
    newData[0] = t.data[0]
    for i = 1, numColors - 1 do
        local prev = newData[i - 1]
        local cur = t.data[i]
        local a = ((prev >> 24) & 0xFF) + ((cur >> 24) & 0xFF)
        local r = ((prev >> 16) & 0xFF) + ((cur >> 16) & 0xFF)
        local g = ((prev >> 8) & 0xFF) + ((cur >> 8) & 0xFF)
        local b = (prev & 0xFF) + (cur & 0xFF)
        newData[i] = ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
    end
    for i = numColors, finalNum - 1 do newData[i] = 0 end
    return newData
end

-- ---------------------------------------------------------------------------
-- DecodeImageStream: reads transforms, color cache and Huffman codes. Returns
-- the decoded pixel array for sub-streams, or true (with ctx populated) at
-- level 0.

decodeImageStream = function(xsize, ysize, isLevel0, br, ctx)
    local transformXsize = xsize
    local transformYsize = ysize
    local transforms = {}
    local transformsSeen = 0
    local colorCacheBits = 0

    if isLevel0 then
        while brReadBits(br, 1) == 1 do
            local type_ = brReadBits(br, 2)
            if (transformsSeen & (1 << type_)) ~= 0 then return false end
            transformsSeen = transformsSeen | (1 << type_)
            local t = { type = type_, xsize = transformXsize, ysize = transformYsize, data = nil, bits = 0 }
            if type_ == PREDICTOR_TRANSFORM or type_ == CROSS_COLOR_TRANSFORM then
                t.bits = MIN_TRANSFORM_BITS + brReadBits(br, NUM_TRANSFORM_BITS)
                local subCtx = {}
                t.data = decodeImageStream(subSampleSize(t.xsize, t.bits), subSampleSize(t.ysize, t.bits), false, br, subCtx)
                if not t.data then return false end
            elseif type_ == COLOR_INDEXING_TRANSFORM then
                local numColors = brReadBits(br, 8) + 1
                local bits = (numColors > 16) and 0 or (numColors > 4) and 1 or (numColors > 2) and 2 or 3
                transformXsize = subSampleSize(transformXsize, bits)
                t.bits = bits
                local subCtx = {}
                t.data = decodeImageStream(numColors, 1, false, br, subCtx)
                if not t.data then return false end
                t.data = expandColorMap(numColors, t)
            elseif type_ == SUBTRACT_GREEN_TRANSFORM then
                -- nothing to read
            else
                return false
            end
            transforms[#transforms + 1] = t
        end
    end

    if brReadBits(br, 1) == 1 then
        colorCacheBits = brReadBits(br, 4)
        if colorCacheBits < 1 or colorCacheBits > MAX_CACHE_BITS then return false end
    end

    if not readHuffmanCodes(br, transformXsize, transformYsize, colorCacheBits, isLevel0, ctx) then
        return false
    end

    if colorCacheBits > 0 then
        ctx.colorCacheSize = 1 << colorCacheBits
        ctx.colorCache = newColorCache(colorCacheBits)
    else
        ctx.colorCacheSize = 0
        ctx.colorCache = nil
    end
    ctx.huffmanSubsampleBits = ctx.huffmanSubsampleBits or 0
    ctx.transformXsize = transformXsize
    ctx.transformYsize = transformYsize
    ctx.huffmanXsize = (transformXsize + (1 << ctx.huffmanSubsampleBits) - 1) >> ctx.huffmanSubsampleBits

    if isLevel0 then
        ctx.transforms = transforms
        return true
    end

    local totalSize = transformXsize * transformYsize
    local data = {}
    for i = 0, totalSize - 1 do data[i] = 0 end
    if not decodeImageData(br, ctx, data, transformXsize, transformYsize) then return false end
    if br.eos then return false end
    return data
end

-- ---------------------------------------------------------------------------
-- Top-level decode

local function applyInverseTransforms(ctx, data, rows)
    local transforms = ctx.transforms
    if #transforms == 0 then return data end
    local in_ = data
    for i = #transforms, 1, -1 do
        local t = transforms[i]
        local out = {}
        if t.type == COLOR_INDEXING_TRANSFORM then
            colorIndexInverse(t, in_, out, rows)
        elseif t.type == SUBTRACT_GREEN_TRANSFORM then
            addGreenToBlueAndRed(in_, t.xsize * rows, out)
        elseif t.type == PREDICTOR_TRANSFORM then
            predictorInverse(t, in_, out, rows)
        else
            colorSpaceInverse(t, in_, out, rows)
        end
        in_ = out
    end
    return in_
end

local MAX_PIXELS = 2048 * 2048

local function decodeVP8LPayload(payload)
    if #payload < 5 then return nil end
    if string.byte(payload, 1) ~= VP8L_MAGIC_BYTE then return nil end

    local b2, b3, b4 = string.byte(payload, 2, 4)
    local bits = (b2 or 0) | ((b3 or 0) << 8) | ((b4 or 0) << 16)
    local width = (bits & 0x3FFF) + 1
    local height = ((bits >> 14) & 0x3FFF) + 1
    if ((bits >> 29) & 7) ~= 0 then return nil end
    if width < 1 or height < 1 or width * height > MAX_PIXELS then return nil end

    local br = newBitReader(payload, 6)
    local ctx = {}
    if not decodeImageStream(width, height, true, br, ctx) then return nil end

    local transformXsize = ctx.transformXsize
    local transformYsize = ctx.transformYsize
    if transformXsize < 1 or transformYsize < 1 then return nil end
    local totalSize = transformXsize * transformYsize
    local data = {}
    for i = 0, totalSize - 1 do data[i] = 0 end
    if not decodeImageData(br, ctx, data, transformXsize, transformYsize) then return nil end
    if br.eos then return nil end

    local final = applyInverseTransforms(ctx, data, transformYsize)
    return final, width, height
end

-- ---------------------------------------------------------------------------
-- Alpha (ALPH chunk) decoding. Port of libwebp 1.6.0 alpha_dec.c +
-- vp8l_dec.c (VP8LDecodeAlphaHeader / VP8LDecodeAlphaImageStream).
-- ALPH header byte: method(2) | filter(2) | pre_processing(2) | reserved(2).

-- Row unfilter (WebPUnfilters from dsp/filters.c). Operates in place.
local function alphaUnfilter(alpha, width, height, filter)
    local function horizontal(pred, o)
        for x = 0, width - 1 do
            local v = (pred + alpha[o + x]) & 0xFF
            alpha[o + x] = v
            pred = v
        end
    end
    for y = 0, height - 1 do
        local o = y * width
        if y == 0 then
            horizontal(0, o)
        elseif filter == 1 then
            horizontal(alpha[o - width], o)
        elseif filter == 2 then
            local prev = o - width
            for x = 0, width - 1 do
                alpha[o + x] = (alpha[prev + x] + alpha[o + x]) & 0xFF
            end
        elseif filter == 3 then
            local prev = o - width
            local top = alpha[prev]
            local top_left = top
            local left = top
            for x = 0, width - 1 do
                top = alpha[prev + x]
                local g = left + top - top_left
                if (g & ~0xff) ~= 0 then
                    if g < 0 then g = 0 else g = 255 end
                end
                left = (alpha[o + x] + g) & 0xFF
                top_left = top
                alpha[o + x] = left
            end
        end
    end
    return alpha
end

local function decodeAlphaPlane(alphaPayload, width, height)
    if not alphaPayload or #alphaPayload < 2 then return nil end
    local h0 = string.byte(alphaPayload, 1)
    local method = h0 & 0x03
    local filter = (h0 >> 2) & 0x03
    if filter > 3 then return nil end
    if method > 1 or ((h0 >> 4) & 0x03) > 1 or ((h0 >> 6) & 0x03) ~= 0 then return nil end
    local total = width * height
    if total < 1 or total > MAX_PIXELS then return nil end

    local alpha
    if method == 0 then
        if #alphaPayload - 1 < total then return nil end
        alpha = {}
        for i = 0, total - 1 do
            alpha[i] = string.byte(alphaPayload, 2 + i)
        end
    else
        local br = newBitReader(alphaPayload, 2)
        local ctx = {}
        if not decodeImageStream(width, height, true, br, ctx) then return nil end
        local txs = ctx.transformXsize
        local tys = ctx.transformYsize
        if txs < 1 or tys < 1 or txs * tys > MAX_PIXELS then return nil end
        local data = {}
        for i = 0, txs * tys - 1 do data[i] = 0 end
        if not decodeImageData(br, ctx, data, txs, tys) then return nil end
        if br.eos then return nil end
        local argb = applyInverseTransforms(ctx, data, tys)
        alpha = {}
        for i = 0, total - 1 do
            alpha[i] = (argb[i] >> 8) & 0xFF
        end
    end
    if filter == 0 then return alpha end
    return alphaUnfilter(alpha, width, height, filter)
end

-- ---------------------------------------------------------------------------
-- VP8 (lossy) decoder. Port of libwebp 1.6.0 vp8_dec.c / frame_dec.c /
-- tree_dec.c / quant_dec.c / dsp/dec.c. Output is byte-identical to
-- `dwebp -ppm` (MODE_RGB, fancy upsampling, ported from upsampling.c /
-- io_dec.c).
-- Boolean decoder uses BITS=24 semantics (equivalent to dwebp's BITS=56).

local V8 = VP8Tables
local kDcTable = V8.kDcTable
local kAcTable = V8.kAcTable
local kZigzag = V8.kZigzag
local kCat3456 = V8.kCat3456
local kBands = V8.kBands
local kYModesIntra4 = V8.kYModesIntra4
local kBModesProba = V8.kBModesProba
local CoeffsProba0 = V8.CoeffsProba0
local CoeffsUpdateProba = V8.CoeffsUpdateProba

local BPS = 32  -- working-buffer row stride (matches C's BPS with padding)
local YBASE = 64  -- top-left of the 16x16/8x8 block inside the flat buffer
local UBASE = 32  -- chroma block offset (stride 32, 1-pixel border)
local VBASE = 32
local kScan = { 0, 4, 8, 12, 128, 132, 136, 140,
                256, 260, 264, 268, 384, 388, 392, 396 }
local kFilterExtraRows = { 0, 2, 8 }
local DC_PRED = 0
local TM_PRED = 1
local V_PRED = 2
local H_PRED = 3

-- Working buffers (persistent across frames). y: base 64, stride 32, size 640.
-- min index (row -1, col -4) = 64 - 32 - 4 = 28 >= 0.
local yArr = {}
local uArr = {}
local vArr = {}
for i = 0, 639 do yArr[i] = 0 end
for i = 0, 319 do uArr[i] = 0 vArr[i] = 0 end

local function clip8(v)
    if (v & ~0xff) == 0 then return v end
    if v < 0 then return 0 end
    return 255
end

local function ksclip1(v)
    if v < -128 then return -128 end
    if v > 127 then return 127 end
    return v
end

local function ksclip2(v)
    if v < -16 then return -16 end
    if v > 15 then return 15 end
    return v
end

local function kabs0(v)
    if v < 0 then return -v end
    return v
end

local VP8_LOG2 = {}
do
    for i = 1, 255 do
        local v, n = i, 0
        while v > 1 do
            v = v >> 1
            n = n + 1
        end
        VP8_LOG2[i] = n
    end
end

-- ---------------------------------------------------------------------------
-- Boolean decoder (BITS=24)

local function vp8LoadNew(br)
    local payload = br.payload
    if br.p < br.max1 then
        local b0 = payload:byte(br.p) or 0
        local b1 = payload:byte(br.p + 1) or 0
        local b2 = payload:byte(br.p + 2) or 0
        br.value = (((br.value << 24) | (b0 << 16) | (b1 << 8) | b2)) & 0xFFFFFFFF
        br.bits = br.bits + 24
        br.p = br.p + 3
    elseif br.p < br.end1 then
        br.value = ((br.value << 8) | (payload:byte(br.p) or 0)) & 0xFFFFFFFF
        br.bits = br.bits + 8
        br.p = br.p + 1
    elseif br.eof == 0 then
        br.value = (br.value << 8) & 0xFFFFFFFF
        br.bits = br.bits + 8
        br.eof = 1
    else
        br.bits = 0
    end
end

local function newBr(payload, start1, size)
    local br = {
        payload = payload,
        p = start1,
        end1 = start1 + size,
        max1 = start1 + size - 3,
        range = 254,
        value = 0,
        bits = -8,
        eof = 0,
    }
    vp8LoadNew(br)
    return br
end

local function vp8GetBit(br, prob)
    if br.bits < 0 then vp8LoadNew(br) end
    local pos = br.bits
    local range = br.range
    local split = (range * prob) >> 8
    local value = br.value >> pos
    local bit = 0
    if value > split then
        bit = 1
        range = range - split
        br.value = (br.value - ((split + 1) << pos)) & 0xFFFFFFFF
    else
        range = split + 1
    end
    local shift = 7 - VP8_LOG2[range]
    range = range << shift
    br.bits = br.bits - shift
    br.range = range - 1
    return bit
end

local function vp8GetSigned(br, v)
    if br.bits < 0 then vp8LoadNew(br) end
    local pos = br.bits
    local split = br.range >> 1
    local value = br.value >> pos
    local mask
    if value > split then mask = -1 else mask = 0 end
    br.bits = br.bits - 1
    br.range = (br.range + mask) | 1
    br.value = (br.value - (((split + 1) & mask) << pos)) & 0xFFFFFFFF
    return (v ~ mask) - mask
end

local function vp8GetValue(br, bits)
    local v = 0
    for i = bits - 1, 0, -1 do
        v = v | (vp8GetBit(br, 128) << i)
    end
    return v
end

local function vp8GetSignedValue(br, bits)
    local value = vp8GetValue(br, bits)
    if vp8GetBit(br, 128) ~= 0 then return -value end
    return value
end

-- ---------------------------------------------------------------------------
-- Header parsing

local function parseSegmentHeader(br, dec)
    local hdr = dec.segmentHdr
    hdr.useSegment = vp8GetBit(br, 128)
    if hdr.useSegment ~= 0 then
        hdr.updateMap = vp8GetBit(br, 128)
        if vp8GetBit(br, 128) ~= 0 then
            hdr.absoluteDelta = vp8GetBit(br, 128)
            for s = 0, 3 do
                if vp8GetBit(br, 128) ~= 0 then
                    hdr.quantizer[s + 1] = vp8GetSignedValue(br, 7)
                else
                    hdr.quantizer[s + 1] = 0
                end
            end
            for s = 0, 3 do
                if vp8GetBit(br, 128) ~= 0 then
                    hdr.filterStrength[s + 1] = vp8GetSignedValue(br, 6)
                else
                    hdr.filterStrength[s + 1] = 0
                end
            end
        end
        if hdr.updateMap ~= 0 then
            for s = 0, 2 do
                if vp8GetBit(br, 128) ~= 0 then
                    dec.probaSegments[s + 1] = vp8GetValue(br, 8)
                else
                    dec.probaSegments[s + 1] = 255
                end
            end
        end
    else
        hdr.updateMap = 0
    end
    return br.eof == 0
end

local function parseFilterHeader(br, dec)
    local hdr = dec.filterHdr
    hdr.simple = vp8GetBit(br, 128)
    hdr.level = vp8GetValue(br, 6)
    hdr.sharpness = vp8GetValue(br, 3)
    hdr.useLfDelta = vp8GetBit(br, 128)
    if hdr.useLfDelta ~= 0 then
        if vp8GetBit(br, 128) ~= 0 then
            for i = 0, 3 do
                if vp8GetBit(br, 128) ~= 0 then
                    hdr.refLfDelta[i + 1] = vp8GetSignedValue(br, 6)
                end
            end
            for i = 0, 3 do
                if vp8GetBit(br, 128) ~= 0 then
                    hdr.modeLfDelta[i + 1] = vp8GetSignedValue(br, 6)
                end
            end
        end
    end
    if hdr.level == 0 then
        dec.filterType = 0
    elseif hdr.simple ~= 0 then
        dec.filterType = 1
    else
        dec.filterType = 2
    end
    return br.eof == 0
end

local function parseQuant(br, dec)
    local baseQ0 = vp8GetValue(br, 7)
    local dqy1dc = (vp8GetBit(br, 128) ~= 0) and vp8GetSignedValue(br, 4) or 0
    local dqy2dc = (vp8GetBit(br, 128) ~= 0) and vp8GetSignedValue(br, 4) or 0
    local dqy2ac = (vp8GetBit(br, 128) ~= 0) and vp8GetSignedValue(br, 4) or 0
    local dquvdc = (vp8GetBit(br, 128) ~= 0) and vp8GetSignedValue(br, 4) or 0
    local dquvac = (vp8GetBit(br, 128) ~= 0) and vp8GetSignedValue(br, 4) or 0
    local hdr = dec.segmentHdr
    for i = 0, 3 do
        local q
        if hdr.useSegment ~= 0 then
            q = hdr.quantizer[i + 1]
            if hdr.absoluteDelta == 0 then q = q + baseQ0 end
        else
            if i > 0 then
                dec.dqm[i + 1] = dec.dqm[1]
                goto continue_seg
            end
            q = baseQ0
        end
        local clipQ = function(v, m)
            if v < 0 then return 0 end
            if v > m then return m end
            return v
        end
        local m = {}
        m.y1 = { kDcTable[clipQ(q + dqy1dc, 127) + 1], kAcTable[clipQ(q, 127) + 1] }
        m.y2 = { kDcTable[clipQ(q + dqy2dc, 127) + 1] * 2, 0 }
        m.y2[2] = (kAcTable[clipQ(q + dqy2ac, 127) + 1] * 101581) >> 16
        if m.y2[2] < 8 then m.y2[2] = 8 end
        m.uv = { kDcTable[clipQ(q + dquvdc, 117) + 1], kAcTable[clipQ(q + dquvac, 127) + 1] }
        dec.dqm[i + 1] = m
        ::continue_seg::
    end
end

local function parseProba(br, dec)
    local proba = dec.proba
    for t = 0, 3 do
        for b = 0, 7 do
            for c = 0, 2 do
                for p = 0, 10 do
                    local ci = ((t * 8 + b) * 3 + c) * 11 + p
                    if vp8GetBit(br, CoeffsUpdateProba[ci + 1]) ~= 0 then
                        proba[ci] = vp8GetValue(br, 8)
                    else
                        proba[ci] = CoeffsProba0[ci + 1]
                    end
                end
            end
        end
    end
    dec.useSkipProba = vp8GetBit(br, 128)
    if dec.useSkipProba ~= 0 then
        dec.skipP = vp8GetValue(br, 8)
    end
end

-- ---------------------------------------------------------------------------
-- Transforms

local function sar(v, n)
    if v >= 0 then return v >> n end
    return ~((~v) >> n)
end

local function mul1(a) return sar(a * 20091, 16) + a end
local function mul2(a) return sar(a * 35468, 16) end

local function transformOne(in_, inOff, buf, dst)
    local t = {}
    for i = 0, 3 do
        local a = in_[inOff + i] + in_[inOff + 8 + i]
        local b = in_[inOff + i] - in_[inOff + 8 + i]
        local c = mul2(in_[inOff + 4 + i]) - mul1(in_[inOff + 12 + i])
        local d = mul1(in_[inOff + 4 + i]) + mul2(in_[inOff + 12 + i])
        t[i * 4] = a + d
        t[i * 4 + 1] = b + c
        t[i * 4 + 2] = b - c
        t[i * 4 + 3] = a - d
    end
    for i = 0, 3 do
        local o = dst + i * 32
        local dc = t[i] + 4
        local a = dc + t[i + 8]
        local b = dc - t[i + 8]
        local c = mul2(t[i + 4]) - mul1(t[i + 12])
        local d = mul1(t[i + 4]) + mul2(t[i + 12])
        buf[o] = clip8(buf[o] + sar(a + d, 3))
        buf[o + 1] = clip8(buf[o + 1] + sar(b + c, 3))
        buf[o + 2] = clip8(buf[o + 2] + sar(b - c, 3))
        buf[o + 3] = clip8(buf[o + 3] + sar(a - d, 3))
    end
end

local function transformAC3(in_, inOff, buf, dst)
    local a = in_[inOff] + 4
    local c4 = mul2(in_[inOff + 4])
    local d4 = mul1(in_[inOff + 4])
    local c1 = mul2(in_[inOff + 1])
    local d1 = mul1(in_[inOff + 1])
    local function store2(y, dc)
        local o = dst + y * 32
        buf[o] = clip8(buf[o] + sar(dc + d1, 3))
        buf[o + 1] = clip8(buf[o + 1] + sar(dc + c1, 3))
        buf[o + 2] = clip8(buf[o + 2] + sar(dc - c1, 3))
        buf[o + 3] = clip8(buf[o + 3] + sar(dc - d1, 3))
    end
    store2(0, a + d4)
    store2(1, a + c4)
    store2(2, a - c4)
    store2(3, a - d4)
end

local function transformDC(in_, inOff, buf, dst)
    local v = sar(in_[inOff] + 4, 3)
    for j = 0, 3 do
        local o = dst + j * 32
        buf[o] = clip8(buf[o] + v)
        buf[o + 1] = clip8(buf[o + 1] + v)
        buf[o + 2] = clip8(buf[o + 2] + v)
        buf[o + 3] = clip8(buf[o + 3] + v)
    end
end

local function transformUV(in_, inOff, buf, dst)
    transformOne(in_, inOff, buf, dst)
    transformOne(in_, inOff + 16, buf, dst + 4)
    transformOne(in_, inOff + 32, buf, dst + 4 * BPS)
    transformOne(in_, inOff + 48, buf, dst + 4 * BPS + 4)
end

local function transformDCUV(in_, inOff, buf, dst)
    if in_[inOff] ~= 0 then transformDC(in_, inOff, buf, dst) end
    if in_[inOff + 16] ~= 0 then transformDC(in_, inOff + 16, buf, dst + 4) end
    if in_[inOff + 32] ~= 0 then transformDC(in_, inOff + 32, buf, dst + 4 * BPS) end
    if in_[inOff + 48] ~= 0 then transformDC(in_, inOff + 48, buf, dst + 4 * BPS + 4) end
end

local whtTmp = {}
local function transformWHT(in_, inOff, out, outOff)
    local t = whtTmp
    for i = 0, 3 do
        local a0 = in_[inOff + i] + in_[inOff + 12 + i]
        local a1 = in_[inOff + 4 + i] + in_[inOff + 8 + i]
        local a2 = in_[inOff + 4 + i] - in_[inOff + 8 + i]
        local a3 = in_[inOff + i] - in_[inOff + 12 + i]
        t[i] = a0 + a1
        t[8 + i] = a0 - a1
        t[4 + i] = a3 + a2
        t[12 + i] = a3 - a2
    end
    for i = 0, 3 do
        local dc = t[i * 4] + 3
        local a0 = dc + t[i * 4 + 3]
        local a1 = t[i * 4 + 1] + t[i * 4 + 2]
        local a2 = t[i * 4 + 1] - t[i * 4 + 2]
        local a3 = dc - t[i * 4 + 3]
        out[outOff] = sar(a0 + a1, 3)
        out[outOff + 16] = sar(a3 + a2, 3)
        out[outOff + 32] = sar(a0 - a1, 3)
        out[outOff + 48] = sar(a3 - a2, 3)
        outOff = outOff + 64
    end
end

local function doTransform(bits, coeffs, inOff, buf, dst)
    local top = bits >> 30
    if top == 3 then
        transformOne(coeffs, inOff, buf, dst)
    elseif top == 2 then
        transformAC3(coeffs, inOff, buf, dst)
    elseif top == 1 then
        transformDC(coeffs, inOff, buf, dst)
    end
end

local function doUvTransform(bits, coeffs, inOff, buf, dst)
    if (bits & 0xff) ~= 0 then
        if (bits & 0xaa) ~= 0 then
            transformUV(coeffs, inOff, buf, dst)
        else
            transformDCUV(coeffs, inOff, buf, dst)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Intra predictions (stride 32)

local function avg2(a, b) return (a + b + 1) >> 1 end
local function avg3(a, b, c) return (a + 2 * b + c + 2) >> 2 end

local function trueMotion(buf, dst, size)
    local topBase = dst - 32
    local topleft = buf[topBase - 1]
    for y = 0, size - 1 do
        local left = buf[dst - 1 + y * 32]
        local r = dst + y * 32
        for x = 0, size - 1 do
            buf[r + x] = clip8(buf[topBase + x] + left - topleft)
        end
    end
end

local function dc16(buf, dst)
    local dc = 16
    for j = 0, 15 do
        dc = dc + buf[dst - 1 + j * 32] + buf[dst - 32 + j]
    end
    local v = dc >> 5
    for j = 0, 15 do
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = v end
    end
end

local function dc16NoTop(buf, dst)
    local dc = 8
    for j = 0, 15 do dc = dc + buf[dst - 1 + j * 32] end
    local v = dc >> 4
    for j = 0, 15 do
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = v end
    end
end

local function dc16NoLeft(buf, dst)
    local dc = 8
    for i = 0, 15 do dc = dc + buf[dst - 32 + i] end
    local v = dc >> 4
    for j = 0, 15 do
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = v end
    end
end

local function dc16NoTopLeft(buf, dst)
    for j = 0, 15 do
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = 128 end
    end
end

local function ve16(buf, dst)
    local top = dst - 32
    for j = 0, 15 do
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = buf[top + i] end
    end
end

local function he16(buf, dst)
    for j = 0, 15 do
        local v = buf[dst - 1 + j * 32]
        local r = dst + j * 32
        for i = 0, 15 do buf[r + i] = v end
    end
end

local predLuma16 = {
    dc16, function(buf, dst) trueMotion(buf, dst, 16) end,
    ve16, he16, dc16NoTop, dc16NoLeft, dc16NoTopLeft,
}

local function dc8uv(buf, dst)
    local dc0 = 8
    for i = 0, 7 do
        dc0 = dc0 + buf[dst - 32 + i] + buf[dst - 1 + i * 32]
    end
    local v = dc0 >> 4
    for j = 0, 7 do
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = v end
    end
end

local function dc8uvNoTop(buf, dst)
    local dc0 = 4
    for i = 0, 7 do dc0 = dc0 + buf[dst - 1 + i * 32] end
    local v = dc0 >> 3
    for j = 0, 7 do
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = v end
    end
end

local function dc8uvNoLeft(buf, dst)
    local dc0 = 4
    for i = 0, 7 do dc0 = dc0 + buf[dst - 32 + i] end
    local v = dc0 >> 3
    for j = 0, 7 do
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = v end
    end
end

local function dc8uvNoTopLeft(buf, dst)
    for j = 0, 7 do
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = 128 end
    end
end

local function ve8uv(buf, dst)
    local top = dst - 32
    for j = 0, 7 do
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = buf[top + i] end
    end
end

local function he8uv(buf, dst)
    for j = 0, 7 do
        local v = buf[dst - 1 + j * 32]
        local r = dst + j * 32
        for i = 0, 7 do buf[r + i] = v end
    end
end

local predChroma8 = {
    dc8uv, function(buf, dst) trueMotion(buf, dst, 8) end,
    ve8uv, he8uv, dc8uvNoTop, dc8uvNoLeft, dc8uvNoTopLeft,
}

local function dc4(buf, dst)
    local dc = 4
    for i = 0, 3 do dc = dc + buf[dst - 32 + i] + buf[dst - 1 + i * 32] end
    dc = dc >> 3
    for j = 0, 3 do
        local r = dst + j * 32
        for i = 0, 3 do buf[r + i] = dc end
    end
end

local function ve4(buf, dst)
    local top = dst - 32
    local v0 = avg3(buf[top - 1], buf[top], buf[top + 1])
    local v1 = avg3(buf[top], buf[top + 1], buf[top + 2])
    local v2 = avg3(buf[top + 1], buf[top + 2], buf[top + 3])
    local v3 = avg3(buf[top + 2], buf[top + 3], buf[top + 4])
    for j = 0, 3 do
        local r = dst + j * 32
        buf[r] = v0 buf[r + 1] = v1 buf[r + 2] = v2 buf[r + 3] = v3
    end
end

local function he4(buf, dst)
    local a = buf[dst - 1 - 32]
    local b = buf[dst - 1]
    local c = buf[dst - 1 + 32]
    local d = buf[dst - 1 + 2 * 32]
    local e = buf[dst - 1 + 3 * 32]
    local r0 = dst
    local r1 = dst + 32
    local r2 = dst + 64
    local r3 = dst + 96
    local w0 = avg3(a, b, c)
    local w1 = avg3(b, c, d)
    local w2 = avg3(c, d, e)
    local w3 = avg3(d, e, e)
    buf[r0] = w0 buf[r0 + 1] = w0 buf[r0 + 2] = w0 buf[r0 + 3] = w0
    buf[r1] = w1 buf[r1 + 1] = w1 buf[r1 + 2] = w1 buf[r1 + 3] = w1
    buf[r2] = w2 buf[r2 + 1] = w2 buf[r2 + 2] = w2 buf[r2 + 3] = w2
    buf[r3] = w3 buf[r3 + 1] = w3 buf[r3 + 2] = w3 buf[r3 + 3] = w3
end

local function rd4(buf, dst)
    local i = buf[dst - 1]
    local j = buf[dst - 1 + 32]
    local k = buf[dst - 1 + 64]
    local l = buf[dst - 1 + 96]
    local x = buf[dst - 1 - 32]
    local a = buf[dst - 32]
    local b = buf[dst - 32 + 1]
    local c = buf[dst - 32 + 2]
    local d = buf[dst - 32 + 3]
    local function s(y, v) buf[dst + y * 32] = v end
    s(3, avg3(j, k, l))
    buf[dst + 3 + 3 * 32] = 0 buf[dst + 3] = 0 -- placeholder, replaced below
    buf[dst + 1 + 3 * 32] = avg3(i, j, k) buf[dst + 0 + 2 * 32] = buf[dst + 1 + 3 * 32]
    buf[dst + 2 + 3 * 32] = avg3(x, i, j) buf[dst + 1 + 2 * 32] = buf[dst + 2 + 3 * 32] buf[dst + 0 + 1 * 32] = buf[dst + 2 + 3 * 32]
    buf[dst + 3 + 3 * 32] = avg3(a, x, i) buf[dst + 2 + 2 * 32] = buf[dst + 3 + 3 * 32] buf[dst + 1 + 1 * 32] = buf[dst + 3 + 3 * 32] buf[dst + 0 + 0 * 32] = buf[dst + 3 + 3 * 32]
    buf[dst + 3 + 2 * 32] = avg3(b, a, x) buf[dst + 2 + 1 * 32] = buf[dst + 3 + 2 * 32] buf[dst + 1 + 0 * 32] = buf[dst + 3 + 2 * 32]
    buf[dst + 3 + 1 * 32] = avg3(c, b, a) buf[dst + 2 + 0 * 32] = buf[dst + 3 + 1 * 32]
    buf[dst + 3 + 0 * 32] = avg3(d, c, b)
end

local function ld4(buf, dst)
    local a = buf[dst - 32]
    local b = buf[dst - 32 + 1]
    local c = buf[dst - 32 + 2]
    local d = buf[dst - 32 + 3]
    local e = buf[dst - 32 + 4]
    local f = buf[dst - 32 + 5]
    local g = buf[dst - 32 + 6]
    local h = buf[dst - 32 + 7]
    buf[dst + 0 * 32] = avg3(a, b, c)
    buf[dst + 1 + 0 * 32] = avg3(b, c, d) buf[dst + 0 + 1 * 32] = buf[dst + 1 + 0 * 32]
    buf[dst + 2 + 0 * 32] = avg3(c, d, e) buf[dst + 1 + 1 * 32] = buf[dst + 2 + 0 * 32] buf[dst + 0 + 2 * 32] = buf[dst + 2 + 0 * 32]
    buf[dst + 3 + 0 * 32] = avg3(d, e, f) buf[dst + 2 + 1 * 32] = buf[dst + 3 + 0 * 32] buf[dst + 1 + 2 * 32] = buf[dst + 3 + 0 * 32] buf[dst + 0 + 3 * 32] = buf[dst + 3 + 0 * 32]
    buf[dst + 3 + 1 * 32] = avg3(e, f, g) buf[dst + 2 + 2 * 32] = buf[dst + 3 + 1 * 32] buf[dst + 1 + 3 * 32] = buf[dst + 3 + 1 * 32]
    buf[dst + 3 + 2 * 32] = avg3(f, g, h) buf[dst + 2 + 3 * 32] = buf[dst + 3 + 2 * 32]
    buf[dst + 3 + 3 * 32] = avg3(g, h, h)
end

local function vr4(buf, dst)
    local i = buf[dst - 1]
    local j = buf[dst - 1 + 32]
    local k = buf[dst - 1 + 64]
    local x = buf[dst - 1 - 32]
    local a = buf[dst - 32]
    local b = buf[dst - 32 + 1]
    local c = buf[dst - 32 + 2]
    local d = buf[dst - 32 + 3]
    buf[dst + 0 * 32] = avg2(x, a) buf[dst + 1 + 2 * 32] = buf[dst + 0 * 32]
    buf[dst + 1 + 0 * 32] = avg2(a, b) buf[dst + 2 + 2 * 32] = buf[dst + 1 + 0 * 32]
    buf[dst + 2 + 0 * 32] = avg2(b, c) buf[dst + 3 + 2 * 32] = buf[dst + 2 + 0 * 32]
    buf[dst + 3 + 0 * 32] = avg2(c, d)
    buf[dst + 0 + 3 * 32] = avg3(k, j, i)
    buf[dst + 0 + 2 * 32] = avg3(j, i, x)
    buf[dst + 0 + 1 * 32] = avg3(i, x, a) buf[dst + 1 + 3 * 32] = buf[dst + 0 + 1 * 32]
    buf[dst + 1 + 1 * 32] = avg3(x, a, b) buf[dst + 2 + 3 * 32] = buf[dst + 1 + 1 * 32]
    buf[dst + 2 + 1 * 32] = avg3(a, b, c) buf[dst + 3 + 3 * 32] = buf[dst + 2 + 1 * 32]
    buf[dst + 3 + 1 * 32] = avg3(b, c, d)
end

local function vl4(buf, dst)
    local a = buf[dst - 32]
    local b = buf[dst - 32 + 1]
    local c = buf[dst - 32 + 2]
    local d = buf[dst - 32 + 3]
    local e = buf[dst - 32 + 4]
    local f = buf[dst - 32 + 5]
    local g = buf[dst - 32 + 6]
    local h = buf[dst - 32 + 7]
    buf[dst + 0 * 32] = avg2(a, b)
    buf[dst + 1 + 0 * 32] = avg2(b, c) buf[dst + 0 + 2 * 32] = buf[dst + 1 + 0 * 32]
    buf[dst + 2 + 0 * 32] = avg2(c, d) buf[dst + 1 + 2 * 32] = buf[dst + 2 + 0 * 32]
    buf[dst + 3 + 0 * 32] = avg2(d, e) buf[dst + 2 + 2 * 32] = buf[dst + 3 + 0 * 32]
    buf[dst + 0 + 1 * 32] = avg3(a, b, c)
    buf[dst + 1 + 1 * 32] = avg3(b, c, d) buf[dst + 0 + 3 * 32] = buf[dst + 1 + 1 * 32]
    buf[dst + 2 + 1 * 32] = avg3(c, d, e) buf[dst + 1 + 3 * 32] = buf[dst + 2 + 1 * 32]
    buf[dst + 3 + 1 * 32] = avg3(d, e, f) buf[dst + 2 + 3 * 32] = buf[dst + 3 + 1 * 32]
    buf[dst + 3 + 2 * 32] = avg3(e, f, g)
    buf[dst + 3 + 3 * 32] = avg3(f, g, h)
end

local function hu4(buf, dst)
    local i = buf[dst - 1]
    local j = buf[dst - 1 + 32]
    local k = buf[dst - 1 + 64]
    local l = buf[dst - 1 + 96]
    buf[dst + 0 * 32] = avg2(i, j)
    buf[dst + 2 + 0 * 32] = avg2(j, k) buf[dst + 0 + 1 * 32] = buf[dst + 2 + 0 * 32]
    buf[dst + 2 + 1 * 32] = avg2(k, l) buf[dst + 0 + 2 * 32] = buf[dst + 2 + 1 * 32]
    buf[dst + 1 + 0 * 32] = avg3(i, j, k)
    buf[dst + 3 + 0 * 32] = avg3(j, k, l) buf[dst + 1 + 1 * 32] = buf[dst + 3 + 0 * 32]
    buf[dst + 3 + 1 * 32] = avg3(k, l, l) buf[dst + 1 + 2 * 32] = buf[dst + 3 + 1 * 32]
    local r3 = dst + 3 * 32
    buf[dst + 3 + 2 * 32] = l buf[dst + 2 + 2 * 32] = l
    buf[dst + 0 + 3 * 32] = l buf[dst + 1 + 3 * 32] = l buf[dst + 2 + 3 * 32] = l buf[dst + 3 + 3 * 32] = l
end

local function hd4(buf, dst)
    local i = buf[dst - 1]
    local j = buf[dst - 1 + 32]
    local k = buf[dst - 1 + 64]
    local l = buf[dst - 1 + 96]
    local x = buf[dst - 1 - 32]
    local a = buf[dst - 32]
    local b = buf[dst - 32 + 1]
    local c = buf[dst - 32 + 2]
    buf[dst + 0 * 32] = avg2(i, x) buf[dst + 2 + 1 * 32] = buf[dst + 0 * 32]
    buf[dst + 0 + 1 * 32] = avg2(j, i) buf[dst + 2 + 2 * 32] = buf[dst + 0 + 1 * 32]
    buf[dst + 0 + 2 * 32] = avg2(k, j) buf[dst + 2 + 3 * 32] = buf[dst + 0 + 2 * 32]
    buf[dst + 0 + 3 * 32] = avg2(l, k)
    buf[dst + 3 + 0 * 32] = avg3(a, b, c)
    buf[dst + 2 + 0 * 32] = avg3(x, a, b)
    buf[dst + 1 + 0 * 32] = avg3(i, x, a) buf[dst + 3 + 1 * 32] = buf[dst + 1 + 0 * 32]
    buf[dst + 1 + 1 * 32] = avg3(j, i, x) buf[dst + 3 + 2 * 32] = buf[dst + 1 + 1 * 32]
    buf[dst + 1 + 2 * 32] = avg3(k, j, i) buf[dst + 3 + 3 * 32] = buf[dst + 1 + 2 * 32]
    buf[dst + 1 + 3 * 32] = avg3(l, k, j)
end

local predLuma4 = {
    dc4, function(buf, dst) trueMotion(buf, dst, 4) end, ve4, he4,
    rd4, vr4, ld4, vl4, hd4, hu4,
}

local function checkMode(mbX, mbY, mode)
    if mode == DC_PRED then
        if mbX == 0 then
            if mbY == 0 then return 6 end
            return 5
        end
        if mbY == 0 then return 4 end
        return 0
    end
    return mode
end

-- ---------------------------------------------------------------------------
-- In-loop filtering

local function doFilter2(buf, p, step)
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    local a = 3 * (q0 - p0) + ksclip1(p1 - q1)
    local a1 = ksclip2(sar(a + 4, 3))
    local a2 = ksclip2(sar(a + 3, 3))
    buf[p - step] = clip8(p0 + a2)
    buf[p] = clip8(q0 - a1)
end

local function doFilter4(buf, p, step)
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    local a = 3 * (q0 - p0)
    local a1 = ksclip2(sar(a + 4, 3))
    local a2 = ksclip2(sar(a + 3, 3))
    local a3 = sar(a1 + 1, 1)
    buf[p - 2 * step] = clip8(p1 + a3)
    buf[p - step] = clip8(p0 + a2)
    buf[p] = clip8(q0 - a1)
    buf[p + step] = clip8(q1 - a3)
end

local function doFilter6(buf, p, step)
    local p2 = buf[p - 3 * step]
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    local q2 = buf[p + 2 * step]
    local a = ksclip1(3 * (q0 - p0) + ksclip1(p1 - q1))
    local a1 = sar(27 * a + 63, 7)
    local a2 = sar(18 * a + 63, 7)
    local a3 = sar(9 * a + 63, 7)
    buf[p - 3 * step] = clip8(p2 + a3)
    buf[p - 2 * step] = clip8(p1 + a2)
    buf[p - step] = clip8(p0 + a1)
    buf[p] = clip8(q0 - a1)
    buf[p + step] = clip8(q1 - a2)
    buf[p + 2 * step] = clip8(q2 - a3)
end

local function hev(buf, p, step, thresh)
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    return (kabs0(p1 - p0) > thresh) or (kabs0(q1 - q0) > thresh)
end

local function needsFilter(buf, p, step, t)
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    return (4 * kabs0(p0 - q0) + kabs0(p1 - q1)) <= t
end

local function needsFilter2(buf, p, step, t, it)
    local p3 = buf[p - 4 * step]
    local p2 = buf[p - 3 * step]
    local p1 = buf[p - 2 * step]
    local p0 = buf[p - step]
    local q0 = buf[p]
    local q1 = buf[p + step]
    local q2 = buf[p + 2 * step]
    local q3 = buf[p + 3 * step]
    if (4 * kabs0(p0 - q0) + kabs0(p1 - q1)) > t then return false end
    return kabs0(p3 - p2) <= it and kabs0(p2 - p1) <= it and kabs0(p1 - p0) <= it and
           kabs0(q3 - q2) <= it and kabs0(q2 - q1) <= it and kabs0(q1 - q0) <= it
end

local function filterLoop26(buf, p, hstride, vstride, size, thresh, ithresh, hevThresh)
    local t = 2 * thresh + 1
    for _ = 1, size do
        if needsFilter2(buf, p, hstride, t, ithresh) then
            if hev(buf, p, hstride, hevThresh) then
                doFilter2(buf, p, hstride)
            else
                doFilter6(buf, p, hstride)
            end
        end
        p = p + vstride
    end
end

local function filterLoop24(buf, p, hstride, vstride, size, thresh, ithresh, hevThresh)
    local t = 2 * thresh + 1
    for _ = 1, size do
        if needsFilter2(buf, p, hstride, t, ithresh) then
            if hev(buf, p, hstride, hevThresh) then
                doFilter2(buf, p, hstride)
            else
                doFilter4(buf, p, hstride)
            end
        end
        p = p + vstride
    end
end

local function vFilter16(buf, p, stride, thresh, ithresh, hevThresh)
    filterLoop26(buf, p, stride, 1, 16, thresh, ithresh, hevThresh)
end

local function hFilter16(buf, p, stride, thresh, ithresh, hevThresh)
    filterLoop26(buf, p, 1, stride, 16, thresh, ithresh, hevThresh)
end

local function vFilter16i(buf, p, stride, thresh, ithresh, hevThresh)
    for k = 1, 3 do
        p = p + 4 * stride
        filterLoop24(buf, p, stride, 1, 16, thresh, ithresh, hevThresh)
    end
end

local function hFilter16i(buf, p, stride, thresh, ithresh, hevThresh)
    for k = 1, 3 do
        p = p + 4
        filterLoop24(buf, p, 1, stride, 16, thresh, ithresh, hevThresh)
    end
end

local function vFilter8(bufU, u, bufV, v, stride, thresh, ithresh, hevThresh)
    filterLoop26(bufU, u, stride, 1, 8, thresh, ithresh, hevThresh)
    filterLoop26(bufV, v, stride, 1, 8, thresh, ithresh, hevThresh)
end

local function vFilter8i(bufU, u, bufV, v, stride, thresh, ithresh, hevThresh)
    filterLoop24(bufU, u + 4 * stride, stride, 1, 8, thresh, ithresh, hevThresh)
    filterLoop24(bufV, v + 4 * stride, stride, 1, 8, thresh, ithresh, hevThresh)
end

local function hFilter8(bufU, u, bufV, v, stride, thresh, ithresh, hevThresh)
    filterLoop26(bufU, u, 1, stride, 8, thresh, ithresh, hevThresh)
    filterLoop26(bufV, v, 1, stride, 8, thresh, ithresh, hevThresh)
end

local function hFilter8i(bufU, u, bufV, v, stride, thresh, ithresh, hevThresh)
    filterLoop24(bufU, u + 4, 1, stride, 8, thresh, ithresh, hevThresh)
    filterLoop24(bufV, v + 4, 1, stride, 8, thresh, ithresh, hevThresh)
end

local function simpleVFilter16(buf, p, stride, thresh)
    local t = 2 * thresh + 1
    for i = 0, 15 do
        local pp = p + i
        if needsFilter(buf, pp, stride, t) then doFilter2(buf, pp, stride) end
    end
end

local function simpleHFilter16(buf, p, stride, thresh)
    local t = 2 * thresh + 1
    for i = 0, 15 do
        local pp = p + i * stride
        if needsFilter(buf, pp, 1, t) then doFilter2(buf, pp, 1) end
    end
end

local function simpleVFilter16i(buf, p, stride, thresh)
    for k = 1, 3 do
        p = p + 4 * stride
        simpleVFilter16(buf, p, stride, thresh)
    end
end

local function simpleHFilter16i(buf, p, stride, thresh)
    for k = 1, 3 do
        p = p + 4
        simpleHFilter16(buf, p, stride, thresh)
    end
end

local function doFilter(dec, mbX, mbY)
    local block = dec.mbData[mbX]
    local yBps = dec.cacheYStride
    local yDst = dec.extra * yBps + mbX * 16
    local ilevel = block.fIlevel
    local limit = block.fLimit
    if limit == 0 then return end
    if dec.filterType == 1 then
        if mbX > 0 then simpleHFilter16(dec.cacheY, yDst, yBps, limit + 4) end
        if block.fInner == 1 then simpleHFilter16i(dec.cacheY, yDst, yBps, limit) end
        if mbY > 0 then simpleVFilter16(dec.cacheY, yDst, yBps, limit + 4) end
        if block.fInner == 1 then simpleVFilter16i(dec.cacheY, yDst, yBps, limit) end
    else
        local uvBps = dec.cacheUvStride
        local uDst = dec.extraUV * uvBps + mbX * 8
        local vDst = uDst
        local hevThresh = block.hevThresh
        if mbX > 0 then
            hFilter16(dec.cacheY, yDst, yBps, limit + 4, ilevel, hevThresh)
            hFilter8(dec.cacheU, uDst, dec.cacheV, vDst, uvBps, limit + 4, ilevel, hevThresh)
        end
        if block.fInner == 1 then
            hFilter16i(dec.cacheY, yDst, yBps, limit, ilevel, hevThresh)
            hFilter8i(dec.cacheU, uDst, dec.cacheV, vDst, uvBps, limit, ilevel, hevThresh)
        end
        if mbY > 0 then
            vFilter16(dec.cacheY, yDst, yBps, limit + 4, ilevel, hevThresh)
            vFilter8(dec.cacheU, uDst, dec.cacheV, vDst, uvBps, limit + 4, ilevel, hevThresh)
        end
        if block.fInner == 1 then
            vFilter16i(dec.cacheY, yDst, yBps, limit, ilevel, hevThresh)
            vFilter8i(dec.cacheU, uDst, dec.cacheV, vDst, uvBps, limit, ilevel, hevThresh)
        end
    end
end

local function precomputeFilterStrengths(dec)
    if dec.filterType > 0 then
        local hdr = dec.filterHdr
        local segHdr = dec.segmentHdr
        for s = 0, 3 do
            local baseLevel
            if segHdr.useSegment ~= 0 then
                baseLevel = segHdr.filterStrength[s + 1]
                if segHdr.absoluteDelta == 0 then baseLevel = baseLevel + hdr.level end
            else
                baseLevel = hdr.level
            end
            for i4x4 = 0, 1 do
                local level = baseLevel
                if hdr.useLfDelta ~= 0 then
                    level = level + hdr.refLfDelta[1]
                    if i4x4 == 1 then level = level + hdr.modeLfDelta[1] end
                end
                if level < 0 then level = 0 elseif level > 63 then level = 63 end
                local fs = { fLimit = 0, fIlevel = 0, fInner = i4x4, hevThresh = 0 }
                if level > 0 then
                    local ilevel = level
                    if hdr.sharpness > 0 then
                        if hdr.sharpness > 4 then
                            ilevel = ilevel >> 2
                        else
                            ilevel = ilevel >> 1
                        end
                        if ilevel > 9 - hdr.sharpness then ilevel = 9 - hdr.sharpness end
                    end
                    if ilevel < 1 then ilevel = 1 end
                    fs.fIlevel = ilevel
                    fs.fLimit = 2 * level + ilevel
                    if level >= 40 then
                        fs.hevThresh = 2
                    elseif level >= 15 then
                        fs.hevThresh = 1
                    end
                end
                dec.fstrengths[s + 1][i4x4 + 1] = fs
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Coefficient decoding

local function getLargeValue(br, proba, p)
    local v
    if vp8GetBit(br, proba[p + 3]) == 0 then
        if vp8GetBit(br, proba[p + 4]) == 0 then
            v = 2
        else
            v = 3 + vp8GetBit(br, proba[p + 5])
        end
    elseif vp8GetBit(br, proba[p + 6]) == 0 then
        if vp8GetBit(br, proba[p + 7]) == 0 then
            v = 5 + vp8GetBit(br, 159)
        else
            v = 7 + 2 * vp8GetBit(br, 165)
            v = v + vp8GetBit(br, 145)
        end
    else
        local bit1 = vp8GetBit(br, proba[p + 8])
        local bit0 = vp8GetBit(br, proba[p + 9 + bit1])
        local cat = 2 * bit1 + bit0
        v = 0
        local tab = kCat3456[cat + 1]
        for i = 1, #tab do
            local prob = tab[i]
            if prob == 0 then break end
            v = v + v + vp8GetBit(br, prob)
        end
        v = v + 3 + (8 << cat)
    end
    return v
end

-- dq = { DC, AC }; proba is a flat 0-based 4*8*3*11 table.
local function getCoeffs(br, proba, t, n, ctx, dq, out, outOff)
    local p = ((t * 8 + kBands[n + 1]) * 3 + ctx) * 11
    while n < 16 do
        if vp8GetBit(br, proba[p]) == 0 then return n end
        while vp8GetBit(br, proba[p + 1]) == 0 do
            n = n + 1
            if n == 16 then return 16 end
            p = (t * 8 + kBands[n + 1]) * 33
        end
        local v
        if vp8GetBit(br, proba[p + 2]) == 0 then
            v = 1
            p = (t * 8 + kBands[n + 2]) * 33 + 11
        else
            v = getLargeValue(br, proba, p)
            p = (t * 8 + kBands[n + 2]) * 33 + 22
        end
        out[outOff + kZigzag[n + 1]] = vp8GetSigned(br, v) * dq[(n > 0) and 2 or 1]
        n = n + 1
    end
    return 16
end

local function parseResiduals(dec, tokenBr)
    local mbX = dec.mbX
    local mb = dec.mbInfo[mbX + 2]
    local leftMb = dec.mbInfo[1]
    local block = dec.mbData[mbX]
    local q = dec.dqm[block.segment + 1]
    local dst = block.coeffs
    for i = 0, 383 do dst[i] = 0 end
    local nonZeroY = 0
    local nonZeroUv = 0
    local first
    local outOff = 0
    if block.isI4x4 == 0 then
        local dc = {}
        for i = 0, 15 do dc[i] = 0 end
        local ctx = mb.nzDc + leftMb.nzDc
        local nz = getCoeffs(tokenBr, dec.proba, 1, 0, ctx, q.y2, dc, 0)
        mb.nzDc = (nz > 0) and 1 or 0
        leftMb.nzDc = mb.nzDc
        if nz > 1 then
            transformWHT(dc, 0, dst, 0)
        else
            local dc0 = sar(dc[0] + 3, 3)
            for i = 0, 15 do dst[i * 16] = dc0 end
        end
        first = 1
    else
        first = 0
    end
    local acT = (block.isI4x4 == 0) and 0 or 3
    local tnz = mb.nz & 0x0f
    local lnz = leftMb.nz & 0x0f
    for y = 0, 3 do
        local l = lnz & 1
        local nzCoeffs = 0
        for x = 0, 3 do
            local ctx = l + (tnz & 1)
            local nz = getCoeffs(tokenBr, dec.proba, acT, first, ctx, q.y1, dst, outOff)
            l = (nz > first) and 1 or 0
            tnz = ((tnz >> 1) | (l << 7)) & 0xff
            local code = 0
            if nz > 3 then code = 3 elseif nz > 1 then code = 2 elseif dst[outOff] ~= 0 then code = 1 end
            nzCoeffs = ((nzCoeffs << 2) | code) & 0xff
            outOff = outOff + 16
        end
        tnz = tnz >> 4
        lnz = ((lnz >> 1) | (l << 7)) & 0xff
        nonZeroY = ((nonZeroY << 8) | nzCoeffs) & 0xffffffff
    end
    local outTNz = tnz
    local outLNz = lnz >> 4
    for ch = 0, 2, 2 do
        local nzCoeffs = 0
        tnz = (mb.nz >> (4 + ch)) & 0xff
        lnz = (leftMb.nz >> (4 + ch)) & 0xff
        for y = 0, 1 do
            local l = lnz & 1
            for x = 0, 1 do
                local ctx = l + (tnz & 1)
                local nz = getCoeffs(tokenBr, dec.proba, 2, 0, ctx, q.uv, dst, outOff)
                l = (nz > 0) and 1 or 0
                tnz = ((tnz >> 1) | (l << 3)) & 0xff
                local code = 0
                if nz > 3 then code = 3 elseif nz > 1 then code = 2 elseif dst[outOff] ~= 0 then code = 1 end
                nzCoeffs = ((nzCoeffs << 2) | code) & 0xff
                outOff = outOff + 16
            end
            tnz = tnz >> 2
            lnz = ((lnz >> 1) | (l << 5)) & 0xff
        end
        nonZeroUv = (nonZeroUv | (nzCoeffs << (4 * ch))) & 0xffffffff
        outTNz = outTNz | ((tnz << 4) << ch)
        outLNz = outLNz | ((lnz & 0xf0) << ch)
    end
    mb.nz = outTNz & 0xff
    leftMb.nz = outLNz & 0xff
    block.nonZeroY = nonZeroY
    block.nonZeroUv = nonZeroUv
    block.dither = 0
    return (nonZeroY | nonZeroUv) == 0
end

local function parseIntraMode(br, dec, mbX)
    local topBase = mbX * 4
    local block = dec.mbData[mbX]
    if dec.segmentHdr.updateMap ~= 0 then
        if vp8GetBit(br, dec.probaSegments[1]) == 0 then
            block.segment = vp8GetBit(br, dec.probaSegments[2])
        else
            block.segment = vp8GetBit(br, dec.probaSegments[3]) + 2
        end
    else
        block.segment = 0
    end
    if dec.useSkipProba ~= 0 then
        block.skip = vp8GetBit(br, dec.skipP)
    end
    block.isI4x4 = (vp8GetBit(br, 145) == 0) and 1 or 0
    if block.isI4x4 == 0 then
        local ymode
        if vp8GetBit(br, 156) ~= 0 then
            if vp8GetBit(br, 128) ~= 0 then ymode = TM_PRED else ymode = H_PRED end
        else
            if vp8GetBit(br, 163) ~= 0 then ymode = V_PRED else ymode = DC_PRED end
        end
        block.imodes[1] = ymode
        for i = 1, 4 do
            dec.intraT[topBase + i] = ymode
            dec.intraL[i] = ymode
        end
    else
        for y = 0, 3 do
            local ymode = dec.intraL[y + 1]
            for x = 0, 3 do
                local base = (dec.intraT[topBase + x + 1] * 10 + ymode) * 9
                if vp8GetBit(br, kBModesProba[base + 1]) == 0 then
                    ymode = 0
                elseif vp8GetBit(br, kBModesProba[base + 2]) == 0 then
                    ymode = 1
                elseif vp8GetBit(br, kBModesProba[base + 3]) == 0 then
                    ymode = 2
                elseif vp8GetBit(br, kBModesProba[base + 4]) == 0 then
                    if vp8GetBit(br, kBModesProba[base + 5]) == 0 then
                        ymode = 3
                    elseif vp8GetBit(br, kBModesProba[base + 6]) == 0 then
                        ymode = 4
                    else
                        ymode = 5
                    end
                elseif vp8GetBit(br, kBModesProba[base + 7]) == 0 then
                    ymode = 6
                elseif vp8GetBit(br, kBModesProba[base + 8]) == 0 then
                    ymode = 7
                elseif vp8GetBit(br, kBModesProba[base + 9]) == 0 then
                    ymode = 8
                else
                    ymode = 9
                end
                dec.intraT[topBase + x + 1] = ymode
                block.imodes[y * 4 + x + 1] = ymode
            end
            dec.intraL[y + 1] = ymode
        end
    end
    if vp8GetBit(br, 142) == 0 then
        block.uvMode = DC_PRED
    elseif vp8GetBit(br, 114) == 0 then
        block.uvMode = V_PRED
    else
        if vp8GetBit(br, 183) ~= 0 then block.uvMode = TM_PRED else block.uvMode = H_PRED end
    end
end

local function parseIntraModeRow(br, dec)
    for mbX = 0, dec.mbW - 1 do
        parseIntraMode(br, dec, mbX)
    end
    return br.eof == 0
end

local function initScanline(dec)
    local leftMb = dec.mbInfo[1]
    leftMb.nz = 0
    leftMb.nzDc = 0
    for i = 1, 4 do dec.intraL[i] = 0 end
    dec.mbX = 0
end

local function decodeMB(dec, tokenBr)
    local mbX = dec.mbX
    local leftMb = dec.mbInfo[1]
    local mb = dec.mbInfo[mbX + 2]
    local block = dec.mbData[mbX]
    local skip = (dec.useSkipProba ~= 0) and block.skip or 0
    if skip == 0 then
        skip = parseResiduals(dec, tokenBr) and 1 or 0
    else
        leftMb.nz = 0
        mb.nz = 0
        if block.isI4x4 == 0 then
            leftMb.nzDc = 0
            mb.nzDc = 0
        end
        block.nonZeroY = 0
        block.nonZeroUv = 0
        block.dither = 0
    end
    if dec.filterType > 0 then
        local fs = dec.fstrengths[block.segment + 1][block.isI4x4 + 1]
        block.fLimit = fs.fLimit
        block.fIlevel = fs.fIlevel
        block.hevThresh = fs.hevThresh
        block.fInner = (fs.fInner ~= 0 or skip == 0) and 1 or 0
    end
    return tokenBr.eof == 0
end

local function reconstructRow(dec, mbY)
    local mbW = dec.mbW
    local mbH = dec.mbH
    local yBps = dec.cacheYStride
    local uvBps = dec.cacheUvStride
    local cacheY = dec.cacheY
    local cacheU = dec.cacheU
    local cacheV = dec.cacheV
    for j = 0, 15 do yArr[YBASE + j * 32 - 1] = 129 end
    for j = 0, 7 do
        uArr[UBASE + j * 32 - 1] = 129
        vArr[VBASE + j * 32 - 1] = 129
    end
    if mbY > 0 then
        yArr[YBASE - 33] = 129
        uArr[UBASE - 33] = 129
        vArr[VBASE - 33] = 129
    else
        for x = -1, 19 do yArr[YBASE - 32 + x] = 127 end
        for x = -1, 7 do
            uArr[UBASE - 32 + x] = 127
            vArr[VBASE - 32 + x] = 127
        end
    end
    for mbX = 0, mbW - 1 do
        local block = dec.mbData[mbX]
        local coeffs = block.coeffs
        local topYuv = dec.yuvT[mbX + 1]
        if mbX > 0 then
            for j = -1, 15 do
                for i = 0, 3 do yArr[YBASE + j * 32 - 4 + i] = yArr[YBASE + j * 32 + 12 + i] end
            end
            for j = -1, 7 do
                for i = 0, 3 do
                    uArr[UBASE + j * 32 - 4 + i] = uArr[UBASE + j * 32 + 4 + i]
                    vArr[VBASE + j * 32 - 4 + i] = vArr[VBASE + j * 32 + 4 + i]
                end
            end
        end
        if mbY > 0 then
            for i = 0, 15 do yArr[YBASE - 32 + i] = topYuv.y[i + 1] end
            for i = 0, 7 do
                uArr[UBASE - 32 + i] = topYuv.u[i + 1]
                vArr[VBASE - 32 + i] = topYuv.v[i + 1]
            end
        end
        if block.isI4x4 ~= 0 then
            if mbY > 0 then
                if mbX >= mbW - 1 then
                    local v = topYuv.y[16]
                    for i = 0, 3 do yArr[YBASE - 32 + 16 + i] = v end
                else
                    local nxt = dec.yuvT[mbX + 2]
                    for i = 0, 3 do yArr[YBASE - 32 + 16 + i] = nxt.y[i + 1] end
                end
            end
            for r = 1, 3 do
                for i = 0, 3 do yArr[YBASE - 32 + 16 + r * 128 + i] = yArr[YBASE - 32 + 16 + i] end
            end
            local bits = block.nonZeroY
            for n = 0, 15 do
                local d = YBASE + kScan[n + 1]
                predLuma4[block.imodes[n + 1] + 1](yArr, d)
                doTransform(bits, coeffs, n * 16, yArr, d)
                bits = (bits << 2) & 0xFFFFFFFF
            end
        else
            local pred = checkMode(mbX, mbY, block.imodes[1])
            predLuma16[pred + 1](yArr, YBASE)
            local bits = block.nonZeroY
            if bits ~= 0 then
                for n = 0, 15 do
                    doTransform(bits, coeffs, n * 16, yArr, YBASE + kScan[n + 1])
                    bits = (bits << 2) & 0xFFFFFFFF
                end
            end
        end
        local bitsUV = block.nonZeroUv
        local pred = checkMode(mbX, mbY, block.uvMode)
        predChroma8[pred + 1](uArr, UBASE)
        predChroma8[pred + 1](vArr, VBASE)
        doUvTransform(bitsUV & 0xff, coeffs, 256, uArr, UBASE)
        doUvTransform(bitsUV >> 8, coeffs, 320, vArr, VBASE)
        if mbY < mbH - 1 then
            for i = 0, 15 do topYuv.y[i + 1] = yArr[YBASE + 480 + i] end
            for i = 0, 7 do
                topYuv.u[i + 1] = uArr[UBASE + 224 + i]
                topYuv.v[i + 1] = vArr[VBASE + 224 + i]
            end
        end
        local yOut = dec.extra * yBps + mbX * 16
        local uvOut = dec.extraUV * uvBps + mbX * 8
        for j = 0, 15 do
            local sr = YBASE + j * 32
            local dr = yOut + j * yBps
            for i = 0, 15 do cacheY[dr + i] = yArr[sr + i] end
        end
        for j = 0, 7 do
            local sr = UBASE + j * 32
            local dr = uvOut + j * uvBps
            for i = 0, 7 do
                cacheU[dr + i] = uArr[sr + i]
                cacheV[dr + i] = vArr[sr + i]
            end
        end
    end
end

local function clipYUV(v)
    if (v & ~0x3FFF) == 0 then return v >> 6 end
    if v < 0 then return 0 end
    return 255
end

local function writeRgbPixel(rgb, o, yv, u, v)
    rgb[o] = clipYUV(((yv * 19077) >> 8) + ((v * 26149) >> 8) - 14234)
    rgb[o + 1] = clipYUV(((yv * 19077) >> 8) - ((u * 6419) >> 8) - ((v * 13320) >> 8) + 8708)
    rgb[o + 2] = clipYUV(((yv * 19077) >> 8) + ((u * 33050) >> 8) - 17685)
end

-- Port of libwebp's UpsampleRgbLinePair_C (fancy upsampling).
-- Each sample row is described by (arr, base); samples are arr[base + i].
-- yBotArr == nil (and dstBot == nil) for single-row mirror calls.
local function upsampleLinePair(yTopArr, yTopBase, yBotArr, yBotBase,
                                uTopArr, uTopBase, vTopArr, vTopBase,
                                uBotArr, uBotBase, vBotArr, vBotBase,
                                rgb, width, dstTop, dstBot)
    local lastPair = (width - 1) >> 1
    local tlU = uTopArr[uTopBase]
    local tlV = vTopArr[vTopBase]
    local lU = uBotArr[uBotBase]
    local lV = vBotArr[vBotBase]
    local o = dstTop * width * 3
    writeRgbPixel(rgb, o, yTopArr[yTopBase],
                  (3 * tlU + lU + 2) >> 2, (3 * tlV + lV + 2) >> 2)
    if yBotArr then
        local ob = dstBot * width * 3
        writeRgbPixel(rgb, ob, yBotArr[yBotBase],
                      (3 * lU + tlU + 2) >> 2, (3 * lV + tlV + 2) >> 2)
    end
    for x = 1, lastPair do
        local tU = uTopArr[uTopBase + x]
        local tV = vTopArr[vTopBase + x]
        local cU = uBotArr[uBotBase + x]
        local cV = vBotArr[vBotBase + x]
        local avgU = tlU + tU + lU + cU + 8
        local avgV = tlV + tV + lV + cV + 8
        local d12U = (avgU + 2 * (tU + lU)) >> 3
        local d03U = (avgU + 2 * (tlU + cU)) >> 3
        local d12V = (avgV + 2 * (tV + lV)) >> 3
        local d03V = (avgV + 2 * (tlV + cV)) >> 3
        local o2 = o + (2 * x - 1) * 3
        writeRgbPixel(rgb, o2, yTopArr[yTopBase + 2 * x - 1],
                      (d12U + tlU) >> 1, (d12V + tlV) >> 1)
        writeRgbPixel(rgb, o2 + 3, yTopArr[yTopBase + 2 * x],
                      (d03U + tU) >> 1, (d03V + tV) >> 1)
        if yBotArr then
            local ob = dstBot * width * 3 + (2 * x - 1) * 3
            writeRgbPixel(rgb, ob, yBotArr[yBotBase + 2 * x - 1],
                          (d03U + lU) >> 1, (d03V + lV) >> 1)
            writeRgbPixel(rgb, ob + 3, yBotArr[yBotBase + 2 * x],
                          (d12U + cU) >> 1, (d12V + cV) >> 1)
        end
        tlU = tU
        tlV = tV
        lU = cU
        lV = cV
    end
    if (width & 1) == 0 then
        local o2 = o + (width - 1) * 3
        writeRgbPixel(rgb, o2, yTopArr[yTopBase + width - 1],
                      (3 * tlU + lU + 2) >> 2, (3 * tlV + lV + 2) >> 2)
        if yBotArr then
            local ob = dstBot * width * 3 + (width - 1) * 3
            writeRgbPixel(rgb, ob, yBotArr[yBotBase + width - 1],
                          (3 * lU + tlU + 2) >> 2, (3 * lV + tlV + 2) >> 2)
        end
    end
end

local function finishRow(dec, isFirst, isLast)
    local width = dec.width
    local height = dec.height
    local mbY = dec.mbY
    local yStart = mbY * 16
    local yEnd = yStart + 16
    if not isFirst then yStart = yStart - dec.extra end
    if not isLast then yEnd = yEnd - dec.extra end
    if yEnd > height then yEnd = height end
    if yStart < yEnd then
        local rowOff = isFirst and dec.extra or 0
        local uvOff = isFirst and dec.extraUV or 0
        local yBps = dec.cacheYStride
        local uvBps = dec.cacheUvStride
        local cacheY = dec.cacheY
        local cacheU = dec.cacheU
        local cacheV = dec.cacheV
        local rgb = dec.rgb
        if yStart == 0 then
            -- First line is special cased: mirror the u/v samples at boundary.
            local yBase = rowOff * yBps
            local uvBase = uvOff * uvBps
            upsampleLinePair(cacheY, yBase, nil, 0,
                             cacheU, uvBase, cacheV, uvBase,
                             cacheU, uvBase, cacheV, uvBase,
                             rgb, width, 0, nil)
        else
            -- Finish the left-over row from the previous call.
            local uvBase = uvOff * uvBps
            upsampleLinePair(dec.tmpY, 0, cacheY, rowOff * yBps,
                             dec.tmpU, 0, dec.tmpV, 0,
                             cacheU, uvBase, cacheV, uvBase,
                             rgb, width, yStart - 1, yStart)
        end
        -- Loop over each output pair of rows.
        local k = 1
        while yStart + 2 * k < yEnd do
            local yRow = rowOff + 2 * k - 1
            local uvRow = uvOff + k - 1
            upsampleLinePair(cacheY, yRow * yBps, cacheY, (yRow + 1) * yBps,
                             cacheU, uvRow * uvBps, cacheV, uvRow * uvBps,
                             cacheU, (uvRow + 1) * uvBps, cacheV, (uvRow + 1) * uvBps,
                             rgb, width, yStart + 2 * k - 1, yStart + 2 * k)
            k = k + 1
        end
        -- Move to the last row.
        local curY = yStart + 2 * (k - 1) + 1
        if yEnd < height then
            -- Save the unfinished samples for the next call (not done yet).
            local yBase = (rowOff + curY - yStart) * yBps
            local uvBase = (uvOff + (curY >> 1) - (yStart >> 1)) * uvBps
            local uvWidth = (width + 1) >> 1
            for i = 0, width - 1 do dec.tmpY[i] = cacheY[yBase + i] end
            for i = 0, uvWidth - 1 do
                dec.tmpU[i] = cacheU[uvBase + i]
                dec.tmpV[i] = cacheV[uvBase + i]
            end
        else
            -- Process the very last row of an even-sized picture.
            if (yEnd & 1) == 0 then
                local yBase = (rowOff + yEnd - 1 - yStart) * yBps
                local uvBase = (uvOff + ((yEnd - 1 - yStart) >> 1)) * uvBps
                upsampleLinePair(cacheY, yBase, nil, 0,
                                 cacheU, uvBase, cacheV, uvBase,
                                 cacheU, uvBase, cacheV, uvBase,
                                 rgb, width, yEnd - 1, nil)
            end
        end
    end
    if not isLast then
        local yBps = dec.cacheYStride
        local uvBps = dec.cacheUvStride
        local cacheY = dec.cacheY
        local cacheU = dec.cacheU
        local cacheV = dec.cacheV
        for k = 0, dec.extra - 1 do
            local src = (16 + k) * yBps
            local dst = k * yBps
            for i = 0, yBps - 1 do cacheY[dst + i] = cacheY[src + i] end
        end
        for k = 0, dec.extraUV - 1 do
            local src = (8 + k) * uvBps
            local dst = k * uvBps
            for i = 0, uvBps - 1 do
                cacheU[dst + i] = cacheU[src + i]
                cacheV[dst + i] = cacheV[src + i]
            end
        end
    end
end

local function decodeVP8Payload(payload, alphaPayload)
    local len = #payload
    if len < 11 then return nil end
    local b1, b2, b3 = string.byte(payload, 1, 3)
    local bits = (b1 or 0) | ((b2 or 0) << 8) | ((b3 or 0) << 16)
    if (bits & 1) ~= 0 then return nil end
    local profile = (bits >> 1) & 7
    if profile > 3 then return nil end
    if ((bits >> 4) & 1) == 0 then return nil end
    local partitionLength = bits >> 5
    local s3, s4, s5, s6, s7 = string.byte(payload, 4, 8)
    if (s3 or 0) ~= 0x9d or (s4 or 0) ~= 0x01 or (s5 or 0) ~= 0x2a then return nil end
    local width = (((s7 or 0) << 8) | (s6 or 0)) & 0x3fff
    local b8, b9 = string.byte(payload, 9, 10)
    local height = (((b9 or 0) << 8) | (b8 or 0)) & 0x3fff
    if width < 1 or height < 1 or width * height > MAX_PIXELS then return nil end
    if 11 + partitionLength > len + 1 then return nil end

    local dec = {
        width = width,
        height = height,
        mbW = (width + 15) >> 4,
        mbH = (height + 15) >> 4,
        filterType = 0,
        segmentHdr = { useSegment = 0, updateMap = 0, absoluteDelta = 0,
                       quantizer = { 0, 0, 0, 0 }, filterStrength = { 0, 0, 0, 0 } },
        filterHdr = { simple = 0, level = 0, sharpness = 0, useLfDelta = 0,
                      refLfDelta = { 0, 0, 0, 0 }, modeLfDelta = { 0, 0, 0, 0 } },
        probaSegments = { 255, 255, 255 },
        proba = {},
        dqm = {},
        fstrengths = { {}, {}, {}, {} },
        useSkipProba = 0,
        skipP = 0,
    }
    for ci = 0, 1055 do dec.proba[ci] = CoeffsProba0[ci + 1] end
    dec.br = newBr(payload, 11, partitionLength)

    vp8GetBit(dec.br, 128) -- colorspace
    vp8GetBit(dec.br, 128) -- clamp_type
    if not parseSegmentHeader(dec.br, dec) then return nil end
    if not parseFilterHeader(dec.br, dec) then return nil end
    local nParts = 1 << vp8GetValue(dec.br, 2)
    dec.numPartsMinusOne = nParts - 1
    local last = nParts - 1
    local sizesStart = 11 + partitionLength
    local partStart = sizesStart + 3 * last
    if partStart > len + 1 then return nil end
    dec.parts = {}
    for p = 0, last - 1 do
        local i1, i2, i3 = string.byte(payload, sizesStart + p * 3, sizesStart + p * 3 + 2)
        local psize = (i1 or 0) | ((i2 or 0) << 8) | ((i3 or 0) << 16)
        local remaining = len - partStart + 1
        if psize > remaining then psize = remaining end
        dec.parts[p + 1] = newBr(payload, partStart, psize)
        partStart = partStart + psize
    end
    dec.parts[nParts] = newBr(payload, partStart, len - partStart + 1)
    parseQuant(dec.br, dec)
    vp8GetBit(dec.br, 128)
    parseProba(dec.br, dec)

    local extra = kFilterExtraRows[dec.filterType + 1]
    local extraUV = extra >> 1
    local yBps = 16 * dec.mbW
    local uvBps = 8 * dec.mbW
    local cacheY = {}
    for i = 0, (extra + 16) * yBps - 1 do cacheY[i] = 127 end
    local cacheU = {}
    for i = 0, (extraUV + 8) * uvBps - 1 do cacheU[i] = 127 end
    local cacheV = {}
    for i = 0, (extraUV + 8) * uvBps - 1 do cacheV[i] = 127 end
    local rgb = {}
    for i = 0, width * height * 3 - 1 do rgb[i] = 0 end
    dec.extra = extra
    dec.extraUV = extraUV
    dec.cacheYStride = yBps
    dec.cacheUvStride = uvBps
    dec.cacheY = cacheY
    dec.cacheU = cacheU
    dec.cacheV = cacheV
    dec.rgb = rgb
    dec.tmpY = {}
    dec.tmpU = {}
    dec.tmpV = {}
    dec.mbData = {}
    for mbX = 0, dec.mbW - 1 do
        local block = {
            segment = 0, skip = 0, isI4x4 = 0,
            imodes = {}, uvMode = 0,
            coeffs = {},
            nonZeroY = 0, nonZeroUv = 0, dither = 0,
            fLimit = 0, fIlevel = 0, hevThresh = 0, fInner = 0,
        }
        for i = 0, 383 do block.coeffs[i] = 0 end
        dec.mbData[mbX] = block
    end
    dec.mbInfo = {}
    for i = 1, dec.mbW + 1 do dec.mbInfo[i] = { nz = 0, nzDc = 0 } end
    dec.intraT = {}
    for i = 1, 4 * dec.mbW do dec.intraT[i] = 0 end
    dec.intraL = { 0, 0, 0, 0 }
    dec.yuvT = {}
    for i = 1, dec.mbW + 1 do
        dec.yuvT[i] = { y = {}, u = {}, v = {} }
        for k = 1, 16 do dec.yuvT[i].y[k] = 0 end
        for k = 1, 8 do
            dec.yuvT[i].u[k] = 0
            dec.yuvT[i].v[k] = 0
        end
    end
    precomputeFilterStrengths(dec)

    dec.mbX = 0
    for mbY = 0, dec.mbH - 1 do
        Tasks.yieldCheck()
        dec.mbY = mbY
        local tokenBr = dec.parts[(mbY & dec.numPartsMinusOne) + 1]
        if not parseIntraModeRow(dec.br, dec) then return nil end
        for mbX = 0, dec.mbW - 1 do
            dec.mbX = mbX
            if not decodeMB(dec, tokenBr) then return nil end
        end
        initScanline(dec)
        reconstructRow(dec, mbY)
        if dec.filterType > 0 then
            for mbX = 0, dec.mbW - 1 do doFilter(dec, mbX, mbY) end
        end
        finishRow(dec, mbY == 0, mbY == dec.mbH - 1)
    end
    local alpha = decodeAlphaPlane(alphaPayload, width, height)
    return rgb, width, height, alpha
end

local function parseWebP(data)
    if #data < 20 then return nil end
    if string.sub(data, 1, 4) ~= "RIFF" or string.sub(data, 9, 12) ~= "WEBP" then return nil end
    local pos = 13
    local len = #data
    local vp8Payload = nil
    local alphaData = nil
    while pos + 8 <= len do
        local cid = string.sub(data, pos, pos + 3)
        local s4, s5, s6, s7 = string.byte(data, pos + 4, pos + 7)
        local size = (s4 or 0) | ((s5 or 0) << 8) | ((s6 or 0) << 16) | ((s7 or 0) << 24)
        if cid == "ALPH" then
            alphaData = string.sub(data, pos + 8, pos + 7 + size)
        elseif cid == "VP8L" then
            return cid, string.sub(data, pos + 8, pos + 7 + size)
        elseif cid == "VP8 " then
            vp8Payload = string.sub(data, pos + 8, pos + 7 + size)
        end
        pos = pos + 8 + size + (size & 1)
    end
    if vp8Payload then return "VP8 ", vp8Payload, alphaData end
    return nil
end

-- ---------------------------------------------------------------------------
-- Animated WebP (VP8X + ANIM + ANMF). Port of libwebp 1.6.0 demux.c
-- (ParseVP8X / ParseAnimationFrame) + anim_decode.c (WebPAnimDecoderGetNext).

local function readLE24(data, pos)
    local b1, b2, b3 = string.byte(data, pos, pos + 2)
    return (b1 or 0) | ((b2 or 0) << 8) | ((b3 or 0) << 16)
end

-- Parse the container of an animated WebP. Returns nil if not animated.
-- Otherwise: canvasW, canvasH, bgcolor, loopCount, frames[] where each frame is
-- { x, y, w, h, duration, dispose, noBlend, cid, payload, alpha }.
local function parseWebPAnimation(data)
    if #data < 20 then return nil end
    if string.sub(data, 1, 4) ~= "RIFF" or string.sub(data, 9, 12) ~= "WEBP" then return nil end
    local pos = 13
    local len = #data
    local canvasW, canvasH, bgcolor, loopCount = nil, nil, 0, 0
    local frames = {}
    local isExtended = false
    local seenAnim = false
    while pos + 8 <= len do
        local cid = string.sub(data, pos, pos + 3)
        local s4, s5, s6, s7 = string.byte(data, pos + 4, pos + 7)
        local size = (s4 or 0) | ((s5 or 0) << 8) | ((s6 or 0) << 16) | ((s7 or 0) << 24)
        if cid == "VP8X" then
            isExtended = true
            local p = pos + 8
            local flags = string.byte(data, p) or 0
            canvasW = readLE24(data, p + 4) + 1
            canvasH = readLE24(data, p + 7) + 1
            if canvasW < 1 or canvasH < 1 or canvasW * canvasH > MAX_PIXELS then return nil end
            if (flags & 0x02) == 0 then return nil end
        elseif cid == "ANIM" then
            seenAnim = true
            local p = pos + 8
            local a, r, g, b = string.byte(data, p, p + 3)
            bgcolor = ((a or 0) << 24) | ((r or 0) << 16) | ((g or 0) << 8) | (b or 0)
            local l1, l2 = string.byte(data, p + 4, p + 5)
            loopCount = (l1 or 0) | ((l2 or 0) << 8)
        elseif cid == "ANMF" then
            if not seenAnim then return nil end
            local payload = string.sub(data, pos + 8, pos + 7 + size)
            if #payload < 16 then return nil end
            local x = 2 * readLE24(payload, 1)
            local y = 2 * readLE24(payload, 4)
            local w = readLE24(payload, 7) + 1
            local h = readLE24(payload, 10) + 1
            local duration = readLE24(payload, 13)
            local bits = string.byte(payload, 16) or 0
            local ipos = 17
            local f = {
                x = x, y = y, w = w, h = h, duration = duration,
                dispose = (bits & 1) == 1,
                noBlend = ((bits >> 1) & 1) == 1,
            }
            while ipos + 8 <= #payload do
                local icid = string.sub(payload, ipos, ipos + 3)
                local i4, i5, i6, i7 = string.byte(payload, ipos + 4, ipos + 7)
                local isize = (i4 or 0) | ((i5 or 0) << 8) | ((i6 or 0) << 16) | ((i7 or 0) << 24)
                if icid == "ALPH" then
                    f.alpha = string.sub(payload, ipos + 8, ipos + 7 + isize)
                elseif icid == "VP8L" then
                    f.cid = "VP8L"
                    f.payload = string.sub(payload, ipos + 8, ipos + 7 + isize)
                elseif icid == "VP8 " then
                    f.cid = "VP8 "
                    f.payload = string.sub(payload, ipos + 8, ipos + 7 + isize)
                end
                ipos = ipos + 8 + isize + (isize & 1)
            end
            if not f.cid or not f.payload then return nil end
            if f.x + f.w > canvasW or f.y + f.h > canvasH then return nil end
            frames[#frames + 1] = f
        end
        pos = pos + 8 + size + (size & 1)
    end
    if not isExtended or #frames == 0 then return nil end
    return canvasW, canvasH, bgcolor, loopCount, frames
end

local function blendPixelNonPremult(src, dst)
    local srcA = (src >> 24) & 0xFF
    if srcA == 0 then return dst end
    local dstA = (dst >> 24) & 0xFF
    local dstFactorA = (dstA * (256 - srcA)) >> 8
    local blendA = srcA + dstFactorA
    local scale = math.floor(16777216 / blendA)
    local function chan(shift)
        local sc = (src >> shift) & 0xFF
        local dc = (dst >> shift) & 0xFF
        return math.floor((sc * srcA + dc * dstFactorA) * scale / 16777216)
    end
    return (chan(16) << 16) | (chan(8) << 8) | chan(0) | (blendA << 24)
end

-- Decode an animated WebP into a list of blended, canvas-sized ARGB frames.
-- Returns { width, height, bgcolor, loop, frames = { { pix, duration } } }.
function WebPDecoder.decodeAnimation(data)
    local canvasW, canvasH, bgcolor, loopCount, frames = parseWebPAnimation(data)
    if not canvasW then return nil end
    local total = canvasW * canvasH
    if total < 1 or total > MAX_PIXELS then return nil end

    local curr = {}
    local prevDisposed = nil
    local prevIter = nil
    local prevWasKey = false
    local out = {}

    for i, f in ipairs(frames) do
        local fargb, fw, fh
        if f.cid == "VP8L" then
            fargb, fw, fh = decodeVP8LPayload(f.payload)
        else
            local rgb, alpha
            rgb, fw, fh, alpha = decodeVP8Payload(f.payload, f.alpha)
            if not rgb then return nil end
            fargb = {}
            for j = 0, fw * fh - 1 do
                local o = j * 3
                local a = alpha and alpha[j] or 0xFF
                fargb[j] = (a << 24) | (rgb[o] << 16) | (rgb[o + 1] << 8) | rgb[o + 2]
            end
        end
        if not fargb then return nil end

        local hasAlpha = (f.cid == "VP8L") or (f.alpha ~= nil)
        local isKey
        if i == 1 then
            isKey = true
        elseif (not hasAlpha or f.noBlend) and f.w == canvasW and f.h == canvasH then
            isKey = true
        else
            isKey = prevIter.dispose and (prevIter.w == canvasW or prevWasKey)
        end

        if isKey then
            for j = 0, total - 1 do curr[j] = 0 end
        else
            for j = 0, total - 1 do curr[j] = prevDisposed[j] end
        end

        local oy = f.y * canvasW + f.x
        local fy, fx
        for fy = 0, f.h - 1 do
            local dst = oy + fy * canvasW
            local src = fy * f.w
            for fx = 0, f.w - 1 do
                curr[dst + fx] = fargb[src + fx]
            end
        end

        if i > 1 and not f.noBlend and not isKey then
            if not prevIter.dispose then
                for fy = 0, f.h - 1 do
                    local off = (f.y + fy) * canvasW + f.x
                    for fx = 0, f.w - 1 do
                        local v = curr[off + fx]
                        if ((v >> 24) & 0xFF) ~= 0xFF then
                            curr[off + fx] = blendPixelNonPremult(v, prevDisposed[off + fx])
                        end
                    end
                end
            else
                local srcMaxX = f.x + f.w
                local dstMaxX = prevIter.x + prevIter.w
                local dstMaxY = prevIter.y + prevIter.h
                for fy = 0, f.h - 1 do
                    local canvasY = f.y + fy
                    local ranges = {}
                    if canvasY < prevIter.y or canvasY >= dstMaxY or
                       f.x >= dstMaxX or srcMaxX <= prevIter.x then
                        ranges[1] = { left = f.x, width = f.w }
                    else
                        local n = 0
                        if f.x < prevIter.x then
                            n = n + 1
                            ranges[n] = { left = f.x, width = prevIter.x - f.x }
                        end
                        if srcMaxX > dstMaxX then
                            n = n + 1
                            ranges[n] = { left = dstMaxX, width = srcMaxX - dstMaxX }
                        end
                    end
                    for _, r in ipairs(ranges) do
                        local off = canvasY * canvasW + r.left
                        for fx = 0, r.width - 1 do
                            local v = curr[off + fx]
                            if ((v >> 24) & 0xFF) ~= 0xFF then
                                curr[off + fx] = blendPixelNonPremult(v, prevDisposed[off + fx])
                            end
                        end
                    end
                end
            end
        end

        prevIter = f
        prevWasKey = isKey
        prevDisposed = {}
        for j = 0, total - 1 do prevDisposed[j] = curr[j] end

        local outPix = {}
        for j = 0, total - 1 do outPix[j] = curr[j] end
        out[#out + 1] = { pix = outPix, duration = f.duration }
        if f.dispose then
            local oy = f.y * canvasW + f.x
            for fy = 0, f.h - 1 do
                local off = oy + fy * canvasW
                for fx = 0, f.w - 1 do
                    prevDisposed[off + fx] = 0
                end
            end
        end

    end

    return { width = canvasW, height = canvasH, bgcolor = bgcolor, loop = loopCount, frames = out }
end

local function composite(gray, a)
    if a >= 255 then return gray end
    if a <= 0 then return 255 end
    return math.floor((gray * a + 255 * (255 - a)) / 255 + 0.5)
end

function WebPDecoder.decode(data, maxW, maxH)
    maxW = maxW or 360
    maxH = maxH or 200
    local cid, payload, alphaData = parseWebP(data)
    if not payload then return nil end
    local pix, w, h
    if cid == "VP8L" then
        pix, w, h = decodeVP8LPayload(payload)
    elseif cid == "VP8 " then
        local rgb, alpha
        rgb, w, h, alpha = decodeVP8Payload(payload, alphaData)
        if not rgb then return nil end
        pix = {}
        for i = 0, w * h - 1 do
            local o = i * 3
            local a = alpha and alpha[i] or 0xFF
            pix[i] = (a << 24) | (rgb[o] << 16) | (rgb[o + 1] << 8) | rgb[o + 2]
        end
    else
        local anim = WebPDecoder.decodeAnimation(data)
        if not anim or #anim.frames == 0 then return nil end
        pix, w, h = anim.frames[1].pix, anim.width, anim.height
    end
    if not pix then return nil end

    local acc = Scale.newAccum(w, h, maxW, maxH)
    local _, _, targetW, targetH = Scale.boxSizes(w, h, maxW, maxH)
    local grayRow = {}
    for y = 0, h - 1 do
        Tasks.yieldCheck()
        local base = y * w
        for x = 0, w - 1 do
            local argb = pix[base + x]
            local gv = Dither.rgbToGray((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)
            grayRow[x + 1] = composite(gv, (argb >> 24) & 0xFF)
        end
        acc.addRow(grayRow)
    end
    local rows = acc.finish()
    if acc.count == 0 then return nil end
    return Dither.toImage(function(x, y)
        local r = rows[y]
        if not r then return 255 end
        return r[x + 1] or 255
    end, targetW, targetH)
end

function WebPDecoder._testDecodeRaw(data)
    local cid, payload, alphaData = parseWebP(data)
    if payload then
        if cid == "VP8L" then
            return decodeVP8LPayload(payload)
        end
        return decodeVP8Payload(payload, alphaData)
    end
    local anim = WebPDecoder.decodeAnimation(data)
    if anim and #anim.frames > 0 then
        return anim.frames[1].pix, anim.width, anim.height
    end
    return nil
end

function WebPDecoder._testBuildTable(codeLengths, size, rootBits)
    return buildHuffmanTable(codeLengths, size, rootBits)
end
