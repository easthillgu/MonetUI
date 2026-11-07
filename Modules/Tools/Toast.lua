-- Modules/Tools/Toast.lua
-- 通知横幅 (toast): 屏幕顶部一条主题化的提示，一次只显示一条，排队播完。
--
-- 自写实现，思路参考 Andromeda 的 Notification（GPL-3.0，代码不可复用）。和它的区别都跟本项目的
-- 像素规矩有关：只做 alpha 淡入淡出（缩放会把 1px 边框和像素字糊掉）；不做"宽度收缩"的花招，
-- 改成底边一条 1px 发丝线随时间排空；不用暴雪的 Interface\ICONS 图标和音频文件，左侧只用一条
-- 主题色竖条。
--
-- 消费者只有两个，都是本项目真的缺的：
--   * 新邮件  UPDATE_PENDING_MAIL + HasNewMail()（小地图邮件图标默认被 Minimap 藏掉了，见 Core hideMail）
--   * 背包满  BAG_UPDATE_DELAYED + C_Container.GetContainerNumFreeSlots，边沿触发
--
-- 事件驱动：没有通知时连 OnUpdate 都不挂，只有动画的 0.4 秒里才跑。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local EventBus = ns.EventBus
-- 下面 Fill / Tick 里防机密值要用 Secrets.IsSecret —— 必须在这里声明：`Secrets` 只是 ns.Secrets，
-- 没有全局同名对象；漏声明不会在加载期报错，只在第一条 toast 弹红字（AGENTS「静态闸门抓不到」那条）。
local Secrets  = ns.Secrets
local Scheduler = ns.Scheduler
local toastSubId = nil

local M = { name = "Toast" }
ns.Toast = M

local WIDTH      = 300    -- 横幅宽度
local HEIGHT     = 44
local PAD        = 10     -- 内边距
local ACCENT     = 2      -- 左侧主题色竖条宽度
local FADE_IN    = 0.15
local FADE_OUT   = 0.25
local TOP        = -64    -- 离屏幕上沿（信息栏在 0..14，往下让开）

local frame, accent, title, body, drain, icon
local queue = {}          -- 待播：{ title=, text= }
local showing             -- 正在播的那条
local phase, t            -- "in" / "hold" / "out" 与阶段内计时
local holdFor = 5         -- 当前这条的停留秒数（开播时缓存，别在 OnUpdate 里读库）

--- 通知总开关 + 两个消费者开关的读取口。
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
    if not frame then return end
    local r, g, b = Color:GetHighlight()
    accent:SetColorTexture(r, g, b, 1)
    drain:SetColorTexture(r, g, b, 0.85)
    -- 标题回到主题色：战斗提醒会按进入/离开单独染色（见 Fill）。
    local er, eg, eb = Color:GetEdge()
    title:SetTextColor(er, eg, eb, 1)
end

local function Fill(entry)
    showing = entry
    title:SetText(entry.title or "")
    body:SetText(entry.text or "")

    -- 可选图标（战斗提醒的"形状"：剑 / 盾）。有图标就把文字右移，避免压住图形。
    local inset = ACCENT + PAD
    if entry.icon then
        icon:SetTexture(Media:Texture(entry.icon))
        icon:Show()
        inset = ACCENT + PAD + 26
    else
        icon:Hide()
    end
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -8)
    body:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, 9)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 9)

    -- 可选着色：左侧色条 / 标题 / 图标同色；没有 tint 就回主题色。
    if entry.tint then
        local r, g, b = entry.tint[1], entry.tint[2], entry.tint[3]
        accent:SetColorTexture(r, g, b, 1)
        drain:SetColorTexture(r, g, b, 0.85)
        title:SetTextColor(r, g, b, 1)
        if entry.icon then icon:SetVertexColor(r, g, b, 1) end
    else
        Paint()
    end

    frame:SetAlpha(0)
    -- 先读宽度并检查是否为机密值（防止 SetWidth 里的机密值拦截）
    local fw = frame:GetWidth() or WIDTH
    if Secrets.IsSecret(fw) then fw = WIDTH end
    drain:SetWidth(fw)
    frame:Show()

    -- 提醒类（战斗进出）用 entry.hold 覆盖停留时间，不跟普通通知的 5 秒走。
    holdFor = entry.hold or math.max(1, tonumber(M:GetSetting("duration")) or 5)
    phase, t = "in", 0
    if not toastSubId then toastSubId = Scheduler:EveryFrame(M.Tick) end
end

local function Next()
    showing = nil
    frame:Hide()
    if toastSubId then Scheduler:Unregister(toastSubId); toastSubId = nil end
    if #queue > 0 then Fill(table.remove(queue, 1)) end
