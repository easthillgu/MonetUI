-- Modules/Nameplates/Nameplates.lua
-- Nameplates (姓名板) in the Monet slim-bar style: our own bar hung on Blizzard's base plate
-- with their native visuals faded out (the Andromeda / ElvUI / Plater approach, no oUF).
-- Bars and aura containers are fed raw (possibly secret) values.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local EventBus = ns.EventBus

local M = { name = "Nameplates" }

--- 战斗中为真。**优先问 Core 的 `ns:InCombat()`**：本客户端先派发 PLAYER_REGEN_*、之后才翻
--- `InCombatLockdown()`，而 `ns:AfterCombat` 的排空就跑在那次派发里 —— 拿原始标志当门，
--- 牌子尺寸会把自己再排回队列（"改完尺寸第一次脱战不生效，要再打一场")。
local function InCombat()
    if type(ns.InCombat) == "function" then return ns:InCombat() end
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

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
-- 团队标记用暴雪自带的 4×4 图标表：索引原样交给 SetSpriteSheetCell，不在 Lua 里比较。
local RAID_ICON_SIZE   = 14
local RAID_ICON_SHEET  = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local RAID_SHEET_CELLS = 4

-- ============================================================================
-- 引擎时长 / 曲线（NDui 同源机制，2026-11-22 引入）
-- ----------------------------------------------------------------------------
-- 战斗中施法数据是机密：时间戳相减、`if endTime` 都会被拦，所以倒计时与填充交给客户端：
--   * StatusBar:SetTimerDuration(durationObject) —— 引擎自己逐帧推进；
--   * C_DurationUtil 的 DurationTextBinding —— 自己把文字刷进 FontString（机密期照走）。
-- 名字颜色同理：UnitHealthPercent(unit, true, 我们自己的颜色曲线) 返回已求值的颜色对象，
-- 直接 SetTextColor，不做算术。
-- 全部特性探测：构建没有这些 API 时整条退回原来的时钟算法。
local castFormatter
if type(_G.C_StringUtil) == "table" and type(C_StringUtil.CreateSecondsFormatter) == "function" then
    local ok, f = pcall(C_StringUtil.CreateSecondsFormatter)
    if ok and f then
        castFormatter = f
        local E = _G.Enum
        if E and E.SecondsFormatterAbbreviation and E.SecondsFormatterAbbreviation.OneLetter then
            pcall(f.SetDefaultAbbreviation, f, E.SecondsFormatterAbbreviation.OneLetter)
        end
        pcall(f.SetMillisecondsThreshold, f, 60)
    end
end

-- 名字血量曲线：满血绿 → 半血黄 → 低血红。曲线必须在**加载期**建（运行期建曲线在受限环境会被拒）。
local healthCurve
if type(_G.C_CurveUtil) == "table" and type(C_CurveUtil.CreateColorCurve) == "function" then
    local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
    if ok and curve then
        local E = _G.Enum
        if E and E.LuaCurveType and E.LuaCurveType.Linear then
            pcall(curve.SetType, curve, E.LuaCurveType.Linear)
        end
        pcall(curve.AddPoint, curve, 0, CreateColor(1, 0.25, 0.25))
        pcall(curve.AddPoint, curve, 0.6, CreateColor(1, 0.85, 0.30))
        pcall(curve.AddPoint, curve, 1, CreateColor(0.35, 0.95, 0.45))
        healthCurve = curve
    end
end
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

--- 每个 CVar 一行账，`/mui nameplates probe cvar` 读的就是它。
--- 以前 `WriteCVar` 把 pcall 的结果直接丢掉，8 个 `nameplateShow*` 里只要有**一个**写不进去，
--- 对应的设置项就是长期空转、一行红字都不响 —— 没人会知道。
local cvarLedger = {}
local cvarWarned = {}

local function Text(value)
    -- 从游戏拿来的值要进字符串（concat / format）之前必须再过一次机密判断：`type()` 判不出来。
    if value == nil then return "-" end
    if Secrets.IsSecret(value) then return "机密" end
    return tostring(value)
end

local function ReadCVar(cvar)
    if not GetCVar then return nil end
    local ok, value = pcall(GetCVar, cvar)
    if ok then return value end
    return nil
end

--- 客户端对"这个 CVar 插件能不能写"给了正规问法：`C_CVar.GetCVarInfo(name)` 返回
--- value, defaultValue, isStoredServerAccount, isStoredServerCharacter,
--- isLockedFromUser, isSecure, isReadOnly（快照 `cvardocumentation.lua:91-100`），
--- 而 `C_CVar.SetCVar` 的前置条件写着 `RequiresNonSecureCVar` ——
--- **`isSecure` 的 CVar 我们连写都写不进**，与在不在战斗无关（8.26.6 第 2 条）。
--- @return table|nil { value, default, locked, secure, readonly }；nil = 客户端没答
local function CVarInfo(cvar)
    if not (C_CVar and type(C_CVar.GetCVarInfo) == "function") then return nil end
    local ok, value, default, _, _, locked, secure, readonly = pcall(C_CVar.GetCVarInfo, cvar)
    if not ok then return nil end
    return { value = value, default = default, locked = locked,
             secure = secure, readonly = readonly }
end

local function CVarRecord(cvar)
    local rec = cvarLedger[cvar]
    if not rec then
        rec = {}
        cvarLedger[cvar] = rec
    end
    return rec
end

--- 同一个 CVar 只记一条；**打印改聚合**（FlushCVarNotes）：1.60 实测一次登录就印出
--- `nameplateShowEnemyMinus / nameplateShowEnemyTotems / nameplateMaxDistance` 三条
--- "空转"，玩家看到的是"这插件一开机就抱怨三件事"。信息要留，但一条说完。
local cvarNotes = {}
local function CVarFlag(cvar, note)
    local rec = CVarRecord(cvar)
    rec.note = note
    if not cvarWarned[cvar] then
        cvarWarned[cvar] = true
        cvarNotes[#cvarNotes + 1] = cvar
    end
end

--- 一轮批量写入结束后统一提示（没有受阻项就一个字都不印）。
local function FlushCVarNotes()
    local n = #cvarNotes
    if n == 0 then return end
    local names = table.concat(cvarNotes, "、")
    -- 上限：只列前 3 个名字，其余给数量（聊天框一行装不下 8 个 CVar 名）
    if n > 3 then
        names = table.concat(cvarNotes, "、", 1, 3) .. (" 等 %d 项"):format(n)
    end
    ns:DevPrint(("|cffffa940姓名板有 %d 项设置客户端不让插件改（isSecure）：%s|r —— "
        .. "需要生效请在暴雪自己的设置里调；细账 /mui nameplates cvars"):format(n, names))
    cvarNotes = {}
end

--- @return boolean 写进去了 / 本来就是那个值
local function WriteCVar(cvar, value)
    -- 期望值来自我们自己的表达式，但"调用点漏了一个 nil"会写成字符串 "nil" ——
    -- 那是真会把客户端设置改坏的，边界上拦一下。
    if value == nil then return false end
    local want = tostring(value)
    local info = CVarInfo(cvar)
    local cur = (info and info.value) or ReadCVar(cvar)
    local rec = CVarRecord(cvar)
    rec.want, rec.got = want, cur

    -- 先读后写（BTP `Core.lua:149` 同一写法）：常态下这 8 个值一个都没变，一笔都不该落。
    if type(cur) == "string" and not Secrets.IsSecret(cur) and cur == want then
        rec.note = "已是"
        return true
    end

    if info and (info.secure or info.readonly or info.locked) then
        CVarFlag(cvar, info.secure and "客户端拒写（isSecure，插件无权改）"
                       or info.readonly and "只读（isReadOnly）"
                       or "玩家已锁定（isLockedFromUser）")
        return false
    end

    if not SetCVar then return false end
    local ok, err = pcall(SetCVar, cvar, want)
    if not ok then
        CVarFlag(cvar, "写入被拒：" .. Text(err))
        return false
    end

    -- 不报错不等于写进去了：secure / read-only 那一类可能就是"静默收下、值不动"。复验一次。
    local after = ReadCVar(cvar)
    if type(after) == "string" and not Secrets.IsSecret(after) and after ~= want then
        CVarFlag(cvar, "写了没生效（复验仍是 " .. Text(after) .. "）")
        return false
    end
    rec.note = "已写"
    return true
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
    WriteCVar("nameplateMaxDistance",       tostring(Setting("viewDistance") or 40))
    FlushCVarNotes()
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
    if InCombat() then
        -- Protected territory: ns:AfterCombat 排队，脱战补做（失败也留在队列直到成功）。
        ns:AfterCombat("nameplates-plate-size", function() M:ApplyPlateSize() end)
        return
    end

    local width, height = VisualSize()

    if not savedPlateSize and C_NamePlate and C_NamePlate.GetNamePlateSize then
        local ok, w, h = pcall(C_NamePlate.GetNamePlateSize)
        -- 原值只在 RestorePlateSize 里原样交回去：机密就别存（存了也只能原样传，
        -- 反而让"保存的原样"变成一串读不出来的值）。
        if ok and not Secrets.IsSecret(w) and not Secrets.IsSecret(h) then
            savedPlateSize = { w, h }
        end
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
        if InCombat() then return end
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
    -- 令牌先过两道：`type()` 判不出机密（机密串的 type 照样是 "string"），之后它还要进
    -- Query / 当表键，所以守卫必须前置。
    if type(unit) ~= "string" or Secrets.IsSecret(unit) then return false end

    if not Secrets.Bool(Query(UnitExists, unit), false) then
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

    -- 白字一律走 "white" 颜色键（Widget:PaletteColor 的恒定纯白档），不再手写 {1,1,1}。
    plate.name = Widget:Font(plate, nameSize, "pixel", "white", "LEFT")
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.name:SetWordWrap(false)

    plate.level = Widget:Font(plate, nameSize, "pixel", "neutral", "RIGHT")
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)

    -- 挂在牌子右侧、等级之外：不遮名字 / 等级，也不跟下面的施法条抢地方。
    local raidIcon = plate:CreateTexture(nil, "OVERLAY", nil, 2)
    raidIcon:SetTexture(RAID_ICON_SHEET)
    raidIcon:SetSize(ns.Media:SnapUnit(RAID_ICON_SIZE), ns.Media:SnapUnit(RAID_ICON_SIZE))
    raidIcon:SetPoint("BOTTOMLEFT", plate, "TOPRIGHT", 4, TEXT_GAP)
    raidIcon:Hide()
    plate.raidIcon = raidIcon

    plate.percent = Widget:Font(health, nameSize, "pixel", "white", "RIGHT")
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

    -- 引擎倒计时：DurationTextBinding 自己把剩余秒数刷进 timer（战斗机密期照常走；
    -- 旧路径要 endTime - GetTime()，机密时只能空白）。特性探测，缺 API 时退回原时钟算法。
    if type(_G.C_DurationUtil) == "table" and type(C_DurationUtil.CreateDurationTextBinding) == "function" then
        local okB, binding = pcall(C_DurationUtil.CreateDurationTextBinding)
        if okB and binding and type(binding.SetFontString) == "function" then
            local E = _G.Enum
            if castFormatter and E and E.DurationTextBindingProperty and type(binding.SetTextFormat) == "function" then
                pcall(binding.SetTextFormat, binding, "{}", {
                    { property = E.DurationTextBindingProperty.RemainingDuration, formatter = castFormatter },
                })
            elseif castFormatter and type(binding.SetFormatter) == "function" then
                pcall(binding.SetFormatter, binding, castFormatter)
            end
            if pcall(binding.SetFontString, binding, timer) then
                pcall(binding.SetEnabled, binding, false)
                timer.binding = binding
            end
        end
    end

    -- 「对你施法」：布尔交给 SetAlphaFromBoolean（允许污染代码传机密），战斗里不做真值测试。
    local isYou = Widget:Font(cast, nameSize, "pixel", "danger", "RIGHT")
    isYou:SetPoint("RIGHT", timer, "LEFT", -3, 0)
    isYou:SetText("对你")
    isYou:SetAlpha(0)

    local text = Widget:Font(cast, nameSize, "pixel", "white", "LEFT")
    text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    text:SetPoint("RIGHT", isYou, "LEFT", -3, 0)
    text:SetWordWrap(false)

    -- B3 打断/失败短文字：红闪期间顶替法术名居中显示（同宽约束，不遮图标/倒计时位）。
    local flashText = Widget:Font(cast, nameSize, "pixel", "danger", "CENTER")
    flashText:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    flashText:SetPoint("RIGHT", isYou, "LEFT", -3, 0)
    flashText:SetWordWrap(false)
    flashText:Hide()

    -- B2 不可打断盾徽：复用 monet_combat_shield 灰阶模具，压在图标右下角，
    -- 法术名从图标右缘 +3 起画，盾徽不会遮到它。
    local shield = cast:CreateTexture(nil, "OVERLAY", nil, 3)
    shield:SetTexture(ns.Media:Texture("monet_combat_shield"))
    shield:SetVertexColor(0.92, 0.92, 0.95, 1)
    shield:SetSize(iconSize * 0.7, iconSize * 0.7)
    shield:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    shield:Hide()

    -- B1 三角火花：复用 CastBar.lua 的双层模具机制（monet_spark_up 尖端在贴图顶边），
    -- 挂在条下沿、尖端顶住填充前沿；位置由现有 CastTick 驱动，不新增每帧驱动。
    local mult = ns.Media:Mult() or 1
    local spark = CreateFrame("Frame", nil, cast)
    spark:SetSize(6 * mult, 3 * mult)
    local sparkEdge = spark:CreateTexture(nil, "OVERLAY", nil, 1)
    sparkEdge:SetTexture(ns.Media:Texture("monet_spark_up"))
    sparkEdge:SetVertexColor(0.10, 0.03, 0.03, 1)
    sparkEdge:SetAllPoints()
    local sparkFill = spark:CreateTexture(nil, "OVERLAY", nil, 2)
    sparkFill:SetTexture(ns.Media:Texture("monet_spark_up"))
    sparkFill:SetVertexColor(1, 1, 1, 1)
    sparkFill:SetPoint("CENTER", spark, "CENTER", 0, 0)
    sparkFill:SetSize(4 * mult, 2 * mult)   -- 芯比描边小一圈（同 CastBar.lua 的比例）
    spark.edge, spark.fill = sparkEdge, sparkFill
    spark:SetPoint("TOP", cast, "BOTTOMLEFT", BORDER, 1)
    spark:Hide()

    cast.fill = fill
    cast.icon = icon
    cast.text = text
    cast.timer = timer
    cast.isYou = isYou
    cast.flashText = flashText
    cast.shield = shield
    cast.spark = spark
    cast:Hide()

    plate.cast = cast
    plate.base = base
    plate.layoutDirty = true

    return plate
