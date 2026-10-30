-- Modules/UnitFrames/Groups.lua
-- 小队 / 团队框架：暴雪安全头（SecureGroupHeaderTemplate）+ Monet 皮肤。
--
-- 为什么必须用安全头：战斗中"谁被分到哪个按钮"只能由受限环境决定。手写固定 token 的按钮
-- 在战斗里不能改 unit 属性，也就不能压缩空位、不能换人。我们只在头的外面做三件事：
--   1) 建视觉（边、血条、能量、名字、职责图标）——由 initialConfigFunction 的 secure 片段回调进来；
--   2) 读状态（血量 / 能量 / 存活 / 距离）——一律走 Utils/Secrets.lua，秘密值不做算术；
--   3) 摆位置——交给 Utils/Mover.lua（容器是普通框，拖动不受限；里面的头跟着走）。
--
-- 改属性（尺寸 / 间距 / 显隐驱动 / 显隐头本身）都只能脱战做，战斗里排队到 PLAYER_REGEN_ENABLED。

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local Math     = ns.Math
local EventBus = ns.EventBus
local Mover    = ns.Mover

local M = { name = "GroupFrames" }

local PARTY_UNITS    = 5   -- 自己 + 小队 1..4
local RAID_GROUPS    = 8
local RAID_PER_GROUP = 5
local BORDER         = Widget.BORDER   -- 1px Monet 发丝边（单一来源见 Utils/Widget.lua）

local RANGE_ALPHA    = 0.45
local RANGE_INTERVAL = 0.25

local party        -- { anchor, header, buttons = { ... } }
local raid         -- { anchor, headers = { [1..8] }, buttons = { ... } }
local byUnit = {}
local ticker

local function Config()
    local db = ns:DB()
    return db and db.groupFrames
end

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

--- 一个按钮的高度：上下边 + 血条 + 1px 分隔 + 能量条（没有能量条就不留分隔）。
local function FrameHeight(cfg)
    local power = cfg.power or 0
    return BORDER * 2 + (cfg.health or 16) + (power > 0 and (1 + power) or 0)
end

local function PartyHeight(cfg)
    return PARTY_UNITS * FrameHeight(cfg) + (PARTY_UNITS - 1) * (cfg.spacing or 2)
end

local function RaidHeight(cfg)
    return RAID_PER_GROUP * FrameHeight(cfg) + (RAID_PER_GROUP - 1) * (cfg.spacing or 2)
end

local function RaidWidth(cfg)
    return RAID_GROUPS * cfg.width + (RAID_GROUPS - 1) * (cfg.groupGap or 8)
end

-- ============================================================================
-- 按钮外观
-- ============================================================================

