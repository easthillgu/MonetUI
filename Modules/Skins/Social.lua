-- Modules/Skins/Social.lua
-- Friends / who, communities, guild and the calendar.  List rows are left alone; only the windows, tabs, close buttons and the main scroll bars are dressed.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local FRIENDS_TABS = {
    "FriendsFrameTab1", "FriendsFrameTab2", "FriendsFrameTab3",
    "FriendsFrameTab4", "FriendsFrameTab5",
}

local function SkinFriends()
    local frame = _G.FriendsFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs(FRIENDS_TABS)

    M:Controls({
        "FriendsFrameSendMessageButton", "FriendsFrameAddFriendButton",
        "FriendsFrameAddIgnoreButton", "FriendsFrameBroadcastButton",
    }, function(button)
        Skin:Button(button)
    end)

    M:Scrolls({ "FriendsFrameListScrollFrame" })

    -- 各标签页（好友 / 声望 / 团队 / 公会…）的列表用 ScrollBox，滚动条是无名 Frame + Thumb；
    -- 递归扫一遍把它们也换上我们的细把手。标签内容懒加载，面板显示时再补一次。
    M:SkinScrollsIn(frame)
    M:HookShow(frame, function() M:SkinScrollsIn(frame) end)
    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            local okKind, kind = pcall(child.GetObjectType, child)
            if okKind and kind == "Frame" then
                pcall(M.HookShow, M, child, function() M:SkinScrollsIn(child) end)
            end
        end
    end
end

local function SkinWho()
    local frame = _G.WhoFrame or _G.FriendsFrame
    if not frame then return end
    M:SkinWindow(frame, { noTitle = true, panel = { bgAlpha = 0.96 } })
    M:Scrolls({ "WhoListScrollFrame" })
    M:Controls({ "WhoFrameWhoButton", "WhoFrameAddFriendButton", "WhoFrameGroupInviteButton" }, function(button)
        Skin:Button(button)
    end)
end

local function SkinCommunities()
    local frame = _G.CommunitiesFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Controls({ "CommunitiesFrameTab1", "CommunitiesFrameTab2", "CommunitiesFrameTab3" }, function(tab)
        Skin:Tab(tab)
    end)
    M:SkinScrollsIn(frame)
end

