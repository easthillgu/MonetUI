-- Modules/BuffFrame/BuffFrame.lua
-- Player buff / debuff display: a compact themed grid anchored under the minimap, replacing the Blizzard aura frame.
-- Aura data comes from C_UnitAuras; when the client marks auras secret the module steps aside instead of erroring.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local Math     = ns.Math
local EventBus = ns.EventBus
local Scheduler = ns.Scheduler

local M = { name = "BuffFrame" }

--- 战斗中为真。**优先问 Core 的 `ns:InCombat()`**：本客户端先派发 PLAYER_REGEN_*、之后才翻
--- `InCombatLockdown()`，而 `ns:AfterCombat` 的排空就跑在那次派发里 —— 拿原始标志当门，
--- 战斗光环容器会把自己再排回队列，第一次脱战建不出来（战斗里没图标，得再打一场）。
local function InCombat()
    if type(ns.InCombat) == "function" then return ns:InCombat() end
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown()
end

local ICON_GAP    = 4
local MAX_AURAS   = 32
-- 折叠：与暴雪同一条 90 秒门槛（AuraUtil.BUFF_DURATION_WARNING_TIME），机密期只读暴雪自己
-- 算好的 numHideableBuffs，不碰光环字段。战斗里引擎容器按这个上限收窄到短时 buff。
local COLLAPSE_THRESHOLD  = 90
local COLLAPSE_VISIBLE_CAP = 4
local COLLAPSE_GROUP_KEY  = "monetPlayerCombatBuffs"

-- A full buff row (10*32-4) and debuff row (8*40-4) both land on 316px so their right edges line up; per-row counts derive from that budget, never hardcoded.
local BUFF_SIZE   = 28
local DEBUFF_SIZE = 36
local ROW_WIDTH   = 316

local AURA_GAP    = 33   -- Andromeda's UI_GAP, used for the top-left inset

--- How many icons of this size fit in one full row.
local function PerRow(size)
    return math.max(1, math.floor((ROW_WIDTH + ICON_GAP) / (size + ICON_GAP)))
end

--- Resize a container to exactly hug the icons it currently shows.
local function FitContainer(container, count, size)
    if count <= 0 then
        container:SetSize(0, 0)
        return
    end
    local stride = size + ICON_GAP
    local perRow = PerRow(size)
    local rows = math.ceil(count / perRow)
    local cols = math.min(count, perRow)
    container:SetSize(
        cols * stride - ICON_GAP,
        rows * stride - ICON_GAP)
end

local buffButtons, procButtons, debuffButtons = {}, {}, {}
local buffContainer, procContainer, debuffContainer
local combatBuffs   -- 前置声明：折叠上限的 helper 在容器创建之前就引用它
local combatAurasEnabled = false -- 只有完整容器组真正 Enable 后才为真；失败/模块禁用时必须是 false
local collapseButton

local function Collapsed()
    local db = ns:DB()
    if type(db.buffFrame) ~= "table" then return true end
    return db.buffFrame.collapsed ~= false
end

local function SetCollapsed(on)
    local db = ns:DB()
    if type(db.buffFrame) ~= "table" then db.buffFrame = {} end
    db.buffFrame.collapsed = on and true or false
end

--- 战斗容器的显示上限：折叠时只留短时 buff + 附魔槽，展开时恢复满格。
local function ApplyCombatCap()
    if not combatAurasEnabled or not combatBuffs then return end
    local cap = Collapsed() and COLLAPSE_VISIBLE_CAP or (MAX_AURAS - 3)
    pcall(combatBuffs.SetAuraGroupMaxFrameCount, combatBuffs, COLLAPSE_GROUP_KEY, cap)
end

--- "+N" / "-" 按钮：收起时显示 "+N"（点击展开），展开且存在可折叠 buff 时显示 "-"（点击收回）。
--- 位置按**当前显示的格数**推算（不锚引擎容器，它的矩形在机密期读不出来）。
local function UpdateCollapseButton(visible, hidden, foldable)
    if not collapseButton then return end
    -- 没有任何可折叠的 buff（永久 / 长时 / 读不出）就整颗藏起来：展开态下没东西可收。
    if (foldable or 0) <= 0 or visible < 0 then
        collapseButton:Hide()
        return
    end
    if hidden > 0 then
        collapseButton.text:SetText("+" .. tostring(hidden))
    else
        collapseButton.text:SetText("-")
    end
    local perRow = PerRow(BUFF_SIZE)
    local row = math.floor(visible / perRow)
    local col = visible % perRow
    local stride = BUFF_SIZE + ICON_GAP
    collapseButton:ClearAllPoints()
    collapseButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
        AURA_GAP + col * stride, -(AURA_GAP + row * stride))
    collapseButton:Show()
end

local function CreateCollapseButton()
    -- kind 必须是 "Button"：Frame 不支持 OnClick 脚本（2026-11-22 重载实判：
    -- "script type not supported by this object"，BuffFrame 整个模块初始化中断）。
    local b = Widget:CreateFrame("MonetUICollapseButton", UIParent, BUFF_SIZE, BUFF_SIZE, nil, "Button")
    b.text = Widget:Font(b, 12, "pixel", "white", "CENTER")
    b.text:SetAllPoints()
    b:EnableMouse(true)
    b:RegisterForClicks("AnyUp")
    b:SetScript("OnClick", function()
        SetCollapsed(not Collapsed())
        ApplyCombatCap()
        M:Update()
    end)
    b:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")
        pcall(tip.SetText, tip, Collapsed() and "展开增益" or "折叠增益")
        pcall(tip.Show, tip)
    end)
    b:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip then pcall(tip.Hide, tip) end
    end)
    b:Hide()
    return b
end
local pending
-- 上一轮成功渲染的结果：读取被机密光环打断时用它兜底，免得整块 Buff 跟着 proc 一起闪没。
local lastBuffs, lastDebuffs = {}, {}

