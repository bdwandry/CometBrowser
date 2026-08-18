-- Settings Menu Overlay for CometBrowser
import "core/constants"
import "core/storage"
import "core/logger"
import "render/style"

SettingsPage = {}
local gfx = playdate.graphics

SettingsPage.isOpen = false
SettingsPage.selectedIndex = 1
SettingsPage.previousState = nil
SettingsPage.onChangeCallback = nil

local ANIM_DURATION_MS = 300
local BORDER = 10
local BOX_RADIUS = 10
local animStartMs = 0

local BOX_X = BORDER
local BOX_Y = BORDER + 10
local BOX_W = Constants.SCREEN_WIDTH - BORDER * 2
local BOX_H = Constants.SCREEN_HEIGHT - BORDER - BOX_Y
local CENTER_X = Constants.SCREEN_WIDTH / 2
local CENTER_Y = BOX_Y + BOX_H / 2

-- Staged settings: a copy of current settings that gets modified.
-- Only applied to Storage on Save (A). Discarded on Cancel (B).
local staged = {}

local settingsOptions = {}

local function buildOptions()
    settingsOptions = {
        {
            label = "Search Engine",
            getValue = function()
                local idx = staged.searchEngine or 1
                return Constants.SEARCH_ENGINES[idx] and Constants.SEARCH_ENGINES[idx].name or "DuckDuckGo"
            end,
            left = function()
                local n = #Constants.SEARCH_ENGINES
                staged.searchEngine = ((staged.searchEngine or 1) - 2 + n) % n + 1
            end,
            right = function()
                local n = #Constants.SEARCH_ENGINES
                staged.searchEngine = ((staged.searchEngine or 1) % n) + 1
            end,
        },
        {
            label = "Browse Mode",
            getValue = function()
                if staged.mode == Constants.MODE_RAW_HTML then return "HTML" end
                return "Reader"
            end,
            left = function()
                if staged.mode == Constants.MODE_RAW_HTML then
                    staged.mode = Constants.MODE_READER
                else
                    staged.mode = Constants.MODE_RAW_HTML
                end
            end,
            right = function()
                if staged.mode == Constants.MODE_RAW_HTML then
                    staged.mode = Constants.MODE_READER
                else
                    staged.mode = Constants.MODE_RAW_HTML
                end
            end,
        },
        {
            label = "Invert Crank",
            getValue = function()
                if staged.invertCrank then return "On" end
                return "Off"
            end,
            left = function()
                staged.invertCrank = not staged.invertCrank
            end,
            right = function()
                staged.invertCrank = not staged.invertCrank
            end,
        },
        {
            label = "Clear Cookies",
            getValue = function() return "" end,
            left = function() CookieJar.clear() end,
            right = function() CookieJar.clear() end,
            isAction = true,
        },
    }
end

function SettingsPage.open(prevState)
    SettingsPage.isOpen = true
    SettingsPage.selectedIndex = 1
    SettingsPage.previousState = prevState
    animStartMs = playdate.getCurrentTimeMilliseconds()
    -- Snapshot current settings into staged copy
    staged = {
        searchEngine = Storage.settings.searchEngine or 1,
        mode = Storage.settings.mode or Constants.MODE_READER,
        invertCrank = Storage.settings.invertCrank or false,
    }
    buildOptions()
    Logger.log("SettingsPage.open() previousState=" .. tostring(prevState))
end

function SettingsPage.close()
    SettingsPage.isOpen = false
    Logger.log("SettingsPage.close()")
end

-- Save staged settings to Storage and trigger re-render
function SettingsPage.saveAndClose()
    Storage.settings.searchEngine = staged.searchEngine
    Storage.settings.mode = staged.mode
    Storage.settings.invertCrank = staged.invertCrank
    Storage.save()
    if SettingsPage.onChangeCallback then
        SettingsPage.onChangeCallback()
    end
    Logger.log("SettingsPage.saveAndClose: mode=" .. tostring(staged.mode))
    SettingsPage.close()
    return "save"
end

-- Discard staged settings and close
function SettingsPage.cancelAndClose()
    Logger.log("SettingsPage.cancelAndClose: discarding changes")
    SettingsPage.close()
    return "close"
end

