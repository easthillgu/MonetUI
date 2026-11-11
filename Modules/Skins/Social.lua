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
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true,
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
-- §8.89 实机（11-10 22:55）逐个点名：`ChatFrame1..10` 与其 `EditBox` **十个全在**，
-- 5..10 只是 `IsShown()=false`。补进名单后玩家启用备用窗口时它已经套好皮 / 钉好位，
-- 不会露出暴雪原样的输入框；PollWatch / HoverWatch 自带可见性门槛，隐藏窗不跑回调。
local CHAT_FRAMES = {
    "ChatFrame1", "ChatFrame2", "ChatFrame3", "ChatFrame4", "ChatFrame5",
    "ChatFrame6", "ChatFrame7", "ChatFrame8", "ChatFrame9", "ChatFrame10",
}

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
    "ChatFrame5EditBox", "ChatFrame6EditBox", "ChatFrame7EditBox", "ChatFrame8EditBox",
    "ChatFrame9EditBox", "ChatFrame10EditBox",
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

-- === CHAT BAND §8.89 BEGIN ===
--- §8.89 方案 C：输入框嵌在「框体内顶部」。
--- 实机（2026-11-10 22:55，session 49191）：cf `B32 H256 T288`（UIParent 子框 LOW/lvl5）、
--- eb `T389 B357`（UIParent 子框 LOW/lvl1）、Tab `T323 B291`(lvl2)、GDM `T317 B291`(lvl1)、
--- `skinBg` 是 cf 子框 lvl4 且 rect 与 cf 一致；`chatStyle=im` ⇒ 输入框常驻、消息已满 128 行。
--- 所以「直接把 eb 挪进 cf 矩形」会被消息文字盖住（lvl1 < lvl5）且长期遮字 ⇒ 不采用。
--- 改法：cf 高度减 32（消息区顶 288→256）、skinBg 上沿上扩 32（外框仍 B32..T288）、
--- eb 底边贴 cf 顶（落在 T256..T288 空带）⇒ 零遮挡、eb 在 cf 矩形外不受层级影响；
--- **同时把页签容器 `GeneralDockManager` 抬回 CHAT_INPUT_BAND**（它锚在 cf 的 background、
--- cf 缩高后整条跟着掉进输入框带、被 eb 吃掉点击，故一并抬升让页签回到原屏幕位）。
--- **改尺寸安全、改位置污染**：实测对 ChatFrame1（EditMode 系统帧）调 SetHeight 不会
--- 扩散污染（脏字段数不变、taint.log 空），而 SetPoint / SetClampRectInsets 会把帧标脏
--- （见上方"贴底已移除"的说明）。所以只改**高度**，位置和宽度完全交给暴雪/玩家。
local CHAT_INPUT_BAND = 32        -- 必须等于 EditBox 模板的 `<Size y="32"/>`
local CHAT_TAB_FADE   = 0.18      -- 页签淡入淡出时长（秒），贴近 Chattynator 的 0.15（§8.90 改读配置）
local CHAT_PIN_FNS = {}           -- 名字 → 稳定闭包（PollWatch 按引用去重）
local CHAT_HOVER = setmetatable({}, { __mode = "k" })  -- frame → true：任一悬停即显示页签
local KNOWN_EB = {}               -- 已纳入频道色跟踪的输入框名（ChatFrameNEditBox）
local chatHideToken = 0
local CHAT_FADE_TARGET           -- 淡入淡出目标 alpha（1 显示 / 0 隐藏）
local CHAT_FADE_FRAME            -- 承载 OnUpdate 插值的私有帧（仅在真客户端创建）

local ChatBand = {}
ChatBand.dynamic = {}    -- 运行期新建的临时聊天窗名（FCF_OpenTemporaryWindow，>10）

local function ReadNum(v)
    local S = ns.Secrets
    if type(v) ~= "number" then return nil end
    if S and S.IsSecret and S.IsSecret(v) then return nil end
    return v
