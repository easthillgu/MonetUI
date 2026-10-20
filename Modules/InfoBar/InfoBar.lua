-- Modules/InfoBar/InfoBar.lua
-- Info bar (信息栏): a full-width strip pinned to the top (or bottom) edge of the screen, carrying small data blocks -- money, latency, durability, spec, currencies, friends.
-- The *shape* is the one Andromeda uses (container plus blocks accumulated alternately from each edge); nothing else is carried over -- this client's API differs from retail in several places, so every call is feature-detected and a failed one degrades to one hidden block (see `/mui infobar diagnose`).

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus
local Color    = ns.Color

local M = { name = "InfoBar", blocks = {} }
ns.InfoBar = M

local blocks = M.blocks

local GAP       = 2     -- gap between neighbouring blocks
local PADDING   = 16    -- horizontal breathing room inside a block
local MIN_WIDTH = 40    -- a block never shrinks below this
local FADE      = 4     -- backdrop / block alpha per second while fading
local PULSE     = 1.6   -- combat pulse cycles per second

-- Live animation state: one OnUpdate drives fade and pulse together from these numbers.
local bar
local blockAlpha, targetBlockAlpha = 0, 0
local barAlpha,   targetBarAlpha   = 0, 0
local pulseColor                   -- nil = no pulse; {r,g,b} = pulsing edge
local pulsePhase = 0
local hoverDepth = 0
local hiddenForPetBattle = false

function M:Settings()
    local db = ns:DB()
    -- Always hand back the *saved* table; falling back to DEFAULTS would let the config panel silently change what `reset` restores.
    if type(db.infobar) ~= "table" then db.infobar = {} end
    return db.infobar
end

local function Setting(key)
    local value = M:Settings()[key]
    if value == nil then value = ns.DEFAULTS.infobar[key] end
    return value
end

function M:BlockEnabled(key)
    local stored = self:Settings().blocks
    local value
    if type(stored) == "table" then value = stored[key] end
    if value == nil then value = ns.DEFAULTS.infobar.blocks[key] end
    return value and true or false
end

--- Push the current animation state onto the bar; the only place colours/alpha are written, so values cannot drift from what the tick believes.
local function ApplyColors()
    if not bar then return end

    if bar.SetBackdropColor then
        local ar, ag, ab = Color:GetAmbient()
        -- Same shape Widget:Refresh uses, but with the *animated* opacity: 0.25 resting / 0.5 hovered / 0.65 always-on.
        bar:SetBackdropColor(ar * 0.35, ag * 0.35, ab * 0.35, barAlpha)
    end

    if bar.SetBackdropBorderColor then
        local br, bg, bb, ba = Color:GetEdge()
        if pulseColor then
            br, bg, bb = pulseColor[1], pulseColor[2], pulseColor[3]
            -- Sine keeps the edge in the light: a slow breath, not a blink.
            ba = 0.35 + 0.65 * math.abs(math.sin(pulsePhase * math.pi))
        end
        bar:SetBackdropBorderColor(br, bg, bb, ba or 1)
    end

    for i = 1, #blocks do
        local frame = blocks[i].frame
        if frame then frame:SetAlpha(blockAlpha) end
    end
end

local function Kick()
    if not bar then return end
    if blockAlpha ~= targetBlockAlpha or barAlpha ~= targetBarAlpha or pulseColor then
        if not bar:GetScript("OnUpdate") then
            bar:SetScript("OnUpdate", function(_, elapsed) M:Tick(elapsed) end)
        end
    end
end

function M:Tick(elapsed)
    if not bar then return end
    local running = false

    if blockAlpha ~= targetBlockAlpha then
        local step = FADE * elapsed
        if blockAlpha < targetBlockAlpha then
            blockAlpha = math.min(blockAlpha + step, targetBlockAlpha)
        else
            blockAlpha = math.max(blockAlpha - step, targetBlockAlpha)
        end
        running = true
    end

    if barAlpha ~= targetBarAlpha then
        local step = FADE * elapsed
        if barAlpha < targetBarAlpha then
            barAlpha = math.min(barAlpha + step, targetBarAlpha)
        else
            barAlpha = math.max(barAlpha - step, targetBarAlpha)
        end
        running = true
    end

    if pulseColor then
        pulsePhase = (pulsePhase + elapsed * PULSE) % 2
        running = true
    end

    ApplyColors()

    if not running then
        bar:SetScript("OnUpdate", nil)
    end
end

--- Resting / hovered opacities, honouring the "mouseover" setting.
local function SetFadeTargets(hovering)
    if Setting("mouseover") ~= true then
        targetBlockAlpha, targetBarAlpha = 1, 0.65
    elseif hovering then
        targetBlockAlpha, targetBarAlpha = 1, 0.5
    else
        targetBlockAlpha, targetBarAlpha = 0, 0.25
    end
