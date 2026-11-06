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

-- 银行**主页那 46 格**的容器索引在本客户端没核过：`Enum.BagIndex` 在这台机器上是
-- `-1 Keyring / -2 Characterbanktab / -3 Accountbanktab`（正式服的 -1 = Bank 那套写法
-- 在这里不成立），代码此前只扫 6..14，等于主页一个都没扫。
-- ⇒ 不猜：把三个候选都交给 Scan，`GetContainerNumSlots` 返 >0 的才算数（返 0 / nil /
--   机密的一律跳过，绝不会画出个假空页）。`/mui bags probe` 把每个候选的实测槽数、
--   `C_Bank` 的几项查询和 `WarbandBankFrame` 是否解析得到一次打全，上线日对着账定稿。
--
-- **2026-11-06 定性完成（1.60.1 / 70790，站银行 NPC 前开银行实测）**：
--   `-1` = **Keyring（钥匙扣）**，32 槽 / 0 件 —— **它不是银行页面，绝不能再进银行扫描**
--   （否则"银行空格"会把钥匙扣 32 格算进去：实测 55 = 钥匙扣 32 + 银行 23）。
--   `-2` / `-3` = Characterbanktab / Accountbanktab，本客户端 **0 槽**（`WarbandBankFrame` 也不存在）。
--   真正的银行存储 = `6..14` = `CharacterBankTab_1..9`，已购 1 个 ⇒ `6:48 槽 / 25 件 / 23 空`，
--   未购买的 7..14 全 0 槽 ⇒ **索引与物理格子 1:1，不存在"同一格出现在多个索引"**（那条旧担忧作废）。
local BANK_PAGE_CANDIDATES = { -2, -3 }   -- -1 是钥匙扣，见上（保留 -2/-3 只为将来客户端有内容时自动接上）

-- ---- 模式（背包 / 银行）：窗口键与存档位置都带模式前缀 --------------------------
-- 以前银行是**原地替换**背包（同一批 cat.key 的窗），所以"位置不能和背包重叠"这件事
-- 在结构上做不到。`bank:` 前缀把两套窗、两份位置账、两个总控 ✕ 彻底分开。
local activeMode = "bags"

local function WinKey(catKey)
    return (activeMode == "bank") and ("bank:" .. catKey) or catKey
end

--- 从带前缀的键回到分类（`EnsureWindow` 查 `CATEGORY_BY_KEY` 用）。
local function BaseKey(key)
    local k = tostring(key or "")
    if k:sub(1, 5) == "bank:" then return k:sub(6) end
    return k
end

--- 键属于哪一套（关银行时只收银行那几扇，背包窗一张都不动）。
local function ModeOf(key)
    return tostring(key or ""):sub(1, 5) == "bank:" and "bank" or "bags"