end
ChatBand.ReadNum = ReadNum

--- 目标高度每次从 Minimap 现算 ⇒ 天然幂等，不需要「记住 base」的账本，
--- 玩家在 EditMode 改高度 / FCF_DockUpdate 重排，由 PollWatch 下一拍纠回。
function ChatBand:TargetHeight()
    local mm = Skin:Need("Minimap")
    if not mm or type(mm.GetHeight) ~= "function" then return nil end
    local ok, h = pcall(mm.GetHeight, mm)
    if not ok or type(h) ~= "number" or h <= CHAT_INPUT_BAND then return nil end
    return h - self:InputBand()
end

--- 只对**一个** cf 校高度；PollWatch 每窗一拍各管各的，不对 10 个窗重复全扫。
function ChatBand:PinHeight(cf)
    local target = self:TargetHeight()
    if not target or not cf or type(cf.GetHeight) ~= "function" then return false end
    local ok, cur = pcall(cf.GetHeight, cf)
    if ok and type(cur) == "number" and math.abs(cur - target) <= 0.5 then return false end
    pcall(cf.SetHeight, cf, target)
    return true
end

local function MatchChatHeight()
    ChatBand:IterateFrames(function(name)
        local f = Skin:Need(name)
        if f then ChatBand:PinHeight(f) end
    end)
end
ChatBand.MatchChatHeight = MatchChatHeight

--- 输入框：底边贴 cf 顶边，正好填满 skinBg 上扩出来的 32 空带。
--- **两个锚点都要判**（暴雪 FCF_DockUpdate 可能只改第二个点），否则会留半个错位框。
--- eb 非保护框，但绝不碰 cf 本体的 SetPoint / ClearAllPoints（taint 判例）。
function ChatBand:PinEditBox(name)
    local cf = Skin:Need(name)
    local eb = Skin:Need(name .. "EditBox")
    if not cf or not eb then return false end
    local okA, p1, a1, rp1, x1, y1 = pcall(eb.GetPoint, eb, 1)
    local okB, p2, a2, rp2, x2, y2 = pcall(eb.GetPoint, eb, 2)
    local already = okA and okB
        and p1 == "BOTTOMLEFT" and a1 == cf and rp1 == "TOPLEFT"
        and p2 == "BOTTOMRIGHT" and a2 == cf and rp2 == "TOPRIGHT"
        and math.abs((ReadNum(x1) or 99) - 0) < 0.6
        and math.abs((ReadNum(y1) or 99) - 0) < 0.6
        and math.abs((ReadNum(x2) or 99) - 0) < 0.6
        and math.abs((ReadNum(y2) or 99) - 0) < 0.6
    if not already then
        pcall(eb.ClearAllPoints, eb)
        pcall(eb.SetPoint, eb, "BOTTOMLEFT", cf, "TOPLEFT", 0, 0)
        pcall(eb.SetPoint, eb, "BOTTOMRIGHT", cf, "TOPRIGHT", 0, 0)
    end
    -- 暴雪把"非活动窗口"的输入框整框淡到 0.35；显示着的那条抬回全不透明。
    local okS, shown = pcall(eb.IsShown, eb)
    if okS and shown then
        local okAl, aRaw = pcall(eb.GetAlpha, eb)
        local a = okAl and ReadNum(aRaw) or nil
        if a and a < 0.99 then pcall(eb.SetAlpha, eb, 1) end
    end
    return not already
end

