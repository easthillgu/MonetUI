-- tools/harness/module-anchor-probe.lua
-- 用法（项目根目录）：lua tools/harness/module-anchor-probe.lua
--
-- 回归目标（2026-11-10 作者判例）：关掉某个模块（任务追踪 / 小地图）后，
-- 依赖它具名锚框的窗口不能跑到屏幕边缘。覆盖两条独立链路：
--   ① Utils/Mover.lua  —— AnchorUsable / Offscreen / ApplyOne 的 fallback 落点
--   ② Modules/Bags/Bags.lua —— TrackerUsable / LayoutWindows 的降级落点
-- 两段都**抽取线上源码原文**执行，不是照抄一份逻辑来自己验自己。

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

local function check(name, ok, detail)
    if not ok then
        print("FAIL " .. name .. (detail and ("  ->  " .. tostring(detail)) or ""))
        return 1
    end
    print("PASS " .. name)
    return 0
end

-- ==========================================================================
-- ① Mover：隐藏锚框 / 名字解析不到 / 无 fallback 时的落点
-- ==========================================================================
local function runMover()
    local src = read("Utils/Mover.lua")
    local parents = slice(src, "local function ParentOf(key)", "local function Stored(entry)")
    local applyOne = slice(src, "local function ApplyOne(entry)", "local function ApplyTree(key, seen)")

    local chunk = [[
local entries = {}
local UIParent = { _name = "UIParent",
    GetWidth = function() return 1920 end,
    GetHeight = function() return 1080 end }
local ns = { AfterCombat = function() end }
local InCombat = function() return false end
local Stored = function(e) return e.store and e.store() or nil end
local FAILED = 0
local function F(shown, rect, name)
    return { _shown = shown, _rect = rect, _name = name,
        GetRect = function(self) if self._rect then
            return self._rect[1], self._rect[2], self._rect[3], self._rect[4] end end,
        GetLeft = function(self) if self._rect then return self._rect[1] end end,
        IsShown = function(self) return self._shown end,
        IsProtected = function() return false end,
        ClearAllPoints = function(self) self.point = nil end,
        SetPoint = function(self, p, parent, rp, x, y) self.point = { p, parent, rp, x, y } end }
end
local function check(name, ok, detail)
    if not ok then FAILED = FAILED + 1 end
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  ->  " .. tostring(detail)) or ""))
end
]] .. parents .. "\n" .. applyOne .. [[

local function run(name, entry, wantParent, wantPoint, wantX)
    local ok = pcall(ApplyOne, entry)
    local q = entry.frame.point
    local pass = ok and q and q[2] == wantParent and q[1] == wantPoint
    if wantX then pass = pass and q[4] == wantX end
    check(name, pass, q and (tostring(q[1]) .. " / " .. tostring(q[2] and q[2]._name)
        .. " / x=" .. tostring(q[4])) or "no point")
end
local none = function() return {} end
local fb = { point = "CENTER", relativePoint = "CENTER", x = 300, y = 0 }

local target = F(false, { 800, 500, 160, 20 }, "target")
entries["target"] = { key = "target", frame = target }
local tot = F(false, { 0, 0, 60, 20 }, "tot")
run("1 登记框隐藏但 rect 有效 -> 仍锚该框（8.78 回归）",
    { key = "targettarget", frame = tot,
      default = { point = "LEFT", relativeTo = "target", relativePoint = "RIGHT", x = 6, y = 0 },
      store = none }, target, "LEFT", 6)

local panel = F(false, { 1500, 800, 260, 194 }, "panel")
MonetUIMinimapPanel = panel
local raid = F(true, { 0, 0, 100, 158 }, "raid")
run("2 具名面板隐藏 -> fallback 且 parent=UIParent",
    { key = "groupRaid", frame = raid,
      default = { point = "RIGHT", relativeTo = "MonetUIMinimapPanel",
                  relativePoint = "LEFT", x = -14, y = 0, fallback = fb }, store = none },
    UIParent, "CENTER", 300)
panel._shown = true
run("3 具名面板显示 -> 锚面板",
    { key = "groupRaid", frame = raid,
      default = { point = "RIGHT", relativeTo = "MonetUIMinimapPanel",
                  relativePoint = "LEFT", x = -14, y = 0, fallback = fb }, store = none },
    panel, "RIGHT", -14)
run("4 名字解析不到 -> fallback",
    { key = "x", frame = F(true, { 0, 0, 10, 10 }, "x"),
      default = { point = "RIGHT", relativeTo = "NoSuchFrame",
                  relativePoint = "LEFT", x = -14, y = 0, fallback = fb }, store = none },
    UIParent, "CENTER", 300)
target._rect = nil
run("5 登记框无 rect -> fallback",
    { key = "targettarget", frame = tot,
      default = { point = "LEFT", relativeTo = "target", relativePoint = "RIGHT",
                  x = 6, y = 0, fallback = fb }, store = none },
    UIParent, "CENTER", 300)
target._rect = { 800, 500, 160, 20 }
run("6 玩家存过的位置优先",
    { key = "targettarget", frame = tot,
      default = { point = "LEFT", relativeTo = "target", relativePoint = "RIGHT", x = 6, y = 0 },
      store = function() return { point = "CENTER", relativeTo = "UIParent",
                                  relativePoint = "CENTER", x = 123, y = 45 } end },
    UIParent, "CENTER", 123)
run("7 小队默认屏位不受影响",
    { key = "groupParty", frame = F(true, { 0, 0, 110, 133 }, "party"),
      default = { point = "CENTER", relativeTo = "UIParent",
                  relativePoint = "CENTER", x = -330, y = 40 }, store = none },
    UIParent, "CENTER", -330)

-- 8：模块关掉 + 没有 fallback 表 —— 不能再把相对偏移当绝对坐标留在屏幕左缘。
panel._shown = false
local orphan = F(true, { 0, 0, 100, 158 }, "orphan")
pcall(ApplyOne, { key = "orphan", frame = orphan,
    default = { point = "LEFT", relativeTo = "MonetUIMinimapPanel",
                relativePoint = "RIGHT", x = 6, y = 0 }, store = none })
local q8 = orphan.point
check("8 具名面板隐藏且无 fallback -> 屏幕内象限、不是 LEFT 6,0",
    q8 and q8[2] == UIParent and q8[1] == "CENTER"
    and q8[4] > -1920 / 2 and q8[4] < 0 and q8[4] ~= 6,
    q8 and tostring(q8[4]) or "no point")

-- 9：锚到可见框但框的 rect 在屏幕外 -> 二次自愈（旧版 needFallback 分支漏掉）。
panel._shown = true
local off = F(true, { 3000, 500, 100, 158 }, "offscreen")
pcall(ApplyOne, { key = "off", frame = off,
    default = { point = "RIGHT", relativeTo = "MonetUIMinimapPanel",
                relativePoint = "LEFT", x = -14, y = 0, fallback = fb }, store = none })
local q9 = off.point
check("9 锚定后落在屏幕外 -> 二次自愈回 fallback",
    q9 and q9[2] == UIParent and q9[1] == "CENTER" and q9[4] == 300,
    q9 and tostring(q9[4]) or "no point")

return FAILED
]]
    return assert(loader(chunk))()
