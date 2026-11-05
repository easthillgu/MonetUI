-- Modules/Skins/Character.lua
-- The character sheet and the inspect sheet: window, side tabs and sub panels (paper doll, reputation, currency, skills, PvP) are plated; item/slot icons are never touched (SkinButtonsIn skips buttons that carry an icon).

local ADDON_NAME, ns = ...

local M     = ns.Skins
local Skin  = ns.Skin
local Widget = ns.Widget

-- **1.60 实测（开服日 11-05，`/mui compat find CharacterFrameTab`）**：`CharacterFrameTab1..3`
-- 这排编号页签**在本客户端不存在**，全 UI 只有 3 个名字命中 —— `CharacterFrameTabIndicators`
-- 这套 TabGroup 容器 + 它的左右翻页箭头。真正的页签按钮是容器**运行期**建的子件（点名会漏），
-- 所以这里只点容器名，整棵子树走 deep 扫；箭头由子树扫顺带涂成我们的按钮。
-- 后果说清楚：以前这三行是空枪，角色页签从收口起一直是暴雪原样。
local CHARACTER_TAB_WIDGET = "CharacterFrameTabIndicators"

local CHARACTER_PANELS = {
    "ReputationFrame", "TokenFrame",
}

-- 装备格单独一档：`slotInfo = true` 让扫描在每格上多挂"物品等级数字 + 冷却遮罩"（作者
-- 11-04 点名只要人物面板这一处）。声望 / 货币 / 检视 / 商人一律不开。
local PAPERDOLL_PANEL = { panel = { bgAlpha = 0.96 }, deep = true, slotInfo = true }

local INSPECT_TABS = { "InspectFrameTab1", "InspectFrameTab2" }

-- **11-05 实机（观察窗开过 + `/mui compat find Inspect` 走 17972 框）**：`InspectTalentFrame`
-- 实名不存在（天赋在 1.60 折进独立系统，观察窗只剩装备 / PVP / 公会三页），而
-- `InspectPaperDollFrame` / `InspectPVPFrame` 都在 ⇒ 摘掉这一条假点名（§8.40 ②）。
local INSPECT_PANELS = { "InspectPaperDollFrame", "InspectPVPFrame" }

-- 子面板的处理和窗口不同：不剥标题/关闭，只剥自己的原美术 + 挂底衬 + 扫直接子控件。
-- 标签页内容（滚动条、上下箭头）是懒建的，`Dress` 默认会在显示时再扫一遍。
local SUB_PANEL = { panel = { bgAlpha = 0.96 }, deep = true }

-- 左上角角色肖像圆形 → 方形，与窗口背景保持一致
-- 通过 Skin:Need 点名拿到 portrait 区域，再把纹理拉伸以适应方形框。
-- 注意：此操作只在窗口美化时执行，不会破坏框体的其它表现。
--
-- **漏斗在 `ns.Skin` 上，不在本模块 `M` 上**：`M:Need` / `M:Mark` 都是 nil
-- （`ns.Skins` 只导出 Panel/Dress/HookShow 那一套）。写成 M: 的话这一句就抛
-- "attempt to call a nil value"，`SkinCharacter` 整条中断 —— 角色窗口从 `535f89e`
-- 收口之后就一直没被美化过，每次登录在聊天框留一条「界面美化「character」应用失败」。
-- 肖像压方形已经上收到**窗口档**（M:SkinWindow 调 Skin:SquarePortrait：裁内接方框 + 越界才收进外框），
-- 这里不再自己找 CharacterFramePortrait —— 同一个动作只有一个入口，也不给别的窗口留第二份实现。

-- **角色面板剥背景 + 美化侧页签（11-05 作者指定，复用专业窗那条通用通道）**。
-- layers 实测 CharacterFrame 还剩：`ui-character-info`（信息栏行底图）×32、
-- `common-sidetab`（模式页签 CharacterFrameModeTab1..4 的底/悬停/遮罩）×18；
-- 装备/属性图标是数字文件 ID（GetAtlas 回 nil），不会被这些 atlas 模式误伤。
local FADE_CHARACTER_ATLAS = {
    "ui%-character%-info",
    "common%-sidetab$",
    "common%-sidetab%-hover",
    "common%-sidetab%-mask",
}
local SWAP_CHARACTER_ATLAS = {
    -- 选中页签 → 我们的**矩形** barfill 盒子（通用方法会把它压到图标之下当底色，不糊图标）。
    -- 作者要"规则方形"：暴雪 sidetab 是斜角框，tint 保留它仍是斜的；换成我们的矩形盒子才方正。
    "common%-sidetab%-selected",
}
local TINT_CHARACTER_ATLAS = {
}

-- 模块级稳定引用：PollWatch 按引用去重。
local function StyleCharacterArt()
    local f = Skin:Need("CharacterFrame")
    if f then Skin:StyleAtlasBackdrop(f, FADE_CHARACTER_ATLAS, SWAP_CHARACTER_ATLAS, TINT_CHARACTER_ATLAS) end
end

local function SkinCharacter()
    M:Dress("CharacterFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, portrait = true })
    -- 美化后把肖像压成方形，与方形背景协调
    -- 肖像由 M:Dress(CharacterFrame, { window = true … }) 那一步统一处理
    M:Dress(CHARACTER_TAB_WIDGET, { deep = true })
    M:Dress(CHARACTER_PANELS, SUB_PANEL)
    M:Dress("PaperDollFrame", PAPERDOLL_PANEL)
    -- 剥信息栏底图 + 美化侧页签（11-05 作者指定，和专业窗共用 Skin:StyleAtlasBackdrop）。
    StyleCharacterArt()
    local cf = Skin:Need("CharacterFrame")
    if cf then Widget:PollWatch(cf, StyleCharacterArt, 2) end
end

local function SkinInspect()
    M:Dress("InspectFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, portrait = true })
    M:Dress(INSPECT_TABS, { as = "tab" })
    M:Dress(INSPECT_PANELS, SUB_PANEL)
end

M:Panel("character", {
    label = "角色界面",
    group = "角色",
    apply = SkinCharacter,
    frames = {
        "CharacterFrame", "CharacterFrameCloseButton",
        CHARACTER_TAB_WIDGET,
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
        "InspectPaperDollFrame", "InspectPVPFrame",
    },
})
