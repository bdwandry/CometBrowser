-- Pure Lua Fast Deflate/Inflate Decompressor for PNG on Playdate
Inflate = {}

local function createBitStream(str)
    local bs = {
        data = str,
        bytePos = 1,
        bitBuf = 0,
        bitCount = 0,
        len = #str
    }

    function bs:readBits(n)
        while self.bitCount < n do
            if self.bytePos > self.len then return nil end
            local b = string.byte(self.data, self.bytePos)
            self.bytePos = self.bytePos + 1
            self.bitBuf = self.bitBuf | (b << self.bitCount)
            self.bitCount = self.bitCount + 8
        end
        local mask = (1 << n) - 1
        local val = self.bitBuf & mask
        self.bitBuf = self.bitBuf >> n
        self.bitCount = self.bitCount - n
        return val
    end

    function bs:alignByte()
        local drop = self.bitCount & 7
        if drop > 0 then
            self.bitBuf = self.bitBuf >> drop
            self.bitCount = self.bitCount - drop
        end
    end

    return bs
end

-- Build canonical Huffman lookup tables
local function buildHuffmanTable(codeLengths)
    local maxLen = 0
    for _, len in ipairs(codeLengths) do
        if len > maxLen then maxLen = len end
    end
    if maxLen == 0 then return {} end

    local blCount = {}
    for i = 0, maxLen do blCount[i] = 0 end
    for _, len in ipairs(codeLengths) do
        blCount[len] = blCount[len] + 1
    end

    local nextCode = {}
    local code = 0
    blCount[0] = 0
    for i = 1, maxLen do
        code = (code + blCount[i - 1]) << 1
        nextCode[i] = code
    end

    local lut = {}
    for sym, len in ipairs(codeLengths) do
        if len > 0 then
            local c = nextCode[len]
            nextCode[len] = nextCode[len] + 1

            -- Reverse bits for LSB-first bitstream
            local revCode = 0
            for b = 0, len - 1 do
                if (c & (1 << (len - 1 - b))) ~= 0 then
                    revCode = revCode | (1 << b)
                end
            end
            table.insert(lut, { code = revCode, len = len, symbol = sym - 1 })
        end
    end

    table.sort(lut, function(a, b) return a.len < b.len end)
    return lut
end

local function decodeSymbol(bs, huff)
    local curCode = 0
    local curLen = 0
    for _, entry in ipairs(huff) do
        while curLen < entry.len do
            local bit = bs:readBits(1)
            if not bit then return nil end
            curCode = curCode | (bit << curLen)
            curLen = curLen + 1
        end
        if curCode == entry.code and curLen == entry.len then
            return entry.symbol
        end
    end
    return nil
end

-- Fixed Huffman Tables (RFC 1951)
local fixedLitTable = nil
local fixedDistTable = nil

local function getFixedTables()
    if fixedLitTable then return fixedLitTable, fixedDistTable end
    local litLens = {}
    for i = 0, 143 do table.insert(litLens, 8) end
    for i = 144, 255 do table.insert(litLens, 9) end
    for i = 256, 279 do table.insert(litLens, 7) end
    for i = 280, 287 do table.insert(litLens, 8) end
    fixedLitTable = buildHuffmanTable(litLens)

    local distLens = {}
    for i = 0, 31 do table.insert(distLens, 5) end
    fixedDistTable = buildHuffmanTable(distLens)
    return fixedLitTable, fixedDistTable
end

local lengthBase = {
    [257]=3, [258]=4, [259]=5, [260]=6, [261]=7, [262]=8, [263]=9, [264]=10,
    [265]=11, [266]=13, [267]=15, [268]=17, [269]=19, [270]=23, [271]=27, [272]=31,
    [273]=35, [274]=43, [275]=51, [276]=59, [277]=67, [278]=83, [279]=99, [280]=115,
    [281]=131, [282]=163, [283]=195, [284]=227, [285]=258
}
local lengthExtra = {
    [257]=0, [258]=0, [259]=0, [260]=0, [261]=0, [262]=0, [263]=0, [264]=0,
    [265]=1, [266]=1, [267]=1, [268]=1, [269]=2, [270]=2, [271]=2, [272]=2,
    [273]=3, [274]=3, [275]=3, [276]=3, [277]=4, [278]=4, [279]=4, [280]=4,
    [281]=5, [282]=5, [283]=5, [284]=5, [285]=0
}