--- §8.91 输入框隐藏档：平时 `SetShown(false)` 折叠输入框带；当用户聚焦输入框（按 Enter / 点击聊天框进入输入态）
--- 暴雪会自动 Show 并聚焦，这里按焦点态保持显示，失焦后下一拍 PollWatch 重新隐藏。`HasFocus` 是 EditBox 标准方法，
--- 非保护框操作无 taint 风险；全程 pcall 兜住运行期异常。
function ChatBand:HideEditBox(name)
    local eb = Skin:Need(name .. "EditBox")
    if not eb then return end
    local okF, focused = pcall(eb.HasFocus, eb)
    local show = okF and focused
    pcall(eb.SetShown, eb, show)
    -- §8.91 修正：controlBg 背板（输入框背景色 / 频道色，见 §8.90）必须同步显隐，
    -- 否则 EditBox 藏了、背景色还挂在那（用户反馈"输入框背景色一直在"）。
    local okM, cb = pcall(ns.Marked, eb, "controlBg")
    if okM and cb and type(cb.SetShown) == "function" then
        pcall(cb.SetShown, cb, show)
    end
end

--- §8.89.4 声明式分发（借鉴 Chattynator 的 `skinner[regionType]`）：
--- 把「按区域类型钉合」的逻辑收进 `ChatBand.skinners`，`PinLayout` 只做分发。
--- 以后新增聊天子件（如缩放把手 ResizeWidget）只需往表里加一项，主干不必再改。
--- 注意：表里仍保留 `if name == "ChatFrame1" then self:PinDock() end` 这些字面结构，
--- 回归桩 `chat-band-probe.lua` 会按串校验，移走会红。
ChatBand.skinners = {
    frame = function(self, name, cf)
        self:PinHeight(cf)
        local pos = self:EditBoxPos()
        if pos == "top" or pos == "hidden" then
            self:PinEditBox(name)   -- hidden 也先钉到顶部带，避免聚焦时掉到底部
        end
        if pos == "hidden" then
            self:HideEditBox(name)  -- 平时折叠，聚焦弹出（在顶部带）
        end
        -- 页签容器 `GeneralDockManager` 在暴雪源码里锚在 `ChatFrameNBackground:TOPLEFT`
        -- （偏移 0），cf 缩高 32 后整条跟着框顶下移、掉进输入框带、被输入框吃掉点击。
        -- 框缩掉的高度正好 = CHAT_INPUT_BAND，所以把 GDM 相对它的原宿主框抬 CHAT_INPUT_BAND，
        -- 页签就回到缩高前的原屏幕位置（运行期已验：GDM B291..T317 = 原始位）。
        -- 只针对 ChatFrame1：GDM 是全局 dock，锚在它（dock primary）的 background 上。
        -- 去重由几何判定承担；Blizzard 重设 dock primary 时抹掉的偏移由 PollWatch 下一拍纠回。
        if name == "ChatFrame1" then
            self:PinDock()
        end
        self:ApplyChannelColorByName(name)   -- §8.90 周期重染输入框频道色
    end,
}

function ChatBand:Dispatch(region, name, cf)
    local sk = self.skinners[region]
    if sk then sk(self, name, cf) end
end

function ChatBand:PinLayout(name)
    local cf = Skin:Need(name)
    if not cf then return end
    self:Dispatch("frame", name, cf)
end

--- 把页签容器抬回输入框带上方。读取它当前第一锚点的相对框（暴雪用的 background），
--- 只改 y 偏移，不动相对框本身；第二锚点一并抬，防暴雪只重设其一。
--- `target` 为 nil（minimap 太矮、band 没激活）时不抬，避免把页签推离原位置。
function ChatBand:PinDock()
    local target = self:TargetHeight()
    if not target then return false end
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return false end
    local okP, p1, r1, rp1, x1, y1 = pcall(gdm.GetPoint, gdm, 1)
    if not okP or not p1 or not r1 then return false end
    local want = self:InputBand()
    local already = p1 == "BOTTOMLEFT" and rp1 == "TOPLEFT"
        and math.abs((ReadNum(x1) or 99) - 0) < 0.6
        and math.abs((ReadNum(y1) or 99) - want) < 0.6
    if not already then
        pcall(gdm.ClearAllPoints, gdm)
        pcall(gdm.SetPoint, gdm, "BOTTOMLEFT", r1, "TOPLEFT", 0, want)
        pcall(gdm.SetPoint, gdm, "BOTTOMRIGHT", r1, "TOPRIGHT", 0, want)
    end
    return not already
