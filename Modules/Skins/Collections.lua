-- Modules/Skins/Collections.lua
-- Collections (mounts / pets / toys / heirlooms / appearances), the achievement window and the adventure guide.  Journal rows are item buttons, so they are skipped by SkinButtonsIn; only chrome (filters, search boxes, tabs, scroll bars) is restyled.
-- 统一入口 M:Dress：名字过 Skin:Need 记账，缺哪个 `/mui skins diagnose` 就报哪个；顺序固定，
-- 不再在每个函数里把 Strip / Panel / 深扫各写一遍。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin
-- `Widget` 必须显式取：本文件以前没有这个 local，而 2026-11-06 新加的
-- `Widget:PollWatch` / `Widget:HeaderRule` 直接写了 `Widget:...` ⇒ 那是**全局 nil**，
-- Apply 在中途抛错（`audit-locals` / `api-audit` / `taint` 全过，只有实机看得出"重涂没生效"）。
local Widget = ns.Widget
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

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

-- **羊皮纸 / 天赋背景 / 行底衬递归剥**：法术页正文是暴雪 `spellbook-page-*` 羊皮纸，
-- 行与行下面还有 `spellbook-list-backplate`（列表底，实测 α0.65）与
-- `spellbook-item-backplate`（每行一块 256x64 的柔和底，实测 α0.25）——
-- 这两层本来是为羊皮纸配的，羊皮纸一剥就变成深底上的**脏暗云**（2026-11-06 玩家报的）。
-- 天赋页是 `talent-background` / `Talents-Background` / `Talents-inner-frame` /
-- `talents-heroclass-backplate`，都挂在匿名子帧上 —— Strip 不递归、deep 只扫按钮，两条都够不到。
-- 只压这些**认得出的背景 atlas**，不碰图标 / 动画遮罩（`talents-animations-mask` / `specart` 保留）。
local SPELLBOOK_BACKDROP_ATLAS = {
    "spellbook%-list%-backplate", "spellbook%-item%-backplate",
    "talent%-background", "talents%-background",
    "talents%-inner%-frame", "talents%-heroclass%-backplate",
}
-- 页底（羊皮纸）**不归零**：照 EUI 口径留 0.1 淡纸 —— 全 0 会让整页纯黑、丢掉"书"的感觉。
local SPELLBOOK_PAGE_ATLAS = { "spellbook%-page" }
-- 天赋节点下的方形投影（11-06 实机：天赋页 54 个常显 α1，挂在各天赋按钮的 BACKGROUND 层）。
-- 不走 `Fade` 的"隐藏一次"标记：暴雪 `UpdateVisualState` 会把 α 抬回来，被标记挡住就永远压不回
-- （Aurora 也是在 `UpdateVisualState` 里反复 `Shadow:SetAlpha(0)`）。所以传显式 alpha=0，
-- 让 `FadeAtlasBackdrop` 每趟（HookShow + 2 秒轮询）都写一遍，幂等。
-- 两个模式都是 Lua .lazy 匹配："node.-shadow" = "node" 后任意串到 "shadow"（square / pvp / 未来的都盖住）。
local TALENT_SHADOW_ATLAS = { "talents%-node.-shadow" }

