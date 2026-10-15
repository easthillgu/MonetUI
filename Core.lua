-- MonetUI Core.lua
-- Entry point: saved settings, module registry & lifecycle, theme plumbing.
--
-- Every file in this addon shares the private namespace table `ns` (the second
-- value of `...`).  The Utils files hang themselves off it (ns.Color, ns.Widget,
-- ns.Secrets, ...) so modules never need a global lookup.  Core adds the module
-- registry on top of it and exposes it as the global `MonetUI` for convenience.

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

ns.name = ADDON_NAME
ns.version = "0.9.0"

-- -- Defaults ----------------------------------------------------------------

local DEFAULTS = {
    enabled = true,
    modules = {
        UnitFrames   = true,
        Cooldown     = true,
        BuffFrame    = true,
        Minimap      = true,
        BagFrame     = true,
        QuestTracker = true,
        ActionBars   = true,
        Nameplates   = true,
        Skins        = true,
    },
    theme = {
        useMonetColor  = true,
        tintBlizzard   = true,
        -- Which engine slot borders are drawn from: "edge" | "ambient" |
        -- "highlight" | "neutral" (see Color:GetBorderKey).  Unit frames, the
        -- minimap panel, action bars, buffs, bags, the quest tracker and the
        -- config panel all follow it, so one dropdown re-tints every border.
        borderKey      = "edge",
    },
    -- Thin bars in Andromeda's layout (see docs/mockup).  Sizes and positions are
    -- both stored per unit so they can be tuned without touching the code; the
    -- "relativeTo" field names either UIParent or another unit frame, which lets
    -- target / focus / pet follow the player frame.
    --
    -- Health is 2px: half of Andromeda's configured 4.  Andromeda also rescales
    -- UIParent (~0.53 at 1440p) while MonetUI draws 1:1, so copying its number
    -- straight over would come out about twice as thick here.
    --
    -- Health colouring, per unit:
    --   fillColor = "highlight"  the Monet signature wash (player, pet)
    --             = "class"      the colour the game itself draws the unit in:
    --                            class colour for players, reaction colour for
    --                            NPCs (target, focus, targettarget)
    --             = "health"     the flat UI health green
    --   lostColor = "black"      the missing part reads as background (player, pet)
    --             = "danger"     the missing part reads as damage taken (target)
    --   powerColor = "type"      the power bar is coloured by UnitPowerType
    --              = "theme"     the power bar keeps the flat theme resource colour
    -- textColorByPercent ramps the health number green -> red as health drops.
    -- smoothBars eases every bar towards its new value (the client does the
    -- easing, so it still works while the values are hidden).
    --
    -- classPower draws the player's combo points (rogue / feral druid) as one
    -- slim pip per point under the player frame.  Blizzard keeps that display
    -- inside PlayerFrame, which this addon hides, so without it a rogue would see
    -- its energy bar and no combo points at all
    -- (see CLASS_POWER in Modules/UnitFrames/UnitFrames.lua).
    --   classPower        false turns the pips off
    --   classPowerHeight  how tall one pip is
    --   classPowerGap     gap between pips (also the breathing room under the frame)
    unitFrames = {
        hideBlizzard = true,
        -- 1px Monet border, then the gap Andromeda keeps between its health and
        -- power bars (its C.MULT, ~1px at 1440p).
        border = 1,
        split  = 1,
        textColorByPercent = true,
        smoothBars = true,
        powerColor = "type",
        classPower       = true,
        classPowerHeight = 3,
        classPowerGap    = 3,
        player = { width = 160, health = 2, power = 1, fillColor = "highlight", lostColor = "black",
                   point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0,    y = -180 },
        target = { width = 160, health = 2, power = 1, fillColor = "class", lostColor = "danger",
                   point = "LEFT",   relativeTo = "player",   relativePoint = "RIGHT",  x = 40,   y = 40 },
        targettarget = { width = 60, health = 2, power = 1, fillColor = "class", lostColor = "danger",
                   point = "LEFT",   relativeTo = "target",   relativePoint = "RIGHT",  x = 6,    y = 0 },
        pet    = { width = 60,  health = 2, power = 1, fillColor = "highlight", lostColor = "black",
                   point = "RIGHT",  relativeTo = "player",   relativePoint = "LEFT",   x = -6,   y = 0 },
        focus  = { width = 60,  health = 2, power = 1, fillColor = "class", lostColor = "danger",
                   point = "RIGHT",  relativeTo = "player",   relativePoint = "LEFT",   x = -100, y = -40 },
    },
    -- Blizzard's default bottom chrome is taken off screen; the buttons keep
    -- working for keybinds because they are re-parented, not destroyed.
    --
    -- ownBars: MonetUI draws its own 1..8 keyed on LibActionButton-1.0 (see
    -- Modules/ActionBars/ActionBars.lua) and parks Blizzard's bars.  With it off
    -- the Blizzard bars are kept, and only "hideBlizzard" can still hide them.
    -- barCount / buttonSize / spacing describe the look; positions holds an
    -- optional per-bar override of the first-run anchors in BAR_DEFS.
    --
    -- First-run layout (see BAR_DEFS): 1/2/3 stacked bottom-centre, the pet bar
    -- right-aligned and the stance bar left-aligned on the row above 3, and
    -- 4..8 stacked on upward but hidden until barCount is raised.
    actionBars = {
        ownBars      = true,
        hideBlizzard = true,
        hideBagBar   = true,
        barCount     = 3,
        buttonSize   = 28,
        spacing      = 2,
        showHotkey   = true,
        showCount    = true,
        showMacro    = true,
        positions    = {},
    },
    -- Nameplates (姓名板) sit on top of Blizzard's own plate bases (see
    -- Modules/Nameplates/Nameplates.lua): the base owns targeting/clicks, the
    -- module draws a Monet slim bar on it and hides Blizzard's UnitFrame child.
    --
    -- Which units the *game* gives a plate to is a CVar, so the show* switches
    -- below are pushed into nameplateShowFriends/Enemies/... on Apply, and put
    -- back when the module is turned off.  hideCritters/hideDead are an extra
    -- addon-side filter on top of that.
    --
    -- width/height are the health box; nameSize is the name/level row above it
    -- and castHeight the cast bar below.  forcePlateSize matches Blizzard's
    -- clickable hitbox to the drawn box (much smaller than its default), so a
    -- click lands on the plate you actually see.
    nameplates = {
        showFriendly = false,   -- friendly players (Blizzard default: off)
        showEnemy    = true,    -- hostile players and npcs
        showNPC      = false,   -- friendly npcs (guard / quest givers)
        showMinor    = true,    -- "minus" mobs (the client's enemy-minus CVar)
        showTotems   = true,
        showSelf     = false,
        hideCritters = true,
        hideDead     = false,
        viewDistance = 60,      -- nameplateMaxDistance

        width        = 120,
        height       = 12,
        nameSize     = 11,
        showName     = true,
        showLevel    = true,
        showPercent  = true,
        truncate     = true,
        nameLength   = 16,

        showCast     = true,
        castHeight   = 13,

        showThreat      = true,
        highlightTarget = true,
        showDebuffs     = true,
        classColor      = true,
        smooth          = true,
        forcePlateSize  = true,
        auraGap         = 4,
    },
    -- Blizzard panel beautification (see Modules/Skins/Skins.lua): the vanilla
    -- windows (quests, world map, character sheet, collections, social, mail /
    -- merchants, system dialogs) are re-plated in the Monet palette so the whole
    -- UI reads as one style.  Each window is a switch under `panels` (whose
    -- shipped defaults live with each skin); `font` is an optional global font
    -- override: "off" | "pixel" | "roadway" | "number".
    skins = {
        font   = "off",
        panels = {},
    },
}
ns.DEFAULTS = DEFAULTS