end

--- 页签悬停显示（§8.89）。
--- **不写 tab 自己的 alpha**：`Skin:UpdateTabState` 的 `fullAlpha` 有 0.5 秒轮询，
--- 会把任何 <0.99 的 tab alpha 抬回 1。改父容器 `GeneralDockManager` 的整框 alpha：
--- 所有 tab（parent = GDM 或 GDMScrollFrameChild）一起隐现；暴雪源码里没人写
--- GDM:SetAlpha，皮肤轮询也不碰它 ⇒ 无写手打架。alpha=0 的框仍参与 IsMouseOver 命中，
--- 页签照样点得到。暴雪自带的 `CHAT_FRAME_TAB_*_NOMOUSE_ALPHA`(0.2/0.4) 只是淡化，
--- 不是隐藏，所以不复用 `ChatFrameUtil.SetTabAlphas`。
--- 集中的配置读取（D）：所有聊天皮肤设置走这一层，SimpleConfig 只写 `db.skins.*`，
--- 不直接碰 ChatBand 内部；配置变化由 `CHAT_SKIN_SETTING_CHANGED` 事件总线广播。
function ChatBand:Opt(key)
    local db = (type(ns.DB) == "function") and ns:DB() or nil
    local cfg = db and db.skins
    return cfg and cfg[key]
end

--- 输入框位置（C）：`top` = 嵌框内顶部（默认，受 CHAT_INPUT_BAND 约束）；
--- `bottom` = 回到暴雪原生框底位置（不钉）；`hidden` = 输入框带折叠、cf 高度恢复、EditBox 隐藏。
--- 其它值一律按 top 处理。切换后需 /reload 生效（与 top↔bottom 同约定）。
function ChatBand:EditBoxPos()
    if self:Opt("chatEditBoxAutoHide") then return "hidden" end
    local p = self:Opt("chatEditBoxPos")
    return (p == "bottom") and "bottom" or "top"
end

--- 输入框带高度（topExtend / 页签抬升量）：`hidden` 时折叠为 0，否则 CHAT_INPUT_BAND。
--- 三处联动（Dress.topExtend、TargetHeight、PinDock.want）都读它，页签位置才不会错位。
function ChatBand:InputBand()
    -- `top` / `hidden` 都保留顶部输入框带（hidden 只是折叠 EditBox，不回收带高度，
    -- 否则聚焦弹出时输入框无处可去、会被暴雪原生钉到底部 —— 用户反馈"输入框跑到下面了"）。
    -- 仅 `bottom` 不预留带（输入框在原生底部）。
    return (self:EditBoxPos() == "bottom") and 0 or CHAT_INPUT_BAND
end

--- §8.90 输入框边框跟随当前频道色（Chatter 式）：读编辑框正在用的 `chatType` / `channelTarget`
--- → `ChatTypeInfo` 颜色，给 controlBg 的边框上色。**不解析任何消息文本**，只读取输入态。
--- 颜色经 `Widget:SetBorderState` 持久化到 controlBg：悬停/主题刷新都不覆盖，静止态显示频道色，
--- 悬停时 ControlState 临时换成高亮、移开再回到频道色。受限制状态下 `GetAttribute` 可能返回机密值，
--- 一律 pcall 包住、读不出就当没有色（不染）。
function ChatBand:ChannelColor(eb)
    if not eb or type(eb.GetAttribute) ~= "function" then return nil end
    local okT, chatType = pcall(eb.GetAttribute, eb, "chatType")
    if not okT or type(chatType) ~= "string" or chatType == "" then return nil end
    local info
    if chatType == "CHANNEL" then
        local okN, n = pcall(eb.GetAttribute, eb, "channelTarget")
        info = (ChatTypeInfo and ChatTypeInfo["CHANNEL" .. (n or 1)])
            or (ChatTypeInfo and ChatTypeInfo["CHANNEL1"])
    else
        info = ChatTypeInfo and ChatTypeInfo[chatType]
    end
    if info and type(info.r) == "number" then return info.r, info.g, info.b end
    return nil
