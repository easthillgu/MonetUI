-- Modules/UnitFrames/BossFrames.lua
-- 首领框架：普通按钮 + visibility 驱动 + Monet 皮肤。
-- 与小队/团队同源：血条、能量、名字、选中边框（样式复用 Groups.lua 的函数）。
--
-- 压制暴雪的 Boss1TargetFrame..Boss5TargetFrame（饿事件 + alpha 0 + 移出屏幕），
-- 自建按钮由客户端受限环境控制显隐（[@bossN,exists] show; hide）。

local ADDON_NAME, ns = ...

local M = { name = "BossFrames" }

-- 延迟取值（防 nil 崩溃）
local function S(k, fb)
    local v = ns and ns[k]
    if v ~= nil then return v end
    return fb
end

local Secrets  = function() return S("Secrets") end
local Widget   = function() return S("Widget") end
local Color    = function() return S("Color") end
local Media    = function() return S("Media") end
local Math     = function() return S("Math") end
local EventBus = function() return S("EventBus") end
local Mover    = function() return S("Mover") end

local MAX_BOSS  = 5
local BORDER     = 1
local RANGE_ALPHA = 0.45
local RANGE_INTERVAL = 0.25

-- ============================================================================
-- 配置
-- ============================================================================

local function Config()
    local db = ns and type(ns.DB) == "function" and ns:DB()
    return db and db.bossFrames
end

local function InCombat()
    -- 优先问 Core 的 `ns:InCombat()`：它按 PLAYER_REGEN_* 自己记状态，登录 / 重载当拍
    -- `InCombatLockdown()` 会给假的 false（AGENTS 实机判例）。没有它就退回实时标志。
    if type(ns.InCombat) == "function" then return ns:InCombat() end
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

--- 受保护写入的唯一门槛：六类受限窗口都算（同 Groups.lua 的 Restricted）。
--- 守卫判"忙"的窗口与 `ns:AfterCombat` 的"当场能做"判据（也是 ns:IsRestricted）同源，
--- 二者不一致才会互顶成死循环。
local function Restricted()
    if type(ns.IsRestricted) == "function" then return ns.IsRestricted() end
    return InCombat()
end

local function FrameHeight(cfg)
    local b = BORDER
    local power = cfg.power or 0
    return b * 2 + (cfg.health or 16) + (power > 0 and (1 + power) or 0)
end

-- ============================================================================
-- 复用 Groups.lua 的样式函数
-- ============================================================================

local function StyleReady()
    local gf = ns and type(ns.GetModule) == "function" and ns:GetModule("GroupFrames")
    return gf and type(gf.StyleButton) == "function"
end

local function GetGroupFrames()
    return ns and type(ns.GetModule) == "function" and ns:GetModule("GroupFrames")
end

-- ============================================================================
-- 状态更新（首领框独立路径）
-- ============================================================================

local byIndex = {}   -- [1..5] → button

