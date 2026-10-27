-- Modules/CombatText.lua —— 战斗辅助
--
-- **默认用暴雪自己的浮动战斗文字**：本客户端 C_CombatText.GetCurrentEventInfo 标着
-- SecretReturns，战斗中我们自己画的数字拿不到明文（FormatAmount 直接 nil，整条不画），
-- 所以"自己的数字"降级为**可选**（默认关，开了才接管暴雪对应 CVar、关掉还原）。
--
-- 模块常驻做两件事（玩家 2026-10-27 定的方向）：
--   1. **进出战斗醒目提示** —— 盾 + 双剑 + 大字，参考 Andromeda modules/combat/combat-alert.lua
--      的编排（剑先滑入交叉、盾随后压上、大字升起），贴图是自绘 SVG
--      （tools/svg/monet_combat_{sword,shield}.svg），颜色全走主题槽。
--      只吃 PLAYER_REGEN_* 事件 —— 纯事件载荷，不碰任何战斗数据，无机密值问题。
--   2. **暴雪战斗数字的显示区域偏移** —— 暴雪的数字锚在 `CombatText.textLocations`
--      （Blizzard_CombatText/Shared/CombatText.lua:425，按 1024×768 设计单位算）。
--      我们只往这张**纯数据表**里写偏移后的几何值：
--        * 不读战斗数据、不碰机密值 —— 读到机密 / 非数值就整段放弃（玩家规矩："涉及
--          机密值则不改"）；
--        * 不写 CombatText 帧字段、不挂任何钩子 —— 暴雪重算表（换分辨率 / 切开关）会
--          换一张新表，我们靠 1 秒轮询认出"新表"再把偏移补回去（拉锯的解法见 HANDOFF）。
--
-- 常驻成本：自己数字的容器（无浮字时 OnUpdate 摘掉）+ 一个驱动帧（1 秒一轮的区域检查，
-- 提示播放时兼做补间）；提示帧只有第一次播放才创建。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local Secrets  = ns.Secrets
local EventBus = ns.EventBus

local M = { name = "CombatText" }
ns.CombatText = M

-- ================================================================
-- 可选：我们自己的数字（默认关 —— 关着的时候一个字都不画、一个 CVar 都不动）
-- ================================================================

local POOL_MAX    = 14      -- 同时最多几行
local LIFE        = 1.15    -- 一行活多久（秒）
local RISE        = 44      -- 上飘高度（UI 单位）
local SPREAD      = 30      -- 水平散开的半宽，避免叠成一坨

-- 类型表：和暴雪 CombatText 的分类一致，只挑"玩家自身"会收到的那些。
local DAMAGE = {
    DAMAGE = true, DAMAGE_CRIT = true, SPELL_DAMAGE = true, SPELL_DAMAGE_CRIT = true,
    DAMAGE_SHIELD = true,
}
local HEAL = {
    HEAL = true, HEAL_CRIT = true, PERIODIC_HEAL = true, PERIODIC_HEAL_CRIT = true,
}
local AVOID = {
    MISS = true, DODGE = true, PARRY = true, BLOCK = true, ABSORB = true, RESIST = true,
    EVADE = true, IMMUNE = true, DEFLECT = true, DAMAGE_SHIELD_MISSED = true,
}

-- 暴雪的对应 CVar：存在就接管，不存在就跳过（不写任何找不到的名字）。
-- "combat" 现在跟醒目提示联动：有提示就压掉暴雪自己的进出战斗小字（免得两份），关掉还原。
local CVARS = {
    damage = { "floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatDamage" },
    heal   = { "floatingCombatTextCombatHealing_v2", "floatingCombatTextCombatHealing" },
    avoid  = { "floatingCombatTextDodgeParryMiss_v2", "floatingCombatTextDodgeParryMiss" },
    combat = { "floatingCombatTextCombatState_v2", "floatingCombatTextCombatState" },
}
local OWN_KEYS = { "damage", "heal", "avoid" }   -- 自己数字的三类（area/alert 不属于 CVar 接管）

