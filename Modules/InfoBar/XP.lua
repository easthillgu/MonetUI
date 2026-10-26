-- Modules/InfoBar/XP.lua
-- Experience line (底部经验线): the XP progress *is* the bottom hairline of the info bar -- the filled part
-- of that line is the percentage, and a ▼ rides its leading edge, tip down on the line (the spark shape
-- comes from the cast indicator in UnitFrames).  No text is parked anywhere: the numbers only appear when the mouse comes near
-- the triangle, inside a small hover zone, and they go away with the mouse.
--
-- Two modes share the same line:
--   * xp   -- while there is still experience to earn: the fill is blue (theme "resource").
--   * rep  -- at max level the watched faction takes the line over, so the hairline is never dead weight;
--             the colour is the game's own reaction colour (red -> orange -> yellow -> green).
-- Effects: a gain slides the fill and the triangle from the old value to the new one (the triangle goes
-- white-hot on the way), and a level-up blinks the fresh segment instead of sliding backwards.

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local M = ns.InfoBar
if not M then return end

local EventBus = ns.EventBus
local Color    = ns.Color
local Secrets  = ns.Secrets
local Media    = ns.Media

local LINE    = 1     -- line thickness in physical pixels: the bottom hairline is always 1px
local MARKER  = 8     -- 三角**宽度**（物理像素）；贴图是 16×8 的 2:1 三角，所以高 = 宽 / 2
local HOVER_W = 24    -- hover zone width around the triangle
local HOVER_H = 10    -- only the lower half of the strip, so a data block above keeps its own tooltip

local GAIN_TIME  = 0.45   -- seconds for the fill + triangle to slide to a new value
local BLINK_TIME = 0.70   -- seconds for the level-up blink

local EPS = 0.0005

local bar                        -- the info bar we decorate
local root, hairline, fill, rested, marker, zone

local mode                       -- "xp" | "rep"  (what the line is showing right now)
local lastFaction                -- last watched factionID; a switch snaps instead of sliding
local displayed = 0              -- the percentage currently drawn (lags behind while animating)
local shown = false              -- was the line up on the previous Apply
local anim                       -- { kind = "gain"|"blink", t, dur, from, to, restEnd, r, g, b }

local function Px(length)
    return length * Media:Mult()
end

--- 三角的**宽度**（UI 单位）。物理像素走，和底边衬线同一个规矩；极端缩放 / 4K 下夹一个下限。
local function MarkerSize()
    local size = Px(MARKER)
    if size < 4 then size = 4 end
    return size
end

--- 三角高度（UI 单位）：贴图是 16×8，宽高比 2:1。
local function MarkerHeight()
    return MarkerSize() / 2
end

local function Format(number)
    if type(number) ~= "number" then return "-" end
    local ok, text = pcall(_G.BreakUpLargeNumbers, math.floor(number))
    if ok and type(text) == "string" then return text end
    return tostring(math.floor(number))
end

-- ============================================================================
-- 读数：经验优先，满级后交给声望
-- ============================================================================

--- 读经验。满级（UnitXPMax = 0）或客户端给回秘密值时返回 nil，交给声望模式。
local function ReadXP()
    local okXP, xp = pcall(_G.UnitXP, "player")
    local okMax, maximum = pcall(_G.UnitXPMax, "player")
    if not okXP or not okMax then return nil end

    xp      = Secrets.Number(xp)
    maximum = Secrets.Number(maximum)
    if not xp or not maximum or maximum <= 0 then return nil end

    -- 休息经验是可选的：nil 就是没有存货，不算错。
    local okRest, rest = pcall(_G.GetXPExhaustion)
    rest = okRest and Secrets.Number(rest) or nil

    local okLevel, level = pcall(_G.UnitLevel, "player")
    level = okLevel and Secrets.Number(level) or nil

    local maxLevel
    if type(_G.GetMaxLevelForPlayerExpansion) == "function" then
        local okCap, cap = pcall(_G.GetMaxLevelForPlayerExpansion)
        if okCap then maxLevel = Secrets.Number(cap) end
    end

    local disabled = false
    if type(_G.IsXPUserDisabled) == "function" then
        local okOff, off = pcall(_G.IsXPUserDisabled)
        disabled = okOff and Secrets.Bool(off) or false
    end

    local percent = xp / maximum
    if percent < 0 then percent = 0 elseif percent > 1 then percent = 1 end

    local restEnd = (xp + (rest or 0)) / maximum
    if restEnd > 1 then restEnd = 1 end

    return {
        mode     = "xp",
        percent  = percent,
        restEnd  = restEnd,
        xp       = xp,
        max      = maximum,
        rest     = (rest and rest > 0) and rest or 0,
        level    = level,
        maxLevel = maxLevel,
        disabled = disabled,
    }
