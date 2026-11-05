-- Modules/Skins/Collections.lua
-- Collections (mounts / pets / toys / heirlooms / appearances), the achievement window and the adventure guide.  Journal rows are item buttons, so they are skipped by SkinButtonsIn; only chrome (filters, search boxes, tabs, scroll bars) is restyled.
-- 统一入口 M:Dress：名字过 Skin:Need 记账，缺哪个 `/mui skins diagnose` 就报哪个；顺序固定，
-- 不再在每个函数里把 Strip / Panel / 深扫各写一遍。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- 1.60 实机（11-05 逐窗开过 + `/mui compat find`，见 HANDOFF §8.40）：只有 1..5，
-- `CollectionsJournalTab6` 不存在（幻化在 1.60 是 `WardrobeCollectionFrame`，不占第 6 页签）。
local COLLECTIONS_TABS = {
    "CollectionsJournalTab1", "CollectionsJournalTab2", "CollectionsJournalTab3",
    "CollectionsJournalTab4", "CollectionsJournalTab5",
}

-- `CampsitesJournal` 本客户端没有这个名字（营地日志在 1.60 折进了地图侧）。
local COLLECTIONS_PANELS = {
    "MountJournal", "PetJournal", "ToyBox", "HeirloomsJournal",
    "WardrobeCollectionFrame",
}

-- 三个页内搜索框有实名（跟随子面板存在），两个没有：`CollectionsJournalSearchBox` 与
-- `ToyBoxSearchBox` 在 1.60 不存在（搜索框是 `TabSystem` 侧的运行期子件，由窗口那侧的 deep 扫接）。
local COLLECTIONS_SEARCH = {
    "MountJournalSearchBox", "PetJournalSearchBox", "WardrobeCollectionFrameSearchBox",
}

-- **摘掉全部 5 个 `*FilterButton`**（11-05 实机：窗开过仍 ✗，实名不存在）：
-- 筛选下拉在 1.60 是各面板 `parentKey` 下的运行期控件，没有全局名。
-- 上面 `M:Dress(COLLECTIONS_PANELS, { deep = true })` 已经覆盖这些子控件，
-- 留着点名只会让 `/mui skins diagnose` 长期报五行的假"缺失"。

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
    M:Dress(COLLECTIONS_SEARCH, { as = "editbox" })
end

-- The talent / spell book.  **1.60 实名（11-05 `/mui compat find PlayerSpells` / `find SpellBook`）**：
-- 只有 `PlayerSpellsFrame` + `PlayerSpellsFrameCloseButton` + `PlayerSpellsFrameClearButton`
-- （外加 `PlayerSpellsMicroButton`）。旧名 `SpellBookFrame` 在**这台客户端不存在**（只有按钮
-- `SpellbookMicroButton`），它是零售 12.x 的名字 —— 留着就是一行永远消不掉的 ✗，删。
-- 页签 `PlayerSpellsTab1..4` 与两个搜索框（`PlayerSpellsSearchBox` / `SpellBookSearchBox`）
-- 同样没有实名：1.60 的分类页签是 `TabSystem` 的运行期子件、搜索框挂在页签系统里，
-- 由窗口这侧的 `deep = true` 接住（§8.40 的 ② 档）。
local PLAYERSPELLS_BUTTONS = { "PlayerSpellsFrameCloseButton", "PlayerSpellsFrameClearButton" }

local function SkinPlayerSpells()
    M:Dress("PlayerSpellsFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true,
    })
    M:Dress(PLAYERSPELLS_BUTTONS, { as = "button" })
end

local ACHIEVEMENT_TABS = { "AchievementFrameTab1", "AchievementFrameTab2" }

local ACHIEVEMENT_PANELS = {
    "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameSummary",
}

-- **摘掉四个点名**（11-05 实机：成就窗开过仍 ✗，实名不存在）：两个 `*Container` 是
-- `HyperText`/`ScrollBox` 的运行期容器，筛选与搜索框挂在 `TabSystem` 里。
-- 列表/分类/统计三块已经 `noPanel + deep`，控件该涂的都涂到了。

local function SkinAchievements()
    M:Dress("AchievementFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, tabs = ACHIEVEMENT_TABS,
        -- 统计页的原生承托底（实机 2026-11-02 枚举）：纯剥离不挂板 —— 与下面
        -- ACHIEVEMENT_PANELS 的 noPanel 同一纪律（成就列表要贴着窗口背景读）。
        wells = { AchievementFrameStatsBG = { panel = false } },
    })
    -- 这三块只剥原美术、不另挂底衬：成就列表要贴着窗口自己的背景读，多一层板子会把行距压脏。
    M:Dress(ACHIEVEMENT_PANELS, { noPanel = true, deep = true })
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
        "PlayerSpellsFrame", PLAYERSPELLS_BUTTONS,
    },
})

M:Panel("collections", {
    label = "收藏（坐骑 / 宠物 / 玩具 / 幻化）",
    group = "收藏",
    apply = SkinCollections,
    frames = {
        "CollectionsJournal", "CollectionsJournalCloseButton",
        COLLECTIONS_TABS, COLLECTIONS_PANELS, COLLECTIONS_SEARCH,
    },
})

M:Panel("achievements", {
    label = "成就",
    group = "收藏",
    apply = SkinAchievements,
    frames = {
        "AchievementFrame", "AchievementFrameCloseButton",
        ACHIEVEMENT_TABS, ACHIEVEMENT_PANELS,
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
