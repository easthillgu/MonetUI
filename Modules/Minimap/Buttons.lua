-- Modules/Minimap/Buttons.lua
-- 小地图内的四个独立按钮：追踪（左下）、难度（左上）、插件收纳（右上）、排队状态（右下）。
--
-- 追踪 / 插件收纳 / 排队状态用的是**暴雪自己的按钮**（搬进来，不重写）：菜单、追踪状态、
-- 插件列表、队列提示都由客户端在管，我们只负责摆位和换掉图标。搬进来的代价是
-- SetParent / SetSize 在战斗里可能被无声拒绝，所以每次套用都重新摆一遍、并按拍纠回。
--
-- 前三颗共用自绘纯白模具徽章（tools/regen-textures.js 生成）：追踪=中性色、收纳=边缘色、
-- 难度=副本难度色。第四颗（QueueStatusButton）与复古组队窗肖像位共用
-- `Skin:GlyphBadge` 的**动态字符徽章**，没有贴图 —— 见 Utils/Skin.lua 末尾。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Media    = ns.Media
local Secrets  = ns.Secrets
local EventBus = ns.EventBus
local Scheduler = ns.Scheduler
local Skin     = ns.Skin

-- 旁表标记（见 Core.lua 的 ns:Mark）
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData）；跨文件共享键仍走 Mark/Marked。
local FFD, GetFFD = ns:NewFrameData()

local B = {}

B.WIDTH  = 20      -- 4:3 矩形（宽:高 = 4:3，横长）
B.HEIGHT = 15
B.CANVAS = 20      -- 徽章材质的画布边长（材质 64×64，徽章本体占中间的 64×48 = 4:3）

local container        -- 三个按钮的容器（挂在小地图的覆盖层上）
local difficultyFrame  -- 难度指示（完全是我们自己的框）
local restoreSubId

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

--- 走点号路径取对象（MinimapCluster.Tracking.Button 这类 parentKey 路径）：
--- 用 Core.lua 里的唯一实现，不在模块里另抄一份。
local Resolve = ns.ResolveObject

