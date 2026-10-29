-- Modules/Nameplates/Nameplates.lua
-- Nameplates (姓名板) in the Monet slim-bar style: our own bar hung on Blizzard's base plate
-- with their UnitFrame child hidden (the Andromeda / ElvUI / Plater approach, no oUF).  The game
-- keeps drawing the auras on a reparented frame; bars are fed raw (possibly secret) values.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local EventBus = ns.EventBus

local M = { name = "Nameplates" }

local plates = {}   -- unit token ("nameplate3") -> our plate frame
local driverHooked = false

--- 本客户端的框体污染是按**键**算的：插件只要往暴雪的框体上写过一个字段，这个框体随后的
--- 暴雪代码就会以我们的名义跑。实机证据（`issecurevariable` 逐键扫 NamePlate1UnitFrame）：
--- 唯一为 false 的键就是 `__monetAuraHook`，紧接着暴雪自己的 `CompactUnitFrame_OnUpdate`
--- 就报 "attempt to compare local 'maxHealth' (a secret number value, while execution tainted
--- by 'MonetUI')"，而且 10 秒一次刷屏；同族的报错还有 SetPoint 被拒的
--- "anchor family connection"。所以姓名板的所有簿记一律走 Core 的旁表（ns:Mark / ns:Marked），
--- 绝不往暴雪的框体（base / UnitFrame / AurasFrame / 它的 debuff 按钮）上写字段。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local BORDER   = Widget.BORDER   -- 1px Monet 发丝边（单一来源见 Utils/Widget.lua）
local TEXT_GAP = Widget.TEXT_GAP -- the gap the unit frames keep above their bars
local CAST_GAP = 4
-- 当前目标的固定标识：金色描边 + 1.1 倍。金色**不跟主题走** —— 它回答的是"这是我的目标"，
-- 而不是"这个单位现在对我什么威胁"（后者是仇恨色，优先级更高，见 UpdateBorder）。
local TARGET_GOLD  = { 1.00, 0.84, 0.28 }
local TARGET_SCALE = 1.1

local function DB()
    local db = ns:DB()
    if type(db.nameplates) ~= "table" then db.nameplates = {} end
    return db.nameplates
end

--- One setting: what the player saved, else what shipped in Core's DEFAULTS.
local function Setting(key)
    local stored = DB()[key]
    if stored ~= nil then return stored end
    return (ns.DEFAULTS.nameplates or {})[key]
end

M.Setting = Setting

-- Which units the game gives a plate to is a CVar, not an addon decision, so the module
-- steers these; every call is pcall'd (unknown CVars raise, and they come and go per build).
local CVARS = {
    "nameplateShowFriends", "nameplateShowEnemies", "nameplateShowFriendlyNpcs",
    "nameplateShowEnemyMinus", "nameplateShowEnemyTotems", "nameplateShowFriendlyTotems",
    "nameplateShowSelf", "nameplateMaxDistance",
}

local savedCVars

local function ReadCVar(cvar)
    if not GetCVar then return nil end
    local ok, value = pcall(GetCVar, cvar)
    if ok then return value end
    return nil
end

local function WriteCVar(cvar, value)
    if not SetCVar then return end
    pcall(SetCVar, cvar, value)
end

local function OnOff(value)
    return (value ~= false) and "1" or "0"
end

--- Push the "who gets a plate" settings into the client.
function M:ApplyCVars()
    if not savedCVars then
        -- Saved once, so turning the module off hands the client back exactly as it was
        -- found (for whatever nameplate addon runs next).
        savedCVars = {}
        for _, cvar in ipairs(CVARS) do
            savedCVars[cvar] = ReadCVar(cvar)
        end
    end

    WriteCVar("nameplateShowFriends",       OnOff(Setting("showFriendly")))
    WriteCVar("nameplateShowEnemies",       OnOff(Setting("showEnemy")))
    WriteCVar("nameplateShowFriendlyNpcs",  OnOff(Setting("showNPC")))
    WriteCVar("nameplateShowEnemyMinus",    Setting("showMinor") and "1" or "0")
    WriteCVar("nameplateShowEnemyTotems",   OnOff(Setting("showTotems")))
    WriteCVar("nameplateShowFriendlyTotems", OnOff(Setting("showTotems")))
    WriteCVar("nameplateShowSelf",          Setting("showSelf") and "1" or "0")
    WriteCVar("nameplateMaxDistance",       tostring(Setting("viewDistance") or 60))
end

function M:RestoreCVars()
    if not savedCVars then return end
    for cvar, value in pairs(savedCVars) do
        if value ~= nil then WriteCVar(cvar, value) end
    end
    savedCVars = nil
end

-- Blizzard owns the clickable area; matching it to our box keeps clicks precise (its default
-- is far larger and can target the plate behind).  Three API generations exist; feature-detected.
local savedPlateSize

local function VisualSize()
    local width  = Setting("width")  or 120
    local height = Setting("height") or 4

    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = ns.Media:SnapSize(Setting("nameSize")) + TEXT_GAP
    end

    local castRow = 0
    if Setting("showCast") ~= false then
        castRow = (Setting("castHeight") or 13) + CAST_GAP
    end

    return width, height + textRow + castRow