--- Read + sort the auras of one unit.
--- 逐索引 pcall：私密/机密光环（不少 proc 属于这一类）会让 GetAuraDataByIndex 直接抛出
--- "attempt to access a secret value"。以前整轮读取包在一个 Measure 里，一个坏索引就把
--- 已读到的全丢掉 → 三个容器一起变空，表现就是"战斗中一出 proc 整块 Buff 消失"。
--- 现在撞上坏索引就停在原地，把手上的部分交出去，第二个返回值标记"这轮没读全"。
local function CollectAuras(unit, filter)
    local list = {}
    if not Secrets.CanReadAuras() then return list, false end

    local complete = true
    for index = 1, MAX_AURAS do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
        if not ok then
            complete = false
            break
        end
        if type(aura) ~= "table" then break end
        list[#list + 1] = aura
    end

    -- 排序也用 pcall：比较器里一旦漏进机密值，table.sort 的报错会连带中断调用方。
    pcall(table.sort, list, function(a, b)
        local ea = Secrets.Number(a.expirationTime) or math.huge
        local eb = Secrets.Number(b.expirationTime) or math.huge
        if ea ~= eb then return ea < eb end
        return (Secrets.Number(a.spellId) or 0) < (Secrets.Number(b.spellId) or 0)
    end)

    return list, complete
end

--- 图标钮的视觉底座（光环行 / 武器附魔行共用同一套规格）：
--- 尺寸、内缩 1px 边框、裁切图标、Cooldown 计时、右下角堆叠数。
--- 脚本（提示 / 右键）由各自的工厂补，数据源不同。
local function CreateIconButton(parent, size)
    local button = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    button:SetSize(size, size)
    button.size = size

    -- Dig the icon in by exactly the theme border: it is painted inside the frame's rect
    -- (`thickness * Media:Mult()` UI units wide), so an icon at SetAllPoints() would bury it.
    local px = ns.Media:Mult()
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", px, -px)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -px, px)
    ns.Skin:CropIcon(button.icon, 0.08, 0.92, 0.08, 0.92)

    -- The swipe follows the icon rather than the button, so it never tints the border band.
    button.cooldown = Widget:Cooldown(button)
    button.cooldown:SetAllPoints(button.icon)
    -- 时长交给 Cooldown 模块渲染：它按剩余时间自动缩放 + 变色（分钟蓝、小时绿、最后几秒
    -- 变红并放大），和动作条冷却完全同一套；模块缺席或关闭时才退回 Blizzard 那行死白数字。
    -- 我们自己不再画 timer（以前那版是固定金色、不会变色）。
    local cooldowns = ns:GetModule("Cooldown")
    if cooldowns and cooldowns.StyleCooldown then
        -- compact = true：28px 的图标放不下 "31:50"，用 "31m" 这种短格式；
        -- 颜色（分钟蓝 / 秒红）、临近到期放大等逻辑和动作条冷却是同一套。
        -- 字体用点阵苹方（`pixel` 键）：和正文同一套，12px 网格下字形最清晰。
        -- 2026-11-01 试过 Super Effective（12px 图标上 "2M" 就吃掉近 80%）和一款 16px 点阵宋
        -- （小字号还要额外维护 10px 下限，不值），实机都不满意，字体文件已删。
        cooldowns:StyleCooldown(button.cooldown, 12, true, "pixel")
    end

    -- HUD 堆叠数恒纯白、不随主题：走 "white" 颜色键（Widget:PaletteColor 唯一键表）。
    button.count = Widget:Font(button, 12, "pixel", "white", "RIGHT")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

    Widget:Theme(button, { thickness = 1, bgAlpha = 0.6 })

    return button
end

local function CreateAuraButton(parent, size)
    local button = CreateIconButton(parent, size)

    -- 自绘的按钮没有暴雪那套提示与右键：自己写一份。
    -- 提示给名字、层数、剩余时间，并说明右键可以取消。
    button:EnableMouse(true)
    button:SetScript("OnEnter", function(self)
        local aura = self.aura
        if not aura then return end
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")

        -- 提示内容按**这一颗按钮绑定的 auraInstanceID** 问客户端，哪怕光环表被换肤 / 重排过，
        -- 名字、层数、说明也永远和图标是同一条（NDui Forever 与暴雪引擎同款口径）。
        -- self.aura 只作兜底：老索引查不到时才用自拼文字。
        local id = Secrets.Number(aura.auraInstanceID)
        if id then
            local ok
            if self.auraFilter == "HARMFUL" and type(tip.SetUnitDebuffByAuraInstanceID) == "function" then
                ok = pcall(tip.SetUnitDebuffByAuraInstanceID, tip, "player", id)
            elseif type(tip.SetUnitAuraByAuraInstanceID) == "function" then
                ok = pcall(tip.SetUnitAuraByAuraInstanceID, tip, "player", id, "HELPFUL")
            end
            if ok then
                pcall(tip.Show, tip)
                return
            end
        end

        local name = aura.name
        if not name then
            local spellId = Secrets.Number(aura.spellId)
            if spellId and _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
                local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
                if ok and type(info) == "table" then name = info.name end
            end
        end
        pcall(tip.SetText, tip, name or "增益")

        local count = Secrets.Number(aura.applications)
        if count and count > 1 then
            pcall(tip.AddLine, tip, "层数：" .. tostring(count), 1, 1, 1)
        end
        local duration = Secrets.Number(aura.duration)
        if duration and duration > 0 then -- TAINT-OK: 上游 CollectAuras 只在 Secrets.CanReadAuras() 为真时喂明文 duration/expiration
            pcall(tip.AddLine, tip, "持续：" .. tostring(Math:DurationText(duration)), 1, 1, 1)
        end
        pcall(tip.AddLine, tip, "右键取消", 0.6, 0.6, 0.6)
        pcall(tip.Show, tip)
    end)
    button:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip then pcall(tip.Hide, tip) end
    end)
    -- 右键取消：OnMouseDown 而不是 OnClick —— 自绘的是 Frame，OnClick 不是它的脚本名。
    button:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "RightButton" then return end
        local aura = self.aura
        if not aura then return end
        local id = Secrets.Number(aura.auraInstanceID)
        if not id then return end
        if _G.C_UnitAuras and type(C_UnitAuras.CancelAuraByInstanceID) == "function" then -- TAINT-OK: 真值测试的是全局表存在性,不涉秘值
            pcall(C_UnitAuras.CancelAuraByInstanceID, "player", id)
        end
    end)

    button:Hide()
    return button
end

local function EnsureButtons(list, parent, needed, size, factory)
    factory = factory or CreateAuraButton
    for i = #list + 1, needed do
        list[i] = factory(parent, size)
    end
    for i = needed + 1, #list do
        list[i]:Hide()
    end
end

local function ShowAura(button, aura, index, filter)
    local size = button.size
    local perRow = PerRow(size)
    local stride = size + ICON_GAP
    local column = (index - 1) % perRow
    local row = math.floor((index - 1) / perRow)

    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", button:GetParent(), "TOPLEFT",
        column * stride, -row * stride)

    -- Show first: everything below must be allowed to fail without leaving the button stuck hidden.
    button:Show()

    button.icon:SetTexture(aura.icon or aura.spellId)

    local count = Secrets.Number(aura.applications)
    if count and count > 1 then
        button.count:SetText(count)
        button.count:Show()
    else
        button.count:Hide()
    end

    local duration = Secrets.Number(aura.duration)
    local expiration = Secrets.Number(aura.expirationTime)
    local remaining = (duration and expiration) and (expiration - GetTime()) or nil -- TAINT-OK: 同上,CanReadAuras 总闸后才进来(duration/expiration 均明文)

    if duration and duration > 0 and expiration and remaining and remaining > 0 then -- TAINT-OK: CanReadAuras 总闸(Update:474)
        -- 时长文本由 Cooldown 模块接管（见 CreateAuraButton），这里只驱动冷却本身：
        -- 模块的 tick 会读这个冷却的剩余时间，按大小换颜色 / 放大。
        -- SetCooldown is a protected method; never let it abort the update.
        if not pcall(button.cooldown.SetCooldown, button.cooldown, expiration - duration, duration) then -- TAINT-OK: CanReadAuras 总闸明文值;pcall 包裹兜底
            pcall(button.cooldown.Clear, button.cooldown)
        end
    else
        pcall(button.cooldown.Clear, button.cooldown)
    end

    local r, g, b = Color:GetBorder()
    if Secrets.Bool(aura.isHarmful, false) then
        r, g, b = Color:GetDanger()
    end
    if button.SetBackdropBorderColor then
        button:SetBackdropBorderColor(r, g, b, 0.9)
    end

    button.auraInstanceID = aura.auraInstanceID
    button.aura = aura
    button.auraFilter = filter or "HELPFUL"
end

