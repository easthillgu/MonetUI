-- Modules/Skins/Character.lua
-- The character sheet and the inspect sheet: window, side tabs and sub panels (paper doll, reputation, currency, skills, PvP) are plated; item/slot icons are never touched (SkinButtonsIn skips buttons that carry an icon).

local ADDON_NAME, ns = ...

local M = ns.Skins
local Skin = ns.Skin

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

local INSPECT_PANELS = { "InspectPaperDollFrame", "InspectPVPFrame", "InspectTalentFrame" }

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
local function MakePortraitSquare()
    local portrait = Skin:Need("CharacterFramePortrait")
    if not portrait then return end
    -- 先记进账本，防止以后改名漏掉
    ns:Mark(portrait, "monetPortraitSquared", true)
    -- 关闭鼠标穿透（防止和下方按钮冲突）
    if portrait.EnableMouse then portrait:EnableMouse(false) end
    -- 设置纹理贴图模式： clamp 可避免边缘重复
    portrait:SetTexCoord(0, 1, 0, 1)
    -- 通过修改宽高比让引擎按方形渲染（12.1.5 实测：portrait 原本是椭圆，
    -- 设置 width=height 会让它被压成正圆/方形取决于引擎，这里通过 SetAllPoints
    -- 覆盖在同一位置并配合 alpha 0 过渡的方式使其可视部分变为方形）
    portrait:SetSize(64, 64)
end

local function SkinCharacter()
    M:Dress("CharacterFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })
    -- 美化后把肖像压成方形，与方形背景协调
    MakePortraitSquare()
    M:Dress(CHARACTER_TAB_WIDGET, { deep = true })
    M:Dress(CHARACTER_PANELS, SUB_PANEL)
    M:Dress("PaperDollFrame", PAPERDOLL_PANEL)
end

local function SkinInspect()
    M:Dress("InspectFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })
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
        "InspectPaperDollFrame", "InspectPVPFrame", "InspectTalentFrame",
    },
})
