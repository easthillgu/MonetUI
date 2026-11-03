-- tools/harness/samples/bad-strip-alpha.lua
-- 故意写坏：给容器挂了背板之后，把它的父链淡到 α=0 却不还原
-- （实机第一例：Skin:InsetWell + 根窗口 Strip 把内嵌容器打到 α0，43 个 inset=true 窗口全空）。
-- 期望：断言四记一条 A4 红，并打印父链上每一层的 α。
local ADDON_NAME, ns = ...

local host = CreateFrame("Frame", "HarnessSampleHost")
local inset = CreateFrame("Frame", "HarnessSampleInset", host)
inset:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 8, tile = false, tileSize = 0,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
inset:SetBackdropColor(0, 0, 0, 0.5)
host:Show()
inset:Show()

-- 这一刀就是 bug：Strip 只把根窗口的 α 归零，没管里面的内嵌容器
host:SetAlpha(0)
