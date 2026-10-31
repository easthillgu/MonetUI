-- Modules/UnitFrames/UnitFrames.lua
-- Player / target / focus / pet unit frames, slim-bar style.
-- Bars are fed raw values via Secrets.SetBar; numeric text only once the client
-- confirms the values are readable (see Utils/Secrets.lua).

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Secrets = ns.Secrets
local Widget  = ns.Widget
local Color   = ns.Color
local Math    = ns.Math
local Media   = ns.Media
local EventBus = ns.EventBus

local M = { name = "UnitFrames" }

local frames = {}

local UNIT_LABEL = {
    player       = "玩家",
    target       = "目标",
    targettarget = "目标的目标",
    focus        = "焦点",
    pet          = "宠物",
}

-- Build order matters: every frame anchors to one earlier in the list.
local UNITS = { "player", "target", "targettarget", "focus", "pet" }

-- 可见性交给安全环境：这些框是 SecureUnitButtonTemplate，战斗中不能由我们 Show/Hide
-- （日志里 MonetUITargetFrame:Show()/Hide() 攒了两百多次的根因）。用 state driver 描述
-- "有这个单位就显示"，由客户端的受限环境在战斗中自己切换，我们只负责内容。
-- player 永远存在，所以是无条件 show；其余按 @unit 判断。
local VISIBILITY = {
    player       = "show",
    target       = "[@target,exists] show; hide",
    targettarget = "[@targettarget,exists] show; hide",
    focus        = "[@focus,exists] show; hide",
    pet          = "[@pet,exists] show; hide",
}

--- 换驱动，而不是写显隐：enabled=false 时整块收起。
local function ApplyVisibility(frame, enabled)
    if not frame or type(_G.RegisterStateDriver) ~= "function" then return end
    local condition = enabled and VISIBILITY[frame.unit] or "hide"
    pcall(_G.RegisterStateDriver, frame, "visibility", condition or "hide")
end

-- Name caps, in CHARACTERS and per locale: a Chinese glyph is about twice as
-- wide as a Latin one at the same size, so the same line holds roughly half as many.
local ZH          = GetLocale() == "zhCN"
local NAME_CAP    = ZH and 8 or 10   -- player / target
local NAME_CAP_SM = ZH and 5 or 8    -- targettarget / focus (half-width frames)

-- Text sits above the bar: name "LEFT"|"RIGHT"|"CENTER",
-- level true = drawn beside the name, healthText "LEFT"|"RIGHT". Pet frames carry no text.
local TEXT_LAYOUT = {
    player       = { name = "LEFT",   level = true,  healthText = "RIGHT", cap = NAME_CAP    },
    target       = { name = "LEFT",   level = true,  healthText = "RIGHT", cap = NAME_CAP    },
    targettarget = { name = "CENTER", level = false,                       cap = NAME_CAP_SM },
    focus        = { name = "CENTER", level = false,                       cap = NAME_CAP_SM },
    pet          = {},
}

local TEXT_GAP   = Widget.TEXT_GAP   -- gap between the frame's top edge and the text row
local NAME_SIZE  = 10
local SMALL_SIZE = 10

-- 暴雪单位框的压制/归还已拆到 Modules/UnitFrames/Blizzard.lua（P5，move-only）：
-- 对外仍是 M:SuppressBlizzard(enable) / M:HideBlizzardCastBars(enable)，调用点不变。

local function Shared(key)
    local stored = (ns:DB().unitFrames or {})[key]
    if stored ~= nil then return stored end
    return (ns.DEFAULTS.unitFrames or {})[key]
end

-- 暴雪施法条的压制/归还已随 Blizzard.lua 一起搬走（P5）。

--- One setting for one unit: stored value, then per-unit default, then the shared block.
local function Setting(unit, key)
    local stored = (ns:DB().unitFrames or {})[unit]
    local value = stored and stored[key]
    if value ~= nil then return value end
    local fallback = (ns.DEFAULTS.unitFrames or {})[unit]
    value = fallback and fallback[key]
    if value ~= nil then return value end
    return Shared(key)
end

local function UnitGeometry(unit)
    return Setting(unit, "width")  or 160,
           Setting(unit, "health") or 4,
           Setting(unit, "power")  or 1
end

-- ---------------------------------------------------------------------------
-- 宠物框"悬停 / 选中才显示"（玩家 2026-10-26 要求）。
--
-- 显隐本身仍归 visibility 状态驱动（SecureUnitButton 战斗里不能 Show/Hide），这里只动 alpha：
-- alpha 0 的帧在客户端眼里照样是"显示着"的，鼠标进得来，所以"移上去才浮现"不会把自己锁死。
-- "选中" = 宠物是当前目标或焦点 —— 这两件事不会给我们任何脚本回调，只能轮询。
-- 判定一律走轮询（Widget:HoverWatch / PollWatch）：绝不往受保护的单位按钮上挂脚本。
-- ---------------------------------------------------------------------------
local PET_IDLE_ALPHA = 0

local function Truthy(value) return value and true or false end

--- 宠物是不是"被选中"（当前目标 / 焦点）。
--- `UnitIsUnit` 标着 SecretWhenUnitComparisonRestricted：受限时拿它的返回值做布尔测试会被客户端
--- 直接拦成错误（`ADDON_ACTION_BLOCKED UNKNOWN()`）。**读不出来时按"选中"处理** —— 宁可多显示
--- 一条框，也不要凭空把宠物血条藏掉（藏掉等于看不见血量，代价更大）。
local function PetSelected()
    if not UnitIsUnit then return false end
    local units = { "target", "focus" }
    for i = 1, #units do
        local got, is = pcall(UnitIsUnit, units[i], "pet")
        if got then
            local ok, yes = pcall(Truthy, is)
            if not ok or yes then return true end
        end
    end
    return false
end

local function SetPetAlpha(frame, shown)
    local value = shown and 1 or PET_IDLE_ALPHA
    if Marked(frame, "petAlpha") == value then return end
    -- 只记成功的那个值：受限环境下 SetAlpha 万一被拒，下次轮询还要再试。
    if pcall(frame.SetAlpha, frame, value) then Mark(frame, "petAlpha", value) end
end

