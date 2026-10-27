-- Modules/UnitFrames/CastBar.lua
-- 单位框的施法条（P5 拆分，2026-10-25）：一条 2px 的红色三角火花，从右向左扫；可断/不可断用颜色区分。
-- move-only：逻辑原样搬自 UnitFrames.lua；接口面：
--   * 输入：M.Setting（单位设置读取）；
--   * 输出：M.castbar.{CreateCastBar, UpdateCast, HideCast}。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Widget  = ns.Widget
local Media   = ns.Media
local Color   = ns.Color

local M = ns:GetModule("UnitFrames")
if not M then return end

local Setting = M.Setting
local Shared  = M.Shared

-- ============================================================================
-- Cast indicator (player & target): NO fill bar, only a red triangle spark
-- that moves RIGHT->LEFT (reverse) under the power bar as the cast progresses.
--
-- 三角是**贴图**（Assets/Textures/monet_spark_up.tga，SVG 手绘，见 tools/svg/），不是字体里的 ▲。
-- 以前用 FontString 画三角，位置受字体行高摆布：字身比 2px 的框高，顶端会溢出压到能量条上
-- （玩家 2026-10-26 报的就是这个）。
-- **契约**：贴图最上面那一行就是三角的尖，所以把贴图的 TOP 锚在能量条下沿（CAST_GAP = 0）
-- 尖端就精确顶在条上，横向扫动时也不会上下漂。
-- ============================================================================

local SPARK_W        = 10         -- 三角宽（物理像素）：原 8 太细，施法条下沿几乎看不见
local SPARK_H        = 5          -- 三角高（物理像素）
local CAST_GAP       = 0          -- 能量条下沿到三角尖端（物理像素）：0 = 尖端正好顶在条上
-- 施法火花配色（玩家 2026-10-27："需要比较明显的视觉差才能提起注意"）：
--   内芯白热 + 外圈危险红晕、外晕呼吸 → 在任何条色（职业色 / resource / neutral）上都跳出来。
-- 两个色都是**美术色白名单**条目（见 MonetUI.md 的「美术色白名单」）；不可断施法整体转中性灰。
local SPARK_CORE     = { 1.00, 0.96, 0.86 }   -- 白热芯
local SPARK_GLOW     = { 1.00, 0.18, 0.10 }   -- 危险红晕
local SPARK_GLOW_K   = 2.8        -- 外晕相对内芯的放大倍数
local SPARK_GLOW_A0  = 0.22       -- 外晕呼吸的下限
local SPARK_GLOW_A1  = 0.52       -- 外晕呼吸的上限

--- 三角火花：**双层**染色模具（外晕 + 内芯），颜色全靠 SetVertexColor。
--- 返回一个宿主框（尺寸 = 内芯，外晕靠贴图不裁切自由外扩），.core / .glow 供换色。
local function CreateTriangleSpark(parent)
    local host = CreateFrame("Frame", nil, parent)

    local glow = host:CreateTexture(nil, "OVERLAY", nil, 1)
    glow:SetTexture(Media:Texture("monet_spark_up"))
    glow:SetVertexColor(SPARK_GLOW[1], SPARK_GLOW[2], SPARK_GLOW[3], 1)
    glow:SetAlpha(SPARK_GLOW_A1)
    glow:SetPoint("CENTER", host, "CENTER", 0, 0)

    local core = host:CreateTexture(nil, "OVERLAY", nil, 2)
    core:SetTexture(Media:Texture("monet_spark_up"))
    core:SetVertexColor(SPARK_CORE[1], SPARK_CORE[2], SPARK_CORE[3], 1)
    core:SetPoint("CENTER", host, "CENTER", 0, 0)

    host.core, host.glow = core, glow
    host:Hide()
    return host
end

--- 给火花上下层分别上色（内芯 / 外晕）。
local function TintSpark(spark, cr, cg, cb, gr, gg, gb)
    if spark.core then pcall(spark.core.SetVertexColor, spark.core, cr, cg, cb, 1) end
    if spark.glow then pcall(spark.glow.SetVertexColor, spark.glow, gr, gg, gb, 1) end
end

