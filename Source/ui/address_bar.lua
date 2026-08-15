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
                if AddressBar.onSubmitCallback then
                    AddressBar.onSubmitCallback(finalUrl)
                end
                return
            end
        end
        AddressBar.isOpen = false
        AddressBar.keyboardShown = false
    end

    playdate.keyboard.textChangedCallback = function()
        AddressBar.inputText = playdate.keyboard.text or ""
    end

    playdate.keyboard.show(AddressBar.inputText)
end

function AddressBar.cancel()
    AddressBar.isOpen = false
    AddressBar.keyboardShown = false
    AddressBar.onSubmitCallback = nil
    playdate.keyboard.keyboardWillHideCallback = nil
    playdate.keyboard.textChangedCallback = nil
end

function AddressBar.drawOverlay()
    if not AddressBar.isOpen then return end

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(10, 6, Constants.SCREEN_WIDTH - 20, 48, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(10, 6, Constants.SCREEN_WIDTH - 20, 48, 6)
    gfx.drawRoundRect(12, 8, Constants.SCREEN_WIDTH - 24, 44, 4)

    local font = Style.fontBodyBold or gfx.getFont()
    gfx.setFont(font)
    gfx.drawText("Enter Web URL or Search Query:", 20, 12)

    local txt = AddressBar.inputText ~= "" and AddressBar.inputText or "https://"
    if #txt > 40 then
        txt = "..." .. string.sub(txt, -37)
    end
    
    gfx.setFont(Style.fontMono or font)
    gfx.drawText(txt, 20, 30)
end