--- 开关只改标记（回调是常驻登记的，轮询里自己看标记，关掉后不会再被拉回 0）。
local function ApplyPetHover(frame, enabled)
    if not frame or frame.unit ~= "pet" then return end
    Mark(frame, "petHoverOn", enabled and true or false)
    if not enabled then
        SetPetAlpha(frame, true)
        return
    end

    if not Marked(frame, "petHoverWatched") then
        Mark(frame, "petHoverWatched", true)
        -- 悬停 0.1 秒一次（浮现要跟手）；选中 / 取消选中 0.2 秒一次（没有事件可挂）。
        Widget:HoverWatch(frame,
            function(f) if Marked(f, "petHoverOn") then SetPetAlpha(f, true) end end,
            function(f)
                if Marked(f, "petHoverOn") and not PetSelected() then SetPetAlpha(f, false) end
            end)
        Widget:PollWatch(frame, function(f)
            if not Marked(f, "petHoverOn") then return end
            local over = false
            local ok, inside = pcall(f.IsMouseOver, f)
            if ok then over = Secrets.Bool(inside, false) end
            SetPetAlpha(f, over or PetSelected())
        end)
    end

    -- 立刻定一次：鼠标本来就停在框上时不会触发 OnEnter，否则开局是隐形的。
    local over = false
    local ok, inside = pcall(frame.IsMouseOver, frame)
    if ok then over = Secrets.Bool(inside, false) end
    SetPetAlpha(frame, over or PetSelected())
end

local function FrameChrome()
    -- 血条与能量条之间用 1px 独立分隔线（早先的双段拆分已删，不再需要第二个返回值）。
    return Shared("border") or 1
end

--- 把颜色向白提亮（factor>1）。对每个分量独立 pcall：秘密值乘法会抛错，失败就原样返回，
--- 保证受限环境下能量/血条仍能上色、只是不提亮。
local function Brighten(r, g, b, factor)
    if factor <= 1 then return r, g, b end
    local function bump(c)
        local ok, v = pcall(function() return math.min(c * factor, 1) end)
        return ok and v or c
    end
    return bump(r), bump(g), bump(b)
end

--- The "current" part of a health bar。样式看设置（fillColor）：
---   "inverse" = edge 的 RGB 反相，亮度吃 Color 的四级阶梯（fill 档）——玩家 / 目标的目标的默认，
---               和小队/团队格同款（Groups.lua）；
---   "class"   = 职业 / 敌我色；"health" = 生命绿；"dark" = 近黑（反相风）；
---   其余（含 "highlight"）= Monet 奶油压暗 20%。
--- 2026-10-25 那版是在函数开头给 player / targettarget 硬顶一份反相，把用户设置整个盖掉
--- （HANDOFF 8.14.4③）；现在它只是一种可选样式 + 默认值，玩家改过就一直生效。
local function FillColorFor(style, unit)
    if style == "inverse" then
        -- edge 由 LibMonetColor 从环境色推出（HSL 反相 + 亮度镜像）；这里再取一次 RGB 反相
        -- 得到"edge 的反色"。GetEdge 无机密值（纯主题色），不用守卫；亮度不自己算，交给阶梯。
        local r, g, b = Color:GetSurface("fill")
        return r, g, b, 1
    elseif style == "class" then
        if UnitIsPlayer(unit) then
            local hr, hg, hb = Color:GetHighlight()
            return hr * 0.8, hg * 0.8, hb * 0.8, 1
        end

        local ok, r, g, b = pcall(UnitSelectionColor, unit)
        if ok and r then
            -- target / targettarget 比 player 的暗 highlight 稍亮，层次感更清楚。
            if unit == "target" or unit == "targettarget" then
                r, g, b = Brighten(r, g, b, 1.15)
            end
            return r, g, b, 1
        end
    elseif style == "health" then
        return Color:GetHealth()
    elseif style == "dark" then
        -- 反相风（Andromeda 默认的 style 1）：填充近黑，剩下的血量靠"暗块面积"读。
        -- 要配 lostColor 的 "light" / "theme25" 才有意义，否则暗填充压在黑底上什么都看不到。
        return 0.10, 0.10, 0.10, 1
    end
    -- highlight（player / pet）是 Monet 招牌奶油色，但原色 {0.95,0.93,0.84} 太接近白，
    -- 铺满整条血条会发灰发白、看不出"血量"。压暗 20% 变成有分量的暖奶油，仍读得出来是 highlight。
    local r, g, b = Color:GetHighlight()
    return r * 0.8, g * 0.8, b * 0.8, 1
end

--- 取"这个单位当前该用的填充色"（= FillColorFor 读库版）。
local function FillColor(unit)
    return FillColorFor(Setting(unit, "fillColor"), unit)
end

--- The *missing* part of a health bar: pure background, needs no unit value.
--- "weave" = 暗色织纹底（阶梯的 lost 档，BarWeave 的发丝线叠在其上）——玩家 / 目标的目标的默认，
--- 队伍格同款；"danger" / "light" / "theme25" / 其余（黑）照旧。
local function LostColorFor(style)
    if style == "weave" then
        local r, g, b = Color:GetSurface("lost")
        return r, g, b, 1
    elseif style == "danger" then
        return Color:GetDanger()
    elseif style == "light" then
        -- 反相风的"亮底"：填充压暗（fillColor = dark）之后，空血这边提亮才读得出血量。
        return 0.60, 0.60, 0.60, 1
    elseif style == "theme25" then
        -- Andromeda 的 bg.multiplier = 0.25：空血带一点同色系的暗调，比纯黑 / 纯红柔和。
        local r, g, b = Color:GetPrimary()
        return r * 0.25, g * 0.25, b * 0.25, 1
    end
    return 0, 0, 0, 1
end

local function LostColor(unit)
    return LostColorFor(Setting(unit, "lostColor"))
end

--- 配置面板的小色块用：**和真正上色走同一套函数**，所以面板上看到的颜色就是条上的颜色。
--- kind = "fill" | "lost"；unit 只影响"职业色"那一支（预览用 player 作参考）。
function M:PreviewColor(kind, value, unit)
    if kind == "lost" then
        return LostColorFor(value)
    end
    return FillColorFor(value, unit or "player")
end

