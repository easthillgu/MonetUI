-- Modules/InfoBar/Currency.lua
-- 信息栏「货币」块的自定义监控：清单来自角色面板 → 货币 子标签的那张表
-- （1.60 · Blizzard_TokenUI/Camelot/Blizzard_TokenUI.lua:382 的 TokenFrame:Update 就是
--  `GetCurrencyListSize` + `GetCurrencyListInfo` 逐行读出来的），所以这里和玩家在面板里
--  看到的代币是同一份数据，不另造一份名单。
--
-- 三档来源：
--   backpack = 沿用客户端 `isShowInBackpack`（背包条旁边显示的那几项，旧行为）；
--   custom   = 玩家自己勾的 currencyID 清单（跨角色保留，当前角色没发现也能按 ID 读）；
--   all      = 当前货币页里所有已发现项。
--
-- 所有来自游戏的字段都过 Secrets 漏斗：布尔用 Bool（`isHeader` / `isShowInBackpack` 在受限
-- 窗口可能是机密布尔），数字用 Number，名字要进 format / concat 还得再过 CanRead。
-- `GetCurrencyInfo(id)` 是自定义档的兜底：货币页那张表在折叠分类 / LoD 未加载时会缺项，
-- 直接按 ID 问客户端就不会让已配置的监控项凭空消失。

local ADDON_NAME, ns = ...
local M = ns.InfoBar
if not M then return end

local Secrets = ns.Secrets
local Widget  = ns.Widget

local C = {}
M.Currency = C

local MODE_LABEL = {
    backpack = "跟随背包显示",
    custom   = "自定义监控",
    all      = "全部已发现",
}
local MODE_ORDER = { "backpack", "custom", "all" }
local LIST_CAP   = 400   -- 货币页理论上可能很长；只读前 400 行，防异常客户端返回巨值

local function Settings() return M:Settings() end

local function Raw(key)
    local value = Settings()[key]
    if value == nil then
        local defaults = ns.DEFAULTS and ns.DEFAULTS.infobar
        value = defaults and defaults[key]
    end
    return value
end

local function Num(value) return Secrets.Number(value) end

local function ReadableName(value)
    if type(value) ~= "string" or value == "" then return nil end
    -- 判完类型还要再问一次可读性：机密串的 type() 照样是 "string"，
    -- 进 format / concat 会抛 invalid value (secret)。
    if not Secrets.CanRead(value) then return nil end
    return value
end

function C:Mode()
    local mode = Raw("currencyMode")
    if mode ~= "custom" and mode ~= "all" then return "backpack" end
    return mode
end

function C:ModeLabel(mode)
    return MODE_LABEL[mode or self:Mode()] or "?"
end

--- 永远返回**存档里那张表**；缺了就地建，绝不写进 ns.DEFAULTS（那是共享默认表）。
function C:Watch()
    local s = Settings()
    if type(s.currencyWatch) ~= "table" then s.currencyWatch = {} end
    return s.currencyWatch
end

function C:MaxOnBar()
    local n = math.floor(Num(Raw("currencyMax")) or 3)
    if n < 1 then n = 1 end
    if n > 8 then n = 8 end
    return n
end

function C:ShowZero()
    return Raw("currencyShowZero") ~= false
end

-- 最近一次成功读到的值。受限窗口里 quantity 变成机密时用它顶一拍，
-- 免得格子在战斗里忽明忽暗；只在内存里，不落盘。
local valueCache = {}

