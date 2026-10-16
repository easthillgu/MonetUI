-- Modules/Skins/Skins.lua
-- Blizzard panel beautification (界面美化): reskin the vanilla windows (quests,
-- world map, character sheet, collections, social, mail / merchants, system
-- dialogs) so the whole UI matches MonetUI's palette, material and fonts.
--
-- This file is the engine, not a skin.  Each panel file (Modules/Skins/*.lua)
-- registers its windows through Skins:Panel(key, { apply = fn, ... }) at load
-- time; the engine owns the lifecycle:
--   * apply at PLAYER_LOGIN, again when a Blizzard load-on-demand window
--     arrives (ADDON_LOADED) and after a loading screen;
--   * keep recording every mutation so the whole thing can be rolled back the
--     moment the module is switched off;
--   * expose the panel list + enable/disable to the config panel.
--
-- Every skin is built from Utils/Skin.lua, which only fades Blizzard art and
-- adds our own child frames.  Nothing here calls SetScript / SetParent /
-- SetShown / Hide on a Blizzard frame -- a skin recolours and re-plates, it
-- never takes a protected or Edit-Mode-owned frame hostage.  Hover feedback on
-- Blizzard controls uses HookScript.

local ADDON_NAME, ns = ...

local Skin     = ns.Skin
local Media    = ns.Media
local EventBus = ns.EventBus

local M = { name = "Skins" }
ns.Skins = M

M.registry = {}   -- ordered list of panel entries
M.byKey    = {}   -- key -> entry
M.active   = false

-- -- Registry ----------------------------------------------------------------

--- Register one window / group of windows for beautification.
-- @param opts {
--   label   = the config label,
--   group   = the config section it belongs to,
--   apply   = function(entry)  the skin (idempotent),
--   default = false to ship it off by default,
-- }
function M:Panel(key, opts)
    assert(type(key) == "string", "Skins:Panel needs a string key")
    opts = opts or {}

    local entry = {
        key     = key,
        label   = opts.label or key,
        group   = opts.group or "其它",
        apply   = opts.apply,
        default = opts.default ~= false,
        -- Blizzard load-on-demand addons whose arrival this pack waits for,
        -- e.g. { Blizzard_Collections = true }.  A declaring pack is applied
        -- at login only once one of them is loaded, and re-applied the moment
        -- one arrives -- instead of every pack re-skinning on every addon load.
        addons  = opts.addons,
        -- Every Blizzard object this skin looks up, as dotted paths.  The names
        -- are our own recall of the retail UI (never lifted from a reference
        -- addon, which may target another build), so they are the one thing in
        -- this module that cannot be verified without the client -- see
        -- M:Diagnose().  A wrong name skips that control silently, it does not
        -- error, which is exactly why they are recorded here for probing.
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

--- Has a pack's load-on-demand addon (if it declared one) actually loaded?
-- A name that does not exist on this client simply keeps the pack idle; the
-- lookup is pcall'd, so this can never raise.
local function AddonLoaded(name)
    local api = _G.C_AddOns
    if not (api and api.IsAddOnLoaded) then return false end
    local ok, loaded = pcall(api.IsAddOnLoaded, name)
    return ok and loaded and true or false
end

--- Can this pack be applied right now?  Packs that declared `addons` wait for
-- one of them; everything else is always applicable.
function M:IsApplicable(entry)
    local addons = entry and entry.addons
    if not addons then return true end
    for name in pairs(addons) do
        if AddonLoaded(name) then return true end
    end
    return false
end

--- Toggle a single panel.  Enabling applies it live; disabling needs a reload
-- to put Blizzard's own art fully back, which the message says.
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
        ns:Print("界面美化「" .. tostring(entry.key) .. "」应用失败: " .. tostring(err))
    end
end

function M:ApplyAll()
    for i = 1, #self.registry do
        self:Apply(self.registry[i])
    end
end

--- Collapse a burst of calls into a single pass on the next frame
-- (C_Timer.After(0)).  Skins whose repaint hooks fire several times per frame
-- wrap themselves in this so a burst costs one repaint, not dozens.
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

-- -- Shared helpers for the panel files ---------------------------------------

--- The common window treatment: fade the frame's *own* chrome, hang a Monet
-- backplate under it, restyle the title and the close button.  Only the frame's
-- own regions are faded (not its children), so item / spell icons inside child
-- buttons stay intact.
-- @param opts {
--   layer   = panel's layer key, e.g. "BACKGROUND",
--   inset   = backplate inset,
--   panel   = Widget:Theme opts for the backplate,
--   titleSize =,
--   noTitle = true to skip the title, noClose = true to skip the close button,
-- }
function M:SkinWindow(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    Skin:Strip(frame, opts.strip)
    Skin:Panel(frame, opts.panel)

    if not opts.noTitle then
        local title = (frame.TitleContainer and frame.TitleContainer.TitleText)
            or frame.TitleText or frame.Title
        if title then
            Skin:Font(title, opts.titleSize or 14, "roadway", "OUTLINE", "edge")
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

--- Run `fn` over a list of named controls; each may be a string (looked up in
-- _G) or a table, and missing ones are skipped.
function M:Controls(list, fn)
    if not list then return end
    for i = 1, #list do
        local item = list[i]
        local object = type(item) == "string" and _G[item] or item
        if object then pcall(fn, object) end
    end
end

--- Restyle a list of buttons.
function M:Buttons(list, opts)
    self:Controls(list, function(button)
        if type(button.GetObjectType) ~= "function" or button:GetObjectType() == "Button"
            or button:GetObjectType() == "CheckButton" then
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

--- Restyle every direct child Button of a frame, skipping item buttons (the ones
-- that carry an icon, i.e. reward / slot icons we must not fade).
local function LooksLikeItemButton(button)
    return button.icon or button.Icon or button.iconTexture or button.IconTexture
        or button.itemButton or button.ItemButton
end

function M:SkinButtonsIn(frame, opts)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        local kind = type(child.GetObjectType) == "function" and child:GetObjectType()
        if kind == "Button" and not LooksLikeItemButton(child) then
            Skin:Button(child, opts)
        end
    end
end

--- Restyle every direct child ScrollFrame of a frame.
function M:SkinScrollsIn(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        local kind = type(child.GetObjectType) == "function" and child:GetObjectType()
        if kind == "ScrollFrame" then
            Skin:ScrollFrame(child)
        end
    end
end

--- Re-run a skin whenever a Blizzard frame is shown (Blizzard builds some
-- content lazily).  HookScript only, and idempotent: one OnShow handler per
-- frame, ever.  Callers re-run this from refresh paths, and stacking a fresh
-- handler each time would multiply a skin on every re-apply.
function M:HookShow(frame, fn)
    if not frame or type(frame.HookScript) ~= "function" or type(fn) ~= "function" then return end
    if frame.__monetShowHook then return end
    frame.__monetShowHook = true
    frame:HookScript("OnShow", function()
        if M.active then pcall(fn) end
    end)
end

--- Run `fn` on a WoW event, but only while the module is active.
function M:OnEvent(event, fn)
    EventBus:Register(event, function()
        if M.active then pcall(fn) end
    end)
end

-- -- Global font (optional) ---------------------------------------------------

-- Restyles Blizzard's shared font objects so static vanilla text matches the
-- MonetUI font.  Off by default: it touches every window at once, so it stays
-- the player's explicit choice.
local FONT_OBJECTS = {
    "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontNormalHuge",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontHighlightLarge",
    "GameFontDisable", "GameFontDisableSmall", "GameFontDisableLarge",
    "GameFontDarkGraySmall", "GameFontGreen", "GameFontGreenSmall",
    "GameFontRed", "GameFontRedSmall", "GameFontWhite", "GameFontWhiteSmall",
    "GameFontNormalMed1", "GameFontNormalMed2", "GameFontNormalMed3",
    "NumberFontNormal", "NumberFontNormalSmall", "NumberFontNormalLarge",
    "NumberFontNormalHuge", "NumberFont_Shadow_Small",
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
            if not fs.__monetGlobalFont then
                fs.__monetGlobalFont = true
                local oldPath, oldSize, oldFlags = fs:GetFont()
                if oldPath then
                    Skin:Record(function()
                        if fs.SetFont then fs:SetFont(oldPath, oldSize, oldFlags) end
                        fs.__monetGlobalFont = nil
                    end)
                end
            end
            local _, size = fs:GetFont()
            pcall(fs.SetFont, fs, path, size or 12, "")
        end
    end
end

-- -- Lifecycle ---------------------------------------------------------------

local hooksInstalled = false

local function InstallHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- Blizzard windows are load-on-demand.  Two paths keep up with them:
    --   * a pack that declared its addon is re-applied the moment that exact
    --     addon arrives (precise, no other pack pays for it);
    --   * packs that declared nothing get ONE debounced pass per burst.  The
    --     login ADDON_LOADED burst used to re-skin every window once per addon
    --     that loaded; the debounce collapses it into a single pass.
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
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if not M.active then return end
        M:ApplyAll()
    end)
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

-- -- Verification -------------------------------------------------------------

-- Every frame name in this module is our own recall of the retail UI, never
-- taken from a reference addon (those may target a different build and their
-- object names are not reliable here).  Because each lookup is a guarded
-- `_G[name]`, a wrong name silently skips that control rather than raising --
-- which also means it fails *quietly*.  This turns that silence into a list:
-- `/mui skins diagnose` walks each entry's `frames` (dotted paths descend into
-- sub-frames) against the running client and reports exactly what is absent, so
-- the missing names can be corrected in one pass instead of guessed at.
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

    -- Shared font objects belong to no window (the option is global, and off by
    -- default), so they are checked separately -- and for the same reason: a
    -- wrong name would be invisible until the player switches the option on and
    -- nothing changes.
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

--- `/mui Skins <sub>`.  Returns false when the sub-command is unknown, so the
-- slash handler can fall back to printing the usage line.
function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub == "diagnose" or sub == "diag" or sub == "probe" then
        self:Diagnose()
        return true
    end
    return false
end

ns:Register("Skins", M)
