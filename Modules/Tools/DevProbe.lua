-- Modules/Tools/DevProbe.lua
-- 游戏内元素探测面板（仅开发版）：
--   /mui dev  开关面板（256×256，主题色边框 + 斜纹画布）
--   /mui dig  枚举「指针下」的窗体：先把鼠标指到目标窗口上，再输这条命令
-- 结果逐行列在面板里；点行选中，名字进底部输入框，
-- Ctrl+C 复制出来接线美化。全量同时落 MonetUIDB.devProbeReport（聊天框装不下）。
--
-- 硬约束（对齐 AGENTS.md，逐条自检）：
--   * 面板全是自建 CreateFrame（MonetUI* 名字），不做暴雪框的子框；
--   * 枚举暴雪框**只读**：每个 Get* 都 pcall，入口过 Widget:Readable，
--     字符串/数字出栈前过 Secrets.CanRead（机密串的 type() 照样是 "string"）；
--   * 不往暴雪对象写字段、不挂 HookScript / hooksecurefunc；候选在命令当拍取
--     （本客户端没有 GetMouseFocus，优先 GetMouseFoci，缺席退回 EnumerateFrames+IsMouseOver），
--     不留任何常驻轮询；
--   * 脚本钩子只挂自建框（面板拖动 / 行点击 / 输入框），与 Config/SimpleConfig.lua 同例。

local ADDON_NAME, ns = ...

local Secrets   = ns.Secrets
local Widget    = ns.Widget
local Media     = ns.Media
local Color     = ns.Color

local PANEL_SIZE = 256
local LIST_W, LIST_H = 240, 158
local ROW_H = 16
local MAX_ROWS = 600          -- 大窗口（商人 ~600 件）截断上限，截断会在状态行注明
local MAX_DEPTH = 10
local MAX_REGIONS = 10        -- 每框最多列这么多 region，防 600 件窗刷屏

-- ---------------------------------------------------------------------------
-- 状态（全部模块级局部；框体懒建，登录时一个字节都不造）

local panel, statusText, hintText, copyBox
local scroll, content, indicator
local rows = {}               -- 行按钮池（自建框，跨次探测复用）
local dataRows = {}           -- 当前探测结果 {label, copy, kind, objType, art, depth}
local truncated = false
local currentRootName = nil

-- 前置声明：BuildPanel 的脚本闭包引用这些助手与模块表，而本体写在后面 ——
-- 不先声明就是全局 nil，静态闸门全绿、运行到那一刻才炸（AGENTS「引用了还没声明的 local」）。
local DevProbe = { name = "DevProbe" }
local Dig, FindCandidate

-- ---------------------------------------------------------------------------
-- 安全读值（与 Modules/Tools/DevTools.lua 同一套口径：pcall + CanRead，读不出 = nil）

local function SafeName(obj)
    if not obj or type(obj.GetName) ~= "function" then return nil end
    local ok, name = pcall(obj.GetName, obj)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    if not Secrets.CanRead(name) then return nil end
    return name
end

local function ReadType(obj)
    if not obj or type(obj.GetObjectType) ~= "function" then return nil end
    local ok, t = pcall(obj.GetObjectType, obj)
    if ok and type(t) == "string" and Secrets.CanRead(t) then return t end
    return nil
end

--- 贴图 identity：atlas 优先，其次路径末段，纯文件 ID 记 "id:N"（与 Skin 的 probeArt 同口径）。
local function ReadArt(tex)
    if not tex then return nil end
    if type(tex.GetAtlas) == "function" then
        local ok, a = pcall(tex.GetAtlas, tex)
        if ok and type(a) == "string" and a ~= "" and Secrets.CanRead(a) then return a end
    end
    if type(tex.GetTexture) == "function" then
        local ok, t = pcall(tex.GetTexture, tex)
        if ok then
            if type(t) == "string" and t ~= "" and Secrets.CanRead(t) then
                return (t:gsub("[^\\/]*[\\/]", ""))
            end
            if type(t) == "number" and Secrets.CanRead(t) then return "id:" .. t end
        end
    end
    return nil
end

--- 沿父链找第一个有名的祖先（含自己）：匿名控件的接线把手就是它。
local function NearestNamed(obj)
    local node = obj
    for _ = 1, 16 do
        if not node then return nil end
        local name = SafeName(node)
        if name then return name end
        if type(node.GetParent) ~= "function" then return nil end
        local ok, parent = pcall(node.GetParent, node)
        if not ok or parent == node then return nil end
        node = parent
    end
    return nil