end

function ChatBand:ApplyChannelColor(eb)
    if not eb then return end
    local cb = ns.Marked(eb, "controlBg")
    if not cb or type(Widget.SetBorderState) ~= "function" then return end
    local r, g, b = self:ChannelColor(eb)
    if not r then return end
    Widget:SetBorderState(cb, r, g, b, 1)
end

function ChatBand:ApplyChannelColorByName(name)
    self:ApplyChannelColor(Skin:Need(name .. "EditBox"))
end

--- 把输入框纳入频道色跟踪（SkinChat 初始化与临时窗注册时调用）。
function ChatBand:TrackEditBox(name)
    local eb = Skin:Need(name .. "EditBox")
    if eb then
        KNOWN_EB[name] = true
        self:ApplyChannelColor(eb)
    end
end

--- §8.90 页签淡入淡出时长：读配置 `tabFade`，非法 / ≤0 回退常量。
function ChatBand:FadeTime()
    local f = tonumber(self:Opt("tabFade"))
    if type(f) ~= "number" or f <= 0 then f = CHAT_TAB_FADE end
    return f
end

--- §8.90 遍历所有聊天窗（静态 1..10 + 运行期临时窗）。回调只收名字；幂等。
function ChatBand:IterateFrames(fn)
    if type(fn) ~= "function" then return end
    for _, name in ipairs(CHAT_FRAMES) do fn(name) end
    for name in pairs(self.dynamic) do fn(name) end
end

--- §8.90 给运行期新建的临时聊天窗（FCF_OpenTemporaryWindow，编号 >10）补齐皮肤与钉合。
--- 逻辑与 Init 里对 CHAT_FRAMES 的处理一一对应，只是按单窗名走。
function ChatBand:RegisterRuntimeChatFrame(name)
    local cf = Skin:Need(name)
    if not cf then return end
    M:Dress({ name }, { panel = { thickness = 1, bgAlpha = 0.35, borderAlpha = 1, topExtend = self:InputBand() } })
    M:Dress({ name .. "Tab" }, { as = "tab", control = { fullAlpha = true } })
    M:Dress({ name .. "EditBox" }, { as = "editbox" })
    if type(cf.ScrollToBottomButton) == "table" then
        Skin:ChatScrollAlert(cf.ScrollToBottomButton)
    end
    local fn = CHAT_PIN_FNS[name]
    if not fn then
        fn = function() ChatBand:PinLayout(name) end
        CHAT_PIN_FNS[name] = fn
    end
    Widget:PollWatch(cf, fn, 1)
    Widget:HoverWatch(cf, ChatHoverEnter, ChatHoverLeave)
    local eb = Skin:Need(name .. "EditBox")
    if eb then Widget:HoverWatch(eb, ChatHoverEnter, ChatHoverLeave) end
    self:TrackEditBox(name)
end

--- §8.90 安装一次 `FCF_OpenTemporaryWindow` 钩子：玩家开战网 / 交易 / 副本等临时窗（编号 >10）时，
--- 暴雪动态建出 ChatFrameN，只遍历 1..10 会漏。钩子里认领名字形如 `ChatFrame%d` 的新窗并补齐皮肤。
--- hooksecurefunc 不污染——只给非安全框上皮肤、不碰受保护 API。
local function EnsureTempWindowHook()
    if ChatBand._tempHooked then return end
    if type(hooksecurefunc) ~= "function" then return end
    ChatBand._tempHooked = true
    hooksecurefunc("FCF_OpenTemporaryWindow", function(chatFrame)
        if not chatFrame or type(chatFrame.GetName) ~= "function" then return end
        local ok, nm = pcall(chatFrame.GetName, chatFrame)
        if not ok or type(nm) ~= "string" or not nm:match("^ChatFrame%d+$") then return end
        if ChatBand.dynamic[nm] then return end
        ChatBand.dynamic[nm] = true
        ChatBand:RegisterRuntimeChatFrame(nm)
    end)
