-- Pure Lua On-Device JPEG Decoder for Playdate
--
-- Baseline (SOF0) is decoded in full (luma-only 8x8 IDCT, chroma coefficients
-- consumed for bitstream sync but not upsampled), streaming block rows through
-- the box downscaler so memory stays bounded for large photos. When the box
-- filter is coarse (4x+ or a large source area) only the DC coefficient is used
-- per block, which is the exact quality needed at that scale and avoids the
-- costly IDCT.
--
-- Progressive (SOF2) images are decoded from their DC scans only (DC scans
-- always precede AC scans), which keeps memory tiny and covers the common case
-- of large progressive photos; smaller progressive images render as coarse
-- block averages. Arithmetic-coded JPEGs (SOF9/10/11) are not supported.
--
-- The decode loop calls Tasks.yieldCheck() between MCU rows so large photos
-- decode cooperatively across frames instead of stalling the run loop.
import "render/decoders/dither"
import "render/decoders/scale"
import "core/tasks"

JPEGDecoder = {}

-- Zigzag ordering: zigzag[zz + 1] = natural (row-major) index, zz = 0..63
local zigzag = {
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
}

-- Fixed-point 1D IDCT basis: idctT[k*8+n] = round(4096 * C(k) * cos((2n+1)k*pi/16))
local idctT = {}
do
    local c0 = 0.707106781186548
    for k = 0, 7 do
        local c = (k == 0) and c0 or 1.0
        for n = 0, 7 do
            idctT[k * 8 + n] = math.floor(4096 * c * math.cos((2 * n + 1) * k * math.pi / 16) + 0.5)
        end
    end
end
local IDCT_SCALE = 4 * 4096 * 4096

local function readU16(str, pos)
    local b1, b2 = string.byte(str, pos, pos + 1)
    if not b1 then return 0 end
    return (b1 << 8) | (b2 or 0)
end

