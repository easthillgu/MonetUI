-- Modules/Tools/Toast.lua
-- 通知横幅 (toast): 屏幕顶部一排主题化的提示，最多同时三列（正中 / 右 / 左），多的排队播完。
--
-- 自写实现，思路参考 Andromeda 的 Notification（GPL-3.0，代码不可复用）。和它的区别都跟本项目的
-- 像素规矩有关：只做 alpha 淡入淡出（缩放会把 1px 边框和像素字糊掉）；不做"宽度收缩"的花招，
-- 改成底边一条 1px 发丝线随时间排空；不用暴雪的 Interface\ICONS 图标和音频文件，左侧只用一条
-- 主题色竖条。
--
-- 消费者三个，都是本项目真的缺的：
--   * 新邮件  UPDATE_PENDING_MAIL + HasNewMail()（小地图邮件图标默认被 Minimap 藏掉了，见 Core hideMail）
--   * 背包满  BAG_UPDATE_DELAYED + C_Container.GetContainerNumFreeSlots，边沿触发
--   * 主色变色 MONETUI_THEME_CHANGED + **值级**比对（换区域 / 换主题时弹一条，写明新色值；见下面消费者段）
--
-- 事件驱动：没有通知在播时连 OnUpdate 都不挂；三列共用一份动画订阅，最后一列停下就摘掉。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local Math     = ns.Math
local EventBus = ns.EventBus
-- 下面 Fill / Tick / ColumnCount 里防机密值要用 Secrets.CanRead —— 必须在这里声明：`Secrets` 只是 ns.Secrets，
-- 没有全局同名对象；漏声明不会在加载期报错，只在第一条 toast 弹红字（AGENTS「静态闸门抓不到」那条）。
local Secrets  = ns.Secrets
local Scheduler = ns.Scheduler

local M = { name = "Toast" }
ns.Toast = M

local WIDTH      = 300    -- 横幅宽度
local HEIGHT     = 44
local PAD        = 10     -- 内边距
local ACCENT     = 2      -- 左侧主题色竖条宽度
local FADE_IN    = 0.15
local FADE_OUT   = 0.25
local TOP        = -64    -- 离屏幕上沿（信息栏在 0..14，往下让开）
local GAP        = 10     -- 列间距

-- 同时最多几列。位置**固定**、按"离中线由近到远"排：第一条永远在正中（和只有一条时一模一样），
-- 第二条往右、第三条往左。某一条播完或新来一条都不会把旁边那条推开 —— 按"当前条数居中"整组挪位的话，
-- 每次增减都瞬移一整列（310px），比多一条还难读。要 4 列就加一个偏移、MAX_COLUMNS 自动跟。
local COLUMN_X = { 0, WIDTH + GAP, -(WIDTH + GAP) }
local MAX_COLUMNS = #COLUMN_X

-- 每列一个面板：{ frame, accent, title, body, drain, icon, phase, t, holdFor, entry }
local panels = {}
local queue = {}          -- 列都占着时的待播：{ title=, text= }
local toastSubId = nil    -- 动画订阅只有一份：所有列共用同一拍，没列在动就摘掉

--- 通知总开关 + 各消费者开关的读取口。
function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.toast) ~= "table" then db.toast = {} end
    return db.toast
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.toast[key] end
    return value
end

--- 主题色：竖条与排空线用**高光槽**（奶白），不用边框槽 —— 边框本来就是边框色，
--- 同色又贴着边框画，肉眼完全分不出来。
local function Paint()
    local r, g, b = Color:GetHighlight()
    -- 标题回到主题色：战斗提醒会按进入/离开单独染色（见 Fill）。
    local er, eg, eb = Color:GetEdge()

    for i = 1, #panels do
        local p = panels[i]
        p.accent:SetColorTexture(r, g, b, 1)
        p.drain:SetColorTexture(r, g, b, 0.85)
        p.title:SetTextColor(er, eg, eb, 1)

        -- 正在播的、带 tint 的那条（战斗提醒的剑 / 盾）不能被主题重涂顶回全局色：重放它自己的着色。
        local e = p.entry
        if e and e.tint then
            local tr, tg, tb = e.tint[1], e.tint[2], e.tint[3]
            p.accent:SetColorTexture(tr, tg, tb, 1)
            p.drain:SetColorTexture(tr, tg, tb, 0.85)
            p.title:SetTextColor(tr, tg, tb, 1)
            if e.icon then p.icon:SetVertexColor(tr, tg, tb, 1) end
        end
    end