--- 把一份 CurrencyInfo（列表行或按 ID 查回来的）翻成我们自己的普通表。
--- base = 同一 ID 上一轮的读数，用来补这次读不到的字段。
local function EntryFromInfo(info, base)
    if type(info) ~= "table" then return nil end
    local id = Num(info.currencyID) or Num(base and base.id)
    if not id or id < 1 then return nil end

    local cached = valueCache[id]
    local name = ReadableName(info.name) or (base and base.name) or (cached and cached.name)
    local qty  = Num(info.quantity)
    if qty == nil then qty = (base and base.quantity) or (cached and cached.quantity) end
    if not name or qty == nil then return nil end

    local maxQ = Num(info.maxQuantity)
    if maxQ == nil then maxQ = (base and base.maxQuantity) or (cached and cached.maxQuantity) end
    local icon = Num(info.iconFileID)
    if icon == nil then icon = (base and base.icon) or (cached and cached.icon) end

    local entry = {
        id          = id,
        name        = name,
        quantity    = qty,
        maxQuantity = maxQ,
        icon        = icon,
        backpack    = Secrets.Bool(info.isShowInBackpack, (base and base.backpack) or false),
    }
    valueCache[id] = { id = id, name = name, quantity = qty, maxQuantity = maxQ, icon = icon }
    return entry
end