end

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
    local empties = {}     -- 空格的**真实坐标** { bag=, slot= }：作者 11-04 要求"空格子能落东西"，
                           -- 只报数量就永远做不出落点（占位壳没有容器/格子身份）。
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
                    empties[#empties + 1] = { bag = bag, slot = slot }
                end
            end
        end
    end

    for _, cat in ipairs(CATEGORIES) do
        local list = groups[cat.key]
        if #list > 1 then SortItems(list) end
    end

    return groups, free, empties
end

-- Quest items take the amber ring regardless of quality; poor/common keep the plain edge (Andromeda likewise demotes common to black).
-- Declared above AcquireButton: its hover closure uses QualityBorder as an upvalue.
-- 品质色**不在这里算**（2026-11-03 收口）：全仓只留一处真值来源 `Skin:QualityColor(q)`（Utils/Skin.lua）——
-- 它先问 `C_Item.GetItemQualityColor`，问不到才落那六个手调数，所以背包 ring 与格子的品质边、
-- 鼠标提示里的品质文字色从此是同一个答案（以前这里另有一张手调表，1.60 上客户端一改就会出现
-- "背包格一圈绿、商人格一圈另一个绿"）。返回值**按品质是同一张表**，下面的 hover 闭包按引用透传，
-- 每次现造新表等于每 0.5 秒重涂一遍全部边框。形状 `{ r=, g=, b= }`，0 / 1 品质返回 nil = 素边。
local QUEST_COLOR = { r = 0.80, g = 0.80, b = 0.00 }   -- task amber（背包自己的语言，不是品质色，留在本文件）

--- Border for an item: quest amber first, then quality hue, else nil (plain edge).
local function QualityBorder(rec)
    if not rec then return nil end
    if rec.isQuest then return QUEST_COLOR end
    return Skin:QualityColor(rec.quality or 0)
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

    -- 物品等级：左上角 10px 点阵 + 描边，走主题亮色（不是品质色 —— 紫装上的紫字读不出来，
    -- 而边框已经替品质说过一次话了）。字体档与 CharacterFrame / 交易格共用 `Skin:SlotInfoFont`。
    -- ilvl 只有 `C_Item.GetItemInfo` 第 4 返回有（本客户端**没有** GetInventoryItemLevel 一族），
    -- 材料/布料的 ilvl 是 0 或 nil ⇒ 一个字都不写，不画"0"（取词走共享 `Skin:SlotInfoText`）。
    local ilvl = Skin:SlotInfoFont(btn)
    Mark(shell, "ilvlF", ilvl)

    btn:SetScript("OnEnter", function(self)
        Widget:Pulse(self, 1, 1, 1, 0.9)
        local rec = Marked(self, "bagRec")
        if not rec then return end
        -- 空格子现在也是真按钮（会收到悬停）：`SetBagItem` 对空槽会弹出一个**没有内容的提示框**。
        -- 真物品的 rec 一定带 itemID，所以拿它当门，空格子上什么都不显示。
        if not rec.itemID then return end
        local qc = QualityBorder(rec)
        if qc then Widget:Pulse(self, qc.r, qc.g, qc.b, 1) end
        local tip = _G.GameTooltip
        if tip then
            pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")
            pcall(tip.SetBagItem, tip, rec.bag, rec.slot)
            pcall(tip.Show, tip)
            if qc and tip.SetBackdropBorderColor then
                -- 原色**只有四个数全部读得出才存**（2026-11-03 收口）。GameTooltip 是暴雪框，
                -- 这类 getter 在 1.60 上可能给机密值：`pr or 0` 呸不掉它（本仓判例：type() 判不出
                -- 机密字符串），一旦把它装进 tipPrev，OnLeave 喂回去就是一次受限调用 —— 最坏结果
                -- 不是崩而是静默：OnLeave 里那次 pcall（现 :490）兜着，抛完 tipPrev 被清，提示框边框就此卡在
                -- 我们的品质色上，外加一条 ADDON_ACTION_BLOCKED 历史。
                -- 读不出 = "我们没改过它"：不存也不还原（宁可不还原，也不拿秘密值进表）。
                -- 附带好处：拿不到 alpha 时不再存 0 —— 那等于把提示框边框整个抹掉。
                local prev
                if tip.GetBackdropBorderColor then
                    local okC, r0, g0, b0, a0 = pcall(tip.GetBackdropBorderColor, tip)
                    local nr, ng, nb, na
                    if okC then
                        nr, ng, nb = Secrets.Number(r0), Secrets.Number(g0), Secrets.Number(b0)
                        na = Secrets.Number(a0)
                        -- 客户端只给三个值（a0 == nil）时补满 alpha：`Secrets.Number(nil)` 也返回 nil，
                        -- 不补就会被当成"读不出"整条放弃；旧写法这时存的是 0 = 还原后边框整个消失。
                        -- 注意只补 `a0 == nil`：false / 机密值仍然算读不出。
                        if na == nil and a0 == nil then na = 1 end
                    end
                    if nr and ng and nb and na then
                        prev = { nr, ng, nb, na }   -- 旁表里只放普通数字
                    end
                else
                    prev = { 0, 0, 0, 0 }   -- 没有 getter 的老模板：维持改动前的写法（四个纯数字）
                end
                Mark(self, "tipPrev", prev)
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
    local ilvlFs = Marked(shell, "ilvlF")

    if not rec then
        shell:SetID(0)
        btn:SetID(0)
        pcall(SetItemButtonTexture, btn, nil)
        pcall(SetItemButtonCount, btn, 0)
        -- 图标贴图也要显式置 nil：`SetItemButtonTexture(btn, nil)` 在本客户端**不会**清掉
        -- icon 上已有的贴图（见下面空格那段注释），回收再复用时旧物品图标会留着。
        if btn.icon then pcall(btn.icon.SetTexture, btn.icon, nil) end
        if quest then quest:SetText("") end
        if count then count:SetText("") end
        if ilvlFs then ilvlFs:SetText("") end
        if cd then cd:Hide() end
        Widget:SetBorderState(shell, nil)
        btn:Hide() -- 模板按钮出生即隐藏；空槽连钮带壳一起藏
        shell:Hide()
        return
    end

    -- 模板点击链的身份：slot 在按钮上，bag 在父壳上（模板 OnClick 的取法）。
    shell:SetID(rec.bag or 0)
    btn:SetID(rec.slot or 0)
    -- 把身份喂全，照暴雪自己建格子的那套（`ContainerFrameItemButtonMixin:Initialize` 里就是
    -- `SetBagID(bag)` + `SetID(slot)` + `UpdateExtended()`）：`SetBagID` 写的是 `bagid` **属性**，
    -- 属性的 OnAttributeChanged 再把 `self.bagID` 填上。我们以前只 `SetID`，
    -- `GetBagID()` 走的是 `self.bagID or self:GetParent():GetID()` 的后半截兜底 —— 拾取够用，
    -- 但掉落脚本可能读的是前者。方法不存在就跳过（不同客户端模板齐不齐是常态）。
    -- 这些按钮是我们自己造的，写属性不涉及"往暴雪对象写字段"那条禁令。
    if type(btn.SetBagID) == "function" then pcall(btn.SetBagID, btn, rec.bag or 0) end
    if type(btn.UpdateExtended) == "function" then pcall(btn.UpdateExtended, btn) end
    pcall(SetItemButtonTexture, btn, rec.texture)
    -- 空格子（`rec.texture == nil`）：模板自带的**默认图标贴图**会留在 icon 上
    -- （1.60 实测 fileID 8187737 —— 那圈"缺贴图"斜纹就是它），而
    -- `SetItemButtonTexture(btn, nil)` **不会**把它清掉；格子被回收给另一个空格时，
    -- 上一位的物品图标同样会留着。⇒ 显式置 nil（图标仍 Show，无贴图即什么都不画；
    -- 不能靠 Hide —— `Skin:FlattenSlotArt` 里是无条件 `icon.Show()`）。
    -- 2026-11-06 玩家报的"空格美化问题"= 我们的凹槽上盖着一层暴雪斜纹，就是这条。
    if rec.texture == nil and btn.icon then
        pcall(btn.icon.SetTexture, btn.icon, nil)
    end
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
    -- 等级：取词口径（过 Secrets.Number、>0 才写、floor、<=0 或读不到清空不写 0）与
    -- CharacterFrame / 交易格共用 `Skin:SlotInfoText`；这里 `rec.ilvl` 已是权威值。
    if ilvlFs then
        ilvlFs:SetText(Skin:SlotInfoText(rec.ilvl))
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

    -- 冷却遮罩走共享原语 `Skin:ApplySlotCooldown`：GetItemCooldown 的返回值在受限环境里
    -- **可能是机密值**（实测报 "bad argument ... SetCooldown: Secret values are only allowed
    -- during untainted execution"），原语内部三个数全过 Secrets.Number、拿不到明文就不画；
    -- 没有 itemID（空格子）时也显式收 —— 按钮是**复用池**，上一件留下的遮罩不清就会画在空位上。
    Skin:ApplySlotCooldown(cd, rec.itemID)

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
--- 当前带 ✕ 的「总控分类窗」键，**按模式各一份**（`bags` / `bank`）。黏性：它只要还显示就继续当
--- 总控，物品在不同分类之间挪动时 ✕ 不会到处跳；它消失了才顺延到下一扇（见 DesignateMaster）。
local masterKey = { bags = nil, bank = nil }
--- ✕ 的实际动作。**前向声明**在这里（EnsureWindow 的 OnClick 闭包要引用它），函数体排在
--- BlizzardBagFrames 之后 —— 那函数依赖它，写在依赖之前会变成全局 nil（AGENTS）。
local CloseAllBags

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

    local cat = CATEGORY_BY_KEY[BaseKey(key)]
    local isBank = ModeOf(key) == "bank"
    -- 框名里不用冒号（键用 `bank:` 前缀，名字里换成 `bank_`）。
    local name = "MonetUIBagWindow_" .. tostring(key):gsub("bank:", "bank_")
    win = Widget:CreateFrame(name, UIParent, 120, 60)
    -- **建框当场就登记**：这句原本排在函数末尾，于是中间任何一句抛错都会留下
    -- "全局名已占、表里没记"的状态，下一次重绘再建同名框 = CreateFrame already exists
    -- （11-04 harness 银行阶段实测的 ×6 全是这一个错的下游）。
    windows[key] = win
    win.catKey = key
    Widget:Theme(win, { thickness = 1, bgAlpha = 0.92 })

    win.title = Widget:Font(win, 12, "pixel", "edge", "LEFT")
    win.title:SetPoint("TOPLEFT", win, "TOPLEFT", 18, -5)  -- clear of the TL ornament
    -- 两套窗同屏，标题必须分得开：银行那几扇挂"银行 · "前缀。
    win.title:SetText((isBank and "银行 · " or "") .. (cat and cat.label or BaseKey(key)))

    Widget:Shadow(win, { size = 6, alpha = 0.5 })
    Widget:Corners(win)
    Widget:Rule(win, win.title)

    -- 总控窗的 ✕：模板自带 UIPanelCloseButton 外观，OnClick 覆盖成"收整套分类背包"
    -- （等同再按一次 B）。默认隐藏 —— DesignateMaster 只让当前总控窗亮它，屏幕上一个 ✕
    -- 都不多，也不会因为某扇窗临时有货就自己冒出来。
    local close = Widget:CloseButton(win, 18)
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -3, 3)
    close:SetScript("OnClick", function() CloseAllBags(ModeOf(key)) end)
    close:Hide()
    win.close = close
    -- 材质统一：走换皮层同一个入口 `Skin:CloseButton`，把暴雪的 normal/pushed/highlight
    -- 三态原皮换成我们的 monet_close_{normal,push,hover}（描边色随主题，OnTheme 里跟着重染），
    -- 和所有被美化的暴雪窗口右上角那枚 ✕ 是同一种东西。我们的框体，不涉及暴雪对象，无污染风险。
    Skin:CloseButton(close)

    win.buttons = {}
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveWindowPosition(self)
    end)

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


