-- Utils/Widget.lua
-- Widget factory: shared UI construction (private API to avoid code duplication)

-- WoW addon environment: all .toc files share the same Lua state
-- Color is already a global table created by Utils/Color.lua (loaded earlier in .toc)
local Color = Color

local Widget = {}

-- ============================================================================
-- Frame Creation
-- ============================================================================

function Widget:CreateFrame(name, parent, width, height, template)
    template = template or "BackdropTemplate"
    local frame = CreateFrame("Frame", name, parent, template)
    frame:SetSize(width or 200, height or 100)
    return frame
end

function Widget:CreateStatusBar(name, parent, width, height)
    local bar = CreateFrame("StatusBar", name, parent, "BackdropTemplate")
    bar:SetSize(width or 200, height or 20)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 100)
    bar:SetValue(0)
    return bar
end

function Widget:CreateIcon(name, parent, size, texture)
    local icon = parent:CreateTexture(name or nil, "ARTWORK")
    icon:SetSize(size or 32, size or 32)
    icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    return icon
end

-- ============================================================================
-- Border & Background
-- ============================================================================

function Widget:ApplyBorder(frame, color, thickness)
    thickness = thickness or 1
    local r, g, b, a = Color:GetEdge()

    if not frame.backdrop then
        frame.backdrop = {
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = thickness,
            insets = {left = thickness, right = thickness, top = thickness, bottom = thickness},
        }
    end

    frame:SetBackdrop(frame.backdrop)
    frame:SetBackdropColor(r * 0.15, g * 0.15, b * 0.15, 0.5)
    frame:SetBackdropBorderColor(r, g, b, a)
end

function Widget:ApplyNeutralBackground(frame, alpha)
    local r, g, b = Color:GetNeutral()
    alpha = alpha or 0.3

    if not frame.bg then
        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints(frame)
    end

    frame.bg:SetColorTexture(r, g, b, alpha)
end

-- ============================================================================
-- Text
-- ============================================================================

function Widget:CreateFontString(parent, text, size, colorType)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(text or "")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 12)

    local r, g, b
    if colorType == "edge" then
        r, g, b = Color:GetEdge()
    elseif colorType == "highlight" then
        r, g, b = Color:GetHighlight()
    else
        r, g, b = Color:GetNeutral()
    end
    fs:SetTextColor(r, g, b, 1)
    return fs
end

-- ============================================================================
-- Cooldown
-- ============================================================================

function Widget:CreateCooldown(parent, size)
    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    cd:SetSize(size or 36, size or 36)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    return cd
end

return Widget