end

--- Resize Blizzard's plate hitbox to the box this module draws.
function M:ApplyPlateSize()
    if Setting("forcePlateSize") == false then return end
    if InCombatLockdown and InCombatLockdown() then
        -- Protected territory: ns:AfterCombat 排队，脱战补做（失败也留在队列直到成功）。
        ns:AfterCombat("nameplates-plate-size", function() M:ApplyPlateSize() end)
        return
    end

    local width, height = VisualSize()

    if not savedPlateSize and C_NamePlate and C_NamePlate.GetNamePlateSize then
        local ok, w, h = pcall(C_NamePlate.GetNamePlateSize)
        if ok then savedPlateSize = { w, h } end
    end

    if not C_NamePlate then return end

    -- Only the documented setter is used: the API manual lists no per-faction setters, so `SetNamePlateEnemySize` / `FriendlySize` are never borrowed --
    -- borrowing an object from another addon instead of the manual is how one silently fails on the build it runs on.
    if type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, width, height)
    end
end

function M:RestorePlateSize()
    if not savedPlateSize or not C_NamePlate then return end
    if type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, savedPlateSize[1], savedPlateSize[2])
    end
    savedPlateSize = nil
end

-- Blizzard's own driver recomputes plate sizes on CVar/settings change and would put its default
-- back; we want ours to win.
--
-- **绝不能 hooksecurefunc(driver, "UpdateNamePlateOptions")**（以前就是这么写的）：那是往暴雪的
-- 方法槽挂我们的函数，驱动框从此被标脏，而它建出来的每一块姓名板都在"MonetUI 的执行环境"里
-- setup —— 暴雪自己随后的更新就会炸，实机全是 `tainted by 'MonetUI'`：
--   CompactUnitFrame.lua:1211  attempt to compare local 'maxHealth' (a secret number value)
--   CompactUnitFrame.lua:668   attempted to index a table that cannot be indexed with secret keys
--   CastingBarFrame.lua:344    boolean test on local 'notInterruptible' (a secret boolean value)
--   Blizzard_NamePlateAuras.lua:366  boolean test on field 'isFullUpdate' (a secret boolean value)
-- 改成轮询：读客户端当前的牌子尺寸，和我们要的不一致就重设一次（尺寸只在改设置 / 换 CVar 时变，
-- 2 秒限一次，不会刷屏）。
function M:HookDriver()
    if driverHooked then return end
    driverHooked = true

    local lastTry = 0
    Widget:PollWatch(_G.UIParent, function()
        if Setting("forcePlateSize") == false then return end
        if InCombatLockdown and InCombatLockdown() then return end
        if not C_NamePlate or type(C_NamePlate.GetNamePlateSize) ~= "function" then return end
        local ok, w, h = pcall(C_NamePlate.GetNamePlateSize)
        if not ok or type(w) ~= "number" or type(h) ~= "number" then return end
        if Secrets.IsSecret(w) or Secrets.IsSecret(h) then return end
        local wantW, wantH = VisualSize()
        if math.abs(w - wantW) < 0.5 and math.abs(h - wantH) < 0.5 then return end
        local now = _G.GetTime and _G.GetTime() or 0
        if now - lastTry < 2 then return end
        lastTry = now
        M:ApplyPlateSize()
    end)
end