function SettingsPage.handleInput()
    if not SettingsPage.isOpen then return nil end

    if playdate.buttonJustPressed(playdate.kButtonDown) then
        SettingsPage.selectedIndex = math.min(#settingsOptions, SettingsPage.selectedIndex + 1)
    elseif playdate.buttonJustPressed(playdate.kButtonUp) then
        SettingsPage.selectedIndex = math.max(1, SettingsPage.selectedIndex - 1)
    elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
        local opt = settingsOptions[SettingsPage.selectedIndex]
        if opt and opt.left then opt.left() end
    elseif playdate.buttonJustPressed(playdate.kButtonRight) then
        local opt = settingsOptions[SettingsPage.selectedIndex]
        if opt and opt.right then opt.right() end
    elseif playdate.buttonJustPressed(playdate.kButtonA) then
        local opt = settingsOptions[SettingsPage.selectedIndex]
        if opt and opt.isAction and opt.left then
            -- Clear Cookies: execute immediately
            opt.left()
        else
            -- Save & Close: apply all staged settings
            return SettingsPage.saveAndClose()
        end
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        -- Cancel & Close: discard all staged settings
        return SettingsPage.cancelAndClose()
    end

    return nil
end

function SettingsPage.draw()
    if not SettingsPage.isOpen then return end

    local elapsed = playdate.getCurrentTimeMilliseconds() - animStartMs
    local t = math.min(1.0, elapsed / ANIM_DURATION_MS)
    -- ease-out cubic
    t = 1 - (1 - t) * (1 - t) * (1 - t)

    local curW = math.max(1, math.floor(BOX_W * t))
    local curH = math.max(1, math.floor(BOX_H * t))
    local curX = math.floor(CENTER_X - curW / 2)
    local curY = math.floor(CENTER_Y - curH / 2)
    local r = math.floor(BOX_RADIUS * t)

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(curX, curY, curW, curH, r)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(curX, curY, curW, curH, r)

    if t > 0.4 then
        local fontH = Style.fontHeading2 or gfx.getFont()
        local fontBold = Style.fontBodyBold or gfx.getFont()
        local fontSmall = Style.fontSmall or Style.fontMono or gfx.getFont()

        gfx.pushContext()
        gfx.setClipRect(curX + 2, curY + 2, curW - 4, curH - 4)

        local innerX = curX + 16
        local innerY = curY + 10
        local innerW = curW - 32

        gfx.setColor(gfx.kColorBlack)
        gfx.setFont(fontH)
        gfx.drawText("SETTINGS", innerX, innerY)
        gfx.drawLine(innerX, innerY + 16, innerX + innerW, innerY + 16)

        local itemY = innerY + 24
        local itemH = 26

        for i, opt in ipairs(settingsOptions) do
            local iy = itemY + (i - 1) * (itemH + 4)
            local isSel = (i == SettingsPage.selectedIndex)

            if isSel then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(innerX - 4, iy, innerW + 8, itemH, 4)
                gfx.setColor(gfx.kColorWhite)
                gfx.drawRoundRect(innerX - 3, iy + 1, innerW + 6, itemH - 2, 3)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
            else
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
                gfx.setColor(gfx.kColorBlack)
            end

            gfx.setFont(fontBold)
            gfx.drawText(opt.label, innerX + 4, iy + 5)

            local val = opt.getValue()
            if val and val ~= "" then
                gfx.setFont(fontSmall)
                local valW = Style.getTextWidth(fontSmall, val)
                gfx.drawText(val, innerX + innerW - valW - 4, iy + 7)
            end

            if isSel and not opt.isAction then
                gfx.setFont(fontSmall)
                local valW = val and Style.getTextWidth(fontSmall, val) or 0
                gfx.drawText("<", innerX + innerW - valW - 18, iy + 7)
                gfx.drawText(">", innerX + innerW - 2, iy + 7)
            elseif isSel and opt.isAction then
                gfx.setFont(fontSmall)
                gfx.drawText("Press A", innerX + innerW - Style.getTextWidth(fontSmall, "Press A") - 4, iy + 7)
            end

            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        end

        local footerY = itemY + #settingsOptions * (itemH + 4) + 8
        gfx.setColor(gfx.kColorBlack)
        gfx.setFont(fontSmall)
        gfx.drawText("(B) Cancel  *  (A) Save & Close", innerX, footerY)

        gfx.popContext()
    end
end
