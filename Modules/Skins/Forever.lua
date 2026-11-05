-- Modules/Skins/Forever.lua
-- WoW Forever 专属窗口：复古查找组（LFGParentFrame）、传承进度（LegacySystemFrame）、微菜单（MicroMenu）——零售 UI 没有，普通皮肤包够不到。
-- 帧名取自本客户端的实机皮肤代码（EllesmereUI 的 *Forever 文件），并全部登记进各面板的 frames 名单，可用 `/mui skins diagnose` 复核。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

--- 战斗中为真。**优先问 Core 的 `ns:InCombat()`**：本客户端先派发 PLAYER_REGEN_*、之后才翻
--- `InCombatLockdown()`，而 `ns:AfterCombat` 的排空就跑在那次派发里（微按钮换皮就是排队的）。
local function InCombat()
    if type(ns.InCombat) == "function" then return ns:InCombat() end
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

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
    -- 浏览页的辅助按钮 / 顶栏下拉 / 父框关闭：全部按全局实名登记，写错就在 diagnose 冒 ✗。
    "LFGBrowseFrameRefreshButton", "LFGBrowseFrameOptionsButton",
    "LFGParentFrameCloseButton",
}
local LFG_TOP_TABS = { "LFGParentFrameTab1", "LFGParentFrameTab2", "LFGParentFrameTab3" }
local LFG_DROPDOWNS = { "LFGBrowseFrameCategoryDropdown", "LFGBrowseFrameActivityDropdown" }
local LFG_SIDE_TABS = { "ListingTab", "BrowsingTab", "WhoListingTab" }

-- QueueStatusButton 是排队状态那枚小眼睛的宿主：属于 Blizzard_QueueStatusFrame，不是本面板的
-- LoD 门管；这里登记只为让 diagnose 能扫到，读不到就落空一行 —— **只进账本，不换肤**。
local LFG_QUEUE = { "QueueStatusButton" }

-- 暴雪的角色图标走图集（atlas）：LFGBROWSE_GROUPDATA_ATLASES 那张表是 Browse.lua 的
-- **local**，外面根本拿不到；行模板又是 ScrollBox 复用的，直接改表 = 下一次滚回来又被
-- 暴雪的 SetAtlas 顶回去。可行的入口只有"逐贴图看 atlas 名，命中就 SetTexture 换成我们的文件图"。
--
-- **不 hooksecurefunc 暴雪方法、不 HookScript 暴雪框**（AGENTS：写过一次 = 这个框之后
-- 全被记在 MonetUI 名下）。走轮询：`Widget:PollWatch` 只在框可见时按拍跑，隐藏时一秒都不多花。
-- 换过一次之后贴图 GetAtlas 会返回 nil —— 下次扫描自然跳过；暴雪复用行重新贴 atlas 时命中，
-- 我们再换回来。所以不需要旁表标记，也不要往贴图写字段。
local ROLE_ATLASES = {
    ["groupfinder-icon-role-large-tank"] = "monet_role_tank",
    ["groupfinder-icon-role-large-heal"] = "monet_role_heal",
    ["groupfinder-icon-role-large-dps"]  = "monet_role_dps",
    ["groupfinder-icon-role-micro-tank"] = "monet_role_tank",
    ["groupfinder-icon-role-micro-heal"] = "monet_role_heal",
    ["groupfinder-icon-role-micro-dps"]  = "monet_role_dps",
}

-- 深度上限：LFGParentFrame → LFGBrowseFrame → ScrollBox → row → DataDisplay → Enumerate → IconN
-- 已经 6 层；再深就到 Tooltip / VoiceChat 那种"我们的手够不着"的子树，收手。
local LFG_WALK_MAX_DEPTH = 7

local function SwapRoleAtlas(tex)
    if not tex or type(tex.GetAtlas) ~= "function" then return end
    if type(tex.SetTexture) ~= "function" then return end
    local okA, atlas = pcall(tex.GetAtlas, tex)
    if not okA or type(atlas) ~= "string" then return end
    local key = ROLE_ATLASES[atlas]
    if not key then return end
    local Media = ns.Media
    if not Media or type(Media.Texture) ~= "function" then return end
    local path = Media:Texture(key)
    if type(path) ~= "string" then return end
    -- SetTexture 会把图集整段清掉，之后 GetAtlas 返回 nil —— 下一次轮询直接跳过；
    -- 暴雪复用行、重新 SetAtlas 之后我们才再换一次。
    if pcall(tex.SetTexture, tex, path) then
        if type(tex.SetTexCoord) == "function" then pcall(tex.SetTexCoord, tex, 0, 1, 0, 1) end
    end
end