local function UpdateState(button)
    local unit = button.unit
    if not unit or not UnitExists(unit) then button.cachedName = nil; return end

    local secrets = Secrets()
    local widget = Widget()
    local color = Color()
    local media = Media()
    local mathm = Math()
    if not secrets or not widget or not color or not media then return end

    -- 血量：战斗中 UnitHealth/UnitHealthMax 是机密值。用 Secrets.SetBar（它把**原始机密值**
    -- 直接喂给 SetMinMaxValues/SetValue —— 文档标注这两个"允许污染代码传机密"，引擎渲染）。
    -- 不要走 Secrets.Number（对机密返回 nil → 条停在 1/1），也不要做 `> 0` 比较（机密不能比）。
    secrets.SetBar(button.health, UnitHealth(unit), UnitHealthMax(unit))

    -- 能量（同上，直接用 SetBar 传机密值）
    if button.power then
        secrets.SetBar(button.power, UnitPower(unit), UnitPowerMax(unit))
        local pt = UnitPowerType(unit)
        local pr, pg, pb = 0, 0, 1
        if _G.PowerBarColor and pt and _G.PowerBarColor[pt] then
            local c = _G.PowerBarColor[pt]
            pr, pg, pb = c.r or 0, c.g or 0, c.b or 1
        end
        pcall(button.power.SetStatusBarColor, button.power, pr, pg, pb, 1)
    end

    -- 名字：战斗中 UnitName 是机密值。**直接把机密 name 传给 FontString:SetText**
    -- （文档标注"允许污染代码传机密"，引擎渲染）；不能用 FitText（字符串操作会碰机密）。
    -- SetTextToFit 也是允许机密的，用它做"缩到宽度"（引擎侧）。
    if button.name then
        local ok, name = pcall(UnitName, unit)
        if ok and name ~= nil then
            if button.name.SetTextToFit then
                pcall(button.name.SetTextToFit, button.name, name)
            else
                pcall(button.name.SetText, button.name, name)
            end
        end
    end

    -- 职责图标：形状说明职责，颜色说明队长 / 助理（Color:RoleTint，和 Groups 同一口径）。
    -- 首领没有职责时整块藏掉（Groups 那边是退回 dps 图标，这里宁可什么都不画）。
    if button.role and _G.UnitGroupRolesAssigned then
        local ok, role = pcall(UnitGroupRolesAssigned, unit)
        if ok and secrets.CanRead(role) then
            local key
            if role == "TANK" then
                key = "monet_role_tank"
            elseif role == "HEALER" then
                key = "monet_role_heal"
            elseif role == "DAMAGER" then
                key = "monet_role_dps"
            end
            if key then
                button.role:SetTexture(media:Texture(key))
                button.role:SetVertexColor(color:RoleTint(unit))
                button.role:Show()
            else
                button.role:Hide()
            end
        end
    end

    -- 选中边框（selectEdges 由 Widget:Theme 创建）
    local edges = button.selectEdges
    if edges and color and type(color.GetHighlight) == "function" then
        local isTarget = false
        local ok, same = pcall(UnitIsUnit, unit, "target")
        if ok and not secrets.IsSecret(same) and secrets.Bool(same) then
            isTarget = true
        end
        local r, g, b = color:GetHighlight()
        local alpha = isTarget and 1 or 0
        for i = 1, 4 do edges[i]:SetVertexColor(r, g, b, alpha) end
    end

    -- 距离 alpha
    local ok, inRange, checked = pcall(UnitInRange, unit)
    local known, near
    if ok and not secrets.IsSecret(checked) then known = secrets.Bool(checked) end
    if ok and secrets.IsSecret(inRange) then
        near = true
    elseif ok then
        near = secrets.Bool(inRange, true)
    end
    button:SetAlpha((known and not near) and RANGE_ALPHA or 1)

    -- 文字更新
    local gf = GetGroupFrames()
    if gf and type(gf.UpdateHealthText) == "function" then
        gf.UpdateHealthText(button)
    end
end

-- ============================================================================
-- 样式 + 建按钮
-- ============================================================================

-- 底板压到不透明：面板那一档（Color 的 L*10）本来就比血条暗，半透明会让背后的
-- 团队框体透上来把对比度吃掉。原来这里想传 bg = {0.06,...}，但 Widget:Theme 不认
-- 这个键（背景色只有阶梯一个来源），写了等于没写。
local function ThemeOpaque(button)
    local widget = Widget()
    if widget and button.SetBackdrop then
        widget:Theme(button, { thickness = BORDER, bgAlpha = 1.0 })
    end
end

