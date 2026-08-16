-- Shared box-filter downscaler for the image decoders.
--
-- Every raster decoder feeds source rows (grayscale 0..255) into an
-- accumulator via addRow() and receives the downscaled rows from finish().
-- Downscaling happens with an integer box size so no fractional math is
-- needed, and only a single source row + the tiny output grid are held in
-- memory at once (crucial on the Playdate, which has ~16MB of RAM).

if Scale ~= nil then return end

Scale = {}

-- Integer box size such that target ~= src / box, both clamped to maxW/maxH.
-- Returns boxW, boxH, targetW, targetH (target = floor(src / box)).
function Scale.boxSizes(srcW, srcH, maxW, maxH)
    local boxW = math.max(1, math.ceil(srcW / math.max(1, maxW)))
    local boxH = math.max(1, math.ceil(srcH / math.max(1, maxH)))
    local targetW = math.max(1, math.floor(srcW / boxW))
    local targetH = math.max(1, math.floor(srcH / boxH))
    return boxW, boxH, targetW, targetH
end

-- Streaming box-filter accumulator.
--   local acc = Scale.newAccum(srcW, srcH, maxW, maxH)
--   for y = 0, srcH - 1 do acc.addRow(row) end   -- row[1..srcW] gray 0..255
--   local rows, tw, th = acc.finish()            -- rows[oy][1..tw], oy 0..th-1
function Scale.newAccum(srcW, srcH, maxW, maxH)
    local boxW, boxH, targetW, targetH = Scale.boxSizes(srcW, srcH, maxW, maxH)

    local accum   = {}
    local filled  = 0   -- source rows accumulated for the current output row
    local out     = {}
    local oy      = 0
    local count   = 0
    local divisor = boxW * boxH

    local api = {}
    function api.addRow(row)
        if not row then return end
        if boxW == 1 then
            -- Fast path: 1:1 horizontal, just copy/accumulate
            for i = 1, targetW do
                accum[i] = (accum[i] or 0) + (row[i] or 0)
            end
        else
            local x = 1
            for oc = 1, targetW do
                local xEnd = math.min(srcW, x + boxW - 1)
                local s = 0
                for k = x, xEnd do s = s + (row[k] or 0) end
                accum[oc] = (accum[oc] or 0) + s
                x = x + boxW
            end
        end
        filled = filled + 1
        if filled >= boxH then
            local r = {}
            for i = 1, targetW do
                r[i] = math.floor((accum[i] or 0) / divisor + 0.5)
            end
            out[oy] = r
            oy = oy + 1
            count = count + 1
            accum  = {}
            filled = 0
        end
    end

    function api.finish()
        if filled > 0 then
            -- Trailing partial block (image height not divisible by boxH)
            local r = {}
            local d = boxW * filled
            for i = 1, targetW do
                r[i] = math.floor((accum[i] or 0) / d + 0.5)
            end
            out[oy] = r
            count = count + 1
        end
        api.count = count
        return out, targetW, targetH, count
    end

    return api
end