end

--- 把一条内容铺到面板上：文字、图标、着色、文字内缩。Fill（从头播）与 RetargetKind
--- （同族换内容）共用这一份，免得两条路径的着色/内缩慢慢走散。
local function Dress(p, entry)
    p.entry = entry
    local frame, title, body = p.frame, p.title, p.body
    title:SetText(entry.title or "")
    body:SetText(entry.text or "")

    -- 可选图标（战斗提醒的"形状"：剑 / 盾）。有图标就把文字右移，避免压住图形。
    local inset = ACCENT + PAD
    if entry.icon then
        p.icon:SetTexture(Media:Texture(entry.icon))
        p.icon:Show()
        inset = ACCENT + PAD + 26
    else
        p.icon:Hide()
    end
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -8)
    body:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, 9)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 9)

    -- 可选着色：左侧色条 / 标题 / 图标同色；没有 tint 就回主题色。
    if entry.tint then
        local r, g, b = entry.tint[1], entry.tint[2], entry.tint[3]
        p.accent:SetColorTexture(r, g, b, 1)
        p.drain:SetColorTexture(r, g, b, 0.85)
        title:SetTextColor(r, g, b, 1)
        if entry.icon then p.icon:SetVertexColor(r, g, b, 1) end
    else
        -- 没有 tint 就把图标的顶点色**复位**再交给 Paint()：tint 分支会写顶点色，
        -- 不复位的话下一条「带图标但不带 tint」的通知会沿用上一条的颜色（潜伏 bug：
        -- 目前只有战斗提醒带 tint，所以还没人被咬到）。
        if entry.icon then p.icon:SetVertexColor(1, 1, 1, 1) end
        Paint()
    end
end

--- 这条该停留多久：提醒类（战斗进出）用 entry.hold 覆盖，不跟普通通知的 duration 走。
--- 出厂默认只有一个真相：GetSetting 已经落到 `DEFAULTS.toast.duration`（Core.lua）。这里的
--- 字面量只防「DEFAULTS 自己缺键」这种改坏的情况，不再代表任何一档默认值。
local function HoldFor(entry)
    local d = tonumber(M:GetSetting("duration")) or 8
    return entry.hold or math.max(1, d)
end

--- 填满一列并开始播：面板自己的阶段计时，互不影响（三列可以同时在不同进度）。
local function Fill(p, entry)
    Dress(p, entry)

    local frame = p.frame
    frame:SetAlpha(0)
    -- 先读宽度并检查是否为机密值（防止 SetWidth 里的机密值拦截）
    local fw = frame:GetWidth() or WIDTH
    if not Secrets.CanRead(fw) then fw = WIDTH end
    p.drain:SetWidth(fw)
    frame:Show()

    p.holdFor = HoldFor(entry)
    p.phase, p.t = "in", 0
    if not toastSubId then toastSubId = Scheduler:EveryFrame(M.Tick, "提示条:动画") end
end

--- 同 kind 的旧条目只该留一条：排队里的删掉，正在播的那一列**就地换内容**（不重播淡入，
-- 否则每次换区域都闪一下）。返回 true = 已经替换到位，调用方不用再开一列。
-- 只有"排队里有同 kind、但没有任何一列在播"时返回 false（由调用方把新条目排进去）。
local function RetargetKind(entry)
    if not entry.kind then return false end

    for i = #queue, 1, -1 do
        if queue[i].kind == entry.kind then table.remove(queue, i) end
    end

    for i = 1, #panels do
        local p = panels[i]
        if p.phase and p.entry and p.entry.kind == entry.kind then
            Dress(p, entry)
            p.holdFor = HoldFor(entry)
            -- 正在淡入的接着淡入（不闪）；停留 / 淡出的重新计时、排空线拉满。
            if p.phase ~= "in" then
                p.phase, p.t = "hold", 0
                local fw = p.frame:GetWidth() or WIDTH
                if not Secrets.CanRead(fw) then fw = WIDTH end
                p.drain:SetWidth(fw)
                p.frame:SetAlpha(1)
            end
            return true
        end
    end
    return false
