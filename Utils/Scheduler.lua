-- Utils/Scheduler.lua
-- Unified frame-driven scheduler (batch B design, TODO 2.1).
-- One master frame replaces the ad-hoc `CreateFrame("Frame")` + `SetScript("OnUpdate")`
-- driver frames that each feature used to build for itself (Widget pulse, action-bar park
-- watch, minimap pins, combat text driver, ...). Subscriptions are interval-driven; an
-- intervalMs of <= 0 registers an "every frame" subscription whose callback receives the
-- master frame's elapsed time. The master frame shows when work exists and hides again
-- once the last subscription is gone, so an idle addon costs one hidden frame.
--
-- 三条纪律（2026-11-03 上线前补的）：
--   1) 回调一律 pcall 包住：一个订阅抛错不能吞掉同拍其余订阅（以前姓名板守卫一抛，
--      鼠标提示的兜底扫描当拍就没跑）。失败只印第一条 + 第二条说明"后续被静默"，
--      计数留着给诊断读 —— 照 EventBus 的做法，不刷屏。
--   2) 回调里再注册订阅 = 遍历中往表里插键，Lua 5.1 明说是未定义行为。新订阅先攒进
--      `pending`，下一拍并入，本拍不跑。
--   3) 单位只在入口换算一次：`intervalMs` 收毫秒、`elapsed` 是秒（历史 bug 745164a）。

local ADDON_NAME, ns = ...

local Scheduler = {}
ns.Scheduler = Scheduler

local masterFrame = nil
local masterRunning = false
local subs = {}   -- id -> { intervalSec, fn, acc, active }
local pending = {}   -- 本拍注册的订阅（下一拍才并入 subs）
local nextSubId = 1
local ticking = false

local failures = {}   -- id -> 这一路被静默掉的失败次数
local timings = {}    -- id -> { calls, cost, max }（秒）

-- 聚合账：逐路明细在注销时删掉（id 单调递增，留着就是每次注册攒一行垃圾永不回收），
-- 总数留在 totals 里，`Scheduler:Count()` 的第二返回值读它。
local totals = { calls = 0, cost = 0, failures = 0 }

local function HasWork()
    return next(subs) ~= nil or next(pending) ~= nil
end

local function ReportFailure(id, err)
    local n = (failures[id] or 0) + 1
    failures[id] = n
    totals.failures = totals.failures + 1
    if n == 1 then
        print("|cffff6b6b[MonetUI]|r Scheduler 订阅 #" .. tostring(id) .. ": " .. tostring(err))
    elseif n == 2 then
        -- 第二条才说"后面的不再打印"：只静默、什么都不提示，会让人以为错误只发生了一次。
        print("|cffff6b6b[MonetUI]|r 订阅 #" .. tostring(id) .. " 的失败会继续被静默（同一订阅只提示两次）")
    end
end

--- 单路耗时。`GetTime` 的精度不够量一帧里的微小差值，所以这套数字只用来**排序找最贵的那一路**，
--- 绝对值要实机核。
local function RecordCost(id, dt)
    if not dt or dt <= 0 then dt = 0 end
    local st = timings[id]
    if not st then
        st = { calls = 0, cost = 0, max = 0 }
        timings[id] = st
    end
    st.calls = st.calls + 1
    st.cost = st.cost + dt
    if dt > st.max then st.max = dt end
    totals.calls = totals.calls + 1
    totals.cost = totals.cost + dt
end

--- pcall 在这里、不在调用点：一个订阅的失败不能影响同拍其余订阅。
--- 保持原有语义：每帧订阅收 elapsed，定频订阅**不收参数**（有的回调看 `...`）。
local function Invoke(id, sub, elapsed)
    local before = GetTime and GetTime() or nil
    local ok, err
    if sub.intervalSec <= 0 then
        ok, err = pcall(sub.fn, elapsed)
    else
        ok, err = pcall(sub.fn)
    end
    RecordCost(id, before and (GetTime() - before) or nil)
    if not ok then ReportFailure(id, err) end
end

local function MasterTick(elapsed)
    ticking = true
    if next(pending) ~= nil then
        local fresh = pending
        pending = {}
        for id, sub in pairs(fresh) do
            -- 注册完又被自己摘掉的（active=false）不并入。
            if sub.active then subs[id] = sub end
        end
    end
    for id, sub in pairs(subs) do
        if sub.active then
            sub.acc = sub.acc + elapsed
            if sub.intervalSec <= 0 or sub.acc >= sub.intervalSec then
                if sub.intervalSec <= 0 then
                    sub.acc = 0
                    Invoke(id, sub, elapsed)
                else
                    sub.acc = sub.acc - sub.intervalSec
                    Invoke(id, sub, nil)
                end
            end
        end
    end
    ticking = false
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

