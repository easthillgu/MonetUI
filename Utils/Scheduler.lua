-- Utils/Scheduler.lua
-- Unified frame-driven scheduler (batch B design, TODO 2.1).
-- One master frame replaces the ad-hoc `CreateFrame("Frame")` + `SetScript("OnUpdate")`
-- driver frames that each feature used to build for itself (Widget pulse, action-bar park
-- watch, minimap pins, combat text driver, ...). Subscriptions are interval-driven; an
-- intervalMs of <= 0 registers an "every frame" subscription whose callback receives the
-- master frame's elapsed time. The master frame shows when work exists and hides again
-- once the last subscription is gone, so an idle addon costs one hidden frame.

local ADDON_NAME, ns = ...

local Scheduler = {}
ns.Scheduler = Scheduler

local masterFrame = nil
local masterRunning = false
local subs = {}   -- id -> { intervalSec, fn, acc, active }
local nextSubId = 1

local function MasterTick(elapsed)
    for id, sub in pairs(subs) do
        if sub.active then
            sub.acc = sub.acc + elapsed
            if sub.intervalSec <= 0 or sub.acc >= sub.intervalSec then
                if sub.intervalSec <= 0 then
                    sub.fn(elapsed)
                    sub.acc = 0
                else
                    sub.acc = sub.acc - sub.intervalSec
                    sub.fn()
                end
            end
        end
    end
end

local function GetMaster()
    if not masterFrame then
        masterFrame = CreateFrame("Frame")
        masterFrame:Hide()
        masterFrame:SetScript("OnUpdate", function(_, elapsed) MasterTick(elapsed) end)
    end
    return masterFrame
end

local function EnsureRunning()
    local f = GetMaster()
    if masterRunning then return end
    masterRunning = true
    f:Show()
end

--- `intervalMs` 是**毫秒**（调用点都按毫秒写），而 OnUpdate 给的 `elapsed` 是**秒** ——
--- 所以在这里换算一次存成秒。以前直接把 250 当阈值存进去，和秒级累加器比，
--- 等于"250 秒一次"：姓名板守卫和鼠标提示兜底扫描都写的是 250，实际几分钟才跑一拍，
--- 而且不报错、看起来还在工作（AGENTS：单位混用的症状不是"差一点"）。
function Scheduler:Every(intervalMs, fn)
    if type(fn) ~= "function" then return nil end
    local id = nextSubId
    nextSubId = nextSubId + 1
    subs[id] = { intervalSec = (intervalMs or 0) / 1000, fn = fn, acc = 0, active = true }
    EnsureRunning()
    return id
end

function Scheduler:EveryFrame(fn)
    return self:Every(0, fn)
end

function Scheduler:Unregister(id)
    subs[id] = nil
    if next(subs) == nil then
        if masterFrame and masterFrame:IsShown() then masterFrame:Hide() end
        masterRunning = false
    end
end

function Scheduler:StopAll()
    for id in pairs(subs) do subs[id] = nil end
    if masterFrame and masterFrame:IsShown() then masterFrame:Hide() end
    masterRunning = false
end

function Scheduler:Count()
    local n = 0
    for _ in pairs(subs) do n = n + 1 end
    return n
end

return Scheduler
