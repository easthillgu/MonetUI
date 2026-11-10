-- tools/harness/bags-token-guard-probe.lua
-- 用法（项目根目录）：lua tools/harness/bags-token-guard-probe.lua
--
-- 回归目标（2026-11-10 作者实报）：在暴雪「货币 → 在背包显示」勾了任意货币后，
-- 按 B 能开背包却关不掉。实机隔离实验：
--   容器框全 Hide、BackpackTokenFrame 仍 IsShown=true → 分类窗保持开着；
--   再 Hide BackpackTokenFrame → 下一拍守卫立刻把分类窗全关掉。
-- 根因：BackpackTokenFrame 是 ContainerFrameCombinedBags 的子框，父框 Hide 不改变
-- 子框自身的 IsShown；它被算进 anyShown 后下降沿永远不来。
--
-- 本桩**抽取线上 Bags.lua 源码原文**执行守卫与扫查，不是照抄一份逻辑自己验自己；
-- 另加静态断言守住「停车仍覆盖货币条、只把边沿信号摘出去」这个修复边界。

local function read(path)
    local f = assert(io.open(path, "r"), "missing " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local function slice(src, from, upto)
    local a = assert(src:find(from, 1, true), "missing marker " .. from)
    local b = assert(src:find(upto, a, true), "missing marker " .. upto)
    return src:sub(a, b - 1)
end

local loader = loadstring or load
local failed = 0

local function check(name, ok, detail)
    if not ok then failed = failed + 1 end
    print((ok and "PASS " or "FAIL ") .. name
        .. (detail and ("  ->  " .. tostring(detail)) or ""))
end

local src = read("Modules/Bags/Bags.lua")

-- ==========================================================================
-- ① 静态断言：修复边界
-- ==========================================================================
local blizzardFrames = slice(src, "local function BlizzardBagFrames()",
    "local function IsBagSignalFrame(frame)")
check("BlizzardBagFrames 仍包含 BackpackTokenFrame（停车必须覆盖它）",
    blizzardFrames:find("BackpackTokenFrame", 1, true) ~= nil)

local signalGate = slice(src, "local function IsBagSignalFrame(frame)",
    "--- ✕ 的实际动作")
check("IsBagSignalFrame 显式排除 BackpackTokenFrame",
    signalGate:find("frame ~= _G.BackpackTokenFrame", 1, true) ~= nil)

local sweep = slice(src, "local function SweepBlizzardBags(allowMouse)",
    "-- ---- 暴雪银行框")
check("SweepBlizzardBags 的 anyShown 走 IsBagSignalFrame 门控",
    sweep:find("if isShown and IsBagSignalFrame(frame) then anyShown = true end", 1, true) ~= nil)
check("停车扫查仍遍历全部 BlizzardBagFrames（含货币条）",
    sweep:find("ipairs(BlizzardBagFrames())", 1, true) ~= nil
    and sweep:find("CollectTree(frame, sweepScratch)", 1, true) ~= nil)
check("停车补禁鼠标仍按 frame 而非信号源判定",
    sweep:find("if isShown and allowMouse then", 1, true) ~= nil)

local closeAll = slice(src, "CloseAllBags = function(mode)",
    "--- 收集 frame 及其全部 Frame 子代")
check("点 ✕ 收整套时只 Hide 真容器框（不替暴雪关货币条）",
    closeAll:find("if IsBagSignalFrame(frame) and frame.IsShown", 1, true) ~= nil)

local initialize = slice(src, "function M:Initialize()",
    "StartBlizzardGuard()")
check("登录复位 restoredOpen 只认真容器框",
    initialize:find("if IsBagSignalFrame(frame) and frame.IsShown", 1, true) ~= nil)

local guard = slice(src, "local function StartBlizzardGuard()",
    "-- ---- 更新触发")
check("守卫保持显式开/关边沿（不退化成 toggle）",
    guard:find("if anyShown == bagsVisualOpen then return end", 1, true) ~= nil
    and guard:find("M:Toggle(true)", 1, true) ~= nil
    and guard:find("M:Toggle(false)", 1, true) ~= nil)

-- ==========================================================================
-- ② 原文执行：扫查 + 守卫状态机
-- ==========================================================================
local unpack_ = table.unpack or unpack

local chunk = [[
local GUARD_INTERVAL = 0.2
local TOGGLE_DEBOUNCE = 0.12
local blizzardSubId, lastToggle = nil, 0
local bagsVisualOpen = false
local bankOpen = false
local shown = false
-- 实机 GetTime() 是进程启动至今的秒数（几百秒起），不会落在 lastToggle 的
-- 0.12s debounce 窗口里；桩从 0 起会把第一拍边沿误吃掉。
local now = 100
local function GetTime() return now end
local function InCombat() return false end
local parked = setmetatable({}, { __mode = "k" })
local sweepScratch = {}
local toggles = {}
local M = {}
function M:Toggle(force)
    if force == nil then shown = not shown else shown = force and true or false end
    toggles[#toggles + 1] = force
end
local ns = { IsModuleEnabled = function() return true end }
local guardFn
local Scheduler = {
    Every = function(_, _, fn) guardFn = fn; return 1 end,
    Unregister = function() end,
    EveryFrame = function() return 2 end,
}
local EventBus = { Register = function() end }

local unpack_ = table.unpack or unpack
local function Frame(name, isShown, alpha)
    return {
        _name = name, _shown = isShown, _alpha = alpha or 1, _mouse = true,
        IsShown = function(self) return self._shown end,
        GetAlpha = function(self) return self._alpha end,
        SetAlpha = function(self, a) self._alpha = a end,
        GetChildren = function(self) return unpack_({}) end,
        EnableMouse = function(self, v) self._mouse = v end,
        IsMouseEnabled = function(self) return self._mouse ~= false end,
    }
end

_G.ContainerFrame1 = Frame("ContainerFrame1", false)
_G.ContainerFrameCombinedBags = Frame("ContainerFrameCombinedBags", false)
_G.BackpackTokenFrame = Frame("BackpackTokenFrame", true)

-- 模拟模块已装载时的停车记账：货币条也要被压 alpha / 补禁鼠标。
parked[_G.ContainerFrame1] = { mouse = {}, mouseSet = {} }
parked[_G.ContainerFrameCombinedBags] = { mouse = {}, mouseSet = {} }
parked[_G.BackpackTokenFrame] = { mouse = {}, mouseSet = {} }

local FAILED = 0
local function check(name, ok, detail)
    if not ok then FAILED = FAILED + 1 end
    print((ok and "PASS " or "FAIL ") .. name
        .. (detail and ("  ->  " .. tostring(detail)) or ""))
end
]] .. blizzardFrames .. "\n" .. signalGate .. "\n"
   .. slice(src, "local function CollectTree(frame, into)", "--- 停车 / 取回") .. "\n"
   .. sweep .. "\n" .. guard .. [[

check("IsBagSignalFrame：真容器框算信号", IsBagSignalFrame(_G.ContainerFrame1) == true)
check("IsBagSignalFrame：货币条不算信号", IsBagSignalFrame(_G.BackpackTokenFrame) == false)
check("IsBagSignalFrame：nil 不算信号", IsBagSignalFrame(nil) == false)
check("BlizzardBagFrames 清单含 3 个框（含货币条）", #BlizzardBagFrames() == 3,
    "#=" .. #BlizzardBagFrames())

-- 实机形态：货币条常驻 shown，容器框全关。修复前 anyShown=true（关不掉），修复后 false。
local function setState(container, token)
    _G.ContainerFrame1._shown = container
    _G.ContainerFrameCombinedBags._shown = container
    _G.BackpackTokenFrame._shown = token
end

setState(false, true)
check("扫查：容器关 + 货币条常驻 → anyShown=false（下降沿能来）",
    SweepBlizzardBags(false) == false)
setState(true, true)
check("扫查：容器开 + 货币条常驻 → anyShown=true", SweepBlizzardBags(false) == true)
setState(true, false)
check("扫查：只有容器开 → anyShown=true", SweepBlizzardBags(false) == true)
setState(false, false)
check("扫查：全关 → anyShown=false", SweepBlizzardBags(false) == false)

-- 停车仍覆盖货币条：暴雪把 alpha 重设成 1，下一拍扫查要按回 0。
setState(false, true)
_G.BackpackTokenFrame._alpha = 1
SweepBlizzardBags(false)
check("停车仍把货币条 alpha 按回 0（修复没顺手删掉停车）",
    _G.BackpackTokenFrame._alpha == 0, "alpha=" .. tostring(_G.BackpackTokenFrame._alpha))

-- ---- 守卫状态机：完整复现「按 B 开 → 按 B 关」 -----------------------------
StartBlizzardGuard()
check("守卫已注册周期回调", type(guardFn) == "function")

local function tick(at, container, token)
    now = at
    setState(container, token)
    guardFn()
end

tick(100, true, true)                     -- 按 B 开：容器框 Show，货币条也 shown
check("开：分类窗被显式打开", shown == true and toggles[#toggles] == true,
    "shown=" .. tostring(shown))

tick(101, false, true)                    -- 按 B 关：容器框 Hide，货币条仍常驻
check("★ 关：货币条常驻也能拿到下降沿并关窗", shown == false
    and toggles[#toggles] == false,
    "shown=" .. tostring(shown) .. " lastToggle=" .. tostring(toggles[#toggles]))

local n = #toggles
tick(102, false, true)                    -- 停在关：不应反复 toggle
check("停在关：不重复触发 toggle", #toggles == n and shown == false,
    "#toggles=" .. #toggles)

tick(103, true, false)                    -- 只有容器框 Show（没勾货币显示的老场景）
check("老场景：只靠容器框仍能开", shown == true and toggles[#toggles] == true)
tick(104, false, false)
check("老场景：全 Hide 仍能关", shown == false and toggles[#toggles] == false)

-- debounce：0.12s 内的第二次边沿要被吃掉，避免重载抖动来回切。
tick(105, true, true)
local n2 = #toggles
now = 105.05
setState(false, true)
guardFn()
check("debounce：0.05s 内的下降沿被吞掉", #toggles == n2,
    "#toggles=" .. #toggles .. " shown=" .. tostring(shown))

return FAILED
]]

local compiled = assert(loader(chunk), "probe chunk 编译失败")
local runtimeFailed = compiled()
failed = failed + (runtimeFailed or 0)

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
