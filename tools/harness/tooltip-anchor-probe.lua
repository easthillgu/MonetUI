-- tools/harness/tooltip-anchor-probe.lua
-- 用法（项目根目录）：lua tools/harness/tooltip-anchor-probe.lua
--
-- 回归目标（2026-11-10 作者实报）：提示框选「小地图右上角」时，偶尔会跑到小地图上。
-- 实机读到的真相：平时锚点是 BOTTOMRIGHT → MonetUIMinimapPanel:TOPRIGHT (0, 8)；
-- 但暴雪每次 SetOwner / Show 都会重写锚点（采样抓到 BOTTOMLEFT → MonetUIBar2Button6:TOPRIGHT）。
-- 修前 mmKey 只记「我们上次的输入」（面板 right/top + 提示框 w/h），那一次输入恰好没变
-- 就跳过写入 → 提示框留在别人的锚点上。另一条：面板只要 IsShown() 为假就退回跟随光标，
-- 光标正停在小地图图标上 → 提示框直接盖到小地图上。
--
-- 本桩**抽取线上 Tooltip.lua 的摆位段原文**在桩环境里跑，不是照抄一份逻辑自己验自己；
-- 另加静态断言守住「锚点回读校验 + 面板临时隐藏不跟光标」这个修复边界。

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

local src = read("Modules/Tooltip/Tooltip.lua")
local config = read("Config/SimpleConfig.lua")

local constants = slice(src, "local OFFSET = 14", "local mode, enrich, idsByAlt, neutralText")
local placement = slice(src, "--- 摆位统一走这里", "-- 内容")

-- ==========================================================================
-- ① 静态断言：修复边界
-- ==========================================================================
check("文件头写明锚点所有权判例",
    src:find("锚点所有权", 1, true) ~= nil
    and src:find("输入恰好没变", 1, true) ~= nil)
check("摆位统一走 SetAnchor（写锚点同时记账）",
    placement:find("local function SetAnchor(tip, point, rel, relPoint, x, y)", 1, true) ~= nil
    and placement:find("lastAnchor = { point = point", 1, true) ~= nil)
check("AnchorIntact 回读 GetPoint + 机密/锚点数校验",
    placement:find("local function AnchorIntact(tip)", 1, true) ~= nil
    and placement:find("pcall(tip.GetPoint, tip, 1)", 1, true) ~= nil
    and placement:find("GetNumPoints", 1, true) ~= nil
    and placement:find("Secrets.Number(x), Secrets.Number(y)", 1, true) ~= nil)
check("ApplyPlacement 在写入前做锚点校验并让去重键作废",
    placement:find("if not AnchorIntact(tip) then", 1, true) ~= nil
    and placement:find("anchorReclaims = anchorReclaims + 1", 1, true) ~= nil
    and placement:find("cursorKey, mmKey = nil, nil", 1, true) ~= nil)
check("off 模式清账且不碰暴雪锚点",
    placement:find("if mode == \"off\" then", 1, true) ~= nil
    and placement:find("cursorKey, mmKey, lastAnchor = nil, nil, nil", 1, true) ~= nil)
check("PlaceCursor 也走 SetAnchor（cursor 模式同样能自愈）",
    placement:find("SetAnchor(tip, \"BOTTOMLEFT\", ui, \"BOTTOMLEFT\", x0, y0)", 1, true) ~= nil)
check("面板可用性只看几何，不再拿 IsShown 当门槛",
    placement:find("local function MinimapPanelGeometry(panel)", 1, true) ~= nil
    and placement:find("Secrets.Number(right)", 1, true) ~= nil
    and placement:find(":IsShown()", 1, true) == nil)
check("只有小地图模块真关掉才退回跟随",
    placement:find("ns:IsModuleEnabled(\"Minimap\")", 1, true) ~= nil
    and placement:find("panelFallbacks = panelFallbacks + 1", 1, true) ~= nil)
check("退回跟随按「次」计数，不按帧刷账本",
    placement:find("if not fallbackCounted then", 1, true) ~= nil
    and placement:find("if right then fallbackCounted = false end", 1, true) ~= nil)
check("几何读不出时钉在 UIParent 绝对坐标，不跟光标",
    placement:find("hold:%.2f:%.2f:%.2f", 1, true) ~= nil
    and placement:find("lastGood.top + lastGood.gap", 1, true) ~= nil)
check("面板对象换过强制重贴",
    placement:find("if panel ~= lastPanel then", 1, true) ~= nil
    and placement:find("mmKey = nil", 1, true) ~= nil)
check("去重键纳入屏幕高度与上下分支",
    placement:find("uiH or 0, above and \"above\" or \"top\"", 1, true) ~= nil)