--- 画「剩余空间」。规则改过三次：玩家 2026-11-03 定"最多一行 + `+N`"；
--- 2026-11-04 作者改判成**真槽位、最多 84 格**（多行），因为占位壳没有容器身份、
--- 拖放落不到空位上；**2026-11-06 作者再改回"一行 + `+N`"** —— 前提已经变了：
--- 空格是真 ItemButton（绑 bag/slot，三向拖放实机验过，见 HANDOFF §8.57），所以"单行"
--- 不再等于"没有落点"，代价只剩一条：**第 N+1 个之后的空位看不见、也够不到**。
--- 那个代价是作者明确接受的（多行 84 格会把银行窗撑成 3 行、比所有分类窗高一大截）。
-- 只画几行（1 = 玩家 11-06 定的口径）。`columns * FREE_ROWS` 就是可视空位数。
local FREE_ROWS = 1

--- 「剩余空间」窗：格子里放的是**真 ItemButton**（绑 bag/slot），不是占位壳。
--- 占位壳没有容器身份 ⇒ 拖放没有落点，玩家"能拖出来、放不进空格"（11-04 实机报的缺陷，
--- 背包侧自始如此：暴雪自己的框被我们长期 alpha 0 停着，唯一能落东西的面就没了）。
--- 身份为什么够：1.60 的 `ContainerFrameItemButtonMixin:GetBagID()` 写的是
--- `return self.bagID or self:GetParent():GetID()` —— 壳就是父级、`UpdateButton` 里
--- `shell:SetID(rec.bag)` + `btn:SetID(rec.slot)` 正好喂到它读的那两个口。
--- 兼容旧调用：传数字（`HideModeWindows` 传 0）= 全清。
--- `keepTitle` = **银行模式**：一个空格都没有时仍留标题行（那行挂着"一键存入 / 栏位管理"，
--- 银行满的时候恰恰是最想点"一键存入"的时候）。此时窗宽按满行算，空/不空之间不跳宽度。
local function FillFreeWindow(win, empties, keepTitle)
    local size    = Setting("iconSize")
    local gap     = Setting("gap")
    local columns = Setting("columns")

    local list
    if type(empties) == "table" then list = empties else list = {} end
    local total = #list
    local draw = math.min(total, columns * FREE_ROWS)
    local hidden = total - draw

    for i = 1, draw do
        local shell = win.buttons[i]
        if not shell then
            shell = AcquireButton(win)
            if not shell then           -- 战斗中模板按钮造不出来：本轮少画几格，脱战重排补齐
                draw = i - 1
                break
            end
            win.buttons[i] = shell
        end
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        shell:ClearAllPoints()
        shell:SetSize(size, size)
        shell:SetPoint("TOPLEFT", win, "TOPLEFT",
            PAD + col * (size + gap), -(TITLE_H + row * (size + gap)))
        -- 空 rec：只有坐标。texture / count / quality / ilvl 全 nil ⇒ UpdateButton 走"清空那一套"，
        -- 但壳与按钮都是真的、ID 是对的 ⇒ 它就是一个可落东西的空位。
        UpdateButton(shell, { bag = list[i].bag, slot = list[i].slot })
        local count = Marked(shell, "countF")
        if count then
            -- 溢出提示写在最后一格正中（我们没有 markF 了，countF 在空格上没人用）。
            -- **这一格仍是真槽位**：`+N` 只是它的说明文字，拖进去照样落到它绑的 bag/slot。
            -- N = `total - draw` = **没画出来的**空位数；11-03 那版写的是 `total - draw + 1`
            -- （它把最后一格当纯指示器、自身也算进去），现在最后一格可落东西，不能再算进去。
            count:SetPoint("CENTER", shell, "CENTER", 0, 0)
            count:SetText((i == draw and hidden > 0) and ("+" .. tostring(hidden)) or "")
        end
        shell:Show()
    end
    for i = draw + 1, #win.buttons do
        UpdateButton(win.buttons[i], nil)
    end

    local rows = draw > 0 and math.ceil(draw / columns) or 0
    local perRow = math.min(draw, columns)
    local w = PAD * 2 + perRow * size + math.max(0, perRow - 1) * gap
    local h = TITLE_H + rows * size + math.max(0, rows - 1) * gap + PAD
    if keepTitle then
        -- 银行模式：宽度按**满一行**算（空/不空之间不跳），没有空格时高度只留标题行。
        local fullW = PAD * 2 + columns * size + math.max(0, columns - 1) * gap
        w = math.max(w, fullW)
        if rows == 0 then h = TITLE_H + PAD end
        win:SetSize(w, h)
        win:SetShown(true)
        return
    end
    win:SetSize(w, h)
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

