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
    ns:Print(("|cffffa940姓名板有 %d 项设置客户端不让插件改（isSecure）：%s|r —— "
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
    WriteCVar("nameplateMaxDistance",       tostring(Setting("viewDistance") or 60))
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

    plate.cast:SetSize(width, castHeight)
    Widget:SyncBarFill(plate.cast.fill, castHeight - BORDER * 2)
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

--- 读一个暴雪对象的 alpha：读不出来（机密 / forbidden / 没有这个方法）返回 nil。
--- @return number|nil
local function AlphaOf(obj)
    if not obj or type(obj.GetAlpha) ~= "function" then return nil end
    local ok, value = pcall(obj.GetAlpha, obj)
    if not ok or type(value) ~= "number" or Secrets.IsSecret(value) then return nil end
    return value
end

--- 这一拍要不要压回 0。读得出来且已经是 0 就跳过 —— 常态下守卫 4 次/秒，几乎全是
--- "把已经是 0 的 alpha 再写一遍"（8.25 那笔账）。
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
local siblingFaded = setmetatable({}, { __mode = "k" })   -- 还原时要知道哪些被我们压过
local siblingAlpha = setmetatable({}, { __mode = "k" })   -- 它们被压之前自己的 alpha（交还要还原）

local function FadeBlizzardSiblings(base, keep)
    if not base or type(base.GetChildren) ~= "function" then return end
    -- `ipairs({ base:GetChildren() })` 里那层 `{}` 是白建的第二张表：GetChildren 本来就
    -- 返回一张新表。守卫每拍每牌都走这里，40 块牌 × 4 次/秒 × 2 张表就是纯 GC 压力。
    local kids = base:GetChildren()
    for i = 1, #kids do
        local c = kids[i]
        if c ~= keep and c.SetAlpha and NeedsFade(c) then
            -- 只在**真要写**的时候记账：以前每个子框每拍都被标一遍，交还时于是把暴雪自己
            -- 按距离算出来的 alpha（实测 base 0.60）一并顶回 1 —— 只有我们动过的才该还原。
            if not siblingFaded[c] then siblingAlpha[c] = AlphaOf(c) end
            siblingFaded[c] = true
            pcall(c.SetAlpha, c, 0)
        end
    end
end

local function RestoreBlizzardSiblings(base)
    if not base or type(base.GetChildren) ~= "function" then return end
    for _, c in ipairs(base:GetChildren()) do
        if siblingFaded[c] then
            siblingFaded[c] = nil
            pcall(c.SetAlpha, c, siblingAlpha[c] or 1)
            siblingAlpha[c] = nil
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
    -- 压之前把它**当前**的 alpha 记在我们自己的牌上（不是暴雪框上）：暴雪按距离算淡出
    -- （实测 base 0.60），交还时硬写 1 会把这套淡出顶掉 —— BetterNamePlates 也是还原原值。
    if plate.blizzardAlpha == nil then plate.blizzardAlpha = AlphaOf(uf) end
    if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end
    -- IsShown 也可能返回机密值：一律过 Secrets.Bool（读不出来就当"没显示"，再 Show 一次）。
    -- Show 是受保护项（下文 456 行注释）：战斗中被拒会弹玩家可见的 ADDON_ACTION_BLOCKED
    -- （2026-11-02 实机：进本姓名板 churn 一次 9 条，BLOCKED 日志全来自这两处）。
    -- 战斗里跳过 —— 被拒的 Show 本来就是 no-op，游戏在下一个 SetUnit / 更新周期自补。
    if uf.IsShown and not InCombat()
        and not Secrets.Bool(uf:IsShown(), false) then pcall(uf.Show, uf) end
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
        if uf.SetAlpha then
            -- 还原接管前读到的那一个值；读不到（当时就机密）才退回 1 —— 那是暴雪自己的默认满不透明。
            pcall(uf.SetAlpha, uf, (plate and plate.blizzardAlpha) or 1)
        end
        -- 同 HideBlizzardPlate：战斗里 Show 必被拒（弹 ADDON_ACTION_BLOCKED），
        -- 跳过，等游戏自己的 SetUnit / 更新周期补齐。
        if not InCombat() then pcall(uf.Show, uf) end
    end
    RestoreBlizzardSiblings(base)
    if plate then
        plate.blizzardHidden = nil
        plate.blizzardUF = nil
        plate.blizzardAlpha = nil
    end
    return uf ~= nil
end

-- The fill computes only with GetTime() (our own plain number) and hands SetValue a value the
-- client clamps against the secret start/end; the timer text needs math, only when end came plain.
local function CastTick(plate)
    local cast = plate.cast
    if not cast or not plate.castActive then return end

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

-- 投射条驱动只在"有条在走"的那段时间挂在 plate 上（HideCast 摘掉），常驻订阅会让空闲
-- 名板也每帧空转。所以它走外部账：所有 plate 共用一个 key，账合成一路。
local CastTickTracked = ns.Scheduler and ns.Scheduler:Profile("nameplates:cast", "名板投射条", CastTick)
    or CastTick

local function HideCast(plate)
    local cast = plate.cast
    if not cast then return end
    plate.castActive = nil
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
    -- `startMS or 0` 是机密数字上的一次真值测试（`or` 走 truth test，同族拦截），所以零值
    -- 兜底只对**非机密**做；机密原样交给 widget（SetMinMaxValues 允许机密）。
    local from, to = startMS, endMS
    if not Secrets.IsSecret(from) then from = from or 0 end
    if not Secrets.IsSecret(to) then to = to or 1 end
    pcall(plate.cast.fill.SetMinMaxValues, plate.cast.fill, from, to)
    -- 只存"有条在走"这个普通布尔：存原始 endMS 会让 CastTick 每帧对它做真值测试。
    -- 机密/读不到 end 时沿用旧行为 —— 不跑每帧 SetValue，条保持静态（保留上次状态）。
    plate.castActive = (not Secrets.IsSecret(endMS) and endMS ~= nil)

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
        -- 宽度读回来也可能成机密（与 Widget:FitText 头部同一课：锚在机密几何上时
        -- GetStringWidth 会变机密）—— 对机密宽度比大小就是被拦调用。
        if type(levelW) == "number" and not Secrets.IsSecret(levelW) and levelW > 0 then
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
    -- **守卫里不再 `Show()`**（这是这一档改动的主要目的）：以前每拍都问一次 `IsShown`、
    -- 没显示就补一刀 `Show`，而它没有战斗门 —— 战斗中必被拒，2026-11-02 进本那 9 条
    -- `ADDON_ACTION_BLOCKED` 就来自 Show 这一处（接管那一次的 Show 在 HideBlizzardPlate 里，
    -- 那边有 `not InCombat()` 门，保留）。暴雪把牌子藏回去时会在下一次 SetUnit / 更新
    -- 周期自己 Show（BetterNamePlates 从头到尾不 Show，就是等这一手）；alpha 已经 0 的框
    -- 视觉上本来就没有可看见的东西，晚一拍点亮不影响压制。
    if uf.SetAlpha and NeedsFade(uf) then
        if plate.blizzardAlpha == nil then plate.blizzardAlpha = AlphaOf(uf) end
        pcall(uf.SetAlpha, uf, 0)
    end
    FadeBlizzardSiblings(plate.base, plate)
end

-- ---- 目标高亮回压守卫（2026-10-28 实机判例）--------------------------------------
-- 牌子成为**当前目标**时，暴雪自己的更新把 UnitFrame 的 alpha 重设回 1（目标高亮，
-- base alpha 同时到 1.0）。我们的回压只挂在 UpdatePlate（事件驱动）里，目标切换那一刻
-- 暴雪抢先、之后就没人再压 —— 表现是"当前目标的暴雪牌整块亮着，和自绘牌同屏"，
-- 它右侧的减益列也跟着回来（探针实锤：假人牌 blizzardHidden=true 但 ufAlpha=1.00）。
-- 低频守卫对全部 blizzardHidden 的牌子整树回压；PLAYER_TARGET_CHANGED 再补一记即时的。
local guardJob = nil
local GUARD_INTERVAL_MS = 250

local function GuardTick()
    if not M.active then return end
    for _, plate in pairs(plates) do
        if plate.blizzardHidden and plate.base then
            KeepBlizzardHidden(plate)
        end
    end
end

--- 回压订阅只在**真有牌压着**的时候存在。以前是一个私有 `CreateFrame("Frame")` + OnUpdate
--- 常驻：`M.active` 为假时它照样每帧醒一次再早退（累加器省的是回调次数，省不下唤醒），
--- 屏幕上一块牌都没有时也是。现在计数归零就摘掉订阅 —— `Utils/Scheduler` 的主框随之
--- 隐藏，空闲时一个回调都不跑，全仓也少一个常驻驱动帧（8.26.7 第 1 条）。
--- 调用点 = 任何让 `blizzardHidden` 增减的地方：`UpdatePlate` / `Apply` / `SetEnabled`。
function M:SyncGuard()
    local n = 0
    for _, plate in pairs(plates) do
        if plate.blizzardHidden and plate.base then n = n + 1 end
    end
    if n == 0 then
        if guardJob then
            ns.Scheduler:Unregister(guardJob)
            guardJob = nil
        end
    elseif not guardJob then
        guardJob = ns.Scheduler:Every(GUARD_INTERVAL_MS, GuardTick, "姓名板:守卫")
    end
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
        M:SyncGuard()
        return false
    end

    if not plate.blizzardHidden then
        HideBlizzardPlate(plate.base, plate)
    else
        KeepBlizzardHidden(plate)
    end
    M:SyncGuard()

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
    if type(unit) ~= "string" or Secrets.IsSecret(unit) then return false end
    local plate = plates[unit]
    if not plate then return false end

    plates[unit] = nil
    plate.unit = nil
    plate:UnregisterAllEvents()
    plate:SetScript("OnUpdate", nil)
    plate.castActive = nil
    plate.castEndClock = nil
    plate:Hide()
    plate.cast:Hide()
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

    self:SyncGuard()      -- 一块牌都不剩：摘掉回压订阅，Scheduler 主框跟着隐藏
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

function M:ProbeSiblings()
    local stamp
    if type(_G.date) == "function" then
        local okDate, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
        if okDate then stamp = s end
    end

    local rows = {}
    local plateCount, unreadable, buffListHits = 0, 0, 0

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
            local okKids, kids = pcall(base.GetChildren, base)
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
                    rows[#rows + 1] = {
                        unit      = Text(unit),
                        base      = baseName,
                        index     = i,
                        name      = name,
                        alpha     = AlphaOf(c),
                        ours      = (c == plate) or nil,
                        unitFrame = (c == uf) or nil,
                        fadedByUs = siblingFaded[c] or nil,
                        priorAlpha = siblingAlpha[c],
                    }
                end
            elseif okKids and type(kids) == "table" then
                -- 有 base、一个子框都没有：要么牌刚出生还没装配，要么这一路的 alpha 全靠 base 继承
                rows[#rows + 1] = { unit = Text(unit), base = baseName, name = "（无子框）" }
            else
                unreadable = unreadable + 1
                rows[#rows + 1] = { unit = Text(unit), name = "（base 子树读不出）" }
            end
        end
    end

    local lockdown = false
    if type(InCombatLockdown) == "function" then
        local okL, v = pcall(InCombatLockdown)
        lockdown = (okL and v) and true or false
    end

    local report = {
        when           = stamp,
        plates         = plateCount,
        unreadableBases = unreadable,
        buffListHits   = buffListHits,
        lockdown       = lockdown,
        truncated      = (#rows >= SIBLING_ROW_CAP) or nil,
        rows           = rows,
        note           = "只读：GetName 过 Text() 防机密串，alpha 走 AlphaOf（nil=读不出）。"
            .. "buffListHits>0 就是 BlizzardBasePlate 下确有同级光环容器，FadeBlizzardSiblings 的覆盖面判据。",
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
        ns:Print("姓名板 siblings：当前没有牌（不在战斗中/没姓名板可见）——空转，账本已写 plates=0。")
    end
    for i = 1, math.min(#rows, SIBLING_PRINT) do
        local r = rows[i]
        local tag = r.ours and "（我们自绘）" or (r.unitFrame and "（暴雪 UnitFrame）") or ""
        ns:Print(string.format("  #%d %-28s α=%-6s%s%s",
            i, r.name, (r.alpha and string.format("%.2f", r.alpha)) or "读不出",
            tag, r.fadedByUs and " [我们压过]" or ""))
    end
    if #rows > SIBLING_PRINT then
        ns:Print(string.format("  …另有 %d 行只在账本里。", #rows - SIBLING_PRINT))
    end
    ns:Print(string.format("判据：牌 %d 块 / 读不出 %d / buffList 命中 %d —— %s",
        plateCount, unreadable, buffListHits,
        (buffListHits > 0) and "有同级光环容器，需确认压暗覆盖到它"
            or "本趟没出现 BuffListFrame（不等于不存在，战斗里再跑一趟）"))
    ns:Print(saved
        and "全量已存 MonetUIDB.nameplateSiblings —— 写入比 /reload 晚 1–2 分钟，别立刻读（登出后再读最稳）。"
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