-- Every query is pcall'd: on this client a unit call can be refused outright in
-- a restricted state, and a filter must never take the whole plate down.
local function Query(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- A unit is a friendly player, a friendly npc, or an enemy (player or npc); friendly npcs get
-- their own CVar, so everything hostile lands under the enemy switch ("all enemies").
local function Category(unit)
    local friend = Secrets.Bool(Query(UnitIsFriend, "player", unit), false)
    local player = Secrets.Bool(Query(UnitIsPlayer, unit), false)
    if friend then
        return player and "friendly" or "npc"
    end
    return "enemy"
end

M.Category = Category

local function RuleFor(category)
    if category == "friendly" then return Setting("showFriendly") end
    if category == "enemy"    then return Setting("showEnemy") end
    return Setting("showNPC")
end

--- Is this unit supposed to show a MonetUI plate at all?
function M:ShouldShow(unit)
    if not unit or not Secrets.Bool(Query(UnitExists, unit), false) then
        return false
    end

    if Setting("hideDead") and Secrets.Bool(Query(UnitIsDeadOrGhost, unit), false) then
        return false
    end

    if Setting("hideCritters") ~= false then
        -- Both can come back secret; type() is legal on a secret, == is not, so == is guarded.
        local classification = Query(UnitClassification, unit)
        if type(classification) == "string" and not Secrets.IsSecret(classification)
            and classification == "minus" then
            return false
        end

        local creature = Query(UnitCreatureType, unit)
        if type(creature) == "string" and not Secrets.IsSecret(creature)
            and creature == "Critter" then
            return false
        end
    end

    return RuleFor(Category(unit)) ~= false
end

--- The bar colour: the game's own class / reaction answer, tapped units grey.  UnitSelectionColor
--- covers players and NPCs in one call and never returns a secret, so it survives combat.
local function HealthColor(unit)
    if not Secrets.Bool(Query(UnitIsPlayer, unit), false)
        and Secrets.Bool(Query(UnitIsTapDenied, unit), false) then
        return Color:GetNeutral()
    end

    if Setting("classColor") ~= false then
        local ok, r, g, b = pcall(UnitSelectionColor, unit)
        if ok and type(r) == "number" then return r, g, b end
    end

    local reaction = Secrets.Number(Query(UnitReaction, "player", unit))
    if reaction then
        if reaction >= 5 then
            return 0.31, 0.65, 0.35          -- friendly
        elseif reaction == 4 then
            return 0.85, 0.77, 0.36          -- neutral
        elseif reaction == 3 then
            return 0.82, 0.45, 0.22          -- unfriendly
        end
        return 0.78, 0.25, 0.25              -- hostile
    end

    return Color:GetNeutral()
end

-- Elite / rare / boss marks, the same letters Blizzard's own plates use.
local CLASSIFICATION_MARK = {
    elite = "+", rareelite = "R+", rare = "R", worldboss = "B",
}

local function PlateWidth()  return Setting("width")  or 120 end
local function PlateHeight() return Setting("height") or 4  end

--- One plate: health box, name/level row above, cast bar under -- all off Blizzard's base frame.
local function Build(base)
    local width, height = PlateWidth(), PlateHeight()

    local plate = Widget:CreateFrame(nil, base, width, height)
    Widget:Theme(plate, { thickness = BORDER, bgAlpha = 0.92 })
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)

    local health = Widget:Bar(plate, width - BORDER * 2, height - BORDER * 2)
    health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)

    -- The *missing* health, drawn under the fill: a plain texture (never a
    -- secret), so it gives the bar a dark "lost" body without reading a value.
    local lost = Widget:LostBarBG(health, 0, 0, 0)

    plate.health = health
    plate.healthLost = lost

    local nameSize = ns.Media:SnapSize(Setting("nameSize"))

    plate.name = Widget:Font(plate, nameSize, "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.name:SetWordWrap(false)

    plate.level = Widget:Font(plate, nameSize, "pixel", "neutral", "RIGHT")
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)

    plate.percent = Widget:Font(health, nameSize, "pixel",
        { r = 1, g = 1, b = 1 }, "RIGHT")
    plate.percent:SetPoint("RIGHT", health, "RIGHT", -3, 0)

    local castHeight = Setting("castHeight") or 13
    local cast = Widget:CreateFrame(nil, plate, width, castHeight)
    Widget:Theme(cast, { thickness = BORDER, bgAlpha = 0.92 })
    cast:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 0, -CAST_GAP)

    local fill = Widget:Bar(cast, width - BORDER * 2, castHeight - BORDER * 2)
    fill:SetPoint("TOPLEFT", cast, "TOPLEFT", BORDER, -BORDER)
    fill:SetPoint("BOTTOMRIGHT", cast, "BOTTOMRIGHT", -BORDER, BORDER)

    local iconSize = castHeight - BORDER * 2
    local icon = Widget:Icon(fill, iconSize, "ARTWORK")
    icon:SetPoint("TOPLEFT", cast, "TOPLEFT", BORDER, -BORDER)
    ns.Skin:CropIcon(icon, 0.08, 0.92, 0.08, 0.92)

    local timer = Widget:Font(cast, nameSize, "pixel", "neutral", "RIGHT")
    timer:SetPoint("RIGHT", cast, "RIGHT", -3, 0)

    local text = Widget:Font(cast, nameSize, "pixel",
        { r = 1, g = 1, b = 1 }, "LEFT")
    text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    text:SetPoint("RIGHT", timer, "LEFT", -3, 0)
    text:SetWordWrap(false)

    cast.fill = fill
    cast.icon = icon
    cast.text = text
    cast.timer = timer
    cast:Hide()

    plate.cast = cast
    plate.base = base
    plate.layoutDirty = true

    return plate
end

--- Re-apply geometry and fonts (settings can change at any moment), off the per-event path:
--- a plate lays out only when just built or the player changed a setting (layoutDirty).
local function Layout(plate)
    local width, height = PlateWidth(), PlateHeight()
    local nameSize = ns.Media:SnapSize(Setting("nameSize"))
    local castHeight = Setting("castHeight") or 6

    plate:SetSize(width, height)
    plate.health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    plate.health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)
    plate.health:SetStatusBarTexture(ns.Media:Texture("barfill"))
    -- SetStatusBarTexture builds a NEW texture object, so the fill gradient has to be re-derived here or
    -- the bar comes back unshaded after every relayout.
    Widget:BarGradient(plate.health)

    plate.name:SetShown(Setting("showName") ~= false)
    plate.level:SetShown(Setting("showLevel") ~= false)
    plate.name:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.level:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.percent:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.percent:SetShown(Setting("showPercent") ~= false)

    plate.cast:SetSize(width, castHeight)
    plate.cast.fill:SetStatusBarTexture(ns.Media:Texture("barfill"))
    Widget:BarGradient(plate.cast.fill)
    plate.cast.icon:SetSize(castHeight - BORDER * 2, castHeight - BORDER * 2)
    plate.cast:Hide()

    -- The name stops where the level starts, so a long name never runs under it.
    plate.name:ClearAllPoints()
    plate.level:ClearAllPoints()
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)
    plate.name:SetPoint("RIGHT", plate.level, "LEFT", -4, 0)
