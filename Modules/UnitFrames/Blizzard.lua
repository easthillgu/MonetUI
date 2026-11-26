-- Modules/UnitFrames/Blizzard.lua
-- 暴雪单位框 / 施法条的压制与归还（P5 拆分，2026-10-26）。
-- 这里动的全是暴雪自己的框：单位框只做可逆的 alpha/鼠标静音，绝不卸事件、Hide 或写脚本；
-- 施法条沿用独立的 ShowWatch 压制。所有状态都在旁表，不往暴雪对象写字段。
-- 接口面没变：仍是 M:SuppressBlizzard(enable) / M:HideBlizzardCastBars(enable) 两个方法，
-- Config/SimpleConfig.lua 直接调前者，所以外部代码一行都不用改。

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData）。
local FFD, GetFFD = ns:NewFrameData()

local M = ns:GetModule("UnitFrames")
if not M then return end


-- Frame globals are PlayerFrame / TargetFrame / ... not unit.."Frame"; look them up explicitly.
local BLIZZARD_FRAMES = {
    player       = "PlayerFrame",
    target       = "TargetFrame",
    targettarget = "TargetFrameToT",
    focus        = "FocusFrame",
    pet          = "PetFrame",
}

--- Suppress the default Blizzard unit frames without disabling their event pipelines.
--- Widget:Mute owns the original alpha/mouse snapshot, so repeated suppression and
--- restoration share one idempotent state instead of losing Blizzard's scripts/events.
function M:SuppressBlizzard(enable)
    local requested = enable and true or false
    local complete = true

    for _, globalName in pairs(BLIZZARD_FRAMES) do
        local blizzard = _G[globalName]
        if blizzard and Widget then
            if requested then
                -- 每次调用都补压：暴雪可能重设 alpha 或创建新的池化子件；Mute 不会覆盖
                -- 第一次记下的原 alpha/鼠标状态。整棵子树关鼠标，避免原生框透明但仍抢点击。
                local muted = Widget:Mute(blizzard, { depth = math.huge })
                if muted and Widget:IsMuted(blizzard) then
                    GetFFD(blizzard).suppressed = true
                else
                    complete = false
                end
            elseif GetFFD(blizzard).suppressed then
                Widget:Unmute(blizzard, { depth = math.huge })
                if Widget:IsMuted(blizzard) then
                    complete = false
                else
                    GetFFD(blizzard).suppressed = nil
                end
            end
        end
    end

    -- 配置可能在战斗或其它会拦写入的限制中切换。静音写不进去时保留原状态，解禁后补做；
    -- 不硬写受保护框，也不因重复调用叠加脚本或事件。
    local blocked = false
    if type(ns.CanRunProtectedWork) == "function" then
        blocked = not ns:CanRunProtectedWork()
    elseif type(ns.IsRestricted) == "function" then
        blocked = ns:IsRestricted()
    end
    if not complete and blocked and type(ns.AfterCombat) == "function" then
        ns:AfterCombat("unitframes-suppress-blizzard", function()
            return M:SuppressBlizzard(requested)
        end)
    end
    return complete
end

-- 暴雪的施法条：这一套我们自己画（单位框上的火花），暴雪那条必须藏掉，
-- 否则两条叠在一起。
-- 名字按客户端代际不同：零售 12.x 是 PlayerCastingBarFrame / OverlayPlayerCastingBarFrame /
-- PetCastingBarFrame，老客户端是 CastingBarFrame / PlayerCastFrame。
-- TargetFrameSpellBar 是目标框的子帧（跟着目标框一起被藏）。
local CAST_BAR_FRAMES = {
    "PlayerCastingBarFrame",
    "OverlayPlayerCastingBarFrame",
    "PetCastingBarFrame",
    "CastingBarFrame",
    "PlayerCastFrame",
    "CastingBarFrame1",
    "CastingBarFrame2",
    "CastingBarFrame3",
    "CastingBarFrame4",
    "TargetFrameSpellBar",
}

--- 藏掉暴雪的施法条（幂等：暴雪自己会 Show 回来，所以钩一次 Show 按回去）。
function M:HideBlizzardCastBars(enable)
    for _, name in ipairs(CAST_BAR_FRAMES) do
        local frame = _G[name]
        if frame then
            if enable then
                if not GetFFD(frame).castHidden then
                    GetFFD(frame).castHidden = true
                    if frame.SetScript then
                        pcall(frame.SetScript, frame, "OnShow", frame.Hide)
                    end
                    -- 不再 hooksecurefunc(Show)（写方法槽 = 污染）：轮询"变显示了"再藏。
                    if ns.Widget then
                        Mark(frame, "castHook", true)
                        ns.Widget:ShowWatch(frame, function(self)
                            if Marked(self, "castHidden") then pcall(self.Hide, self) end
                        end)
                    end
                end
                pcall(frame.Hide, frame)
            elseif Marked(frame, "castHidden") then
                Mark(frame, "castHidden", nil)
                if frame.SetScript then
                    pcall(frame.SetScript, frame, "OnShow", nil)
                end
                pcall(frame.Show, frame)
            end
        end
    end
end
