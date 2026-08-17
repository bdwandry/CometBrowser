-- Pure Lua On-Device SVG Vector Renderer for Playdate
--
-- Renders a subset of the SVG spec relevant to web icons & simple drawings:
--   rect, circle, ellipse, line, polygon, polyline, path (M/L/H/V/Z plus
--   C/Q/S/T/A approximated with line segments), g, defs (skipped), use
--   (best-effort resolve), display:none / visibility:hidden (inherited from
--   group ancestors).
--
-- Colors are 1-bit: anything with a visible stroke or fill draws black; only
-- fill="none" + stroke-less elements are skipped (nothing to draw).
local gfx = playdate.graphics

SVGDecoder = {}

-- Extract attributes from an element tag string into a map (order-independent).
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

-- Does this element draw anything? fill="none" AND no stroke => invisible.
local function hasInk(attrs)
    local fill = attrs["fill"]
    local stroke = attrs["stroke"]
    if stroke and stroke ~= "none" and stroke ~= "" then return true end
    if fill == "none" then return false end
    return true
end

-- Sequential tag scanner. Calls visit(tagName, attrs, isClose, isSelfClose)
-- for every tag in the document, skipping comments.
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

    -- Extract viewBox: minX minY width height
    local vbMinX, vbMinY, vbW, vbH = string.match(xmlString, "viewBox%s*=%s*[\"']%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
    local wRaw = string.match(xmlString, 'width%s*=%s*["\']([%d%.]+)')
    local hRaw = string.match(xmlString, 'height%s*=%s*["\']([%d%.]+)')

    local srcW = tonumber(vbW) or tonumber(wRaw) or 100
    local srcH = tonumber(vbH) or tonumber(hRaw) or 100
    local minX = tonumber(vbMinX) or 0
    local minY = tonumber(vbMinY) or 0

    if srcW <= 0 or srcH <= 0 then return nil end

    -- Scale to fit caller-specified bounds
    local scale = math.min(maxW / srcW, maxH / srcH)
    if scale > 2 then scale = 2 end
    local targetW = math.max(20, math.floor(srcW * scale))
    local targetH = math.max(20, math.floor(srcH * scale))

    local img = gfx.image.new(targetW, targetH, gfx.kColorWhite)
    if not img then return nil end

    -- Resolve <use href="#id">: inline the referenced element markup in place.
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

    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)

    local function tx(x) return math.floor(((tonumber(x) or 0) - minX) * scale) end
    local function ty(y) return math.floor(((tonumber(y) or 0) - minY) * scale) end

    -- Sequential walk with an inherited-visibility stack: shapes inside a
    -- display:none / visibility:hidden group (or <defs>) are not rendered.
    local skipDepth = 0
    local shapeGroupStack = {}
    local drawn = 0

    scanTags(body, function(tag, attrs, isClose, isSelfClose)
        if not isClose then
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
                -- ── Shape rendering ──────────────────────────────────────
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
                    local cx, cy = tx(attrs["cx"]), ty(attrs["cy"])
                    local rx = math.max(1, math.floor((tonumber(attrs["rx"]) or 1) * scale))
                    local ry = math.max(1, math.floor((tonumber(attrs["ry"]) or 1) * scale))
                    local steps = math.max(2, math.min(5, math.floor(math.min(rx, ry) / 2)))
                    for s = 1, steps do
                        local f = 1 - ((s - 1) / steps) * 0.6
                        gfx.drawEllipse(cx - math.floor(rx * f), cy - math.floor(ry * f),
                            math.max(2, math.floor(rx * f * 2)), math.max(2, math.floor(ry * f * 2)),
                            0, 360, 1, 0)
                    end
                    drawn = drawn + 1

                elseif tag == "line" and hasInk(attrs) and attrs["x1"] and attrs["y1"]
                    and attrs["x2"] and attrs["y2"] then
                    gfx.drawLine(tx(attrs["x1"]), ty(attrs["y1"]), tx(attrs["x2"]), ty(attrs["y2"]))
                    drawn = drawn + 1

                elseif (tag == "polygon" or tag == "polyline") and hasInk(attrs) and attrs["points"] then
                    local pts = {}
                    for num in string.gmatch(attrs["points"], "([%-%d%.eE]+)") do
                        pts[#pts + 1] = tonumber(num) or 0
                    end
                    for i = 1, math.max(0, #pts - 3), 2 do
                        gfx.drawLine(tx(pts[i]), ty(pts[i + 1]), tx(pts[i + 2]), ty(pts[i + 3]))
                    end
                    if tag == "polygon" and #pts >= 4 then
                        gfx.drawLine(tx(pts[#pts - 1]), ty(pts[#pts]), tx(pts[1]), ty(pts[2]))
                    end
                    drawn = drawn + 1

                elseif tag == "path" and hasInk(attrs) and attrs["d"] then
                    local curX, curY = 0, 0
                    local startX, startY = 0, 0
                    local hasPoint = false
                    for cmd, args in string.gmatch(attrs["d"], "([a-zA-Z])%s*([^a-zA-Z]*)") do
                        local coords = {}
                        for num in string.gmatch(args, "([%-%d%.eE]+)") do
                            coords[#coords + 1] = tonumber(num) or 0
                        end
                        local isRel = (cmd == string.lower(cmd))
                        local c = string.upper(cmd)
                        local function pt(px, py)
                            if isRel then return curX + px, curY + py else return px, py end
                        end
                        if c == "M" then
                            if #coords >= 2 then
                                curX, curY = pt(coords[1], coords[2])
                                startX, startY = curX, curY
                                hasPoint = true
                                for i = 3, #coords, 2 do
                                    local nx, ny = pt(coords[i], coords[i + 1])
                                    gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                    curX, curY = nx, ny
                                end
                            end
                        elseif c == "L" then
                            for i = 1, #coords, 2 do
                                local nx, ny = pt(coords[i], coords[i + 1])
                                gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(ny))
                                curX, curY = nx, ny
                            end
                        elseif c == "H" then
                            for _, hx in ipairs(coords) do
                                local nx = isRel and (curX + hx) or hx
                                gfx.drawLine(tx(curX), ty(curY), tx(nx), ty(curY))
                                curX = nx
                            end
                        elseif c == "V" then
                            for _, vy in ipairs(coords) do
                                local ny = isRel and (curY + vy) or vy
                                gfx.drawLine(tx(curX), ty(curY), tx(curX), ty(ny))
                                curY = ny
                            end
                        elseif c == "Z" then
                            if hasPoint then
                                gfx.drawLine(tx(curX), ty(curY), tx(startX), ty(startY))
                                curX, curY = startX, startY
                            end
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
                            end
                        elseif c == "A" then
                            -- Approximate arcs with straight chords; fine at icon size.
                            for i = 1, #coords, 7 do
                                local ex, ey = pt(coords[i + 5] or 0, coords[i + 6] or 0)
                                gfx.drawLine(tx(curX), ty(curY), tx(ex), ty(ey))
                                curX, curY = ex, ey
                            end
                        end
                    end
                    drawn = drawn + 1
                end
            end
        else
            -- Closing tag: pop skip state for containers.
            if tag == "svg" or tag == "g" or tag == "a" or tag == "symbol"
                or tag == "mask" or tag == "clipPath" or tag == "defs"
                or tag == "pattern" or tag == "marker" or tag == "switch" then
                if #shapeGroupStack > 0 then
                    skipDepth = table.remove(shapeGroupStack)
                end
            end
        end
    end)

    gfx.popContext()
    if drawn == 0 then return nil end
    return img
end
