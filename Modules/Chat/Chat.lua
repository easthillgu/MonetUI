-- 聊天细条（2026-11-27）：**不再自建输入框**，输入框统一交给客户端自己的 `ChatFrame1EditBox`。
--
-- 为什么这么改（用户原话："输入窗可以并到这个 bar 的输入窗吗，合并起来"）：以前这套是
-- "独立 bar + 自建输入框"，屏上就是**两条输入框**（自建那条在上，客户端那条带「说：」头的在下）。
-- 自建那条只能按我们选中的频道发纯文本，`/mui`、`/invite`、物品链接、回复这类斜杠命令一律落到
-- "不支持这个斜杠命令" —— 所以真正能用的是客户端那条。于是反过来合并：**留客户端的输入框，
-- 我们只剩一条 3px 彩色细条贴在它上沿**，点格子 = 改客户端输入框的 chatType 属性并聚焦。
-- 不碰暴雪的 Lua、不覆写全局、不改受保护对象，只写一个普通框的属性（实测 header 会跟着变）。

local ADDON_NAME, ns = ...

local M = {}
local EventBus, Secrets, Scheduler = ns.EventBus, ns.Secrets, ns.Scheduler

local HOME = _G.LE_PARTY_CATEGORY_HOME or 1
local INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE or 2
-- 自定义频道（「综合 / 本地防务 / 大脚世界频道 …」）。
-- 2026-11-27 实测：`Enum.PermanentChatChannelType` 是一张**表**（不是值），拿它当频道类型比较
-- 会把所有自定义频道判掉、这本名单一直是空的（而且零报错）；真正的取值在 `Enum.ChatChannelType.Custom = 1`。
local CUSTOM_CHANNEL = _G.Enum and _G.Enum.ChatChannelType and _G.Enum.ChatChannelType.Custom or 1

local EVENTS = {
    "CHANNEL_UI_UPDATE", "CHANNEL_FLAGS_UPDATED", "GROUP_ROSTER_UPDATE",
    "RAID_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD",
}

local frame = nil
local customChannels, watching = {}, false
local active = false
-- 前向声明：`Render()`（在本文件靠前处）也要调它；直接写成后面的 `local function`
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

-- 固定频道：细条只用其中 6 个（本 / 官 只在细条外，靠 `/i`、`/o` 直达），
-- 但保留完整名单，`available()` 供细条判断"这个场景能不能用"。
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
    if a.chatType == "CHANNEL" then return a.name == b.name end
    return true
end

-- ------------------------------------------------------------------ 客户端的输入框（唯一入口）
local function NativeEditBox()
    local eb = _G.ChatFrame1EditBox
    if type(eb) ~= "table" then return nil end
    return eb
end

local function NativeAttr(name)
    local eb = NativeEditBox()
    if not eb then return nil end
    local ok, value = pcall(eb.GetAttribute, eb, name)
    if not ok then return nil end
    return ReadText(value)
end

--- 客户端输入框此刻的目标；读不到就按「说」。细条高亮照它画，玩家用 Tab 换频道、`/p` 之类也能跟上。
local function NativeTarget()
    local chatType = NativeAttr("chatType")
    if not chatType then return BY_KEY.SAY end
    if chatType == "CHANNEL" then
        local name = NativeAttr("channel")
        for _, channel in ipairs(customChannels) do
            if name and channel.name == name then return channel end
        end
        return BY_KEY.SAY
    end
    return BY_TYPE[chatType] or BY_KEY.SAY
end

-- ------------------------------------------------------------------ 频道细条（贴在输入框上沿）
-- 目标（2026-11-27）：一条**与聊天框同宽、3px 高**的细条，按频道顺序等分成格子，
-- 每格用该频道的颜色 —— 说 / 喊 / 密 / 队 / 团 / 公 / 世界（大脚世界频道）。
-- 3px 高不好点 ⇒ 整条给 6px 命中高度（色块只画最下面 3px，正好压在输入框顶边上）。
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
local STRIP_PAINT, STRIP_HIT = 3, 6
-- 细条/输入框的最小宽度：玩家把聊天窗拖得极窄时兜一下，免得输入区没地方。
local MIN_BAR_WIDTH = 260
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

local function SlotAvailable(slot, target)
    if not target then return false end
    if slot.key == "WORLD" then return true end
    return target.available()
end

local function Render()
    if not frame then return end
    local current = NativeTarget()
    local count = #STRIP_SLOTS
    local segWidth = frame:GetWidth() / count
    for index = 1, count do
        local slot = STRIP_SLOTS[index]
        local seg = strips[index]
        local target = SlotTarget(slot)
        local available = SlotAvailable(slot, target)
        seg.slot = slot
        seg.target = target
        seg.usable = available
        seg:ClearAllPoints()
        seg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", math.floor((index - 1) * segWidth), 0)
        seg:SetSize(math.max(2, math.floor(segWidth)), STRIP_HIT)
        local r, g, b = ChannelRGB(slot.chatType)
        seg.tex:SetColorTexture(r, g, b, 1)
        if not available then
            seg.tex:SetAlpha(STRIP_ALPHA_OFF)
        elseif SameTarget(current, target) then
            seg.tex:SetAlpha(1)
        else
            seg.tex:SetAlpha(STRIP_ALPHA_IDLE)
        end
        seg:EnableMouse(true)
    end
    -- 不可用的格子也要收鼠标（右键拖动得通），左键点击在 OnClick 里按 usable 挡掉。
    FollowWidth()