local function StyleButton(button, cfg)
    if not button then return end

    if StyleReady() then
        local gf = GetGroupFrames()
        if gf and type(gf.StyleButton) == "function" then
            gf.StyleButton(button, cfg, (cfg.width or 180) < 100)
            if type(gf.NameCap) == "function" then
                button.nameCap = gf.NameCap(cfg)
            end
            ThemeOpaque(button)
        end
        return
    end

    -- 降级：简易皮肤
    local w = cfg.width or 180
    local h = FrameHeight(cfg)
    button:SetSize(w, h)
    local widget = Widget()
    ThemeOpaque(button)

    local inner = w - BORDER * 2
    local healthH = cfg.health or 16

    if not button.health and widget then
        button.health = widget:Bar(button, inner, healthH)
        button.health:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, BORDER)
    end
    if button.health then
        button.health:SetSize(inner, healthH)
    end

    local powerH = cfg.power or 0
    if powerH > 0 and widget then
        if not button.power then
            -- 能量条：纯高亮平涂，不用渐变（和玩家/小队框同一口径）。
            button.power = widget:Bar(button, inner, powerH, "monet_barfill")
        end
        button.power:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", BORDER, BORDER)
        button.power:Show()
    end

    if not button.name and widget then
        button.name = widget:Font(button, 10, "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
        button.name:SetWordWrap(false)
        if button.name.SetShadowColor then
            button.name:SetShadowColor(0, 0, 0, 1)
            button.name:SetShadowOffset(1, -1)
        end
    end
    if button.name then
        button.name:ClearAllPoints()
        button.name:SetPoint("LEFT", button, "LEFT", BORDER + 3, 0)
        button.name:SetSize(inner - 6, 13)
    end
end

local function CreateButton(index, cfg)
    local unit = "boss" .. index

    -- **必须是 SecureUnitButtonTemplate**：点击由客户端在受限环境里执行
    -- （*type1 = target / *type2 = togglemenu，和 Groups 的 SecureInit 同一套）。
    -- 普通 Button 上直接调 TargetUnit / ToggleDropDownMenu 是受保护调用，
    -- 战斗中必被拦成 ADDON_ACTION_FORBIDDEN（wuxian check 报的就是这一条）。
    -- 模板建不出来时退回普通 Button —— 那时只显示不点击，绝不挂受保护的 OnClick。
    local ok, button = pcall(CreateFrame, "Button", "MonetBossButton" .. index, nil,
        "SecureUnitButtonTemplate")
    local secure = ok and button
    if not secure then
        ok, button = pcall(CreateFrame, "Button", "MonetBossButton" .. index, nil)
        if not ok or not button then return nil end
    end

    button:SetID(0)
    button.unit = unit
    button:RegisterForClicks("AnyDown", "AnyUp")

    if secure then
        pcall(button.SetAttribute, button, "unit", unit)
        pcall(button.SetAttribute, button, "*type1", "target")
        pcall(button.SetAttribute, button, "*type2", "togglemenu")
    end

    StyleButton(button, cfg)

    -- visibility 驱动
    if type(_G.RegisterStateDriver) == "function" then
        pcall(_G.RegisterStateDriver, button, "visibility",
            "[@" .. unit .. ",exists] show; hide")
    end

    return button
end

-- ============================================================================
-- 容器 / 锚点
-- ============================================================================

local bossAnchor
local bossButtons = {}
local ticker

local function BuildBoss(cfg)
    if bossAnchor then return bossButtons end

    bossAnchor = CreateFrame("Frame", "MonetBossAnchor", UIParent)
    bossAnchor:SetSize(cfg.width, MAX_BOSS * FrameHeight(cfg) + (MAX_BOSS - 1) * (cfg.spacing or 2))

    for i = 1, MAX_BOSS do
        local btn = CreateButton(i, cfg)
        if btn then
            btn:SetParent(bossAnchor)
            if i == 1 then
                btn:SetPoint("TOPLEFT", bossAnchor, "TOPLEFT", 0, 0)
            else
                btn:SetPoint("TOPLEFT", bossButtons[i - 1], "BOTTOMLEFT", 0, -(cfg.spacing or 2))
            end
            btn:Hide()  -- visibility 驱动控制
            bossButtons[i] = btn
            byIndex[i] = btn
        end
    end

    -- 距离 ticker
    local function Tick()
        local secrets = Secrets()
        if not secrets then return end
        for i = 1, MAX_BOSS do
            local btn = bossButtons[i]
            if btn and secrets.Bool(btn:IsShown(), false) and btn.unit and UnitExists(btn.unit) then
                UpdateState(btn)
            end
        end
    end

    if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
        ticker = C_Timer.NewTicker(RANGE_INTERVAL, Tick)
    end

    return bossButtons
end

local function RestyleBoss(cfg)
    if not bossAnchor then return end
    -- **战斗中一个尺寸都不能改**：`MonetBossAnchor` 挂着 `SecureUnitButtonTemplate` 子按钮，
    -- 自己也算受保护框（改它的几何等于挪安全子按钮），`SetSize` 直接被拒。实机 2026-11-01：
    -- 进战斗后主题一刷新就刷 6 条
    --   ADDON_ACTION_BLOCKED MonetUI MonetBossAnchor:SetSize()
    --   ADDON_ACTION_BLOCKED MonetUI MonetBossButton1..5:SetSize()
    -- 主题事件在战斗里照常派发（区域切换 / MonetColor 回调 / 手动 /mui），所以这里必须排队。
    if Restricted() then
        if type(ns.AfterCombat) == "function" then
            ns:AfterCombat("bossframes-restyle", function()
                local c = Config()
                if c then RestyleBoss(c) end
            end)
        end
        return
    end
    bossAnchor:SetSize(cfg.width, MAX_BOSS * FrameHeight(cfg) + (MAX_BOSS - 1) * (cfg.spacing or 2))
    for i = 1, MAX_BOSS do
        local btn = bossButtons[i]
        if btn then StyleButton(btn, cfg) end
    end
end

local StopSuppressTicker   -- 前向声明：TeardownBoss 在定义之前，见下面「压制暴雪首领框」

local function TeardownBoss()
    if ticker then ticker:Cancel(); ticker = nil end
    if StopSuppressTicker then StopSuppressTicker() end
    if bossAnchor then bossAnchor:Hide(); bossAnchor = nil end
    for i = 1, MAX_BOSS do
        local btn = bossButtons[i]
        if btn then
            if type(_G.UnregisterStateDriver) == "function" then
                pcall(_G.UnregisterStateDriver, btn, "visibility")
            end
            btn:Hide()
            bossButtons[i] = nil
            byIndex[i] = nil
        end
    end
end

-- ============================================================================
-- 压制暴雪首领框
-- ============================================================================

local function StarveBoss(frame)
    if not frame then return end
    pcall(frame.UnregisterAllEvents, frame)
    if type(frame.GetChildren) ~= "function" then return end
    -- `GetChildren` 返回的是**多返回值**不是表：直接 `pcall(frame.GetChildren, frame)` 只拿到
    -- 第一个子框，随后 `#kids` 恒为 0（框体表没有数组部分）—— 子件事件从来没被饿掉过。
    -- 本仓其余十处都写成 `{ ... }`（见 Utils/Skin.lua 的同款注释）。
    local ok, kids = pcall(function() return { frame:GetChildren() } end)
    if not ok or type(kids) ~= "table" then return end
    for i = 1, #kids do
        local child = kids[i]
        if child and type(child.UnregisterAllEvents) == "function" then
            pcall(child.UnregisterAllEvents, child)
        end
    end
end

local function ParkBoss(frame)
    if not frame then return end
    pcall(frame.SetAlpha, frame, 0)
    pcall(frame.EnableMouse, frame, false)
    if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, false) end
    if type(frame.ClearAllPoints) == "function" then pcall(frame.ClearAllPoints, frame) end
    if type(frame.SetPoint) == "function" then
        pcall(frame.SetPoint, frame, "TOPLEFT", "UIParent", "BOTTOMRIGHT", 1, -1)
    end
