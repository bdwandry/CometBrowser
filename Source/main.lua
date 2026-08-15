-- CometBrowser Main Application Loop (100% Pure On-Device)
import "CoreLibs/timer"
import "CoreLibs/graphics"
import "CoreLibs/keyboard"
import "core/constants"
import "core/url"
import "core/storage"
import "core/http_client"
import "core/logger"
import "html/document"
import "render/style"
import "render/layout"
import "render/link_manager"
import "render/image_decoder"
import "ui/chrome"
import "ui/address_bar"
import "ui/home_page"
import "ui/error_page"
import "ui/bookmarks_page"
import "ui/history_page"
import "ui/hud"

local gfx = playdate.graphics

-- ── Forward Declarations ──────────────────────────────────────────────────────
local navigateTo
local executeNavigation
local updateSystemMenu

-- ── Browser State ─────────────────────────────────────────────────────────────
local currentState       = Constants.STATE_HOME
local currentUrlObj      = nil
local currentDoc         = nil
local pageTitle          = "CometBrowser"
local currentBrowseMode  = Constants.MODE_READER

-- Scroll physics
local scrollY            = 0
local targetScrollY      = 0
local crankVelocity      = 0

-- Progress tracking
local progressCurrent    = 0
local progressTotal      = 0

-- History stack
local navHistory         = {}
local historyIndex       = 0
local MAX_HISTORY        = 30

-- Pending navigation
local pendingNavUrl      = nil

-- Mouse Cursor State
local mouseX             = 200
local mouseY             = 120
local mouseSpeed         = 4

-- Form input state
local activeInputField   = nil
local keyboardOpen       = false
local addressBarKeyboardArmed = false

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function pushHistory(urlString)
    -- If we navigate somewhere new, clear future history
    if historyIndex < #navHistory then
        local newHist = {}
        for i=1, historyIndex do table.insert(newHist, navHistory[i]) end
        navHistory = newHist
    end

    if #navHistory > 0 and navHistory[#navHistory] == urlString then return end
    table.insert(navHistory, urlString)
    historyIndex = #navHistory

    if #navHistory > MAX_HISTORY then
        table.remove(navHistory, 1)
        historyIndex = historyIndex - 1
    end
end

local function goBack()
    if historyIndex > 1 then
        historyIndex = historyIndex - 1
        return navHistory[historyIndex]
    end
    return nil
end

local function goForward()
    if historyIndex < #navHistory then
        historyIndex = historyIndex + 1
        return navHistory[historyIndex]
    end
    return nil
end

local function openKeyboardForInput(inputBlock)
    if not inputBlock then return end
    activeInputField = inputBlock
    keyboardOpen = true
    playdate.keyboard.show(inputBlock.value or "")

    playdate.keyboard.keyboardDidHideCallback = function()
        keyboardOpen = false
        local entered = playdate.keyboard.text or ""
        if activeInputField then
            activeInputField.value = entered
        end
        activeInputField = nil
        playdate.keyboard.keyboardDidHideCallback = nil
    end
end

local function submitForm(formAction, inputBlock)
    if not formAction or formAction == "" or formAction == "#" then return end
    local pairs = {}
    for _, item in ipairs(Layout.renderItems or {}) do
        if item.type == "input_field" and item.formAction == formAction then
            if item.name and item.name ~= "" then
                table.insert(pairs, URL.encode(item.name) .. "=" .. URL.encode(item.value or ""))
            end
        end
    end
    if #pairs == 0 and inputBlock then
        table.insert(pairs, URL.encode(inputBlock.name or "q") .. "=" .. URL.encode(inputBlock.value or ""))
    end
    local query = table.concat(pairs, "&")
    local sep = string.find(formAction, "?") and "&" or "?"
    local target = formAction .. (query ~= "" and (sep .. query) or "")
    navigateTo(target)
end

local function getActiveTotalHeight()
    return Layout.totalHeight
end