local function WalkSwapRole(frame, depth)
    if not frame or depth > LFG_WALK_MAX_DEPTH then return end
    -- 不可见 / 读不出可见性 = forbidden 对象，整棵子树放手。
    local okV, visible = pcall(function() return frame:IsVisible() end)
    if not okV or not visible then return end

    if type(frame.GetRegions) == "function" then
        local okR, regions = pcall(function() return { frame:GetRegions() } end)
        if okR and type(regions) == "table" then
            for i = 1, #regions do SwapRoleAtlas(regions[i]) end
        end
    end
    if type(frame.GetChildren) == "function" then
        local okC, kids = pcall(function() return { frame:GetChildren() } end)
        if okC and type(kids) == "table" then
            for i = 1, #kids do WalkSwapRole(kids[i], depth + 1) end
        end
    end
end

-- 稳定引用 —— PollWatch 用它去重，闭包每次新建 = 每一拍都多挂一条轮询（AGENTS 明写）。
local function RefreshLfgRoleAtlas()
    if not M.active then return end
    -- 轮询不在任何面板 Apply 的作用域里，自己套一层 Skin.With，账本才记在 "lfg" 名下。
    Skin.With("lfg", function()
        local parent = Skin:Need("LFGParentFrame")
        if parent then WalkSwapRole(parent, 0) end
    end)
end

local function SkinLFG()
    M:Dress("LFGParentFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })

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
    M:Dress(LFG_TOP_TABS, { as = "tab" })
    M:Dress(LFG_DROPDOWNS, { as = "dropdown" })
    -- 队列眼睛的宿主框：不做换肤（属于 Blizzard_QueueStatusFrame、有自己的动画），
    -- 只过 Need 让它进账本，方便 `/mui skins diagnose` 一眼看到能不能读到。
    -- （2026-11-03 独立审查必改项：原先这里写的是 M:Dress(LFG_QUEUE, { as = "fade" })，
    --  而 DRESSERS.fade 实际会调 Skin:Fade 把框压成 alpha 0 —— 排队眼睛直接消失，
    --  与注释正好相反；去掉换肤调用，只保留账本登记。）
    for i = 1, #LFG_QUEUE do
        Skin:Need(LFG_QUEUE[i])
    end
    SideTabs("LFGParentFrame", LFG_SIDE_TABS)

    -- Atlas 换图：进面板就先扫一次；之后靠 PollWatch 每 2 秒复检（ScrollBox 复用行 = 暴雪
    -- 会重新贴 atlas，我们这一遍再把图换回来）。回调稳定引用；PollWatch 内部会去重。
    RefreshLfgRoleAtlas()
    local parent = Skin:Need("LFGParentFrame")
    if parent and ns.Widget and ns.Widget.PollWatch and ns.Widget:Readable(parent) then
        ns.Widget:PollWatch(parent, RefreshLfgRoleAtlas, 2)
    end
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
        LFG_VIEWS, LFG_BUTTONS, LFG_TOP_TABS, LFG_DROPDOWNS, LFG_QUEUE,
    },
})

local LEGACY_SIDE_TABS = { "LegacyRewardTrackTab", "LegacyChallengeTab", "LegacyTreeTab" }
local LEGACY_PAGES     = { "RewardTrackPage", "ChallengesPage" }

local function SkinLegacySystem()
    M:Dress("LegacySystemFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })
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

-- **1.60 实测（开服日 11-05，`/mui compat find MicroButton` 走 19804 个框，全客户端一共 17 个命中）**：
-- 底栏 15 颗 = Achievement / Character / Collections / EJ / Guild / Help / Housing / LFD / Legacy /
-- MainMenu / PlayerSpells / Profession / QuestLog / Spellbook / Store / Talent（+ 容器 `MicroButtonAndBagsBar`）。
-- `SocialsMicroButton` 与 `PVPMicroButton` **不存在**（好友/社区/PVP 合并进 `SocialUIFrame`，
-- 名字是 `SocialUIFrame*`；PVP 那一档整个折掉了）—— 这两行是空枪，从收口起那两颗"按钮"没被涂过，
-- 因为它们压根不在。删掉，别让台账上永远挂着两行消不掉的 ✗。
local MICRO_BUTTONS = {
    "CharacterMicroButton", "ProfessionMicroButton", "PlayerSpellsMicroButton",
    "AchievementMicroButton", "QuestLogMicroButton", "GuildMicroButton",
    "LFDMicroButton", "CollectionsMicroButton", "EJMicroButton",
    "StoreMicroButton", "MainMenuMicroButton", "HelpMicroButton",
    "HousingMicroButton",
    -- Forever 保留、零售改名或折掉的那几颗：
    "SpellbookMicroButton", "TalentMicroButton", "LegacyMicroButton",
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
    if InCombat() then
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
            if InCombat() then return end
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
