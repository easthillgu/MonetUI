-- Modules/Tooltip.lua
-- 鼠标提示：**位置** + **内容增强**（精简自 Andromeda 的 modules/tooltip）。
--
-- 位置（原缺陷已修）：跟随光标；贴到屏幕右/上边缘时**翻到光标另一侧**，再越界就顶回屏幕内；
--   偏移按物理像素算（Media:Mult），不再是随 UI 缩放浮动的 UI 单位。
--
-- 内容（只保留三样，其余在 HANDOFF 3.13 里写了为什么砍）：
--   * 单位：追加一行「目标: <名字>」—— 这个单位正在打谁（名字用职业色，NPC 用高光色）；
--   * Alt：追加一行 ID —— 单位是 NPC ID（GUID 里的 creature 编号）、物品是 itemID、法术是 spellID。
--
-- 为什么不是钩子：本客户端**没有** TooltipDataProcessor（手册零命中），而 HookScript /
-- hooksecurefunc 写的是暴雪框的脚本槽 / 方法槽，AGENTS 的污染模型明令禁止（GameTooltip
-- 也一样，`SharedTooltip_SetBackdropStyle` 都没敢 hook）。所以用一个**自建驱动帧**每帧看一次：
-- 显示上升沿那一帧就补齐内容，代价只有"多出来的那一行晚 1 帧出现"。
--
-- 幂等：内容变了（换了目标 / 换了物品 / Shift 比对 / 按下 Alt）才重补一次；补完记签名，
-- 签名没变就不再碰 —— 否则每 0.05 秒往同一个提示框里加一行，会一直长。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Color   = ns.Color
local Media   = ns.Media
local Mark    = function(o, k, v) return ns:Mark(o, k, v) end
local Marked  = function(o, k) return ns:Marked(o, k) end

local M = { name = "Tooltip" }
ns.Tooltip = M

--- 光标与提示框之间让开的距离（物理像素）。
local OFFSET = 14
--- 内容扫描间隔（秒）。位置是每帧；内容只在"变了"的时候才动，没必要每帧重算。
local SCAN = 0.05

local follow, enrich, idsByAlt      -- 设置缓存（每帧要读，别去翻 DB）
local driver, wasShown, scanAcc, lastKey

-- ============================================================================
-- 设置（键仍是 follow / enrich / idsByAlt，面板与 /mui 都走这里）
-- ============================================================================

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.tooltip) ~= "table" then db.tooltip = {} end
    return db.tooltip
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = (ns.DEFAULTS.tooltip or {})[key] end
    return value
end

-- ============================================================================
-- 位置
-- ============================================================================

--- 把提示框摆到光标旁：默认右下，右边放不下翻左边，上面放不下翻下面，最后顶回屏幕。
local function Place(tip)
    local ui = _G.UIParent
    if not ui then return end
    local x, y = _G.GetCursorPosition()
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local scale = ui:GetEffectiveScale()
    if type(scale) ~= "number" or scale <= 0 then return end

    -- 只在"该动"的时候动：光标没动、尺寸没变就不写布局（静止悬停零开销）。
    local w, h = tip:GetWidth() or 0, tip:GetHeight() or 0
    local key = string.format("%.2f:%.2f:%.2f:%.2f:%.3f", x, y, w, h, scale)
    if key == lastKey then return end
    lastKey = key

    local off = OFFSET * (Media:Mult() or 1)
    local cx, cy = x / scale, y / scale
    local uiW, uiH = ui:GetWidth() or 0, ui:GetHeight() or 0

    local ox, oy = off, -off                      -- 框的 BOTTOMLEFT 相对光标右下
    if w > 0 and cx + ox + w > uiW then ox = -(w + off) end   -- 右边放不下 → 翻到左侧
    if h > 0 and cy + oy + h > uiH then oy = -(h + off) end   -- 上面放不下 → 翻到下方
    if cx + ox < 0 then ox = -cx end                          -- 左越界
    if cy + oy < 0 then oy = -cy end                          -- 下越界

    tip:ClearAllPoints()
    tip:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT", cx + ox, cy + oy)
end

-- ============================================================================
-- 内容
-- ============================================================================

local TARGET_LABEL = _G.TARGET or "Target"
local ITEM_ID_LABEL = (_G.ITEMS or "Item") .. " ID"
local SPELL_ID_LABEL = (_G.SPELLS or "Spell") .. " ID"
local NPC_ID_LABEL = "NPC ID"