--- 织纹浓度跟着"空槽样式"走（2026-10-31 玩家实机反馈："损失血量设置成高亮红，是无效的"）。
--- 这层 45° 布纹（Widget:BarWeave 的 monet_stripe_weave）画在 BACKGROUND、创建在空槽色之后，
--- 所以它是**盖在空槽上面**的，alpha 0.85：实机逐层读出来是
---   填充 ARTWORK(-474) / 空槽色 BACKGROUND(nil) / 织纹 BACKGROUND(-501, alpha 0.85)。
--- 空槽选实色（高亮红 / 浅灰 / 黑 / 主题 25%）时，红被这层灰布纹压成灰褐，看着就像"没生效"。
--- 所以只有"暗织纹"样式保留 0.85，实色样式压到 0.15 —— 留一点布面质感，但颜色读得出来。
---
--- **必须两个入口都调**：建框那一次（UpdateHealthColor）读到的可能是默认值（库还没合并完），
--- 之后真正每次都跑的是 UpdateDesaturation（血量事件 + Apply + 主题刷新都过它）。
--- 只挂在建框那一次上，玩家改完设置会一直是 0.85（实机就是这么复现的）。
local function ApplyWeaveDensity(frame)
    if not frame.health then return end
    local alpha = Setting(frame.unit, "lostColor") == "weave" and 0.85 or 0.15
    if Marked(frame, "weaveAlpha") == alpha then return end
    Mark(frame, "weaveAlpha", alpha)
    ns.Widget:BarWeaveDensity(frame.health, alpha)
end

