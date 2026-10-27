-- Modules/Bags/Bags.lua
-- Monet-style categorized bags & bank, drawn from scratch with Monet widgets and this client's C_Container / C_Bank APIs.
-- Ideas borrowed from common bag addons; code original (cargBags is GPL, so it is never used).
-- Client constants below were verified via wuxian api_get against the official manual, not from memory.

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Widget   = ns.Widget
local Math     = ns.Math
local Color    = ns.Color
local EventBus = ns.EventBus
local Secrets  = ns.Secrets

local M = { name = "Bags" }

-- BagIndex (manual): backpack + carried bags, reagent bag, then bank tabs.
local BAGS_CARRIED = { 0, 1, 2, 3, 4 }   -- Backpack + Bag_1..Bag_4
local BAG_REAGENT  = 5                    -- ReagentBag (present only if crafted)
local BANK_TABS    = { 6, 7, 8, 9, 10, 11, 12, 13, 14 }    -- CharacterBankTab_1..9

-- ItemClass (manual).  Local table so a missing Enum global can never bite.
local IC = {
    Consumable      = 0,
    Container       = 1,
    Weapon          = 2,
    Gem             = 3,
    Armor           = 4,
    Reagent         = 5,
    Projectile      = 6,
    Tradegoods      = 7,
    ItemEnhancement = 8,
    Recipe          = 9,
    Questitem       = 12,
    Key             = 13,
    Miscellaneous   = 15,
    Battlepet       = 17,
}

local Q_POOR = 0

local function Setting(key)
    local stored = (ns:DB().bags or {})[key]
    if stored ~= nil then
        -- 迁移：anchor 的默认值我们控制，玩家不需要手工调 anchor.x/y（那是布局内部量）。
        -- 所以只要 anchor 存在，**无条件覆盖成最新默认值**。这是第三次迭代了，
        -- 每次改默认值都要写一次迁移逻辑太蠢——直接统一。
        -- （玩家显式拖过的窗口 WindowPosition 不受影响，RestoreDragged 单独路径。）
        if key == "anchor" then
            return { frame = "MonetUIQuestTracker", side = "right",
                     x = -18, y = -28 }
        end
        return stored
    end
    return (ns.DEFAULTS.bags or {})[key]
end

-- Ordered: the FIRST category whose match() accepts an item claims it, so the list runs specific -> general and "other" is the fallback.

local CATEGORIES = {
    { key = "junk",  label = "垃圾",
      match = function(it) return it.quality == Q_POOR and (it.sellPrice or 0) > 0 end },
    { key = "gear",  label = "装备",
      match = function(it)
          return (it.classID == IC.Armor or it.classID == IC.Weapon)
             and it.equipLoc and it.equipLoc ~= "" and it.equipLoc ~= "INVTYPE_NON_EQUIP"
      end },
    { key = "use",   label = "消耗品",
      match = function(it) return it.classID == IC.Consumable or it.classID == IC.ItemEnhancement end },
    { key = "goods", label = "材料",
      match = function(it) return it.classID == IC.Tradegoods or it.classID == IC.Reagent end },
    { key = "quest", label = "任务",
      match = function(it) return it.isQuest or it.classID == IC.Questitem end },
    { key = "pets",  label = "收藏",
      match = function(it)
          return it.classID == IC.Battlepet
              or (it.classID == IC.Miscellaneous and (it.subClassID == 2 or it.subClassID == 5))
      end },
    { key = "other", label = "其他",
      match = function() return true end },
}

local CATEGORY_BY_KEY = {}
for _, cat in ipairs(CATEGORIES) do CATEGORY_BY_KEY[cat.key] = cat end

