-- Pure Lua On-Device SVG Vector Renderer for Playdate
local gfx = playdate.graphics

SVGDecoder = {}

function SVGDecoder.decode(xmlString)
    if not xmlString or not string.match(xmlString, "<svg") then return nil end

    -- Extract viewBox: minX minY width height
    local vbMinX, vbMinY, vbW, vbH = string.match(xmlString, "viewBox%s*=%s*[\"']%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
    local wAttr = string.match(xmlString, 'width%s*=%s*["\'](%d+)')
    local hAttr = string.match(xmlString, 'height%s*=%s*["\'](%d+)')

    local srcW = tonumber(vbW) or tonumber(wAttr) or 100
    local srcH = tonumber(vbH) or tonumber(hAttr) or 100
    local minX = tonumber(vbMinX) or 0
    local minY = tonumber(vbMinY) or 0

    if srcW <= 0 or srcH <= 0 then return nil end

    -- Scale to fit Playdate screen bounds (max 360x160)
    local scale = math.min(320 / srcW, 140 / srcH)
    if scale > 2 then scale = 2 end
    local targetW = math.max(20, math.floor(srcW * scale))
    local targetH = math.max(20, math.floor(srcH * scale))

    local img = gfx.image.new(targetW, targetH, gfx.kColorWhite)
    if not img then return nil end

    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)

    local function tx(x) return math.floor(((tonumber(x) or 0) - minX) * scale) end
    local function ty(y) return math.floor(((tonumber(y) or 0) - minY) * scale) end

    -- 1. Parse <rect>
    for rx, ry, rw, rh in string.gmatch(xmlString, "<rect[^>]*x%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*y%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*width%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*height%s*=%s*[\"']([%-%d%.]+)[\"']") do
        local x = tx(rx)
        local y = ty(ry)
        local w = math.max(1, math.floor((tonumber(rw) or 1) * scale))
        local h = math.max(1, math.floor((tonumber(rh) or 1) * scale))
        gfx.drawRect(x, y, w, h)
    end

    -- 2. Parse <circle>
    for cx, cy, cr in string.gmatch(xmlString, "<circle[^>]*cx%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*cy%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*r%s*=%s*[\"']([%-%d%.]+)[\"']") do
        local x = tx(cx)
        local y = ty(cy)
        local r = math.max(1, math.floor((tonumber(cr) or 1) * scale))
        gfx.drawCircleAtPoint(x, y, r)
    end

    -- 3. Parse <line>
    for lx1, ly1, lx2, ly2 in string.gmatch(xmlString, "<line[^>]*x1%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*y1%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*x2%s*=%s*[\"']([%-%d%.]+)[\"'][^>]*y2%s*=%s*[\"']([%-%d%.]+)[\"']") do
        gfx.drawLine(tx(lx1), ty(ly1), tx(lx2), ty(ly2))
    end

    -- 4. Parse <polygon> / <polyline>
    for pts in string.gmatch(xmlString, "<poly[gonline]+[^>]*points%s*=%s*[\"']([^\"']+)[\"']") do
        local polyCoords = {}
        for num in string.gmatch(pts, "([%-%d%.]+)") do
            table.insert(polyCoords, tonumber(num) or 0)
        end
        for i = 1, #polyCoords - 3, 2 do
            gfx.drawLine(tx(polyCoords[i]), ty(polyCoords[i+1]), tx(polyCoords[i+2]), ty(polyCoords[i+3]))
        end
    end

    -- 5. Parse <path> basic commands (M, L, H, V, Z)
    for d in string.gmatch(xmlString, "<path[^>]*d%s*=%s*[\"']([^\"']+)[\"']") do
        local curX, curY = 0, 0
        local startX, startY = 0, 0

        for cmd, args in string.gmatch(d, "([a-zA-Z])%s*([^a-zA-Z]*)") do
            local coords = {}
            for num in string.gmatch(args, "([%-%d%.]+)") do
                table.insert(coords, tonumber(num) or 0)
            end

            local isRel = (cmd == string.lower(cmd))
            local c = string.upper(cmd)

            if c == "M" then
                if #coords >= 2 then
                    curX = isRel and (curX + coords[1]) or coords[1]
                    curY = isRel and (curY + coords[2]) or coords[2]
                    startX, startY = curX, curY
                    for i = 3, #coords, 2 do
                        local nextX = isRel and (curX + coords[i]) or coords[i]
                        local nextY = isRel and (curY + coords[i+1]) or coords[i+1]
                        gfx.drawLine(tx(curX), ty(curY), tx(nextX), ty(nextY))
                        curX, curY = nextX, nextY
                    end
                end
            elseif c == "L" then
                for i = 1, #coords, 2 do
                    local nextX = isRel and (curX + coords[i]) or coords[i]
                    local nextY = isRel and (curY + coords[i+1]) or coords[i+1]
                    gfx.drawLine(tx(curX), ty(curY), tx(nextX), ty(nextY))
                    curX, curY = nextX, nextY
                end
            elseif c == "H" then
                for _, hx in ipairs(coords) do
                    local nextX = isRel and (curX + hx) or hx
                    gfx.drawLine(tx(curX), ty(curY), tx(nextX), ty(curY))
                    curX = nextX
                end
            elseif c == "V" then
                for _, vy in ipairs(coords) do
                    local nextY = isRel and (curY + vy) or vy
                    gfx.drawLine(tx(curX), ty(curY), tx(curX), ty(nextY))
                    curY = nextY
                end
            elseif c == "Z" then
                gfx.drawLine(tx(curX), ty(curY), tx(startX), ty(startY))
                curX, curY = startX, startY
            end
        end
    end

    gfx.popContext()
    return img
end
