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
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Color  = ns.Color
local Media  = ns.Media

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

-- ===== 社区 / 公会窗的**内部**（1.60 实机结构，2026-11-13）=====
--
-- **为什么内部件全部"按字段 + 按形状"取**：本客户端的 `CommunitiesFrame:GetChildren()`
-- 返回**空表**（同一次实测 `GetNumChildren()` = 51，`GetRegions()` 也返回 0）⇒ 挂在窗口本体上的
-- `deep = true` 一趟子控件都扫不到，所以这扇窗以前只有窗壳 + 凹槽是我们的。
-- 内部件只能从字段进（`.MemberList` / `.CommunitiesList` / `.RosterTab` …）；再往里
-- （名册行、俱乐部条目）`GetChildren()` 正常，但它们是 ScrollBox **回收复用**的、下标随时变
-- ⇒ 认件一律看形状：整宽且薄（≤ 26）的是名册行，整宽且高 40–96 的是俱乐部条目。
--
-- 美术纪律（11-05 商人窗「铁槌图标被抹掉」判例的同一课）：这些控件里同时挂着 16×16 职业图标、
-- 52×51 公会旗 / 徽记、30×30 功能图标 —— **只压宽贴图**（宽度 ≥ 宿主宽度的 80%），
-- 绝不整框 `Skin:Strip(..., { regions = true })`。

--- 读字段（受限框上裸取字段会抛，统一裹住）。
local function Field(host, key)
    if not host then return nil end
    local ok, v = pcall(function() return host[key] end)
    if ok then return v end
    return nil
end

--- `GetChildren` / `GetRegions` 返回**多返回值**，必须用 `{ }` 包成表再遍历。
local function ListOf(host, getter)
    if not host or type(host[getter]) ~= "function" then return {} end
    local ok, list = pcall(function() return { host[getter](host) } end)
    if ok and type(list) == "table" then return list end
    return {}
end
local function ChildrenOf(host) return ListOf(host, "GetChildren") end
local function RegionsOf(host) return ListOf(host, "GetRegions") end

local function KindOf(obj)
    if not obj or type(obj.GetObjectType) ~= "function" then return nil end
    local ok, kind = pcall(obj.GetObjectType, obj)
    return ok and kind or nil
end

local function ShapeOf(obj)
    if not obj or type(obj.GetWidth) ~= "function" or type(obj.GetHeight) ~= "function" then return nil end
    local okW, w = pcall(obj.GetWidth, obj)
    local okH, h = pcall(obj.GetHeight, obj)
    if okW and okH and type(w) == "number" and type(h) == "number" then return w, h end
    return nil
end

local function IsButton(obj)
    if not obj then return false end
    if KindOf(obj) == "Button" then return true end
    if type(obj.IsObjectType) == "function" then
        local ok, v = pcall(obj.IsObjectType, obj, "Button")
        return (ok and v) and true or false
    end
    return false
end

--- 只压**宽贴图**（宽度 ≥ 宿主宽度的 ratio，默认 0.8）。
--- 名册行里除了整宽的底图还挂着 16×16 职业图标，俱乐部条目里有公会旗 / 徽记 / 功能图标 ——
--- 这个判据是"压掉窗体装饰、留住内容图标"唯一可行的分界线。
local function FadeWideArt(host, ratio)
    local w0 = ShapeOf(host)
    if not w0 then return 0 end
    local floor = w0 * (ratio or 0.8)
    local n = 0
    for _, reg in ipairs(RegionsOf(host)) do
        if KindOf(reg) == "Texture" and not Marked(reg, "art") then
            local w = ShapeOf(reg)
            if w and w >= floor then
                Skin:Fade(reg)
                n = n + 1
            end
        end
    end
    return n
end

--- 我们自己的一块平板（行 / 条目 / 页签的选中圈都用它）。
--- 挂宿主下一层（`level - 1`），所以画在宿主的贴图**后面**；关鼠标，绝不吃点击。
local function NewPlate(host, opts)
    if not host then return nil end
    local ok, plate = pcall(CreateFrame, "Frame", nil, host, "BackdropTemplate")
    if not ok or not plate then return nil end
    pcall(plate.SetAllPoints, plate, host)
    local level = (type(host.GetFrameLevel) == "function" and host:GetFrameLevel() or 1) - 1
    pcall(plate.SetFrameLevel, plate, math.max(0, level))
    pcall(plate.EnableMouse, plate, false)
    opts = opts or {}
    opts.thickness = opts.thickness or 1
    Widget:Theme(plate, opts)
    return plate
end

--- 悬停才出现的平板：平时 `Hide()`，鼠标进来才 `Show()`。
--- **不走 HookScript**（那会往暴雪按钮的脚本槽里写我们的函数、把整个按钮标脏），
--- 走 `Widget:HoverWatch` 轮询 —— 和 `Skin:HoverHighlight` 同一条路。
local function HoverPlate(host, alpha)
    if not host then return nil end
    local plate = Marked(host, "cfPlate")
    if plate then return plate end
    plate = NewPlate(host, { bgAlpha = alpha or 0.45, bgSurface = "hover", borderAlpha = 0 })
    if not plate then return nil end
    Mark(host, "cfPlate", plate)
    plate:Hide()
    Widget:HoverWatch(host, function() plate:Show() end, function() plate:Hide() end)
    return plate
end

