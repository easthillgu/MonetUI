-- Modules/Skins/Social.lua
-- Friends / who, communities, guild and the calendar.  List rows are left alone; only the windows, tabs, close buttons and the main scroll bars are dressed.
-- 本文件的所有美化都走 M:Dress：名字先过 Skin:Need 记账（缺什么 `/mui skins diagnose` 直接报），
-- 顺序固定为"剥原美术 → 挂底衬 → 窗口件 → 子控件深扫"，不在这里各写各的。

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin
local Widget = ns.Widget   -- 置顶那条要用 Widget:PollWatch；本文件以前没有这个 local
                           -- （AGENTS 记过：写成 `Widget:...` 就是全局 nil，闸门全绿、实机不生效）

-- 项目惯例（其余模块同款）：`ns:Marked` 是**冒号方法**（`function ns:Marked(object, key)`，
-- 见 Core.lua:576），必须带 self。本文件曾用点调用（`ns` 后接点、再传 eb 与键名），
-- self 被当成 object、键名被当成 key → 恒返回 nil，输入框背板永远取不到，
-- 表现就是"输入框背景色一直在、频道色不生效"（2026-11-11 实机截图 + 枚举定位）。
local Marked = function(o, k) return ns:Marked(o, k) end

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
local CHAT_TAB_LIFT   = 0         -- §8.92 页签容器相对 cf 顶的抬升量：0 = 落进输入带内、与 EditBox 同区
local CHAT_INPUT_BOOST = 3        -- §8.92 聚焦时 EditBox 抬到 GDM 之上所需的层数（页签 Tab = GDM+1）
local CHAT_TAB_FADE   = 0.18      -- 页签淡入淡出时长（秒），贴近 Chattynator 的 0.15（§8.90 改读配置）
--- §8.94 三层底板统一口径。改前实测（11-11 14:1x，2560×1440）三处 RGB 完全相同都是
--- (0.110,0.106,0.122)，但浓度三档：聊天框 0.349 / 页签 0.902 / 输入框 0.902，边框浓度两档：
--- 页签 0.80、聊天框与输入框 1.00。§8.93 把页签和输入框挪到框沿外侧之后，这两种密度紧挨着，
--- 视觉上"页签是实心块、聊天框只剩一圈线"，作者判为"背景和边框不统一"。
--- 现统一为：三处底板 CHAT_PLATE_ALPHA、三处 1px 边框 CHAT_EDGE_ALPHA。**任何一处改档都要一起改**。
local CHAT_PLATE_ALPHA = 0.35     -- 底板浓度（对齐聊天框既有的 0.35）
local CHAT_EDGE_ALPHA  = 0.80     -- 边框浓度（对齐页签既有的 0.80）
local CHAT_PIN_FNS = {}           -- 名字 → 稳定闭包（PollWatch 按引用去重）
local CHAT_HOVER = setmetatable({}, { __mode = "k" })  -- frame → true：任一悬停即显示页签
local KNOWN_EB = {}               -- 已纳入频道色跟踪的输入框名（ChatFrameNEditBox）
local INPUT_LAYER = {}            -- §8.92 名字 → { eb = 原始 frameLevel, cb = 原始背板 level }
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
--- §8.93：不再扣 `InputBand()`（恒 0），而是固定扣掉 `CHAT_INPUT_BAND`——cf 顶边于是落在
--- `minimapTop - 32`，正好等于小地图上沿（实机：小地图 T256，cf 底 32 ⇒ 高 224 ⇒ cf 顶 256）。
--- 输入框/页签都挂在这条顶边**外面**，不再从消息区里挖空间。
function ChatBand:TargetHeight()
    local mm = Skin:Need("Minimap")
    if not mm or type(mm.GetHeight) ~= "function" then return nil end
    local ok, h = pcall(mm.GetHeight, mm)
    if not ok or type(h) ~= "number" or h <= CHAT_INPUT_BAND then return nil end
    return h - CHAT_INPUT_BAND
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