end

local function OurFrame(f)
    if type(f) ~= "table" then return true end
    local name = SafeName(f)
    return name ~= nil and string.find(name, "^MonetUI") ~= nil
end

local function DepthOf(f)
    local d, node = 0, f
    for _ = 1, 24 do
        if type(node.GetParent) ~= "function" then break end
        local ok, p = pcall(node.GetParent, node)
        if not ok or not p or p == node then break end
        d = d + 1
        node = p
    end
    return d
end

-- ---------------------------------------------------------------------------
-- 面板（懒建一次）

local function UpdateIndicator()
    if not indicator then return end
    local total = #dataRows * ROW_H
    if total <= LIST_H then
        indicator:Hide()
        return
    end
    local okCur, cur = pcall(scroll.GetVerticalScroll, scroll)
    cur = (okCur and type(cur) == "number") and cur or 0
    local maxOffset = total - LIST_H
    local h = math.max(8, LIST_H * (LIST_H / total))
    local y = maxOffset > 0 and (cur / maxOffset) * (LIST_H - h) or 0
    indicator:SetHeight(h)
    indicator:ClearAllPoints()
    indicator:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 3, -y)
    local r, g, b = Color:GetEdge()
    indicator:SetColorTexture(r, g, b, 0.7)
    indicator:Show()
end

local function ScrollBy(dy)
    if not scroll then return end
    local okCur, cur = pcall(scroll.GetVerticalScroll, scroll)
    cur = (okCur and type(cur) == "number") and cur or 0
    pcall(scroll.SetVerticalScroll, scroll, cur + dy)
    UpdateIndicator()
end