--- 背包条自己那份"已关注"清单（BackpackTokenFrameMixin:Update 走的就是它）。
--- 货币页那张表还没加载时，这是背包档最可靠的兜底。
function C:BackpackIDs()
    local api = _G.C_CurrencyInfo
    if not api or type(api.GetBackpackCurrencyInfo) ~= "function" then return {} end
    local out = {}
    for i = 1, 8 do
        local ok, info = pcall(api.GetBackpackCurrencyInfo, i)
        if not ok or type(info) ~= "table" then break end
        local id = Num(info.currencyTypesID)
        if not id or id < 1 then break end
        out[#out + 1] = id
    end
    return out
end

--- 当前可读的货币全集：先按货币页列表顺序取，再把"清单里没有、但玩家已经勾过 /
--- 背包条正在显示"的 ID 按 ID 补问一遍。返回 (list, byID)。
--- extraIDs 是可选的额外待补 ID（背包兜底用）。
function C:Available(extraIDs)
    local api = _G.C_CurrencyInfo
    local list, byID = {}, {}

    if api and type(api.GetCurrencyListSize) == "function"
       and type(api.GetCurrencyListInfo) == "function" then
        local ok, size = pcall(api.GetCurrencyListSize)
        size = ok and Num(size) or nil
        if size and size > 0 then
            if size > LIST_CAP then size = LIST_CAP end
            for i = 1, size do
                local okInfo, info = pcall(api.GetCurrencyListInfo, i)
                if okInfo and type(info) == "table" then
                    -- 机密布尔一律按"不是表头"处理：机密期把整张表当表头会让格子直接空白
                    -- （旧实现就是这个默认值）。真正的过滤靠 currencyID —— 分类表头
                    -- 没有 currencyID，EntryFromInfo 会把它们自然丢掉。
                    if not Secrets.Bool(info.isHeader, false) then
                        local entry = EntryFromInfo(info, nil)
                        if entry and not byID[entry.id] then
                            byID[entry.id] = entry
                            list[#list + 1] = entry
                        end
                    end
                end
            end
        end
    end

    local probe, seen = {}, {}
    local watch = self:Watch()
    for i = 1, #watch do
        local id = Num(watch[i])
        if id and not seen[id] then seen[id] = true; probe[#probe + 1] = id end
    end
    if extraIDs then
        for i = 1, #extraIDs do
            local id = extraIDs[i]
            if id and not seen[id] then seen[id] = true; probe[#probe + 1] = id end
        end
    end

    if api and type(api.GetCurrencyInfo) == "function" then
        for i = 1, #probe do
            local id = probe[i]
            if not byID[id] then
                local okInfo, info = pcall(api.GetCurrencyInfo, id)
                if okInfo then
                    -- 暴雪自己在 Blizzard_Professions.lua:1490 都要回填
                    -- `currencyInfo.currencyID = currencyTypesID` —— 按 ID 查回来的表里
                    -- 这个字段不保证存在，所以 base 必须带上我们正在问的那个 ID。
                    local entry = EntryFromInfo(info, valueCache[id] or { id = id })
                    if entry then
                        entry.hiddenFromList = true
                        byID[entry.id] = entry
                        list[#list + 1] = entry
                    end
                end
            end
        end
    end

    return list, byID
end

local function EffectiveIDs(list, backpackIDs)
    local mode = C:Mode()
    local ids, seen = {}, {}
    local function add(id)
        if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end

    if mode == "custom" then
        local watch = C:Watch()
        for i = 1, #watch do add(Num(watch[i])) end
    elseif mode == "all" then
        for i = 1, #list do add(list[i].id) end
    else
        for i = 1, #list do
            if list[i].backpack then add(list[i].id) end
        end
        if #ids == 0 and backpackIDs then
            for i = 1, #backpackIDs do add(backpackIDs[i]) end
        end
    end
    return ids, mode
end

--- 一次给渲染层全部答案：(entries, missing, mode, allList)
--- entries 已按"是否显示 0 值"过滤，但**没**按条上上限截断（提示框要看全）。
function C:Snapshot()
    local backpackIDs = (self:Mode() == "backpack") and self:BackpackIDs() or nil
    local list, byID = self:Available(backpackIDs)
    local ids, mode = EffectiveIDs(list, backpackIDs)
    local entries, missing = {}, 0
    for i = 1, #ids do
        local entry = byID[ids[i]]
        if not entry then
            missing = missing + 1
        elseif entry.quantity ~= 0 or self:ShowZero() then
            entries[#entries + 1] = entry
        end
    end
    return entries, missing, mode, list
end

function C:FormatQuantity(value)
    local n = Num(value)
    if not n then return "?" end
    n = math.floor(n + 0.5)
    if n >= 100000000 then return string.format("%.1f亿", n / 100000000) end
    if n >= 10000 then return string.format("%.1f万", n / 10000) end
    return tostring(n)
end

--- 条身只读前 N 项（N = currencyMax），多出来的折成 "+k"，不把整条撑爆。
function C:BarText(entries)
    local max = self:MaxOnBar()
    local parts = {}
    for i = 1, math.min(#entries, max) do
        local entry = entries[i]
        parts[#parts + 1] = string.format("%s %s", entry.name, self:FormatQuantity(entry.quantity))
    end
    local more = #entries - max
    if more > 0 then parts[#parts + 1] = string.format("+%d", more) end
    return table.concat(parts, " · ")
end

--- 任何设置变动只走这一处：立刻重画格子 + 若选择面板开着就同步勾选态。
local function Changed()
    M:RefreshBlock("currency")
    C:RefreshPanel()
end

--- 从别的档切到自定义时，先把"当前正在显示的那些"变成初始清单，
--- 再补上货币页里此刻**有余额**的其它项（上限 8）：1.60 的货币页往往只有两三种，
--- 客户端的 `isShowInBackpack` 却只标记了一种，光继承显示项会让第二种（如商人青睐）
--- 在自定义档里凭空缺席，玩家还得自己猜 ID 去 add。玩家看到的是接着改，不是从零开始。
function C:EnsureCustom()
    if self:Mode() == "custom" then return end
    local backpackIDs = (self:Mode() == "backpack") and self:BackpackIDs() or nil
    local list = self:Available(backpackIDs)
    local ids = EffectiveIDs(list, backpackIDs)
    Settings().currencyWatch = {}
    local watch, seen = self:Watch(), {}
    for i = 1, #ids do
        local id = ids[i]
        if not seen[id] then seen[id] = true; watch[#watch + 1] = id end
    end
    for i = 1, #list do
        local entry = list[i]
        if #watch >= 8 then break end
        if entry.quantity and entry.quantity > 0 and not seen[entry.id] then
            seen[entry.id] = true
            watch[#watch + 1] = entry.id
        end
    end
    Settings().currencyMode = "custom"
end

function C:SetMode(mode)
    if mode ~= "custom" and mode ~= "all" then mode = "backpack" end
    if mode == "custom" then self:EnsureCustom() end
    Settings().currencyMode = mode
    Changed()
end

--- 勾 / 取消一个 ID；非自定义档会先自动切到自定义并继承当前清单。
--- 返回 true = 这次是"加入"。
function C:ToggleWatch(id)
    id = Num(id)
    if not id or id < 1 then return false end
    self:EnsureCustom()

    local watch = self:Watch()
    local found
    for i = 1, #watch do
        if Num(watch[i]) == id then found = i break end
    end
    if found then table.remove(watch, found) else watch[#watch + 1] = id end
    Changed()
    return found == nil
end

function C:ClearWatch()
    Settings().currencyWatch = {}
    Changed()
end

function C:SetMax(value)
    local n = math.floor(Num(value) or 3)
    if n < 1 then n = 1 end
    if n > 8 then n = 8 end
    Settings().currencyMax = n
    Changed()
    return n
end

function C:SetShowZero(value)
    Settings().currencyShowZero = value and true or false
    Changed()
end

-- =========================================================================
-- 选择面板：右键货币格弹出。行就是货币页那张表，点一下增删自定义监控。
-- 自己的 UIParent 子框、DIALOG 档，不碰任何暴雪框体（AGENTS 污染模型）。
-- =========================================================================
local PANEL_W   = 320
local ROW_H     = 22
local VISIBLE   = 12
local HEADER_H  = 42
local FOOTER_H  = 34

local panel, rows, scrollOffset, cachedList = nil, {}, 0, nil

local function AnchorPanel()
    local block = M:GetBlock("currency")
    if not panel or not block or not block.frame then return end
    panel:ClearAllPoints()
    if M:GetSetting("anchorTop") ~= false then
        panel:SetPoint("TOPLEFT", block.frame, "BOTTOMLEFT", 0, -2)
    else
        panel:SetPoint("BOTTOMLEFT", block.frame, "TOPLEFT", 0, 2)
    end
end

local function BuildPanel()
    if panel then return panel end
    local block = M:GetBlock("currency")
    if not block then return nil end

    panel = Widget:CreateFrame("MonetUIInfoBarCurrencyPanel", _G.UIParent,
        PANEL_W, HEADER_H + VISIBLE * ROW_H + FOOTER_H)
    Widget:Theme(panel, { thickness = 1, bgAlpha = 0.94, borderAlpha = 1 })
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:EnableMouseWheel(true)

    local title = Widget:Font(panel, 12, "pixel", "bright", "LEFT")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -8)
    title:SetText("货币监控")

    local modeButton = Widget:CreateFrame(nil, panel, 132, 20)
    Widget:Theme(modeButton, { thickness = 1, bgAlpha = 0.9 })
    Widget:ButtonMaterial(modeButton, { alpha = 0, weaveAlpha = 0.25 })
    modeButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -32, -4)
    modeButton:EnableMouse(true)
    local modeText = Widget:Font(modeButton, 12, "pixel", "edge", "CENTER")
    modeText:SetPoint("CENTER", modeButton, "CENTER", 0, 0)
    modeText:SetWordWrap(false)
    panel.modeText = modeText
    modeButton:SetScript("OnClick", function()
        local index = 1
        for i = 1, #MODE_ORDER do
            if MODE_ORDER[i] == C:Mode() then index = i end
        end
        C:SetMode(MODE_ORDER[index % #MODE_ORDER + 1])
        ns:Print("货币监控模式：" .. C:ModeLabel())
    end)

    local close = Widget:CloseButton(panel, 20)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 3, 3)
    close:SetScript("OnClick", function() panel:Hide() end)

    for i = 1, VISIBLE do
        local button = CreateFrame("Button", nil, panel)
        button:SetSize(PANEL_W - 20, ROW_H)
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -HEADER_H - (i - 1) * ROW_H)
        button:EnableMouse(true)

        -- 勾选框只作显示：整行才是点击目标，免得两颗控件各收一半点击。
        local check = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
        check:SetSize(16, 16)
        check:SetPoint("LEFT", button, "LEFT", 0, 0)
        check:EnableMouse(false)
        if ns.Skin then pcall(ns.Skin.CheckButton, ns.Skin, check) end

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", check, "RIGHT", 4, 0)

        local name = Widget:Font(button, 12, "pixel", "neutral", "LEFT")
        name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        name:SetPoint("RIGHT", button, "RIGHT", -56, 0)
        name:SetWordWrap(false)

        local qty = Widget:Font(button, 12, "pixel", "bright", "RIGHT")
        qty:SetPoint("RIGHT", button, "RIGHT", 0, 0)
        qty:SetWidth(52)
        qty:SetWordWrap(false)

        button:SetScript("OnClick", function()
            local entry = button.entry
            if entry then C:ToggleWatch(entry.id) end
        end)
        button:SetScript("OnEnter", function()
            local tip = _G.GameTooltip
            local entry = button.entry
            if not tip or not entry then return end
            pcall(tip.SetOwner, tip, button, "ANCHOR_RIGHT")
            pcall(tip.AddLine, tip, entry.name, 1, 1, 1)
            pcall(tip.AddDoubleLine, tip, "ID", tostring(entry.id), 0.8, 0.8, 0.8, 1, 1, 1)
            pcall(tip.Show, tip)
        end)
        button:SetScript("OnLeave", function() M:HideTooltip() end)

        rows[i] = { button = button, check = check, icon = icon, name = name, qty = qty }
    end

    local hint = Widget:Font(panel, 12, "pixel", "neutral", "LEFT")
    hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 8)
    hint:SetWidth(PANEL_W - 24)
    hint:SetJustifyH("LEFT")
    panel.hint = hint

    panel:SetScript("OnMouseWheel", function(_, delta)
        local total = cachedList and #cachedList or 0
        local maxOffset = math.max(0, total - VISIBLE)
        local next = math.max(0, math.min(maxOffset, scrollOffset - delta))
        if next ~= scrollOffset then
            scrollOffset = next
            C:RefreshPanel()
        end
    end)

    -- 格子被隐藏（模块关掉 / 宠物对战 / 没有数据）时面板不能留在 DIALOG 层。
    if block.frame and block.frame.SetScript then
        local prevOnHide = block.frame:GetScript("OnHide")
        block.frame:SetScript("OnHide", function(self)
            if prevOnHide then prevOnHide(self) end
            panel:Hide()
        end)
    end

    panel:Hide()
    return panel
end

function C:RefreshPanel()
    if not panel or not panel:IsShown() then return end

    local list = self:Available()
    cachedList = list
    local mode = self:Mode()
    panel.modeText:SetText("模式：" .. (MODE_LABEL[mode] or mode))

    local watched = {}
    if mode == "all" then
        watched = nil   -- nil = 全勾
    elseif mode == "custom" then
        local watch = self:Watch()
        for i = 1, #watch do
            local id = Num(watch[i])
            if id then watched[id] = true end
        end
    else
        for i = 1, #list do
            if list[i].backpack then watched[list[i].id] = true end
        end
    end

    local maxOffset = math.max(0, #list - VISIBLE)
    if scrollOffset > maxOffset then scrollOffset = maxOffset end

    for i = 1, VISIBLE do
        local row = rows[i]
        local entry = list[scrollOffset + i]
        row.button.entry = entry
        if not entry then
            row.button:Hide()
        else
            row.button:Show()
            row.check:SetChecked(watched == nil or watched[entry.id] == true)
            row.icon:SetTexture((entry.icon and entry.icon > 0) and entry.icon or nil)
            row.name:SetText(entry.name)
            row.qty:SetText(self:FormatQuantity(entry.quantity))
        end
    end

    if #list == 0 then
        panel.hint:SetText("清单为空：先开一次角色面板 → 货币，或用 /mui infobar currency add <ID>")
    else
        panel.hint:SetText(string.format("共 %d 项 · 滚轮翻页 · 点击行增删监控", #list))
    end
end

function C:TogglePanel()
    if not BuildPanel() then return end
    if panel:IsShown() then panel:Hide() return end
    AnchorPanel()
    scrollOffset = 0
    panel:Show()
    self:RefreshPanel()
end

function C:HidePanel()
    if panel then panel:Hide() end
end

-- =========================================================================
-- 斜杠命令：/mui infobar currency ...（由 InfoBar:HandleCommand 转进来）
-- =========================================================================
local function Usage()
    ns:Print("|cffffd100/mui infobar currency|r <命令>")
    ns:Print("  list / status    列出货币页清单与 ID（完整清单存 MonetUIDB.currencyReport）")
    ns:Print("  add <ID|名称> ...  加入自定义监控（可一次多个）；del <...> 移除；clear 清空")
    ns:Print("  mode backpack|custom|all   来源切换；panel 打开勾选面板")
    ns:Print("  切到 custom 会自动带入当前显示项 + 货币页里有余额的其它项（最多 8 项）")
    ns:Print("  max <1-8>        条上最多显示几项；zero on|off 是否显示 0 值")
end

local function Resolve(text)
    if type(text) ~= "string" or text == "" then return nil end
    local list = C:Available()
    local id = tonumber(text)
    if id then
        id = math.floor(id)
        -- 数字也可能是清单里的某一项：顺便把名字带回去，回显才不会只有一串 ID。
        for i = 1, #list do
            if list[i].id == id then return id, list[i].name end
        end
        return id, nil   -- 允许加一个当前货币页没列出来的 ID（跨角色 / 折叠分类）
    end
    local needle = string.lower(text)
    for i = 1, #list do
        local name = list[i].name
        if type(name) == "string"
           and string.find(string.lower(name), needle, 1, true) then
            return list[i].id, name
        end
    end
    return nil
end

--- 一次可以跟好几个目标：`add 荣誉点数 商人青睐` / `add 1901 2201` /
--- `del 荣誉点数 商人青睐`。中文货币名里没有空格，空白与中英文逗号都能当分隔符。
--- 先拿整串试一次，命中就当成一个含空格的名字（英文客户端的 "Honor Points"），
--- 没命中才拆开逐个解析。
local function SplitArgs(text)
    local parts = {}
    for token in tostring(text or ""):gmatch("[^%s,，、]+") do
        parts[#parts + 1] = token
    end
    return parts
end

function C:List()
    local list = self:Available()
    local watch = self:Watch()
    local watched = {}
    for i = 1, #watch do
        local id = Num(watch[i])
        if id then watched[id] = true end
    end

    ns:Print(string.format("货币清单（角色面板 · 货币）：%d 项 · 当前模式 %s",
        #list, self:ModeLabel()))

    local report = { mode = self:Mode(), count = #list, entries = {} }
    local shown = math.min(#list, 24)
    for i = 1, shown do
        local entry = list[i]
        ns:Print(string.format("  %s%d %s = %s%s", watched[entry.id] and "*" or " ",
            entry.id, entry.name, self:FormatQuantity(entry.quantity),
            entry.backpack and " [背包]" or ""))
        report.entries[i] = {
            id = entry.id, name = entry.name,
            quantity = entry.quantity, backpack = entry.backpack,
        }
    end
    if #list > shown then
        ns:Print(string.format("  ……另有 %d 项，完整清单在 MonetUIDB.currencyReport", #list - shown))
    elseif #list == 0 then
        ns:Print("  清单为空：先打开一次角色面板 → 货币 子标签（LoD 窗口要开过才加载）。")
    end
    -- 清单可能几十上百行，聊天框装不下：全量落 SavedVariables，登出后读最稳。
    for i = 1, #list do
        if not report.entries[i] then
            local entry = list[i]
            report.entries[i] = {
                id = entry.id, name = entry.name,
                quantity = entry.quantity, backpack = entry.backpack,
            }
        end
    end
    ns:DB().currencyReport = report
end

function C:Status()
    local entries, missing, mode, list = self:Snapshot()
    local watch = self:Watch()
    ns:Print(string.format("货币监控：%s · 条上最多 %d 项 · 0 值%s",
        self:ModeLabel(mode), self:MaxOnBar(), self:ShowZero() and "显示" or "隐藏"))
    ns:Print(string.format("  自定义清单 %d 项 · 当前生效 %d 项 · 暂不可读 %d 项 · 货币页可见 %d 项",
        #watch, #entries, missing, #list))
end

function C:AddByText(text)
    local tokens = SplitArgs(text)
    if #tokens == 0 then
        ns:Print("用法：/mui infobar currency add <ID|名称> [ID|名称 ...]")
        return
    end
    local whole = table.concat(tokens, " ")
    if Resolve(whole) then tokens = { whole } end

    local added, skipped, existing = 0, 0, 0
    for i = 1, #tokens do
        local id, name = Resolve(tokens[i])
        if not id or id < 1 then
            skipped = skipped + 1
        else
            self:EnsureCustom()   -- 幂等：只在第一次真正切档
            local watch, found = self:Watch(), false
            for j = 1, #watch do
                if Num(watch[j]) == id then found = true break end
            end
            if found then
                existing = existing + 1
            else
                watch[#watch + 1] = id
                added = added + 1
                ns:Print(string.format("已加入监控：%d %s", id, name or ""))
            end
        end
    end
    if added > 0 then Changed() end
    if skipped > 0 or existing > 0 then
        ns:Print(string.format("新增 %d 项 · 已在清单 %d 项 · 没找到 %d 项（可用 /mui infobar currency list 查 ID）",
            added, existing, skipped))
    end
end

function C:RemoveByText(text)
    local tokens = SplitArgs(text)
    if #tokens == 0 then
        ns:Print("用法：/mui infobar currency del <ID|名称> [ID|名称 ...]")
        return
    end
    local whole = table.concat(tokens, " ")
    if Resolve(whole) then tokens = { whole } end

    local removed, missing = 0, 0
    for i = 1, #tokens do
        local id, name = Resolve(tokens[i])
        if not id then
            missing = missing + 1
        else
            local watch, found = self:Watch(), false
            for j = 1, #watch do
                if Num(watch[j]) == id then
                    table.remove(watch, j)
                    found = true
                    break
                end
            end
            if found then
                removed = removed + 1
                ns:Print(string.format("已移出监控：%d %s", id, name or ""))
            else
                ns:Print(string.format("清单里没有 %d。", id))
            end
        end
    end
    if removed > 0 then Changed() end
    if missing > 0 then
        ns:Print(string.format("没找到 %d 项（可用 /mui infobar currency list 查 ID）", missing))
    end
end

function C:HandleCommand(tail)
    local cmd, arg = tostring(tail or ""):match("^(%S+)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    arg = arg or ""

    if cmd == "" or cmd == "status" then
        self:Status()
    elseif cmd == "list" or cmd == "scan" then
        self:List()
    elseif cmd == "add" then
        self:AddByText(arg)
    elseif cmd == "del" or cmd == "remove" or cmd == "rm" then
        self:RemoveByText(arg)
    elseif cmd == "clear" then
        self:ClearWatch()
        ns:Print("自定义货币清单已清空。")
    elseif cmd == "mode" then
        local wanted = string.lower(arg)
        local mode
        if wanted == "custom" or wanted == "自定义" then mode = "custom"
        elseif wanted == "all" or wanted == "全部" then mode = "all"
        elseif wanted == "backpack" or wanted == "auto" or wanted == "背包" then mode = "backpack"
        else Usage() return true end
        self:SetMode(mode)
        ns:Print("货币监控模式：" .. self:ModeLabel())
    elseif cmd == "max" then
        ns:Print("条上最多显示 " .. self:SetMax(tonumber(arg)) .. " 项。")
    elseif cmd == "zero" then
        local on = not (arg == "off" or arg == "0" or arg == "false")
        self:SetShowZero(on)
        ns:Print("0 值货币：" .. (on and "显示" or "隐藏"))
    elseif cmd == "panel" or cmd == "ui" then
        self:TogglePanel()
    else
        Usage()
    end
    return true
end
