-- Modules/Tooltip.lua
-- 鼠标提示：**位置** + **内容增强**（精简自 Andromeda 的 modules/tooltip）。
--
-- 位置有三种摆法（设置键 anchor）：
--   cursor  —— 跟随光标；贴到屏幕右/上边缘时**翻到光标另一侧**，再越界就顶回屏幕内；
--   minimap —— 提示框的**右下角对齐小地图面板的右上角**（贴在地图上沿、右边缘齐平），
--              长得顶出屏幕顶边就改挂在面板下方；
--   off     —— 不动，用暴雪自己的锚点。
--   偏移按物理像素算（Media:Mult），不随 UI 缩放浮动。
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
--- 提示框与小地图面板之间让开的距离（物理像素）。
local MM_GAP = 8
--- 翻边阈值（UI 单位）：光标离右边缘不足这么宽就翻到左边、离下边缘不足这么高就翻到上面。
--- **只和光标位置有关，不看提示框宽高** —— 以前按"放不放得下"翻边，而宽高会被内容
--- （Shift 对比、我们追加的 ID 行）改变，鼠标停在临界位置就会左右横跳（玩家 2026-10-26 报"位置乱跑"）。
local EDGE_W = 420
local EDGE_H = 320
--- 内容扫描间隔（秒）。位置是每帧；内容只在"变了"的时候才动，没必要每帧重算。
local SCAN = 0.05

local mode, enrich, idsByAlt       -- 设置缓存（每帧要读，别去翻 DB）：cursor / minimap / off
local driver, wasShown, scanAcc, cursorKey, mmKey

-- ============================================================================
-- 设置（键：anchor / enrich / idsByAlt，面板与 /mui 都走这里）
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

--- 位置模式。老存档只有 follow（布尔）：true = 跟随鼠标，false = 暴雪默认。
local function ResolveMode(self)
    local db = self:Settings()
    local value = db.anchor
    if value == nil then
        if db.follow ~= nil then
            value = db.follow and "cursor" or "off"
        else
            value = (ns.DEFAULTS.tooltip or {}).anchor or "cursor"
        end
    end
    if value ~= "cursor" and value ~= "minimap" and value ~= "off" then value = "cursor" end
    return value
end

M.ResolveMode = ResolveMode

-- ============================================================================
-- 位置
-- ============================================================================

--- 把提示框摆到光标旁：默认右下；光标进入右侧/下侧边缘带就翻到另一边；最后再夹回屏幕内。
--- **所有判断只看光标位置**（不看提示框宽高），所以内容变化不会让它在两侧之间横跳。
local function PlaceCursor(tip)
    local ui = _G.UIParent
    if not ui then return end
    local x, y = _G.GetCursorPosition()
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local scale = ui:GetEffectiveScale()
    if type(scale) ~= "number" or scale <= 0 then return end

    local w, h = tip:GetWidth() or 0, tip:GetHeight() or 0
    local cx, cy = x / scale, y / scale
    local uiW, uiH = ui:GetWidth() or 0, ui:GetHeight() or 0
    local off = OFFSET * (Media:Mult() or 1)

    -- 翻边：只看光标离边缘多远（与宽高无关 → 不会因为内容变宽/变高而反复翻）
    local left  = uiW > 0 and (uiW - cx) < EDGE_W
    local below = uiH > 0 and cy < EDGE_H

    local x0 = left  and (cx - w - off) or (cx + off)
    local y0 = below and (cy - h - off) or (cy + off)

    -- 兜底夹取：真放不下就贴着屏幕边（结果仍是确定的，不会来回）
    if uiW > 0 and x0 + w > uiW then x0 = uiW - w end
    if uiH > 0 and y0 + h > uiH then y0 = uiH - h end
    if x0 < 0 then x0 = 0 end
    if y0 < 0 then y0 = 0 end

    -- 去重：光标没动、尺寸没变就不写布局（静止悬停零开销）。
    local key = string.format("%.1f:%.1f:%.1f:%.1f:%.2f", x, y, w, h, scale)
    if key == cursorKey then return end
    cursorKey = key

    tip:ClearAllPoints()
    tip:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT", x0, y0)
end

--- 提示框的**右下角对齐小地图面板的右上角**：贴在地图上沿、右边缘齐平。
--- 长得顶出屏幕顶边就改挂在面板下方（顶边贴面板底边）；小地图模块没开就退回跟随光标。
local function PlaceMinimap(tip)
    local minimap = ns:GetModule("Minimap")
    local panel = minimap and minimap.panel
    -- 面板是我们自己造的框（MonetUIMinimapPanel），但模块关掉时它是隐藏的：
    -- 隐藏时锚上去等于锚在一个看不见的位置，宁可直接退回光标。
    if not panel or not Secrets.Bool(panel:IsShown(), false) then
        PlaceCursor(tip)
        return
    end

    local ui = _G.UIParent
    local gap = MM_GAP * (Media:Mult() or 1)
    local w, h = tip:GetWidth() or 0, tip:GetHeight() or 0
    local right, top = panel:GetRight() or 0, panel:GetTop() or 0
    local uiH = ui and ui:GetHeight() or 0

    -- 面板被拖动 / 提示框内容变长都要重摆；两者没变就不写。
    local key = string.format("%.2f:%.2f:%.2f:%.2f", right, top, w, h)
    if key == mmKey then return end
    mmKey = key

    tip:ClearAllPoints()
    if uiH > 0 and h > 0 and top + gap + h > uiH then
        -- 上面放不下：挂到面板下方，仍然右对齐
        tip:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -gap)
    else
        tip:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", 0, gap)
    end
end

--- 按当前模式摆位。off 什么都不做（让暴雪的锚点留着）。
local function ApplyPlacement(tip)
    if mode == "cursor" then
        PlaceCursor(tip)
    elseif mode == "minimap" then
        PlaceMinimap(tip)
    end
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
    cursorKey, mmKey = nil, nil
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
        ApplyPlacement(tip)
        Enrich(tip)
        return
    end

    -- 每帧都过一遍：光标模式靠 cursorKey 去重、小地图模式靠 mmKey 去重，
    -- 两边都只在"位置或尺寸真的变了"时才写布局。
    ApplyPlacement(tip)

    scanAcc = scanAcc + (elapsed or 0)
    if scanAcc < SCAN then return end
    scanAcc = 0
    Enrich(tip)
end

local function Install()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", Tick)
    -- **不设 SetClampedToScreen**：引擎的夹取会和我们每帧写的锚点是两套写手，
    -- 贴边时位置会互相拉扯（"乱跑"的另一个来源）。夹取在 PlaceCursor 里自己算，结果确定。
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function M:Apply()
    mode     = ResolveMode(self)
    enrich   = self:GetSetting("enrich") and true or false
    idsByAlt = self:GetSetting("idsByAlt") and true or false
    -- 开关变了：记账清零，下一次扫描按新设置重来。
    -- 注意**不 Hide**（以前的毛病：取消勾选会把正在看的提示框直接收掉）。
    local tip = _G.GameTooltip
    if tip then Reset(tip) end
end

function M:Initialize()
    mode     = ResolveMode(self)
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
        mode, enrich, idsByAlt = "off", false, false
        local tip = _G.GameTooltip
        if tip then Reset(tip) end
    end
end

ns:Register("Tooltip", M)