--- 遍历子树里**整宽**的 Button（宽度 ≥ 根宽度的 90%，高度在 [minH, maxH] 之间）。
--- 深度上限 5：名册行是 `Button <- Frame(内容) <- Frame(滚动区) <- Frame <- MemberList` 四层。
local function EachWideButton(root, depth, minH, maxH, fn)
    if not root or depth > 5 then return 0 end
    local w0 = ShapeOf(root)
    local floor = (w0 or 0) * 0.9
    local n = 0
    for _, child in ipairs(ChildrenOf(root)) do
        if IsButton(child) then
            local w, h = ShapeOf(child)
            if w and h and w >= floor and h >= minH and h <= maxH then
                fn(child)
                n = n + 1
            end
        else
            n = n + EachWideButton(child, depth + 1, minH, maxH, fn)
        end
    end
    return n
end

--- ScrollBox 的自绘滚动条：无名 Frame + 8px 把手 + 两个 17×11 步进钮，
--- 没有 `ScrollUpButton` 这类字段 ⇒ 按形状认（窄而高 = 把手，矮而窄 = 步进钮）。
--- 步进钮只认 atlas（`Skin:ScrollArrowButton` 认得出来才动它）—— 认不出来就保持暴雪原样，
--- 压掉图却不补 V 形就是"箭头不见了"。
--- 11-13 实测结构是 **三段**：`8x290 轨 → 8x252 槽 → 8x59 把手 Button`（Club 那条同构），
--- 把手不在轨的直接子件里 ⇒ 必须递归。深度 3 是"轨 → 槽 → 把手"正好落地的一层。
local function SkinScrollRail(root)
    local function walk(node, d)
        if d > 3 then return end
        for _, kid in ipairs(ChildrenOf(node)) do
            if IsButton(kid) then
                local w, h = ShapeOf(kid)
                if w and h then
                    if w <= 16 and h >= 24 then
                        pcall(Skin.ScrollThumb, Skin, kid)
                    elseif h <= 14 and w <= 24 then
                        pcall(Skin.ScrollArrowButton, Skin, kid)
                    end
                end
            else
                walk(kid, d + 1)
            end
        end
    end
    walk(root, 1)
end

--- 把一个字段（可能是 Frame，也可能**本身就是 Texture**：`TopFiligree` 就是）里的贴图逐张压掉，
--- 需要时向子件递归。只写 Texture regions，**绝不碰子件以外的东西** —— 这些字段里有的是装饰边框
--- （`FilligreeOverlay` 8 张：4 个 64×64 角 + 2 条 43×247 竖边 + 2 个 34×43），
--- 有的是整窗覆盖层（`PortraitOverlay` 里有 4 张 60×60 徽记）。
local function FadeTreeArt(host, depth)
    if not host then return 0 end
    local n = 0
    if KindOf(host) == "Texture" then
        -- `FadeHold` 而不是 `Fade`：这几件都是**整窗覆盖层**，暴雪每趟刷新会把 α 抬回来
        -- （`PortraitOverlay` 第 4 张 64×64 徽记就是 `hidden=true` 却 α=1.00），
        -- 而 `Fade` 见到标记就早退、永远纠不回来。
        Skin:FadeHold(host)
        return 1
    end
    depth = depth or 0
    if depth > 3 then return 0 end
    for _, reg in ipairs(RegionsOf(host)) do
        if KindOf(reg) == "Texture" and not Marked(reg, "cfRule") then
            Skin:FadeHold(reg)
            n = n + 1
        end
    end
    for _, kid in ipairs(ChildrenOf(host)) do
        n = n + FadeTreeArt(kid, depth + 1)
    end
    return n
end

-- --- 名册页 -------------------------------------------------------------

--- 名册行（592×20 的 Button）：压掉整宽的 ARTWORK 底图与 HIGHLIGHT（暴雪鼠标高亮），
--- 悬停反馈换成我们自己的平板。16×16 职业图标与名字由 `FadeWideArt` 的宽度判据保住。
--- 选中行目前**没有**可靠判据（暴雪把"选中/离线/交替"都画在同一张 ARTWORK 上、α 全是 1），
--- 待实机量过贴图 fileID 再补；此刻选中信息仍由右侧成员详情接住。
local function SkinRosterRow(row)
    if Marked(row, "cfRow") then return end
    Mark(row, "cfRow", true)
    FadeWideArt(row)
    HoverPlate(row, 0.45)
end

