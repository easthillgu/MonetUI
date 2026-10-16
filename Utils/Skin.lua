-- Utils/Skin.lua
-- Blizzard-panel skinning primitives (the addon's private skin toolkit).
--
-- The Skins module builds every panel skin out of these helpers: fade the
-- original Blizzard art, hang a Monet backplate / border under the frame, and
-- restyle the controls (buttons, tabs, scroll bars, check boxes, drop-downs,
-- close buttons, text) so a vanilla window matches the rest of MonetUI.
--
-- Two rules run through everything here:
--   * Defensive.  A client that lacks a frame, a method or a template simply
--     skips that step; nothing raises.
--   * Reversible.  Every mutation of a Blizzard object is recorded, so
--     Skin:Rollback() puts the original back when the module is turned off.
--     Objects we add ourselves are merely hidden.
--
-- Nothing here ever calls SetScript / SetParent / SetShown / Hide on a Blizzard
-- frame.  A skin only fades art and adds its own child frames, which keeps the
-- addon taint-free on protected UI and leaves Edit Mode layouts intact.  All
-- hover handling on Blizzard buttons is done with HookScript.

local ADDON_NAME, ns = ...

local Color    = ns.Color
local Media    = ns.Media
local Widget   = ns.Widget
local EventBus = ns.EventBus

local Skin = {}
ns.Skin = Skin

-- -- Undo recording ------------------------------------------------------------

Skin.undo      = {}    -- ordered list of restore closures
Skin.recording = false

--- Record a closure that undoes one mutation (only while recording).
function Skin:Record(restore)
    if self.recording and type(restore) == "function" then
        self.undo[#self.undo + 1] = restore
    end
end

function Skin:BeginRecord()
    self.undo = {}
    self.recording = true
end

--- Replay every recorded undo, newest first, then stop recording.
function Skin:Rollback()
    for i = #self.undo, 1, -1 do
        pcall(self.undo[i])
    end
    self.undo = {}
    self.recording = false
end

-- Frames/textures we created.  On rollback they are hidden, on re-apply shown
-- again -- the skin code caches them on the Blizzard frame, so they are built
-- once and merely toggled.
Skin.added = {}

-- Only while recording: things built for a Blizzard window belong to the skin
-- module and hide with it, while helpers called for the addon's own frames
-- (the config panel) must not join that rollback list.
function Skin:Track(frame)
    if frame and self.recording then
        self.added[#self.added + 1] = frame
    end
    return frame
end

function Skin:ShowAdded()
    for i = 1, #self.added do
        local frame = self.added[i]
        if frame and frame.SetShown then pcall(frame.SetShown, frame, true) end
    end
end

function Skin:HideAdded()
    for i = 1, #self.added do
        local frame = self.added[i]
        if frame and frame.SetShown then pcall(frame.SetShown, frame, false) end
    end
end

-- -- Theme re-tinting ----------------------------------------------------------

-- Colour changes that the Widget theme registration cannot see (a Blizzard
-- texture we recoloured, a thumb we drew ourselves).  Panels push a refresh
-- closure; the Skins module runs them whenever the theme changes.
Skin.tinters = {}

function Skin:OnTheme(fn)
    if type(fn) == "function" then
        self.tinters[#self.tinters + 1] = fn
    end
    return fn
end

function Skin:RefreshThemes()
    for i = 1, #self.tinters do
        pcall(self.tinters[i])
    end
end

EventBus:Register("MONETUI_THEME_CHANGED", function()
    Skin:RefreshThemes()
end)

-- -- Small helpers -------------------------------------------------------------

local function IsTexture(region)
    return region and type(region.IsObjectType) == "function" and region:IsObjectType("Texture")
end

--- The FontString of a button (Blizzard stores it in .Text or via GetFontString).
function Skin:GetText(button)
    if not button then return nil end
    local text = button.Text
    if not text and type(button.GetFontString) == "function" then
        text = button:GetFontString()
    end
    return text
end

--- Fade any region (texture) to invisible without moving it, remembering the
-- old alpha.  Hidden once per region.
function Skin:Fade(region)
    if not region or type(region.SetAlpha) ~= "function" then return region end
    if region.__monetHidden then return region end
    -- Our own art (Skin:SwapArt) is never faded: a later pass restyling the
    -- same control must not hide the glyph we just put on it.
    if region.__monetArt then return region end
    region.__monetHidden = true

    local old = region.GetAlpha and region:GetAlpha() or 1
    self:Record(function()
        if region.SetAlpha then region:SetAlpha(old) end
        region.__monetHidden = nil
    end)

    region:SetAlpha(0)
    return region
end

--- Fade a texture's four sprite edges / a whole button's art, whatever shape it
-- has.
function Skin:FadeButtonArt(button)
    if not button then return end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }
    for i = 1, #getters do
        local getter = button[getters[i]]
        if type(getter) == "function" then
            local tex = getter(button)
            if tex then self:Fade(tex) end
        end
    end
end

-- -- Stripping ----------------------------------------------------------------

-- Named background pieces Blizzard keeps on its panels.
local BACKDROP_PIECES = {
    "NineSlice", "Bg", "Background", "Border", "BorderFrame", "Inset", "InsetFrame",
    "TopBorder", "BottomBorder", "LeftBorder", "RightBorder", "TitleBg", "TitleBG",
    "BgTop", "BgBottom", "BgLeft", "BgRight", "BG", "Backdrop",
}

--- Fade the original art of a frame.
-- @param opts table {
--   regions   = false to leave plain textures alone,
--   backdrops = false to leave the named background pieces alone,
--   keep      = function(region) -> true to skip a texture,
--   keepTexture = a texture to always keep (a status bar's fill),
--   art       = true to also fade button art,
-- }
function Skin:Strip(frame, opts)
    if not frame then return frame end
    opts = opts or {}

    if opts.backdrops ~= false then
        for i = 1, #BACKDROP_PIECES do
            local piece = frame[BACKDROP_PIECES[i]]
            if piece and type(piece.SetAlpha) == "function" then
                self:Fade(piece)
            end
        end
    end

    if opts.regions ~= false and type(frame.GetRegions) == "function" then
        local keep = opts.keep
        local regions = { frame:GetRegions() }
        for i = 1, #regions do
            local region = regions[i]
            if IsTexture(region) and region ~= opts.keepTexture then
                if not (keep and keep(region)) then
                    self:Fade(region)
                end
            end
        end
    end

    if opts.art then
        self:FadeButtonArt(frame)
    end

    return frame
end

-- -- Text ---------------------------------------------------------------------

--- Restyle a FontString with one of the addon fonts and (optionally) a theme
-- colour.  Records the old font so a rollback restores it.
function Skin:Font(fs, size, key, flags, colorKey)
    if not fs or type(fs.SetFont) ~= "function" then return fs end

    if not fs.__monetFont then
        fs.__monetFont = true
        local path, oldSize, oldFlags = fs:GetFont()
        if path then
            self:Record(function()
                if fs.SetFont then fs:SetFont(path, oldSize, oldFlags) end
                fs.__monetFont = nil
            end)
        end
    end

    pcall(Widget.SetFont, Widget, fs, size or 12, key or "pixel", flags or "")
    if colorKey then
        self:ColorText(fs, colorKey)
    end
    return fs
end

--- Recolour a FontString to a theme slot, remembering the old colour.
function Skin:ColorText(fs, colorKey)
    if not fs or type(fs.SetTextColor) ~= "function" then return fs end

    local r, g, b, a
    if type(colorKey) == "table" then
        r, g, b, a = colorKey.r, colorKey.g, colorKey.b, colorKey.a or 1
    else
        r, g, b, a = Color:Get(colorKey or "neutral")
    end

    if not fs.__monetColor then
        fs.__monetColor = true
        local oldR, oldG, oldB, oldA = fs:GetTextColor()
        local oldSR, oldSG, oldSB, oldSA
        if fs.GetShadowColor then oldSR, oldSG, oldSB, oldSA = fs:GetShadowColor() end
        self:Record(function()
            if fs.SetTextColor then fs:SetTextColor(oldR, oldG, oldB, oldA) end
            if oldSR and fs.SetShadowColor then fs:SetShadowColor(oldSR, oldSG, oldSB, oldSA) end
            fs.__monetColor = nil
        end)
    end

    fs:SetTextColor(r, g, b, a or 1)
    if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0) end
    return fs
end

-- -- Backplates ---------------------------------------------------------------

local function NewBackdropFrame(parent, levelOffset)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local level = (parent.GetFrameLevel and parent:GetFrameLevel() or 1) + (levelOffset or -1)
    frame:SetFrameLevel(math.max(0, level))
    frame:EnableMouse(false)
    return frame
end

--- A themed backplate behind a Blizzard frame.  Built once, cached on the frame.
-- @param opts { thickness=, bgAlpha=, borderAlpha=, borderKey=, inset= }
function Skin:Panel(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    local bg = frame.__monetSkinBg
    if not bg then
        bg = NewBackdropFrame(frame, opts.levelOffset or -1)
        local inset = opts.inset or 0
        bg:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
        bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.85,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
        })
        frame.__monetSkinBg = bg
        self:Track(bg)
    end

    bg:Show()
    return bg
end

--- A backplate for a control that already sits inside a panel, drawn *under* the
-- control (used for buttons / drop-downs / edit boxes).
function Skin:ControlBg(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    local bg = frame.__monetControlBg
    if not bg then
        bg = NewBackdropFrame(frame, -1)
        bg:SetAllPoints(frame)
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.9,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
        })
        frame.__monetControlBg = bg
        self:Track(bg)
    end

    bg:Show()
    return bg
end

--- Hover feedback on a Blizzard control: tint its Monet border to the highlight
-- colour.  HookScript (never SetScript) so existing scripts survive, and only
-- installed once.
function Skin:HoverHighlight(control, opts)
    if not control or type(control.HookScript) ~= "function" then return end
    if control.__monetHover then return end
    control.__monetHover = true
    opts = opts or {}

    local function border(bg)
        return bg or control.__monetSkinBg or control.__monetControlBg
    end

    control:HookScript("OnEnter", function()
        local bg = border()
        if bg and bg.SetBackdropBorderColor then
            local r, g, b = Color:GetHighlight()
            bg:SetBackdropBorderColor(r, g, b, opts.alpha or 1)
        end
    end)
    control:HookScript("OnLeave", function()
        local bg = border()
        if bg then Widget:Refresh(bg) end
    end)
end

-- -- Controls -----------------------------------------------------------------

-- The control helpers below are meant to be *re-appliable*: a skin may be
-- rolled back (module off) and applied again (module on) any number of times.
-- The fade calls are idempotent through `__monetHidden` (cleared by Rollback),
-- while objects we create (a backplate, a tab underline, a thumb fill) are
-- cached on the frame and only toggled, so no helper short-circuits the whole
-- visual pass.

--- Restyle a Blizzard button (flat Monet plate + themed border + font).
function Skin:Button(button, opts)
    if not button then return button end
    opts = opts or {}

    self:Strip(button, { keep = opts.keep })
    self:FadeButtonArt(button)
    self:ControlBg(button, {
        thickness   = opts.thickness or 1,
        bgAlpha     = opts.bgAlpha or 0.9,
        borderAlpha = opts.borderAlpha,
        borderKey   = opts.borderKey,
    })

    local text = self:GetText(button)
    if text then
        self:Font(text, opts.size or 12, opts.fontKey or "pixel", opts.flags, opts.textKey or "neutral")
    end

    self:HoverHighlight(button, { alpha = opts.borderAlpha or 1 })
    return button
end

--- Restyle a tab button (square, themed, accent underline).
function Skin:Tab(tab, opts)
    if not tab then return tab end
    self:Button(tab, opts)

    if not tab.__monetTab then
        tab.__monetTab = true
        local underline = tab:CreateTexture(nil, "OVERLAY")
        underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 4, 1)
        underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -4, 1)
        underline:SetHeight(2)
        tab.__monetTabBar = underline
        self:Track(underline)
        self:OnTheme(function()
            local r, g, b = Color:GetBorder()
            underline:SetColorTexture(r, g, b, 0.9)
        end)
    end
    return tab