end

--- 读当前监视的声望。没有监视对象 / 本客户端没有这套 API 时返回 nil。
local function ReadRep()
    local api = _G.C_Reputation
    if type(api) ~= "table" or type(api.GetWatchedFactionData) ~= "function" then return nil end

    local ok, data = pcall(api.GetWatchedFactionData)
    if not ok or type(data) ~= "table" then return nil end

    local factionID = Secrets.Number(data.factionID)
    if not factionID or factionID == 0 then return nil end

    local minValue = Secrets.Number(data.currentReactionThreshold)
    local maxValue = Secrets.Number(data.nextReactionThreshold)
    local standing = Secrets.Number(data.currentStanding)
    if not minValue or not maxValue or not standing then return nil end

    -- 同一级别内的进度：跨级时区间由暴雪给的两个阈值决定；满级（阈值相等）就直接当满条。
    local span  = maxValue - minValue
    local value = standing - minValue
    local percent
    if span > 0 then
        percent = value / span
    else
        percent, span, value = 1, 0, 0
    end
    if percent < 0 then percent = 0 elseif percent > 1 then percent = 1 end

    return {
        mode      = "rep",
        factionID = factionID,
        percent   = percent,
        value     = value,
        max       = span,
        name      = data.name,
        reaction  = Secrets.Number(data.reaction),
    }
end

--- 这条线现在该画什么：有经验画经验，满级了画声望（可以用设置关掉）。
local function ReadProgress()
    local data = ReadXP()
    if data then return data end
    if M:GetSetting("xpFaction") ~= false then return ReadRep() end
    return nil
end

--- 颜色：经验用主题的 resource，声望用游戏自己的反应色（红 → 橙 → 黄 → 绿）。
local function ColourOf(data)
    if data.mode == "rep" then
        local palette = _G.FACTION_BAR_COLORS
        local entry = palette and palette[data.reaction or 4]
        if type(entry) == "table" and entry.r then
            return entry.r, entry.g, entry.b
        end
        return 0.8, 0.8, 0.2
    end
    return Color:GetResource()
end

-- ============================================================================
-- 画：几何与配色
-- ============================================================================

local function Tint(data)
    local r, g, b = ColourOf(data)
    fill:SetVertexColor(r, g, b, 1)
    rested:SetVertexColor(r, g, b, 0.35)
    marker:SetVertexColor(r, g, b, 1)
end

--- 把线、三角、悬停区摆到某个百分比上。restEnd 是休息经验那一截的终点（声望模式传 nil）。
local function Draw(percent, restEnd)
    local width = root:GetWidth() or 0
    if width <= 0 then return end

    if percent < 0 then percent = 0 elseif percent > 1 then percent = 1 end

    fill:SetTexCoord(0, percent, 0, 1)

    if restEnd then
        if restEnd < percent then restEnd = percent elseif restEnd > 1 then restEnd = 1 end
        rested:SetTexCoord(0, restEnd, 0, 1)
        rested:SetShown(restEnd > percent + 0.001)
    else
        rested:Hide()
    end

    -- 锚点算像素：FontString 不能锚到父框架的百分比位置。
    local x = math.floor(percent * width + 0.5)
    local half = MarkerSize() / 2
    local markerX = x
    if markerX < half then markerX = half end
    if markerX > width - half then markerX = width - half end

    marker:ClearAllPoints()
    -- 尖端顶在经验条上沿（和 Build 里同一套几何），横坐标跟着进度走
    marker:SetPoint("BOTTOM", root, "BOTTOMLEFT", markerX, Px(LINE))

    -- 悬停区跟着三角走，但不许被屏幕边缘切掉一半
    local zoneX = x
    local zoneHalf = Px(HOVER_W) / 2
    if width > Px(HOVER_W) then
        if zoneX < zoneHalf then zoneX = zoneHalf end
        if zoneX > width - zoneHalf then zoneX = width - zoneHalf end
    end

    zone:ClearAllPoints()
    zone:SetPoint("CENTER", root, "BOTTOMLEFT", zoneX, Px(HOVER_H) / 2)