-- 名字显示放宽（2026-10-27 玩家定 70% 规则）：
-- 旧的整段走 Math:Shorten(单一来源,review 2026-10-24 #4)截断，会把名字裁掉 —— 现在
-- 截断规则**暂不使用**，改走 Widget:FitText（超过框宽 70% 就缩字号、绝不裁字）；
-- 布局时仍登记 nameCap（保留设置，暂不读）。

--- 按钮名字的基础字号（FitText 的 baseSize 用；small 框 9 / 普通 10）。
local function NameBaseSize(small) return small and 9 or 10 end

--- 名字最多几个字：中文一个字顶两个拉丁字宽，团队框只放得下三四个。
local function NameCap(cfg)
    local wide = (cfg.width or 72) >= 100
    if GetLocale() == "zhCN" then return wide and 7 or 4 end
    return wide and 10 or 7
end

--- 按钮模板没带 BackdropTemplate 时的退路：四边各一条 1px 贴图，颜色跟主题走。
-- 正常路径是 Widget:Theme（安全头用逗号模板串，BackdropTemplate 会一起合进来）；
-- 这里只是兜底 —— 万一模板串没合上，也不能让"没边框"成为唯一结果。
-- 四边发丝线的公共骨架（review 2026-10-24 #4）：plain / select 两条构建路径原来各复制了一遍
-- "建 4 条贴图 + 锚四边"，只差宿主与绘制层级；现在共用 BuildEdges，粗细 / 颜色由各自的 Size* 填。
local function BuildEdges(host, drawLayer, subLevel)
    local edges = {}
    for i = 1, 4 do
        local tex = host:CreateTexture(nil, drawLayer, nil, subLevel)
        tex:SetTexture(Media.texture.blank)
        edges[i] = tex
    end
    edges[1]:SetPoint("TOPLEFT")
    edges[1]:SetPoint("TOPRIGHT")
    edges[2]:SetPoint("BOTTOMLEFT")
    edges[2]:SetPoint("BOTTOMRIGHT")
    edges[3]:SetPoint("TOPLEFT")
    edges[3]:SetPoint("BOTTOMLEFT")
    edges[4]:SetPoint("TOPRIGHT")
    edges[4]:SetPoint("BOTTOMRIGHT")
    return edges
end

local function PlainBorder(button)
    if button.monetEdges then return button.monetEdges end

    button.monetEdges = BuildEdges(button, "BORDER", 0)
    return button.monetEdges
end

--- 退路边框的粗细与颜色：粗细是物理像素（换 UI 缩放不变粗），颜色跟主题的 borderKey 走。
--- 物理像素粗细（换 UI 缩放不变粗）：两条横边 SetHeight、两条竖边 SetWidth。
local function SizeEdges(edges, thickness)
    if not edges then return end
    edges[1]:SetHeight(thickness)
    edges[2]:SetHeight(thickness)
    edges[3]:SetWidth(thickness)
    edges[4]:SetWidth(thickness)
end

local function SizePlainBorder(button)
    local edges = button.monetEdges
    if not edges then return end

    SizeEdges(edges, BORDER * Media:Mult())

    local r, g, b = Color:GetBorder()
    for i = 1, 4 do edges[i]:SetVertexColor(r, g, b, 1) end
end

-- ============================================================================
-- 选中目标边框
-- ============================================================================

local SELECT_BORDER = 2   -- 物理像素：1px 和按钮自己的边框糊在一起，2px 才一眼分得出来

--- 选中边框的四条边。常驻（建一次），靠顶点色 alpha 显隐：
-- 受保护的按钮在战斗里不能 SetShown / SetAlpha，但改它里面贴图的顶点色随时都行，
-- 所以"谁被选中"这件事在战斗里也能立刻反映，不用等脱战。
-- 建在覆盖层上（StyleButton 保证 overlay 先于它存在）：作为 button 的 region 会被
-- 血条子框架盖住一半，选中这种即时反馈不能发灰。
local function EnsureSelectBorder(button)
    if button.selectEdges then return button.selectEdges end

    button.selectEdges = BuildEdges(button.overlay or button, "OVERLAY", 7)
    return button.selectEdges
end

--- 粗细按物理像素走（换 UI 缩放不变粗）。
local function SizeSelectBorder(button)
    SizeEdges(button.selectEdges, SELECT_BORDER * Media:Mult())
end

--- 点亮 / 熄灭。颜色是主题的 highlight，主题一换由 RefreshAll 重刷。
local function SetSelected(button, selected)
    local edges = button.selectEdges
    if not edges then return end

    local r, g, b = Color:GetHighlight()
    local alpha = selected and 1 or 0
    for i = 1, 4 do edges[i]:SetVertexColor(r, g, b, alpha) end

    button.selected = selected and true or false
end

--- 血条 + 治疗预估 / 吸收盾（P4 拆分：原 StyleButton 内 179-219 行原样搬出）。
local function StyleHealthBars(button, inner, healthHeight)
    if not button.health then
        button.health = Widget:Bar(button, inner, healthHeight)
        -- 空的那一半：一层平涂，血条才有体积
        button.lost = Widget:LostBarBG(button.health, 1, 1, 1, 1)
    end
    button.health:SetSize(inner, healthHeight)
    button.health:ClearAllPoints()
    button.health:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    Widget:BarWeave(button.health, { height = healthHeight })

    -- 治疗预估 / 吸收盾：两条 StatusBar 都从血条填充的右缘往外叠，超出部分由血条裁掉
    --（Pawprint modules/Frames.lua:811-822 的手法）。值全程不做算术，秘密值直接进
    -- SetValue；吸收盾叠在治疗预估的填充右缘之后，预估为 0 时自然贴着血条填充。
    -- 两条都常驻、用值 0 表达"没有"——受保护按钮的子框我们不动显隐，战斗里也安全。
    if not button.incoming then
        local fill = button.health:GetStatusBarTexture()
        local incoming = CreateFrame("StatusBar", nil, button.health)
        incoming:SetPoint("TOPLEFT", fill, "TOPRIGHT")
        incoming:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT")
        incoming:SetStatusBarTexture(Media:Texture("monet_barfill"))
        incoming:SetMinMaxValues(0, 1)
        incoming:SetValue(0)
        button.incoming = incoming

        local absorb = CreateFrame("StatusBar", nil, button.health)
        absorb:SetPoint("TOPLEFT", incoming:GetStatusBarTexture(), "TOPRIGHT")
        absorb:SetPoint("BOTTOMLEFT", incoming:GetStatusBarTexture(), "BOTTOMRIGHT")
        absorb:SetStatusBarTexture(Media:Texture("monet_barfill"))
        absorb:SetMinMaxValues(0, 1)
        absorb:SetValue(0)
        button.absorb = absorb

        button.health:SetClipsChildren(true)
    end
    button.incoming:SetWidth(inner)
    button.absorb:SetWidth(inner)
    -- 主题色（血条填充同源）的低透明度延伸 = 治疗预估；吸收盾用白叠层区分
    local ir, ig, ib = Color:GetPrimary()
    button.incoming:SetStatusBarColor(ir, ig, ib, 0.45)
    button.absorb:SetStatusBarColor(1, 1, 1, 0.3)
end

--- 文字 / 图标 / 选中边框的承载覆盖层（原 220-229 行）。
local function StyleOverlay(button)
    -- 文字 / 图标 / 选中边框的承载层。WoW 的渲染规则是"子框架盖在父级 region 之上"
    --（本仓 UnitFrames.lua:1068-1071 的冷却数字就踩过这个），所以压在血条上面的东西
    -- 不能是 button 的 region —— 会被血条（button 的子框架）整个糊住。收进一个专用
    -- 覆盖层：层级高于血条、治疗预估、吸收盾，内容随它们一起建。
    if not button.overlay then
        local overlay = CreateFrame("Frame", nil, button)
        overlay:SetAllPoints(button)
        overlay:SetFrameLevel(button.health:GetFrameLevel() + 3)
        button.overlay = overlay
    end
end

--- 能量条（原 231-239 行）。**纯高亮平涂，不用渐变**（玩家 2026-10-30 定）。
local function StylePowerBar(button, inner, powerHeight)
    if powerHeight > 0 then
        if not button.power then button.power = Widget:Bar(button, inner, powerHeight, "monet_barfill") end
        button.power:SetSize(inner, powerHeight)
        button.power:ClearAllPoints()
        button.power:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", BORDER, BORDER)
        button.power:Show()
    elseif button.power then
        button.power:Hide()
    end
end

--- 名字 + 血量文字（原 241-269 行）。
local function StyleTexts(button, cfg, small, inner)
    if not button.name then
        button.name = Widget:Font(button.overlay, NameBaseSize(small), "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
        -- 名字压在血条上：小框放不下一行独立的名字，加硬阴影保证亮色血条上也读得清
        if button.name.SetShadowColor then
            button.name:SetShadowColor(0, 0, 0, 1)
            button.name:SetShadowOffset(1, -1)
        end
        button.name:SetWordWrap(false)
    end
    Widget:SetFont(button.name, NameBaseSize(small), "pixel")
    -- 基础字号留在按钮上：名字缩字（FitText）要"从这一档往下缩"，绝不能拿缩过的当 base。
    button.nameSize = NameBaseSize(small)
    -- 血量文字开着时名字给右侧让位（百分比 4 字符 / 当前值带千分位，32 够放）
    local textReserve = ((cfg.healthText or "none") ~= "none") and 32 or 0
    local nameBoxW = inner - 6 - (small and 10 or 12) - textReserve
    button.nameBoxW = nameBoxW   -- FitText 的 boxWidth：自动宽度字串不能用 GetWidth 猜（见 Widget:FitText 注）
    button.name:SetSize(nameBoxW, small and 11 or 13)
    button.name:ClearAllPoints()
    button.name:SetPoint("LEFT", button, "LEFT", BORDER + 3, 0)

    -- 血量文字：压在血条右侧。none 模式也建好（只写空串），切模式不用重建 region。
    if not button.healthText then
        local fs = Widget:Font(button.overlay, small and 9 or 10, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
        if fs.SetShadowColor then
            fs:SetShadowColor(0, 0, 0, 1)
            fs:SetShadowOffset(1, -1)
        end
        button.healthText = fs
    end
    Widget:SetFont(button.healthText, small and 9 or 10, "pixel")
    button.healthText:ClearAllPoints()
    button.healthText:SetPoint("RIGHT", button, "RIGHT", -(BORDER + 3), 0)
    button.healthTextMode = cfg.healthText or "none"
end

--- 职责图标（原 271-278 行）。
local function StyleRoleIcon(button, small)
    -- 职责图标：三张灰阶自绘图，形状说明职责，颜色说明队长 / 助理（Color:RoleTint）。
    -- 压在右上角、探出 1px 进缝里，不占名字的行宽。
    if not button.role then
        button.role = button.overlay:CreateTexture(nil, "OVERLAY")
        button.role:SetTexture(Media:Texture("monet_role_dps"))
        button.role:SetSize(small and 8 or 9, small and 8 or 9)
        button.role:SetPoint("TOPRIGHT", button, "TOPRIGHT", 1, 1)
    end
end

--- 建（或重贴）一个单位按钮的外观。可重复调用：只改尺寸和锚点，不重建 region。
--- P4 拆分：本函数只做"顺序 + 组合"，各段实现在上面五个 helper 里；语义逐条保留
---（无早退、各段条件与顺序都与拆分前一致）。
local function StyleButton(button, cfg, small)
    local width, height = cfg.width, FrameHeight(cfg)
    button:SetSize(width, height)

    if button.SetBackdrop then
        Widget:Theme(button, { thickness = BORDER, bgAlpha = 0.9 })
    else
        PlainBorder(button)
        SizePlainBorder(button)
    end

    local inner = width - BORDER * 2
    local healthHeight = cfg.health or 16
    local powerHeight = cfg.power or 0

    StyleHealthBars(button, inner, healthHeight)
    StyleOverlay(button)
    StylePowerBar(button, inner, powerHeight)
    StyleTexts(button, cfg, small, inner)
    StyleRoleIcon(button, small)
    -- 选中目标边框：四条边常驻、平时 alpha 0，成为当前目标时才点亮（SyncSelection）。
    -- **必须显式初始化 alpha**：BuildEdges 建出来的贴图默认是白色 alpha 1，不主动压掉的话
    -- 每格都像"被选中"（2026-10-25 实机：队伍框开局满屏高亮）。
    EnsureSelectBorder(button)
    SizeSelectBorder(button)
    SetSelected(button, button.selected == true)

    -- Clique / 点击施法类插件认这张表；没装也没有副作用。
    -- 走 _G 拿：这个全局在本客户端根本没有，直接写全局名会被静态检查当成"用了一个不存在的全局"。
    local clickcast = _G.ClickCastFrames
    if type(clickcast) == "table" then
        clickcast[button] = true
    end
end

--- 内容整体变淡（距离太远）。受保护的按钮不能 SetAlpha，改它里面的 region。
local function SetContentAlpha(button, alpha)
    if button.health then button.health:SetAlpha(alpha) end
    if button.power then button.power:SetAlpha(alpha) end
    -- 文字与职责图标都收在覆盖层里，淡一次全淡；预估 / 吸收盾是血条的子框，随血条淡
    if button.overlay then button.overlay:SetAlpha(alpha) end
end

-- ============================================================================
-- 状态刷新
-- ============================================================================

local function UnitClassColor(unit)
    local ok, class = pcall(UnitClassBase, unit)
    -- UnitClassBase 被标了 SecretWhenUnitIdentityRestricted：受限时返回机密串，
    -- 而机密串的 type() 照样是 "string"，直接喂给 ClassColor 会在里面的比较/索引上炸。
    -- 先判 issecretvalue 再用（UnitFrames.lua:466 是同一套写法）。
    if ok and type(class) == "string" and not Secrets.IsSecret(class) then
        local r, g, b = Color:ClassColor(class)
        if r then return r, g, b end
    end
    return Color:GetHealth()
end

local function DisplayName(button)
    local raw = button.unitName or ""
    local dash = string.find(raw, "-", 1, true)
    if dash then raw = string.sub(raw, 1, dash - 1) end
    -- 截断停用（70% 缩字规则，见文件头）：只剥服务名后缀，长度交给 FitText 收。
    return raw
end

--- 名字缩字：占按钮宽最多 70%，超了缩字号、绝不裁字（Widget:FitText 单一入口）。
-- FitText 内部会把 maxWidth 钳到名字框自己的宽度（StyleTexts 里 SetSize 时已给
-- 血量文字留位），所以这里只传 70% 限额。
local function FitName(button, text)
    if not button.name then return end
    Widget:FitText(button.name, text or "", (button:GetWidth() or 72) * 0.70,
        button.nameSize or 9, nil, 6, button.nameBoxW)
end

local function UpdateHealth(button)
    local unit = button.unit
    if not unit or not UnitExists(unit) then return end
    Secrets.SetBar(button.health, UnitHealth(unit), UnitHealthMax(unit), Secrets.SMOOTH)
end

local function UpdatePower(button)
    local unit = button.unit
    if not button.power or not unit or not UnitExists(unit) then return end

    -- Energy is the identity signal in a party frame: colour it by class so a
    -- warrior's rage / rogue's energy / priest's mana read apart at a glance.
    -- (Health deliberately does not use class colour -- see UpdateState.)
    local r, g, b = UnitClassColor(unit)
    button.power:SetStatusBarColor(r, g, b)

    local maximum = UnitPowerMax(unit)
    Secrets.SetBar(button.power, UnitPower(unit), maximum, Secrets.SMOOTH)

    -- 没有这种资源的单位（盗贼满能量、战士 0 怒气）就别留一条空带子
    local plain = Secrets.Number(maximum)
    button.power:SetShown(plain == nil or plain > 0)
end

local function UpdateName(button)
    local unit = button.unit
    if not unit or not UnitExists(unit) then return end

    -- 同案（2026-10-25 战斗名字）：战斗窗口 UnitName 返回机密串 —— 读到机密就不覆盖
    -- 缓存（保持上一轮明文），绝不让 DisplayName 的 string.find 碰机密值。
    local ok, name = pcall(UnitName, unit)
    if ok and type(name) == "string" and not Secrets.IsSecret(name) then
        button.unitName = name
    end
    FitName(button, DisplayName(button))
end

local function UpdateRole(button)
    local unit = button.unit
    if not unit or not UnitExists(unit) then return end

    local ok, role = pcall(UnitGroupRolesAssigned, unit)
    local key = "monet_role_dps"
    if ok and role == "TANK" then
        key = "monet_role_tank"
    elseif ok and role == "HEALER" then
        key = "monet_role_heal"
    end
    button.role:SetTexture(Media:Texture(key))

    local r, g, b = Color:RoleTint(unit)
    button.role:SetVertexColor(r, g, b)
end

--- 存活 / 离线 / 主题色：一条事件（UNIT_HEALTH、UNIT_FLAGS、UNIT_CONNECTION）就能全刷。
local function UpdateState(button)
    local unit = button.unit
    if not unit or not UnitExists(unit) then return end

    -- 机密布尔值级前置（同 UpdateRange 2026-10-25 修：issecretvalue 不触发客户端拦截，
    -- 真值测试才触发；机密时落回与 Bool 被拦后默认**逐位一致**的分支）。进战斗的一次
    -- 全池刷新会把这组测试放大成每次 ×4 的拦截波（UpdateState + UpdateHealthText ± 2）。
    local dead
    if not Secrets.IsSecret(UnitIsDeadOrGhost(unit)) then
        dead = Secrets.Bool(UnitIsDeadOrGhost(unit))
    end
    local offline
    if Secrets.IsSecret(UnitIsConnected(unit)) then
        -- 连接状态未知 → 按在线处理（= Bool 默认 true）
        offline = false
    else
        offline = not Secrets.Bool(UnitIsConnected(unit), true)
    end

    if offline then
        FitName(button, "离线")
    elseif dead then
        FitName(button, "死亡")
    else
        FitName(button, DisplayName(button))
    end

    if dead or offline then
        button.health:SetStatusBarColor(0.35, 0.35, 0.35)
    else
        -- 配色案（2026-10-25）：小队/团队血条 = monetcolor.edge 的 RGB 反相，
        -- 和玩家/目标的目标同款。职业辨认继续只集中在能量条（UpdatePower）。
        local er, eg, eb = Color:GetEdge()
        button.health:SetStatusBarColor(1 - er, 1 - eg, 1 - eb)
    end

    -- 空槽 = 暗色织纹底（同 UnitFrames 的暗织纹；BarWeave 发丝线叠在其上，:187）。
    -- 原来是 danger 红空槽——那套留给目标框，队伍这边不再用红色暗示"掉血"。
    local nr, ng, nb = Color:GetNeutral()
    button.lost:SetVertexColor(nr * 0.32, ng * 0.32, nb * 0.32, 1)
end

-- 血量文字（Pawprint modules/Frames.lua:349-399 的纪律）：
-- plain 值自己算；秘密值不做算术，要么交给客户端的百分比曲线，要么原样喂给
-- SetText / SetFormattedText（C 侧格式化秘密值），写不进去就留空。
local function ShortNum(value)
    if value == nil then return "" end
    if not Secrets.IsSecret(value) then
        local breakUp = _G.BreakUpLargeNumbers
        if breakUp then
            local ok, text = pcall(breakUp, value)
            if ok and text then return text end
        end
        return tostring(value)
    end
    local breakUp = _G.BreakUpLargeNumbers
    if breakUp then
        local ok, text = pcall(breakUp, value)
        if ok then return text end
    end
    return value
end

local function HealthPercent(unit, current, maximum)
    local c, m = Secrets.Number(current), Secrets.Number(maximum)
    if c and m and m > 0 then return c / m * 100 end
    local constants = _G.CurveConstants
    if _G.UnitHealthPercent and constants and constants.ScaleTo100 then
        local ok, pct = pcall(UnitHealthPercent, unit, true, constants.ScaleTo100)
        if ok and (Secrets.IsSecret(pct) or pct ~= nil) then return pct end
    end
end

local function UpdateHealthText(button)
    local fs = button.healthText
    if not fs then return end

    local mode = button.healthTextMode or "none"
    local unit = button.unit
    if mode == "none" or not unit or not UnitExists(unit) then
        fs:SetText("")
        return
    end

    -- 死亡 / 离线时名字行已经在报状态,血量文字让位(值级前置同 UpdateState)
    local dead
    if not Secrets.IsSecret(UnitIsDeadOrGhost(unit)) then
        dead = Secrets.Bool(UnitIsDeadOrGhost(unit))
    end
    local offline
    if Secrets.IsSecret(UnitIsConnected(unit)) then
        offline = false
    else
        offline = not Secrets.Bool(UnitIsConnected(unit), true)
    end
    if dead or offline then
        fs:SetText("")
        return
    end

    local current, maximum = UnitHealth(unit), UnitHealthMax(unit)
    if mode == "percent" then
        local pct = HealthPercent(unit, current, maximum)
        if pct == nil or not pcall(fs.SetFormattedText, fs, "%.0f%%", pct) then
            fs:SetText("")
        end
    else -- "value"
        if not pcall(fs.SetText, fs, ShortNum(current)) then
            fs:SetText("")
        end
    end
end

-- 治疗预估 / 吸收盾（Pawprint modules/Frames.lua:447-455 的纪律）：
-- 返回值可以是秘密值 —— 不做比较、不做算术，原样进 SetValue；minmax 的上限同理。
-- 开关关掉 / 单位不存在时写 0，不写 Show/Hide（见 StyleButton 的常驻注释）。
local function UpdateIncoming(button)
    local bar = button.incoming
    if not bar then return end

    local cfg = Config()
    local unit = button.unit
    if not _G.UnitGetIncomingHeals or not unit or not UnitExists(unit)
       or (cfg and cfg.showIncomingHeals == false) then
        pcall(bar.SetValue, bar, 0)
        return
    end

    local value = UnitGetIncomingHeals(unit)
    if not Secrets.IsSecret(value) and not value then value = 0 end
    pcall(bar.SetMinMaxValues, bar, 0, UnitHealthMax(unit))
    pcall(bar.SetValue, bar, value)
end

local function UpdateAbsorb(button)
    local bar = button.absorb
    if not bar then return end

    local cfg = Config()
    local unit = button.unit
    if not _G.UnitGetTotalAbsorbs or not unit or not UnitExists(unit)
       or (cfg and cfg.showAbsorbs == false) then
        pcall(bar.SetValue, bar, 0)
        return
    end

    local value = UnitGetTotalAbsorbs(unit)
    if not Secrets.IsSecret(value) and not value then value = 0 end
    pcall(bar.SetMinMaxValues, bar, 0, UnitHealthMax(unit))
    pcall(bar.SetValue, bar, value)
end

local function UpdateRange(button)
    local unit = button.unit
    if not unit or unit == "player" or not UnitExists(unit) then
        SetContentAlpha(button, 1)
        return
    end

    local ok, inRange, checked = pcall(UnitInRange, unit)
    if not ok then
        SetContentAlpha(button, 1)
        return
    end

    -- 对机密值做布尔测试会被客户端拦下（2026-10-25 13:37 细档实锤：UNKNOWN() 日志族
    -- 99% 的发源就是下面这两行，~5 条/秒持续）。issecretvalue 的**值级判定不触发拦**，
    -- 真值测试才触发 —— 所以先值级判，机密时直接落回"未知"语义（known=nil / near=true，
    -- 与 Bool 被拦后的回退默认**逐位一致**），非机密才做真值测试。
    local known, near
    if not Secrets.IsSecret(checked) then known = Secrets.Bool(checked) end
    if Secrets.IsSecret(inRange) then
        near = true
    else
        near = Secrets.Bool(inRange, true)
    end
    SetContentAlpha(button, (known and not near) and RANGE_ALPHA or 1)
end

local function RefreshButton(button)
    UpdateName(button)
    UpdateHealth(button)
    UpdatePower(button)
    UpdateRole(button)
    UpdateState(button)
    UpdateHealthText(button)
    UpdateIncoming(button)
    UpdateAbsorb(button)
    UpdateRange(button)
end

-- ============================================================================
-- 单位映射
-- ============================================================================

local function MapButtons()
    byUnit = {}

    local function add(list)
        if not list then return end
        for i = 1, #list do
            local button = list[i]
            local unit = button:GetAttribute("unit")
            if unit then
                button.unit = unit
                byUnit[unit] = button
            end
        end
    end

    if party then add(party.buttons) end
    if raid then add(raid.buttons) end
end

--- 谁是当前目标：按钮的 unit 和目标同一个单位就点亮它的边框。
-- 只在上一个/当前选中的按钮变化时才写顶点色 —— 切目标很频繁，但真正变的通常只有两个按钮。
local selectedButton

local function SyncSelection()
    local target

    -- 只看显示着的按钮：团队里小队的那些按钮还在 byUnit 里（unit 已被安全头清空，这里再兜一层）
    -- IsShown 在受限环境下也可能返回机密值，统一过 Secrets.Bool（读不出来按"没显示"）。
    for unit, button in pairs(byUnit) do
        if Secrets.Bool(button:IsShown(), false) then
            -- UnitIsUnit 在受限时返回**机密布尔**（秘密标注 SecretWhenUnitComparisonRestricted，
            -- AGENTS 实机判例）：先值级判，机密就当作"不是"跳过（= Bool 被拦后的 nil 回退分支）。
            local ok, same = pcall(UnitIsUnit, unit, "target")
            if ok and not Secrets.IsSecret(same) and Secrets.Bool(same) then
                target = button
                break
            end
        end
    end

    if target == selectedButton then return end

    if selectedButton then SetSelected(selectedButton, false) end
    selectedButton = target
    if selectedButton then SetSelected(selectedButton, true) end
end

--- 名册变了：按钮的归属可能整体换了，先重映射再把每个可见按钮刷一遍。
function M:RefreshAll()
    MapButtons()
    for _, button in pairs(byUnit) do
        -- 退路边框的颜色跟着主题走（走 Widget:Theme 的按钮没有 monetEdges，这里是空转）
        SizePlainBorder(button)
        SizeSelectBorder(button)
        if Secrets.Bool(button:IsShown(), false) then RefreshButton(button) end
    end

    -- 名册一动，目标可能换到别的按钮上；主题一换，选中色也要重上
    SyncSelection()
end

function M:UpdateUnit(unit, kind)
    local button = unit and byUnit[unit]
    if not button or not Secrets.Bool(button:IsShown(), false) then return end

    if kind == "health" then
        -- 血条填充的右缘动了，预估 / 吸收盾的锚点与上限都要跟着重算
        UpdateHealth(button)
        UpdateState(button)
        UpdateHealthText(button)
        UpdateIncoming(button)
        UpdateAbsorb(button)
    elseif kind == "power" then
        UpdatePower(button)
    elseif kind == "heal" then
        UpdateIncoming(button)
    elseif kind == "absorb" then
        UpdateAbsorb(button)
    elseif kind == "name" then
        UpdateName(button)
        UpdateState(button)
        UpdateHealthText(button)
    else
        UpdateState(button)
        UpdateHealthText(button)
    end
end

-- ============================================================================
-- 安全头
-- ============================================================================

--- secure 片段：建按钮时在受限环境里设尺寸和点击属性，最后回 Lua 建视觉。
local function SecureInit(width, height)
    return ([[
    self:SetWidth(%d)
    self:SetHeight(%d)
    self:SetAttribute("*type1", "target")
    self:SetAttribute("*type2", "togglemenu")
    self:GetParent():CallMethod("initialConfigFunction", self:GetName())
]]):format(width, height)
end

local function CreateHeader(name, parent, cfg, count)
    local ok, header = pcall(CreateFrame, "Frame", name, parent, "SecureGroupHeaderTemplate")
    if not ok or not header then return nil end

    local buttons = {}

    -- CallMethod 会把 header 作为 self 传入，所以回调签名必须是 (self, buttonName)；
    -- 少了 self 的话 buttonName 拿到的是 header 本身，_G[header] 恒为 nil，StyleButton 永不执行。
    header.initialConfigFunction = function(self, buttonName)
        local button = _G[buttonName]
        if not button then return end

        StyleButton(button, cfg, (cfg.width or 72) < 100)
        button.nameCap = NameCap(cfg)

        if not button.monetListed then
            button.monetListed = true
            buttons[#buttons + 1] = button
        end
    end

    header:SetAttribute("template", "SecureUnitButtonTemplate,BackdropTemplate")
    header:SetAttribute("initialConfigFunction", SecureInit(cfg.width, FrameHeight(cfg)))
    header:SetAttribute("showSolo", false)
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("unitsPerColumn", count)
    header:SetAttribute("maxColumns", 1)
    header:SetAttribute("point", "TOP")
    header:SetAttribute("xOffset", 0)
    header:SetAttribute("yOffset", -(cfg.spacing or 2))

    return header, buttons
end

--- 预创建：脱战时把全部按钮物化出来，否则战斗中第一次换人建不出新按钮。
-- 注意：安全头算要建几个按钮的公式是 unitCount - (startingIndex - 1)（SecureGroupHeaders.lua:144），
-- startingIndex 给 1 - count 时，如果预创建那一刻队伍里已经有人（比如在队伍里 /reload），
-- 会多建几个。多出来的按钮一直是隐藏且 unit=nil 的，MapButtons 会跳过，不会画错人。
local function Precreate(header, count)
    header:SetAttribute("startingIndex", 1 - count)
    header:Show()
    header:SetAttribute("startingIndex", 1)
end

--- 显隐驱动：开/关都只换这一条，别让"停用后又被驱动点亮"。
local function SetDriver(header, snippet, on)
    if not header then return end
    if on then
        pcall(RegisterAttributeDriver, header, "state-visibility", snippet)
    else
        pcall(UnregisterAttributeDriver, header, "state-visibility")
    end
end

--- 头和它的按钮能不能显示，跟当前队伍形态对齐（驱动只负责之后的切换）。
local function SyncHeaderShown(header, kind)
    if not header then return end
    local shown
    if kind == "raid" then
        shown = IsInRaid() and true or false
    else
        shown = (not IsInRaid()) and IsInGroup() and true or false
    end
    pcall(header.SetShown, header, shown)
end

-- ============================================================================
-- 暴雪自己的框体
-- ============================================================================

local parked = setmetatable({}, { __mode = "k" })

--- 藏掉暴雪的团队/小队框。
--- **不写字段、不挂 OnShow 钩子、也不 Hide()**：
---   * 写字段 / HookScript 会把框标脏；
---   * `Hide()` 同样会被算成"插件动过这个受保护框"，之后它自己的
---     `CompactUnitFrame_UpdateHealthColor` 比较机密颜色分量就会抛
---     "attempt to compare local 'oldR' (a secret number value, while execution tainted by 'MonetUI')"。
--- 所以只做 **alpha 0 + 关鼠标**（和 MainActionBar 同一套，那一套实测是干净的），
--- 框体本身保持在显示状态，它的更新逻辑照常跑，不会进"受保护被拒"的分支。
local function Park(frame)
    if not frame or parked[frame] then return end
    parked[frame] = true
    -- 1. alpha 0（保持"仍在显示"的语义，不与自身 Show 拉锯）
    pcall(frame.SetAlpha, frame, 0)
    -- 2. 关鼠标（EnableMouse 不受保护）
    pcall(frame.EnableMouse, frame, false)
    if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, false) end
    -- 3. 移出屏幕 —— 暴雪可能画 backdrop/border/selection highlight 且
    --    SetIgnoreParentAlpha，alpha 0 挡不住；SetPoint 不受保护。
    if type(frame.ClearAllPoints) == "function" then pcall(frame.ClearAllPoints, frame) end
    if type(frame.SetPoint) == "function" then
        pcall(frame.SetPoint, frame, "TOPLEFT", "UIParent", "BOTTOMRIGHT", 1, -1)
    end
end

local function Unpark(frame)
    if not frame or not parked[frame] then return end
    parked[frame] = nil
    pcall(frame.SetAlpha, frame, 1)
    pcall(frame.Show, frame)
end

--- 暴雪的小队/团队框分两组（小队 `PartyFrame` 是新式分离框，团队两组是容器 + 管理器）。
local BLIZZARD_GROUP_FRAMES = {
    party = { "CompactPartyFrame", "PartyFrame" },
    raid  = { "CompactRaidFrameContainer", "CompactRaidFrameManager" },
}

--- 饿事件：框体不再收到 GROUP_ROSTER_UPDATE / UNIT_*，因此不会被再次拉起或刷新。
--- 这是 NDui 的做法，也是三家里唯一不动受保护几何/层级就能"关掉"的路径。
--- **不可逆**：Blizzard 自己注册的事件在插件侧补不回来，还原只能靠 /reload。
local starved = setmetatable({}, { __mode = "k" })
local warnedReload = false

local function Starve(frame)
    if not frame or starved[frame] then return end
    starved[frame] = true
    pcall(frame.UnregisterAllEvents, frame)
end

local function Unstarve(frame)
    if not frame or not starved[frame] then return end
    starved[frame] = nil
    if not warnedReload then
        warnedReload = true
        if type(ns.Print) == "function" then
            ns:Print("暴雪团队/小队框的事件需要在 /reload 之后才会重新注册。")
        end
    end
end

--- alpha 0 的成员框仍然占着鼠标:点空地会被当成点单位(选目标/施法)。
--- `EnableMouse` 不受保护、也不写字段,所以只关鼠标是最便宜的修法。
---
--- 层级比看上去深:团队是 容器 → `CompactRaidGroupN` → `CompactRaidGroupNMemberM`,
--- 小队还另有独立全局 `PartyMemberFrameN` / `CompactPartyFrameMemberN`(不一定是容器的子框)。
--- 所以这里**递归**关(深度 4 足够覆盖上述三代),外加显式名单兜底;
--- 成员框是 LoD/进组后才建的,所以 Repark 每次都会重扫(幂等,几十个框的 pcall,可忽略)。
local EXTRA_PARTY_MEMBERS = {}
for i = 1, 5 do
    EXTRA_PARTY_MEMBERS[#EXTRA_PARTY_MEMBERS + 1] = "PartyMemberFrame" .. i
    EXTRA_PARTY_MEMBERS[#EXTRA_PARTY_MEMBERS + 1] = "CompactPartyFrameMember" .. i
end

local function MuteOne(frame, enable)
    if not frame then return end
    -- 战斗中**不能**对受保护的成员框 EnableMouse / EnableMouseMotion —— 会被客户端拦成
    -- ADDON_ACTION_BLOCKED（实机 ×984，每秒一条，来自压制 ticker）。战斗中只靠 AlphaTree 的
    -- alpha 0 + 移出屏幕挡视觉；鼠标在脱战后由 1s ticker 补关（那时不受保护）。
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if type(frame.EnableMouse) == "function" then pcall(frame.EnableMouse, frame, enable) end
    if type(frame.EnableMouseMotion) == "function" then pcall(frame.EnableMouseMotion, frame, enable) end
end

--- 暴雪的紧凑框对很多子件设了 `SetIgnoreParentAlpha(true)`，
--- 所以根框 `SetAlpha(0)` 挡不住它们露出来（空心描边）。
--- 必须逐件归零；归还时统一拉回 1（简单、安全、幂等）。
local function AlphaTree(frame, alpha, depth)
    if not frame then return end
    depth = depth or 0
    if type(frame.SetAlpha) == "function" then pcall(frame.SetAlpha, frame, alpha) end
    if depth >= 4 or type(frame.GetChildren) ~= "function" then return end
    local ok, kids = pcall(frame.GetChildren, frame)
    if not ok or type(kids) ~= "table" then return end
    for i = 1, #kids do AlphaTree(kids[i], alpha, depth + 1) end
end

local function MuteTree(frame, enable, depth)
    if not frame then return end
    depth = depth or 0
    MuteOne(frame, enable)
    if depth >= 4 or type(frame.GetChildren) ~= "function" then return end
    local ok, kids = pcall(frame.GetChildren, frame)
    if not ok or type(kids) ~= "table" then return end
    for i = 1, #kids do MuteTree(kids[i], enable, depth + 1) end
end

local function MuteChildren(frame, enable)
    MuteTree(frame, enable, 0)
    if not enable then return end
    -- 归还时把独立全局成员框一起放开
    for _, name in ipairs(EXTRA_PARTY_MEMBERS) do MuteOne(_G[name], true) end
end

local function ParkGroup(frame)
    Park(frame)            -- alpha 0 + 关鼠标（与 MainActionBar 同一套，不写字段、不 Hide）
    Starve(frame)          -- 饿事件：不再被暴雪自己拉起
    AlphaTree(frame, 0)    -- 递归归零 alpha（绕过 IgnoreParentAlpha 漏网）
    MuteTree(frame, false) -- 整棵子树关鼠标（成员按钮在第三层）
    if frame == _G.CompactPartyFrame or frame == _G.PartyFrame then
        -- 小队的独立成员框不一定是容器的子框
        for _, name in ipairs(EXTRA_PARTY_MEMBERS) do
            MuteOne(_G[name], false)
            AlphaTree(_G[name], 0)
        end
    end
end

local function UnparkGroup(frame)
    if not frame then return end
    Unstarve(frame)
    AlphaTree(frame, 1)    -- 归还：全树拉回 alpha 1
    MuteChildren(frame, true)
    Unpark(frame)
    -- 独立成员框也恢复
    for _, name in ipairs(EXTRA_PARTY_MEMBERS) do
        MuteOne(_G[name], true)
        AlphaTree(_G[name], 1)
    end
end

--- 藏掉暴雪的团队/小队框（`groupFrames.hideBlizzard`）。
---
--- **不 Hide()、不 SetParent、不挂 OnShow、不写字段**：
---   * Hide()/SetParent 会被算成"插件动过这个受保护框"，退出编辑模式时
---     `CompactUnitFrame_UpdateHealthColor` 比较机密颜色分量就会抛
---     "attempt to compare local 'oldR' (a secret number value, while execution tainted by 'MonetUI')"；
---   * 所以只做 **饿事件 + alpha 0 + 关鼠标**：框体仍算"显示"，它自己的更新逻辑照常跑，
---     不写任何属性、不换父，语义上最接近"玩家把它调成透明"。
---
--- 本仓 2026-10 的旧记录里，对 `CompactPartyFrame` 直接 SetAlpha 也复现过上面那条 oldR。
--- 这一版按新方案重试（先饿事件、只有 alpha/鼠标两项）；若退出编辑模式再报，
--- 把 `groupFrames.hideBlizzard` 关掉即可退回到"完全放手"，不需要改代码。
local function SetBlizzardHidden(cfg, partyActive, raidActive)
    local hide = not (cfg and cfg.hideBlizzard == false)
    local groups = BLIZZARD_GROUP_FRAMES

    if not hide then
        for _, name in ipairs(groups.party) do UnparkGroup(_G[name]) end
        for _, name in ipairs(groups.raid)  do UnparkGroup(_G[name]) end
        return
    end

    for _, name in ipairs(groups.party) do
        if partyActive then ParkGroup(_G[name]) else UnparkGroup(_G[name]) end
    end
    for _, name in ipairs(groups.raid) do
        if raidActive then ParkGroup(_G[name]) else UnparkGroup(_G[name]) end
    end
end

--- LoD 补做：`Blizzard_CompactRaidFrames` 可能在登录之后才加载，而且加载时会把框换成新对象
--- （"藏一次 + 盯 OnShow"永远漏），所以三个时机各补一次。
--- Park/Starve 都是幂等的（弱键旁表守卫），重复调用只是两次查表。
local function ReparkBlizzardGroups()
    local cfg = Config()
    if not cfg then return end
    local partyCfg, raidCfg = cfg.party, cfg.raid
    if not partyCfg or not raidCfg then return end
    if type(ns.IsModuleEnabled) == "function" and ns:IsModuleEnabled("GroupFrames") == false then
        return
    end
    SetBlizzardHidden(cfg,
        party ~= nil and partyCfg.enabled ~= false,
        raid ~= nil and raidCfg.enabled ~= false)
end

-- ============================================================================
-- 子框鼠标循环静音（补 LoD 漏网）
-- ============================================================================
--- 子框（StatusIcon、Pet 等）是 LoD 后建的，`MuteTree` 跑一次抓不全。
--- 用一个轻量 ticker 每 1 秒重扫 parked 框的整棵子树，pcall 关鼠标 —— 只有几十个
--- EnableMouse 调用，开销可忽略；幂等，对已关的框重复调用无副作用。
local muteTicker

local function StopMuteTicker()
    if muteTicker then muteTicker:Cancel(); muteTicker = nil end
end

local MUTE_ROOTS = { "CompactPartyFrame", "PartyFrame",
                     "CompactRaidFrameContainer", "CompactRaidFrameManager" }

local function StartMuteTicker()
    StopMuteTicker()
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    muteTicker = C_Timer.NewTicker(1, function()
        for _, name in ipairs(MUTE_ROOTS) do
            local f = _G[name]
            if f and parked[f] then
                AlphaTree(f, 0)
                MuteTree(f, false)
            end
        end
    end)
end

local function StylePartyHeader(header, cfg)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", false)
    header:SetAttribute("showPlayer", cfg.showPlayer ~= false)
    header:SetAttribute("yOffset", -(cfg.spacing or 2))
    -- 头自己的宽高由安全头按按钮尺寸算（SecureGroupHeaders.lua:251），这里不要抢着设。
end

local function StyleRaidHeader(header, cfg)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showParty", false)
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("point", "TOP")
    header:SetAttribute("xOffset", 0)
    header:SetAttribute("yOffset", -(cfg.spacing or 2))
    header:SetAttribute("unitsPerColumn", RAID_PER_GROUP)
    header:SetAttribute("maxColumns", 1)
    header:SetAttribute("sortMethod", "NAME")
    -- 宽高由安全头自己按按钮尺寸算（SecureGroupHeaders.lua:251），这里不设。
end

local function BuildParty(cfg)
    local anchor = CreateFrame("Frame", "MonetPartyAnchor", UIParent)
    anchor:SetSize(cfg.width, PartyHeight(cfg))

    local header, buttons = CreateHeader("MonetPartyHeader", anchor, cfg, PARTY_UNITS)
    if not header then
        anchor:Hide()
        return nil
    end

    StylePartyHeader(header, cfg)
    header:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    Precreate(header, PARTY_UNITS)

    party = { anchor = anchor, header = header, buttons = buttons }
    SyncHeaderShown(header, "party")
    return party
end

local function BuildRaid(cfg)
    local anchor = CreateFrame("Frame", "MonetRaidAnchor", UIParent)
    anchor:SetSize(RaidWidth(cfg), RaidHeight(cfg))

    local result = { anchor = anchor, headers = {}, buttons = {} }

    for group = 1, RAID_GROUPS do
        local header, buttons = CreateHeader("MonetRaidGroup" .. group, anchor, cfg, RAID_PER_GROUP)
        if not header then
            anchor:Hide()
            return nil
        end

        StyleRaidHeader(header, cfg)
        header:SetAttribute("groupFilter", tostring(group))
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", anchor, "TOPLEFT", (group - 1) * (cfg.width + (cfg.groupGap or 8)), 0)

        Precreate(header, RAID_PER_GROUP)

        result.headers[group] = header
        for i = 1, #buttons do result.buttons[#result.buttons + 1] = buttons[i] end
    end

    raid = result
    for group = 1, RAID_GROUPS do SyncHeaderShown(result.headers[group], "raid") end
    return raid
end

--- 尺寸 / 间距变了：脱战重贴所有按钮和头的属性（按钮是受保护的，改属性只能脱战）。
local function RestyleParty(cfg)
    if not party then return end
    party.anchor:SetSize(cfg.width, PartyHeight(cfg))

    local header = party.header
    StylePartyHeader(header, cfg)

    for i = 1, #party.buttons do
        local button = party.buttons[i]
        StyleButton(button, cfg, cfg.width < 100)
        button.nameCap = NameCap(cfg)
    end
end

local function RestyleRaid(cfg)
    if not raid then return end
    raid.anchor:SetSize(RaidWidth(cfg), RaidHeight(cfg))

    for group = 1, RAID_GROUPS do
        local header = raid.headers[group]
        if header then
            StyleRaidHeader(header, cfg)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", raid.anchor, "TOPLEFT",
                (group - 1) * (cfg.width + (cfg.groupGap or 8)), 0)
        end
    end

    for i = 1, #raid.buttons do
        local button = raid.buttons[i]
        StyleButton(button, cfg, cfg.width < 100)
        button.nameCap = NameCap(cfg)
    end
end

-- ============================================================================
-- 距离扫描
-- ============================================================================

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function StartTicker()
    StopTicker()
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    ticker = C_Timer.NewTicker(RANGE_INTERVAL, function()
        for _, button in pairs(byUnit) do
            if Secrets.Bool(button:IsShown(), false) then UpdateRange(button) end
        end
    end)
end

-- ============================================================================
-- 模块接口
-- ============================================================================

-- 排队补做时以模块开关的当前状态为准（排队期间可能被停用，别把已经关掉的框又建回来）
local function DesiredState()
    if type(ns.IsModuleEnabled) == "function"
       and ns:IsModuleEnabled("GroupFrames") == false then
        M:SetEnabled(false)
    else
        M:Apply()
    end
end

function M:Apply()
    local cfg = Config()
    if not cfg then return end

    -- 受保护的框（安全头）在战斗里不能建、不能改属性：排队到脱战，别硬来。
    if InCombat() then
        ns:AfterCombat("groupframes-state", DesiredState)
        return
    end

    local partyCfg, raidCfg = cfg.party, cfg.raid
    if not partyCfg or not raidCfg then return end

    if partyCfg.enabled ~= false then
        if not party then BuildParty(partyCfg) end
        if party then
            RestyleParty(partyCfg)
            SetDriver(party.header, "[group:party] show; hide", true)
            SyncHeaderShown(party.header, "party")
            party.anchor:Show()
            Mover:Register(party.anchor, "groupParty", {
                group   = "groups",
                label   = "小队框架",
                default = partyCfg,
                store   = function() return partyCfg end,
                isVisible = function()
                    return partyCfg.enabled ~= false and (not IsInRaid()) and IsInGroup() and true or false
                end,
            })
        end
    elseif party then
        SetDriver(party.header, nil, false)
        pcall(party.header.Hide, party.header)
        party.anchor:Hide()
    end

    if raidCfg.enabled ~= false then
        if not raid then BuildRaid(raidCfg) end
        if raid then
            RestyleRaid(raidCfg)
            for group = 1, RAID_GROUPS do
                SetDriver(raid.headers[group], "[group:raid] show; hide", true)
                SyncHeaderShown(raid.headers[group], "raid")
            end
            raid.anchor:Show()
            Mover:Register(raid.anchor, "groupRaid", {
                group   = "groups",
                label   = "团队框架",
                default = raidCfg,
                store   = function() return raidCfg end,
                isVisible = function()
                    return raidCfg.enabled ~= false and IsInRaid() and true or false
                end,
            })
        end
    elseif raid then
        for group = 1, RAID_GROUPS do
            SetDriver(raid.headers[group], nil, false)
            pcall(raid.headers[group].Hide, raid.headers[group])
        end
        raid.anchor:Hide()
    end

    SetBlizzardHidden(cfg,
        party ~= nil and partyCfg.enabled ~= false,
        raid ~= nil and raidCfg.enabled ~= false)

    self:RefreshAll()
    StartTicker()
    StartMuteTicker()   -- 循环静音暴雪子框鼠标（LoD 补网）
end

function M:RegisterEvents()
    local unitEvents = {
        UNIT_HEALTH       = "health",
        UNIT_MAXHEALTH    = "health",
        UNIT_POWER_UPDATE = "power",
        UNIT_MAXPOWER     = "power",
        UNIT_DISPLAYPOWER = "power",
        UNIT_NAME_UPDATE  = "name",
        UNIT_CONNECTION   = "state",
        UNIT_FLAGS        = "state",
        UNIT_HEAL_PREDICTION       = "heal",
        UNIT_ABSORB_AMOUNT_CHANGED = "absorb",
    }

    for event, kind in pairs(unitEvents) do
        EventBus:Register(event, function(_, unit)
            M:UpdateUnit(unit, kind)
        end)
    end

    -- 进组/退组时暴雪会新建（或复活）成员框，鼠标要重新关一遍
    EventBus:Register("GROUP_ROSTER_UPDATE", function()
        M:RefreshAll()
        ReparkBlizzardGroups()
    end)
    -- 暴雪的框是 LoD + 会被换成新对象：进世界 / 换区 / 该包加载时都补一次压制。
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        M:RefreshAll()
        ReparkBlizzardGroups()
    end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", function() ReparkBlizzardGroups() end)
    EventBus:Register("ADDON_LOADED", function(_, name)
        if name == "Blizzard_CompactRaidFrames" then ReparkBlizzardGroups() end
    end)

    -- 选中目标边框：切目标只改四条边的 alpha，战斗里也能立刻跟上
    EventBus:Register("PLAYER_TARGET_CHANGED", function() SyncSelection() end)

    -- 战斗里排队的补做已交给 ns:AfterCombat（Core 统一注册 PLAYER_REGEN_ENABLED 排空）。

    EventBus:Register("MONETUI_THEME_CHANGED", function() M:RefreshAll() end)
end

function M:Initialize()
    self:RegisterEvents()
    self:Apply()
end

function M:SetEnabled(enabled)
    -- 停用要拆安全头、藏受保护框，同样是战斗受限操作：排队到脱战。
    -- Apply / SetEnabled 两条入口在战斗里想补做的是同一件事"按开关现状落地"，
    -- 所以共用一个 key（ns:AfterCombat 按 key 去重；DesiredState 读实时状态，任何顺序都对）。
    if InCombat() then
        ns:AfterCombat("groupframes-state", DesiredState)
        return
    end

    if enabled then
        self:Apply()
        StartMuteTicker()   -- 循环静音暴雪子框鼠标（LoD 补网）
        return
    end

    StopMuteTicker()        -- 模块停用：不再关子框鼠标
    StopTicker()
    if party then
        SetDriver(party.header, nil, false)
        pcall(party.header.Hide, party.header)
        party.anchor:Hide()
    end
    if raid then
        for group = 1, RAID_GROUPS do
            SetDriver(raid.headers[group], nil, false)
            pcall(raid.headers[group].Hide, raid.headers[group])
        end
        raid.anchor:Hide()
    end
    SetBlizzardHidden(Config() or {}, false, false)
end

--- 首领框架（Modules/UnitFrames/BossFrames.lua）复用这里的样式件。
--- 它们原本是文件局部函数，BossFrames 的 StyleReady() 因此永远为假、一直走降级皮肤
--- （review 2026-10-29 H18）。导出后由 BossFrames 显式取用。
M.StyleButton = StyleButton
M.NameCap = NameCap
M.UpdateHealthText = UpdateHealthText
M.FrameHeight = FrameHeight

ns:Register("GroupFrames", M)
