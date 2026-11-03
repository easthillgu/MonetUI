-- Modules/Tooltip/Tooltip.lua
-- 鼠标提示：**位置** + **内容增强**（精简自 Andromeda 的 modules/tooltip）。
--
-- 位置有三种摆法（设置键 anchor）：
--   cursor  —— 跟随光标；贴到屏幕右/上边缘时**翻到光标另一侧**，再越界就顶回屏幕内；
--   minimap —— 提示框的**右下角对齐小地图面板的右上角**（贴在地图上沿、右边缘齐平），
--              长得顶出屏幕顶边就改挂在面板下方；
--   off     —— 不动，用暴雪自己的锚点。
--   偏移按物理像素算（Media:Mult），不随 UI 缩放浮动。
--
-- 内容（三样，其余在 HANDOFF 3.13 里写了为什么砍）：
--   * 单位：一行「目标: <名字>」—— 这个单位正在打谁（名字用职业色，NPC 用中性色）；
--   * Alt：一行 ID —— 单位是 NPC ID（GUID 里的 creature 编号）、物品是 itemID、法术是 spellID。
--   这两行画在**我们自己的小框**里（挂在提示框下沿，1px 主题色边框），不用 tooltip:AddLine ——
--   本客户端的提示框是数据行驱动的，追加的行会被下一次重填抹掉（HANDOFF 3.18）。
--   * 正文染色（开关 neutralText）：把暴雪画在提示框里的**通用说明文字**（无彩色的属性行、
--     纯黄的描述行）归一成主题 neutral；品质 / 职业 / 套装绿 / 未达标红这些**身份信息**不碰，
--     标题行整行不参与 —— 判据与实证理由见 RecolorStaticText 的注释。
--
-- 触发（2026-11-03 改）：**暴雪自己的 tooltip 数据回调** `TooltipDataProcessor.AddTooltipPostCall`
-- —— 它在 Blizzard 每次填完数据之后叫我们一次，所以内容**不再晚一帧**，也不需要在
-- 每次重填之间空转。这一层是 FrameXML 的表，不是 `C_*` API：
-- **以前注释里写的"本客户端没有 TooltipDataProcessor（手册零命中）"是误判** ——
-- `docs/api` 快照只收 `Blizzard_APIDocumentationGenerated`，FrameXML 层的名字本来就不在里面，
-- "快照缺席 ≠ 客户端没有"（AGENTS「模板造出来没报错 ≠ 模板存在」同一条口径）。
-- 实据：本客户端装着五套插件都在用它（`Lueur/NodeScan.lua:1862`、`EnhanceQoLTooltip`、
-- `DungeonsForever/Core/TipLines.lua:858`、`Polestar/Core/Hooks.lua:229`、`EnhanceQoLVendor`）。
--
-- 为什么仍**不是钩子**：`HookScript` / `hooksecurefunc` 写的是暴雪框的脚本槽 / 方法槽，
-- AGENTS 的污染模型明令禁止（GameTooltip 也一样，`SharedTooltip_SetBackdropStyle` 都没敢 hook）。
-- post-call 不碰任何方法槽：我们只是被暴雪叫一次。
--
-- 退路：那个表或 `AllTypes` 拿不到 / 注册被拒时（`/mui tooltip diagnose` 看状态），
-- 内容层退回 250ms 兜底扫描 —— 摆位与显隐本来就靠每帧那一路，功能不因缺 API 而死。
--
-- 幂等：内容变了（换了目标 / 换了物品 / Shift 比对 / 按下 Alt）才重补一次；补完记签名，
-- 签名没变就不再碰 —— 否则往同一个提示框里反复加一行，会一直长。
-- Alt 起落走 `MODIFIER_STATE_CHANGED`（按 `idsByAlt` 开关**按需注册**，关掉就摘事件）。

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
--- 内容兜底扫描间隔（毫秒）。即时那一路是暴雪的 post-call；这里只兜两件事：
---   ①那个 FrameXML 表在本客户端拿不到（退化为纯轮询）；
---   ②"目标: 谁"这类**没有重填事件**的状态漂移（悬停期间别人的目标变了，暴雪不会重填提示框）。
--- 从 0.05s（每帧级别）降到 250ms：即时性已经由回调负责，轮询只是保险。
local CONTENT_INTERVAL_MS = 250

local mode, enrich, idsByAlt, neutralText   -- 设置缓存（每帧要读，别去翻 DB）：mode = cursor / minimap / off
local cursorKey, mmKey
local placeJob, contentJob         -- Utils/Scheduler 订阅号（本仓不再自建 OnUpdate 帧）
local wasShown, modDown            -- 提示框显隐上升沿 / Alt 当前状态
local modFrame                     -- MODIFIER_STATE_CHANGED 事件帧（按 idsByAlt 按需建/摘）
local processorState = "uninstalled"   -- uninstalled / missing / no-alltypes / registered / rejected:<err>