--- One plain record for a filled (bag, slot).  GetItemInfo may return nil for uncached items, so its fields are optional and container info stays the fallback.
local function BuildItem(bag, slot, info)
    local it = {
        bag     = bag,
        slot    = slot,
        itemID  = info.itemID,
        link    = info.hyperlink,
        count   = info.stackCount,
        quality = info.quality or 0,
        locked  = info.isLocked,
        name    = info.itemName,
    }

    it.texture = info.iconFileID

    if info.hyperlink and C_Item and C_Item.GetItemInfo then
        -- 返回顺序（客户端文档 ItemDocumentation.lua:GetItemInfo）：
        --   1 itemName  2 itemLink  3 itemQuality  4 itemLevel  5 itemMinLevel
        --   6 itemType  7 itemSubType  8 itemStackCount  9 itemEquipLoc
        --  10 itemTexture  11 sellPrice  12 classID  13 subclassID ...
        -- 第 8 项之后这里曾经少写了一个占位符，于是 equipLoc 拿到的是堆叠数、
        -- classID 拿到的是卖价 —— 分类（装备/材料/收藏）永远不命中，图标也全是空的。
        local ok, name, link, quality, ilvl, _, _, _, _, equipLoc, tex, sellPrice,
              classID, subClassID = pcall(C_Item.GetItemInfo, info.hyperlink)
        if ok then
            it.name      = name or it.name
            it.quality   = quality or it.quality
            it.texture   = tex or it.texture
            it.ilvl      = ilvl
            it.equipLoc  = equipLoc
            it.sellPrice = sellPrice
            it.classID   = classID
            it.subClassID= subClassID
        end
    end

    -- Quest detection guarded: not every build carries this namespace call.
    if C_Container and C_Container.GetContainerItemQuestInfo then
        local ok, q = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
        if ok and q then
            it.isQuest = (q.questID and q.questID > 0) or q.isQuestItem or false
        end
    end

    return it
end

local function AssignCategory(it)
    for _, cat in ipairs(CATEGORIES) do
        if cat.match(it) then return cat.key end
    end
    return "other"
end