end

--- 安装一次 `ChatEdit_UpdateHeader` 钩子：暴雪每次刷新输入框头部（切频道 / 聚焦 / 输 `/w 名`）都走它，
--- 钩子里只按名字认领我们的输入框并即时重染边框。hooksecurefunc 不污染——只读取属性、给我们的
--- 非安全框上色，不碰任何受保护 API。受限制上下文里 `GetAttribute` 的机密值被 pcall 兜掉。
local function EnsureChannelHeaderHook()
    if ChatBand._headerHooked then return end
    if type(hooksecurefunc) ~= "function" then return end
    ChatBand._headerHooked = true
    hooksecurefunc("ChatEdit_UpdateHeader", function(eb)
        if not eb or type(eb.GetName) ~= "function" then return end
        local ok, nm = pcall(eb.GetName, eb)
        if ok and nm and KNOWN_EB[nm] then
            ChatBand:ApplyChannelColor(eb)
        end
    end)
end

function ChatBand:HoverEnabled()
    if self:Opt("hoverChatTabs") == false then return false end
    if type(M.IsEnabled) ~= "function" then return false end
    local ok, on = pcall(M.IsEnabled, M, "chat")
    return (ok and on) and true or false
end

function ChatBand:SetTabsVisible(on)
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return false end
    local want = on and 1 or 0
    local ok, cur = pcall(gdm.GetAlpha, gdm)
    if ok and type(cur) == "number" and math.abs(cur - want) < 0.01 then return false end
    pcall(gdm.SetAlpha, gdm, want)
    return true
end

--- 页签淡入淡出（B，借鉴 Chattynator 的 fadeInterpolator）。
--- 真帧挂 OnUpdate 做线性插值；桩环境 / 极端情况下没有可挂脚本的帧（`SetScript` 不存在），
--- 直接落到离散目标，行为不变 —— 这样回归桩依旧走硬切换、62 项不破。
function ChatBand:FadeTo(show)
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return end
    if type(gdm.SetScript) ~= "function" then
        self:SetTabsVisible(show)   -- show 已是布尔（true/false）；桩与真客户端都是标准 Lua，0 都为真，统一用布尔最稳
        return
    end
    local want = show and 1 or 0    -- 布尔 → alpha 数值；两种 Lua 里 0 都是真值，这里只把布尔 on/off 拼成 1/0
    local ok, cur = pcall(gdm.GetAlpha, gdm)
    cur = (ok and type(cur) == "number") and cur or want
    if math.abs(cur - want) < 0.01 then return end
    CHAT_FADE_TARGET = want
    if not CHAT_FADE_FRAME then
        CHAT_FADE_FRAME = CreateFrame("Frame")
        CHAT_FADE_FRAME:Hide()
        CHAT_FADE_FRAME:SetScript("OnUpdate", function(self, dt)
            local tgt = CHAT_FADE_TARGET
            if not tgt then self:Hide(); return end
            local g = Skin:Need("GeneralDockManager")
            if not g then self:Hide(); CHAT_FADE_TARGET = nil; return end
            local ok2, c = pcall(g.GetAlpha, g)
            c = (ok2 and type(c) == "number") and c or tgt
            local step = (dt or 0) / ChatBand:FadeTime()   -- 闭包里 self 是帧，不是 ChatBand；必须显式用表名调
            if tgt > c then c = math.min(tgt, c + step) else c = math.max(tgt, c - step) end
            pcall(g.SetAlpha, g, c)
            if math.abs(c - tgt) < 0.01 then
                pcall(g.SetAlpha, g, tgt)
                CHAT_FADE_TARGET = nil
                self:Hide()
            end
        end)
    end
    CHAT_FADE_FRAME:Show()
