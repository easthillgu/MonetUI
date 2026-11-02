-- Modules/Skins/Social.lua
-- Friends / who, communities, guild and the calendar.  List rows are left alone; only the windows, tabs, close buttons and the main scroll bars are dressed.
-- 本文件的所有美化都走 M:Dress：名字先过 Skin:Need 记账（缺什么 `/mui skins diagnose` 直接报），
-- 顺序固定为"剥原美术 → 挂底衬 → 窗口件 → 子控件深扫"，不在这里各写各的。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local FRIENDS_TABS = {
    "FriendsFrameTab1", "FriendsFrameTab2", "FriendsFrameTab3",
    "FriendsFrameTab4", "FriendsFrameTab5",
}

local FRIENDS_BUTTONS = {
    "FriendsFrameSendMessageButton", "FriendsFrameAddFriendButton",
    "FriendsFrameAddIgnoreButton", "FriendsFrameBroadcastButton",
}

local function SkinFriends()
    -- 各标签页（好友 / 声望 / 团队 / 公会…）的列表用 ScrollBox，滚动条是无名 Frame + Thumb，
    -- 而且行在切页时才建出来。以前这里给每个子 Frame 各挂一条永久 ShowWatch（帧多、且切页
    -- 不触发父帧的显示瞬间）；deep 改成"一帧一条轮询，只在窗口可见时跑"，切页也能补上。
    M:Dress("FriendsFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        rule = true,
        tabs = FRIENDS_TABS,
        buttons = FRIENDS_BUTTONS,
        scrolls = { "FriendsFrameListScrollFrame" },
    })
end

local WHO_BUTTONS = { "WhoFrameWhoButton", "WhoFrameAddFriendButton", "WhoFrameGroupInviteButton" }

local function SkinWho()
    -- Who 在本客户端要么是独立窗口，要么就是 FriendsFrame 的第 4 页（查无独立窗口时退回它）。
    local frame = Skin:Need("WhoFrame") or Skin:Need("FriendsFrame")
    M:Dress(frame, {
        window = true, noTitle = true, inset = true, panel = { bgAlpha = 0.96 },
        buttons = WHO_BUTTONS, scrolls = { "WhoListScrollFrame" },
    })
end

local COMMUNITIES_TABS = { "CommunitiesFrameTab1", "CommunitiesFrameTab2", "CommunitiesFrameTab3" }

local function SkinCommunities()
    M:Dress("CommunitiesFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, tabs = COMMUNITIES_TABS,
    })
end

local GUILD_FRAMES = { "GuildFrame", "GuildControlUI", "GuildRegistrarFrame", "GuildInviteFrame" }

local function SkinGuild()
    M:Dress(GUILD_FRAMES, { window = true, inset = true, panel = { bgAlpha = 0.96 } })
    -- 名单滚动区挂在各窗口自己的成员上，两种命名都见过；逐个窗口短路取第一个存在的。
    for _, name in ipairs(GUILD_FRAMES) do
        local scroll = Skin:Need(name .. ".GuildRosterScrollFrame")
            or Skin:Need(name .. ".RosterScrollFrame")
        if scroll then Skin:ScrollFrame(scroll) end
    end
end

local CALENDAR_FRAMES = { "CalendarFrame", "GameCalendarFrame", "GameCalendarFrameSet" }

local function SkinCalendar()
    M:Dress(CALENDAR_FRAMES, { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })
end

-- Chat: the window chrome, its scroll bars, the toggle / channel buttons and the input box.  The chat
-- area gets a low-alpha plate rather than a full window one -- it sits over the world, so it has to
-- stay readable-through rather than opaque.  ChatFrameN's Background texture is in BACKDROP_PIECES, so
-- Strip already fades Blizzard's blue; the plate replaces it.
local CHAT_FRAMES = { "ChatFrame1", "ChatFrame2", "ChatFrame3", "ChatFrame4" }

local CHAT_SCROLLS = {
    "ChatFrame1ScrollFrame", "ChatFrame2ScrollFrame",
    "ChatFrame3ScrollFrame", "ChatFrame4ScrollFrame",
}

-- 聊天窗右下角那两个按钮。原来的 `ChatFrameToggleButton` 是 3.x 时代的旧名，本客户端
-- 拿不到它存在的任何证据；有实名证据的是 `ChatFrameMenuButton` —— 同机为 Camelot 写的
-- EnhanceQoLChatSocial/ChatControlVisibility.lua:4-5（`ChatFrameChannelButton` /
-- `ChatFrameMenuButton`）与 EnhanceQoL/EnhanceQoL_Camelot.lua 的 `luacheck: globals` 行。
-- 所以那个菜单按钮从来没被换过皮。若实机 `/mui skins diagnose` 反过来证明旧名也在，再补回来。
local CHAT_BUTTONS = { "ChatFrameMenuButton", "ChatFrameChannelButton" }

