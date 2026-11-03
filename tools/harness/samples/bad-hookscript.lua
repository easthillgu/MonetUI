-- tools/harness/samples/bad-hookscript.lua
-- 故意写坏：往暴雪框体的脚本槽里挂钩子（AGENTS：HookScript / hooksecurefunc 都算污染，
-- 改用轮询）。不受限状态真客户端不报错，但污染账必须记 —— 期望：断言三记 A3h 红。
local ADDON_NAME, ns = ...

local frame = _G.QuestLogFrame or _G.CharacterFrame or _G.UIParent
if frame and frame.HookScript then
    frame:HookScript("OnShow", function() end)
end

if _G.hooksecurefunc then
    hooksecurefunc("PanelTemplates_SelectTab", function() end)
end
