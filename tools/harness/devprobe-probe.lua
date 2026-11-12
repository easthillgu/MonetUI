-- tools/harness/devprobe-probe.lua
-- `Modules/Tools/DevProbe.lua` 的**离线行为探针**（不是发行码，游戏里永不加载）。
--
-- 为什么单独一条：harness 只 pump 登录那一秒，DevProbe 是懒建模块 —— run.js 的红 0
-- 对它是"没跑到"，不是"跑过没红"。本探针把真文件 loadfile 进假环境，手动驱动
-- 「开面板 → dig → 预览 tick → 左键确认 → 枚举 → 点行复制」整条链，外加
-- 右键取消 / 机密名 / forbidden / 匿名祖先 / GetMouseFoci 缺席退路 / 截断。
--
-- 跑法：lua tools/harness/devprobe-probe.lua
-- 退出码：全过 0，任一失败 1。

local probePath = arg and arg[0] or ...
local function norm(p) return (p or ""):gsub("\\", "/") end
local function RepoRoot()
    local p = norm(probePath)
    local i = p:find("tools/harness/devprobe%-probe.lua$", 1)
    if i then return p:sub(1, i - 1) end
    return "./"
end
local root = RepoRoot()
local target = root .. "Modules/Tools/DevProbe.lua"

local f = io.open(target, "rb")
if not f then
    print("[FAIL] 读不到 " .. tostring(target))
    os.exit(1)
end
local src = f:read("*a")
f:close()

-- ---------------------------------------------------------------- 假环境

local printed, db = {}, {}
local marks = setmetatable({}, { __mode = "k" })
local allFrames = {}

local function MakeFontString()
    local fs = { text = "", otype = "FontString" }
    function fs:SetText(t) self.text = tostring(t or "") end
    function fs:GetText() return self.text end
    function fs:SetPoint() end
    function fs:SetWidth() end
    function fs:SetWordWrap() end
    function fs:SetTextColor() end
    function fs:GetObjectType() return "FontString" end
    return fs
end

local function MakeTexture()
    local t = { otype = "Texture", shown = true }
    function t:GetAtlas() return self.atlas end
    function t:GetTexture() return self.path end
    function t:GetObjectType() return "Texture" end
    function t:SetWidth() end
    function t:SetHeight() end
    function t:ClearAllPoints() end
    function t:SetPoint() end
    function t:SetColorTexture() end
    function t:SetTexture() end
    function t:SetAllPoints() end
    function t:SetVertexColor() end
    function t:Hide() self.shown = false end
    function t:Show() self.shown = true end
    return t
end

