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
-- 内容（只保留两样，其余在 HANDOFF 3.13 里写了为什么砍）：
--   * 单位：一行「目标: <名字>」—— 这个单位正在打谁（名字用职业色，NPC 用高光色）；
--   * Alt：一行 ID —— 单位是 NPC ID（GUID 里的 creature 编号）、物品是 itemID、法术是 spellID。
--   这两行画在**我们自己的小框**里（挂在提示框下沿，1px 主题色边框），不用 tooltip:AddLine ——
--   本客户端的提示框是数据行驱动的，追加的行会被下一次重填抹掉（HANDOFF 3.18）。
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
    -- 战斗中提示框宽高可能是机密值（内容源自战斗数据）：机密时按 0 处理，
    -- 只跟随光标、跳过宽度偏移与屏幕夹取，避免对机密值做算术/比较。
    if Secrets.IsSecret(w) then w = 0 end
    if Secrets.IsSecret(h) then h = 0 end
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
    if Secrets.IsSecret(w) then w = 0 end
    if Secrets.IsSecret(h) then h = 0 end
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
--- **机密单位令牌一律当"读不到"**：受限时 GetUnit 会把 unit 也标成机密，
--- `type(x) == "string"` 对它照样成立（所以不能只判类型），而机密串一旦进
--- `table.concat` / `..` 就会抛 `invalid value (secret)`（2026-10-26 实机报的就是这条）。
local function TooltipUnit(tip)
    if type(tip.GetUnit) ~= "function" then return nil end
    local ok, _, unit = pcall(tip.GetUnit, tip)
    if not ok or type(unit) ~= "string" then return nil end
    if Secrets.IsSecret(unit) then return nil end
    return unit
end