--- Build the cast indicator: a simple frame holding only the spark.
local function CreateCastBar(frame)
    if frame.unit ~= "player" and frame.unit ~= "target" then return end

    local width = Setting(frame.unit, "width") or 160
    local border = (Shared("border") or 1)
    local barWidth = width - border * 2

    -- A plain frame (no StatusBar, no fill, no background) to anchor the spark
    local mult = Media:Mult() or 1
    local sparkW, sparkH = SPARK_W * mult, SPARK_H * mult

    local cast = CreateFrame("Frame", nil, frame)
    cast:SetSize(barWidth, sparkH)
    cast:SetPoint("TOPLEFT", frame.power, "BOTTOMLEFT", 0, -(CAST_GAP * mult))

    -- 白热三角 + 红晕（随施法向右→左扫动）
    local spark = CreateTriangleSpark(cast)
    spark:SetSize(sparkW, sparkH)
    spark.core:SetSize(sparkW, sparkH)
    spark.glow:SetSize(sparkW * SPARK_GLOW_K, sparkH * SPARK_GLOW_K)
    -- TOP 锚 = 贴图最上面那一行（三角的尖）压在 cast 框顶边，而 cast 框顶边就是能量条下沿。
    spark:SetPoint("TOP", cast, "TOP", 0, 0)

    cast.spark = spark
    cast:Hide()

    frame.cast = cast
    return cast
end

--- Read cast/channel info without letting a restricted call break the frame.
local function CastInfo(channel, unit)
    local fn = channel and UnitChannelInfo or UnitCastingInfo
    if type(fn) ~= "function" then return nil end

    local result = { pcall(fn, unit) }
    if not result[1] then return nil end

    -- pcall wraps returns: result[1]=ok, result[2]=name, result[3]=text, result[4]=texture,
    -- result[5]=startTimeMS, result[6]=endTimeMS, result[7]=isTradeSkill(string? 本客户端是 bool),
    -- 本客户端实测（2026-10-25，11 个返回值）：
    --   6=boolean, 7=string(castID), **8=notInterruptible(boolean)**, 9=spellID(number),
    --   10=string, 11=number
    -- 所以**施法与引导都用第 8 位**取 notInterruptible、第 9 位取 spellID。
    -- 以前施法分支取第 9 位（那是 spellID）→ 数字为真 → 普通施法被当成"不可打断"变灰。
    local name      = result[2]
    local texture   = result[4]
    local startMS   = result[5]
    local endMS     = result[6]
    -- `channel and A or B` truth-tests A before selecting; A is a secret under
    -- restriction and the mere test throws ("boolean test on field '?'").  Pick explicitly.
    local notInt, spellID = result[8], result[9]
    -- 兜底：老布局里第 8 位不是布尔时，退回"不可打断 = false"（宁可红色，不乱变灰）。
    if type(notInt) ~= "boolean" then notInt = false end
    return name, texture, startMS, endMS, notInt, spellID
end

