-- tools/harness/samples/bad-combat-write.lua
-- 故意写坏：刷新路径里对**受保护**暴雪框体做几何 / 显隐写入，而且没有守卫。
-- 平明期这条不报错（所以样例本身不该在自由阶段出红），六类受限窗口里必是
-- ADDON_ACTION_BLOCKED —— 期望：断言二记 A2 红（level=red，不是 guarded）。
--
-- 目标必须逐对象挑：world-data 的 prot 位（build-world.js 沿 XML protected="true" /
-- Secure* 模板 inherits 链求闭包）说 PlayerFrame 是 SecureUnitButtonTemplate 出身的
-- 受保护框，CharacterFrame 是普通暴雪框。拿 CharacterFrame 当靶子测的是"桩拒绝一切暴雪框"
-- 这个已经修掉的错判据；它现在只该出 A2n 黄。
local ADDON_NAME, ns = ...

local M = {}
ns:Register("HarnessSampleCombatWrite", M)

function M:Apply()
    -- 受保护：真客户端战斗里必拒 → A2 红
    local protected = _G.PlayerFrame
    if protected then
        protected:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
        protected:SetFrameStrata("DIALOG")
    end
    local alsoProtected = _G.FocusFrame
    if alsoProtected then
        alsoProtected:Hide()
    end
    -- 非受保护：客户端不会拒，但判据只到 XML 声明 → A2n 黄（留实机复核）
    local plain = _G.CharacterFrame
    if plain then
        plain:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 12, -12)
    end
end
