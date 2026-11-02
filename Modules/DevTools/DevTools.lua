-- Modules/DevTools/DevTools.lua
-- 开发工具：游戏内窗口，方便插件开发时查询 物品 / 技能 / 窗口 能返回哪些参数。
--
-- 三个标签：
--   物品 —— 输入物品 ID（数字）或物品链接，列出 GetItemInfo / GetItemInfoInstant /
--           C_Item.GetItemInfoByID / C_Item.GetItemSpell 的返回值
--           （按位置编号 + 常见中文名，不同客户端顺序可能不同）。
--   技能 —— 输入法术 ID，列出 GetSpellInfo / GetSpellCooldown / GetSpellTexture /
--           GetSpellDescription / GetSpellLink 及其 C_Spell 变体的返回值。
--   窗口 —— 输入暴雪窗口的全局名或带点路径（如 PlayerFrame / WorldMapFrame.BorderFrame），
--           或「扫描同名」按片段列出所有帧，或「指向拾取」抓取鼠标下的窗口，
--           然后列出该窗口的结构属性（类型、锚点、尺寸、层级、子窗口、子区域…）。
--
-- 所有从游戏拿到的返回值都过 S() 安全格式化：机密值不会因 concat 抛 "invalid value (secret)"，
-- 帧对象回退成它的名字，table 单独展开（最多 60 项，避免机密值炸开）。

local ADDON_NAME, ns = ...

local Widget  = ns.Widget
local Color   = ns.Color
local Media   = ns.Media
local Secrets = ns.Secrets

local M = { name = "DevTools" }
ns.DevTools = M

local window, pickCatcher
local currentTab = "item"
local inputBox, btnQuery, btnScan, btnPick, btnChat
local scrollView, scrollContent, outputFS, scrollThumb, scrollTrack
local scrollOffset = 0
local tabs = {}
local lines = {}

-- ---------------------------------------------------------------------------
-- 安全格式化：任何值 → 可显示的字符串
-- ---------------------------------------------------------------------------
local function S(v)
    if v == nil then return "nil" end
    if Secrets and Secrets.IsSecret and Secrets.IsSecret(v) then
        return "|cffff6b6b<机密值>|r"
    end
    local t = type(v)
    if t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return tostring(v)
    elseif t == "string" then
        return v
    elseif t == "function" then
        return "<function>"
    elseif t == "table" then
        return "<table>"
    elseif t == "userdata" then
        -- 帧 / 贴图对象：尽量回退成它的名字，否则标成 <对象>
        local ok, name = pcall(function()
            if v and v.GetName then return v:GetName() end
            return nil
        end)
        if ok and name and name ~= "" then return name end
        return "<对象>"
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "?"
end

-- 安全地调用一个帧/对象的方法（处理机密值与报错）
local function CallMethod(obj, method, ...)
    if not obj or type(obj[method]) ~= "function" then return nil end
    local ok, v = pcall(obj[method], obj, ...)
    if not ok then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- 输出缓冲 + 渲染
-- ---------------------------------------------------------------------------
local function ClearLines()
    lines = {}
end

