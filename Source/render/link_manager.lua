-- Hyperlink Focus & Interaction Manager for CometBrowser
import "core/constants"

LinkManager = {}
local gfx = playdate.graphics

LinkManager.links = {}
LinkManager.selectedIndex = nil

function LinkManager.clear()
    LinkManager.links = {}
    LinkManager.selectedIndex = nil
end

function LinkManager.clearSelection()
    LinkManager.selectedIndex = nil
end

function LinkManager.addLinkRect(href, text, rect)
    if not href or href == "" or not rect then return end

    local lastLink = LinkManager.links[#LinkManager.links]
    if lastLink and lastLink.href == href and lastLink.text == text then
        table.insert(lastLink.rects, rect)
        return
    end

    table.insert(LinkManager.links, {
        index = #LinkManager.links + 1,
        href = href,
        text = text or href,
        rects = { rect },
        primaryRect = rect
    })
end

function LinkManager.getCount()
    return #LinkManager.links
end

-- Pick the closest selectable object that is currently visible in the
-- viewport. If nothing is in view, fall back to the closest link on the
-- page (the caller then scrolls it into view). Used for the first D-pad
-- press after scrolling so selection starts where the reader is looking.
local function findInitialSelection(currentScrollY)
    local viewTop = currentScrollY
    local viewBottom = currentScrollY + Constants.CONTENT_HEIGHT
    local viewCenter = viewTop + Constants.CONTENT_HEIGHT / 2

    -- Pass 1: links whose center is inside the viewport
    local bestIndex, bestDist = nil, math.huge
    for i, l in ipairs(LinkManager.links) do
        local cy = l.primaryRect.y + (l.primaryRect.h or 0) / 2
        if cy >= viewTop and cy <= viewBottom then
            local d = math.abs(cy - viewCenter)
            if d < bestDist then
                bestDist = d
                bestIndex = i
            end
        end
    end
    if bestIndex then return bestIndex end

    -- Pass 2: nothing in view, pick the closest link anywhere on the page
    for i, l in ipairs(LinkManager.links) do
        local cy = l.primaryRect.y + (l.primaryRect.h or 0) / 2
        local d = math.abs(cy - viewCenter)
        if d < bestDist then
            bestDist = d
            bestIndex = i
        end
    end
    return bestIndex
end

function LinkManager.getSelectedLink()
    if LinkManager.selectedIndex and LinkManager.selectedIndex >= 1 and LinkManager.selectedIndex <= #LinkManager.links then
        return LinkManager.links[LinkManager.selectedIndex]
    end
    return nil
end

function LinkManager.selectNext(currentScrollY)
    if #LinkManager.links == 0 then
        LinkManager.selectedIndex = nil
        return nil
    end

    if not LinkManager.selectedIndex then
        local idx = findInitialSelection(currentScrollY or 0)
        if idx then
            LinkManager.selectedIndex = idx
            return LinkManager.links[idx]
        end
        LinkManager.selectedIndex = nil
        return nil
    else
        LinkManager.selectedIndex = LinkManager.selectedIndex + 1
        if LinkManager.selectedIndex > #LinkManager.links then
            LinkManager.selectedIndex = 1
        end
    end

    return LinkManager.links[LinkManager.selectedIndex]
end

function LinkManager.selectPrev(currentScrollY)
    if #LinkManager.links == 0 then
        LinkManager.selectedIndex = nil
        return nil
    end

    if not LinkManager.selectedIndex then
        local idx = findInitialSelection(currentScrollY or 0)
        if idx then
            LinkManager.selectedIndex = idx
            return LinkManager.links[idx]
        end
        LinkManager.selectedIndex = nil
        return nil
    else
        LinkManager.selectedIndex = LinkManager.selectedIndex - 1
        if LinkManager.selectedIndex < 1 then
            LinkManager.selectedIndex = #LinkManager.links
        end
    end

    return LinkManager.links[LinkManager.selectedIndex]
end

function LinkManager.drawSelectedHighlight(scrollY)
    local link = LinkManager.getSelectedLink()
    if not link then return end

    gfx.setClipRect(0, Constants.CONTENT_Y, Constants.CONTENT_WIDTH, Constants.CONTENT_HEIGHT)
    
    for _, r in ipairs(link.rects) do
        local drawY = r.y - scrollY
        if drawY + r.h >= Constants.CONTENT_Y and drawY <= Constants.SCREEN_HEIGHT then
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(r.x - 2, drawY - 1, r.w + 4, r.h + 2, 3)
            gfx.fillRect(r.x - 4, drawY + math.floor(r.h / 2) - 2, 2, 5)
        end
    end

    gfx.clearClipRect()
end

function LinkManager.isHighlighted(href, x, y)
    local sel = LinkManager.getSelectedLink()
    if not sel or not href then return false end
    if sel.href == href then
        for _, r in ipairs(sel.rects) do
            if r.x == x and r.y == y then return true end
        end
    end
    return false
end

function LinkManager.addLink(link)
    if not link or not link.href then return end
    LinkManager.addLinkRect(link.href, link.href, {
        x = link.x, y = link.y, w = link.w, h = link.h
    })
end

function LinkManager.getHoveredLink(screenX, pageY)
    -- pageY is mouse Y + scrollY (in document space)
    for _, link in ipairs(LinkManager.links) do
        for _, r in ipairs(link.rects) do
            if screenX >= r.x and screenX <= r.x + (r.w or 60) and
               pageY  >= r.y and pageY  <= r.y + (r.h or 14) then
                return link
            end
        end
    end
    return nil
end

