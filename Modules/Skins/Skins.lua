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
-- content lazily).  HookScript only.
function M:HookShow(frame, fn)
    if not frame or type(frame.HookScript) ~= "function" or type(fn) ~= "function" then return end
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

    -- Blizzard windows are load-on-demand: skin a group when its addon arrives.
    EventBus:Register("ADDON_LOADED", function()
        if not M.active then return end
        M:ApplyAll()
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

ns:Register("Skins", M)
