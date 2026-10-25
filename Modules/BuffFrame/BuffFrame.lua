-- Modules/BuffFrame/BuffFrame.lua
-- Player buff / debuff display: a compact themed grid anchored under the minimap, replacing the Blizzard aura frame.
-- Aura data comes from C_UnitAuras; when the client marks auras secret the module steps aside instead of erroring.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local Math     = ns.Math
local EventBus = ns.EventBus

local M = { name = "BuffFrame" }

local ICON_GAP    = 4
local MAX_AURAS   = 32

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

local function CreateAuraButton(parent, size)
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
        -- 字体用 PingFangPixel（不是像素字体）：28px 图标把字号压到 8-10px 时，
        -- 12px 网格字体会糊成一片；矢量字体 + 硬描边（OUTLINE, MONOCHROME）才看得清。
        cooldowns:StyleCooldown(button.cooldown, 12, true, "pingfang")
    end

    button.count = Widget:Font(button, 12, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

    Widget:Theme(button, { thickness = 1, bgAlpha = 0.6 })

    -- 自绘的按钮没有暴雪那套提示与右键：自己写一份。
    -- 提示给名字、层数、剩余时间，并说明右键可以取消。
    button:EnableMouse(true)
    button:SetScript("OnEnter", function(self)
        local aura = self.aura
        if not aura then return end
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")

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

local function EnsureButtons(list, parent, needed, size)
    for i = #list + 1, needed do
        list[i] = CreateAuraButton(parent, size)
    end
    for i = needed + 1, #list do
        list[i]:Hide()
    end
end

local function ShowAura(button, aura, index)
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
end

local function UpdateRow(list, parent, auras, size)
    local needed = math.min(#auras, MAX_AURAS)
    EnsureButtons(list, parent, needed, size)

    for index = 1, needed do
        Secrets.Measure(ShowAura, list[index], auras[index], index)
    end
end

local function HideContainer(container)
    if not container then return end
    container:Hide()
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
-- 战斗兜底：引擎 AuraContainer
-- ----------------------------------------------------------------------------
-- 这个客户端在战斗中把光环数据标成机密：C_Secrets.ShouldAurasBeSecret() 为真时，
-- C_UnitAuras.GetAuraDataByIndex 对插件直接抛
--   "Auras cannot be accessed when secret while tainted by 'ForceTaint_Strong'"
-- 一个索引都读不到，自己读数据画的那套只能整块让位（这就是"一进战斗整块 Buff 消失"）。
-- 引擎的 AuraContainer 由客户端自己读光环、自己画按钮（目标框光环走的就是这条路），不受这条
-- 限制，所以战斗中改由它顶班，数据实时准确。
-- 代价：引擎不能按**剩余时长**给光环分类，"光环类 / 触发类"两行只能在脱战期间保留；
-- 战斗中是一整条流式排列（尺寸、边框、冷却、时长数字都和目标框同一套样式）。
-- 约束：容器必须在**脱战**时创建——战斗里 CreateFrame 出来的容器永远是空的（目标框实测）。
-- ============================================================================

local combatBuffs, combatDebuffs
local combatMode = false
local combatWarned = false
local RebuildCombatAuras   -- 前置声明：EnsureCombatAuras 战斗中要把它排进 ns:AfterCombat（实现在下面）

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

local function CreateCombatAura(frameName, key, filter, size, kind)
    if not EnsureAuraContainerAddOn() then
        return nil, "Blizzard_AuraContainer 未加载"
    end
    local ok, container = pcall(CreateFrame, "AuraContainer", frameName, UIParent, "CustomAuraContainerTemplate")
    if not ok or type(container) ~= "table" then
        return nil, "CreateFrame(AuraContainer) 失败（模板可能不存在）"
    end

    -- 先给一个可渲染的矩形，否则引擎那轮 OnUpdate 永远不会跑第一次布局。
    container:SetSize(1, 1)
    ApplyCombatFlow(container, size)

    local opts = {
        maxFrameCount = MAX_AURAS,
        candidateFilters = {},              -- 空表 = 不设白名单，引擎自己决定显示什么
        layout = {
            elementSpacing = ICON_GAP,
            lineSpacing    = ICON_GAP,
            elementWidth   = size,
            elementHeight  = size,
            layoutIndex    = 1,
        },
        -- 按钮样式与目标框共用（尺寸/裁切/字号由 spec 覆盖）。kind = "debuff" 时走引擎的
        -- 解魔法类型色边框 —— 那条也是引擎自己上色，战斗中照样有效。
        -- crop 必须和自绘那套一模一样（砍掉法术图标自带的 8% 描边），边框 1px、图标内缩
        -- 同样的 1 个物理像素、时长 12px，否则战斗中一看就是"另一套皮肤"。
        initializeFrame = function(button)
            pcall(function()
                if type(ns.AuraButtonStyle) == "function" then
                    local pad = ns.Media and ns.Media:Mult() or 1
                    if type(pad) ~= "number" or pad <= 0 then pad = 1 end
                    ns.AuraButtonStyle(button, kind, {
                        width = size, height = size,
                        crop = { 0.08, 0.92, 0.08, 0.92 },
                        iconInset = pad,
                        textSize = 12,
                        borderInside = true,   -- 自绘那套的边框画在按钮内侧，引擎默认向外扩，必须统一
                    })
                end
            end)
        end,
    }
    local sortMethod = _G.AuraContainerSortMethod
    if type(sortMethod) == "table" then sortMethod = sortMethod.Default end
    if type(sortMethod) == "number" then opts.sortMethod = sortMethod end
    local sortDirection = _G.AuraContainerSortDirection
    if type(sortDirection) == "table" then sortDirection = sortDirection.Normal end
    if type(sortDirection) == "number" then opts.sortDirection = sortDirection end

    local okAdd, err = pcall(container.AddAuraGroup, container, key, filter, opts)
    if not okAdd then
        return nil, "AddAuraGroup 失败: " .. tostring(err)
    end

    pcall(container.SetUnit, container, "player")
    pcall(container.UpdateAllAuras, container)
    container:Hide()
    return container
end

local function EnsureCombatAuras()
    if combatBuffs and combatDebuffs then return true end
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        -- 战斗里建出来的容器永远是空的：排队到脱战补做（ns:AfterCombat）。
        ns:AfterCombat("buffframe-auras", RebuildCombatAuras)
        return false
    end
    -- 染色曲线必须在非 securecall 的上下文里先建好，否则按钮拿不到曲线。
    if type(ns.PrepareAuraStyle) == "function" then pcall(ns.PrepareAuraStyle) end

    local buffs, why = CreateCombatAura("MonetUICombatBuffFrame", "monetPlayerCombatBuffs", "HELPFUL", BUFF_SIZE, "buff")
    local debuffs = buffs and CreateCombatAura("MonetUICombatDebuffFrame", "monetPlayerCombatDebuffs", "HARMFUL", DEBUFF_SIZE, "debuff")
    if not buffs or not debuffs then
        if not combatWarned then
            combatWarned = true
            ns:Print("战斗中的玩家光环（原生 AuraContainer）不可用：" .. tostring(why or "未知原因"))
        end
        if buffs then pcall(buffs.Hide, buffs) end
        if debuffs then pcall(debuffs.Hide, debuffs) end
        return false
    end

    combatBuffs, combatDebuffs = buffs, debuffs
    combatBuffs:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP, -AURA_GAP)
    -- debuff 跟自绘那套一样隔 8 个像素，把"有益 / 有害"分开。
    combatDebuffs:SetPoint("TOPLEFT", combatBuffs, "BOTTOMLEFT", 0, -8)
    return true
end

--- 引擎按钮在 initializeFrame 返回后就锁死（连我们建在按钮里的子帧都不能改写），
--- 换主题只能把容器连同按钮扔掉重建。战斗中重建会得到空容器：
--- 把自己排进 ns:AfterCombat，脱战重试。
function RebuildCombatAuras()
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        ns:AfterCombat("buffframe-auras", RebuildCombatAuras)
        return
    end
    for _, container in ipairs({ combatBuffs, combatDebuffs }) do
        if container then
            pcall(container.ClearAllPoints, container)
            pcall(container.Hide, container)
            pcall(container.SetParent, container, nil)
        end
    end
    combatBuffs, combatDebuffs = nil, nil
end

--- 两套显示互斥切换。进战斗 → 引擎顶班；脱战 → 自绘分行那套回来。
local function SetCombatMode(on)
    if on == combatMode then
        -- 已经在这个模式里：容器可能还没建过（进战斗前一帧才失败），补一次，别每次重做。
        if on and EnsureCombatAuras() then
            pcall(combatBuffs.Show, combatBuffs)
            pcall(combatDebuffs.Show, combatDebuffs)
        end
        return
    end
    if on then
        -- 自绘那套退场：只清按钮，buffContainer 本身留着 —— 它是 QueueUpdate 的 OnUpdate 驱动帧，
        -- 隐藏的帧不跑 OnUpdate，藏起来就再也收不到下一次刷新了。
        for _, list in ipairs({ buffButtons, procButtons, debuffButtons }) do
            for i = 1, #list do list[i]:Hide() end
        end
        HideContainer(procContainer)
        HideContainer(debuffContainer)
        combatMode = true
        if EnsureCombatAuras() then
            pcall(combatBuffs.Show, combatBuffs)
            pcall(combatDebuffs.Show, combatDebuffs)
        end
    else
        if combatBuffs then pcall(combatBuffs.Hide, combatBuffs) end
        if combatDebuffs then pcall(combatDebuffs.Hide, combatDebuffs) end
        combatMode = false
    end
end

function M:Update()
    if not buffContainer then return end

    if not Secrets.CanReadAuras() then
        -- 加密/受限环境（战斗中）：插件读不到任何光环，交给引擎 AuraContainer。
        SetCombatMode(true)
        return
    end
    SetCombatMode(false)

    local buffs, buffsComplete = CollectAuras("player", "HELPFUL")
    local debuffs, debuffsComplete = CollectAuras("player", "HARMFUL")

    -- 没读全：优先用已读到的部分；一条都没读到（第一个索引就撞墙）才沿用上一轮。
    if not buffsComplete and #buffs == 0 then buffs = lastBuffs end
    if not debuffsComplete and #debuffs == 0 then debuffs = lastDebuffs end
    if buffsComplete then lastBuffs = buffs end
    if debuffsComplete then lastDebuffs = debuffs end

    local auras, procs = SplitBuffs(buffs)

    UpdateRow(buffButtons, buffContainer, auras, BUFF_SIZE)
    FitContainer(buffContainer, #auras, BUFF_SIZE)
    UpdateRow(procButtons, procContainer, procs, BUFF_SIZE)
    FitContainer(procContainer, #procs, BUFF_SIZE)
    UpdateRow(debuffButtons, debuffContainer, debuffs, DEBUFF_SIZE)
    FitContainer(debuffContainer, #debuffs, DEBUFF_SIZE)

    -- debuff 行自己算落点，**不锚在 proc 行上**：proc 行空的时候被 FitContainer 压成 0×0
    -- 并且被 SetShown(false)，锚到它上面整行拿不到矩形（GetLeft() 返回 nil）—— 实机症状是
    -- "debuff 明明在（按钮 shown、冷却在跑），屏幕上什么都没有"。
    -- 间距和以前完全一致：buff 底 +4 是 proc 行，proc 底 +8 是 debuff 行（proc 空时高度算 0）。
    local function RowHeight(count, size)
        if count <= 0 then return 0 end
        return math.ceil(count / PerRow(size)) * (size + ICON_GAP) - ICON_GAP
    end
    debuffContainer:ClearAllPoints()
    debuffContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP,
        -(AURA_GAP + RowHeight(#auras, BUFF_SIZE) + 4 + RowHeight(#procs, BUFF_SIZE) + 8))

    -- buffContainer 常显（空的时候被 FitContainer 压成 0 高，什么都不画），只切换后两块。
    procContainer:SetShown(#procs > 0)
    debuffContainer:SetShown(#debuffs > 0)
end

--- Throttled update: UNIT_AURA can fire very often during combat.
local function QueueUpdate()
    local frame = buffContainer
    if not frame or pending then return end
    pending = true
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.__elapsed = (self.__elapsed or 0) + elapsed -- TAINT-OK: buffContainer 是自建容器（MonetUICombatBuffFrame），暴雪代码不在此框上运行
        if self.__elapsed < 0.25 then return end
        self.__elapsed = 0 -- TAINT-OK: 同上，自建节流计数
        self:SetScript("OnUpdate", nil)
        pending = false
        M:Update()
    end)
end

local function SuppressBlizzard()
    local found = 0
    for _, name in ipairs({ "BuffFrame", "DebuffFrame", "TempEnchantFrame" }) do
        local blizzard = _G[name]
        if blizzard then
            found = found + 1
            -- **不 Hide()、不 UnregisterAllEvents、不写脚本槽**：
            --   * Hide() 会被暴雪自己的 Show() 顶回来（一边补、一边顶 = 一闪一闪）；
            --   * 写脚本槽 / 注销事件都是"动过这个框"，之后它自己的代码全算成 MonetUI 的污染。
            -- alpha 0 的框一直算"显示着"，不触发它的 Show 逻辑，也就不打架（见 AGENTS.md）。
            pcall(blizzard.SetAlpha, blizzard, 0)
            pcall(blizzard.EnableMouse, blizzard, false)
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

    SuppressBlizzard()

    -- 战斗兜底的引擎容器**必须在脱战时建好**：战斗里建的容器永远空。这里顺手建一次，
    -- 进战斗时就不用现建（也避免进战斗那一刻才失败）。
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
    end)
    -- 换主题：自绘那套直接重涂；引擎那套按钮建完就锁死，只能连容器一起重建。
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        RebuildCombatAuras()
        M:Update()
    end)

    self:Update()
end

function M:SetEnabled(enabled)
    if enabled then
        self:Update()
    else
        -- buffContainer 也藏起来的话，QueueUpdate 的 OnUpdate 驱动就停了，所以只清按钮。
        if procContainer then procContainer:Hide() end
        if debuffContainer then debuffContainer:Hide() end
        if combatBuffs then pcall(combatBuffs.Hide, combatBuffs) end
        if combatDebuffs then pcall(combatDebuffs.Hide, combatDebuffs) end
        for _, button in ipairs(buffButtons) do button:Hide() end
        for _, button in ipairs(procButtons) do button:Hide() end
        for _, button in ipairs(debuffButtons) do button:Hide() end
    end
end

ns:Register("BuffFrame", M)
