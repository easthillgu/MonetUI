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
-- §8.107（11-12 Aurora 研读 + 实机复扫）订正：1.60 的 `CharacterFrame` 自身 `GetRegions()` = **0**，
-- 所有装饰都挂在**子帧**上（LeftPaneHost / RightPaneHost / CharacterStatsPaneScrollBox / 模式页签…）。
-- 实机可见的大贴图还剩 17 类、其中 `noAtlas` 51 张（`GetTexture()` 是数字 fileID 130871 的老式底板）。
-- 旧名单只认 4 条 atlas、且 `StyleAtlasBackdrop` 走 `Fade` 的"隐藏一次"标记 —— 暴雪换页把 alpha
-- 抬回来后标记还在、后续 Apply 直接早退，所以一直"压过又回来"。这里把 fade 那趟改成
-- `FadeAtlasBackdrop(..., 0)` 的**每趟都写**通道（`0` 在 Lua 是真值，走 SetAlpha 不走 Fade）。
local FADE_CHARACTER_ATLAS = {
    "ui%-character%-info",          -- UI-Character-Info-* 全族：General-BG / Stat-BG / ScrollLine×7 / StatTab×4
    "common%-sidetab$", "common%-sidetab%-hover", "common%-sidetab%-mask",
    "common%-framedivider",         -- 两栏之间的金色分隔线（Aurora HidePaneArt 第二层点名）
    "common%-insideframe",          -- 统计框那圈金边
    "_ui%-frame%-innertoptile", "_ui%-frame%-toptilestreaks",
    -- §8.107 复验补漏：整窗 1330x1044 的 BACKGROUND 金属大底（最外圈那圈棕金边），
    -- 复验读数 α1.00，是角色窗唯一残留；技能页名单早收了同一条，这里对齐。
    -- `FadeAtlasBackdrop` 递归 8 层，挂在哪一层子帧上都扫得到。
    "gamepad%-uiframemetal",
    -- 11-14 全量普查（§8.114.5）补漏：角色窗里还亮着、但名单没有的装饰族。
    --   AzeriteArmor-CharacterInfo-*  = 项链/护甲那一圈边框光晕（5 张）
    --   GearEnchant*                  = 附魔光环 + 图标外框（2 张）
    --   Nzoth-charactersheet-item-glow= 腐化装备的紫光
    --   pvpqueue-sidebar-honorbar-background / transfer-log-background = PvP 侧栏与转服记录的底
    -- 都是纯装饰（图标与数值不受影响）。
    "azeritearmor%-characterinfo%-",
    "gearenchant",
    "nzoth%-charactersheet%-item%-glow",
    "pvpqueue%-sidebar%-honorbar%-background",
    "transfer%-log%-background",
}
local SWAP_CHARACTER_ATLAS = {
    -- 选中页签 → 我们的**矩形** barfill 盒子（通用方法会把它压到图标之下当底色，不糊图标）。
    -- 作者要"规则方形"：暴雪 sidetab 是斜角框，tint 保留它仍是斜的；换成我们的矩形盒子才方正。
    "common%-sidetab%-selected",
}
local TINT_CHARACTER_ATLAS = {
}

-- 1.60 实机：20 个装备槽全局名全在，19 个带 `BorderFrame` 装饰子框
-- （`CharacterAmmoSlot` 是裸 ItemButton，没有 —— 与 Aurora `shared/PaperDollFrame.lua:69,109-110` 一致）。
-- 这 19 张是槽位的斜角底板，压掉后图标由 `Skin:IconWidget` 那套方边接住；**只压子框，不碰图标**。
local EQUIPMENT_SLOTS = {
    "CharacterHeadSlot", "CharacterNeckSlot", "CharacterShoulderSlot", "CharacterBackSlot",
    "CharacterChestSlot", "CharacterShirtSlot", "CharacterTabardSlot", "CharacterWristSlot",
    "CharacterHandsSlot", "CharacterWaistSlot", "CharacterLegsSlot", "CharacterFeetSlot",
    "CharacterFinger0Slot", "CharacterFinger1Slot", "CharacterTrinket0Slot", "CharacterTrinket1Slot",
    "CharacterMainHandSlot", "CharacterSecondaryHandSlot", "CharacterRangedSlot", "CharacterAmmoSlot",
}

-- 模块级稳定引用：PollWatch 按引用去重。
local function StyleCharacterArt()
    local f = Skin:Need("CharacterFrame")
    if not f then return end
    -- swap / tint 仍走 StyleAtlasBackdrop（它负责把选中页签换成我们的矩形盒子）；
    -- fadePatterns 传空表，纯淡出交给下面那趟"每趟都写"的 FadeAtlasBackdrop，两趟职责不重叠。
    Skin:StyleAtlasBackdrop(f, {}, SWAP_CHARACTER_ATLAS, TINT_CHARACTER_ATLAS)
    Skin:FadeAtlasBackdrop(f, FADE_CHARACTER_ATLAS, nil, 0)
    -- Aurora `HidePaneArt` 的两层粒度，但只收「认不出名字」的数字 fileID 大贴图（§8.107 四道门）。
    Skin:FadePlainBackdrops(f, { depth = 1, minSize = 120 })
    for i = 1, #EQUIPMENT_SLOTS do
        local slot = Skin:Need(EQUIPMENT_SLOTS[i])
        local bf = slot and slot.BorderFrame
        if bf and type(bf.SetAlpha) == "function" then pcall(bf.SetAlpha, bf, 0) end
    end
end

local function SkinCharacter()
    M:Dress("CharacterFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, portrait = true })
    -- `M:SkinWindow` 会在运行期按 `<name>CloseButton` 拼出关闭钮，静态扫描看不到那次查找；
    -- 显式登记一次（`check-frame-list` 要求 frames 名单里的名字在代码里有取用路径）。
    Skin:Need("CharacterFrameCloseButton")
    -- 美化后把肖像压成方形，与方形背景协调
    -- 肖像由 M:Dress(CharacterFrame, { window = true … }) 那一步统一处理
    M:Dress(CHARACTER_TAB_WIDGET, { deep = true })
    M:Dress(CHARACTER_PANELS, SUB_PANEL)
    M:Dress("PaperDollFrame", PAPERDOLL_PANEL)
    -- 剥信息栏底图 + 美化侧页签（11-05 作者指定，和专业窗共用 Skin:StyleAtlasBackdrop）。
    StyleCharacterArt()
    local cf = Skin:Need("CharacterFrame")
    -- §8.107：1s（原 2s）。装饰贴图会被暴雪换页 / 展开右栏时抬回 alpha，
    -- 三趟压法都是幂等「每趟都写」，周期短一档才追得上回潮；Aurora 同处是 0.5s OnUpdate。
    if cf then Widget:PollWatch(cf, StyleCharacterArt, 1) end
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