local function UpdateRow(list, parent, auras, size, filter)
    local needed = math.min(#auras, MAX_AURAS)
    EnsureButtons(list, parent, needed, size)

    for index = 1, needed do
        Secrets.Measure(ShowAura, list[index], auras[index], index, filter)
    end
end

local function HideContainer(container)
    if not container then return end
    container:Hide()
end

--- 光环补扫账本（`Auras.lua` 的 `fitGroups`）里"我们这一组"的开/关。
--- 本模块给引擎按钮上样式走的是 `ns.AuraButtonStyle(button, kind, spec)` —— **三个参、
--- 不传 owner**，按 `FitGroup` 里 `owner or "external"` 的约定全部记在 `"external"` 这一组。
--- 那一组的 `mounted` 默认就是 true（第一次登记按钮时 `FitGroup` 建组即置真），没人销账的话
--- `HasAuraFitWork()` 永远为真 → 那条 1 秒补扫 ticker 在按完任何一个按钮之后**永不可取消**，
--- 屏幕上一个光环都没有也照跑。所以必须在本模块自己的生命周期边界上成对销/建。
--- 注意不要接进 `HideContainer`：它只收 procContainer/debuffContainer（我们脱战自绘那两行，
--- 战斗开始时才藏），而 `"external"` 的按钮属于常显的战斗引擎容器 —— 在那里销账恰好把
--- 补扫在"按钮正要显示"的那一刻关掉。
--- 调用前置判类型 + pcall：Auras 未加载/未导出时不能报错。只动我们自己的表，
--- 不碰暴雪对象、不吃战斗锁定。
local function SetExternalAuraFit(on)
    if type(ns.AuraFitMounted) ~= "function" then return end
    pcall(ns.AuraFitMounted, on and true or false, "external")
end

--- 把玩家的 buff 拆成"光环类"和"触发类"两组。
--- 判据照抄暴雪 BuffFrame 的 hideUnlessExpanded（BuffFrame.lua:640）：
---   duration == 0（永久光环）/ expirationTime == 0 / 剩余 > BUFF_DURATION_WARNING_TIME(=90s)
--- 算**光环类**（暴雪那边可折叠），其余（临时、触发的 proc、快到期的）算**触发类**。
--- 分成两行的理由：这两类寿命特征完全不同 —— 光环类基本不动，触发类每几秒来去一次；
--- 混在一行里，一个 proc 冒出来就会把整排光环顶走一格。
--- 读不出数值（保密/异常）时按"光环类"处理：宁可不动，也不要每次刷新都跳行。
local PROC_THRESHOLD = _G.BUFF_DURATION_WARNING_TIME or 90

local function SplitBuffs(buffs)
    local auras, procs = {}, {}
    local now = GetTime()
    for i = 1, #buffs do
        local aura = buffs[i]
        local duration = Secrets.Number(aura.duration)
        local expiration = Secrets.Number(aura.expirationTime)
        local foldable = true
        if duration ~= nil and expiration ~= nil then -- TAINT-OK: CanReadAuras 总闸明文值
            if duration > 0 and expiration > 0 then -- TAINT-OK: 同上
                foldable = (expiration - now) > PROC_THRESHOLD
            end
        end
        if foldable then
            auras[#auras + 1] = aura
        else
            procs[#procs + 1] = aura
        end
    end
    return auras, procs
end

-- ============================================================================
-- 战斗中的玩家光环：**引擎 AuraContainer 顶班 + 我们的皮肤**（2026-10-25 二期，按 ArcAuras
-- 的实机纪律重做；一期"交给暴雪原生框"保留为兜底）
-- ----------------------------------------------------------------------------
-- 背景：战斗中客户端把光环数据标成机密，插件**硬禁读**——
--   C_UnitAuras.GetAuraDataByIndex → "Auras cannot be accessed when secret while tainted by 'MonetUI'"
-- 所以自绘网格在战斗里没有数据源；唯一能拿到实时数据的是客户端自己（引擎 AuraContainer）。
--
-- 一期为什么失败（判例，别再犯）：
--   1) 容器创建后 Hide() 再在战斗里 Show()：引擎的首次布局/刷新从未跑过 → 整块空白
--      （补 UpdateAllAuras 后已有光环可见）；
--   2) 战斗中**新建的按钮**（新 proc）执行 initializeFrame 里的换肤时，整段被一个 pcall
--      包着：任何一步（时长染色曲线等）抛错就**连 SetIcon 一起跳过** → 按钮在、能悬停、
--      没有图标。
--
-- 二期做法（对照 ArcAuras `AD_DriverAura.lua:777-883`、`AD_DriverUnitAuras.lua:354-386`）：
--   * 容器在**登录/脱战**时建好（战斗里建容器引擎会拒绝），`SetEnabled(true)` 让它参与引擎流程；
--   * 按钮样式改成**必需件先注册**（SetIcon / SetDurationCooldown / SetApplicationCount），
--     装饰件（边框 / 时长文本 / 染色）排在后面且各自 pcall 隔离 —— 任何装饰失败都不再
--     影响"图标是否注册"（见 UnitFrames `StyleAuraButton`）；
--   * 机密期不做颜色曲线（`C_CurveUtil` 会被拒），退回冷却自带数字；
--   * 引擎容器不可用时（建不出来）自动退回一期方案：暴雪原生 Buff 框 alpha 1 顶上。
-- ============================================================================

local combatDebuffs
local combatMode = false
local combatWarned = false
local SuppressBlizzard   -- 前置声明：SetCombatMode / SuppressBlizzard 互引用

--- AuraContainer 属于 LoD 插件，没加载时 CreateFrame 拿不到那个模板。
local function EnsureAuraContainerAddOn()
    local C = _G.C_AddOns
    if not C or type(C.LoadAddOn) ~= "function" then return false end
    local ok, loaded = pcall(C.IsAddOnLoaded, "Blizzard_AuraContainer")
    if not ok then return false end
    if not loaded and not pcall(C.LoadAddOn, "Blizzard_AuraContainer") then return false end
    return true
end

-- 两代 API：Flow* 是新名字，AuraLayout* 是旧名字；新名优先、旧名兜底、都没有就跳过。
local function FlowCall(container, newName, oldName, ...)
    local f = container[newName]
    if type(f) ~= "function" and oldName then f = container[oldName] end
    if type(f) ~= "function" then return false end
    return pcall(f, container, ...)
end

--- 贴左上、向右长、满行往下换行。
local function ApplyCombatFlow(container, size)
    local perRow = PerRow(size)
    -- 引擎判换行时会多算一个 elementSpacing，所以行宽要多给一格间距（见 UnitFrames 的同名注释）。
    local lineSize = perRow * size + perRow * ICON_GAP

    FlowCall(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint", "TOPLEFT")
    local flow = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    local grown = false
    if type(flow) == "table" and flow.Right ~= nil and flow.Down ~= nil then
        grown = FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection",
            flow.Right, flow.Down)
    end
    if not grown then
        FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection", "RIGHT", "DOWN")
    end
    local axes = _G.AnchorUtil and _G.AnchorUtil.FlowLayoutAxis
    if axes and type(container.SetFlowLayoutAxis) == "function" then
        pcall(container.SetFlowLayoutAxis, container, axes.Horizontal)
    end
    FlowCall(container, "SetFlowLayoutElementSpacing", "SetAuraLayoutElementSpacing", ICON_GAP)
    FlowCall(container, "SetFlowLayoutLineSpacing", "SetAuraLayoutLineSpacing", ICON_GAP)
    FlowCall(container, "SetFlowLayoutMaximumLineSize", "SetAuraLayoutRowWidth", lineSize)
end

local function SetCombatAuraEnabled(container, enabled)
    if type(container.SetEnabled) ~= "function" then return true end
    return pcall(container.SetEnabled, container, enabled and true or false)
end

--- 失败容器必须真正退出引擎刷新；Hide/alpha=0 都不会停止 SetEnabled(true) 的容器。
local function DiscardCombatAura(container)
    if not container then return end
    SetCombatAuraEnabled(container, false)
    pcall(container.Hide, container)
end

local function SetCombatContainersEnabled(enabled)
    local ok = true
    for _, container in ipairs({ combatBuffs, combatDebuffs }) do
        if container and not SetCombatAuraEnabled(container, enabled) then ok = false end
    end
    return ok
end

local function CreateCombatAura(frameName, key, filter, size, kind)
    if not EnsureAuraContainerAddOn() then
        return nil, "Blizzard_AuraContainer 未加载"
    end
    local ok, container = pcall(CreateFrame, "AuraContainer", frameName, UIParent, "CustomAuraContainerTemplate")
    if not ok or type(container) ~= "table" then
        return nil, "CreateFrame(AuraContainer) 失败（模板可能不存在）"
    end

    -- 引擎要一个可渲染的矩形才会跑第一次布局。
    if not pcall(container.SetSize, container, 1, 1) then
        DiscardCombatAura(container)
        return nil, "SetSize 失败"
    end
    ApplyCombatFlow(container, size)

    local styleButton = function(button)
        pcall(function()
            if type(ns.AuraButtonStyle) == "function" then
                local pad = ns.Media and ns.Media:Mult() or 1
                if type(pad) ~= "number" or pad <= 0 then pad = 1 end
                ns.AuraButtonStyle(button, kind, {
                    width = size, height = size,
                    crop = { 0.08, 0.92, 0.08, 0.92 },
                    iconInset = pad,
                    textSize = 12,
                    fontKey = "pixel",
                    borderInside = true,
                })
            end
        end)
    end
    local opts = {
        -- 三个附魔槽会额外占格，预留出来，免得一排塞满后换行把 debuff 行顶偏。
        maxFrameCount = MAX_AURAS - (kind == "buff" and 3 or 0),
        candidateFilters = {},              -- 空表 = 不设白名单，引擎自己决定显示什么
        layout = {
            elementSpacing = ICON_GAP,
            lineSpacing    = ICON_GAP,
            elementWidth   = size,
            elementHeight  = size,
            layoutIndex    = 1,
        },
        -- 按钮样式与目标框共用。关键：StyleAuraButton 现在**必需件先注册**，装饰失败不影响图标。
        initializeFrame = styleButton,
    }
    local sortMethod = _G.AuraContainerSortMethod
    if type(sortMethod) == "table" then
        -- 战斗中引擎只有一条流式排（不支持"按剩余时长分组"：过滤项只有 maxDuration 上限，
        -- 没有下限），所以用**按到期时间排序**贴近我们脱战的两排观感：短时 proc 排最前，
        -- 长 buff 往后。
        sortMethod = sortMethod.Expiration or sortMethod.Default
    end
    if type(sortMethod) == "number" then opts.sortMethod = sortMethod end
    local sortDirection = _G.AuraContainerSortDirection
    if type(sortDirection) == "table" then sortDirection = sortDirection.Normal end
    if type(sortDirection) == "number" then opts.sortDirection = sortDirection end

    local okAdd, err = pcall(container.AddAuraGroup, container, key, filter, opts)
    if not okAdd then
        DiscardCombatAura(container)
        return nil, "AddAuraGroup 失败: " .. tostring(err)
    end

    -- 临时附魔（磨刀石 / 毒 / 符文）在机密期读不到 C_Item.GetWeaponEnchantInfo，
    -- 我们那条自绘行只能隐藏。把三个武器槽交给引擎：它用 C_PaperDollInfo 读机密数据、
    -- 用 secretwrap 写图标 / 冷却 / 层数；我们只提供同样的 initializeFrame 样式。
    -- （NDui Forever 与暴雪 BuffFrame 同款机制；只取机制，不抄它的代码。）
    if kind == "buff" and type(container.AddItemEnchantment) == "function" then
        local slots = _G.AuraContainerItemEnchantmentSlot
        if type(slots) == "table" then
            for _, slot in pairs(slots) do
                if type(slot) == "number" then
                    pcall(container.AddItemEnchantment, container, slot, {
                        hidePermanent = true,
                        initializeFrame = styleButton,
                    })
                end
            end
            if type(container.SetItemEnchantmentLayout) == "function" then
                pcall(container.SetItemEnchantmentLayout, container, {
                    elementWidth  = size, elementHeight = size,
                    elementSpacing = ICON_GAP, lineSpacing = ICON_GAP,
                    layoutIndex = 1,
                })
            end
        end
    end

    pcall(container.SetUnit, container, "player")
    -- ArcAuras 同款：出生就 Enable，让引擎把它纳入自己的刷新流程（出生后 Hide 不影响）。
    if not SetCombatAuraEnabled(container, true) then
        DiscardCombatAura(container)
        return nil, "SetEnabled(true) 失败"
    end
    pcall(container.UpdateAllAuras, container)
    -- **常显 + alpha 0**：引擎只给"活着的"容器派数据/刷新，脱战藏起来（Hide）就再也不会更新，
    -- 进战斗 Show 出来是空的（一期踩过）。所以保持 Show 状态，用 alpha 当开关：
    -- 脱战 0（我们的自绘行在画），进战斗 1。alpha 0 的框不触发它的 Show 逻辑，也不吃鼠标
    -- （按钮 SetMouseClickEnabled(false)）。
    if type(container.SetMouseClickEnabled) == "function" then pcall(container.SetMouseClickEnabled, container, false) end
    pcall(container.EnableMouse, container, false)
    pcall(container.SetAlpha, container, 0)
    pcall(container.Show, container)
    return container
end

local function MarkCombatAurasUnavailable(why)
    combatAurasEnabled = false
    if not combatWarned then
        combatWarned = true
        ns:Print("战斗中的玩家光环（原生 AuraContainer）不可用，战斗中改用暴雪原生 Buff 框：" .. tostring(why or "未知原因"))
    end
end

local function EnsureCombatAuras()
    if not ns:IsModuleEnabled("BuffFrame") then return false end
    if combatAurasEnabled and combatBuffs and combatDebuffs then return true end
    if InCombat() then
        -- 战斗里建出来的容器永远是空的：排队到脱战补做（ns:AfterCombat）。
        ns:AfterCombat("buffframe-auras", EnsureCombatAuras)
        return false
    end

    -- 模块关闭时只停用、不销毁；重新启用必须复用原容器，且仅在脱战时恢复 Enable。
    if combatBuffs and combatDebuffs then
        if SetCombatContainersEnabled(true) then
            combatAurasEnabled = true
            ApplyCombatCap()
            local alpha = combatMode and 1 or 0
            pcall(combatBuffs.SetAlpha, combatBuffs, alpha)
            pcall(combatDebuffs.SetAlpha, combatDebuffs, alpha)
            SetExternalAuraFit(true)
            return true
        end
        SetCombatContainersEnabled(false)
        SetExternalAuraFit(false)
        MarkCombatAurasUnavailable("已有容器 SetEnabled(true) 失败")
        return false
    end

    -- 正常路径不会出现半个已发布引用；真出现时先停用清场，绝不留下 Enabled 孤儿。
    if combatBuffs or combatDebuffs then
        DiscardCombatAura(combatBuffs)
        DiscardCombatAura(combatDebuffs)
        combatBuffs, combatDebuffs = nil, nil
        SetExternalAuraFit(false)
    end
    if type(ns.PrepareAuraStyle) == "function" then pcall(ns.PrepareAuraStyle) end

    local buffs, why = CreateCombatAura("MonetUICombatBuffFrame", "monetPlayerCombatBuffs", "HELPFUL", BUFF_SIZE, "buff")
    local debuffs = buffs and CreateCombatAura("MonetUICombatDebuffFrame", "monetPlayerCombatDebuffs", "HARMFUL", DEBUFF_SIZE, "debuff")
    if not buffs or not debuffs then
        -- Hide 不会停止引擎更新；两半都必须 SetEnabled(false) 后再藏。
        if buffs then
            SetCombatAuraEnabled(buffs, false)
            pcall(buffs.Hide, buffs)
        end
        if debuffs then
            SetCombatAuraEnabled(debuffs, false)
            pcall(debuffs.Hide, debuffs)
        end
        SetExternalAuraFit(false)
        MarkCombatAurasUnavailable(why)
        return false
    end

    combatBuffs, combatDebuffs = buffs, debuffs
    combatAurasEnabled = true
    ApplyCombatCap()
    combatBuffs:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP, -AURA_GAP)
    combatDebuffs:SetPoint("TOPLEFT", combatBuffs, "BOTTOMLEFT", 0, -8)
    -- 回场：这两个容器上的按钮才是真正要给补扫干活的那一批。
    SetExternalAuraFit(true)
    return true