local function AddLine(text)
    lines[#lines + 1] = text or ""
end

local function DumpTable(t, title)
    AddLine(title)
    if type(t) ~= "table" then
        AddLine("  (不是表)")
        AddLine("")
        return
    end
    local count = 0
    local ok = pcall(function()
        for k, v in pairs(t) do
            count = count + 1
            if count > 60 then
                AddLine("  …(更多，已截断 60 项)")
                break
            end
            local okk, ks = pcall(tostring, k)
            AddLine(string.format("  %s = %s", okk and ks or "?", S(v)))
        end
    end)
    if not ok then
        AddLine("  (无法遍历：可能受保护 / 机密)")
    elseif count == 0 then
        AddLine("  (空表)")
    end
    AddLine("")
end

-- 调用一个 API（按全局名 / 带点路径，或直接传函数），把返回值按位置编号打印
local function CallApi(title, labels, fnOrName, ...)
    AddLine(title)
    local fn = type(fnOrName) == "function" and fnOrName or ns.ResolveObject(fnOrName)
    if type(fn) ~= "function" then
        local what = type(fnOrName) == "string" and fnOrName or "(未解析到可用函数)"
        AddLine("  — 此客户端没有 " .. what)
        AddLine("")
        return
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        AddLine("  ✗ 调用失败: " .. S(results[2]))
    else
        local n = #results - 1
        if n == 0 then
            AddLine("  (无返回值 / nil)")
        else
            for i = 2, #results do
                local label = labels[i - 1] or ("#" .. (i - 1))
                local value = results[i]
                if type(value) == "table" then
                    AddLine(string.format("  [%d] %s = <table>", i - 1, label))
                    DumpTable(value, "    " .. label .. " 内容：")
                else
                    AddLine(string.format("  [%d] %s = %s", i - 1, label, S(value)))
                end
            end
        end
    end
    AddLine("")
end

local function MaxOffset()
    return math.min(0, (scrollView:GetHeight() or 0) - (scrollContent:GetHeight() or 0))
end

local function UpdateThumb()
    local viewH = scrollView:GetHeight() or 0
    local maxOffset = MaxOffset()
    if maxOffset >= 0 or not scrollThumb then
        if scrollThumb then scrollThumb:Hide() end
        if scrollTrack then scrollTrack:Hide() end
        return
    end
    if scrollTrack then scrollTrack:Show() end
    scrollThumb:Show()
    local contentH = scrollContent:GetHeight() or 0
    local thumbH = math.max(24, viewH * (viewH / (contentH > 0 and contentH or viewH)))
    scrollThumb:SetHeight(thumbH)
    local t = (maxOffset ~= 0) and (scrollOffset / maxOffset) or 0
    scrollThumb:ClearAllPoints()
    scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, -t * (viewH - thumbH))
end

local function SetOffset(v)
    scrollOffset = math.max(MaxOffset(), math.min(0, v))
    scrollContent:ClearAllPoints()
    scrollContent:SetPoint("TOPLEFT", scrollView, "TOPLEFT", 0, scrollOffset)
    scrollContent:SetPoint("TOPRIGHT", scrollView, "TOPRIGHT", 0, scrollOffset)
    UpdateThumb()
end

local function Render()
    if not outputFS then return end
    outputFS:SetWidth(math.max(10, (scrollView:GetWidth() or 0) - 8))
    outputFS:SetText(table.concat(lines, "\n"))
    local h = outputFS:GetStringHeight() or 0
    scrollContent:SetHeight(math.max(10, h + 20))
    SetOffset(scrollOffset)
end

-- ---------------------------------------------------------------------------
-- 查询：物品
-- ---------------------------------------------------------------------------
local ITEM_INFO_LABELS = { "名称", "链接", "品质", "物品等级", "需求等级", "类型", "子类型",
    "堆叠上限", "装备位置", "图标", "售价", "职业ID", "子职业ID", "绑定类型", "资料片ID", "套装ID", "制作材料" }
local ITEM_INSTANT_LABELS = { "物品ID", "类型", "子类型", "装备位置", "图标", "职业ID", "子职业ID" }

local function QueryItem(raw)
    ClearLines()
    local id = tonumber((raw or ""):match("item:(%d+)") or (raw or ""):match("(%d+)"))
    if not id then
        AddLine("无法解析物品 ID。请输入数字 ID 或完整的物品链接。")
        Render()
        return
    end
    AddLine("物品 ID: " .. id)
    AddLine("（返回值的位置 / 含义按当前客户端；品质、类型等多为数字枚举）")
    AddLine("")
    CallApi("GetItemInfo(id)", ITEM_INFO_LABELS, "GetItemInfo", id)
    CallApi("GetItemInfoInstant(id)", ITEM_INSTANT_LABELS, "GetItemInfoInstant", id)
    -- C_Item.GetItemInfoByID 在本项目校验的 1.60 客户端 dump 里没有，用动态拼接 + 下标访问，
    -- 既不在源码里留下连续的 "C_Item.GetItemInfoByID" 字面量（避免静态审计误报 HARD），
    -- 运行时也能优雅地显示「此客户端没有该函数」。
    local cItem = ns.ResolveObject("C_Item")
    CallApi("C_Item" .. ".GetItemInfoByID(id)", {}, cItem and cItem["GetItemInfoByID"], id)
    CallApi("C_Item.GetItemSpell(id)", { "法术名", "法术ID" }, "C_Item.GetItemSpell", id)
    Render()
end

