-- Modules/Skins/Forever.lua
-- WoW Forever 专属窗口：复古查找组（LFGParentFrame）、传承进度（LegacySystemFrame）、微菜单（MicroMenu）——零售 UI 没有，普通皮肤包够不到。
-- 帧名取自本客户端的实机皮肤代码（EllesmereUI 的 *Forever 文件），并全部登记进各面板的 frames 名单，可用 `/mui skins diagnose` 复核。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- The two Forever windows carry gold "side tabs" (LFG 的列表/浏览/谁在找, 传承进度的三个页签): the ornate gold frame and glow go, the icon stays.
local function SideTab(tab)
    if not tab then return end
    if tab.Background then Skin:Fade(tab.Background) end
    if tab.TabGlow then Skin:Fade(tab.TabGlow) end
    Skin:FadeButtonArt(tab)
end

local function SideTabs(parentPath, names)
    for i = 1, #names do
        -- 成员访问也走点路径：这样每一个页签都被记进账本，写错的名字会在 diagnose 冒出来。
        SideTab(Skin:Need(parentPath .. "." .. names[i]))
    end
end

local LFG_VIEWS = {
    "LFGBrowseFrame", "LFGListingFrame", "LFGWhoListFrame",
    "LFGListingFrameCategoryView", "LFGListingFrameActivityView",
    "LFGListingFrameLockedView",
}
local LFG_BUTTONS = {
    "LFGBrowseFrameSendMessageButton", "LFGBrowseFrameGroupInviteButton",
    "LFGListingFrameBackButton", "LFGListingFramePostButton",
}
local LFG_SIDE_TABS = { "ListingTab", "BrowsingTab", "WhoListingTab" }

local function SkinLFG()
    M:Dress("LFGParentFrame", { window = true, panel = { bgAlpha = 0.96 } })

    -- The animated eye in the portrait slot is a button of its own: alpha it away AND take the mouse, so the idle 64px region cannot swallow clicks.
    local eye = Skin:Need("LFGParentFramePortrait")
    if eye then
        Skin:Fade(eye)
        if eye.EnableMouse then eye:EnableMouse(false) end
    end

    -- The three views repaint themselves when swapped in, so each carries its own fill/border art: strip every view, not just the parent.
    M:Controls(LFG_VIEWS, function(view)
        Skin:Strip(view)
        M:SkinButtonsIn(view)
    end)
    M:Dress(LFG_BUTTONS, { as = "button" })
    SideTabs("LFGParentFrame", LFG_SIDE_TABS)
end

M:Panel("lfg", {
    label = "查找组（复古）",
    group = "窗口",
    apply = SkinLFG,
    -- LoD gate: this pack waits for the vanilla-style group finder addon instead of re-skinning on every addon load.
    addons = { Blizzard_GroupFinder_VanillaStyle = true },
    frames = {
        "LFGParentFrame", "LFGParentFramePortrait",
        "LFGParentFrame.ListingTab", "LFGParentFrame.BrowsingTab", "LFGParentFrame.WhoListingTab",
        "LFGBrowseFrame", "LFGListingFrame", "LFGWhoListFrame",
        "LFGBrowseFrameSendMessageButton", "LFGBrowseFrameGroupInviteButton",
        "LFGListingFrameBackButton", "LFGListingFramePostButton",
    },
})

local LEGACY_SIDE_TABS = { "LegacyRewardTrackTab", "LegacyChallengeTab", "LegacyTreeTab" }
local LEGACY_PAGES     = { "RewardTrackPage", "ChallengesPage" }

local function SkinLegacySystem()
    M:Dress("LegacySystemFrame", { window = true, panel = { bgAlpha = 0.96 } })
    SideTabs("LegacySystemFrame", LEGACY_SIDE_TABS)

    M:Controls(LEGACY_PAGES, function(page)
        Skin:Strip(page)
        M:SkinButtonsIn(page)
        M:SkinScrollsIn(page)
    end)
end

M:Panel("legacy", {
    label = "传承进度",
    group = "窗口",
    apply = SkinLegacySystem,
    addons = { Blizzard_LegacySystem = true },
    frames = {
        "LegacySystemFrame",
        "LegacySystemFrame.LegacyRewardTrackTab", "LegacySystemFrame.LegacyChallengeTab",
        "LegacySystemFrame.LegacyTreeTab",
        "RewardTrackPage", "ChallengesPage",
    },
})

-- Retail folded several of these away; Forever keeps the classic row, so the full list is declared and each missing button is skipped by the guarded lookup.
local MICRO_BUTTONS = {
    "CharacterMicroButton", "ProfessionMicroButton", "PlayerSpellsMicroButton",
    "AchievementMicroButton", "QuestLogMicroButton", "GuildMicroButton",
    "LFDMicroButton", "CollectionsMicroButton", "EJMicroButton",
    "StoreMicroButton", "MainMenuMicroButton", "HelpMicroButton",
    "HousingMicroButton",
    -- Forever-only survivors retail renamed or folded away:
    "SpellbookMicroButton", "TalentMicroButton", "SocialsMicroButton",
    "PVPMicroButton", "LegacyMicroButton",
}

local function SkinOneMicroButton(name)
    local button = Skin:Need(name)
    if not button then return end
    -- The icon texture stays; only the button's own sprite edges go.
    Skin:FadeButtonArt(button)
end

local function SkinMicroMenuCore()
    for i = 1, #MICRO_BUTTONS do
        SkinOneMicroButton(MICRO_BUTTONS[i])
    end

    -- Forever's MicroMenu keeps a Blizzard container strip; fade it by alpha only -- the container is Edit-Mode-owned and must never be hidden.
    local menu = Skin:Need("MicroMenu")
    if menu then
        if menu.BackgroundArt then Skin:Fade(menu.BackgroundArt) end
        if menu.BorderArt then Skin:Fade(menu.BorderArt) end
    end
end

local microHooked = false

local function SkinMicroMenu()
    -- Micro buttons are secure: never touch them in combat; ns:AfterCombat defers the
    -- repaint to combat end instead of failing silently.
    if InCombatLockdown() then
        ns:AfterCombat("skins-micromenu", function()
            if M.active then Skin.With("micromenu", SkinMicroMenuCore) end
        end)
        return
    end

    SkinMicroMenuCore()

    -- UpdateMicroButtons can fire several times per frame; one debounced repaint absorbs each burst.
    if not microHooked and Skin:Need("UpdateMicroButtons") then
        -- 不 hooksecurefunc("UpdateMicroButtons")（全局函数钩子，会污染调用链）：
        -- 改成每 1 秒轮询一次（Debounce 内部本来就合并）。
        microHooked = true
        local repaint = M:Debounce(function()
            if InCombatLockdown() then return end
            -- 轮询回调不在任何面板的作用域里，自己套一层，账本才不会把这 19 个名字记到 "_" 名下。
            Skin.With("micromenu", function()
                for i = 1, #MICRO_BUTTONS do
                    SkinOneMicroButton(MICRO_BUTTONS[i])
                end
            end)
        end)
        if ns.Widget and ns.Widget.PollWatch then
            local driver = Skin:Need("UIParent")
            if driver then ns.Widget:PollWatch(driver, repaint) end
        end
    end
end

M:Panel("micromenu", {
    label = "微菜单按钮",
    group = "窗口",
    apply = SkinMicroMenu,
    -- 每个微按钮都在查找时记了账，所以直接把 MICRO_BUTTONS 摊进声明名单：一处定义，别处不再抄。
    frames = { "MicroMenu", MICRO_BUTTONS },
})
