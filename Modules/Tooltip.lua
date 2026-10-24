-- Modules/Tooltip.lua
-- Tooltip placement (鼠标提示位置): one switch moves every tooltip in the game -- item, spell, unit,
-- aura, action button -- to the cursor.  This file owns *behaviour* only; the look (border / centre
-- colour / font) belongs to the skins engine (Modules/Skins/System.lua, panel "tooltip").
--
-- The tooltip is one shared frame that every Blizzard window and every addon feeds, so placement has
-- to be taken over at the frame itself rather than at any one caller: OnShow puts it next to the
-- cursor, OnUpdate keeps it there while the mouse moves.  OnUpdate only fires while the tooltip is
-- shown, so a hidden tooltip costs nothing, and the position is only written when the cursor actually
-- moved (an idle hover must not re-layout every frame).
--
-- Why not SetOwner(owner, "ANCHOR_CURSOR") and leave it at that: that anchor type is applied when the
-- owner is assigned, and Blizzard's own `GameTooltip_SetDefaultAnchor` (action buttons, unit frames,
-- bags) immediately SetPoint()s the tooltip onto the bottom-right default container on top of it.  A
-- follower that writes the position itself wins that fight once, for every caller, without hooking
-- each entry point.

local ADDON_NAME, ns = ...

local M = { name = "Tooltip" }
ns.Tooltip = M

local OFFSET_X, OFFSET_Y = 16, -16   -- 让开光标右下角一点，别盖住正在悬停的东西

local follow     -- cached copy of the setting: OnUpdate runs every frame while a tooltip is up
local installed  -- hooks are installed once and stay; `follow` decides whether they do anything
local lastX, lastY, lastScale

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.tooltip) ~= "table" then db.tooltip = {} end
    return db.tooltip
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.tooltip[key] end
    return value
end

--- 把提示框摆到光标右下角。只在光标动了 / 缩放变了的时候写，静止悬停不碰布局。
local function Place(tip)
    local ui = _G.UIParent
    if not ui then return end

    local x, y = _G.GetCursorPosition()
    local scale = ui:GetEffectiveScale()
    if scale ~= lastScale then
        -- 分辨率 / 缩放的改变不需要额外的缩放监听：这里顺手发现，顺手重摆
        lastScale = scale
        lastX, lastY = nil, nil
    end
    if x == lastX and y == lastY then return end
    lastX, lastY = x, y

    tip:ClearAllPoints()
    tip:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT", x / scale + OFFSET_X, y / scale + OFFSET_Y)
end

local function OnShow(self)
    lastX, lastY = nil, nil
    if follow then Place(self) end
end

local function OnUpdate(self)
    if follow then Place(self) end
end

local function InstallHooks()
    if installed then return end
    local tip = _G.GameTooltip
    if not tip then return end
    installed = true

    -- 不 HookScript（写脚本槽 = 污染，见 AGENTS）：用轮询。
    -- OnShow → Widget:ShowWatch；OnUpdate（跟随光标）→ Widget:PollWatch（0.2 秒一次，够顺滑）。
    ns.Widget:ShowWatch(tip, function(self)
        lastX, lastY = nil, nil
        if follow then Place(self) end
    end)
    ns.Widget:PollWatch(tip, function(self)
        if follow then Place(self) end
    end)
end

--- 设置改动后立刻对齐：打开就当场摆到光标旁，关掉先收起（下一次悬停走暴雪自己的位置）。
function M:Apply()
    follow = self:GetSetting("follow") and true or false
    lastX, lastY = nil, nil

    local tip = _G.GameTooltip
    if tip and tip.IsShown and tip:IsShown() then
        if follow then Place(tip) else pcall(tip.Hide, tip) end
    end
end

function M:Initialize()
    follow = self:GetSetting("follow") and true or false
    InstallHooks()
end

--- 模块开关：关掉只是让跟随失效，钩子本身不回退（重开时零成本）。
function M:SetEnabled(value)
    if value then
        follow = self:GetSetting("follow") and true or false
        InstallHooks()
    else
        follow = false
    end
end

ns:Register("Tooltip", M)
