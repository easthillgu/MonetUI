-- tools/api-audit-selftest/Broken.lua
-- Fixture for `node tools/api-audit.js --addon tools/api-audit-selftest`.
-- Every line below is deliberately wrong; the audit must report HARD for each one.
-- Not loaded by the addon (tools/ is not in MonetUI.toc and not walked by the real run).

local ADDON, ns = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_AURA")                          -- ok
frame:RegisterEvent("NOT_A_REAL_EVENT")                   -- HARD unknown event
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")        -- HARD restricted event

function ns:SelfTest()
    C_ActionBar.ThisFunctionDoesNotExist(1)               -- HARD unknown C_* call
    C_GameRules.GetActiveGameMode()                       -- ok
    Enum.ForeverExperiencePreset.Nope                     -- HARD unknown enum value
    Enum.NotAnEnum                                        -- HARD unknown enum
    UseAction(1)                                          -- HARD protected global
    UnitHealth("player", true, 3)                         -- SOFT argument count (max 2)
    frame:BlinkThatDoesNotExist(1)                        -- INFO undocumented method
end
