-- 100% Pure On-Device Multi-Format Image Engine for CometBrowser
-- Uses HttpClient for sequential image downloads after page load.
import "core/url"
import "core/http_client"
import "core/tasks"
import "render/style"
import "render/decoders/dither"
import "render/decoders/bmp"
import "render/decoders/gif"
import "render/decoders/png"
import "render/decoders/svg"
import "render/decoders/jpeg"
import "render/decoders/ico"
import "render/decoders/webp"

ImageDecoder = {}
local gfx = playdate.graphics

-- In-memory cache: url -> playdate.graphics.image | false
local imageCache     = {}
local downloadQueue  = {}
local isDownloading  = false
local isDecoding     = false

function ImageDecoder.clearCache()
    imageCache    = {}
    downloadQueue = {}
    isDownloading = false
    isDecoding    = false
end

-- Decode raw image bytes. JPEG is run through the cooperative task scheduler
-- (its decode loop calls Tasks.yieldCheck()), so large photos decode across
-- frames without stalling the run loop; onDone(imgOrNil) fires when done.
local function decodeRawImageData(data, url, onDone)
    if not data or #data < 4 then
        onDone(nil)
        return
    end

    local b1, b2, b3, b4 = string.byte(data, 1, 4)

    -- JPEG: FF D8 (async, can take seconds for big photos)
    if b1 == 0xFF and b2 == 0xD8 then
        isDecoding = true
        Tasks.run(
            function()
                local ok, img = pcall(function() return JPEGDecoder.decode(data, 360, 200) end)
                if not ok then error(tostring(img)) end
                return img
            end,
            function(img)
                isDecoding = false
                onDone(img)
            end,
            function(err)
                isDecoding = false
                onDone(nil)
            end
        )
        return
    end

    -- PNG / GIF / WebP can also take seconds for large images on the physical
    -- device. Run them through the cooperative task scheduler (their decoders
    -- call Tasks.yieldCheck()) so the run loop never stalls; the Simulator is
    -- fast enough that the synchronous path never tripped the watchdog there.
    local asyncDecode = nil
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then -- PNG
        asyncDecode = function() return PNGDecoder.decode(data, 360, 200) end
    elseif string.sub(data, 1, 4) == "RIFF" and string.sub(data, 9, 12) == "WEBP" then -- WebP
        asyncDecode = function() return WebPDecoder.decode(data, 360, 200) end
    elseif string.sub(data, 1, 6) == "GIF87a" or string.sub(data, 1, 6) == "GIF89a" then -- GIF
        asyncDecode = function() return GIFDecoder.decode(data, 360, 200) end
    end

    if asyncDecode then
        isDecoding = true
        Tasks.run(
            function()
                local ok, img = pcall(asyncDecode)
                if not ok then error(tostring(img)) end
                return img
            end,
            function(img)
                isDecoding = false
                onDone(img)
            end,
            function(err)
                isDecoding = false
                onDone(nil)
            end
        )
        return
    end

    local img = nil

    -- BMP: BM
    if string.sub(data, 1, 2) == "BM" then
        local ok, r = pcall(function() return BMPDecoder.decode(data) end)
        if ok and r then img = r end
    -- ICO / CUR: reserved(2)=0, type(2)=1 icon / 2 cursor
    elseif b1 == 0 and b2 == 0 and (b3 == 1 or b3 == 2) and b4 == 0 then
        local ok, r = pcall(function() return ICODecoder.decode(data, 360, 200) end)
        if ok and r then img = r end
    -- SVG
    else
        local head = string.lower(string.sub(data, 1, 200))
        if string.find(head, "<svg") or string.find(head, "<?xml") then
            local ok, r = pcall(function() return SVGDecoder.decode(data, 360, 200) end)
            if ok and r then
                img = r
            elseif not ok then
            end
        end
    end

    onDone(img)
end

local function processNextImage()
    if isDownloading or isDecoding or #downloadQueue == 0 then return end

    -- Don't download images while the main page is loading
    if HttpClient.isLoading() then return end

    local url = table.remove(downloadQueue, 1)

    if imageCache[url] ~= nil then
        processNextImage()
        return
    end

    isDownloading = true

    HttpClient.get(url, {
        onSuccess = function(status, headers, body, finalUrl)
            if body and #body > 8 then
                decodeRawImageData(body, url, function(img)
                    imageCache[url] = img or false
                    isDownloading = false
                    playdate.timer.performAfterDelay(16, function()
                        processNextImage()
                    end)
                end)
            else
                imageCache[url] = false
                isDownloading = false
                playdate.timer.performAfterDelay(16, function()
                    processNextImage()
                end)
            end
        end,
        onError = function(err)
            imageCache[url] = false
            isDownloading = false
            playdate.timer.performAfterDelay(16, function()
                processNextImage()
            end)
        end
    })