check("长提示框改钉屏幕顶沿（不再从面板底边往下溢出）",
    placement:find("SetAnchor(tip, \"TOPRIGHT\", ui, \"TOPLEFT\", right, (uiH or 0) - gap)", 1, true) ~= nil
    and placement:find("SetPoint(\"TOPRIGHT\", panel, \"BOTTOMRIGHT\"", 1, true) == nil)
check("设置变化让锚点账一起作废",
    src:find("InvalidatePlacement()   -- 模式", 1, true) ~= nil
    and placement:find("local function InvalidatePlacement()", 1, true) ~= nil)
check("隐藏沿 Reset 清 lastAnchor（下次显示必重贴）",
    src:find("cursorKey, mmKey, lastAnchor = nil, nil, nil", 1, true) ~= nil)
check("诊断打印外部改写 / 退回跟随 / 回读一致",
    src:find("锚点：外部改写 %d 次", 1, true) ~= nil
    and src:find("AnchorIntact(tip) and \"是\" or \"否\"", 1, true) ~= nil)
check("配置提示同步改口径",
    config:find("面板临时隐藏时保持原位", 1, true) ~= nil)

-- ==========================================================================
-- ② 原文执行：摆位状态机
-- ==========================================================================
local chunk = [[
local mode = "minimap"
local cursorKey, mmKey = nil, nil
local lastAnchor, lastPanel, lastGood = nil, nil, nil
local anchorReclaims, panelFallbacks = 0, 0
local fallbackCounted = false

local SECRET = setmetatable({}, { __secret = true })
local function Secret() return SECRET end
local Secrets = {
    IsSecret = function(v) return type(v) == "table" and v.__secret == true end,
    Number = function(v) if type(v) == "number" then return v end return nil end,
    Bool = function(v, d) if type(v) == "boolean" then return v end return d end,
}
local Media = { Mult = function() return 1 end }

local writes = 0
local function Frame(name, w, h)
    local f = { _name = name, _points = {}, _w = w or 250, _h = h or 100,
                _right = 2100.33, _top = 225, _shown = true }
    f.GetName = function(self) return self._name end
    f.ClearAllPoints = function(self) self._points = {} end
    f.SetPoint = function(self, p, r, rp, x, y)
        writes = writes + 1
        self._points[#self._points + 1] = { p, r, rp, x or 0, y or 0 }
    end
    f.GetPoint = function(self, i)
        local q = self._points[i]
        if not q then return nil end
        return q[1], q[2], q[3], q[4], q[5]
    end
    f.GetNumPoints = function(self) return #self._points end
    f.GetWidth = function(self) return self._w end
    f.GetHeight = function(self) return self._h end
    f.GetEffectiveScale = function(self) return 0.64 end
    f.GetRight = function(self) return self._right end
    f.GetTop = function(self) return self._top end
    f.IsShown = function(self) return self._shown ~= false end
    return f
end

local ui = Frame("UIParent", 2133.33, 1200)
ui._right, ui._top = 2133.33, 1200
UIParent = ui
local minimap = Frame("Minimap")
local panel = Frame("MonetUIMinimapPanel")
panel._right, panel._top = 2100.33, 225
local tip = Frame("GameTooltip", 250.88, 188.98)

local moduleEnabled = true
local minimapModule = { panel = panel }
local ns = {
    GetModule = function(_, name) return name == "Minimap" and minimapModule or nil end,
    IsModuleEnabled = function(_, name)
        if name == "Minimap" then return moduleEnabled end
        return true
    end,
}
function GetCursorPosition() return 1000, 900 end

local FAILED = 0
local function check(name, ok, detail)
    if not ok then FAILED = FAILED + 1 end
    print((ok and "PASS " or "FAIL ") .. name
        .. (detail and ("  ->  " .. tostring(detail)) or ""))
end
local function Point(t)
    local q = t._points[1]
    if not q then return "none" end
    return tostring(q[1]) .. ">" .. tostring(q[2] and q[2]._name) .. ":" .. tostring(q[3])
        .. "(" .. tostring(q[4]) .. "," .. tostring(q[5]) .. ")"
end
]] .. constants .. "\n" .. placement .. [[

-- ---- 正常 minimap 摆位 ----------------------------------------------------
ApplyPlacement(tip)
check("正常：右下角贴小地图面板右上角 (0,8)",
    Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)", Point(tip))
check("首次摆位不计外部改写（lastAnchor 还没有）", anchorReclaims == 0, anchorReclaims)

local n = writes
ApplyPlacement(tip)
check("输入没变：去重仍生效，不重复写布局", writes == n, "writes=" .. writes)

-- ---- ★ 核心回归：外部把锚点改掉，输入却没变 -------------------------------
tip:ClearAllPoints()
tip:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, 0)
writes = 0
ApplyPlacement(tip)
check("★ 暴雪重贴锚点后：下一拍被拉回小地图上方",
    Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)", Point(tip))
check("★ 修前会跳过写入（mmKey 没变），修后记账 +1",
    anchorReclaims == 1, "reclaims=" .. anchorReclaims)

-- ---- 追加第二个锚点也要发现 -----------------------------------------------
tip:SetPoint("LEFT", ui, "LEFT", 10, 10)
ApplyPlacement(tip)
check("追加第二个锚点（会拉伸提示框）→ 重贴回单点",
    tip:GetNumPoints() == 1 and Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)",
    Point(tip) .. " n=" .. tip:GetNumPoints())

-- ---- GetPoint 抛错 / 机密：宁可多写一次，也不能认别人的锚点 ---------------
local realGetPoint = tip.GetPoint
tip.GetPoint = function() error("blocked") end
ApplyPlacement(tip)
check("GetPoint 被拦 → 强制重贴（不静默放过）",
    Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)", Point(tip))
tip.GetPoint = realGetPoint

-- ---- 面板临时隐藏：绝不跟回光标 -------------------------------------------
panel._shown = false
writes = 0
ApplyPlacement(tip)
check("面板 IsShown=false 但几何有效：仍锚在面板上沿（修前会退回跟随光标）",
    Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)", Point(tip))
panel._shown = true

-- ---- 几何这一拍读不出：钉在最后一次有效位置 -------------------------------
local realRight = panel.GetRight
panel.GetRight = function() return Secret() end
ApplyPlacement(tip)
check("几何读不出：锚点改钉 UIParent 绝对坐标，不是光标",
    Point(tip) == "BOTTOMRIGHT>UIParent:BOTTOMLEFT(2100.33,233)", Point(tip))
panel.GetRight = realRight
ApplyPlacement(tip)
check("几何恢复：立刻重贴回面板",
    Point(tip) == "BOTTOMRIGHT>MonetUIMinimapPanel:TOPRIGHT(0,8)", Point(tip))

-- ---- 面板对象重建：right/top 不变也要重贴 ---------------------------------
local newPanel = Frame("MonetUIMinimapPanel")
newPanel._right, newPanel._top = 2100.33, 225
minimapModule.panel = newPanel
ApplyPlacement(tip)
check("面板换对象：重贴到新面板（留在旧面板上会整个跑掉）",
    tip._points[1][2] == newPanel, Point(tip))
minimapModule.panel = panel
lastPanel = nil
ApplyPlacement(tip)

-- ---- 模块真关掉：保持原设计的跟随光标 -------------------------------------
moduleEnabled = false
ApplyPlacement(tip)
check("小地图模块真关掉：退回跟随光标（BOTTOMLEFT 锚在 UIParent）",
    tip._points[1][1] == "BOTTOMLEFT" and tip._points[1][2] == ui, Point(tip))
check("退回跟随有计数（诊断可查）", panelFallbacks >= 1, panelFallbacks)
local fb = panelFallbacks
ApplyPlacement(tip)
ApplyPlacement(tip)
check("连续几帧停在跟随：计数不按帧涨", panelFallbacks == fb, panelFallbacks)
moduleEnabled = true
InvalidatePlacement()
ApplyPlacement(tip)

-- ---- off 模式：不干涉暴雪 --------------------------------------------------
mode = "off"
local offAnchor = Point(tip)
local before = writes
ApplyPlacement(tip)
check("off 模式不写布局、清掉锚点账",
    writes == before and lastAnchor == nil and Point(tip) == offAnchor)

-- ---- 长提示框：顶边钉屏幕顶沿，不往面板下方溢出 ---------------------------
mode = "minimap"
InvalidatePlacement()
tip._h = 1100
ApplyPlacement(tip)
check("长提示框：TOPRIGHT 钉屏幕顶沿、右缘与面板齐平",
    tip._points[1][1] == "TOPRIGHT" and tip._points[1][2] == ui
    and math.abs(tip._points[1][4] - 2100.33) < 0.01
    and math.abs(tip._points[1][5] - 1192) < 0.01, Point(tip))
tip._h = 188.98

-- ---- cursor 模式同样有自愈能力 --------------------------------------------
mode = "cursor"
InvalidatePlacement()
ApplyPlacement(tip)
check("cursor 模式：摆到光标旁",
    tip._points[1][1] == "BOTTOMLEFT" and tip._points[1][2] == ui, Point(tip))
tip:ClearAllPoints()
tip:SetPoint("CENTER", minimap, "CENTER", 0, 0)
ApplyPlacement(tip)
check("cursor 模式：外部改写后也拉回光标锚点",
    tip._points[1][1] == "BOTTOMLEFT" and tip._points[1][2] == ui, Point(tip))

print(FAILED == 0 and "ALL PASS" or (FAILED .. " FAILED"))
os.exit(FAILED == 0 and 0 or 1)
]]

local fn, err = loader(chunk)
if not fn then
    print("FAIL 桩代码加载失败: " .. tostring(err))
    os.exit(1)
end
fn()
