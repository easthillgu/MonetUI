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
    local height = Setting("height") or 12

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
local function PlateHeight() return Setting("height") or 12  end

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
    local lost = health:CreateTexture(nil, "BACKGROUND")
    lost:SetAllPoints(health)
    lost:SetVertexColor(0, 0, 0, 1)

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
    local castHeight = Setting("castHeight") or 13

    plate:SetSize(width, height)
    plate.health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    plate.health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)
    plate.health:SetStatusBarTexture(ns.Media:Texture("barfill"))
    -- SetStatusBarTexture builds a NEW texture object, so the fill gradient has to be re-derived here or
    -- the bar comes back unshaded after every relayout.
    Widget:BarGradient(plate.health)

    plate.name:SetShown(Setting("showName") ~= false)
    plate.level:SetShown(Setting("showLevel") ~= false)
    plate.name:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
    plate.level:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
    plate.percent:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
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

-- 已修饰的 debuff 按钮数：`/mui nameplates diagnose` 会打印，用来判断 B1 到底有没有找到东西。
local dressedDebuffs = 0
-- 边框颜色的来源统计：`dispel` = 读到了暴雪的驱散色，`theme` = 退回主题色。
-- 实机上如果 theme 一直涨，说明这个客户端把驱散色烘在贴图里，顶点色读不出来。
local dispelBorders, themeBorders = 0, 0

local DEBUFF_W, DEBUFF_H = 18, 14       -- 和目标框的原生 AuraContainer 同一个矩形
local DEBUFF_V_CROP = 2                 -- 18:14 的竖向裁边（上下各 2px）
local DEBUFF_TEXT_MIN, DEBUFF_TEXT_MAX = 8, 14

--- 按名字取一张贴图（只要有 SetTexCoord 就当候选）。
local function TextureOf(button, ...)
    for i = 1, select("#", ...) do
        local tex = rawget(button, (select(i, ...)))
        if type(tex) == "table" and type(tex.SetTexCoord) == "function" then return tex end
    end
end

