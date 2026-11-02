-- Modules/Skins/Collections.lua
-- Collections (mounts / pets / toys / heirlooms / appearances), the achievement window and the adventure guide.  Journal rows are item buttons, so they are skipped by SkinButtonsIn; only chrome (filters, search boxes, tabs, scroll bars) is restyled.
-- 统一入口 M:Dress：名字过 Skin:Need 记账，缺哪个 `/mui skins diagnose` 就报哪个；顺序固定，
-- 不再在每个函数里把 Strip / Panel / 深扫各写一遍。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local COLLECTIONS_TABS = {
    "CollectionsJournalTab1", "CollectionsJournalTab2", "CollectionsJournalTab3",
    "CollectionsJournalTab4", "CollectionsJournalTab5", "CollectionsJournalTab6",
}

local COLLECTIONS_PANELS = {
    "MountJournal", "PetJournal", "ToyBox", "HeirloomsJournal",
    "WardrobeCollectionFrame", "CampsitesJournal",
}

local COLLECTIONS_SEARCH = {
    "CollectionsJournalSearchBox", "MountJournalSearchBox", "PetJournalSearchBox",
    "ToyBoxSearchBox", "HeirloomsJournalSearchBox", "WardrobeCollectionFrameSearchBox",
}

-- 筛选下拉直接挂在主收藏窗和各个子面板上。
local COLLECTIONS_FILTERS = {
    "MountJournalFilterButton", "PetJournalFilterButton", "ToyBoxFilterButton",
    "HeirloomsJournalFilterButton", "CollectionsJournalFilterButton",
}

local function SkinCollections()
    M:Dress("CollectionsJournal", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, rule = true, tabs = COLLECTIONS_TABS,
        -- 宠物页的三块内容区（实机 2026-11-02 枚举确认）：左列表 / 右宠物卡 / 卡内详情，
        -- 独立全局名。挂在窗口级 wells 上走 Skin:Well（exact 全局名解析）。
        wells = {
            PetJournalLeftInset = true,
            PetJournalRightInset = true,
            PetJournalPetCardInset = true,
        },
    })
    -- 子面板：剥原美术 + 挂底衬 + 深扫（收藏格子是带图标的按钮，LooksLikeItemButton 会跳过）。
    -- 面板里的行是切页时才建的，deep 的可见期补扫负责之后每次翻页。
    M:Dress(COLLECTIONS_PANELS, { panel = { bgAlpha = 0.96 }, deep = true })
    M:Dress(COLLECTIONS_FILTERS, { as = "dropdown" })
    M:Dress(COLLECTIONS_SEARCH, { as = "editbox" })
end

-- The talent / spell book.  PlayerSpells is the modern window; SpellBookFrame is its older name and
-- some clients still have it, so both are tried.  Tabs are player-spell categories and the spec list is
-- a ScrollFrame, both handled here.
local PLAYERSPELLS_TABS = {
    "PlayerSpellsTab1", "PlayerSpellsTab2", "PlayerSpellsTab3", "PlayerSpellsTab4",
}

local PLAYERSPELLS_EDITS = { "PlayerSpellsSearchBox", "SpellBookSearchBox" }

local PLAYERSPELLS_BUTTONS = { "AssistedCombatRotationFrame", "PlayerSpellsCloseButton" }

local function SkinPlayerSpells()
    M:Dress({ "PlayerSpellsFrame", "SpellBookFrame" }, {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, tabs = PLAYERSPELLS_TABS,
    })
    -- 搜索框两种模板（EditBox / SearchBox）都认；另一个名字若是按钮会被 editbox 档跳过，
    -- 所以两类分开点名，不再在一个循环里判类型。
    M:Dress(PLAYERSPELLS_EDITS, { as = "editbox" })
    M:Dress(PLAYERSPELLS_BUTTONS, { as = "button" })
end

local ACHIEVEMENT_TABS = { "AchievementFrameTab1", "AchievementFrameTab2" }

local ACHIEVEMENT_PANELS = {
    "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameSummary",
}

local ACHIEVEMENT_SCROLLS = {
    "AchievementFrameCategoriesContainer", "AchievementFrameAchievementsContainer",
}