end

--- 动画步进：淡入 → 停留（排空线变短）→ 淡出 → 下一条。
function M.Tick(elapsed)
    t = t + (elapsed or 0)

    if phase == "in" then
        local a = t / FADE_IN
        if a >= 1 then
            frame:SetAlpha(1)
            phase, t = "hold", 0
        else
            frame:SetAlpha(a)
        end
    elseif phase == "hold" then
        local progress = 1 - (t / holdFor)
        if progress <= 0 then
            phase, t = "out", 0
            drain:SetWidth(0)
        else
            -- 同样在 Tick 防止机密值 SetWidth 失败
            local fw = frame:GetWidth() or WIDTH
            if Secrets.IsSecret(fw) then fw = WIDTH end
            drain:SetWidth(fw * progress)
        end
    else -- out
        local a = 1 - (t / FADE_OUT)
        if a <= 0 then
            Next()
        else
            frame:SetAlpha(a)
        end
    end
end

--- 对外入口。正在播 / 有排队时压队列，播完自动接上。
--- 弹一条通知（在窗口外 / 排队时自动压栈）。opts 可带 icon / tint / hold：
--   icon = Media 键（战斗提醒用 monet_combat_sword / monet_combat_shield）
--   tint = { r, g, b }（色条、标题、图标同色）
--   hold = 停留秒数（覆盖全局 duration）
function M:Notify(head, text, opts)
    if not (self.active and frame) then return end
    local entry = { title = head, text = text }
    if type(opts) == "table" then
        entry.icon = opts.icon
        entry.tint = opts.tint
        entry.hold = opts.hold
    end
    if showing then
        queue[#queue + 1] = entry
        -- 队列不能无限长：掉线重连那种场景会一次涌进来一堆。
        while #queue > 8 do table.remove(queue, 1) end
        return
    end
    Fill(entry)
end

local function Build()
    if frame then return true end

    frame = Widget:CreateFrame("MonetUIToast", _G.UIParent, WIDTH, HEIGHT)
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.92 })
    frame:SetFrameStrata("HIGH")
    frame:SetPoint("TOP", _G.UIParent, "TOP", 0, TOP)
    frame:EnableMouse(true)
    frame:Hide()

    -- 左侧主题色竖条：代替 Andromeda 的图标位，不需要任何贴图。
    accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    accent:SetWidth(ACCENT)

    -- 战斗提醒用的图标位（形状：剑 / 盾）。平时隐藏，只有带 icon 的通知才显示。
    icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", frame, "LEFT", ACCENT + PAD, 0)
    icon:Hide()

    title = Widget:Font(frame, 12, "pixel", "edge", "LEFT", nil, Media.outlineFlags)
    title:SetWordWrap(false)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", ACCENT + PAD, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -8)
    title:SetHeight(13)

    body = Widget:Font(frame, 12, "pixel", "neutral", "LEFT", nil, Media.outlineFlags)
    body:SetWordWrap(false)
    body:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", ACCENT + PAD, 9)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 9)
    body:SetHeight(13)

    -- 底边排空线：1px，随停留时间从左往右缩，读完就该消失了。
    drain = frame:CreateTexture(nil, "ARTWORK")
    drain:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    drain:SetHeight(Media:SnapUnit(1))
    drain:SetColorTexture(1, 1, 1, 1)

    -- 点击关闭（左键顺便收起，右键也一样；这一版没有可点的动作）。
    frame:SetScript("OnMouseUp", function()
        if phase == "hold" then phase, t = "out", 0 end
    end)

    Paint()
    return true
end

-- ============================================================================
-- 消费者
-- ============================================================================

--- 新邮件：小地图的邮件图标被 Minimap 默认藏掉了，这里补一条提示。
--- HasNewMail 在 1.60 手册里没有条目，用 _G 探测；拿不到就整条不发（不能凭事件瞎报）。
local lastMail
local function CheckMail()
    local has = _G.HasNewMail
    if type(has) ~= "function" then return end
    local ok, value = pcall(has)
    if not ok then return end
    value = value and true or false
    if value and lastMail ~= true then M:Notify("新邮件", "邮箱里有未读邮件") end
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
        M:Notify("背包已满", "所有背包格子都用完了")
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

    -- 主题一换，竖条与排空线重涂（两个文字由 Widget 的颜色槽自己跟）。
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if M.active then Paint() end
    end)
end

function M:SetEnabled(value)
    self.active = value and true or false
    if not frame then return end

    if not self.active then
        queue = {}
        showing = nil
        if toastSubId then Scheduler:Unregister(toastSubId); toastSubId = nil end
        frame:Hide()
    end
end

ns:Register("Toast", M)
