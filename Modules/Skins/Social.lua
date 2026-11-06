-- Modules/Skins/Social.lua
-- Friends / who, communities, guild and the calendar.  List rows are left alone; only the windows, tabs, close buttons and the main scroll bars are dressed.
-- 本文件的所有美化都走 M:Dress：名字先过 Skin:Need 记账（缺什么 `/mui skins diagnose` 直接报），
-- 顺序固定为"剥原美术 → 挂底衬 → 窗口件 → 子控件深扫"，不在这里各写各的。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin
local Widget = ns.Widget   -- 置顶那条要用 Widget:PollWatch；本文件以前没有这个 local
                           -- （AGENTS 记过：写成 `Widget:...` 就是全局 nil，闸门全绿、实机不生效）

-- **1.60 实测（开服日 11-05，`/mui compat find Friends` 走 19805 个框，只返回这 18 个实名）**：
-- 编号页签只有 **1 / 3 / 4**，`FriendsFrameTab2`、`FriendsFrameTab5` 与
-- `FriendsFrameAddIgnoreButton`、`FriendsFrameBroadcastButton`、`FriendsFrameListScrollFrame`
-- 在本客户端**不存在**（离线佐证：`framexml-source` 的 `Blizzard_FriendsFrame/Mainline/FriendsFrame.xml`
-- 里列表是 `parentKey="ScrollBox"`(WowScrollBoxList) + `parentKey="ScrollBar"`(MinimalScrollBar)，
-- 全是**无名子件**，没有 `…ListScrollFrame` 这种东西）。⇒ 滚动区交给 `deep = true` 的整树扫，
-- 不再点这些死名；死名留在名单里只会变成台账上永远消不掉的一行 ✗。
local FRIENDS_TABS = {
    "FriendsFrameTab1", "FriendsFrameTab3", "FriendsFrameTab4",
}

local FRIENDS_BUTTONS = {
    "FriendsFrameSendMessageButton", "FriendsFrameAddFriendButton",
}

-- 1.60 把好友 / 公会 / 社区 / 黑名单合并进 `SocialUIFrame`（离线：`Blizzard_SocialUI/Mainline/
-- SocialUI.xml:3` 继承 `PortraitFrameTemplate`；实机：`/mui compat find Social` 返回
-- `SocialUIFrame` + `…CloseButton` + `…Inset`）。`FriendsFrame` 那套经典窗口同名也还在，
-- **哪一个真被 O 打开取决于玩家设置**，所以两扇都涂 —— 漏一扇就是玩家看到整块暴雪原样。
local SOCIAL_UI_WINDOW = "SocialUIFrame"

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
    })
    -- 合并版社交窗口同一套做法（窗口件 + 整树深扫；页签/列表都是运行期子件）。
    -- `deepRows = 4`：11-05 实机测得好友列表的行是
    -- `Button:匿名 <- Frame <- Frame <- Frame <- SocialUIFrame`（四深），默认的直接子件档扫不到
    -- ⇒ 那 12 件 `friends-card-*` 一直是 `α1.00 暴雪原样`。深度只给这一扇窗开：
    -- 递归深度就是轮询成本，不顺手加给所有窗口。
    M:Dress(SOCIAL_UI_WINDOW, {
        portrait = true,
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        deepRows = 4,
    })
end

-- **1.60 实测（`/mui compat find WhoFrame`）**：独立"查询"窗口 `WhoFrame` 不存在，
-- 三个按钮名（`WhoFrameWhoButton` / `…AddFriendButton` / `…GroupInviteButton`）和
-- `WhoListScrollFrame` 一起是死名 —— 查询已经并进好友窗的第 4 页，全客户端只剩
-- `WhoFrameEditBox` 和它的清除按钮两个实名。所以这里只涂那只有实名证据的输入框，
-- 页面本身由 `SkinFriends` 的 `FriendsFrame` / `SocialUIFrame` 深扫接住。
local WHO_EDIT = "WhoFrameEditBox"
local WHO_BUTTONS = { "WhoFrameEditBoxClearButton" }

local function SkinWho()
    M:Dress(WHO_EDIT, { as = "editbox" })
    M:Dress(WHO_BUTTONS, { as = "button" })
end

-- **A 档覆盖率补（11-05 `skin-coverage.js` 实机核对：这些窗此刻客户端真存在、又没美化）**。
-- 好友/邀请这一族是独立小窗：加好友、战网邀请、好友列表的"好友的好友"、拉新奖励。
-- 全走窗口档（剥原美术 + 挂底衬 + 标题/关闭 + 整树深扫），按钮/输入框由 deep 接住。
local ADDFRIEND_WINDOWS = {
    "AddFriendFrame", "BattleNetInviteFrame", "FriendsFriendsFrame",
    "RecruitAFriendRecruitmentFrame", "RecruitAFriendRewardsFrame",
}