local function UpdateHealthColor(frame)
    frame.health:SetStatusBarColor(FillColor(frame.unit))

    local lost = frame.healthLost
    if lost then
        local r, g, b, a = LostColor(frame.unit)
        lost:SetVertexColor(r, g, b, a or 1)
    end

    ApplyWeaveDensity(frame)

    -- Separator: pure black is invisible against the near-black frame background
    -- (and against the player's black lost-health area).  Tint it with the theme's
    -- border colour so it always reads as a divider, and follow theme changes here.
    local sep = frame.healthSeparator
    if sep then
        local r, g, b = Color:GetBorder()
        sep:SetColorTexture(r, g, b, 0.55)
    end
end

--- Dead, ghost or disconnected?  Plain booleans; Secrets.Bool guards a hiding build.
local function IsUnavailable(unit)
    if not UnitExists(unit) then return false end
    if Secrets.Bool(UnitIsDeadOrGhost(unit), false) then return true end
    return not Secrets.Bool(UnitIsConnected(unit), true)
end

--- Grey the bars via the client's desaturation: it keeps working while values are hidden.
local function UpdateDesaturation(frame)
    local grey = IsUnavailable(frame.unit)

    if frame.health then frame.health:SetStatusBarDesaturated(grey) end
    if frame.power  then frame.power:SetStatusBarDesaturated(grey)  end

    -- Pips empty out on death anyway; greying keeps the player frame consistent.
    local pips = frame.classPower and frame.classPower.pips
    if pips then
        for i = 1, #pips do
            pips[i]:SetStatusBarDesaturated(grey)
        end
    end

    -- A dead unit shows the *missing* overlay end to end; the client won't desaturate a
    -- plain texture, so grey it by hand.
    local lost = frame.healthLost
    if lost then
        if grey then
            local r, g, b = Color:GetNeutral()
            lost:SetVertexColor(r, g, b, 1)
        else
            lost:SetVertexColor(LostColor(frame.unit))
        end
    end

    -- 这里每次都跑（血量事件 / Apply / 主题刷新），所以织纹浓度必须在这里定，见 ApplyWeaveDensity。
    ApplyWeaveDensity(frame)
end

--- Everything about a bar that does not depend on its current value.
local function UpdateBarLook(frame)
    UpdateHealthColor(frame)
    UpdateDesaturation(frame)
end

-- Power type can change at runtime (shapeshift/vehicle); re-read on UNIT_DISPLAYPOWER,
-- unknown tokens fall through to the client colour, then the theme.
local POWER_COLOR = {
    MANA           = { 0.20, 0.50, 0.90 },
    RAGE           = { 0.85, 0.20, 0.20 },
    FOCUS          = { 0.85, 0.45, 0.15 },
    ENERGY         = { 0.90, 0.85, 0.25 },
    COMBO_POINTS   = { 0.85, 0.35, 0.55 },
    RUNES          = { 0.45, 0.75, 0.85 },
    RUNIC_POWER    = { 0.30, 0.80, 0.90 },
    SOUL_SHARDS    = { 0.55, 0.35, 0.85 },
    LUNAR_POWER    = { 0.35, 0.45, 0.90 },
    HOLY_POWER     = { 0.95, 0.90, 0.55 },
    ALTERNATE      = { 0.55, 0.80, 0.35 },
    MAELSTROM      = { 0.25, 0.60, 0.95 },
    CHI            = { 0.60, 0.95, 0.85 },
    INSANITY       = { 0.55, 0.25, 0.75 },
    BURNING_EMBERS = { 0.90, 0.45, 0.10 },
    DEMONIC_FURY   = { 0.60, 0.35, 0.80 },
    ARCANE_CHARGES = { 0.35, 0.65, 0.95 },
    FURY           = { 0.80, 0.25, 0.55 },
    PAIN           = { 0.90, 0.50, 0.10 },
    ESSENCE        = { 0.45, 0.75, 0.85 },
}

local function UpdatePowerColor(frame)
    local unit = frame.unit
    local bar = frame.power
    -- 目标的目标没有能量条（2026-10-25 起血条吃掉那两行），这个函数是 Apply 遍历所有框时
    -- 无条件调的：不早退就会在最后一行抛 "attempt to index field 'power' (a nil value)"，
    -- 于是配置面板改任何一个单位框颜色都报错、后半段（含平滑/文本）全不生效。
    if not bar then return end
    -- player / target / targettarget 的能量条提亮，和压暗后的血条拉开层次。
    -- 自己的条再高一档：玩家血条现在是统一的暗奶油色（不再染职业色），
    -- 身上唯一的"亮点"就是这条能量，不提亮就显得比目标那条暗。
    local brighten = (unit == "player") and 1.45
                  or ((unit == "target" or unit == "targettarget") and 1.25 or 1)

    if Setting(unit, "powerColor") == "theme" then
        local r, g, b = Color:GetResource()
        r, g, b = Brighten(r, g, b, brighten)
        bar:SetStatusBarColor(r, g, b)
        return
    end

    -- 对方是玩家：能量条直接上它的**职业色**（血条已经是统一色，职业就靠这一条认）。
    -- 自己的条不这么干 —— 自己的职业自己知道，保持按能量类型更直观。
    -- UnitClassBase 标着 SecretWhenUnitIdentityRestricted，机密时退回能量类型色。
    if unit ~= "player" and UnitIsPlayer(unit) then
        local classFile = UnitClassBase(unit)
        if type(classFile) == "string" and not Secrets.IsSecret(classFile) then
            local cr, cg, cb = Color:ClassColor(classFile)
            if cr then
                cr, cg, cb = Brighten(cr, cg, cb, brighten)
                bar:SetStatusBarColor(cr, cg, cb)
                return
            end
        end
    end

    -- Guard so a client that hides the token never hands us a secret table key.
    local _, token, r, g, b = UnitPowerType(unit)
    local tuned = (type(token) == "string" and not Secrets.IsSecret(token))
                  and POWER_COLOR[token] or nil
    if tuned then
        local tr, tg, tb = Brighten(tuned[1], tuned[2], tuned[3], brighten)
        bar:SetStatusBarColor(tr, tg, tb)
        return
    end

    local nr, ng, nb = Secrets.Number(r), Secrets.Number(g), Secrets.Number(b)
    if nr and ng and nb and (nr + ng + nb) > 0 then
        nr, ng, nb = Brighten(nr, ng, nb, brighten)
        bar:SetStatusBarColor(nr, ng, nb)
        return
    end

    local cr, cg, cb = Color:GetResource()
    cr, cg, cb = Brighten(cr, cg, cb, brighten)
    frame.power:SetStatusBarColor(cr, cg, cb)
end

-- 职业资源小格已拆到 Modules/UnitFrames/ClassPower.lua（P5，move-only）：M.classpower.*

--- The interpolation to hand to the client: nil means "snap straight to it" (a saved preference).
local function Smoothing()
    if Shared("smoothBars") == false then return nil end
    return Secrets.SMOOTH
end

--- Health-percentage ramp with explicit stops; a red-to-green lerp passes through
--- muddy brown.
local HEALTH_RAMP = {
    { at = 1.00, r = 0.40, g = 0.88, b = 0.42 },
    { at = 0.60, r = 0.94, g = 0.86, b = 0.36 },
    { at = 0.30, r = 0.95, g = 0.58, b = 0.24 },
    { at = 0.00, r = 0.94, g = 0.26, b = 0.26 },
}

local function PercentColor(pct)
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    for i = 1, #HEALTH_RAMP - 1 do
        local high, low = HEALTH_RAMP[i], HEALTH_RAMP[i + 1]
        if pct >= low.at then
            local span = high.at - low.at
            local t = span > 0 and (pct - low.at) / span or 0
            return low.r + (high.r - low.r) * t,
                   low.g + (high.g - low.g) * t,
                   low.b + (high.b - low.b) * t
        end
    end
    local last = HEALTH_RAMP[#HEALTH_RAMP]
    return last.r, last.g, last.b
end

local function UpdateName(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    -- Colouring follows identity, so it is refreshed here: the pet frame still needs its bar coloured.
    UpdateBarLook(frame)

    local nameText = frame.name
    if not nameText then return end   -- pet frames carry no text

    -- 配色案（2026-10-25）+ 案（2026-10-25 战斗名字）：目标的目标是自己时显示 ">☆<"，
    -- ☆ 中国红（#DE2910）。
    -- **UnitIsUnit 在本客户端标注机密[SecretWhenUnitComparisonRestricted]**（实机探针：
    -- 战斗中返回机密布尔）—— 作者拍板（2026-10-25 二定）：**明文判定可用才显示 ">☆<"，
    -- 判定是机密（战斗窗）就用真名**。IsSecret 在值级判定（issecretvalue 对机密布尔
    -- 有效），机密布尔不真值测试、不缓存上一次判定。
    if unit == "targettarget" then
        local okSelf, isSelf = pcall(UnitIsUnit, unit, "player")
        if okSelf and not Secrets.IsSecret(isSelf) and isSelf then
            nameText:SetText(">|cffde2910☆|r<")
            local r, g, b = Color:GetEdge()
            nameText:SetTextColor(r, g, b, 1)
            return  -- targettarget 没有 level / 血量文本，直接收
        end
    end

    -- 案（2026-10-25 战斗名字，7afecfb 的值级设想被实机探针修正）：本客户端战斗窗口
    -- UnitName 返回的就是**机密字符串**（快照：SecretWhenUnitNameIdentityRestricted +
    -- "允许污染代码传机密"；探针 unitName_secret=true，名牌同窗口 plate_name_secret=true
    -- ——名牌能显示名字，是因为它把机密串原样 SetText 进显示控件：认为机密值可展示、
    -- 不可读）。策略分三档：
    --   明文 → 职业色显示，超宽走 FitText 缩字号（2026-10-27 起截断停用）；
    --   机密串 → 原样 SetText 进显示（不可截断、不派生、不比较），底色退主题 neutral；
    --   读不到（nil / 抛错）→ frame.label。
    local okName, name = pcall(UnitName, unit)
    local rawName = okName and type(name) == "string" and name or nil
    local secretName = rawName ~= nil and Secrets.IsSecret(rawName)
    local classFile
    if rawName ~= nil and not secretName then
        local okClass, _, class = pcall(UnitClass, unit)
        if okClass and type(class) == "string" and not Secrets.IsSecret(class) then
            classFile = class
        end
    end
    -- 规则（2026-10-27 玩家定）：名字最多占框宽 70%，超了**缩字号**（Widget:FitText，
    -- 绝不截断）；frame.nameCap 仍由布局登记但不再读（原截断规则暂不使用）。
    -- 机密串走 FitText 的"不测不缩"分支：原样按基础字号显示。
    -- 名字与 level / 血量文字同占框顶那行左右分列：实测这两段占的宽不够留 30% 时再收。
    do
        local W = frame:GetWidth() or 160
        local maxW = W * 0.70
        local levelW  = frame.level      and frame.level:GetStringWidth()      or 0
        local healthW = frame.healthText and frame.healthText:GetStringWidth() or 0
        if levelW + healthW > 0 then
            maxW = math.min(maxW, W - levelW - healthW - 6)
        end
        Widget:FitText(nameText, rawName or frame.label, maxW, NAME_SIZE, nil, 6)
    end

    local r, g, b = Color:ClassColor(classFile)
    if not r then
        -- 机密窗口里的名字没有职业信息：给主题中性色，底边不误导。
        if secretName then
            r, g, b = Color:GetNeutral()
        else
            r, g, b = Color:GetEdge()
        end
    end
    nameText:SetTextColor(r, g, b, 1)

    local levelText = frame.level
    if levelText then
        local level = Secrets.Number(UnitLevel(unit))
        if level and level > 0 then
            levelText:SetText("Lv" .. level)
        elseif level == -1 then
            levelText:SetText("??")
        else
            levelText:SetText("")
        end
    end
end

local function UpdateHealth(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit), Smoothing())
    UpdateDesaturation(frame)

    local healthText = frame.healthText
    if not healthText then return end -- pet frames carry no text

    if Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(UnitHealth(unit))
        local maximum = Secrets.Number(UnitHealthMax(unit))
        if current and maximum and maximum > 0 then
            -- Target frame shows percentage; others show current/max
            if unit == "target" then
                local pct = math.floor(current / maximum * 100 + 0.5)
                healthText:SetText(pct .. "%")
            else
                local style = (ns:DB().numberFormat == "cn") and "cn" or nil
                healthText:SetText(Math:ShortNumber(current, 1, style) .. " / "
                    .. Math:ShortNumber(maximum, 1, style))
            end
            if Setting(unit, "textColorByPercent") ~= false then
                healthText:SetTextColor(PercentColor(current / maximum))
            end
        else
            healthText:SetText("")
        end
    else
        -- restricted: keep the bar, hide the numbers
        healthText:SetText("")
    end
end

local function UpdatePower(frame)
    local unit = frame.unit
    -- 配色案：目标的目标没有能量条（frame.power == nil），整条路径短路。
    if not frame.power or not UnitExists(unit) then return end

    Secrets.SetBar(frame.power, UnitPower(unit), UnitPowerMax(unit), Smoothing())
    UpdatePowerColor(frame)
    UpdateDesaturation(frame)

    -- Hide a bar the unit simply does not have (e.g. a rogue with 0 max energy).
    local maximum = Secrets.Number(UnitPowerMax(unit))
    frame.power:SetShown(maximum == nil or maximum > 0)
end

-- 施法条已拆到 Modules/UnitFrames/CastBar.lua（P5，move-only）：M.castbar.*

-- 光环子系统已拆到 Modules/UnitFrames/Auras.lua（P5 试水，move-only）。
-- 对外接口：M.auras.EnsureTargetAuras / M.auras.RebuildTargetAuras（内部样式经
-- ns.AuraButtonStyle / ns.PrepareAuraStyle 供 BuffFrame 复用）。

-- 内部表共享给 Auras.lua（它在 .toc 里紧随本文件加载）。
M.frames = frames
M.Shared = Shared
M.Setting = Setting

-- 职业资源色 token 表（ClassPower.lua 也要用；原样共享，不改语义）。
M.POWER_COLOR = POWER_COLOR

--- 摆好一个单位框。位置读写统一交给 Utils/Mover.lua：归一落点、网格/互相吸附、战斗锁、依赖顺序都在那边。
local function PositionFrame(frame)
    if not frame then return end
    ns.Mover:Apply(frame.unit)
end

--- A FontString anchored above the bar: side "LEFT", "RIGHT" or "CENTER".
local function TextAbove(frame, side, size, key, colorKey, justify)
    local text = Widget:Font(frame, size, key, colorKey, justify or side)
    if side == "CENTER" then
        text:SetPoint("BOTTOM", frame, "TOP", 0, TEXT_GAP)
    elseif side == "RIGHT" then
        text:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
    else
        text:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, TEXT_GAP)
    end
    return text
end

-- The border doubles as a live signal; the colour runs
-- through Widget:SetBorderState so a theme refresh re-applies the state.

--- Threat glow colours via the Monet palette: 1 primary, 2 blend, 3 danger,
--- 4 tanking -> health ("safe" because you hold it).
local function ThreatBorder(status)
    if status == 4 then return Color:GetHealth() end
    if status == 3 then return Color:GetDanger() end
    if status == 2 then return Color:Blend("primary", "danger", 0.6) end
    return Color:GetPrimary()
end

--- The colour the state layer (LibMonetColor-Anim-1.0) last delivered for this
--- frame.  It is the BASE of the border: hover and threat paint over it and
--- hand it back when they are done, so the state tint is never lost.
local function RestoreDynamicBorder(frame)
    if not frame then return end
    local c = frame.monetColor
    if c then
        Widget:SetBorderState(frame, c.r, c.g, c.b, c.a)
    else
        Widget:SetBorderState(frame, nil)
    end
end

--- Paint the state layer's colour -- unless hover or threat currently owns
--- the border.
local function ApplyDynamicBorder(frame)
    if not frame or frame.monetBorderOverride then return end
    local c = frame.monetColor
    if not c then return end
    Widget:SetBorderState(frame, c.r, c.g, c.b, c.a)
end

--- Re-evaluate the threat glow.  A secret status must not raise nor clear a glow
--- that is still true: the last state is kept until PLAYER_REGEN_ENABLED.
local function UpdateThreat(frame)
    if not Shared("threatGlow") then return end

    -- UnitThreatSituation 返回 nil 有两种完全不同的含义：
    --   * 机密值（受限环境下）-> 保留上次状态，等 PLAYER_REGEN_ENABLED 再判；
    --   * 普通的 nil -> 客户端压根没有威胁信息（脱战后就是这样），此时必须**清掉**红边。
    -- 以前把两者当一回事（`if status == nil then return end`），于是脱战后 threatStatus 停在 3、
    -- monetBorderOverride 一直是 true，红边就再也不会消失。
    local raw = UnitThreatSituation(frame.unit)
    if raw ~= nil and Secrets.IsSecret(raw) then return end
    local status = Secrets.Number(raw) or 0

    frame.threatStatus = status
    if status > 0 then
        -- The threat owns the border until it ends.
        frame.monetBorderOverride = true
        local r, g, b, a = ThreatBorder(status)
        Widget:SetBorderState(frame, r, g, b, a)
    elseif not Widget:IsMouseOver(frame) then
        -- Drop the glow; the state layer's colour is the base again.
        frame.monetBorderOverride = false
        RestoreDynamicBorder(frame)
    end
end

--- Hover: the border washes to the highlight slot (a 1px wash).  HookScript, because
--- Widget:UnitTooltip owns OnEnter / OnLeave.
local function HoverBorder(frame, enter)
    if not Shared("hoverGlow") then return end
    if frame.threatStatus and frame.threatStatus > 0 then return end

    frame.monetBorderOverride = enter and true or false
    if enter then
        local r, g, b, a = Color:GetHighlight()
        Widget:SetBorderState(frame, r, g, b, a)
    else
        -- The hover is over: the state layer's colour comes back.
        RestoreDynamicBorder(frame)
    end
end

--- The state layer (LibMonetColor-Anim-1.0) drives the border colour: the
--- combat brightening, the entry flash, the low-health red, the
--- out-of-combat dimming and the rest tint.  One sink per frame -- the layer
--- judges the state, this module only paints what it is handed.
local function RegisterDynamicBorders()
    local Anim = ns:GetAnim()
    if not Anim then return end
    for _, unit in ipairs(UNITS) do
        local frame = frames[unit]
        if frame and not frame.monetBorder then
            frame.monetBorder = Anim:RegisterColorSink(function(r, g, b, a)
                frame.monetColor = { r = r, g = g, b = b, a = a }
                ApplyDynamicBorder(frame)
            end, {
                -- The border slot follows the user's choice (edge / ambient /
                -- highlight / neutral), so it is resolved on every repaint.
                base = function() return Color:GetBorderKey() end,
                pulse = true,
            })
        end
    end