end

local function BlizzardUnitFrame(base)
    return base and rawget(base, "UnitFrame") or nil
end

--- Take the plate over: fade Blizzard's box out (kept and still shown, see below) and borrow its aura list;
--- only faded, so a later Restore gives back exactly what the game drew.
--
-- **压暗范围是 base 上的全部子框（除我们自绘牌）**（2026-10-28 实机判例）：只压
-- `base.UnitFrame` 不够 —— base 上还有**同级容器**（实机探针：每块牌子各 1 个
-- StatusBar+Frame 的匿名容器，alpha 1.00，随 base 的距离衰减 alpha 0.60 可见），
-- 有减益时暴雪还会**动态再建**容器（BuffListFrame 一族）。这些 sibling 全都不在
-- UnitFrame 里，alpha 沿树继承救不了它们 → "暴雪牌子没藏掉、和自绘的同屏"。
-- 一并压 0（SetAlpha 非 Hide：C++ 点击区锚在血条/名字上，见下，alpha 不影响命中）。
local siblingFaded = setmetatable({}, { __mode = "k" })   -- 还原时要知道哪些被我们压过

local function FadeBlizzardSiblings(base, keep)
    for _, c in ipairs({ base:GetChildren() }) do
        if c ~= keep and c.SetAlpha then
            siblingFaded[c] = true
            pcall(c.SetAlpha, c, 0)
        end
    end
end

local function RestoreBlizzardSiblings(base)
    for _, c in ipairs({ base:GetChildren() }) do
        if siblingFaded[c] then
            siblingFaded[c] = nil
            pcall(c.SetAlpha, c, 1)
        end
    end
end

local function HideBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if not uf then return false end

    -- **不要 Hide**：本客户端的姓名板点击是 C++ 做的，点击区来自
    -- NamePlateUnitFrameMixin:UpdateHitTestArea 里 SetHitTestPoints 设的那几个点，而它们锚在
    -- 暴雪的血条 / 名字上。把 UnitFrame 藏起来，这些锚点就没有可测的矩形了 —— 表现就是
    -- "点不中玩家 / 宠物，只有没被我们接管的 NPC 才点得中"。只把 alpha 压到 0：
    -- 视觉上一样看不见，但 hit test 仍然有效。
    if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end
    if uf.IsShown and not uf:IsShown() then pcall(uf.Show, uf) end
    FadeBlizzardSiblings(base, plate)

    plate.blizzardUF = uf
    plate.blizzardHidden = true
    return true
end

--- Hand the plate back as found (module off or unit filtered out): the Blizzard box is shown again
--- （光环仍然是它自己的子帧，跟着一起回来 —— 2026-10-26 起我们不再借用它）。
--- **绝不从我们的上下文触碰 ApplyFrameOptions**：它是暴雪的单位帧生产者
--- （ApplyFrameOptions → SetUpFrame → UpdateMaxHealth / UpdateHealPrediction / 写状态条），
--- 调用它时环境里若仍有秘值，一次 secret-compare 被拦就把整条 CUF 生产链标脏，之后
--- 暴雪自己的事件处理逐条爆（taint.log 取证 01:15:42 / 01:21:49 / 01:24:27 / 01:29:14
--- —— 四个版本三次复现：直接调、InCombat 门、引擎事件旗帜 + 全局探针，全部肯别过）。
--- 秘值存活窗口探针测不全（player 明文、姓名板机密同刻并存；flags 关掉仍能读到机密），
--- 所以不再"挑时机"，干脆不打：还原外观只需要 alpha / Show（普通受保护项，被拒只进
--- BLOCKED 日志），游戏自己会在下一次 SetUnit / 更新时跑 ApplyFrameOptions 补齐。
--- @param base Blizzard's nameplate base frame
--- @param plate our plate frame that borrowed `base`'s unit frame (may be nil)
local function RestoreBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if uf then
        if uf.SetAlpha then pcall(uf.SetAlpha, uf, 1) end
        pcall(uf.Show, uf)
    end
    RestoreBlizzardSiblings(base)
    if plate then
        plate.blizzardHidden = nil
        plate.blizzardUF = nil
    end
    return uf ~= nil
end

-- The fill computes only with GetTime() (our own plain number) and hands SetValue a value the
-- client clamps against the secret start/end; the timer text needs math, only when end came plain.
local function CastTick(plate)
    local cast = plate.cast
    if not cast or not plate.castEndMS then return end

    pcall(cast.fill.SetValue, cast.fill, GetTime() * 1000)

    if plate.castEndClock then
        local left = plate.castEndClock - GetTime()
        if left < 0 then left = 0 end
        if left < 10 then
            cast.timer:SetText(string.format("%.1f", left))
        else
            cast.timer:SetText(string.format("%d", math.floor(left + 0.5)))
        end
    else
        cast.timer:SetText("")
    end