end

function ChatBand:AnyHover()
    for _, inside in pairs(CHAT_HOVER) do if inside then return true end end
    return false
end

--- 离开时延迟 2 秒才隐藏（B，借鉴 Chattynator 的 2s 延迟）：输入框带顶 T288 到页签条底
--- B291 有 3px 缝，直接 hide 会让鼠标跨缝那两帧闪一下。token 用来丢弃过期的隐藏请求，
--- 0.18s 淡出让显隐更顺，跨缝不再硬跳。
function ChatBand:Refresh()
    if not self:HoverEnabled() or self:AnyHover() then
        chatHideToken = chatHideToken + 1
        self:FadeTo(true)
        return
    end
    local token = chatHideToken + 1
    chatHideToken = token
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(2, function()
            if token ~= chatHideToken then return end
            if not ChatBand:HoverEnabled() or ChatBand:AnyHover() then return end
            ChatBand:FadeTo(false)
        end)
    else
        self:FadeTo(false)
    end
end

local function ChatHoverEnter(f)
    CHAT_HOVER[f] = true
    ChatBand:Refresh()
end
local function ChatHoverLeave(f)
    -- 跨缝保护（B，借鉴 Chattynator 的 OnLeave 二次校验）：离开回调触发时若光标其实
    -- 仍在帧上（子/父边界抖动），不清账、直接刷新（AnyHover 仍为真 ⇒ 保持显示），
    -- 避免把"还在框上"误判成"离开"而开始隐藏。
    local stillOver = false
    if type(f) == "table" and type(f.IsMouseOver) == "function" then
        local ok, over = pcall(f.IsMouseOver, f)
        stillOver = ok and over or false
    end
    if not stillOver then
        CHAT_HOVER[f] = nil
    end
    ChatBand:Refresh()
end
ChatBand.Enter, ChatBand.Leave = ChatHoverEnter, ChatHoverLeave

--- 触发区 = 所有聊天框 + 所有输入框 + 页签条容器。HoverWatch 自带可见性门槛，
--- 隐藏窗口不会跑回调；共用同一对模块级函数 ⇒ Apply 重跑也不会重复登记。
local function SetupChatTabHover()
    ChatBand:IterateFrames(function(name)
        local cf = Skin:Need(name)
        local eb = Skin:Need(name .. "EditBox")
        if cf then Widget:HoverWatch(cf, ChatHoverEnter, ChatHoverLeave) end
        if eb then Widget:HoverWatch(eb, ChatHoverEnter, ChatHoverLeave) end
    end)
    local gdm = Skin:Need("GeneralDockManager")
    if gdm then Widget:HoverWatch(gdm, ChatHoverEnter, ChatHoverLeave) end
    ChatBand:Refresh()
end
ChatBand.Setup = SetupChatTabHover

--- 配置面板的 setter 走这里（D）：只发事件，不直接调 ChatBand 内部。
--- 解耦后 SimpleConfig 不依赖 ChatBand 的任何方法名，只有 `RefreshChatTabHover` 这个稳定入口。
function M:RefreshChatTabHover()
    if ns.EventBus and type(ns.EventBus.Fire) == "function" then
        ns.EventBus:Fire("CHAT_SKIN_SETTING_CHANGED")
    end
end

-- 编辑模式 / 登录恢复可能在套皮后重排，进世界再校一次（SetHeight 幂等、无污染）。
if ns.EventBus then
    ns.EventBus:Register("PLAYER_ENTERING_WORLD", MatchChatHeight)
    -- D：配置变化（悬停开关 / 输入框位置）统一由这条事件触发页签刷新；
    -- 输入框位置由 PollWatch 下一拍自动按新值重钉，无需在这里手动重排。
    ns.EventBus:Register("CHAT_SKIN_SETTING_CHANGED", function()
        ChatBand:Refresh()
    end)