end

--- 引擎容器是否可作为战斗显示。
local function EngineCombatReady()
    return combatAurasEnabled and combatBuffs ~= nil and combatDebuffs ~= nil
end

--- 换主题：**绝不重建引擎容器**（2026-10-25 判例）。旧的 RebuildCombatAuras 已删除 ——
--- 它没有任何调用点，而它做的事（ClearAllPoints + Hide + 置空后重建）恰恰是那条判例禁止的：
--- 重建会留下一世代仍 SetEnabled(true) 的旧容器，战斗里引擎每次写它的按钮都被记成 MonetUI。
--- 现在的口径：边框颜色保持创建时那一套，换主题后 /reload 跟新主题。

--- 战斗显示开关：只切 alpha（容器常显，引擎才会持续更新；见 CreateCombatAura 的注释）。
local function SetCombatContainersAlpha(alpha)
    if not combatAurasEnabled then return end
    if combatBuffs then pcall(combatBuffs.SetAlpha, combatBuffs, alpha) end
    if combatDebuffs then pcall(combatDebuffs.SetAlpha, combatDebuffs, alpha) end
end

-- ============================================================================
-- A1 脱战武器附魔行（磨刀石 / 毒 / 元素磨刀石等临时增强）
-- ----------------------------------------------------------------------------
-- 本客户端的临时附魔由暴雪 BuffFrame 内嵌 auraType="TempEnchant" 按钮绘制，而我们
-- 脱战把 BuffFrame 整体 alpha 0、自绘行只读 C_UnitAuras 的 HELPFUL/HARMFUL ⇒ 附魔
-- 两头都看不见。这里补一条专用行：数据源 C_Item.GetWeaponEnchantInfo（1.60 文档，
-- 返回 WeaponEnchantInfo 数组，timeLeft 单位**毫秒**），图标直接用 enchantIconID
-- （fileID）。`TempEnchantFrame` 在 12.1.5 / 1.60 都没有（别去找）；而
-- `GetInventoryItem*` 全族 **1.60.1 · 71139 实测存在**（耐久槽位路径就在用），那条旧结论作废。
-- 战斗跟随 combatMode 隐藏（战斗中能否读该 API 未实测，A2 待实机另行拍板）。
-- ============================================================================