end

-- Hover depth is counted, not inferred: moving from bar onto a block fires the bar's OnLeave first, which would fade the strip while the cursor is still on it.
local function OnEnter()
    hoverDepth = hoverDepth + 1
    SetFadeTargets(true)
    Kick()
end

local function OnLeave()
    hoverDepth = hoverDepth - 1
    if hoverDepth <= 0 then
        hoverDepth = 0
        SetFadeTargets(false)
        Kick()
    end
end

local function ShowTooltip(owner)
    local tip = _G.GameTooltip
    if not tip then return end
    -- A bar pinned to the top edge has to open downwards, and vice versa.
    local top = Setting("anchorTop")
    pcall(tip.SetOwner, tip, owner, top and "ANCHOR_BOTTOM" or "ANCHOR_TOP",
          0, top and -6 or 6)
end

local function HideTooltip()
    local tip = _G.GameTooltip
    if tip then pcall(tip.Hide, tip) end
end

--- Run a Blizzard panel opener by *name*.  These FrameXML globals are not in this client's API manual, so look them up defensively (a wrong name shows via `/mui infobar diagnose`).
function M:OpenPanel(globalName, ...)
    local fn = _G[globalName]
    if type(fn) ~= "function" then return false end
    local combat = _G.InCombatLockdown
    if type(combat) == "function" and combat() then return false end
    local ok = pcall(fn, ...)
    if not ok then ns:Print("无法打开 " .. tostring(globalName) .. "（本客户端可能没有这个函数）") end
    return ok
end

--- Fit a block to its text; an empty block is hidden instead of left as a hollow gap, so a missing API costs one number, not a stripe of the bar.
function M:SetText(block, text)
    if not block or not block.frame then return end

    local value = text and text ~= "" and tostring(text) or nil
    block.text:SetText(value or "")
    block.hasText = value ~= nil

    if value then
        local width = block.text:GetStringWidth() or 0
        block.frame:SetWidth(math.max(width, MIN_WIDTH) + PADDING)
    end

    self:Relayout()
end

--- Redistribute visible blocks: left-anchored grow rightwards, right-anchored leftwards, in registration order.
function M:Relayout()
    if not bar then return end

    local left, right = 0, 0
    for i = 1, #blocks do
        local block = blocks[i]
        local frame = block.frame
        if frame and frame:IsShown() then
            local width = frame:GetWidth() or 0
            frame:ClearAllPoints()
            if block.position == "RIGHT" then
                frame:SetPoint("RIGHT", bar, "RIGHT", -right, 0)
                right = right + width + GAP
            else
                frame:SetPoint("LEFT", bar, "LEFT", left, 0)
                left = left + width + GAP
            end
        end
    end
end

local function UpdateShown(block)
    if not block.frame then return end
    local on = M.active and M:BlockEnabled(block.key) and block.hasText ~= false
    block.frame:SetShown(on and true or false)
    M:Relayout()
end

--- Record a block's spec; frames are built later in `M:Build` because blocks register at file load while the bar only exists at login.
-- @param spec { key, label, position="LEFT"|"RIGHT", update, tooltip, onClick, onUpdate }
function M:RegisterBlock(spec)
    if type(spec) ~= "table" or type(spec.key) ~= "string" then return nil end
    for i = 1, #blocks do
        if blocks[i].key == spec.key then return blocks[i] end
    end
    spec.position = (spec.position == "RIGHT") and "RIGHT" or "LEFT"
    spec.hasText = false
    blocks[#blocks + 1] = spec
    return spec
end

function M:GetBlock(key)
    for i = 1, #blocks do
        if blocks[i].key == key then return blocks[i] end
    end
    return nil
end

local function BuildBlockFrame(block)
    if block.frame or not bar then return end

    local frame = CreateFrame("Button", nil, bar, "BackdropTemplate")
    frame:SetHeight(bar:GetHeight())
    frame:EnableMouse(true)
    -- Borderless so the strip reads as one surface; Theme still registers it so a border-colour change follows.
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0, borderAlpha = 0 })

    frame:SetScript("OnEnter", function(self)
        -- Counted first: the fade must survive the hand-off between two blocks.
        OnEnter()
        local r, g, b = Color:GetAmbient()
        if self.SetBackdropColor then
            self:SetBackdropColor(r * 0.35, g * 0.35, b * 0.35, 0.25)
        end
        ShowTooltip(self)
        if block.tooltip then pcall(block.tooltip, block) end
        local tip = _G.GameTooltip
        if tip then pcall(tip.Show, tip) end
    end)

    frame:SetScript("OnLeave", function(self)
        OnLeave()
        if self.SetBackdropColor then self:SetBackdropColor(0, 0, 0, 0) end
        HideTooltip()
    end)

    if block.onClick then
        frame:SetScript("OnClick", function(_, mouseButton)
            pcall(block.onClick, block, mouseButton)
        end)
    end

    if block.onUpdate then
        frame:SetScript("OnUpdate", function(_, elapsed)
            if not M.active then return end
            if not M:BlockEnabled(block.key) then return end
            pcall(block.onUpdate, block, elapsed)
        end)
    end

    local text = Widget:Font(frame, 12, "pixel", "highlight", "CENTER")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.text = text

    block.frame = frame
    block.text = text
    M:Relayout()
