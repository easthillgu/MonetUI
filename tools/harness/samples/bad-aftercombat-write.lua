-- tools/harness/samples/bad-aftercombat-write.lua
-- 故意写坏：**模块自己的 PLAYER_REGEN_ENABLED 处理里直接写受保护框**，不走 ns:AfterCombat。
-- 客户端"先派事件、后翻 InCombatLockdown()"（AGENTS 2026-10-27 实机探针），所以这一拍
-- 原生标志还是 true，写受保护框必被拒。Core 的 AfterCombat 延迟层只管它自己的队列，
-- 绕不过这种"在派发拍里硬写"的形状 —— 正确写法是把这刀挪进 C_Timer.After(0, …)。
-- 期望：断言二记 A6 红（窗口 = regen 派发当拍，lockdown 仍 true）。
local ADDON_NAME, ns = ...

ns.EventBus:Register("PLAYER_REGEN_ENABLED", function()
    local frame = _G.PlayerFrame
    if frame then
        frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 13, -13)
    end
end)