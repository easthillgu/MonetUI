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

--- 聊天框底边对齐到全局基线（和第一动作条同一条线，见 Utils/Layout.lua）。
--- 聊天窗口的位置是暴雪记在账号级布局里的，我们从没设过它（之前底边是 50，动作条 24），
--- 所以这里只"校底边"：左边的 X 保持用户自己的值，停靠的子窗口跟着主窗口走。
local function AlignChatBottom()
    local chat = _G.ChatFrame1
    if not chat or type(chat.GetRect) ~= "function" then return end
    local ok, left, bottom = pcall(chat.GetRect, chat)
    if not ok or type(left) ~= "number" or type(bottom) ~= "number" then return end

    local target = ns.Layout and ns.Layout.bottom
    if type(target) ~= "number" then return end

    -- 暴雪给聊天框加了屏幕内缩（实测左/下都留 32），SetPoint 到底边会被**夹回 32**，
    -- 所以 y=24 根本落不下来。先把下边内缩放宽到 target，其余三边保持暴雪原值。
    local okIns, insLeft, insRight, insTop, insBottom = pcall(chat.GetClampRectInsets, chat)
    if okIns and type(insLeft) == "number" and type(insRight) == "number"
        and type(insTop) == "number" and type(insBottom) == "number" then
        if -insBottom > target then
            pcall(chat.SetClampRectInsets, chat, insLeft, insRight, insTop, -target)
        end
    end

    if math.abs(bottom - target) < 0.01 then return end

    pcall(chat.ClearAllPoints, chat)
    pcall(chat.SetPoint, chat, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, target)
end

-- 暴雪的布局（编辑模式 / 登录恢复）可能在套用皮肤之后把聊天框放回去，所以每个
-- PLAYER_ENTERING_WORLD 再校一次；套用皮肤时也校一次（改设置立刻可见）。
if ns.EventBus then
    ns.EventBus:Register("PLAYER_ENTERING_WORLD", AlignChatBottom)
end

local function SkinChat()
    AlignChatBottom()

    M:Controls(CHAT_FRAMES, function(chat)
        ns.Skin:Strip(chat)
        ns.Skin:Panel(chat, { thickness = 1, bgAlpha = 0.35 })
    end)

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
