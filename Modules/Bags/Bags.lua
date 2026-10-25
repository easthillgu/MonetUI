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
    if stored ~= nil then return stored end
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

local function AcquireButton(parent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn.icon = Widget:Icon(btn, nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)

    btn.count = Widget:Font(btn, 11, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
    btn.count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)

    btn.quest = Widget:Font(btn, 14, "pixel", { r = 1, g = 0.82, b = 0 }, "CENTER")
    btn.quest:SetPoint("CENTER", btn, "CENTER", 0, 0)

    btn.cd = Widget:Cooldown(btn)

    Widget:Theme(btn, { thickness = 1, bgAlpha = 0.8 })
    Widget:ButtonMaterial(btn, { alpha = 0, weaveAlpha = 0.25 })

    -- Hand-written instead of Widget:Highlight so the tooltip can ride along.
    btn:SetScript("OnEnter", function(self)
        if self.icon then self.icon:SetVertexColor(1.25, 1.25, 1.25) end
        local rec = self.item
        if not rec then return end
        local qc = QualityBorder(rec)
        if qc then
            Widget:Pulse(self, qc.r, qc.g, qc.b, 1)
        else
            local r, g, b = Color:GetHighlight()
            Widget:Pulse(self, r, g, b, 0.9)
        end
        local tip = _G.GameTooltip
        if tip then
            pcall(tip.SetOwner, tip, self, "ANCHOR_RIGHT")
            pcall(tip.SetBagItem, tip, rec.bag, rec.slot)
            pcall(tip.Show, tip)
            -- Tint the tooltip backdrop if the client exposes one; remember its border first.
            if qc and tip.SetBackdropBorderColor then
                local pr, pg, pb, pa
                if tip.GetBackdropBorderColor then
                    pr, pg, pb, pa = tip:GetBackdropBorderColor()
                end
                self.tipPrev = { pr or 0, pg or 0, pb or 0, pa or 0 }
                pcall(tip.SetBackdropBorderColor, tip, qc.r, qc.g, qc.b, 0.6)
            end
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self.icon then self.icon:SetVertexColor(1, 1, 1) end
        Widget:UnPulse(self)
        local tip = _G.GameTooltip
        if tip then
            if tip.SetBackdropBorderColor and self.tipPrev then
                local p = self.tipPrev
                pcall(tip.SetBackdropBorderColor, tip, p[1], p[2], p[3], p[4])
                self.tipPrev = nil
            end
            pcall(tip.Hide, tip)
        end
    end)

    btn:SetScript("OnClick", function(self, mouseButton)
        local rec = self.item
        if not rec then return end
        if mouseButton == "RightButton" and C_Container.UseContainerItem then
            pcall(C_Container.UseContainerItem, rec.bag, rec.slot)
        else
            pcall(C_Container.PickupContainerItem, rec.bag, rec.slot)
        end
    end)
    btn:SetScript("OnDragStart", function(self)
        local rec = self.item
        if rec then pcall(C_Container.PickupContainerItem, rec.bag, rec.slot) end
    end)
    btn:SetScript("OnReceiveDrag", function(self)
        local rec = self.item
        if rec then pcall(C_Container.PickupContainerItem, rec.bag, rec.slot) end
    end)

    btn:SetParent(parent)
    return btn
end

local function UpdateButton(btn, rec)
    btn.item = rec

    if not rec then
        btn.icon:SetTexture(nil)
        btn.count:SetText("")
        btn.quest:SetText("")
        btn.cd:Hide()
        Widget:SetBorderState(btn, nil)
        btn:Hide()
        return
    end

    btn.icon:SetTexture(rec.texture)
    btn:SetAlpha(rec.locked and 0.4 or 1)

    btn.count:SetText(rec.count and rec.count > 1 and rec.count or "")
    btn.quest:SetText(rec.isQuest and "!" or "")

    local qc = QualityBorder(rec)
    if qc then Widget:SetBorderState(btn, qc.r, qc.g, qc.b, 1)
    else Widget:SetBorderState(btn, nil) end

    -- GetItemCooldown 的返回值在受限环境里**可能是机密值**（实测报 "bad argument ... SetCooldown:
    -- Secret values are only allowed during untainted execution"）。一律过 Secrets.Number：
    -- 拿不到明文就不画冷却，绝不把机密值拿去比较或塞进 SetCooldown。
    if rec.itemID and C_Container.GetItemCooldown then
        local ok, start, duration, enable = pcall(C_Container.GetItemCooldown, rec.itemID)
        start, duration, enable = Secrets.Number(start), Secrets.Number(duration), Secrets.Number(enable)
        if ok and start and duration and duration > 0 and enable ~= 0 then -- TAINT-OK: 上一行 Secrets.Number 守卫(见 :280 注释)
            btn.cd:Show()
            if not pcall(btn.cd.SetCooldown, btn.cd, start, duration) then btn.cd:Hide() end -- TAINT-OK: 上游 Secrets.Number 守卫 + pcall 兜底
        else
            btn.cd:Hide()
        end
    end

    btn:Show()
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
    Widget:Theme(win, { thickness = 2, bgAlpha = 0.92 })

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
        local btn = win.buttons[i]
        if not btn then
            btn = AcquireButton(win)
            win.buttons[i] = btn
        end
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        btn:ClearAllPoints()
        btn:SetSize(size, size)
        btn:SetPoint("TOPLEFT", win, "TOPLEFT",
            PAD + col * (size + gap),
            -(TITLE_H + row * (size + gap)))
        UpdateButton(btn, rec)
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
--- 锚点是 **UIParent 的左上角**（x 向右、y 向下），窗口向右排、向下堆。
--- 原来 anchor.x = -33 被当成"离右边 33"来用，套在 TOPLEFT 上就是"离左边 33"，
--- 第一个窗口整个跑到屏幕外，只剩一两个看得见。
local function LayoutWindows()
    local anchor = Setting("anchor") or {}
    local perRow = Setting("windowsPerRow") or 2
    local spacing = 14

    local base = _G[anchor.frame] or UIParent
    local originX = anchor.x or 24
    local originY = anchor.y or -140

    local col, x, rowW, rowH, rowBottom = 0, 0, 0, 0, 0
    for _, cat in ipairs(CATEGORIES) do
        local win = windows[cat.key]
        if win and win:IsShown() and not WindowPosition(cat.key) then
            local w, h = win:GetWidth(), win:GetHeight()
            if col >= perRow then
                -- 这一排排满了：整排往右挪一格（按这一排最宽的），再整排往下挪一格
                -- （按上一排最高的）。每扇窗高度不同，用当前窗的高度会让下一排压上来。
                x = x + rowW + spacing
                rowBottom = rowBottom + rowH + spacing
                col, rowW, rowH = 0, 0, 0
            end
            win:ClearAllPoints()
            win:SetPoint("TOPLEFT", base, "TOPLEFT", originX + x, originY - rowBottom)

            col = col + 1
            rowW = math.max(rowW, w)
            rowH = math.max(rowH, h)
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
--- 玩家按 B（或点背包钮）时暴雪走的就是 ContainerFrame:Show()，
--- 所以钩 Show / SetShown 就够 —— 不用自己去抢按键。
---
--- 两件事必须留到**下一帧**再做：
---   1. 藏框 —— 暴雪正在 Show 它的框时我们就把框藏了，它自己的
---      "生成物品格子" 那一步会拿到 nil（ContainerFrame.lua 的 'itemButton' is a nil value）。
---      晚一帧藏，暴雪的流程能正常跑完，只是玩家会看到背包闪一下。
---   2. 开关我们的窗口 —— 暴雪一次开背包会把合并框 Show 六次（背包 + 5 个包），
---      同一帧里的多次触发只能算一次。
local blizzardHooked = false
local interceptGuard = false

local function HookBlizzardBags()
    for _, frame in ipairs(BlizzardBagFrames()) do
        if not Marked(frame, "bagHook") then
            Mark(frame, "bagHook", true)
            local function Intercept(self)
                if not ns:IsModuleEnabled("Bags") then return end
                if interceptGuard then return end
                interceptGuard = true
                local defer = function()
                    interceptGuard = false
                    for _, other in ipairs(BlizzardBagFrames()) do
                        pcall(other.Hide, other)
                    end
                    M:Toggle()
                end
                if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
                    C_Timer.After(0, defer)
                else
                    defer()
                end
            end
            -- 不再 hooksecurefunc(frame, "Show"/"SetShown")（写方法槽 = 污染源，见 AGENTS）。
            -- 改成轮询"从隐藏变显示"：暴雪把合并背包 Show 出来时我们接管并立刻开自己的窗口。
            ns.Widget:ShowWatch(frame, Intercept)
        end
    end
    blizzardHooked = true
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
        HideBlizzardBags(false)
    end
end

function M:Initialize()
    if not ns:DB().bags then ns:DB().bags = {} end

    -- 暴雪的背包框（ContainerFrame1…13）一开始可能还没建出来，
    -- 每次事件都补钩一次（幂等）。
    HookBlizzardBags()

    -- BAG_UPDATE fires often and for every bag: the handler only marks a rebuild, coalesced to one frame by the flag.
    local pending = false
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self)
        if not pending then self:Hide() return end
        pending = false
        if shown then Rebuild("bags") end
    end)

    local function Mark()
        HookBlizzardBags()
        if not shown then return end
        pending = true
        driver:Show()
    end

    EventBus:Register("BAG_UPDATE", Mark)
    EventBus:Register("BAG_UPDATE_DELAYED", Mark)
    EventBus:Register("ITEM_LOCK_CHANGED", Mark)

    -- Bank: only while the bank is open.
    EventBus:Register("BANKFRAME_OPENED", function()
        if Setting("showBank") then
            shown = true
            HideBlizzardBags(true)
            Rebuild("bank")
        end
    end)
    EventBus:Register("BANKFRAME_CLOSED", function()
        -- 银行关了就把背包那几扇窗放回去（原来这里一关就再也不回来了）。
        if shown then
            Rebuild("bags")
        else
            for _, win in pairs(windows) do win:Hide() end
        end
        HideBlizzardBags(false)
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
        HideBlizzardBags(false)
    else
        HookBlizzardBags()
    end
end

ns:Register("Bags", M)
