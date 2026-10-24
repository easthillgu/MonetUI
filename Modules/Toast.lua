-- Modules/Toast.lua
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

local M = { name = "Toast" }
ns.Toast = M

local WIDTH      = 300    -- 横幅宽度
local HEIGHT     = 44
local PAD        = 10     -- 内边距
local ACCENT     = 2      -- 左侧主题色竖条宽度
local FADE_IN    = 0.15
local FADE_OUT   = 0.25
local TOP        = -64    -- 离屏幕上沿（信息栏在 0..14，往下让开）

local frame, accent, title, body, drain
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
end

local function Fill(entry)
    showing = entry
    title:SetText(entry.title or "")
    body:SetText(entry.text or "")
    frame:SetAlpha(0)
    drain:SetWidth(frame:GetWidth() or WIDTH)
    frame:Show()

    holdFor = math.max(1, tonumber(M:GetSetting("duration")) or 5)
    phase, t = "in", 0
    frame:SetScript("OnUpdate", M.Tick)
end

local function Next()
    showing = nil
    frame:Hide()
    frame:SetScript("OnUpdate", nil)
    if #queue > 0 then Fill(table.remove(queue, 1)) end
end

--- 动画步进：淡入 → 停留（排空线变短）→ 淡出 → 下一条。
function M.Tick(self, elapsed)
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
            drain:SetWidth((frame:GetWidth() or WIDTH) * progress)
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
function M:Notify(head, text)
    if not (self.active and frame) then return end
    local entry = { title = head, text = text }
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

    title = Widget:Font(frame, 12, "pingfang", "highlight", "LEFT", nil, Media.outlineFlags)
    title:SetWordWrap(false)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", ACCENT + PAD, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -8)
    title:SetHeight(13)

    body = Widget:Font(frame, 12, "pingfang", "neutral", "LEFT", nil, Media.outlineFlags)
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
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
    end
end

ns:Register("Toast", M)