end

--- 点格子 = 把客户端输入框切到这一格并聚焦（只写属性，不调暴雪的 Lua）。
local function ApplySlot(slot)
    local eb = NativeEditBox()
    local target = SlotTarget(slot)
    if not eb or not target then return end
    pcall(eb.SetAttribute, eb, "chatType", target.chatType)
    if target.chatType == "CHANNEL" then
        pcall(eb.SetAttribute, eb, "channel", target.name)
    else
        pcall(eb.SetAttribute, eb, "channel", nil)
    end
    pcall(eb.Show, eb)
    pcall(eb.SetFocus, eb)
    if target.chatType == "WHISPER" then
        local ok, text = pcall(eb.GetText, eb)
        if ok and (ReadText(text) or "") == "" then
            pcall(eb.SetText, eb, "/w ")
            pcall(eb.SetCursorPosition, eb, 3)
        end
    end
    Render()
end

local function RefreshChannels()
    if not frame then return end
    customChannels = CollectCustomChannels()
    Render()
end

-- ------------------------------------------------------------------ 输入框位置（右键拖细条）
-- 玩家问"输入窗能否移动"（2026-11-27）：能 —— 清掉 `ChatFrame1EditBox` 原来那两条
-- （`BOTTOMLEFT/BOTTOMRIGHT → ChatFrame1:TOPLEFT/TOPRIGHT`）锚点、改成 UIParent 锚点，
-- 实测 5 秒内不会被客户端拽回去（见提交记录里的探针读数）。
-- 交互：**右键按住细条任意一格拖动**（左键仍是切频道，不吃冲突），松手落盘。
-- 注意 ①位置是我们直接写客户端框的锚点，重载后会回默认 ⇒ 存档 + 每秒复查，被拽回就补一次；
--      ②细条锚在输入框顶边，所以输入框一走，细条自己就跟上了。
local INPUT_STORE_KEY = "ChatInput"
local drag = nil

local function StoredInputPos()
    local db = ns:DB()
    local chat = db and db.chat
    local store = chat and chat.positions
    local pos = store and store[INPUT_STORE_KEY]
    if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then
        return pos
    end
    return nil
end