local ENCHANT_SIZE = BUFF_SIZE   -- 附魔属有益临时增强，沿用 buff/proc 行的 28px 规格
-- 语义紫：临时附魔 = 紫。**固定语义色，不随主题变**（先例：debuff 红边走 Color:GetDanger，
-- 也是语义优先于主题）；换主题后 Update 重涂时这里照旧染紫。
local ENCHANT_PURPLE = { r = 0.67, g = 0.42, b = 0.98 }
local ENCHANT_MAX_AGE = 30 * 86400 -- 剩余 > 30 天当读不到（AGENTS 冷却判例：毫秒/秒混算防线）

local enchantButtons = {}
local enchantContainer
local enchantSubId = nil        -- Scheduler 订阅号，模块级局部防重复注册
local enchantActive = false     -- 模块启用旗：右键取消路径的守门之一
local enchantApiWarned = false  -- API 缺失一次性警告
local enchantIconWarned = false -- enchantIconID 缺失一次性警告
-- M:Update 每轮记下的三行实际高度：附魔行锚点按它累加，**绝不锚在可能为空的行上**
-- （空容器被 FitContainer 压成 0×0 后 GetLeft() 返回 nil —— AGENTS 判例）。
local lastRowHeights = { buff = 0, proc = 0, debuff = 0 }

--- 三个武器槽。Enum.WeaponSlot（1.60 文档 TYPES.md：MainHand=0 / OffHand=1 / Ranged=2）
--- 优先读客户端枚举，缺席时退回文档值。
local function WeaponSlots()
    local e = _G.Enum and _G.Enum.WeaponSlot
    if type(e) == "table" and e.MainHand ~= nil and e.OffHand ~= nil and e.Ranged ~= nil then
        return { e.MainHand, e.OffHand, e.Ranged }
    end
    return { 0, 1, 2 }
end

--- 逐槽读附魔。返回 nil = API 不存在（整行隐藏 + 一次性警告）；否则返回
--- { slot, enchant } 数组（可能为空）。hasEnchant 过 Secrets.Bool：机密时落回
--- false = 隐藏该格，绝不对机密值做真值测试。
local function CollectEnchants()
    local C = _G.C_Item
    if not C or type(C.GetWeaponEnchantInfo) ~= "function" then return nil end
    local list = {}
    for _, slot in ipairs(WeaponSlots()) do
        local ok, enchants = pcall(C.GetWeaponEnchantInfo, slot)
        if ok and type(enchants) == "table" then
            for i = 1, #enchants do
                local e = enchants[i]
                if type(e) == "table" and Secrets.Bool(e.hasEnchant, false) then
                    list[#list + 1] = { slot = slot, enchant = e }
                end
            end
        end
    end
    return list
end

local function CreateEnchantButton(parent, size)
    local button = CreateIconButton(parent, size)

    -- enchantIconID 为 nil/0 时的降级小片：不画图标，只画"附魔"文字 + 计时
    -- （计时仍由 Cooldown 模块渲染，规格与其它行一致）。
    button.label = Widget:Font(button, 10, "pixel", "white", "CENTER")
    button.label:SetPoint("TOP", button, "TOP", 0, -3)
    button.label:SetText("附魔")
    button.label:Hide()

    button:EnableMouse(true)
    -- 提示只显示能安全读到的：附魔名没有可查的 API（enchantID 不拿去 concat/format），
    -- 名字查不到就不显示名字，别猜 API。剩余/次数用 ShowEnchant 存下的明文快照。
    button:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip or self.slot == nil then return end
        pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")
        pcall(tip.SetText, tip, "武器附魔")
        if self.secLeft then
            pcall(tip.AddLine, tip, "剩余：" .. Math:DurationText(self.secLeft), 1, 1, 1)
        end
        if self.chargesShown and self.chargesShown > 0 then
            pcall(tip.AddLine, tip, "次数：" .. tostring(self.chargesShown), 1, 1, 1)
        end
        pcall(tip.AddLine, tip, "右键取消", 0.6, 0.6, 0.6)
        pcall(tip.Show, tip)
    end)
    button:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip then pcall(tip.Hide, tip) end
    end)
    -- 右键取消：机制同暴雪 TempEnchant 按钮（C_Spell.CancelItemTempEnchantment(slot, type)），
    -- 只取机制不抄代码。受限 API ⇒ 调用前战斗/受限守门；enchantType 过 Secrets.Number。
    -- 取消成功后下一拍轮询自然刷新。写法沿用本模块光环行的 OnMouseDown（Frame 无 OnClick）。
    button:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "RightButton" then return end
        if not enchantActive or self.slot == nil then return end
        if InCombat() then return end
        if type(ns.IsRestricted) == "function" and ns:IsRestricted() then return end
        local C = _G.C_Spell
        if not C or type(C.CancelItemTempEnchantment) ~= "function" then return end
        local etype = Secrets.Number(self.enchantTypeRaw) or 0
        pcall(C.CancelItemTempEnchantment, self.slot, etype)
    end)

    button:Hide()
    return button
end

local function ShowEnchant(button, entry, index)
    local size = button.size
    local perRow = PerRow(size)
    local stride = size + ICON_GAP
    local column = (index - 1) % perRow
    local row = math.floor((index - 1) / perRow)

    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", button:GetParent(), "TOPLEFT",
        column * stride, -row * stride)
    button:Show()

    local e = entry.enchant
    -- 图标 = enchantIconID（fileID 直接 SetTexture，同光环行写法）。nil/0 → 文字小片。
    local iconID = Secrets.Number(e.enchantIconID)
    if iconID and iconID > 0 then
        button.icon:SetTexture(iconID)
        button.icon:Show()
        button.label:Hide()
    else
        button.icon:Hide()
        button.label:Show()
        if not enchantIconWarned then
            enchantIconWarned = true
            ns:Print("武器附魔缺少图标ID（enchantIconID），已改用文字小片显示。")
        end
    end

    -- 次数（charges）> 0 时右下角堆叠数，沿用光环行堆叠画法。
    local charges = Secrets.Number(e.charges)
    button.chargesShown = charges
    if charges and charges > 0 then
        button.count:SetText(charges)
        button.count:Show()
    else
        button.count:Hide()
    end

    -- timeLeft 是**毫秒**（1.60 文档）→ /1000 成秒；> 30 天当读不到。
    local ms = Secrets.Number(e.timeLeft)
    local sec = ms and (ms / 1000) or nil
    if sec and sec > ENCHANT_MAX_AGE then sec = nil end
    button.secLeft = sec
    if sec and sec > 0 then
        local expire = GetTime() + sec
        -- 同一附魔持续期间不每秒重设冷却（避免 swipe 每拍回跳）：换槽 / 换附魔 /
        -- 到期时刻漂移 > 2s 才重设，其余交给 Cooldown 自己走。
        if button.slot ~= entry.slot or not button.expireAt
            or math.abs(expire - button.expireAt) > 2 then
            if not pcall(button.cooldown.SetCooldown, button.cooldown, GetTime(), sec) then -- TAINT-OK: 与光环行同源——Secrets.Number 明文秒数、combatMode 早退仅脱战执行、pcall 兜底；武器附魔无 DurationObject 可用
                pcall(button.cooldown.Clear, button.cooldown)
            end
            button.expireAt = expire
        end
    else
        pcall(button.cooldown.Clear, button.cooldown)
        button.expireAt = nil
    end

    -- 语义紫边框（见 ENCHANT_PURPLE 注释）：1px 边框机制沿用 Widget:Theme，只换色。
    if button.SetBackdropBorderColor then
        button:SetBackdropBorderColor(ENCHANT_PURPLE.r, ENCHANT_PURPLE.g, ENCHANT_PURPLE.b, 0.9)
    end

    button.slot = entry.slot
    button.enchantTypeRaw = e.enchantType
end

--- 附魔行落点：UIParent + 三行实际高度累加（buff 底 +4 proc、proc 底 +8 debuff、
--- debuff 底 +8 附魔），与 debuff 行同款"不锚空行"写法。
local function AnchorEnchantRow()
    if not enchantContainer then return end
    local h = lastRowHeights
    enchantContainer:ClearAllPoints()
    enchantContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP,
        -(AURA_GAP + h.buff + 4 + h.proc + 8 + h.debuff + 8))
end

