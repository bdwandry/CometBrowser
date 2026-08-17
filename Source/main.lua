-- CometBrowser Main Application Loop (100% Pure On-Device)
import "CoreLibs/timer"
import "CoreLibs/graphics"
import "CoreLibs/keyboard"
import "core/constants"
import "core/url"
import "core/storage"
import "core/http_client"
import "core/tasks"
import "core/cookie_jar"
import "core/logger"
import "core/encoding"
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
local renderBody
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

-- True while the downloaded HTML is being parsed/laid out (async task); keeps
-- the LOADING screen visible and informs the user what is happening.
local isRendering        = false

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
skipInputFrames          = 0   -- after keyboard closes, skip input for 1 frame

-- B button hold state: defer keyboard to release, allow B+Left/Right history
local bHoldActive       = false
local bHoldUsedDir      = false
local bHoldStartMs      = 0
local bNotPressedFrames = 0
local navigatingHistory = false  -- true while goBack/goForward drives navigateTo

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
        navigatingHistory = true
        return navHistory[historyIndex]
    end
    return nil
end

local function goForward()
    if historyIndex < #navHistory then
        historyIndex = historyIndex + 1
        navigatingHistory = true
        return navHistory[historyIndex]
    end
    return nil
end

local function openKeyboardForInput(inputBlock)
    if not inputBlock then return end
    activeInputField = inputBlock
    keyboardOpen = true
    playdate.keyboard.keyboardWillHideCallback = nil
    playdate.keyboard.textChangedCallback = nil
    playdate.keyboard.show(inputBlock.value or "")

    playdate.keyboard.keyboardDidHideCallback = function()
        keyboardOpen = false
        skipInputFrames = 2
        local entered = playdate.keyboard.text or ""
        if activeInputField then
            if activeInputField.maxlength and #entered > activeInputField.maxlength then
                entered = string.sub(entered, 1, activeInputField.maxlength)
            end
            activeInputField.value = entered
        end
        activeInputField = nil
        playdate.keyboard.keyboardDidHideCallback = nil
    end
end

local function submitForm(formAction, inputBlock)
    if not formAction or formAction == "" then
        -- Fallback: use the current page URL as the form target
        formAction = currentUrlObj and currentUrlObj.normalized or ""
    end
    if formAction == "#" then return end
    local pairs = {}
    for _, item in ipairs(Layout.renderItems or {}) do
        if item.disabled then
            -- Disabled controls are never submitted.
        elseif item.type == "input_field" and item.formAction == formAction then
            if item.name and item.name ~= "" then
                table.insert(pairs, URL.encode(item.name) .. "=" .. URL.encode(item.value or ""))
            end
        elseif item.type == "input_submit" and item.formAction == formAction and item.name then
            table.insert(pairs, URL.encode(item.name) .. "=" .. URL.encode(item.value or ""))
        elseif item.type == "checkbox_field" and item.formAction == formAction and item.checked then
            table.insert(pairs, URL.encode(item.name or "") .. "=" .. URL.encode(item.value ~= "" and item.value or "on"))
        elseif item.type == "select_field" and item.formAction == formAction then
            local opt = item.options and item.options[item.selectedIndex]
            if opt and not opt.disabled and not opt.group then
                table.insert(pairs, URL.encode(item.name or "") .. "=" .. URL.encode(opt.value or opt.text or ""))
            end
        end
    end
    -- If no fields matched by formAction, try collecting all visible input fields
    if #pairs == 0 then
        for _, item in ipairs(Layout.renderItems or {}) do
            if not item.disabled and item.type == "input_field" and item.name and item.name ~= "" then
                table.insert(pairs, URL.encode(item.name) .. "=" .. URL.encode(item.value or ""))
            end
        end
    end
    -- Last resort: include the submit button's own name=value
    if #pairs == 0 and inputBlock and not inputBlock.disabled then
        table.insert(pairs, URL.encode(inputBlock.name or "q") .. "=" .. URL.encode(inputBlock.value or ""))
    end
    local query = table.concat(pairs, "&")
    local sep = string.find(formAction, "?") and "&" or "?"
    local target = formAction .. (query ~= "" and (sep .. query) or "")
    navigateTo(target)
end