--- §8.94 压掉 cf 自带的那层"黑底板 + 16px 黑边框"。
--- 实测（11-11 14:2x）`ChatFrame4:GetRegions()` 有 9 张 Texture：1 张 BACKGROUND（447×233，全黑）
--- + 8 张 BORDER（全黑 8/16/439 三种），**vertex alpha 全是 0.25 且 GetAlpha 也是 0.25**
--- ⇒ 有效 α ≈ 0.25。它叠在我们的 skinBg（0.35）之上，框体实际压暗 ≈ 0.51 ——
--- 而页签块只有我们那层 0.35，于是"页签块通透、聊天框发实"，正是作者说的"背景和边框不统一"。
--- 只写 SetAlpha(0)（不碰贴图/几何/顶点色），任一被暴雪重设都由 PinLayout 的 1 秒轮询纠回。
--- 判据只看 layer（BACKGROUND / BORDER）+ 对象类型 Texture，不点名贴图路径。
function ChatBand:FadeNativePlate(cf)
    if not cf or type(cf.GetRegions) ~= "function" then return end
    local okR, regions = pcall(function() return { cf:GetRegions() } end)
    if not okR then return end
    for _, reg in ipairs(regions) do
        if type(reg) == "table" and type(reg.SetAlpha) == "function" then
            local okK, kind = pcall(reg.GetObjectType, reg)
            local okL, layer = pcall(reg.GetDrawLayer, reg)
            if okK and kind == "Texture" and okL
                and (layer == "BACKGROUND" or layer == "BORDER") then
                local okA, a = pcall(reg.GetAlpha, reg)
                if not okA or a ~= 0 then pcall(reg.SetAlpha, reg, 0) end
            end
        end
    end
end

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

--- §8.92 输入框与页签同区（都在 32 输入带内）的层级切换：
--- 平时页签容器 `GeneralDockManager` 在带内可见（悬停淡入照旧），EditBox 收起来；
--- 聚焦输入时暴雪会把 EditBox 显示出来，但它与页签同区、原始 level 只等于 GDM（实机 LOW/lvl1），
--- 会被页签（GDM+1）压住 —— 于是把 eb 与它的 controlBg 一起抬到 GDM 之上，失焦再原样放回。
--- 只写我们自己能写的框（非保护 EditBox + 私有背板），pcall 兜住；原始 level 记在旁表，
--- 反复聚焦不会越抬越高。
function ChatBand:SyncInputLayer(name)
    local eb = Skin:Need(name .. "EditBox")
    if not eb or type(eb.SetFrameLevel) ~= "function" then return end
    local okF, focused = pcall(eb.HasFocus, eb)
    local up = okF and focused
    local rec = INPUT_LAYER[name]

    if up then
        if not rec then
            local okE, el = pcall(eb.GetFrameLevel, eb)
            rec = { eb = okE and el or nil, cb = nil }
            local cb = Marked(eb, "controlBg")
            if cb and type(cb.GetFrameLevel) == "function" then
                local okC, cl = pcall(cb.GetFrameLevel, cb)
                rec.cb = okC and cl or nil
            end
            INPUT_LAYER[name] = rec
        end
        local gdm = Skin:Need("GeneralDockManager")
        local gl = 1
        if gdm then
            local okG, g = pcall(gdm.GetFrameLevel, gdm)
            if okG and type(g) == "number" then gl = g end
        end
        local want = gl + CHAT_INPUT_BOOST
        pcall(eb.SetFrameLevel, eb, want)
        local cb = Marked(eb, "controlBg")
        if cb and type(cb.SetFrameLevel) == "function" then
            pcall(cb.SetFrameLevel, cb, want - 1)
        end
        return
    end

    if not rec then return end
    if rec.eb then pcall(eb.SetFrameLevel, eb, rec.eb) end
    local cb = Marked(eb, "controlBg")
    if cb and rec.cb and type(cb.SetFrameLevel) == "function" then
        pcall(cb.SetFrameLevel, cb, rec.cb)
    end
    INPUT_LAYER[name] = nil
end

--- §8.91 输入框隐藏档：平时 `SetShown(false)` 折叠输入框带；当用户聚焦输入框（按 Enter / 点击聊天框进入输入态）
--- 暴雪会自动 Show 并聚焦，这里按焦点态保持显示，失焦后下一拍 PollWatch 重新隐藏。`HasFocus` 是 EditBox 标准方法，
--- 非保护框操作无 taint 风险；全程 pcall 兜住运行期异常。
function ChatBand:HideEditBox(name)
    local eb = Skin:Need(name .. "EditBox")
    if not eb then return end
    local okF, focused = pcall(eb.HasFocus, eb)
    local show = okF and focused
    -- 先抬层再显示：否则这一拍 EditBox 会先以原 level 露出来、被同区的页签压住闪一下。
    self:SyncInputLayer(name)
    pcall(eb.SetShown, eb, show)
    -- §8.91 修正：controlBg 背板（输入框背景色 / 频道色，见 §8.90）必须同步显隐，
    -- 否则 EditBox 藏了、背景色还挂在那（用户反馈"输入框背景色一直在"）。
    local okM, cb = pcall(Marked, eb, "controlBg")
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
        self:FadeNativePlate(cf)   -- §8.94 暴雪黑底板/黑边框（α0.25）压 0，框体只剩我们那层 0.35
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
    -- 镀铬（页签容器 + ButtonFrame）是**全局一份**，只在 ChatFrame1 这一拍同步，别 10 个窗各写一遍。
    if name == "ChatFrame1" then self:SyncChrome() end
