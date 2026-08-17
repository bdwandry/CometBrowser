-- Address Bar & Web Search Controller for CometBrowser
import "core/url"
import "core/constants"
import "core/storage"
import "render/style"

AddressBar = {}
local gfx = playdate.graphics

AddressBar.isOpen = false
AddressBar.inputText = ""
AddressBar.onSubmitCallback = nil
AddressBar.keyboardShown = false

function AddressBar.open(currentUrl, onSubmit)
    AddressBar.isOpen = true
    AddressBar.keyboardShown = false
    AddressBar.onSubmitCallback = onSubmit
    
    local initialText = ""
    if currentUrl and not string.match(currentUrl, "^about:") then
        initialText = currentUrl
    end

    AddressBar.inputText = initialText
    -- Keyboard is NOT shown here; it launches on B release (see launchKeyboard).
    -- This lets the user press Left/Right to navigate back/forward instead.
end

function AddressBar.launchKeyboard()
    if not AddressBar.isOpen or AddressBar.keyboardShown then return end
    AddressBar.keyboardShown = true

    playdate.keyboard.keyboardWillHideCallback = function(submitted)
        if submitted then
            local text = playdate.keyboard.text or ""
            text = string.gsub(text, "^%s*(.-)%s*$", "%1")
            if text ~= "" then
                local finalUrl
                if URL.isSearchQuery(text) then
                    local searchEngine = Constants.SEARCH_ENGINES[Storage.settings.searchEngine or 1]
                    finalUrl = URL.buildSearchUrl(searchEngine.url, text)
                else
                    local parsed = URL.parse(text)
                    finalUrl = parsed.normalized
                end
                
                AddressBar.isOpen = false
                AddressBar.keyboardShown = false
                skipInputFrames = 2
                if AddressBar.onSubmitCallback then
                    AddressBar.onSubmitCallback(finalUrl)
                end
                return
            end
        end
        AddressBar.isOpen = false
        AddressBar.keyboardShown = false
        skipInputFrames = 2
    end

    playdate.keyboard.textChangedCallback = function()
        AddressBar.inputText = playdate.keyboard.text or ""
    end

    playdate.keyboard.show(AddressBar.inputText)
end

function AddressBar.cancel()
    if AddressBar.keyboardShown then
        playdate.keyboard.hide()
    end
    AddressBar.isOpen = false
    AddressBar.keyboardShown = false
    AddressBar.onSubmitCallback = nil
    playdate.keyboard.keyboardWillHideCallback = nil
    playdate.keyboard.textChangedCallback = nil
end

function AddressBar.drawOverlay()
    if not AddressBar.isOpen then return end

    local boxX, boxY, boxW, boxH
    if AddressBar.keyboardShown then
        boxX = 4
        boxY = 4
        boxW = 192
        boxH = Constants.SCREEN_HEIGHT - 8
    else
        boxX = 10
        boxY = 6
        boxW = Constants.SCREEN_WIDTH - 20
        boxH = 48
    end

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(boxX, boxY, boxW, boxH, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(boxX, boxY, boxW, boxH, 6)

    -- Clip to box interior
    gfx.pushContext()
    gfx.setClipRect(boxX + 2, boxY + 2, boxW - 4, boxH - 4)

    local innerX = boxX + 10
    local innerY = boxY + 10
    local innerW = boxW - 20

    local font = Style.fontBodyBold or gfx.getFont()
    gfx.setFont(font)
    gfx.drawText("Enter URL or Search:", innerX, innerY)

    local txt = AddressBar.inputText or ""
    local monoFont = Style.fontMono or font
    gfx.setFont(monoFont)

    if AddressBar.keyboardShown then
        -- Wrap text to fill the box vertically
        local lineY = innerY + 22
        local lineHeight = 14
        local line = ""
        for i = 1, #txt do
            local ch = string.sub(txt, i, i)
            local testLine = line .. ch
            local tw = Style.getTextWidth(monoFont, testLine)
            if tw > innerW and #line > 0 then
                monoFont:drawText(line, innerX, lineY)
                lineY = lineY + lineHeight
                line = ch
                if lineY > boxY + boxH - 14 then break end
            else
                line = testLine
            end
        end
        if line ~= "" and lineY <= boxY + boxH - 14 then
            monoFont:drawText(line, innerX, lineY)
        end
    else
        monoFont:drawText(txt, innerX, innerY + 22)
    end

    gfx.popContext()
end
