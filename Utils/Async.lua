-- Utils/Async.lua
-- 按帧预算的协程任务器（#38，2026-11-06）。
--
-- 为什么需要：Utils/Scheduler 只有"定时"（Every / EveryFrame），切不了**万次扫描** ——
-- 背包全量重扫、换皮深扫、EnumerateFrames 类全扫（Compat:Find 走 1.5 万个框）都是
-- "整帧跑完"的形状，一卡就是一帧掉帧。这个把长任务切成"每帧最多花 BUDGET_MS 毫秒，
-- 超了就 yield 到下一帧"，空闲时把驱动摘掉（复用 Scheduler 的主帧，不额外建 OnUpdate 框）。
--
-- 三条纪律（都是本仓踩过的）：
--   ① **perItem 里碰游戏来的值先过 Secrets 漏斗**（调用点负责；任务器不替你判 ——
--      判例：RurutiaSuite 在 UnitAura 的 expirationTime/spellID 上直接算术并当表键会炸）。
--   ② 计时用 `debugprofilestop`（毫秒，#42 那条：GetTime 量不到帧内小差值），没有才退 GetTime。
--   ③ 协程里 pcall 包住每一项：一项抛错不能吞掉整个任务，也不能吞掉同帧其余任务。
local ADDON_NAME, ns = ...

local Scheduler = ns.Scheduler
local Async = {}
ns.Async = Async

local BUDGET_MS = 12          -- 每帧给异步任务的总预算（毫秒）
local jobs = {}               -- 活动任务
local driverId = nil          -- Scheduler:EveryFrame 的订阅号
local frameDeadline = 0       -- 本帧允许的耗时上限（毫秒），驱动每拍刷新

local function NowMs()
    if type(_G.debugprofilestop) == "function" then
        local ok, v = pcall(_G.debugprofilestop)
        if ok and type(v) == "number" then return v end
    end
    if type(_G.GetTime) == "function" then
        local ok, v = pcall(_G.GetTime)
        if ok and type(v) == "number" then return v * 1000 end
    end
    return 0
end

--- 任务体里调它：预算用完就 yield 到下一帧（下一拍驱动会再 resume 回来）。
--- 不在协程里调（没在 resume 中）时是空操作，调用点不必判断。
local function Checkpoint()
    if coroutine.isyieldable and coroutine.isyieldable() and NowMs() >= frameDeadline then
        coroutine.yield("wait")
    end
end
Async.Checkpoint = Checkpoint

local function StopDriver()
    if driverId and Scheduler then
        Scheduler:Unregister(driverId)
        driverId = nil
    end
end

local function EnsureDriver()
    if driverId or not Scheduler then return end
    driverId = Scheduler:EveryFrame(function()
        frameDeadline = NowMs() + BUDGET_MS
        local i = 1
        while i <= #jobs do
            local job = jobs[i]
            if coroutine.status(job.co) == "dead" then
                table.remove(jobs, i)
                if job.onDone then pcall(job.onDone) end
            else
                local ok, err = coroutine.resume(job.co)
                if not ok then
                    -- 协程本体抛错（不是 perItem 的 pcall 漏网）：报一次，丢掉这个任务，别卡死驱动。
                    print("|cffff6b6b[MonetUI]|r Async 任务 " .. tostring(job.name or "?") .. " 异常: " .. tostring(err))
                    table.remove(jobs, i)
                else
                    i = i + 1
                end
            end
            -- 帧预算用尽：本帧不再 resume 更多任务，下一帧继续。
            if NowMs() >= frameDeadline then break end
        end
        if #jobs == 0 then StopDriver() end
    end)
end

--- 通用作业：body 是个会在合适处调 Checkpoint() 的函数，用协程切片跑。
--- onDone 可省；name 只用于报错归因。返回一个可 Cancel 的句柄。
function Async:Run(body, onDone, name)
    if type(body) ~= "function" then return nil end
    local job = { co = coroutine.create(body), onDone = onDone, name = name }
    jobs[#jobs + 1] = job
    job.Cancel = function()
        for i, j in ipairs(jobs) do if j == job then table.remove(jobs, i); break end end
        if #jobs == 0 then StopDriver() end
    end
    EnsureDriver()
    return job
end

--- 列表切片迭代：对 list 每项调 perItem(item, index)，按帧预算分批跑，跑完 onDone(list)。
--- 这是"万次扫描"最常用的形状（EnumerateFrames 收集到的数组、背包格、皮肤帧）。
--- 同一 list 重复 Each 会各起一个任务；调用点自己防重入。
function Async:Each(list, perItem, onDone, name)
    if type(list) ~= "table" or type(perItem) ~= "function" then
        if onDone then pcall(onDone, list) end
        return nil
    end
    local n = #list
    if n == 0 then
        if onDone then pcall(onDone, list) end
        return nil
    end
    local idx = 0
    local job = self:Run(function()
        while idx < n do
            idx = idx + 1
            local ok, err = pcall(perItem, list[idx], idx)
            if not ok then
                print("|cffff6b6b[MonetUI]|r Async:Each " .. tostring(name or "?") ..
                      " 第 " .. tostring(idx) .. " 项失败: " .. tostring(err))
            end
            Checkpoint()
        end
    end, function() if onDone then pcall(onDone, list) end end, name)
    return job
end

--- 诊断用：当前在跑的任务数。
function Async:Count() return #jobs end

return Async