-- 模块级稳定引用：M:HookShow / Widget:PollWatch 都按引用去重，在 Apply 里现造闭包会每次多挂一条。
--- 法术书 / 天赋页的"全暗化"一趟：剥背景 + 提亮为浅底配的深色字 + 压掉页内装饰纹样。
local function DarkenSpellbookPage()
    local f = Skin:Need("PlayerSpellsFrame")
    if not f then return end
    Skin:FadeAtlasBackdrop(f, SPELLBOOK_BACKDROP_ATLAS)
    Skin:FadeAtlasBackdrop(f, SPELLBOOK_PAGE_ATLAS, nil, 0.1)
    Skin:FadeAtlasBackdrop(f, TALENT_SHADOW_ATLAS, nil, 0)
    Skin:BrightenDarkText(f)
    -- EUI 口径的字段通道（比按 atlas 认更稳，名字与 `EllesmereUIBlizzardSkin_WindowPacks.lua` 同源）。
    local sb = f.SpellBookFrame
    if sb then
        for _, key in ipairs({ "BookBGLeft", "BookBGRight", "BookBGHalved" }) do
            local t = sb[key]
            if t and t.SetAlpha then pcall(t.SetAlpha, t, 0.1) end
        end
        for _, key in ipairs({ "TopBar", "BookCornerFlipbook", "Bookmark" }) do
            local t = sb[key]
            -- Bookmark 是"当前页签书签"，EUI 保留它；这里只压 TopBar / 翻书角。
            if key ~= "Bookmark" and t and t.SetAlpha then pcall(t.SetAlpha, t, 0) end
        end
    end
    -- 法术格美术（backplate 归零 / 金环整圈归零 / 图标方角裁切）—— 这一步只碰格子，不动页签。
    Skin:SpellbookItemArt(f)
    -- 页签：**只做纯文字页签**（专精 / 天赋 / 法术书）。
    -- `CategoryTabSystem`（法术书里那排分类图标）**整档不碰** —— 2026-11-06 实机：
    -- 那排页签在展开/收回两种布局下都被法术网格压住、图标不可见；照 EUI 判据换皮后依旧不可见，
    -- 无法证明收益、却引入了"图标丢"的嫌疑。按"宁可不换皮，也不动图标"收口。
    -- （`Skin:TabSystemArt` 内部也会跳过任何 `Icon` 有贴图的页签，双保险。）
    Skin:TabSystemArt(f.tabSystem or f.TabSystem)
    -- 页签：**只做纯文字页签**（专精 / 天赋 / 法术书）。带图标的 `CategoryTabSystem`
    -- 一律不碰 —— 2026-11-06 实机两次判例：那排图标页签在"收回"布局下与法术网格重叠，
    -- 且图标/方模式/数组贴图三家并存，任何"换皮"都会把图标压没（`Skin:TabSystemArt`
    -- 内部也会跳过任何 Icon 有贴图的页签）。
    Skin:TabSystemArt(f.tabSystem or f.TabSystem)
    -- 标题：字段通道认不到（挂在匿名子帧上），按几何认领后排成我们的样式 + 一条发丝线。
    local title = Skin:AdoptTopTitle(f)
    if title and not Marked(f, "topTitleRule") and ns.Widget and ns.Widget.HeaderRule then
        Widget:HeaderRule(f, title, { pad = 8, gap = 3 }) -- TAINT-OK: 只读标题矩形，线是我们自己的
        Mark(f, "topTitleRule", true)
    end
end

local function SkinPlayerSpells()
    -- 11-05 实机（天赋/法术页开着扫 `/mui skins layers PlayerSpellsFrame`）：窗口壳已涂，
    -- 但 `PlayerSpellsFramePortrait`（62×62）+ 那张 58×58 CircleMask 还是"暴雪原样" ⇒ 补 portrait 隐藏。
    M:Dress("PlayerSpellsFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, portrait = true,
    })
    M:Dress(PLAYERSPELLS_BUTTONS, { as = "button" })
    -- 英雄天赋选择弹窗（天赋流程的一环，11-05 skin-coverage 实机核对存在、没美化）。
    M:Dress("HeroTalentsSelectionDialog", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true,
    })
    -- 羊皮纸 / 行底衬 / 天赋背景 + 深色字提亮：Apply 先跑一趟，再挂 Show 重涂
    -- （面板懒建 + 暴雪 Show 会重设 alpha），**最后加 2 秒轮询兜住"切页才出生的行"** ——
    -- Show 不覆盖这种时刻（法术书切分类、学新法术补行都不发 Show）。
    -- 三处都是幂等：Fade 靠 `hidden` 标记，提亮靠"提亮后颜色不再暗"自跳过。
    DarkenSpellbookPage()
    M:HookShow(Skin:Need("PlayerSpellsFrame"), DarkenSpellbookPage)
    local frame = Skin:Need("PlayerSpellsFrame")
    if frame then Widget:PollWatch(frame, DarkenSpellbookPage, 2) end
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
        "PlayerSpellsFrame", PLAYERSPELLS_BUTTONS, "HeroTalentsSelectionDialog",
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