end

local function SuppressBlizzardBoss()
    local cfg = Config()
    if cfg and cfg.hideBlizzard == false then return end

    -- **受限窗口里一次都不做**：`BossTargetFrameContainer` / `BossNTargetFrame` 都是
    -- `protected=true`（实机探针 2026-11-01），受限期对受保护框的 SetAlpha / SetPoint /
    -- ClearAllPoints 全部被拒。压制必须在受限之外做扎实，受限中补不了。
    if Restricted() then return end

    local f = _G.BossTargetFrameContainer
    if f then
        StarveBoss(f)
        ParkBoss(f)
    end
    for i = 1, MAX_BOSS do
        local bf = _G["Boss" .. i .. "TargetFrame"]
        if bf then
            StarveBoss(bf)
            ParkBoss(bf)
        end
    end
end

--- 补压 ticker（2 秒，只在脱战跑）。
---
--- 为什么需要它：以前压制只在 Initialize / PLAYER_ENTERING_WORLD / 换区域各做一次。
--- 实机 2026-11-01（副本内）：`BossTargetFrameContainer` 的 alpha 是 **1.00** —— 压制从没生效过。
--- 原因有两层：①进副本那一刻 `Apply()` 在战斗里被推迟（战斗里做不了）；②暴雪的首领框是懒创建
--- 且会自己重设 alpha，只在登录做一次会漏掉后建的框。脱战每 2 秒补一次，两种都能兜住。
local suppressTicker

