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
local Skin     = ns.Skin

--- 战斗中为真。**不要只用 InCombatLockdown**：登录 / 重载正好落在战斗里时，它有一小段时间
--- 返回 false（客户端还没把受限状态铺开），于是"模板按钮不能在战斗里出生"这条就被绕过了。
--- 实机症状（玩家 2026-10-31 报）：战斗里 /reload 之后背包窗口只有标题、没有物品图标。
--- 用 UnitAffectingCombat("player") 兜住这一段（1.60 有，返回普通 bool）。
--- 注意位置：必须写在 `local Secrets = ns.Secrets` **之后** —— 第一版放在它前面，
--- 里面的 `Secrets` 被当成全局（nil），于是每次调用都抛 "attempt to index global 'Secrets'"，
--- 物品按钮一个都建不出来（外壳 0 个、暴雪背包也停不了车）。
local function InCombat()
    local ok, locked = pcall(InCombatLockdown)
    if ok and locked then return true end
    local ok2, fighting = pcall(UnitAffectingCombat, "player")
    if ok2 then return Secrets.Bool(fighting, false) end
    return false
end

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

-- ============================================================================
-- 传送类物品（炉石 / 传送卷轴 / 传送器 / 传送披风戒指 / 虫洞…）
-- ============================================================================
-- classID 五花八门（消耗品 / 玩具 / 装备），推不出来，只能匹配名单。
-- 两条路都留：
--   * `TRAVEL_ITEMS[itemID]` —— 精确命中，人工维护；
--   * `TRAVEL_NAME_PATTERNS` —— 名字模式兜底（本客户端是中文，模式稳定；
--     物品 ID 会随资料片变，名字不会）。命中 ID 就不过名字。
-- ⚠️ 待实机校对：这组模式是按"传送类应该叫什么"写的，没有逐条对着 1.60 物品库核过。
local TRAVEL_ITEMS = {}                       -- [itemID] = true
local TRAVEL_NAME_PATTERNS = { "炉石", "传送", "虫洞", "传送门", "回城", "召集" }

local function IsTravelItem(it)
    if it.itemID and TRAVEL_ITEMS[it.itemID] then return true end
    -- 名字可能是**机密串**（受限环境的 GetItemInfo 同理）：机密串上
    -- `== ""` / `:find()` 都会抛，所以先过 Secrets.IsSecret，判不出来就当不匹配。
    local name = it.name
    if type(name) ~= "string" or Secrets.IsSecret(name) or name == "" then return false end
    for i = 1, #TRAVEL_NAME_PATTERNS do
        if name:find(TRAVEL_NAME_PATTERNS[i], 1, true) then return true end
    end
    return false
end

-- ============================================================================
-- 分类规则（2026-11-01 重写，判定链口径照 RealUI_Inventory）
-- ============================================================================
--
-- 两个序号，**必须解耦**（RealUI `Filters.lua:95-124` 的教训）：
--   * `rank`  决定**归属**：一条物品只归 rank 最小的那条。rank 越小越优先。
--   * `order` 决定**窗口显示顺序**。以后允许玩家拖换窗口顺序时，只动 order，
--     不动 rank —— 否则"改显示顺序"会连带改分类结果。
--
-- 为什么不用"第一条命中即归属"（本文件原来的写法）：那时分类结果**依赖列表顺序**，
-- 而顺序同时在表达"哪个窗口在上"，两件事被塞进一个序号里。后果是任务用的消耗品
-- 会被 `use` 抢走（`use` 排在 `quest` 前面），装备方案里的装备也压不过 `gear`。
--
-- 判定优先级（rank 由小到大）：
--   垃圾 0 > 新物品 1 > 任务 3 > 传送 4 > 消耗品 10 > 套装 20 > 战团绑 21 >
--   装备 22 > 容器 23 > 材料 30 > 收藏 40 > 心能 50 > 其他 99
--
local CATEGORIES = {
    -- 灰色**且有卖价**（无卖价的灰装不混进可卖垃圾，与 RealUI:Filters.lua:251 同口径）
    { key = "junk",  label = "垃圾",   rank = 0,  order = 1,
      match = function(it) return it.quality == Q_POOR and (it.sellPrice or 0) > 0 end },

    -- 新物品：C_NewItems 的标记只在背包格子上存在，不能从 itemID 推
    { key = "new",   label = "新物品", rank = 1,  order = 2,
      match = function(it) return it.isNew == true end },

    -- 任务优先于消耗品/材料：任务要交的东西多数也是消耗品或材料（旧版的顺序把它分错了）
    { key = "quest", label = "任务",   rank = 3,  order = 3,
      match = function(it) return it.isQuest or it.classID == IC.Questitem end },

    -- 传送类：炉石 / 传送卷轴 / 传送器 / 传送披风戒指等。这类物品的 classID 五花八门
    -- （消耗品 / 玩具 / 装备），从 classID 推不出来，只能靠白名单 + 名字模式。
    { key = "travel", label = "传送",  rank = 4,  order = 4,
      match = function(it) return IsTravelItem(it) end },

    { key = "use",   label = "消耗品", rank = 10, order = 5,
      match = function(it) return it.classID == IC.Consumable or it.classID == IC.ItemEnhancement end },

    -- 装备方案里的装备：**这一类暂不做**。RealUI 用
    -- `C_EquipmentSet.GetItemLocations` 拿位置后交给 `EquipmentManager_GetLocationData`
    -- 解码成 bag/slot（`FilterData.lua:13-39`，按格子而不是按 itemID 记，同名物品放别处不算）。
    -- 1.60 快照里**没有** `EquipmentManager_GetLocationData`（api-lookup 实测无匹配），
    -- 解不开位置就只能按 itemID 匹配 —— 那会把背包里的同名装备误判成套装件。
    -- 所以等有可靠解码方式再加，宁可少一个窗口。
    -- 战团绑定（12.x 的"装备前战团绑定"）：能寄给小号、不能卖
    { key = "warbound", label = "战团绑", rank = 21, order = 7,
      match = function(it) return it.isWarboundUntilEquip == true end },

    -- 装备：按**装备位**判，不按 classID —— 职业工具 / 可装备法术 / 圣物都在这条路上
    { key = "gear",  label = "装备",   rank = 22, order = 8,
      match = function(it) return it.isEquippable == true end },

    -- 空背包 / 箭袋这类"容器"本身
    { key = "containers", label = "容器", rank = 23, order = 9,
      match = function(it) return it.isContainer == true end },

    { key = "goods", label = "材料",   rank = 30, order = 10,
      match = function(it) return it.classID == IC.Tradegoods or it.classID == IC.Reagent end },

    { key = "pets",  label = "收藏",   rank = 40, order = 11,
      match = function(it)
          return it.classID == IC.Battlepet
              or (it.classID == IC.Miscellaneous and (it.subClassID == 2 or it.subClassID == 5))
      end },

    { key = "anima", label = "心能",   rank = 50, order = 12,
      match = function(it) return it.isAnima == true end },

    { key = "other", label = "其他",   rank = 99, order = 13,
      match = function() return true end },
}