--- 记下暴雪按钮被搬走之前的父级、锚点、尺寸与贴图透明度（还原时放回去）。
--- layout 是我们给它安排的锚点（还原按钮时按它摆回去，重入钩子也靠它复原）。
local function SaveParent(frame, layout)
    if savedParents[frame] then
        if layout then
            savedParents[frame].layout = layout
            -- 上一次还原失败时轮询会让路；重新启用按钮时再恢复重摆。
            savedParents[frame].restoring = false
        end
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
        restoring = false,
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
    if not saved or not saved.layout or saved.restoring then return end
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
    local fd = GetFFD(frame)
    if fd.reassertHooked then return end
    fd.reassertHooked = true
    Widget:PollWatch(frame, function(self)
        if InCombatLockdown() then return end
        local saved = savedParents[self]
        if not saved or saved.restoring then return end
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
    --
    -- **只能 alpha 0 + 关鼠标，不能 Hide**（AGENTS「收暴雪的 HUD 帧」）：Hide 会让它自己的
    -- 显隐逻辑和我们对着干，而且还原时没人记得它原本是显示还是隐藏。原 alpha 记进旁表，
    -- RestoreOne 时还回去。
    local oldParent = savedParents[btn] and savedParents[btn].parent
    if oldParent and oldParent ~= container and oldParent ~= UIParent then
        if not Marked(oldParent, "parked") then
            Mark(oldParent, "parked", true)
            Mark(oldParent, "parkAlpha", oldParent.GetAlpha and oldParent:GetAlpha() or 1)
            if type(oldParent.EnableMouse) == "function" then
                pcall(oldParent.EnableMouse, oldParent, false)
            end
        end
        pcall(oldParent.SetAlpha, oldParent, 0)
    end

    HideArt(btn, "StateTexture")
    HideArt(btn, "AddTexture")
    -- 暴雪自己的按钮美术（外框 / 按下 / 高亮）收掉：自绘徽章画上去以后，
    -- 暴雪的"追踪"图标会和我们自己的徽章**同时**出现，两个图标叠在一起。
    HideArt(btn, "NormalTexture")
    HideArt(btn, "PushedTexture")
    HideArt(btn, "HighlightTexture")

    -- 徽章存在旁表里（ns:Mark）：btn 是暴雪的框体，往它上面写字段就等于把它标脏，
    -- 它之后跑的暴雪代码会全部算成"被 MonetUI 污染"。
    local badge = Marked(btn, "badge")
    if not badge then
        badge = AddBadge(btn, "monet_map_tracking", "border")
        Mark(btn, "badge", badge)
        HookHover(btn, badge)
    end
    badge:Show()
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

    local badge = Marked(btn, "badge")
    if not badge then
        badge = AddBadge(btn, "monet_map_compartment", "border")
        Mark(btn, "badge", badge)
        HookHover(btn, badge)
    end
    badge:Show()
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
    difficultyFrame:HookScript("OnEnter", function(self) -- TAINT-OK: difficultyFrame 是自建标记（MonetUIMinimapDifficulty）
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
    difficultyFrame:HookScript("OnLeave", function() -- TAINT-OK: 同上（OnLeave 藏 tooltip）
        if _G.GameTooltip then GameTooltip:Hide() end
    end)
end

local function SetupDifficulty()
    if not difficultyFrame then
        -- 徽章就是材质本身（4:3），难度徽章按副本难度染色
        difficultyFrame = Widget:CreateFrame("MonetUIMinimapDifficulty", container, B.WIDTH, B.HEIGHT)
        difficultyFrame.icon = AddBadge(difficultyFrame, "monet_map_difficulty", "edge")
        difficultyFrame:HookScript("OnEnter", function() SetHover(difficultyFrame.icon, true) end) -- TAINT-OK: 同上（hover 用 EnableMouse 开启）
        difficultyFrame:HookScript("OnLeave", function() SetHover(difficultyFrame.icon, false) end) -- TAINT-OK: 同上
        SetupDifficultyTooltip()
    end
    difficultyFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 4, -4)
    UpdateDifficulty()
end

-- ------------------------------------------------------------------ 排队状态（右下）
-- 参照只读参考件 Andromeda 的 `MAP:CreateQueueStatusButton()`（把 QueueStatusButton 摆到
-- 小地图 BOTTOMRIGHT），但**不抄它的 hooksecurefunc / SetPoint 钩**：AGENTS 禁止往暴雪
-- 方法槽里写东西。改为 `Widget:PollWatch` 每 0.5 秒按回父级与锚点。
-- 眼睛本身换成动态字符徽章：两处眼睛（LFG 窗肖像位 / 这里）同一套、同一帧。
local QUEUE_PATH = "QueueStatusButton"

--- 按钮上的暴雪美术：Highlight（96×96 发光）+ Eye 子树（LFGEyeTemplate 的 flipbook / 光晕）。
--- 只压 alpha、不 Hide：暴雪靠 QueueStatusButton:Show/Hide 与 Eye 的动画组管状态机，
--- 断掉 shown 链会让排队提示整个停掉。动画会把 alpha 抬回来 ⇒ QueuePoll 每拍补压。
local function QueueArtRegions(btn)
    local out = {}
    local function walk(obj, depth)
        if not obj or depth > 3 or not Widget:Readable(obj) then return end
        local okR, regs = pcall(function() return { obj:GetRegions() } end)
        if okR and type(regs) == "table" then
            for i = 1, #regs do
                local r = regs[i]
                local okT, kind = pcall(r.GetObjectType, r)
                if okT and kind == "Texture" then out[#out + 1] = r end
            end
        end
        local okC, kids = ns.Widget:ChildrenOf(obj)
        if okC and type(kids) == "table" then
            for i = 1, #kids do walk(kids[i], depth + 1) end
        end
    end
    walk(btn, 0)
    return out
end

--- 回写并复核一个 alpha；SetAlpha 在受限上下文里可能"不报错但没落地"。
local function RestoreAlpha(region, alpha)
    if type(region.SetAlpha) ~= "function" then return false end
    if not pcall(region.SetAlpha, region, alpha) then return false end
    if type(region.GetAlpha) == "function" then
        local ok, current = pcall(region.GetAlpha, region)
        if not ok then return false end
        local matchesOK, matches = pcall(function() return current == alpha end)
        if not matchesOK or not matches then return false end
    end
    return true
end

--- 隐藏我们自己的装饰，并在取器可用时确认真的藏掉。
local function HideDecoration(region)
    if type(region.Hide) ~= "function" then return false end
    if not pcall(region.Hide, region) then return false end
    if type(region.IsShown) == "function" then
        local ok, shown = pcall(region.IsShown, region)
        if not ok then return false end
        local hiddenOK, hidden = pcall(function() return not shown end)
        if not hiddenOK or not hidden then return false end
    end
    return true
end

--- 原 alpha 记进旁表（不写暴雪字段），RestoreQueueArt 按值放回。
local function FadeQueueEye(btn)
    if not btn then return end
    local list = Marked(btn, "queueArt")
    if not list then
        -- 只扫一次，且必须在建徽章**之前**：自建板的 backdrop 不该被算成暴雪美术。
        list = {}
        for _, reg in ipairs(QueueArtRegions(btn)) do
            local ok, a = pcall(reg.GetAlpha, reg)
            list[#list + 1] = { region = reg, alpha = (ok and type(a) == "number" and a) or 1 }
        end
        Mark(btn, "queueArt", list)
    end
    for i = 1, #list do
        pcall(list[i].region.SetAlpha, list[i].region, 0)
    end
end

local function RestoreQueueArt(btn)
    local list = Marked(btn, "queueArt")
    if not list then return true end
    for i = 1, #list do
        if not RestoreAlpha(list[i].region, list[i].alpha) then return false end
    end
    Mark(btn, "queueArt", nil)
    return true
end

--- 每 0.5 秒：①补压被动画抬回来的 alpha；②按回父级与锚点。
--- Camelot 的 `QueueStatusButtonMixin:UpdateDefaultAnchor()` 会 ClearAllPoints + SetPoint
--- 把按钮拉回小地图默认位，**不改父级** ⇒ 只看 parent 的 HookReassert 抓不到这一下。
local function QueuePoll()
    local btn = Resolve(QUEUE_PATH)
    if not btn or not container then return end
    local saved = savedParents[btn]
    if not saved or not saved.layout or saved.restoring then return end
    FadeQueueEye(btn)
    if InCombatLockdown() then return end
    local okP, par = pcall(btn.GetParent, btn)
    local okR, rel = pcall(function()
        local _, r = btn:GetPoint(1)
        return r
    end)
    if not okR or not okP or par ~= container or rel ~= container then
        PlaceButton(btn, saved.layout)
    end
end

local function SetupQueueStatus()
    local btn = Resolve(QUEUE_PATH)
    if not btn or not container then return false end
    local layout = { "BOTTOMRIGHT", "BOTTOMRIGHT", -4, 4 }
    SaveParent(btn, layout)
    PlaceButton(btn, layout)
    HookReassert(btn)
    FadeQueueEye(btn)

    -- 徽章挂在**按钮**上：显隐完全交给暴雪（没排队时按钮 hidden=true，字符一起隐）。
    -- 板关鼠标，点击照旧落到 QueueStatusButton 自己的 OnClick / OnEnter / OnLeave。
    local glyph = Marked(btn, "glyph")
    if not glyph then
        glyph = Skin:GlyphBadge(btn, {
            w = B.WIDTH, h = B.HEIGHT, size = 10, colorKey = "bright",
        })
        if glyph then
            pcall(glyph.SetAllPoints, glyph, btn)
            Mark(btn, "glyph", glyph)
        end
    else
        Skin:GlyphBadgeOn(glyph)
    end
    pcall(btn.EnableMouse, btn, true)

    if not Marked(container, "queuePoll") then
        Mark(container, "queuePoll", true)
        Widget:PollWatch(container, QueuePoll, 0.5)
    end
    return true
end

--- QueueStatusButton 属于 LoD 的 Blizzard_QueueStatusFrame；登录那一拍可能还没建出来。
--- 挂在 UIParent 上等（1 秒一拍），一出现就接走并注销自己。
local function EnsureQueueStatus()
    if not container or not Resolve(QUEUE_PATH) then return end
    local settings = ns:GetModule("Minimap"):GetSettings()
    if settings.mapQueueStatus ~= false then SetupQueueStatus() end
    Widget:Unwatch(UIParent, EnsureQueueStatus)
end

-- ------------------------------------------------------------------ 对外接口

--- 事务式还原一个按钮。只有父级、锚点、尺寸与装饰全部写回并复核成功，调用方才删快照。
--- 失败时 `restoring` 保持为 true：重摆轮询让路，快照留到下一次脱战重试。
local function RestoreFrame(frame, saved)
    if not frame or not saved then return false, "missing snapshot" end
    saved.restoring = true
    if (type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown())
        or (type(_G.UnitAffectingCombat) == "function" and _G.UnitAffectingCombat("player")) then
        return false, "restricted"
    end

    local wasReasserting = reasserting
    reasserting = true
    local ok, restored, reason = pcall(function()
        frame:SetParent(saved.parent)
        frame:ClearAllPoints()
        for _, pt in ipairs(saved.points) do
            frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
        end
        frame:SetSize(saved.size[1], saved.size[2])

        -- pcall 成功不等于写入成功；受保护家族会静默吞掉排版，必须回读复核。
        if frame:GetParent() ~= saved.parent then return false, "parent" end
        if frame:GetWidth() ~= saved.size[1] or frame:GetHeight() ~= saved.size[2] then
            return false, "size"
        end
        if frame:GetNumPoints() ~= #saved.points then return false, "point count" end
        for i, pt in ipairs(saved.points) do
            local point, relTo, relPoint, x, y = frame:GetPoint(i)
            if point ~= pt[1] or relTo ~= pt[2] or relPoint ~= pt[3]
                or x ~= pt[4] or y ~= pt[5] then
                return false, "points"
            end
        end

        for _, info in ipairs(saved.art) do
            if not RestoreAlpha(info.region, info.alpha) then return false, "art" end
        end

        -- 徽章存在旁表里（`Mark(btn, "badge", ...)`）：以前读的是 `frame.monetBadge` 这个
        -- 从来不存在的字段，所以还原时徽章一直挂在屏幕上（review 2026-10-29）。
        local badge = Marked(frame, "badge")
        if badge and not HideDecoration(badge) then return false, "badge" end
        -- 排队按钮的动态字符徽章只藏不删（下次 Apply 复用同一块板）。
        local glyph = Marked(frame, "glyph")
        if glyph then
            Skin:GlyphBadgeOff(glyph)
            if not HideDecoration(glyph) then return false, "glyph" end
        end
        if not RestoreQueueArt(frame) then return false, "queue art" end

        -- 追踪按钮的原父框（Tracking）是被我们 alpha 0 压掉的，一并还回去。
        local oldParent = saved.parent
        if oldParent and oldParent ~= container and oldParent ~= UIParent
            and Marked(oldParent, "parked") then
            local alpha = Marked(oldParent, "parkAlpha")
            if type(oldParent.SetAlpha) ~= "function" then return false, "parked alpha" end
            oldParent:SetAlpha(type(alpha) == "number" and alpha or 1)
            if type(oldParent.GetAlpha) == "function" then
                local current = oldParent:GetAlpha()
                if current ~= (type(alpha) == "number" and alpha or 1) then
                    return false, "parked alpha"
                end
            end
            if type(oldParent.EnableMouse) == "function" then
                oldParent:EnableMouse(true)
                if type(oldParent.IsMouseEnabled) == "function" and not oldParent:IsMouseEnabled() then
                    return false, "parked mouse"
                end
            end
            Mark(oldParent, "parked", nil)
            Mark(oldParent, "parkAlpha", nil)
        end
        return true
    end)
    reasserting = wasReasserting
    if not ok then return false, "restore failed" end
    return restored, reason
end

local function StopRestorePoller()
    if not restoreSubId then return end
    Scheduler:Unregister(restoreSubId)
    restoreSubId = nil
end

local function RetryButtonRestore()
    if B:Restore() then StopRestorePoller() end
end

local function EnsureRestorePoller()
    if restoreSubId then return end
    restoreSubId = Scheduler:Every(500, RetryButtonRestore, "小地图:按钮还原重试")
end

--- 某个开关关掉时：把暴雪按钮放回原来的位置（显隐交给"暴雪集群按钮"那一组管）。
--- 返回 true 表示已还原或无需还原；false 表示快照已保留，可稍后重试。
local function RestoreOne(path)
    local frame = Resolve(path)
    if not frame then return false, "frame unavailable" end
    local saved = savedParents[frame]
    if not saved then return true end
    local ok, reason = RestoreFrame(frame, saved)
    if ok then
        savedParents[frame] = nil
        return true
    end
    EnsureRestorePoller()
    return false, reason
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
        -- 收纳按钮在 ⇒ 顺手把散落的插件图标也收进来（登记进收纳列表 + 压掉小地图那颗）。
        B:StartCollect()
    else
        RestoreOne("AddonCompartmentFrame")
        B:RestoreCollect()
    end
    if settings.mapDifficulty then
        SetupDifficulty()
    else
        if difficultyFrame then difficultyFrame:Hide() end
    end
    if settings.mapQueueStatus ~= false then
        -- 老存档没有这个键（nil ~= false ⇒ 默认开），不必写 migration。
        if not SetupQueueStatus() then
            Widget:PollWatch(UIParent, EnsureQueueStatus, 1)
        end
    else
        RestoreOne(QUEUE_PATH)
    end
end

--- 还原：把暴雪按钮搬回原来的父级与锚点，我们画的底板藏起来。
--- 返回 false 表示至少一项未完成；对应快照保留，可在限制解除后再次调用。
function B:Restore()
    -- 先把帧名收集成一张表再逐个还原：失败项保留在弱键表里，但局部数组持有强引用，
    -- 避免本轮遍历中因弱键回收而丢失重试目标。
    local frames = {}
    for frame in pairs(savedParents) do frames[#frames + 1] = frame end

    local complete = true
    for _, frame in ipairs(frames) do
        local saved = savedParents[frame]
        if saved then
            local ok = RestoreFrame(frame, saved)
            if ok then
                savedParents[frame] = nil
            else
                complete = false
            end
        end
    end
    if difficultyFrame then difficultyFrame:Hide() end
    -- 收进收纳的图标一并放回去（否则模块关了、小地图上仍然少一堆图标）。
    B:RestoreCollect()
    -- 队列的两条轮询一并摘掉：模块关了就别再按拍写暴雪按钮。
    Widget:Unwatch(UIParent, EnsureQueueStatus)
    if container then
        Widget:Unwatch(container, QueuePoll)
        Mark(container, "queuePoll", nil)
    end
    if complete then
        StopRestorePoller()
    else
        EnsureRestorePoller()
    end
    return complete
end

--- 难度会随进出副本变，单独刷新一次。
function B:UpdateDifficulty()
    UpdateDifficulty()
end

--- 主题换了，三个图标重新染色。
function B:RefreshTints()
    local tracking = Resolve("MinimapCluster.Tracking.Button")
    local trackingBadge = tracking and Marked(tracking, "badge")
    if trackingBadge then
        TintIcon(trackingBadge, trackingBadge.tintKey)
    end
    local compartment = Resolve("AddonCompartmentFrame")
    local compartmentBadge = compartment and Marked(compartment, "badge")
    if compartmentBadge then
        TintIcon(compartmentBadge, compartmentBadge.tintKey)
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
    local queue = Resolve(QUEUE_PATH)
    if queue and queue:IsMouseOver() then return true end
    if difficultyFrame and difficultyFrame:IsMouseOver() then return true end
    return false
end

--- 容器（给区域名条定位用）。
function B:Container()
    return container
end

-- ------------------------------------------------------------------ 插件图标收纳
--
-- 报障："收纳不完善 —— 收纳里有的插件，小地图上还留着自己那颗图标。"
-- 这个库（LibDBIcon-1.0）自带收纳 API，收纳按钮点开的 AddonCompartmentFrame 那张列表
-- 就是它登记的条目（不是暴雪凭空的名单）：
--   IsButtonCompartmentAvailable() / IsButtonInCompartment(name)
--   AddButtonToCompartment(name) —— 往列表登记一条，点击时转调 dataObject.OnClick
--   Hide(name) / Show(name)      —— 只显隐小地图上那一颗，**不写插件的存档**
-- 所以"收进来"= 登记 + 隐藏两件事一起做；插件迟注册、或者它自己 Refresh 又把那颗 Show 回来，
-- 由一条 1.5s 轮询纠回（一次只遍历 objects 表，很便宜）。
-- 关掉"插件收纳"时反向做：我们登记过的撤掉、我们隐藏过的放回去（不碰插件自己藏的）。

local collectSubId
local collectedNames = {}   -- 我们隐藏过的（关模块时放回去）
local addedNames = {}       -- 我们登记进收纳的（关模块时撤掉）
-- `addedNames` 只在本次会话有效，但 `AddButtonToCompartment` 会写进**插件自己的存档**
-- （`object.db.showInCompartment=true`）。不落盘记住"哪几条是我们加的"，重载后就撤不回来了
-- —— 玩家关掉收纳会看到列表里多出一条重复项。所以登记时同时记进 MonetUIDB。
local function AddedStore()
    local db = ns:DB()
    local store = db.minimapCollectAdded
    if type(store) ~= "table" then
        store = {}
        db.minimapCollectAdded = store
    end
    return store
end

local function LibDBIcon()
    local stub = _G.LibStub
    if type(stub) ~= "table" or type(stub.GetLibrary) ~= "function" then return nil end
    local ok, lib = pcall(stub.GetLibrary, stub, "LibDBIcon-1.0", true)
    if ok and type(lib) == "table" then return lib end
    return nil
end

local function ShownSafe(frame)
    local ok, value = pcall(frame.IsShown, frame)
    if not ok then return false end
    return Secrets.Bool(value, false)
end

--- 收纳列表里那条同名条目。
--- `lib:IsButtonInCompartment(name)` 只认库自己写进去的 `object.db.showInCompartment`，
--- 而不少插件是直接 `AddonCompartmentFrame:RegisterAddon(...)` 登记的（Lueur 就是），
--- 那条不等 true —— 只看库的标志会**再补一条同名条目**，玩家在列表里看到两个 Lueur。
local function CompartmentEntry(name)
    local regs = _G.AddonCompartmentFrame and _G.AddonCompartmentFrame.registeredAddons
    if type(regs) ~= "table" then return nil end
    for i = 1, #regs do
        local entry = regs[i]
        if type(entry) == "table" and entry.text == name then return entry end
    end
    return nil
end

--- 一颗图标：没登记进收纳就登记；小地图上那颗还亮着就压掉。
local function CollectOne(lib, name)
    if type(lib.objects) ~= "table" or not lib.objects[name] then return end
    if type(lib.IsButtonCompartmentAvailable) == "function"
        and not lib:IsButtonCompartmentAvailable() then
        return
    end
    if type(lib.GetMinimapButton) ~= "function" then return end
    local btn = lib:GetMinimapButton(name)
    if not btn then return end
    local entry = CompartmentEntry(name)
    if type(lib.IsButtonInCompartment) == "function" and not lib:IsButtonInCompartment(name)
        and not entry then
        if pcall(lib.AddButtonToCompartment, lib, name) then
            addedNames[name] = true
            AddedStore()[name] = true
        end
    elseif entry and entry.registerForAnyClick then
        -- 这一条是**库**写的（只有库登记的那条带 registerForAnyClick）。可能不是本会话加的
        -- （上次会话加完存盘了），也记进存档：关掉收纳时才有归属可撤。
        if not AddedStore()[name] then
            AddedStore()[name] = true
            addedNames[name] = true
        end
    end
    if ShownSafe(btn) then
        if pcall(lib.Hide, lib, name) then collectedNames[name] = true end
    end
end

--- 把当前所有 LibDBIcon 图标收进收纳（幂等，可反复调用）。返回注册总数。
function B:CollectIcons()
    local lib = LibDBIcon()
    if not lib or type(lib.objects) ~= "table" then return 0 end
    -- 重载后 `addedNames` 是空的，但从存档里能捞回来（关掉收纳时要撤销的就是这些）。
    for name in pairs(AddedStore()) do addedNames[name] = true end
    local n = 0
    for name in pairs(lib.objects) do
        n = n + 1
        CollectOne(lib, name)
    end
    return n
end

--- 不是 LibDBIcon 画的、但**自己往收纳列表登记了条目、又在小地图上留着一颗按钮**的图标。
--- LibDBIcon 那条路只覆盖用库的插件；直接调 `AddonCompartmentFrame:RegisterAddon` 的插件
--- 不在 `lib.objects` 里，得点名收。名单为空也不影响别人（没装的框体是 nil）。
local EXTRA_BUTTONS = {
    "WoWBridgeMinimapButton",   -- 无限工坊 · 开发组件（收纳里有条目，按钮仍在 Minimap 上）
}
local extraHidden = {}          -- 我们藏过的（恢复时放回去）

local function CollectExtras()
    for i = 1, #EXTRA_BUTTONS do
        local name = EXTRA_BUTTONS[i]
        local frame = rawget(_G, name)
        if type(frame) == "table" and frame.Hide and Widget:Readable(frame) then
            local okShow, shown = pcall(frame.IsShown, frame)
            if okShow and Secrets.Bool(shown, false) then
                if pcall(frame.Hide, frame) then extraHidden[name] = true end
            end
        end
    end
end

local function RestoreExtras()
    for name in pairs(extraHidden) do
        local frame = rawget(_G, name)
        if type(frame) == "table" and frame.Show then pcall(frame.Show, frame) end
    end
    extraHidden = {}
end

--- 轮询：插件迟注册（登录后几秒才成表）与它自己 Refresh 都要纠回。
--- 不再问 `Minimap:IsActive()`：这条轮询只在 StartCollect 里挂、在 RestoreCollect 里摘，
--- 关闭模块走的是 RestoreCollect 那条路，别在这里多一道会漏的门（热载时 active 还没置位）。
local function TickCollect()
    B:CollectIcons()
    CollectExtras()
end

function B:StartCollect()
    B:CollectIcons()
    CollectExtras()
    if not collectSubId then
        collectSubId = Scheduler:Every(1500, TickCollect, "小地图:插件图标收纳")
    end
end

function B:RestoreCollect()
    local lib = LibDBIcon()
    if lib then
        for name in pairs(collectedNames) do
            pcall(lib.Show, lib, name)
        end
        if type(lib.RemoveButtonFromCompartment) == "function" then
            local store = AddedStore()
            for name in pairs(addedNames) do
                pcall(lib.RemoveButtonFromCompartment, lib, name)
            end
            for name in pairs(store) do
                pcall(lib.RemoveButtonFromCompartment, lib, name)
            end
            for name in pairs(store) do store[name] = nil end
        end
    end
    RestoreExtras()
    collectedNames, addedNames = {}, {}
    if collectSubId then
        Scheduler:Unregister(collectSubId)
        collectSubId = nil
    end
end

--- `/mui minimap collect`：收纳现状（每颗：在不在收纳列表、小地图上还亮不亮、是不是我们藏的）。
function B:ProbeCollect()
    local lib = LibDBIcon()
    if not lib then
        ns:Print("本机没有 LibDBIcon-1.0（没有插件用它画小地图图标），没什么可收的。")
        return
    end
    local avail = type(lib.IsButtonCompartmentAvailable) == "function"
        and lib:IsButtonCompartmentAvailable()
    ns:Print(("收纳按钮可用=%s · 轮询=%s"):format(tostring(avail and true or false),
        collectSubId and "运行中" or "停"))
    local n = 0
    for name in pairs(lib.objects or {}) do
        n = n + 1
        local btn = lib.GetMinimapButton and lib:GetMinimapButton(name)
        local inC = type(lib.IsButtonInCompartment) == "function"
            and lib:IsButtonInCompartment(name)
        ns:Print(("  %s：收纳=%s  小地图上=%s  我们藏的=%s"):format(
            tostring(name), tostring(inC and true or false),
            btn and tostring(ShownSafe(btn)) or "无按钮",
            tostring(collectedNames[name] and true or false)))
    end
    ns:Print(("  共 %d 颗（LibDBIcon 注册表）"):format(n))
    for i = 1, #EXTRA_BUTTONS do
        local name = EXTRA_BUTTONS[i]
        local frame = rawget(_G, name)
        local state = "不存在"
        if type(frame) == "table" then
            local okShow, shown = pcall(frame.IsShown, frame)
            state = okShow and tostring(Secrets.Bool(shown, false)) or "读不出"
        end
        ns:Print(("  %s（非 LibDBIcon）：小地图上=%s  我们藏的=%s"):format(
            name, state, tostring(extraHidden[name] and true or false)))
    end
end

--- `/mui minimap buttons`：盘点**散落在小地图周围的插件图标**（LibDBIcon 一类）。
---
--- 报障口径是"收纳不完善，收进去的插件仍然有自己的图标在外头" —— 先按真名/父级/锚点把它们列出来，
--- 才知道哪些是我们该收的、哪些是暴雪自己的（追踪 / 收纳 / 排队 / 日历 / 邮件 / 缩放）。
--- 判据用两条：① 名字带 `LibDBIcon`（这个库的按钮命名是 `LibDBIcon10_<插件名>`，是硬信号）；
--- ② 没有名字的（有些插件自绘）再看"挂在 Minimap / MinimapCluster 上 + 带 OnClick + 尺寸 ≤ 48"。
function B:ScanMinimapButtons()
    local rows, seen = {}, {}
    local where = function(relTo)
        if type(relTo) == "string" then return relTo end
        if type(relTo) == "table" then
            local okN, n2 = pcall(relTo.GetName, relTo)
            return (okN and n2) or "(匿名帧)"
        end
        return "?"
    end
    local function pointsText(frame)
        local n = frame.GetNumPoints and frame:GetNumPoints() or 0
        local out = {}
        for i = 1, math.min(n, 3) do
            local ok, point, relTo, relPoint, x, y = pcall(frame.GetPoint, frame, i)
            if ok and point then
                out[#out + 1] = ("%s→%s%s(%s,%s)"):format(point, tostring(relPoint), where(relTo),
                    tostring(x), tostring(y))
            end
        end
        if n > 3 then out[#out + 1] = ("…共%d点"):format(n) end
        return #out > 0 and table.concat(out, " ") or "无锚点"
    end
    --- 锚点（任意一点）是否指向小地图那三颗框；顺带回"它就是小地图的直接子框"。
    local function anchoredToMap(frame)
        local n = frame.GetNumPoints and frame:GetNumPoints() or 0
        for i = 1, math.min(n, 3) do
            local ok, _, relTo = pcall(frame.GetPoint, frame, i)
            if ok then
                local rn = where(relTo)
                if rn == "Minimap" or rn == "MinimapCluster" or rn == "MinimapBackdrop" then return true end
            end
        end
        return false
    end
    local function consider(frame)
        if not frame or seen[frame] then return end
        seen[frame] = true
        local okN, name = pcall(frame.GetName, frame)
        name = okN and name or nil
        local okP, p = pcall(frame.GetParent, frame)
        local parent = "?"
        if okP and p then
            local okPN, pn = pcall(p.GetName, p)
            parent = (okPN and pn) or "(匿名父级)"
        end
        local libdbi = type(name) == "string" and name:find("^LibDBIcon") ~= nil
        local hasClick = false
        if frame.GetScript then
            local okS, script = pcall(frame.GetScript, frame, "OnClick")
            hasClick = okS and type(script) == "function"
        end
        local okW, w = pcall(frame.GetWidth, frame)
        local okH, h = pcall(frame.GetHeight, frame)
        -- 受限窗口里宽高可能是机密数字，拿去做 `w > 0` 比较会抛（AGENTS：数字只有 ==nil / 真值 / tostring 稳）。
        w, h = (okW and Secrets.Number(w)) or 0, (okH and Secrets.Number(h)) or 0
        local nearMap = anchoredToMap(frame)
        -- 判据口径（2026-11-26 第二版，第一版只看子树时 0 命中）：
        -- ① 名字以 LibDBIcon 开头（即使它被挂到 UIParent / 别的容器上也能认出来）；
        -- ② 任何带 OnClick、尺寸 ≤ 48、锚点指向 Minimap / MinimapCluster / MinimapBackdrop 的按钮；
        -- ③ 名字里带 Minimap / MinimapIcon 的按钮（有些插件自绘，不挂锚点只按名字能认）。
        local byName = type(name) == "string" and (name:find("Minimap") ~= nil or name:find("MinimapIcon") ~= nil)
        if libdbi or (hasClick and nearMap and w > 0 and w <= 48 and h <= 48 and h > 0) or (byName and hasClick) then
            local okShown, shownRaw = pcall(frame.IsShown, frame)
            local shown = okShown and Secrets.Bool(shownRaw, false) or false
            local okAlpha, alpha = pcall(frame.GetAlpha, frame)
            if not okAlpha then alpha = nil end
            if Secrets and type(Secrets.CanRead) == "function" then
                if not Secrets.CanRead(alpha) then alpha = nil end
            end
            rows[#rows + 1] = {
                frame = frame,
                name = type(name) == "string" and name or "(无名)",
                libdbi = libdbi,
                parent = parent,
                point = pointsText(frame),
                w = w, h = h,
                shown = shown,
                alpha = alpha,
            }
        end
    end
    -- 第一趟：小地图那棵子树（LibDBIcon 的按钮通常直接挂 Minimap）。
    local function walk(frame, depth)
        if not frame or depth > 4 then return end
        local okC, children = ns.Widget:ChildrenOf(frame)
        if not okC or type(children) ~= "table" then return end
        for _, child in ipairs(children) do
            consider(child)
            walk(child, depth + 1)
        end
    end
    for _, root in ipairs({ _G.Minimap, _G.MinimapCluster, _G.MinimapBackdrop }) do
        if root then
            consider(root)
            walk(root, 1)
        end
    end
    -- 第二趟：全界面扫（有些插件把按钮挂在 UIParent 或自己的容器上，只靠锚点指向小地图）。
    if type(EnumerateFrames) == "function" then
        local frame = EnumerateFrames()
        while frame do
            consider(frame)
            frame = EnumerateFrames(frame)
        end
    end
    local out = {}
    for i, r in ipairs(rows) do
        local size = (r.w and r.h) and ("%dx%d"):format(math.floor(r.w), math.floor(r.h)) or "-"
        local alpha = r.alpha and ("%.2f"):format(r.alpha) or "-"
        out[#out + 1] = ("  %2d. %s%s  %s  父=%s  alpha=%s  显示=%s  锚点=%s"):format(
            i, r.name, r.libdbi and "（LibDBIcon）" or "", size, r.parent, alpha, tostring(r.shown), r.point)
    end
    return rows, out
end

EventBus:Register("MONETUI_THEME_CHANGED", function()
    if ns:GetModule("Minimap"):IsActive() then B:RefreshTints() end
end)

ns:GetModule("Minimap").buttons = B