end

--- Re-apply geometry and fonts (settings can change at any moment), off the per-event path:
--- a plate lays out only when just built or the player changed a setting (layoutDirty).
local SyncPlateAuraLayout
local function Layout(plate)
    local width, height = PlateWidth(), PlateHeight()
    local nameSize = ns.Media:SnapSize(Setting("nameSize"))
    local castHeight = Setting("castHeight") or 6

    plate:SetSize(width, height)
    plate.health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    plate.health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)
    -- 剖面渐变烤在贴图里；按条高选版本（细条 = 上亮下暗的单向剖面）。重排改了条高，
    -- 所以每次重排都重设一次 —— 走 Widget:SyncBarFill（它会同步 fillKey 标记，
    -- 标记和实际贴图对不上的话，Widget:Size 那侧的去重就会跳过真正该做的切换）。
    Widget:SyncBarFill(plate.health, height - BORDER * 2)

    plate.name:SetShown(Setting("showName") ~= false)
    plate.level:SetShown(Setting("showLevel") ~= false)
    plate.name:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.level:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.percent:SetFont(ns.Media:FontFor("pixel", nameSize), nameSize, ns.Media:EffectiveFlags(ns.Media.fontFlags, nameSize))
    plate.percent:SetShown(Setting("showPercent") ~= false)

    local iconSize = ns.Media:SnapUnit(RAID_ICON_SIZE)
    plate.raidIcon:SetSize(iconSize, iconSize)
    plate.raidIcon:ClearAllPoints()
    plate.raidIcon:SetPoint("BOTTOMLEFT", plate, "TOPRIGHT", 4, TEXT_GAP)

    plate.cast:SetSize(width, castHeight)
    Widget:SyncBarFill(plate.cast.fill, castHeight - BORDER * 2)
    plate.cast.icon:SetSize(castHeight - BORDER * 2, castHeight - BORDER * 2)
    -- 火花/盾徽随重排同步：火花按物理像素定尺寸并钉回起点，盾徽按图标比例。
    local mult = ns.Media:Mult() or 1
    plate.cast.spark:SetSize(6 * mult, 3 * mult)
    plate.cast.spark.edge:SetSize(6 * mult, 3 * mult)
    plate.cast.spark.fill:SetSize(4 * mult, 2 * mult)
    plate.cast.spark:ClearAllPoints()
    plate.cast.spark:SetPoint("TOP", plate.cast, "BOTTOMLEFT", BORDER, 1)
    plate.cast.shield:SetSize((castHeight - BORDER * 2) * 0.7, (castHeight - BORDER * 2) * 0.7)
    plate.cast:Hide()

    -- The name stops where the level starts, so a long name never runs under it.
    plate.name:ClearAllPoints()
    plate.level:ClearAllPoints()
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)
    plate.name:SetPoint("RIGHT", plate.level, "LEFT", -4, 0)
    -- 上面那记 SetFont 把名字框的字号打回基准档，UpdateText 里 FitText 缩档的结果随之失效：
    -- 必须让排版缓存判据作废，否则下一次 UpdateText 认为"什么都没变"就跳过，
    -- 长名字会以基准字号溢出（而不是按规则缩字号）。level 的文字 SetFont 不会清，判据留着。
    plate.fitName, plate.fitLevel, plate.fitMaxW, plate.fitSize = nil, nil, nil, nil
    if SyncPlateAuraLayout then SyncPlateAuraLayout(plate) end
end

local function BlizzardUnitFrame(base)
    return base and rawget(base, "UnitFrame") or nil
end