end

--- Restyle a scroll bar (track + arrows + thumb).
function Skin:ScrollBar(scrollbar)
    if not scrollbar then return scrollbar end

    self:Strip(scrollbar, { regions = true })
    local fadeButtons = { "ScrollUpButton", "ScrollDownButton", "ScrollUp", "ScrollDown" }
    for i = 1, #fadeButtons do
        local button = scrollbar[fadeButtons[i]]
        if button then
            self:Strip(button, { regions = true })
            self:FadeButtonArt(button)
        end
    end

    local thumb = scrollbar.Thumb
    if thumb then
        self:Strip(thumb, { regions = true })
        if not thumb.__monetThumbFill then
            local fill = thumb:CreateTexture(nil, "ARTWORK")
            fill:SetAllPoints(thumb)
            thumb.__monetThumbFill = fill
            self:Track(fill)
            self:OnTheme(function()
                local r, g, b = Color:GetBorder()
                fill:SetColorTexture(r, g, b, 0.85)
            end)
        end
    end
    return scrollbar
end

--- Walk a scroll frame's scroll bar (Blizzard names differ across builds).
function Skin:ScrollFrame(scrollFrame)
    if not scrollFrame then return end
    local bar = scrollFrame.ScrollBar or scrollFrame.Scrollbar
    if not bar and type(scrollFrame.GetScrollBar) == "function" then
        bar = scrollFrame:GetScrollBar()
    end
    if bar then self:ScrollBar(bar) end
    return scrollFrame