end

local function AnchorBar()
    if not bar then return end
    local top = Setting("anchorTop")
    local parent = _G.UIParent
    bar:ClearAllPoints()
    bar:SetPoint(top and "TOPLEFT" or "BOTTOMLEFT",  parent,
                 top and "TOPLEFT" or "BOTTOMLEFT", 0, 0)
    bar:SetPoint(top and "TOPRIGHT" or "BOTTOMRIGHT", parent,
                 top and "TOPRIGHT" or "BOTTOMRIGHT", 0, 0)
    bar:SetHeight(tonumber(Setting("height")) or 14)

    for i = 1, #blocks do
        if blocks[i].frame then blocks[i].frame:SetHeight(bar:GetHeight()) end
    end
end

local function CreateBar()
    if bar then return end

    -- Named so Edit Mode / bug reports can address it; entirely our own frame, nothing attaches to a Blizzard frame.  Strata stays BACKGROUND so it can never paint over gameplay UI (the minimap cluster moved to the bottom-right keeps the default top edge clear).
    bar = Widget:CreateFrame("MonetUIInfoBar", _G.UIParent)
    bar:SetFrameStrata("BACKGROUND")
    -- 2 physical px: the info bar belongs to the panel tier of the border split (unit frames, auras
    -- and action buttons take 1px; the info bar, minimap and quest tracker take 2px).
    Widget:Theme(bar, { thickness = 2, bgAlpha = 0.25 })
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() OnEnter() end)
    bar:SetScript("OnLeave", function() OnLeave() end)

    AnchorBar()
end

local function UpdateBlock(block)
    if not block or not block.frame then return end

    -- Disabled blocks still need UpdateShown: returning early would leave a switched-off block on screen.
    if not M:BlockEnabled(block.key) then
        UpdateShown(block)
        return
    end
    if type(block.update) ~= "function" then
        UpdateShown(block)
        return
    end

    -- A bad value must never take the whole bar down; report once so the same updater doesn't fail on every event.
    local ok, err = pcall(block.update, block)
    if not ok then
        if not block.reported then
            block.reported = true
            ns:Print("信息栏 [" .. tostring(block.key) .. "] 更新失败，该块暂不显示：" .. tostring(err))
        end
        UpdateShown(block)
        return
    end
    UpdateShown(block)
end

function M:RefreshBlock(key)
    UpdateBlock(self:GetBlock(key))
end

function M:Initialize()
    self.active = true

    CreateBar()

    for i = 1, #blocks do
        local block = blocks[i]
        BuildBlockFrame(block)

        if block.events then
            for j = 1, #block.events do
                local eventName = block.events[j]
                EventBus:Register(eventName, function()
                    if M.active then UpdateBlock(block) end
                end)
            end
        end

        UpdateBlock(block)
    end

    self:ApplyLayout()

    -- Pet battles take over the screen; the strip is furniture, so it goes.
    EventBus:Register("PET_BATTLE_OPENING_START", function()
        hiddenForPetBattle = true
        if bar and M.active then bar:SetShown(false) end
    end)
    EventBus:Register("PET_BATTLE_CLOSE", function()
        hiddenForPetBattle = false
        if bar and M.active then bar:SetShown(true) end
    end)

    -- Combat: the edge breathes red while a guard is up, yellow while the calendar has pending invites (checked on both edges of combat).
    local function RefreshPulse()
        if Setting("combatPulse") ~= true then
            pulseColor = nil
        elseif _G.InCombatLockdown and _G.InCombatLockdown() then
            local r, g, b = Color:GetDanger()
            pulseColor = { r, g, b }
        elseif _G.C_Calendar and _G.C_Calendar.GetNumPendingInvites
               and (_G.C_Calendar.GetNumPendingInvites() or 0) > 0 then
            pulseColor = { 1, 1, 0 }
        else
            pulseColor = nil
        end
        ApplyColors()
        Kick()
    end
    self.RefreshPulse = RefreshPulse

    EventBus:Register("PLAYER_REGEN_DISABLED", function() if M.active then RefreshPulse() end end)
    EventBus:Register("PLAYER_REGEN_ENABLED",  function() if M.active then RefreshPulse() end end)
    if _G.C_Calendar and _G.C_Calendar.GetNumPendingInvites then
        EventBus:Register("CALENDAR_UPDATE_PENDING_INVITES",
            function() if M.active then RefreshPulse() end end)
    end

    -- The theme engine already re-tinted registered widgets (it registered at file load, this at login), so re-apply the animated opacities after its blanket refresh.
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if M.active then ApplyColors() end
    end)

    -- Layout / visibility rules depend on these three.
    local function Reapply()
        if not M.active then return end
        M:ApplyLayout()
        for i = 1, #blocks do UpdateBlock(blocks[i]) end
        M:Relayout()
        SetFadeTargets(hoverDepth > 0)
        ApplyColors()
        Kick()
    end
    self.Reapply = Reapply

    EventBus:Register("PLAYER_ENTERING_WORLD", function() if M.active then Reapply() end end)

    -- Resting state: with the fade off the strip starts fully lit; with it on the blocks are invisible and only the faint backdrop shows.
    SetFadeTargets(false)
    blockAlpha, barAlpha = targetBlockAlpha, targetBarAlpha

    ApplyColors()
    RefreshPulse()
