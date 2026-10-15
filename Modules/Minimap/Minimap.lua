-- Modules/Minimap/Minimap.lua
-- Minimap border / text beautification.
--
-- The module does not replace the minimap, it frames it: the cluster is moved to
-- the bottom-right corner (Andromeda's placement), the default border is tinted
-- with the Monet edge colour, the decorative compass is removed and a themed
-- panel is placed behind the cluster.  Coordinates and a small clock sit above
-- it.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local EventBus = ns.EventBus

local M = { name = "Minimap" }

local panel, coordText, clockText, driver

-- -- Data ---------------------------------------------------------------------

local function GetPlayerPosition()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end

    local position = C_Map.GetPlayerMapPosition(mapID, "player")
    if not position then return nil end

    if position.GetXY then
        local x, y = position:GetXY()
        return x, y
    end
    return nil
end

local function UpdateCoordinates()
    if not coordText then return end
    local x, y = GetPlayerPosition()
    if x and y then
        coordText:SetText(string.format("%.1f, %.1f", x * 100, y * 100))
    else
        coordText:SetText("")
    end
end

local function UpdateClock()
    if not clockText then return end
    local hour, minute = GetGameTime()
    if hour then
        clockText:SetText(string.format("%02d:%02d", hour, minute))
    end
end

-- -- Skinning -----------------------------------------------------------------

-- Andromeda parks the minimap in the bottom-right corner; its UI_GAP is 33.
local MINIMAP_GAP = 33
local minimapWarned = false

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

local function ApplyBorderTint()
    local er, eg, eb = Color:GetEdge()
    local border = _G.MinimapBorder
    if border and border.SetVertexColor then border:SetVertexColor(er, eg, eb) end
    local borderTop = _G.MinimapBorderTop
    if borderTop and borderTop.SetVertexColor then borderTop:SetVertexColor(er, eg, eb) end
end

local function Skin()
    local minimap = _G.Minimap
    if not minimap then return false end

    MoveCluster()
    ApplyBorderTint()

    local compass = _G.MinimapCompassTexture
    if compass then compass:Hide() end

    local backdrop = _G.MinimapBackdrop
    if backdrop then backdrop:Hide() end

    local northTag = _G.MinimapNorthTag
    if northTag and northTag.SetVertexColor then
        local r, g, b = Color:GetNeutral()
        northTag:SetVertexColor(r, g, b)
    end

    -- framed panel behind the minimap
    if not panel then
        panel = Widget:CreateFrame("MonetUIMinimapPanel", UIParent, 150, 150)
        panel:SetFrameStrata("BACKGROUND")
        panel:SetFrameLevel(1)
        panel:EnableMouse(false)
        panel:SetPoint("CENTER", minimap, "CENTER", 0, 0)
        panel:SetSize(150, 150)
        Widget:Theme(panel, { thickness = 2, bgAlpha = 0.35 })
    end

    -- coordinates + clock above the minimap (it now sits in the bottom-right,
    -- so there is no room below it)
    local textParent = _G.MinimapCluster or UIParent
    if not coordText then
        coordText = Widget:Font(textParent, 12, "pixel", "neutral", "CENTER")
        coordText:SetPoint("BOTTOM", minimap, "TOP", 0, 6)
    end
    if not clockText then
        clockText = Widget:Font(textParent, 12, "pixel", "edge", "CENTER")
        clockText:SetPoint("RIGHT", coordText, "LEFT", -12, 0)
    end

    return true
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    if not Skin() then
        -- The minimap is not ready yet, try again when the world / area loads.
        EventBus:Register("PLAYER_ENTERING_WORLD", function() Skin() end)
        EventBus:Register("ZONE_CHANGED_NEW_AREA", function() Skin() end)
    end

    if not driver then
        driver = CreateFrame("Frame")
        local coordElapsed, clockElapsed = 0, 0
        driver:SetScript("OnUpdate", function(_, elapsed)
            coordElapsed = coordElapsed + elapsed
            clockElapsed = clockElapsed + elapsed
            if coordElapsed >= 0.35 then
                coordElapsed = 0
                UpdateCoordinates()
            end
            if clockElapsed >= 10 then
                clockElapsed = 0
                UpdateClock()
            end
        end)
    end

    UpdateCoordinates()
    UpdateClock()

    EventBus:Register("ZONE_CHANGED", UpdateCoordinates)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", UpdateCoordinates)
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        ApplyBorderTint()
        UpdateClock()
    end)
end

function M:SetEnabled(enabled)
    if panel then panel:SetShown(enabled and true or false) end
    if coordText then coordText:SetShown(enabled and true or false) end
    if clockText then clockText:SetShown(enabled and true or false) end
    if driver then
        if enabled then driver:Show() else driver:Hide() end
    end
end

ns:Register("Minimap", M)