end

function ImageDecoder.update()
    -- Called every frame from main.lua to pump the image download queue.
    -- If we think we're downloading but the HTTP client is idle, the download
    -- was cancelled (e.g. by a navigation) and its callbacks will never fire,
    -- so release the "busy" flag or the queue would stall forever.
    if isDownloading and not HttpClient.isLoading() then
        isDownloading = false
    end
    -- If a decode task was cancelled (navigation) its onDone never runs.
    if isDecoding and not Tasks.isRunning() then
        isDecoding = false
    end
    if not isDownloading and not isDecoding and #downloadQueue > 0 and not HttpClient.isLoading() then
        processNextImage()
    end
end

function ImageDecoder.enqueue(src)
    if not src or src == "" then return end
    if imageCache[src] ~= nil then return end
    for _, qu in ipairs(downloadQueue) do
        if qu == src then return end
    end
    table.insert(downloadQueue, src)
end

function ImageDecoder.evict(src)
    if src and imageCache[src] ~= nil then
        imageCache[src] = nil
    end
end

function ImageDecoder.isDecoded(src)
    if not src or src == "" then return false end
    local v = imageCache[src]
    return v ~= nil and v ~= false
end

function ImageDecoder.getImage(src)
    if not src or src == "" then return nil end
    local v = imageCache[src]
    if v and v ~= false then return v end
    return nil
end

-- Evict a single image from cache to free memory
function ImageDecoder.evict(src)
    if src and imageCache[src] ~= nil then
        imageCache[src] = nil
    end
end

-- Check if a specific image is cached (decoded or failed)
function ImageDecoder.isCached(src)
    return imageCache[src] ~= nil
end

-- Check if a specific image is cached and successful
function ImageDecoder.isDecoded(src)
    local c = imageCache[src]
    return c ~= nil and c ~= false
end

function ImageDecoder.draw(x, y, w, h, altText, href, isSelected, src)
    x = math.floor(x or 0)
    y = math.floor(y or 0)
    w = math.floor(math.max(w or 80, 40))
    h = math.floor(math.max(h or 40, 20))
    if w > 360 then w = 360 end
    if h > 180 then h = 180 end

    -- Try cache first
    if src and src ~= "" then
        local cached = imageCache[src]
        if cached and cached ~= false then
            -- Draw dithered image, scaled to fit box
            local iw, ih = cached:getSize()
            if iw > 0 and ih > 0 then
                local scaleX = w / iw
                local scaleY = h / ih
                local scale  = math.min(scaleX, scaleY)
                local dw     = math.floor(iw * scale)
                local dh     = math.floor(ih * scale)
                local dx     = x + math.floor((w - dw) / 2)
                local dy     = y + math.floor((h - dh) / 2)
                cached:drawScaled(dx, dy, scale)
            else
                cached:draw(x, y)
            end
            if isSelected then
                gfx.setColor(gfx.kColorBlack)
                gfx.setLineWidth(2)
                gfx.drawRoundRect(x, y, w, h, 4)
                gfx.setLineWidth(1)
            end
            return
        elseif cached == nil then
            ImageDecoder.enqueue(src)
        end
    end

    -- Draw Loading Placeholder Card
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(x, y, w, h, 4)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(x, y, w, h, 4)

    -- Hatch pattern
    for hx = x + 4, x + w - 4, 10 do
        gfx.drawLine(hx, y + 3, hx, y + h - 3)
    end

    -- Camera icon
    local iconX = x + math.floor(w / 2) - 8
    local iconY = y + math.floor(h / 2) - 6
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(iconX, iconY, 16, 11, 2)
    gfx.fillCircleAtPoint(iconX + 8, iconY + 5, 3)
    gfx.drawPixel(iconX + 13, iconY + 1)

    -- Alt text
    if altText and altText ~= "" and h > 30 then
        local font  = Style.fontSmall or gfx.getFont()
        gfx.setFont(font)
        local label = #altText > 26 and string.sub(altText, 1, 23) .. "..." or altText
        local lw    = Style.getTextWidth(font, label)
        local lx    = x + math.floor((w - lw) / 2)
        local ly    = iconY + 14
        if ly + 10 <= y + h - 2 then
            gfx.drawText(label, lx, ly)
        end
    end

    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- Test hook: run a buffer through the format dispatch and return the decoded
-- image (or nil) synchronously. Unused; JPEG/PNG/GIF/WebP now decode async
-- through the task scheduler and are not covered by this.
function ImageDecoder._testDecode(data)
    local result = nil
    decodeRawImageData(data, "test://", function(img) result = img end)
    return result
end
