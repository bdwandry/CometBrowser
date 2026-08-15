-- Storage & Datastore for CometBrowser (Bookmarks, History, Settings)
import "core/constants"

Storage = {}

local DATA_FILENAME = "comet_browser_data"

Storage.bookmarks = {}
Storage.history = {}
Storage.cookies = {}
Storage.settings = {
    searchEngine = 1,
    mode = Constants.MODE_RAW_HTML,
    autoReader = false,
    fontSize = "medium"
}

function Storage.init()
    local saved = playdate.datastore.read(DATA_FILENAME)
    if saved then
        if saved.bookmarks and #saved.bookmarks > 0 then
            Storage.bookmarks = saved.bookmarks
        else
            Storage.bookmarks = {}
            for _, b in ipairs(Constants.DEFAULT_BOOKMARKS) do
                table.insert(Storage.bookmarks, { title = b.title, url = b.url, desc = b.desc })
            end
        end
        if saved.history then
            Storage.history = saved.history
        end
        if saved.cookies then
            Storage.cookies = saved.cookies
        end
        if saved.settings then
            for k, v in pairs(saved.settings) do
                Storage.settings[k] = v
            end
        end
    else
        -- Load defaults
        Storage.bookmarks = {}
        for _, b in ipairs(Constants.DEFAULT_BOOKMARKS) do
            table.insert(Storage.bookmarks, { title = b.title, url = b.url, desc = b.desc })
        end
        Storage.save()
    end
end

function Storage.save()
    local data = {
        bookmarks = Storage.bookmarks,
        history = Storage.history,
        cookies = Storage.cookies,
        settings = Storage.settings
    }
    playdate.datastore.write(data, DATA_FILENAME, true)
end

function Storage.addHistory(title, url)
    if not url or url == "" or string.match(url, "^about:") then return end
    title = title or url
    
    -- Check if URL is already in history, remove old entry to move to top
    for i = #Storage.history, 1, -1 do
        if Storage.history[i].url == url then
            table.remove(Storage.history, i)
            break
        end
    end
    
    local timeFormatted = "Recent"
    pcall(function()
        local t = playdate.getTime()
        timeFormatted = string.format("%02d:%02d", t.hour, t.minute)
    end)
    
    table.insert(Storage.history, 1, {
        title = title,
        url = url,
        time = timeFormatted
    })
    
    -- Limit history to 50 items
    while #Storage.history > 50 do
        table.remove(Storage.history)
    end
    
    Storage.save()
end

function Storage.addBookmark(title, url, desc)
    if not url or url == "" then return false end
    title = title or url
    desc = desc or ""
    
    -- Check for duplicate
    for _, b in ipairs(Storage.bookmarks) do
        if b.url == url then
            b.title = title
            Storage.save()
            return true
        end
    end
    
    table.insert(Storage.bookmarks, {
        title = title,
        url = url,
        desc = desc
    })
    Storage.save()
    return true
end

function Storage.removeBookmark(index)
    if index and index >= 1 and index <= #Storage.bookmarks then
        table.remove(Storage.bookmarks, index)
        Storage.save()
        return true
    end
    return false
end

function Storage.isBookmarked(url)
    for _, b in ipairs(Storage.bookmarks) do
        if b.url == url then return true end
    end
    return false
end
