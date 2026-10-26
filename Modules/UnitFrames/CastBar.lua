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

local SPARK_W        = 8          -- 三角宽（物理像素）
local SPARK_H        = 4          -- 三角高（物理像素）
local CAST_GAP       = 0          -- 能量条下沿到三角尖端（物理像素）：0 = 尖端正好顶在条上
local SPARK_RED      = { 1, 0, 0 }  -- normal / interruptible cast

--- 三角火花：一张染色模具贴图，颜色全靠 SetVertexColor。
local function CreateTriangleSpark(parent)
    local spark = parent:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(Media:Texture("monet_spark_up"))
    spark:SetVertexColor(SPARK_RED[1], SPARK_RED[2], SPARK_RED[3], 1)
    spark:Hide()
    return spark
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

    -- Red triangle spark (moves RIGHT->LEFT as cast progresses)
    local spark = CreateTriangleSpark(cast)
    spark:SetSize(sparkW, sparkH)
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

    -- An uninterruptible cast turns the spark grey; a normal
    -- (interruptible) cast stays red.
    -- 机密布尔直接落回 false（灰 = 不可断路径不会误点亮；细档实锤同族发源之一，
    -- 值级判定不触发客户端拦截，真值测试才触发）。
    -- 贴图是纯白模具，颜色走 SetVertexColor（和边框 / 图标同一套语法）。
    if Secrets.IsSecret(notInterruptible) then
        frame.cast.spark:SetVertexColor(SPARK_RED[1], SPARK_RED[2], SPARK_RED[3], 1)
    elseif Secrets.Bool(notInterruptible, false) then
        local nr, ng, nb = Color:GetNeutral()
        frame.cast.spark:SetVertexColor(nr, ng, nb, 1)
    else
        frame.cast.spark:SetVertexColor(SPARK_RED[1], SPARK_RED[2], SPARK_RED[3], 1)
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