local container
local active = {}       -- 正在飘的：{ fs=, t=, dx= }
local spare = {}        -- 回收的 FontString
local running           -- 自己数字的 OnUpdate 是否挂着

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.combatText) ~= "table" then db.combatText = {} end
    return db.combatText
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.combatText[key] end
    return value
end

-- ---------------------------------------------------------------- 暴雪 CVar 接管
local function CVarApi()
    local api = _G.C_CVar
    if api and type(api.GetCVar) == "function" and type(api.SetCVar) == "function" then return api end
    return nil
end

--- 原值存档（跟着 DB 走，重登后还能还原）。
local function Saved()
    local db = M:Settings()
    if type(db.saved) ~= "table" then db.saved = {} end
    return db.saved
end

--- 把某一类的暴雪浮动文字关掉，原值存进存档（只存第一次见到的值）。
local function Suppress(key)
    local api = CVarApi()
    if not api then return end
    local saved = Saved()
    for _, name in ipairs(CVARS[key] or {}) do
        local ok, value = pcall(api.GetCVar, name)
        if ok and value ~= nil then
            if saved[name] == nil then saved[name] = value end
            pcall(api.SetCVar, name, "0")
            return
        end
    end
end

local function Restore(key)
    local api = CVarApi()
    if not api then return end
    local saved = Saved()
    for _, name in ipairs(CVARS[key] or {}) do
        local value = saved[name]
        if value ~= nil then
            pcall(api.SetCVar, name, value)
            saved[name] = nil
            return
        end
    end
end

-- ---------------------------------------------------------------- 自己数字的渲染
local function EnsureContainer()
    if container then return end
    container = CreateFrame("Frame", "MonetUICombatText", _G.UIParent)
    container:SetSize(180, 80)
    container:SetFrameStrata("HIGH")
    container:EnableMouse(false)
end

--- 挂到玩家框上方（跟着框走）；拿不到玩家框就退回屏幕中央偏上。
local function Anchor()
    if not container then return end
    container:ClearAllPoints()

    local uf = ns:GetModule("UnitFrames")
    local player = uf and type(uf.GetFrame) == "function" and uf:GetFrame("player")
    if player and type(player.GetTop) == "function" then
        container:SetPoint("BOTTOM", player, "TOP", 0, 6)
        container:SetFrameLevel((player:GetFrameLevel() or 1) + 8)
    else
        container:SetPoint("BOTTOM", _G.UIParent, "CENTER", 0, 120)
        container:SetFrameLevel(200)
    end
end

local function Acquire()
    local fs = table.remove(spare)
    if fs then
        fs:Show()
        return fs
    end
    fs = Widget:Font(container, 12, "pingfang", "danger", "CENTER", nil, Media.outlineFlags)
    fs:SetWordWrap(false)
    return fs
end