end

local function HideCast(plate)
    local cast = plate.cast
    if not cast then return end
    plate.castEndMS = nil
    plate.castEndClock = nil
    plate:SetScript("OnUpdate", nil)
    cast:Hide()
end

--- Read the cast tuple without letting a restricted call break the plate; `type(name) == "nil"`
--- is the safe "is anything being cast"; slots differ: channel puts notInterruptible 7th, cast 8th.
local function CastInfo(channel, unit)
    local fn = channel and UnitChannelInfo or UnitCastingInfo
    if type(fn) ~= "function" then return nil end

    local result = { pcall(fn, unit) }
    if not result[1] then return nil end

    -- `channel and A or B` would truth-test A before selecting; A is a secret under
    -- restriction and the mere test throws.  Pick the slots explicitly.
    local notInterruptible
    if channel then
        notInterruptible = result[7]
    else
        notInterruptible = result[8]
    end
    return result[2], result[4], result[5], result[6], notInterruptible
end

local function UpdateCast(plate)
    local unit = plate.unit
    if not plate.cast then return end
    if Setting("showCast") == false or not unit then return HideCast(plate) end

    local name, texture, startMS, endMS, notInterruptible = CastInfo(false, unit)
    local channel = false
    if type(name) == "nil" then
        name, texture, startMS, endMS, notInterruptible = CastInfo(true, unit)
        channel = true
    end
    if type(name) == "nil" then return HideCast(plate) end

    -- Name and texture go straight to the widgets: SetText / SetTexture accept a secret.
    plate.cast.text:SetText(name)
    if type(texture) ~= "nil" then
        plate.cast.icon:SetTexture(texture)
        plate.cast.icon:Show()
    else
        plate.cast.icon:Hide()
    end

    -- Bars take the raw times; no arithmetic of ours touches them.
    pcall(plate.cast.fill.SetMinMaxValues, plate.cast.fill, startMS or 0, endMS or 1)
    plate.castEndMS = endMS

    -- Plain end => a real countdown; hidden end => bar moves, number blank (see 4.6 in MonetUI.md).
    local endClock = Secrets.Number(endMS)
    plate.castEndClock = endClock and (endClock / 1000) or nil

    if Secrets.Bool(notInterruptible, false) then
        plate.cast.fill:SetStatusBarColor(Color:GetNeutral())
    elseif channel then
        plate.cast.fill:SetStatusBarColor(0.62, 0.62, 0.92)
    else
        plate.cast.fill:SetStatusBarColor(Color:GetResource())
    end

    plate.cast:Show()
    plate:SetScript("OnUpdate", CastTick)
end

local function UpdateHealth(plate)
    local unit = plate.unit

    -- A refused unit call skips the write entirely so the bar keeps its last state (Secrets contract).
    local hp, hpMax = Query(UnitHealth, unit), Query(UnitHealthMax, unit)
    if hp ~= nil and hpMax ~= nil then
        local interpolation = (Setting("smooth") ~= false) and Secrets.SMOOTH or nil
        Secrets.SetBar(plate.health, hp, hpMax, interpolation)
    end

    local r, g, b = HealthColor(unit)
    plate.health:SetStatusBarColor(r, g, b)

    -- Dead / disconnected: the client greys the bar, and the "lost" overlay (no value of its
    -- own) is greyed by hand so a corpse reads as one (same rule as the unit frames).
    local connected = Query(UnitIsConnected, unit)
    if connected == nil then connected = true end   -- refused query reads as connected
    local gone = Secrets.Bool(Query(UnitIsDeadOrGhost, unit), false)
        or not Secrets.Bool(connected, true)
    plate.health:SetStatusBarDesaturated(gone)
    if gone then
        local nr, ng, nb = Color:GetNeutral()
        plate.healthLost:SetVertexColor(nr, ng, nb, 1)
    else
        plate.healthLost:SetVertexColor(0, 0, 0, 1)
    end

    -- Percentage text needs real numbers, so only when the client says health is readable (the
    -- bar always fills); Secrets.Number hands back a plain number or nil, making it safe.
    if Setting("showPercent") ~= false and Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(Query(UnitHealth, unit))
        local maximum = Secrets.Number(Query(UnitHealthMax, unit))
        if current and maximum and maximum > 0 then
            local percent = current / maximum * 100
            plate.percent:SetText(string.format("%d%%", math.floor(percent + 0.5)))
        else
            plate.percent:SetText("")
        end
    else
        plate.percent:SetText("")
    end
end

