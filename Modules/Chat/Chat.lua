-- 聊天条机制受 NDui 启发：独立输入框 + 频道切换；所有对象与脚本均为 MonetUI 自建。

local ADDON_NAME, ns = ...

local M = {}
local Widget, Skin, Mover = ns.Widget, ns.Skin, ns.Mover
local Color, EventBus, Secrets = ns.Color, ns.EventBus, ns.Secrets
local Scheduler = ns.Scheduler

local WIDTH, HEIGHT = 520, 30
local HOME = _G.LE_PARTY_CATEGORY_HOME or 1
local INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE or 2
local CUSTOM_CHANNEL = _G.Enum and _G.Enum.PermanentChatChannelType
    and _G.Enum.PermanentChatChannelType.Custom or 3
local EVENTS = {
    "CHANNEL_UI_UPDATE", "CHANNEL_FLAGS_UPDATED", "GROUP_ROSTER_UPDATE",
    "RAID_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD",
}

local frame, editBox, customButton, customIndex = nil, nil, nil, 1
local fixedButtons, buttonLabels = {}, {}
local customChannels, cycle, selected, watching = {}, {}, nil, false
local active = false
-- 前向声明：`Render()`（在本文件靠前处）末尾也要调它；直接写成后面的 `local function`
-- 会让 Render 里的名字解析成全局 nil（AGENTS「静态闸门抓不到」那条）。
local FollowWidth

local function ReadText(value)
    if type(value) ~= "string" or not Secrets.CanRead(value) then return nil end
    return value
end

local function ReadNumber(value)
    if type(value) ~= "number" then return nil end
    return Secrets.Number(value)
end

local function ReadBool(value, default)
    if type(value) ~= "boolean" or not Secrets.CanRead(value) then return default end
    return Secrets.Bool(value, default)
end

local function InGroup(category)
    local fn = _G.IsInGroup
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, category)
    return ok and ReadBool(value, false) or false
end

local function InRaid(category)
    local fn = _G.IsInRaid
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, category)
    return ok and ReadBool(value, false) or false
end

local function InGuild()
    local fn = _G.IsInGuild
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn)
    return ok and ReadBool(value, false) or false
end

local function IsOfficer()
    local api = _G.C_GuildInfo
    local fn = api and api.IsGuildOfficer
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn)
    return ok and ReadBool(value, false) or false
end

local FIXED = {
    { key = "SAY", label = "说", chatType = "SAY", available = function() return true end },
    { key = "YELL", label = "喊", chatType = "YELL", available = function() return true end },
    { key = "WHISPER", label = "密", chatType = "WHISPER", available = function() return true end },
    { key = "PARTY", label = "队", chatType = "PARTY", available = function()
        return InGroup(HOME) and not InRaid(HOME)
    end },
    { key = "RAID", label = "团", chatType = "RAID", available = function() return InRaid(HOME) end },
    { key = "INSTANCE_CHAT", label = "本", chatType = "INSTANCE_CHAT", available = function()
        return InGroup(INSTANCE)
    end },
    { key = "GUILD", label = "会", chatType = "GUILD", available = InGuild },
    { key = "OFFICER", label = "官", chatType = "OFFICER", available = function()
        return InGuild() and IsOfficer()
    end },
}

local BY_TYPE, BY_KEY = {}, {}
for _, entry in ipairs(FIXED) do
    BY_TYPE[entry.chatType] = entry
    BY_KEY[entry.key] = entry
end

local ALIASES = {
    s = "SAY", say = "SAY", y = "YELL", yell = "YELL", p = "PARTY", party = "PARTY",
    raid = "RAID", i = "INSTANCE_CHAT", instance = "INSTANCE_CHAT",
    g = "GUILD", guild = "GUILD", o = "OFFICER", officer = "OFFICER",
}

