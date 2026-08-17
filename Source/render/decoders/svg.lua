-- Pure Lua On-Device SVG Vector Renderer for Playdate
--
-- Renders a subset of the SVG spec relevant to web icons & simple drawings:
--   rect, circle, ellipse, line, polygon, polyline, path (M/L/H/V/Z/C/Q/S/T/A
--   approximated with line segments), g, defs (skipped), use (best-effort
--   resolve), display:none / visibility:hidden (inherited from group ancestors).
--
-- Colors are 1-bit: anything with a visible stroke or fill draws black; only
-- fill="none" + stroke-less elements are skipped (nothing to draw).
local gfx = playdate.graphics

SVGDecoder = {}

local function getAttrs(tagStr)
    local out = {}
    for k, v in string.gmatch(tagStr, '([%w%:-]+)%s*=%s*"([^"]*)"') do
        out[k] = v
    end
    for k, v in string.gmatch(tagStr, "([%w%:-]+)%s*=%s*'([^']*)'") do
        out[k] = v
    end
    return out
end

local function isHidden(attrs)
    if attrs["display"] == "none" then return true end
    if attrs["visibility"] == "hidden" or attrs["visibility"] == "collapse" then return true end
    return false
end

local function hasInk(attrs)
    local fill = attrs["fill"]
    local stroke = attrs["stroke"]
    if stroke and stroke ~= "none" and stroke ~= "" then return true end
    if fill == "none" then return false end
    return true
end

-- Parse a CSS style="" attribute string into a property map.
local function parseStyle(styleStr)
    if not styleStr or styleStr == "" then return {} end
    local out = {}
    for prop, val in string.gmatch(styleStr, "([^;:]+)%s*:%s*([^;]+)") do
        local k = string.lower(string.match(prop, "^%s*(.-)%s*$") or "")
        local v = string.match(val, "^%s*(.-)%s*$") or ""
        if k ~= "" then out[k] = v end
    end
    return out
end

-- Merge style="" into attrs (style wins over XML attributes).
local function mergeStyle(attrs)
    local style = parseStyle(attrs["style"])
    if next(style) == nil then return attrs end
    local merged = {}
    for k, v in pairs(attrs) do merged[k] = v end
    for k, v in pairs(style) do merged[k] = v end
    return merged
end