--- 选总控窗并只显示它那一个 ✕。**黏性**：当前总控窗只要还显示就继续当，避免物品在分类间移动
--- 时 ✕ 跳到别的窗上；它空了（该分类没货被 FillWindow 收掉）才顺延到 ORDERED 里第一个还显示的
--- 分类窗。「剩余空间」窗永远不当总控 —— 它是补位的那一行空格子，不是装东西的窗。
--- 在 Rebuild 末尾调用（LayoutWindows / RestoreDragged 之后，此刻各窗显隐已定）。
local function DesignateMaster()
    -- 每个模式各选各的总控：背包和银行同屏时屏幕上两个 ✕（各收各的一套），
    -- 而不是银行一开就把背包那枚 ✕ 抢走。
    local visible = {}
    for _, cat in ipairs(ORDERED) do
        for _, mode in ipairs({ "bags", "bank" }) do
            local key = (mode == "bank") and ("bank:" .. cat.key) or cat.key
            local win = windows[key]
            if cat.key ~= FREE_CAT.key and win and win:IsShown() then
                visible[key] = mode
            end
        end
    end
    for _, mode in ipairs({ "bags", "bank" }) do
        local keep = masterKey[mode] and windows[masterKey[mode]]
        if not (keep and keep:IsShown()) then
            masterKey[mode] = nil
            for _, cat in ipairs(ORDERED) do
                local key = (mode == "bank") and ("bank:" .. cat.key) or cat.key
                if visible[key] then masterKey[mode] = key break end
            end
        end
    end
    for key, win in pairs(windows) do
        if win.close then
            local m = masterKey[ModeOf(key)]
            if key == m then win.close:Show() else win.close:Hide() end
        end
    end
end

--- Tile the visible, not-yet-dragged windows in category order from the anchor.
--- 首选布局：side="right" —— 分类背包的 RIGHT 对齐 QuestTracker 的 LEFT，
--- 间隔 anchor.x（负数 = QuestTracker 左边），垂直从 anchor.y 起一列堆下来。
--- 如果 anchor.frame 不存在（QuestTracker 模块关了 / 还没初始化），降级到
--- "屏幕中间 x=屏幕宽度-280，顶部 y=-28 往下堆" —— 保证无论如何都不会跑出屏幕。
local function LayoutWindows(mode)
    local anchor = Setting("anchor") or {}
    local spacing = 14
    mode = mode or activeMode

    --- 背包那一列现在占多宽（取还显示着、且没被玩家拖过的最宽一扇）。
    --- 银行列要贴在它**再往左**一格，所以这个宽度必须在排版当场量，不能写死常数。
    local function bagsColumnWidth()
        local widest = 0
        for _, cat in ipairs(ORDERED) do
            local win = windows[cat.key]
            if win and win:IsShown() then
                local w = (win:GetWidth() or 0)
                if w > widest then widest = w end
            end
        end
        return widest
    end

    local base = _G[anchor.frame]
    local sideRight = (anchor.side == "right" and base)

    if sideRight then
        -- 贴 base 左边，垂直一列。
        local x = anchor.x or -18
        if mode == "bank" then
            x = x - bagsColumnWidth() - spacing
        end
        local y = anchor.y or -28
        local rowH = 0
        for _, cat in ipairs(ORDERED) do
            local key = (mode == "bank") and ("bank:" .. cat.key) or cat.key
            local win = windows[key]
            if win and win:IsShown() and not WindowPosition(key) then
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
    if mode == "bank" then
        originX = originX - bagsColumnWidth() - spacing
    end
    local originY  = anchor.y or -28
    local rowH = 0
    for _, cat in ipairs(ORDERED) do
        local key = (mode == "bank") and ("bank:" .. cat.key) or cat.key
        local win = windows[key]
        if win and win:IsShown() and not WindowPosition(key) then
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

--- 最近一次银行重绘的**实际条数**（park 暴雪银行框的唯一前置判据：我们一张都没画出来
--- 就说明候选索引 / GameRule / LoD 有问题，那一刻绝不收暴雪的框 —— 宁可见两套，不可看不见）。
--- 两列都重排，**背包在前、银行在后**：银行列的 x 要按"当时背包列的真实宽度"算。
--- 只重排当前模式是结构性的错：银行开完之后再重排背包（多开一扇窗、或银行关闭回到
--- 背包模式），背包列变宽就没人重算银行列 ⇒ 两列重叠（11-04 实机报的"银行材料/银行容器
--- 界面有重叠"就是这个；重叠的不是两扇银行窗彼此，是横向撞上）。
local function LayoutBothModes()
    LayoutWindows("bags")
    LayoutWindows("bank")
end

local bankDrawn = 0
-- `bankFree`（最近一次银行扫描的空格数）**必须声明在 Rebuild 之前**：原先它写在文件下半段
-- （银行工具那一段），而 Rebuild 在上面就 `bankFree = free` 了 —— 那个赋值落到**全局**上，
-- 本地这份永远是 0（2026-11-06 `wuxian check` 的 `global-write` 警告抓出来的）。
local bankFree = 0
local ParkBlizzardBank   -- 前置声明：函数体排在 CloseAllBags 之后（依赖那条链）
-- `EnsureBankTitleTools` 也一样：它定义在银行工具件那一段（Rebuild 之后），
-- 而 Rebuild 要调它 ⇒ 必须先在这儿占位，后面用**赋值**写（写 `local function` 等于另建一个
-- 同名局部，Rebuild 抓到的仍是全局 nil —— AGENTS 那条判例，2026-11-06 又被探针抓了一次）。
local EnsureBankTitleTools

--- 关掉某一模式的全部窗口（银行关闭只收银行那几扇，背包窗一张都不动）。
local function HideModeWindows(mode)
    for key, win in pairs(windows) do
        if ModeOf(key) == mode then
            -- 「剩余空间」那扇只吃 FillFreeWindow（它画的是空格子，不是物品），别拿物品路径清它。
            if BaseKey(key) == FREE_CAT.key then
                FillFreeWindow(win, 0)
            else
                FillWindow(win, {})
            end
            win:Hide()
        end
    end
end