end

-- ==========================================================================
-- ② Bags：任务追踪关掉（框在但 hidden）/ 没布局 / 显示 三种落点
-- ==========================================================================
local function runBags()
    local src = read("Modules/Bags/Bags.lua")
    local layout = slice(src, "local function TrackerUsable(frame)", "--- 最近一次银行重绘")

    local chunk = [[
local UIParent = { _name = "UIParent",
    GetWidth = function() return 1920 end,
    GetHeight = function() return 1080 end }
_G.UIParent = UIParent
local shown = true
local activeMode = "bags"
-- Marked 恒 true = 不进 PollWatch 补扫分支，本桩只验同步落点。
local Marked = function() return true end
local Mark = function() end
local Widget = { PollWatch = function() end, Unwatch = function() end }
local WindowPosition = function() return nil end
local RestoreDragged = function() end
local ORDERED = { { key = "a" }, { key = "b" } }
local FAILED = 0
local function check(name, ok, detail)
    if not ok then FAILED = FAILED + 1 end
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  ->  " .. tostring(detail)) or ""))
end
local function W(name, w, h)
    return { _name = name, _w = w, _h = h,
        IsShown = function() return true end,
        GetWidth = function(self) return self._w end,
        GetHeight = function(self) return self._h end,
        ClearAllPoints = function(self) self.point = nil end,
        SetPoint = function(self, p, parent, rp, x, y) self.point = { p, parent, rp, x, y } end }
end
local function T(isShown, rect)
    return { _shown = isShown, _rect = rect, _name = "MonetUIQuestTracker",
        IsShown = function(self) return self._shown end,
        GetRect = function(self) if self._rect then
            return self._rect[1], self._rect[2], self._rect[3], self._rect[4] end end,
        GetLeft = function(self) if self._rect then return self._rect[1] end end }
end
local windows = {
    a = W("a", 300, 200), b = W("b", 260, 160),
    ["bank:a"] = W("bank:a", 300, 200), ["bank:b"] = W("bank:b", 260, 160),
}
local Setting = function(key)
    if key == "anchor" then
        return { frame = "MonetUIQuestTracker", side = "right", x = -18, y = -28 }
    end
end
]] .. layout .. [[

local tracker = T(false, { 1500, 800, 264, 400 })
_G.MonetUIQuestTracker = tracker
LayoutWindows("bags")
local q = windows.a.point
check("1 任务追踪关掉（框在但 hidden）-> 降级到 UIParent",
    q and q[2] == UIParent and q[1] == "TOPLEFT",
    q and (tostring(q[1]) .. " / " .. tostring(q[2] and q[2]._name)) or "no point")
check("2 降级落点整列在屏幕内（x>=16 且 x+300<=1920）",
    q and q[4] >= 16 and q[4] + 300 <= 1920, q and tostring(q[4]) or "no point")
check("3 降级 y 不把列顶出屏幕上沿", q and q[5] <= -16,
    q and tostring(q[5]) or "no point")

LayoutWindows("bank")
local qb = windows["bank:a"].point
check("4 银行列降级也不越左边界", qb and qb[2] == UIParent and qb[4] >= 16,
    qb and tostring(qb[4]) or "no point")

tracker._shown = true
LayoutWindows("bags")
local qv = windows.a.point
check("5 任务追踪开着 -> 贴回 tracker 左边 -18",
    qv and qv[2] == tracker and qv[1] == "TOPRIGHT" and qv[4] == -18,
    qv and (tostring(qv[1]) .. " / x=" .. tostring(qv[4])) or "no point")

tracker._rect = nil
LayoutWindows("bags")
local qr = windows.a.point
check("6 锚框存在但没布局（无 rect）-> 降级", qr and qr[2] == UIParent,
    qr and tostring(qr[2] and qr[2]._name) or "no point")

return FAILED
]]
    return assert(loader(chunk))()
end

local total = runMover() + runBags()
print(total == 0 and "ALL PASS" or (total .. " FAILED"))
os.exit(total == 0 and 0 or 1)