end

-- ============================================================================
-- 特效：涨的时候滑过去，升级的时候闪一下
-- ============================================================================

local Apply   -- 前向声明：动画收尾要回头再对一次目标值

local function Tick(_, elapsed)
    if not anim or not root then return end

    anim.t = anim.t + elapsed
    local t = anim.t / anim.dur
    if t > 1 then t = 1 end

    if anim.kind == "gain" then
        -- Smoothstep：起步和收尾都软，中段快，和施法条火花的走法一致。
        local eased = t * t * (3 - 2 * t)
        local percent = anim.from + (anim.to - anim.from) * eased
        displayed = percent
        Draw(percent, anim.restEnd)

        -- 三角越接近终点越白（白热），落定回本色
        local hot = (1 - eased) * 0.8
        marker:SetVertexColor(anim.r + (1 - anim.r) * hot,
                              anim.g + (1 - anim.g) * hot,
                              anim.b + (1 - anim.b) * hot, 1)
    else
        -- 升级：整段短促地闪两下，alpha 呼吸而不是变色
        local pulse = 0.35 + 0.65 * math.abs(math.cos(t * math.pi * 1.5))
        fill:SetVertexColor(anim.r, anim.g, anim.b, pulse)
        marker:SetVertexColor(anim.r, anim.g, anim.b, pulse)
        rested:SetVertexColor(anim.r, anim.g, anim.b, 0.35 * pulse)
    end

    if t >= 1 then
        root:SetScript("OnUpdate", nil)
        anim = nil
        Apply()
    end
end

local function StartAnim(spec)
    if not root then return end
    anim = spec
    anim.t = 0
    root:SetScript("OnUpdate", Tick)
end

--- 涨了：从当前画到的值滑到新值。动画中途又涨一次就从半路接着滑。
local function StartGain(data, from, to)
    local r, g, b = ColourOf(data)
    StartAnim({
        kind = "gain", dur = GAIN_TIME,
        from = from, to = to,
        restEnd = data.restEnd,
        r = r, g = g, b = b,
    })
end

local function StartBlink(data)
    local r, g, b = ColourOf(data)
    StartAnim({ kind = "blink", dur = BLINK_TIME, r = r, g = g, b = b })
end

--- 停下动画并把画布交回 Apply（它会把颜色重置回本色）。
local function StopAnim()
    if not root then return end
    root:SetScript("OnUpdate", nil)
    anim = nil
end

--- 逐步收敛到目标值：没有动画时直接画，涨了滑过去，掉了（升级）闪一下。
Apply = function()
    if not root then return end

    -- 底边衬线始终显示，颜色跟随主题（ApplyDecorations 在主题切换时会调到这里）。
    root:Show()
    do
        local r, g, b = Color:GetEdge()
        hairline:SetVertexColor(r, g, b, 1)
    end

    local data = (M:GetSetting("xp") ~= false) and ReadProgress() or nil
    if not data then
        -- 没有经验 / 声望数据：只留底边衬线，进度相关元素全部藏起来。
        fill:Hide()
        rested:Hide()
        marker:Hide()
        zone:Hide()
        M:HideTooltip()
        StopAnim()
        shown = false
        return
    end

    fill:Show()
    marker:Show()
    zone:Show()
    Tint(data)

    local target = data.percent
    local switched = (data.mode == "rep") and (data.factionID ~= lastFaction)
    lastFaction = data.factionID

    -- 刚显示 / 换了模式（经验↔声望）/ 换了个监视的声望：直接落位，
    -- 别从 0 或者上一条线的位置划一遍
    if not shown or data.mode ~= mode or switched then
        mode = data.mode
        StopAnim()
        Draw(target, data.restEnd)
        displayed = target
        shown = true
        return
    end

    -- 动画自己在画：等它跑完再回头对目标值，免得两套位置打架
    if anim then return end

    if target > displayed + EPS then
        StartGain(data, displayed, target)
    elseif target < displayed - EPS then
        -- 掉回起点 = 升级 / 声望跨级：直接落到新的位置，然后闪两下
        Draw(target, data.restEnd)
        displayed = target
        StartBlink(data)
    else
        Draw(target, data.restEnd)
        displayed = target
    end