end

-- 血条 / 缺失段 / 织纹 / 分隔线 / 能量条。抽自 CreateUnitFrame（P4 拆分，逐条保留语义）。
local function BuildUnitBars(frame, border, width, healthHeight, powerHeight, showPower)
    local health = Widget:Bar(frame, width - border * 2, healthHeight)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", border, -border)
    health:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -border, -border)

    -- The *missing* part: a plain texture behind the fill, tinted by UpdateHealthColor.
    local lost = Widget:LostBarBG(health, 1, 1, 1)

    -- The ground the bar sits on: the Monet canvas weave, so the empty part of the bar reads
    -- as cloth instead of a flat hole.  Created after `lost` (so it draws over it) and still
    -- under the fill -- the filled part stays flat colour.
    Widget:BarWeave(health)

    -- 1px separator line between health and power.  It is tinted
    -- with the border colour rather than black: a black line vanishes against the
    -- near-black frame background and the player's black lost-health area.
    -- （配色案：目标的目标没有能量条，这一行整个跳过 —— frame.power 保持 nil，
    -- 后面的 UpdatePower / SetShown 调用全有 nil 守卫。）
    local separator, power
    if showPower then
        separator = health:CreateTexture(nil, "OVERLAY")
        separator:SetHeight(1)
        separator:SetPoint("TOPLEFT", health, "BOTTOMLEFT", 0, 0)
        separator:SetPoint("TOPRIGHT", health, "BOTTOMRIGHT", 0, 0)
        local sr, sg, sb = Color:GetBorder()
        separator:SetColorTexture(sr, sg, sb, 0.55)

        -- 能量条：**纯高亮平涂**，不用渐变（玩家 2026-10-30 定）。传显式材质后
        -- Widget:Bar 不会再叠运行时渐变，也不会按高度换剖面 —— 顶点色就是资源色。
        power = Widget:Bar(frame, nil, nil, "monet_barfill")
        power:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", border, border)
        power:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -border, border)
        power:SetHeight(powerHeight)
        power:SetStatusBarColor(Color:GetResource())

        -- Same woven ground as the health bar.
        Widget:BarWeave(power)
    end

    frame.health = health
    frame.healthLost = lost
    frame.healthSeparator = separator
    frame.power = power