local function MakeFrame(kind, name, parent)
    local fr = {
        kind = kind or "Frame", name = name, parent = parent,
        shown = true, scripts = {}, children = {}, regions = {},
    }
    allFrames[#allFrames + 1] = fr
    -- 真客户端里 CreateFrame 会把新框挂进父框的 GetChildren；假环境也要连上，
    -- 否则行池（CreateFrame("Button", nil, content)）在 content.children 里 invisible。
    if parent and parent.children then
        parent.children[#parent.children + 1] = fr
    end
    function fr:GetName() return self.name end
    function fr:GetObjectType() return self.kind end
    function fr:SetPoint(...) self.points = { ... } end
    function fr:ClearAllPoints() self.points = nil end
    function fr:SetSize(w, h) self.w, self.h = w, h end
    function fr:SetWidth(w) self.w = w end
    function fr:SetHeight(h) self.h = h end
    function fr:GetWidth() return self.w end
    function fr:GetHeight() return self.h end
    function fr:SetFrameStrata(s) self.strata = s end
    function fr:SetClampedToScreen() end
    function fr:SetMovable() end
    function fr:EnableMouse(v) self.mouse = v end
    function fr:RegisterForDrag() end
    function fr:SetScript(slot, fn) self.scripts[slot] = fn end
    function fr:GetScript(slot) return self.scripts[slot] end
    function fr:Show() self.shown = true end
    function fr:Hide() self.shown = false end
    function fr:IsShown() return self.shown end
    function fr:CreateTexture()
        local t = MakeTexture()
        self.regions[#self.regions + 1] = t
        return t
    end
    function fr:CreateFontString()
        local fs = MakeFontString()
        self.regions[#self.regions + 1] = fs
        return fs
    end
    function fr:SetAllPoints() end
    function fr:StartMoving() end
    function fr:StopMovingOrSizing() end
    -- ScrollFrame
    function fr:SetScrollChild(c) self.scrollChild = c end
    function fr:EnableMouseWheel(v) self.wheel = v end
    function fr:GetVerticalScroll() return self.vscroll or 0 end
    function fr:SetVerticalScroll(v) self.vscroll = math.max(0, v) end
    -- EditBox
    function fr:SetText(t) self.text = tostring(t or "") end
    function fr:GetText() return self.text or "" end
    function fr:HighlightText() self.highlighted = true end
    function fr:SetFocus() self.focused = true end
    function fr:ClearFocus() self.focused = false end
    function fr:SetAutoFocus() end
    function fr:SetTextInsets() end
    function fr:SetTextColor() end
    function fr:SetFont() end
    -- 暴雪侧只读面（假目标树用）
    function fr:GetChildren() return table.unpack(self.children) end
    function fr:GetRegions() return table.unpack(self.regions) end
    function fr:GetParent() return self.parent end
    function fr:GetRect()
        if self.rect then return table.unpack(self.rect) end
        return nil
    end
    function fr:IsMouseOver() return self.mouseOver and true or false end
    return fr
end

CreateFrame = function(kind, name, parent) return MakeFrame(kind, name, parent) end
UIParent = MakeFrame("Frame", "UIParent", nil)

local fakeNs = {}
fakeNs.Print = function(_, line) printed[#printed + 1] = tostring(line) end
fakeNs.DB = function() return db end
fakeNs.Register = function(_, name, mod) fakeNs._mod = mod; fakeNs._name = name end
fakeNs.Marked = function(_, obj, key)
    local t = marks[obj]
    return t and t[key]
end
-- 机密值口径：名字是 "__secret__" 的当作读不出（CanRead=false），其余放行。
fakeNs.Secrets = { CanRead = function(v) return v ~= "__secret__" end }

local W = {}
W.CreateFrame = function(_, name, parent, w, h, template, kind)
    local fr = CreateFrame(kind or "Frame", name, parent)
    if w then fr:SetSize(w, h or w) end
    return fr
end
W.Theme = function(_, fr, opts) fr.themed = opts end
W.ButtonMaterial = function(_, fr, opts) fr.material = opts end
W.Shadow = function() end
W.Font = function(_, parent, size)
    local fs = parent:CreateFontString()
    fs.size = size
    return fs
end
W.SetFont = function() end
W.CloseButton = function(_, parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 24, size or 24)
    return b
end
W.Readable = function(_, fr) return fr.readable ~= false end
W.IsMouseOver = function(_, fr) return fr.mouseOver and true or false end
fakeNs.Widget = W
fakeNs.Color = {
    GetEdge = function() return 0.9, 0.8, 0.6, 1 end,
    GetHighlight = function() return 1, 0.9, 0.5, 1 end,
}
fakeNs.Media = {}
local subs = {}
fakeNs.Scheduler = {
    Every = function(_, ms, fn, label)
        local id = #subs + 1
        subs[id] = { ms = ms, fn = fn, label = label }
        return id
    end,
    Unregister = function(_, id) subs[id] = nil end,
}

local pass, failcount = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1; print("  [OK]   " .. label)
    else failcount = failcount + 1; print("  [FAIL] " .. label) end
end
local function any(sub)
    for _, line in ipairs(printed) do
        if line:find(sub, 1, true) then return true end
    end
    return false
end
local function FrameNamed(name)
    for _, fr in ipairs(allFrames) do
        if fr.name == name then return fr end
    end
    return nil
end

-- ---------------------------------------------------------------- 加载真文件

local chunk, err = loadfile(target)
if not chunk then print("[FAIL] 编译失败：" .. tostring(err)) os.exit(1) end
chunk("MonetUI", fakeNs)
local M = fakeNs._mod
ok(M ~= nil and fakeNs._name == "DevProbe", "注册发生，模块名 = DevProbe")
M:Initialize()
ok(#allFrames == 1, "Initialize 懒建：登录一个框都不造（只有假 UIParent）")

-- ---------------------------------------------------------------- 1. 开面板

ok(M:HandleCommand("") == true, "/mui dev 入口消费命令")
local panel = FrameNamed("MonetUIDevProbeFrame")
ok(panel ~= nil and panel.shown, "面板建出来且显示")
ok(panel and panel.w == 256 and panel.h == 256, "尺寸 256×256")
ok(panel and panel.strata == "DIALOG", "strata = DIALOG（在普通窗口之上、接住器之下）")
ok(panel and panel.themed ~= nil and panel.material ~= nil, "主题边框 + 斜纹画布都接上（Theme + ButtonMaterial）")

-- ---------------------------------------------------------------- 2. dig 起点选

ok(M:HandleCommand("dig") == true, "/mui dig 入口消费命令")
local catcher = FrameNamed("MonetUIDevProbeCatcher")
local highlight = FrameNamed("MonetUIDevProbeHighlight")
ok(catcher ~= nil and catcher.shown and catcher.mouse == true, "接住器显示且收鼠标")
local subCount, tickFn, tickLabel, tickMs = 0, nil, nil, nil
for _, s in pairs(subs) do
    subCount = subCount + 1
    tickFn, tickLabel, tickMs = s.fn, s.label, s.ms
end
ok(subCount == 1 and tickMs == 100 and tickLabel == "DevProbe:点选预览",
    "点选预览 = Scheduler:Every(100ms) 且带显式标签")

-- ---------------------------------------------------------------- 3. 假目标树

local merchant = MakeFrame("Frame", "MerchantFrame", UIParent)
merchant.rect = { 100, 200, 400, 500 }
local repairBtn = MakeFrame("Button", "MerchantRepairAllButton", merchant)
local anon = MakeFrame("Frame", nil, merchant)
local secretFrame = MakeFrame("Frame", "__secret__", merchant)
local forbidden = MakeFrame("Frame", "ForbiddenOne", merchant)
forbidden.readable = false
merchant.children = { repairBtn, anon, secretFrame, forbidden }
local tex = MakeTexture()
tex.atlas = "SpellIcon-256x256-Repair"
repairBtn.regions = { tex }

GetMouseFoci = function() return { catcher, merchant } end

-- ---------------------------------------------------------------- 4. 预览 tick

tickFn()
ok(highlight.shown and highlight.w == 400 and highlight.h == 500,
    "预览高亮跟着候选矩形走（GetMouseFoci 跳过自家接住器）")
local status = FrameNamed("MonetUIDevProbeFrame") and panel.regions
-- statusText 是面板的 FontString region；找含「点选目标」的那条
local statusFS
for _, r in ipairs(panel.regions) do
    if r.otype == "FontString" and r.text:find("点选目标", 1, true) then statusFS = r end
end
ok(statusFS ~= nil and statusFS.text:find("MerchantFrame", 1, true),
    "状态行报出候选名字 MerchantFrame")

-- ---------------------------------------------------------------- 5. 左键确认 → 枚举

catcher.scripts.OnMouseDown(catcher, "LeftButton")
local subAfter = 0
for _ in pairs(subs) do subAfter = subAfter + 1 end
ok(subAfter == 0 and not catcher.shown and not highlight.shown,
    "确认后摘订阅、收接住器与高亮（不留常驻轮询）")
local report = db.devProbeReport
ok(report ~= nil and report.root == "MerchantFrame" and report.total > 0,
    "枚举落账本 devProbeReport（root = MerchantFrame）")
ok(any("已探测 MerchantFrame"), "聊天框打一行摘要")

local scroll = FrameNamed("MonetUIDevProbeList")
local content = scroll and scroll.scrollChild
ok(content ~= nil and #content.children == report.total,
    "行数 = 账本条数（行池与数据对齐）")

local function RowWith(needle)
    for _, row in ipairs(content.children) do
        local t = row.text and row.text.text or ""
        if t:find(needle, 1, true) then return row end
    end
    return nil
end
local copyBox = FrameNamed("MonetUIDevProbeCopy")

local rootRow = content.children[1]
ok(rootRow ~= nil and (rootRow.text.text or ""):find("MerchantFrame", 1, true),
    "根框在列表第一行")
rootRow.scripts.OnClick()
ok(copyBox.text == "MerchantFrame" and copyBox.highlighted and copyBox.focused,
    "点行 → 名字进输入框并全选（Ctrl+C 可复制）")

local btnRow = RowWith("MerchantRepairAllButton")
ok(btnRow ~= nil, "子按钮在列表里")
btnRow.scripts.OnClick()
ok(copyBox.text == "MerchantRepairAllButton", "点子按钮 → 复制的是它的全局名")

local regionRow = RowWith("SpellIcon-256x256-Repair")
ok(regionRow ~= nil, "region 按图集认脸列出")
regionRow.scripts.OnClick()
ok(copyBox.text == "MerchantRepairAllButton", "点 region → 复制宿主框名（接线把手）")

local anonRow = RowWith("(匿名)")
ok(anonRow ~= nil, "匿名框照实标 (匿名)")
anonRow.scripts.OnClick()
ok(copyBox.text == "MerchantFrame", "匿名框 → 复制最近有名祖先")

ok(RowWith("读不出") ~= nil, "forbidden 框单独一行，不崩不混进正常行")

-- 机密名：SafeName 读不出 ⇒ 当匿名，绝不把机密串拼进显示文本
local secretLeak = false
for _, row in ipairs(content.children) do
    if (row.text.text or ""):find("__secret__", 1, true) then secretLeak = true end
end
ok(not secretLeak, "机密名不出现在任何行文本里")

-- ---------------------------------------------------------------- 6. 右键取消

M:HandleCommand("dig")
ok(catcher.shown, "再输 /mui dig 重新进入点选")
local totalBefore = db.devProbeReport.total
catcher.scripts.OnMouseDown(catcher, "RightButton")
local subAfter2 = 0
for _ in pairs(subs) do subAfter2 = subAfter2 + 1 end
ok(subAfter2 == 0 and not catcher.shown and db.devProbeReport.total == totalBefore,
    "右键 = 取消：摘订阅、收接住器、不触发枚举")

-- ---------------------------------------------------------------- 7. 关闭按钮 / 开关

local closeBtn
for _, fr in ipairs(allFrames) do
    if fr.kind == "Button" and fr.parent == panel and fr.scripts.OnClick then closeBtn = fr end
end
ok(closeBtn ~= nil, "面板有关闭按钮")
closeBtn.scripts.OnClick()
ok(not panel.shown, "关闭按钮收面板（前置声明生效：闭包里的 DevProbe 不是全局 nil）")
M:HandleCommand("")
ok(panel.shown, "/mui dev 再开")
M:HandleCommand("")
ok(not panel.shown, "/mui dev 再关（开关语义）")

-- ---------------------------------------------------------------- 8. GetMouseFoci 缺席退路

GetMouseFoci = nil
merchant.mouseOver = true
repairBtn.mouseOver = true
UIParent.mouseOver = true
local enumList = { UIParent, merchant, repairBtn }
local enumIdx = 0
EnumerateFrames = function()
    enumIdx = enumIdx + 1
    return enumList[enumIdx]
end
M:HandleCommand("dig")
local tick2
for _, s in pairs(subs) do tick2 = s.fn end
tick2()
local statusFS2
for _, r in ipairs(panel.regions) do
    if r.otype == "FontString" and r.text:find("点选目标", 1, true) then statusFS2 = r end
end
ok(statusFS2 ~= nil and statusFS2.text:find("MerchantRepairAllButton", 1, true),
    "退路（EnumerateFrames+IsMouseOver）取最深的候选 = 子按钮")
catcher.scripts.OnMouseDown(catcher, "LeftButton")
ok(db.devProbeReport.root == "MerchantRepairAllButton", "退路点选后枚举的是子按钮子树")
EnumerateFrames = nil
merchant.mouseOver = nil
repairBtn.mouseOver = nil
UIParent.mouseOver = nil

-- ---------------------------------------------------------------- 9. 两条腿都缺 ⇒ 不崩

M:HandleCommand("dig")
local tick3
for _, s in pairs(subs) do tick3 = s.fn end
local okTick = pcall(tick3)
ok(okTick and not highlight.shown, "GetMouseFoci/EnumerateFrames 都缺：tick 不崩、不高亮")
local okClick = pcall(catcher.scripts.OnMouseDown, catcher, "LeftButton")
local statusFS3
for _, r in ipairs(panel.regions) do
    if r.otype == "FontString" and r.text:find("没有点中任何框体", 1, true) then statusFS3 = r end
end
ok(okClick and statusFS3 ~= nil, "此时左键 = 诚实一句（面板状态行），不崩")

-- ---------------------------------------------------------------- 10. 截断

local wide = MakeFrame("Frame", "WideFrame", UIParent)
wide.children = {}
for i = 1, 700 do
    wide.children[i] = MakeFrame("Button", "WideChild" .. i, wide)
end
GetMouseFoci = function() return { catcher, wide } end
M:HandleCommand("dig")
local tick4
for _, s in pairs(subs) do tick4 = s.fn end
tick4()
catcher.scripts.OnMouseDown(catcher, "LeftButton")
ok(db.devProbeReport.root == "WideFrame" and db.devProbeReport.truncated == true
    and db.devProbeReport.total == 600,
    "700 件大窗：截断在 600 行且账本注明 truncated")

-- ---------------------------------------------------------------- 11. 静态边界

local codeSrc = src:gsub("%-%-[^\n]*", "")
ok(not codeSrc:find("hooksecurefunc", 1, true) and not codeSrc:find("HookScript", 1, true),
    "不挂 hooksecurefunc / HookScript（暴雪框只读，脚本只挂自建框）")

print(("devprobe-probe: %d 过 / %d 失"):format(pass, failcount))
os.exit(failcount == 0 and 0 or 1)