local function Rebuild(bagType)
    activeMode = (bagType == "bank") and "bank" or "bags"
    local indexes = nil
    if activeMode == "bank" then
        -- 主页候选在前（哪个索引真有货由 Scan 的 `GetContainerNumSlots > 0` 判定），标签页在后。
        indexes = {}
        for _, i in ipairs(BANK_PAGE_CANDIDATES) do indexes[#indexes + 1] = i end
        for _, i in ipairs(BANK_TABS) do indexes[#indexes + 1] = i end
    else
        indexes = BAGS_CARRIED
        if Setting("showReagentBag") then
            indexes = { 0, 1, 2, 3, 4, BAG_REAGENT }
        end
    end

    local groups, free, empties = Scan(indexes)
    local drawn = 0
    for key, items in pairs(groups) do
        drawn = drawn + #items
        local wkey = WinKey(key)
        if #items > 0 then
            local win = EnsureWindow(wkey)
            FillWindow(win, items)
        elseif windows[wkey] then
            FillWindow(windows[wkey], {})
        end
    end
    if activeMode == "bank" then
        bankDrawn = drawn
        bankFree = free
    end
    -- 「剩余空间」排在最后（FREE_CAT 在 ORDERED 里 order 最大，LayoutWindows 自然把它堆在末尾）。
    -- 传**真实坐标表**而不是数量：那些格子得是能落东西的真槽位。
    -- 2026-11-06：**银行侧也开了** —— 索引语义已定性（`6..14` = CharacterBankTab_1..9、
    -- 与物理格子 1:1、钥匙扣 `-1` 已从扫描里剔除），原先"银行索引没定性、真槽位可能绑错格"
    -- 这条阻塞消失。显示口径（2026-11-06 作者定）= **只画一行**（`FREE_ROWS = 1` × `columns`），
    -- 其余空位在最后一格写 `+N`（见 FillFreeWindow）。代价：第 N+1 个之后够不到 —— 已接受。
    -- 银行模式：这扇窗是**银行那一列的第一扇**，标题行右端挂两颗动作钮（一键存入 / 栏位管理）。
    -- 所以银行开着时即使一个空格都没有，也要把标题行留着（作者 2026-11-06 定）——
    -- 否则"银行满了想存东西"恰好是按钮消失的时刻。
    local freeWin = EnsureWindow(WinKey(FREE_CAT.key))
    FillFreeWindow(freeWin, empties, activeMode == "bank")

    LayoutBothModes()
    RestoreDragged()
    DesignateMaster()

    if activeMode == "bank" then
        EnsureBankTitleTools(freeWin)
        -- 接管**默认 on**（2026-11-06 作者拍板，DEFAULTS.bags.hideBlizzardBank = true）：
        -- 空格子是真 ItemButton、三向拖放已逐格实测（HANDOFF §8.57）。前提不变 ——
        -- 只有**真画出银行物品**时才停车（`bankDrawn > 0`），零物品时绝不接管（否则等于藏了个空框）。
        ParkBlizzardBank((Setting("hideBlizzardBank") and true or false) and bankDrawn > 0)
    end
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

--- ✕ 的实际动作：收整套。先把还显示着的暴雪框 Hide 一次 —— 停车只压 alpha、从不 Hide，
--- 此刻暴雪框仍 IsShown；不先收它，守卫的边沿会停在"开"，玩家要按两下 B 才能重新打开。
--- 战斗中不能 Hide 暴雪框（里面有受保护子按钮，会被拦），那就只收我们的窗，
--- 下一次 B 的边沿自然把整套带回来（我们的窗本来也归 shown 管）。
--- mode = "bags"（默认，收背包并关暴雪背包）/ "bank"（只收银行那几扇 + 放开暴雪银行框）。
CloseAllBags = function(mode)
    if mode == "bank" then
        HideModeWindows("bank")
        ParkBlizzardBank(false)
        -- 暴雪银行交互本身交给客户端：`C_Bank.CloseBankFrame` 文档无限制标记。
        if C_Bank and C_Bank.CloseBankFrame then pcall(C_Bank.CloseBankFrame) end
        return
    end
    if not InCombat() then
        for _, frame in ipairs(BlizzardBagFrames()) do
            if frame and frame.IsShown and frame:IsShown() then pcall(frame.Hide, frame) end
        end
    end
    M:Toggle(false)
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

-- ---- 暴雪银行框：条件停车（作者 11-04 拍的 ②A） ----------------------------------
-- 收的**唯一判据**是我们真画出了银行物品（`bankDrawn > 0`）。候选容器索引在本客户端还没核过
-- （`Enum.BagIndex` 在这台机器上是 -1 Keyring / -2 Characterbanktab / -3 Accountbanktab，
-- 正式服"−1 = 银行主页"那套写法在这里不成立），扫不到货就说明索引错 / GameRule 关了银行 /
-- LoD 没到位 —— 那一刻一个字节都不许动暴雪的框：**宁可屏幕上两套并存，也不能让玩家打不开银行**。
-- 手法沿用背包：alpha 0 + 整树关鼠标，绝不 `Hide`（Hide 会被暴雪自己的 Show 顶回来，见 AGENTS）。
-- ⚠ 放开（`park = false`）就是"把暴雪那块管理区还给你"的通道：买栏位与背包↔银行包互换都只能
--   （2026-11-06 起：`bank:free` 标题行上的「栏位管理」钮就是这条通道，原来那个「包裹管理」面板已删）。
local function BankFrameCandidates()
    local out = {}
    -- 名字只走 Skin:Need 这一个漏斗（取不到 = 账本里的一行 ✗，不静默跳过）；
    -- WarbandBankFrame 目前是缺席项（还没解析到根），留着它就是为了那一行 ✗ 能被看见。
    local bank = Skin:Need("BankFrame")
    if bank then out[#out + 1] = bank end
    local warband = Skin:Need("WarbandBankFrame")
    if warband then out[#out + 1] = warband end
    return out
end

ParkBlizzardBank = function(park)
    local frames = BankFrameCandidates()
    if #frames == 0 then return end
    -- 战斗中关鼠标这一半做不了（受保护子按钮）—— 排队到脱战补做（同 ParkBlizzardBags）。
    if park and InCombat() then
        ns:AfterCombat("bags-park-bank", function() ParkBlizzardBank(true) end)
        return
    end
    for _, frame in ipairs(frames) do
        if park then
            Widget:Mute(frame, { depth = 2 })
        else
            Widget:Unmute(frame, { depth = 2 })
        end
    end
end

-- ---- 银行标题行工具件（2026-11-06 作者定：动作从「包裹管理」面板搬进标题行） --------
-- 两件事各一颗钮，挂在「银行 · 剩余空间」窗的**标题行右端**：
--   ① 一键存入（`C_Bank.AutoDepositItemsIntoBank`，文档无 [受限] 标记）；
--   ② 栏位管理 —— 只做"把暴雪银行框还给你"，**不代调 `C_Bank.PurchaseBankTab`**
--      （快照标 [受限]，我们点它 = 历史 `UseContainerItem` 那一族越权）。
-- 原来的「包裹管理」折叠面板整块删除（作者 11-06 拍板）：两个动作只剩这一处入口，
-- 一行账（栏位 n/max · 空格 · 物品）在 `/mui bags probe` 里已经有，不再占一扇窗。
local bankFreeWin, bankDepositBtn, bankTabBtn
local function BankHeadButton(parent, label, width, onClick)
    -- kind 必须是 "Button"：`Widget:CreateFrame` 不传 kind 默认建 Frame，Frame 没有
    -- RegisterForClicks / OnClick（建出来那一刻就 attempt to call nil）。
    local button = Widget:CreateFrame(nil, parent, width, 18, nil, "Button")
    Widget:Theme(button, { thickness = 1, bgAlpha = 0.9 })
    Widget:ButtonMaterial(button, { alpha = 0, weaveAlpha = 0.25 })
    button:EnableMouse(true)
    button:RegisterForClicks("AnyUp")
    -- 色键是 bright：`edge` 摆在 bgAlpha 0.9 的深底板上会读成"禁用"（11-04 的实测判例）。
    local text = Widget:Font(button, 10, "pixel", "bright", "CENTER")
    text:SetAllPoints()
    text:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

--- 一键存入。必须留回执：玩家点了没反应时，"钮没接上鼠标"和"API 静默无操作"分不出来。
--- 正式服语义 = 只存"打了自动存入标记"的物品；一个标记都没有时静默不动，不报错。
local function DepositAllBank()
    local bt = (Enum and Enum.BankType and Enum.BankType.Character) or 0
    if not (C_Bank and C_Bank.AutoDepositItemsIntoBank) then
        ns:Print("[mui bags] 一键存入：本客户端没有 C_Bank.AutoDepositItemsIntoBank —— 这颗钮在此无效")
        return
    end
    local support = "?"
    if C_Bank.DoesBankTypeSupportAutoDeposit then
        local okS, v = pcall(C_Bank.DoesBankTypeSupportAutoDeposit, bt)
        support = okS and tostring(v) or "读不出"
    end
    local before = bankDrawn or 0
    local ok, err = pcall(C_Bank.AutoDepositItemsIntoBank, bt)
    M:Refresh()
    ns:Print(("[mui bags] 一键存入：调用=%s · 支持自动存入=%s · 画出 %d → %d 件%s")
        :format(ok and "成功" or ("失败（" .. tostring(err) .. "）"), support,
            before, bankDrawn or 0,
            (ok and before == (bankDrawn or 0))
                and "｜数量没变 = 客户端只存「打了自动存入标记」的物品，没标记就是这种静默无操作（不是被拦）"
                or ""))
end

--- 栏位管理 = 把暴雪银行框还回去（买栏位 / 换银行包只能在它那块面上做）。
--- 只动 alpha / 鼠标（AGENTS 允许的隐藏路子），不写暴雪框字段、不代调受保护 API。
local function ReleaseBlizzardBank()
    ParkBlizzardBank(false)
    Skin:WarnOnce("bankToolsRelease",
        "暴雪银行框已放开：栏位与换包请在那块上操作；重新开银行即恢复接管。")
end

--- 在「银行 · 剩余空间」的标题行右端懒建两颗钮（幂等；窗是复用对象，只建一次）。
--- **赋值不是 `local function`**：上面第 ~1000 行有前置声明，Rebuild 抓的是那个上值。
EnsureBankTitleTools = function(win)
    if not win then return end
    if bankFreeWin == win and bankDepositBtn then return end
    bankFreeWin = win
    if not bankDepositBtn then
        bankTabBtn = BankHeadButton(win, "栏位管理", 58, ReleaseBlizzardBank)
        bankTabBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -6)
        bankDepositBtn = BankHeadButton(win, "一键存入", 58, DepositAllBank)
        bankDepositBtn:SetPoint("TOPRIGHT", bankTabBtn, "TOPLEFT", -4, 0)
    end
    -- 标题文字别伸到钮底下：标题是 FontString，限宽即可（Rule 仍按标题宽度画）。
    if win.title then win.title:SetWidth(math.max(60, win:GetWidth() - 132)) end
end

local SetBankToolsSetting = function(key, value)
    local db = ns:DB()
    db.bags = db.bags or {}
    db.bags[key] = value
end



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
        -- 整套关掉后总控作废：下一次打开重选（哪一类先有货谁当）。
        -- **必须是表**：masterKey 现在按模式各一份，写成 nil 会让下一次
        -- DesignateMaster 索引 nil 直接抛 —— 症状就是"按 B 没反应"（11-04 实机报的这条）。
        masterKey = { bags = nil, bank = nil }
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
        -- 银行关了：只收银行那几扇，并把暴雪框放开（停车是"我们接管"的那半边，
        -- 接管结束就该还回去 —— 留着 alpha 0 的框下次进银行前没人能看见它）。
        HideModeWindows("bank")
        ParkBlizzardBank(false)
        -- 背包那几扇窗放回去（原来这里一关就再也不回来了）。
        -- 暴雪框的显隐归暴雪管（停车不碰它），这里只管我们自己的窗口。
        if shown then
            Rebuild("bags")
        else
            for _, win in pairs(windows) do
                if ModeOf(win.catKey) == "bags" then win:Hide() end
            end
        end
    end)
end

function M:HandleCommand(rest)
    if rest == "hidebliz on" or rest == "hidebliz off" then
        -- 接管暴雪银行框的开关，**默认 on**（2026-11-06 作者拍板；依据 HANDOFF §8.57：空格已是
        -- 真 ItemButton、三向拖放逐格实测通过）。关掉的理由仍然是"要买栏位 / 换银行包"——
        -- 那两件事必须回到暴雪那块面（`C_Bank.PurchaseBankTab` 受限，我们不做）。
        -- ⚠ 写的是**显式布尔**：写 nil 等于删键，而默认值是 true，`off` 会被默认顶回来。
        local on = (rest == "hidebliz on")
        SetBankToolsSetting("hideBlizzardBank", on)
        if on then
            ParkBlizzardBank(bankDrawn > 0)
        else
            ParkBlizzardBank(false)
        end
        ns:Print(("[mui bags hidebliz] 接管暴雪银行框 = %s（画出 %d 件）%s")
            :format(tostring(on), bankDrawn or 0,
                on and "｜空格子已是真槽位（11-06），但**银行侧拖放未实机验证**；先拖一次再当结论"
                    or "｜暴雪银行框已放开，拖放可用（观感上两套并存）"))
        return true
    end
    if rest == "bank off" then
        -- 放开暴雪银行框（买栏位 / 换包要在它上面做），同时收我们的银行窗。
        CloseAllBags("bank")
        return true
    end
    if rest == "bank" then
        shown = true
        Rebuild("bank")
        StartPolling()
        return true
    end
    if rest == "probe" then
        -- ④：把"银行到底该扫哪个容器索引"这件事变成一条命令能打全的账。
        -- 逐索引只打**槽数**（读不出 = `-`），一行一个组，别刷长文（聊天框只留十几行）。
        local function slotsOf(index)
            local ok, v = pcall(C_Container.GetContainerNumSlots, index)
            local n = ok and Secrets.Number(v) or nil
            return n and tostring(n) or "-"
        end
        local groups = {
            "主页候选 " .. table.concat((function()
                local out = {}
                for _, i in ipairs(BANK_PAGE_CANDIDATES) do out[#out + 1] = i .. ":" .. slotsOf(i) end
                return out
            end)(), " "),
            "随身包 " .. table.concat((function()
                local out = {}
                for _, i in ipairs(BAGS_CARRIED) do out[#out + 1] = i .. ":" .. slotsOf(i) end
                out[#out + 1] = "5:" .. slotsOf(BAG_REAGENT)
                return out
            end)(), " "),
            "标签页 " .. table.concat((function()
                local out = {}
                for _, i in ipairs(BANK_TABS) do out[#out + 1] = i .. ":" .. slotsOf(i) end
                return out
            end)(), " "),
        }
        for _, line in ipairs(groups) do ns:Print("[bags.probe] " .. line) end

        -- 逐索引明细。11-04 在 12.1.5 实测出现不自洽：`标签页 6:98 7:98 …` 每格都报 98 槽，
        -- 可同一趟里"画出 136 件 · 空格 0"（7×98=686 格，空格该有 ~550）。光看槽数分不清
        -- `GetContainerNumSlots` 报的是不是这个索引自己的数据 ⇒ 同一趟里再把每个索引
        -- **实际取到的件数 / 空格数 / 拿不到表的格数**打出来，谁在说谎一眼可见。
        local detail = {}
        for _, bag in ipairs({ -1, -2, -3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }) do
            local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
            local slots = (okN and Secrets.Number(n)) or 0
            local items, empties, noInfo = 0, 0, 0
            local cap = slots > 120 and 120 or slots
            for slot = 1, cap do
                local okI, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
                if not okI or type(info) ~= "table" then noInfo = noInfo + 1
                elseif info.itemID then items = items + 1
                else empties = empties + 1 end
            end
            detail[#detail + 1] = ("%d|槽%d 件%d 空%d 无表%d"):format(bag, slots, items, empties, noInfo)
        end
        ns:Print("[bags.probe] 逐索引（各截前 120 格）：" .. table.concat(detail, "  "))

        local bt = (Enum and Enum.BankType and Enum.BankType.Character) or 0
        local function num(fn, arg)
            if not (C_Bank and C_Bank[fn]) then return "无API" end
            local ok, v = pcall(C_Bank[fn], arg)
            local n = ok and Secrets.Number(v) or nil
            return n and tostring(n) or "-"
        end
        ns:Print(("[bags.probe] C_Bank(Character): 已购 %s / 上限 %s · 能用 %s · 能看 %s")
            :format(num("FetchNumPurchasedBankTabs", bt), num("FetchMaxNumBankTabs", bt),
                tostring(C_Bank and C_Bank.CanUseBank and pcall(C_Bank.CanUseBank, bt)),
                tostring(C_Bank and C_Bank.CanViewBank and pcall(C_Bank.CanViewBank, bt))))
        ns:Print(("[bags.probe] Enum.BankType=%s · Enum.BagIndex=%s · 暴雪框 BankFrame=%s / Warband=%s")
            :format(tostring(Enum and Enum.BankType ~= nil), tostring(Enum and Enum.BagIndex ~= nil),
                Skin:Need("BankFrame") and "有" or "✗",
                Skin:Need("WarbandBankFrame") and "有" or "✗"))
        ns:Print(("[bags.probe] 我们这侧：mode=%s · bankOpen=%s · shown=%s · 上次银行重绘：画出 %d 件 / 空格 %d")
            :format(tostring(activeMode), tostring(bankOpen), tostring(shown),
                bankDrawn or 0, bankFree or 0))

        -- P2.4（②A 保险）的**判据**，不看肉眼：我们的决定 + 暴雪框的实际状态。
        -- 决定 = bankDrawn>0 才接管；状态 = 每个框的 muted / alpha / 鼠标三件事。
        -- 真客户端上正确的组合只有两种：
        --   画出 0 件 → muted=false · alpha=1 · 鼠标开   （暴雪银行照旧能用）
        --   画出 >0 件 → muted=true · alpha=0 · 鼠标关   （我们的窗顶上，且必须看得见东西）
        -- 出现「画出 0 件 + muted=true」就是 P0：我们把一个空框藏起来了。
        for _, frame in ipairs(BankFrameCandidates()) do
            local label = Widget:FrameLabel(frame)
            local muted = (type(Widget.IsMuted) == "function") and Widget:IsMuted(frame) or false
            local okA, alpha = pcall(function() return frame:GetAlpha() end)
            local okM, mouse = pcall(function() return frame:IsMouseEnabled() end)
            local okS, vis = pcall(function() return frame:IsShown() end)
            ns:Print(("[bags.probe]   %s：接管=%s · alpha=%s · 鼠标=%s · IsShown=%s")
                :format(label, tostring(muted),
                    okA and tostring(alpha) or "读不出",
                    okM and tostring(mouse) or "读不出",
                    okS and tostring(vis) or "读不出"))
        end
        local verdict
        -- 第一分叉必须是"接管开关 + 银行现在开没开"，不是上一次重绘的计数：11-04 实测就是
        -- 拿陈旧的 `bankDrawn>0` 当现状，印出"应当接管"而同一行观测写着 `接管=false`。
        -- 开关**默认 on**（11-06 作者拍板）；这一支覆盖的是"玩家显式关掉"。
        if not (Setting("hideBlizzardBank") and true or false) then
            verdict = "接管开关被**显式关掉**（默认是 on）→ 不该接管：暴雪银行框照旧可见可用，"
                .. "买栏位 / 换银行包就在它上面做。想要单套观感：`/mui bags hidebliz on`"
                .. "（11-06 起空格已是真槽位，三条拖放已实测通过）。"
        elseif not bankOpen then
            verdict = "接管开着但银行没开 → 不该接管：每行都该是 接管=false · alpha=1"
                .. "（IsShown 归暴雪自己，不是判据）"
        elseif (bankDrawn or 0) > 0 then
            verdict = "银行开着且画出物品 → 应当接管（暴雪框 alpha 0 + 关鼠标）；"
                .. "若我们的窗里没东西 = 索引对了但渲染断了"
        else
            verdict = "银行开着但一件都没画出 → **不该接管**：每行都该是 接管=false · alpha=1；"
                .. "若开着 hidebliz 却写着 接管=true 就是 P0（空框被藏起来），当场 `/mui bags hidebliz off`"
        end
        ns:Print("[bags.probe] 判读：" .. verdict)
        return true
    end
    if rest == "layout" then
        -- 重叠 / 面板看不见的报告器：几何全部实测，不靠肉眼推断。
        -- 每扇窗打 `左右上下 + 是否显示 + 是否被拖过`，再两两判横竖重叠；
        -- 折叠面板单独一行（显示状态 + 矩形 + 子控件数量 —— "按钮看不到"要分清是没建、
        -- 还是建了但被别的窗压住/在屏外）。
        local rects = {}
        for key, win in pairs(windows) do
            if win:IsShown() then
                -- ⚠ `GetRect()` 返回的是 **left, bottom, width, height**，不是 L/R/T/B。
                -- 第一版当四角来打，于是"同一列 14 扇窗 left 全等于 1032"看着像 bug、
                -- 其实那是正常的列 x，而"R"是 bottom —— 报告自己在骗人。这里换算成真四角。
                local ok, l, btm, w, h = pcall(function() return win:GetRect() end)
                if ok and type(l) == "number" then
                    rects[#rects + 1] = { key = key, l = l, r = l + (w or 0),
                        b = btm, t = btm + (h or 0), w = w, h = h,
                        dragged = WindowPosition(key) and true or false,
                        strata = select(2, pcall(function() return win:GetFrameStrata() end)) }
                end
            end
        end
        table.sort(rects, function(a, b) return a.key < b.key end)
        ns:Print(("[bags.layout] mode=%s bankOpen=%s shown=%s · 显示中的窗 %d 扇")
            :format(tostring(activeMode), tostring(bankOpen), tostring(shown), #rects))
        for _, a in ipairs(rects) do
            ns:Print(("  %-16s 左%.0f 右%.0f 下%.0f 上%.0f（%.0fx%.0f）拖过=%s strata=%s")
                :format(a.key, a.l, a.r, a.b, a.t, a.w or 0, a.h or 0,
                    tostring(a.dragged), tostring(a.strata)))
        end
        for i = 1, #rects do
            for j = i + 1, #rects do
                local a, b = rects[i], rects[j]
                -- 纵向重叠 = "a 的底在 b 的顶之下" **且** "b 的底在 a 的顶之下"。
                -- 上一版写成 `a.b > b.t`（那是"分离"的条件），于是把 14px 的合法间距
                -- 全报成重叠，打出来的纵向数是负数 —— 负数就是间隙，一眼该识别出来。
                local hz = a.l < b.r and b.l < a.r
                local vt = a.b < b.t and b.b < a.t
                local ox = hz and (math.min(a.r, b.r) - math.max(a.l, b.l)) or 0
                local oy = vt and (math.min(a.t, b.t) - math.max(a.b, b.b)) or 0
                if hz and vt and ox > 0 and oy > 0 then
                    ns:Print(("  ⚠ 重叠 %s × %s：横向 %.0fpx · 纵向 %.0fpx"):format(
                        a.key, b.key, ox, oy))
                end
            end
        end
        -- 「剩余空间」那一行的自检（11-04 作者实测：拾取正常、光标能带物品、落进暴雪框能成，
        -- 只有我们自己的空位不收货）。三种可能各有各的证据，光看"落不下去"分不出来：
        --   ① 空位根本没建出来（Scan 没收到坐标 / free 窗没显示）；
        --   ② 建出来了但身份没喂对（GetBagID / GetID 不是那个 (bag,slot)）；
        --   ③ 建出来也对了，但模板的 OnReceiveDrag 没挂上（被我们的脚本覆盖掉）。
        local function try(obj, method)
            -- 注意取方法要用**点号**（`fb:GetBagID and ...` 是语法错，上一笔就是这么炸的）。
            -- 也不能写 `return ok and v or nil`：**v=false 会被吞成 nil**（11-04 第三次同类错，
            -- 窗明明关着却报"显示=nil"，读的人以为方法没实现）。只有 pcall 失败才返回 nil。
            if not obj or type(obj[method]) ~= "function" then return nil end
            local ok, v = pcall(obj[method], obj)
            if not ok then return nil end
            return v
        end
        for _, key in ipairs({ FREE_CAT.key, "bank:" .. FREE_CAT.key }) do
            local fw = windows[key]
            if fw then
                local first = fw.buttons and fw.buttons[1]
                local fb = first and Marked(first, "itemBtn")
                local recv
                if fb and type(fb.GetScript) == "function" then
                    local okS, f = pcall(fb.GetScript, fb, "OnReceiveDrag")
                    recv = okS and f or nil
                end
                ns:Print(("  空位窗[%s] 显示=%s · 按钮 %d 个 · 首格 bag=%s slot=%s 鼠标=%s 显示=%s OnReceiveDrag=%s · bagID字段=%s")
                    :format(key, tostring(try(fw, "IsShown")), (fw.buttons and #fw.buttons) or 0,
                        tostring(try(fb, "GetBagID")), tostring(try(fb, "GetID")),
                        tostring(try(fb, "IsMouseEnabled")), tostring(try(fb, "IsShown")),
                        recv and "挂了" or "无",
                        -- nil = 还在靠 `GetParent():GetID()` 兜底；有值 = SetBagID 的属性链走通了
                        fb and tostring(rawget(fb, "bagID")) or "无按钮"))
            else
                ns:Print(("  空位窗[%s]：没建过（本会话没进过这一侧）"):format(key))
            end
        end
        -- 标题行动作钮（2026-11-06 起：原「包裹管理」面板已删，两个动作搬到这里）。
        -- 判据 = 钮在、显、可点、且挂在 `bank:free` 这扇窗上（不是别处）。
        if bankDepositBtn and bankTabBtn then
            local function btnLine(label, b)
                local okR, l2, btm2, w2, h2 = pcall(function() return b:GetRect() end)
                return ("  %s：显示=%s · 鼠标=%s · 父=%s · 左%.0f 右%.0f 下%.0f 上%.0f")
                    :format(label, tostring(try(b, "IsShown")), tostring(try(b, "IsMouseEnabled")),
                        tostring(b:GetParent() == bankFreeWin and "bank:free" or "别处"),
                        okR and l2 or 0, okR and (l2 + (w2 or 0)) or 0,
                        okR and btm2 or 0, okR and (btm2 + (h2 or 0)) or 0)
            end
            ns:Print(btnLine("标题钮「一键存入」", bankDepositBtn))
            ns:Print(btnLine("标题钮「栏位管理」", bankTabBtn))
        else
            ns:Print("  标题行动作钮：还没创建（本会话没进过银行侧）")
        end
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
        -- 模块关掉：取回停车（alpha 1 + 鼠标还回去），玩家继续用原生背包 / 银行。
        -- 守卫这时会因为 IsModuleEnabled 为假而停手。
        ParkBlizzardBags(false)
        ParkBlizzardBank(false)
    else
        ParkBlizzardBags(true)
        StartBlizzardGuard()
    end
end

ns:Register("Bags", M)
