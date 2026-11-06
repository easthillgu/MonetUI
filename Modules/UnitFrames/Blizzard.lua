-- Modules/UnitFrames/Blizzard.lua
-- 暴雪单位框 / 施法条的压制与归还（P5 拆分，2026-10-26）。
-- 这里动的全是暴雪自己的框：只做"收掉"—— 卸事件、卸 OnShow、alpha/Hide 与旁表记账，
-- 绝不往它们身上写字段或挂我们的钩子（AGENTS.md 污染模型里最贵的一课）。
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

--- Suppress the default Blizzard unit frames (the oUF pattern).  In borrow mode
--- TargetFrame is hidden visually only, or the borrowed aura list would freeze.
function M:SuppressBlizzard(enable)
    for _, globalName in pairs(BLIZZARD_FRAMES) do
        local blizzard = _G[globalName]
        if blizzard then
            if enable and not GetFFD(blizzard).suppressed then
                GetFFD(blizzard).suppressed = true
                -- 2026-10-25：**TargetFrame 也走彻底压制**。
                -- 以前给它留的是"借用模式"（只 alpha 0、事件照跑），因为 A 方案靠它画光环；
                -- A 方案已废（光环改由引擎容器自绘），留着的后果是：TargetFrame 自己的代码
                -- 在"被 MonetUI 写过"的上下文里继续跑 → 每次战斗进出都冒一条
                -- ADDON_ACTION_BLOCKED UNKNOWN()（二分到 UnitFrames 单独开即可复现）。
                pcall(blizzard.UnregisterAllEvents, blizzard)
                if blizzard.SetScript then
                    pcall(blizzard.SetScript, blizzard, "OnShow", blizzard.Hide)
                end
                blizzard:Hide()
            elseif not enable and GetFFD(blizzard).suppressed then
                GetFFD(blizzard).suppressed = nil
                pcall(blizzard.SetScript, blizzard, "OnShow", nil)
                if type(blizzard.EnableMouse) == "function" then
                    pcall(blizzard.EnableMouse, blizzard, true)
                end
                if type(blizzard.SetAlpha) == "function" then
                    pcall(blizzard.SetAlpha, blizzard, 1)
                end
                blizzard:Show()
            end
        end
    end
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
