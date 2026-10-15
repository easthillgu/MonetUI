-- Modules/Skins/Social.lua
-- Friends / who, communities, guild and the calendar.  List rows are left
-- alone; only the windows, tabs, close buttons and the main scroll bars are
-- dressed.

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