-- -- Small helpers ------------------------------------------------------------

local modules = {}
local moduleOrder = {}
local started = false

local function MergeDefaults(dst, src)
    for key, value in pairs(src) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then dst[key] = {} end
            MergeDefaults(dst[key], value)
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
    return dst
end

--- Database schema.  Bumping this re-applies the settings that changed their
-- meaning in the shipped defaults (see Migrate).
local SCHEMA = 2

--- One-off adjustments to a database written by an older MonetUI.
-- MergeDefaults only fills in *missing* keys, so a value whose number changed
-- has to be pushed explicitly.  Stored positions are the player's and are never
-- touched here.
local function Migrate(db)
    if (db.schema or 1) >= SCHEMA then return end

    -- v2: health bars halved to Andromeda's real thickness, plus health colour
    -- rules (fillColor / lostColor) for the new bar styling.
    for unit, defaults in pairs(DEFAULTS.unitFrames) do
        if type(defaults) == "table" then
            local stored = db.unitFrames[unit]
            if type(stored) == "table" then
                stored.health    = defaults.health
                stored.power     = defaults.power
                stored.fillColor = defaults.fillColor
                stored.lostColor = defaults.lostColor
            end
        end
    end

    db.schema = SCHEMA
end

local function LoadDatabase()
    local db = ns:DB()
    MergeDefaults(db, DEFAULTS)
    Migrate(db)
    return db
end

function ns:Print(message)
    print("|cff88aaff[MonetUI]|r " .. tostring(message))
end

--- The saved variable table, always a table.
function ns:DB()
    if type(_G.MonetUIDB) ~= "table" then
        _G.MonetUIDB = {}
    end
    return _G.MonetUIDB
