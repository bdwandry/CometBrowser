-- File-based crash/event logger for CometBrowser.
-- Writes to the game's data folder:
--   Simulator: <pdx>/Data/com.bryanwandrych.cometbrowser/comet.log
--   Device:    /Data/com.bryanwandrych.cometbrowser/comet.log
-- Every line is written and the file closed immediately, so the log survives
-- even a hard crash.
import "CoreLibs/utilities/where"

Logger = {}

local LOG_PATH = "comet.log"
local seq = 0

local function nowString()
    local t = playdate.getTime()
    return string.format("%02d:%02d:%02d", t.hour, t.minute, t.second)
end

function Logger.init()
    local path = "unknown"
    pcall(function()
        local p = playdate.getPath()
        if p then path = tostring(p) end
    end)
    pcall(function()
        local f = playdate.file.open(LOG_PATH, playdate.file.kFileWrite)
        if f then
            f:write("=== CometBrowser crash log ===\n")
            f:write("gamePath: " .. path .. "\n")
            f:close()
        end
    end)
    seq = 0
    Logger.log("Logger initialized")
end

function Logger.log(msg)
    seq = seq + 1
    local line = string.format("[%s #%d] %s\n", nowString(), seq, tostring(msg))
    pcall(function()
        local f = playdate.file.open(LOG_PATH, playdate.file.kFileAppend)
        if f then
            f:write(line)
            f:close()
        end
    end)
end

function Logger.error(msg)
    local stack = ""
    pcall(function()
        local w = where()
        if w then stack = w end
    end)
    Logger.log("ERROR: " .. tostring(msg) .. "  ||  stack: " .. stack)
end