--- 表头：6 个排序按钮的列底（(宽-9)×24 的 BACKGROUND）与高亮都压掉，只留文字，
--- 再在按钮下沿拉一条发丝线（分栏靠线，不靠色块）。
local function SkinRosterHeader(header)
    if Marked(header, "cfHeader") then return end
    Mark(header, "cfHeader", true)
    -- 表头**自己**那层大图：617×60 的列底 + `_UI-Frame-TopTileStreaks` 43 高 + 一圈
    -- `UI-Frame-Inner*` 3px 内框（3×309 那条靠高度判）。不压掉它，分栏线画在一条羊皮纸带上。
    for _, reg in ipairs(RegionsOf(header)) do
        if KindOf(reg) == "Texture" and not Marked(reg, "cfRule") then
            local w, h = ShapeOf(reg)
            if w and h and (w >= 200 or h >= 100) then Skin:Fade(reg) end
        end
    end
    local cells = {}
    for _, child in ipairs(ChildrenOf(header)) do
        if IsButton(child) then
            local w, h = ShapeOf(child)
            if w and h and h <= 30 and w >= 20 then
                FadeWideArt(child)
                cells[#cells + 1] = child
            end
        end
    end
    if #cells == 0 then return end
    local left, right = cells[1], cells[#cells]
    local tex = header:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet_hairline"])
    tex:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, -1)
    tex:SetPoint("TOPRIGHT", right, "BOTTOMRIGHT", 0, -1)
    tex:SetHeight(Media:SnapUnit(1))
    local r, g, b = Color:GetEdge()
    tex:SetVertexColor(r, g, b, 0.55)
    Mark(header, "cfRule", tex)
end

--- 表头那一行是 `MemberList` 里**唯一**挂着 ≥3 个矮按钮的 Frame（617×60）。
local function FindHeaderRow(list)
    for _, child in ipairs(ChildrenOf(list)) do
        if KindOf(child) == "Frame" then
            local count = 0
            for _, kid in ipairs(ChildrenOf(child)) do
                if IsButton(kid) then
                    local w, h = ShapeOf(kid)
                    if w and h and h <= 30 and w >= 20 then count = count + 1 end
                end
            end
            if count >= 3 then return child end
        end
    end
    return nil
end

--- 勾选框的勾：暴雪那张 checked 贴图是 32×32、铺满整格 32px 的框，和 12px 的标签并排读起来
--- 就是"一块色斑"。缩到框的 62% 居中；图本身仍由 `Skin:CheckButton` 换成 `monet_check`。
--- 幂等（`cfCheckFit` 标记），所以每趟调用只是一次表查询。
local function FitCheckMark(check)
    local ok, tex = pcall(function() return check.GetCheckedTexture and check:GetCheckedTexture() end)
    if not ok or not tex then return end
    if Marked(tex, "cfCheckFit") then return end
    Mark(tex, "cfCheckFit", true)
    local w = ShapeOf(check) or 24
    local size = math.max(8, math.floor(w * 0.62))
    pcall(tex.ClearAllPoints, tex)
    pcall(tex.SetPoint, tex, "CENTER", check, "CENTER", 0, 0)
    pcall(tex.SetSize, tex, size, size)
end

local function SkinRoster(frame)
    local list = Field(frame, "MemberList")
    if not list or not Skin:IsScriptObject(list) then return end

    -- ⚠ 结构件（表头 / 勾选框 / 滚动轨 / 行）**只在窗口第一次显示、且停在这一页时**才存在：
    -- 登录那一趟 Apply 里 `MemberList` 还是空的。所以「一次性标记」只能盖住**静态美术**
    -- （列表外框那几张大贴图），结构件每一趟都要重新找 —— 找到才留引用，找不到下一趟再来。
    if not Marked(list, "cfArt") then
        Mark(list, "cfArt", true)
        for _, child in ipairs(ChildrenOf(list)) do
            for _, reg in ipairs(RegionsOf(child)) do
                local w, h = ShapeOf(reg)
                if KindOf(reg) == "Texture" and w and h and w >= 200 and h >= 100 then Skin:Fade(reg) end
            end
        end
    end

    SkinScrollRail(list)

    local header = Marked(list, "cfHeaderRef") or FindHeaderRow(list)
    if header then
        Mark(list, "cfHeaderRef", header)
        SkinRosterHeader(header)
    end
    if not Marked(list, "cfCheck") then
        for _, child in ipairs(ChildrenOf(list)) do
            if KindOf(child) == "CheckButton" and type(child.GetChecked) == "function" then
                Mark(list, "cfCheck", true)
                pcall(Skin.CheckButton, Skin, child)
                FitCheckMark(child)
            end
        end
    end

    EachWideButton(list, 0, 0, 26, SkinRosterRow)
end

-- --- 左栏俱乐部列表 -----------------------------------------------------

--- 俱乐部条目（171×68）：压掉整宽的底图三层（normal / pressed / 悬停高亮），
--- 公会旗、徽记、加号图标全部留下。
--- 选中标志：暴雪选中的那一条会把 `communities-nav-button-green-pressed` 挂回同一张 region
--- （只动 atlas、α 一直是 1）⇒ 我们压掉它的显示，另画一条左缘竖线，按"那张图上还有没有 atlas"
--- 判断当前条目是不是选中项。
local function SkinClubEntry(entry)
    if Marked(entry, "cfEntry") then return end
    Mark(entry, "cfEntry", true)
    FadeWideArt(entry)
    HoverPlate(entry, 0.4)

    local sel
    for _, reg in ipairs(RegionsOf(entry)) do
        if KindOf(reg) == "Texture" and type(reg.GetAtlas) == "function" then
            local ok, atlas = pcall(reg.GetAtlas, reg)
            if ok and type(atlas) == "string" and atlas:find("pressed", 1, true) then sel = reg break end
        end
    end
    if sel then Mark(entry, "cfSel", sel) end

    local accent = entry:CreateTexture(nil, "OVERLAY")
    accent:SetTexture(Media.texture.blank)
    accent:SetPoint("TOPLEFT", entry, "TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", entry, "BOTTOMLEFT", 0, 0)
    accent:SetWidth(Media:SnapUnit(3))
    local r, g, b = Color:GetPrimary()
    accent:SetVertexColor(r, g, b, 0.9)
    accent:Hide()
    Mark(entry, "cfAccent", accent)
end

local function TouchClubEntry(entry)
    SkinClubEntry(entry)
    local accent, sel = Marked(entry, "cfAccent"), Marked(entry, "cfSel")
    if not accent or not sel then return end
    local on = false
    local ok, atlas = pcall(sel.GetAtlas, sel)
    if ok and type(atlas) == "string" and atlas ~= "" then on = true end
    accent:SetShown(on)
end

--- 左栏那几个装饰字段（羊皮纸花边）：`TopFiligree` / `BottomFiligree` **本身就是 Texture**，
--- `InsetFrame` 里的子件是 3px 内框线，`FilligreeOverlay` 是 4 个 64×64 角 + 2 条 43×247 竖边。
--- 它们都不是条目容器（条目在 `CommunitiesList` 的第 1 个子件里），整棵压掉是安全的。
local CLUB_ART_FIELDS = { "TopFiligree", "BottomFiligree", "FilligreeOverlay", "InsetFrame" }

local function SkinClubList(frame)
    local rail = Field(frame, "CommunitiesList")
    if not rail or not Skin:IsScriptObject(rail) then return end

    if not Marked(rail, "cfArt") then
        Mark(rail, "cfArt", true)
        -- 左栏底图（166×373 / 168×378 的暴雪羊皮纸）与 rail 自己的三张整栏贴图：压掉。
        local hosts = { rail }
        for _, child in ipairs(ChildrenOf(rail)) do hosts[#hosts + 1] = child end
        for _, host in ipairs(hosts) do
            for _, reg in ipairs(RegionsOf(host)) do
                local w, h = ShapeOf(reg)
                if KindOf(reg) == "Texture" and w and h and w >= 100 and h >= 100 then Skin:Fade(reg) end
            end
        end
    end

    -- 花边字段每趟复检（暴雪切页会把这些框重新 `Show` 并抬回 α1；`Skin:Fade` 幂等）。
    for _, key in ipairs(CLUB_ART_FIELDS) do
        FadeTreeArt(Field(rail, key), 1)
    end

    -- 滚动轨与条目同理：只在窗口显示后才建出来，每趟重找（两个 helper 自己带幂等标记）。
    SkinScrollRail(rail)
    EachWideButton(rail, 0, 40, 96, TouchClubEntry)
end

-- --- 右侧图标页签 -------------------------------------------------------

--- 图标页签（32×32 CheckButton，Roster / Chat / 公会信息 / 福利 / 出团设置）：
--- 暴雪底板是一张 **64×64** 的 BORDER 贴图（比按钮大一圈），图标是 30×30 的 ARTWORK
--- ⇒ 底板与 32×32 的选中标志压掉，图标留着；选中态由我们自己的一圈 1px 边表达（方向无关）。
local COMMUNITY_TABS = {
    "RosterTab", "ChatTab", "GuildInfoTab", "GuildBenefitsTab", "GuildPreferredPlaySettingsTab",
}

local function SkinIconTab(tab)
    if not tab or Marked(tab, "cfTab") or not Skin:IsScriptObject(tab) then return end
    Mark(tab, "cfTab", true)

    local icon
    for _, reg in ipairs(RegionsOf(tab)) do
        if KindOf(reg) == "Texture" then
            local w = ShapeOf(reg)
            if w then
                if w >= 48 then
                    Skin:Fade(reg)                      -- 64×64 暴雪页签底板
                elseif w >= 31 and w <= 40 then
                    Skin:Fade(reg)                      -- 32×32 选中标志 / 高光
                elseif w >= 24 and w <= 30 and not icon then
                    local ok, tex = pcall(function() return reg.GetTexture and reg:GetTexture() end)
                    if ok and tex ~= nil then icon = reg end
                end
            end
        end
    end
    if icon then Mark(tab, "cfIcon", icon) end
    local ring = NewPlate(tab, { bgAlpha = 0, borderAlpha = 0 })
    if ring then Mark(tab, "cfRing", ring) end
end

local function SyncIconTabs(frame)
    for _, key in ipairs(COMMUNITY_TABS) do
        local tab = Field(frame, key)
        if tab and Skin:IsScriptObject(tab) then
            SkinIconTab(tab)
            local ring, icon = Marked(tab, "cfRing"), Marked(tab, "cfIcon")
            local checked = false
            if type(tab.GetChecked) == "function" then
                local ok, v = pcall(tab.GetChecked, tab)
                checked = (ok and v) and true or false
            end
            if icon then pcall(icon.SetAlpha, icon, checked and 1 or 0.55) end
            if ring and type(ring.SetBackdropBorderColor) == "function" then
                local r, g, b = Color:GetHighlight()
                pcall(ring.SetBackdropBorderColor, ring, r, g, b, checked and 0.95 or 0)
            end
        end
    end
end

-- --- 动作钮与筛选下拉 ---------------------------------------------------

--- 窗口自带的文字钮与三个筛选下拉。图标钮（`AddToChatButton` / `CommunitiesCalendarButton`）
--- 不在这里：它们的"这是干什么"全靠那张 30×30 图标，走通用档有把图标压成 α0 的风险，
--- 等实机确认 region 结构再决定。
local COMMUNITY_CONTROLS = {
    "InviteButton", "GuildLogButton",
    "CommunitiesListDropdown", "CommunityMemberListDropdown", "GuildMemberListDropdown",
}

local function SkinCommunityControls(frame)
    for _, key in ipairs(COMMUNITY_CONTROLS) do
        local obj = Field(frame, key)
        if obj and not Marked(obj, "cfControl") and Skin:IsScriptObject(obj) then
            Mark(obj, "cfControl", true)
            pcall(Skin.Button, Skin, obj, { size = 12 })
        end
    end
end

--- 窗口本体的装饰件：`CommunitiesFrame:GetRegions()` 返回 **0 张**，但**字段**能拿到整窗那一层。
--- `PortraitOverlay`（814×426）里挂着 4 张 60×60 徽记 —— 截图里那几团最显眼的残留就是它；
--- `PortraitContainer`（1×1 的宿主框）里挂着一张 62×62 的公会徽记 —— 左上角那团；
--- 两者的区别只在宿主尺寸，**画出来的都是肖像**，按作者既定口径（肖像一律隐藏）一起压掉。
--- `TitleContainer` / `CommunitiesControlFrame` 目前没有可见贴图，留着每趟复检（花不了什么）。
--- ⚠ 这几件都是**整窗**覆盖层，里面没有功能图标（页签、按钮、列表都是别的子件）⇒ 整棵压掉。
local COMMUNITY_WINDOW_ART = { "PortraitOverlay", "PortraitContainer", "TitleContainer", "CommunitiesControlFrame" }

local function SkinWindowArt(frame)
    for _, key in ipairs(COMMUNITY_WINDOW_ART) do
        FadeTreeArt(Field(frame, key), 1)
    end
end

--- 一整趟内部补扫：首次应用与轮询共用**同一个**稳定函数
--- （`Widget:PollWatch` 按函数身份去重，在 Apply 里现造闭包会每触发一次多挂一条）。
local function CommunitiesBodyPass()
    local frame = _G.CommunitiesFrame
    if not frame or not Skin:IsScriptObject(frame) then return end
    if not Widget:Readable(frame) then return end

    SkinWindowArt(frame)
    SkinRoster(frame)
    SkinClubList(frame)
    SyncIconTabs(frame)
    SkinCommunityControls(frame)

    -- 暴雪切页 / 刷新会把压过的贴图 alpha 抬回来（§8.107 判例）⇒ 每趟写回一次 α0。
    -- 只对两个内容区递归：窗口本体那一层的 `GetChildren()` 是空的，够不到里面。
    local list = Field(frame, "MemberList")
    if list then Skin:ReassertHidden(list, 0) end
    local rail = Field(frame, "CommunitiesList")
    if rail then Skin:ReassertHidden(rail, 0) end
end

local function SkinCommunities()
    -- **窗口本体不开 `deep`**：这一层 `GetChildren()` 返回空表（见上面那段注释），
    -- 那一趟轮询一次真控件都碰不到。内部件由 `CommunitiesBodyPass` 按结构接管。
    M:Dress("CommunitiesFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 },
    })
    M:Dress(COMMUNITIES_DIALOGS, {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true,
    })

    CommunitiesBodyPass()

    local frame = _G.CommunitiesFrame
    if frame and not Marked(frame, "cfPoll") then
        Mark(frame, "cfPoll", true)
        -- 1 秒一趟：行与条目是 ScrollBox 回收复用的，翻页 / 换公会 / 滚动时才需要补。
        Widget:PollWatch(frame, CommunitiesBodyPass, 1)
    end
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

-- 2026-11-11 转储定案（§8.100 P0-2，framexml-source 1.60.1.70707 零命中）：
-- `ChatChannelManagerPopup` / `EditChannelPopup` 及三颗 `ChatChannelManagerPopup*Button`
-- 在 1.60 不存在（频道 UI 真身是 `ChannelFrame` + `CreateChannelPopup`，已在
-- CHAT_EXTRA_WINDOWS / 本表）。死名整组摘掉，只留真存在的 CreateChannelPopup。
local CHAT_CHANNEL_POPUPS = { "CreateChannelPopup" }

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
--- §8.96 输入框空闲渐隐（`chatEditBoxMode == "fade"` 档）。参考实现（千问给的 ChatEditFade.lua）
--- 的四个时长直接沿用，但**驱动方式全部换掉**：它的 `UIFade` 在本客户端是 nil（只有 `UIFrameFade`），
--- 且它用 `eb:SetScript("OnEditFocus…")` 抢焦点脚本 —— 实测这些脚本槽**已全部被暴雪占用**
--- （`GetScript` 均返回非 nil），直接 SetScript 会顶掉暴雪自己的焦点/更新逻辑。这里改为：
--- 私有 OnUpdate 插值帧 + 每 0.2 秒节流查 `HasFocus`，一个脚本也不占、零 taint。
local CHAT_EDIT_IDLE_ALPHA  = 0.25   -- 空闲透明度
local CHAT_EDIT_FADE_OUT    = 0.35   -- 淡出时长（秒）
local CHAT_EDIT_FADE_IN     = 0.20   -- 淡入时长（秒）
local CHAT_EDIT_IDLE_DELAY  = 3.0    -- 失焦后多久开始渐隐（秒）
local CHAT_EDIT_POLL_STEP   = 0.2    -- 焦点态判定节流间隔（秒）
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
--- §8.96 输入框渐隐状态：name → { cur, target, idleSince, pollAt }
--- `cur` 是我们认定的当前 alpha（不每帧回读，避免暴雪写入时来回抖）；`idleSince` 是失焦时刻。
local EDIT_FADE = {}
local EDIT_FADE_FRAME            -- 私有 OnUpdate 帧，仅在存在 fade 档时创建

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
    -- §8.96：`fade` 档的 alpha 归渐隐引擎（`EditFadeStep`）管，这里拉回 1 会把它每拍抹平、永远渐不隐。
    local okS, shown = pcall(eb.IsShown, eb)
    if okS and shown and self:EditBoxMode() ~= "fade" then
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
---
--- **2026-11-11 订正（记录仪实锤 + 代码分析）**：上面"页签（GDM+1）压得住输入框"是错的 ——
--- 页签的 +1 是 GDM **子树内部**的层级；命中裁决时 GDM 子树整体拿 GDM 自己的 level（L1）
--- 去和直接挂 UIParent 的输入框（L1）比，**平局**，平局裁决按建框先后（输入框晚建 ⇒ 赢）。
--- 0.13.4 的 hide 档输入框空闲时整个藏着、不参与裁决，所以从没暴露；§8.96 fade 档是第一个
--- "常显 + 未聚焦"的档 ⇒ 点页签全落在输入框上（页签 OnClick 不触发、焦点翻到 eb，记录仪逐帧可见）。
--- 因此层级从两态扩成三态：聚焦 = GDM+BOOST（抬到页签之上，原设计）；
--- **常显未聚焦 = GDM−1（压到页签子树之下，点击归页签）**；隐藏 = 还原原始层级。
function ChatBand:SyncInputLayer(name, shownOverride)
    local eb = Skin:Need(name .. "EditBox")
    if not eb or type(eb.SetFrameLevel) ~= "function" then return end

    -- 原始层级在**第一次见到**时就记（不是第一次聚焦）：fade / show 档可能永远不聚焦，
    -- 没记就无从还原。
    local rec = INPUT_LAYER[name]
    if not rec then
        local okE, el = pcall(eb.GetFrameLevel, eb)
        rec = { eb = (okE and type(el) == "number") and el or nil, cb = nil }
        local cb = Marked(eb, "controlBg")
        if cb and type(cb.GetFrameLevel) == "function" then
            local okC, cl = pcall(cb.GetFrameLevel, cb)
            rec.cb = (okC and type(cl) == "number") and cl or nil
        end
        INPUT_LAYER[name] = rec
    end

    local gdm = Skin:Need("GeneralDockManager")
    local gl = 1
    if gdm then
        local okG, g = pcall(gdm.GetFrameLevel, gdm)
        if okG and type(g) == "number" then gl = g end
    end

    local okF, focused = pcall(eb.HasFocus, eb)
    local okS, shown = pcall(eb.IsShown, eb)
    -- shownOverride：HideEditBox 在 SetShown **之前**调本函数（先抬层再显示，防闪），
    -- 那一刻 IsShown 还是旧值，得用"打算变成"的显隐态来判。
    -- **不能写 `and/or` 短路**：override 为 false 时 `false or ...` 会落回读实际值，
    -- "还原"分支被吞成"压档"（Lua 短路惯用法不吃 false，2026-11-11 自查抓到）。
    local isShown
    if shownOverride ~= nil then
        isShown = shownOverride
    else
        isShown = okS and shown == true
    end
    local want
    if okF and focused == true then
        want = gl + CHAT_INPUT_BOOST            -- 聚焦：抬到页签之上（§8.92 原设计）
    elseif isShown then
        want = math.max(0, gl - 1)              -- 常显未聚焦：压到页签子树之下，点击归页签
    else
        want = rec.eb or 1                      -- 隐藏（hide 档空闲）：还原原始层级
    end
    pcall(eb.SetFrameLevel, eb, want)

    local cb = Marked(eb, "controlBg")
    if cb and type(cb.SetFrameLevel) == "function" then
        -- 抬 / 压两态背板跟着走（eb−1，不低于 0）；还原态回到背板自己的原始层级。
        local cbWant = ((okF and focused == true) or isShown) and math.max(0, want - 1) or rec.cb
        if cbWant then pcall(cb.SetFrameLevel, cb, cbWant) end
    end
    self:SyncEditMouse(name)   -- 聚焦边沿：立刻能吃点击
end

--- §8.91 输入框隐藏档：平时 `SetShown(false)` 折叠输入框带；当用户聚焦输入框（按 Enter / 点击聊天框进入输入态）
--- 暴雪会自动 Show 并聚焦，这里按焦点态保持显示，失焦后下一拍 PollWatch 重新隐藏。`HasFocus` 是 EditBox 标准方法，
--- 非保护框操作无 taint 风险；全程 pcall 兜住运行期异常。
function ChatBand:HideEditBox(name)
    -- §8.96：`fade` 档靠 alpha 表达，不用显隐；两条路都写会闪（先藏后露一帧）。
    if self:EditBoxMode() == "fade" then
        self:HoldEditBox(name)
        return
    end
    local eb = Skin:Need(name .. "EditBox")
    if not eb then return end
    local okF, focused = pcall(eb.HasFocus, eb)
    local show = okF and focused
    -- 先抬层再显示：否则这一拍 EditBox 会先以原 level 露出来、被同区的页签压住闪一下。
    -- shownOverride 传目标显隐态：此刻 IsShown 还是旧值（见 SyncInputLayer 注）。
    self:SyncInputLayer(name, show)
    pcall(eb.SetShown, eb, show)
    -- §8.91 修正：controlBg 背板（输入框背景色 / 频道色，见 §8.90）必须同步显隐，
    -- 否则 EditBox 藏了、背景色还挂在那（用户反馈"输入框背景色一直在"）。
    local okM, cb = pcall(Marked, eb, "controlBg")
    if okM and cb and type(cb.SetShown) == "function" then
        pcall(cb.SetShown, cb, show)
    end
end

--- §8.96 渐隐档的"保持显示"：`fade` 模式下输入框**始终 shown**，只靠 alpha 表达空闲/聚焦。
--- 必须与 `HideEditBox` 的 SetShown 二值路径互斥——两条路都写显隐会闪（先藏后露一帧）。
function ChatBand:HoldEditBox(name)
    local eb = Skin:Need(name .. "EditBox")
    if not eb then return end
    local okS, shown = pcall(eb.IsShown, eb)
    if okS and not shown then pcall(eb.SetShown, eb, true) end

    local st = EDIT_FADE[name]
    if not st then
        local okA, a = pcall(eb.GetAlpha, eb)
        local cur = (okA and type(a) == "number") and a or 1
        st = { cur = cur, from = cur, target = cur, idleSince = nil, pollAt = 0 }
        EDIT_FADE[name] = st
    end
    self:EnsureEditFadeFrame()
end

--- 退出渐隐档（切到 hide / show）时把 alpha 复位成 1 并清状态，
--- 否则残留的 0.25 会跟着输入框进到别的档位（`show` 档本该常亮）。
function ChatBand:ReleaseEditFade(name)
    if not EDIT_FADE[name] then return end
    EDIT_FADE[name] = nil
    self:SetEditAlpha(name, 1)
    self:SyncEditMouse(name)
end

--- 输入框鼠标仲裁（2026-11-11 二次修复，三档通用）。
--- 一次修复（关鼠标 + AnyHover 开回来）实机不够：悬停是点击的前置，悬停即开鼠标等于没关。
--- 二次修复前的层级实验（输入框压到 L0、页签 L2）实机仍被抢 ⇒ **本客户端的点击裁决不看
--- level**（至少在这组框上），结合全部证据唯一自洽的是建框先后（输入框随 ChatFrame1 建，
--- 早于 GDM 子树，早建赢）。层级压档保留（绘制顺序上输入框本就该在页签下面），
--- 但点击让位只能走"退出仲裁"：**鼠标关掉的框不参与裁决**。
--- 规则：输入框显示着时，**鼠标在任何页签上 = 恒让位**（未聚焦让点击、聚焦也让——
--- 顺带修掉"打字时点页签被输入框抢"）；其余位置聚焦或悬停输入框自身时开
--- （保住"点输入框聚焦 / 点框内摆光标"）。hide 档空闲时整框藏着，天然安全。
function ChatBand:SyncEditMouse(name)
    local eb = Skin:Need(name .. "EditBox")
    if not eb or type(eb.EnableMouse) ~= "function" then return end
    local want = false
    local okS, shown = pcall(eb.IsShown, eb)
    if okS and shown == true then
        local overTab = false
        for _, cn in ipairs(CHAT_FRAMES) do
            local t = Skin:Need(cn .. "Tab")
            if t and not overTab then
                local okO, o = pcall(t.IsMouseOver, t)
                if okO and o == true then overTab = true end
            end
        end
        if not overTab then
            for cn in pairs(self.dynamic) do
                local t = Skin:Need(cn .. "Tab")
                if t and not overTab then
                    local okO, o = pcall(t.IsMouseOver, t)
                    if okO and o == true then overTab = true end
                end
            end
        end
        if not overTab then
            local okF, focused = pcall(eb.HasFocus, eb)
            local okO, overEb = pcall(eb.IsMouseOver, eb)
            want = (okF and focused == true) or (okO and overEb == true)
        end
    end
    local okM, was = pcall(eb.IsMouseEnabled, eb)
    if not okM or was ~= want then
        pcall(eb.EnableMouse, eb, want)
    end
end

--- 私有插值帧：一个 OnUpdate 推进所有输入框，不为每个 eb 各挂一个（10 窗 + 临时窗会散成十几个脚本）。
--- 焦点态每 `CHAT_EDIT_POLL_STEP` 秒才判一次；alpha 每帧推进，步长按"整段跨度在 fadeTime 秒内走完"算，
--- 所以 1→0.25 与 0.25→1 各自都在配置的时长内结束，而不是按绝对 1.0 尺度缩放。
local function EditFadeStep(_, dt)
    local now = 0
    if type(GetTime) == "function" then
        local ok, t = pcall(GetTime)
        if ok and type(t) == "number" then now = t end
    end
    local alive = false
    for name, st in pairs(EDIT_FADE) do
        local eb = Skin:Need(name .. "EditBox")
        local okS, shown = false, false
        if eb then okS, shown = pcall(eb.IsShown, eb) end
        if not (eb and okS and shown) then
            st.pollAt = 0          -- 窗口被藏起来：清掉节流，下次露面立刻重判
        else
            alive = true
            if now >= (st.pollAt or 0) then
                st.pollAt = now + CHAT_EDIT_POLL_STEP
                local okF, focused = pcall(eb.HasFocus, eb)
                focused = okF and focused == true
                if focused then
                    st.idleSince = nil
                    if st.target ~= 1 then st.from = st.cur; st.target = 1 end
                else
                    st.idleSince = st.idleSince or now
                    local want = (now - st.idleSince >= CHAT_EDIT_IDLE_DELAY) and CHAT_EDIT_IDLE_ALPHA or 1
                    if st.target ~= want then st.from = st.cur; st.target = want end
                end
                -- 焦点边沿同拍结算层级 + 鼠标：聚焦那一下必须立刻抬层、能吃点击（0.2s 节流够快）。
                -- SyncInputLayer 末尾自带 SyncEditMouse，不必再单独调。
                ChatBand:SyncInputLayer(name)
            end
            local cur, tgt = st.cur or 1, st.target or 1
            if math.abs(cur - tgt) > 0.004 then
                local dur = (tgt < cur) and CHAT_EDIT_FADE_OUT or CHAT_EDIT_FADE_IN
                local span = math.abs(tgt - (st.from or cur))
                local step = (dur > 0) and ((dt or 0) * math.max(span, 0.05) / dur) or 1
                if tgt > cur then cur = math.min(tgt, cur + step) else cur = math.max(tgt, cur - step) end
                st.cur = cur
                ChatBand:SetEditAlpha(name, cur)
            end
        end
    end
    if not alive then EDIT_FADE_FRAME:Hide() end
end

function ChatBand:EnsureEditFadeFrame()
    -- 桩环境（回归探针）没有 CreateFrame：不建帧，fade 档退化成"保持 shown、alpha 不动"，
    -- 静态断言与显隐断言都还能验，只是不会真的插值。
    if type(CreateFrame) ~= "function" then return end
    if EDIT_FADE_FRAME then
        if not EDIT_FADE_FRAME:IsShown() then EDIT_FADE_FRAME:Show() end
        return
    end
    local f = CreateFrame("Frame")
    f:Hide()
    f:SetScript("OnUpdate", EditFadeStep)
    EDIT_FADE_FRAME = f
    f:Show()
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
        -- §8.96 三档：fade 保持 shown + alpha 渐隐；其余档（show/hide）必须清掉渐隐状态，
        -- 否则残留的半透明会跟着输入框漂到别的档位。
        if self:EditBoxMode() == "fade" then
            self:HoldEditBox(name)
        else
            self:ReleaseEditFade(name)
        end
        self:SyncInputLayer(name)   -- 1s 轮询兜底：三态层级（聚焦抬 / 常显压 / 隐藏还原）+ 鼠标开关
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
    local mode = self:EditBoxMode()
    -- `hide` 档：输入框折在顶部输入带里（§8.93 起这条带已在框沿外侧），聚焦才露出。
    if mode == "hide" then return "hidden" end
    local p = self:Opt("chatEditBoxPos")
    return (p == "bottom") and "bottom" or "top"
end

--- §8.96 输入框平时状态三档：`hide` / `fade` / `show`。
--- 取代 §8.91 的布尔 `chatEditBoxAutoHide`（老 DB 只存布尔，没有新键时按旧值迁移：
--- 老值 true = 全隐 → `hide`，false = 常显 → `show`；两者都不是"渐隐"，不擅自替玩家改语义）。
function ChatBand:EditBoxMode()
    local m = self:Opt("chatEditBoxMode")
    if m == "hide" or m == "fade" or m == "show" then return m end
    -- 走到这里说明新键被清成非法值：退回 §8.91 的布尔语义（true = 全隐、false = 常显），
    -- 不擅自把"常显"的用户改成渐隐。
    if self:Opt("chatEditBoxAutoHide") == false then return "show" end
    return "hide"
end

--- §8.96 输入框 alpha 一次写两处：EditBox 本体 + 主题化背板 `controlBg`（§8.90 的频道色底板）。
--- 只写 eb 是本项目踩过的坑（§8.91「输入框的背景色一直在啊」）：背板是独立 frame，
--- 父框 alpha 不会顺着它走，两块必须同步，否则渐隐后会剩一块"半截底板"。
function ChatBand:SetEditAlpha(name, a)
    local eb = Skin:Need(name .. "EditBox")
    if not eb then return end
    local okA, cur = pcall(eb.GetAlpha, eb)
    if not (okA and type(cur) == "number" and math.abs(cur - a) < 0.004) then
        pcall(eb.SetAlpha, eb, a)
    end
    local okM, cb = pcall(Marked, eb, "controlBg")
    if okM and cb and type(cb.SetAlpha) == "function" then
        local okB, cba = pcall(cb.GetAlpha, cb)
        if not (okB and type(cba) == "number" and math.abs(cba - a) < 0.004) then
            pcall(cb.SetAlpha, cb, a)
        end
    end
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
        -- §8.106 KNOWN_EB 的键是基础名 `ChatFrameN`（TrackEditBox 传进来的），而这里拿到的是
        -- 输入框真名 `ChatFrameNEditBox`。以前直接 KNOWN_EB[nm] 恒 miss —— 这是双后缀 bug 的
        -- 另一半：就算把 TrackEditBox 的入参改对，钩子照样一次都不会重染。去掉后缀再认领。
        local base = (ok and type(nm) == "string") and (nm:match("^(.-)EditBox$") or nm) or nil
        if base and KNOWN_EB[base] then
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
    -- 悬停边沿同拍结算输入框鼠标开关（fade 档：离开聊天区就还给页签/世界）。
    for name in pairs(KNOWN_EB) do
        self:SyncEditMouse(name)
    end
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
    -- §8.106 这里必须传**基础名**（ChatFrameN）：TrackEditBox / PinEditBox / SyncEditMouse /
    -- ApplyChannelColorByName 一律在函数内部拼 `name .. "EditBox"`。以前传 CHAT_EDITS
    -- （已经是 ChatFrameNEditBox 全名），于是账本冒出 10 条 `ChatFrameNEditBoxEditBox` 死名、
    -- KNOWN_EB 存成错键、头部钩子按真名永远匹配不上 ⇒ §8.90「切频道即时重染」从没生效过。
    -- `CHAT_EDITS` 只供 M:Dress 与 frames 账本用（那两处要的确实是全名）。
    for _, name in ipairs(CHAT_FRAMES) do ChatBand:TrackEditBox(name) end

    -- 聊天窗"滚回底部"那枚箭头：暴雪逐帧重放它的 alpha 动画 ⇒ 压 α0 顶不住，只能换皮。
    for _, name in ipairs(CHAT_FRAMES) do
        local f = Skin:Need(name)
        if f and f.ScrollToBottomButton then
            Skin:ChatScrollAlert(f.ScrollToBottomButton)
        end
    end

    M:Dress(CHAT_CHANNEL_POPUPS, { window = true, inset = true, panel = { bgAlpha = 0.96 } })
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
        CHAT_CHANNEL_POPUPS,
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