end

--- §8.94 页签在容器内的"落座"量：页签底 − 容器底（实测 ChatFrame4Tab 260 / GDM 259 ⇒ 1）。
--- 暴雪把页签挂在 GDM（或 GDM 的 ScrollFrameChild）里，页签比容器高 6、下沿还低 1，
--- 所以"容器底对齐框顶"会让页签底下留一条草地缝（作者 11-11 说"背景和边框不统一"时看到的那条）。
--- 这里现量，不写死数字；取不到可见页签就当 0（最多差 1 个单位）。
local function TabSeat(gdm)
    if not gdm or type(gdm.GetChildren) ~= "function" then return 0 end
    local okG, gb = pcall(gdm.GetBottom, gdm)
    if not okG or type(gb) ~= "number" then return 0 end
    local ok, kids = pcall(function() return { gdm:GetChildren() } end)
    if not ok then return 0 end
    local pool = {}
    for _, child in ipairs(kids) do
        pool[#pool + 1] = child
        local okC, gkids = pcall(function() return { child:GetChildren() } end)
        if okC then
            for _, g in ipairs(gkids) do pool[#pool + 1] = g end
        end
    end
    for _, tab in ipairs(pool) do
        local okN, nm = pcall(tab.GetName, tab)
        if okN and type(nm) == "string" and nm:match("Tab%d+$") then
            local okS, shown = pcall(tab.IsShown, tab)
            local okB, tb = pcall(tab.GetBottom, tab)
            if okS and shown and okB and type(tb) == "number" then
                return tb - gb
            end
        end
    end
    return 0
end

--- 把页签容器钉到**我们自己的聊天背板上沿**（不是暴雪 `ChatFrameNBackground`）。
--- 那层暴雪背景比 cf 内缩 3（实测 bg1 顶 259 / cf 顶 256），锚它页签就永远悬在框顶上方；
--- `skinBg` 与 cf 精确同边（32..256），锚它页签底板才能真正压住框顶那条 1px 线。
--- 偏移再减 `seat`，页签**自己的底边**落上框顶线，中间不留缝。
--- `target` 为 nil（minimap 太矮、band 没激活）时不钉，避免把页签推离原位置。
function ChatBand:PinDock()
    local target = self:TargetHeight()
    if not target then return false end
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return false end
    local okP, p1, r1, rp1, x1, y1 = pcall(gdm.GetPoint, gdm, 1)
    if not okP or not p1 or not r1 then return false end
    -- 相对框换成宿主聊天窗的皮肤背板；拿不到就退回原相对框（宁可行不齐，也别不钉）。
    local host = nil
    local okParent, par = pcall(r1.GetParent, r1)
    if okParent and par then host = par end
    local bg = host and Marked(host, "skinBg") or nil
    local ref = bg or r1
    local want = CHAT_TAB_LIFT - TabSeat(gdm)
    local already = p1 == "BOTTOMLEFT" and r1 == ref and rp1 == "TOPLEFT"
        and math.abs((ReadNum(x1) or 99) - 0) < 0.6
        and math.abs((ReadNum(y1) or 99) - want) < 0.6
    if not already then
        pcall(gdm.ClearAllPoints, gdm)
        pcall(gdm.SetPoint, gdm, "BOTTOMLEFT", ref, "TOPLEFT", 0, want)
        pcall(gdm.SetPoint, gdm, "BOTTOMRIGHT", ref, "TOPRIGHT", 0, want)
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
--- 不直接碰 ChatBand 内部；配置变化由 `MONETUI_CHAT_SKIN_SETTING_CHANGED` 事件总线广播。
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

--- 顶部外扩量（topExtend）：§8.93 起**恒 0**。外框不再从框内挖一条 32 的输入带 ——
--- 上沿与 cf 顶边齐平（cf 顶边又被 `TargetHeight` 对齐到小地图上沿），框内 100% 是消息区；
--- 页签与输入框（§8.92 同区、平时渐隐）骑在框顶上沿的**外侧**，像挂在边框上。
--- 保留这个函数是留一个语义出口：以后想恢复"框内含输入带"，只改这里一处。
function ChatBand:InputBand()
    return 0
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
    local cb = Marked(eb, "controlBg")
    if not cb or type(Widget.SetBorderState) ~= "function" then return end
    local r, g, b = self:ChannelColor(eb)
    if not r then return end
    Widget:SetBorderState(cb, r, g, b, CHAT_EDGE_ALPHA)
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
    M:Dress({ name }, { panel = { thickness = 1, bgAlpha = CHAT_PLATE_ALPHA,
                                  borderAlpha = CHAT_EDGE_ALPHA, topExtend = self:InputBand() } })
    M:Dress({ name .. "Tab" }, { as = "tab", control = {
        fullAlpha = true, bgAlpha = CHAT_PLATE_ALPHA, borderAlpha = CHAT_EDGE_ALPHA } })
    M:Dress({ name .. "EditBox" }, { as = "editbox", control = {
        bgAlpha = CHAT_PLATE_ALPHA, borderAlpha = CHAT_EDGE_ALPHA } })
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

--- 单个框写 alpha + 鼠标开关。α0 时必须**同时**关鼠标：暴雪按钮在 alpha 0 下仍然吃点击，
--- 否则鼠标扫过聊天窗左侧/左上角空白会莫名其妙弹出频道菜单、或拦住别人对底下的点击。
local function SetChromeOn(f, a)
    if not f then return end
    local ok, cur = pcall(f.GetAlpha, f)
    if not (ok and type(cur) == "number" and math.abs(cur - a) < 0.01) then
        pcall(f.SetAlpha, f, a)
    end
    if type(f.EnableMouse) == "function" then
        -- 鼠标开关单独判：暴雪在 Show / SetEnabled 里会重开鼠标，而 alpha 可能一点没变 ——
        -- 跟着 alpha 的"有变化才写"走，就会出现"看不见但突然又能点"。
        local want = (a or 0) > 0.05
        local okM, was = pcall(f.IsMouseEnabled, f)
        if not okM or was ~= want then
            pcall(f.EnableMouse, f, want)
        end
    end
end

--- 模块级稳定闭包：`IterateFrames` 每帧都要跑一次，现造闭包会每秒分配上百个（AGENTS 判例）。
local chromeAlpha = 1
local function ChromeOne(name)
    SetChromeOn(Skin:Need(name .. "ButtonFrame"), chromeAlpha)
end

--- 挂在聊天框外、但逻辑属于聊天框的两枚暴雪按钮（`FloatingChatFrame.lua` 的 `ReparentChatFrames`
--- 把它们从聊天框重挂到 UIParent，位置仍跟随 `chatFrame.buttonSide`）：
---   · `QuickJoinToastButton` —— 作者 11-11 说的"聊天框左上的社交按钮"，实机 32×32、t341/b309/l1，
---     有公会/好友组队邀请时左上角那个带数字的方块；
---   · `TextToSpeechButtonFrame` —— 语音朗读按钮容器，紧贴在它下方（t309/b283）。
local CHAT_CHROME_EXTRA = { "QuickJoinToastButton", "TextToSpeechButtonFrame" }

--- 页签容器 + 暴雪原生聊天镀铬（`ChatFrameNButtonFrame`：菜单 / 频道 / 最小化三枚按钮）同链显隐。
--- 作者 11-11 报"聊天框左上的社交按钮没有隐藏掉"：页签早已淡到 0，但 ButtonFrame 的 alpha 我们
--- 从没管过 —— 暴雪按窗口激活态自己写 1.0（实测 ChatFrame1..4）或 0.2（未激活窗 5..10），
--- 于是框左侧那枚喇叭按钮一直亮着，跟渐隐的页签明显不是一套。
--- 现在它跟 GDM 写同一个值：0 = 连按钮带背板一起消失，1 = 完整可用。
function ChatBand:ApplyChromeAlpha(a)
    chromeAlpha = a
    local gdm = Skin:Need("GeneralDockManager")
    if gdm then
        local ok, cur = pcall(gdm.GetAlpha, gdm)
        if not (ok and type(cur) == "number" and math.abs(cur - a) < 0.01) then
            pcall(gdm.SetAlpha, gdm, a)
        end
    end
    self:IterateFrames(ChromeOne)
    for _, nm in ipairs(CHAT_CHROME_EXTRA) do
        SetChromeOn(Skin:Need(nm), a)
    end
end

--- GDM 已在目标档时也照样同步 ButtonFrame：暴雪会在窗口激活 / CHAT_UPDATE 时把它改回 1.0 或 0.2，
--- 只比 GDM 就永远发现不了这个漂移（这正是"没隐藏掉"的直接原因）。
function ChatBand:SetTabsVisible(on)
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return false end
    local want = on and 1 or 0
    local ok, cur = pcall(gdm.GetAlpha, gdm)
    local changed = not (ok and type(cur) == "number" and math.abs(cur - want) < 0.01)
    self:ApplyChromeAlpha(want)
    return changed
end

--- 1 秒轮询里的兜底：淡入插值进行中交给 OnUpdate（`CHAT_FADE_TARGET` 非空时不抢写），
--- 平时按 GDM 现值纠回被暴雪改过的 ButtonFrame alpha。
function ChatBand:SyncChrome()
    if CHAT_FADE_TARGET then return end
    local gdm = Skin:Need("GeneralDockManager")
    if not gdm then return end
    local ok, cur = pcall(gdm.GetAlpha, gdm)
    if ok and type(cur) == "number" then self:ApplyChromeAlpha(cur) end
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
    if math.abs(cur - want) < 0.01 then
        -- GDM 已在目标档，但暴雪可能单独把 ButtonFrame 改回 1.0/0.2 ⇒ 顺手同步一次（§8.95）。
        self:ApplyChromeAlpha(want)
        return
    end
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
            -- 页签容器 + 按钮框写同一条曲线（§8.95）：只写 GDM 会看到"页签淡掉了、喇叭还亮着"。
            ChatBand:ApplyChromeAlpha(c)
            if math.abs(c - tgt) < 0.01 then
                ChatBand:ApplyChromeAlpha(tgt)
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
        ns.EventBus:Fire("MONETUI_CHAT_SKIN_SETTING_CHANGED")
    end
end

-- 编辑模式 / 登录恢复可能在套皮后重排，进世界再校一次（SetHeight 幂等、无污染）。
if ns.EventBus then
    ns.EventBus:Register("PLAYER_ENTERING_WORLD", MatchChatHeight)
    -- D：配置变化（悬停开关 / 输入框位置）统一由这条事件触发页签刷新；
    -- 输入框位置由 PollWatch 下一拍自动按新值重钉，无需在这里手动重排。
    ns.EventBus:Register("MONETUI_CHAT_SKIN_SETTING_CHANGED", function()
        ChatBand:Refresh()
    end)
end

-- 旧的「输入框置顶（框外、页签行之上）」实现已由上面的 ChatBand 取代（§8.89）：
-- 新落点是框内顶部空带，几何与页签不再互相让位。历史推导留在 HANDOFF §8.62 / §8.88。

local function SkinChat()
    -- 底板**保持半透**（聊天浮在世界之上，要能透）；边框浓度与底板浓度都由 §8.94 的两个常量给，
    -- 与页签背板、输入框背板同档 —— 三块紧邻的板子必须是同一密度，否则读成"实心页签 + 空心框"。
    -- `topExtend` 见 `ChatBand:InputBand()`（§8.93 起恒 0，外框上沿与小地图上沿齐平）。
    M:Dress(CHAT_FRAMES, {
        panel = { thickness = 1, bgAlpha = CHAT_PLATE_ALPHA,
                  borderAlpha = CHAT_EDGE_ALPHA, topExtend = ChatBand:InputBand() },
    })

    MatchChatHeight()

    M:Dress(CHAT_BUTTONS, { as = "button" })
    -- 页签走 Skin:Tab：选中态由现成的 0.5 秒轮询跟随（不 hook PanelTemplates_*，
    -- 全局函数钩会把整条编辑模式链带脏）。`fullAlpha` 抬平暴雪的整框鬼影；
    -- 页签**整体显隐**由父容器 GDM 的 alpha 管（见 ChatBand），两者不打架。
    -- §8.94 页签背板原来吃 Skin:Button 的默认档（0.90 底 / 0.80 边），现在显式与聊天框同档。
    M:Dress(CHAT_TABS, { as = "tab", control = {
        fullAlpha = true, bgAlpha = CHAT_PLATE_ALPHA, borderAlpha = CHAT_EDGE_ALPHA } })
    -- §8.94 输入框背板原来是 `Skin:EditBox` 里写死的 0.9，现在由这里传同一档（dresser 已支持 control）。
    M:Dress(CHAT_EDITS, { as = "editbox", control = {
        bgAlpha = CHAT_PLATE_ALPHA, borderAlpha = CHAT_EDGE_ALPHA } })
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
