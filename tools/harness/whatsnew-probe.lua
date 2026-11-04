-- tools/harness/whatsnew-probe.lua
-- `Modules/Tools/WhatsNew.lua` 的**离线行为探针**（不是发行码，游戏里永不加载）。
--
-- 为什么单独一条：harness 只 pump 1 秒，而本模块的提示挂在 `C_Timer.After(3, …)` 上 ——
-- 也就是说 `run.js` 的红 0 对它是"没跑到"，不是"跑过没红"（本仓同一坑已犯过三次）。
-- 本探针把真文件 `loadfile` 进假环境，并**手动触发那颗定时器**，于是"打一次 / 不再打 /
-- 强制重看 / 无记录时不编内容 / 拿不到版本时不崩"都是真断言。
--
-- 跑法：node tools/whatsnew-probe.js   （或 lua tools/harness/whatsnew-probe.lua）
-- 退出码：全过 0，任一失败 1。

local probePath = arg and arg[0] or ...
local function norm(p) return (p or ""):gsub("\\", "/") end
local function RepoRoot()
    local p = norm(probePath)
    local i = p:find("tools/harness/whatsnew%-probe.lua$", 1)
    if i then return p:sub(1, i - 1) end
    return "./"
end
local root = RepoRoot()
local target = (arg and arg[1]) or (root .. "Modules/Tools/WhatsNew.lua")

local f = io.open(target, "rb")
if not f then
    print("[FAIL] 读不到 " .. tostring(target))
    os.exit(1)
end
local src = f:read("*a")
f:close()

-- ---------------------------------------------------------------- 假环境
local printed, db, timers, metaOK = {}, { }, {}, true
-- 注意：`local t = { f = function() t.x = 1 end }` 里 t 在自己的初始化表达式里**还不可见**
-- （Lua 的 local 要等语句结束才进作用域）—— 所以先声明再填字段，否则 Register 一调就炸。
local fakeNs = {}
fakeNs.Print = function(_, line) printed[#printed + 1] = tostring(line) end
fakeNs.DB = function() return db end
fakeNs.Register = function(_, name, mod) fakeNs._mod = mod; fakeNs._name = name end
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end }
C_AddOns = {
    GetAddOnMetadata = function(_, variable)
        if not metaOK then error("no metadata api") end
        if variable == "Version" then return "0.12.0" end
        return nil
    end,
}

local pass, failcount = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1; print("  [OK]   " .. label)
    else failcount = failcount + 1; print("  [FAIL] " .. label) end
end
local function any(sub)
    for _, line in ipairs(printed) do if line:find(sub, 1, true) then return true end end
    return false
end
local function fire()
    local n = #timers
    for i = 1, n do timers[i].fn() end
    timers = {}
end

local chunk, err = loadfile(target)
if not chunk then print("[FAIL] 编译失败：" .. tostring(err)) os.exit(1) end
chunk("MonetUI", fakeNs)
local M = fakeNs._mod

ok(M ~= nil and fakeNs._name == "WhatsNew", "注册发生，模块名 = WhatsNew（⇒ /mui whatsnew 走 Core 的模块名分发）")

-- 1. 首次登录：延迟一拍后打一次，且写 seen
printed = {}
M:Initialize()
ok(#timers == 1 and timers[1].delay == 3, "1 提示挂在 3 秒延迟上（不跟启动横幅挤在一起）")
fire()
ok(any("已更新到 0.12.0"), "2 版本变化时打出标题行")
local bullets = 0
for _, line in ipairs(printed) do if line:find("  · ", 1, true) then bullets = bullets + 1 end end
ok(bullets >= 3 and bullets <= 6, ("3 要点条数在 3–6 之间（实际 %d，太长没人读）"):format(bullets))
ok(any("/mui report"), "4 结尾给下一步动作（配置 / 出问题跑 report）")
ok(db.whatsNewSeen == "0.12.0", "5 记住「已看过」，落进 SavedVariables")

-- 6. 同版本不再打扰
printed = {}
M:Initialize()
fire()
ok(#printed == 0, "6 同一版本第二次登录不重复打")

-- 7. 手动重看有内容
printed = {}
ok(M:HandleCommand("show") == true and any("已更新到 0.12.0"), "7 /mui whatsnew 强制重看")
printed = {}
ok(M:HandleCommand("bogus") == false, "8 未知子命令交回 Core（不自己吞）")

-- 9. 没有该版本的记录 ⇒ 诚实一句，不编内容
db.whatsNewSeen = nil
local realMeta = C_AddOns.GetAddOnMetadata
C_AddOns.GetAddOnMetadata = function(_, variable)
    if variable == "Version" then return "9.9.9" end
    return nil
end
printed = {}
ok(M:HandleCommand("show") == true and any("没有单独的准备更新说明") and not any("  · "),
  "9 无该版本要点时只说一句，绝不现编内容")
C_AddOns.GetAddOnMetadata = realMeta

-- 10. 元数据 API 不可用 ⇒ 不崩、说清楚
metaOK = false
printed = {}
local okCall = pcall(function() M:HandleCommand("show") end)
ok(okCall and any("读不到本插件版本号"), "10 拿不到版本：不抛，且明说原因")
metaOK = true

-- 11. 关掉模块 ⇒ 抹掉"已看过"，重开能再看一次
db.whatsNewSeen = "0.12.0"
M:SetEnabled(false)
ok(db.whatsNewSeen == nil, "11 关闭模块后清掉已看过标记（重新开启才提示得到）")

-- 12/13. 静态边界：纯文本模块不许碰任何帧
local codeSrc = src:gsub("%-%-[^\n]*", "")
ok(not codeSrc:find("CreateFrame", 1, true) and not codeSrc:find("HookScript", 1, true)
   and not codeSrc:find("hooksecurefunc", 1, true) and not codeSrc:find("SetPoint", 1, true),
  "12 不建帧、不挂任何钩子（它是登录一次性的文本输出）")
ok(not src:find("TODO", 1, true) and not src:find("待补", 1, true), "13 文案里没有占位符")

-- 14. NOTES 形状：键是版本号、值全是非空字符串（防将来塞错类型把 Print 打断）
local notesChunk = src:match("local NOTES = (%{.-\n%})")
ok(notesChunk ~= nil, "14 NOTES 可定位（定位不到就是有人搬了写法，得同步改这条判据）")

print(("whatsnew-probe: %d 过 / %d 失"):format(pass, failcount))
os.exit(failcount == 0 and 0 or 1)