--- 给一个借来的 debuff 按钮补上 Monet 外观（reskin，不换数据、不做过滤）。
-- 暴雪的 AurasFrame 继续负责「画什么」，这里只负责「长什么样」：
--   1. 图标裁边（和施法图标同一比例）；
--   2. 淡掉暴雪的厚边框，用 1px 重画 —— 颜色优先取它的顶点色（驱散类型编码），
--      读不到就退回主题边框色；
--   3. 层数 / 剩余时间换 pixel 数字字体。
-- 冷却扫圈保留（关掉描边，扫圈继续走）。
-- 全部不依赖暴雪内部成员名：名字优先、几何判据兜底，任何一步失败静默跳过。
local function DressDebuffButton(button)
    if not button or type(button) ~= "table" then return end

    local d = Marked(button, "debuff")
    if not d then
        d = { fonts = {} }
        Mark(button, "debuff", d)
        dressedDebuffs = dressedDebuffs + 1

        -- 宽度在受限环境里可能是**机密值**：`type(x)=="number"` 挡不住（机密值也报 number），
        -- 直接比较会抛 "attempt to compare ... (a secret number value, while execution tainted by 'MonetUI')"。
        -- 一律先过 Secrets.Number：拿不到明文就当"不知道宽度"，跳过这条几何判据。
        local okW, bw = pcall(button.GetWidth, button)
        bw = okW and Secrets.Number(bw) or nil
        if not (type(bw) == "number" and bw > 0) then bw = nil end

        local okR, regions = pcall(function() return { button:GetRegions() } end)
        if not okR or not regions then regions = {} end

        -- 1) 暴雪的边框：名字优先，再退到「比按钮本身还宽」（图标不会超出按钮）。
        local stock = TextureOf(button, "Border", "DebuffBorder", "border", "IconBorder")
        if not stock and bw then
            for i = 1, #regions do
                local r = regions[i]
                local okRW, rw = pcall(r.GetWidth, r)
                rw = okRW and Secrets.Number(rw) or nil
                if type(rw) == "number" and rw > bw + 0.5 then stock = r; break end
            end
        end

        -- 2) 图标：名字优先，再取「不是边框、且至少和按钮一样宽」的那张。
        local icon = TextureOf(button, "Icon", "icon")
        if not icon and bw then
            for i = 1, #regions do
                local r = regions[i]
                if r ~= stock and type(r.SetTexCoord) == "function" then
                    local okRW, rw = pcall(r.GetWidth, r)
                    rw = okRW and Secrets.Number(rw) or nil
                    if type(rw) == "number" and rw >= bw - 0.5 then icon = r; break end
                end
            end
        end
        if icon then
            pcall(icon.SetTexCoord, icon, 0, 1,
                DEBUFF_V_CROP / DEBUFF_W, 1 - DEBUFF_V_CROP / DEBUFF_W)
            d.icon = icon
        end

        -- 3) 边框：一律淡掉暴雪的厚边框，用 1px 重画。
        -- 颜色优先取暴雪那个边框的顶点色 —— 那是驱散类型的颜色编码，能保住就保住；
        -- 读不到（或读出纯白 = 颜色烘在贴图里）就退回主题边框色。
        -- 2026-10-19 的决定：宁可丢掉个别客户端的驱散色，也不要一排厚薄不一。
        local sr, sg, sb
        if stock and type(stock.GetVertexColor) == "function" then
            local okC, r, g, b = pcall(stock.GetVertexColor, stock)
            if okC and type(r) == "number" and type(g) == "number" and type(b) == "number"
                and not (r > 0.95 and g > 0.95 and b > 0.95) then
                sr, sg, sb = r, g, b
                d.borderSource = "dispel"
                dispelBorders = dispelBorders + 1
            end
        end
        if not sr then
            sr, sg, sb = Color:GetBorder()
            d.borderSource = "theme"
            themeBorders = themeBorders + 1
        end

        if stock then
            pcall(stock.SetAlpha, stock, 0)
            d.stockBorder = stock
        end

        local bd = button:CreateTexture(nil, "OVERLAY")
        bd:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
        bd:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
        pcall(bd.SetColorTexture, bd, sr, sg, sb, 1)
        d.border = bd

        -- 4) 冷却：关描边，保留扫圈。
        local okC2, children = pcall(function() return { button:GetChildren() } end)
        if okC2 and children then
            for i = 1, #children do
                local c = children[i]
                if c and type(c.GetObjectType) == "function"
                    and c:GetObjectType() == "Cooldown" then
                    pcall(c.SetDrawEdge, c, false)
                    pcall(c.SetDrawSwipe, c, true)
                    pcall(c.SetAllPoints, c, button)   -- follow the 18x14 rectangle
                    d.cooldown = c
                    break
                end
            end
        end

        -- 5) 文字
        for i = 1, #regions do
            local r = regions[i]
            if r and type(r.GetObjectType) == "function"
                and r:GetObjectType() == "FontString" then
                d.fonts[#d.fonts + 1] = r
                pcall(r.SetJustifyH, r, "RIGHT")
            end
        end

        -- 字号跟着矩形走：14px 高的图标配 8 号数字。
        d.size = math.max(DEBUFF_TEXT_MIN, math.min(DEBUFF_TEXT_MAX,
            math.floor(DEBUFF_H * 0.42 + 0.5)))
    end

    -- 每一次显隐都把矩形和图标压回去：这套按钮是暴雪的，回收 / 重排时它会把尺寸
    -- 和贴图坐标写回去；只在第一次设，第二次显示就退回方块了。
    pcall(button.SetSize, button, DEBUFF_W, DEBUFF_H)
    if d.icon then
        pcall(d.icon.ClearAllPoints, d.icon)
        pcall(d.icon.SetAllPoints, d.icon, button)
        pcall(d.icon.SetTexCoord, d.icon, 0, 1,
            DEBUFF_V_CROP / DEBUFF_W, 1 - DEBUFF_V_CROP / DEBUFF_W)
    end
    if d.cooldown then
        pcall(d.cooldown.SetAllPoints, d.cooldown, button)
    end

    -- 字体每次重设：暴雪回收按钮时会把字体写回去。
    for i = 1, #d.fonts do
        pcall(Widget.SetFont, Widget, d.fonts[i], d.size, "cooldown")
    end
end

--- 遍历一整个 debuff 列表，把还没打扮过的按钮补上。
--- 池化按钮第一次显示时可能还没进 GetChildren()；以前给每个按钮挂 OnShow 补一次，
--- 现在不挂了（HookScript 写脚本槽 = 污染，见 AGENTS）。AnchorDebuffs 在每次
--- UpdatePlate 里都会重跑，池化按钮下一次刷新自然会被补上。
local function DressDebuffList(list)
    if not list or type(list.GetChildren) ~= "function" then return end
    local ok, children = pcall(function() return { list:GetChildren() } end)
    if not ok or not children then return end
    for i = 1, #children do
        DressDebuffButton(children[i])
    end
end

--- Your debuffs without reading any aura: Blizzard's AurasFrame is moved onto our plate (the
--- game keeps drawing it, we only say where), hung above the name row; redone per pooled plate.
local function AnchorDebuffs(auras, plate)
    local list = auras and rawget(auras, "DebuffListFrame")
    if not list or type(list.SetPoint) ~= "function" then return end

    local gap = Setting("auraGap") or 4
    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = ns.Media:SnapSize(Setting("nameSize")) + TEXT_GAP
    end

    pcall(list.ClearAllPoints, list)
    pcall(list.SetPoint, list, "BOTTOMLEFT", plate, "TOPLEFT", 0, textRow + gap)

    -- B1：借来之后补外观。列表被暴雪重排时会再走一遍，字体重新压一次。
    DressDebuffList(list)
