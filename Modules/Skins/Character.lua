-- Modules/Skins/Character.lua
-- The character sheet and the inspect sheet: window, side tabs and sub panels (paper doll, reputation, currency, skills, PvP) are plated; item/slot icons are never touched (SkinButtonsIn skips buttons that carry an icon).

local ADDON_NAME, ns = ...

local M = ns.Skins

local CHARACTER_TABS = {
    "CharacterFrameTab1", "CharacterFrameTab2", "CharacterFrameTab3",
}

local CHARACTER_PANELS = {
    "PaperDollFrame", "ReputationFrame", "TokenFrame",
}

local INSPECT_TABS = { "InspectFrameTab1", "InspectFrameTab2" }

local INSPECT_PANELS = { "InspectPaperDollFrame", "InspectPVPFrame", "InspectTalentFrame" }

-- 子面板的处理和窗口不同：不剥标题/关闭，只剥自己的原美术 + 挂底衬 + 扫直接子控件。
-- 标签页内容（滚动条、上下箭头）是懒建的，`Dress` 默认会在显示时再扫一遍。
local SUB_PANEL = { panel = { bgAlpha = 0.96 }, deep = true }

local function SkinCharacter()
    M:Dress("CharacterFrame", { window = true, panel = { bgAlpha = 0.96 } })
    M:Dress(CHARACTER_TABS, { as = "tab" })
    M:Dress(CHARACTER_PANELS, SUB_PANEL)
end

local function SkinInspect()
    M:Dress("InspectFrame", { window = true, panel = { bgAlpha = 0.96 } })
    M:Dress(INSPECT_TABS, { as = "tab" })
    M:Dress(INSPECT_PANELS, SUB_PANEL)
end

M:Panel("character", {
    label = "角色界面",
    group = "角色",
    apply = SkinCharacter,
    frames = {
        "CharacterFrame", "CharacterFrameCloseButton",
        "CharacterFrameTab1", "CharacterFrameTab2", "CharacterFrameTab3",
        "PaperDollFrame", "ReputationFrame", "TokenFrame",
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
