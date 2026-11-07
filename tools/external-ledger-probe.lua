-- tools/external-ledger-probe.lua
-- 「外部驱动账」行为闸门（Scheduler:Profile / ExternalSnapshot / PrintStats 外部段）。
-- 为什么需要它：这批驱动（施法条 / 名板投射 / 属性面板 / 信息栏逐块 / 滚动条拖动）**不进订阅表**，
-- 常驻订阅会让空闲也每帧空转；它们只在干活时挂着 SetScript。若壳写错（吞错、改写实参、
-- 不记账、key 撞车），症状同样是「/mui perf 里什么都没有」——和 Cursor 那次一样是静默失效。
--
-- 用桩件加载**真实** Utils/Scheduler.lua（不是复制一份逻辑），验证：
--   1) 壳转发全部实参（含 (self, elapsed) 两参形态）且不往回调外塞返回值
--   2) 每拍记一次账，calls/cost/max 累加正确
--   3) ExternalSnapshot 按累计耗时降序、label 落账
--   4) PrintStats 不抛错（含外部段）
--   5) 非函数 / 无 key 入参原样返回（调用点写错不该崩）
--
-- 跑法：lua tools/external-ledger-probe.lua    退出码 0 = 全绿
-- 依赖：lua 5.4（loadfile 的三参 env 形态）；无第三方库。

local env = setmetatable({}, { __index = _G })
env._G = env

local fakeTime = 0
env.debugprofilestop = function()
  fakeTime = fakeTime + 0.002 -- 每读一次前进 2ms：一次回调 = before/after 两次读 = 4ms
  return fakeTime * 1000
end
env.GetTime = function() return 0 end

local frameStub = {
  SetScript = function() end,
  GetScript = function() end,
  Hide = function() end,
  Show = function() end,
  IsShown = function() return false end,
}
env.CreateFrame = function() return frameStub end

local chunk = assert(loadfile("Utils/Scheduler.lua", "t", env))
local ns = {}
chunk("MonetUI", ns)
local S = assert(ns.Scheduler, "ns.Scheduler 未导出")

local fail = 0
local function check(name, cond, extra)
  if not cond then
    print("  ✗ " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    fail = fail + 1
  else
    print("  ✓ " .. name)
  end
end

-- 1) 转发实参 + 返回值不掺水
local got = {}
local wrapped = S:Profile("k2", "第二路", function(...)
  local n = select("#", ...)
  for i = 1, n do got[i] = select(i, ...) end
  return "RET"
end)
local a, b = {}, 0.016
wrapped(a, b)
check("壳转发两个实参（(self, elapsed) 形态不被改写）", got[1] == a and got[2] == b, tostring(got[1]) .. "/" .. tostring(got[2]))
local nret = select("#", wrapped(a, b))
check("壳不往回调外塞返回值（OnUpdate 不关心，但不能掺东西）", nret == 0, "长度 " .. nret)

-- 2) 记账（上面已调用 3 次：第一次 + 返回值检查两次里的第一次）
wrapped(a, b)
local ext = S:ExternalSnapshot()
check("外部账只有登记过的一路", #ext == 1, #ext)
check("调用次数 = 3", ext[1].calls == 3, ext[1].calls)
check("label 落账", ext[1].label == "第二路", ext[1].label)
check("累计耗时 > 0", ext[1].cost > 0, ext[1].cost)
check("峰值 <= 累计", ext[1].max <= ext[1].cost, ext[1].max)

-- 3) 排序：再造一路更贵的
local heavy = S:Profile("k1", "第一路", function()
  for _ = 1, 3 do fakeTime = fakeTime + 0.01 end -- 额外 30ms
end)
heavy()
local sorted = S:ExternalSnapshot()
check("按累计耗时降序（贵的那路在最前）", sorted[1].key == "k1", sorted[1].label)
check("两路都在账上", #sorted == 2, #sorted)

-- 4) PrintStats 不抛（含外部段）
local ok, err = pcall(S.PrintStats, S)
check("PrintStats 不抛错（含外部驱动段）", ok, err)

-- 5) 非函数入参原样返回（调用点写错不该崩）
check("Profile 收到非函数原样返回", S:Profile("x", "x", nil) == nil)
check("Profile 无 key 原样返回", S:Profile(nil, "x", function() end) ~= nil)

-- 6) ResetCosts：清零外部账与聚合，不动订阅
local hadSubId = S:Every(200, function() end)
local subRows = S:Snapshot()
check("注册点来源被记下（R: where 带文件名与行号）",
  subRows[1] and type(subRows[1].where) == "string" and subRows[1].where:find("%.lua:%d+") ~= nil,
  subRows[1] and subRows[1].where)
S:ResetCosts()
local _, st = S:Count()
check("ResetCosts 清空外部账", #S:ExternalSnapshot() == 0, #S:ExternalSnapshot())
check("ResetCosts 清空聚合调用数", st.calls == 0, st.calls)
check("ResetCosts 不动订阅（在册仍 1）", st.running == 1, st.running)
S:Unregister(hadSubId)

print(fail == 0 and "\n全部通过" or ("\n失败 " .. fail .. " 项"))
os.exit(fail == 0 and 0 or 1)