local function ApplyInputPos(pos)
    local eb = NativeEditBox()
    if not eb or not pos then return end
    pcall(eb.ClearAllPoints, eb)
    pcall(eb.SetPoint, eb, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    pcall(eb.SetWidth, eb, frame and frame:GetWidth() or MIN_BAR_WIDTH)
end

--- 客户端有没有把输入框拽回它自己的锚点（点方向 / 参照框 / 偏移任一不符就算）。
local function InputPosDrifted(pos)
    local eb = NativeEditBox()
    if not eb or not pos then return false end
    local okN, count = pcall(eb.GetNumPoints, eb)
    if not okN or count ~= 1 then return true end
    local okP, point, relative, _, x, y = pcall(eb.GetPoint, eb, 1)
    if not okP or point ~= "BOTTOMLEFT" or relative ~= UIParent then return true end
    if math.abs((tonumber(x) or 0) - pos.x) >= 1 then return true end
    if math.abs((tonumber(y) or 0) - pos.y) >= 1 then return true end
    return false
end

local function SaveInputPos(x, y)
    local db = ns:DB()
    local chat = db and db.chat
    if not chat then return end
    chat.positions = chat.positions or {}
    chat.positions[INPUT_STORE_KEY] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
end

--- `/mui chat reset`：把输入框还给客户端（清存档 + 恢复它原来那两条锚点）。
local function ResetInputPos()
    local db = ns:DB()
    local chat = db and db.chat
    if chat and chat.positions then chat.positions[INPUT_STORE_KEY] = nil end
    local eb = NativeEditBox()
    local host = _G.ChatFrame1
    if not eb or not host then return false end
    pcall(eb.ClearAllPoints, eb)
    pcall(eb.SetPoint, eb, "BOTTOMLEFT", host, "TOPLEFT", 0, 0)
    pcall(eb.SetPoint, eb, "BOTTOMRIGHT", host, "TOPRIGHT", 0, 0)
    return true
end

local function DragStep()
    local eb = NativeEditBox()
    if not drag or not eb then return end
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local w = eb:GetWidth()
    local x = cx - drag.dx
    local y = cy - drag.dy
    -- 夹在屏幕里，别拖出画面
    local maxX = math.max(0, UIParent:GetWidth() - w)
    local maxY = math.max(0, UIParent:GetHeight() - 31)
    if x < 0 then x = 0 elseif x > maxX then x = maxX end
    if y < 0 then y = 0 elseif y > maxY then y = maxY end
    drag.x, drag.y = x, y
    pcall(eb.ClearAllPoints, eb)
    pcall(eb.SetPoint, eb, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    pcall(eb.SetWidth, eb, frame and frame:GetWidth() or MIN_BAR_WIDTH)
end

local DragTick   -- Scheduler:Profile 的壳，Build 之后才建

local function StartDrag()
    local eb = NativeEditBox()
    if not eb or drag then return end
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local okL, l = pcall(eb.GetLeft, eb)
    local okB, b = pcall(eb.GetBottom, eb)
    if not okL or not okB or not l or not b then return end
    drag = { dx = cx - l, dy = cy - b, x = l, y = b }
    if not DragTick then
        DragTick = Scheduler:Profile("chat:draginput", "聊天:拖动输入框", DragStep)
    end
    frame:SetScript("OnUpdate", DragTick)
    frame:Show()
end

local function StopDrag()
    if not drag then return end
    local x, y = drag.x, drag.y
    drag = nil
    frame:SetScript("OnUpdate", nil)
    SaveInputPos(x, y)
end


function M:Refresh()
    if active then RefreshChannels() end
end

-- ------------------------------------------------------------------ 宽度跟随聊天框
-- 报障（2026-11-27）："聊天条比聊天框宽出来一截"。条是独立框（`WIDTH = 520` 写死），
-- 而聊天窗是 430（默认存档的宽度，玩家还能自己拖窄拖宽）—— 两边一旦不一致，条就伸到窗外面。
-- 做法（参照同机 easyChat）：**不写死宽度**，向聊天窗实测宽度看齐，1s 复查一次
-- （玩家拖宽聊天窗、换布局、重载都能跟上），再兜一个最小宽度。
local followId, highlightId
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
    -- 输入框被搬到别处时（右键拖过），宽度也跟聊天窗走，并且每秒复查一次锚点：
    -- 客户端自己的布局（FCF 更新、改窗口尺寸）可能把它拽回 `ChatFrame1` 顶上，拽回就补一次。
    local pos = StoredInputPos()
    if not pos then return end
    if InputPosDrifted(pos) then ApplyInputPos(pos) return end
    local eb = NativeEditBox()
    if eb and math.abs(eb:GetWidth() - w) >= 1 then pcall(eb.SetWidth, eb, w) end
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
    frame = CreateFrame("Frame", "MonetUIChatBar", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(30)
    frame:SetHeight(STRIP_HIT)
    frame:SetWidth(MIN_BAR_WIDTH)
    local eb = NativeEditBox() or _G.GeneralDockManager or UIParent
    frame:ClearAllPoints()
    -- 贴住客户端输入框的上沿（高度 6，色块画最下面 3px，正好压在输入框顶边上）。
    frame:SetPoint("BOTTOMLEFT", eb, "TOPLEFT", 0, 0)

    -- 频道细条：每格一颗按钮（6px 命中框），色块只占最下面 3px。
    for index = 1, #STRIP_SLOTS do
        local seg = CreateFrame("Button", nil, frame)
        seg.tex = seg:CreateTexture(nil, "OVERLAY")
        seg.tex:SetPoint("BOTTOMLEFT", seg, "BOTTOMLEFT", 0, 0)
        seg.tex:SetPoint("BOTTOMRIGHT", seg, "BOTTOMRIGHT", 0, 0)
        seg.tex:SetHeight(STRIP_PAINT)
        seg:SetScript("OnClick", function(self)
            if not self.usable then return end
            ApplySlot(self.slot)
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
        -- 右键按住拖 = 搬输入框（左键留给切频道，两者不抢）。
        seg:SetScript("OnMouseDown", function(_, button)
            if button == "RightButton" then StartDrag() end
        end)
        seg:SetScript("OnMouseUp", function()
            StopDrag()
        end)
        seg:EnableMouse(true)
        strips[index] = seg
    end
    FollowWidth()
end

function M:Initialize()
    if not frame then Build() end
    active = true
    RegisterEvents()
    RefreshChannels()
    ApplyInputPos(StoredInputPos())
    if not followId then
        followId = Scheduler:Every(1000, FollowWidth, "聊天:细条宽度")
    end
    if not highlightId then
        -- 玩家用 Tab / `/p` 换频道时，细条的高亮也要跟上（属性是客户端那边改的，我们只能读）。
        highlightId = Scheduler:Every(300, Render, "聊天:细条高亮")
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
        frame:Hide()
        if followId then
            Scheduler:Unregister(followId)
            followId = nil
        end
        if highlightId then
            Scheduler:Unregister(highlightId)
            highlightId = nil
        end
    end
end

function M:HandleCommand(rest)
    if rest == "reset" then
        if ResetInputPos() then
            ns:Print("聊天输入框已还给客户端（存档位置已清）。")
        else
            ns:Print("找不到 ChatFrame1 / ChatFrame1EditBox，没法还原。")
        end
        return true
    end
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
    local current = NativeTarget()
    ns:Print(("聊天细条：启用=%s，客户端输入框当前=%s，宽度=%d，自定义频道=%d，发送锁定=%s"):format(
        active and "是" or "否", current and current.label or "无",
        frame and math.floor(frame:GetWidth()) or -1, #customChannels, lockdown))
    return true
end

ns:Register("Chat", M)