-- ── System Menu ───────────────────────────────────────────────────────────────
updateSystemMenu = function()
    local menu = playdate.getSystemMenu()
    menu:removeAllMenuItems()

    menu:addMenuItem("Home", function()
        pendingNavUrl = "about:home"
    end)

    if currentState == Constants.STATE_PAGE and currentUrlObj and currentUrlObj.scheme ~= "about" then
        menu:addMenuItem("Bookmark", function()
            Storage.addBookmark(pageTitle, currentUrlObj.normalized, "")
        end)

        local initialVal = "Reader"
        if currentBrowseMode == Constants.MODE_RAW_HTML then initialVal = "HTML" end

        menu:addOptionsMenuItem("Mode", { "Reader", "HTML" }, initialVal, function(value)
            if value == "Reader" then currentBrowseMode = Constants.MODE_READER
            elseif value == "HTML" then currentBrowseMode = Constants.MODE_RAW_HTML end

            Storage.settings.mode = currentBrowseMode
            Storage.save()

            if currentUrlObj then
                navigateTo(currentUrlObj.normalized)
            end
        end)
    end

    menu:addMenuItem("Bookmarks", function()
        BookmarksPage.open()
        currentState = Constants.STATE_BOOKMARKS
    end)

    menu:addMenuItem("History", function()
        HistoryPage.open()
        currentState = Constants.STATE_HISTORY
    end)
end

-- ── Navigation ────────────────────────────────────────────────────────────────
local runNavigation