--- 机密值一律当"读不到"：能进 table.concat / format 的只有普通值。
local function Plain(value)
    if value == nil then return nil end
    if Secrets.IsSecret(value) then return nil end
    return value
end

--- 提示框当前是哪个单位（本客户端的 GameTooltip:GetUnit() 返回 name, unit）。
local function TooltipUnit(tip)
    if type(tip.GetUnit) ~= "function" then return nil end
    local ok, _, unit = pcall(tip.GetUnit, tip)
    if ok and type(unit) == "string" then return unit end
    return nil
end

--- 某一行左侧文本（TextLeftN）的明文，读不到 / 机密返回 nil。
local function LineText(tip, index)
    local name = tip.GetName and tip:GetName()
    if not name then return nil end
    local fs = _G[name .. "TextLeft" .. index]
    if type(fs) ~= "table" or type(fs.GetText) ~= "function" then return nil end
    local ok, text = pcall(fs.GetText, fs)
    if not ok then return nil end
    return Plain(text)
end

--- 内容指纹：单位 / 物品链接 / 法术 id / 行数 / 首末行 / Alt 状态。
--- 变了才重补内容；没变就什么都不做。
local function Signature(tip)
    local parts = {}
    parts[#parts + 1] = TooltipUnit(tip) or ""
    local lines = tip:NumLines() or 0
    parts[#parts + 1] = tostring(lines)
    parts[#parts + 1] = LineText(tip, 1) or ""
    if lines > 1 then parts[#parts + 1] = LineText(tip, lines) or "" end
    if type(tip.GetItem) == "function" then
        local ok, _, link = pcall(tip.GetItem, tip)
        if ok and type(link) == "string" then parts[#parts + 1] = Plain(link) or "?" end
    end
    if type(tip.GetSpell) == "function" then
        local ok, _, id = pcall(tip.GetSpell, tip)
        if ok and id ~= nil then
            local n = Secrets.Number(id)
            if n then parts[#parts + 1] = tostring(n) end
        end
    end
    parts[#parts + 1] = (_G.IsAltKeyDown and _G.IsAltKeyDown()) and "1" or "0"
    return table.concat(parts, "\1")
end

--- 空行 + 「标签 / 值」两列。值的颜色默认高光色（主题色，和皮肤一致）。
local function AddPair(tip, label, value, vr, vg, vb)
    local lr, lg, lb = Color:GetNeutral()
    if vr == nil then vr, vg, vb = Color:GetHighlight() end
    tip:AddLine(" ")
    if type(tip.AddDoubleLine) == "function" then
        tip:AddDoubleLine(label, value, lr, lg, lb, vr, vg, vb)
    else
        tip:AddLine(label .. " " .. tostring(value), lr, lg, lb)
    end
end

--- 「目标: <名字>」—— 这一行回答"它现在在打谁"，比装等/专精便宜得多，也不碰 inspect。
local function AddUnitTarget(tip, unit)
    local target = unit .. "target"
    if not Secrets.Bool(UnitExists(target), false) then return end

    local ok, name = pcall(UnitName, target)
    name = ok and Plain(name) or nil
    if not name or name == "" then
        -- 战斗中身份是机密：宁可少一行，也不写"目标: ???"骗自己。
        return
    end

    local vr, vg, vb
    if Secrets.Bool(UnitIsPlayer(target), false) then
        local okc, classFile = pcall(UnitClassBase, target)
        classFile = okc and Plain(classFile) or nil
        if classFile then vr, vg, vb = Color:ClassColor(classFile) end
    end
    AddPair(tip, TARGET_LABEL, name, vr, vg, vb)
end

--- Alt：单位给 NPC ID，物品给 itemID，法术给 spellID。
local function AddIDs(tip, unit)
    if not idsByAlt then return end
    if not (_G.IsAltKeyDown and _G.IsAltKeyDown()) then return end

    if unit then
        -- 玩家 GUID 是 Player-xxx，没有数字 ID；Creature-/Vehicle- 才有。
        local ok, guid = pcall(UnitGUID, unit)
        guid = ok and Plain(guid) or nil
        if type(guid) == "string" then
            local id = guid:match("^Creature%-(%d+)") or guid:match("^Vehicle%-(%d+)")
            if id then AddPair(tip, NPC_ID_LABEL, id) end
        end
        return
    end

    if type(tip.GetItem) == "function" then
        local ok, _, link = pcall(tip.GetItem, tip)
        link = ok and Plain(link) or nil
        if type(link) == "string" then
            local id = link:match("item:(%d+)")
            if id then AddPair(tip, ITEM_ID_LABEL, id) return end
        end
    end

    if type(tip.GetSpell) == "function" then
        local ok, _, spellID = pcall(tip.GetSpell, tip)
        if ok and spellID ~= nil then
            local id = Secrets.Number(spellID)
            if id then AddPair(tip, SPELL_ID_LABEL, tostring(id)) end
        end
    end
end

local function EnrichInto(tip)
    local unit = TooltipUnit(tip)
    if unit then
        if enrich then AddUnitTarget(tip, unit) end
        AddIDs(tip, unit)
        return
    end
    AddIDs(tip, nil)
end

--- 补一次内容（幂等）。三种记账：
---   tipPre  = 补之前的签名    → 用来判断"我们加的行被引擎抹掉了"
---   tipPost = 补之后的签名    → 相等就不用再补
---   tipNoAdd = 本次显示里别再补（引擎在重绘，补了会被抹，反复补就是闪）
local function Enrich(tip)
    if not enrich and not idsByAlt then return end
    if Marked(tip, "tipNoAdd") then return end

    local now = Signature(tip)
    if Marked(tip, "tipPost") == now then return end

    local pre = Marked(tip, "tipPre")
    if pre ~= nil and pre == now then
        -- 同一份内容，我们加过的行却不见了：引擎按数据重绘了整个框。再补就是每 0.05s 闪一次。
        Mark(tip, "tipNoAdd", true)
        Mark(tip, "tipPost", nil)
        return
    end

    pcall(EnrichInto, tip)
    Mark(tip, "tipPre", now)
    Mark(tip, "tipPost", Signature(tip))
end

-- ============================================================================
-- 驱动：一个自建帧，每帧一次；提示框隐藏时立刻返回（没有轮询开销）
-- ============================================================================

local function Reset(tip)
    Mark(tip, "tipPre", nil)
    Mark(tip, "tipPost", nil)
    Mark(tip, "tipNoAdd", nil)
    lastKey = nil
    scanAcc = 0
end

local function Tick(_, elapsed)
    local tip = _G.GameTooltip
    if not tip then return end

    if not tip:IsVisible() then
        if wasShown then
            wasShown = false
            Reset(tip)
        end
        return
    end

    if not wasShown then
        -- 上升沿：当帧摆位 + 补内容（晚一帧的那一行，就是在这一步补的）
        wasShown = true
        scanAcc = 0
        if follow then Place(tip) end
        Enrich(tip)
        return
    end

    if follow then Place(tip) end

    scanAcc = scanAcc + (elapsed or 0)
    if scanAcc < SCAN then return end
    scanAcc = 0
    Enrich(tip)
end

local function Install()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", Tick)

    -- 兜底：翻转算漏了也不会跑出屏幕（GameTooltip 不是受保护框，随时可设）。
    local tip = _G.GameTooltip
    if tip and type(tip.SetClampedToScreen) == "function" then
        pcall(tip.SetClampedToScreen, tip, true)
    end
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function M:Apply()
    follow   = self:GetSetting("follow") and true or false
    enrich   = self:GetSetting("enrich") and true or false
    idsByAlt = self:GetSetting("idsByAlt") and true or false
    -- 开关变了：记账清零，下一次扫描按新设置重来。
    -- 注意**不 Hide**（以前的毛病：取消勾选会把正在看的提示框直接收掉）。
    local tip = _G.GameTooltip
    if tip then Reset(tip) end
end

function M:Initialize()
    follow   = self:GetSetting("follow") and true or false
    enrich   = self:GetSetting("enrich") and true or false
    idsByAlt = self:GetSetting("idsByAlt") and true or false
    Install()
end

--- 模块开关：关掉只是让跟随与增强失效，驱动本身留着（重开零成本）。
function M:SetEnabled(value)
    if value then
        self:Apply()
        Install()
    else
        follow, enrich, idsByAlt = false, false, false
        local tip = _G.GameTooltip
        if tip then Reset(tip) end
    end
end

ns:Register("Tooltip", M)