local function SkinAddFriend()
    M:Dress(ADDFRIEND_WINDOWS, {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
    })
end

-- `CommunitiesFrameTab1..3` 在 1.60 没有实名（页签是 `TabSystemTemplate` 的运行期子件）⇒ 摘掉点名。

-- **A 档覆盖率补（11-05 skin-coverage 实机核对：客户端真存在、没美化）**：社区/公会那一族对话框
-- （新建/加入/设置/公会日志/新闻筛选/公会文本编辑/成员申请/头像选择）。全走窗口档 + deep。
local COMMUNITIES_DIALOGS = {
    "CommunitiesAddDialog", "CommunitiesCreateDialog", "CommunitiesSettingsDialog",
    "CommunitiesGuildLogFrame", "CommunitiesGuildNewsFiltersFrame",
    "CommunitiesGuildTextEditFrame", "CommunitiesTicketManagerDialog",
    "CommunitiesAvatarPickerDialog",
}

local function SkinCommunities()
    M:Dress("CommunitiesFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true,
    })
    M:Dress(COMMUNITIES_DIALOGS, {
        window = true, inset = true, panel = { bgAlpha = 0.97 }, deep = true,
    })
end

-- 1.60 的公会/好友/社区合并进 `SocialUIFrame`（见 A 批）；`GuildFrame` 是零售 12.x 的名字，
-- 这台机器上没有 ⇒ 在 1.60 的台账里那一行 ✗ 属**预期**（两客户端共用一份名单，不为一个客户端删另一个的名字）。
local GUILD_FRAMES = { "GuildFrame", "GuildControlUI", "GuildRegistrarFrame", "GuildInviteFrame" }

local function SkinGuild()
    M:Dress(GUILD_FRAMES, { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })
    -- **名册滚动区不再点名**（11-05 实机：`<窗口>.GuildRosterScrollFrame` / `<窗口>.RosterScrollFrame`
    -- 两种拼法都是照参考件猜的，实名一个都没有 ⇒ 9 行假缺失）。名册是 `ScrollBox` + `MinimalScrollBar`，
    -- 由上面 `M:Dress(GUILD_FRAMES …)` 的 `deep` 接住（§8.40 ②）。
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

-- **11-05 实机**：`ChatFrame1..4ScrollFrame` 没有实名（聊天窗的滚动条是运行期 `ScrollBar` 子件，
-- 18 个含 chatframe1 的实名里也没有它）⇒ 点名摘掉，滚动条由 `CHAT_FRAMES` 的深扫 / Skin:ScanScrollArrows 接。

-- 聊天窗右下角那两个按钮。原来的 `ChatFrameToggleButton` 是 3.x 时代的旧名，本客户端
-- 拿不到它存在的任何证据；有实名证据的是 `ChatFrameMenuButton` —— 同机为 Camelot 写的
-- EnhanceQoLChatSocial/ChatControlVisibility.lua:4-5（`ChatFrameChannelButton` /
-- `ChatFrameMenuButton`）与 EnhanceQoL/EnhanceQoL_Camelot.lua 的 `luacheck: globals` 行。
-- 所以那个菜单按钮从来没被换过皮。若实机 `/mui skins diagnose` 反过来证明旧名也在，再补回来。
local CHAT_BUTTONS = { "ChatFrameMenuButton", "ChatFrameChannelButton" }

-- 停靠在聊天窗底部的那排页签。命名是 **`ChatFrame<N>Tab`**（不是老框架的 `ChatFrameTab<N>`）：
-- 11-06 实机逐个点名，`ChatFrame1Tab..ChatFrame10Tab` **十个全在**（`交谈 5..10` 那些是暴雪预留的
-- 备用窗口，此刻 `IsShown()=false`，但**出生就要涂**，否则用户多开一个窗就露出一枚暴雪原样页签 ——
-- 上一版只点了 1 / 2，实机正是这个缺口：正在用的 `ChatFrame4Tab`（CHAT）10 张贴图全 α1）。
-- `fullAlpha = true`：暴雪会把非活动 / 未读的页签**整框**淡到 0.2~0.4，我们的贴图与文字跟着消失；
-- 抬回 1 之后，选中态由我们自己的下划线表达（判据见 `Skin:UpdateTabState` 末段）。
local CHAT_TABS = {
    "ChatFrame1Tab", "ChatFrame2Tab", "ChatFrame3Tab", "ChatFrame4Tab", "ChatFrame5Tab",
    "ChatFrame6Tab", "ChatFrame7Tab", "ChatFrame8Tab", "ChatFrame9Tab", "ChatFrame10Tab",
}