--- 每次暴雪填完数据给我们的载荷：`{ type =, id =, guid = }`（`data.type` 是 `Enum.TooltipDataType` 的值）。
--- 按提示框对象记（弱键：暴雪的提示框是池化的，我们不写字段、也不留引用）。
local lastPayload = setmetatable({}, { __mode = "k" })

--- type → kind 的账本（`/mui tooltip diagnose` 读的就是它）：
--- 枚举名写错、或本客户端的 type 值对不上，症状都是"ID 行安静地不出现"，
--- 所以每个见过的 type 都记一笔命中数，让"没命中"看得见。
local typeLedger = {}
local typeLedgerN = 0

-- ============================================================================
-- 设置（键：anchor / enrich / idsByAlt / neutralText，面板与 /mui 都走这里）
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
--- **不设 `SetClampedToScreen`**：引擎的夹取会和我们每帧写的锚点是两套写手，
--- 贴边时位置会互相拉扯（玩家 2026-10-26 报"乱跑"的另一个来源）。夹取在 PlaceCursor 里自己算，结果确定。
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

--- Alt 的 ID 行能不能直接从**暴雪给的载荷**拿。`data.id` 对 item / spell / aura 就是那个 ID，
--- 比我们自己再问一次 `GetItem` / `GetSpell` 好两处：
---   * 受限时那两个 getter 返回机密串 / 机密数字，每问一次就是一次"要被拦的比较"；
---   * 载荷是暴雪填完数据之后交出来的普通值，不用我们再猜一次提示框里装的是什么。
--- 单位的 NPC ID 载荷里没有（`data.id` 对 unit 不是 creature 编号），仍走 GUID 那一条。
local function IdFromPayload(payload)
    if type(payload) ~= "table" then return nil, nil end
    local id = Secrets.Number(payload.id)
    if not id then return nil, nil end
    if payload.kind == "item" then return ITEM_ID_LABEL, tostring(id) end
    if payload.kind == "spell" or payload.kind == "aura" then return SPELL_ID_LABEL, tostring(id) end
    return nil, nil
end

--- Alt 有没有按下（`IsAltKeyDown` 不受保护，两个键都算）。
local function AltDown()
    if _G.IsAltKeyDown then return Secrets.Bool(_G.IsAltKeyDown(), false) end
    return false
end