local function Tick(_, elapsed)
    elapsed = elapsed or 0
    local alive = 0

    for i = #active, 1, -1 do
        local entry = active[i]
        entry.t = entry.t + elapsed
        local progress = entry.t / LIFE

        if progress >= 1 then
            entry.fs:Hide()
            spare[#spare + 1] = entry.fs
            table.remove(active, i)
        else
            alive = alive + 1
            entry.fs:SetPoint("BOTTOM", container, "BOTTOM", entry.dx * progress, RISE * progress)
            local alpha = (progress < 0.7) and 1 or (1 - (progress - 0.7) / 0.3)
            entry.fs:SetAlpha(alpha)
        end
    end

    if alive == 0 and running then
        running = false
        container:SetScript("OnUpdate", nil)
    end
end

local function Emit(text, r, g, b, big)
    if not (container and text and text ~= "") then return end

    local fs = Acquire()
    Widget:SetFont(fs, big and 16 or 12, "pingfang", Media.outlineFlags)
    fs:SetText(text)
    fs:SetTextColor(r, g, b, 1)
    fs:SetAlpha(1)
    fs:SetPoint("BOTTOM", container, "BOTTOM", 0, 0)

    if #active >= POOL_MAX then
        -- 挤掉最老的一条，池子才不会被刷屏撑爆
        local oldest = table.remove(active, 1)
        if oldest then
            oldest.fs:Hide()
            spare[#spare + 1] = oldest.fs
        end
    end

    active[#active + 1] = {
        fs = fs,
        t = 0,
        dx = (math.random() - 0.5) * SPREAD,
    }

    if not running then
        running = true
        container:SetScript("OnUpdate", Tick)
    end
end

--- 数字格式化：BreakUpLargeNumbers 在 1.60 手工里存在，但仍 pcall —— 属性表不同版本行为不一致。
local function FormatAmount(value)
    local number = Secrets.Number(value)
    if not number then return nil end
    local breakUp = _G.BreakUpLargeNumbers
    if type(breakUp) == "function" then
        local ok, text = pcall(breakUp, number)
        if ok and text then return text end
    end
    return tostring(number)
end

local function OnCombatText(_, msgType)
    if not (M.active and container) or type(msgType) ~= "string" then return end

    local isDamage = DAMAGE[msgType]
    local isHeal = not isDamage and HEAL[msgType]
    local isAvoid = not isDamage and not isHeal and AVOID[msgType]
    if not (isDamage or isHeal or isAvoid) then return end

    local key = isDamage and "damage" or (isHeal and "heal" or "avoid")
    if M:GetSetting(key) == false then return end

    local api = _G.C_CombatText
    if not api or type(api.GetCurrentEventInfo) ~= "function" then return end

    -- 机密环境下这次调用可能给出机密值；构造整体 pcall，任何异常都当"这条不显示"。
    local ok, data, arg3 = pcall(api.GetCurrentEventInfo)
    if not ok then return end

    local big = msgType:find("_CRIT") ~= nil

    if isDamage then
        local amount = FormatAmount(data)
        if not amount then return end
        local r, g, b = Color:GetDanger()
        Emit("-" .. amount, r, g, b, big)
    elseif isHeal then
        local amount = FormatAmount(arg3)
        if not amount then return end
        local r, g, b = Color:GetHealth()
        Emit("+" .. amount, r, g, b, big)
    else
        local label = _G[msgType]
        if type(label) ~= "string" then label = msgType end
        local r, g, b = Color:GetNeutral()
        Emit(label, r, g, b, false)
    end
end

-- ================================================================
-- 暴雪战斗数字的显示区域（只写纯几何偏移，不碰机密值）
-- ================================================================

-- 预设值按 1024×768 设计单位给，应用时乘暴雪同款的屏幕缩放（WorldFrame/1024·768）。
local AREA_PRESETS = {
    center = { 0, 0 },
    up     = { 0, 150 },
    down   = { 0, -150 },
    left   = { -230, 0 },
    right  = { 230, 0 },
}

local AREA_POLL = 1        -- 轮询间隔（秒）：暴雪重算后最多 1 秒把偏移补回去
local areaAcc = 0
local locTable             -- 我们正在其上生效的 textLocations 实例
local locPristine          -- 那张表的原始值快照 { startX, startY, endX, endY }

--- 与暴雪同款的屏幕缩放；读不到（或读到机密值）返回 nil —— 调用方就放弃这次偏移。
local function ScreenScale()
    local wf = _G.WorldFrame
    if not (wf and type(wf.GetWidth) == "function") then return nil end
    local ok, w, h = pcall(function() return wf:GetWidth(), wf:GetHeight() end)
    if not ok then return nil end
    if type(w) ~= "number" or type(h) ~= "number" then return nil end
    if Secrets.IsSecret(w) or Secrets.IsSecret(h) then return nil end
    if w <= 0 or h <= 0 then return nil end
    return w / 1024, h / 768
end

local function ApplyArea()
    local ct = _G.CombatText
    local ts = ct and ct.textLocations
    if type(ts) ~= "table" then return end       -- 帧还没建 / 还没初始化（空表走不进来）

    if ts ~= locTable then
        -- 暴雪换了一张表（重算）或第一次见到：先快照原值。
        -- 任何一项不是普通数值（含机密值）→ 按玩家规矩"涉及机密值则不改"，整段放弃。
        local a, b, c, d = ts.startX, ts.startY, ts.endX, ts.endY
        if type(a) ~= "number" or type(b) ~= "number"
        or type(c) ~= "number" or type(d) ~= "number" then return end
        if Secrets.IsSecret(a) or Secrets.IsSecret(b)
        or Secrets.IsSecret(c) or Secrets.IsSecret(d) then return end
        locPristine = { a, b, c, d }
        locTable = ts
    end
    if not locPristine then return end

    local dx, dy = 0, 0
    if M.active then
        local preset = M:GetSetting("area") or "center"
        local off = AREA_PRESETS[preset] or AREA_PRESETS.center
        local sx, sy = ScreenScale()
        if not sx then return end
        dx, dy = off[1] * sx, off[2] * sy
    end

    -- 幂等：每次都从快照算目标值，值没变就不写（偏移为 0 时这就是"还原"）。
    local nx, ny = locPristine[1] + dx, locPristine[2] + dy
    local ex, ey = locPristine[3] + dx, locPristine[4] + dy
    if ts.startX ~= nx then ts.startX = nx end
    if ts.startY ~= ny then ts.startY = ny end
    if ts.endX   ~= ex then ts.endX   = ex end
    if ts.endY   ~= ey then ts.endY   = ey end
end

-- ================================================================
-- 进出战斗醒目提示（参考 Andromeda combat-alert，编排简化、贴图自绘）
-- ================================================================

local ALERT_ENTER = 1.5     -- 提示总时长（秒）
local ALERT_LEAVE = 1.4

local SWORD_SIZE  = 168     -- 剑贴图显示边长（画布 256，缩着画）
local SHIELD_SIZE = 124     -- 盾贴图显示边长
local SWORD_SLIDE = 105     -- 进入时剑从画面上角滑入的起始偏移
local SWORD_OUT   = 26      -- 淡出时剑继续向外漂的距离
local TEXT_BASE   = -2      -- 大字锚点（alert 底边下 2px）
local TEXT_RISE   = 26      -- 进入时大字从下方升起的高度
local TEXT_DRIFT  = 16      -- 淡出时大字上飘的距离

local alert                -- 主帧（第一次播放才建）
local aSwordR, aSwordL, aShield, aText
local playing              -- nil | "enter" | "leave"
local playT, playDur
local queue = {}

local function Prog(t0, t1, t)
    if t <= t0 then return 0 end
    if t >= t1 then return 1 end
    return (t - t0) / (t1 - t0)
end

local function EaseOut(p)
    return 1 - (1 - p) ^ 3
end

local function EnsureAlert()
    if alert then return end
    alert = CreateFrame("Frame", "MonetUICombatAlert", _G.UIParent)
    alert:SetSize(240, 170)
    alert:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 200)
    alert:SetFrameStrata("HIGH")
    alert:EnableMouse(false)
    alert:Hide()

    -- 层序：两把剑（ARTWORK）→ 盾压住交点（OVERLAY）→ 大字（OVERLAY 后建 = 最上）
    aSwordR = alert:CreateTexture(nil, "ARTWORK")
    aSwordR:SetTexture(Media:Texture("monet_combat_sword"))
    aSwordR:SetSize(SWORD_SIZE, SWORD_SIZE)
    aSwordR:SetPoint("CENTER", alert, "CENTER", 0, 0)

    aSwordL = alert:CreateTexture(nil, "ARTWORK")
    aSwordL:SetTexture(Media:Texture("monet_combat_sword"))
    aSwordL:SetSize(SWORD_SIZE, SWORD_SIZE)
    aSwordL:SetPoint("CENTER", alert, "CENTER", 0, 0)
    aSwordL:SetTexCoord(1, 0, 0, 1)     -- 水平镜像 = 左边那把

    aShield = alert:CreateTexture(nil, "OVERLAY")
    aShield:SetTexture(Media:Texture("monet_combat_shield"))
    aShield:SetSize(SHIELD_SIZE, SHIELD_SIZE)
    aShield:SetPoint("CENTER", alert, "CENTER", 0, 0)

    aText = Widget:Font(alert, 24, "pingfang", "danger", "CENTER", "OVERLAY", Media.outlineFlags)
    aText:SetPoint("TOP", alert, "BOTTOM", 0, TEXT_BASE)
    aText:SetWordWrap(false)
end

local function Place(tex, alpha, scale, ox, oy, base)
    tex:SetAlpha(alpha)
    tex:SetSize(base * scale, base * scale)
    tex:SetPoint("CENTER", alert, "CENTER", ox or 0, oy or 0)
end

--- t = 已播放秒数；全部关键帧都是绝对时间，进出两套各画各的。
local function RenderAlert(kind, t)
    if kind == "enter" then
        -- 剑：从画面上角滑入交叉 → 停 → 向外漂着淡出
        local swordIn  = EaseOut(Prog(0, 0.35, t))
        local swordOut = Prog(1.05, ALERT_ENTER, t)
        local slide    = (1 - swordIn) * SWORD_SLIDE + swordOut * SWORD_OUT
        local swordA   = swordIn * (1 - swordOut)
        local swordS   = 0.85 + 0.15 * swordIn + 0.10 * swordOut
        Place(aSwordR, swordA, swordS,  slide, slide, SWORD_SIZE)
        Place(aSwordL, swordA, swordS, -slide, slide, SWORD_SIZE)

        -- 盾：剑到位后从中心弹出 → 停 → 放大着淡出
        local shIn  = EaseOut(Prog(0.30, 0.55, t))
        local shOut = Prog(1.15, ALERT_ENTER, t)
        Place(aShield, shIn * (1 - shOut), 0.25 + 0.75 * shIn + 0.12 * shOut,
              0, 0, SHIELD_SIZE)

        -- 大字：升起 → 停 → 上飘着淡出
        local txIn  = EaseOut(Prog(0.15, 0.50, t))
        local txOut = Prog(1.10, ALERT_ENTER, t)
        aText:SetAlpha(txIn * (1 - txOut))
        aText:SetPoint("TOP", alert, "BOTTOM", 0,
            TEXT_BASE - TEXT_RISE * (1 - txIn) + TEXT_DRIFT * txOut)
    else
        -- 离开：整体微微涨开 → 缩没淡出；大字独立淡入淡出
        local appear  = EaseOut(Prog(0, 0.18, t))
        local grow    = Prog(0, 0.35, t)
        local shrink  = EaseOut(Prog(0.35, 0.95, t))
        local alpha   = appear * (1 - shrink)
        local scale   = 1 + 0.06 * grow - 0.45 * shrink
        local outward = 40 * shrink
        Place(aShield, alpha, scale, 0, 0, SHIELD_SIZE)
        Place(aSwordR, alpha, scale,  outward, outward, SWORD_SIZE)
        Place(aSwordL, alpha, scale, -outward, outward, SWORD_SIZE)

        local txIn  = EaseOut(Prog(0, 0.30, t))
        local txOut = Prog(0.85, 1.35, t)
        aText:SetAlpha(txIn * (1 - txOut))
        aText:SetPoint("TOP", alert, "BOTTOM", 0,
            TEXT_BASE - 18 * (1 - txIn) + TEXT_DRIFT * txOut)
    end
end

local Play   -- 前置声明（FinishAlert 会回调）

local function FinishAlert()
    alert:Hide()
    playing = nil
    if queue[1] then
        Play(table.remove(queue, 1))
    end
end

local function StopAlert()
    wipe(queue)
    playing = nil
    if alert then alert:Hide() end
end

Play = function(kind)
    if playing then
        -- 连环进出战斗（恐惧 / 读条打断）：排队播，最多存 3 条，超了丢最老的
        if #queue >= 3 then table.remove(queue, 1) end
        queue[#queue + 1] = kind
        return
    end

    EnsureAlert()
    playing = kind
    playT = 0
    playDur = (kind == "enter") and ALERT_ENTER or ALERT_LEAVE

    if kind == "enter" then
        local s = _G.ENTERING_COMBAT
        aText:SetText((type(s) == "string" and s) or "进入战斗")
        local r, g, b = Color:GetDanger()
        aText:SetTextColor(r, g, b, 1)
    else
        local s = _G.LEAVING_COMBAT
        aText:SetText((type(s) == "string" and s) or "离开战斗")
        local r, g, b = Color:GetHealth()
        aText:SetTextColor(r, g, b, 1)
    end

    local r, g, b = Color:Get("primary")      -- 盾：主题色
    aShield:SetVertexColor(r, g, b, 1)
    r, g, b = Color:Get("highlight")          -- 剑：主题高光
    aSwordR:SetVertexColor(r, g, b, 1)
    aSwordL:SetVertexColor(r, g, b, 1)

    alert:Show()
    RenderAlert(kind, 0)
end

-- ---------------------------------------------------------------- 驱动帧
local driver

local function DriverTick(_, elapsed)
    if not M.active then return end
    elapsed = elapsed or 0

    if playing then
        playT = playT + elapsed
        if playT >= playDur then
            FinishAlert()
        else
            RenderAlert(playing, playT)
        end
    end

    -- 暴雪换表（重算 textLocations）后把偏移补回去
    areaAcc = areaAcc + elapsed
    if areaAcc >= AREA_POLL then
        areaAcc = 0
        ApplyArea()
    end
end

-- ================================================================
-- 模块接口
-- ================================================================

function M:Initialize()
    self.active = true
    EnsureContainer()
    Anchor()

    EventBus:Register("COMBAT_TEXT_UPDATE", function(_, msgType)
        if M.active then OnCombatText(nil, msgType) end
    end)

    -- 只吃事件本身，载荷不读任何战斗数据 —— 无机密值问题
    EventBus:Register("PLAYER_REGEN_DISABLED", function()
        if M.active and M:GetSetting("alert") then Play("enter") end
    end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if M.active and M:GetSetting("alert") then Play("leave") end
    end)

    -- 玩家框可能比我们晚建 / 被拖动：进场时重新贴一次锚点。
    EventBus:Register("PLAYER_ENTERING_WORLD", function() if M.active then Anchor() end end)

    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", DriverTick)

    self:Apply()
end

function M:Apply()
    if not self.active then return end

    for _, key in ipairs(OWN_KEYS) do
        if self:GetSetting(key) == false then
            Restore(key)
        else
            Suppress(key)
        end
    end

    -- 有醒目提示就不让暴雪再画一份进出战斗小字；关掉提示就把原设置还回去。
    if self:GetSetting("alert") then
        Suppress("combat")
    else
        Restore("combat")
        StopAlert()
    end

    ApplyArea()
end

function M:SetEnabled(value)
    self.active = value and true or false

    if self.active then
        Anchor()
        self:Apply()
        return
    end

    -- 关掉：暴雪的浮动文字全还回去，提示停掉，显示区域写回原值。
    for key in pairs(CVARS) do Restore(key) end
    StopAlert()
    ApplyArea()

    if not container then return end
    container:SetScript("OnUpdate", nil)
    running = false
    for i = #active, 1, -1 do
        active[i].fs:Hide()
        spare[#spare + 1] = active[i].fs
        active[i] = nil
    end
end

ns:Register("CombatText", M)