end

local function BlizzardUnitFrame(base)
    return base and rawget(base, "UnitFrame") or nil
end

--- Take the plate over: fade Blizzard's box out (kept and still shown, see below) and borrow its aura list;
--- only faded, so a later Restore gives back exactly what the game drew.
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

    local auras = rawget(uf, "AurasFrame")
    if auras and Setting("showDebuffs") ~= false then
        if type(auras.SetParent) == "function" then pcall(auras.SetParent, auras, plate) end
        if type(auras.SetAlpha) == "function" then pcall(auras.SetAlpha, auras, 1) end
        Mark(auras, "plate", plate)
        plate.blizzardAuras = auras
        AnchorDebuffs(auras, plate)
    end

    -- Blizzard 自己的重排会再往 DebuffListFrame 上加锚点；以前这里挂
    -- hooksecurefunc(uf, "ApplyFrameOptions") 去跟。**不能挂**：secure hook 插在暴雪的调用链
    -- 中间，我们的代码一跑，同一条链后面暴雪的安全调用就会整片被拒（实机就是这条链上的
    -- `attempt to call a nil value` / `SetPoint ... anchor family`）。
    -- 改成在 UpdatePlate（每个姓名板事件都会走）里重新 AnchorDebuffs —— 独立执行，
    -- 不夹在暴雪的链里。

    plate.blizzardUF = uf
    plate.blizzardHidden = true
    return true
end

--- Hand the plate back as found (module off or unit filtered out): box shown, aura list returned.
local function RestoreBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if uf then
        local auras = rawget(uf, "AurasFrame")
        if auras and Marked(auras, "plate") then
            Mark(auras, "plate", nil)
            if type(auras.SetParent) == "function" then pcall(auras.SetParent, auras, uf) end
        end
        -- 真正会重排暴雪那套锚点的是 Base 的 ApplyFrameOptions（它自己带 NamePlateSetupOptions）；
        -- uf:ApplyFrameOptions() 缺这两个参数，进函数第一行就抛，以前的 pcall 把这条静默吞了。
        if base and type(base.ApplyFrameOptions) == "function" then
            pcall(base.ApplyFrameOptions, base)   -- the game re-anchors its own list
        end
        if uf.SetAlpha then pcall(uf.SetAlpha, uf, 1) end
        pcall(uf.Show, uf)
    end
    if plate then
        plate.blizzardHidden = nil
        plate.blizzardAuras = nil
        plate.blizzardUF = nil
    end
    return uf ~= nil
end