--- 收集要显示的附加行：目标行（开关 enrich）+ Alt 的 ID 行（开关 idsByAlt）。
--- payload = 暴雪回调给的那次填充（没有就退化成问提示框自己）。
local function CollectLines(tip, payload)
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
    if idsByAlt and AltDown() then
        local label, id
        if unit then
            local ok, guid = pcall(UnitGUID, unit)
            guid = ok and Plain(guid) or nil
            if type(guid) == "string" then
                id = NPCIdFromGUID(guid)
                label = NPC_ID_LABEL
            end
        else
            label, id = IdFromPayload(payload)
            if not id then
                -- 没有载荷可用（退化成轮询那一趟、或 type 没命中）：才去问提示框自己
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
        end
        if id then
            local r, g, b = Color:GetNeutral()
            lines[#lines + 1] = { text = label .. ": " .. id, r = r, g = g, b = b }
        end
    end

    return lines
end

--- 法术 / 光环提示的标题**提亮**成主题 highlight 档，正文才归一成 neutral（灰）。
---
--- 2026-11-03 前这里写的是 `Color:GetNeutral()` —— 和正文同一个灰，实机读成
--- "正文比标题还亮、标题反而发灰"（玩家报"颜色写反了"）。层级本来就该反过来：
--- **标题亮、正文灰**，highlight 是设计语言里的强调色、neutral 是通用静态文字。
---
--- 暴雪按"法术品质"把标题染成金色（实机 2026-11-01：`飞行模式：驭空术` = 1.00,0.82,0.00），
--- 而单位提示的标题是白色 —— 两种提示框的标题色不一致，统一成主题色。
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

    -- 标题走 highlight（亮档），正文走 neutral（灰档）。只取 RGB：GetHighlight 自带
    -- a = 0.5（那是洗色的强度，不是文字的），alpha 显式给 1。
    local r, g, b = Color:GetHighlight()
    if not r then return end
    local okC, cr, cg, cb = pcall(line.GetTextColor, line)
    if okC and Secrets.Number(cr) and Secrets.Number(cg) and Secrets.Number(cb) then
        if math.abs(cr - r) < 0.01 and math.abs(cg - g) < 0.01 and math.abs(cb - b) < 0.01 then
            return                                  -- 已经是我们的颜色：不重复写
        end
    end
    pcall(line.SetTextColor, line, r, g, b, 1)
end

-- ---- 正文染色：通用说明文字归一到主题 neutral --------------------------------
--
-- 判据只看**这一行此刻的颜色**，不看行号 —— 一行排第几完全由内容决定（物品八九行、
-- 法术三行、单位两行，还会随 Shift 对比、套装件数变化），按行号猜必错；
-- 而"用什么颜色画"本身就是暴雪的分类信号：
--   * 无彩色（r≈g≈b）：属性行、"需要等级"、普通说明 —— 纯白或灰白；
--   * 纯黄（r≈g 且 b 明显掉下去）：描述文字与"使用："那一族。
-- 其余一律不动：物品品质、职业色、套装/附魔的绿与蓝、未达标的红都是**身份信息**。
-- 传说装的橙（1,0.8,0）r 与 g 差 0.2，落在"r≈g"之外，不会被当成纯黄吃掉。
--
-- **第 1 行（标题）整行不参与**：标题天然就是身份 —— 物品品质色、玩家职业色、
-- 精英与首领的红。尤其精英 / 世界首领的标题正是纯黄（Quality2 = 1,1,0），
-- 这条就是"标题不碰"的实证理由。唯一被改色的标题是法术类（金色没有身份信息），
-- 那条走上面的 `RecolorSpellTitle` —— 但它是**提亮**成 highlight，不是拉平成 neutral。
local ACHROMA_SPAN = 0.06    -- 三通道最大差小于这个 → 当无彩色
local YELLOW_MIN   = 0.75    -- 纯黄的两条腿：r、g 都够亮
local YELLOW_SPAN  = 0.08    -- 且 r 与 g 基本相等
local YELLOW_MAX_B = 0.45    -- 而 b 明显掉下去

-- 上面那条"窄黄带"只认 (1,1,0) 这种纯黄，正好漏掉暴雪真正用来写**普通说明文字**的两档
-- （本客户端全局常量实测）：`NORMAL_FONT_COLOR` (1, 0.82, 0) —— r-g = 0.18，掉出窄带；
-- `LIGHTYELLOW_FONT_COLOR` (1, 1, 0.6) —— b = 0.6，掉出 b 上限。结果就是"使用："这类正文
-- 保持暴雪的亮黄，读起来比我们染灰的标题还亮（2026-11-03 玩家报"颜色写反了"）。
-- 补的是**已知常量的容差比对**，不是把窄带放宽：放宽会把神器金 (1, 0.9, 0.41)、
-- 橙装 (1, 0.5, 0) 这些**带信息量**的颜色一起拉平。
local STATIC_TEXT_COLORS = {
    { 1.00, 0.82, 0.00 },   -- NORMAL_FONT_COLOR
    { 1.00, 1.00, 0.60 },   -- LIGHTYELLOW_FONT_COLOR
    { 1.00, 1.00, 0.00 },   -- YELLOW_FONT_COLOR
}
local STATIC_TOL = 0.03

local function IsStaticTextColor(r, g, b)
    if math.max(r, g, b) - math.min(r, g, b) < ACHROMA_SPAN then return true end
    if math.abs(r - g) < YELLOW_SPAN
       and r >= YELLOW_MIN and g >= YELLOW_MIN and b <= YELLOW_MAX_B then
        return true
    end
    for i = 1, #STATIC_TEXT_COLORS do
        local c = STATIC_TEXT_COLORS[i]
        if math.abs(r - c[1]) <= STATIC_TOL and math.abs(g - c[2]) <= STATIC_TOL
           and math.abs(b - c[3]) <= STATIC_TOL then
            return true
        end
    end
    return false
end

--- 逐行走提示框的文字（左列 + 右列），从第 2 行起（标题不参与，见上）。
--- 取行只用 `NumLines` + `GameTooltipTextLeft<i>` 这套 FrameXML 全局名：
--- `GameTooltip:GetLine` 不在本客户端手册里（api-audit 报 undocumented），而这个写法是
--- 参考件在**同一客户端**上用的（EnhanceQoLTooltip_Camelot.lua:1137）。
--- 行数读不出（受限）或名字拿不到就整趟什么都不做，并把 `linePathOK` 记成 false 让自检报出来 ——
--- 宁可不染色，不要猜。
local linePathOK = false
local function EachTooltipLine(tip, fn, firstIndex)
    if type(tip.NumLines) ~= "function" or type(tip.GetName) ~= "function" then return end
    local okN, num = pcall(tip.NumLines, tip)
    local n = okN and Secrets.Number(num) or nil
    local okName, name = pcall(tip.GetName, tip)
    local prefix = okName and Plain(name) or nil
    if not n or type(prefix) ~= "string" then return end
    linePathOK = true
    for i = firstIndex, n do
        fn(_G[prefix .. "TextLeft" .. i], i, "Left")
        fn(_G[prefix .. "TextRight" .. i], i, "Right")
    end
end

--- 上一趟的账（自检读它）：见到几行、改了几行。
local recolorSeen, recolorChanged = 0, 0

--- 真正动手的地方。**alpha 必须原样传回去**：暴雪用 alpha 表示"这一行被调暗了多少"
--- （不可用/置灰的属性行就是靠它），而 `SetTextColor` 少传第四个参数会把 alpha 顶成 1。
--- 四个分量有一个读不出来（机密）就跳过这一行 —— 手册给 `FontString:GetTextColor` 与
--- `GetText` 都标着 `SecretReturnsForAspect`（按规则集会返回机密值），所以这不是假想的防护。
local function RecolorStaticText(tip)
    if not neutralText then return 0, 0 end
    local r, g, b = Color:GetNeutral()
    if not r then return 0, 0 end

    local changed, seen = 0, 0
    local function Handle(fs)
        if not fs or type(fs.GetTextColor) ~= "function"
           or type(fs.SetTextColor) ~= "function" then return end
        local ok, cr, cg, cb, ca = pcall(fs.GetTextColor, fs)
        if not ok then return end
        cr, cg, cb = Secrets.Number(cr), Secrets.Number(cg), Secrets.Number(cb)
        if not (cr and cg and cb) then return end
        local a = Secrets.Number(ca)
        -- `ca ~= nil` 是机密数字也做得动的比较（AGENTS 的执法强度表），可以放心当"有没有第四个值"用
        if ca ~= nil and not a then return end
        a = a or 1
        seen = seen + 1
        if not IsStaticTextColor(cr, cg, cb) then return end
        if math.abs(cr - r) < 0.01 and math.abs(cg - g) < 0.01 and math.abs(cb - b) < 0.01 then
            return                                   -- 已经是我们的颜色：不重复写
        end
        pcall(fs.SetTextColor, fs, r, g, b, a)
        changed = changed + 1
    end

    EachTooltipLine(tip, Handle, 2)
    return changed, seen
end

--- 补一次内容：算签名，没变就只对齐小框；变了（换目标 / 按 Alt / 换物品）才重写文字。
--- payload 来自暴雪的 post-call（见文件头）；兜底扫描那一路传的是上次缓存的那份。
local function Enrich(tip, payload)
    -- 两件"美化"（法术标题、正文归一）属于美化本身，和「显示 ID」「补全描述」两个开关无关，
    -- 所以都放在早退之前。
    pcall(RecolorSpellTitle, tip)
    local okR, changed, seen = pcall(RecolorStaticText, tip)
    if okR and changed then
        recolorChanged, recolorSeen = changed, seen or recolorSeen
    end

    if not enrich and not idsByAlt then
        UpdateBox(tip, {}, nil)
        return
    end

    local ok, lines = pcall(CollectLines, tip, payload)
    if not ok or type(lines) ~= "table" then lines = {} end

    local parts = { TooltipUnit(tip) or "" }
    for i = 1, #lines do parts[#parts + 1] = lines[i].text end
    UpdateBox(tip, lines, SafeSig(parts))
end

-- ============================================================================
-- 触发层：暴雪的数据回调（即时）+ 每帧摆位 + 250ms 兜底
-- ============================================================================

local function Reset(tip)
    Mark(tip, "boxSig", nil)
    Mark(tip, "boxSide", nil)
    if box then box:Hide() end
    cursorKey, mmKey = nil, nil
    lastPayload[tip] = nil
end

--- 提示框此刻可见吗。**不直接 `tip:IsVisible()`**：读不出来（forbidden / 答案是机密）时
--- 一律当"不可见"，宁可这一拍什么都不做，也不要拿读不懂的东西当判断（AGENTS：读不懂 ≠ 不能访问，
--- 但**写侧**保守 = 不动）。
local function TooltipVisible()
    local tip = _G.GameTooltip
    if not tip or type(tip.IsVisible) ~= "function" then return nil, nil end
    local ok, visible = pcall(tip.IsVisible, tip)
    if not ok then return nil, nil end
    return tip, Secrets.Bool(visible, false)
end

--- **唯一的"现在就画"入口**：暴雪回调、Alt 起落、开关变化、兜底扫描都走它。
--- 顺序要紧：暴雪是 `SetOwner → 摆锚点 + Show → 填数据`，所以 post-call 到达时提示框**已经可见**，
--- 而每帧那路还没来得及置上升沿 —— 若这里只看 `wasShown`，即时那一路在"第一次悬停"上
--- 永远不生效，又退回到晚一帧。所以这里自己认可见性，自己补摆位。
local function RedrawNow()
    local tip, visible = TooltipVisible()
    if not tip or not visible then return end
    wasShown = true
    ApplyPlacement(tip)
    pcall(Enrich, tip, lastPayload[tip])
end

--- 每帧那一拍。现在是 `Utils/Scheduler` 的 EveryFrame 订阅，不再是本模块自己的 OnUpdate 帧
--- （AGENTS/`7108581` 同一条：全仓只留一个驱动帧）。这里只管两件事 ——
--- 摆位（内部按 key 去重，光标不动就不写布局）与显隐沿（决定我们那块小框在不在）。
--- 提示框没显示时一次 `IsVisible` 就走。
local function PlaceTick()
    local tip, visible = TooltipVisible()
    if not tip then return end

    if not visible then
        if wasShown then
            wasShown = false
            Reset(tip)
        end
        return
    end

    if not wasShown then
        RedrawNow()          -- 上升沿：摆位 + 补内容（载荷用暴雪回调给的那份）
        return
    end

    -- 每帧都过一遍：光标模式靠 cursorKey 去重、小地图模式靠 mmKey 去重，
    -- 两边都只在"位置或尺寸真的变了"时才写布局。
    ApplyPlacement(tip)
end

--- type → 我们关心的种类。**数字一律从 `Enum.TooltipDataType` 现取，不硬编码**：
--- 本客户端（1.60 / camelot）与零售的枚举值不保证一致，写死数字就是"看起来能跑、
--- 换个构建安静失灵"。命中的键名与没命中的都记账，`/mui tooltip diagnose` 读。
local kindByType, enumHit, enumMiss
local function BuildKindMap()
    local E = _G.Enum and _G.Enum.TooltipDataType
    if type(E) ~= "table" then
        enumHit, enumMiss = {}, { "Enum.TooltipDataType（整张表都没有）" }
        return nil
    end
    local want = {
        Item = "item", Toy = "item",
        Spell = "spell", Totem = "spell", UnitAura = "aura",
        Unit = "unit", Corpse = "unit", BattlePet = "unit", CompanionPet = "unit",
        Currency = "currency", Quest = "quest",
    }
    local map, hit, miss = {}, {}, {}
    for name, kind in pairs(want) do
        local value = E[name]
        if type(value) == "number" and not Secrets.IsSecret(value) then
            map[value] = kind
            hit[#hit + 1] = name .. "=" .. tostring(value) .. "→" .. kind
        else
            miss[#miss + 1] = name
        end
    end
    table.sort(hit)
    table.sort(miss)
    enumHit, enumMiss = hit, miss
    return map
end

--- 见过的 type 记一笔（诊断）。`data.type` 可能是**机密数字**，所以进字符串 / 当表键之前
--- 必须先过 `Secrets.Number`（AGENTS 的表键与 concat 两刀都在这一条上）。
local function RecordType(numericType, kind)
    local key = tostring(numericType) .. " " .. tostring(kind or "未识别")
    local n = typeLedger[key] or 0
    if n == 0 then
        if typeLedgerN >= 40 then return end   -- 封顶：账本是给人看的，不是给人淹死的
        typeLedgerN = typeLedgerN + 1
    end
    typeLedger[key] = n + 1
end

--- **暴雪填完数据之后叫我们一次** —— 这就是内容层的新触发点。
--- 这一层不碰暴雪对象的方法槽、不挂脚本、不写字段：只是被叫，所以我们没把任何东西标脏。
local function OnTooltipData(tooltip, data)
    if type(tooltip) ~= "table" or type(data) ~= "table" then return end
    -- 只做主提示框：对比框（ShoppingTooltip）与内嵌框各自也会被叫，我们那块框只跟着 GameTooltip 走
    if tooltip ~= _G.GameTooltip then return end

    local rawType = Secrets.Number(data.type)
    if not rawType then return end            -- 读不出来就不当它是某个类型（宁可少一行）

    local kind = kindByType and kindByType[rawType] or nil
    RecordType(rawType, kind)

    local payload = { kind = kind or "other", id = Secrets.Number(data.id) }
    lastPayload[tooltip] = payload

    -- 当场画：暴雪的顺序是 `SetOwner → 摆锚点 + Show → 填数据`，所以这一叫到达时提示框**已经可见**，
    -- 而每帧那路还没来得及置上升沿 —— 若在这里看 `wasShown`，即时那一路在"第一次悬停"上
    -- 永远不生效，又退回晚一帧（文件头承诺的就是这一拍不晚）。
    -- 预填 / 池化回收时它不可见，`RedrawNow` 自己问过可见性就返回；载荷已经记下，
    -- 等每帧那路的上升沿补画 —— 我们的框不会先于提示框出现，屏幕上挂一块没人要的板子。
    RedrawNow()
end

--- 注册一次就够（`TooltipDataProcessor` 没有反注册接口）。落空的状态记在 `processorState`，
--- 由诊断命令报出来 —— 这一层的全部价值就是"不再靠猜客户端有没有这个东西"。
local function RegisterProcessor()
    if processorState == "registered" then return true end
    local TDP = _G.TooltipDataProcessor
    if type(TDP) ~= "table" or type(TDP.AddTooltipPostCall) ~= "function" then
        processorState = "missing"
        return false
    end
    local all = TDP.AllTypes
    if all == nil or Secrets.IsSecret(all) then
        processorState = "no-alltypes"
        return false
    end
    local ok, err = pcall(TDP.AddTooltipPostCall, all, OnTooltipData)
    if ok then
        processorState = "registered"
        return true
    end
    processorState = "rejected: " .. (Secrets.IsSecret(err) and "?" or tostring(err))
    return false
end

--- Alt 起落是"内容没变、显示变"，唯一需要的事件就这一个。
--- 按 `idsByAlt` 开关**按需注册 / 摘除**（参考件同一手法：开关关掉连事件帧都不留）。
local function SetModifierWatch(on)
    if on and not modFrame then
        modFrame = CreateFrame("Frame")
        modDown = AltDown()
        modFrame:SetScript("OnEvent", function()
            local down = AltDown()
            if down == modDown then return end    -- 其它修饰键的起落不算我们的事
            modDown = down
            RedrawNow()
        end)
        modFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    elseif not on and modFrame then
        modFrame:UnregisterAllEvents()
        modFrame:SetScript("OnEvent", nil)
        modFrame = nil
        modDown = nil
    end
end

--- 订阅起停（和姓名板的 `SyncGuard` 同一条规矩：无事可做就整条停，
--- 不给调度器留一条空转订阅；模块关掉了 frame 也一并摘掉）。
local function SyncJobs()
    local needFrame   = (mode ~= "off") or enrich or idsByAlt
    -- 正文染色也算"要内容"：暴雪每次重填都会把颜色画回去，靠 post-call + 这一拍兜底重刷。
    local needContent = enrich or idsByAlt or neutralText

    if needFrame then
        if not placeJob then placeJob = ns.Scheduler:EveryFrame(PlaceTick) end
    elseif placeJob then
        ns.Scheduler:Unregister(placeJob)
        placeJob = nil
        wasShown = false
        if _G.GameTooltip then Reset(_G.GameTooltip) end
    end

    if needContent then
        if not contentJob then contentJob = ns.Scheduler:Every(CONTENT_INTERVAL_MS, RedrawNow) end
    elseif contentJob then
        ns.Scheduler:Unregister(contentJob)
        contentJob = nil
    end

    SetModifierWatch(needContent)
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
    if not kindByType then kindByType = BuildKindMap() end
    RegisterProcessor()
    SyncJobs()
end

-- ============================================================================
-- 自检：`/mui tooltip diagnose`
-- ============================================================================
--- 这一趟要回答的是三件事：①那个 FrameXML 表在不在、注册成没成（我们**曾经误判它不存在**，
--- 依据是 `docs/api` 零命中，而快照只收 `C_*`）；②`Enum.TooltipDataType` 里那些键名在本客户端
--- 对不对得上（写错就是"ID 行安静地不出现"，没有报错）；③运行期真见过哪些 type。
function M:Diagnose(verbose)
    -- 每一行既打到聊天框也记进 rows：type 账本最多 40 行，加上表头一定超出聊天框能留住的
    -- 十几行（AGENTS「结果只认账本」同一条），所以末尾整本存进 SavedVariables。
    local rows = {}
    local function Say(line)
        rows[#rows + 1] = line
        ns:Print(line)
    end

    local TDP = _G.TooltipDataProcessor
    local allTypes = (type(TDP) == "table") and TDP.AllTypes or nil
    local allText
    if allTypes == nil then
        allText = "无"
    else
        -- 它是数字还是别的什么，本仓没有实测过：数字就报数字，不是数字只报类型，
        -- 别拿 tostring(table) 的地址当"值"糊弄看账的人。
        local n = Secrets.Number(allTypes)
        allText = n and tostring(n) or ("非数字(" .. type(allTypes) .. ")")
    end

    Say("---- 鼠标提示自检 ----")
    Say(("TooltipDataProcessor：表=%s，AddTooltipPostCall=%s，AllTypes=%s｜注册状态=%s"):format(
        type(TDP),
        (type(TDP) == "table" and type(TDP.AddTooltipPostCall) == "function") and "有" or "无",
        allText, processorState))
    Say(("Enum.TooltipDataType：命中 %d 个，缺席 %d 个"):format(
        enumHit and #enumHit or 0, enumMiss and #enumMiss or 0))
    if enumHit and #enumHit > 0 then Say("  认得：" .. table.concat(enumHit, ", ")) end
    if enumMiss and #enumMiss > 0 then Say("  没这个键名：" .. table.concat(enumMiss, ", ")) end

    local tip = _G.GameTooltip
    Say(("设置：位置=%s｜补全描述=%s｜Alt 显示 ID=%s｜正文归一=%s"):format(
        tostring(mode), enrich and "开" or "关", idsByAlt and "开" or "关",
        neutralText and "开" or "关"))
    -- 正文染色的账：`取行路径` 是 NumLines + GameTooltipTextLeft<i> 那套能不能走通
    -- （走不通就是"染色安静地不生效"，和枚举键名写错同一类毛病）；
    -- 后两个数只反映**上一趟**，所以自检要边悬停边跑。
    Say(("正文归一：取行路径=%s｜上一趟 见 %d 行 / 改 %d 行（neutral=%s）"):format(
        linePathOK and "可用" or "没走通", recolorSeen, recolorChanged,
        (function()
            local r, g, b = Color:GetNeutral()
            return r and ("%.2f,%.2f,%.2f"):format(r, g, b) or "读不出"
        end)()))
    Say(("订阅：每帧摆位=%s｜兜底扫描=%s（%dms）｜Alt 事件帧=%s"):format(
        placeJob and "在" or "无", contentJob and "在" or "无", CONTENT_INTERVAL_MS,
        modFrame and "在" or "无"))
    -- 可见性一律走 `TooltipVisible`（pcall + Secrets.Bool）：GameTooltip 属于可能被引擎
    -- 临时禁读的框，直接 `tip:IsVisible()` 会抛（AGENTS：三个 Watch 驱动都为此设了这道漏斗）。
    local _, tipVisible = TooltipVisible()
    Say(("驱动提示框：GameTooltip=%s，可见性=%s，我们的小框=%s"):format(
        tip and "有" or "无",
        tip and (tipVisible and "可见" or "不可见/读不出") or "-",
        (box and box:IsShown()) and "显示" or "隐藏"))

    local keys = {}
    for k in pairs(typeLedger) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return (typeLedger[a] or 0) > (typeLedger[b] or 0) end)
    if #keys == 0 then
        Say("type 账本：还没被暴雪回调叫过（悬停一个物品/单位再跑一次）。")
    else
        local shownCount = verbose and #keys or math.min(8, #keys)
        Say(("type 账本（共 %d 种，按次数排）："):format(#keys))
        for i = 1, shownCount do
            Say(("  %-18s ×%d"):format(keys[i], typeLedger[keys[i]]))
        end
        if #keys > shownCount then
            Say(("  ……另 %d 种：/mui tooltip diagnose all"):format(#keys - shownCount))
        end
    end

    -- 落盘（读法同 `compatReport`：**写盘比 /reload 晚 1–2 分钟**，别跑完立刻去读）：
    --   <游戏目录>/WTF/Account/<账号>/SavedVariables/MonetUI.lua 里的 tooltipDiag
    local ok, db = pcall(function() return ns:DB() end)
    if ok and type(db) == "table" then
        db.tooltipDiag = {
            when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil,
            processorState = processorState,
            allTypes = allText,
            rows = rows,
        }
        Say(("（全量 %d 行已存 MonetUIDB.tooltipDiag，WTF 里可直接读）"):format(#rows))
    end
end

-- ============================================================================
-- 生命周期
-- ============================================================================

--- 四个设置一次读进缓存（每帧 / 每次回调都要读，别去翻 DB）。
--- Apply / Initialize / SetEnabled 三个入口共用这一份 —— 加一个键漏一处，
--- 症状是"面板上改了要重载才生效"，静态闸门抓不出来。
local function ReadSettings(self)
    mode        = ResolveMode(self)
    enrich      = self:GetSetting("enrich") and true or false
    idsByAlt    = self:GetSetting("idsByAlt") and true or false
    neutralText = self:GetSetting("neutralText") and true or false
end

function M:Apply()
    ReadSettings(self)
    -- 开关变了：记账清零，下一拍按新设置重来。
    -- 注意**不 Hide 提示框**（以前的毛病：取消勾选会把正在看的提示框直接收掉）；
    -- SyncJobs 只会收掉**我们自己的**那块小框。
    SuppressHealthBar(true)
    SyncJobs()
    RedrawNow()
end

function M:Initialize()
    ReadSettings(self)
    Install()
end

--- 模块开关：关掉只是让跟随、增强、Alt 与正文染色失效；`TooltipDataProcessor` 那层
--- **没有反注册接口**，所以回调留着（它先问开关），下次打开零成本。
function M:SetEnabled(value)
    if value then
        self:Apply()
        Install()
    else
        mode, enrich, idsByAlt, neutralText = "off", false, false, false
        SuppressHealthBar(false)
        SyncJobs()          -- 订阅整条摘掉 + 我们的小框收掉（Reset 在里面）
    end
end

--- `/mui tooltip probe colors`：把**此刻**提示框每一行的颜色与文字记进 SavedVariables。
--- 为什么要它：正文归一的判据是"按颜色分类"，而 1.60 上到底哪些行是白 / 灰 / 黄、
--- 哪些是品质色与职业色，本仓没有实测过（`docs/api` 快照也不收这些行）。
--- 悬停一件物品、一个单位、一个法术各跑一次，然后读
---   WTF/Account/<账号>/SavedVariables/MonetUI.lua 里的 tooltipProbe
--- 每行给：序号、左右列、颜色四分量、我们把它判成"静态"还是"身份"、文字前 40 字。
--- 判错的行就改 `IsStaticTextColor` 的那四个阈值 —— 有这本账才谈得上调参。
function M:ProbeLineColors()
    local tip = _G.GameTooltip
    local _, visible = TooltipVisible()
    if not tip or not visible then
        ns:Print("提示框此刻没显示：先用鼠标悬停一个物品 / 单位 / 法术，再跑一次。")
        return
    end

    local rows = {}
    local function Handle(fs, i, side)
        if not fs or type(fs.GetText) ~= "function" or type(fs.GetTextColor) ~= "function" then return end
        local okT, text = pcall(fs.GetText, fs)
        local t = (okT and Plain(text)) or ""
        if t ~= "" then
            t = (t:gsub("|c%x+", "")):gsub("|r", "")     -- 行内色码只是噪声，去掉再记账
        else
            t = "(空)"
        end
        local okC, cr, cg, cb, ca = pcall(fs.GetTextColor, fs)
        local r = okC and Secrets.Number(cr) or nil
        local g = okC and Secrets.Number(cg) or nil
        local b = okC and Secrets.Number(cb) or nil
        local a = okC and Secrets.Number(ca) or nil
        local verdict
        if r and g and b then
            verdict = IsStaticTextColor(r, g, b) and "静态" or "身份"
        else
            verdict = "读不出"
        end
        rows[#rows + 1] = ("%2d %-5s %-16s a=%-5s %-6s %s"):format(
            i, side,
            (r and g and b) and ("%.2f,%.2f,%.2f"):format(r, g, b) or "机密/读不出",
            a and ("%.2f"):format(a) or "-",
            verdict, t:sub(1, 40))
    end

    EachTooltipLine(tip, Handle, 1)     -- 探针从第 1 行起（要连标题的身份色一起看）

    local ok, db = pcall(function() return ns:DB() end)
    if ok and type(db) == "table" then
        db.tooltipProbe = {
            when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil,
            lines = rows,
        }
    end
    ns:Print(("提示框逐行颜色 %d 行：已存 MonetUIDB.tooltipProbe（WTF 里可直接读，写盘比 /reload 晚 1–2 分钟）"):format(#rows))
    if not linePathOK then
        ns:Print("取行路径没走通：NumLines / GameTooltipTextLeft<i> 在本客户端拿不到 —— 正文归一不会生效。")
    end
end

--- `/mui tooltip diagnose`（另收 `diag`；`all` = 打完整个 type 账本）
function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub == "diagnose" or sub == "diag" or sub == "" then
        self:Diagnose(false)
        return true
    end
    if sub == "diagnose all" or sub == "diag all" or sub == "all" then
        self:Diagnose(true)
        return true
    end
    if sub == "probe" or sub == "probe colors" or sub == "colors" then
        self:ProbeLineColors()
        return true
    end
    return false
end

ns:Register("Tooltip", M)