end

-- 旧的「输入框置顶（框外、页签行之上）」实现已由上面的 ChatBand 取代（§8.89）：
-- 新落点是框内顶部空带，几何与页签不再互相让位。历史推导留在 HANDOFF §8.62 / §8.88。

local function SkinChat()
    -- 底板**保持半透**（聊天浮在世界之上，要能透），1px 边框抬到满 alpha。
    -- `topExtend` 把上沿上扩 32 ⇒ cf 矮了 32 但外框轮廓仍是 B32..T288，
    -- 输入框就落在这条扩展出来的空带里（`Utils/Skin.lua` 的 `Skin:Panel`）。
    M:Dress(CHAT_FRAMES, {
        panel = { thickness = 1, bgAlpha = 0.35, borderAlpha = 1,
                  topExtend = ChatBand:InputBand() },
    })

    MatchChatHeight()

    M:Dress(CHAT_BUTTONS, { as = "button" })
    -- 页签走 Skin:Tab：选中态由现成的 0.5 秒轮询跟随（不 hook PanelTemplates_*，
    -- 全局函数钩会把整条编辑模式链带脏）。`fullAlpha` 抬平暴雪的整框鬼影；
    -- 页签**整体显隐**由父容器 GDM 的 alpha 管（见 ChatBand），两者不打架。
    M:Dress(CHAT_TABS, { as = "tab", control = { fullAlpha = true } })
    M:Dress(CHAT_EDITS, { as = "editbox" })
    -- §8.90 输入框边框跟频道色：认领这 10 个输入框 + 安装头部钩子（切频道即时重染）。
    EnsureChannelHeaderHook()
    -- §8.90 临时聊天窗（>10）动态覆盖钩子。
    EnsureTempWindowHook()
    for _, name in ipairs(CHAT_EDITS) do ChatBand:TrackEditBox(name) end

    -- 聊天窗"滚回底部"那枚箭头：暴雪逐帧重放它的 alpha 动画 ⇒ 压 α0 顶不住，只能换皮。
    for _, name in ipairs(CHAT_FRAMES) do
        local f = Skin:Need(name)
        if f and f.ScrollToBottomButton then
            Skin:ChatScrollAlert(f.ScrollToBottomButton)
        end
    end

    M:Dress(CHAT_CHANNEL_POPUPS, { window = true, inset = true, panel = { bgAlpha = 0.96 } })
    M:Dress(CHAT_CHANNEL_BUTTONS, { as = "button" })
    M:Dress(CHAT_EXTRA_WINDOWS, { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })

    -- 重钉：每个聊天窗挂**一个模块级稳定闭包**（`Widget:PollWatch` 按引用去重，
    -- 在 Apply 里现造闭包会每触发一次就多登记一条 —— AGENTS 的重复轮询判例）。
    ChatBand:IterateFrames(function(name)
        local f = Skin:Need(name)
        if f then
            local fn = CHAT_PIN_FNS[name]
            if not fn then
                fn = function() ChatBand:PinLayout(name) end
                CHAT_PIN_FNS[name] = fn
            end
            Widget:PollWatch(f, fn, 1)
        end
    end)

    SetupChatTabHover()
end
ChatBand.SkinChat = SkinChat

M:Panel("chat", { label = "聊天", group = "社交", apply = SkinChat,
    frames = {
        CHAT_FRAMES, CHAT_BUTTONS, CHAT_TABS, CHAT_EDITS,
        CHAT_CHANNEL_POPUPS, CHAT_CHANNEL_BUTTONS,
        CHAT_EXTRA_WINDOWS,
    } })
-- === CHAT BAND §8.89 END ===

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