--- Scan a set of bag indexes into { categoryKey = { item, ... } }.
local function Scan(bagIndexes)
    local groups = {}
    for _, cat in ipairs(CATEGORIES) do groups[cat.key] = {} end

    for _, bag in ipairs(bagIndexes) do
        local num = C_Container.GetContainerNumSlots(bag)
        if num and num > 0 then
            for slot = 1, num do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    local it = BuildItem(bag, slot, info)
                    local key = AssignCategory(it)
                    groups[key][#groups[key] + 1] = it
                end
            end
        end
    end

    return groups
end

-- Quest items take the amber ring regardless of quality; poor/common keep the plain edge (Andromeda likewise demotes common to black).
-- Declared above AcquireButton: its hover closure uses QualityBorder as an upvalue.
local QUALITY_COLOR = {
    -- [0] poor and [1] common: intentionally absent -- plain edge
    [2] = { r = 0.20, g = 0.80, b = 0.20 },  -- Uncommon green
    [3] = { r = 0.20, g = 0.55, b = 1.00 },  -- Rare    blue
    [4] = { r = 0.65, g = 0.30, b = 0.95 },  -- Epic    purple
    [5] = { r = 1.00, g = 0.55, b = 0.00 },  -- Legendary orange
    [6] = { r = 0.90, g = 0.80, b = 0.40 },  -- Artifact
    [7] = { r = 0.90, g = 0.80, b = 0.40 },  -- Heirloom
}
local QUEST_COLOR = { r = 0.80, g = 0.80, b = 0.00 }   -- task amber

--- Border for an item: quest amber first, then quality hue, else nil (plain edge).
local function QualityBorder(rec)
    if not rec then return nil end
    if rec.isQuest then return QUEST_COLOR end
    return QUALITY_COLOR[rec.quality or 0]
end

-- --- 模板槽层压平（收养案 2026-10-25）：模板自带暗色槽底 + IconMask 蒙版 + 默认绘制层，
-- --- 不解锁就把图标整个蒙成"缺纹理斜纹方块"（实机 snap：只有按探针暴力解的格子出图）。
-- --- 幂等：Acquire 建钮时跑一遍，UpdateButton 每次重绘再跑（SetItemButtonTexture/disable
-- --- 会把蒙版/顶点色重新带上）。一律**方法调用**，不写模板按钮属性（污染红线）。
local function FlattenSlotArt(btn)
    if btn.icon then
        pcall(btn.icon.RemoveMaskTexture, btn.icon, btn.IconMask)
        pcall(btn.icon.SetVertexColor, btn.icon, 1, 1, 1, 1)
        pcall(btn.icon.SetTexCoord, btn.icon, 0, 1, 0, 1)
        pcall(btn.icon.SetDrawLayer, btn.icon, "OVERLAY", 7)
        pcall(btn.icon.ClearAllPoints, btn.icon)
        pcall(btn.icon.SetAllPoints, btn.icon, btn)
        pcall(btn.icon.Show, btn.icon)
    end
    if btn.IconMask then
        pcall(btn.IconMask.SetTexture, btn.IconMask, nil)
        pcall(btn.IconMask.SetSize, btn.IconMask, 0.001, 0.001)
        pcall(btn.IconMask.Hide, btn.IconMask)
    end
    if btn.NewItemTexture then
        pcall(btn.NewItemTexture.SetAlpha, btn.NewItemTexture, 0)
        pcall(btn.NewItemTexture.Hide, btn.NewItemTexture)
    end
    if btn.BattlepayItemTexture then
        pcall(btn.BattlepayItemTexture.SetAlpha, btn.BattlepayItemTexture, 0)
        pcall(btn.BattlepayItemTexture.Hide, btn.BattlepayItemTexture)
    end
    if btn.flash then
        pcall(btn.flash.SetAlpha, btn.flash, 0)
        pcall(btn.flash.Hide, btn.flash)
    end
    if btn.NormalTexture then
        pcall(btn.NormalTexture.SetAlpha, btn.NormalTexture, 0)
    end
    if btn.IconBorder then
        pcall(btn.IconBorder.SetAlpha, btn.IconBorder, 0)
    end
    local ht = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if ht then
        pcall(ht.ClearAllPoints, ht)
        pcall(ht.SetAllPoints, ht, btn)
    end
end

-- 收养改写（2026-10-25 案「右键提示被禁用」）：此前手绘按钮 OnClick 调 UseContainerItem，
-- 调用发生在我们的执行栈上，客户端按「谁在调」判越权，弹「MonetUI 已被禁用，因为该功能
-- 只对暴雪的 UI 开放」（与动作条 action 属性同键模型：**调用链上下文**说了算，API 本身
-- 不保护）。改 Ellesmere 收养路线（EllesmereUIBags_Grid.lua:70-128 / RenderButton :167-181）：
-- 壳框 + 模板 ItemButton，OnClick 是暴雪模板自己的（右键使用 / 左键抓取 / 拖放全原生），
-- bag/slot 身份装在 shell/btn 的 ID 上（模板 OnClick 读 self:GetID() + 父壳 GetID()）。
-- 我们的 OnEnter/OnLeave 用 SetScript 覆盖模板自己的（tooltip / 高亮 / 冷却照旧走 rec）。
-- 两个硬边界：模板按钮**战斗中不能出生**（战斗里建的按钮天生被污染，进本第一次右键就
-- FORBIDDEN；EllesmereUIBags_Grid.lua:72-76 同一结论）→ 战斗中返回 nil，FillWindow 跳过
-- 该名额，BAG_UPDATE 在脱战后自然重排；自己的簿记 rec/上次边框全部入 ns:Mark 旁表，
-- 模板按钮上不写自定义字段。
local function AcquireButton(parent)
    if InCombatLockdown() then return nil end

    local shell = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local btn = CreateFrame("ItemButton", nil, shell, "ContainerFrameItemButtonTemplate")
    -- 内缩 1px：壳的 Monet 边框要露出来（按钮全铺会把背板边线整个盖掉）。
    btn:SetPoint("TOPLEFT", shell, "TOPLEFT", 1, -1)
    btn:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -1, 1)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    Mark(shell, "itemBtn", btn)

    -- Monet 视觉层：边框主题/材质压纹走壳（子层不吃鼠标，点击照旧落到按钮）；任务标
    -- '!' 与冷却框挂按钮。图标与计数交给模板本体（SetItemButtonTexture / SetItemButtonCount）。
    Widget:Theme(shell, { thickness = 1, bgAlpha = 0.8 })
    Widget:ButtonMaterial(shell, { alpha = 0, weaveAlpha = 0.25 })

    -- 模板自有美术层压平（建钮时第一遍；每次重绘还会再跑，见 UpdateButton）。
    FlattenSlotArt(btn)

    -- 任务标 '!'：像素字没有 BOLD 标志，**THICKOUTLINE** 就是它的加粗档（实机三版对比：
    -- OUTLINE 太细、叠印糊成一坨、THICKOUTLINE 粗细正好 —— 玩家 2026-10-27 反馈"太细"）。
    local quest = Widget:Font(btn, 12, "pixel", { r = 1, g = 0.82, b = 0 }, "CENTER", nil,
                              "THICKOUTLINE, MONOCHROME")
    quest:SetPoint("CENTER", btn, "CENTER", 0, 0)
    Mark(shell, "questF", quest)

    -- 物品数量：**我们自己画**。模板的 SetItemButtonCount 写的是它自己的 Count 字体串，
    -- 而 FlattenSlotArt 把图标抬到 OVERLAY 7 层 —— 计数被图标整个盖住（玩家 2026-10-27 报的
    -- "数量不显示"）。这里补一条 OVERLAY 9 层的白字，位置与模板默认一致（右下角内缩）。
    local count = Widget:Font(btn, 12, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT", "OVERLAY")
    count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    count:SetDrawLayer("OVERLAY", 9)
    Mark(shell, "countF", count)

    local cd = Widget:Cooldown(btn)
    Mark(shell, "cdF", cd)

    btn:SetScript("OnEnter", function(self)
        Widget:Pulse(self, 1, 1, 1, 0.9)
        local rec = Marked(self, "bagRec")
        if not rec then return end
        local qc = QualityBorder(rec)
        if qc then Widget:Pulse(self, qc.r, qc.g, qc.b, 1) end
        local tip = _G.GameTooltip
        if tip then
            pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")
            pcall(tip.SetBagItem, tip, rec.bag, rec.slot)
            pcall(tip.Show, tip)
            if qc and tip.SetBackdropBorderColor then
                local pr, pg, pb, pa
                if tip.GetBackdropBorderColor then
                    pr, pg, pb, pa = tip:GetBackdropBorderColor()
                end
                Mark(self, "tipPrev", { pr or 0, pg or 0, pb or 0, pa or 0 })
                pcall(tip.SetBackdropBorderColor, tip, qc.r, qc.g, qc.b, 0.6)
            end
        end
    end)
    btn:SetScript("OnLeave", function(self)
        Widget:UnPulse(self)
        local tip = _G.GameTooltip
        if tip then
            local prev = Marked(self, "tipPrev")
            if tip.SetBackdropBorderColor and prev then
                pcall(tip.SetBackdropBorderColor, tip, prev[1], prev[2], prev[3], prev[4])
                Mark(self, "tipPrev", nil)
            end
            pcall(tip.Hide, tip)
        end
    end)

    return shell
end

local function UpdateButton(shell, rec)
    local btn = Marked(shell, "itemBtn")
    if not btn then return end
    Mark(btn, "bagRec", rec)
    local quest = Marked(shell, "questF")
    local count = Marked(shell, "countF")
    local cd = Marked(shell, "cdF")

    if not rec then
        shell:SetID(0)
        btn:SetID(0)
        pcall(SetItemButtonTexture, btn, nil)
        pcall(SetItemButtonCount, btn, 0)
        if quest then quest:SetText("") end
        if count then count:SetText("") end
        if cd then cd:Hide() end
        Widget:SetBorderState(shell, nil)
        btn:Hide() -- 模板按钮出生即隐藏；空槽连钮带壳一起藏
        shell:Hide()
        return
    end

    -- 模板点击链的身份：slot 在按钮上，bag 在父壳上（模板 OnClick 的取法）。
    shell:SetID(rec.bag or 0)
    btn:SetID(rec.slot or 0)
    pcall(SetItemButtonTexture, btn, rec.texture)
    pcall(SetItemButtonCount, btn, (rec.count and rec.count > 1) and rec.count or 0)
    -- 数量：我们自己的白字（模板那条被图标盖住，见 AcquireButton）。1 个不写数字。
    -- 走 Secrets.Number：机密/非数字一律当"读不到"（同一行下面的冷却代码就是这个口径）。
    if count then
        local n = Secrets.Number(rec.count)
        if n and n > 1 then
            count:SetText((n > 999) and "999+" or tostring(n))
        else
            count:SetText("")
        end
    end
    pcall(SetItemButtonDesaturated, btn, rec.locked and true or false)
    -- SetItemButton* 会把蒙版/顶点色/槽底美术重新带上（实机：蒙版回来了就是缺纹理
    -- 斜纹方块），每次重绘后再平一次 —— 全是幂等方法调用，开销可忽略（几十格）。
    FlattenSlotArt(btn)
    -- 去饱和补挂（2026-10-25 实锤：SetItemButtonDesaturated 走 shader 层 SetDesaturated，
    -- 不写顶点色，白顶点覆盖不掉它——此前"被白色顶点色覆盖"是误诊。在这里再补一次，
    -- 防 SetItemButtonTexture 内部重置的时序；幂等）。
    if btn.icon and btn.icon.SetDesaturated then
        pcall(btn.icon.SetDesaturated, btn.icon, rec.locked and true or false)
    end
    shell:SetAlpha(rec.locked and 0.4 or 1)
    if quest then quest:SetText(rec.isQuest and "!" or "") end

    local qc = QualityBorder(rec)
    if qc then Widget:SetBorderState(shell, qc.r, qc.g, qc.b, 1)
    else Widget:SetBorderState(shell, nil) end

    -- GetItemCooldown 的返回值在受限环境里**可能是机密值**（实测报 "bad argument ... SetCooldown:
    -- Secret values are only allowed during untainted execution"）。一律过 Secrets.Number：
    -- 拿不到明文就不画冷却，绝不把机密值拿去比较或塞进 SetCooldown。
    if cd and rec.itemID and C_Container.GetItemCooldown then
        local ok, start, duration, enable = pcall(C_Container.GetItemCooldown, rec.itemID)
        start, duration, enable = Secrets.Number(start), Secrets.Number(duration), Secrets.Number(enable)
        if ok and start and duration and duration > 0 and enable ~= 0 then -- TAINT-OK: 上一行 Secrets.Number 守卫
            cd:Show()
            if not pcall(cd.SetCooldown, cd, start, duration) then cd:Hide() end -- TAINT-OK: Secrets.Number 守卫 + pcall 兜底
        else
            cd:Hide()
        end
    end

    -- 实机父链探针实锤：模板按钮**出生即隐藏**（btn shown=false、icon vis=false 但几何/贴图 ATP 全通
    -- ——那是图标全黑 + tooltip 失联的真凶：按钮藏着，OnEnter 也不会触发）。壳 Show 不带上按钮，
    -- 必须显式 Show；自建按钮（非暴雪生成的受保护按钮），Show/Hide 不受战斗 lockdown 限制。
    btn:Show()
    shell:Show()
end

-- Each category with items gets its own framed, movable window holding a grid; windows the user dragged keep their spot, the rest tile from the saved anchor.

local windows = {}   -- key -> window frame

local function WindowPosition(key)
    return (ns:DB().bags and ns:DB().bags.positions or {})[key]
end

local function SaveWindowPosition(win)
    local db = ns:DB()
    db.bags = db.bags or {}
    db.bags.positions = db.bags.positions or {}
    local point, _, relativePoint, x, y = win:GetPoint()
    db.bags.positions[win.catKey] = {
        point = point, relativePoint = relativePoint,
        x = Math:Round(x, 0), y = Math:Round(y, 0),
    }
end

local function EnsureWindow(key)
    local win = windows[key]
    if win then return win end

    local cat = CATEGORY_BY_KEY[key]
    local name = "MonetUIBagWindow_" .. key
    win = Widget:CreateFrame(name, UIParent, 120, 60)
    win.catKey = key
    Widget:Theme(win, { thickness = 1, bgAlpha = 0.92 })

    win.title = Widget:Font(win, 12, "pixel", "edge", "LEFT")
    win.title:SetPoint("TOPLEFT", win, "TOPLEFT", 18, -5)  -- clear of the TL ornament
    win.title:SetText(cat and cat.label or key)

    Widget:Shadow(win, { size = 6, alpha = 0.5 })
    Widget:Corners(win)
    Widget:Rule(win, win.title)

    win.buttons = {}
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveWindowPosition(self)
    end)

    windows[key] = win
    return win