--- 单位要消失时只做"把借的东西还回去"这一件事，不重排、不 Show。
--- **必须做，而且必须在暴雪回收之前做**：NAME_PLATE_UNIT_REMOVED 之后
--- NamePlateDriverFrame:OnNamePlateRemoved 会 ClearUnit + ReleaseUnitFrame，把这个 UnitFrame
--- 丢回**公共池**，下一次它会被挂到**另一个** base 上。如果 AurasFrame 还挂在我们 plate
--- （它是旧 base 的孩子）上，两个姓名板的锚点族就被这一根父级连起来了 —— 于是暴雪在新 base
--- 里自己的 SetPoint 全被拒，实机就是这样报的：
---   Blizzard_NamePlateUnitFrame.lua:808（光环列表锚到 self.name）
---   Blizzard_NamePlateUnitFrame.lua:676（CastBarsContainer 锚到 self，跟光环毫无关系，
---   正好证明是"self 这一族"被别的姓名板连上了）
---   Action[SetPoint] failed because[SetPoint would result in anchor family connection]
--- 同时把 alpha 还原：回收的帧若带着 alpha 0 进池子，下一个"不接管"的姓名板（过滤掉的单位）
--- 会看不见。
local function HandBackAuras(plate)
    if not plate then return end
    local uf = plate.blizzardUF
    local auras = uf and rawget(uf, "AurasFrame")
    if auras and Marked(auras, "plate") then
        Mark(auras, "plate", nil)
        if type(auras.SetParent) == "function" then pcall(auras.SetParent, auras, uf) end
    end
    if uf and uf.SetAlpha then pcall(uf.SetAlpha, uf, 1) end
    plate.blizzardAuras = nil
    plate.blizzardHidden = nil
    plate.blizzardUF = nil
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

    return result[2], result[4], result[5], result[6],
        (channel and result[7] or result[8])
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

    local name = Query(UnitName, unit)
    if type(name) == "string" then
        -- Truncating needs a length, which a secret refuses -- a hidden name is drawn whole.
        if not Secrets.IsSecret(name) and Setting("truncate") ~= false then
            local limit = Setting("nameLength") or 16
            if #name > limit then name = name:sub(1, limit) .. "..." end
        end
        plate.name:SetText(name)
    else
        plate.name:SetText("")
    end

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
end

--- The border says what the unit is doing to you: threat first, then your target.
--- UnitThreatSituation can be secret, so it keeps the theme colour when it cannot be read.
local function UpdateBorder(plate)
    local unit = plate.unit
    local r, g, b = Color:GetBorder()

    local status = nil
    if Setting("showThreat") ~= false then
        status = Secrets.Number(Query(UnitThreatSituation, "player", unit))
    end

    if status == 3 then
        r, g, b = 0.90, 0.20, 0.20
    elseif status == 2 or status == 1 then
        r, g, b = 0.95, 0.70, 0.25
    elseif Setting("highlightTarget") ~= false
        and Secrets.Bool(Query(UnitIsUnit, unit, "target"), false) then
        r, g, b = Color:GetHighlight()
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
local function KeepBlizzardHidden(plate)
    local uf = plate.blizzardUF
    if not uf then return end
    if uf.IsShown and not uf:IsShown() then pcall(uf.Show, uf) end
    if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end
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

    -- 暴雪重排过它的光环列表时（每次 ApplyFrameOptions），这里把我们的锚点重新压一遍。
    -- 独立于暴雪的调用链，所以不会污染它（以前是挂 ApplyFrameOptions 后钩，那会把后面
    -- 的安全调用整片拖进"被 MonetUI 污染"的执行里）。
    if plate.blizzardAuras then
        AnchorDebuffs(plate.blizzardAuras, plate)
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
    -- 暴雪下一步就把这个 UnitFrame 收回公共池，借来的光环列表必须先还回去（见 HandBackAuras），
    -- 否则它会被池子带到另一个姓名板上去，把两族的锚点连起来。
    if plate.blizzardHidden then HandBackAuras(plate) end
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

    -- A new target re-tints every plate's border.
    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        if not M.active then return end
        for _, plate in pairs(plates) do UpdateBorder(plate) end
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

--- Re-apply every setting: CVars, hitbox, then repaint the plates on screen.  The borrowed
--- aura list is handed back first so a showDebuffs change is picked up by the re-hide below.
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
    ns:Print(("已修饰的 debuff 按钮：%d 个（0 表示 DebuffListFrame 没有子帧或还没显示过）"):format(dressedDebuffs))
    ns:Print(("边框颜色：驱散色 %d 个 / 主题色 %d 个（全是主题色 = 这个客户端把驱散色烘在贴图里）")
        :format(dispelBorders, themeBorders))
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