local function SelectRow(row)
    local d = row.data
    if not d or not copyBox then return end
    copyBox:SetText(d.copy or "")
    copyBox:HighlightText()
    copyBox:SetFocus()
    local bits = {}
    bits[#bits + 1] = d.kind == "region" and "贴图/文字" or (d.kind == "root" and "根框" or "框体")
    if d.objType then bits[#bits + 1] = d.objType end
    if d.art then bits[#bits + 1] = d.art end
    if not d.copy then bits[#bits + 1] = "无名，按最近祖先接线" end
    hintText:SetText(table.concat(bits, " · "))
end

local function EnsureRows(n)
    for i = #rows + 1, n do
        local row = CreateFrame("Button", nil, content)
        row:SetSize(LIST_W - 4, ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -(i - 1) * ROW_H)
        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        -- 自建框才能挂脚本（SimpleConfig 下拉行同例）；颜色悬停当拍采样，跟着主题走。
        row:SetScript("OnEnter", function()
            local r, g, b = Color:GetHighlight()
            hover:SetColorTexture(r, g, b, 0.25)
        end)
        local text = Widget:Font(row, 12, "pixel", "neutral", "LEFT")
        text:SetPoint("LEFT", row, "LEFT", 4, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        text:SetWordWrap(false)
        row.text = text
        row:SetScript("OnClick", function() SelectRow(row) end)
        rows[i] = row
    end
end

local function FillList()
    EnsureRows(#dataRows)
    for i = 1, #rows do
        local row = rows[i]
        local d = dataRows[i]
        if d then
            row.data = d
            row.text:SetText(d.label)
            row:Show()
        else
            row.data = nil
            row:Hide()
        end
    end
    content:SetHeight(math.max(1, #dataRows * ROW_H))
    pcall(scroll.SetVerticalScroll, scroll, 0)
    UpdateIndicator()
end

local function BuildPanel()
    if panel then return end

    panel = Widget:CreateFrame("MonetUIDevProbeFrame", UIParent, PANEL_SIZE, PANEL_SIZE)
    panel:SetFrameStrata("DIALOG")
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    panel:SetClampedToScreen(true)
    -- 主题色边框 + 深色底（主题刷新自动重涂）；斜纹画布走 ButtonMaterial 的织纹层，
    -- 与配置面板下拉同一套画风（ADD 白织纹，不烧色）。
    Widget:Theme(panel, { thickness = 2, bgAlpha = 0.96, borderAlpha = 1 })
    Widget:ButtonMaterial(panel, { alpha = 0, weaveAlpha = 0.18 })
    Widget:Shadow(panel, { size = 6, alpha = 0.5 })
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local title = Widget:Font(panel, 14, "pixel", "edge", "LEFT")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -9)
    title:SetText("元素探测")

    local close = Widget:CloseButton(panel, 20)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() DevProbe:Close() end)

    statusText = Widget:Font(panel, 12, "pixel", "neutral", "LEFT")
    statusText:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -30)
    statusText:SetWidth(LIST_W)
    statusText:SetWordWrap(false)
    statusText:SetText("指针放到目标窗口上，再输 /mui dig")

    scroll = CreateFrame("ScrollFrame", "MonetUIDevProbeList", panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -48)
    scroll:SetSize(LIST_W, LIST_H)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_W, 1)
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        ScrollBy(-delta * ROW_H * 3)
    end)

    indicator = panel:CreateTexture(nil, "OVERLAY")
    indicator:SetWidth(2)
    indicator:Hide()

    copyBox = CreateFrame("EditBox", "MonetUIDevProbeCopy", panel, "BackdropTemplate")
    copyBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -212)
    copyBox:SetSize(LIST_W, 20)
    Widget:Theme(copyBox, { thickness = 1, bgAlpha = 0.9 })
    Widget:SetFont(copyBox, 12, "pixel")
    local er, eg, eb = Color:GetEdge()
    copyBox:SetTextColor(er, eg, eb)
    copyBox:SetTextInsets(6, 6, 0, 0)
    copyBox:SetAutoFocus(false)
    copyBox:SetScript("OnMouseUp", function(self)
        self:HighlightText()
        self:SetFocus()
    end)
    copyBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    copyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    copyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    hintText = Widget:Font(panel, 10, "pixel", "neutral", "LEFT")
    hintText:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -238)
    hintText:SetWidth(LIST_W)
    hintText:SetWordWrap(false)
    hintText:SetText("点行选中 · Ctrl+C 复制 · 滚轮翻页")

    panel:Hide()
end

-- ---------------------------------------------------------------------------
-- 枚举（只读走目标子树：GetChildren 递归 + 每框 GetRegions）

function Dig(root)
    dataRows = {}
    truncated = false
    local rootName = SafeName(root)
    currentRootName = rootName

    local function add(d)
        if #dataRows >= MAX_ROWS then
            truncated = true
            return
        end
        dataRows[#dataRows + 1] = d
    end

    local function walkRegions(frame, depth, ownerName)
        if type(frame.GetRegions) ~= "function" then return end
        local ok, regions = pcall(function() return { frame:GetRegions() } end)
        if not ok or type(regions) ~= "table" then return end
        local shown = 0
        for i = 1, #regions do
            if shown >= MAX_REGIONS or #dataRows >= MAX_ROWS then break end
            local reg = regions[i]
            local t = ReadType(reg)
            if t == "Texture" or t == "FontString" then
                shown = shown + 1
                local art = ReadArt(reg)
                local ours = ns:Marked(reg, "art") or ns:Marked(reg, "skinPlate")
                    or ns:Marked(reg, "skinBg") or ns:Marked(reg, "qualityBorder")
                local label = art or (t == "Texture" and "(贴图)" or "(文字)")
                if ours then label = "[我们的] " .. label end
                add({
                    label = string.rep("  ", depth) .. label,
                    copy = ownerName,
                    kind = "region", objType = t, art = art, depth = depth,
                })
            end
        end
    end

    local function walk(frame, depth)
        if #dataRows >= MAX_ROWS or depth > MAX_DEPTH then
            truncated = true
            return
        end
        if not Widget:Readable(frame) then
            add({ label = string.rep("  ", depth) .. "(读不出：forbidden)",
                  copy = nil, kind = "blocked", depth = depth })
            return
        end
        local name = SafeName(frame)
        local copy = name or NearestNamed(frame)
        add({
            label = string.rep("  ", depth) .. (name or "(匿名)"),
            copy = copy,
            kind = depth == 0 and "root" or "frame",
            objType = ReadType(frame), depth = depth,
        })
        walkRegions(frame, depth + 1, copy)
        if type(frame.GetChildren) ~= "function" then return end
        local ok, kids = pcall(function() return { frame:GetChildren() } end)
        if not ok or type(kids) ~= "table" then return end
        for i = 1, #kids do
            if #dataRows >= MAX_ROWS then
                truncated = true
                break
            end
            walk(kids[i], depth + 1)
        end
    end

    walk(root, 0)
    FillList()

    statusText:SetText(("目标：%s · %d 个元素%s"):format(
        rootName or "(匿名)", #dataRows, truncated and "（已截断）" or ""))
    hintText:SetText("点行选中 · Ctrl+C 复制 · 滚轮翻页")
    copyBox:SetText("")

    -- 长输出必须同时落账本（聊天框只留十几行；落盘比 /reload 晚 1–2 分钟）。
    local okDb, db = pcall(function() return ns:DB() end)
    if okDb and type(db) == "table" then
        local stamp
        if type(_G.date) == "function" then
            local okD, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
            if okD then stamp = s end
        end
        db.devProbeReport = {
            when = stamp, root = rootName or "(匿名)",
            total = #dataRows, truncated = truncated, rows = dataRows,
        }
    end
    ns:Print(("已探测 %s：%d 个元素，点面板里的行复制名字（全量在 MonetUIDB.devProbeReport）"):format(
        rootName or "(匿名)", #dataRows))
end

-- ---------------------------------------------------------------------------
-- 候选（命令当拍取：GetMouseFoci 优先；缺席退回 EnumerateFrames + IsMouseOver 全量扫）

function FindCandidate()
    if type(_G.GetMouseFoci) == "function" then
        local ok, foci = pcall(_G.GetMouseFoci)
        if ok and type(foci) == "table" then
            local best, bestDepth = nil, -1
            for i = 1, #foci do
                local f = foci[i]
                if type(f) == "table" and not OurFrame(f) and Widget:Readable(f) then
                    local d = DepthOf(f)
                    if d > bestDepth then best, bestDepth = f, d end
                end
            end
            return best
        end
    end
    -- 退路：全量扫 + IsMouseOver（Widget 封装已带 pcall/机密判定），取最深、同深取最小。
    if type(_G.EnumerateFrames) ~= "function" then return nil end
    local best, bestDepth, bestArea = nil, -1, math.huge
    local ok0, f = pcall(_G.EnumerateFrames)
    local count = 0
    while ok0 and f and count < 20000 do
        count = count + 1
        if type(f) == "table" and not OurFrame(f) and Widget:IsMouseOver(f) then
            local d = DepthOf(f)
            local okR, _, _, w, h = pcall(f.GetRect, f)
            local area = (okR and type(w) == "number" and type(h) == "number") and (w * h) or math.huge
            if d > bestDepth or (d == bestDepth and area < bestArea) then
                best, bestDepth, bestArea = f, d, area
            end
        end
        local okN, nxt = pcall(_G.EnumerateFrames, f)
        if not okN or nxt == f then break end
        f = nxt
    end
    return best
end

-- ---------------------------------------------------------------------------
-- 模块入口（DevProbe 表已在文件头前置声明）

function DevProbe:Open()
    BuildPanel()
    panel:Show()
end

function DevProbe:Close()
    if panel then panel:Hide() end
end

function DevProbe:Toggle()
    if panel and panel:IsShown() then
        self:Close()
    else
        self:Open()
    end
end

--- Core 顶层 `/mui dev` / `/mui dig` 与模块名兜底 `/mui devprobe <子命令>` 共用这一个入口。
function DevProbe:HandleCommand(rest)
    local arg = string.lower(rest or "")
    if arg == "dig" then
        -- 候选要在开面板**之前**取：面板落点在屏幕中央偏右，可能正好压住指针。
        local target = FindCandidate()
        self:Open()
        if target then
            Dig(target)
        else
            statusText:SetText("鼠标下没有框体。指针放到目标上，再输 /mui dig")
            ns:Print("指针下没有可枚举的框体：把鼠标指到目标窗口上，再输 /mui dig。")
        end
        return true
    end
    if arg == "" or arg == "dev" then
        self:Toggle()
        return true
    end
    if arg == "close" then
        self:Close()
        return true
    end
    ns:Print("用法：/mui dev（开关面板）· /mui dig（枚举指针下的窗体）")
    return true
end

function DevProbe:Initialize()
    -- 懒建：登录不造框，第一次 /mui dev 才建。命令门闸在 Core 的 DEV_COMMANDS。
end

ns:Register("DevProbe", DevProbe)