end

-- ============================================================================
-- 提示框：鼠标凑到三角附近才出来
-- ============================================================================

local function Tooltip()
    local tip = _G.GameTooltip
    if not tip then return end

    local data = ReadProgress()
    if not data then return end

    if data.mode == "rep" then
        pcall(tip.AddLine, tip, "声望", 0.6, 0.8, 1)
        pcall(tip.AddLine, tip, data.name or "-", 1, 1, 1)

        if data.max > 0 then
            pcall(tip.AddDoubleLine, tip, "当前",
                string.format("%s / %s（%.1f%%）", Format(data.value), Format(data.max), data.percent * 100),
                1, 1, 1, 1, 1, 1)
            pcall(tip.AddDoubleLine, tip, "还需", Format(data.max - data.value), 1, 1, 1, 1, 1, 1)
        else
            pcall(tip.AddLine, tip, "该声望已满", 1, 1, 1)
        end

        local standing = data.reaction and _G["FACTION_STANDING_LABEL" .. data.reaction]
        if type(standing) == "string" and standing ~= "" then
            pcall(tip.AddDoubleLine, tip, "关系", standing, 1, 1, 1, 1, 1, 1)
        end
        return
    end

    pcall(tip.AddLine, tip, "经验", 0.6, 0.8, 1)
    pcall(tip.AddDoubleLine, tip, "当前",
        string.format("%s / %s（%.1f%%）", Format(data.xp), Format(data.max), data.percent * 100),
        1, 1, 1, 1, 1, 1)
    pcall(tip.AddDoubleLine, tip, "还需", Format(data.max - data.xp) .. " 升级", 1, 1, 1, 1, 1, 1)

    if data.rest > 0 then
        pcall(tip.AddDoubleLine, tip, "休息经验", Format(data.rest) .. "（双倍剩余）", 0.45, 0.75, 1, 1, 1, 1)
    end

    if data.level and data.maxLevel and data.maxLevel > 0 then
        pcall(tip.AddDoubleLine, tip, "等级", string.format("%d / %d", data.level, data.maxLevel),
            1, 1, 1, 1, 1, 1)
    end

    if data.disabled then
        pcall(tip.AddLine, tip, "经验获取已关闭（右键头像可重新开启）", 1, 0.65, 0.45)
    end
end

-- ============================================================================
-- 建
-- ============================================================================