--- 附魔行刷新：1s 轮询与 M:Update（脱战路径）共用。战斗模式由 SetCombatMode 藏行，
--- 这里直接早退。所有游戏返回值已过 Secrets.Bool/Number，机密格隐藏/降级。
local function UpdateEnchants()
    if not enchantActive or not enchantContainer then return end
    if combatMode then return end

    local list = CollectEnchants()
    if not list then
        if not enchantApiWarned then
            enchantApiWarned = true
            -- api-audit:ok 运行时兜底文案：快照（docs/api/FUNCTIONS.md）里 C_Item.GetWeaponEnchantInfo 在
            ns:Print("本客户端没有 C_Item.GetWeaponEnchantInfo，武器附魔行不可用（整行隐藏）。")
        end
        for i = 1, #enchantButtons do enchantButtons[i]:Hide() end
        enchantContainer:Hide()
        return
    end

    EnsureButtons(enchantButtons, enchantContainer, #list, ENCHANT_SIZE, CreateEnchantButton)
    for index = 1, #list do
        Secrets.Measure(ShowEnchant, enchantButtons[index], list[index], index)
    end
    FitContainer(enchantContainer, #list, ENCHANT_SIZE)
    enchantContainer:SetShown(#list > 0)
    AnchorEnchantRow()
end

local function StartEnchantPoll()
    if enchantSubId then return end
    -- 签名 fn(elapsed)：UpdateEnchants 不收参，调度器投 elapsed 也无碍（形参 ≤1）。
    enchantSubId = Scheduler:Every(1000, UpdateEnchants, "光环:武器附魔")
end

local function StopEnchantPoll()
    if enchantSubId then
        Scheduler:Unregister(enchantSubId)
        enchantSubId = nil
    end
end

--- 两套显示互斥切换。进战斗 → 引擎容器（我们的皮肤）；不可用时 → 暴雪原生框。脱战 → 自绘。
local function SetCombatMode(on)
    if on == combatMode then
        -- 已经在战斗模式：**什么都别做**。每次刷新都推 UpdateAllAuras = 战斗中每秒多次
        -- 让引擎在"我们"的上下文里重写按钮，历史上那批 ADDON_ACTION_BLOCKED（×15 级）
        -- 正是这么来的。容器常显，引擎自己有 UNIT_AURA 驱动，够用。
        return
    end
    if on then
        -- 自绘那套退场：只清按钮，buffContainer 本身留着 —— 它是 QueueUpdate 的 OnUpdate 驱动帧，
        -- 隐藏的帧不跑 OnUpdate，藏起来就再也收不到下一次刷新了。
        for _, list in ipairs({ buffButtons, procButtons, debuffButtons, enchantButtons }) do
            for i = 1, #list do list[i]:Hide() end
        end
        HideContainer(procContainer)
        HideContainer(debuffContainer)
        -- 附魔行战斗跟随隐藏（A1 只做脱战；战斗中 GetWeaponEnchantInfo 可读性未实测）。
        HideContainer(enchantContainer)
        combatMode = true
        -- **战斗中绝不创建容器**（引擎会给出空容器，且可能产生拦截）。容器由脱战路径
        -- 提前建好；真没有就退回暴雪原生框（SuppressBlizzard 里按 EngineCombatReady 判断）。
        SetCombatContainersAlpha(1)
        -- 只在"需要原生框兜底"时才去写暴雪光环框：战斗里碰它们会被记成 MonetUI
        -- （实机：每次进/出战斗各 +1 条 ADDON_ACTION_BLOCKED UNKNOWN()）。
        -- 引擎容器可用时，那些框的 alpha 在脱战就已经是 0，不需要再写。
        if not EngineCombatReady() then SuppressBlizzard() end
    else
        combatMode = false
        SetCombatContainersAlpha(0)
        SuppressBlizzard()
    end
end

--- 机密期只从暴雪自己的 BuffFrame 账本取**数量**：它仍在后台更新 auraInfo /
--- numHideableBuffs，我们既不读光环字段也不碰它的脚本，所以不会触发机密拦截。
--- 返回 总格数, 可折叠数（numHideableBuffs 与折叠状态无关，始终是"可折叠"的计数）。
local function CombatCollapseCounts()
    local b = _G.BuffFrame
    if not b then return 0, 0 end
    local okTotal, total = pcall(function() return b.auraInfo and #b.auraInfo or 0 end)
    local okHidden, hidden = pcall(function() return b.numHideableBuffs end)
    if not okTotal or not okHidden or type(total) ~= "number" or type(hidden) ~= "number" then
        return 0, 0
    end
    if Secrets.IsSecret(total) or Secrets.IsSecret(hidden) then return 0, 0 end
    hidden = math.max(0, math.min(hidden, total))
    return total, hidden
end

function M:Update()
    if not ns:IsModuleEnabled("BuffFrame") or not buffContainer then return end

    if not Secrets.CanReadAuras() then
        -- 加密/受限环境（战斗中）：**插件被硬禁读**——2026-10-25 插件上下文实测：
        --   GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'MonetUI'
        -- 不是"返回机密字段"，是整个 API 直接拒。所以战斗显示只能交给客户端自己：
        -- 首选引擎 AuraContainer（我们的皮肤，见 CreateCombatAura），不可用时退回暴雪原生框。
        SetCombatMode(true)
        local total, hideable = CombatCollapseCounts()
        if Collapsed() then
            UpdateCollapseButton(math.max(0, total - hideable), hideable, hideable)
        else
            UpdateCollapseButton(total, 0, hideable)
        end
        return
    end
    SetCombatMode(false)

    -- 脱战才允许补建战斗容器（主题重建 / 建失败之后都靠这里补）。战斗里创建会被引擎拒。
    if not EngineCombatReady() then EnsureCombatAuras() end

    local buffs, buffsComplete = CollectAuras("player", "HELPFUL")
    local debuffs, debuffsComplete = CollectAuras("player", "HARMFUL")

    -- 没读全：优先用已读到的部分；一条都没读到（第一个索引就撞墙）才沿用上一轮。
    if not buffsComplete and #buffs == 0 then buffs = lastBuffs end
    if not debuffsComplete and #debuffs == 0 then debuffs = lastDebuffs end
    if buffsComplete then lastBuffs = buffs end
    if debuffsComplete then lastDebuffs = debuffs end

    -- 脱战折叠：与暴雪同款 90 秒门槛，长时增益收进 "+N"，短时 / 临时 buff 照常显示。
    local hiddenBuffs = {}
    if Collapsed() then
        local visibleBuffs = {}
        for i = 1, #buffs do
            local aura = buffs[i]
            local duration = Secrets.Number(aura.duration)
            local expiration = Secrets.Number(aura.expirationTime)
            -- 初始 true：永久光环（duration==0）与读不出数值的按"可折叠"处理，
            -- 与 SplitBuffs 的 foldable 判据保持同一口径（暴雪 hideUnlessExpanded 同款）。
            local longer = true
            if duration ~= nil and expiration ~= nil then -- TAINT-OK: Secrets.Number 已过 canaccessvalue
                if duration > 0 then
                    if expiration > 0 then
                        longer = (expiration - GetTime()) > COLLAPSE_THRESHOLD
                    end
                end
            end
            if longer then
                hiddenBuffs[#hiddenBuffs + 1] = aura
            else
                visibleBuffs[#visibleBuffs + 1] = aura
            end
        end
        buffs = visibleBuffs
    end

    local auras, procs = SplitBuffs(buffs)

    UpdateRow(buffButtons, buffContainer, auras, BUFF_SIZE, "HELPFUL")
    FitContainer(buffContainer, #auras, BUFF_SIZE)
    UpdateRow(procButtons, procContainer, procs, BUFF_SIZE, "HELPFUL")
    FitContainer(procContainer, #procs, BUFF_SIZE)
    UpdateRow(debuffButtons, debuffContainer, debuffs, DEBUFF_SIZE, "HARMFUL")
    FitContainer(debuffContainer, #debuffs, DEBUFF_SIZE)

    -- debuff 行自己算落点，**不锚在 proc 行上**：proc 行空的时候被 FitContainer 压成 0×0
    -- 并且被 SetShown(false)，锚到它上面整行拿不到矩形（GetLeft() 返回 nil）—— 实机症状是
    -- "debuff 明明在（按钮 shown、冷却在跑），屏幕上什么都没有"。
    -- 间距和以前完全一致：buff 底 +4 是 proc 行，proc 底 +8 是 debuff 行（proc 空时高度算 0）。
    local function RowHeight(count, size)
        if count <= 0 then return 0 end
        return math.ceil(count / PerRow(size)) * (size + ICON_GAP) - ICON_GAP
    end
    lastRowHeights.buff   = RowHeight(#auras, BUFF_SIZE)
    lastRowHeights.proc   = RowHeight(#procs, BUFF_SIZE)
    lastRowHeights.debuff = RowHeight(#debuffs, DEBUFF_SIZE)
    debuffContainer:ClearAllPoints()
    debuffContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP,
        -(AURA_GAP + lastRowHeights.buff + 4 + lastRowHeights.proc + 8))

    -- buffContainer 常显（空的时候被 FitContainer 压成 0 高，什么都不画），只切换后两块。
    procContainer:SetShown(#procs > 0)
    debuffContainer:SetShown(#debuffs > 0)
    -- 收起态：foldable = 被收进 "+N" 的数量；展开态：foldable = 光环行数量（SplitBuffs 已按
    -- 同一条 90 秒/永久门槛分出 auras）。没有可折叠的 buff 时按钮整颗隐藏。
    local foldableTotal = Collapsed() and #hiddenBuffs or #auras
    UpdateCollapseButton(#auras + #procs, #hiddenBuffs, foldableTotal)

    -- 附魔行：数据刷新 + 按上面记下的实际行高累加锚点（同样不锚可能为空的行）。
    UpdateEnchants()
end

--- Throttled update: UNIT_AURA can fire very often during combat.
--- 迁到 Scheduler：来一波就注册一个 0.25s 的一次性订阅（perf 可见），到点更新 + 注销
--- （主帧随之自 Hide），窗口内的后续 UNIT_AURA 被 pending 拦掉只更新一次。
local buffSubId = nil
local function QueueUpdate()
    local frame = buffContainer
    if not ns:IsModuleEnabled("BuffFrame") or not frame or pending then return end
    pending = true
    buffSubId = Scheduler:Every(250, function()
        if buffSubId then Scheduler:Unregister(buffSubId); buffSubId = nil end
        pending = false
        M:Update()
    end, "光环:布局重排")
end

function SuppressBlizzard()
    local found = 0
    -- TempEnchantFrame 在 12.1.5 实测**不存在**（`/mui compat find Enchant` 全 UI 只有 4 个交易附魔框），
    -- 留着是因为它是 Forever 那边的候选名字；这一趟拿不到就是空枪，不报错。
    for _, name in ipairs({ "BuffFrame", "DebuffFrame", "TempEnchantFrame" }) do
        local blizzard = _G[name]
        if blizzard then
            found = found + 1
            -- **不 Hide()、不 UnregisterAllEvents、不写脚本槽**，也只用根框的 alpha + 鼠标
            -- （depth 0：那些框的子节点是光环按钮，关鼠标会把暴雪自己的提示也一起关掉）：
            --   * Hide() 会被暴雪自己的 Show() 顶回来（一边补、一边顶 = 一闪一闪）；
            --   * 写脚本槽 / 注销事件都是"动过这个框"，之后它自己的代码全算成 MonetUI 的污染。
            -- alpha 0 的框一直算"显示着"，不触发它的 Show 逻辑，也就不打架（见 AGENTS.md）。
            -- **战斗策略（2026-10-25 二期）**：战斗中优先让**引擎 AuraContainer**（我们的皮肤）
            -- 顶班；它不可用时才退回**暴雪原生 Buff 框**（alpha 1 + 可鼠标，客户端自己更新）。
            -- 脱战中一律 alpha 0 藏起来，用我们自绘那套。
            local useNative = combatMode and not EngineCombatReady()
            if useNative then
                Widget:Unmute(blizzard, { depth = 0, combat = "write" })
            else
                Widget:Mute(blizzard, { depth = 0, combat = "write" })
            end
        end
    end
    if found == 0 then
        ns:Print("未找到暴雪光环框架，若同时出现两套 Buff 显示请告知开发者。")
    end
end

function M:Initialize()
    -- Anchored top-left, matching Andromeda's BuffAnchor (its UI_GAP is 33).
    buffContainer = Widget:CreateFrame("MonetUIBuffFrame", UIParent, 1, 1)
    buffContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP, -AURA_GAP)

    -- 触发类（proc / 临时 buff）单独一行，夹在光环类和 debuff 之间。行距给 4（同一类 buff
    -- 的子分组，别拉太开）；到 debuff 那段仍是 8，借间距把"有益 / 有害"分开。
    -- 空容器会被 FitContainer 压成 0 高，所以哪一组没内容都不会留下空隙。
    procContainer = Widget:CreateFrame("MonetUIBuffProcFrame", UIParent, 1, 1)
    procContainer:SetPoint("TOPLEFT", buffContainer, "BOTTOMLEFT", 0, -4)

    debuffContainer = Widget:CreateFrame("MonetUIDebuffFrame", UIParent, 1, 1)
    debuffContainer:SetPoint("TOPLEFT", procContainer, "BOTTOMLEFT", 0, -8)

    -- A1 武器附魔行：排在 debuff 行之后。锚点走 AnchorEnchantRow（UIParent + 行高累加，
    -- 不锚可能为空的行）；无附魔时整行 Hide、不占高。1s 轮询驱动数据（见 UpdateEnchants）。
    enchantContainer = Widget:CreateFrame("MonetUIEnchantFrame", UIParent, 1, 1)
    AnchorEnchantRow()
    enchantContainer:Hide()
    enchantActive = true
    StartEnchantPoll()

    collapseButton = CreateCollapseButton()
    ApplyCombatCap()

    SuppressBlizzard()

    -- 引擎容器**必须在登录/脱战时建好**（ArcAuras 同款纪律：战斗里 CreateFrame 出来的容器
    -- 永远是空的，AddAuraGroup 也可能被拒）。这里是"装载窗口"，创建一定合法。
    EnsureCombatAuras()

    EventBus:RegisterUnit("UNIT_AURA", "player", QueueUpdate)
    EventBus:Register("PLAYER_ENTERING_WORLD", function() M:Update() end)
    EventBus:Register("PLAYER_SPECIALIZATION_CHANGED", function() M:Update() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:Update() end)
    -- 进/出战斗要立刻切换两套显示，别等下一次 UNIT_AURA（战斗中那条事件不一定来）。
    EventBus:Register("PLAYER_REGEN_DISABLED", function() M:Update() end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        -- 战斗中被拦的容器重建由 ns:AfterCombat 在更早的统一排空里做掉。
        M:Update()
        -- 保密状态在脱战后可能再过一拍才解除（ArcAuras 同款兜底：`Settle` 里 +1 秒再试）。
        if type(_G.C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(1, function()
                local inCombat = type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown()
                if not inCombat then M:Update() end
            end)
        end
    end)
    -- 换主题：**不重建引擎容器**（2026-10-25 17:54 实机判例）。
    -- 重建 = 新一批引擎按钮被我们碰过，之后引擎在战斗里写它们就被记成 MonetUI，
    -- 冒 ADDON_ACTION_BLOCKED UNKNOWN()（×11 一次）。代价：战斗容器（以及目标/焦点光环）
    -- 的边框颜色停留在创建时那一套，靠 /reload 跟上新主题 —— 换来"0 拦截"这条底线。
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        M:Update()
    end)

    self:Update()
end

function M:SetEnabled(enabled)
    if enabled then
        -- 已有容器只恢复、不重建；战斗中只排队，脱战前绝不重设 Enable。
        if combatBuffs and combatDebuffs and not EngineCombatReady() then
            if InCombat() then
                ns:AfterCombat("buffframe-auras", EnsureCombatAuras)
            else
                EnsureCombatAuras()
            end
        end
        if EngineCombatReady() then
            SetExternalAuraFit(true)
        else
            SetExternalAuraFit(false)
        end
        -- 附魔行：恢复右键路径 + 重挂轮询（防重复），self:Update() 里会立即刷一次。
        enchantActive = true
        StartEnchantPoll()
        self:Update()
    else
        combatAurasEnabled = false
        -- 引擎容器保持 Show 状态，但必须真正退出刷新；alpha=0 不是禁用。
        if combatBuffs then pcall(combatBuffs.SetAlpha, combatBuffs, 0) end
        if combatDebuffs then pcall(combatDebuffs.SetAlpha, combatDebuffs, 0) end
        SetCombatContainersEnabled(false)
        SuppressBlizzard()
        -- buffContainer 也藏起来的话，QueueUpdate 的 OnUpdate 驱动就停了，所以只清按钮。
        if procContainer then procContainer:Hide() end
        if debuffContainer then debuffContainer:Hide() end
        -- 附魔行完整退场：藏行清钮、注销轮询、右键路径失效（enchantActive 守门）。
        enchantActive = false
        StopEnchantPoll()
        if enchantContainer then enchantContainer:Hide() end
        if collapseButton then collapseButton:Hide() end
        for _, button in ipairs(enchantButtons) do button:Hide() end
        for _, button in ipairs(buffButtons) do button:Hide() end
        for _, button in ipairs(procButtons) do button:Hide() end
        for _, button in ipairs(debuffButtons) do button:Hide() end
        -- 屏幕上一个我们的光环都不剩：`"external"` 这一组当场停账。条目不能删
        -- （引擎按钮的 initializeFrame 一个按钮只进来一次），只把组标成不干活，
        -- 目标框那两组不受影响；重新开启模块时再挂回去。
        SetExternalAuraFit(false)
    end
end

-- 只读探针（2026-11-03，上线日验收用）：`/mui buffframe probe`
-- **只数子框个数，一个 aura 字段都不读**。战斗里读光环数据是硬禁读
-- （`Auras cannot be accessed when secret while tainted by 'MonetUI'`），
-- 但 GetChildren 拿的是"容器里有几个框"，不碰 aura API，所以战斗里跑也安全。
-- 判据：我们的容器有子框 = 引擎在喂数据；0 或读不出 = 这一趟战斗显示是空的。
local function CountKids(frame)
    if type(frame) ~= "table" then return nil end
    -- `GetChildren` 返回**多返回值**不是表：`pcall(frame.GetChildren, frame)` 只接到第一个
    -- 子框，`type(kids) ~= "table"` 于是恒成立 → 这个探针**永远返回 nil**，
    -- 上线日验收读到的"读不出"其实是"数错了"（`c2b6b2b` 同款）。
    local ok, kids = pcall(function() return { frame:GetChildren() } end)
    if not ok or type(kids) ~= "table" then return nil end
    return #kids
end

--- 探针用的安全 stringify：机密值不进 concat/format（AGENTS：先判再 tostring）。
local function SafeSecretStr(v)
    if v == nil then return "nil" end
    if Secrets.IsSecret(v) then return "机密" end
    return tostring(v)
end

function M:HandleCommand(rest)
    local raw = string.lower(rest or "")
    if raw ~= "probe" and raw ~= "diag" and raw ~= "diagnose"
        and not string.find(raw, "^probe") then
        return false
    end

    local inLockdown = type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown()
    local rows = {
        { key = "ourCombatBuffs",   frame = combatBuffs },
        { key = "ourCombatDebuffs", frame = combatDebuffs },
        { key = "BuffFrame",        frame = _G.BuffFrame },
        { key = "DebuffFrame",      frame = _G.DebuffFrame },
        { key = "TempEnchantFrame", frame = _G.TempEnchantFrame },
    }
    local out = {}
    for _, r in ipairs(rows) do
        local exists = type(r.frame) == "table"
        local kids = exists and CountKids(r.frame) or nil
        r.exists = exists
        r.children = kids
        out[#out + 1] = { key = r.key, exists = exists, children = kids }
    end

    local _, moduleEnabled = pcall(function() return ns.IsModuleEnabled and ns:IsModuleEnabled("BuffFrame") end)

    -- A1 武器附魔探针：API 存在性 + 每槽 hasEnchant / timeLeft(秒) / charges / iconID。
    -- 每个值先过 Secrets.Bool/Number，拿不到明文才 SafeSecretStr（机密只标"机密"，
    -- 绝不进 concat/format）。逐槽 pcall：战斗中该 API 可读性未实测，读不出就如实报。
    local enchApi = type(_G.C_Item) == "table" and type(_G.C_Item.GetWeaponEnchantInfo) == "function"
    local enchSlots, enchTotal = {}, 0
    if enchApi then
        for _, slot in ipairs(WeaponSlots()) do
            local ok, enchants = pcall(_G.C_Item.GetWeaponEnchantInfo, slot)
            local parts = {}
            if not ok then
                parts[#parts + 1] = "读不出:" .. SafeSecretStr(enchants)
            elseif type(enchants) ~= "table" then
                parts[#parts + 1] = "无数据"
            else
                for i = 1, #enchants do
                    local e = enchants[i]
                    if type(e) == "table" then
                        local has = Secrets.Bool(e.hasEnchant, false)
                        if has then enchTotal = enchTotal + 1 end
                        local ms = Secrets.Number(e.timeLeft)
                        local sec = ms and math.floor(ms / 1000) or nil
                        local charges = Secrets.Number(e.charges)
                        local icon = Secrets.Number(e.enchantIconID)
                        parts[#parts + 1] = string.format("has=%s timeLeft=%s charges=%s icon=%s",
                            tostring(has),
                            sec and (tostring(sec) .. "s") or SafeSecretStr(e.timeLeft),
                            charges and tostring(charges) or SafeSecretStr(e.charges),
                            icon and tostring(icon) or SafeSecretStr(e.enchantIconID))
                    end
                end
                if #parts == 0 then parts[#parts + 1] = "空" end
            end
            enchSlots[#enchSlots + 1] = { slot = slot, text = table.concat(parts, "; ") }
        end
    end
    local enchRowShown = (enchantContainer and enchantContainer:IsShown()) and true or false
    local enchIcons = 0
    for i = 1, #enchantButtons do
        if enchantButtons[i]:IsShown() then enchIcons = enchIcons + 1 end
    end
    local enchVerdict
    if not enchApi then
        enchVerdict = "API缺失：附魔行整行隐藏（已一次性警告）"
    elseif not moduleEnabled then
        enchVerdict = "模块已禁用：附魔行按设计隐藏"
    elseif combatMode then
        enchVerdict = "战斗中：附魔行按设计隐藏（A2 待实机拍板）"
    elseif enchTotal == 0 then
        enchVerdict = "当前无武器附魔：上磨刀石/毒后 1 秒内应出图标"
    elseif enchRowShown and enchIcons >= enchTotal then
        enchVerdict = "正常：脱战附魔行在画"
    else
        enchVerdict = "异常：有附魔但行未显示/格数不符，查轮询与锚点"
    end
    local enchReport = {
        api = enchApi, total = enchTotal, rowShown = enchRowShown, icons = enchIcons,
        pollId = enchantSubId, active = enchantActive, slots = enchSlots, verdict = enchVerdict,
    }

    local report = {
        when = (type(_G.date) == "function") and (select(2, pcall(_G.date, "%Y-%m-%d %H:%M:%S"))) or nil,
        moduleEnabled = moduleEnabled and true or false,
        lockdown = inLockdown and true or false,
        inCombat = (type(ns.InCombat) == "function" and ns:InCombat()) and true or false,
        frames = out,
        enchant = enchReport,
        note = "只数 GetChildren 的个数，不读 aura 字段；children=nil 表示帧不存在或读不出。附魔段逐值过 Secrets，机密只标'机密'。",
    }
    local saved = false
    if type(ns.DB) == "function" then
        local okDb, db = pcall(function() return ns:DB() end)
        if okDb and type(db) == "table" then
            pcall(function() db.buffProbe = report end)
            saved = true
        end
    end

    for _, r in ipairs(out) do
        local state = (not r.exists) and "未创建"
            or (r.children == nil and "读不出（容器不可访问）")
            or (r.children == 0 and "空（0 个子框）")
            or ("子框 " .. tostring(r.children))
        ns:Print(string.format("buffframe probe %-17s %s", r.key, state))
    end
    ns:Print(string.format("战斗标志 lockdown=%s ns:InCombat=%s",
        tostring(report.lockdown), tostring(report.inCombat)))
    -- 附魔段：一行式总览 + 每槽明细 + 判读结论。
    ns:Print(string.format("buffframe probe 附魔 api=%s 行shown=%s 图标=%d 轮询id=%s active=%s",
        tostring(enchApi), tostring(enchRowShown), enchIcons,
        tostring(enchantSubId), tostring(enchantActive)))
    for _, r in ipairs(enchSlots) do
        ns:Print(string.format("buffframe probe slot%d %s", r.slot, r.text))
    end
    ns:Print("buffframe probe 附魔判读：" .. enchVerdict)
    ns:Print(saved
        and "全量已存 MonetUIDB.buffProbe —— 写入比 /reload 晚 1–2 分钟，别立刻读（登出后再读最稳）。"
        or "账本没打开，只有聊天框这几行。")
    return true
end

ns:Register("BuffFrame", M)