local function UpdateText(plate)
    local unit = plate.unit

    -- 名字与 "Lv???" 共享一行左右分列：先定 level 段，名字的可用宽要避开它。
    local parts = {}
    if Setting("showLevel") ~= false then
        local level = Secrets.Number(Query(UnitLevel, unit))
        if level and level > 0 then
            parts[#parts + 1] = "Lv" .. level
        elseif level == -1 then
            parts[#parts + 1] = "??"
        end

        local classification = Query(UnitClassification, unit)
        if type(classification) == "string" and not Secrets.IsSecret(classification) then
            local mark = CLASSIFICATION_MARK[classification]
            if mark then parts[#parts + 1] = mark end
        end
    end
    plate.level:SetText(table.concat(parts, " "))

    -- 规则（2026-10-27 玩家定）：名字最多占牌子总宽 70%，超了**缩字号**、绝不截断 ——
    -- 统一走 Widget:FitText（机密名走它内部的"不测不缩"分支，原样显示）。
    -- Setting("truncate"/"nameLength") 保留在设置里但不再读（原截断规则暂不使用）。
    -- level 段比剩余 30% 还宽时再收一档，免得两段挤在一起。
    local name = Query(UnitName, unit)
    local nameSize = ns.Media:SnapSize(Setting("nameSize"))
    if type(name) == "string" then
        local W = PlateWidth()
        local maxWidth = W * 0.70
        local levelW = plate.level:GetStringWidth()
        if levelW > 0 then
            maxWidth = math.min(maxWidth, W - levelW - 4)
        end
        Widget:FitText(plate.name, name, maxWidth, nameSize, nil, 6)
    else
        Widget:FitText(plate.name, "", PlateWidth() * 0.70, nameSize, nil, 6)
    end
end

--- The border says what the unit is doing to you: threat first, then "this is my target".
--- UnitThreatSituation / UnitIsUnit can be secret, so each keeps its previous answer
--- instead of flickering (AGENTS: 受限时保留上次状态).
local function UpdateBorder(plate)
    local unit = plate.unit
    local r, g, b = Color:GetBorder()

    -- 当前目标：金色描边 + 放大 1.1 倍（固定信号，不随主题变）。
    -- UnitIsUnit 受限时返回机密 → 落回"上一次的判定"；用 false 会让战斗中每次刷新
    -- 都把牌子缩回 1.0、金边闪一下。
    local isTarget = false
    if Setting("highlightTarget") ~= false then
        isTarget = Secrets.Bool(Query(UnitIsUnit, unit, "target"), plate.isTarget or false)
    end
    plate.isTarget = isTarget

    local scale = isTarget and TARGET_SCALE or 1
    if plate.targetScale ~= scale then
        plate.targetScale = scale
        plate:SetScale(scale)
    end

    -- 仇恨状态：UnitThreatSituation 受限时返回机密值。**机密就保留上一次的判定**
    -- （AGENTS：受限时保留上次状态）—— 以前走 Secrets.Number，机密时拿到 nil、status 变 nil，
    -- 边框落回默认色，战斗中就是"红边一直闪灭"（review 2026-10-29 H16）。
    -- 脱战后它返回**普通 nil**（表示没有该信息），那不是机密，按 0 处理，红边才会正常消失。
    local status
    if Setting("showThreat") ~= false then
        local raw = Query(UnitThreatSituation, "player", unit)
        if Secrets.IsSecret(raw) then
            status = plate.threatStatus   -- 保留上次
        else
            status = Secrets.Number(raw) or 0
        end
    end
    plate.threatStatus = status

    if status == 3 then
        r, g, b = 0.90, 0.20, 0.20
    elseif status == 2 or status == 1 then
        r, g, b = 0.95, 0.70, 0.25
    elseif isTarget then
        r, g, b = TARGET_GOLD[1], TARGET_GOLD[2], TARGET_GOLD[3]
    end

    if plate.SetBackdropBorderColor then
        plate:SetBackdropBorderColor(r, g, b, 1)
    end
    if plate.cast and plate.cast.SetBackdropBorderColor then
        plate.cast:SetBackdropBorderColor(r, g, b, 1)
    end
end

--- Blizzard can show its own UnitFrame again on any update; keep it faded (never hidden — the
--- C++ nameplate hit test is anchored to its bars, see HideBlizzardPlate).
--- sibling 容器一并回压：暴雪更新会重设它们的 alpha，**有减益时还会动态新 建 sibling 容器**
--- （alpha 沿树继承救不了它们，和背包"晚生子框"同一课）—— 每拍整树补压。
local function KeepBlizzardHidden(plate)
    local uf = plate.blizzardUF
    if not uf then return end
    if uf.IsShown and not uf:IsShown() then pcall(uf.Show, uf) end
    if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end
    FadeBlizzardSiblings(plate.base, plate)
end

-- ---- 目标高亮回压守卫（2026-10-28 实机判例）--------------------------------------
-- 牌子成为**当前目标**时，暴雪自己的更新把 UnitFrame 的 alpha 重设回 1（目标高亮，
-- base alpha 同时到 1.0）。我们的回压只挂在 UpdatePlate（事件驱动）里，目标切换那一刻
-- 暴雪抢先、之后就没人再压 —— 表现是"当前目标的暴雪牌整块亮着，和自绘牌同屏"，
-- 它右侧的减益列也跟着回来（探针实锤：假人牌 blizzardHidden=true 但 ufAlpha=1.00）。
-- 低频守卫对全部 blizzardHidden 的牌子整树回压；PLAYER_TARGET_CHANGED 再补一记即时的。
local guardDriver, guardAcc = nil, 0
local GUARD_INTERVAL = 0.25

local function StartGuard()
    if guardDriver then return end
    guardDriver = CreateFrame("Frame")
    guardDriver:SetScript("OnUpdate", function(_, elapsed)
        if not M.active then return end
        guardAcc = guardAcc + (elapsed or 0)
        if guardAcc < GUARD_INTERVAL then return end
        guardAcc = 0
        for _, plate in pairs(plates) do
            if plate.blizzardHidden and plate.base then
                KeepBlizzardHidden(plate)
            end
        end
    end)
end

local function UpdatePlate(plate)
    local unit = plate.unit
    if not unit or not Secrets.Bool(Query(UnitExists, unit), false) then
        plate:Hide()
        return false
    end

    if not M:ShouldShow(unit) then
        -- Filtered out: give the unit the plate the game would have drawn (widgets,
        -- soft-target icon, Blizzard's own look) and stand down.
        if plate.blizzardHidden then RestoreBlizzardPlate(plate.base, plate) end
        plate:Hide()
        HideCast(plate)
        return false
    end

    if not plate.blizzardHidden then
        HideBlizzardPlate(plate.base, plate)
    else
        KeepBlizzardHidden(plate)
    end

    -- **接管失败就别画我们这块**（2026-10-25 实机：同一只怪出现两块牌子 —— 暴雪的牌子
    -- 右端显示冰冻陷阱，我们的牌子左上显示猎人标记）。拿不到暴雪 UnitFrame 时我们无法把它
    -- 压暗，两块就会叠在屏幕上；此时宁可退回暴雪原生那一块。
    if not plate.blizzardHidden then
        plate:Hide()
        HideCast(plate)
        return false
    end

    if plate.layoutDirty then
        Layout(plate)
        plate.layoutDirty = nil
    end

    plate:Show()
    UpdateHealth(plate)
    UpdateText(plate)
    UpdateBorder(plate)
    UpdateCast(plate)
    return true
end

M.UpdatePlate = UpdatePlate

function M:UpdateAll()
    for _, plate in pairs(plates) do
        UpdatePlate(plate)
    end
end

-- One handler on the plate; unit events register per plate with RegisterUnitEvent, so only
-- on-screen plates cost anything.
local PLATE_EVENTS = {
    UNIT_HEALTH = true, UNIT_MAXHEALTH = true,
    UNIT_NAME_UPDATE = true, UNIT_LEVEL = true,
    UNIT_FACTION = true, UNIT_CONNECTION = true,
}

local THREAT_EVENTS = {
    UNIT_THREAT_SITUATION_UPDATE = true, UNIT_THREAT_LIST_UPDATE = true,
}

local CAST_EVENTS = {
    UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_STOP = true,
    UNIT_SPELLCAST_FAILED = true, UNIT_SPELLCAST_INTERRUPTED = true,
    UNIT_SPELLCAST_DELAYED = true, UNIT_SPELLCAST_CHANNEL_START = true,
    UNIT_SPELLCAST_CHANNEL_UPDATE = true, UNIT_SPELLCAST_CHANNEL_STOP = true,
    UNIT_SPELLCAST_INTERRUPTIBLE = true, UNIT_SPELLCAST_NOT_INTERRUPTIBLE = true,
}

local UNIT_EVENTS = {
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_LEVEL",
    "UNIT_FACTION", "UNIT_CONNECTION",
    "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local function OnPlateEvent(plate, event)
    if not plate.unit or not plates[plate.unit] then return end

    if CAST_EVENTS[event] then
        if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
            or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            -- The cast that just ended can still read back stale, so the end comes from the
            -- event, not a fresh query.
            HideCast(plate)
        else
            UpdateCast(plate)
        end
        return
    end

    if THREAT_EVENTS[event] then
        UpdateBorder(plate)
        return
    end

    if PLATE_EVENTS[event] then
        UpdatePlate(plate)
    end
end

--- Attach to the base frame Blizzard gave this unit.
local function Added(unit)
    local base = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and Query(C_NamePlate.GetNamePlateForUnit, unit) or nil
    if not base then return nil end

    local plate = Marked(base, "plate")
    if not plate then
        plate = Build(base)
        Mark(base, "plate", plate)
        plate:SetScript("OnEvent", OnPlateEvent)
    end

    plate.unit = unit
    plate:ClearAllPoints()
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)
    plate:SetFrameLevel(base:GetFrameLevel() + 1)
    -- 同一个 base 会被池子换给另一个单位：目标判定/缩放/仇恨色从头来，别继承上一只的。
    plate.isTarget = nil
    plate.targetScale = nil
    plate.threatStatus = nil

    for _, event in ipairs(UNIT_EVENTS) do
        plate:RegisterUnitEvent(event, unit)
    end

    plates[unit] = plate
    UpdatePlate(plate)
    return plate
end

M.Added = Added

local function Removed(unit)
    local plate = plates[unit]
    if not plate then return false end

    plates[unit] = nil
    plate.unit = nil
    plate:UnregisterAllEvents()
    plate:SetScript("OnUpdate", nil)
    plate.castEndMS = nil
    plate.castEndClock = nil
    plate:Hide()
    plate.cast:Hide()
    return true
end

M.Removed = Removed

function M:RegisterEvents()
    if self.eventsRegistered then return end
    self.eventsRegistered = true

    EventBus:Register("NAME_PLATE_UNIT_ADDED", function(_, unit)
        if not M.active then return end
        Added(unit)
    end)

    EventBus:Register("NAME_PLATE_UNIT_REMOVED", function(_, unit)
        if not M.active then return end
        Removed(unit)
    end)

    -- A new target re-tints every plate's border; 换目标同时会把新目标的暴雪牌点亮
    -- （目标高亮重设 UnitFrame alpha，见上面的守卫注释）—— 这里即时回压一记。
    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        if not M.active then return end
        for _, plate in pairs(plates) do
            if plate.blizzardHidden and plate.base then KeepBlizzardHidden(plate) end
            UpdateBorder(plate)
        end
    end)

    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if not M.active then return end
        M:HookDriver()
        M:ApplyPlateSize()
        M:AbsorbExisting()
        M:UpdateAll()
    end)

    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if not M.active then return end
        -- 被挡的牌子尺寸改写已由 ns:AfterCombat 排队补做。
        M:UpdateAll()
    end)

    -- Once a restriction lifts the numbers come back.
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function()
        if not M.active then return end
        M:UpdateAll()
    end)

    -- The theme listener in Utils/Widget.lua runs first (registered at load), so borders are
    -- re-tinted here after it, in the same tick.
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not M.active then return end
        M:UpdateAll()
    end)