end

--- 空着的列（按 COLUMN_X 的次序：正中 → 右 → 左）。三列都占着就是 nil。
local function FreePanel()
    for i = 1, #panels do
        if not panels[i].phase then return panels[i] end
    end
    return nil
end

--- 有列空出来就按先来后到补位（同 kind 的旧条目在入队时已被替换，这里不再判）。
local function Dispatch()
    local p = FreePanel()
    while p and #queue > 0 do
        Fill(p, table.remove(queue, 1))
        p = FreePanel()
    end
end

--- 一列播完：收掉自己，然后立刻看看队列里有没有下一条（同一拍里就能开始淡入）。
local function Finish(p)
    p.entry = nil
    p.phase = nil
    p.frame:Hide()
    p.drain:SetWidth(0)
    Dispatch()
end

--- 动画步进：每列各自走"淡入 → 停留（排空线变短）→ 淡出"，走完从队列补位。
-- 三列共用这一拍（一个 Scheduler 订阅）；一列都不在动时把订阅摘掉，空闲期一帧都不跑。
function M.Tick(elapsed)
    local dt = elapsed or 0

    for i = 1, #panels do
        local p = panels[i]
        if p.phase then
            p.t = p.t + dt

            if p.phase == "in" then
                local a = p.t / FADE_IN
                if a >= 1 then
                    p.frame:SetAlpha(1)
                    p.phase, p.t = "hold", 0
                else
                    p.frame:SetAlpha(a)
                end
            elseif p.phase == "hold" then
                local progress = 1 - (p.t / p.holdFor)
                if progress <= 0 then
                    p.phase, p.t = "out", 0
                    p.drain:SetWidth(0)
                else
                    -- 同样在 Tick 防止机密值 SetWidth 失败
                    local fw = p.frame:GetWidth() or WIDTH
                    if not Secrets.CanRead(fw) then fw = WIDTH end
                    p.drain:SetWidth(fw * progress)
                end
            else -- out
                local a = 1 - (p.t / FADE_OUT)
                if a <= 0 then
                    Finish(p)
                else
                    p.frame:SetAlpha(a)
                end
            end
        end
    end

    -- 这一拍里可能刚补位（phase 又变成 "in"），所以按**现在的**状态判空闲，别用循环前那个快照。
    local animating = false
    for i = 1, #panels do
        if panels[i].phase then animating = true; break end
    end
    if not animating and toastSubId then
        Scheduler:Unregister(toastSubId)
        toastSubId = nil
    end
end