local function ResolveChannel(identifier)
    local api = _G.C_ChatInfo
    local fn = api and api.GetChannelInfoFromIdentifier
    if type(fn) ~= "function" then return nil end
    if type(identifier) == "number" then
        identifier = tostring(identifier)
    elseif type(identifier) ~= "string" then
        return nil
    end
    local ok, info = pcall(fn, identifier)
    if not ok or type(info) ~= "table" then return nil end
    local localID = ReadNumber(info.localID)
    local name = ReadText(info.name)
    local channelType = ReadNumber(info.channelType)
    if not localID or localID <= 0 or not name or name == "" or channelType ~= CUSTOM_CHANNEL then
        return nil
    end
    return { key = "CHANNEL", chatType = "CHANNEL", label = name, name = name, localID = localID }
end

local function ChannelFromLookup(identifier)
    local fn = _G.GetChannelName
    if type(fn) ~= "function" then return nil end
    local ok, localID = pcall(fn, identifier)
    if not ok then return nil end
    local id = ReadNumber(localID)
    if not id or id <= 0 then return nil end
    return ResolveChannel(id)
end

local function CollectCustomChannels()
    local out, seen = {}, {}
    local fn = _G.GetChannelName
    if type(fn) ~= "function" then return out end
    for index = 1, 20 do
        local ok, localID = pcall(fn, index)
        if ok then
            local id = ReadNumber(localID)
            if id and id > 0 and not seen[id] then
                local channel = ResolveChannel(id)
                if channel then
                    seen[id] = true
                    out[#out + 1] = channel
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.localID < b.localID end)
    return out
end

local function SameTarget(a, b)
    if not a or not b then return false end
    if a.chatType ~= b.chatType then return false end
    if a.chatType == "CHANNEL" then return a.localID == b.localID end
    return true
end

local function FindCustom(localID)
    for _, channel in ipairs(customChannels) do
        if channel.localID == localID then return channel end
    end
    return nil
end