end

-- -- Module registry ----------------------------------------------------------

function ns:Register(name, module)
    assert(type(name) == "string", "Module name must be a string")
    assert(type(module) == "table", "Module must be a table")

    if not modules[name] then
        moduleOrder[#moduleOrder + 1] = name
    end
    modules[name] = module
    return module
end

function ns:GetModule(name)
    return modules[name]
end

function ns:GetModuleOrder()
    return moduleOrder
end

function ns:HasMonetColor()
    return LMC ~= nil
end

-- -- Module lifecycle ---------------------------------------------------------

function ns:IsModuleEnabled(name)
    local value = self:DB().modules[name]
    if value == nil then
        value = DEFAULTS.modules[name] ~= false
    end
    return value and true or false
end

function ns:InitializeModule(name)
    local module = modules[name]
    if not module or module._initialized then return false end

    if module.Initialize then
        local ok, err = pcall(module.Initialize, module)
        if not ok then
            self:Print("模块 " .. name .. " 初始化失败: " .. tostring(err))
            return false
        end
    end

    module._initialized = true
    return true
end

--- Enable/disable a module at runtime (used by the config panel).
function ns:SetModuleEnabled(name, value)
    local module = modules[name]
    if not module then return end

    value = value and true or false
    self:DB().modules[name] = value

    if value then
        self:InitializeModule(name)
    end
    if module.SetEnabled then
        local ok, err = pcall(module.SetEnabled, module, value)
        if not ok then
            self:Print("模块 " .. name .. " 切换失败: " .. tostring(err))
        end
    end
end

function ns:StartModules()
    if started then return end
    started = true

    if self:DB().enabled == false then
        self:Print("本体已被禁用，输入 |cffffd100/mui enable|r 启用。")
        return
    end

    for _, name in ipairs(moduleOrder) do
        if self:IsModuleEnabled(name) then
            self:InitializeModule(name)
        end
    end

    local count = 0
    for _, name in ipairs(moduleOrder) do
        if modules[name]._initialized then count = count + 1 end
    end
    self:Print(string.format("已加载 %d/%d 个模块。", count, #moduleOrder))
end

-- -- Theme --------------------------------------------------------------------

local function RefreshTheme(reason)
    ns.Color:Refresh()
    ns.EventBus:Fire("MONETUI_THEME_CHANGED", reason)
end
ns.RefreshTheme = RefreshTheme

-- -- MonetColor callback reservation -------------------------------------------

--- Opt into the engine's own "colours changed" notification, so a profile switch
-- or an engine-side refresh re-tints every border / bar straight away instead of
-- waiting for the next zone change.
--
-- LibMonetColor ships with or without CallbackHandler-1.0 and the two expose the
-- registration differently:
--   * CallbackHandler present : LMC:RegisterCallback("OnThemeColorsChanged", fn)
--   * built-in fallback       : LMC.events:RegisterCallback("MonetUI", fn)
-- so the shape is detected rather than assumed and both are pcall'd.  Either way
-- the handler is handed the event name first, which is why it ignores its
-- arguments.  No engine, or no notification, simply leaves the zone handlers
-- below as the baseline -- this is the reservation every border colour (unit
-- frames, minimap panel, action bars, buffs) hangs off through
-- Widget:Theme -> Color:GetEdge.
local function ReserveMonetColorCallback()
    if not LMC then return false end

    local handler = function() RefreshTheme("monet") end

    -- CallbackHandler style: the method is embedded on the library itself.
    if type(LMC.RegisterCallback) == "function" then
        if pcall(LMC.RegisterCallback, LMC, "OnThemeColorsChanged", handler) then
            return true
        end
    end

    -- Built-in fallback registry: the method lives on LMC.events and keys on an
    -- arbitrary consumer id.
    local events = LMC.events
    if events and type(events.RegisterCallback) == "function" then
        if pcall(events.RegisterCallback, events, ADDON_NAME, handler) then
            return true
        end
    end

    return false
end

--- True when the engine itself will tell us about colour changes.
ns.hasMonetColorCallback = ReserveMonetColorCallback()

-- -- Slash commands -----------------------------------------------------------

local function PrintStatus()
    local source, profile = ns.Color:GetSource()
    ns:Print(string.format("v%s | MonetColor: %s | 主题来源: %s%s | 回调: %s",
        ns.version,
        ns:HasMonetColor() and "|cff00ff00已接入|r" or "|cffff6b6b未找到|r",
        source,
        source == "monet" and ("（" .. tostring(profile) .. "）") or "",
        ns.hasMonetColorCallback and "|cff00ff00已订阅|r" or "|cff808080未订阅|r"))

    for _, name in ipairs(moduleOrder) do
        local module = modules[name]
        local state
        if not ns:IsModuleEnabled(name) then
            state = "|cff808080关闭|r"
        elseif module._initialized then
            state = "|cff00ff00开启|r"
        else
            state = "|cffffd100待机|r"
        end
        ns:Print(string.format("  - %-13s %s", name, state))
    end

    local er, eg, eb = ns.Color:GetEdge()
    ns:Print(string.format("边缘色 |cff%s|r (%.2f, %.2f, %.2f)   %s",
        ns.Math:RGBToHex(er, eg, eb), er, eg, eb, ns.Secrets:Describe()))
end

local function PrintHelp()
    ns:Print("命令：")
    ns:Print("  |cffffd100/mui|r            打开配置面板")
    ns:Print("  |cffffd100/mui status|r     显示模块与主题状态")
    ns:Print("  |cffffd100/mui theme|r      重新采样环境色彩")
    ns:Print("  |cffffd100/mui enable|r     启用本体")
    ns:Print("  |cffffd100/mui disable|r    禁用本体（需 /reload）")
    ns:Print("  |cffffd100/mui <模块> on|off|r  单独开关模块")
    ns:Print("  |cffffd100/mui reset|r      恢复默认设置（需 /reload）")
end

local function HandleSlash(message)
    local command, rest = string.match(message or "", "^(%S*)%s*(.-)$")
    command = string.lower(command or "")

    if command == "" or command == "config" or command == "options" then
        if ns.Config and ns.Config.Toggle then
            ns.Config:Toggle()
        else
            ns:Print("配置面板尚未加载。")
        end

    elseif command == "status" then
        PrintStatus()

    elseif command == "theme" then
        RefreshTheme("manual")
        local er, eg, eb = ns.Color:GetEdge()
        ns:Print(string.format("主题已刷新：边缘色 #%s (%.2f, %.2f, %.2f)",
            ns.Math:RGBToHex(er, eg, eb), er, eg, eb))

    elseif command == "enable" then
        ns:DB().enabled = true
        ns:Print("已启用，执行 /reload 后生效。")

    elseif command == "disable" then
        ns:DB().enabled = false
        ns:Print("已禁用，执行 /reload 后生效。")

    elseif command == "reset" then
        _G.MonetUIDB = nil
        ns:Print("设置已重置，执行 /reload 后生效。")

    elseif command == "help" then
        PrintHelp()

    else
        local wanted = string.lower(command)
        local moduleName
        for key in pairs(modules) do
            if string.lower(key) == wanted then
                moduleName = key
                break
            end
        end

        if moduleName then
            if rest == "on" or rest == "1" then
                ns:SetModuleEnabled(moduleName, true)
                ns:Print("模块 " .. moduleName .. " 已开启。")
            elseif rest == "off" or rest == "0" then
                ns:SetModuleEnabled(moduleName, false)
                ns:Print("模块 " .. moduleName .. " 已关闭。")
            else
                ns:Print("用法：/mui " .. moduleName .. " on|off")
            end
        else
            PrintHelp()
        end
    end
end

SLASH_MONETUI1 = "/monetui"
SLASH_MONETUI2 = "/mui"
SlashCmdList["MONETUI"] = HandleSlash

-- -- Boot ---------------------------------------------------------------------
-- EventBus owns the only frame; every listener below is registered on it.

ns.EventBus:Register("ADDON_LOADED", function(_, addonName)
    if addonName ~= ADDON_NAME then return end
    LoadDatabase()
end)

ns.EventBus:Register("PLAYER_LOGIN", function()
    LoadDatabase()
    RefreshTheme("login")
    ns:StartModules()

    ns:Print(string.format("v%s 已加载。MonetColor: %s。输入 |cffffd100/mui|r 打开配置。",
        ns.version,
        ns:HasMonetColor() and "|cff00ff00已接入|r" or "|cffff6b6b未找到（使用内置调色板）|r"))
end)

-- The engine recomputes on zone changes; we only need to pick the new colours up
-- and tell the modules about it.
ns.EventBus:Register("ZONE_CHANGED",       function() RefreshTheme("zone") end)
ns.EventBus:Register("ZONE_CHANGED_INDOORS", function() RefreshTheme("zone") end)
ns.EventBus:Register("ZONE_CHANGED_NEW_AREA", function() RefreshTheme("zone") end)
ns.EventBus:Register("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
    if not isInitialLogin and not isReloadingUi then
        RefreshTheme("world")
    end
end)

-- Restricted states (combat / PvP) may hide values again, so let modules refresh
-- their text once the restriction lifts.
ns.EventBus:Register("ADDON_RESTRICTION_STATE_CHANGED", function()
    ns.EventBus:Fire("MONETUI_RESTRICTION_CHANGED")
end)

_G.MonetUI = ns
