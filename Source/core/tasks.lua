-- Cooperative Task Scheduler for CometBrowser.
--
-- Heavy work (HTML tokenizing, DOM building, readability extraction, layout)
-- is run inside a coroutine that pauses whenever a single frame has consumed
-- its CPU budget. This keeps every update() far below the ~10 second "Run
-- loop stalled" watchdog, so pages like Wikipedia that take many seconds to
-- parse on the physical Playdate no longer crash the app (the Simulator is
-- fast enough that they never tripped the watchdog there).

if Tasks ~= nil then return end

Tasks = {}

-- The 10s "Run loop stalled" watchdog only fires when a single frame blocks
-- that long. Chunking the parse into ~500ms slices is 20x under that limit and
-- keeps the renderer at (near) full speed: wall-clock time ≈ actual parse CPU
-- time instead of being throttled by a tiny 25ms slice per 33ms frame.
local FRAME_BUDGET_MS = 500   -- max milliseconds of heavy work per frame
local CHECK_EVERY     = 64    -- check the clock only every N loop iterations

local counter      = 0
local frameStartMs = 0
local inside       = false
local queue        = {}
local gcPending    = false
local progressValue = 0

-- Call from the hot loops of any heavy work. On the Playdate, coroutine.yield
-- is only legal inside a coroutine we resume, so when called outside a task
-- (plain synchronous parsing) this is a no-op.
function Tasks.yieldCheck()
    counter = counter + 1
    if counter >= CHECK_EVERY then
        counter = 0
        if inside and playdate.getCurrentTimeMilliseconds() - frameStartMs >= FRAME_BUDGET_MS then
            coroutine.yield()
        end
    end
end

-- Report monotonic progress of the running task as a fraction in [0,1].
-- Fractional progress is ignored so the bar can never move backwards.
function Tasks.reportProgress(f)
    if f > 1 then f = 1 elseif f < 0 then f = 0 end
    if f > progressValue then progressValue = f end
end

function Tasks.getProgress()
    return progressValue
end

-- Schedule a coroutine task. fn should call Tasks.yieldCheck() in its hot
-- loops. onComplete(result) runs when the task finishes normally;
-- onError(message) runs if it raises an error.
function Tasks.run(fn, onComplete, onError)
    progressValue = 0
    table.insert(queue, {
        co = coroutine.create(fn),
        onComplete = onComplete,
        onError = onError,
        result = nil
    })
end

function Tasks.isRunning()
    return #queue > 0
end

-- Drop any in-flight tasks. Used when the user navigates away mid-render.
function Tasks.cancelAll()
    if #queue > 0 then
        queue = {}
        progressValue = 0
        gcPending = true
    end
end

-- Ask the scheduler to drain the garbage collector a little each frame, so the
-- large temporaries left over from parsing a page are reclaimed without a
-- single full collection stalling the run loop for seconds on device.
function Tasks.scheduleGC()
    gcPending = true
end

-- Advance the head task by one frame's worth of work, then drain a little GC.
-- Called once per frame from the main update loop.
function Tasks.update()
    if #queue > 0 then
        frameStartMs = playdate.getCurrentTimeMilliseconds()
        local task = queue[1]

        inside = true
        local ok, result = coroutine.resume(task.co)
        inside = false

        if ok then
            task.result = result
            if coroutine.status(task.co) == "dead" then
                progressValue = 1
                table.remove(queue, 1)
                Tasks.scheduleGC()
                if task.onComplete then
                    pcall(task.onComplete, task.result)
                end
            end
        else
            table.remove(queue, 1)
            Tasks.scheduleGC()
            if task.onError then
                pcall(task.onError, tostring(result))
            end
        end
    end

    -- Spread forced GC across frames instead of one big pause.
    if gcPending then
        local done = pcall(function()
            for _ = 1, 4 do
                if collectgarbage("step") then return true end
            end
            return false
        end)
        if done then gcPending = false end
    end
end
