-- Modules/Skins/Collections.lua
-- Collections (mounts / pets / toys / heirlooms / appearances), the achievement window and the adventure guide.  Journal rows are item buttons, so they are skipped by SkinButtonsIn; only chrome (filters, search boxes, tabs, scroll bars) is restyled.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local COLLECTIONS_TABS = {
    "CollectionsJournalTab1", "CollectionsJournalTab2", "CollectionsJournalTab3",
    "CollectionsJournalTab4", "CollectionsJournalTab5", "CollectionsJournalTab6",
    "CollectionsJournalTab7",
}

local COLLECTIONS_PANELS = {
    "MountJournal", "PetJournal", "ToyBox", "HeirloomsJournal",
    "WardrobeCollectionFrame", "CampsitesJournal",
}

local COLLECTIONS_SEARCH = {
    "CollectionsJournalSearchBox", "MountJournalSearchBox", "PetJournalSearchBox",
    "ToyBoxSearchBox", "HeirloomsJournalSearchBox", "WardrobeCollectionFrameSearchBox",
}

local function SkinCollections()
    local frame = _G.CollectionsJournal
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(COLLECTIONS_TABS)

    M:Controls(COLLECTIONS_PANELS, function(panel)
        Skin:Strip(panel)
        Skin:Panel(panel, { bgAlpha = 0.96 })
        M:SkinButtonsIn(panel)
        M:SkinScrollsIn(panel)
    end)

    -- Filter drop-downs sit directly on the journal / sub panels.
    M:Controls({
        "MountJournalFilterButton", "PetJournalFilterButton", "ToyBoxFilterButton",
        "HeirloomsJournalFilterButton", "CollectionsJournalFilterButton",
    }, function(button)
        Skin:Dropdown(button)
    end)

    M:Controls(COLLECTIONS_SEARCH, function(editBox)
        Skin:EditBox(editBox)
    end)
end

-- The talent / spell book.  PlayerSpells is the modern window; SpellBookFrame is its older name and
-- some clients still have it, so both are tried.  Tabs are player-spell categories and the spec list is
-- a ScrollFrame, both handled here.
local PLAYERSPELLS_TABS = {
    "PlayerSpellsTab1", "PlayerSpellsTab2", "PlayerSpellsTab3", "PlayerSpellsTab4",
}

local function SkinPlayerSpells()
    M:Controls({ "PlayerSpellsFrame", "SpellBookFrame" }, function(frame)
        if not frame then return end
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        M:SkinScrollsIn(frame)
        M:SkinButtonsIn(frame)
    end)
    M:Tabs(PLAYERSPELLS_TABS)

    M:Controls({
        "PlayerSpellsSearchBox", "SpellBookSearchBox",
        "AssistedCombatRotationFrame", "PlayerSpellsCloseButton",
    }, function(control)
        if not control then return end
        local kind = type(control.GetObjectType) == "function" and control:GetObjectType()
        if kind == "EditBox" or kind == "SearchBox" then
            Skin:EditBox(control)
        else
            Skin:Button(control)
        end
    end)
end

local ACHIEVEMENT_TABS = { "AchievementFrameTab1", "AchievementFrameTab2" }

local function SkinAchievements()
    local frame = _G.AchievementFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(ACHIEVEMENT_TABS)

    M:Controls({
        "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameSummary",
    }, function(panel)
        Skin:Strip(panel)
        M:SkinScrollsIn(panel)
    end)

    M:Controls({
        "AchievementFrameCategoriesContainer", "AchievementFrameAchievementsContainer",
    }, function(scroll)
        Skin:ScrollFrame(scroll)
    end)

    M:Controls({ "AchievementFrameFilterButton", "AchievementFrameSearchBox" }, function(control)
        if control and type(control.GetObjectType) == "function"
            and control:GetObjectType() == "EditBox" then
            Skin:EditBox(control)
        else
            Skin:Dropdown(control)
        end
    end)
end

local ENCOUNTER_TABS = { "EncounterJournalTab1", "EncounterJournalTab2", "EncounterJournalTab3" }

local function SkinEncounterJournal()
    local frame = _G.EncounterJournal
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(ENCOUNTER_TABS)

    M:Controls({
        "EncounterJournalInstanceSelect", "EncounterJournalBossButton1",
        "EncounterJournalBossButton2", "EncounterJournalBossButton3",
    }, function(panel)
        Skin:Strip(panel)
        M:SkinScrollsIn(panel)
    end)
end

M:Panel("playerspells", {
    label = "天赋 / 技能书",
    group = "收藏",
    apply = SkinPlayerSpells,
    frames = {
        "PlayerSpellsFrame", "SpellBookFrame",
        "PlayerSpellsTab1", "PlayerSpellsTab2", "PlayerSpellsTab3", "PlayerSpellsTab4",
        "PlayerSpellsSearchBox", "SpellBookSearchBox", "AssistedCombatRotationFrame",
        "PlayerSpellsCloseButton",
    },
})

M:Panel("collections", {
    label = "收藏（坐骑 / 宠物 / 玩具 / 幻化）",
    group = "收藏",
    apply = SkinCollections,
    frames = {
        "CollectionsJournal", "CollectionsJournalCloseButton",
        "CollectionsJournalTab1", "CollectionsJournalTab2", "CollectionsJournalTab3",
        "CollectionsJournalTab4", "CollectionsJournalTab5", "CollectionsJournalTab6",
        "CollectionsJournalTab7",
        "MountJournal", "PetJournal", "ToyBox", "HeirloomsJournal",
        "WardrobeCollectionFrame", "CampsitesJournal",
        "CollectionsJournalSearchBox", "MountJournalSearchBox", "PetJournalSearchBox",
        "ToyBoxSearchBox", "HeirloomsJournalSearchBox", "WardrobeCollectionFrameSearchBox",
        "MountJournalFilterButton", "PetJournalFilterButton", "ToyBoxFilterButton",
        "HeirloomsJournalFilterButton", "CollectionsJournalFilterButton",
    },
})

M:Panel("achievements", {
    label = "成就",
    group = "收藏",
    apply = SkinAchievements,
    frames = {
        "AchievementFrame", "AchievementFrameCloseButton",
        "AchievementFrameTab1", "AchievementFrameTab2",
        "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameSummary",
        "AchievementFrameCategoriesContainer", "AchievementFrameAchievementsContainer",
        "AchievementFrameFilterButton", "AchievementFrameSearchBox",
    },
})

M:Panel("encounterjournal", {
    label = "冒险指南",
    group = "收藏",
    apply = SkinEncounterJournal,
    frames = {
        "EncounterJournal", "EncounterJournalCloseButton",
        "EncounterJournalTab1", "EncounterJournalTab2", "EncounterJournalTab3",
        "EncounterJournalInstanceSelect",
        "EncounterJournalBossButton1", "EncounterJournalBossButton2", "EncounterJournalBossButton3",
    },
})