--- 对外入口。有空列就直接播（三列可以同时显示），三列都占着才压队列、播完自动接上。
--- 弹一条通知。opts 可带 icon / tint / hold / kind：
--   icon = Media 键 —— 进出战斗 monet_combat_sword / monet_combat_shield；
--          提示类 monet_info（无 tint → Paint 染主题高光奶白）；
--          告警类 monet_warning + tint = { Color:GetDanger() }（2026-11-16 全仓接图标口径）。
--   tint = { r, g, b }（色条、标题、图标同色）
--   hold = 停留秒数（覆盖全局 duration）
--   kind = 同族标记：同 kind 只留最新的一条 —— 正在播的那列就地换内容（不闪），排队的删掉。
--          换区域的色值属于这一类：连换三次区域只该看到最后那个颜色，不是三张过期卡片。
function M:Notify(head, text, opts)
    if not (self.active and panels[1]) then return end
    local entry = { title = head, text = text }
    if type(opts) == "table" then
        entry.icon = opts.icon
        entry.tint = opts.tint
        entry.hold = opts.hold
        entry.kind = opts.kind
    end

    if RetargetKind(entry) then return end

    -- 统一走「入队 + Dispatch」：有空列就**当场**填进去（同一个面板、同一拍开始淡入），
    -- 没有就排队，两者行为完全一样。以前这里另有一条"有空列且队列为空就直接 Fill"的
    -- 快路径，和 Dispatch 等价，只让人误以为「队列与空列可以并存」。
    queue[#queue + 1] = entry
    -- 队列不能无限长：掉线重连那种场景会一次涌进来一堆。
    while #queue > 8 do table.remove(queue, 1) end
    Dispatch()
end

--- 造一列：几何与以前那条完全一致，只是横向偏移按 COLUMN_X 固定。
local function NewPanel(index)
    local p = {}

    local frame = Widget:CreateFrame("MonetUIToast" .. index, _G.UIParent, WIDTH, HEIGHT)
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.92 })
    frame:SetFrameStrata("HIGH")
    frame:SetPoint("TOP", _G.UIParent, "TOP", COLUMN_X[index], TOP)
    frame:EnableMouse(true)
    frame:Hide()
    p.frame = frame

    -- 左侧主题色竖条：代替 Andromeda 的图标位，不需要任何贴图。
    p.accent = frame:CreateTexture(nil, "ARTWORK")
    p.accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    p.accent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    p.accent:SetWidth(ACCENT)

    -- 战斗提醒用的图标位（形状：剑 / 盾）。平时隐藏，只有带 icon 的通知才显示。
    p.icon = frame:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(22, 22)
    p.icon:SetPoint("LEFT", frame, "LEFT", ACCENT + PAD, 0)
    p.icon:Hide()

    p.title = Widget:Font(frame, 12, "pixel", "edge", "LEFT", nil, Media.outlineFlags)
    p.title:SetWordWrap(false)
    p.title:SetPoint("TOPLEFT", frame, "TOPLEFT", ACCENT + PAD, -8)
    p.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -8)
    p.title:SetHeight(13)

    p.body = Widget:Font(frame, 12, "pixel", "neutral", "LEFT", nil, Media.outlineFlags)
    p.body:SetWordWrap(false)
    p.body:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", ACCENT + PAD, 9)
    p.body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 9)
    p.body:SetHeight(13)

    -- 底边排空线：1px，随停留时间从左往右缩，读完就该消失了。
    p.drain = frame:CreateTexture(nil, "ARTWORK")
    p.drain:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    p.drain:SetHeight(Media:SnapUnit(1))
    p.drain:SetColorTexture(1, 1, 1, 1)

    -- 点击关闭（左键顺便收起，右键也一样；这一版没有可点的动作）。
    frame:SetScript("OnMouseUp", function()
        if p.phase == "hold" then p.phase, p.t = "out", 0 end
    end)

    return p
end

--- 屏幕上真放得下几列：n 列占 n*WIDTH + (n-1)*GAP（再留 40 的边）。小窗口 / 高缩放时
-- 三列会顶出屏幕，宁可少开一列也不要把最左最右那两条推到屏幕外。
-- UIParent 宽度读不出来（0 / 读不了）就按最大列数走 —— 这条只是防丑，不该把功能卡掉。
local function ColumnCount()
    local width = _G.UIParent and _G.UIParent:GetWidth()
    if not Secrets.CanRead(width) then return MAX_COLUMNS end
    if type(width) ~= "number" or width <= 0 then return MAX_COLUMNS end
    for n = MAX_COLUMNS, 1, -1 do
        if width >= n * WIDTH + (n - 1) * GAP + 40 then return n end
    end
    return 1
end

--- 建列（只建一次）。**列数在这里定死**：玩家长大窗口 / 改 UI 缩放后不会补列，缩小窗口
--- 也不会撤列（撤列要处理正在播的那条，得不偿失）。可接受的代价：改完缩放 `/reload` 一次。
local function Build()
    if panels[1] then return true end
    for i = 1, ColumnCount() do
        panels[i] = NewPanel(i)
    end
    Paint()
    return true