local distBase = {
    [0]=1, [1]=2, [2]=3, [3]=4, [4]=5, [5]=7, [6]=9, [7]=13,
    [8]=17, [9]=25, [10]=33, [11]=49, [12]=65, [13]=97, [14]=129, [15]=193,
    [16]=257, [17]=385, [18]=513, [19]=769, [20]=1025, [21]=1537, [22]=2049, [23]=3073,
    [24]=4097, [25]=6145, [26]=8193, [27]=12289, [28]=16385, [29]=24577
}
local distExtra = {
    [0]=0, [1]=0, [2]=0, [3]=0, [4]=1, [5]=1, [6]=2, [7]=2,
    [8]=3, [9]=3, [10]=4, [11]=4, [12]=5, [13]=5, [14]=6, [15]=6,
    [16]=7, [17]=7, [18]=8, [19]=8, [20]=9, [21]=9, [22]=10, [23]=10,
    [24]=11, [25]=11, [26]=12, [27]=12, [28]=13, [29]=13
}

local clOrder = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

function Inflate.decompress(data)
    if not data or #data < 2 then return nil end

    -- Skip zlib header (CMF/FLG) if present
    local cmf = string.byte(data, 1)
    local flg = string.byte(data, 2)
    local startPos = 1
    if (cmf & 0x0F) == 8 and ((cmf * 256 + flg) % 31) == 0 then
        startPos = 3 -- Skip 2-byte zlib header
        if (flg & 0x20) ~= 0 then startPos = startPos + 4 end -- Skip preset dictionary
    end

    local rawStream = string.sub(data, startPos)
    local bs = createBitStream(rawStream)
    local output = {}

    local isFinal = 0
    while isFinal == 0 do
        isFinal = bs:readBits(1)
        local btype = bs:readBits(2)
        if not btype then break end

        if btype == 0 then -- Uncompressed block
            bs:alignByte()
            local len = bs:readBits(16)
            local nlen = bs:readBits(16)
            if not len then break end
            for _ = 1, len do
                local b = bs:readBits(8)
                if not b then break end
                table.insert(output, b)
            end

        elseif btype == 1 or btype == 2 then -- Huffman blocks
            local litTable, distTable
            if btype == 1 then
                litTable, distTable = getFixedTables()
            else
                local hlit  = (bs:readBits(5) or 0) + 257
                local hdist = (bs:readBits(5) or 0) + 1
                local hclen = (bs:readBits(4) or 0) + 4

                local codeLens = {}
                for i = 1, 19 do codeLens[i] = 0 end
                for i = 1, hclen do
                    local cl = bs:readBits(3)
                    codeLens[clOrder[i] + 1] = cl or 0
                end
                local clTable = buildHuffmanTable(codeLens)

                -- Read code lengths for literals & distances
                local allLens = {}
                while #allLens < (hlit + hdist) do
                    local sym = decodeSymbol(bs, clTable)
                    if not sym then break end
                    if sym < 16 then
                        table.insert(allLens, sym)
                    elseif sym == 16 then
                        local repeatCount = (bs:readBits(2) or 0) + 3
                        local last = allLens[#allLens] or 0
                        for _ = 1, repeatCount do table.insert(allLens, last) end
                    elseif sym == 17 then
                        local repeatCount = (bs:readBits(3) or 0) + 3
                        for _ = 1, repeatCount do table.insert(allLens, 0) end
                    elseif sym == 18 then
                        local repeatCount = (bs:readBits(7) or 0) + 11
                        for _ = 1, repeatCount do table.insert(allLens, 0) end
                    end
                end

                local litLens = {}
                for i = 1, hlit do table.insert(litLens, allLens[i] or 0) end
                litTable = buildHuffmanTable(litLens)

                local distLens = {}
                for i = hlit + 1, hlit + hdist do table.insert(distLens, allLens[i] or 0) end
                distTable = buildHuffmanTable(distLens)
            end

            -- Decode symbols
            while true do
                local sym = decodeSymbol(bs, litTable)
                if not sym or sym == 256 then break end

                if sym < 256 then
                    table.insert(output, sym)
                else
                    local baseL = lengthBase[sym] or 3
                    local extraLBits = lengthExtra[sym] or 0
                    local extraL = (extraLBits > 0) and (bs:readBits(extraLBits) or 0) or 0
                    local matchLen = baseL + extraL

                    local distSym = decodeSymbol(bs, distTable) or 0
                    local baseD = distBase[distSym] or 1
                    local extraDBits = distExtra[distSym] or 0
                    local extraD = (extraDBits > 0) and (bs:readBits(extraDBits) or 0) or 0
                    local matchDist = baseD + extraD

                    local srcIdx = #output - matchDist + 1
                    for i = 0, matchLen - 1 do
                        local b = output[srcIdx + i] or 0
                        table.insert(output, b)
                    end
                end
            end
        end
    end

    -- Convert integer byte array to string chunks for speed
    local strChunks = {}
    local step = 4096
    for i = 1, #output, step do
        local sub = {}
        for j = i, math.min(#output, i + step - 1) do
            table.insert(sub, string.char(output[j]))
        end
        table.insert(strChunks, table.concat(sub))
    end
    return table.concat(strChunks)
end
