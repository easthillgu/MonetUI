-- Modules/Skins/Skins.lua
-- Blizzard panel beautification (界面美化) engine: panel files (Modules/Skins/*.lua) register windows through Skins:Panel(key, { apply = fn, ... }); the engine applies them at login / ADDON_LOADED / loading screen, records every mutation for rollback, and exposes the list to the config panel.
-- Skins only fade Blizzard art and add our own child frames: no SetScript / SetParent / SetShown / Hide on a Blizzard frame; hover feedback uses HookScript.

local ADDON_NAME, ns = ...

local Skin     = ns.Skin
local Media    = ns.Media
local EventBus = ns.EventBus
local Widget   = ns.Widget


-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local M = { name = "Skins" }
ns.Skins = M

M.registry = {}   -- ordered list of panel entries
M.byKey    = {}   -- key -> entry
M.active   = false

--- Register one window / group of windows for beautification.
-- @param opts { label, group, apply = function(entry) (idempotent), default = false to ship off, addons = { ... }, frames = { ... } }
function M:Panel(key, opts)
    assert(type(key) == "string", "Skins:Panel needs a string key")
    opts = opts or {}

    local entry = {
        key     = key,
        label   = opts.label or key,
        group   = opts.group or "其它",
        apply   = opts.apply,
        default = opts.default ~= false,
        -- Blizzard load-on-demand addons this pack waits for, e.g. { Blizzard_Collections = true }; the pack is applied once one is loaded, and re-applied the moment one arrives.
        addons  = opts.addons,
        -- Every Blizzard object this skin looks up, as dotted paths; a wrong name skips that control silently rather than erroring, which is exactly why they are recorded here for `/mui skins diagnose` to probe.
        frames  = opts.frames,
    }

    if not self.byKey[key] then
        self.registry[#self.registry + 1] = entry
    else
        -- replace the placeholder in place
        for i = 1, #self.registry do
            if self.registry[i].key == key then
                self.registry[i] = entry
                break
            end
        end
    end

    self.byKey[key] = entry
    return entry
end

function M:Settings()
    local db = ns:DB()
    if type(db.skins) ~= "table" then db.skins = {} end
    return db.skins
end

function M:IsEnabled(key)
    local entry = self.byKey[key]
    local panels = self:Settings().panels
    local value = panels and panels[key]
    if value == nil then
        value = entry and entry.default
    end
    return value ~= false
end

--- Has a pack's load-on-demand addon (if declared) actually loaded?  A missing addon keeps the pack idle; the lookup is pcall'd, so it can never raise.
local function AddonLoaded(name)
    local api = _G.C_AddOns
    if not (api and api.IsAddOnLoaded) then return false end
    local ok, loaded = pcall(api.IsAddOnLoaded, name)
    return ok and loaded and true or false
end

--- Can this pack be applied right now?  Packs that declared `addons` wait for one of them; everything else is always applicable.
function M:IsApplicable(entry)
    local addons = entry and entry.addons
    if not addons then return true end
    for name in pairs(addons) do
        if AddonLoaded(name) then return true end
    end
    return false
end

--- Toggle a single panel.  Enabling applies live; disabling needs a /reload to put Blizzard's art fully back, which the message says.
function M:SetPanelEnabled(key, value)
    local skins = self:Settings()
    skins.panels = skins.panels or {}
    skins.panels[key] = value and true or false

    if value then
        if self.active then
            self:Apply(self.byKey[key])
        end
    else
        ns:Print("界面美化「" .. tostring(key) .. "」已关闭，执行 /reload 后恢复原生外观。")
    end
end

function M:IsActive()
    return self.active and true or false
end

function M:Apply(entry)
    if not entry or type(entry.apply) ~= "function" then return end
    if not self:IsApplicable(entry) then return end
    if not self:IsEnabled(entry.key) then return end

    local ok, err = pcall(entry.apply, entry)
    if not ok then
        -- Report a given panel once, not once per pass.  A pack that throws on this client is re-applied
        -- by every ApplyAll, every ADDON_LOADED burst, every PLAYER_ENTERING_WORLD and its own
        -- QUEST_LOG_UPDATE / WORLD_MAP_UPDATE hook, so an unguarded print turns one broken frame name
        -- into dozens of identical lines per session.
        if not entry.__applyFailed then
            entry.__applyFailed = true
            ns:Print("界面美化「" .. tostring(entry.key) .. "」应用失败: " .. tostring(err))
        end
    end
end

function M:ApplyAll()
    for i = 1, #self.registry do
        self:Apply(self.registry[i])
    end
end

--- Collapse a burst of calls into a single pass on the next frame (C_Timer.After(0)); wrap repaint hooks in this so a burst costs one repaint, not dozens.
function M:Debounce(fn)
    local pending = false
    return function()
        if pending then return end
        pending = true
        C_Timer.After(0, function()
            pending = false
            if M.active then pcall(fn) end
        end)
    end
end

--- The common window treatment: fade the frame's *own* chrome (not its children, so icons stay intact), hang a Monet backplate under it, restyle title and close button.
-- @param opts { layer, inset, panel = Widget:Theme opts, titleSize, noTitle = true, noClose = true }
function M:SkinWindow(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    Skin:Strip(frame, opts.strip)
    Skin:Panel(frame, opts.panel)

    if not opts.noTitle then
        local title = (frame.TitleContainer and frame.TitleContainer.TitleText)
            or frame.TitleText or frame.Title
        if title then
            Skin:Font(title, opts.titleSize or 12, "pixel", nil, "edge")
        end
    end

    if not opts.noClose then
        local close = frame.CloseButton
        if not close and type(frame.GetName) == "function" then
            local name = frame:GetName()
            if name then close = _G[name .. "CloseButton"] end
        end
        if close then Skin:CloseButton(close) end
    end

    return frame
end

--- Run `fn` over a list of named controls; each may be a string (looked up in _G) or a table, and missing ones are skipped.
function M:Controls(list, fn)
    if not list then return end
    for i = 1, #list do
        local item = list[i]
        local object = type(item) == "string" and _G[item] or item
        if object then pcall(fn, object) end
    end
end

--- Restyle a list of buttons (check boxes get the check-button skin, with our own checkmark art, instead of the text-button plate).
function M:Buttons(list, opts)
    self:Controls(list, function(button)
        local kind = type(button.GetObjectType) == "function" and button:GetObjectType()
        -- RadioButton is a CheckButton subclass, so without this branch every radio button in the
        -- skinned windows falls into Skin:CheckButton and gets a CHECK glyph.  monet_radio is drawn
        -- and registered for exactly this and had no call site until now.
        if kind == "RadioButton" then
            Skin:RadioButton(button, opts)
        elseif kind == "CheckButton" then
            Skin:CheckButton(button, opts)
        elseif not kind or kind == "Button" then
            Skin:Button(button, opts)
        end
    end)
end

--- Restyle a list of tabs.
function M:Tabs(list, opts)
    self:Controls(list, function(tab)
        Skin:Tab(tab, opts)
    end)
end

--- Restyle a list of scroll frames (and their scroll bars).
function M:Scrolls(list)
    self:Controls(list, function(scroll)
        Skin:ScrollFrame(scroll)
    end)
end

--- Item buttons (the ones carrying an icon -- reward / slot icons we must not fade) are skipped.
local function LooksLikeItemButton(button)
    return button.icon or button.Icon or button.iconTexture or button.IconTexture
        or button.itemButton or button.ItemButton
end

--- Restyle every direct child Button of a frame, skipping item buttons.
function M:SkinButtonsIn(frame, opts)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        -- 受保护窗口的子控件在零售服上是 forbidden object：连 GetObjectType 都可能抛
        -- "Attempt to access forbidden object from code tainted by an AddOn"，所以整段都走 pcall。
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind then
            if kind == "RadioButton" then
                pcall(Skin.RadioButton, Skin, child, opts)
            elseif kind == "CheckButton" then
                pcall(Skin.CheckButton, Skin, child, opts)
            elseif kind == "Button" then
                local okItem, isItem = pcall(LooksLikeItemButton, child)
                if not okItem or not isItem then
                    pcall(Skin.Button, Skin, child, opts)
                end
            end
        end
    end
end

--- Restyle every direct child ScrollFrame of a frame.
function M:SkinScrollsIn(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        -- forbidden object 上连 GetObjectType 都会抛（见 SkinButtonsIn 的注释），一律 pcall。
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind and kind == "ScrollFrame" then
            pcall(Skin.ScrollFrame, Skin, child)
        end
    end
end

--- Restyle every direct child Slider of a frame.
function M:SkinSlidersIn(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind and kind == "Slider" then
            pcall(Skin.Slider, Skin, child)
        end
    end
end

--- Re-run a skin whenever a Blizzard frame is shown (some content is built lazily).
--- **不再 HookScript("OnShow")**：那是往暴雪框体的脚本槽里写我们的函数（污染源）。
--- 改用 Widget:ShowWatch 轮询"从隐藏变显示"这一个瞬间。
function M:HookShow(frame, fn)
    if not frame or type(fn) ~= "function" then return end
    if Marked(frame, "showHook") then return end
    Mark(frame, "showHook", true)
    ns.Widget:ShowWatch(frame, function()
        if M.active then pcall(fn) end
    end)
end

--- Run `fn` on a WoW event, but only while the module is active.
function M:OnEvent(event, fn)
    EventBus:Register(event, function()
        if M.active then pcall(fn) end
    end)
end

-- Restyles Blizzard's shared font objects so static vanilla text matches the MonetUI pixel font.  Off by default: it touches every window at once, so it stays the player's explicit choice.
local FONT_OBJECTS = {
    "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontNormalHuge",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontHighlightLarge",
    "GameFontDisable", "GameFontDisableSmall", "GameFontDisableLarge",
    "GameFontDarkGraySmall", "GameFontGreen", "GameFontGreenSmall",
    "GameFontRed", "GameFontRedSmall", "GameFontWhite", "GameFontWhiteSmall",
    "GameFontNormalMed1", "GameFontNormalMed2", "GameFontNormalMed3",
    "NumberFontNormal", "NumberFontNormalSmall", "NumberFontNormalLarge",
    "NumberFontNormalHuge", "NumberFont_Shadow_Small",
    -- 提示框用自己的字体对象（不是 GameFont*），不在这里列出来，全局字体开关就管不到物品 / 技能 / 角色
    -- 那几万行提示框文字 —— 它们会继续用暴雪的 FRIZQT__/ARHei，和界面其余部分不一样。
    "GameTooltipText", "GameTooltipTextSmall", "GameTooltipHeaderText",
}

function M:GetFontKey()
    local key = self:Settings().font
    if key == "off" or key == nil then return nil end
    return key
end

function M:ApplyFont()
    local key = self:GetFontKey()
    if not key then return end
    local path = Media:Font(key)

    for i = 1, #FONT_OBJECTS do
        local fs = _G[FONT_OBJECTS[i]]
        if fs and type(fs.SetFont) == "function" then
            if not Marked(fs, "globalFont") then
                Mark(fs, "globalFont", true)
                local oldPath, oldSize, oldFlags = fs:GetFont()
                if oldPath then
                    Skin:Record(function()
                        if fs.SetFont then fs:SetFont(oldPath, oldSize, oldFlags) end
                        Mark(fs, "globalFont", nil)
                    end)
                end
            end
            local _, size = fs:GetFont()
            -- Keep Blizzard's own size (their layouts are built around it); only the flags are ours, so the pixel font renders with hard edges.
            pcall(fs.SetFont, fs, path, size or 12, Media.fontFlags)
        end
    end
end

local hooksInstalled = false

local function InstallHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- Blizzard windows are load-on-demand: a pack that declared its addon is re-applied the moment that exact addon arrives; packs that declared nothing get ONE debounced pass per burst, so the login ADDON_LOADED burst collapses into a single re-skin.
    local loosePass = M:Debounce(function()
        for i = 1, #M.registry do
            local entry = M.registry[i]
            if not entry.addons then M:Apply(entry) end
        end
    end)

    EventBus:Register("ADDON_LOADED", function(_, addonName)
        if not M.active then return end
        if addonName then
            for i = 1, #M.registry do
                local entry = M.registry[i]
                if entry.addons and entry.addons[addonName] then
                    M:Apply(entry)
                end
            end
        end
        loosePass()
    end)

    -- Edit Mode / loading screens can rebuild chrome, so re-apply.
    -- Debounced for the same reason as the ADDON_LOADED burst above: PLAYER_ENTERING_WORLD fires on
    -- every loading screen and relog, and a full ApplyAll walks every panel's Strip.
    EventBus:Register("PLAYER_ENTERING_WORLD", M:Debounce(function()
        if not M.active then return end
        M:ApplyAll()
    end))

    -- The UI scale slider is the one input that invalidates the pixel model itself.  Media:Mult() reads
    -- the uiScale CVar, and every border edgeSize / inset and every SnapUnit length is derived from it,
    -- so without this the borders keep their old physical width while new widgets get the new one --
    -- two different border widths on screen at once.  This is the only place that reacts to it.
    -- Login catch-up.  The client frequently applies the UI scale AFTER the first frames are built,
    -- and our UI_SCALE_CHANGED listener may not be installed yet when that happens -- so the event
    -- never reaches us and the borders keep a grid computed from a stale CVar.  AishCore's PixelSnap
    -- documents the same race and re-snaps at 1s and 4s; these two passes close that window.
    -- Guarded to run once per session, not once per zone.
    local loginRescaled = false
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if loginRescaled then return end
        loginRescaled = true
        if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
        local function pass()
            if M.active then Widget:RefreshThemes(true) end
        end
        C_Timer.After(1, pass)
        C_Timer.After(4, pass)
    end)

    EventBus:Register("UI_SCALE_CHANGED", M:Debounce(function()
        if not M.active then return end
        Widget:RefreshThemes(true)   -- re-derive edgeSize / insets, then re-tint
        M:ApplyAll()                  -- skin-layer plates are Widget:Theme'd, so this picks them up too
    end))
end

function M:Initialize()
    self.active = true
    InstallHooks()

    Skin:BeginRecord()
    self:ApplyFont()
    self:ApplyAll()

    ns:Print("界面美化已启用（" .. tostring(#self.registry) .. " 个窗口）。")
end

function M:SetEnabled(enabled)
    enabled = enabled and true or false

    if enabled then
        if self.active then return end
        self.active = true
        Skin:BeginRecord()
        self:ApplyFont()
        Skin:ShowAdded()
        self:ApplyAll()
    else
        self.active = false
        Skin:Rollback()
        Skin:HideAdded()
    end
end

-- Frame names are our own recall of the retail UI (never lifted from a reference addon, which may target another build); a guarded `_G` lookup fails silently, so `/mui skins diagnose` turns that silence into an exact missing-name list.
local ResolvePath = ns.ResolvePath

function M:Diagnose()
    local totalFound, totalMissing = 0, 0

    ns:Print("界面美化对象自检（本客户端实测）：")

    for _, entry in ipairs(self.registry) do
        local names = entry.frames
        if names and #names > 0 then
            local missing, found = {}, 0
            for i = 1, #names do
                if ResolvePath(names[i]) then
                    found = found + 1
                else
                    missing[#missing + 1] = names[i]
                end
            end

            totalFound = totalFound + found
            totalMissing = totalMissing + #missing

            if #missing == 0 then
                ns:Print(("|cff88ff88✓|r [%s] %d/%d 对象存在"):format(entry.key, found, #names))
            else
                ns:Print(("|cffff6b6b✗|r [%s] %d/%d 存在，缺少: %s"):format(
                    entry.key, found, #names, table.concat(missing, ", ")))
            end
        end
    end

    -- Shared font objects belong to no window, so they are checked separately; a wrong name would be invisible until the player switches the option on.
    local fontMissing = {}
    for i = 1, #FONT_OBJECTS do
        if not ResolvePath(FONT_OBJECTS[i]) then
            fontMissing[#fontMissing + 1] = FONT_OBJECTS[i]
        end
    end
    totalFound = totalFound + (#FONT_OBJECTS - #fontMissing)
    totalMissing = totalMissing + #fontMissing
    if #fontMissing == 0 then
        ns:Print(("|cff88ff88✓|r [统一字体] %d 个共享字体对象全部存在"):format(#FONT_OBJECTS))
    else
        ns:Print(("|cffff6b6b✗|r [统一字体] %d/%d 存在，缺少: %s"):format(
            #FONT_OBJECTS - #fontMissing, #FONT_OBJECTS, table.concat(fontMissing, ", ")))
    end

    ns:Print(("合计 %d 存在 / %d 缺失。"):format(totalFound, totalMissing))
    if totalMissing > 0 then
        ns:Print("上面缺失的对象在本客户端用了别的名字，按行补进对应皮肤文件即可。")
    end
end

--- `/mui Skins <sub>`.  Returns false when the sub-command is unknown, so the slash handler can fall back to printing the usage line.
function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub == "diagnose" or sub == "diag" or sub == "probe" then
        self:Diagnose()
        return true
    end
    return false
end

ns:Register("Skins", M)