-- 停靠在聊天窗底部的那排页签。有实名证据的命名是 **`<窗口名>Tab`**（`ChatFrame1Tab` /
-- `ChatFrame2Tab`）：ChatControlVisibility.lua:6 用的就是 `ChatFrame1Tab`，
-- EnhanceQoL_Camelot.lua 的 globals 行同时给 `GENERAL_CHAT_DOCK` / `FCFDock_UpdateTabs`。
-- 反过来 `ChatFrameTab1..N`（老框架的编号命名）在这台机器上**没找到正面证据**——Polestar 里
-- 那处 `ChatFrameTab` 是 `Interface\ChatFrame\ChatFrameTab` 贴图路径，不是框名，所以这里不列它。
-- 有几个聊天窗就有几个页签；玩家自己开出来的临时/日志窗口没有实名证据，同样不列。
-- 实机用 `/mui compat find ChatFrame` 扫真名 + `/mui skins diagnose` 核这两个名字。
local CHAT_TABS = { "ChatFrame1Tab", "ChatFrame2Tab" }

local CHAT_EDITS = {
    "ChatFrame1EditBox", "ChatFrame2EditBox", "ChatFrame3EditBox", "ChatFrame4EditBox",
}

local CHAT_CHANNEL_POPUPS = { "ChatChannelManagerPopup", "CreateChannelPopup", "EditChannelPopup" }

local CHAT_CHANNEL_BUTTONS = {
    "ChatChannelManagerPopupAcceptButton", "ChatChannelManagerPopupCancelButton",
    "ChatChannelManagerPopupDeleteButton",
}

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
    local mm = Skin:Need("Minimap")
    if not mm or type(mm.GetHeight) ~= "function" then return end
    local ok, h = pcall(mm.GetHeight, mm)
    if not ok or type(h) ~= "number" or h <= 0 then return end
    for _, name in ipairs(CHAT_FRAMES) do
        local f = Skin:Need(name)
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
    M:Dress(CHAT_FRAMES, { panel = { thickness = 1, bgAlpha = 0.35 } })

    MatchChatHeight()

    M:Dress(CHAT_SCROLLS, { as = "scroll" })
    M:Dress(CHAT_BUTTONS, { as = "button" })
    -- 页签走 Skin:Tab：选中态由现成的 0.5 秒轮询跟随（不 hook PanelTemplates_*，
    -- 那条钩子的代价在 Skin.lua:830 记过——全局函数钩会把整条编辑模式链带脏）。
    M:Dress(CHAT_TABS, { as = "tab" })
    M:Dress(CHAT_EDITS, { as = "editbox" })

    -- Channel management: the popup list, and the two create/edit dialogs it opens.
    M:Dress(CHAT_CHANNEL_POPUPS, { window = true, inset = true, panel = { bgAlpha = 0.97 } })
    M:Dress(CHAT_CHANNEL_BUTTONS, { as = "button" })
end

M:Panel("chat", { label = "聊天", group = "社交", apply = SkinChat,
    frames = {
        CHAT_FRAMES, CHAT_SCROLLS, CHAT_BUTTONS, CHAT_TABS, CHAT_EDITS,
        CHAT_CHANNEL_POPUPS, CHAT_CHANNEL_BUTTONS,
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
        FRIENDS_TABS, FRIENDS_BUTTONS, "FriendsFrameListScrollFrame",
        "WhoFrame", "WhoListScrollFrame", WHO_BUTTONS,
    },
})

M:Panel("communities", {
    label = "社区",
    group = "社交",
    apply = SkinCommunities,
    frames = { "CommunitiesFrame", "CommunitiesFrameCloseButton", COMMUNITIES_TABS },
})

M:Panel("guild", {
    label = "公会",
    group = "社交",
    apply = SkinGuild,
    frames = {
        GUILD_FRAMES,
        "GuildFrame.GuildRosterScrollFrame", "GuildFrame.RosterScrollFrame",
    },
})

M:Panel("calendar", {
    label = "日历",
    group = "社交",
    apply = SkinCalendar,
    frames = { CALENDAR_FRAMES },
})

-- 签名请愿（公会/战队登记表）：UIPanels_Game 的 [Family] PetitionFrame 无 game-type 门控。
local PETITION_BUTTONS = {
    "PetitionFrameSignButton", "PetitionFrameRequestButton",
    "PetitionFrameRenameButton", "PetitionFrameCancelButton",
}

local function SkinPetition()
    M:Dress("PetitionFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = PETITION_BUTTONS,
    })
end

M:Panel("petition", {
    label = "签名请愿",
    group = "社交",
    apply = SkinPetition,
    frames = { "PetitionFrame", "PetitionFrameCloseButton", PETITION_BUTTONS },
})

-- 战袍设计（公会注册官处）：[Family] TabardFrame 无门控。
-- 自定义区的箭头/图标按钮带贴图内容，不做深扫，只收拾确定 / 取消。
local function SkinTabard()
    M:Dress("TabardFrame", {
        window = true,
        inset = true,
        -- 和商人窗同族：MoneyInset + MoneyBg 一对货币承托（实机 2026-11-02 枚举确认存在），
        -- 控件底语义：纯 lost 底 / 纯剥离，不上签名色边框。
        wells = {
            MoneyInset = { borderAlpha = 0 },
            MoneyBg = { panel = false },
        },
        panel = { bgAlpha = 0.96 },
        buttons = { "TabardFrameAcceptButton", "TabardFrameCancelButton" },
    })
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