local function ShortText(text, limit)
    local chars, count = {}, 0
    for char in string.gmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
        if count >= limit then break end
        chars[#chars + 1] = char
        count = count + 1
    end
    local out = table.concat(chars)
    if #out < #text then out = out .. "…" end
    return out
end

local function SetLabelColor(label, r, g, b)
    if label then label:SetTextColor(r, g, b, 1) end
end

local function PaintButton(button, chosen)
    if not button then return end
    local label = buttonLabels[button]
    if label then
        local r, g, b
        if chosen then
            r, g, b = Color:GetHighlight()
        else
            r, g, b = Color:GetNeutral()
        end
        SetLabelColor(label, r, g, b)
    end
    local bg = ns.Marked(button, "controlBg")
    if not bg then return end
    if chosen then
        local r, g, b = Color:GetHighlight()
        if Widget.SetBorderState then Widget:SetBorderState(bg, r, g, b, 1) end
        if bg.SetBackdropColor then bg:SetBackdropColor(r, g, b, 0.16) end
    else
        if Widget.SetBorderState then Widget:SetBorderState(bg, nil, nil, nil, nil) end
    end
end

local function Render()
    if not frame then return end
    local x = 6
    for _, entry in ipairs(FIXED) do
        local button = fixedButtons[entry.key]
        local available = entry.available()
        button:SetShown(available)
        if available then
            button:ClearAllPoints()
            button:SetPoint("LEFT", frame, "LEFT", x, 0)
            button:SetSize(26, 22)
            PaintButton(button, SameTarget(selected, entry))
            x = x + 28
        end
    end
    if #customChannels > 0 then
        customIndex = math.max(1, math.min(customIndex, #customChannels))
        local shown = selected and selected.chatType == "CHANNEL" and selected or customChannels[customIndex]
        local label = buttonLabels[customButton]
        if label then label:SetText(ShortText(shown.name, 5)) end
        customButton:SetShown(true)
        customButton:ClearAllPoints()
        customButton:SetPoint("LEFT", frame, "LEFT", x, 0)
        customButton:SetSize(64, 22)
        PaintButton(customButton, SameTarget(selected, shown))
        x = x + 66
    else
        customButton:SetShown(false)
    end
    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", frame, "LEFT", x, 0)
    editBox:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    editBox:SetHeight(22)
    FollowWidth()
end

local function RefreshChannels()
    if not frame then return end
    customChannels = CollectCustomChannels()
    cycle = {}
    for _, entry in ipairs(FIXED) do
        if entry.key ~= "YELL" and entry.key ~= "WHISPER" and entry.available() then
            cycle[#cycle + 1] = entry
        end
    end
    for _, channel in ipairs(customChannels) do cycle[#cycle + 1] = channel end
    if not selected or (selected.chatType == "CHANNEL" and not FindCustom(selected.localID)) then
        selected = cycle[1] or BY_KEY.SAY
    end
    Render()
end

function M:GetTarget()
    return selected
end

function M:Refresh()
    if active then RefreshChannels() end
end

local function SelectTarget(target, focus)
    if not active or not target then return end
    selected = target
    if target.chatType == "CHANNEL" then
        for index, channel in ipairs(customChannels) do
            if channel.localID == target.localID then customIndex = index; break end
        end
    end
    Render()
    if focus then
        if target.chatType == "WHISPER" then
            local text = ReadText(editBox:GetText())
            if text == "" then
                editBox:SetText("/w ")
                editBox:SetCursorPosition(3)
            end
        end
        editBox:SetFocus()
    end
end

function M:Cycle(reverse)
    if not active then return end
    RefreshChannels()
    if #cycle == 0 then return end
    local current
    for index, target in ipairs(cycle) do
        if SameTarget(selected, target) then current = index; break end
    end
    local nextIndex
    if current then
        nextIndex = (current + (reverse and -1 or 1) - 1) % #cycle + 1
    else
        nextIndex = reverse and #cycle or 1
    end
    SelectTarget(cycle[nextIndex], true)
end

local function Fail(reason)
    ns:Print("|cffff6b6b聊天条|r：" .. reason .. "；文本已保留。")
end

local function LockdownReason()
    local api = _G.C_ChatInfo
    local fn = api and api.InChatMessagingLockdown
    if type(fn) ~= "function" then return "当前客户端没有聊天锁定查询，已停止发送" end
    local ok, value = pcall(fn)
    if not ok or type(value) ~= "boolean" or not Secrets.CanRead(value) then
        return "聊天锁定状态不可读，已停止发送"
    end
    if Secrets.Bool(value, true) then return "聊天发送当前被锁定" end
    return nil
end

local function LanguageID()
    local fn = _G.GetDefaultLanguage
    if type(fn) ~= "function" then return nil end
    local ok, _, id = pcall(fn)
    if not ok then return nil end
    local number = ReadNumber(id)
    if number and number > 0 then return number end
    return nil
end

local function SplitTarget(text)
    local target, message = string.match(text, "^(%S+)%s+(.+)$")
    if not target or not message or message == "" then return nil end
    return target, message
end

local function Send()
    if not active then return end
    local raw = ReadText(editBox:GetText())
    if not raw then Fail("输入内容不可读"); return end
    local text = string.match(raw, "^%s*(.-)%s*$")
    if text == "" then return end
    local blocked = LockdownReason()
    if blocked then Fail(blocked); return end

    local target = selected or BY_KEY.SAY
    local message = text
    local command, rest = string.match(text, "^/(%S*)%s*(.*)$")
    if command then
        command = string.lower(command)
        local alias = ALIASES[command]
        if alias then
            target = BY_TYPE[alias]
            message = rest
            if not target.available() then Fail("当前没有这个聊天目标"); return end
        elseif command == "w" or command == "whisper" or command == "tell" then
            local who
            who, message = SplitTarget(rest)
            if not who then Fail("密语格式为 /w 名字 内容"); return end
            target = { key = "WHISPER", chatType = "WHISPER", label = "密语", target = who }
        elseif command == "channel" then
            local name
            name, message = SplitTarget(rest)
            target = name and ChannelFromLookup(name) or nil
            if not target then Fail("找不到这个已加入的自定义频道"); return end
        else
            local number = tonumber(command)
            if number and number >= 1 and number <= 20 and number == math.floor(number) then
                target = ChannelFromLookup(number)
            else
                target = ChannelFromLookup(command)
            end
            if not target then Fail("不支持这个斜杠命令"); return end
            message = rest
        end
    elseif target.chatType == "WHISPER" then
        local who
        who, message = SplitTarget(text)
        if not who then Fail("密语格式为 名字 内容，或 /w 名字 内容"); return end
        target = { key = "WHISPER", chatType = "WHISPER", label = "密语", target = who }
    end

    message = string.match(message, "^%s*(.-)%s*$")
    if message == "" then Fail("没有可发送的内容"); return end
    if target.chatType == "CHANNEL" then
        local channel = FindCustom(target.localID)
        if not channel then Fail("这个自定义频道已经离开"); return end
        target = channel
    end

    local api = _G.C_ChatInfo
    local send = api and api.SendChatMessage
    if type(send) ~= "function" then Fail("当前客户端没有聊天发送 API"); return end
    local languageID = LanguageID()
    local ok, result
    if target.chatType == "CHANNEL" then
        ok, result = pcall(send, message, "CHANNEL", languageID, target.localID)
    elseif target.chatType == "WHISPER" then
        ok, result = pcall(send, message, "WHISPER", languageID, target.target)
    else
        ok, result = pcall(send, message, target.chatType, languageID)
    end
    local failed = not ok
    if not failed and type(result) ~= "nil" then
        failed = type(result) ~= "boolean" or not Secrets.CanRead(result)
            or not Secrets.Bool(result, true)
    end
    if failed then
        Fail("发送失败")
        return
    end
    editBox:SetText("")
end

-- ------------------------------------------------------------------ 宽度跟随聊天框
-- 报障（2026-11-27）："聊天条比聊天框宽出来一截"。聊天条是独立框（`WIDTH = 520` 写死），
-- 而聊天窗是 430（默认存档的宽度，玩家还能自己拖窄拖宽）—— 两边一旦不一致，条就伸到窗外面。
-- 做法（参照同机 easyChat）：**不写死宽度**，向聊天窗实测宽度看齐，1s 复查一次
-- （玩家拖宽聊天窗、换布局、重载都能跟上）。easyChat 那条按钮条是"按内容算宽 + 锚在
-- GeneralDockManager"，它永远不会比窗口宽；我们这条里有输入框，所以选"跟随窗口宽度"，
-- 再兜一个最小宽度，免得把窗拖得极窄时输入区被按钮挤没。
-- 只在非受限窗口写我们自己的框，不受保护约束。
local MIN_BAR_WIDTH = 260
local followId
local function ChatWindowWidth()
    local win = _G.ChatFrame1
    if type(win) ~= "table" or type(win.GetWidth) ~= "function" then return nil end
    local ok, w = pcall(win.GetWidth, win)
    if not ok or type(w) ~= "number" then return nil end
    w = Secrets.Number(w)
    if not w or w < 120 then return nil end
    return w
end

FollowWidth = function()
    if not frame then return end
    local w = ChatWindowWidth()
    if not w then return end
    if w < MIN_BAR_WIDTH then w = MIN_BAR_WIDTH end
    if math.abs(frame:GetWidth() - w) >= 1 then frame:SetWidth(w) end
end

local function OnEvent(_, event)
    if not active then return end
    if event == "MONETUI_THEME_CHANGED" then Render() else RefreshChannels() end
end

local function RegisterEvents()
    if watching then return end
    watching = true
    for _, event in ipairs(EVENTS) do EventBus:Register(event, OnEvent) end
    EventBus:Register("MONETUI_THEME_CHANGED", OnEvent)
end

local function Build()
    frame = Widget:CreateFrame("MonetUIChatBar", UIParent, WIDTH, HEIGHT, "BackdropTemplate", "Frame")
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.92 })
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(20)
    frame:EnableMouse(true)

    editBox = CreateFrame("EditBox", "MonetUIChatBarEditBox", frame, "BackdropTemplate")
    editBox:SetAutoFocus(false)
    editBox:SetTextInsets(8, 8, 0, 0)
    editBox:SetMaxLetters(255)
    Skin:EditBox(editBox, { bgAlpha = 0.92 })
    Widget:SetFont(editBox, 12, "pixel")
    local r, g, b = Color:GetEdge()
    editBox:SetTextColor(r, g, b)
    editBox:SetScript("OnTabPressed", function() M:Cycle(_G.IsShiftKeyDown and _G.IsShiftKeyDown() or false) end)
    editBox:SetScript("OnEnterPressed", Send)
    editBox:SetScript("OnEscapePressed", function()
        editBox:SetText("")
        editBox:ClearFocus()
    end)

    for _, entry in ipairs(FIXED) do
        local button = CreateFrame("Button", nil, frame, "BackdropTemplate")
        local label = Widget:Font(button, 11, "pixel", "neutral", "CENTER")
        button:SetFontString(label)
        label:SetAllPoints(button)
        label:SetText(entry.label)
        Skin:Button(button, { thickness = 1, bgAlpha = 0.82, size = 11 })
        button:SetScript("OnClick", function() SelectTarget(entry, true) end)
        fixedButtons[entry.key] = button
        buttonLabels[button] = label
    end

    customButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    local customLabel = Widget:Font(customButton, 10, "pixel", "neutral", "CENTER")
    customButton:SetFontString(customLabel)
    customLabel:SetAllPoints(customButton)
    customLabel:SetText("自定")
    Skin:Button(customButton, { thickness = 1, bgAlpha = 0.82, size = 10 })
    customButton:SetScript("OnClick", function()
        if #customChannels == 0 then return end
        if selected and selected.chatType == "CHANNEL" then
            customIndex = customIndex % #customChannels + 1
        else
            customIndex = math.max(1, math.min(customIndex, #customChannels))
        end
        SelectTarget(customChannels[customIndex], true)
    end)
    buttonLabels[customButton] = customLabel

    local dock = Skin:Need("GeneralDockManager")
    -- Tab 比容器高 6px；偏移 12px 后仍留 6px 间距。
    Mover:Register(frame, "ChatBar", {
        label = "聊天条",
        group = "general",
        store = ns:DB().chat.positions,
        default = {
            point = "BOTTOMLEFT",
            relativeTo = dock and "GeneralDockManager" or "UIParent",
            relativePoint = dock and "TOPLEFT" or "BOTTOMLEFT",
            x = dock and 0 or 20,
            y = dock and 12 or 2,
            fallback = {
                point = "BOTTOMLEFT", relativeTo = "UIParent", relativePoint = "BOTTOMLEFT", x = 20, y = 2,
            },
        },
        isVisible = function() return active end,
    })
    selected = BY_KEY.SAY
    FollowWidth()
end

function M:Initialize()
    if not frame then Build() end
    active = true
    RegisterEvents()
    RefreshChannels()
    FollowWidth()
    if not followId then
        followId = Scheduler:Every(1000, FollowWidth, "聊天:宽度跟随")
    end
    frame:Show()
    return true
end

function M:SetEnabled(value)
    active = value and true or false
    if not frame then
        if active then self:Initialize() end
        return
    end
    if active then
        self:Initialize()
    else
        editBox:ClearFocus()
        frame:Hide()
        if followId then
            Scheduler:Unregister(followId)
            followId = nil
        end
    end
end

function M:HandleCommand(rest)
    if rest ~= "status" then return false end
    local api = _G.C_ChatInfo
    local fn = api and api.InChatMessagingLockdown
    local lockdown = "API 缺失"
    if type(fn) == "function" then
        local ok, value = pcall(fn)
        if ok and type(value) == "boolean" and Secrets.CanRead(value) then
            lockdown = Secrets.Bool(value, true) and "是" or "否"
        else
            lockdown = "读不到"
        end
    end
    ns:Print(("聊天条：启用=%s，当前=%s，自定义频道=%d，发送锁定=%s"):format(
        active and "是" or "否", selected and selected.label or "无", #customChannels, lockdown))
    return true
end

ns:Register("Chat", M)
