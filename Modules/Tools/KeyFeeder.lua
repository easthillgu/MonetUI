-- Modules/Tools/KeyFeeder.lua
-- 施法成功反馈：屏幕中央显示刚成功释放的技能图标，0.3s 渐隐。
--
-- 只做一件事，不碰任何暴雪框体：监听 UNIT_SPELLCAST_SUCCEEDED(player)，从载荷取 spellID，
-- 用 C_Spell.GetSpellTexture 拿图标，画在我们自己的一张 64px 框上，然后线性淡出。
--
-- 为什么要值级守卫：本客户端在受限状态下把 spellID 标机密（快照写 SecretWhenUnitSpellCastRestricted），
-- 而机密数字不能当表键、不能比较、进 format 会抛。读不出来就这一拍不画，绝不猜。
--
-- 驱动：只在动画活着的那段时间挂一条每帧回调，用 Scheduler:Profile 包壳记进 /mui perf 的外部账；
-- 最后一帧自己 Unregister，空闲时零开销。连发（GCD 里多次成功）只重置计时 + 换图标，不排队。

local ADDON_NAME, ns = ...

local Widget    = ns.Widget
local Media     = ns.Media
local EventBus  = ns.EventBus
local Scheduler = ns.Scheduler
local Secrets   = ns.Secrets

local M = { name = "KeyFeeder" }
ns.KeyFeeder = M

local SIZE  = 64     -- 图标类材质建议 64x64（本仓材质规范）
local FADE  = 0.3    -- 用户点名的渐隐时长（秒）
local X, Y  = 0, 80  -- 屏幕中央偏上一点，免得压住角色 / 施法条

local frame, icon, driverId
local startedAt     -- 绝对起始时刻；nil = 不在播

local function Stop()
    if driverId then
        Scheduler:Unregister(driverId)
        driverId = nil
    end
    startedAt = nil
    if frame then frame:Hide() end
end

--- 每帧只推 alpha。用绝对时钟（GetTime）而不是累加 OnUpdate 的 elapsed：
--- 订阅刚挂上时 master frame 从隐藏转显示，第一拍 elapsed 会异常大（实机抓到 0.295s），
--- 累加口径会把 0.3s 动画一拍跑完（画面上只闪一下）。绝对时钟不受首拍抖动影响。
--- 驱动壳不 pcall、不改实参（Scheduler:Profile 的约定）。
local function Tick()
    if not frame or not startedAt then return end
    local now = GetTime and GetTime() or nil
    if type(now) ~= "number" then return end
    local left = 1 - (now - startedAt) / FADE
    if left <= 0 then
        Stop()
        return
    end
    frame:SetAlpha(left)
end

local function EnsureFrame()
    if frame then return true end
    if not Widget or not Widget.CreateFrame then return false end
    frame = Widget:CreateFrame("MonetUIKeyFeeder", _G.UIParent, SIZE, SIZE)
    if not frame then return false end
    frame:SetFrameStrata("HIGH")
    frame:SetPoint("CENTER", _G.UIParent, "CENTER", X, Y)
    frame:EnableMouse(false)
    frame:SetAlpha(0)
    frame:Hide()
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.35 })
    icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(frame)
    return true
end

--- 播一次：spellID 已由调用点做过 CanRead。
local function Play(spellID)
    if not EnsureFrame() then return end
    local getter = C_Spell and C_Spell.GetSpellTexture
    if type(getter) ~= "function" then return end
    local ok, texture = pcall(getter, spellID)
    if not ok or texture == nil then return end
    icon:SetTexture(texture)
    frame:SetAlpha(1)
    frame:Show()
    startedAt = GetTime and GetTime() or 0
    if not driverId then
        local tick = Tick
        if Scheduler and type(Scheduler.Profile) == "function" then
            tick = Scheduler:Profile("keyfeeder:fade", "按键反馈:渐隐", Tick)
        end
        driverId = Scheduler:EveryFrame(tick, "按键反馈:渐隐")
    end
end

local function OnCast(_, unit, _, spellID)
    -- 只看玩家自己：其它单位 / 宠物的成功施法不该弹我们屏幕中间的图标。
    if unit ~= "player" then return end
    if not Secrets.CanRead(spellID) then return end
    local id = Secrets.Number(spellID)
    if type(id) ~= "number" or id <= 0 then return end
    Play(id)
end

function M:Initialize()
    if EventBus and type(EventBus.RegisterUnit) == "function" then
        EventBus:RegisterUnit("UNIT_SPELLCAST_SUCCEEDED", "player", OnCast)
    elseif EventBus then
        EventBus:Register("UNIT_SPELLCAST_SUCCEEDED", OnCast)
    end
end

function M:SetEnabled(value)
    if value then
        if frame and frame:IsShown() then return end
    else
        Stop()
    end
end

ns:Register("KeyFeeder", M)
