-- Modules/Minimap/Buttons.lua
-- 小地图内的三个独立按钮：追踪（左下）、难度（左上）、插件收纳（右上）。
--
-- 追踪与插件收纳用的是**暴雪自己的按钮**（搬进来，不重写）：菜单、追踪状态、插件列表
-- 都由客户端在管，我们只负责摆位和画自己的图标。搬进来的代价是 SetParent / SetSize
-- 在战斗里可能被无声拒绝，所以每次套用都重新摆一遍。
--
-- 三个按钮共用同一块 3:4 底板（15×20，Widget:Theme 的平边框），图标是自绘的纯白模具
-- （tools/regen-textures.js 生成），颜色在运行期染：追踪=中性色、收纳=边缘色、
-- 难度=副本难度色。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Media    = ns.Media
local Secrets  = ns.Secrets
local EventBus = ns.EventBus

-- 旁表标记（见 Core.lua 的 ns:Mark）
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local B = {}

B.WIDTH  = 20      -- 4:3 矩形（宽:高 = 4:3，横长）
B.HEIGHT = 15
B.CANVAS = 20      -- 徽章材质的画布边长（材质 64×64，徽章本体占中间的 64×48 = 4:3）

local container        -- 三个按钮的容器（挂在小地图的覆盖层上）
local difficultyFrame  -- 难度指示（完全是我们自己的框）

-- 暴雪按钮被搬进来之前的父级与锚点（还原时放回去）
local savedParents = setmetatable({}, { __mode = "k" })

-- 暴雪按钮上会被我们压掉 alpha 的贴图（还原时按原值放回去）。
-- NormalTexture / PushedTexture / HighlightTexture 是暴雪自己的按钮美术：追踪按钮的
-- NormalTexture 就是暴雪的"追踪"图标，我们的自绘徽章画上去以后两者会**同时**出现，
-- 所以要一并压掉（还原时按原值放回去）。
local ART_KEYS = { "StateTexture", "AddTexture", "Text",
                   "NormalTexture", "PushedTexture", "HighlightTexture" }

--- 按钮上的一张贴图：先看字段（NormalTexture / PushedTexture / HighlightTexture …），
--- 字段没有就用取器（GetNormalTexture …）。
--- 暴雪的追踪 / 收纳按钮就是后者 —— 它们的贴图是 XML 里没有 parentKey 的
--- <NormalTexture atlas="…">，字段拿不到，只有取器拿得到。
local function ArtRegion(frame, key)
    if not frame then return nil end
    local okField, region = pcall(function() return frame[key] end)
    if okField and region then return region end
    local getter = frame["Get" .. key]
    if type(getter) == "function" then
        local ok, value = pcall(getter, frame)
        if ok then return value end
    end
    return nil
end

-- ------------------------------------------------------------------ 小工具

--- 走点号路径取对象（MinimapCluster.Tracking.Button 这类 parentKey 路径）。
local function Resolve(path)
    local node = _G
    for segment in path:gmatch("[^%.]+") do
        if node == nil then return nil end
        local ok, value = pcall(function() return node[segment] end)
        if not ok then return nil end
        node = value
    end
    return node
end