runNavigation = function(urlString)
    if not urlString or urlString == "" then return end
    Logger.log("runNavigation: " .. tostring(urlString))
    urlString = URL.unwrapRedirect(urlString)
    urlString = string.gsub(urlString, "^%s*(.-)%s*$", "%1")

    activeInputField = nil
    keyboardOpen = false
    ImageDecoder.clearCache()

    if urlString == "about:home" then
        currentState  = Constants.STATE_HOME
        currentUrlObj = URL.parse("about:home")
        pageTitle     = "CometBrowser Start Page"
        pushHistory("about:home")
        scrollY = 0
        targetScrollY = 0
        crankVelocity = 0
        updateSystemMenu()
        return
    end

    if not string.match(urlString, "^https?://") and not string.match(urlString, "^about:") then
        if URL.isSearchQuery(urlString) then
            urlString = "https://html.duckduckgo.com/html/?q=" .. URL.encode(urlString)
        else
            urlString = "https://" .. urlString
        end
    end

    local parsed = URL.parse(urlString)
    currentUrlObj   = parsed
    currentState    = Constants.STATE_LOADING
    progressCurrent = 0
    progressTotal   = 0
    pageTitle       = "Loading..."
    pushHistory(urlString)
    updateSystemMenu()

    HttpClient.get(urlString, {
        onProgress = function(cur, tot)
            progressCurrent = cur or 0
            progressTotal   = tot or 0
        end,
        onSuccess = function(status, headers, body, finalUrl)
            print("ZQFETCH OK status=" .. tostring(status) .. " bytes=" .. #(body or ""))
            Logger.log("fetch OK status=" .. tostring(status) .. " bytes=" .. #(body or "") .. " url=" .. tostring(finalUrl))
            local cbOk, cbErr = pcall(function()
                local resolvedUrl = finalUrl or parsed.normalized
                currentUrlObj = URL.parse(resolvedUrl)

                local parseOk, doc = pcall(function()
                    return Document.parse(body, resolvedUrl, currentBrowseMode)
                end)

                -- Force garbage collection immediately after parsing the heavy HTML string
                body = nil
                collectgarbage("collect")

                if parseOk and doc then
                    print("ZQPARSE ok reader=" .. tostring(doc.isReaderMode) .. " blocks=" .. tostring(#(doc.blocks or {})))
                    Logger.log("parse ok reader=" .. tostring(doc.isReaderMode) .. " blocks=" .. tostring(#(doc.blocks or {})))
                    currentDoc = doc
                    pageTitle  = doc.title or currentUrlObj.host or "Web Page"

                    local layoutOk, lErr = pcall(function()
                        Layout.build(currentDoc)
                    end)

                    -- Force garbage collection again after laying out UI blocks
                    collectgarbage("collect")

                    if layoutOk then
                        print("ZQITEMS " .. tostring(#(Layout.renderItems or {})))
                        Logger.log("layout ok items=" .. tostring(#(Layout.renderItems or {})))
                        print("=== ZQBLOCKS start ===")
                        for i, blk in ipairs(currentDoc.blocks or {}) do
                            local txt = ""
                            if blk.inlines then
                                for _, inl in ipairs(blk.inlines) do txt = txt .. (inl.text or "") end
                            elseif blk.text then txt = blk.text end
                            if #txt > 90 then txt = string.sub(txt, 1, 90) .. "..." end
                            print(i .. "[" .. (blk.type or "?") .. "]" .. (blk.level and (" h"..blk.level) or "") .. " |" .. txt .. "|")
                        end
                        print("=== ZQBLOCKS end ===")
                        scrollY = 0
                        targetScrollY = 0
                        crankVelocity = 0
                        currentState = Constants.STATE_PAGE
                        Storage.addHistory(pageTitle, resolvedUrl)
                        updateSystemMenu()

                        -- Enqueue all images for background download
                        for _, blk in ipairs(currentDoc.blocks or {}) do
                            if blk.type == "image" and blk.src and blk.src ~= "" then
                                ImageDecoder.enqueue(blk.src)
                            end
                        end

                        return
                    else
                        print("ZQLAYOUT-ERR " .. tostring(lErr))
                        ErrorPage.show("Layout Error: " .. tostring(lErr), parsed.normalized)
                        currentState = Constants.STATE_ERROR
                        pageTitle    = "Render Error"
                        updateSystemMenu()
                        return
                    end
                else
                    ErrorPage.show("Parse Error: " .. tostring(doc), parsed.normalized)
                    currentState = Constants.STATE_ERROR
                    pageTitle    = "Render Error"
                    updateSystemMenu()
                    return
                end
            end)
            if not cbOk then
                print("ZQNAV-CB-ERR: " .. tostring(cbErr))
                Logger.error("navigation callback: " .. tostring(cbErr))
                ErrorPage.show("Render Error: " .. tostring(cbErr), parsed.normalized)
                currentState = Constants.STATE_ERROR
                pageTitle    = "Render Error"
                updateSystemMenu()
            end
        end,
        onError = function(err)
            print("ZQFETCH ERROR: " .. tostring(err))
            Logger.log("fetch ERROR: " .. tostring(err))
            ErrorPage.show(err, parsed.normalized)
            currentState = Constants.STATE_ERROR
            pageTitle    = "Connection Error"
            updateSystemMenu()
        end
    })
end

-- Wrap navigation so an unexpected Lua error shows an Error page instead of
-- crashing the app (and so the message is visible in the console for diagnosis).
executeNavigation = function(urlString)
    if not urlString or urlString == "" then return end
    local ok, err = pcall(function()
        runNavigation(urlString)
    end)
    if not ok then
        print("ZQNAV-ERR: " .. tostring(err))
        Logger.error("executeNavigation: " .. tostring(err))
        ErrorPage.show("Navigation Error: " .. tostring(err), urlString)
        currentState = Constants.STATE_ERROR
        pageTitle    = "Navigation Error"
        updateSystemMenu()
    end
end

navigateTo = function(urlString)
    pendingNavUrl = urlString
end

-- ── Top-Level App Init ────────────────────────────────────────────────────────
Storage.init()
Logger.init()
Style.init()
HomePage.reset()
currentBrowseMode = Storage.settings.mode or Constants.MODE_READER
updateSystemMenu()
pendingNavUrl = "about:home"

-- ── Main Update Loop ──────────────────────────────────────────────────────────
-- The whole frame runs inside a pcall: if any Lua error slips through, it is
-- written to the crash log and the frame is skipped instead of killing the app.
local lastFrameErrAt = 0

local function updateFrame()
    gfx.clear()

    -- Live-sync on-screen keyboard text into the focused input field
    if keyboardOpen and activeInputField then
        activeInputField.value = playdate.keyboard.text or ""
    end

    if pendingNavUrl then
        local dest = pendingNavUrl
        pendingNavUrl = nil
        executeNavigation(dest)
    end

    local crankChange = playdate.getCrankChange()

    -- While any keyboard is up (address bar or a page's form input), the crank
    -- belongs to the keyboard's own cursor, so the page behind it must not
    -- scroll, and no velocity may be left over to release when it closes.
    local keyboardActive = keyboardOpen or AddressBar.isOpen
    if keyboardActive then
        crankChange = 0
        crankVelocity = 0
    elseif crankChange ~= 0 then
        crankVelocity = crankVelocity + crankChange * 1.6
    end
    crankVelocity = crankVelocity * 0.85
    if math.abs(crankVelocity) < 0.05 then crankVelocity = 0 end

    -- Manual crank scrolling moves the view, so drop the old link selection;
    -- the next D-pad press re-picks the closest selectable object in view.
    -- Only react to real crank input (not the decaying velocity tail), or the
    -- selection would be wiped right after it is made.
    if crankChange ~= 0 then
        LinkManager.clearSelection()
    end

    HttpClient.update()
    ImageDecoder.update()
    playdate.timer.updateTimers()

    -- Deferred address-bar keyboard: opens the on-screen keyboard on B release,
    -- but if Left/Right is pressed instead, cancel it and navigate back/forward.
    if addressBarKeyboardArmed and AddressBar.isOpen then
        if playdate.buttonJustReleased(playdate.kButtonB) then
            addressBarKeyboardArmed = false
            AddressBar.launchKeyboard()
        elseif playdate.buttonJustPressed(playdate.kButtonLeft) or playdate.buttonJustPressed(playdate.kButtonRight) then
            addressBarKeyboardArmed = false
            AddressBar.cancel()
            if playdate.buttonJustPressed(playdate.kButtonLeft) then
                local prev = goBack()
                if prev then navigateTo(prev) end
            else
                local fwd = goForward()
                if fwd then navigateTo(fwd) end
            end
        end
    end

    -- ── HOME STATE ────────────────────────────────────────────────────────────
    if currentState == Constants.STATE_HOME then
        if not AddressBar.isOpen then
            local selUrl = HomePage.handleInput()
            if selUrl then navigateTo(selUrl) end
        end
        HomePage.draw(crankChange)

        if playdate.buttonJustPressed(playdate.kButtonB) and not AddressBar.isOpen then
            AddressBar.open("", function(newUrl) navigateTo(newUrl) end)
            addressBarKeyboardArmed = true
        end

    -- ── PAGE STATE ────────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_PAGE then
        local totalH = getActiveTotalHeight()
        local maxScroll = math.max(0, totalH - Constants.CONTENT_HEIGHT)
        local isHtmlMode = (currentBrowseMode == Constants.MODE_RAW_HTML)

        if not keyboardOpen and not AddressBar.isOpen then
            -- ── READER MODE: crank scrolls up/down, D-Pad navigates links ──────
            if not isHtmlMode then
                targetScrollY = targetScrollY + crankVelocity

                -- A + Left = Back, A + Right = Forward
                if playdate.buttonIsPressed(playdate.kButtonA) then
                    if playdate.buttonJustPressed(playdate.kButtonLeft) then
                        local prev = goBack()
                        navigateTo(prev or "about:home")
                    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
                        local fwd = goForward()
                        if fwd then navigateTo(fwd) end
                    end
                else
                    if playdate.buttonJustPressed(playdate.kButtonDown) then
                        local nextLink = LinkManager.selectNext(scrollY)
                        if nextLink and nextLink.primaryRect then
                            local linkY = nextLink.primaryRect.y
                            if linkY > targetScrollY + Constants.CONTENT_HEIGHT - 50 then
                                targetScrollY = linkY - Constants.CONTENT_HEIGHT + 70
                            elseif linkY < targetScrollY + Constants.CONTENT_Y then
                                targetScrollY = linkY - Constants.CONTENT_Y - 20
                            end
                        else
                            targetScrollY = targetScrollY + 40
                        end
                    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
                        local prevLink = LinkManager.selectPrev(scrollY)
                        if prevLink and prevLink.primaryRect then
                            local linkY = prevLink.primaryRect.y
                            if linkY < targetScrollY + Constants.CONTENT_Y then
                                targetScrollY = linkY - Constants.CONTENT_Y - 20
                            elseif linkY > targetScrollY + Constants.CONTENT_HEIGHT - 50 then
                                targetScrollY = linkY - Constants.CONTENT_HEIGHT + 70
                            end
                        else
                            targetScrollY = targetScrollY - 40
                        end
                    end
                end

                -- (A) alone = Follow focused link / activate form input
                if playdate.buttonJustPressed(playdate.kButtonA) and not playdate.buttonIsPressed(playdate.kButtonLeft) and not playdate.buttonIsPressed(playdate.kButtonRight) then
                    local activeLink = LinkManager.getSelectedLink()
                    if activeLink then
                        local primary = activeLink.primaryRect or (activeLink.rects and activeLink.rects[1])
                        if primary and primary.isFormInput and primary.inputBlock then
                            local block = primary.inputBlock
                            if block.type == "input_field" then
                                openKeyboardForInput(block)
                            elseif block.type == "input_submit" then
                                submitForm(block.formAction, block)
                            end
                        elseif activeLink.href then
                            navigateTo(activeLink.href)
                        end
                    end
                end

                -- (B) = Address Bar
                if playdate.buttonJustPressed(playdate.kButtonB) and not AddressBar.isOpen then
                    local curUrlStr = currentUrlObj and currentUrlObj.normalized or ""
                    AddressBar.open(curUrlStr, function(newUrl) navigateTo(newUrl) end)
                    addressBarKeyboardArmed = true
                end

            -- ── HTML MODE: Virtual Mouse Cursor ──────────────────────────────
            else
                -- Move cursor with D-Pad
                local moved = false
                if playdate.buttonIsPressed(playdate.kButtonA) then
                    -- A + Left = Back, A + Right = Forward
                    if playdate.buttonJustPressed(playdate.kButtonLeft) then
                        local prev = goBack()
                        navigateTo(prev or "about:home")
                    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
                        local fwd = goForward()
                        if fwd then navigateTo(fwd) end
                    end
                else
                    if playdate.buttonIsPressed(playdate.kButtonLeft) then
                        mouseX = math.max(2, mouseX - mouseSpeed)
                        moved = true
                    end
                    if playdate.buttonIsPressed(playdate.kButtonRight) then
                        mouseX = math.min(Constants.SCREEN_WIDTH - 2, mouseX + mouseSpeed)
                        moved = true
                    end
                    if playdate.buttonIsPressed(playdate.kButtonUp) then
                        mouseY = math.max(Constants.CONTENT_Y + 2, mouseY - mouseSpeed)
                        moved = true
                    end
                    if playdate.buttonIsPressed(playdate.kButtonDown) then
                        mouseY = math.min(Constants.SCREEN_HEIGHT - 2, mouseY + mouseSpeed)
                        moved = true
                    end

                    -- Crank also moves cursor up/down (tilting)
                    if crankChange ~= 0 then
                        mouseY = math.max(Constants.CONTENT_Y + 2, math.min(Constants.SCREEN_HEIGHT - 2, mouseY + crankChange * 0.5))
                    end

                    -- Auto-scroll: if cursor near top or bottom edge, scroll
                    local SCROLL_ZONE = 20
                    if mouseY <= Constants.CONTENT_Y + SCROLL_ZONE then
                        local strength = (SCROLL_ZONE - (mouseY - Constants.CONTENT_Y)) / SCROLL_ZONE
                        targetScrollY = targetScrollY - 3 * (1 + strength * 3)
                    elseif mouseY >= Constants.SCREEN_HEIGHT - SCROLL_ZONE then
                        local strength = (SCROLL_ZONE - (Constants.SCREEN_HEIGHT - mouseY)) / SCROLL_ZONE
                        targetScrollY = targetScrollY + 3 * (1 + strength * 3)
                    end

                    -- (A) = Left Click: follow hovered link or activate input
                    if playdate.buttonJustPressed(playdate.kButtonA) then
                        local hitLink = LinkManager.getHoveredLink(mouseX, mouseY + scrollY)
                        if hitLink then
                            local primary = hitLink.primaryRect or (hitLink.rects and hitLink.rects[1])
                            if primary and primary.isFormInput and primary.inputBlock then
                                local block = primary.inputBlock
                                if block.type == "input_field" then
                                    openKeyboardForInput(block)
                                elseif block.type == "input_submit" then
                                    submitForm(block.formAction, block)
                                end
                            elseif hitLink.href then
                                navigateTo(hitLink.href)
                            end
                        end
                    end

                    -- (B) = Right Click: open Address Bar (context action)
                    if playdate.buttonJustPressed(playdate.kButtonB) and not AddressBar.isOpen then
                        local curUrlStr = currentUrlObj and currentUrlObj.normalized or ""
                        AddressBar.open(curUrlStr, function(newUrl) navigateTo(newUrl) end)
                        addressBarKeyboardArmed = true
                    end
                end
            end

            targetScrollY = math.max(0, math.min(maxScroll, targetScrollY))
            scrollY = scrollY + (targetScrollY - scrollY) * 0.4
        end

        Layout.draw(scrollY)

        -- Draw mouse cursor in HTML mode
        if isHtmlMode then
            local mx = mouseX
            local my = mouseY
            -- Arrow cursor (fill black triangle outline in white then black)
            gfx.setColor(gfx.kColorWhite)
            gfx.fillTriangle(mx, my, mx + 10, my + 4, mx + 4, my + 10)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawTriangle(mx, my, mx + 10, my + 4, mx + 4, my + 10)
            gfx.drawLine(mx, my, mx + 4, my + 10)

            -- Highlight hovered link
            local hovLink = LinkManager.getHoveredLink(mouseX, mouseY + scrollY)
            if hovLink and hovLink.primaryRect then
                local r = hovLink.primaryRect
                gfx.setColor(gfx.kColorBlack)
                gfx.setLineWidth(1)
                gfx.drawRect(r.x - 1, r.y - scrollY - 1, (r.w or 60) + 2, (r.h or 14) + 2)
                gfx.setLineWidth(1)
            end
        end

        Hud.draw(scrollY, Layout.totalHeight, LinkManager.getSelectedLink())

    -- ── LOADING STATE ─────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_LOADING then
        local fontH = Style.fontHeading1 or gfx.getFont()
        local fontB = Style.fontBody    or gfx.getFont()

        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, Constants.CONTENT_Y, Constants.SCREEN_WIDTH, Constants.CONTENT_HEIGHT)

        gfx.setColor(gfx.kColorBlack)
        gfx.setFont(fontH)
        gfx.drawText("Loading Web Page...", 24, 60)
        gfx.setFont(fontB)

        local displayHost = currentUrlObj and currentUrlObj.normalized or "Web Request"
        if #displayHost > 45 then displayHost = string.sub(displayHost, 1, 42) .. "..." end
        gfx.drawText(displayHost, 24, 90)

        if progressTotal > 0 then
            local pct = math.floor((progressCurrent / progressTotal) * 100)
            gfx.drawText(string.format("Received: %d / %d bytes (%d%%)", progressCurrent, progressTotal, pct), 24, 116)
            gfx.drawRect(24, 138, 352, 10)
            gfx.fillRect(24, 138, math.floor(352 * pct / 100), 10)
        else
            gfx.drawText(string.format("Downloading on device... (%d bytes)", progressCurrent), 24, 116)
        end

        gfx.drawText("(B) Cancel  *  (Left) Back", 24, 165)

        if playdate.buttonJustPressed(playdate.kButtonB) then
            HttpClient.cancel()
            navigateTo("about:home")
        end
        if playdate.buttonJustPressed(playdate.kButtonLeft) then
            HttpClient.cancel()
            local prev = goBack()
            navigateTo(prev or "about:home")
        end

    -- ── ERROR STATE ───────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_ERROR then
        if not AddressBar.isOpen then
            local action = ErrorPage.handleInput()
            if action == "retry" then
                if currentUrlObj then navigateTo(currentUrlObj.normalized) end
            elseif action == "search" then
                AddressBar.open("", function(newUrl) navigateTo(newUrl) end)
                AddressBar.launchKeyboard()
            elseif action == "home" then
                navigateTo("about:home")
            end

            if playdate.buttonJustPressed(playdate.kButtonLeft) then
                local prev = goBack()
                navigateTo(prev or "about:home")
            end
        end

        ErrorPage.draw()

    -- ── BOOKMARKS STATE ───────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_BOOKMARKS then
        local action = BookmarksPage.handleInput()
        if action == "close" then navigateTo("about:home")
        elseif action then navigateTo(action) end
        BookmarksPage.draw(crankChange)

    -- ── HISTORY STATE ─────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_HISTORY then
        local action = HistoryPage.handleInput()
        if action == "close" then navigateTo("about:home")
        elseif action then navigateTo(action) end
        HistoryPage.draw(crankChange)
    end

    local isReader = (currentBrowseMode == Constants.MODE_READER)
    Chrome.draw(currentUrlObj, pageTitle, currentState == Constants.STATE_LOADING, progressCurrent, progressTotal, isReader)
    AddressBar.drawOverlay()
end

function playdate.update()
    local ok, err = pcall(updateFrame)
    if not ok then
        local now = playdate.getCurrentTimeMilliseconds()
        if now - lastFrameErrAt > 1000 then
            lastFrameErrAt = now
            Logger.error("playdate.update: " .. tostring(err))
        end
    end
end
