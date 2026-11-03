-- tools/harness/samples/bad-combat-write.lua
-- 故意写坏：刷新路径里对暴雪框体做几何 / 显隐写入，而且**没有守卫**。
-- 平明期这条不报错（所以样例本身不该在自由阶段出红），六类受限窗口里必是
-- ADDON_ACTION_BLOCKED —— 期望：断言二记 A2 红（level=red，不是 guarded）。
local ADDON_NAME, ns = ...

local M = {}
ns:Register("HarnessSampleCombatWrite", M)

function M:Apply()
    local frame = _G.CharacterFrame
    if frame then
        frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 12, -12)
        frame:SetFrameStrata("DIALOG")
    end
    local minimap = _G.Minimap
    if minimap then
        minimap:Hide()
    end
end