local CHAT_EDITS = {
    "ChatFrame1EditBox", "ChatFrame2EditBox", "ChatFrame3EditBox", "ChatFrame4EditBox",
}

local CHAT_CHANNEL_POPUPS = { "ChatChannelManagerPopup", "CreateChannelPopup", "EditChannelPopup" }

local CHAT_CHANNEL_BUTTONS = {
    "ChatChannelManagerPopupAcceptButton", "ChatChannelManagerPopupCancelButton",
    "ChatChannelManagerPopupDeleteButton",
}

-- A 档补：频道主窗 + 聊天设置窗（实机 skin-coverage 核对存在）。
local CHAT_EXTRA_WINDOWS = { "ChannelFrame", "ChatConfigFrame" }

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

-- 输入框**置顶**（2026-11-06 玩家拍板：摆在窗口上方、不遮文字）。
-- 实测暴雪把它钉在自己窗口的**下沿**：`ChatFrame4EditBox` = TOPLEFT→`ChatFrame4`BOTTOMLEFT (-5,-2)
-- 加 RIGHT→`ScrollBar`RIGHT (+8)；而**页签条停在窗口上沿**（`ChatFrame4Tab` 顶边比窗口顶边高 36 UI）
-- ⇒ 只钉到窗口顶边会盖住页签行，必须再让开一个页签高度。
-- 暴雪在 `FCF_DockUpdate`（拖窗 / 改大小 / 改停靠）里会把锚点重钉回底部，而我们不给暴雪框挂钩子
-- ⇒ 走 `Widget:PollWatch` 每 1 秒校一次，**几何真的对不上才写**（一次写 = 往暴雪框上落一次布局）。
-- 安全性：`ChatFrame1..10EditBox` 实测 `IsProtected()=false`（可写）；坐标读数一律先过机密值守卫。
local CHAT_PIN_FNS = {}   -- 名字 → 稳定闭包（PollWatch 按引用去重，绝不能在 Apply 里现造）

local function ReadNum(v)
    local S = ns.Secrets
    if type(v) ~= "number" then return nil end
    if S and S.IsSecret(v) then return nil end
    return v
end

local function PinChatEditBox(name)
    -- 存在性一律走 `Skin:Need`（AGENTS：确认对象只有一个漏斗，且这三类名字都在本档账上）
    local cf = Skin:Need(name)
    local eb = Skin:Need(name .. "EditBox")
    if not cf or not eb then return end
    local okF, raw = pcall(cf.GetTop, cf)
    local frameTop = okF and ReadNum(raw) or nil
    if not frameTop then return end
    -- 让开页签条自己那一行（页签隐藏 / 读不到几何时就只留 2px 缝）
    local dy = 2
    local tab = Skin:Need(name .. "Tab")
    if tab then
        local okS, shown = pcall(tab.IsShown, tab)
        local okT, tRaw = pcall(tab.GetTop, tab)
        local okH, hRaw = pcall(tab.GetHeight, tab)
        local tTop, tH = okT and ReadNum(tRaw) or nil, okH and ReadNum(hRaw) or nil
        if okS and shown and tTop and tH and tH > 0 and tTop > frameTop then
            dy = (tTop - frameTop) + tH + 2
        end
    end
    local okP, p1, a1, rp1, x1, y1 = pcall(eb.GetPoint, eb, 1)
    local already = okP and p1 == "BOTTOMLEFT" and a1 == cf and rp1 == "TOPLEFT"
        and math.abs((ReadNum(x1) or 0) + 5) < 0.6
        and math.abs((ReadNum(y1) or 0) - dy) < 0.6
    if not already then
        pcall(eb.ClearAllPoints, eb)
        pcall(eb.SetPoint, eb, "BOTTOMLEFT", cf, "TOPLEFT", -5, dy)
        -- 右沿用 +8 跟原来对齐（暴雪原来锚到无名 `ScrollBar` 的 RIGHT +8，宽度就是窗口宽 + 那点出血）
        pcall(eb.SetPoint, eb, "BOTTOMRIGHT", cf, "TOPRIGHT", 8, dy)
    end
    -- 暴雪还把"非当前活动窗口"的输入框整框淡到 0.349（实测 1..10 全中、连我们没点名的 5/6 也一样）
    -- ⇒ 我们的底衬与边框在那种强度下读不出来。显示着的那条抬回全不透明。
    if pcall(eb.IsShown, eb) then
        local okA, aRaw = pcall(eb.GetAlpha, eb)
        local a = okA and ReadNum(aRaw) or nil
        if a and a < 0.99 then pcall(eb.SetAlpha, eb, 1) end
    end