end

--- Restyle a check button: fade the box art, draw a Monet box, keep the check
-- glyph but tint it with the theme border colour.
function Skin:CheckButton(check, opts)
    if not check then return check end

    -- Fade the box (Normal) and the pressed / disabled glows, but keep the check
    -- texture visible.
    if check.GetNormalTexture   then self:Fade(check:GetNormalTexture()) end
    if check.GetPushedTexture   then self:Fade(check:GetPushedTexture()) end
    if check.GetDisabledTexture then self:Fade(check:GetDisabledTexture()) end
    if check.GetHighlightTexture then self:Fade(check:GetHighlightTexture()) end

    self:ControlBg(check, { thickness = 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local checked = check.GetCheckedTexture and check:GetCheckedTexture()
    if checked then
        -- Our own checkmark art, tinted into the theme on top of it.
        checked = self:SwapArt(checked, "monet-check") or checked
        if checked.SetVertexColor then
            local r, g, b = Color:GetBorder()
            pcall(checked.SetVertexColor, checked, r, g, b)
            if not check.__monetCheckTint then
                check.__monetCheckTint = true
                self:OnTheme(function()
                    local nr, ng, nb = Color:GetBorder()
                    if checked.SetVertexColor then checked:SetVertexColor(nr, ng, nb) end
                end)
            end
        end
    end

    -- The stock highlight is gone, so hover feedback rides on the plate border.
    self:HoverHighlight(check, { alpha = (opts and opts.borderAlpha) or 1 })

    local text = self:GetText(check) or check.Text
    if text then self:Font(text, (opts and opts.size) or 12, "pixel", nil, "neutral") end
    return check
end

--- Restyle a drop-down button (Blizzard UIDropDownMenuButtonTemplate).
function Skin:Dropdown(button, opts)
    if not button then return button end
    return self:Button(button, opts or { size = 12 })
end

--- Restyle an edit box.
function Skin:EditBox(editBox)
    if not editBox then return editBox end

    self:Fade(editBox.Left)
    self:Fade(editBox.Middle)
    self:Fade(editBox.Right)
    self:Strip(editBox, { regions = true })
    self:ControlBg(editBox, { bgAlpha = 0.9 })
    return editBox
end

--- Swap a texture's art for one of ours and remember how to put the original
-- back: atlas name or file path, texcoords and alpha, all recorded for
-- Skin:Rollback.  The texture is marked __monetArt so Skin:Fade leaves it
-- alone.  Idempotent: a texture already carrying our art is returned as is.
-- @return the same texture, or nil when it cannot be swapped
function Skin:SwapArt(tex, key)
    if not tex or type(tex.SetTexture) ~= "function" then return nil end
    if tex.__monetArt then return tex end

    local atlas = tex.GetAtlas and tex:GetAtlas() or nil
    local path  = tex.GetTexture and tex:GetTexture() or nil
    local u1, v1, u2, v2 = 0, 0, 1, 1
    if tex.GetTexCoord then u1, v1, u2, v2 = tex:GetTexCoord() end
    local alpha = tex.GetAlpha and tex:GetAlpha() or 1

    self:Record(function()
        if atlas and tex.SetAtlas then pcall(tex.SetAtlas, tex, atlas)
        elseif tex.SetTexture then pcall(tex.SetTexture, tex, path or 0) end
        if tex.SetTexCoord then pcall(tex.SetTexCoord, tex, u1, v1, u2, v2) end
        if tex.SetAlpha then pcall(tex.SetAlpha, tex, alpha) end
        tex.__monetArt = nil
    end)

    tex.__monetArt = true
    pcall(tex.SetTexture, tex, Media:Texture(key))
    if tex.SetTexCoord then pcall(tex.SetTexCoord, tex, 0, 1, 0, 1) end
    if tex.SetAlpha then pcall(tex.SetAlpha, tex, 1) end
    return tex
end

--- Restyle a standard close button into the theme, with our own art under it:
-- normal = monet-close-normal, pushed = monet-close-push, highlight =
-- monet-close-hover over the top (its blend mode is untouched, so hover only
-- brightens the art).  The highlight is left white -- an additive tint would
-- go invisible on the darker border colours.
function Skin:CloseButton(button)
    if not button then return button end

    local normal = self:SwapArt(button.GetNormalTexture and button:GetNormalTexture(),
        "monet-close-normal")
    local pushed = self:SwapArt(button.GetPushedTexture and button:GetPushedTexture(),
        "monet-close-push")
    self:SwapArt(button.GetHighlightTexture and button.GetHighlightTexture(),
        "monet-close-hover")

    if normal and normal.SetVertexColor then
        local r, g, b = Color:GetBorder()
        pcall(normal.SetVertexColor, normal, r, g, b)
        if pushed and pushed.SetVertexColor then
            pcall(pushed.SetVertexColor, pushed, r, g, b)
        end
        if not button.__monetCloseTint then
            button.__monetCloseTint = true
            self:OnTheme(function()
                local nr, ng, nb = Color:GetBorder()
                if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(nr, ng, nb) end
            end)
        end
    end
    return button
end

--- Crop an icon to a square and give it a Monet border.
function Skin:Icon(icon, border)
    if not icon or icon.__monetIcon then return icon end
    icon.__monetIcon = true

    if icon.SetTexCoord then pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92) end
    if border and icon.GetObjectType and icon:GetObjectType() == "Texture" then
        local bg = NewBackdropFrame(icon:GetParent(), 1)
        bg:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bg:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        Widget:Theme(bg, { thickness = 1, bgAlpha = 0 })
        self:Track(bg)
    end
    return icon
end

-- -- Titles / header rows -----------------------------------------------------

--- Style a panel title bar: hide Blizzard's art and recolour the title text.
function Skin:TitleBar(frame, text, size)
    if not frame then return end
    local title = text or frame.TitleContainer and frame.TitleContainer.TitleText or frame.TitleText or frame.Title
    if title then
        self:Font(title, size or 14, "roadway", "OUTLINE", "edge")
    end
end

--- A 1px themed divider the caller anchors itself.
function Skin:Divider(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    local r, g, b = Color:GetNeutral()
    line:SetColorTexture(r, g, b, 0.3)
    self:Track(line)
    self:OnTheme(function()
        local nr, ng, nb = Color:GetNeutral()
        line:SetColorTexture(nr, ng, nb, 0.3)
    end)
    return line
end
