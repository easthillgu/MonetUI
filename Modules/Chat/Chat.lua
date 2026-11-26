-- 聊天条机制受 NDui 启发：独立输入框 + 频道切换；所有对象与脚本均为 MonetUI 自建。

local ADDON_NAME, ns = ...

local M = {}
local Widget, Skin, Mover = ns.Widget, ns.Skin, ns.Mover
local Color, EventBus, Secrets = ns.Color, ns.EventBus, ns.Secrets
local Scheduler = ns.Scheduler

local WIDTH, HEIGHT = 520, 30
local HOME = _G.LE_PARTY_CATEGORY_HOME or 1
local INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE or 2
-- 自定义频道（「综合 / 本地防务 / 大脚世界频道 …」）。
-- 2026-11-27 实测：`Enum.PermanentChatChannelType` 是一张**表**（不是值），拿它当频道类型比较
-- 会把所有自定义频道判掉、这本名单一直是空的（而且零报错）；真正的取值在 `Enum.ChatChannelType.Custom = 1`。
local CUSTOM_CHANNEL = _G.Enum and _G.Enum.ChatChannelType and _G.Enum.ChatChannelType.Custom or 1
    and _G.Enum.PermanentChatChannelType.Custom or 3
local EVENTS = {
    "CHANNEL_UI_UPDATE", "CHANNEL_FLAGS_UPDATED", "GROUP_ROSTER_UPDATE",
    "RAID_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD",
}

local frame, editBox = nil, nil
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

-- ------------------------------------------------------------------ 频道细条（聊天条上沿）
-- 目标（2026-11-27）：一条**与聊天框同宽、3px 高**的细条，按频道顺序等分成格子，
-- 每格用该频道的颜色 —— 说 / 喊 / 密 / 队 / 团 / 公 / 世界（大脚世界频道）。
-- 3px 高不好点 ⇒ 每格做成 8px 高的命中框（颜色只画顶上 3px），点哪格就切到哪个频道并聚焦输入。
-- 三档透明度：当前频道 100%，本场景可用但不是当前 55%，本场景用不上（不在队/团/公会、没这个世界频道）18%。
-- 颜色一律取 `ChatTypeInfo[<chatType>]`（1.60.1 / 71139 实测存在），缺表时用下面的兜底色。
local STRIP_SLOTS = {
    { key = "SAY",     chatType = "SAY",     label = "说" },
    { key = "YELL",    chatType = "YELL",    label = "喊" },
    { key = "WHISPER", chatType = "WHISPER", label = "密" },
    { key = "PARTY",   chatType = "PARTY",   label = "队" },
    { key = "RAID",    chatType = "RAID",    label = "团" },
    { key = "GUILD",   chatType = "GUILD",   label = "公" },
    { key = "WORLD",   chatType = "CHANNEL", label = "世界" },
}
local STRIP_PAINT, STRIP_HIT = 3, 8
local STRIP_ALPHA_IDLE, STRIP_ALPHA_OFF = 0.55, 0.18
local STRIP_FALLBACK = {
    SAY = { 1, 1, 1 }, YELL = { 1, 0.25, 0.25 }, WHISPER = { 1, 0.5, 1 },
    PARTY = { 0.66, 0.66, 1 }, RAID = { 1, 0.5, 0 }, GUILD = { 0.25, 1, 0.25 },
    CHANNEL = { 1, 0.75, 0.75 },
}
local strips = {}   -- 每格一个按钮（含 3px 色块），Build 时建一次

local function ChannelRGB(chatType)
    local info = _G.ChatTypeInfo and _G.ChatTypeInfo[chatType]
    if type(info) == "table" then
        local r, g, b = info.r, info.g, info.b
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return r, g, b
        end
    end
    local fallback = STRIP_FALLBACK[chatType] or STRIP_FALLBACK.SAY
    return fallback[1], fallback[2], fallback[3]
end

--- 「世界」格的目标 = 大脚世界频道（名字里带「世界」的自定义频道；不在这个频道里时这格不可点）。
local function WorldChannel()
    for _, channel in ipairs(customChannels) do
        local name = channel.name
        if type(name) == "string"
            and (string.find(name, "世界") or string.find(string.lower(name), "world")) then
            return channel
        end
    end
    return nil
end

local function SlotTarget(slot)
    if slot.key == "WORLD" then return WorldChannel() end
    return BY_KEY[slot.key]
end

local function Render()
    if not frame then return end
    local count = #STRIP_SLOTS
    local segWidth = frame:GetWidth() / count
    for index = 1, count do
        local slot = STRIP_SLOTS[index]
        local seg = strips[index]
        local target = SlotTarget(slot)
        local available = target ~= nil and (slot.key == "WORLD" or target.available())
        seg.slot = slot
        seg.target = target
        seg:ClearAllPoints()
        seg:SetPoint("TOPLEFT", frame, "TOPLEFT", math.floor((index - 1) * segWidth), 0)
        seg:SetSize(math.max(2, math.floor(segWidth)), STRIP_HIT)
        local r, g, b = ChannelRGB(slot.chatType)
        seg.tex:SetColorTexture(r, g, b, 1)
        if not available then
            seg.tex:SetAlpha(STRIP_ALPHA_OFF)
        elseif SameTarget(selected, target) then
            seg.tex:SetAlpha(1)
        else
            seg.tex:SetAlpha(STRIP_ALPHA_IDLE)
        end
        seg.usable = available
        seg:EnableMouse(available)
    end
    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", frame, "LEFT", 6, 0)
    editBox:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    editBox:SetPoint("TOP", frame, "TOP", 0, -5)
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

    -- 频道细条：每格一颗按钮（8px 命中框），色块只占顶上 3px。
    for index = 1, #STRIP_SLOTS do
        local seg = CreateFrame("Button", nil, frame)
        seg.tex = seg:CreateTexture(nil, "OVERLAY")
        seg.tex:SetPoint("TOPLEFT", seg, "TOPLEFT", 0, 0)
        seg.tex:SetPoint("TOPRIGHT", seg, "TOPRIGHT", 0, 0)
        seg.tex:SetHeight(STRIP_PAINT)
        seg:SetScript("OnClick", function(self)
            if not self.usable or not self.target then return end
            SelectTarget(self.target, true)
        end)
        seg:SetScript("OnEnter", function(self)
            if not self.usable or type(_G.GameTooltip) ~= "table" then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.slot.label, 1, 1, 1)
            if self.target and type(self.target.name) == "string" then
                GameTooltip:AddLine(self.target.name, 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        seg:SetScript("OnLeave", function()
            if type(_G.GameTooltip) == "table" then GameTooltip:Hide() end
        end)
        seg:EnableMouse(false)
        strips[index] = seg
    end

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
