-- tools/harness/capability-probe.lua
-- N4 运行期能力表（`Utils/Compat.lua` 的 `Compat:Capability`）的行为探针。不是发行码。
--
-- 为什么单独一条：这张表是"模块判断这台客户端有没有 X"的唯一出口，而它最容易犯的三种错
-- 本仓全都栽过：① 把"读不出"塌成"没有"（`Secrets.CanMeasureHealth` 判例：血量整段空白）；
-- ② 在受限窗口里造探测框（自建 AuraContainer 判例：连环 ADDON_ACTION_BLOCKED）；
-- ③ 重复造框（探模板会真的跑模板 OnLoad）。这三条都是**行为**性质，静态 grep 看不见，
-- 所以把真文件 loadfile 进假环境、拿计数器证。
--
-- 跑法：node tools/capability-probe.js （或 lua tools/harness/capability-probe.lua）
-- 退出码：全过 0，任一失败 1。

local probePath = arg and arg[0] or ...
local function norm(p) return (p or ""):gsub("\\", "/") end
local function RepoRoot()
    local p = norm(probePath)
    local i = p:find("tools/harness/capability%-probe.lua$", 1)
    if i then return p:sub(1, i - 1) end
    return "./"
end
local root = RepoRoot()
local target = (arg and arg[1]) or (root .. "Utils/Compat.lua")

local f = io.open(target, "rb")
if not f then print("[FAIL] 读不到 " .. tostring(target)) os.exit(1) end
local src = f:read("*a")
f:close()

-- ---------------------------------------------------------------- 可控假环境
local state = {
    resolveThrows = false,   -- ResolveObject 抛错 = 受限/forbidden
    values = {},             -- path → 对象（nil = 没有）
    restricted = false,
    createCalls = 0,
    addonLoaded = false,
    addonLoadable = false,
    noAddOnApi = false,
}

local fakeNs = {}
-- 产品里是 `pcall(ns.ResolveObject, path)`（**点号调用**，没有 self），假实现必须同形，
-- 否则参数错位、整条探针都白跑（本仓判例：桩的元数/形状错会静默走到兜底分支）。
function fakeNs.ResolveObject(path)
    if state.resolveThrows then error("forbidden") end
    return state.values[path]
end
function fakeNs.IsRestricted() return state.restricted end

local fakeFrameMT = {}
function fakeFrameMT:GetScript() return nil end
local function newFakeFrame()
    return setmetatable({ SetShown = function() end, RegisterForClicks = function() end },
        { __index = function(_, k)
              if k == "SetPointerScript" or k == "PostClick" then return function() end end
              return nil
          end })
end

CreateFrame = function(_, _, _, tmpl)
    state.createCalls = state.createCalls + 1
    if tmpl and tmpl:find("SecureHandlerClickTemplate", 1, true) then return newFakeFrame() end
    return nil
end
C_AddOns = {
    IsAddOnLoaded = function() if state.noAddOnApi then error("no api") end return state.addonLoaded end,
    GetAddOnInfo = function() if state.noAddOnApi then error("no api") end
        return "X", "X", "", state.addonLoadable, "", "" end,
}
pcall(function() C_GameRules = { IsGameRuleActive = function() return false end } end)

local chunk, err = loadfile(target)
if not chunk then print("[FAIL] 编译失败：" .. tostring(err)) os.exit(1) end
chunk("MonetUI", fakeNs)
local Compat = fakeNs.Compat

local pass, failed = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1; print("  [OK]   " .. label)
    else failed = failed + 1; print("  [FAIL] " .. label) end
end

-- 1. 三态：有 / 没有 / 读不出
state.values["canaccessvalue"] = function() end
ok(Compat:Capability("secretGate") == true, "1 路径在 = true")
ok(Compat:Capability("secretProbe") == false, "2 路径不在 = false（不是 nil）")
state.resolveThrows = true
ok(Compat:Capability("scriptsAllowed") == nil, "3 ResolveObject 抛错 = nil（不知道），不是 false")
state.resolveThrows = false

-- 4. 「不知道」不许被 cache 成「没有」：恢复后同一 key 要能翻成 true
state.values["RunScript"] = function() end
ok(Compat:Capability("scriptsAllowed") == true, "4 之前读不出的条目恢复后能问到 true（nil 没进 cache）")

-- 5/6/7. 造实例类探测的三条纪律
state.restricted = true
local before = state.createCalls
ok(Compat:Capability("secureClickHandler") == nil, "5 受限窗口里不造实例，直接 nil")
ok(state.createCalls == before, "6 受限窗口里 CreateFrame 一次都没发生")
state.restricted = false
ok(Compat:Capability("secureClickHandler") == true, "7 不受限后真探到（造出来且方法在）")
local afterFirst = state.createCalls
ok(afterFirst == before + 1, "8 探测确实造了一个实例（不是猜的）")
for _ = 1, 5 do Compat:Capability("secureClickHandler") end
ok(state.createCalls == afterFirst, "9 一辈子只造一次（重复问不重复造框）")

-- 10/11/12/13. LoD 类 + cache 命中
state.addonLoaded = true
ok(Compat:Capability("auraContainerLoD") == true, "11 LoD 已加载 = true")
state.addonLoaded = false          -- 之后"变了"，但已 cache ⇒ 仍给 true（证明命中，不重复求值）
state.noAddOnApi = true            -- 若真的重新求值，这里会变成 nil/false
ok(Compat:Capability("auraContainerLoD") == true, "12 cache 命中：状态变了也不改口（不重复问客户端）")
state.noAddOnApi = false
state.values["C_RestrictedActions.InCombatLockdown"] = nil
ok(Compat:Capability("combatFlagNamespaced") == false,
   "13 名字不存在 = false（12.1.5 的 C_RestrictedActions.InCombatLockdown 正是这种）")
state.resolveThrows = false

-- 14. 未知能力名不编答案
local uv, un = Compat:Capability("madeUpThing")
ok(uv == nil and un == "未知能力名", "14 未知能力名：nil + 明确原因，绝不默认 false")

-- 15/16. 列能力表不许有副作用
state.createCalls = 0
local lines = Compat:ListCapabilities()
ok(type(lines) == "table" and #lines >= 8, "15 ListCapabilities 有条目")
ok(state.createCalls == 0, "16 列表不造任何实例（报告命令不许改变运行期状态）")

-- 17. 静态：Compat.lua 不许出现钩子/藏框
local codeSrc = src:gsub("%-%-[^\n]*", "")
ok(not codeSrc:find("HookScript", 1, true) and not codeSrc:find("Hide", 1, true)
   and not codeSrc:find("SetAttribute", 1, true),
   "17 能力层里没有钩子/藏框/写属性（它只负责问，不负责改）")

print(("capability-probe: %d 过 / %d 失"):format(pass, failed))
os.exit(failed == 0 and 0 or 1)