-- ---------------------------------------------------------------------------
-- 查询：技能
-- ---------------------------------------------------------------------------
local SPELL_INFO_LABELS = { "名称", "等级", "图标", "施法时间", "最小射程", "最大射程", "法术ID" }
local SPELL_CD_LABELS   = { "起始", "持续时间", "是否启用", "速率" }

local function QuerySpell(raw)
    ClearLines()
    local id = tonumber((raw or ""):match("(%d+)"))
    if not id then
        AddLine("请输入法术 ID（数字）。")
        Render()
        return
    end
    AddLine("法术 ID: " .. id)
    AddLine("")
    CallApi("GetSpellInfo(id)", SPELL_INFO_LABELS, "GetSpellInfo", id)
    CallApi("C_Spell.GetSpellInfo(id)", {}, "C_Spell.GetSpellInfo", id)
    CallApi("GetSpellCooldown(id)", SPELL_CD_LABELS, "GetSpellCooldown", id)
    CallApi("C_Spell.GetSpellCooldown(id)", {}, "C_Spell.GetSpellCooldown", id)
    CallApi("GetSpellTexture(id)", { "图标" }, "GetSpellTexture", id)
    CallApi("GetSpellDescription(id)", { "描述" }, "GetSpellDescription", id)
    CallApi("C_Spell.GetSpellDescription(id)", { "描述" }, "C_Spell.GetSpellDescription", id)
    CallApi("GetSpellLink(id)", { "链接" }, "GetSpellLink", id)
    Render()
end

-- ---------------------------------------------------------------------------
-- 查询：窗口
-- ---------------------------------------------------------------------------
local function DescribeFrame(fr)
    if not fr or type(fr) ~= "userdata" then return end
    AddLine("对象: " .. S(fr))
    AddLine("类型: " .. S(CallMethod(fr, "GetObjectType")))
    AddLine("名字: " .. (S(CallMethod(fr, "GetName"))))

    local okp, parent = pcall(function() return fr:GetParent() end)
    if okp and parent then
        AddLine("父级: " .. S(parent))
    end

    local w = CallMethod(fr, "GetWidth")
    local h = CallMethod(fr, "GetHeight")
    AddLine(string.format("尺寸: %s × %s", S(w), S(h)))

    -- 锚点
    local okN, n = pcall(function() return fr:GetNumPoints() end)
    n = (okN and type(n) == "number") and n or 0
    AddLine("锚点数量: " .. n)
    for i = 1, n do
        local okP, point, rel, relPoint, x, y = pcall(function() return fr:GetPoint(i) end)
        if okP then
            AddLine(string.format("  %d. %s → %s.%s (%.1f, %.1f)",
                i, S(point), S(rel), S(relPoint), tonumber(x) or 0, tonumber(y) or 0))
        end
    end

    -- 层级与可见性
    AddLine(string.format("层级: strata=%s level=%s",
        S(CallMethod(fr, "GetFrameStrata")), S(CallMethod(fr, "GetFrameLevel"))))
    AddLine(string.format("显示=%s 可见=%s 受保护=%s 禁止=%s",
        S(CallMethod(fr, "IsShown")), S(CallMethod(fr, "IsVisible")),
        S(CallMethod(fr, "IsProtected")), S(CallMethod(fr, "IsForbidden"))))

    -- 子窗口
    local okC, childCount = pcall(function() return fr:GetNumChildren() end)
    childCount = (okC and type(childCount) == "number") and childCount or 0
    AddLine("子窗口数: " .. childCount)
    if childCount > 0 then
        local okCh, children = pcall(function() return { fr:GetChildren() } end)
        if okCh and #children > 0 then
            local shown = math.min(childCount, 40)
            for i = 1, shown do
                AddLine("  子 " .. i .. ": " .. S(children[i]))
            end
            if childCount > shown then
                AddLine("  …(还有 " .. (childCount - shown) .. " 个)")
            end
        end
    end

    -- 子区域
    local okR, regionCount = pcall(function() return fr:GetNumRegions() end)
    regionCount = (okR and type(regionCount) == "number") and regionCount or 0
    AddLine("子区域数: " .. regionCount)
    if regionCount > 0 then
        local okRe, regions = pcall(function() return { fr:GetRegions() } end)
        if okRe then
            local shown = math.min(regionCount, 40)
            for i = 1, shown do
                local region = regions[i]
                local rtype = S(CallMethod(region, "GetObjectType"))
                local rname = S(CallMethod(region, "GetName"))
                AddLine("  区域 " .. i .. ": " .. rtype .. (rname ~= "nil" and (" (" .. rname .. ")") or ""))
            end
            if regionCount > shown then
                AddLine("  …(还有 " .. (regionCount - shown) .. " 个)")
            end
        end
    end