local function SkinGuild()
    M:Controls({ "GuildFrame", "GuildControlUI", "GuildRegistrarFrame", "GuildInviteFrame" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        Skin:ScrollFrame(frame.GuildRosterScrollFrame or frame.RosterScrollFrame)
    end)
end

local function SkinCalendar()
    M:Controls({ "CalendarFrame", "GameCalendarFrame", "GameCalendarFrameSet" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        M:SkinButtonsIn(frame)
    end)
end

-- Chat: the window chrome, its scroll bars, the toggle / channel buttons and the input box.  The chat
-- area gets a low-alpha plate rather than a full window one -- it sits over the world, so it has to
-- stay readable-through rather than opaque.  ChatFrameN's Background texture is in BACKDROP_PIECES, so
-- Strip already fades Blizzard's blue; the plate replaces it.
local CHAT_FRAMES = { "ChatFrame1", "ChatFrame2", "ChatFrame3", "ChatFrame4" }

--- 聊天框"贴底"已移除（2026-10-29）。
--- **原因：ChatFrame1 是暴雪 EditMode 的系统帧（system=8），从插件里对它做
--- ClearAllPoints / SetPoint / SetClampRectInsets 会把这个帧永久标脏**（AGENTS.md 的
--- "anchor family connection"）。它一脏，编辑模式 `InvokeOnAnyEditModeSystemAnchorChanged`
--- 用 `secureexecuterange` 遍历 52 个系统帧时整段执行被带脏 —— 实机后果：
--- `GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'MonetUI'`
--- （编辑模式 + 目标追踪两条栈同时炸，09:52:03）。暴雪/玩家自己记的聊天位置，
--- 我们不抢；需要贴底请在编辑模式里拖（那是暴雪自己的安全路径）。
--- 聊天框的**外观**美化（Strip + Panel + 滚动条 + 按钮 + 输入框）保留在下面。

--- 聊天框高度对齐小地图（2026-10-29）。
--- **改尺寸安全、改位置污染**：实测对 ChatFrame1（EditMode 系统帧）调 SetHeight 不会
--- 扩散污染（脏字段数不变、taint.log 空），而 SetPoint / SetClampRectInsets 会把帧标脏
--- （见下方"贴底已移除"的说明）。所以只对齐**高度**，位置和宽度完全交给暴雪/玩家。
local function MatchChatHeight()
    local mm = _G.Minimap
    if not mm or type(mm.GetHeight) ~= "function" then return end
    local ok, h = pcall(mm.GetHeight, mm)
    if not ok or type(h) ~= "number" or h <= 0 then return end
    for _, name in ipairs(CHAT_FRAMES) do
        local f = _G[name]
        if f and type(f.SetHeight) == "function" then
            local gok, cur = pcall(f.GetHeight, f)
            if not gok or math.abs((cur or 0) - h) > 0.5 then
                pcall(f.SetHeight, f, h)
            end
        end
    end
end

-- 编辑模式 / 登录恢复可能在套皮后重排，进世界再校一次（SetHeight 幂等、无污染）。
if ns.EventBus then
    ns.EventBus:Register("PLAYER_ENTERING_WORLD", MatchChatHeight)
end

local function SkinChat()
    M:Controls(CHAT_FRAMES, function(chat)
        ns.Skin:Strip(chat)
        ns.Skin:Panel(chat, { thickness = 1, bgAlpha = 0.35 })
    end)

    MatchChatHeight()

    M:Controls({
        "ChatFrame1ScrollFrame", "ChatFrame2ScrollFrame",
        "ChatFrame3ScrollFrame", "ChatFrame4ScrollFrame",
    }, function(scroll)
        ns.Skin:ScrollFrame(scroll)
    end)

    M:Controls({
        "ChatFrameToggleButton", "ChatFrameChannelButton",
        "ChatFrame1EditBox", "ChatFrame2EditBox", "ChatFrame3EditBox", "ChatFrame4EditBox",
    }, function(control)
        if not control then return end
        local kind = type(control.GetObjectType) == "function" and control:GetObjectType()
        if kind == "EditBox" then
            ns.Skin:EditBox(control)
        else
            ns.Skin:Button(control)
        end
    end)

    -- Channel management: the popup list, and the two create/edit dialogs it opens.
    M:Controls({ "ChatChannelManagerPopup", "CreateChannelPopup", "EditChannelPopup" }, function(popup)
        if popup then M:SkinWindow(popup, { panel = { bgAlpha = 0.97 } }) end
    end)
    M:Controls({
        "ChatChannelManagerPopupAcceptButton", "ChatChannelManagerPopupCancelButton",
        "ChatChannelManagerPopupDeleteButton",
    }, function(button)
        if button then ns.Skin:Button(button) end
    end)
end

M:Panel("chat", { label = "聊天", group = "社交", apply = SkinChat,
    frames = {
        "ChatFrame1", "ChatFrame2", "ChatFrame3", "ChatFrame4",
        "ChatFrame1ScrollFrame", "ChatFrame2ScrollFrame",
        "ChatFrame3ScrollFrame", "ChatFrame4ScrollFrame",
        "ChatFrameToggleButton", "ChatFrameChannelButton",
        "ChatFrame1EditBox", "ChatFrame2EditBox", "ChatFrame3EditBox", "ChatFrame4EditBox",
        "ChatChannelManagerPopup", "CreateChannelPopup", "EditChannelPopup",
        "ChatChannelManagerPopupAcceptButton", "ChatChannelManagerPopupCancelButton",
        "ChatChannelManagerPopupDeleteButton",
    } })

M:Panel("friends", {
    label = "好友 / 查询",
    group = "社交",
    apply = function()
        SkinFriends()
        SkinWho()
    end,
    frames = {
        "FriendsFrame", "FriendsFrameCloseButton",
        "FriendsFrameTab1", "FriendsFrameTab2", "FriendsFrameTab3",
        "FriendsFrameTab4", "FriendsFrameTab5",
        "FriendsFrameSendMessageButton", "FriendsFrameAddFriendButton",
        "FriendsFrameAddIgnoreButton", "FriendsFrameBroadcastButton",
        "FriendsFrameListScrollFrame",
        "WhoFrame", "WhoListScrollFrame",
        "WhoFrameWhoButton", "WhoFrameAddFriendButton", "WhoFrameGroupInviteButton",
    },
})

M:Panel("communities", {
    label = "社区",
    group = "社交",
    apply = SkinCommunities,
    frames = {
        "CommunitiesFrame", "CommunitiesFrameCloseButton",
        "CommunitiesFrameTab1", "CommunitiesFrameTab2", "CommunitiesFrameTab3",
    },
})

M:Panel("guild", {
    label = "公会",
    group = "社交",
    apply = SkinGuild,
    frames = {
        "GuildFrame", "GuildControlUI", "GuildRegistrarFrame", "GuildInviteFrame",
    },
})

M:Panel("calendar", {
    label = "日历",
    group = "社交",
    apply = SkinCalendar,
    frames = {
        "CalendarFrame", "GameCalendarFrame", "GameCalendarFrameSet",
    },
})

-- 签名请愿（公会/战队登记表）：UIPanels_Game 的 [Family] PetitionFrame 无 game-type 门控。
local function SkinPetition()
    local frame = _G.PetitionFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Buttons({
        "PetitionFrameSignButton", "PetitionFrameRequestButton",
        "PetitionFrameRenameButton", "PetitionFrameCancelButton",
    })
    M:SkinScrollsIn(frame)
end

M:Panel("petition", {
    label = "签名请愿",
    group = "社交",
    apply = SkinPetition,
    frames = {
        "PetitionFrame", "PetitionFrameCloseButton",
        "PetitionFrameSignButton", "PetitionFrameRequestButton",
        "PetitionFrameRenameButton", "PetitionFrameCancelButton",
    },
})

-- 战袍设计（公会注册官处）：[Family] TabardFrame 无门控。
-- 自定义区的箭头/图标按钮带贴图内容，不做 SkinButtonsIn，只收拾确定/取消。
local function SkinTabard()
    local frame = _G.TabardFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Buttons({ "TabardFrameAcceptButton", "TabardFrameCancelButton" })
end

M:Panel("tabard", {
    label = "战袍设计",
    group = "社交",
    apply = SkinTabard,
    frames = {
        "TabardFrame", "TabardFrameCloseButton",
        "TabardFrameAcceptButton", "TabardFrameCancelButton",
    },
})
