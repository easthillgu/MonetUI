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
--   4) 回调签名只能是 `(elapsed)` —— 本调度器投**一个**参数，不像 SetScript 的
--      `(self, elapsed)`。2026-11-07 判例：Cursor 把 OnUpdate 换成 EveryFrame 时签名没跟着改，
--      `_` 吃掉 dt、`elapsed` 恒 nil、`clock` 永不前进，拖尾整条消失、零报错零卡顿。
--      闸门：`node tools/scheduler-callback-probe.js`（R1 形参 ≤1 / R2 冒号方法不许裸名传）。

local ADDON_NAME, ns = ...

local Scheduler = {}
ns.Scheduler = Scheduler

--- 诊断数据面的版本号（`/mui perf` 会打出来）。每次改 Snapshot 行结构或账本语义就 +1，
--- 用途很具体：2026-11-07 出现过「以为装上了新代码、其实客户端还在跑旧版」的一轮误读
---（凭证：输出里没有新增的 `@ 文件:行` 字段）。有版本号就不必靠猜字段。
---   1 = 只有订阅明细 + 聚合
---   2 = 加外部驱动账（Profile / ExternalSnapshot）+ Snapshot 行带 where 来源
Scheduler.diagRev = 2

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

--- 外部计时账（#42 收尾，2026-11-07）。Widget 的三张 watch 表（hover / show / poll）
--- 不是本表的订阅 —— 它们各自建帧、没有 id 也没有 intervalSec —— 但同样要能在
--- `/mui perf` 里看到。**以前它们完全不可见**，于是"找最贵的一路"这个用途只对
--- 在册的几路成立（实测在册 3 路，而全仓自建 OnUpdate 驱动 50 处）。
--- 为什么另开一本而不是塞进 timings：Snapshot 的行格式按订阅写死（intervalSec /
--- everyFrame），混进字符串 key 会让 PrintStats 的 `%d` 直接抛错。数据面分开、打印时合并。
local external = {}   -- key -> { label, calls, cost, max }（秒）

local function RecordExternal(key, label, dt)
    local st = external[key]
    if not st then
        st = { label = label or tostring(key), calls = 0, cost = 0, max = 0 }
        external[key] = st
    end
    if not dt or dt <= 0 then dt = 0 end
    st.calls = st.calls + 1
    st.cost = st.cost + dt
    if dt > st.max then st.max = dt end
end

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

--- 计时源（#42，11-05 实机）：`GetTime()` 的粒度量不到一帧里的微小差值 ——
--- `/mui perf` 在 1.60 上每一路都是 `累计 0.000s · 峰值 0.000s`（18083 次调用全归零），
--- 于是"找最贵的一路"这个用途整个失效。这台客户端有 `debugprofilestop`
--- （实测 `type=function`、返回**毫秒**且带四位小数：`83597232.4398`）⇒ 优先用它，
--- 没有才退回 `GetTime`。两者都读不到就不计时，一个回调都不许因为仪表而抛。
local HaveProfileStop = type(_G.debugprofilestop) == "function"

local function Now()
    if HaveProfileStop then
        local ok, v = pcall(_G.debugprofilestop)
        if ok and type(v) == "number" then return v / 1000 end
    end
    if type(GetTime) == "function" then
        local ok, v = pcall(GetTime)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

--- 单路耗时。换源之后绝对值终于可信，但**排序找最贵的那一路**仍是主要用途。
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
    local before = Now()
    local ok, err
    if sub.intervalSec <= 0 then
        ok, err = pcall(sub.fn, elapsed)
    else
        ok, err = pcall(sub.fn)
    end
    local after = Now()
    RecordCost(id, (before and after) and (after - before) or nil)
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
--- 注册点来源（`文件:行`），只用于诊断：`/mui perf` 里 `#5` 这种编号本身说明不了任何事
---（2026-11-07 实机：#5 640 次调用累计 0.70s、平均 1.1ms/次，全仓没人知道它是谁）。
--- 实现走「对**函数**取定义位置」而不是「取栈层」：客户端 1.60 实测
--- `debug.getinfo(2, "Sl")` 拿不到调用者（where 全 nil），按函数取则拿到闭包的定义行 ——
--- 对定位一样够用（甚至更准：指向回调本体，而不是注册那一句）。
--- 仍然全程 pcall：拿不到就留 nil，绝不让诊断把注册流程带崩。
local function WhereOf(fn)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return nil end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then return nil end
    local src = info.short_src or info.source
    if type(src) ~= "string" or src == "" then return nil end
    -- 只留文件名，路径对读日志的人没有价值
    local name = src:match("[^\\/]+$") or src
    local line = tonumber(info.linedefined) or tonumber(info.currentline)
    if not line or line <= 0 then return name end
    return string.format("%s:%d", name, line)
