-- Modules/Tools/Durability.lua
-- 装备耐久警告（durability warning）：最低的装备耐久掉到阈值以下时，用通知横幅提醒一次；
-- 修好 / 换装回到阈值以上之后才重新武装。
--
-- 只读装备耐久，不改任何东西：事件由 UPDATE_INVENTORY_DURABILITY / PLAYER_EQUIPMENT_CHANGED /
-- PLAYER_ENTERING_WORLD 驱动，平时没有 OnUpdate。没有 Toast 模块时退化成聊天框一行提示。
--
-- `GetInventoryItemDurability` 在 1.60 **实测存在**（2026-11-26 / build 71139，签名就是 `(slot)`；
-- 归档 §2.1 那句"`GetInventoryItem*` 全族不存在"是 11-04 取物品等级的语境，对耐久不成立）。
-- 参数形态仍保留"第一次读出数字才定形"的探测，因为零售是 `(unit, slot)`、这套客户端是 `(slot)`。

local ADDON_NAME, ns = ...

local EventBus = ns.EventBus
local Secrets  = ns.Secrets

local M = { name = "Durability" }
ns.Durability = M

-- 头 / 肩 / 胸 / 腰 / 腿 / 靴 / 腕 / 手 / 主手 / 副手 / 远程（= InventorySlotId 1…18 里带耐久的那些）。
-- ⚠ 槽位号是**客户端枚举**，不许按名字猜：15 = 披风（无耐久）、16 = 主手、17 = 副手、18 = 远程。
-- 11-26 之前这里写成"15 主手 / 16 副手"，副手（17）从来没被读过（拿双手武器时看不出来）。
local SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }
local SLOT_LABEL = {
    [1] = "头部", [3] = "肩部", [5] = "胸甲", [6] = "腰带", [7] = "腿部",
    [8] = "靴子", [9] = "手腕", [10] = "手套", [16] = "主手", [17] = "副手", [18] = "远程",
}
local HYSTERESIS = 5     -- 高出阈值这么多才算"修好了"，免得在阈值上下反复报警

local mode               -- "slot" | "unit"：本会话用哪种参数形态，探测一次就定
local armed = true       -- true = 下次跌破阈值还要报警

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.durability) ~= "table" then db.durability = {} end
    return db.durability
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.durability[key] end
    return value
end

local function ReadSlotWith(kind, slot)
    local fn = _G.GetInventoryItemDurability
    if type(fn) ~= "function" then return nil end

    local ok, current, maximum
    if kind == "unit" then
        ok, current, maximum = pcall(fn, "player", slot)
    else
        ok, current, maximum = pcall(fn, slot)
    end
    if not ok then return nil end

    current, maximum = Secrets.Number(current), Secrets.Number(maximum)
    if not current or not maximum or maximum <= 0 then return nil end
    return current, maximum
end

local function DurabilityForSlot(slot)
    if type(_G.GetInventoryItemDurability) ~= "function" then return nil end
    if mode then return ReadSlotWith(mode, slot) end

    -- 未定形：拿这件装备去试两种参数形态，**读出数字的那个**才算本会话形态。
    -- 旧写法只认"pcall 没报错"——空槽位传 (slot) 也会"成功"并返回 nil, nil，
    -- 形态就此定死成错的，之后每件都读不出（格子和提示永远空白，且不报错）。
    for _, kind in ipairs({ "slot", "unit" }) do
        local current, maximum = ReadSlotWith(kind, slot)
        if current then
            mode = kind
            return current, maximum
        end
    end
    return nil
end

--- 一件装备的名字：优先物品链接里的 `[名字]`，读不出（无链接 / 机密串 / 没有这个 API）时退回槽位名。
--- 机密串连 `match` 都会抛（AGENTS：进 concat / 比较之前先 CanRead）。
local function ItemName(slot)
    local fn = _G.GetInventoryItemLink
    local link
    if type(fn) == "function" then
        local ok, value = pcall(fn, "player", slot)
        if not ok or type(value) ~= "string" or value == "" then
            ok, value = pcall(fn, slot)
        end
        if ok and type(value) == "string" and value ~= "" and Secrets.CanRead(value) then
            local okMatch, name = pcall(string.match, value, "%[(.-)%]")
            if okMatch and type(name) == "string" and name ~= "" then link = name end
        end
    end
    return link or SLOT_LABEL[slot]
end

--- 所有装备里最低的那件：返回百分比（0..100），没有可读数据时 nil。
local function Lowest()
    local worst
    for _, slot in ipairs(SLOTS) do
        local current, maximum = DurabilityForSlot(slot)
        if current then
            local pct = current / maximum * 100
            if not worst or pct < worst then worst = pct end
        end
    end
    return worst
end

------------------------------------------------------------------------------
-- 对外的读数（信息栏耐久格 `/mui` 探针都走这里，**不许在别处抄第二份槽位表 / 探测**）：
--   M:Signature()  本会话定形的参数形态 "slot" / "unit"（还没定形时 nil）
--   M:ReadSlot(s)  单件：current, maximum（无耐久 / 空槽 / 读不出 → nil）
--   M:Scan()       全量：平均 + 最低 + 逐件清单（一次扫描，格子和提示共用）
------------------------------------------------------------------------------

function M:Signature() return mode end

function M:ReadSlot(slot) return DurabilityForSlot(slot) end

M.SLOTS = SLOTS