-- Proper SVG path number tokenizer.  The regex ([%-%d%.eE]+) merges adjacent
-- numbers (e.g. "0-8.264" → one token), breaking C/Q/S/T commands.  This
-- character-level parser correctly splits them.
local function tokenizePathNumbers(s)
    local nums = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = s:byte(i)
        -- whitespace / comma: skip
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x2C then
            i = i + 1
        else
            local start = i
            -- optional sign
            if c == 0x2B or c == 0x2D then
                i = i + 1
                if i > n then break end
                c = s:byte(i)
            end
            -- integer digits
            local hasDigit = false
            while c >= 0x30 and c <= 0x39 do
                hasDigit = true
                i = i + 1
                if i > n then break end
                c = s:byte(i)
            end
            -- fractional part
            if c == 0x2E then
                if i + 1 <= n and s:byte(i + 1) >= 0x30 and s:byte(i + 1) <= 0x39 then
                    -- dot followed by digit: consume
                    i = i + 1
                    c = s:byte(i)
                    while c >= 0x30 and c <= 0x39 do
                        hasDigit = true
                        i = i + 1
                        if i > n then break end
                        c = s:byte(i)
                    end
                elseif not hasDigit then
                    -- .xxx without integer part
                    i = i + 1
                    if i > n then break end
                    c = s:byte(i)
                    while c >= 0x30 and c <= 0x39 do
                        hasDigit = true
                        i = i + 1
                        if i > n then break end
                        c = s:byte(i)
                    end
                end
                -- else: digit.digit with no trailing digits → end number before dot
            end
            -- exponent
            if (c == 0x65 or c == 0x45) and hasDigit then
                i = i + 1
                if i <= n then
                    c = s:byte(i)
                    if c == 0x2B or c == 0x2D then
                        i = i + 1
                    end
                    while i <= n and s:byte(i) >= 0x30 and s:byte(i) <= 0x39 do
                        i = i + 1
                    end
                end
            end
            if i > start and hasDigit then
                local num = tonumber(s:sub(start, i - 1))
                if num then nums[#nums + 1] = num end
            end
            if i == start then i = start + 1 end -- skip unknown char
        end
    end
    return nums
end

-- Also tokenize polygon/polyline points attributes (same format).
local function tokenizePoints(str)
    return tokenizePathNumbers(str)
end

local function scanTags(body, visit)
    local pos = 1
    while true do
        local s = string.find(body, "<", pos, true)
        if not s then break end
        local e = string.find(body, ">", s, true)
        if not e then break end
        local inside = string.sub(body, s + 1, e - 1)
        pos = e + 1
        local head = string.sub(inside, 1, 3)
        if head == "!--" then
            local ce = string.find(body, "-->", e, true)
            if ce then pos = ce + 3 end
        elseif head == "![" then
            local ce = string.find(body, "]]>", e, true)
            if ce then pos = ce + 3 end
        elseif head ~= "!D" and head ~= "!d" and head ~= "?x" and head ~= "?X" then
            local trimmed = string.gsub(inside, "^%s*(.-)%s*$", "%1")
            if trimmed ~= "" then
                local isClose = (string.sub(trimmed, 1, 1) == "/")
                local tagBody = isClose and string.sub(trimmed, 2) or trimmed
                local isSelfClose = (string.sub(tagBody, -1) == "/")
                if isSelfClose then tagBody = string.sub(tagBody, 1, -2) end
                local tagName = string.match(tagBody, "^([%w%:-]+)")
                if tagName then
                    tagName = string.lower(tagName)
                    local attrStr = string.sub(tagBody, #tagName + 1)
                    visit(tagName, getAttrs(attrStr), isClose, isSelfClose)
                end
            end
        end
    end
end

function SVGDecoder.decode(xmlString, maxW, maxH)
    if not xmlString or not string.match(xmlString, "<svg") then return nil end

    maxW = maxW or 360
    maxH = maxH or 200

    local vbMinX, vbMinY, vbW, vbH = string.match(xmlString,
        "viewBox%s*=%s*[\"']%s*([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
    local wRaw = string.match(xmlString, 'width%s*=%s*["\']([%d%.eE]+)')
    local hRaw = string.match(xmlString, 'height%s*=%s*["\']([%d%.eE]+)')

    local srcW = tonumber(vbW) or tonumber(wRaw) or 100
    local srcH = tonumber(vbH) or tonumber(hRaw) or 100
    local minX = tonumber(vbMinX) or 0
    local minY = tonumber(vbMinY) or 0

    if srcW <= 0 or srcH <= 0 then return nil end

    local scale = math.min(maxW / srcW, maxH / srcH)
    if scale > 2 then scale = 2 end
    local targetW = math.max(20, math.floor(srcW * scale))
    local targetH = math.max(20, math.floor(srcH * scale))

    local img = gfx.image.new(targetW, targetH, gfx.kColorWhite)
    if not img then return nil end

    local function expandUses(src)
        local out, lastPos = {}, 1
        while true do
            local s, e = string.find(src, "<[uU][sS][eE][^>]*/?>", lastPos)
            if not s then
                out[#out + 1] = string.sub(src, lastPos)
                break
            end
            out[#out + 1] = string.sub(src, lastPos, s - 1)
            local a = getAttrs(string.sub(src, s + 4, e - 1))
            local id = string.match(a["href"] or a["xlink:href"] or "", "^#(.+)$")
            if id then
                local ref = nil
                for elTag, elStr in string.gmatch(src, "<([%w%:-]+)([^>]*)>") do
                    local ea = getAttrs(elStr)
                    if ea["id"] == id then
                        ref = "<" .. elTag .. elStr .. ">"
                        break
                    end
                end
                out[#out + 1] = ref or ""
            end
            lastPos = e + 1
        end
        return table.concat(out)
    end
    local body = expandUses(xmlString)

    -- Wrap all drawing in pcall so gfx.popContext is always reached.
    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)

    local ok, drawErr = pcall(function()
        local function tx(x) return math.floor(((tonumber(x) or 0) - minX) * scale) end
        local function ty(y) return math.floor(((tonumber(y) or 0) - minY) * scale) end

        local skipDepth = 0
        local shapeGroupStack = {}
        local drawn = 0
        local curX, curY = 0, 0
        local startX, startY = 0, 0
        local hasPoint = false
        local lastCtrlX, lastCtrlY = 0, 0 -- for S/T smooth curves

        scanTags(body, function(tag, attrs, isClose, isSelfClose)
            if not isClose then
                attrs = mergeStyle(attrs)
                local ownHidden = isHidden(attrs)
                local enteringSkip = (tag == "defs" or ownHidden)
                local container = (tag == "svg" or tag == "g" or tag == "a" or tag == "symbol"
                    or tag == "mask" or tag == "clipPath" or tag == "defs"
                    or tag == "pattern" or tag == "marker" or tag == "switch")
                if container and not isSelfClose then
                    shapeGroupStack[#shapeGroupStack + 1] = skipDepth
                    if enteringSkip then skipDepth = skipDepth + 1 end
                end
                if not enteringSkip and skipDepth == 0 then
                    if tag == "rect" and hasInk(attrs) and attrs["x"] and attrs["y"]
                        and attrs["width"] and attrs["height"] then
                        local x = tx(attrs["x"])
                        local y = ty(attrs["y"])
                        local w = math.max(1, math.floor((tonumber(attrs["width"]) or 1) * scale))
                        local h = math.max(1, math.floor((tonumber(attrs["height"]) or 1) * scale))
                        if attrs["rx"] or attrs["ry"] then
                            gfx.drawRoundRect(x, y, w, h, math.min(4, math.max(1, math.floor((tonumber(attrs["rx"]) or 2) * scale))))
                        else
                            gfx.drawRect(x, y, w, h)
                        end
                        drawn = drawn + 1

                    elseif tag == "circle" and hasInk(attrs) and attrs["cx"] and attrs["cy"] and attrs["r"] then
                        local r = math.max(1, math.floor((tonumber(attrs["r"]) or 1) * scale))
                        gfx.drawCircleAtPoint(tx(attrs["cx"]), ty(attrs["cy"]), r)
                        drawn = drawn + 1

                    elseif tag == "ellipse" and hasInk(attrs) and attrs["cx"] and attrs["cy"]
                        and attrs["rx"] and attrs["ry"] then
                        local ecx, ecy = tx(attrs["cx"]), ty(attrs["cy"])
                        local erx = math.max(1, math.floor((tonumber(attrs["rx"]) or 1) * scale))
                        local ery = math.max(1, math.floor((tonumber(attrs["ry"]) or 1) * scale))
                        local steps = math.max(2, math.min(5, math.floor(math.min(erx, ery) / 2)))
                        for si = 1, steps do
                            local f = 1 - ((si - 1) / steps) * 0.6
                            gfx.drawEllipse(ecx - math.floor(erx * f), ecy - math.floor(ery * f),
                                math.max(2, math.floor(erx * f * 2)), math.max(2, math.floor(ery * f * 2)),
                                0, 360, 1, 0)
                        end
                        drawn = drawn + 1

                    elseif tag == "line" and hasInk(attrs) and attrs["x1"] and attrs["y1"]
                        and attrs["x2"] and attrs["y2"] then
                        gfx.drawLine(tx(attrs["x1"]), ty(attrs["y1"]), tx(attrs["x2"]), ty(attrs["y2"]))
                        drawn = drawn + 1

                    elseif (tag == "polygon" or tag == "polyline") and hasInk(attrs) and attrs["points"] then
                        local pts = tokenizePoints(attrs["points"])
                        for pi = 1, math.max(0, #pts - 3), 2 do
                            gfx.drawLine(tx(pts[pi]), ty(pts[pi + 1]), tx(pts[pi + 2]), ty(pts[pi + 3]))
                        end
                        if tag == "polygon" and #pts >= 4 then
                            gfx.drawLine(tx(pts[#pts - 1]), ty(pts[#pts]), tx(pts[1]), ty(pts[2]))
                        end
                        drawn = drawn + 1

                    elseif tag == "path" and hasInk(attrs) and attrs["d"] then
                        curX, curY = 0, 0
                        startX, startY = 0, 0
                        hasPoint = false
                        lastCtrlX, lastCtrlY = 0, 0
                        for cmd, args in string.gmatch(attrs["d"], "([a-zA-Z])%s*([^a-zA-Z]*)") do
                            local coords = tokenizePathNumbers(args)
                            local isRel = (cmd == string.lower(cmd))
                            local c = string.upper(cmd)
                            local function pt(px, py)
                                px = px or 0
                                py = py or 0
                                if isRel then return curX + px, curY + py else return px, py end
                            end
                            if c == "M" then
                                for i = 1, #coords, 2 do
                                    local nx, ny = pt(coords[i], coords[i + 1])
                                    if i == 1 then
                                        curX, curY = nx, ny
                                        startX, startY = curX, curY
                                        hasPoint = true
                                    else
                                        gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                        curX, curY = nx, ny
                                    end
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            elseif c == "L" then
                                for i = 1, #coords, 2 do
                                    local nx, ny = pt(coords[i], coords[i + 1])
                                    gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                    curX, curY = nx, ny
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            elseif c == "H" then
                                for _, hx in ipairs(coords) do
                                    local nx = isRel and (curX + hx) or hx
                                    gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(curY))
                                    curX = nx
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            elseif c == "V" then
                                for _, vy in ipairs(coords) do
                                    local ny = isRel and (curY + vy) or vy
                                    gfx.drawLine(tx(curX), ty(curY), tx(curX), ty(ny))
                                    curY = ny
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            elseif c == "Z" then
                                if hasPoint then
                                    gfx.drawLine(tx(curX), ty(curY), tx(startX), ty(startY))
                                    curX, curY = startX, startY
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            elseif c == "C" then
                                for i = 1, #coords, 6 do
                                    local x1, y1 = pt(coords[i], coords[i + 1])
                                    local x2, y2 = pt(coords[i + 2], coords[i + 3])
                                    local x3, y3 = pt(coords[i + 4], coords[i + 5])
                                    for t = 1, 8 do
                                        local u = t / 8
                                        local nx = (1 - u) * (1 - u) * (1 - u) * curX + 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u * x3
                                        local ny = (1 - u) * (1 - u) * (1 - u) * curY + 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u * y3
                                        gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                        curX, curY = nx, ny
                                    end
                                    lastCtrlX, lastCtrlY = x2, y2
                                end
                            elseif c == "S" then
                                -- Smooth cubic: reflect previous control point
                                for i = 1, #coords, 4 do
                                    local sx1, sy1 = curX * 2 - lastCtrlX, curY * 2 - lastCtrlY
                                    local x2, y2 = pt(coords[i], coords[i + 1])
                                    local x3, y3 = pt(coords[i + 2], coords[i + 3])
                                    for t = 1, 8 do
                                        local u = t / 8
                                        local nx = (1 - u) * (1 - u) * (1 - u) * curX + 3 * (1 - u) * (1 - u) * u * sx1 + 3 * (1 - u) * u * u * x2 + u * u * u * x3
                                        local ny = (1 - u) * (1 - u) * (1 - u) * curY + 3 * (1 - u) * (1 - u) * u * sy1 + 3 * (1 - u) * u * u * y2 + u * u * u * y3
                                        gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                        curX, curY = nx, ny
                                    end
                                    lastCtrlX, lastCtrlY = x2, y2
                                end
                            elseif c == "Q" then
                                for i = 1, #coords, 4 do
                                    local x1, y1 = pt(coords[i], coords[i + 1])
                                    local x2, y2 = pt(coords[i + 2], coords[i + 3])
                                    for t = 1, 6 do
                                        local u = t / 6
                                        local nx = (1 - u) * (1 - u) * curX + 2 * (1 - u) * u * x1 + u * u * x2
                                        local ny = (1 - u) * (1 - u) * curY + 2 * (1 - u) * u * y1 + u * u * y2
                                        gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                        curX, curY = nx, ny
                                    end
                                    lastCtrlX, lastCtrlY = x1, y1
                                end
                            elseif c == "T" then
                                -- Smooth quadratic: reflect previous control point
                                for i = 1, #coords, 2 do
                                    local tx1, ty1 = curX * 2 - lastCtrlX, curY * 2 - lastCtrlY
                                    local x2, y2 = pt(coords[i], coords[i + 1])
                                    for t = 1, 6 do
                                        local u = t / 6
                                        local nx = (1 - u) * (1 - u) * curX + 2 * (1 - u) * u * tx1 + u * u * x2
                                        local ny = (1 - u) * (1 - u) * curY + 2 * (1 - u) * u * ty1 + u * u * y2
                                        gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                        curX, curY = nx, ny
                                    end
                                    lastCtrlX, lastCtrlY = tx1, ty1
                                end
                            elseif c == "A" then
                                for i = 1, #coords, 7 do
                                    local ex, ey = pt(coords[i + 5] or 0, coords[i + 6] or 0)
                                    gfx.drawLine(tx(curX), ty(curY), tx(ex), ty(ey))
                                    curX, curY = ex, ey
                                end
                                lastCtrlX, lastCtrlY = curX, curY
                            end
                        end
                        drawn = drawn + 1
                    end
                end
            else
                if tag == "svg" or tag == "g" or tag == "a" or tag == "symbol"
                    or tag == "mask" or tag == "clipPath" or tag == "defs"
                    or tag == "pattern" or tag == "marker" or tag == "switch" then
                    if #shapeGroupStack > 0 then
                        skipDepth = table.remove(shapeGroupStack)
                    end
                end
            end
        end)

        return drawn
    end)

    gfx.popContext()

    if not ok then
        return nil
    end
    if (ok and drawErr or 0) == 0 then return nil end
    return img
end
