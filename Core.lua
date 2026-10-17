-- MonetUI Core.lua
-- Entry point: saved settings, module registry & lifecycle, theme plumbing.
-- Every file shares the private namespace table `ns` (the second value of `...`); the Utils files hang off it, Core adds the module registry and exposes it as the global `MonetUI`.

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

ns.name = ADDON_NAME
ns.version = "0.10.0"

local DEFAULTS = {
    enabled = true,
    modules = {
        UnitFrames   = true,
        Cooldown     = true,
        BuffFrame    = true,
        Minimap      = true,
        BagFrame     = true,
        Bags         = true,
        QuestTracker = true,
        ActionBars   = true,
        Nameplates   = true,
        Skins        = true,
        InfoBar      = true,
    },
    theme = {
        useMonetColor  = true,
        tintBlizzard   = true,
        -- Which engine slot borders are drawn from (see Color:GetBorderKey); one dropdown re-tints every border in the addon.
        borderKey      = "edge",
    },
    -- Categorized bags & bank (Modules/Bags/Bags.lua): every slot is scanned once and claimed by the first matching category (垃圾 / 装备 / 消耗品 / 材料 / 任务 / 收藏 / 其他); each category gets its own framed, movable window tiled from `anchor`.  Reads only this client's C_Container / C_Bank APIs.
    bags = {
        iconSize       = 34,
        gap            = 4,
        columns        = 10,
        windowsPerRow  = 2,
        showReagentBag = true,
        showBank       = true,
        anchor         = { frame = "UIParent", x = -33, y = -120 },
        positions      = {},   -- per-category window spots the user dragged to
    },
    -- Cooldown countdown text (Modules/Cooldown): the renderer scales the unit itself (60s -> minutes, 1h -> hours, 24h -> days, via Math:DurationText) and treats the last alertSeconds as "tight".  false for scale hands the numbers back to Blizzard; false for alert keeps one colour and one size.
    cooldown = {
        scale        = true,
        alert        = true,
        alertSeconds = 5,
    },
    -- Unit frames in Andromeda's layout (see docs/mockup), sized per unit so target / focus / pet can follow the player frame.  Health is 2px -- half of Andromeda's configured 4, because Andromeda rescales UIParent while MonetUI draws 1:1.
    -- fillColor/lostColor/powerColor pick the bar colours (class = the colour the game itself draws the unit in; black = missing part reads as background; type = coloured by UnitPowerType); smoothBars eases every bar from the client side so it still works while values are hidden.
    -- classPower draws the player's combo points as slim pips under the player frame (Blizzard keeps them inside the PlayerFrame this addon hides); threatGlow / hoverGlow are Andromeda-style edge glows re-tinted through Widget:SetBorderState so theme refreshes cannot stomp them.
    unitFrames = {
        hideBlizzard = true,
        -- 1px Monet border, then the gap Andromeda keeps between its health and power bars (its C.MULT, ~1px at 1440p).
        border = 1,
        split  = 1,
        threatGlow = true,
        hoverGlow  = true,
        textColorByPercent = true,
        smoothBars = true,
        powerColor = "type",
        classPower       = true,
        classPowerHeight = 3,
        classPowerGap    = 3,
        -- Target auras: reparent Blizzard's own TargetFrame aura list onto our target frame (Andromeda's layout, growing up) and anchor it above.  Only the position is borrowed, never the data -- C_UnitAuras is hidden mid-fight, so this is the same ForeverUI trick the Nameplates module uses.
        showTargetAuras = true,
        targetAuraGap   = 22,
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
    -- Blizzard's bottom chrome is re-parented off screen, not destroyed, so the buttons keep working for keybinds.
    -- ownBars: MonetUI draws its own 1..8 bars on LibActionButton-1.0 (Modules/ActionBars) and parks Blizzard's bars; with it off only hideBlizzard can still hide them.  First-run layout lives in BAR_DEFS, positions holds a per-bar override.
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
    -- Nameplates (姓名板, Modules/Nameplates) sit on Blizzard's own plate bases: the base owns targeting/clicks, the module draws a Monet slim bar on it and hides Blizzard's UnitFrame child.  Which units get a plate at all is a CVar, so the show* switches are pushed into nameplateShowFriends/Enemies/... on Apply and put back when the module is off; hideCritters/hideDead filter on top of that.
    -- width/height are the health box, nameSize the name/level row, castHeight the cast bar; forcePlateSize matches Blizzard's clickable hitbox to the drawn box so a click lands on the plate you actually see.
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
        nameSize     = 12,
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
    -- Blizzard panel beautification (Modules/Skins): each window is a switch under `panels`.  `font` is an optional global override: "off" (Blizzard faces) or "pixel" (Fusion Pixel everywhere -- Media:SnapSize keeps text on the 12px grid, MONOCHROME keeps the edges hard).
    skins = {
        font   = "pixel",
        panels = {},
    },
    -- Info bar (信息栏, Modules/InfoBar): one full-width strip along a screen edge carrying small data blocks.  anchorTop pins it to the top edge (so it clears the bottom action bars), height is the strip height (14 fits a 12px font), mouseover keeps the blocks invisible until hovered, combatPulse breathes red in combat / yellow with pending invites; blocks are one switch per data block.
    infobar = {
        anchorTop   = true,
        height      = 14,
        mouseover   = true,
        combatPulse = true,
        blocks = {
            gold       = true,
            durability = true,
            currency   = true,
            system     = true,
            spec       = true,
            friends    = true,
        },
    },
}
ns.DEFAULTS = DEFAULTS

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