local function clamp255(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return v
end

-- Two-pass separable integer IDCT. block is overwritten with spatial samples.
local function idct2d(block, tmp)
    for r = 0, 7 do
        local off = r * 8
        for n = 0, 7 do
            local s = 0
            for k = 0, 7 do s = s + block[off + k] * idctT[k * 8 + n] end
            tmp[off + n] = s
        end
    end
    for c = 0, 7 do
        for n = 0, 7 do
            local s = 0
            for k = 0, 7 do s = s + tmp[k * 8 + c] * idctT[k * 8 + n] end
            block[n * 8 + c] = s
        end
    end
end

-------------------------------------------------------------------------------
-- Bit reader: MSB-first, JPEG byte stuffing, restart + marker detection
-------------------------------------------------------------------------------
local function newReader(str, pos)
    local self = { str = str, pos = pos or 1, bitBuf = 0, nbits = 0 }

    -- Returns next byte (with stuffing removed) or nil at a real marker.
    -- RST markers (0xD0..0xD7) are returned as-is; the reader tracks no state.
    function self.readByte()
        if self.pos > #str then return nil end
        local b = string.byte(str, self.pos)
        self.pos = self.pos + 1
        if b == 0xFF then
            if self.pos > #str then return nil end
            local n = string.byte(str, self.pos)
            if n == 0x00 then
                self.pos = self.pos + 1
                return 0xFF
            end
            if n >= 0xD0 and n <= 0xD7 then
                self.pos = self.pos + 1
                return n -- restart marker, part of the entropy stream
            end
            self.pos = self.pos - 1 -- rewind so the marker starts at the FF byte
            return nil
        end
        return b
    end

    function self.readBits(n)
        while self.nbits < n do
            local b = self.readByte()
            if b == nil then return nil end
            self.bitBuf = (self.bitBuf << 8) | b
            self.nbits = self.nbits + 8
        end
        local v = (self.bitBuf >> (self.nbits - n)) & ((1 << n) - 1)
        self.nbits = self.nbits - n
        self.bitBuf = self.bitBuf & ((1 << self.nbits) - 1)
        return v
    end

    function self.expectRestart(n)
        self.nbits = 0
        local b = self.readByte()
        if not b then return nil end
        if b >= 0xD0 and b <= 0xD7 and (b - 0xD0) == (n % 8) then return b end
        return nil
    end

    return self
end

-------------------------------------------------------------------------------
-- Canonical MSB-first Huffman tables
-------------------------------------------------------------------------------
local function buildHuff(counts, values)
    local mincode, maxcode, valptr = {}, {}, {}
    local code = 0
    local k = 1
    for l = 1, 16 do
        local c = counts[l] or 0
        if c ~= 0 then
            mincode[l] = code
            maxcode[l] = code + c - 1
            valptr[l] = k
            k = k + c
        else
            mincode[l] = -1
            maxcode[l] = -1
            valptr[l] = k
        end
        code = (code + c) << 1
    end
    return { mincode = mincode, maxcode = maxcode, valptr = valptr, values = values }
end

local function decodeSymbol(reader, huff)
    local code = 0
    for l = 1, 16 do
        local bit = reader.readBits(1)
        if bit == nil then return nil end
        code = (code << 1) | bit
        local mn = huff.mincode[l]
        if mn >= 0 and code >= mn and code <= huff.maxcode[l] then
            return huff.values[huff.valptr[l] + code - mn]
        end
    end
    return nil
end

local function extend(val, s)
    if s == 0 then return 0 end
    if val < (1 << (s - 1)) then return val - (1 << s) + 1 end
    return val
end

-- Decode DC difference (returns signed diff or nil at end of scan)
local function decodeDC(reader, tbl)
    local s = decodeSymbol(reader, tbl)
    if s == nil then return nil end
    if s == 0 then return 0 end
    local v = reader.readBits(s)
    if v == nil then return nil end
    return extend(v, s)
end

-- Decode all 63 AC coefficients into block (natural order, dequantized).
-- Returns false on end-of-scan (marker), true otherwise.
local function decodeAC(reader, tbl, block, qt)
    Tasks.yieldCheck()
    local k = 1 -- zigzag position
    while k <= 63 do
        local s = decodeSymbol(reader, tbl)
        if s == nil then return false end
        local r = s >> 4
        local cs = s & 15
        if cs == 0 then
            if r == 15 then
                k = k + 16
            else
                return true -- EOB
            end
        else
            k = k + r
            if k > 63 then return true end
            local v = reader.readBits(cs)
            if v == nil then return false end
            block[zigzag[k + 1]] = extend(v, cs) * qt[k + 1]
            k = k + 1
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- Baseline scan decode (streaming, block rows -> downscaler)
-------------------------------------------------------------------------------
local function decodeBaseline(data, pos, frame, scan, dcTables, acTables, qt, restartInterval, maxW, maxH)
    local width, height = frame.width, frame.height
    local comps = frame.comps
    local ns = #scan.comps

    -- Sampling factors for this scan
    local sMaxH, sMaxV = 1, 1
    for i = 1, ns do
        local fc = comps[scan.comps[i]]
        if fc.h > sMaxH then sMaxH = fc.h end
        if fc.v > sMaxV then sMaxV = fc.v end
    end
    if ns == 1 then sMaxH, sMaxV = 1, 1 end -- non-interleaved

    local mcuCols = math.max(1, math.ceil(width / (sMaxH * 8)))
    local mcuRows = math.max(1, math.ceil(height / (sMaxV * 8)))

    local reader = newReader(data, pos)
    local acc = Scale.newAccum(width, height, maxW, maxH)
    local rowBuf = {}
    local block = {}
    local tmp = {}
    local dcPred = {}
    for i = 1, ns do dcPred[i] = 0 end

    local boxW, boxH = Scale.boxSizes(width, height, maxW, maxH)
    local dcOnly = (boxW >= 4) or (boxH >= 4) or (width * height > 200000)

    local mcuIndex = 0
    local ended = false

    for mcuY = 0, mcuRows - 1 do
        Tasks.yieldCheck()
        for mcuX = 0, mcuCols - 1 do
            if restartInterval > 0 and mcuIndex > 0 and (mcuIndex % restartInterval) == 0 then
                if not reader.expectRestart(mcuIndex) then
                    ended = true
                    break
                end
                for i = 1, ns do dcPred[i] = 0 end
            end
            if ended then break end

            for ci = 1, ns do
                local c = scan.comps[ci]
                local fc = comps[c]
                local dcTbl = dcTables[scan.dcTbl[ci]]
                local acTbl = acTables[scan.acTbl[ci]]
                local qtz = qt[fc.qt]
                for bj = 0, fc.v - 1 do
                    for bi = 0, fc.h - 1 do
                        local diff = decodeDC(reader, dcTbl)
                        if diff == nil then
                            ended = true
                            break
                        end
                        dcPred[ci] = dcPred[ci] + diff
                        local dc = dcPred[ci]
                        local px = mcuX * sMaxH * 8 + bi * 8
                        local py = mcuY * sMaxV * 8 + bj * 8

                        if ci == 1 then
                            -- Luma (Y): fill row buffer
                            if dcOnly then
                                -- consume AC symbols for stream sync, then use DC only
                                if not decodeAC(reader, acTbl, block, qtz) then
                                    ended = true
                                    break
                                end
                                local g = clamp255(math.floor(dc * qtz[1] / 8 + 0.5) + 128)
                                for ri = 0, 7 do
                                    local rb = rowBuf[py + ri]
                                    if not rb then rb = {} rowBuf[py + ri] = rb end
                                    for cx = 0, 7 do rb[px + cx + 1] = g end
                                end
                            else
                                block[0] = dc * qtz[1]
                                for i = 1, 63 do block[i] = 0 end
                                if not decodeAC(reader, acTbl, block, qtz) then
                                    ended = true
                                    break
                                end
                                idct2d(block, tmp)
                                for ri = 0, 7 do
                                    local rb = rowBuf[py + ri]
                                    if not rb then rb = {} rowBuf[py + ri] = rb end
                                    for cx = 0, 7 do
                                        rb[px + cx + 1] = clamp255(math.floor(block[ri * 8 + cx] / IDCT_SCALE + 0.5) + 128)
                                    end
                                end
                            end
                        else
                            -- Chroma: consume bits for sync, discard
                            block[0] = 0
                            if not decodeAC(reader, acTbl, block, qtz) then
                                ended = true
                                break
                            end
                        end
                    end
                    if ended then break end
                end
                if ended then break end
            end

            mcuIndex = mcuIndex + 1
            if ended then break end
        end
        -- Feed completed block rows to the downscaler (even on end-of-scan
        -- marker so the final MCU row's Y rows are not lost)
        local base = mcuY * sMaxV * 8
        for ri = 0, sMaxV * 8 - 1 do
            local y = base + ri
            if y < height then
                acc.addRow(rowBuf[y])
            end
        end
        if ended then break end
    end

    return { acc = acc, ended = ended, pos = reader.pos }
end
-------------------------------------------------------------------------------
-- Progressive: decode DC scans only (memory-safe, block averages)
-------------------------------------------------------------------------------
-- Returns true on success, false on truncation.
local function decodeProgressiveDC(data, pos, frame, scan, dcTables, qt, restartInterval, state)
    local width, height = frame.width, frame.height
    local comps = frame.comps
    local ns = #scan.comps

    -- Frame-level sampling factors (defines every component's block grid)
    local maxHf, maxVf = 1, 1
    for i = 1, #comps do
        if comps[i].h > maxHf then maxHf = comps[i].h end
        if comps[i].v > maxVf then maxVf = comps[i].v end
    end
    local mcuColsF = math.max(1, math.ceil(width / (maxHf * 8)))
    local mcuRowsF = math.max(1, math.ceil(height / (maxVf * 8)))

    -- For a non-interleaved scan each block is its own MCU.
    local mcuCols, mcuRows
    if ns == 1 then
        local fc = comps[scan.comps[1]]
        mcuCols = mcuColsF * fc.h
        mcuRows = mcuRowsF * fc.v
    else
        mcuCols, mcuRows = mcuColsF, mcuRowsF
    end

    local reader = newReader(data, pos)
    local refinement = (scan.ah ~= 0)
    local mcuIndex = 0
    local ended = false

    for mcuY = 0, mcuRows - 1 do
        Tasks.yieldCheck()
        for mcuX = 0, mcuCols - 1 do
            if restartInterval > 0 and mcuIndex > 0 and (mcuIndex % restartInterval) == 0 then
                if not reader.expectRestart(mcuIndex) then
                    ended = true
                    break
                end
                for i = 1, ns do state.dcPred[scan.comps[i]] = 0 end
            end
            if ended then break end

            for ci = 1, ns do
                local c = scan.comps[ci]
                local fc = comps[c]
                if not state.blockDC[c] then state.blockDC[c] = {} end
                local dcTbl = dcTables[scan.dcTbl[ci]]
                local blocks
                if ns == 1 then
                    blocks = 1
                else
                    blocks = fc.h * fc.v
                end
                for bi = 0, blocks - 1 do
                    Tasks.yieldCheck()
                    local idx = state.blkIdx[c]
                    state.blkIdx[c] = idx + 1
                    if refinement then
                        local bit = reader.readBits(1)
                        if bit == nil then
                            ended = true
                            break
                        end
                        local dc = state.blockDC[c][idx] or 0
                        if bit ~= 0 then
                            state.blockDC[c][idx] = dc + (1 << scan.al)
                        else
                            state.blockDC[c][idx] = dc - (1 << scan.al)
                        end
                    else
                        local diff = decodeDC(reader, dcTbl)
                        if diff == nil then
                            ended = true
                            break
                        end
                        state.dcPred[c] = (state.dcPred[c] or 0) + diff
                        state.blockDC[c][idx] = state.dcPred[c] << scan.al
                    end
                end
                if ended then break end
            end
            mcuIndex = mcuIndex + 1
            if ended then break end
        end
        if ended then break end
    end

    return not ended, reader.pos
end

-- Turn stored DC coefficients into a downscaled image.
local function renderProgressiveDC(frame, state, maxW, maxH, qt)
    local width, height = frame.width, frame.height
    local comps = frame.comps
    local yc = 1 -- luma is component index 1

    local sMaxH, sMaxV = 1, 1
    for i = 1, #comps do
        if comps[i].h > sMaxH then sMaxH = comps[i].h end
        if comps[i].v > sMaxV then sMaxV = comps[i].v end
    end
    local mcuCols = math.max(1, math.ceil(width / (sMaxH * 8)))
    local mcuRows = math.max(1, math.ceil(height / (sMaxV * 8)))

    local acc = Scale.newAccum(width, height, maxW, maxH)
    local rowBuf = {}
    local yfc = comps[yc]
    local qtz = qt[yfc.qt]
    local qdc = qtz and qtz[1] or 1
    local idx = 0

    for mcuY = 0, mcuRows - 1 do
        Tasks.yieldCheck()
        for mcuX = 0, mcuCols - 1 do
            for bj = 0, yfc.v - 1 do
                for bi = 0, yfc.h - 1 do
                    Tasks.yieldCheck()
                    local dc = state.blockDC[yc][idx] or 0
                    idx = idx + 1
                    local px = mcuX * sMaxH * 8 + bi * 8
                    local py = mcuY * sMaxV * 8 + bj * 8
                    local g = clamp255(math.floor(dc * qdc / 8 + 0.5) + 128)
                    for ri = 0, 7 do
                        local rb = rowBuf[py + ri]
                        if not rb then rb = {} rowBuf[py + ri] = rb end
                        for cx = 0, 7 do rb[px + cx + 1] = g end
                    end
                end
            end
        end
        local base = mcuY * sMaxV * 8
        for ri = 0, sMaxV * 8 - 1 do
            local y = base + ri
            if y < height then acc.addRow(rowBuf[y]) end
        end
    end

    return acc
end

-------------------------------------------------------------------------------
-- Main decoder
-------------------------------------------------------------------------------
function JPEGDecoder.decode(data, maxW, maxH)
    if not data or #data < 4 then return nil end
    if string.byte(data, 1) ~= 0xFF or string.byte(data, 2) ~= 0xD8 then return nil end

    maxW = maxW or 360
    maxH = maxH or 200

    local pos = 3
    local frame
    local qt = {}
    local dcTables = {}
    local acTables = {}
    local restartInterval = 0
    local progressive = false
    local state = { dcPred = {}, blockDC = {}, blkIdx = {} }
    local acc

    local function parseHuffSegment(p)
        local segEnd = p + readU16(data, p)
        p = p + 2
        while p < segEnd do
            local tc = string.byte(data, p)
            p = p + 1
            local counts = {}
            local total = 0
            for i = 1, 16 do
                local c = string.byte(data, p) or 0
                p = p + 1
                counts[i] = c
                total = total + c
            end
            local values = {}
            for i = 1, total do
                values[i] = string.byte(data, p) or 0
                p = p + 1
            end
            local t = buildHuff(counts, values)
            local cls = (tc >> 4) & 1
            local id = tc & 0x0F
            if cls == 0 then dcTables[id] = t else acTables[id] = t end
        end
        return segEnd
    end

    local function parseQTSegment(p)
        local segEnd = p + readU16(data, p)
        p = p + 2
        while p < segEnd do
            local pq = string.byte(data, p)
            p = p + 1
            local id = pq & 0x0F
            local t = {}
            for i = 0, 63 do
                if (pq >> 4) == 0 then
                    t[i + 1] = string.byte(data, p) or 1
                    p = p + 1
                else
                    t[i + 1] = readU16(data, p)
                    p = p + 2
                end
            end
            qt[id] = t
        end
        return segEnd
    end

    while pos <= #data - 1 do
        if string.byte(data, pos) ~= 0xFF then break end
        local m = string.byte(data, pos + 1)
        if not m then break end
        pos = pos + 2

        if m == 0xD9 then break -- EOI

        elseif m == 0xDB then -- DQT
            pos = parseQTSegment(pos)

        elseif m == 0xC4 then -- DHT
            pos = parseHuffSegment(pos)

        elseif m == 0xC0 or m == 0xC2 then -- SOF0 / SOF2
            local p = pos + 2 -- skip length
            local precision = string.byte(data, p) or 8
            local height = readU16(data, p + 1)
            local width  = readU16(data, p + 3)
            local ncomp  = string.byte(data, p + 5) or 0
            local comps = {}
            p = p + 6
            for i = 1, ncomp do
                local id = string.byte(data, p)
                local samp = string.byte(data, p + 1) or 0x11
                local qtid = string.byte(data, p + 2) or 0
                comps[i] = {
                    id = id,
                    h = samp >> 4,
                    v = samp & 0x0F,
                    qt = qtid,
                }
                p = p + 3
            end
            frame = { width = width, height = height, precision = precision, comps = comps }
            progressive = (m == 0xC2)
            for i = 1, #comps do state.blkIdx[i] = 0 end
            pos = pos + readU16(data, pos)

        elseif m == 0xDD then -- DRI
            restartInterval = readU16(data, pos + 2)
            pos = pos + readU16(data, pos)

        elseif m == 0xDA then -- SOS
            if not frame then break end
            local segLen = readU16(data, pos)
            local ns = string.byte(data, pos + 2) or 0
            local scanComps, dcTbl, acTbl = {}, {}, {}
            local p = pos + 3
            for i = 1, ns do
                local cid = string.byte(data, p)
                local tbls = string.byte(data, p + 1) or 0
                local ci = nil
                for j = 1, #frame.comps do
                    if frame.comps[j].id == cid then ci = j break end
                end
                ci = ci or i
                scanComps[i] = ci
                dcTbl[i] = tbls >> 4
                acTbl[i] = tbls & 0x0F
                p = p + 2
            end
            local ss = string.byte(data, p) or 0
            local se = string.byte(data, p + 1) or 63
            local ahal = string.byte(data, p + 2) or 0
            local scan = {
                comps = scanComps,
                dcTbl = dcTbl,
                acTbl = acTbl,
                ss = ss,
                se = se,
                ah = ahal >> 4,
                al = ahal & 0x0F,
            }

            -- Entropy data begins here
            local entropyPos = pos + segLen

            if progressive then
                if scan.ss == 0 and scan.se == 0 then
                    -- DC scan: decode and store
                    local ok, nextPos = decodeProgressiveDC(data, entropyPos, frame, scan, dcTables, qt, restartInterval, state)
                    pos = nextPos
                    if not ok then
                        break -- truncated
                    end
                else
                    -- AC scan: we have all DCs, stop here
                    if acc == nil then
                        acc = renderProgressiveDC(frame, state, maxW, maxH, qt)
                    end
                    break
                end
            else
                local res = decodeBaseline(data, entropyPos, frame, scan, dcTables, acTables, qt, restartInterval, maxW, maxH)
                acc = res.acc
                pos = res.pos
                if res.ended then break end
            end

        else
            -- Other segment: skip by length
            local len = readU16(data, pos)
            pos = pos + len
        end
    end

    if acc == nil and frame then
        -- Progressive with no AC scans reached yet: render DCs
        acc = renderProgressiveDC(frame, state, maxW, maxH, qt)
    end
    if not acc or acc.count == 0 then return nil end

    local rows, targetW, targetH = acc.finish()
    return Dither.toImage(function(x, y)
        local r = rows[y]
        if not r then return 255 end
        return r[x + 1] or 255
    end, targetW, targetH)
end