end

--- Pick up plates already up when the module (re)loaded: nameplate tokens run in a fixed
--- range, so asking for each and attaching to whatever exists is enough.
function M:AbsorbExisting()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Secrets.Bool(Query(UnitExists, unit), false) then
            Added(unit)
        end
    end
end

--- Re-apply every setting: CVars, hitbox, then repaint the plates on screen.
--- 每块牌子先"交还暴雪"再由下一轮 UpdatePlate 重新接管：尺寸 / 字号 / 显隐这类结构改动
--- 只有重建（Restore → Hide）才吃得到。
function M:Apply()
    if not ns:IsModuleEnabled("Nameplates") then return end

    for _, plate in pairs(plates) do
        plate.layoutDirty = true
        if plate.blizzardHidden and plate.base then
            RestoreBlizzardPlate(plate.base, plate)
        end
    end

    self:ApplyCVars()
    self:ApplyPlateSize()
    self:HookDriver()
    self:UpdateAll()
end

function M:Initialize()
    self.active = true
    -- 诊断口：`/mui` 探针要读当前名牌表（plates 是文件局部，改这里不导入其它引用）。
    self.plates = plates
    self:RegisterEvents()
    self:HookDriver()
    self:ApplyCVars()
    self:ApplyPlateSize()
    self:AbsorbExisting()
