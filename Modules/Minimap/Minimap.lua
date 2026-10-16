-- Modules/Minimap/Minimap.lua
-- Minimap reshape.
--
-- The module does not replace the minimap, it reworks it: the cluster is moved
-- to the bottom-right corner and the circular map becomes a 256x190 rectangle
-- (Andromeda's shape), a themed panel is placed behind it and the default
-- circular art is removed.
--
-- Shape first: reshaping and being able to undo it (SetEnabled) are the
-- module's contract.  Deferred backlog, owner-confirmed lower priority:
-- tracking button on the map, right-click main menu, a UiConfig button that
-- opens the MonetUI settings panel.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus

local M = { name = "Minimap" }

local panel = nil

-- -- Skinning -----------------------------------------------------------------

-- Andromeda parks the minimap in the bottom-right corner and stretches it into a
-- 256x190 rectangle; its UI_GAP is 33.
local MINIMAP_GAP    = 33
local MINIMAP_CANVAS = 256          -- the (square) minimap canvas
local MINIMAP_CROP   = 33           -- (256 - 190) / 2, hidden above and below
local MINIMAP_HEIGHT = MINIMAP_CANVAS - MINIMAP_CROP * 2
local minimapWarned  = false
local restoreWarned  = false
local shapeOverridden = false

-- The state captured before the first skin, cleared by Restore().  A module
-- that cannot undo itself is worse than no module: "disabled" must mean the
-- default minimap is back, not just that the themed panel is gone.
local original = nil

-- Runtime switch state; Skin and the theme callback obey it so a zone change
-- cannot re-skin a module the user has turned off.
local active = false

-- The mask Blizzard's own Minimap frame spec declares.  There is no getter to
-- read the current mask back with (the API manual only has Texture's, not
-- MinimapFrame's), so the restore target is this XML-declared default path.
local DEFAULT_MASK = "Interface\\Minimap\\MiniMap-CompassMask"

local ART_NAMES = { "MinimapBorder", "MinimapBorderTop", "MinimapCompassTexture",
                    "MinimapBackdrop", "MinimapNorthTag" }

--- Move Blizzard's minimap cluster to the bottom-right corner.
-- Guarded: Edit Mode also anchors this frame, and a failure here (which would
-- taint) must not stop the rest of the module.  Re-applied on every skin so a
-- zone change or an Edit Mode layout cannot undo it.
local function MoveCluster()
    local cluster = _G.MinimapCluster
    if not cluster then return end

    pcall(cluster.ClearAllPoints, cluster)
    local ok = pcall(cluster.SetPoint, cluster, "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
        -MINIMAP_GAP, MINIMAP_GAP)
    if not ok and not minimapWarned then
        minimapWarned = true
        ns:Print("小地图定位失败，已保留暴雪默认位置。")
    end
end

--- Turn the circular minimap into a 256x190 rectangle the way Andromeda does:
-- the canvas stays 256x256 and a mask texture blanks the top and bottom bands,
-- while the hit rectangle is shrunk to match what is actually visible.
local function ReshapeMinimap(minimap)
    pcall(minimap.SetMaskTexture, minimap, ns.Media:Texture("minimapRect"))
    pcall(minimap.SetSize, minimap, MINIMAP_CANVAS, MINIMAP_CANVAS)
    pcall(minimap.SetHitRectInsets, minimap, 0, 0, MINIMAP_CROP, MINIMAP_CROP)
    pcall(minimap.SetClampRectInsets, minimap, 0, 0, 0, 0)
    pcall(minimap.SetClampedToScreen, minimap, true)

    -- Third-party minimap buttons ask this to place themselves; telling them the
    -- map is square keeps them inside the rectangle (this is what Andromeda
    -- does).  Overriding a Blizzard global is deliberate here, hence the write.
    if not shapeOverridden then
        shapeOverridden = true
        _G.GetMinimapShape = function() return "SQUARE" end
    end
end

--- Remove the default circular art: it no longer fits the rectangular map (the
-- themed panel behind the cluster is the frame now).  Remember() snapshots the
-- shown/alpha state of every name here before this runs.
local function ClearDefaultArt()
    for _, name in ipairs(ART_NAMES) do
        local region = _G[name]
        if region and region.Hide then region:Hide() end
        if region and region.SetAlpha then region:SetAlpha(0) end
    end
end

--- Snapshot everything the skin is about to change, exactly once, so Restore()
-- can undo it.  All reads are guarded: a missing getter must not stop the
-- capture (and a skipped field simply stays as the skin left it).
local function Remember(minimap)
    if original then return end

    local state = {
        -- No MinimapFrame:GetMaskTexture exists in this client's API manual (only
        -- Texture's), so the restore target is the mask Blizzard's own frame spec
        -- declares rather than a value read back at runtime.
        mask = DEFAULT_MASK,
        art  = {},
    }
    if minimap.GetSize           then state.size    = { minimap:GetSize() } end
    if minimap.GetHitRectInsets  then state.hit     = { minimap:GetHitRectInsets() } end
    if minimap.GetClampRectInsets then state.clamp  = { minimap:GetClampRectInsets() } end
    if minimap.IsClampedToScreen then state.clamped = minimap:IsClampedToScreen() end

    local cluster = _G.MinimapCluster
    if cluster and cluster.GetNumPoints then
        state.points = {}
        for i = 1, cluster:GetNumPoints() do
            local point, relTo, relPoint, x, y = cluster:GetPoint(i)
            state.points[#state.points + 1] = { point, relTo, relPoint, x, y }
        end
    end

    for _, name in ipairs(ART_NAMES) do
        local region = _G[name]
        if region and region.IsShown then
            state.art[name] = { shown = region:IsShown(),
                                alpha = region.GetAlpha and region:GetAlpha() or 1 }
        end
    end

    state.shape = rawget(_G, "GetMinimapShape")
    original = state
end

--- Put the default minimap back: cluster anchor, mask, size, hit / clamp
-- insets, art state and the GetMinimapShape global.  Protected methods are
-- pcall'd; a failure (typically combat lockdown) is reported once so the user
-- knows a /reload is the fallback.
local function Restore()
    local state = original
    original = nil
    if not state then return end

    local failed = false
    local function try(ok) if not ok then failed = true end end

    local cluster = _G.MinimapCluster
    if cluster and state.points and #state.points > 0 then
        pcall(cluster.ClearAllPoints, cluster)
        for _, pt in ipairs(state.points) do
            try(pcall(cluster.SetPoint, cluster, pt[1], pt[2], pt[3], pt[4], pt[5]))
        end
    end

    local minimap = _G.Minimap
    if minimap then
        try(pcall(minimap.SetMaskTexture, minimap, state.mask))
        if state.size then
            try(pcall(minimap.SetSize, minimap, state.size[1], state.size[2]))
        end
        if state.hit then
            try(pcall(minimap.SetHitRectInsets, minimap,
                      state.hit[1], state.hit[2], state.hit[3], state.hit[4]))
        end
        if state.clamp then
            try(pcall(minimap.SetClampRectInsets, minimap,
                      state.clamp[1], state.clamp[2], state.clamp[3], state.clamp[4]))
        end
        if state.clamped ~= nil then
            try(pcall(minimap.SetClampedToScreen, minimap, state.clamped))
        end
    end

    for name, saved in pairs(state.art) do
        local region = _G[name]
        if region and region.SetShown then
            region:SetShown(saved.shown)
            if region.SetAlpha and saved.alpha then region:SetAlpha(saved.alpha) end
        end
    end

    -- Deliberate global write, restoring the deliberate global write: nil
    -- clears the override outright when this client never had the function.
    _G.GetMinimapShape = state.shape
    shapeOverridden = false

    if failed and not restoreWarned then
        restoreWarned = true
        ns:Print("小地图还原未完全成功（可能处于战斗中），/reload 可恢复默认小地图。")
    end
end

local function Skin()
    if not active then return false end
    local minimap = _G.Minimap
    if not minimap then return false end

    Remember(minimap)
    MoveCluster()
    ReshapeMinimap(minimap)
    ClearDefaultArt()

    -- framed panel hugging the visible rectangle
    if not panel then
        panel = Widget:CreateFrame("MonetUIMinimapPanel", UIParent,
            MINIMAP_CANVAS + 8, MINIMAP_HEIGHT + 8)
        panel:SetFrameStrata("BACKGROUND")
        panel:SetFrameLevel(1)
        panel:EnableMouse(false)
        Widget:Theme(panel, { thickness = 2, bgAlpha = 0.35 })
    end
    panel:ClearAllPoints()
    panel:SetPoint("CENTER", minimap, "CENTER", 0, 0)

    return true
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    -- Blizzard re-anchors the cluster when the area changes, so the skin is
    -- re-applied rather than done once.
    EventBus:Register("PLAYER_ENTERING_WORLD", function() Skin() end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", function() Skin() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if active then ClearDefaultArt() end
    end)

    active = true
    Skin()
end

--- Runtime switch (config panel / `/mui minimap on|off`).  Disabling restores
-- everything the skin changed, not just the panel: a rectangular, art-less
-- minimap left behind by a "disabled" module would be worse than the default.
function M:SetEnabled(enabled)
    active = enabled and true or false
    if active then
        Skin()
    else
        Restore()
    end
    if panel then panel:SetShown(active) end
end

ns:Register("Minimap", M)