--- 读一个暴雪对象的 alpha：读不出来（机密 / forbidden / 没有这个方法）返回 nil。
--- @return number|nil
local function AlphaOf(obj)
    if not obj or type(obj.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(obj.GetAlpha, obj)
    if not ok or type(value) ~= "number" or Secrets.IsSecret(value) then return nil end
    return value
end

--- 这一拍要不要压回 0。已知节点逐帧复查，已经是 0 就跳过写入。
--- **读不出来时照旧写**：暴雪把 alpha 顶回 1 的正是在战斗中，那时"读不到"很可能只是
--- "现在不许我判断"，当成"不用写"就等于把 2026-10-28 的实机判例（当前目标的暴雪牌
--- `blizzardHidden=true` 但 `ufAlpha=1.00`，和自绘牌同屏）又放回来。宁可多写一次。
local function NeedsFade(obj)
    local a = AlphaOf(obj)
    return a == nil or a ~= 0
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
-- 原生节点按 base 记账：UnitFrame 来自框体池，同一块牌换单位时可能已经换成另一个对象。
-- 只记在我们确实压过的节点上，交还时恢复它自己的 alpha，不把暴雪距离衰减统一顶成 1。
local fadedNodes = setmetatable({}, { __mode = "k" })       -- obj -> { base, alpha }
local pendingRestores = setmetatable({}, { __mode = "k" })  -- base -> true
local restoreRetryAt = setmetatable({}, { __mode = "k" })   -- base -> guard clock

--- `GetChildren` 返回的是**多返回值**不是表，必须包表；包表统一走 Widget:ChildrenOf。
local function ChildrenOf(frame)
    local _, kids = ns.Widget:ChildrenOf(frame)
    return kids
end

local function RegionsOf(frame)
    return { frame:GetRegions() }
end

local function FadeNativeNode(obj, base, plate, deep)
    if not obj or obj == plate or type(obj.SetAlpha) ~= "function" then return end
    local rec = fadedNodes[obj]
    if rec then
        -- 框体池把节点交给另一块牌时，还原责任跟着节点走，旧 base 不再能改它。
        rec.base = base
    elseif not NeedsFade(obj) then
        return
    else
        rec = { base = base, alpha = AlphaOf(obj) }
        fadedNodes[obj] = rec
    end

    -- 声明 ignoreParentAlpha 的深层节点不受 UnitFrame alpha=0 约束，必须进逐帧列表。
    local fast = not deep
    if deep and type(obj.IsIgnoringParentAlpha) == "function" then
        local ok, ignores = pcall(obj.IsIgnoringParentAlpha, obj)
        fast = ok and Secrets.Bool(ignores, false)
    end
    local list = fast and plate.fastFaded or plate.deepFaded
    local seen = fast and plate.fastSeen or plate.deepSeen
    if not seen[obj] then
        seen[obj] = true
        list[#list + 1] = obj
    end
    if NeedsFade(obj) then pcall(obj.SetAlpha, obj, 0) end
end

-- UnitFrame 的 selectionHighlight 等子件声明了 ignoreParentAlpha，根 alpha=0 挡不住它们。
-- 首次接管与低频补扫递归覆盖帧和 region；逐帧只复查已知快节点。
local function FadeNativeTree(frame, base, plate, depth)
    if not frame or frame == plate then return end
    if type(frame.GetChildren) == "function" then
        local ok, kids = pcall(ChildrenOf, frame)
        if ok and type(kids) == "table" then
            for i = 1, #kids do
                local child = kids[i]
                if child ~= plate then
                    FadeNativeNode(child, base, plate, depth > 0)
                    FadeNativeTree(child, base, plate, depth + 1)
                end
            end
        end
    end
    if type(frame.GetRegions) == "function" then
        local ok, regions = pcall(RegionsOf, frame)
        if ok and type(regions) == "table" then
            for i = 1, #regions do
                FadeNativeNode(regions[i], base, plate, true)
            end
        end
    end
end

local function FadeBlizzardTree(base, plate)
    FadeNativeTree(base, base, plate, 0)
end

local function RestoreNativeBase(base)
    local objects = {}
    for obj, rec in pairs(fadedNodes) do
        if rec.base == base then objects[#objects + 1] = obj end
    end
    local failed = false
    for i = 1, #objects do
        local obj = objects[i]
        local rec = fadedNodes[obj]
        local want = rec and rec.alpha ~= nil and rec.alpha or 1
        local ok = pcall(obj.SetAlpha, obj, want)
        local after = AlphaOf(obj)
        -- 读得出来才要求"写进去的值就在那儿"；**读不出来（机密 / 受限）不能当失败**
        -- ——否则战斗中每块离场的牌都变成永远还不掉的重试账（2026-11-26 实机：待还原
        -- 3→6 随打怪单调增长，而 GuardTick 每 0.25s 白试一次）。SetAlpha 成功就算还了，
        -- 真被拒（pcall 失败）才留给守卫重试。
        if ok and (after == nil or after == want) then
            fadedNodes[obj] = nil
        else
            failed = true
        end
    end
    if failed then
        pendingRestores[base] = true
    else
        pendingRestores[base] = nil
        restoreRetryAt[base] = nil
    end
    return not failed
end

local function HideBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if not uf then return false end

    if plate.blizzardUF and plate.blizzardUF ~= uf then
        RestoreNativeBase(base)
        plate.blizzardUF, plate.blizzardHidden, plate.blizzardAlpha = nil, nil, nil
        plate.fastFaded, plate.fastSeen, plate.deepFaded, plate.deepSeen = {}, {}, {}, {}
    end
    plate.fastFaded = plate.fastFaded or {}
    plate.fastSeen = plate.fastSeen or {}
    plate.deepFaded = plate.deepFaded or {}
    plate.deepSeen = plate.deepSeen or {}

    if plate.blizzardAlpha == nil then plate.blizzardAlpha = AlphaOf(uf) end
    FadeNativeNode(uf, base, plate, false)
    FadeBlizzardTree(base, plate)
    -- Show 是受保护项；战斗中等暴雪下一次 SetUnit / 更新自己补，不发无谓拦截。
    if uf.IsShown and not InCombat()
        and not Secrets.Bool(uf:IsShown(), false) then pcall(uf.Show, uf) end

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
    local restored = RestoreNativeBase(base)
    if uf and not InCombat() then pcall(uf.Show, uf) end
    if plate then
        plate.blizzardHidden = nil
        plate.blizzardUF = nil
        plate.blizzardAlpha = nil
        plate.fastFaded, plate.fastSeen, plate.deepFaded, plate.deepSeen = nil, nil, nil, nil
    end
    return restored
end

-- UpdateBorder 定义在后面（仇恨/目标描边）；红闪到期要请它恢复边框色，先前向声明这个 local，
-- 否则 CastTick 里引用的是全局 nil（AGENTS：helper 必须在依赖的 local 之后）。
local UpdateBorder

--- B1 火花染色：普通=白芯+深描边，不可打断=中性灰（与灰色填充同一信号）。
--- 只依赖我们自己的旁表状态 plate.castNotInt（UpdateCast 里经 Secrets.Bool 落定的普通布尔）。
local function TintCastSpark(plate)
    local spark = plate.cast and plate.cast.spark
    if not spark then return end
    local r, g, b = 1, 1, 1
    if plate.castNotInt then r, g, b = Color:GetNeutral() end
    spark.fill:SetVertexColor(r, g, b, 1)
    spark.edge:SetVertexColor(0.10, 0.03, 0.03, 1)
end

local function HideCast(plate)
    local cast = plate.cast
    if not cast then return end
    plate.castActive = nil
    plate.castEndClock = nil
    plate.castStartClock = nil
    -- B3/B4 的状态时间戳一并清掉：plate 会被池子复用，残留的 flash 会在下一只怪身上诈尸。
    plate.castFlashUntil = nil
    plate.castDelayUntil = nil
    plate.castNotInt = nil
    plate.castEngine = nil
    plate.castEngineText = nil
    plate:SetScript("OnUpdate", nil)
    -- 引擎倒计时/「对你」一起收掉：绑定停用后保留的最后一帧文字要清空，不然下次 Show 会带旧秒数。
    if cast.timer and cast.timer.binding then pcall(cast.timer.binding.SetEnabled, cast.timer.binding, false) end
    if cast.timer then cast.timer:SetText("") end
    if cast.isYou then cast.isYou:SetAlpha(0) end
    cast.flashText:Hide()
    cast.spark:Hide()
    cast.shield:Hide()
    cast:Hide()
end

-- The fill computes only with GetTime() (our own plain number) and hands SetValue a value the
-- client clamps against the secret start/end; the timer text needs math, only when end came plain.
local function CastTick(plate)
    local cast = plate.cast
    if not cast then return end
    local now = GetTime()

    -- B3：打断/失败红闪期间驱动保持挂载（StartCastFlash 负责挂上）；
    -- 边框约 5Hz 红闪，到期恢复主题描边并走原隐藏路径。纯时间戳，不用 C_Timer。
    if plate.castFlashUntil then
        if now < plate.castFlashUntil then
            local lit = (math.floor(now * 10) % 2) == 0
            cast:SetBackdropBorderColor(0.95, 0.16, 0.12, lit and 1 or 0.35)
            return
        end
        plate.castFlashUntil = nil
        UpdateBorder(plate)
        HideCast(plate)
        return
    end

    -- B4：受击退条的尾闪（0.25s 琥珀亮芯），机密期火花钉在起点也照样闪。
    if plate.castDelayUntil then
        if now < plate.castDelayUntil then
            cast.spark.fill:SetVertexColor(1, 0.82, 0.30, 1)
        else
            plate.castDelayUntil = nil
            TintCastSpark(plate)   -- 到期恢复常规染色
        end
    end

    if not plate.castActive then return end

    -- 引擎在跑（SetTimerDuration）时不再写值：条由客户端自己推进，我们写 SetValue 会和它打架。
    if not plate.castEngine then
        pcall(cast.fill.SetValue, cast.fill, now * 1000)
    end

    if plate.castEngineText then
        -- 秒数由 DurationTextBinding 逐帧刷新（战斗机密期也有；旧路径在机密时只能空白）
    elseif plate.castEndClock then
        local left = plate.castEndClock - now
        if left < 0 then left = 0 end
        if left < 10 then
            cast.timer:SetText(string.format("%.1f", left))
        else
            cast.timer:SetText(string.format("%d", math.floor(left + 0.5)))
        end
    else
        cast.timer:SetText("")
    end

    -- B1：火花沿填充前沿移动。进度公式与引擎 StatusBar 的 (value-min)/(max-min) 同形，
    -- 引导（start>end）自然从 1 退到 0，不需要分支；宽度取设置值（普通数），不读框体几何。
    -- 机密施法值时 start/end 钟不存在 → 钉在起点（CastBar.lua:162 先例）。
    local s, e = plate.castStartClock, plate.castEndClock
    local x = BORDER
    if s and e and e ~= s then
        local frac = (now - s) / (e - s)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        x = BORDER + ((Setting("width") or 120) - BORDER * 2) * frac
    end
    cast.spark:SetPoint("TOP", cast, "BOTTOMLEFT", x, 1)
end

-- 投射条驱动只在"有条在走"的那段时间挂在 plate 上（HideCast 摘掉），常驻订阅会让空闲
-- 名板也每帧空转。所以它走外部账：所有 plate 共用一个 key，账合成一路。
-- B3 的红闪期也算"有条"：StartCastFlash 同样挂这个壳，/mui perf 里仍是 nameplates:cast 一路。
local CastTickTracked = ns.Scheduler and ns.Scheduler:Profile("nameplates:cast", "名板投射条", CastTick)
    or CastTick

--- 打断者名字：事件载荷给的是 GUID（受限时也可能是机密串）。逐级 pcall；
--- 名字若读成机密就不拼文案（SetText 吃得下机密串，concat 吃不下）—— 宁可只显示「被打断」。
local function InterrupterName(guid)
    if type(guid) == "nil" then return nil end
    local ok, _, _, _, _, name = pcall(GetPlayerInfoByGUID, guid)
    if not ok then return nil end
    if type(name) == "nil" then
        local okT, token = pcall(UnitTokenFromGUID, guid)
        if okT and type(token) ~= "nil" then
            local okN, unitName = pcall(UnitName, token)
            if okN then name = unitName end
        end
    end
    return name
end

--- B3：打断/失败不再瞬时藏条 —— 置 0.5s 红闪时间戳，渲染与收尾都交给现有 CastTick。
--- 条没在显示（showCast 关 / 本来就没条）时不闪，直接走原隐藏路径。
local function StartCastFlash(plate, label)
    local cast = plate.cast
    if not cast or not cast:IsShown() then return HideCast(plate) end
    plate.castActive = nil
    plate.castEndClock = nil
    plate.castStartClock = nil
    plate.castDelayUntil = nil
    plate.castFlashUntil = GetTime() + ns.Math.FX.castFlash
    cast.spark:Hide()
    cast.shield:Hide()
    cast.text:Hide()
    cast.timer:Hide()
    -- 红闪期间停掉引擎秒数（DurationTextBinding 自己会一直数下去），并收掉「对你」标记。
    if cast.timer.binding then pcall(cast.timer.binding.SetEnabled, cast.timer.binding, false) end
    if cast.isYou then cast.isYou:SetAlpha(0) end
    plate.castEngine, plate.castEngineText = nil, nil
    cast.flashText:SetText(label)
    cast.flashText:Show()
    plate:SetScript("OnUpdate", CastTickTracked)
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

    -- 新施法开始：上一轮可能还挂着红闪（打断后立刻再施法），先收掉闪烁状态。
    plate.castFlashUntil = nil
    plate.cast.flashText:Hide()
    plate.cast.text:Show()
    plate.cast.timer:Show()

    -- Name and texture go straight to the widgets: SetText / SetTexture accept a secret.
    plate.cast.text:SetText(name)
    if type(texture) ~= "nil" then
        plate.cast.icon:SetTexture(texture)
        plate.cast.icon:Show()
    else
        plate.cast.icon:Hide()
    end

    -- Bars take the raw times; no arithmetic of ours touches them.
    -- `startMS or 0` 是机密数字上的一次真值测试（`or` 走 truth test，同族拦截），所以零值
    -- 兜底只对**非机密**做；机密原样交给 widget（SetMinMaxValues 允许机密）。
    local from, to = startMS, endMS
    if not Secrets.IsSecret(from) then from = from or 0 end
    if not Secrets.IsSecret(to) then to = to or 1 end
    pcall(plate.cast.fill.SetMinMaxValues, plate.cast.fill, from, to)
    -- 只存"有条在走"这个普通布尔：存原始 endMS 会让 CastTick 每帧对它做真值测试。
    -- 引擎时长可用时条由客户端自己推进；否则机密/读不到 end 维持旧行为（静态条，保留上次状态）。
    plate.castActive = nil   -- 下面引擎块 / 旧路径判定后落定

    -- Plain end => a real countdown; hidden end => bar moves, number blank (see 4.6 in MonetUI.md).
    local endClock = Secrets.Number(endMS)
    plate.castEndClock = endClock and (endClock / 1000) or nil
    -- B1：起点钟也只在两端都是普通数时存（机密不做算术）；缺任一端火花钉起点。
    local startClock = Secrets.Number(startMS)
    plate.castStartClock = (startClock and plate.castEndClock) and (startClock / 1000) or nil

    -- B2：不可打断判定只落一次普通布尔，灰填充与盾徽共用；机密落回"可打断"（Secrets.Bool 契约）。
    local notInt = Secrets.Bool(notInterruptible, false)
    plate.castNotInt = notInt
    plate.cast.shield:SetShown(notInt)
    if notInt then
        plate.cast.fill:SetStatusBarColor(Color:GetNeutral())
    elseif channel then
        plate.cast.fill:SetStatusBarColor(0.62, 0.62, 0.92)
    else
        plate.cast.fill:SetStatusBarColor(Color:GetResource())
    end

    -- B5：引擎时长对象 —— 战斗里客户端自己读机密施法数据并推进填充/倒计时。
    -- 拿不到（旧构建 / 单位没在施法）就退回旧时钟算法；两条路互斥，绝不双写。
    local durationObj
    do
        local fn = channel and _G.UnitChannelDuration or _G.UnitCastingDuration
        if type(fn) == "function" then
            local okD, d = pcall(fn, unit)
            if okD then durationObj = d end
        end
    end
    plate.castEngine, plate.castEngineText = nil, nil
    if durationObj and type(plate.cast.fill.SetTimerDuration) == "function" then
        local E = _G.Enum
        local dir = channel and E and E.StatusBarTimerDirection and E.StatusBarTimerDirection.RemainingTime
                            or E and E.StatusBarTimerDirection and E.StatusBarTimerDirection.ElapsedTime
        if pcall(plate.cast.fill.SetTimerDuration, plate.cast.fill, durationObj, nil, dir) then
            plate.castEngine = true
            plate.cast.timer:SetText("")
            local b = plate.cast.timer.binding
            if b and type(b.SetDuration) == "function" then
                pcall(b.SetEnabled, b, true)
                if pcall(b.SetDuration, b, durationObj) then
                    plate.castEngineText = true
                end
            end
        end
    end
    plate.castActive = plate.castEngine or (not Secrets.IsSecret(endMS) and endMS ~= nil)

    -- B6：「对你施法」标记。PlayerIsSpellTarget 返回机密布尔 → 只交给 SetAlphaFromBoolean。
    local isYou = plate.cast.isYou
    if isYou then
        if type(PlayerIsSpellTarget) == "function" and type(isYou.SetAlphaFromBoolean) == "function" then
            local okY, you = pcall(PlayerIsSpellTarget, unit)
            if okY then isYou:SetAlphaFromBoolean(you, 1, 0) else isYou:SetAlpha(0) end
        else
            isYou:SetAlpha(0)
        end
    end

    -- B1：火花随条显示（引导也显示），先钉起点，CastTick 每拍把它推到填充前沿。
    TintCastSpark(plate)
    plate.cast.spark:ClearAllPoints()
    plate.cast.spark:SetPoint("TOP", plate.cast, "BOTTOMLEFT", BORDER, 1)
    plate.cast.spark:Show()

    plate.cast:Show()
    plate:SetScript("OnUpdate", CastTickTracked)
end

local function UpdateHealth(plate)
    local unit = plate.unit

    -- A refused unit call skips the write entirely so the bar keeps its last state (Secrets contract).
    -- **守卫必须在 `~= nil` 之前**：受限时 Query 拿到的是机密数字（pcall 成功、不是 nil），
    -- `hp ~= nil` 本身就是一次被拦比较（2026-10-30 ×8 同一形态）。机密照样交给 SetBar
    -- （引擎自己读，见 Utils/Secrets.lua 头部），只有"读不到"（普通 nil）才跳过。
    local hp, hpMax = Query(UnitHealth, unit), Query(UnitHealthMax, unit)
    local opaque = Secrets.IsSecret(hp) or Secrets.IsSecret(hpMax)
    if opaque or (hp ~= nil and hpMax ~= nil) then
        local interpolation = (Setting("smooth") ~= false) and Secrets.SMOOTH or nil
        Secrets.SetBar(plate.health, hp, hpMax, interpolation)
    end

    local r, g, b = HealthColor(unit)
    plate.health:SetStatusBarColor(r, g, b)

    -- Dead / disconnected: the client greys the bar, and the "lost" overlay (no value of its
    -- own) is greyed by hand so a corpse reads as one (same rule as the unit frames).
    local connected = Query(UnitIsConnected, unit)
    -- 机密布尔上做 `== nil` 同样被拦：先问 IsSecret，机密就直接往下交给 Secrets.Bool
    -- 落回"算连接着"（= 以前被拦后的回退值）。
    if not Secrets.IsSecret(connected) and connected == nil then
        connected = true
    end
    local gone = Secrets.Bool(Query(UnitIsDeadOrGhost, unit), false)
        or not Secrets.Bool(connected, true)
    plate.health:SetStatusBarDesaturated(gone)
    if gone then
        local nr, ng, nb = Color:GetNeutral()
        plate.healthLost:SetVertexColor(nr, ng, nb, 1)
    else
        plate.healthLost:SetVertexColor(0, 0, 0, 1)
    end

    -- 百分比：**不要拿 CanMeasureHealth 当门**（它问的是 C_Secrets 的答案，实测与真实值不一致：
    -- 2026-11-01 副本内 26 块牌子 `CanMeasureHealth(nameplateN)=false`，于是百分比全空白）。
    -- 先试普通算术，拿不到就交给客户端的百分比曲线 —— 机密数字 SetFormattedText 吃得下。
    if Setting("showPercent") ~= false then
        local written = Secrets.FormatHealthPercent(plate.percent, unit, hp, hpMax)
        if not written then plate.percent:SetText("") end
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
    local levelText = table.concat(parts, " ")
    -- 写入守卫：level 段只在真变了的时候写。UpdatePlate 是每块牌子 UNIT_HEALTH 的处理函数，
    -- 而等级/阶级符号跟血量无关 —— 以前每次跳血都重写一遍这个 FontString。
    if plate.levelText ~= levelText then
        plate.levelText = levelText
        plate.level:SetText(levelText)
    end

    -- 规则（2026-10-27 玩家定）：名字最多占牌子总宽 70%，超了**缩字号**、绝不截断 ——
    -- 统一走 Widget:FitText（机密名走它内部的"不测不缩"分支，原样显示）。
    -- Setting("truncate"/"nameLength") 保留在设置里但不再读（原截断规则暂不使用）。
    -- level 段比剩余 30% 还宽时再收一档，免得两段挤在一起。
    local name = Query(UnitName, unit)
    local nameSize = ns.Media:SnapSize(Setting("nameSize"))
    -- 名字可能是机密串：**机密值不能进 `==`**（secret-compare 会被拦），所以只有明文名字
    -- 才参与下面的排版判据；机密名一律照原样重跑 FitText。
    local namePlain = (type(name) == "string" and not Secrets.IsSecret(name)) and name or nil

    local W = PlateWidth()
    local maxWidth = W * 0.70
    if namePlain then
        local levelW = plate.level:GetStringWidth()
        -- 宽度读回来也可能成机密（与 Widget:FitText 头部同一课：锚在机密几何上时
        -- GetStringWidth 会变机密）—— 对机密宽度比大小就是被拦调用。
        if type(levelW) == "number" and not Secrets.IsSecret(levelW) and levelW > 0 then
            maxWidth = math.min(maxWidth, W - levelW - 4)
        end
    end

    -- 排版判据全等就跳过整段测量：Widget:FitText 里是 SetFont + SetText + GetStringWidth，
    -- 外加最坏 12 档的"缩一号再量一次"循环（Utils/Widget.lua:1269-1278）。副本里一次
    -- 伤害跳字 = 一块牌子最多 13 次字体测量，而名字/等级/宽度一个都没变。
    -- 名字**颜色**不在这段里（它跟血量百分比曲线走，见下），所以仍然每次都刷。
    local cacheable = namePlain ~= nil
        and type(maxWidth) == "number" and not Secrets.IsSecret(maxWidth)
        and type(nameSize) == "number" and not Secrets.IsSecret(nameSize)
    local fitSame = cacheable and plate.fitName == namePlain and plate.fitLevel == levelText
        and plate.fitMaxW == maxWidth and plate.fitSize == nameSize
    if not fitSame then
        if cacheable then
            plate.fitName, plate.fitLevel = namePlain, levelText
            plate.fitMaxW, plate.fitSize = maxWidth, nameSize
        else
            plate.fitName, plate.fitLevel, plate.fitMaxW, plate.fitSize = nil, nil, nil, nil
        end
        Widget:FitText(plate.name, type(name) == "string" and name or "", maxWidth, nameSize, nil, 6)
    end
    -- B5：名字颜色 = 血量百分比曲线（满血绿 → 半血黄 → 低血红）。曲线在加载期建好，
    -- UnitHealthPercent 返回的是**已求值的颜色对象**（不做算术、机密期也算得出来），
    -- 直接把 RGB 交给 SetTextColor（NDui 同款机制）。
    if healthCurve and type(UnitHealthPercent) == "function" then
        local okP, col = pcall(UnitHealthPercent, unit, true, healthCurve)
        if okP and col then
            local okR, r, g, b = pcall(col.GetRGB, col)
            if okR and r then plate.name:SetTextColor(r, g, b) end
        end
    end
end

--- 团队标记：索引**原样**交给客户端的 SetSpriteSheetCell（帧索引允许机密值传入），
--- Lua 里不比较、不做表键。机密数字的 type() 仍是 "number"，所以类型门不会把它判掉；
--- 只有普通数字才做 1..8 的范围检查（拿机密值和字面量比大小会抛）。
local function UpdateRaidIcon(plate)
    local tex = plate.raidIcon
    if not tex then return end
    if Setting("showRaidIcon") == false then tex:Hide(); return end

    local ok, index = pcall(GetRaidTargetIndex, plate.unit)
    if not ok or type(index) ~= "number" then tex:Hide(); return end
    if not Secrets.IsSecret(index) and (index < 1 or index > RAID_SHEET_CELLS * RAID_SHEET_CELLS) then
        tex:Hide()
        return
    end

    if type(tex.SetSpriteSheetCell) == "function" then
        if pcall(tex.SetSpriteSheetCell, tex, index, RAID_SHEET_CELLS, RAID_SHEET_CELLS) then
            tex:Show()
            return
        end
    elseif type(SetRaidTargetIconTexture) == "function" then
        if pcall(SetRaidTargetIconTexture, tex, index) then
            tex:Show()
            return
        end
    end
    tex:Hide()
end

--- The border says what the unit is doing to you: threat first, then "this is my target".
--- UnitThreatSituation / UnitIsUnit can be secret, so each keeps its previous answer
--- instead of flickering (AGENTS: 受限时保留上次状态).
--- （赋值给文件前部前向声明的 local：CastTick 的红闪到期要调它恢复边框。）
function UpdateBorder(plate)
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
-- C++ nameplate hit test is anchored to its bars, see HideBlizzardPlate).
-- 已知快节点逐帧回压；full=true 时补扫动态新建的深层节点和 ignoreParentAlpha region。
local function KeepBlizzardHidden(plate, full)
    local base = plate.base
    local uf = BlizzardUnitFrame(base)
    if not uf then return end
    if plate.blizzardUF ~= uf then
        if not plate.blizzardHidden or not HideBlizzardPlate(base, plate) then return end
    end

    for i = 1, #plate.fastFaded do
        FadeNativeNode(plate.fastFaded[i], base, plate, false)
    end
    if full then
        FadeBlizzardTree(base, plate)
        for i = 1, #plate.deepFaded do
            FadeNativeNode(plate.deepFaded[i], base, plate, true)
        end
    end
end

-- 目标高亮 / 焦点 / 光环更新会重设原生 alpha。逐帧复查已知节点，消掉 250ms 可见窗口；
-- 全树扫描仍限 4Hz，避免几十块牌每帧递归 GetChildren/GetRegions。
local guardJob = nil
local GUARD_SCAN_INTERVAL = 0.25
local RESTORE_RETRY_INTERVAL = 0.25
local guardClock, guardScanElapsed = 0, 0

local function GuardTick(elapsed)
    local dt = elapsed or 0
    guardClock = guardClock + dt

    local bases = {}
    for base in pairs(pendingRestores) do bases[#bases + 1] = base end
    local sawPending = #bases > 0
    for i = 1, #bases do
        local base = bases[i]
        if (restoreRetryAt[base] or 0) <= guardClock then
            RestoreNativeBase(base)
            if pendingRestores[base] then
                restoreRetryAt[base] = guardClock + RESTORE_RETRY_INTERVAL
            end
        end
    end
    if sawPending and not next(pendingRestores) then M:SyncGuard() end
    if not M.active then return end

    guardScanElapsed = guardScanElapsed + dt
    local full = guardScanElapsed >= GUARD_SCAN_INTERVAL
    if full then guardScanElapsed = guardScanElapsed - GUARD_SCAN_INTERVAL end
    for _, plate in pairs(plates) do
        if plate.blizzardHidden and plate.base then
            KeepBlizzardHidden(plate, full)
        end
    end
end

--- 回压订阅只在**真有牌压着或还有还原欠账**的时候存在。
function M:SyncGuard()
    local n = 0
    for _ in pairs(pendingRestores) do n = n + 1 end
    for _, plate in pairs(plates) do
        if plate.blizzardHidden and plate.base then n = n + 1 end
    end
    if n == 0 then
        if guardJob then
            ns.Scheduler:Unregister(guardJob)
            guardJob = nil
        end
    elseif not guardJob then
        guardJob = ns.Scheduler:EveryFrame(GuardTick, "姓名板:守卫")
    end
end

-- ============================================================================
-- 姓名板光环（引擎 AuraContainer，2026-11-23 接入，依据 HANDOFF §8.143）
-- ----------------------------------------------------------------------------
-- 战斗中客户端把光环数据标成机密、插件硬禁读（`C_UnitAuras.GetAuraDataByIndex` 直接抛），
-- 唯一能画实时 debuff 的是客户端自己：引擎按 `nameplateN` 单位**自己**解析 / 布局 / 分配按钮，
-- 连战斗窗口里都照常跑（§8.143 v7 指纹：4 个 HARMFUL 光环、宽度是 SECRET）。
-- 三件事必须按原样做，错一件就整块空白且零报错：
--   ① 绑定用**事件载荷令牌**（`plate.unit` 就是 `nameplateN`），不能从框体名反推大小写；
--   ② 容器出生就要 `SetEnabled(true)` + `UpdateAllAuras`，并且给一个可渲染的 1×1 矩形；
--   ③ 换单位不是换光环 —— 池子复用后引擎不会自己重读，必须 `SetUnit(新令牌)` + `UpdateAllAuras`。
-- 容器**永不销毁**（重建会留下上一世代被引擎驱动的容器，战斗里连环拦截）：模块关闭只是
-- `SetEnabled(false)` 让它退出引擎刷新，`plate:Hide()` 连子树一起藏，并摘掉共享 fit 账；
-- 重新启用只恢复仍存活的容器。出生后保持 Show，显示开关用 alpha，不用 Hide（引擎会停更）。
-- ============================================================================

local AURA_OWNER = "monetNameplateAuras"
local AURA_GAP   = 2
local AURA_MAX   = 12
local AURA_W     = 24
local AURA_H     = 18
-- 与 UnitFrames 的目标框同一套矩形裁切：左右不裁，上下各 3/24（AuraIconTexCoord）。
local AURA_TEX   = { 0, 1, 3 / 24, 1 - 3 / 24 }
local auraWarned = false
local auraStyleErr = nil      -- 最近一次换肤异常（探针读它，别再被 pcall 吞掉）

--- 一排能放几个：与暴雪同名公式一致，只是行宽取玩家设的姓名板宽度。
local function AuraPerRow(width)
    return math.max(1, math.floor((PlateWidth() + AURA_GAP) / (width + AURA_GAP)))
end

--- AuraContainer 属于 LoD 插件，没加载时 CreateFrame 拿不到那个模板。
local function EnsureAuraContainerAddOn()
    local C = _G.C_AddOns
    if not C or type(C.LoadAddOn) ~= "function" then return false end
    local ok, loaded = pcall(C.IsAddOnLoaded, "Blizzard_AuraContainer")
    if not ok then return false end
    if not loaded and not pcall(C.LoadAddOn, "Blizzard_AuraContainer") then return false end
    return true
end

-- 两代 API：Flow* 是新名字，AuraLayout* 是旧名字；新名优先、旧名兜底、都没有就跳过。
local function AuraFlowCall(container, newName, oldName, ...)
    local f = container[newName]
    if type(f) ~= "function" and oldName then f = container[oldName] end
    if type(f) ~= "function" then return false end
    return pcall(f, container, ...)
end

--- 贴左下、向右长、满行往上换行（名字上方那一簇的标准朝向）。
local function ApplyPlateAuraFlow(container, width)
    local perRow = AuraPerRow(width)
    -- 引擎判换行时会多算一个 elementSpacing，所以行宽要多给一格间距（同 UnitFrames 的注释）。
    local lineSize = perRow * width + perRow * AURA_GAP

    AuraFlowCall(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint", "BOTTOMLEFT")
    local flow = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    local grown = false
    if type(flow) == "table" and flow.Right ~= nil and flow.Up ~= nil then
        grown = AuraFlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection",
            flow.Right, flow.Up)
    end
    if not grown then
        AuraFlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection", "RIGHT", "UP")
    end
    local axes = _G.AnchorUtil and _G.AnchorUtil.FlowLayoutAxis
    if axes and type(container.SetFlowLayoutAxis) == "function" then
        pcall(container.SetFlowLayoutAxis, container, axes.Horizontal)
    end
    AuraFlowCall(container, "SetFlowLayoutElementSpacing", "SetAuraLayoutElementSpacing", AURA_GAP)
    AuraFlowCall(container, "SetFlowLayoutLineSpacing", "SetAuraLayoutLineSpacing", AURA_GAP)
    AuraFlowCall(container, "SetFlowLayoutMaximumLineSize", "SetAuraLayoutRowWidth", lineSize)
end

-- 容器的锚点与换行都挂在名字行的左上角；姓名板宽度变了要重算每行个数，所以重排时重跑一次。
SyncPlateAuraLayout = function(plate)
    local container = plate.auraContainer
    if not container then return end
    ApplyPlateAuraFlow(container, ns.Media:SnapUnit(AURA_W))
    container:ClearAllPoints()
    container:SetPoint("BOTTOMLEFT", plate.name, "TOPLEFT", 0, AURA_GAP)
end

local function AuraWarn(reason)
    if auraWarned then return end
    auraWarned = true
    ns:Print("姓名板光环：引擎容器不可用（" .. tostring(reason) .. "），本会话不再尝试。")
end

local function SetPlateAuraEnabled(container, enabled)
    if type(container) ~= "table" or type(container.SetEnabled) ~= "function" then return true end
    return pcall(container.SetEnabled, container, enabled and true or false)
end

local function DiscardPlateAuraContainer(container)
    if type(container) ~= "table" then return end
    SetPlateAuraEnabled(container, false)
    pcall(container.Hide, container)
    pcall(container.SetParent, container, nil)
end

--- 一块牌子一个容器，挂在**我们自己的牌子**下面（随牌子一起显隐、随模块关闭一起消失）。
--- 只在首次建，建好不再动结构：战斗里建容器对姓名板是允许的（§8.143 v7 实测），
--- 所以不走 AfterCombat 队列 —— 排队反而会让第一块牌子整场没有 debuff。
local function CreatePlateAuraContainer(plate)
    if not EnsureAuraContainerAddOn() then
        AuraWarn("Blizzard_AuraContainer 未加载")
        return nil
    end
    local iconW, iconH = ns.Media:SnapUnit(AURA_W), ns.Media:SnapUnit(AURA_H)
    local ok, container = pcall(CreateFrame, "AuraContainer", nil, plate, "CustomAuraContainerTemplate")
    if not ok or type(container) ~= "table" then
        AuraWarn("CreateFrame(AuraContainer) 失败（模板可能不存在）")
        return nil
    end

    -- 引擎要一个可渲染的矩形才会跑第一次布局。
    container:SetSize(1, 1)
    ApplyPlateAuraFlow(container, iconW)

    local styleButton = function(button)
        if type(ns.AuraButtonStyle) ~= "function" then return end
        local pad = ns.Media and ns.Media:Mult() or 1
        if type(pad) ~= "number" or pad <= 0 then pad = 1 end
        -- texCoordOnce：图标贴图由引擎写（SetIcon 交进去的就是这颗纹理）。texcoord **只写一次**
        -- 且不进 0.5s 裁切驱动 —— 驱动每拍对它 SetTexCoord 等于反复往引擎自有贴图上写，实机把
        -- 整排图标写成空白方块；而一次都不写 texcoord 时引擎画不出图标（2026-11-22 实机：只剩
        -- 黄色时长数字、没有方块）。同 NDui 在本客户端"SetIcon 之前写一次 texcoord"的做法。
        -- AURA_TEX = 目标框那套 24×18 裁切（上/下各去 3/24 → 4:3 横向矩形，不改图标内容）。
        local ok, err = pcall(ns.AuraButtonStyle, button, "debuff", {
            width = iconW, height = iconH,
            crop = false,
            texCoordOnce = AURA_TEX,
            iconInset = pad,
            textSize = 10,
            fontKey = "pixel",
            borderInside = true,
        }, AURA_OWNER)
        if not ok then auraStyleErr = tostring(err) end
    end
    local opts = {
        maxFrameCount = AURA_MAX,
        -- 空表 = 不设白名单；只看 filter 里的 PLAYER token（玩家自己施放）。
        candidateFilters = {},
        layout = {
            elementSpacing = AURA_GAP,
            lineSpacing    = AURA_GAP,
            elementWidth   = iconW,
            elementHeight  = iconH,
            layoutIndex    = 1,
        },
        -- 必需件先注册（Auras.lua 的 StyleAuraButton 内部保证），装饰失败不影响图标。
        initializeFrame = styleButton,
    }
    local sortMethod = _G.AuraContainerSortMethod
    if type(sortMethod) == "table" then sortMethod = sortMethod.Expiration or sortMethod.Default end
    if type(sortMethod) == "number" then opts.sortMethod = sortMethod end
    local sortDirection = _G.AuraContainerSortDirection
    if type(sortDirection) == "table" then sortDirection = sortDirection.Normal end
    if type(sortDirection) == "number" then opts.sortDirection = sortDirection end

    -- PLAYER token = 玩家自己施放（NDui 在同客户端用它区别 isFromPlayerOrPlayerPet=任意玩家）。
    -- 不加 !CROWD_CONTROL：作者要的是"玩家放的 debuff"全集，控制技也算。
    local okAdd, err = pcall(container.AddAuraGroup, container, "debuffs", "HARMFUL|PLAYER", opts)
    if not okAdd then
        DiscardPlateAuraContainer(container)
        AuraWarn("AddAuraGroup 失败: " .. tostring(err))
        return nil
    end

    pcall(container.SetUnit, container, plate.unit)
    -- 出生就 Enable，让引擎把它纳入自己的刷新流程（出生后 Show/Hide 不影响）。
    if not SetPlateAuraEnabled(container, true) then
        DiscardPlateAuraContainer(container)
        AuraWarn("SetEnabled(true) 失败")
        return nil
    end
    pcall(container.UpdateAllAuras, container)
    if type(container.SetMouseClickEnabled) == "function" then pcall(container.SetMouseClickEnabled, container, false) end
    pcall(container.EnableMouse, container, false)

    -- 锚在名字行的左上角：名字的 BOTTOMLEFT 就是牌子的 TOPLEFT + TEXT_GAP，
    -- 所以名字的 TOPLEFT 正好是"牌子左边缘、名字正上方"，与重排时的 SyncPlateAuraLayout 同一条。
    local okAnchor = pcall(function()
        container:ClearAllPoints()
        container:SetPoint("BOTTOMLEFT", plate.name, "TOPLEFT", 0, AURA_GAP)
    end)
    if not okAnchor then
        DiscardPlateAuraContainer(container)
        AuraWarn("容器锚点失败")
        return nil
    end
    -- 与 BuffFrame 不同：姓名板上这块容器**就是功能本身**，alpha 保持 1、保持 Show。
    pcall(container.SetAlpha, container, 1)
    pcall(container.Show, container)
    plate.auraContainer = container
    return container
end

--- 绑定 / 重绑：同一块牌子被池子换给另一个单位时，引擎不会自己重读，必须显式换绑。
--- 幂等 —— 牌子对象（连同容器）活过模块关闭 / 重开，重开时容器已经在了。
local function BindPlateAuras(plate)
    if not M.active or not plate or not plate.unit then return end
    local container = plate.auraContainer
    if not container then
        -- 时长染色曲线必须由**非安全调用方**先建好；机密窗口只创建容器，不创建曲线。
        if not InCombat() and type(ns.PrepareAuraStyle) == "function" then pcall(ns.PrepareAuraStyle) end
        container = CreatePlateAuraContainer(plate)
        if not container then return end
    elseif not SetPlateAuraEnabled(container, true) then
        -- 只恢复仍存活的原容器；恢复失败不重建替代品。
        pcall(container.Hide, container)
        return
    end
    pcall(container.SetUnit, container, plate.unit)
    pcall(container.UpdateAllAuras, container)
    pcall(container.Show, container)
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
        -- SyncGuard 只在接管状态变化时跑；它是整表重数，不能放进每块牌的 HEALTH 事件。
        if plate.blizzardHidden then
            RestoreBlizzardPlate(plate.base, plate)
            M:SyncGuard()
        end
        plate:Hide()
        HideCast(plate)
        return false
    end

    if not plate.blizzardHidden then
        HideBlizzardPlate(plate.base, plate)
        -- 只有这一支接管原生牌，避免每块牌的 HEALTH 事件都触发全表重数。
        M:SyncGuard()
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
    UpdateRaidIcon(plate)
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
    "UNIT_AURA",
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_LEVEL",
    "UNIT_FACTION", "UNIT_CONNECTION",
    "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local function OnPlateEvent(plate, event, ...)
    if not plate.unit or not plates[plate.unit] then return end

    if event == "UNIT_AURA" then
        -- 暴雪先处理同一事件并创建/重排原生光环子框；我们在注册序之后补扫整棵。
        if plate.blizzardHidden and plate.base then KeepBlizzardHidden(plate, true) end
        return
    end

    if CAST_EVENTS[event] then
        if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
            -- B3：不再瞬时藏条 —— 0.5s 红闪 + 短文字，到期由 CastTick 走原隐藏路径。
            -- 刚结束的施法可能读回旧值，所以文案来自事件本身，不做新查询。
            local label = event == "UNIT_SPELLCAST_INTERRUPTED" and "被打断" or "失败"
            if event == "UNIT_SPELLCAST_INTERRUPTED" then
                -- B6：载荷 unitTarget, castGUID, spellID, interruptedBy。
                local _, _, _, interruptedBy = ...
                local who = InterrupterName(interruptedBy)
                if type(who) == "string" and not Secrets.IsSecret(who) then
                    label = label .. " > " .. who
                end
            end
            StartCastFlash(plate, label)
        elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            -- The cast that just ended can still read back stale, so the end comes from the
            -- event, not a fresh query.
            HideCast(plate)
        else
            if event == "UNIT_SPELLCAST_DELAYED" and plate.cast and plate.cast:IsShown() then
                -- B4：退条只记一个 0.25s 尾闪时间戳；不读 delayTimeMs（第 11 返回是机密）。
                plate.castDelayUntil = GetTime() + ns.Math.FX.castDelay
            end
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
-- 令牌是**事件载荷**：它之后要当表键（plates[unit]）又要进 Unit* 查询，两样都会在机密值上
-- 被拦。type() 判不出机密（机密串的 type 照样是 "string"），所以两道都要 —— 判不住就
-- 少画一块牌子，别在索引时炸。
local function Added(unit)
    if type(unit) ~= "string" or Secrets.IsSecret(unit) then return nil end

    local base = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and Query(C_NamePlate.GetNamePlateForUnit, unit) or nil
    if not base then return nil end

    local plate = Marked(base, "plate")
    if not plate then
        plate = Build(base)
        Mark(base, "plate", plate)
        plate:SetScript("OnEvent", OnPlateEvent)
    end

    -- base 复用后 UnitFrame 可能已被池子换成新对象；先清旧归属，不能把旧 alpha 快照套给新框。
    if plate.blizzardHidden and plate.blizzardUF ~= BlizzardUnitFrame(base) then
        RestoreBlizzardPlate(base, plate)
    end

    plate.unit = unit
    if Setting("showAuras") ~= false then BindPlateAuras(plate) end
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
    if type(unit) ~= "string" or Secrets.IsSecret(unit) then return false end
    local plate = plates[unit]
    if not plate then return false end

    -- 原生 UnitFrame 马上要回池；先恢复我们压过的节点，失败则留下 pending 账由守卫重试。
    if plate.blizzardHidden and plate.base then RestoreBlizzardPlate(plate.base, plate) end
    plates[unit] = nil
    plate.unit = nil
    plate:UnregisterAllEvents()
    -- HideCast 一并清掉施法状态与 B1-B4 新增键（spark/shield/flashText 随框隐藏），
    -- plate 被池子换给下一只单位时不带残留。
    HideCast(plate)
    plate:Hide()
    M:SyncGuard()
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
            if plate.blizzardHidden and plate.base then KeepBlizzardHidden(plate, true) end
            UpdateBorder(plate)
        end
    end)

    EventBus:Register("PLAYER_FOCUS_CHANGED", function()
        if not M.active then return end
        for _, plate in pairs(plates) do
            if plate.blizzardHidden and plate.base then KeepBlizzardHidden(plate, true) end
        end
    end)

    -- 团队标记事件没有载荷；牌子的单位令牌不变，所以全量重画一次就够。
    EventBus:Register("RAID_TARGET_UPDATE", function()
        if not M.active then return end
        M:UpdateAll()
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
        -- 光环开关改了就当场落地：关 = 连容器一起藏（不销毁），开 = 重绑并显示。
        if plate.auraContainer then
            if Setting("showAuras") ~= false then
                BindPlateAuras(plate)
            else
                SetPlateAuraEnabled(plate.auraContainer, false)
                pcall(plate.auraContainer.Hide, plate.auraContainer)
            end
        elseif Setting("showAuras") ~= false and plate.unit then
            BindPlateAuras(plate)
        end
    end

    self:ApplyCVars()
    self:ApplyPlateSize()
    self:HookDriver()
    self:UpdateAll()
    self:SyncGuard()
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
        self:SyncGuard()
        if type(ns.AuraFitMounted) == "function" then pcall(ns.AuraFitMounted, true, AURA_OWNER) end
        return
    end

    self.active = false
    for unit, plate in pairs(plates) do
        if plate.base then RestoreBlizzardPlate(plate.base, plate) end
        -- 容器随 plate 保留供下次复用，但模块关闭时必须退出引擎刷新。
        SetPlateAuraEnabled(plate.auraContainer, false)
        plate.unit = nil
        plate:UnregisterAllEvents()
        HideCast(plate)   -- 模块关闭同样清干净施法状态（含红闪/尾闪时间戳）
        plate:Hide()
        plates[unit] = nil
    end

    self:SyncGuard()      -- 一块牌都不剩：摘掉回压订阅，Scheduler 主框跟着隐藏
    -- 容器不销毁（重建会让引擎驱动的旧世代容器留在场），只把共享 fit 账摘掉。
    if type(ns.AuraFitMounted) == "function" then pcall(ns.AuraFitMounted, false, AURA_OWNER) end
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
    "C_CVar.GetCVarInfo",
    "NamePlateDriverFrame",
    "NamePlateDriverFrame.UpdateNamePlateOptions",
}

--- 实机探针（`/mui nameplates probe cvar`）：一次把 8 个 CVar 读全 ——
--- 客户端答"能不能写"（isSecure / isReadOnly / isLockedFromUser）、当前值、默认值、
--- 我们要的值、以及本会话上一次写入的判决。
--- 为什么要这条：`WriteCVar` 以前吞掉 pcall 结果，"设置项长期空转"这种病**一行红字都不响**，
--- 光看代码看不出来；而按约定不能发长 `/run` 去现场摸，所以把它做成一条子命令。
function M:ProbeCVars()
    ns:Print(("姓名板 CVar 探针（%d 个）· 客户端 %s")
        :format(#CVARS, Text(GetBuildInfo and GetBuildInfo())))
    local unwritable = 0
    for _, cvar in ipairs(CVARS) do
        local info = CVarInfo(cvar)
        local rec = cvarLedger[cvar]

        local flags = "可写"
        if not info then
            flags = "GetCVarInfo 无答复"
        elseif info.secure then
            flags, unwritable = "isSecure（插件写不进）", unwritable + 1
        elseif info.readonly then
            flags, unwritable = "isReadOnly", unwritable + 1
        elseif info.locked then
            flags = "isLockedFromUser（玩家已锁）"
        end

        local got = (info and info.value) or ReadCVar(cvar)
        ns:Print(("%s = %s · 默认 %s · %s · 期望 %s · %s")
            :format(cvar, Text(got), Text(info and info.default), flags,
                    Text(rec and rec.want), Text(rec and rec.note or "本会话没写过")))
    end
    if unwritable > 0 then
        ns:Print(("|cffff6b6b%d 个不可写|r：这些设置项在本客户端只能由暴雪自己改（CVar 界面 / 控制台命令），"
            .. "插件写了不生效 —— 设置面板里该把它们标掉，别留成「看起来能调」的开关。")
            :format(unwritable))
    else
        ns:Print("全部可写。")
    end
end

-- 只读探针（2026-11-03，上线日验收用）：`/mui nameplates siblings`
-- 把每块牌的 `base:GetChildren()` **真名 + alpha** 落进账本：五家参考件的名单里都没有
-- `BuffListFrame`，本仓没有第二样本，"暴雪到底在同一块牌上画了哪些同级容器"只能实机读出来。
-- 纪律：一个属性都不写、不 Hide、不 SetAlpha、不挂脚本；名字过 `Text()`（机密串进
-- concat 会抛）、alpha 走 `AlphaOf()`（读不出记 nil，不猜 1）。
local SIBLING_ROW_CAP = 400
local SIBLING_PRINT   = 8

--- 模块关掉时 `plates` 是空的，探针仍要能独立清点暴雪牌 —— 否则"还原有没有做"根本无从验
--- （2026-11-26 实机：关模块后 `/mui nameplates siblings` 只回"没有牌"，看不出还原结果）。
local function IndependentNameplateBases()
    local out = {}
    local api = _G.C_NamePlate
    local fn = api and api.GetNamePlates
    if type(fn) == "function" then
        local ok, list = pcall(fn)
        if ok and type(list) == "table" then
            for i = 1, #list do
                local base = list[i]
                if base then out[#out + 1] = base end
            end
        end
    end
    return out
end

--- 在子树里找名字含 needle 的框（`BuffListFrame` 不一定挂在 base 直属层 —— 暴雪把它建在
--- UnitFrame 下面时，只看 base:GetChildren() 会永远数到 0）。限深 4 层 / 节点预算 400。
local function SubtreeNameHits(root, needle)
    local hits, budget = 0, 400
    local function walk(frame, depth)
        if depth > 4 or budget <= 0 then return end
        local ok, kids = pcall(ChildrenOf, frame)
        if not ok or type(kids) ~= "table" then return end
        for i = 1, #kids do
            budget = budget - 1
            if budget <= 0 then return end
            local child = kids[i]
            local name
            if type(child.GetName) == "function" then
                local okN, raw = pcall(child.GetName, child)
                if okN then name = Text(raw) end
            end
            if name and name ~= "-" and name ~= "nil"
                and string.find(string.lower(name), needle) then hits = hits + 1 end
            walk(child, depth + 1)
        end
    end
    walk(root, 0)
    return hits
end

function M:ProbeSiblings()
    local stamp
    if type(_G.date) == "function" then
        local okDate, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
        if okDate then stamp = s end
    end

    local rows = {}
    local plateCount, unreadable, buffListHits, buffListDeep = 0, 0, 0, 0

    for unit, plate in pairs(plates) do
        local base = plate and plate.base
        if type(base) == "table" then
            plateCount = plateCount + 1
            local baseName
            if type(base.GetName) == "function" then
                local okN, raw = pcall(base.GetName, base)
                if okN then baseName = Text(raw) end
            end
            local uf = BlizzardUnitFrame(base)
            -- 多返回值：直接 `pcall(base.GetChildren, base)` 只接到第一个子框，
            -- `type(kids) == "table"` 恒假 → 这份兄弟框报告永远 0 行（用 ChildrenOf 包表）。
            local okKids, kids = pcall(ChildrenOf, base)
            if okKids and type(kids) == "table" and #kids > 0 then
                for i = 1, #kids do
                    if #rows >= SIBLING_ROW_CAP then break end
                    local c = kids[i]
                    local name
                    if type(c.GetName) == "function" then
                        local okC, raw = pcall(c.GetName, c)
                        if okC then name = Text(raw) end
                    end
                    if name == nil or name == "-" or name == "nil" then name = "（匿名）" end
                    if string.find(string.lower(name), "bufflist") then buffListHits = buffListHits + 1 end
                    local rec = fadedNodes[c]
                    rows[#rows + 1] = {
                        unit      = Text(unit),
                        base      = baseName,
                        index     = i,
                        name      = name,
                        alpha     = AlphaOf(c),
                        ours      = (c == plate) or nil,
                        unitFrame = (c == uf) or nil,
                        fadedByUs = rec and rec.base == base or nil,
                        priorAlpha = rec and rec.alpha,
                    }
                end
            elseif okKids and type(kids) == "table" then
                -- 有 base、一个子框都没有：要么牌刚出生还没装配，要么这一路的 alpha 全靠 base 继承
                rows[#rows + 1] = { unit = Text(unit), base = baseName, name = "（无子框）" }
            else
                unreadable = unreadable + 1
                rows[#rows + 1] = { unit = Text(unit), name = "（base 子树读不出）" }
            end
            -- 直属层没命中不等于没有：暴雪常把光环容器建在 UnitFrame 下面（整棵子树再数一次）。
            buffListDeep = buffListDeep + SubtreeNameHits(base, "bufflist")
        end
    end

    -- 模块关掉 / 我们的牌还没建时，独立清点暴雪牌：base 与 UnitFrame 的 alpha 就是"还原"的直接读数。
    local independent = 0
    if plateCount == 0 then
        local bases = IndependentNameplateBases()
        for i = 1, #bases do
            if #rows >= SIBLING_ROW_CAP then break end
            local base = bases[i]
            independent = independent + 1
            buffListDeep = buffListDeep + SubtreeNameHits(base, "bufflist")
            local uf = BlizzardUnitFrame(base)
            rows[#rows + 1] = {
                unit  = "独立清点",
                base  = "暴雪牌 " .. i,
                index = i,
                name  = "（暴雪牌 base）",
                alpha = AlphaOf(base),
            }
            if uf and #rows < SIBLING_ROW_CAP then
                local rec = fadedNodes[uf]
                rows[#rows + 1] = {
                    unit      = "独立清点",
                    base      = "暴雪牌 " .. i,
                    index     = i,
                    name      = "UnitFrame",
                    alpha     = AlphaOf(uf),
                    unitFrame = true,
                    priorAlpha = rec and rec.alpha,
                    fadedByUs = (rec and rec.base == base) or nil,
                }
            end
        end
    end

    local fadedCount, pendingCount = 0, 0
    for _ in pairs(fadedNodes) do fadedCount = fadedCount + 1 end
    for _ in pairs(pendingRestores) do pendingCount = pendingCount + 1 end
    local moduleOn = true
    if type(ns.IsModuleEnabled) == "function" then
        moduleOn = ns:IsModuleEnabled("Nameplates") and true or false
    end

    local lockdown = false
    if type(InCombatLockdown) == "function" then
        local okL, v = pcall(InCombatLockdown)
        lockdown = (okL and v) and true or false
    end

    local report = {
        when           = stamp,
        plates         = plateCount,
        independentBases = independent,
        fadedNodes     = fadedCount,
        pendingRestores = pendingCount,
        moduleEnabled  = moduleOn,
        unreadableBases = unreadable,
        buffListHits   = buffListHits,
        buffListDeep   = buffListDeep,
        lockdown       = lockdown,
        truncated      = (#rows >= SIBLING_ROW_CAP) or nil,
        rows           = rows,
        note           = "只读：GetName 过 Text() 防机密串，alpha 走 AlphaOf（nil=读不出）。"
            .. "buffListHits>0 就是 BlizzardBasePlate 下确有同级光环容器，FadeBlizzardTree 的覆盖面判据。"
            .. "pendingRestores 只剩 SetAlpha 真被拒的欠账（读不出 alpha 不再算失败，见 RestoreNativeBase）。",
    }

    local saved = false
    if type(ns.DB) == "function" then
        local okDb, db = pcall(function() return ns:DB() end)
        if okDb and type(db) == "table" then
            local okSet = pcall(function() db.nameplateSiblings = report end)
            saved = okSet and true or false
        end
    end

    if plateCount == 0 then
        if independent > 0 then
            ns:Print(string.format(
                "姓名板 siblings：我们的牌 0 块 —— 改为独立清点暴雪牌 %d 块（模块=%s）。",
                independent, moduleOn and "开" or "关"))
        else
            ns:Print("姓名板 siblings：既没有我们的牌、也看不到暴雪牌（不在战斗中/附近没有红名）——空转，账本已写。")
        end
    end
    for i = 1, math.min(#rows, SIBLING_PRINT) do
        local r = rows[i]
        local tag = r.ours and "（我们自绘）" or (r.unitFrame and "（暴雪 UnitFrame）") or ""
        local prior = r.priorAlpha and string.format("（原 %.2f）", r.priorAlpha) or ""
        ns:Print(string.format("  #%d %-28s α=%-6s%s%s%s",
            i, r.name, (r.alpha and string.format("%.2f", r.alpha)) or "读不出",
            tag, r.fadedByUs and " [我们压过]" or "", prior))
    end
    if #rows > SIBLING_PRINT then
        ns:Print(string.format("  …另有 %d 行只在账本里。", #rows - SIBLING_PRINT))
    end
    ns:Print(string.format("判据：牌 %d 块 / 独立清点 %d 块 / 读不出 %d / buffList 直属 %d · 子树 %d —— %s",
        plateCount, independent, unreadable, buffListHits, buffListDeep,
        (buffListDeep > 0) and "确有光环容器（子树里有 BuffList），需确认压暗覆盖到它及子框"
            or "本趟子树里都没有 BuffListFrame（目标没光环，或客户端不建这个容器）"))
    local restore
    if moduleOn then
        restore = "模块开着：账面节点正被压暗，属正常"
    elseif fadedCount == 0 and pendingCount == 0 then
        restore = "还原完成：模块关闭后账本已清空"
    else
        restore = "还原未完成：仍有节点记在账上（等脱战或下一次补扫）"
    end
    ns:Print(string.format("账本：压下节点 %d 个 / 待还原 %d 块牌 / 模块=%s / 战斗中=%s —— %s",
        fadedCount, pendingCount, moduleOn and "开" or "关", lockdown and "是" or "否", restore))
    ns:Print(saved
        and "全量已存 MonetUIDB.nameplateSiblings —— 写入比 /reload 晚 1–2 分钟，别立刻读（登出后再读最稳）。"
        or "账本没打开，只有聊天框这几行。")
end

--- 实机探针（`/mui nameplates auras`）：只读清点每块牌子的引擎光环容器 —— 存在与否、
--- 绑到哪个单位、子框数、宽度。判别法（§8.143）：**子框 0 个 = 引擎从没分配过**（绑定写错 /
--- 容器没被纳入刷新），**宽度是 SECRET = 引擎真的排版过**。全部读数走 Query / Text 漏斗。
--- 引擎那三行 `SetTexture` 的可判读出口是 `GetTextureFilePath`（引擎在 `auraData.icon` 为 nil 时
--- 写 `QUESTION_MARK_ICON`，见 `Blizzard_AuraContainerUtil.lua` 的 `SetIconTextureForAura`）——
--- 但这条在**姓名板上两头都读不出内容**（见下），所以分档只对能读到路径的框体有意义。
---
--- **1.60 / 71037 实测（2026-11-23）**：引擎写过的姓名板图标，`GetTextureFilePath` 在**两种执行
--- 上下文里都拿不到内容** —— `try`/`run`（ForceTaint_Strong 污染）里返回**机密字符串**，未污染的
--- `/mui` 路径里直接**读不到**（nil / forbidden / 抛错）。同一批纹理两种读数相反，说明「机密」只代表
--- 「这条读数来自被污染的调用」，**不是**「引擎写了图标」的证据（对照：`try` 下 机密 10 / 读不到 0，
--- `/mui` 下 机密 0 / 读不到 10）。⇒ 真/问号/空三档对姓名板不可达；图标有没有画出来只认
--- `显`（图标纹理 IsShown）、`子框`（引擎池大小）、`宽=机密`（引擎排版过）和截图。
local function IconReport(container, limit)
    local kids = Query(ChildrenOf, container)
    if not kids then return "子框读不到" end
    local seen, shown, shownUnread = 0, 0, 0
    local real, question, blank, secret, forbidden = 0, 0, 0, 0, 0
    local samples = {}
    for i = 1, #kids do
        local button = kids[i]
        local icon = Marked(button, "auraIcon")
        if icon then
            seen = seen + 1
            local vis = Query(icon.IsShown, icon)
            if vis == nil or Secrets.IsSecret(vis) then
                shownUnread = shownUnread + 1
            elseif Secrets.Bool(vis, false) then
                shown = shown + 1
            end
            local path = Query(icon.GetTextureFilePath, icon)
            local tag
            if Secrets.IsSecret(path) then
                secret = secret + 1
                tag = "机密"
            elseif type(path) ~= "string" then
                forbidden = forbidden + 1
                tag = "读不到"
            elseif path == "" then
                blank = blank + 1
                tag = "空"
            elseif string.upper(path):find("QUESTIONMARK", 1, true) then
                question = question + 1
                tag = "问号"
            else
                real = real + 1
                -- 只留文件名尾巴，整条路径太长会把聊天行挤断。
                tag = path:match("([^\\/]+)$") or path
            end
            if seen <= limit then samples[#samples + 1] = tag end
        end
    end
    if seen == 0 then return "无图标纹理", samples end
    return string.format("图标 %d（显 %d / 显?%d / 真 %d / 问号 %d / 空 %d / 机密 %d / 读不到 %d）",
        seen, shown, shownUnread, real, question, blank, secret, forbidden), samples
end

function M:ProbeAuras()
    local stamp
    if type(_G.date) == "function" then
        local okDate, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
        if okDate then stamp = s end
    end

    local rows, total, bound, laidOut, missing = {}, 0, 0, 0, 0
    for unit, plate in pairs(plates) do
        total = total + 1
        local container = plate.auraContainer
        if not container then
            missing = missing + 1
            rows[#rows + 1] = { unit = Text(unit), container = false, kids = 0 }
        else
            bound = bound + 1
            local kids = Query(ChildrenOf, container)
            local kidCount = kids and #kids or -1
            local width = Query(container.GetWidth, container)
            local alpha = Query(container.GetAlpha, container)
            local shown = Query(container.IsShown, container)
            local secretWidth = Secrets.IsSecret(width)
            if secretWidth or (type(width) == "number" and width > 1) then laidOut = laidOut + 1 end
            local iconText, samples = IconReport(container, 6)
            rows[#rows + 1] = {
                unit = Text(unit), container = true, kids = kidCount,
                width = Text(width), secretWidth = secretWidth,
                alpha = Text(alpha), shown = Text(shown),
                plateShown = Text(Query(plate.IsShown, plate)),
                icons = iconText, iconSamples = samples,
            }
        end
    end

    local enabled = Setting("showAuras") ~= false
    local report = {
        when = stamp,
        showAuras = enabled,
        plates = total,
        withContainer = bound,
        withoutContainer = missing,
        engineLaidOut = laidOut,
        auraWarned = auraWarned or nil,
        auraStyleError = auraStyleErr or nil,
        rows = rows,
        note = "只读。子框 0 = 引擎没分配过；宽度=机密 或 >1 = 引擎已排版（§8.143 判别法）。" ..
               " 图标：显 = 图标纹理 IsShown（能读到就有意义）；真/问号/空 只在路径读得到时才可能命中；" ..
               "机密 = 读数来自被污染调用（ForceTaint_Strong），不是「引擎写了图标」的证据；" ..
               "读不到 = nil/forbidden/抛错。1.60/71037 上姓名板图标路径两头都读不出内容，别拿它判断有无图标。",
    }
    local saved = false
    if type(ns.DB) == "function" then
        local okDb, db = pcall(function() return ns:DB() end)
        if okDb and type(db) == "table" then
            saved = pcall(function() db.nameplateAuras = report end) and true or false
        end
    end

    ns:Print(string.format("姓名板光环：开关 %s · 牌 %d 块 · 有容器 %d / 无 %d · 引擎已排版 %d%s",
        enabled and "开" or "关", total, bound, missing, laidOut,
        auraWarned and " · 本会话建容器失败过" or ""))
    if auraStyleErr then
        ns:Print("  换肤抛错：" .. auraStyleErr)
    end
    for i = 1, math.min(#rows, 12) do
        local r = rows[i]
        if r.container then
            ns:Print(string.format("  #%d %-12s 子框=%-3s 宽=%-6s α=%-5s 容器显=%-5s 牌显=%s",
                i, r.unit, tostring(r.kids), r.width, r.alpha, r.shown, r.plateShown))
            ns:Print(string.format("     %s%s", tostring(r.icons),
                (r.iconSamples and #r.iconSamples > 0)
                    and ("  " .. table.concat(r.iconSamples, " ")) or ""))
        else
            ns:Print(string.format("  #%d %-12s （没有容器）", i, r.unit))
        end
    end
    if #rows > 12 then ns:Print(string.format("  …另有 %d 块只在账本里。", #rows - 12)) end
    if total == 0 then
        ns:Print("  当前没有牌 —— 走到怪边上（或战斗中）再跑一次，空转读数说明不了问题。")
    end
    ns:Print(saved and "全量已存 MonetUIDB.nameplateAuras（落盘比 /reload 晚 1–2 分钟）。"
        or "账本没打开，只有聊天框这几行。")
end

function M:HandleCommand(rest)
    local sub = string.lower(rest or "")

    -- `/mui nameplates probe cvar`（也收 `/mui nameplates cvar`，客户端里少敲两个词）
    if sub:find("^probe%s+cvar") or sub:find("^cvar") then
        self:ProbeCVars()
        return true
    end

    -- `/mui nameplates siblings`：只读清点 base 下的同级子框（真名 + alpha）→ 账本
    if sub:find("^siblings") or sub:find("^probe%s+siblings") then
        self:ProbeSiblings()
        return true
    end

    -- `/mui nameplates auras`：只读清点引擎光环容器（存在 / 绑定 / 子框数 / 宽度）
    if sub:find("^auras") or sub:find("^probe%s+auras") then
        self:ProbeAuras()
        return true
    end

    if sub ~= "diagnose" and sub ~= "diag" and sub ~= "probe" then return false end

    -- 同一本账：确认 + 打印交给 `Skin:Verify`，`/mui skins diagnose` 才会一起带上这些名字。
    local _, missing = ns.Skin:Verify("nameplates", PROBED, "姓名板对象自检（本客户端实测）：")
    if missing > 0 then
        ns:Print(string.format("%d 个缺失：全部已按特性探测跳过，不会报错；"
            .. "`NamePlateDriverFrame` 缺失时点击区仍会在设置/区域变化时重设。", missing))
    end
    ns:Print("  另：|cffffd100/mui nameplates probe cvar|r 读那 8 个 CVar 的可写性与写入判决账。")
    return true
end

ns:Register("Nameplates", M)