end

--- Turning the module off is a real handover: plates go back to Blizzard, and every CVar and
--- the plate size the module steered are restored.
function M:SetEnabled(enabled)
    enabled = enabled and true or false

    if enabled then
        self.active = true
        self:RegisterEvents()
        self:HookDriver()
        self:ApplyCVars()
        self:ApplyPlateSize()
        self:AbsorbExisting()
        self:UpdateAll()
        StartGuard()
        return
    end

    self.active = false
    for unit, plate in pairs(plates) do
        if plate.base then RestoreBlizzardPlate(plate.base, plate) end
        plate.unit = nil
        plate:UnregisterAllEvents()
        plate:SetScript("OnUpdate", nil)
        plate:Hide()
        plate.cast:Hide()
        plates[unit] = nil
    end

    self:RestoreCVars()
    self:RestorePlateSize()
end

-- Which objects this module assumes exist on *this* client: functions check against the API
-- manual, frames do not -- so the probe asks the running client (compare `/mui skins diagnose`).
local PROBED = {
    "C_NamePlate",
    "C_NamePlate.GetNamePlateForUnit",
    "C_NamePlate.GetNamePlateSize",
    "C_NamePlate.SetNamePlateSize",
    "NamePlateDriverFrame",
    "NamePlateDriverFrame.UpdateNamePlateOptions",
}

function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub ~= "diagnose" and sub ~= "diag" and sub ~= "probe" then return false end

    ns:Print("姓名板对象自检（本客户端实测）：")
    local missing = 0
    for i = 1, #PROBED do
        if ns.ResolvePath(PROBED[i]) then
            ns:Print(("|cff88ff88✓|r %s"):format(PROBED[i]))
        else
            missing = missing + 1
            ns:Print(("|cffff6b6b✗|r %s（缺失）"):format(PROBED[i]))
        end
    end

    if missing == 0 then
        ns:Print("全部存在。")
    else
        ns:Print(string.format("%d 个缺失：全部已按特性探测跳过，不会报错；"
            .. "`NamePlateDriverFrame` 缺失时点击区仍会在设置/区域变化时重设。", missing))
    end
    return true
end

ns:Register("Nameplates", M)