local function StartSuppressTicker()
    if suppressTicker then return end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then return end
    suppressTicker = C_Timer.NewTicker(2, function()
        if Restricted() then return end
        if type(ns.IsModuleEnabled) == "function"
           and ns:IsModuleEnabled("BossFrames") == false then return end
        SuppressBlizzardBoss()
    end)
end

StopSuppressTicker = function()
    if suppressTicker then suppressTicker:Cancel(); suppressTicker = nil end
end
-- ============================================================================
-- 模块接口
-- ============================================================================

local function DesiredState()
    if type(ns.IsModuleEnabled) == "function"
       and ns:IsModuleEnabled("BossFrames") == false then
        M:SetEnabled(false)
    else
        M:Apply()
    end
end

function M:Apply()
    local cfg = Config()
    if not cfg then return end

    if Restricted() then
        if type(ns.AfterCombat) == "function" then
            ns:AfterCombat("bossframes-state", DesiredState)
        end
        return
    end

    SuppressBlizzardBoss()

    if cfg.enabled ~= false then
        BuildBoss(cfg)
        -- 压制 ticker：暴雪首领框是懒创建且会自己重设 alpha，一次压制盖不住整场。
        -- 它只在脱战跑（受保护框），战斗中什么都不做。
        StartSuppressTicker()
        local mov = Mover()
        if mov and type(mov.Register) == "function" and bossAnchor then
            mov:Register(bossAnchor, "bossFrames", {
                group   = "bossFrames",
                label   = "首领框架",
                default = cfg,
                store   = function() return cfg end,
                isVisible = function()
                    for i = 1, MAX_BOSS do
                        if _G.UnitExists("boss" .. i) then return true end
                    end
                    return false
                end,
            })
        end
    else
        TeardownBoss()
    end
end

function M:RegisterEvents()
    local eb = EventBus()
    if not eb or type(eb.Register) ~= "function" then return end

    eb:Register("PLAYER_ENTERING_WORLD", function() M:Apply() end)
    eb:Register("ZONE_CHANGED_NEW_AREA", function()
        local cfg = Config()
        if cfg then SuppressBlizzardBoss() end
    end)
    eb:Register("UNIT_TARGET", function()
        for i = 1, MAX_BOSS do
            local btn = bossButtons[i]
            if btn and Secrets().Bool(btn:IsShown(), false) then UpdateState(btn) end
        end
    end)
    eb:Register("MONETUI_THEME_CHANGED", function()
        local cfg = Config()
        if cfg then RestyleBoss(cfg) end
    end)
end

function M:Initialize()
    self:RegisterEvents()
    self:Apply()
end

function M:SetEnabled(enabled)
    if Restricted() then
        if type(ns.AfterCombat) == "function" then
            ns:AfterCombat("bossframes-state", DesiredState)
        end
        return
    end
    if enabled then
        self:Apply()
    else
        TeardownBoss()
    end
end

ns:Register("BossFrames", M)