end

-- 名字 / 等级 / 血量百分比三处文本（位置与有无由 TEXT_LAYOUT 决定）。
-- 抽自 CreateUnitFrame（P4 拆分，逐条保留语义）。
local function BuildUnitTexts(frame, unit)
    local layout = TEXT_LAYOUT[unit] or {}
    frame.nameCap = layout.cap

    -- New layout: [Name(LEFT)] ...... [2px] [Health%] [2px] [Level(RIGHT)]
    -- Name anchored to TOPLEFT, Level anchored to TOPRIGHT, Health% between them

    if layout.name then
        frame.name = Widget:Font(frame, NAME_SIZE, "pixel", "edge",
            layout.name == "CENTER" and "CENTER" or layout.name)
        if layout.name == "LEFT" then
            frame.name:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, TEXT_GAP)
        elseif layout.name == "RIGHT" then
            frame.name:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
        else
            frame.name:SetPoint("BOTTOM", frame, "TOP", 0, TEXT_GAP)
        end
    end

    if layout.name and layout.level then
        frame.level = Widget:Font(frame, SMALL_SIZE, "pixel", "neutral", "RIGHT")
        -- Level anchored to TOPRIGHT of frame
        frame.level:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
    end

    if layout.healthText then
        frame.healthText = Widget:Font(frame, SMALL_SIZE, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
        -- Health% sits 2px left of Level (or right of Name if no Level).
        -- The level must exist first: this used to test frame.level before it was
        -- created, so every health text silently anchored after the name instead.
        if frame.level then
            frame.healthText:SetPoint("RIGHT", frame.level, "LEFT", -2, 0)
        elseif frame.name then
            frame.healthText:SetPoint("LEFT", frame.name, "RIGHT", 2, 0)
        else
            frame.healthText:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
        end
    end
end

-- 收尾：主题 / 单位提示 / 悬停边框 / 拖动登记 / 位置记忆。
-- 抽自 CreateUnitFrame（P4 拆分，逐条保留语义）。
local function FinishUnitFrame(frame, unit, position, border)
    Widget:Theme(frame, { thickness = border, bgAlpha = 0.9 })
    Widget:UnitTooltip(frame, unit)
    frame:HookScript("OnEnter", function(self) HoverBorder(self, true) end) -- TAINT-OK: frame 是自建单位框（hover 边框）
    frame:HookScript("OnLeave", function(self) HoverBorder(self, false) end) -- TAINT-OK: 同上

    -- 拖动 / 吸附 / 位置记忆统一走 Utils/Mover.lua（默认位置是调用方给的 position 表）。
    ns.Mover:Register(frame, unit, {
        group   = "unitframes",
        label   = UNIT_LABEL[unit] or unit,
        default = position,
        store   = function() return ns:DB().unitFrames[unit] end,
    })

    frame.position = position
    frame:Hide()
end

local function CreateUnitFrame(unit, position)
    local border = FrameChrome()
    local width, healthHeight, powerHeight = UnitGeometry(unit)
    -- 配色案（2026-10-25）：目标的目标不画能量条、也不画分隔线，血条吸收这两行，
    -- 占满原来的"血 + 分隔 + 能量"总高（框体总高不变）。
    local showPower = true
    if unit == "targettarget" then
        showPower = false
        healthHeight = healthHeight + 1 + powerHeight
        powerHeight = 0
    end
    -- No split: health + 1px separator + power
    local height = border * 2 + healthHeight + (showPower and (1 + powerHeight) or 0)

    -- 安全单位按钮：和暴雪一样，左键 = 选中（设为目标），右键 = 弹单位菜单
    -- （设置焦点等）。SecureUnitButtonTemplate 的两个模板写在同一条串里实测可用。
    -- 受保护的框体上非安全脚本（OnEnter / OnLeave / OnUpdate）照样能设，
    -- 只有 SetAttribute / RegisterForClicks 这类安全动作在战斗中会被拒。
    local frame = Widget:CreateFrame("MonetUI" .. unit:gsub("^%l", string.upper) .. "Frame",
        UIParent, width, height, "SecureUnitButtonTemplate, BackdropTemplate", "CheckButton")
    frame.unit = unit
    frame.label = UNIT_LABEL[unit] or unit

    -- 单位按钮的契约：unit + *type1(target) + *type2(togglemenu)。
    -- 全部在创建时设好（登录时不在战斗中），之后战斗里不需要再改。
    pcall(frame.SetAttribute, frame, "unit", unit)
    pcall(frame.SetAttribute, frame, "*type1", "target")
    pcall(frame.SetAttribute, frame, "*type2", "togglemenu")
    pcall(frame.RegisterForClicks, frame, "AnyUp")

    BuildUnitBars(frame, border, width, healthHeight, powerHeight, showPower)

    -- The class resource hangs under the player frame only; it owns Blizzard's class power.
    if unit == "player" then
        M.classpower.CreateClassPower(frame)
    end
    -- Cast bar for player and target.
    if unit == "player" or unit == "target" then
        M.castbar.CreateCastBar(frame)
    end

    UpdateBarLook(frame)

    BuildUnitTexts(frame, unit)

    FinishUnitFrame(frame, unit, position, border)

    return frame
end

function M:GetFrame(unit)
    return frames[unit]
end

function M:UpdateUnit(unit, kind, powerType)
    local frame = frames[unit]
    if not frame then return end

    -- **施法事件不受"框是否显示"的门控**（2026-10-26 玩家报"目标框左下角三角一直在"）：
    -- 以前这里统一 `IsShown` 早退，于是"目标消失 / 切走时结束的那次施法"收不到收尾，
    -- cast 框停在显示状态，下次目标出现三角就还挂在那儿（机密时间那条路径还会把它钉在左端）。
    -- 现在：显示着才去查数据刷新；隐藏着就只收状态，等它重新显示时 RefreshUnit 再按真实情况摆回来。
    if kind == "cast" then
        if Secrets.Bool(frame:IsShown(), false) then
            M.castbar.UpdateCast(frame)
        else
            M.castbar.HideCast(frame)
        end
        return
    end

    -- IsShown 在 1.60 标了 SecretReturnsForAspect（Shown），受限时会是机密值：用 Secrets.Bool 兜。
    if not Secrets.Bool(frame:IsShown(), false) then return end
    if kind == "health" then
        UpdateHealth(frame)
    elseif kind == "power" then
        UpdatePower(frame)
        -- Only the resource's own power type is worth a refresh (energy ticks all the time).
        if M.classpower.ClassPowerIn(frame, powerType) then
            M.classpower.UpdateClassPower(frame)
        end
    else
        UpdateName(frame)
    end
end

--- Show / hide a frame for the unit and refresh all of its parts.
--- 显隐本身不在这里做：visibility 驱动负责（战斗中 Show/Hide 是受保护的），
--- 这里只把内容刷成当前单位的值。
local function RefreshUnit(unit)
    local frame = frames[unit]
    if not frame then return end
    if not UnitExists(unit) then
        -- 单位没了：顺手把威胁状态清掉，否则下次显形会先亮一圈旧红边（targettarget 尤其常见）。
        frame.threatStatus = nil
        if frame.monetBorderOverride then
            frame.monetBorderOverride = false
            RestoreDynamicBorder(frame)
        end
        -- 施法条也要收：这块框可能马上被换给另一个单位，留着的三角会"挂"在新目标上。
        if M.castbar then M.castbar.HideCast(frame) end
        return
    end

    UpdateHealth(frame)
    UpdatePower(frame)
    M.classpower.UpdateClassPower(frame)
    UpdateName(frame)
    UpdateThreat(frame)
    -- 施法条跟着一起对齐：框重新出现时（切目标 / 登录 / 换区域）按"现在真的在打什么"摆，
    -- 不依赖下一次施法事件 —— 否则中途接手的施法会一直不显示，或者残留旧状态。
    if M.castbar then M.castbar.UpdateCast(frame) end
    -- A fresh target means a fresh aura list; lift (or re-stack) it above our bar.
    if unit == "target" and M.auras then M.auras.EnsureTargetAuras(frame) end
end

function M:UpdateAll()
    for _, unit in ipairs(UNITS) do
        RefreshUnit(unit)
    end
end

--- 颜色类设置改了要立刻看得到：重涂血条 / 损失部分 / 能量条 / 分隔线，再刷一遍数值。
--- （颜色是在 CreateUnitFrame 里一次性涂的，只跑 UpdateAll 不会重涂 —— 之前改颜色下拉
--- 必须 /reload 才生效，就是这里缺了这一层。）
function M:Apply()
    for _, frame in pairs(frames) do
        UpdateHealthColor(frame)
        UpdatePowerColor(frame)
    end
    -- 宠物框的"悬停 / 选中才显示"也在这里落地：配置面板改勾立刻生效，不用 /reload。
    ApplyPetHover(frames.pet, Shared("petHover") ~= false)
    self:UpdateAll()
end

--- 血条配色自查（`/mui lost`）：
--- "我把损失部分设成高亮红，没反应" 这类反馈，先跑它，一眼看出是**样式没落地**（style 还是 weave /
--- DB 没存上）还是**落地了但被盖住**（lost 已是红、weaveAlpha 仍是 0.85）。
function M:DebugLost()
    for _, unit in ipairs(UNITS) do
        local frame = frames[unit]
        local style = Setting(unit, "lostColor")
        local r, g, b = LostColor(unit)
        local weave = frame and frame.health and Marked(frame.health, "weave")
        local function alphaOf()
            if not weave then return "nil" end
            local ok, value = pcall(weave.GetAlpha, weave)
            if ok and value then return ("%.2f"):format(value) end
            return "?"
        end
        local before = alphaOf()
        -- 幂等：现场再算一次。跑完 alpha 变了 = 平时的刷新路径没走到 ApplyWeaveDensity。
        if frame then ApplyWeaveDensity(frame) end
        ns:Print(("%s：样式 %s　空槽色 %.2f/%.2f/%.2f　织纹 %s → %s　mark=%s　frame.unit=%s")
            :format(unit, tostring(style), r or -1, g or -1, b or -1, before, alphaOf(),
                tostring(frame and Marked(frame, "weaveAlpha")), tostring(frame and frame.unit)))
    end
end

local UNIT_EVENTS = {
    UNIT_HEALTH               = "health",
    UNIT_MAXHEALTH            = "health",
    UNIT_POWER_UPDATE         = "power",
    UNIT_MAXPOWER             = "power",
    UNIT_DISPLAYPOWER         = "power",
    UNIT_NAME_UPDATE          = "name",
    UNIT_CONNECTION           = "name",
    UNIT_SPELLCAST_START      = "cast",
    UNIT_SPELLCAST_STOP       = "cast",
    UNIT_SPELLCAST_FAILED     = "cast",
    UNIT_SPELLCAST_INTERRUPTED = "cast",
    UNIT_SPELLCAST_DELAYED    = "cast",
    UNIT_SPELLCAST_CHANNEL_START = "cast",
    UNIT_SPELLCAST_CHANNEL_UPDATE = "cast",
    UNIT_SPELLCAST_CHANNEL_STOP = "cast",
    UNIT_SPELLCAST_INTERRUPTIBLE = "cast",
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE = "cast",
}

-- Factory: the loop variable must not be captured directly.
local function MakeUnitHandler(kind)
    return function(_, changedUnit, ...)
        M:UpdateUnit(changedUnit, kind, ...)
    end
end

local function MakeThreatHandler()
    return function(_, changedUnit)
        local frame = frames[changedUnit]
        if frame and Secrets.Bool(frame:IsShown(), false) then UpdateThreat(frame) end
    end
end

function M:RegisterEvents()
    -- B 方案：布局由引擎的 flow layout 负责，不再需要抢回子帧

    for unit in pairs(frames) do
        for event, kind in pairs(UNIT_EVENTS) do
            EventBus:RegisterUnit(event, unit, MakeUnitHandler(kind))
        end
        -- This client carries the classic-era event name; retail's
        -- UNIT_THREAT_SITUATION_CHANGED would fail registration.
        EventBus:RegisterUnit("UNIT_THREAT_SITUATION_UPDATE", unit, MakeThreatHandler())
    end

--    -- Re-stack the borrowed aura list; positioning only (SetPoint), safe while restricted.
--    EventBus:RegisterUnit("UNIT_AURA", "target", function()
--        local frame = frames.target
--        if frame and frame:IsShown() and frame.blizzardAuras then
--            StackTargetAuras(frame)
--        end
--    end)

    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        RefreshUnit("target")
        RefreshUnit("targettarget")
    end)

    EventBus:Register("UNIT_TARGET", function(_, unit)
        if unit == "target" then RefreshUnit("targettarget") end
    end)

    EventBus:Register("PLAYER_ENTERING_WORLD", function() M:UpdateAll() end)
    EventBus:Register("GROUP_ROSTER_UPDATE", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        -- 战斗中被拦的容器重建 / 开关排队都由 ns:AfterCombat 在更早的统一排空里做掉。
        M:UpdateAll()
    end)
    -- Death / resurrection: the bars grey out and come back.
    EventBus:Register("PLAYER_DEAD", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_ALIVE", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_UNGHOST", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function()
    -- 2026-10-25 实机判例：**不重建引擎容器**。重建后那批按钮被我们碰过，引擎在战斗里
    -- 再写它们就被记成 MonetUI → ADDON_ACTION_BLOCKED UNKNOWN()（×11）。代价：目标/焦点
    -- 光环的边框颜色保持创建时那一套，/reload 后跟新主题。见 BuffFrame 同款注释。
    M:UpdateAll()
end)
end

