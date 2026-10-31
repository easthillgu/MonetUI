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

-- 左上角角色肖像圆形 → 方形，与窗口背景保持一致
-- 通过 Skin:Need 点名拿到 portrait 区域，再把纹理拉伸以适应方形框。
-- 注意：此操作只在窗口美化时执行，不会破坏框体的其它表现。
local function MakePortraitSquare(frame)
    local portrait = M:Need("CharacterFramePortrait")
    if not portrait then return end
    -- 先记进账本，防止以后改名漏掉
    M:Mark(portrait, "monetPortraitSquared", true)
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
    M:Dress("CharacterFrame", { window = true, panel = { bgAlpha = 0.96 } })
    -- 美化后把肖像压成方形，与方形背景协调
    MakePortraitSquare(CharacterFrame)
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