--- 背包物品的名字：`C_Container.GetContainerItemLink` 的 `[名字]`；读不出（空位 / 机密串 / 没有链接）时 nil。
--- （装备名走 `ItemName` 的 `GetInventoryItemLink`，那条 1.60 实测存在，与背包这条是两套 API。）
local function BagItemName(bag, slot)
    local api = _G.C_Container
    local fn = api and api.GetContainerItemLink
    if type(fn) ~= "function" then return nil end
    local ok, link = pcall(fn, bag, slot)
    if not ok or type(link) ~= "string" or link == "" then return nil end
    if not Secrets.CanRead(link) then return nil end
    local okMatch, name = pcall(string.match, link, "%[(.-)%]")
    if okMatch and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- 0 = 背包本体，1–4 = 普通包，5 = 材料包（BagIndex 枚举，见 docs/api/TYPES.md）。
local BAG_INDEXES = { 0, 1, 2, 3, 4, 5 }

--- **背包内物品**的耐久：槽位路径读不出时的兜底数据源（例如没穿带耐久的装备、或 API 被临时限制）。
--- 返回结构同 `M:Scan()`，另加 `source = "bags"`；一件都读不出时 nil。
--- 只扫耐久列（每槽一次 pcall），闲置空格直接跳过，不会像旧实现那样无脑扫满 110 格。
function M:ScanBags()
    local api = _G.C_Container
    if not api or type(api.GetContainerItemDurability) ~= "function"
        or type(api.GetContainerNumSlots) ~= "function" then
        return nil
    end

    local out = { count = 0, items = {}, source = "bags" }
    local sum = 0

    for i = 1, #BAG_INDEXES do
        local bag = BAG_INDEXES[i]
        local okSlots, numSlots = pcall(api.GetContainerNumSlots, bag)
        numSlots = okSlots and Secrets.Number(numSlots) or nil
        if numSlots and numSlots >= 1 then
            for slot = 1, numSlots do
                local ok, current, maximum = pcall(api.GetContainerItemDurability, bag, slot)
                if ok then
                    current, maximum = Secrets.Number(current), Secrets.Number(maximum)
                    if current and maximum and maximum > 0 then
                        local pct = current / maximum * 100
                        if pct > 100 then pct = 100 end
                        local name = BagItemName(bag, slot) or ("背包 " .. bag .. " · 槽 " .. slot)
                        out.count = out.count + 1
                        sum = sum + pct
                        out.items[#out.items + 1] = {
                            slot = slot, bag = bag, name = name, pct = pct,
                            current = current, maximum = maximum,
                        }
                        if not out.lowest or pct < out.lowest then
                            out.lowest, out.lowestName = pct, name
                        end
                    end
                end
            end
        end
    end

    if out.count == 0 then return nil end
    out.percent = sum / out.count
    table.sort(out.items, function(a, b) return a.pct < b.pct end)
    return out
end

--- 全量扫描结果：
--- `{ percent = 平均, lowest = 最低那件的百分比, lowestSlot, lowestName, count,
---    items = { { slot, name, pct, current, maximum }, … } }`
--- 一件都读不出（没穿带耐久的装备 / API 不可用）时 nil；`items` 按耐久从低到高排，
--- 提示框直接照排 ⇒ 最该修的那件在第一行。
function M:Scan()
    local out = { count = 0, items = {}, source = "slots" }
    local sum = 0

    for i = 1, #SLOTS do
        local slot = SLOTS[i]
        local current, maximum = DurabilityForSlot(slot)
        if current then
            local pct = current / maximum * 100
            if pct > 100 then pct = 100 end
            local name = ItemName(slot)
            out.count = out.count + 1
            sum = sum + pct
            out.items[#out.items + 1] = { slot = slot, name = name, pct = pct, current = current, maximum = maximum }
            if not out.lowest or pct < out.lowest then
                out.lowest, out.lowestSlot, out.lowestName = pct, slot, name
            end
        end
    end

    if out.count == 0 then return nil end
    out.percent = sum / out.count
    table.sort(out.items, function(a, b) return a.pct < b.pct end)
    return out
end

local function Check()
    if not M.active then return end
    if M:GetSetting("warn") == false then return end

    -- 1.60.1 · 71139 实测 `GetInventoryItemDurability(slot)` 存在且可用（7 件全读得出），
    -- 所以这条告警现在是**真能响**的，不再是"写了等于没写"。
    -- 客户端哪天又把它收回，`DurabilityForSlot` 的"读出数字才定形"会让它自动静默失效，不报错。
    local pct = Lowest()
    if not pct then return end

    local threshold = tonumber(M:GetSetting("threshold")) or 30
    if pct <= threshold then
        if not armed then return end
        armed = false

        local text = string.format("最低剩 %d%%，记得修理", math.floor(pct + 0.5))
        local toast = ns:GetModule("Toast")
        if toast and toast.Notify then
            -- 告警族带 ⚠ 图标 + 危险红（2026-11-16 全仓提示/告警接图标的口径）。
            toast:Notify("装备耐久", text, {
                icon = "monet_warning",
                tint = { ns.Color:GetDanger() },
            })
        else
            ns:Print("装备耐久：" .. text)
        end
    elseif pct > threshold + HYSTERESIS then
        armed = true
    end
end

function M:Initialize()
    self.active = true
    EventBus:Register("UPDATE_INVENTORY_DURABILITY", function()
        if M.active then Check() end
    end)
    EventBus:Register("PLAYER_EQUIPMENT_CHANGED", function()
        if M.active then Check() end
    end)
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        -- 不重新武装：不然每换一个区域就会再提醒一次。登录那次 armde 仍是初始的 true，
        -- 所以"带着残血装备上线"照样会提示一次。
        if M.active then Check() end
    end)
end

--- 设置改了就立刻按新阈值判一次（调高阈值时不必等到下次掉耐久）。
function M:Apply()
    if self.active then
        armed = true
        Check()
    end
end

function M:SetEnabled(value)
    self.active = value and true or false
    if self.active then
        armed = true
        Check()
    end
end

ns:Register("Durability", M)