end

-- ============================================================================
-- 消费者
-- ============================================================================

--- 主色变色：换区域（引擎按地图配色）、手动换主题、关掉引擎配色回退内置表，都会走 RefreshTheme。
-- 判据是**值**不是事件：引擎的 OnThemeRefreshed 每趟重算都发（§8.125），回到去过的地图颜色
-- 一模一样 —— 按事件弹的话每过一个区域就刷一条，全是没变化的。下面按主色（primary 槽）逐通道比。
local lastPrimary          -- 上一次读过的主色；nil = 还没建立基线
local COLOR_EPS = 0.004    -- ≈1/255：低于它的差异色值抹平、肉眼也读不出

--- 读当前主色并与上一次比，顺手把基线推到当前值（**读得到**的时候）。
--- @return r, g, b, changed —— 机密 / 读不出来的值返回 nil（这一条就不发）。
--- 注意：读不出来时**基线保持不动**（不是"顺手推"）：那一拍我们根本没拿到值，
--- 拿它当"没变"会把下一次真实的变色吞掉，当"变了"则是凭空弹一条。
local function PrimaryDelta()
    local r, g, b = Color:GetPrimary()
    -- 颜色来自我们自己的库 profile，但受限窗口里任何值都可能被标成机密：宁可少发一条，
    -- 也不要在 math.abs 里撞上机密数字比较（会变成一条 ADDON_ACTION_BLOCKED）。
    -- 判据用 CanRead（"此刻能不能运算"）而不是 IsSecret（"是不是机密"）：后者不抛，
    -- 但非机密而当前读不了的值它也会放行。
    if not (Secrets.CanRead(r) and Secrets.CanRead(g) and Secrets.CanRead(b)) then return nil end
    r, g, b = r or 0, g or 0, b or 0

    local prev = lastPrimary
    lastPrimary = { r = r, g = g, b = b }
    if not prev then return r, g, b, false end   -- 首刷只建基线，不算"变色"

    local changed = math.abs(prev.r - r) > COLOR_EPS
        or math.abs(prev.g - g) > COLOR_EPS
        or math.abs(prev.b - b) > COLOR_EPS
    return r, g, b, changed
end

-- RefreshTheme 的 reason（Core.lua）：让玩家知道这条是换区域还是自己改的设置。
-- `config` 来自我们的设置面板（对比度 / 调色那几处都走 RefreshTheme("config")），
-- `manual` 才是 `/mui theme` 命令 —— 两个都算"玩家自己动的手"，但一个在面板里、一个在命令行。
local THEME_REASON = {
    login  = "登录",
    world  = "进世界",
    zone   = "换区域",
    monet  = "区域配色",
    config = "面板",
    manual = "手动",
}

local function ThemeNotice(reason)
    local r, g, b, changed = PrimaryDelta()
    if not changed then return end
    if not (M.active and M:GetSetting("themeColor")) then return end

    local text = "#" .. Math:RGBToHex(r, g, b)
    -- 区域名来自我们自己的数据表（不是客户端给的字符串）；照样判一次可读性 —— 它之后要进
    -- concat，机密串的 type() 仍然是 "string"（AGENTS 的判例），只判类型拦不住。
    -- 顺序：**先 CanRead 再做 `~= ""`**。以前是反的（先比较后判机密），等于没防 ——
    -- 现在 zone 来自我们自己的表所以不会真抛，但这行注释声称的守卫必须是真守卫。
    local _, zone = Color:GetZoneInfo()
    if Secrets.CanRead(zone) and type(zone) == "string" and zone ~= "" then
        text = text .. " · " .. zone
    end
    local why = THEME_REASON[reason]
    if why then text = text .. "（" .. why .. "）" end
    M:Notify("主色已更换", text, { hold = 4, kind = "themeColor", icon = "monet_info" })
end

