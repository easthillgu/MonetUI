-- Modules/Skins/Character.lua
-- The character sheet and the inspect sheet.  The window, its side tabs and the
-- sub panels (paper doll, reputation, currency, skills, PvP) are plated; item /
-- slot icons are never touched (SkinButtonsIn skips buttons that carry an icon).

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local CHARACTER_TABS = {
    "CharacterFrameTab1", "CharacterFrameTab2", "CharacterFrameTab3",
    "CharacterFrameTab4", "CharacterFrameTab5",
}

local CHARACTER_PANELS = {
    "PaperDollFrame", "ReputationFrame", "TokenFrame", "SkillFrame", "PVPFrame",
}

local INSPECT_TABS = { "InspectFrameTab1", "InspectFrameTab2" }

local INSPECT_PANELS = { "InspectPaperDollFrame", "InspectPVPFrame", "InspectTalentFrame" }

local function SkinCharacter()
    local frame = _G.CharacterFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(CHARACTER_TABS)

    M:Controls(CHARACTER_PANELS, function(panel)
        Skin:Strip(panel)
        Skin:Panel(panel, { bgAlpha = 0.96 })
        M:SkinButtonsIn(panel)
        M:SkinScrollsIn(panel)
    end)
end

local function SkinInspect()
    local frame = _G.InspectFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(INSPECT_TABS)

    M:Controls(INSPECT_PANELS, function(panel)
        Skin:Strip(panel)
        Skin:Panel(panel, { bgAlpha = 0.96 })
        M:SkinButtonsIn(panel)
        M:SkinScrollsIn(panel)
    end)
end

M:Panel("character", {
    label = "角色界面",
    group = "角色",
    apply = SkinCharacter,
    frames = {
        "CharacterFrame", "CharacterFrameCloseButton",
        "CharacterFrameTab1", "CharacterFrameTab2", "CharacterFrameTab3",
        "CharacterFrameTab4", "CharacterFrameTab5",
        "PaperDollFrame", "ReputationFrame", "TokenFrame", "SkillFrame", "PVPFrame",
    },
})

M:Panel("inspect", {
    label = "观察 / 装备对比",
    group = "角色",
    apply = SkinInspect,
    frames = {
        "InspectFrame", "InspectFrameCloseButton",
        "InspectFrameTab1", "InspectFrameTab2",
        "InspectPaperDollFrame", "InspectPVPFrame", "InspectTalentFrame",
    },
})