end

--- 诊断能力自检（`/mui perf diag`）。上面那版按栈层取来源在本客户端返回空，
--- 事后靠猜；以后遇到「诊断字段是空的」，先跑这个看客户端到底给了什么。
function Scheduler:ProbeDebug()
    local out = {
        hasDebug = type(debug) == "table",
        hasGetinfo = (type(debug) == "table" and type(debug.getinfo) == "function"),
    }
    if not out.hasGetinfo then return out end
    local sample = function() return 1 end
    local okF, infoF = pcall(debug.getinfo, sample, "S")
    if okF and type(infoF) == "table" then
        out.fn = string.format("%s:%s", tostring(infoF.short_src), tostring(infoF.linedefined))
    else
        out.fn = "失败：" .. tostring(infoF)
    end
    local okL, infoL = pcall(debug.getinfo, 1, "Sl")
    if okL and type(infoL) == "table" then
        out.level = string.format("%s:%s", tostring(infoL.short_src), tostring(infoL.currentline))
    else
        out.level = "失败：" .. tostring(infoL)
    end
    return out
end

function Scheduler:Every(intervalMs, fn)
    if type(fn) ~= "function" then return nil end
    local id = nextSubId
    nextSubId = nextSubId + 1
    local sub = {
        intervalSec = (tonumber(intervalMs) or 0) / 1000,
        fn = fn,
        acc = 0,
        active = true,
        where = WhereOf(fn),
    }
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

--- 给「按需挂 / 摘的 OnUpdate 驱动」套一层计时壳（#42 收尾，2026-11-07）。
--- 为什么这些驱动不搬进订阅表：施法条、名板投射条、属性面板、滚动条拖动都是
--- **只在干活的那段时间存在**的每帧回调，搬成常驻订阅就变成空闲也每帧空转；
--- 但它们恰恰是战斗中最密的每帧路径，在 `/mui perf` 里完全看不见同样说不过去。
--- 于是：驱动照旧自己 `SetScript("OnUpdate", Scheduler:Profile(key, label, fn))`，
--- 挂上期间每一拍记一笔到 `external` 账（数据面与订阅表分开 —— Snapshot 的行格式
--- 按 intervalSec 写死，字符串 key 混进去会让 PrintStats 的 `%d` 直接抛错）。
--- 壳**不 pcall、不吞错、不改参数**：原回调抛错照旧冒到客户端，那是既有行为。
function Scheduler:Profile(key, label, fn)
    if not key or type(fn) ~= "function" then return fn end
    return function(...)
        local before = Now()
        fn(...)
        local after = Now()
        RecordExternal(key, label, (before and after) and (after - before) or nil)
    end
end

--- 外部驱动的数据面（`/mui perf` 与 PrintStats 读它）。按累计耗时排序。
function Scheduler:ExternalSnapshot()
    local rows = {}
    for key, st in pairs(external) do
        rows[#rows + 1] = {
            key = key,
            label = st.label,
            calls = st.calls,
            cost = st.cost,
            max = st.max,
        }
    end
    table.sort(rows, function(a, b) return a.cost > b.cost end)
    return rows
end

--- 清零全部计时账（订阅明细 + 聚合 + 外部驱动），**不动订阅本身**。
--- 为什么需要：峰值（max）是历史最高，改完一处想看"现在多少钱"时不清零就永远读的是旧尖峰。
--- 2026-11-07 InfoBar 内存块那次 24.5ms 就是靠清零前后对比才确认是它（累计约 2×24ms、
--- 其余 540 帧近乎 0 ⇒ 每 5 秒固定掉一帧）。
function Scheduler:ResetCosts()
    for id in pairs(timings) do timings[id] = nil end
    for id in pairs(failures) do failures[id] = nil end
    for key in pairs(external) do external[key] = nil end
    totals.calls, totals.cost, totals.failures = 0, 0, 0
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
            where = sub.where,
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
        -- 峰值六位小数：单次常在几十微秒，三位会全打成 0.000s（11-05 实测）
        print(("  #%d %s · 调用 %d · 累计 %0.4fs · 峰值 %0.6fs · 失败 %d%s"):format(
            row.id,
            row.everyFrame and "每帧" or ("%0.3fs"):format(row.intervalSec),
            row.calls, row.cost, row.max, row.failures,
            row.where and ("  @ " .. row.where) or ""))
    end
    local ext = self:ExternalSnapshot()
    if #ext > 0 then
        print(("  — 外部驱动 %d 路（按需挂摘，不进订阅表）—"):format(#ext))
        for i = 1, #ext do
            local row = ext[i]
            print(("  %s · 调用 %d · 累计 %0.4fs · 峰值 %0.6fs"):format(
                row.label, row.calls, row.cost, row.max))
        end
    end
    return #rows
end

return Scheduler