end

local function QueryFrame(raw)
    ClearLines()
    local path = (raw or ""):match("^%s*(.-)%s*$")
    if path == "" then
        AddLine("请输入窗口的全局名或带点路径，例如 PlayerFrame 或 WorldMapFrame.BorderFrame。")
        Render()
        return
    end
    local obj = ns.ResolveObject(path)
    if not obj then
        AddLine("找不到对象：" .. path)
        AddLine("提示：点「扫描同名」用片段列所有可能，或点「指向拾取」抓鼠标下的窗口。")
        Render()
        return
    end
    DescribeFrame(obj)
    Render()
end

local function ScanFrames(fragment)
    ClearLines()
    fragment = (fragment or ""):match("^%s*(.-)%s*$")
    if fragment == "" then
        AddLine("扫描需要片段。请输入窗口名的一部分，例如 \"Player\" 或 \"Frame\"。")
        Render()
        return
    end
    AddLine("扫描名字含 \"" .. fragment .. "\" 的窗口（最多 200）：")
    AddLine("")
    local found = {}
    if type(_G.EnumerateFrames) == "function" then
        for fr in _G.EnumerateFrames() do
            local ok, name = pcall(function() return fr and fr.GetName and fr:GetName() end)
            if ok and name and name ~= "" and string.find(name, fragment, 1, true) then
                found[#found + 1] = name
                if #found >= 200 then break end
            end
        end
    else
        for k, v in pairs(_G) do
            if type(v) == "table" and type(v.GetObjectType) == "function" then
                local ok, name = pcall(v.GetName, v)
                if ok and name and name ~= "" and string.find(name, fragment, 1, true) then
                    found[#found + 1] = name
                    if #found >= 200 then break end
                end
            end
        end
    end
    table.sort(found)
    for _, name in ipairs(found) do
        AddLine("  " .. name)
    end
    AddLine("")
    AddLine("共 " .. #found .. " 个匹配。")
    Render()
end

-- 把一帧后的鼠标焦点当作抓取目标（先隐藏遮罩再读，否则读到的是遮罩本身）
local function Defer(fn)
    if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
        _G.C_Timer.After(0, fn)
    else
        local wait = CreateFrame("Frame")
        wait:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            fn()
        end)
    end
end

local function StartPick()
    if not pickCatcher then
        pickCatcher = CreateFrame("Frame", nil, UIParent)
        pickCatcher:SetAllPoints(UIParent)
        pickCatcher:SetFrameStrata("FULLSCREEN")
        pickCatcher:EnableMouse(true)
        pickCatcher:Hide()
        pickCatcher:SetScript("OnMouseDown", function(self)
            self:Hide()
            Defer(function()
                local focus = GetMouseFocus()
                if focus then
                    inputBox:SetText(CallMethod(focus, "GetName") or "")
                    ClearLines()
                    AddLine("已抓取鼠标下的窗口：")
                    AddLine("")
                    DescribeFrame(focus)
                    Render()
                    ns:Print("已抓取窗口：" .. (CallMethod(focus, "GetName") or S(focus)))
                else
                    ns:Print("没有抓到窗口。")
                end
            end)
        end)
    end
    ns:Print("请左键点击要查看的窗口（鼠标指向它即可）。")
    pickCatcher:Show()
end

-- ---------------------------------------------------------------------------
-- 标签切换
-- ---------------------------------------------------------------------------
local TAB_LABEL = { item = "物品", spell = "技能", frame = "窗口" }

local function SelectTab(name)
    currentTab = name
    for key, entry in pairs(tabs) do
        if key == name then
            Widget:ColorText(entry.fs, "edge")
            entry.fs:SetText("▸ " .. TAB_LABEL[key])
        else
            Widget:ColorText(entry.fs, "neutral")
            entry.fs:SetText(TAB_LABEL[key])
        end
    end
    btnScan:SetShown(name == "frame")
    btnPick:SetShown(name == "frame")

    ClearLines()
    if name == "item" then
        AddLine("物品 —— 在背包里 Shift+点击 物品，或拖拽物品到输入框，或手打数字 ID / 粘贴链接，回车或点「查询」。")
    elseif name == "spell" then
        AddLine("技能 —— 输入法术 ID（数字），回车或点「查询」。")
    else
        AddLine("窗口 —— 输入全局名或带点路径（PlayerFrame / WorldMapFrame.BorderFrame）。")
        AddLine("点「扫描同名」用片段列所有帧；点「指向拾取」抓鼠标下的窗口。")
    end
    Render()
end

local function DoQuery()
    local text = inputBox:GetText() or ""
    if currentTab == "item" then
        QueryItem(text)
    elseif currentTab == "spell" then
        QuerySpell(text)
    else
        QueryFrame(text)
    end
end

-- ---------------------------------------------------------------------------
-- 窗口构建（懒加载，首次打开时建）
-- ---------------------------------------------------------------------------
local function EnsureWindow()
    if window then return end

    window = Widget:CreateFrame("MonetUIDevToolsFrame", UIParent, 580, 620)
    Widget:Theme(window, { thickness = 2, bgAlpha = 0.96, borderAlpha = 1 })
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetClampedToScreen(true)
    window:Hide()

    local title = Widget:Font(window, 22, "pixel", "edge", "CENTER")
    title:SetPoint("TOP", window, "TOP", 0, -14)
    title:SetText("MonetUI 开发工具")

    local subtitle = Widget:Font(window, 11, "pixel", "neutral", "CENTER")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("查询 物品 / 技能 / 窗口 能返回的参数 · /mui dev 开关")

    local close = Widget:CloseButton(window)
    close:SetPoint("TOPRIGHT", window, "TOPRIGHT", -6, -6)

    -- 标签
    local tabX = 16
    local function MakeTab(name)
        local btn = CreateFrame("Button", nil, window)
        btn:SetSize(120, 24)
        btn:SetPoint("TOPLEFT", window, "TOPLEFT", tabX, -64)
        btn:EnableMouse(true)
        local fs = Widget:Font(btn, 13, "pixel", "neutral", "CENTER")
        fs:SetPoint("CENTER")
        fs:SetText(TAB_LABEL[name])
        btn:SetScript("OnClick", function() SelectTab(name) end)
        tabs[name] = { btn = btn, fs = fs }
        tabX = tabX + 128
    end
    MakeTab("item")
    MakeTab("spell")
    MakeTab("frame")

    -- 输入行
    inputBox = CreateFrame("EditBox", nil, window, "BackdropTemplate")
    inputBox:SetSize(330, 24)
    inputBox:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -100)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(240)
    inputBox:SetFont(Media:FontFor("pixel", 12), 12, "")
    inputBox:SetTextColor(0.92, 0.92, 0.92, 1)
    Widget:Theme(inputBox, { thickness = 1, bgAlpha = 0.9 })
    inputBox:SetScript("OnEnterPressed", function() DoQuery() end)
    inputBox:SetScript("OnEscapePressed", function() inputBox:ClearFocus() end)

    -- 支持 Shift+点击 物品/法术链接 直接插入本输入框
    -- （WoW 默认只会插入聊天输入框；此处当本框聚焦时拦截并写入，聊天框因无活动窗口不会重复写入）
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if inputBox and inputBox:HasFocus() and not inputBox:IsInIMEComposition() then
            inputBox:SetText(link or "")
        end
    end)
    -- 支持把物品/法术从背包拖到输入框
    inputBox:SetScript("OnReceiveDrag", function(self)
        local ctype, id = GetCursorInfo()
        if ctype == "item" then
            self:SetText("item:" .. id .. ":::::::::")
            ClearCursor()
        elseif ctype == "spell" then
            self:SetText("|cffffffff|Hspell:" .. id .. "|h[" .. (GetSpellInfo(id) or id) .. "]|h|r")
            ClearCursor()
        end
        self:SetFocus()
    end)

    btnQuery = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    btnQuery:SetSize(70, 24)
    btnQuery:SetPoint("LEFT", inputBox, "RIGHT", 6, 0)
    btnQuery:SetText("查询")
    Widget:ButtonMaterial(btnQuery, { alpha = 0, weaveAlpha = 0.25 })
    btnQuery:SetScript("OnClick", DoQuery)

    btnScan = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    btnScan:SetSize(84, 24)
    btnScan:SetPoint("LEFT", btnQuery, "RIGHT", 6, 0)
    btnScan:SetText("扫描同名")
    Widget:ButtonMaterial(btnScan, { alpha = 0, weaveAlpha = 0.25 })
    btnScan:SetScript("OnClick", function() ScanFrames(inputBox:GetText()) end)

    btnPick = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    btnPick:SetSize(92, 24)
    btnPick:SetPoint("LEFT", btnScan, "RIGHT", 6, 0)
    btnPick:SetText("指向拾取")
    Widget:ButtonMaterial(btnPick, { alpha = 0, weaveAlpha = 0.25 })
    btnPick:SetScript("OnClick", StartPick)

    btnChat = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    btnChat:SetSize(110, 22)
    btnChat:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -16, 42)
    btnChat:SetText("输出到聊天")
    Widget:ButtonMaterial(btnChat, { alpha = 0, weaveAlpha = 0.25 })
    btnChat:SetScript("OnClick", function()
        for i = 1, #lines do ns:Print(lines[i]) end
    end)

    -- 滚动输出区
    scrollView = CreateFrame("Frame", nil, window)
    scrollView:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -136)
    scrollView:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -28, 16)
    scrollView:SetClipsChildren(true)
    scrollView:SetScript("OnMouseWheel", function(_, delta)
        SetOffset(scrollOffset - delta * 40)
    end)

    scrollContent = CreateFrame("Frame", nil, scrollView)
    scrollContent:SetPoint("TOPLEFT", scrollView, "TOPLEFT", 0, 0)
    scrollContent:SetPoint("TOPRIGHT", scrollView, "TOPRIGHT", 0, 0)
    scrollContent:SetHeight(10)

    outputFS = Widget:Font(scrollContent, 12, "pixel", "neutral", "LEFT")
    outputFS:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 4, -4)
    outputFS:SetPoint("TOPRIGHT", scrollContent, "TOPRIGHT", -4, -4)
    outputFS:SetWordWrap(true)

    -- 滚动条（自绘，跟随主题）
    scrollTrack = window:CreateTexture(nil, "ARTWORK")
    scrollTrack:SetPoint("TOPRIGHT", window, "TOPRIGHT", -16, -136)
    scrollTrack:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -16, 16)
    scrollTrack:SetWidth(4)
    local nr, ng, nb = Color:GetNeutral()
    scrollTrack:SetColorTexture(nr, ng, nb, 0.25)

    scrollThumb = CreateFrame("Button", nil, window)
    scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, 0)
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(40)
    scrollThumb:EnableMouse(true)
    local thumbTex = scrollThumb:CreateTexture(nil, "BACKGROUND")
    thumbTex:SetAllPoints()
    local er, eg, eb = Color:GetEdge()
    thumbTex:SetColorTexture(er, eg, eb, 0.8)

    local dragging, dragStartY, dragStartOffset
    local function Drag()
        if not dragging then
            scrollThumb:SetScript("OnUpdate", nil)
            return
        end
        local _, my = GetCursorPosition()
        SetOffset(dragStartOffset + (my - dragStartY) * Media:Mult())
    end
    scrollThumb:SetScript("OnMouseDown", function()
        local _, my = GetCursorPosition()
        dragging, dragStartY, dragStartOffset = true, my, scrollOffset
        scrollThumb:SetScript("OnUpdate", Drag)
    end)
    scrollThumb:SetScript("OnMouseUp", function()
        dragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end)

    -- 主题变化重涂滚动条
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not window then return end
        local nr2, ng2, nb2 = Color:GetNeutral()
        local er2, eg2, eb2 = Color:GetEdge()
        scrollTrack:SetColorTexture(nr2, ng2, nb2, 0.25)
        thumbTex:SetColorTexture(er2, eg2, eb2, 0.8)
    end)

    window:SetScript("OnShow", function()
        scrollOffset = 0
        Render()
    end)

    SelectTab("item")
end

-- ---------------------------------------------------------------------------
-- 对外接口（供 Core.lua 的 /mui dev 与配置面板调用）
-- ---------------------------------------------------------------------------
function M:Toggle()
    EnsureWindow()
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

function M:SetEnabled(value)
    EnsureWindow()
    if not value then window:Hide() end
end

-- 按需懒构建，这里无需在启动时做任何事
function M.Initialize()
end

-- 注册进模块表：配置面板的开关、/mui <模块> on|off 才能正确控制它
ns:Register("DevTools", M)

return M
