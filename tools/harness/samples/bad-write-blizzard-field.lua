-- tools/harness/samples/bad-write-blizzard-field.lua
-- 故意写坏：直接往暴雪框体上挂字段（AGENTS：必须走 ns:Mark 旁表）。
-- 期望：断言三记一条 A3 红，位置就是本文件的这一行。
local ADDON_NAME, ns = ...

local frame = _G.CharacterFrame or _G.UIParent
if frame then
    frame.harnessBadField = "不该写在暴雪对象上"
end