-- Activate a focused form control: type text / submit the form / toggle a
-- checkbox or radio / cycle a dropdown selection.
local function activateFormBlock(block)
    if not block then return end
    if block.disabled or block.inert then return end
    if block.type == "input_field" then
        Layout.selectedInputItem = block
        openKeyboardForInput(block)
    elseif block.type == "input_submit" then
        submitForm(block.formAction, block)
    elseif block.type == "checkbox_field" then
        if block.radio then
            for _, item in ipairs(Layout.renderItems or {}) do
                if item.type == "checkbox_field" and item.radio and item.name == block.name and item ~= block then
                    item.checked = false
                end
            end
            block.checked = true
        else
            block.checked = not block.checked
        end
        Layout.selectedInputItem = block
    elseif block.type == "select_field" then
        local n = #(block.options or {})
        if n > 0 then
            local tries = n + 1
            while tries > 0 do
                block.selectedIndex = ((block.selectedIndex or 1) % n) + 1
                local opt = block.options[block.selectedIndex]
                if not opt.disabled and not opt.group then break end
                tries = tries - 1
            end
        end
        Layout.selectedInputItem = block
    end
end

local function getActiveTotalHeight()
    return Layout.totalHeight
end

-- ── System Menu ───────────────────────────────────────────────────────────────
updateSystemMenu = function()
    local menu = playdate.getSystemMenu()
    menu:removeAllMenuItems()

    menu:addMenuItem("Home-Page", function()
        pendingNavUrl = "about:home"
    end)

    if currentState == Constants.STATE_PAGE and currentUrlObj and currentUrlObj.scheme ~= "about" then
        local initialVal = "Reader"
        if currentBrowseMode == Constants.MODE_RAW_HTML then initialVal = "HTML" end

        menu:addOptionsMenuItem("View", { "Reader", "HTML" }, initialVal, function(value)
            if value == "Reader" then currentBrowseMode = Constants.MODE_READER
            elseif value == "HTML" then currentBrowseMode = Constants.MODE_RAW_HTML end

            Storage.settings.mode = currentBrowseMode
            Storage.save()

            if currentUrlObj then
                -- The page body is already in memory (Document keeps it in
                -- doc.rawHtml for both modes), so switching views only needs a
                -- re-parse/re-layout -- never a re-download.
                if currentDoc and currentDoc.rawHtml and currentDoc.rawHtml ~= "" then
                    renderBody(currentDoc.rawHtml, currentUrlObj.normalized, false)
                else
                    navigateTo(currentUrlObj.normalized)
                end
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

    menu:addMenuItem("Clear Cookies", function()
        CookieJar.clear()
    end)
end

-- ── Navigation ────────────────────────────────────────────────────────────────
local runNavigation

runNavigation = function(urlString)
    if not urlString or urlString == "" then return end

    -- Any still-running parse/render of a previous page must be dropped; its
    -- onComplete would otherwise fire later and hijack the new page.
    Tasks.cancelAll()
    isRendering = false

    urlString = URL.unwrapRedirect(urlString)
    urlString = string.gsub(urlString, "^%s*(.-)%s*$", "%1")

    activeInputField = nil
    keyboardOpen = false
    ImageDecoder.clearCache()

    if urlString == "about:home" then
        currentState  = Constants.STATE_HOME
        currentUrlObj = URL.parse("about:home")
        pageTitle     = "CometBrowser Start Page"
        if not navigatingHistory then pushHistory("about:home") end
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
    if not navigatingHistory then pushHistory(urlString) end
    navigatingHistory = false
    updateSystemMenu()

    HttpClient.get(urlString, {
        onProgress = function(cur, tot)
            progressCurrent = cur or 0
            progressTotal   = tot or 0
        end,
        onSuccess = function(status, headers, body, finalUrl)

            local resolvedUrl = finalUrl or parsed.normalized
            currentUrlObj = URL.parse(resolvedUrl)
            body = Encoding.toUtf8(body, headers and headers["content-type"] or nil)
            renderBody(body, resolvedUrl, true)
        end,
        onError = function(err)
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
        ErrorPage.show("Navigation Error: " .. tostring(err), urlString)
        currentState = Constants.STATE_ERROR
        pageTitle    = "Navigation Error"
        updateSystemMenu()
    end
end

-- Parse + layout a fetched (or cached) HTML body as a cooperative task, so a
-- big page is rendered a little each frame instead of stalling the run loop
-- for 10+ seconds on the physical device. Used both after a fresh download
-- (addToHistory = true) and when switching Reader/HTML view (addToHistory =
-- false) re-parses the in-memory body -- no re-download.
renderBody = function(body, url, addToHistory)
    isRendering = true
    progressCurrent = 0
    progressTotal   = 0
    pageTitle       = "Rendering..."
    currentState    = Constants.STATE_LOADING

    Tasks.run(
        function()
            local parseOk, doc = pcall(function()
                return Document.parse(body, url, currentBrowseMode)
            end)
            if not parseOk then
                error("Parse Error: " .. tostring(doc))
            end

            local layoutOk, lErr = pcall(function()
                Layout.build(doc)
            end)
            if not layoutOk then
                error("Layout Error: " .. tostring(lErr))
            end

            return doc
        end,
        function(doc)
            isRendering = false
            currentDoc = doc
            pageTitle  = doc.title or currentUrlObj.host or "Web Page"
            scrollY = 0
            targetScrollY = 0
            crankVelocity = 0
            currentState = Constants.STATE_PAGE
            if addToHistory then
                Storage.addHistory(pageTitle, url)
            end
            updateSystemMenu()

            -- Enqueue all images for background download
            local imgCount = 0
            for _, blk in ipairs(currentDoc.blocks or {}) do
                if blk.type == "image" and blk.src and blk.src ~= "" then
                    imgCount = imgCount + 1
                    ImageDecoder.enqueue(blk.src)
                end
            end
        end,
        function(err)
            isRendering = false
            ErrorPage.show(err, url)
            currentState = Constants.STATE_ERROR
            pageTitle    = "Render Error"
            updateSystemMenu()
        end
    )
end

navigateTo = function(urlString)
    pendingNavUrl = urlString
end

-- ── Interactive <details> toggling ─────────────────────────────────────────────
-- Re-parses the current document with the toggled details element forced open
-- (or closed), re-layouts, and preserves the scroll position. No history entry
-- is added for a toggle.
local detailsOpenSet = {}

local toggleDetails = function(dkey)
    if not currentDoc or not currentDoc.rawHtml or isRendering then return end
    local prevScroll = scrollY
    local prevTarget = targetScrollY
    isRendering = true
    Tasks.run(
        function()
            detailsOpenSet[dkey] = not detailsOpenSet[dkey]
            local parseOk, doc = pcall(function()
                return Document.parse(
                    currentDoc.rawHtml,
                    currentDoc.baseUrl,
                    currentDoc.mode,
                    { detailsOpen = detailsOpenSet }
                )
            end)
            if not parseOk then
                error("Parse Error: " .. tostring(doc))
            end
            local layoutOk, lErr = pcall(function()
                Layout.build(doc)
            end)
            if not layoutOk then
                error("Layout Error: " .. tostring(lErr))
            end
            return doc
        end,
        function(doc)
            isRendering = false
            currentDoc = doc
            scrollY = prevScroll
            targetScrollY = prevTarget
            Layout.draw(0)
        end,
        function(err)
            isRendering = false
            detailsOpenSet[dkey] = not detailsOpenSet[dkey]
        end
    )
end

-- ── Top-Level App Init ────────────────────────────────────────────────────────
Storage.init()
CookieJar.prune()
Logger.init()
Style.init()
HomePage.reset()
currentBrowseMode = Storage.settings.mode or Constants.MODE_READER
updateSystemMenu()

-- ── Main Update Loop ──────────────────────────────────────────────────────────
-- The whole frame runs inside a pcall: if any Lua error slips through, it is
-- written to the crash log and the frame is skipped instead of killing the app.
local lastFrameErrAt = 0
local lastFrameAtMs = 0

local function updateFrame()
    gfx.clear()

    -- Detect system menu close: if >500ms gap between frames, the system menu
    -- was open. Close keyboard/address bar so they don't linger.
    local nowMs = playdate.getCurrentTimeMilliseconds()
    if lastFrameAtMs > 0 and (nowMs - lastFrameAtMs) > 500 then
        if keyboardOpen then
            playdate.keyboard.hide()
            keyboardOpen = false
        end
        if AddressBar.isOpen then
            AddressBar.cancel()
        end
        skipInputFrames = 2
    end
    lastFrameAtMs = nowMs

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
    Tasks.update()

    -- Reset B hold state when not in a page-browsing state (loading, error, etc.)
    if currentState ~= Constants.STATE_HOME and currentState ~= Constants.STATE_PAGE then
        bHoldActive = false
    end

    -- ── B BUTTON HOLD STATE MACHINE ──────────────────────────────────────────
    -- On B press: start tracking.  While B held: Left/Right navigate history.
    -- On B release (no direction used): open address bar + keyboard.
    -- Requires 4 consecutive frames of B-not-pressed before treating as a real
    -- release, preventing simulator key-repeat flickers from opening the
    -- keyboard while the user is still physically holding B.
    if currentState == Constants.STATE_HOME or currentState == Constants.STATE_PAGE then
        local bDown = playdate.buttonIsPressed(playdate.kButtonB)
        local nowMs = playdate.getCurrentTimeMilliseconds()

        if bDown then
            bNotPressedFrames = 0
        else
            bNotPressedFrames = bNotPressedFrames + 1
        end

        if playdate.buttonJustPressed(playdate.kButtonB) and not AddressBar.isOpen and not keyboardOpen and not bHoldActive then
            bHoldActive = true
            bHoldUsedDir = false
            bHoldStartMs = nowMs
            bNotPressedFrames = 0
        end
        if bHoldActive and bDown then
            if not AddressBar.isOpen and not keyboardOpen then
                if playdate.buttonIsPressed(playdate.kButtonLeft) then
                    if not bHoldUsedDir then
                        local prev = goBack()
                        navigateTo(prev or "about:home")
                    end
                    bHoldUsedDir = true
                elseif playdate.buttonIsPressed(playdate.kButtonRight) then
                    if not bHoldUsedDir then
                        local fwd = goForward()
                        if fwd then navigateTo(fwd) end
                    end
                    bHoldUsedDir = true
                end
            end
        end
        if bHoldActive and bNotPressedFrames >= 4 then
            if not bHoldUsedDir and not AddressBar.isOpen and not keyboardOpen then
                if currentState == Constants.STATE_HOME then
                    AddressBar.open("", function(newUrl) navigateTo(newUrl) end)
                    AddressBar.launchKeyboard()
                else
                    local curUrlStr = currentUrlObj and currentUrlObj.normalized or ""
                    AddressBar.open(curUrlStr, function(newUrl) navigateTo(newUrl) end)
                    AddressBar.launchKeyboard()
                end
            end
            bHoldActive = false
            bNotPressedFrames = 0
        end
    else
        bNotPressedFrames = 0
        bHoldActive = false
    end

    -- Decrement skipInputFrames unconditionally so it ticks down in every state
    if skipInputFrames > 0 then skipInputFrames = skipInputFrames - 1 end

    -- ── HOME STATE ────────────────────────────────────────────────────────────
    if currentState == Constants.STATE_HOME then
        if skipInputFrames <= 0 and not AddressBar.isOpen and not keyboardOpen then
            local selUrl = HomePage.handleInput()
            if selUrl then navigateTo(selUrl) end
        end
        HomePage.draw(crankChange)

    -- ── PAGE STATE ────────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_PAGE then
        local totalH = getActiveTotalHeight()
        local maxScroll = math.max(0, totalH - Constants.CONTENT_HEIGHT)
        local isHtmlMode = (currentBrowseMode == Constants.MODE_RAW_HTML)

        if skipInputFrames <= 0 and not keyboardOpen and not AddressBar.isOpen then
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
                        if primary and primary.isToggle and primary.toggleKey then
                            toggleDetails(primary.toggleKey)
                        elseif primary and primary.isFormInput and primary.inputBlock then
                            activateFormBlock(primary.inputBlock)
                        elseif activeLink.href and not (primary and primary.inert) then
                            navigateTo(activeLink.href)
                        end
                    end
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
                    -- Suppress mouse movement while B is held for history navigation
                    if not bHoldActive then
                        local dpadHeld = false
                        if playdate.buttonIsPressed(playdate.kButtonLeft) then
                            mouseX = math.max(2, mouseX - mouseSpeed)
                            moved = true
                            dpadHeld = true
                        end
                        if playdate.buttonIsPressed(playdate.kButtonRight) then
                            mouseX = math.min(Constants.SCREEN_WIDTH - 2, mouseX + mouseSpeed)
                            moved = true
                            dpadHeld = true
                        end
                        if playdate.buttonIsPressed(playdate.kButtonUp) then
                            mouseY = math.max(Constants.CONTENT_Y + 2, mouseY - mouseSpeed)
                            moved = true
                            dpadHeld = true
                        end
                        if playdate.buttonIsPressed(playdate.kButtonDown) then
                            mouseY = math.min(Constants.SCREEN_HEIGHT - 2, mouseY + mouseSpeed)
                            moved = true
                            dpadHeld = true
                        end

                        if dpadHeld then
                            if crankChange ~= 0 then
                                mouseY = math.max(Constants.CONTENT_Y + 2, math.min(Constants.SCREEN_HEIGHT - 2, mouseY + crankChange * 0.5))
                            end
                            local SCROLL_ZONE = 20
                            if mouseY <= Constants.CONTENT_Y + SCROLL_ZONE then
                                local strength = (SCROLL_ZONE - (mouseY - Constants.CONTENT_Y)) / SCROLL_ZONE
                                targetScrollY = targetScrollY - 3 * (1 + strength * 3)
                            elseif mouseY >= Constants.SCREEN_HEIGHT - SCROLL_ZONE then
                                local strength = (SCROLL_ZONE - (Constants.SCREEN_HEIGHT - mouseY)) / SCROLL_ZONE
                                targetScrollY = targetScrollY + 3 * (1 + strength * 3)
                            end
                        else
                            targetScrollY = targetScrollY + crankVelocity
                        end
                    end
                end
            end

            -- (A) = Left Click: follow hovered link or activate input.
            -- Handled OUTSIDE the A-hold branch: on the press frame buttonIsPressed(A)
            -- is already true, so a handler nested in the else could never fire.
            if playdate.buttonJustPressed(playdate.kButtonA) and
               not playdate.buttonIsPressed(playdate.kButtonLeft) and
               not playdate.buttonIsPressed(playdate.kButtonRight) then
                local hitLink = LinkManager.getHoveredLink(mouseX, mouseY + scrollY)
                if hitLink then
                    local primary = hitLink.primaryRect or (hitLink.rects and hitLink.rects[1])
                    if primary and primary.isToggle and primary.toggleKey then
                        toggleDetails(primary.toggleKey)
                    elseif primary and primary.isFormInput and primary.inputBlock then
                        activateFormBlock(primary.inputBlock)
                    elseif hitLink.href and not (primary and primary.inert) then
                        navigateTo(hitLink.href)
                    end
                end
            end

            targetScrollY = math.max(0, math.min(maxScroll, targetScrollY))
            scrollY = scrollY + (targetScrollY - scrollY) * 0.4
        end

        Layout.draw(scrollY)

        Hud.draw(scrollY, Layout.totalHeight, LinkManager.getSelectedLink())

    -- ── LOADING STATE ─────────────────────────────────────────────────────────
    elseif currentState == Constants.STATE_LOADING then
        local fontH = Style.fontHeading1 or gfx.getFont()
        local fontB = Style.fontBody    or gfx.getFont()

        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, Constants.CONTENT_Y, Constants.SCREEN_WIDTH, Constants.CONTENT_HEIGHT)

        gfx.setColor(gfx.kColorBlack)
        gfx.setFont(fontH)
        if isRendering then
            gfx.drawText("Rendering Web Page...", 24, 60)
        else
            gfx.drawText("Loading Web Page...", 24, 60)
        end
        gfx.setFont(fontB)

        local displayHost = currentUrlObj and currentUrlObj.normalized or "Web Request"
        if #displayHost > 45 then displayHost = string.sub(displayHost, 1, 42) .. "..." end
        gfx.drawText(displayHost, 24, 90)

        if isRendering then
            local p = Tasks.getProgress()
            local pct = math.floor(math.min(1, p) * 100)
            gfx.drawText(string.format("Rendering page content... %d%%", pct), 24, 116)
            gfx.drawRect(24, 138, 352, 10)
            gfx.fillRect(24, 138, math.floor(352 * math.min(1, p)), 10)
        elseif progressTotal > 0 then
            local pct = math.floor(math.min(100, (progressCurrent / progressTotal) * 100))
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
    gfx.clearClipRect()
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    Chrome.draw(currentUrlObj, pageTitle, currentState == Constants.STATE_LOADING, progressCurrent, progressTotal, isReader)
    AddressBar.drawOverlay()

    -- Draw mouse cursor as the very last thing so nothing can draw over it
    if currentState == Constants.STATE_PAGE and currentBrowseMode == Constants.MODE_RAW_HTML then
        gfx.pushContext()
        gfx.clearClipRect()
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
        local mx = mouseX
        local my = mouseY
        gfx.setColor(gfx.kColorWhite)
        gfx.fillTriangle(mx, my, mx + 10, my + 4, mx + 4, my + 10)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawTriangle(mx, my, mx + 10, my + 4, mx + 4, my + 10)
        gfx.drawLine(mx, my, mx + 4, my + 10)
        gfx.popContext()
    end
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