local function SkinAchievements()
    M:Dress("AchievementFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, tabs = ACHIEVEMENT_TABS,
        -- 统计页的原生承托底（实机 2026-11-02 枚举）：纯剥离不挂板 —— 与下面
        -- ACHIEVEMENT_PANELS 的 noPanel 同一纪律（成就列表要贴着窗口背景读）。
        wells = { AchievementFrameStatsBG = { panel = false } },
    })
    -- 这三块只剥原美术、不另挂底衬：成就列表要贴着窗口自己的背景读，多一层板子会把行距压脏。
    M:Dress(ACHIEVEMENT_PANELS, { noPanel = true, deep = true })
    M:Dress(ACHIEVEMENT_SCROLLS, { as = "scroll" })
    M:Dress({ "AchievementFrameSearchBox" }, { as = "editbox" })
    M:Dress({ "AchievementFrameFilterButton" }, { as = "dropdown" })
end

local ENCOUNTER_TABS = { "EncounterJournalTab1", "EncounterJournalTab2", "EncounterJournalTab3" }

-- 副本选择列表 + 首领页签按钮：同样只剥原美术，内容（首领图标、正文）不动。
local ENCOUNTER_PANELS = {
    "EncounterJournalInstanceSelect", "EncounterJournalBossButton1",
    "EncounterJournalBossButton2", "EncounterJournalBossButton3",
}

local function SkinEncounterJournal()
    M:Dress("EncounterJournal", { window = true, inset = true, panel = { bgAlpha = 0.96 }, rule = true, tabs = ENCOUNTER_TABS })
    M:Dress(ENCOUNTER_PANELS, { noPanel = true, deep = true })
end

M:Panel("playerspells", {
    label = "天赋 / 技能书",
    group = "收藏",
    apply = SkinPlayerSpells,
    frames = {
        "PlayerSpellsFrame", "SpellBookFrame",
        PLAYERSPELLS_TABS, PLAYERSPELLS_EDITS, PLAYERSPELLS_BUTTONS,
    },
})

M:Panel("collections", {
    label = "收藏（坐骑 / 宠物 / 玩具 / 幻化）",
    group = "收藏",
    apply = SkinCollections,
    frames = {
        "CollectionsJournal", "CollectionsJournalCloseButton",
        COLLECTIONS_TABS, COLLECTIONS_PANELS, COLLECTIONS_FILTERS, COLLECTIONS_SEARCH,
    },
})

M:Panel("achievements", {
    label = "成就",
    group = "收藏",
    apply = SkinAchievements,
    frames = {
        "AchievementFrame", "AchievementFrameCloseButton",
        ACHIEVEMENT_TABS, ACHIEVEMENT_PANELS, ACHIEVEMENT_SCROLLS,
        "AchievementFrameFilterButton", "AchievementFrameSearchBox",
    },
})

M:Panel("encounterjournal", {
    label = "冒险指南",
    group = "收藏",
    apply = SkinEncounterJournal,
    frames = {
        "EncounterJournal", "EncounterJournalCloseButton",
        ENCOUNTER_TABS, ENCOUNTER_PANELS,
    },
})

-- 幻化：Blizzard_Transmog 是 AllowLoad: Game（不限 game-type），本客户端有幻化（外观/试衣间数据齐全）。
-- 装备格子带图标，深扫会自动跳过。
local function SkinTransmog()
    M:Dress("TransmogFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })
end

M:Panel("transmog", {
    label = "幻化",
    group = "收藏",
    apply = SkinTransmog,
    addons = { Blizzard_Transmog = true },
    frames = { "TransmogFrame", "TransmogFrameCloseButton" },
})

-- 试衣间：camelot 在 UIPanels_Game 里带 DressUpFramesOverrides.lua（本客户端专属名单），窗口存在。
-- 3D 模型区是内容，不动；只收拾窗口壳与动作按钮。
local function SkinDressUp()
    -- Link / 外观切换挂在帧的成员上（不是全局名），点路径同样能查，缺了只是账本上一行 ✗。
    M:Dress("DressUpFrame", {
        window = true,
        inset = true, -- DressUpFrameInset（实机 2026-11-02 枚举确认）
        panel = { bgAlpha = 0.96 },
        rule = true,
        buttons = {
            "DressUpFrameResetButton", "DressUpFrameCancelButton",
            "DressUpFrame.LinkButton", "DressUpFrame.ToggleOutfitDetailsButton",
        },
    })
end

M:Panel("dressup", {
    label = "试衣间",
    group = "收藏",
    apply = SkinDressUp,
    frames = {
        "DressUpFrame", "DressUpFrameCloseButton",
        "DressUpFrameResetButton", "DressUpFrameCancelButton",
        "DressUpFrame.LinkButton", "DressUpFrame.ToggleOutfitDetailsButton",
    },
})