--- 指纹用的安全拼接：机密值换成 "?"，永远不让 concat 碰到它。
local function SafeSig(parts)
    local out = {}
    for i = 1, #parts do
        local v = parts[i]
        if type(v) ~= "string" then v = tostring(v) end
        if Secrets.IsSecret(v) then v = "?" end
        out[#out + 1] = v
    end
    return table.concat(out, "\1")
end

--- 附加信息画在**我们自己的小框**里，不用 tooltip:AddLine。
-- 原因（2026-10-26 实机）：本客户端的 GameTooltip 是**数据行驱动**的，动作条冷却 / 信息栏 /
-- 单位框都会不停地重填整个框，我们追加的行下一拍就被抹掉 —— 表现就是"按下 Alt 只闪一次 ID，
-- 然后再也看不到"。画在自己的框里，内容、颜色、1px 边框全归我们管，谁也抹不掉。
local BOX_PAD    = 5      -- 内边距（物理像素）
local BOX_GAP    = 2      -- 与提示框之间的缝（物理像素）
local BOX_FONT   = 12     -- 字号（UI 单位）
local BOX_SLACK  = 3      -- 行间补白（UI 单位）

local box, boxLines = nil, {}
local boxW, boxH    -- 小框尺寸由我们自己 SetSize 写入，这里记账；**不问客户端** ——
                    -- 小框锚在 GameTooltip 上，锚定链受限时 box:GetWidth/GetHeight 会变机密，
                    -- 而 tip:GetWidth 同一时刻可以是明文（机密按"锚"判，不按上游宽度判，2026-10-27 实机）。

local function EnsureBox()
    if box then return box end
    box = ns.Widget:CreateFrame("MonetUITooltipExtra", _G.UIParent, 160, 24)
    box:SetFrameStrata("TOOLTIP")            -- 和 GameTooltip 同层
    box:EnableMouse(false)
    -- 和提示框同一套外观：1px 主题色边框 + 近黑底（边框色由 Widget:Theme 跟主题刷新）
    ns.Widget:Theme(box, { thickness = 1, bgAlpha = 0.95, borderAlpha = 1 })
    box:Hide()
    return box
end

local function BoxLine(index)
    local fs = boxLines[index]
    if fs then return fs end
    fs = ns.Widget:Font(box, BOX_FONT, "pixel", "neutral", "LEFT")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    boxLines[index] = fs
    return fs
end

--- 把附加行画到小框里：lines = { { text =, r =, g =, b = }, ... }。
--- sig 没变就只做对齐，不重写文字（避免每 0.05 秒 SetText 一遍）。
local function UpdateBox(tip, lines, sig)
    if #lines == 0 then
        if box then box:Hide() end
        Mark(tip, "boxSig", nil)
        return
    end
    EnsureBox()

    local mult = Media:Mult() or 1
    local pad  = BOX_PAD * mult
    local gap  = BOX_GAP * mult

    if Marked(tip, "boxSig") ~= sig then
        Mark(tip, "boxSig", sig)
        local y = -pad
        local widest = 0
        local measured = false   -- 只要有一行拿到明文尺寸就算测过
        for i = 1, math.max(#lines, #boxLines) do
            local fs = BoxLine(i)
            local line = lines[i]
            if line then
                fs:SetText(line.text)
                fs:SetTextColor(line.r, line.g, line.b)
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", box, "TOPLEFT", pad, y)
                fs:Show()
                local w = fs:GetStringWidth() or 0
                local h = fs:GetStringHeight() or BOX_FONT
                -- 战斗受限时提示框几何是机密值，而小框锚在它上面 —— GetStringWidth/Height
                -- 标着 SecretWhenAnchoringSecret，会跟着变机密。机密就放弃这一行的测量：
                -- 宽度不参与 widest（框宽保留上一次的），行高退回字号（布局不塌）。
                if Secrets.IsSecret(w) then w = 0 else measured = true end
                if Secrets.IsSecret(h) then h = BOX_FONT end
                if w > widest then widest = w end
                y = y - (h + BOX_SLACK)
            else
                fs:Hide()
            end
        end
        if measured then
            boxW, boxH = math.max(widest + pad * 2, 80), -y + pad
            box:SetSize(boxW, boxH)
        end
    end

    -- 宽度跟着提示框走：内容变宽时小框不会短一截。
    -- 比较用**记账值** boxW（我们自己写的尺寸），不读 box:GetWidth —— 它会变机密（见上）。
    local tipW = tip:GetWidth() or 0
    if Secrets.IsSecret(tipW) then tipW = 0 end   -- 机密时不同步宽度（0 → 跳过）
    if tipW > 0 and boxW and math.abs(boxW - tipW) > 0.5 then
        boxW = math.max(tipW, 80)
        box:SetWidth(boxW)
    end

    -- 挂提示框下沿；屏幕底部放不下就挂上沿（只看几何，不会来回）
    local uiH = _G.UIParent and _G.UIParent:GetHeight() or 0
    local tipBottom = tip:GetBottom() or 0
    local below
    if Secrets.IsSecret(tipBottom) then
        below = true   -- 机密时固定挂提示框下方，避免对机密值比较
    else
        below = (uiH <= 0) or (tipBottom > (boxH or 0) + gap)
    end
    local side = below and "below" or "above"
    if Marked(tip, "boxSide") ~= side then
        Mark(tip, "boxSide", side)
        box:ClearAllPoints()
        if below then
            box:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -gap)
        else
            box:SetPoint("BOTTOMLEFT", tip, "TOPLEFT", 0, gap)
        end
    end

    box:Show()
end

--- Creature / Vehicle / Pet 的 GUID 里，NPC ID 在第 6 段：
---   Creature-0-3922-1-12685-167032-00005FF815  →  167032
--- 旧的 `^Creature%-(%d+)` 抓的是第 2 段的固定 "0"，所以所有 NPC 都显示 NPC ID: 0
--- （玩家 2026-10-27 实机报的就是这个）。段数对不上就返回 nil，宁可少显示一行。
local function NPCIdFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    if type(id) ~= "string" then return nil end
    if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then return id end
    return nil
end

--- 收集要显示的附加行：目标行（开关 enrich）+ Alt 的 ID 行（开关 idsByAlt）。
local function CollectLines(tip)
    local lines = {}
    local unit = TooltipUnit(tip)

    -- 「目标: 谁」—— 这个单位正在打谁
    if enrich and unit then
        local target = unit .. "target"
        if Secrets.Bool(UnitExists(target), false) then
            local ok, name = pcall(UnitName, target)
            name = ok and Plain(name) or nil
            if name and name ~= "" then
                -- 静态文字一律 neutral（DESIGN-LANGUAGE §3/§7-a）：目标的目标本来只想要"能读"，
                -- 职业色是**身份**信息、只在该单位是玩家时用；NPC 的兜底色从 highlight（职业色）
                -- 改成 neutral，免得战士看谁都是红的。
                local r, g, b = Color:GetNeutral()
                if Secrets.Bool(UnitIsPlayer(target), false) then
                    local okc, classFile = pcall(UnitClassBase, target)
                    classFile = okc and Plain(classFile) or nil
                    if classFile then
                        local cr, cg, cb = Color:ClassColor(classFile)
                        if cr then r, g, b = cr, cg, cb end
                    end
                end
                lines[#lines + 1] = { text = TARGET_LABEL .. ": " .. name, r = r, g = g, b = b }
            end
        end
    end

    -- Alt：单位 = NPC ID（GUID 里的 creature/vehicle 编号），物品 = itemID，法术 = spellID
    if idsByAlt and _G.IsAltKeyDown and _G.IsAltKeyDown() then
        local label, id
        if unit then
            local ok, guid = pcall(UnitGUID, unit)
            guid = ok and Plain(guid) or nil
            if type(guid) == "string" then
                id = NPCIdFromGUID(guid)
                label = NPC_ID_LABEL
            end
        else
            if type(tip.GetItem) == "function" then
                local ok, _, link = pcall(tip.GetItem, tip)
                link = ok and Plain(link) or nil
                if type(link) == "string" then
                    local itemID = link:match("item:(%d+)")
                    if itemID then label, id = ITEM_ID_LABEL, itemID end
                end
            end
            if not id and type(tip.GetSpell) == "function" then
                local ok, _, spellID = pcall(tip.GetSpell, tip)
                -- `spellID ~= nil` 不能写在 Secrets.Number 前面：受限时它是机密数字，
                -- 这一句比较本身就是被拦调用（pcall 的 ok 是普通值，被 pcall 的返回值不是）。
                local n = ok and Secrets.Number(spellID) or nil
                if n then label, id = SPELL_ID_LABEL, tostring(n) end
            end
        end
        if id then
            local r, g, b = Color:GetNeutral()
            lines[#lines + 1] = { text = label .. ": " .. id, r = r, g = g, b = b }
        end
    end

    return lines
end

--- 法术 / 光环提示的标题统一成主题中性色。
---
--- 暴雪按"法术品质"把标题染成金色（实机 2026-11-01：`飞行模式：驭空术` = 1.00,0.82,0.00），
--- 而单位提示的标题是白色 —— 两种提示框的标题色不一致，也和 docs/DESIGN-LANGUAGE.md
--- 的决策 a（通用静态文字用 neutral，highlight 只给 hover/选中/焦点）冲突。
---
--- **只动法术类**：物品提示的品质色（橙装 / 紫装）是有信息量的，保留。
--- 判据：`GameTooltip:GetSpell()` 拿得到 spellID，且没有物品链接。
--- 受限状态下 spellID 是**机密数字** → 判不出来就不动（宁可留金色，不要瞎猜）。
local function RecolorSpellTitle(tip)
    if type(tip.GetSpell) ~= "function" then return end
    local ok, _, spellID = pcall(tip.GetSpell, tip)
    if not ok or not Secrets.Number(spellID) then return end

    if type(tip.GetItem) == "function" then
        local okI, _, link = pcall(tip.GetItem, tip)
        local l = okI and Plain(link) or nil
        if type(l) == "string" and l:find("item:") then return end
    end

    local line = (type(tip.GetLine) == "function" and tip:GetLine(1)) or _G.GameTooltipTextLeft1
    if not line or type(line.SetTextColor) ~= "function"
       or type(line.GetTextColor) ~= "function" then return end

    local r, g, b = Color:GetNeutral()
    if not r then return end
    local okC, cr, cg, cb = pcall(line.GetTextColor, line)
    if okC and Secrets.Number(cr) and Secrets.Number(cg) and Secrets.Number(cb) then
        if math.abs(cr - r) < 0.01 and math.abs(cg - g) < 0.01 and math.abs(cb - b) < 0.01 then
            return                                  -- 已经是我们的颜色：不重复写
        end
    end
    pcall(line.SetTextColor, line, r, g, b)
end

--- 补一次内容：算签名，没变就只对齐小框；变了（换目标 / 按 Alt / 换物品）才重写文字。
local function Enrich(tip)
    -- 标题配色属于"美化"本身，和「显示 ID」「补全描述」两个开关无关，所以放在早退之前
    pcall(RecolorSpellTitle, tip)

    if not enrich and not idsByAlt then
        UpdateBox(tip, {}, nil)
        return
    end

    local ok, lines = pcall(CollectLines, tip)
    if not ok or type(lines) ~= "table" then lines = {} end

    local parts = { TooltipUnit(tip) or "" }
    for i = 1, #lines do parts[#parts + 1] = lines[i].text end
    UpdateBox(tip, lines, SafeSig(parts))
end

-- ============================================================================
-- 驱动：一个自建帧，每帧一次；提示框隐藏时立刻返回（没有轮询开销）
-- ============================================================================

local function Reset(tip)
    Mark(tip, "boxSig", nil)
    Mark(tip, "boxSide", nil)
    if box then box:Hide() end
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

--- 收掉提示框底部的绿色生命条（GameTooltipStatusBar）。
-- 玩家 2026-10-27：它贴在提示框最下沿，正好和我们补的「目标 / ID」小框抢位置。
-- 手法走全仓唯一的一份 Widget:Mute / Unmute（alpha 0 + 关鼠标，不 Hide；Hide 会被暴雪的
-- Show 顶回来，屏幕上一闪一闪）。
local function SuppressHealthBar(on)
    local bar = _G.GameTooltipStatusBar
    if not bar then return end
    if on then
        ns.Widget:Mute(bar, { depth = 0, combat = "write" })
    else
        ns.Widget:Unmute(bar, { depth = 0, combat = "write" })
    end
end

local function Install()
    SuppressHealthBar(true)
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
        SuppressHealthBar(false)
        local tip = _G.GameTooltip
        if tip then Reset(tip) end
    end
end

ns:Register("Tooltip", M)