--- Update the cast indicator for the player/target frame.
--- Only positions the red triangle spark (no fill bar, no text).
local function UpdateCast(frame)
    if not frame.cast then return end
    local unit = frame.unit
    if unit ~= "player" and unit ~= "target" then return end

    local name, texture, startMS, endMS, notInterruptible, spellID = CastInfo(false, unit)
    local channel = false
    if type(name) == "nil" then
        name, texture, startMS, endMS, notInterruptible, spellID = CastInfo(true, unit)
        channel = true
    end
    if type(name) == "nil" then
        frame.cast:Hide()
        frame.cast.spark:Hide()
        frame.cast:SetScript("OnUpdate", nil)
        return
    end

    -- 可断施法：白热芯 + 红色呼吸晕（在任何条色上都跳出来）；
    -- 不可断施法：内芯与外晕一起转中性灰（"这条断不了"的信号）。
    -- 机密布尔直接落回"可断"路径（值级判定不触发客户端拦截，真值测试才触发）。
    if Secrets.IsSecret(notInterruptible) then
        TintSpark(frame.cast.spark, SPARK_CORE[1], SPARK_CORE[2], SPARK_CORE[3],
                  SPARK_GLOW[1], SPARK_GLOW[2], SPARK_GLOW[3])
    elseif Secrets.Bool(notInterruptible, false) then
        local nr, ng, nb = Color:GetNeutral()
        TintSpark(frame.cast.spark, nr, ng, nb, nr, ng, nb)
    else
        TintSpark(frame.cast.spark, SPARK_CORE[1], SPARK_CORE[2], SPARK_CORE[3],
                  SPARK_GLOW[1], SPARK_GLOW[2], SPARK_GLOW[3])
    end

    -- 受限时 startMS / endMS 是保密值（Secret number），OnUpdate 里的减法会抛
    -- "attempt to perform arithmetic on a secret number value"（零售服实测）。拿不到普通数字就
    -- 把火花钉在起点并停掉 OnUpdate，收尾交给下一次施法事件；施法条本身照常显示。
    if Secrets.IsSecret(startMS) or Secrets.IsSecret(endMS) then
        frame.cast.startTimeMS = nil
        frame.cast.endTimeMS = nil
        frame.cast.channeling = channel
        frame.cast:Show()
        frame.cast.spark:Show()
        frame.cast.spark:ClearAllPoints()
        -- 和常规路径一致：TOP 锚，钉在左端（机密的开始/结束时间不能参与算术）
        frame.cast.spark:SetPoint("TOP", frame.cast, "TOPLEFT", 0, 0)
        frame.cast:SetScript("OnUpdate", nil)
        return
    end

    -- Store times for spark calculation
    frame.cast.startTimeMS = startMS
    frame.cast.endTimeMS = endMS
    frame.cast.channeling = channel
    frame.cast:Show()
    frame.cast.spark:Show()

    -- OnUpdate 挂在**普通子框**（frame.cast）上，不挂在单位框上：
    -- 单位框现在是受保护的安全单位按钮，战斗中改它的脚本会被拒，
    -- 而战斗恰恰是施条动画最要紧的时候。
    local castFrame = frame.cast
    castFrame:SetScript("OnUpdate", function(self, elapsed)
        local cast = castFrame
        if not cast or not cast.endTimeMS then
            self:SetScript("OnUpdate", nil)
            return
        end

        local now = GetTime() * 1000
        local startMS = cast.startTimeMS or 0
        local endMS = cast.endTimeMS
        local maxDur = endMS - startMS
        if maxDur <= 0 then maxDur = 1 end

        local progress
        if cast.channeling then
            -- Channeling: progresses from 1 to 0
            progress = (endMS - now) / maxDur
        else
            -- Casting: progresses from 0 to 1
            progress = (now - startMS) / maxDur
        end
        if progress < 0 then progress = 0 elseif progress > 1 then progress = 1 end

        -- Move spark RIGHT -> LEFT (reverse): at progress=0 (start), spark at RIGHT; at progress=1, spark at LEFT
        local barWidth = cast:GetWidth()
        local x = barWidth * (1 - progress)
        -- TOP 锚（与创建时一致）：只动横坐标，纵坐标永远贴着能量条下沿
        cast.spark:SetPoint("TOP", cast, "TOPLEFT", x, 0)

        -- 外晕呼吸（约 1 秒一个来回）：只动 alpha，不碰几何；施法条平时很窄，这点明暗让它更抓眼
        local glow = cast.spark.glow
        if glow then
            glow:SetAlpha(SPARK_GLOW_A0 + (SPARK_GLOW_A1 - SPARK_GLOW_A0)
                * (0.5 + 0.5 * math.sin(GetTime() * 6)))
        end

        -- Auto-hide when cast ends
        if (cast.channeling and now >= endMS) or (not cast.channeling and now >= endMS) then
            cast:Hide()
            cast.spark:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

--- Hide cast bar (called on STOP/FAILED/INTERRUPTED/CHANNEL_STOP).
local function HideCast(frame)
    if not frame.cast then return end
    frame.cast:Hide()
    frame.cast.spark:Hide()
    frame.cast.endTimeMS = nil
    frame.cast.startTimeMS = nil
    frame.cast.channeling = false
    frame.cast:SetScript("OnUpdate", nil)
end

M.castbar = {
    CreateCastBar = CreateCastBar,
    UpdateCast = UpdateCast,
    HideCast = HideCast,
}