local CATEGORY_BY_KEY = {}
for _, cat in ipairs(CATEGORIES) do CATEGORY_BY_KEY[cat.key] = cat end

--- 「剩余空间」：一张**伪分类**（玩家 2026-11-03 要的那一行空格子）。
--- 故意不写进 `CATEGORIES`：那张是**判定表**，`AssignCategory` 会逐条 `match`，
--- 混进去等于"所有物品都归剩余空间"（而且它没有 match 函数，pcall 直接报错吞掉）。
--- 它只借窗口机制：有 label 就有一扇窗、`order` 最大就排在最后、`LayoutWindows` 一列堆下来，
--- 不必为它另写一套建窗/排版/存档的代码。
local FREE_CAT = { key = "free", label = "剩余空间", order = 100 }
CATEGORY_BY_KEY[FREE_CAT.key] = FREE_CAT

--- 显示顺序：按 `order` 排，**和分类优先级（rank）无关**。
--- 排窗口、列标题一律走这张表，不要用 `CATEGORIES` 的数组顺序 ——
--- 那张是判定表，动它的顺序等于动归属（RealUI 把两件事分开的全部意义就在这）。
local ORDERED = {}
for _, cat in ipairs(CATEGORIES) do ORDERED[#ORDERED + 1] = cat end
ORDERED[#ORDERED + 1] = FREE_CAT
table.sort(ORDERED, function(a, b) return a.order < b.order end)

--- 装备位三段判定（照 RealUI:Slots.lua:138-151）：容器 / 箭袋 = 容器；
--- NonEquip = 其它；**其余全是装备** —— 职业工具 / 可装备法术 / 圣物都在这条路上。
--- 旧版用 `classID == Armor or Weapon`，把职业工具和圣物归到了"其他"。
---
--- **用数字枚举，不要赌 `itemEquipLoc` 的字符串名**（实机 2026-11-01）：
--- 这台客户端不可装备物品返回的是 `INVTYPE_NON_EQUIP_IGNORE`，不是 `INVTYPE_NON_EQUIP`，
--- 字符串精确匹配会把炉石 / 配方 / 材料全判成装备（当时装备窗 183 高、"其他"空着）。
--- 数字侧是 `Enum.InventoryType`，RealUI 也正是这么判的。
local function EquipKind(invType)
    if type(invType) ~= "number" or Secrets.IsSecret(invType) then return "other" end
    if invType == Enum.InventoryType.IndexNonEquipType then return "other" end
    if invType == Enum.InventoryType.IndexBagType or invType == Enum.InventoryType.IndexQuiverType then
        return "container"
    end
    return "equipment"
end

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

    -- 新物品：只能从格子上读，不能从 itemID 推（RealUI:Bags.lua:1254 同口径）。
    if C_NewItems and C_NewItems.IsNewItem then
        local ok, isNew = pcall(C_NewItems.IsNewItem, bag, slot)
        if ok then it.isNew = isNew and true or false end
    end

    -- 装备位三段判定：**用数字枚举**（`C_Item.GetItemInventoryTypeByID`），
    -- 不要用 `it.equipLoc` 的字符串名 —— 本客户端不可装备物品返回的是
    -- `INVTYPE_NON_EQUIP_IGNORE`，字符串精确匹配会把炉石/配方/材料全判成装备
    -- （实机 2026-11-01：装备窗 183 高、"其他"空着）。拿不到就退回 "other"。
    local invType
    if C_Item and C_Item.GetItemInventoryTypeByID and it.itemID then
        local okInv, t = pcall(C_Item.GetItemInventoryTypeByID, it.itemID)
        if okInv then invType = t end
    end
    local kind = EquipKind(invType)
    it.equipKind     = kind
    it.isEquippable  = (kind == "equipment")
    it.isContainer   = (kind == "container")

    -- 12.x「装备前战团绑定」：能寄给小号、不能卖，值得单独一眼看到
    if C_Item and C_Item.IsItemBindToAccountUntilEquip and it.link then
        local ok, w = pcall(C_Item.IsItemBindToAccountUntilEquip, it.link)
        if ok then it.isWarboundUntilEquip = w and true or false end
    end

    -- 心能物品（暗影国度遗留，1.60 上是否还有语义未知；有 API 就跟着走，没有就不建这一档）
    if C_Item and C_Item.IsAnimaItemByID and it.itemID then
        local ok, a = pcall(C_Item.IsAnimaItemByID, it.itemID)
        if ok then it.isAnima = a and true or false end
    end

    return it
end

--- 归属判定：**rank 最小的赢**，不是"列表里第一条命中"。
--- 好处是两个序号解耦：`rank` 只表达优先级，`order` 只表达窗口显示顺序，
--- 调显示顺序不会改分类结果（RealUI:Filters.lua:115-124 的口径）。
local function AssignCategory(it)
    local bestKey, bestRank = "other", math.huge
    for i = 1, #CATEGORIES do
        local cat = CATEGORIES[i]
        if cat.rank < bestRank then
            local ok, hit = pcall(cat.match, it)
            if ok and hit then
                bestKey, bestRank = cat.key, cat.rank
                if bestRank == 0 then break end   -- 垃圾已是最高优先，不用再比
            end
        end
    end
    return bestKey
end

--- 排序用的标量：**机密值一律退回默认值**，绝不拿它去比较（AGENTS：战斗里
--- 机密串/数字上的 `==`、`<` 会抛 `attempt to compare ... a secret value`）。
--- 品质 / 物品等级 / 名字都可能在受限环境变成机密（GetItemInfo 的返回值同理）。
local function Sortable(value, fallback)
    if value == nil then return fallback end
    if Secrets.IsSecret(value) then return fallback end
    return value
end

--- 袋内排序（照 RealUI:Bags.lua:71-111 的口径，但砍掉装备位那档：我们已经把装备分出去了）：
--- 品质降序 → 物品等级降序 → 名字升序 → 堆叠数降序。
local function SortItems(list)
    table.sort(list, function(a, b)
        local qa, qb = Sortable(a.quality, 0), Sortable(b.quality, 0)
        if qa ~= qb then return qa > qb end
        local ia, ib = Sortable(a.ilvl, 0), Sortable(b.ilvl, 0)
        if ia ~= ib then return ia > ib end
        local na, nb = Sortable(a.name, ""), Sortable(b.name, "")
        if na ~= nb then return na < nb end
        local ida, idb = Sortable(a.itemID, 0), Sortable(b.itemID, 0)
        if ida ~= idb then return ida < idb end
        return (Sortable(a.count, 1)) > (Sortable(b.count, 1))
    end)
end

--- Scan a set of bag indexes into { categoryKey = { item, ... } },
--- plus the number of **empty** slots in that same set (the 「剩余空间」 line reads it).
local function Scan(bagIndexes)
    local groups = {}
    for _, cat in ipairs(CATEGORIES) do groups[cat.key] = {} end

    local free = 0
    for _, bag in ipairs(bagIndexes) do
        local num = Secrets.Number(C_Container.GetContainerNumSlots(bag))
        if num and num > 0 then
            for slot = 1, num do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    local it = BuildItem(bag, slot, info)
                    local key = AssignCategory(it)
                    groups[key][#groups[key] + 1] = it
                else
                    -- 空槽：`info` 是空表（或 nil）。
                    -- 注意 `info.itemID` 这里只做**真值测试**（AGENTS：真值测试对机密值稳定），
                    -- 机密槽会走上面那条分支当"有物品"，不会虚报成空格。
                    free = free + 1
                end
            end
        end
    end

    for _, cat in ipairs(CATEGORIES) do
        local list = groups[cat.key]
        if #list > 1 then SortItems(list) end
    end

    return groups, free
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
    -- 实现已上移 Utils/Skin.lua 的 Skin:FlattenSlotArt（商人 / 交易窗同一份）。
    Skin:FlattenSlotArt(btn)
    -- 玩家 2026-11-02：背包图标放大一点 + 裁切到合适尺寸 —— 统一 8% 裁切档
    -- （与动作条 / 商人 / 交易一致）：暴雪自带的描边圈消失，同框内容放大 ~17%。
    -- CropIcon 的轮询账本每 0.5s 重压 texcoord，物品换贴图不会退回全幅。
    if btn and btn.icon then
        Skin:CropIcon(btn.icon, 0.08, 0.92, 0.08, 0.92)
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
    if InCombat() then return nil end

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
--- 我们的分类窗口开没开。**前向声明**在这里：`LayoutWindows`（下面）的补扫闭包要读它，
--- 而真正的赋值语句在文件后半「暴雪背包框」那一节 —— 声明写在它后面，Lua 在编译期就把它
--- 当**全局 nil**（AGENTS：静态闸门抓不到"引用了还没声明的 local"），那条补扫永远不触发。
local shown

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
    win.slots   = {}   -- 「剩余空间」那行的空格子池（只有 free 窗用得到）
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

--- 一格"空的"背包格子：只有背板、描边和斜纹，没有图标、不接鼠标。
--- 衬底走 Widget:ButtonMaterial —— **和动作条空槽是同一份**（`monet_stripe_weave` 平铺在
--- BACKGROUND、ADD 混合、weaveAlpha 0.25，1 texel = 1 物理像素所以相邻格子相位连续）；
--- 描边与底色走 Widget:Theme，参数照抄 AcquireButton 给物品壳的那两行，
--- 这样"剩余空间"那一行的格子和上面装东西的格子看上去是同一种东西。
--- **不建 ItemButton**：纯装饰，因此没有"模板按钮战斗中不能出生"那条限制，
--- 战斗中重扫也照样能画（物品窗在战斗里缺格子是已知代价，这一行不该跟着缺）。
local function AcquireFreeSlot(parent)
    local shell = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Widget:Theme(shell, { thickness = 1, bgAlpha = 0.8 })
    Widget:ButtonMaterial(shell, { alpha = 0, weaveAlpha = 0.25 })

    -- "+N" 写在格子正中（物品计数在右下角，那一档留给数字本身；这里没有图标可让位）。
    local mark = Widget:Font(shell, 12, "pixel", "neutral", "CENTER", "OVERLAY",
                             "THICKOUTLINE, MONOCHROME")
    mark:SetPoint("CENTER", shell, "CENTER", 0, 0)
    mark:SetText("")
    Mark(shell, "markF", mark)
    return shell
end

--- 画「剩余空间」：free = 这一趟扫描里的空槽总数。
--- 规则（玩家 2026-11-03 定）：**最多一行**（`columns` 格，尺寸同物品图标）。
---   free <= columns → 剩几个画几个，一格一个空格；
---   free >  columns → 前面照画，最后一格写 "+N"，N = 还没被画出来的那几个。
--- 两种情况合起来是同一个算式：`draw = min(free, columns)`、`extra = free - draw + 1`
--- （最后一格"代表"几个），`extra > 1` 才写字 —— 所以刚好一行的时候不会看到多余的 "+1"。
local function FillFreeWindow(win, free)
    local size    = Setting("iconSize")
    local gap     = Setting("gap")
    local columns = Setting("columns")

    free = math.max(tonumber(free) or 0, 0)
    local draw  = math.min(free, columns)
    local extra = draw > 0 and (free - draw + 1) or 0

    for i = 1, draw do
        local shell = win.slots[i]
        if not shell then
            shell = AcquireFreeSlot(win)
            win.slots[i] = shell
        end
        shell:ClearAllPoints()
        shell:SetSize(size, size)
        shell:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + (i - 1) * (size + gap), -TITLE_H)
        local mark = Marked(shell, "markF")
        if mark then
            -- extra 是我们自己算出来的普通数字，拼接安全（不是从游戏读的值）。
            mark:SetText((i == draw and extra > 1) and ("+" .. tostring(extra)) or "")
        end
        shell:Show()
    end
    for i = draw + 1, #win.slots do
        win.slots[i]:Hide()
    end

    -- 宽度跟着实际画的格数收（画 3 格就不要留 10 格的空壳）；满一行时和别的分类窗完全等宽。
    local w = PAD * 2 + draw * size + math.max(0, draw - 1) * gap
    win:SetSize(w, TITLE_H + size + PAD)
    win:SetShown(draw > 0)
end

--- Place windows the user has dragged back where they left them.
--- 定义在 LayoutWindows **之前**：LayoutWindows 的降级补扫闭包要调用它，
--- 而闭包在文本里早于原来的定义位置 —— 那样会解析成全局 nil，
--- 报错还会被 PollWatch 的 pcall 吞掉（review 2026-10-29 H5）。
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
        for _, cat in ipairs(ORDERED) do
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
    for _, cat in ipairs(ORDERED) do
        local win = windows[cat.key]
        if win and win:IsShown() and not WindowPosition(cat.key) then
            local w, h = win:GetWidth(), win:GetHeight()
            win:ClearAllPoints()
            win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", originX, originY - rowH)
            rowH = rowH + h + spacing
        end
    end

    -- 降级布局：说明 QuestTracker 帧还没出生。PollWatch 低频轮询，帧一出来
    -- 就把窗口贴回正确位置，然后**自我注销** —— 一次性补扫，不该永久空转。
    if not _G.MonetUIQuestTracker then
        if not Marked(_G.UIParent, "bagsRetry") then
            Mark(_G.UIParent, "bagsRetry", true)
            local retry
            retry = function()
                if _G.MonetUIQuestTracker and shown then
                    Widget:Unwatch(_G.UIParent, retry)
                    Mark(_G.UIParent, "bagsRetry", nil)
                    LayoutWindows()
                    RestoreDragged()
                end
            end
            Widget:PollWatch(_G.UIParent, retry, 2)
        end
    end
end

local function Rebuild(bagType)
    local indexes = (bagType == "bank") and BANK_TABS or BAGS_CARRIED
    if bagType == "bags" and Setting("showReagentBag") then
        indexes = { 0, 1, 2, 3, 4, BAG_REAGENT }
    end

    local groups, free = Scan(indexes)
    for key, items in pairs(groups) do
        if #items > 0 then
            local win = EnsureWindow(key)
            FillWindow(win, items)
        elseif windows[key] then
            FillWindow(windows[key], {})
        end
    end
    -- 「剩余空间」排在最后（FREE_CAT 在 ORDERED 里 order 最大，LayoutWindows 自然把它堆在末尾）。
    FillFreeWindow(EnsureWindow(FREE_CAT.key), free)

    LayoutWindows()
    RestoreDragged()
end

-- ---- 暴雪背包框：预停车（2026-10-28 定案）---------------------------------------
-- 本客户端实机探针（2026-10-28）：按 B 开背包，BAG_OPEN / BAG_CLOSED **不发**，
-- 连 BAG_UPDATE 都不发 —— "开背包"这件事在事件层是静默的，IsShown 边沿是唯一信号。
-- 旧方案（守卫见到显示的就 Hide()）两个代价：Show → Hide 之间有可见闪帧；暴雪自己的
-- 更新逻辑会再 Show 回来，跟守卫打拉锯（"两套同屏"的老病灶）。
-- 新方案：模块开着就**常驻停车** —— alpha 0 + 全子树禁鼠标。暴雪的 Show 照样成功
-- （IsShown 为真，我们拿它当边沿信号），但屏幕上永远看不见、鼠标事件穿过去；
-- 没有 Hide 这一刀，拉锯战不存在。SetAlpha / EnableMouse 不是受保护调用（AGENTS.md
-- 藏暴雪 HUD 的正路），战斗中也可用；不往框上写字段，记账用弱键旁表（ns:Mark 同款）。
local parked = setmetatable({}, { __mode = "k" })
local bagsVisualOpen = false    -- 上次扫描：暴雪框是否有任何一个在显示（边沿检测）
shown = false                   -- 我们的分类窗口开没开（**local 声明在窗口那一节**，见上文前向声明）

--- 战斗中为真。暴雪背包框里有受保护子按钮，战斗里对它们 EnableMouse 会被拦
--- （QuestTracker 2026-10-26 实机记录过同类 ×29）；鼠标这一半要跳战斗、脱战补做。
--- 判定用文件顶部的 InCombat()（InCombatLockdown 在登录当拍可能还是旧的 false）。

--- 暴雪的背包框：零售 12.x 默认是**合并背包**（ContainerFrameCombinedBags），
--- 老客户端才是 ContainerFrame1..N。两个都得管；BackpackTokenFrame 跟着背包一起出现。
local function BlizzardBagFrames()
    local frames = {}
    for index = 1, 13 do
        local frame = _G["ContainerFrame" .. index]
        if frame then frames[#frames + 1] = frame end
    end
    local combined = _G.ContainerFrameCombinedBags
    if combined then frames[#frames + 1] = combined end
    local tokens = _G.BackpackTokenFrame
    if tokens then frames[#frames + 1] = tokens end
    return frames
end

--- 收集 frame 及其全部 Frame 子代（ItemButton 等收鼠标事件的东西都在里面；
--- alpha 0 的框其子框照样收 OnEnter，所以必须整棵树关）。
local function CollectTree(frame, into)
    into[#into + 1] = frame
    local kids = { frame:GetChildren() }
    for _, child in ipairs(kids) do
        if child and child.GetChildren then CollectTree(child, into) end
    end
    return into
end

--- 停车 / 取回。取回按记账把鼠标还回去、alpha 拉回 1（模块关闭后玩家还要用原生背包）。
local function ParkBlizzardBags(park)
    -- 停车要整树关鼠标（受保护子按钮）—— 战斗中这一半做不了，排队到脱战再补。
    -- alpha 0 本身不受保护，但一起跳过更简单，且停车只在装载 / 脱战时发生。
    if park and InCombat() then
        ns:AfterCombat("bags-park", function()
            -- **脱战当拍别急着判断**：PLAYER_REGEN_ENABLED 派发时 InCombatLockdown /
            -- UnitAffectingCombat 可能还是旧值 true（HANDOFF 3.26 的老毛病），于是这里会
            -- 二次延后到"下一次脱战" —— 实际上等于永远不 park，玩家按 B 会看到暴雪背包
            -- 和我们那套同屏。换个新 tick 再判断，标志这时才是新的。
            C_Timer.After(0, function() ParkBlizzardBags(true) end)
        end)
        return
    end
    for _, frame in ipairs(BlizzardBagFrames()) do
        if frame then
            if park then
                if not parked[frame] then
                    local rec = { mouse = {}, mouseSet = {} }
                    for _, f in ipairs(CollectTree(frame, {})) do
                        if f.EnableMouse and f.IsMouseEnabled and f:IsMouseEnabled() then
                            pcall(f.EnableMouse, f, false)
                            rec.mouseSet[f] = true
                            rec.mouse[#rec.mouse + 1] = f
                        end
                    end
                    parked[frame] = rec
                end
                pcall(frame.SetAlpha, frame, 0)
            elseif parked[frame] then
                local rec = parked[frame]
                parked[frame] = nil
                for _, f in ipairs(rec.mouse) do pcall(f.EnableMouse, f, true) end
                pcall(frame.SetAlpha, frame, 1)
            end
        end
    end
end

--- 扫一遍暴雪背包框：把漂移的停车状态按回去（暴雪重设 alpha / 重开鼠标就补一刀），
--- 返回"是否有框在显示"。只读 IsShown / GetAlpha，**不 Hide** —— 显示状态归暴雪管，我们只看。
local blizzardDriver, guardAcc, lastToggle = nil, 0, 0
local bankOpen = false          -- 银行开合也会 Show/Hide 背包框：那段时间的边沿让给银行路径
local GUARD_INTERVAL = 0.2
local TOGGLE_DEBOUNCE = 0.12

-- 停车扫查的复用工作台（避免每拍建表）。
local sweepScratch = {}

local function SweepBlizzardBags(allowMouse)
    local anyShown = false
    for _, frame in ipairs(BlizzardBagFrames()) do
        if frame and frame.IsShown then
            local isShown = frame:IsShown()
            if isShown then anyShown = true end
            local rec = parked[frame]
            if rec then
                if frame.GetAlpha and frame:GetAlpha() ~= 0 then
                    pcall(frame.SetAlpha, frame, 0)
                end
                -- 晚生/重开的子框（开背包时暴雪现建 ItemButton）鼠标默认是开的：
                -- alpha 沿树继承所以看不见，但鼠标状态不继承 → tooltip 会冒出来。
                -- 只在框显示着时才需要管（不显示收不到鼠标事件），整树补禁。
                if isShown and allowMouse then
                    for i = #sweepScratch, 1, -1 do sweepScratch[i] = nil end
                    CollectTree(frame, sweepScratch)
                    for _, f in ipairs(sweepScratch) do
                        if f.EnableMouse and f.IsMouseEnabled and f:IsMouseEnabled() then
                            pcall(f.EnableMouse, f, false)
                            if not rec.mouseSet[f] then
                                rec.mouseSet[f] = true
                                rec.mouse[#rec.mouse + 1] = f
                            end
                        end
                    end
                end
            end
        end
    end
    return anyShown
end

--- 守卫 = 边沿检测器：暴雪框"从无到有" = 玩家按了 B（开我们的窗），"从有到无" =
--- 玩家又按了 B（关我们的窗）。一次开背包暴雪会 Show 好几个框，边沿天然合并成一次；
--- TOGGLE_DEBOUNCE 挡掉重载瞬间的抖动。**不再 toggle**：开/关都显式，免得"回光返照"
--- 把我们自己切来切去（2026-10-26 实机 bug 的根）。
local function StartBlizzardGuard()
    if blizzardDriver then return end
    blizzardDriver = CreateFrame("Frame")
    blizzardDriver:SetScript("OnUpdate", function(_, elapsed)
        if not ns:IsModuleEnabled("Bags") then return end
        guardAcc = guardAcc + (elapsed or 0)
        if guardAcc < GUARD_INTERVAL then return end
        guardAcc = 0

        local anyShown = SweepBlizzardBags(not InCombat())
        if anyShown == bagsVisualOpen then return end
        bagsVisualOpen = anyShown
        local now = GetTime()
        if bankOpen or (now - lastToggle) < TOGGLE_DEBOUNCE then return end
        lastToggle = now
        if anyShown then
            if not shown then M:Toggle(true) end
        elseif shown then
            M:Toggle(false)
        end
    end)
    -- 脱战后补一刀：战斗中跳过的鼠标屏蔽在这里补做（受保护子按钮在战斗里动不得）。
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if not ns:IsModuleEnabled("Bags") then return end
        SweepBlizzardBags(true)
    end)
end

-- ---- 更新触发（2026-10-28 补强）------------------------------------------------
-- 玩家报"背包物品更新不及时"：本客户端 BAG_UPDATE 覆盖不全（邮件取件 / 商人购买后
-- 窗口停在旧内容，要重开背包才更新）。三层保险：
--   ① 事件（Initialize 里注册；EventBus 对本客户端不认识的事件名会静默跳过，零成本）；
--   ② 公开刷新入口 M:Refresh()（其它模块 / /mui bags refresh 显式触发）；
--   ③ 开窗期间的签名轮询：每 0.5s 对一次"槽位=itemID x 数量"指纹，变了才重建 ——
--      "及时"最终不赌事件派发（本客户端事件缺口已经不止一次：PLAYER_REGEN_* 当拍
--      标志是旧值、事件不补发，见 HANDOFF 3.26）。
local POLL_INTERVAL = 0.5

--- 轻量指纹：一组背包槽位的 itemID+数量串。只读数量字段，不碰贴图/链接。
--- 每个袋子还要记**自己的格数**（`bag<N>=<格数>`）：买了新背包时新格子是空的，
--- 物品串一个都不变，只靠物品指纹就永远不重扫 —— 而「剩余空间」那一行的数字正是
--- 由格数决定的，必须让它动一下。
local function BagSignature(indexes)
    local parts = {}
    for _, bag in ipairs(indexes) do
        local num = Secrets.Number(C_Container.GetContainerNumSlots(bag))
        if num and num > 0 then
            parts[#parts + 1] = "bag" .. tostring(bag) .. "=" .. tostring(num)
            for slot = 1, num do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    parts[#parts + 1] = bag .. ":" .. slot .. "="
                        .. tostring(info.itemID) .. "x" .. tostring(info.stackCount)
                end
            end
        end
    end
    return table.concat(parts, ",")
end

local pollDriver, pollAcc, bagSig, bankSig

-- 战斗里 reload 的收尾：模板物品按钮不能出生（AcquireButton 返回 nil），窗口只剩标题；
-- 而签名轮询只认"背包内容指纹"——空窗口和满窗口的指纹一样，所以脱战后**不会**自己补。
-- 这里强制把指纹清掉并重建一次（玩家 2026-10-31 报的那条就是这个缺口）。
EventBus:Register("PLAYER_REGEN_ENABLED", function()
    if not ns:IsModuleEnabled("Bags") then return end
    bagSig, bankSig = nil, nil
    if shown then Rebuild("bags") end
    if bankOpen then Rebuild("bank") end
end)

local function StartPolling()
    bagSig, bankSig = nil, nil      -- 重开窗口先强制对一次
    if not pollDriver then
        pollDriver = CreateFrame("Frame")
        pollDriver:SetScript("OnUpdate", function(self, elapsed)
            if not shown then self:Hide() return end
            pollAcc = (pollAcc or 0) + (elapsed or 0)
            if pollAcc < POLL_INTERVAL then return end
            pollAcc = 0
            local indexes = Setting("showReagentBag")
                and { 0, 1, 2, 3, 4, BAG_REAGENT } or BAGS_CARRIED
            local sig = BagSignature(indexes)
            if sig ~= bagSig then
                bagSig = sig
                Rebuild("bags")
            end
            if bankOpen then
                local bSig = BagSignature(BANK_TABS)
                if bSig ~= bankSig then
                    bankSig = bSig
                    Rebuild("bank")
                end
            end
        end)
    end
    pollDriver:Show()
end

local function StopPolling()
    if pollDriver then pollDriver:Hide() end
    bagSig, bankSig = nil, nil
end

--- 打开 / 关闭分类背包。force = true / false 显式开关（给守卫边沿那条路用，不 toggle）。
function M:Toggle(force)
    if force == nil then
        shown = not shown
    elseif force then
        shown = true
    else
        shown = false
    end

    if shown then
        -- 暴雪框已在 Initialize 停车（alpha 0 + 禁鼠标），这里不用再藏；
        -- 就算它此刻被 Show 着（边沿路径来的），停车状态让它在屏幕上不可见。
        Rebuild("bags")
        StartPolling()
    else
        StopPolling()
        for _, win in pairs(windows) do win:Hide() end
        -- 暴雪框的显隐归暴雪管（停车不碰它），关我们的窗就够了。
    end
end

function M:Initialize()
    if not ns:DB().bags then ns:DB().bags = {} end

    -- 只要模块开着，暴雪的背包框一律常驻停车（alpha 0 + 全子树禁鼠标，见上文的模型注释）。
    ParkBlizzardBags(true)

    -- **分类背包不要默认打开**（玩家 2026-10-31 报：每次进游戏都是开着的）。
    -- 原因：客户端会把"上次退出时开着的"暴雪背包在登录后恢复成 shown，守卫的边沿检测就把它
    -- 当成"玩家按了 B"，直接把我们的窗口弹出来。这里登录时先把它们关掉（停车让它们本来也
    -- 不可见，这一步是为了让**状态**也回到关），再把守卫基线设成"关" —— 这样第一次按 B
    -- 才是真正的"从关到开"的边沿。
    -- 战斗中不动暴雪背包（父框里是受保护子按钮）：robust 见 bagsVisualOpen 那行。
    local restoredOpen = false
    for _, frame in ipairs(BlizzardBagFrames()) do
        if frame and frame.IsShown and frame:IsShown() then
            restoredOpen = true
            if not InCombat() then pcall(frame.Hide, frame) end
        end
    end
    -- 关掉了 → 基线"关"（第一次 B 是边沿）；战斗里关不掉 → 基线"开"，避免一登录就弹我们的窗。
    bagsVisualOpen = restoredOpen and InCombat() or false
    StartBlizzardGuard()

    -- BAG_UPDATE fires often and for every bag: the handler only marks a rebuild, coalesced to one frame by the flag.
    -- 资源口径（2026-10-28 探针实测）：帧级合并比 0.1s timer 更紧（突发一帧只重建一次，
    -- 空闲时驱动器自 Hide 零开销）；CURSOR_CHANGED 本客户端 ×298 高频刷，挂上它等于
    -- 窗口开着时每次光标变化都全量重建 —— 不注册，兜底交给签名轮询。
    local pending, pendingBank = false, false
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self)
        if not pending and not pendingBank then self:Hide() return end
        local doBags, doBank = pending, pendingBank
        pending, pendingBank = false, false
        if doBags and shown then Rebuild("bags") end
        if doBank and shown and bankOpen then Rebuild("bank") end
    end)

    local function Mark()
        if not shown then return end
        pending = true
        driver:Show()
    end

    local function MarkBank()
        if not shown or not bankOpen then return end
        pendingBank = true
        driver:Show()
    end

    -- ① 事件层：BAG_UPDATE 是主路径，再补几条本客户端可能单独发的（EventBus 对
    --    不认识的事件名静默跳过，注册多余事件零成本）。
    EventBus:Register("BAG_UPDATE", Mark)
    EventBus:Register("BAG_UPDATE_DELAYED", Mark)
    EventBus:Register("ITEM_LOCK_CHANGED", Mark)
    EventBus:Register("ITEM_COUNT_CHANGED", Mark)   -- 部分客户端堆叠变化只发这条（去重事件，精准）
    EventBus:Register("LOOT_READY", Mark)           -- 拾取结算（一次拾取发多条，帧级合并吸收）
    EventBus:RegisterUnit("UNIT_INVENTORY_CHANGED", "player", Mark)
    EventBus:Register("PLAYERBANKSLOTS_CHANGED", MarkBank)  -- 银行格子变化（快照有，载荷 slot）
    -- 读图回来缓存可能失效：开着窗就强制重扫（事件不补发，InfoBar 同款教训）。
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if shown then
            bagSig, bankSig = nil, nil
            Rebuild("bags")
            if bankOpen then Rebuild("bank") end
        end
    end)

    -- Bank: only while the bank is open.
    EventBus:Register("BANKFRAME_OPENED", function()
        bankOpen = true
        if Setting("showBank") then
            shown = true
            Rebuild("bank")
            StartPolling()
        end
    end)
    EventBus:Register("BANKFRAME_CLOSED", function()
        bankOpen = false
        -- 银行关了就把背包那几扇窗放回去（原来这里一关就再也不回来了）。
        -- 暴雪框的显隐归暴雪管（停车不碰它），这里只管我们自己的窗口。
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
        Rebuild("bank")
        StartPolling()
        return true
    end
    if rest == "refresh" then
        -- 显式刷新：事件缺口时的手动兜底（也供其它模块调用 M:Refresh()）。
        self:Refresh()
        return true
    end
    self:Toggle()
    return true
end

--- 公开刷新入口：显式触发重扫（② 层）。窗口没开时是 no-op。
function M:Refresh()
    if not shown then return end
    bagSig, bankSig = nil, nil
    Rebuild("bags")
    if bankOpen then Rebuild("bank") end
end

function M:SetEnabled(enabled)
    if not enabled then
        StopPolling()
        for _, win in pairs(windows) do win:Hide() end
        shown = false
        bagsVisualOpen = false
        -- 模块关掉：取回停车（alpha 1 + 鼠标还回去），玩家继续用原生背包。
        -- 守卫这时会因为 IsModuleEnabled 为假而停手。
        ParkBlizzardBags(false)
    else
        ParkBlizzardBags(true)
        StartBlizzardGuard()
    end
end

ns:Register("Bags", M)