--- 没事可做就收帧。pending 也算活：主帧藏了，攒着的订阅就永远并不进来。
local function SyncRunning()
    if HasWork() then
        EnsureRunning()
        return
    end
    if masterFrame and masterFrame:IsShown() then masterFrame:Hide() end
    masterRunning = false
end

--- `intervalMs` 是**毫秒**（调用点都按毫秒写），而 OnUpdate 给的 `elapsed` 是**秒** ——
--- 所以在这里换算一次存成秒。以前直接把 250 当阈值存进去，和秒级累加器比，
--- 等于"250 秒一次"：姓名板守卫和鼠标提示兜底扫描都写的是 250，实际几分钟才跑一拍，
--- 而且不报错、看起来还在工作（AGENTS：单位混用的症状不是"差一点"）。
function Scheduler:Every(intervalMs, fn)
    if type(fn) ~= "function" then return nil end
    local id = nextSubId
    nextSubId = nextSubId + 1
    local sub = { intervalSec = (tonumber(intervalMs) or 0) / 1000, fn = fn, acc = 0, active = true }
    if ticking then
        -- 遍历中插键是未定义行为：延后一拍生效（纪律 2）。
        pending[id] = sub
    else
        subs[id] = sub
    end
    EnsureRunning()
    return id
end

function Scheduler:EveryFrame(fn)
    return self:Every(0, fn)
end

function Scheduler:Unregister(id)
    if not id then return end
    -- 两张表都要查：可能是本拍刚注册、还没并进来的那一路。
    local sub = pending[id]
    pending[id] = nil
    if sub then sub.active = false end
    sub = subs[id]
    subs[id] = nil
    if sub then sub.active = false end
    -- 明细跟着订阅走，聚合账留着。
    timings[id] = nil
    failures[id] = nil
    SyncRunning()
end

function Scheduler:StopAll()
    for id, sub in pairs(subs) do sub.active = false subs[id] = nil end
    for id, sub in pairs(pending) do sub.active = false pending[id] = nil end
    SyncRunning()
end

--- 在册订阅数。第二个返回值是聚合账（老调用点只接一个，行为不变）。
function Scheduler:Count()
    local n = 0
    for _ in pairs(subs) do n = n + 1 end
    local waiting = 0
    for _ in pairs(pending) do waiting = waiting + 1 end
    return n, {
        running = n,
        pending = waiting,
        calls = totals.calls,
        cost = totals.cost,
        failures = totals.failures,
    }
end

--- 逐路数据面（`/mui perf` 命令本体不在这次范围内，先把账做出来）。
--- 按累计耗时排序，最贵的在最前面；只读，不改任何状态。
function Scheduler:Snapshot()
    local rows = {}
    for id, sub in pairs(subs) do
        local st = timings[id] or { calls = 0, cost = 0, max = 0 }
        rows[#rows + 1] = {
            id = id,
            intervalSec = sub.intervalSec,
            everyFrame = sub.intervalSec <= 0,
            active = sub.active,
            calls = st.calls,
            cost = st.cost,
            max = st.max,
            failures = failures[id] or 0,
        }
    end
    table.sort(rows, function(a, b) return a.cost > b.cost end)
    local waiting = 0
    for _ in pairs(pending) do waiting = waiting + 1 end
    return rows, {
        running = #rows,
        pending = waiting,
        calls = totals.calls,
        cost = totals.cost,
        failures = totals.failures,
    }
end

--- 把账印出来（诊断入口；一次印完，调用点自己决定何时触发）。
function Scheduler:PrintStats()
    local rows, stats = self:Snapshot()
    print(("|cffbebfb3[MonetUI] Scheduler|r 在册 %d · 等一拍 %d · 累计调用 %d 次 / %0.3f 秒 · 被静默的失败 %d")
        :format(stats.running, stats.pending, stats.calls, stats.cost, stats.failures))
    for i = 1, #rows do
        local row = rows[i]
        print(("  #%d %s · 调用 %d · 累计 %0.3fs · 峰值 %0.3fs · 失败 %d"):format(
            row.id,
            row.everyFrame and "每帧" or ("%0.3fs"):format(row.intervalSec),
            row.calls, row.cost, row.max, row.failures))
    end
    return #rows
end

return Scheduler
