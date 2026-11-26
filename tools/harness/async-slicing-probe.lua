-- async-slicing-probe.lua
-- 用真实 Utils/Async.lua + 模拟 Lua 5.1 协程 API / Scheduler 验证按帧切片。
--   lua tools/harness/async-slicing-probe.lua
-- 时钟由 perItem 显式推进，不依赖真实耗时；Scheduler 回调按 fn(elapsed) 投参。

local root = arg[1] or "."
local source = root .. "/Utils/Async.lua"

local function world()
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local clock = 0
    env.debugprofilestop = function() return clock end

    -- WoW 是 Lua 5.1：主线程 running() 只返回 nil，且没有 isyieldable。
    -- 在 5.4 上保留真实协程实现，只把 running 的返回值收窄成 5.1 形状。
    local coroutine51 = {
        create = coroutine.create,
        resume = coroutine.resume,
        status = coroutine.status,
        yield = coroutine.yield,
        running = function()
            local co, isMain = coroutine.running()
            if isMain then return nil end
            return co
        end,
    }
    env.coroutine = coroutine51

    local scheduler = { unregisters = 0 }
    function scheduler:EveryFrame(fn, label)
        assert(label == "异步:任务驱动", "EveryFrame 缺少显式标签")
        self.driver = fn
        return 1
    end
    function scheduler:Unregister(id)
        assert(id == 1, "摘错了驱动订阅号")
        self.driver = nil
        self.unregisters = self.unregisters + 1
    end
    env.Scheduler = scheduler

    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = assert(loadfile(source))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile(source, "t", env))
    end
    local Async = chunk("MonetUI", { Scheduler = scheduler })

    local function advance(ms) clock = clock + ms end
    local function tick()
        assert(scheduler.driver, "驱动已提前摘掉")
        scheduler.driver(1 / 60) -- 真实 Scheduler:EveryFrame 只投一个 elapsed
    end
    return env, Async, scheduler, advance, tick
end

local env, Async, scheduler, advance, tick = world()
assert(rawget(env.coroutine, "isyieldable") == nil, "探针必须模拟没有 isyieldable 的 Lua 5.1")
advance(1000)
Async.Checkpoint() -- 主线程即使已超预算也不能 yield

local list, visited, perTick, doneCalls, doneList = {}, {}, {}, 0, nil
for i = 1, 10 do list[i] = "item-" .. i end
local handle = Async:Each(list, function(item, index)
    assert(item == list[index], "perItem 参数顺序改变")
    visited[index] = item
    advance(3) -- 每帧预算 12ms：第 4 / 8 项必须 yield
end, function(done)
    doneCalls = doneCalls + 1
    doneList = done
end, "slicing-probe")
assert(handle and Async:Count() == 1, "Each 没有创建任务")

while scheduler.driver do
    local before = #visited
    tick()
    perTick[#perTick + 1] = #visited - before
end

local activeTicks, maxPerTick = 0, 0
for _, count in ipairs(perTick) do
    if count > 0 then activeTicks = activeTicks + 1 end
    if count > maxPerTick then maxPerTick = count end
end
assert(#visited == 10, "列表没有完整迭代")
assert(activeTicks == 3 and maxPerTick == 4,
    "没有按帧切片: ticks=" .. activeTicks .. " max=" .. maxPerTick)
assert(doneCalls == 1 and doneList == list, "onDone 语义改变")
assert(Async:Count() == 0 and scheduler.unregisters == 1, "完成后没有清理驱动")
print("PASS Async:Each Lua 5.1 多帧切片 counts=[4,4,2], activeTicks=3")

-- 单项异常仍由 Async:Each 的 pcall 隔离，后续项与 onDone 必须继续。
local errors = 0
env.print = function(message)
    assert(message:find("第 2 项失败", 1, true), "异常归因不正确")
    errors = errors + 1
end
local afterError = 0
Async:Each({ "a", "b", "c" }, function(_, index)
    advance(20)
    if index == 2 then error("expected item failure") end
    afterError = afterError + 1
end, function() afterError = afterError + 1 end, "error-probe")
while scheduler.driver do tick() end
assert(errors == 1 and afterError == 3, "单项异常吞掉了后续项或 onDone")
print("PASS Async:Each 单项异常隔离与 onDone 回调语义")
print("ALL PASS")
