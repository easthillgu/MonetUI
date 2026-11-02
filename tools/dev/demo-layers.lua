-- 分层美化演示窗：六层标准配方实机展示
-- 用法：wuxian run --addon MonetUI "$(cat tools/dev/demo-layers.lua)"
-- 注意：此脚本经 wuxian run 传参会被拍平成单行，禁用 `--` 行注释，只用块注释。

local ns = _G.MonetUI
local S, W, C, SK = ns.Skin, ns.Widget, ns.Color, ns.Skins

local prev = _G.MonetDemoLayers
if prev then prev:Hide() end

local f = CreateFrame("Frame", "MonetDemoLayers", UIParent, BackdropTemplateMixin and "BackdropTemplate")
f:SetSize(440, 470)
f:SetPoint("CENTER", UIParent, "CENTER", 300, 40)
f:SetFrameStrata("DIALOG")
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)

--[[
第 1 层 窗壳：panel L*10 + 1px 边，背板挂窗口本体（11-02 渲染判例）
]]
SK:Dress(f, { window = true })

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -13)
title:SetJustifyH("LEFT")
title:SetText("分层演示 · 六层配方")
local er, eg, eb = C:Get("edge")
title:SetTextColor(er, eg, eb)
W:HeaderRule(f, title, { key = "demoTitle" })

--[[
第 2 层 正文凹槽：root.Inset + InsetWell = lost L*28 亮一档 + 1px 主题边
]]
local inset = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate")
f.Inset = inset
inset:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -44)
inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 92)
local plate = S:InsetWell(f)

local function label(parent, text, anchorTo, dy, small)
    local t = parent:CreateFontString(nil, "OVERLAY", small and "GameFontNormalSmall" or "GameFontNormal")
    t:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, dy or -6)
    t:SetJustifyH("LEFT")
    t:SetText(text)
    local nr, ng, nb = C:Get("neutral")
    t:SetTextColor(nr, ng, nb)
    return t
end

--[[
第 3 层 织纹：只给大空区（条）。lost 底 -> BarWeave 发丝线 -> fill 压顶
]]
local bar = CreateFrame("Frame", nil, inset, BackdropTemplateMixin and "BackdropTemplate")
bar:SetSize(392, 26)
bar:SetPoint("TOPLEFT", inset, "TOPLEFT", 14, -14)
local ground = bar:CreateTexture(nil, "BACKGROUND")
ground:SetColorTexture(C:GetSurface("lost"))
ground:SetAllPoints(bar)
W:BarWeave(bar, { alpha = 0.85 })
local fill = bar:CreateTexture(nil, "ARTWORK")
local fr, fg, fb = C:GetSurface("fill")
fill:SetColorTexture(fr, fg, fb, 0.96)
fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
fill:SetSize(390 * 0.62, 24)
label(inset, "3| 织纹 L*40 + fill L*46（62%）—— 材质只给大空区", bar, -4, true)

--[[
第 4 层 控件底 α0.9（as=button 统一入口）+ 空槽 α0.25
]]
local btn1 = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
btn1:SetSize(128, 26)
btn1:SetText("控件 α0.9")
btn1:SetPoint("TOPLEFT", inset, "TOPLEFT", 14, -78)
SK:Dress(btn1, { as = "button" })

local btn2 = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
btn2:SetSize(128, 22)
btn2:SetText("小件 α0.7")
btn2:SetPoint("LEFT", btn1, "RIGHT", 10, 0)
SK:Dress(btn2, { as = "button" })

local slotRow = label(inset, "4| 空槽 α0.25（「这里少了东西」的语义）", btn1, -14, true)
local slots = {}
for i = 1, 3 do
    local slot = CreateFrame("Frame", nil, inset, BackdropTemplateMixin and "BackdropTemplate")
    slot:SetSize(40, 40)
    slot:SetPoint("TOPLEFT", slotRow, "BOTTOMLEFT", (i - 1) * 48, -6)
    W:Theme(slot, { bgAlpha = 0.25, thickness = 1 })
    slots[i] = slot
end

--[[
第 5 层 内容：图标只做 0.08 裁切融合，深度感交给身后的槽
]]
local icons = {
    "Interface\\Icons\\Spell_Nature_WispSplode",
    "Interface\\Icons\\INV_Sword_27",
    "Interface\\Icons\\Trade_BlackSmithing",
}
for i = 1, 3 do
    local icon = slots[i]:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("CENTER")
    icon:SetTexture(icons[i])
    S:CropIcon(icon, 0.08, 0.92, 0.08, 0.92)
end
label(inset, "5| 图标 CropIcon 0.08 —— 内容不参与层次", slotRow, -52, true)

--[[
第 6 层 点缓 = 交界发丝线（HeaderRule 已画标题那条，层交界不再多画）
底部收尾：关闭按钮 + 提示
]]
local note = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
note:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
note:SetJustifyH("LEFT")
note:SetJustifyV("TOP")
note:SetText("色阶管分层 · 织纹管材质 · 发丝线管交界\n裁切管融合 · alpha 管压场")
local nr2, ng2, nb2 = C:Get("neutral")
note:SetTextColor(nr2, ng2, nb2, 0.9)

local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
close:SetSize(84, 24)
close:SetText("关闭")
close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
SK:Dress(close, { as = "button" })
close:SetScript("OnClick", function() f:Hide() end)

f:Show()

local fw, fh = fill:GetSize()
local hostOk = plate and plate:GetParent() == f
local diag = string.format("fill: shown=%s layer=%s size=%.0fx%.0f | plate=%s hostIsRoot=%s",
    tostring(fill:IsShown()), tostring(fill:GetDrawLayer()), fw or -1, fh or -1,
    tostring(plate ~= nil), tostring(hostOk))
return "MonetDemoLayers v2 created 440x470 | " .. diag