end

local function SkinChat()
    -- 底板按玩家拍板**保持半透**（聊天浮在世界之上，要能透），但把 1px 边框抬到满 alpha：
    -- 以前边框 alpha 跟着 `edge` 的默认强度走，在 0.35 的底上一起发虚 ⇒ "背景/边框观感"那条。
    M:Dress(CHAT_FRAMES, { panel = { thickness = 1, bgAlpha = 0.35, borderAlpha = 1 } })

    MatchChatHeight()

    M:Dress(CHAT_BUTTONS, { as = "button" })
    -- 页签走 Skin:Tab：选中态由现成的 0.5 秒轮询跟随（不 hook PanelTemplates_*，
    -- 那条钩子的代价在 Skin.lua:830 记过——全局函数钩会把整条编辑模式链带脏）。
    -- `fullAlpha` 关掉暴雪的整框鬼影（名单注释里有实测数字）。
    M:Dress(CHAT_TABS, { as = "tab", control = { fullAlpha = true } })
    M:Dress(CHAT_EDITS, { as = "editbox" })

    -- 聊天窗"滚回底部"那枚箭头（`ChatFrameN.ScrollToBottomButton`）：平时 `.Flash` 不显示，
    -- 窗口被往上滚 / 切页跳到底时暴雪逐帧重放它的 alpha 动画 ⇒ 压 α0 顶不住，只能换皮。
    -- 11-06 玩家报的"切完 tab 边框外侧多出一枚原始材质"就是它（静止扫描抓不到，0.1 秒记录器
    -- 抓到 `anon/Button [459,58 16x11] a=1.00`，父链 `← ChatFrame1`）。判据见 `Skin:ChatScrollAlert`。
    for _, name in ipairs(CHAT_FRAMES) do
        local f = Skin:Need(name)
        if f and f.ScrollToBottomButton then
            Skin:ChatScrollAlert(f.ScrollToBottomButton)
        end
    end

    -- Channel management: the popup list, and the two create/edit dialogs it opens.
    M:Dress(CHAT_CHANNEL_POPUPS, { window = true, inset = true, panel = { bgAlpha = 0.97 } })
    M:Dress(CHAT_CHANNEL_BUTTONS, { as = "button" })

    -- **A 档覆盖率补（11-05 skin-coverage 实机核对：客户端真存在、没美化）**：
    -- 聊天频道主窗 `ChannelFrame` 与聊天设置窗 `ChatConfigFrame`（暴雪新拆出来的设置面板）。
    M:Dress(CHAT_EXTRA_WINDOWS, { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })

    -- 置顶的重钉：每个聊天窗挂**一个模块级稳定闭包**（`Widget:PollWatch` 按引用去重，
    -- 在 Apply 里现造闭包会每触发一次就多登记一条 —— AGENTS 的重复轮询判例）。
    for _, name in ipairs(CHAT_FRAMES) do
        local f = Skin:Need(name)
        if f then
            local fn = CHAT_PIN_FNS[name]
            if not fn then
                fn = function() PinChatEditBox(name) end
                CHAT_PIN_FNS[name] = fn
            end
            Widget:PollWatch(f, fn, 1)
        end
    end
end

M:Panel("chat", { label = "聊天", group = "社交", apply = SkinChat,
    frames = {
        CHAT_FRAMES, CHAT_BUTTONS, CHAT_TABS, CHAT_EDITS,
        CHAT_CHANNEL_POPUPS, CHAT_CHANNEL_BUTTONS,
        CHAT_EXTRA_WINDOWS,
    } })

M:Panel("friends", {
    label = "好友 / 查询",
    group = "社交",
    apply = function()
        SkinFriends()
        SkinWho()
        SkinAddFriend()
    end,
    frames = {
        "FriendsFrame", "FriendsFrameCloseButton",
        FRIENDS_TABS, FRIENDS_BUTTONS,
        SOCIAL_UI_WINDOW,
        WHO_EDIT, WHO_BUTTONS,
        ADDFRIEND_WINDOWS,
    },
})

M:Panel("communities", {
    label = "社区",
    group = "社交",
    apply = SkinCommunities,
    frames = { "CommunitiesFrame", "CommunitiesFrameCloseButton", COMMUNITIES_DIALOGS },
})

M:Panel("guild", {
    label = "公会",
    group = "社交",
    apply = SkinGuild,
    frames = {
        GUILD_FRAMES,
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