local function Build(parentBar)
    if root then return end
    bar = parentBar

    root = CreateFrame("Frame", nil, bar)
    root:SetAllPoints(bar)
    -- 画在底板和数据块之上（数据块在条体层级 +1）
    root:SetFrameLevel(bar:GetFrameLevel() + 4)

    -- 底边衬线：始终显示，不管有没有经验。作为轨道，经验进度叠在它上面。
    hairline = root:CreateTexture(nil, "ARTWORK", nil, -1)
    hairline:SetTexture(Media.texture.blank)
    hairline:SetHeight(Px(LINE))
    hairline:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    hairline:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    do
        local r, g, b = Color:GetEdge()
        hairline:SetVertexColor(r, g, b, 1)
    end

    -- 休息经验先画、已得经验盖在上面：同一根衬线，宽的那截在底下
    rested = root:CreateTexture(nil, "ARTWORK", nil, 0)
    rested:SetTexture(Media.texture.blank)
    rested:SetHeight(Px(LINE))
    rested:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    rested:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    rested:Hide()

    fill = root:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetTexture(Media.texture.blank)
    fill:SetHeight(Px(LINE))
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    fill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)

    marker = root:CreateTexture(nil, "OVERLAY")
    -- 三角是贴图（tools/svg/monet_spark_down.svg → Assets/Textures）：**底边就是尖端那一行**。
    -- 尖端顶的是经验条的**上沿**（`Px(LINE)`，那条 1px 衬线的顶边），不是压在线上 ——
    -- 三角整个骑在线上面，线的颜色（进度色 / 声望色）一点不被盖住。
    -- 以前用字体里的 ▼，位置随字体行高漂，和施法条那颗火花是同一个毛病。
    marker:SetTexture(Media:Texture("monet_spark_down"))
    marker:SetSize(MarkerSize(), MarkerHeight())
    marker:SetPoint("BOTTOM", root, "BOTTOMLEFT", 0, Px(LINE))

    -- 只有这一小片认鼠标；悬停它也算悬停条身（M:Hover）
    zone = CreateFrame("Frame", nil, root)
    zone:SetSize(Px(HOVER_W), Px(HOVER_H))
    zone:SetPoint("CENTER", root, "BOTTOMLEFT", 0, Px(HOVER_H) / 2)
    zone:SetFrameLevel(root:GetFrameLevel() + 1)
    zone:EnableMouse(true)

    zone:SetScript("OnEnter", function(self)
        M:Hover(true)
        M:ShowTooltip(self)
        Tooltip()
        local tip = _G.GameTooltip
        if tip then pcall(tip.Show, tip) end
    end)

    zone:SetScript("OnLeave", function()
        M:Hover(false)
        M:HideTooltip()
    end)

    -- 暴雪自己的经验条：零售 12.x 把它挪到了屏幕最下方的"状态追踪条"
    -- （MainStatusTrackingBarContainer，里面还有那行"经验值: x/y"）。我们的经验线就是进度本身，
    -- 所以原来那条收起来 —— 客户端会自己把它 Show 回来，钩一次按回去。
    local function HideBlizzardXP()
        for _, name in ipairs({ "MainStatusTrackingBarContainer", "PlayerXPBar", "ExperienceBar", "MainStatusBar" }) do
            local f = _G[name]
            if f and type(f.Hide) == "function" then pcall(f.Hide, f) end
        end
        local container = _G.MainStatusTrackingBarContainer
        if container and not Marked(container, "xpHidden") and ns.Widget then
            Mark(container, "xpHidden", true)
            -- 轮询代替 hooksecurefunc(Show)：写方法槽会把框体标脏（见 AGENTS）。
            ns.Widget:ShowWatch(container, function(self) pcall(self.Hide, self) end)
        end
    end
    HideBlizzardXP()

    local function Refresh()
        HideBlizzardXP()
        if M.active then Apply() end
    end

    -- PLAYER_XP_UPDATE 覆盖击杀 / 任务；UPDATE_EXHAUSTION 与 PLAYER_UPDATE_RESTING 覆盖旅店休息；
    -- PLAYER_LEVEL_UP 会把线从经验切到声望；UPDATE_FACTION 是声望自己变；分辨率变了三角要重新落位。
    EventBus:Register("PLAYER_XP_UPDATE",      Refresh)
    EventBus:Register("UPDATE_EXHAUSTION",     Refresh)
    EventBus:Register("PLAYER_UPDATE_RESTING", Refresh)
    EventBus:Register("PLAYER_LEVEL_UP",       Refresh)
    EventBus:Register("UPDATE_FACTION",        Refresh)
    EventBus:Register("PLAYER_ENTERING_WORLD", Refresh)
    EventBus:Register("DISPLAY_SIZE_CHANGED",  Refresh)

    Apply()
end

M:AddDecoration({
    key   = "xp",
    build = Build,
    apply = function() if root then Apply() end end,
})