--- 新邮件：小地图的邮件图标被 Minimap 默认藏掉了，这里补一条提示。
--- HasNewMail 在 1.60 手册里没有条目，用 _G 探测；拿不到就整条不发（不能凭事件瞎报）。
local lastMail
local function CheckMail()
    local has = _G.HasNewMail
    if type(has) ~= "function" then return end
    local ok, value = pcall(has)
    if not ok then return end
    value = value and true or false
    if value and lastMail ~= true then
        M:Notify("新邮件", "邮箱里有未读邮件", { icon = "monet_info" })
    end
    lastMail = value
end

--- 背包满：只在"由不满变满"那一次提示，腾出空间后重新武装。
local bagWarned = false
local function CheckBags()
    local api = _G.C_Container
    if not api or type(api.GetContainerNumFreeSlots) ~= "function" then return end

    local total = 0
    local first = _G.BACKPACK_CONTAINER or 0
    local last = _G.NUM_BAG_SLOTS or 4
    for i = first, last do
        local free, family = api.GetContainerNumFreeSlots(i)
        if family == 0 then total = total + (free or 0) end
    end

    if total == 0 and not bagWarned then
        bagWarned = true
        -- 告警族带 ⚠ 图标 + 危险红（与战斗横幅同一套 tint 机制，monet_warning 灰度模具）。
        M:Notify("背包已满", "所有背包格子都用完了", {
            icon = "monet_warning",
            tint = { Color:GetDanger() },
        })
    elseif total > 0 then
        bagWarned = false
    end
end

function M:Apply()
    Paint()
end

function M:Initialize()
    self.active = true
    if not Build() then return end

    -- 登录那一刷（RefreshTheme("login")）在 StartModules 之前，本模块还没订阅 —— 基线得在这里
    -- 自己建，否则本场第一次换区域会被当成"首刷"吞掉，玩家等半天等不到那条提示。
    PrimaryDelta()

    EventBus:Register("UPDATE_PENDING_MAIL", function()
        if M.active and M:GetSetting("mail") ~= false then CheckMail() end
    end)
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if M.active and M:GetSetting("mail") ~= false then CheckMail() end
    end)

    EventBus:Register("BAG_UPDATE_DELAYED", function()
        if M.active and M:GetSetting("bagFull") ~= false then CheckBags() end
    end)

    -- 进入 / 离开战斗提醒：原 Modules/CombatText 的 alert 唯一保留项（2026-11-02 并入）。
    -- 只留"形状 + 颜色 + 文字"，飘字动画与私有驱动帧一并删除。
    EventBus:Register("PLAYER_REGEN_DISABLED", function()
        if not (M.active and M:GetSetting("combatAlert") ~= false) then return end
        local text = _G.ENTERING_COMBAT
        if type(text) ~= "string" then text = "进入战斗" end
        M:Notify("进入战斗", text, {
            icon = "monet_combat_sword",
            tint = { Color:GetDanger() },
            hold = 1.6,
        })
    end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if not (M.active and M:GetSetting("combatAlert") ~= false) then return end
        local text = _G.LEAVING_COMBAT
        if type(text) ~= "string" then text = "离开战斗" end
        M:Notify("离开战斗", text, {
            icon = "monet_combat_shield",
            tint = { Color:GetHealth() },
            hold = 1.6,
        })
    end)

    -- 主题一换，竖条与排空线重涂（两个文字由 Widget 的颜色槽自己跟），
    -- 顺便在主色**真的变了**时弹一条（值级判定见 PrimaryDelta）。
    EventBus:Register("MONETUI_THEME_CHANGED", function(_, reason)
        if not M.active then return end
        Paint()
        ThemeNotice(reason)
    end)
end

function M:SetEnabled(value)
    self.active = value and true or false
    if not panels[1] then return end

    if not self.active then
        queue = {}
        for i = 1, #panels do
            local p = panels[i]
            p.entry, p.phase, p.t = nil, nil, 0
            p.frame:Hide()
        end
        if toastSubId then Scheduler:Unregister(toastSubId); toastSubId = nil end
    end
end

ns:Register("Toast", M)