end

--- Re-anchor and re-measure; called after a setting changes.
function M:ApplyLayout()
    if not bar then return end
    AnchorBar()
    self:Relayout()
    bar:SetShown(self.active and not hiddenForPetBattle)
end

function M:SetEnabled(enabled)
    self.active = enabled and true or false
    -- Core initializes a module *before* enabling it, so `bar` exists whenever this arrives with `enabled` true; nothing to build here.
    if not bar then return end

    if not self.active then
        -- Hiding the bar suppresses its OnLeave, so reset the hover count or the strip would come back faded-in-but-not-hovered.
        hoverDepth = 0
        SetFadeTargets(false)
    end

    bar:SetShown(self.active and not hiddenForPetBattle)
    if self.active then
        if self.Reapply then
            self.Reapply()
        else
            self:ApplyLayout()
        end
    end
end

-- Every function this module calls; absent names are a report, not an error -- missing APIs simply mean the matching block stays empty.
local PROBED = {
    "GetMoney", "GetFramerate", "GetNetStats",
    "C_AddOns.GetNumAddOns", "C_AddOns.GetAddOnName",
    "GetAddOnMemoryUsage", "UpdateAddOnMemoryUsage",
    "C_CurrencyInfo.GetCurrencyListSize", "C_CurrencyInfo.GetCurrencyListInfo",
    "C_SpecializationInfo.GetSpecialization", "C_SpecializationInfo.GetSpecializationInfo",
    "C_SpecializationInfo.GetNumSpecializationsForClassID",
    "GetInventoryItemDurability",
    "C_FriendList.GetNumFriends", "C_FriendList.GetNumOnlineFriends",
    "UnitClass", "InCombatLockdown",
    "ToggleCharacter", "ToggleFriends", "ToggleTalentFrame",
}

function M:Diagnose()
    ns:Print("信息栏对象自检（本客户端实测）：")

    local missing = 0
    for i = 1, #PROBED do
        local name = PROBED[i]
        if ns.ResolvePath(name) then
            ns:Print(("|cff88ff88✓|r %s"):format(name))
        else
            missing = missing + 1
            ns:Print(("|cffff6b6b✗|r %s（缺失）"):format(name))
        end
    end
    if missing == 0 then
        ns:Print("全部函数存在。")
    else
        ns:Print(string.format("%d 个缺失：对应数据块会自动留空，不影响其它块。", missing))
    end

    if self.durabilityMode then
        ns:Print(("耐久取值签名已实测为: GetInventoryItemDurability(%s)")
            :format(self.durabilityMode == "unit" and "unit, slot" or "slot"))
    elseif self.active then
        ns:Print("耐久取值签名：尚未探测（装备上任意一件有耐久的装备后会自动判定）。")
    end

    local shown = 0
    for i = 1, #blocks do
        local block = blocks[i]
        local state
        if not self:BlockEnabled(block.key) then
            state = "配置关闭"
        elseif not block.frame then
            state = "未构建"
        elseif not block.frame:IsShown() then
            state = "已隐藏（无数据）"
        else
            state = "显示中"
            shown = shown + 1
        end
        ns:Print(("  - %-11s %s"):format(block.key, state))
    end
    ns:Print(("当前 %d/%d 块可见。"):format(shown, #blocks))
end

function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub == "diagnose" or sub == "diag" or sub == "probe" then
        self:Diagnose()
        return true
    end
    return false
end

ns:Register("InfoBar", M)