function M:Initialize()
    for _, unit in ipairs(UNITS) do
        local default = ns.DEFAULTS.unitFrames[unit]
        frames[unit] = CreateUnitFrame(unit, default)
        PositionFrame(frames[unit])
        ApplyVisibility(frames[unit], true)
    end

    if ns:DB().unitFrames.hideBlizzard then
        self:SuppressBlizzard(true)
    end

    -- 宠物框默认"悬停 / 选中才显示"（配置可关，见 ApplyPetHover）。
    ApplyPetHover(frames.pet, Shared("petHover") ~= false)

    -- 暴雪的施法条：这一套自己画，暴雪那条藏掉。
    self:HideBlizzardCastBars(true)

    -- The state layer paints the borders; without it the theme slot is used.
    RegisterDynamicBorders()

    self:RegisterEvents()
    self:UpdateAll()
end

--- 安全单位按钮的显隐：走 visibility 驱动（战斗中不能由我们 SetShown ——
--- 日志里 MonetUITargetFrame:Hide()/Show() 攒了两百多次就是这条路径）。
local function ApplyEnabled(enabled)
    for _, frame in pairs(frames) do
        ApplyVisibility(frame, enabled)
        -- A hidden module must not keep the state layer's ticker running.
        if frame.monetBorder and frame.monetBorder.SetEnabled then
            frame.monetBorder:SetEnabled(enabled and true or false)
        end
    end
end

function M:SetEnabled(enabled)
    -- 模块整个关掉：暴雪的施法条还回去（我们自己那条也没了）。
    self:HideBlizzardCastBars(not enabled)

    -- 显隐本身是受保护操作：不在战斗当场做，在战斗排队到脱战（ns:AfterCombat）。
    ns:AfterCombat("unitframes-enabled", function()
        ApplyEnabled(enabled)
        -- 重新开启时 UpdateAll -> RefreshUnit -> EnsureTargetAuras 会把容器显示回来。
        if enabled then self:UpdateAll() end
    end)
end

ns:Register("UnitFrames", M)