end

-- TITLE_H covers the label + brush underline; PAD keeps the first item row clear of the stroke.
local TITLE_H = 30
local PAD     = 5

local function FillWindow(win, items)
    local size     = Setting("iconSize")
    local gap      = Setting("gap")
    local columns  = Setting("columns")

    for i, rec in ipairs(items) do
        local shell = win.buttons[i]
        if not shell then
            -- 收养案：战斗中模板按钮不能出生，AcquireButton 返回 nil —— 跳过该名额，
            -- 等脱战后的 BAG_UPDATE 自然重排补齐（Ellesmere 同款 _poolShort 语义）。
            shell = AcquireButton(win)
            if not shell then break end
            win.buttons[i] = shell
        end
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        shell:ClearAllPoints()
        shell:SetSize(size, size)
        shell:SetPoint("TOPLEFT", win, "TOPLEFT",
            PAD + col * (size + gap),
            -(TITLE_H + row * (size + gap)))
        UpdateButton(shell, rec)
    end
    for i = #items + 1, #win.buttons do
        UpdateButton(win.buttons[i], nil)
    end

    local rows = math.max(1, math.ceil(#items / columns))
    local w = PAD * 2 + columns * size + (columns - 1) * gap
    local h = TITLE_H + rows * size + (rows - 1) * gap + PAD
    win:SetSize(w, h)
    win:SetShown(#items > 0)
end

--- Tile the visible, not-yet-dragged windows in category order from the anchor.
--- 首选布局：side="right" —— 分类背包的 RIGHT 对齐 QuestTracker 的 LEFT，
--- 间隔 anchor.x（负数 = QuestTracker 左边），垂直从 anchor.y 起一列堆下来。
--- 如果 anchor.frame 不存在（QuestTracker 模块关了 / 还没初始化），降级到
--- "屏幕中间 x=屏幕宽度-280，顶部 y=-28 往下堆" —— 保证无论如何都不会跑出屏幕。
local function LayoutWindows()
    local anchor = Setting("anchor") or {}
    local spacing = 14

    local base = _G[anchor.frame]
    local sideRight = (anchor.side == "right" and base)

    if sideRight then
        -- 贴 base 左边，垂直一列。
        local x = anchor.x or -18
        local y = anchor.y or -28
        local rowH = 0
        for _, cat in ipairs(CATEGORIES) do
            local win = windows[cat.key]
            if win and win:IsShown() and not WindowPosition(cat.key) then
                local w, h = win:GetWidth(), win:GetHeight()
                win:ClearAllPoints()
                win:SetPoint("TOPRIGHT", base, "TOPLEFT", x, y - rowH)
                rowH = rowH + h + spacing
            end
        end
        return
    end

    -- 降级：QuestTracker 帧不在，屏幕中间一列。
    local UIParent = _G.UIParent
    local screenW = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 1920
    local originX = screenW - 300   -- 屏幕右边往里 300px（约 Minimap 列 + 一点）
    local originY  = anchor.y or -28
    local rowH = 0
    for _, cat in ipairs(CATEGORIES) do
        local win = windows[cat.key]
        if win and win:IsShown() and not WindowPosition(cat.key) then
            local w, h = win:GetWidth(), win:GetHeight()
            win:ClearAllPoints()
            win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", originX, originY - rowH)
            rowH = rowH + h + spacing
        end
    end

    -- 降级布局：说明 QuestTracker 帧还没出生。PollWatch 低频轮询，帧一出来
    -- （锚框是 UIParent，所以每 2s 跑一次）就重新 LayoutWindows 贴回正确位置。
    if not _G.MonetUIQuestTracker then
        if not Marked(_G.UIParent, "bagsRetry") then
            Mark(_G.UIParent, "bagsRetry", true)
            Widget:PollWatch(_G.UIParent, function()
                if _G.MonetUIQuestTracker and shown then
                    LayoutWindows()
                    RestoreDragged()
                end
            end, 2)
        end
    end
end

--- Place windows the user has dragged back where they left them.
local function RestoreDragged()
    for key, win in pairs(windows) do
        local pos = WindowPosition(key)
        if pos and win:IsShown() then
            win:ClearAllPoints()
            win:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT",
                pos.x or 0, pos.y or 0)
        end
    end
end

local function Rebuild(bagType)
    local indexes = (bagType == "bank") and BANK_TABS or BAGS_CARRIED
    if bagType == "bags" and Setting("showReagentBag") then
        indexes = { 0, 1, 2, 3, 4, BAG_REAGENT }
    end

    local groups = Scan(indexes)
    for key, items in pairs(groups) do
        if #items > 0 then
            local win = EnsureWindow(key)
            FillWindow(win, items)
        elseif windows[key] then
            FillWindow(windows[key], {})
        end
    end

    LayoutWindows()
    RestoreDragged()
end

local blizzardHidden = {}

--- 暴雪的背包框：零售 12.x 默认是**合并背包**（ContainerFrameCombinedBags），
--- 老客户端才是 ContainerFrame1..N。两个都得管。
local function BlizzardBagFrames()
    local frames = {}
    for index = 1, 13 do
        local frame = _G["ContainerFrame" .. index]
        if frame then frames[#frames + 1] = frame end
    end
    local combined = _G.ContainerFrameCombinedBags
    if combined then frames[#frames + 1] = combined end
    return frames
end

--- 藏 / 还暴雪的背包框。
--- 还原时必须真的 Show 回来：只把记账抹掉的话，暴雪的框永远留在隐藏状态，
--- 玩家就一个背包都打不开了。
local function HideBlizzardBags(enable)
    for _, frame in ipairs(BlizzardBagFrames()) do
        if enable then
            if frame:IsShown() then
                blizzardHidden[frame] = true
                frame:Hide()
            end
        elseif blizzardHidden[frame] then
            blizzardHidden[frame] = nil
            pcall(frame.Show, frame)
        end
    end
end

--- 暴雪的背包框每次被打开都要拦一道：把我们的分类窗口顶上来，暴雪那条继续藏着。
--- 玩家按 B（或点背包钮）时暴雪走的就是「Show 它的 ContainerFrame」。
---
--- **不再用 ShowWatch 的上升沿**（2026-10-26 实机 bug：连续按 B 会两套背包一起出来）。原因两条：
---   1. `ShowWatch` 是 0.2 秒轮询 —— 两次 B 压在一个间隔里，上升沿直接漏掉；
---   2. 更关键：我们藏掉之后，暴雪那边（合并框 + 5 个包是一串调用）**还会再 Show 回来**，
---      而老实现只在"切换我们自己的窗口"那一下藏过一次，之后没人管 → 我们的窗口开着、暴雪的框也留着。
---
--- 现在的规矩是**持续不变量**：只要模块开着，暴雪那十几个背包框一律不许出现在屏幕上；
--- 每 0.05 秒扫一次，见到就藏，并把"见到"当成玩家按了一次 B（= 切换我们自己的窗口）。
--- 连续调用（一次开背包会 Show 六次）会合并成同一个 tick 里的一次；`TOGGLE_DEBOUNCE` 再把
--- 我们刚藏完那一小段里暴雪的"回光返照"挡掉，免得自己把自己切来切去。
local blizzardDriver, guardAcc, lastToggle = nil, 0, 0
local bankOpen = false          -- 银行窗口开着时，暴雪自己也会开背包框：只藏，不当成"玩家按了 B"
local GUARD_INTERVAL = 0.05
local TOGGLE_DEBOUNCE = 0.12

--- 扫一遍暴雪背包框：见到显示的就藏掉，返回"刚才是不是有东西在显示"。
local function SweepBlizzardBags()
    local opened = false
    for _, frame in ipairs(BlizzardBagFrames()) do
        if frame and frame.IsShown and frame:IsShown() then
            opened = true
            blizzardHidden[frame] = true
            pcall(frame.Hide, frame)
        end
    end
    return opened
end

local function StartBlizzardGuard()
    if blizzardDriver then return end
    blizzardDriver = CreateFrame("Frame")
    blizzardDriver:SetScript("OnUpdate", function(_, elapsed)
        if not ns:IsModuleEnabled("Bags") then return end
        guardAcc = guardAcc + (elapsed or 0)
        if guardAcc < GUARD_INTERVAL then return end
        guardAcc = 0

        local opened = SweepBlizzardBags()
        local now = GetTime()
        if opened and not bankOpen and (now - lastToggle) >= TOGGLE_DEBOUNCE then
            lastToggle = now
            M:Toggle()
        end
    end)
end

local shown = false

--- 打开 / 关闭分类背包。force = true 时只开（给"暴雪背包被打开"那条路用）。
function M:Toggle(force)
    if force == nil then
        shown = not shown
    elseif force then
        shown = true
    else
        shown = false
    end

    if shown then
        HideBlizzardBags(true)
        Rebuild("bags")
    else
        for _, win in pairs(windows) do win:Hide() end
        -- **不要把暴雪的背包框还回来**：那一步会把它 Show 出来，而守卫（0.05s 扫一次）下一拍
        -- 又会把它当成"玩家按了 B"再切一次我们的窗口 —— 自己把自己弹来弹去。
        -- 还框只在模块被关掉时做（SetEnabled(false)）。
    end
end

function M:Initialize()
    if not ns:DB().bags then ns:DB().bags = {} end

    -- 只要模块开着，暴雪的背包框一律不许出现（每 0.05s 扫一次，见 StartBlizzardGuard 的注释）。
    StartBlizzardGuard()

    -- BAG_UPDATE fires often and for every bag: the handler only marks a rebuild, coalesced to one frame by the flag.
    local pending = false
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self)
        if not pending then self:Hide() return end
        pending = false
        if shown then Rebuild("bags") end
    end)

    local function Mark()
        if not shown then return end
        pending = true
        driver:Show()
    end

    EventBus:Register("BAG_UPDATE", Mark)
    EventBus:Register("BAG_UPDATE_DELAYED", Mark)
    EventBus:Register("ITEM_LOCK_CHANGED", Mark)

    -- Bank: only while the bank is open.
    EventBus:Register("BANKFRAME_OPENED", function()
        bankOpen = true
        if Setting("showBank") then
            shown = true
            HideBlizzardBags(true)
            Rebuild("bank")
        end
    end)
    EventBus:Register("BANKFRAME_CLOSED", function()
        bankOpen = false
        -- 银行关了就把背包那几扇窗放回去（原来这里一关就再也不回来了）。
        -- **不再 HideBlizzardBags(false)**：守卫会把它们立刻又藏起来，而"还框"只属于模块关闭。
        if shown then
            Rebuild("bags")
        else
            for _, win in pairs(windows) do win:Hide() end
        end
    end)
end

function M:HandleCommand(rest)
    if rest == "bank" then
        shown = true
        HideBlizzardBags(true)
        Rebuild("bank")
        return true
    end
    self:Toggle()
    return true
end

function M:SetEnabled(enabled)
    if not enabled then
        for _, win in pairs(windows) do win:Hide() end
        shown = false
        -- 模块关掉：把当初藏起来的暴雪背包框还回去（守卫这时会因为 IsModuleEnabled 为假而停手）
        HideBlizzardBags(false)
    else
        StartBlizzardGuard()
    end
end

ns:Register("Bags", M)