--- Database schema.  Bumping this re-applies the settings that changed their meaning in the shipped defaults (see Migrate).
local SCHEMA = 2

--- One-off adjustments to a database written by an older MonetUI: MergeDefaults only fills in *missing* keys, so a value whose number changed has to be pushed explicitly.  Stored positions are the player's and are never touched here.
local function Migrate(db)
    if (db.schema or 1) >= SCHEMA then return end

    -- v2: health bars halved to Andromeda's real thickness, plus the fillColor / lostColor colour rules.
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

--- Walk a dotted path through the global table ("WorldMapFrame.BorderFrame") and report whether it resolves (true / false).  Intermediate nodes must be tables, so indexing can never raise.
-- Modules use this to *probe* the objects they assume exist on this client: a wrong name fails silently (every real lookup is a guarded `_G[name]`), and this makes that silence queryable via `/mui skins diagnose`.
function ns.ResolvePath(path)
    if type(path) ~= "string" or path == "" then return false end
    local node = _G
    for segment in string.gmatch(path, "[^%.]+") do
        if type(node) ~= "table" then return false end
        node = node[segment]
    end
    return node ~= nil
end

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

local function RefreshTheme(reason)
    ns.Color:Refresh()
    ns.EventBus:Fire("MONETUI_THEME_CHANGED", reason)
end
ns.RefreshTheme = RefreshTheme

--- Opt into the engine's own "colours changed" notification, so a profile switch or an engine-side refresh re-tints every border / bar straight away instead of waiting for the next zone change.
-- LibMonetColor ships with or without CallbackHandler-1.0 and the two expose the registration differently, so the shape is detected rather than assumed and both are pcall'd.  Either way the handler is handed the event name first, which is why it ignores its arguments.  No engine, or no notification, leaves the zone handlers below as the baseline.
local function ReserveMonetColorCallback()
    if not LMC then return false end

    local handler = function() RefreshTheme("monet") end

    -- CallbackHandler style: the method is embedded on the library itself.
    if type(LMC.RegisterCallback) == "function" then
        if pcall(LMC.RegisterCallback, LMC, "OnThemeColorsChanged", handler) then
            return true
        end
    end

    -- Built-in fallback registry: the method lives on LMC.events and keys on an arbitrary consumer id.
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

    -- Zone sampling: which environment colour drives the theme here.
    local mapID, zoneName, envSource, h, s, l = ns.Color:GetZoneInfo()
    if mapID then
        ns:Print(string.format("区域取色 %s | 地图 %d | HSL %.1f / %.2f / %.2f | 来源: %s",
            zoneName or "未知", mapID, h, s, l, envSource or "?"))
    end
end

local function PrintHelp()
    ns:Print("命令：")
    ns:Print("  |cffffd100/mui|r            打开配置面板")
    ns:Print("  |cffffd100/mui status|r     显示模块与主题状态")
    ns:Print("  |cffffd100/mui theme|r      重新采样环境色彩")
    ns:Print("  |cffffd100/mui enable|r     启用本体")
    ns:Print("  |cffffd100/mui disable|r    禁用本体（需 /reload）")
    ns:Print("  |cffffd100/mui <模块> on|off|r  单独开关模块")
    ns:Print("  |cffffd100/mui skins diagnose|r 探测本客户端缺少的对象名（skins / nameplates / infobar 同）")
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
            local module = modules[moduleName]

            if rest == "on" or rest == "1" then
                ns:SetModuleEnabled(moduleName, true)
                ns:Print("模块 " .. moduleName .. " 已开启。")
            elseif rest == "off" or rest == "0" then
                ns:SetModuleEnabled(moduleName, false)
                ns:Print("模块 " .. moduleName .. " 已关闭。")
            else
                -- Modules may expose their own sub-commands (e.g. `/mui skins diagnose`): a handler returns true when it consumed the rest of the line, otherwise fall through to the usage line.
                local handled = false
                if type(module.HandleCommand) == "function" then
                    local ok, result = pcall(module.HandleCommand, module, rest)
                    handled = ok and result and true or false
                end

                if not handled then
                    local usage = "用法：/mui " .. moduleName .. " on|off"
                    if type(module.HandleCommand) == "function" then
                        usage = usage .. "  或  /mui " .. moduleName .. " diagnose"
                    end
                    ns:Print(usage)
                end
            end
        else
            PrintHelp()
        end
    end
end

SLASH_MONETUI1 = "/monetui"
SLASH_MONETUI2 = "/mui"
SlashCmdList["MONETUI"] = HandleSlash

-- Boot: EventBus owns the only frame; every listener below is registered on it.
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

-- The engine recomputes on zone changes; we only pick the new colours up and tell the modules about it.
ns.EventBus:Register("ZONE_CHANGED",       function() RefreshTheme("zone") end)
ns.EventBus:Register("ZONE_CHANGED_INDOORS", function() RefreshTheme("zone") end)
ns.EventBus:Register("ZONE_CHANGED_NEW_AREA", function() RefreshTheme("zone") end)
ns.EventBus:Register("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
    if not isInitialLogin and not isReloadingUi then
        RefreshTheme("world")
    end
end)

-- Restricted states (combat / PvP) may hide values again, so let modules refresh their text once the restriction lifts.
ns.EventBus:Register("ADDON_RESTRICTION_STATE_CHANGED", function()
    ns.EventBus:Fire("MONETUI_RESTRICTION_CHANGED")
end)

_G.MonetUI = ns