--- 记下暴雪按钮被搬走之前的父级、锚点、尺寸与贴图透明度（还原时放回去）。
--- layout 是我们给它安排的锚点（还原按钮时按它摆回去，重入钩子也靠它复原）。
local function SaveParent(frame, layout)
    if savedParents[frame] then
        if layout then savedParents[frame].layout = layout end
        return
    end
    local points = {}
    if frame.GetNumPoints then
        for i = 1, frame:GetNumPoints() do
            local point, relTo, relPoint, x, y = frame:GetPoint(i)
            points[#points + 1] = { point, relTo, relPoint, x, y }
        end
    end
    local art = {}
    for _, key in ipairs(ART_KEYS) do
        local region = ArtRegion(frame, key)
        if region and region.GetAlpha then
            local ok, alpha = pcall(region.GetAlpha, region)
            if ok then art[#art + 1] = { region = region, alpha = alpha } end
        end
    end
    savedParents[frame] = {
        parent = frame:GetParent(),
        points = points,
        size   = { frame:GetWidth(), frame:GetHeight() },
        art    = art,
        layout = layout,
    }
end

-- ------------------------------------------------------------------ 摆位 / 重入

-- 重入标志：我们的钩子会调 SetParent / SetPoint，那两个又会触发钩子自己。
local reasserting = false

--- 把按钮摆到容器里的某个位置。
--- layout = { 点, 相对点, x, y }（相对 container）。
--- 注意相对**帧**永远是 container，只有相对**点**在 layout 里 ——
--- 早先把 layout[2] 当成 relativeTo 传给了 SetPoint（那是个字符串），
--- SetPoint 直接失败，按钮一个锚点都没有，等于飘在父框的原点、永远看不见。
local function PlaceButton(frame, layout)
    reasserting = true
    pcall(frame.ClearAllPoints, frame)
    pcall(frame.SetPoint, frame, layout[1], container, layout[2], layout[3], layout[4])
    pcall(frame.SetParent, frame, container)
    pcall(frame.SetSize, frame, B.WIDTH, B.HEIGHT)
    reasserting = false
end

--- 暴雪有时会把按钮搬回去（换区域、集群 Relayout、UpdateMinimapConfig 之后），
--- 钩一次 SetParent / SetPoint / SetScale，把我们的摆位按回去。
--- 钩子里只做「按回去」的动作，所以暴雪自己的状态机不会错乱（Ellesmere 3680-3681、
--- 3983-3998 的同款做法）。
local function Reassert(frame)
    if reasserting then return end
    local saved = frame and savedParents[frame]
    if not saved or not saved.layout then return end
    if InCombatLockdown() then
        -- 战斗中搬不动（受保护），排队等脱战补做
        pcall(function()
            local minimapModule = ns:GetModule("Minimap")
            if minimapModule and minimapModule.RequestSkin then minimapModule:RequestSkin() end
        end)
        return
    end
    PlaceButton(frame, saved.layout)
end

--- 暴雪有时会把按钮搬回去（换区域 / 集群 Relayout / UpdateMinimapConfig 之后）。
--- 以前用 hooksecurefunc 钩 SetParent/SetPoint/SetScale（写方法槽 = 污染，见 AGENTS）；
--- 改成每 0.5 秒轮询一次"父级还是不是 container"，不是就 Reassert 按回去。
local function HookReassert(frame)
    if Marked(frame, "reassertHooked") then return end
    Mark(frame, "reassertHooked", true)
    Widget:PollWatch(frame, function(self)
        if InCombatLockdown() then return end
        if self:GetParent() ~= container then
            pcall(Reassert, self)
        end
    end)
end

--- 把暴雪按钮的某张贴图压掉（只压 alpha，不隐藏 —— 隐藏父帧会停掉它的状态更新）。
local function HideArt(frame, key)
    local region = ArtRegion(frame, key)
    if region and region.SetAlpha then pcall(region.SetAlpha, region, 0) end
end

--- 徽章染色：贴图是中性灰底 + 白色描边的"模具"，颜色全靠顶点色乘上去。
-- BadgeColor 定义在本文件靠后的位置，TintIcon / SetHover 却在它前面调用它：不先声明成 upvalue
-- 的话这两个函数看到的是全局 `BadgeColor`（nil），零售服一旦真的走到小地图按钮那条路就报
-- "attempt to call a nil value"（Forever 上那条路走不到，所以一直没暴露）。
local BadgeColor
local function TintIcon(icon, key)
    if not icon then return end
    local r, g, b = BadgeColor(key)
    pcall(icon.SetVertexColor, icon, r, g, b, 1)
end

--- 悬停状态：把底板边框点亮，离开恢复主题色。
local function SetHover(plate, hovered)
    if not plate then return end
    if hovered then
        local r, g, b, a = ns.Color:Get("highlight")
        Widget:SetBorderState(plate, r, g, b, a or 1)
    else
        Widget:SetBorderState(plate, nil)
    end
end

--- 给一个框体加"4:3 徽章"。
--- 徽章**就是材质本身**（描边 + 半透明底 + 符号都在贴图里），运行期用顶点色染色 ——
--- 所以贴图是中性灰底 + 白色描边的"模具"（染色模具不许带色相，见 AGENTS.md）。
--- 贴图画布 64×64，徽章本体占中间的 64×48 = 4:3；画成 20×20 时徽章正好 20×15。
local function AddBadge(parent, textureKey, tintKey)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media:Texture(textureKey))
    tex:SetPoint("CENTER", parent, "CENTER", 0, 0)
    tex:SetSize(B.CANVAS, B.CANVAS)
    tex.tintKey = tintKey
    TintIcon(tex, tintKey)
    return tex
end

--- 悬停状态：沿用本色、只提亮（难度徽章不能因为悬停就丢掉难度色）。
local function SetHover(tex, hovered)
    if not tex then return end
    local r, g, b = BadgeColor(tex.tintKey)
    if hovered then
        tex:SetVertexColor(math.min(1, r * 1.4), math.min(1, g * 1.4), math.min(1, b * 1.4), 1)
    else
        tex:SetVertexColor(r, g, b, 1)
    end
end

--- 徽章染色：追踪 / 收纳用主题边框色，难度徽章用副本难度色。
function BadgeColor(key)
    if key == "border" then
        local r, g, b = ns.Color:GetBorder()
        return r, g, b
    end
    local r, g, b = ns.Color:Get(key)
    return r, g, b
end

--- 悬停状态：点亮底板。轮询（Widget:HoverWatch），不挂脚本钩子。
local function HookHover(frame, tex)
    if Marked(frame, "hoverHooked") then return end
    Mark(frame, "hoverHooked", true)
    ns.Widget:HoverWatch(frame,
        function() SetHover(tex, true) end,
        function() SetHover(tex, false) end)
end

-- ------------------------------------------------------------------ 三个按钮

--- 追踪：暴雪的 Tracking.Button（DropdownButton，点开是追踪菜单）。
--- 它的父框 Tracking 默认是隐藏的（客户端在有追踪目标时才显示），
--- 按钮被搬出来之后就不再受那个显隐管，我们自己决定它一直在。
local function SetupTracking()
    local btn = Resolve("MinimapCluster.Tracking.Button")
    if not btn then return end

    local layout = { "BOTTOMLEFT", "BOTTOMLEFT", 4, 4 }
    SaveParent(btn, layout)
    PlaceButton(btn, layout)
    HookReassert(btn)

    -- 按钮搬走之后，暴雪那个容器框（零售 12.x 会在集群角上留一个旋涡按钮）就空了：把它收起来，
    -- 免得地图上方挂着一个点不动的旧按钮。老客户端上这个框默认就是隐藏的，收起来没有影响。
    local oldParent = savedParents[btn] and savedParents[btn].parent
    if oldParent and oldParent ~= container and oldParent ~= UIParent then
        pcall(oldParent.Hide, oldParent)
        pcall(oldParent.SetAlpha, oldParent, 0)
    end

    HideArt(btn, "StateTexture")
    HideArt(btn, "AddTexture")
    -- 暴雪自己的按钮美术（外框 / 按下 / 高亮）收掉：自绘徽章画上去以后，
    -- 暴雪的"追踪"图标会和我们自己的徽章**同时**出现，两个图标叠在一起。
    HideArt(btn, "NormalTexture")
    HideArt(btn, "PushedTexture")
    HideArt(btn, "HighlightTexture")

    if not btn.monetBadge then
        btn.monetBadge = AddBadge(btn, "monet_map_tracking", "border")
        HookHover(btn, btn.monetBadge)
    end
    btn.monetBadge:Show()
    -- 客户端的 Show 覆写会转去显隐 Tracking 框，所以用 SetShown 直接定显隐。
    pcall(btn.SetShown, btn, true)
end

--- 插件收纳：暴雪的 AddonCompartmentFrame（DropdownButton，点开是插件列表）。
local function SetupCompartment()
    local btn = Resolve("AddonCompartmentFrame")
    if not btn then return end

    local layout = { "TOPRIGHT", "TOPRIGHT", -4, -4 }
    SaveParent(btn, layout)
    PlaceButton(btn, layout)
    HookReassert(btn)

    HideArt(btn, "StateTexture")
    HideArt(btn, "AddTexture")
    HideArt(btn, "Text")     -- 插件数量那一行（列表在菜单里，不必再占地方）
    -- 同追踪按钮：暴雪的"收纳"图标要收掉，否则和我们自己的徽章同时出现。
    HideArt(btn, "NormalTexture")
    HideArt(btn, "PushedTexture")
    HideArt(btn, "HighlightTexture")

    if not btn.monetBadge then
        btn.monetBadge = AddBadge(btn, "monet_map_compartment", "border")
        HookHover(btn, btn.monetBadge)
    end
    btn.monetBadge:Show()
    pcall(btn.SetShown, btn, true)
end

--- 难度：客户端这个版本**没有**小地图难度框（Camelot 的 CreateInstanceDifficultyFrame
--- 是故意留空的），所以整块都是我们自己画的：盾牌图标按难度染色。
local function DifficultyTint(name)
    if type(name) ~= "string" or Secrets.IsSecret(name) then return "edge" end
    if string.find(name, "史诗") then return "danger" end
    if string.find(name, "英雄") then return "resource" end
    if string.find(name, "普通") then return "health" end
    return "edge"
end

local function UpdateDifficulty()
    if not difficultyFrame then return end
    local settings = ns:GetModule("Minimap"):GetSettings()
    if not settings.mapDifficulty then
        difficultyFrame:Hide()
        return
    end

    local _, instanceType, _, difficultyName = GetInstanceInfo()
    if type(instanceType) ~= "string" or instanceType == "" or instanceType == "none" then
        difficultyFrame:Hide()
        return
    end

    difficultyFrame:Show()
    TintIcon(difficultyFrame.icon, DifficultyTint(difficultyName))
end

--- 难度牌子上挂个提示：光一个盾牌色块，看不出是哪个难度。
local function SetupDifficultyTooltip()
    if not difficultyFrame then return end
    difficultyFrame:EnableMouse(true)
    difficultyFrame:HookScript("OnEnter", function(self)
        local _, instanceType, _, difficultyName, maxPlayers = GetInstanceInfo()
        if type(instanceType) ~= "string" or instanceType == "" then return end
        if not _G.GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if type(difficultyName) == "string" and not Secrets.IsSecret(difficultyName) then
            GameTooltip:SetText(difficultyName, 1, 1, 1)
        else
            GameTooltip:SetText(_G.LOOT_TYPE_NORMAL or "副本", 1, 1, 1)
        end
        if type(maxPlayers) == "number" and maxPlayers > 0 then
            GameTooltip:AddLine(string.format("%d 人", maxPlayers), 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    difficultyFrame:HookScript("OnLeave", function()
        if _G.GameTooltip then GameTooltip:Hide() end
    end)
end

local function SetupDifficulty()
    if not difficultyFrame then
        -- 徽章就是材质本身（4:3），难度徽章按副本难度染色
        difficultyFrame = Widget:CreateFrame("MonetUIMinimapDifficulty", container, B.WIDTH, B.HEIGHT)
        difficultyFrame.icon = AddBadge(difficultyFrame, "monet_map_difficulty", "edge")
        difficultyFrame:HookScript("OnEnter", function() SetHover(difficultyFrame.icon, true) end)
        difficultyFrame:HookScript("OnLeave", function() SetHover(difficultyFrame.icon, false) end)
        SetupDifficultyTooltip()
    end
    difficultyFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 4, -4)
    UpdateDifficulty()
end

-- ------------------------------------------------------------------ 对外接口

--- 某个开关关掉时：把暴雪按钮放回原来的位置（显隐交给"暴雪集群按钮"那一组管）。
local function RestoreOne(path)
    local frame = Resolve(path)
    if not frame then return end
    local saved = savedParents[frame]
    if not saved then return end
    -- 先把存档删掉，再动手还原：重入钩子看到"这个按钮已经交还给暴雪了"就不会
    -- 在我们 SetParent / SetPoint 的过程中又把它搬回容器里（否则还原会被钩子推翻）。
    savedParents[frame] = nil
    pcall(frame.SetParent, frame, saved.parent)
    pcall(frame.ClearAllPoints, frame)
    for _, pt in ipairs(saved.points) do
        pcall(frame.SetPoint, frame, pt[1], pt[2], pt[3], pt[4], pt[5])
    end
    pcall(frame.SetSize, frame, saved.size[1], saved.size[2])
    for _, info in ipairs(saved.art) do
        pcall(info.region.SetAlpha, info.region, info.alpha)
    end
    if frame.monetBadge then pcall(frame.monetBadge.Hide, frame.monetBadge) end
end

--- 把三个按钮摆到覆盖层上（overlay 是小地图可见区那块透明层）。
function B:Apply(overlay)
    if not overlay then return end

    if not container then
        container = Widget:CreateFrame("MonetUIMinimapButtons", overlay, 1, 1)
        container:SetAllPoints(overlay)
        container:EnableMouse(false)
    end

    local settings = ns:GetModule("Minimap"):GetSettings()
    if settings.mapTracking then
        SetupTracking()
    else
        RestoreOne("MinimapCluster.Tracking.Button")
    end
    if settings.mapCompartment then
        SetupCompartment()
    else
        RestoreOne("AddonCompartmentFrame")
    end
    if settings.mapDifficulty then
        SetupDifficulty()
    else
        if difficultyFrame then difficultyFrame:Hide() end
    end
end

--- 还原：把暴雪按钮搬回原来的父级与锚点，我们画的底板藏起来。
function B:Restore()
    -- 先把帧名收集成一张表再逐个还原：遍历中改 savedParents（还要把条目置 nil）
    -- 既可能撞上"遍历中改表"的规矩，也可能撞上弱键被回收。
    local frames = {}
    for frame in pairs(savedParents) do frames[#frames + 1] = frame end

    for _, frame in ipairs(frames) do
        local saved = savedParents[frame]
        if frame and saved then
            -- 先把存档删掉再还原：重入钩子看到"已经交还给暴雪了"就不会在
            -- 还原的过程中又把它搬回容器里（同 RestoreOne 的理由）。
            savedParents[frame] = nil
            pcall(frame.SetParent, frame, saved.parent)
            pcall(frame.ClearAllPoints, frame)
            for _, pt in ipairs(saved.points) do
                pcall(frame.SetPoint, frame, pt[1], pt[2], pt[3], pt[4], pt[5])
            end
            pcall(frame.SetSize, frame, saved.size[1], saved.size[2])
            for _, info in ipairs(saved.art) do
                pcall(info.region.SetAlpha, info.region, info.alpha)
            end
            if frame.monetBadge then pcall(frame.monetBadge.Hide, frame.monetBadge) end
        end
    end
    savedParents = setmetatable({}, { __mode = "k" })
    if difficultyFrame then difficultyFrame:Hide() end
end

--- 难度会随进出副本变，单独刷新一次。
function B:UpdateDifficulty()
    UpdateDifficulty()
end

--- 主题换了，三个图标重新染色。
function B:RefreshTints()
    local tracking = Resolve("MinimapCluster.Tracking.Button")
    if tracking and tracking.monetBadge then
        TintIcon(tracking.monetBadge, tracking.monetBadge.tintKey)
    end
    local compartment = Resolve("AddonCompartmentFrame")
    if compartment and compartment.monetBadge then
        TintIcon(compartment.monetBadge, compartment.monetBadge.tintKey)
    end
    -- 难度图标的颜色跟着当前难度走，重算一次
    UpdateDifficulty()
end

--- 鼠标是不是停在某个按钮上（右键菜单据此让位）。
-- 直接问每个按钮自己（IsMouseOver），比记 enter/leave 计数可靠：按钮在悬停时被隐藏
-- 的话，计数会漏掉一次 leave。
function B:IsOverButton()
    local tracking = Resolve("MinimapCluster.Tracking.Button")
    if tracking and tracking:IsMouseOver() then return true end
    local compartment = Resolve("AddonCompartmentFrame")
    if compartment and compartment:IsMouseOver() then return true end
    if difficultyFrame and difficultyFrame:IsMouseOver() then return true end
    return false
end

--- 容器（给区域名条定位用）。
function B:Container()
    return container
end

EventBus:Register("MONETUI_THEME_CHANGED", function()
    if ns:GetModule("Minimap"):IsActive() then B:RefreshTints() end
end)

ns:GetModule("Minimap").buttons = B
