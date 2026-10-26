-- Utils/Skin.lua
-- Blizzard-panel skinning primitives (the addon's private skin toolkit): fade the original art, hang a Monet backplate / border under the frame, restyle the controls so a vanilla window matches the rest of MonetUI.
-- Two rules run through everything here: defensive (a client that lacks a frame, a method or a template simply skips that step; nothing raises) and reversible (every mutation of a Blizzard object is recorded, so Skin:Rollback() puts the original back; objects we add ourselves are merely hidden).
-- Nothing here ever calls SetScript / SetParent / SetShown / Hide on a Blizzard frame -- a skin only fades art and adds its own child frames, which keeps the addon taint-free on protected UI and leaves Edit Mode layouts intact.  All hover handling uses HookScript.

local ADDON_NAME, ns = ...


-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local Color    = ns.Color
local Media    = ns.Media
local Widget   = ns.Widget
local EventBus = ns.EventBus

local Skin = {}
ns.Skin = Skin

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

-- Frames/textures we created: hidden on rollback, shown again on re-apply -- the skin code caches them on the Blizzard frame, so they are built once and merely toggled.
Skin.added = {}

-- Only while recording: things built for a Blizzard window belong to the skin and hide with it, while helpers called for the addon's own frames (the config panel) must not join that rollback list.
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

-- Colour changes the Widget theme registration cannot see (a Blizzard texture we recoloured, a thumb we drew ourselves): panels push a refresh closure and the Skins module runs them whenever the theme changes.
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

--- Fade any region (texture) to invisible without moving it, remembering the old alpha.  Hidden once per region.
function Skin:Fade(region)
    if not region or type(region.SetAlpha) ~= "function" then return region end
    if Marked(region, "hidden") then return region end
    -- Our own art (Skin:SwapArt) is never faded: a later pass restyling the same control must not hide the glyph we just put on it.
    if Marked(region, "art") then return region end
    Mark(region, "hidden", true)

    local old = region.GetAlpha and region:GetAlpha() or 1
    self:Record(function()
        if region.SetAlpha then region:SetAlpha(old) end
        Mark(region, "hidden", nil)
    end)

    region:SetAlpha(0)
    return region
end

--- Fade a texture's four sprite edges / a whole button's art, whatever shape it has.
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

-- Named background pieces Blizzard keeps on its panels.
local BACKDROP_PIECES = {
    "NineSlice", "Bg", "Background", "Border", "BorderFrame", "Inset", "InsetFrame",
    "TopBorder", "BottomBorder", "LeftBorder", "RightBorder", "TitleBg", "TitleBG",
    "BgTop", "BgBottom", "BgLeft", "BgRight", "BG", "Backdrop",
}

--- Fade the original art of a frame.
-- @param opts { regions=false, backdrops=false, keep=function(region), keepTexture=tex, art=true } -- false / absent leaves that layer alone.
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

--- Restyle a FontString with one of the addon fonts and (optionally) a theme colour.  Records the old font so a rollback restores it.
function Skin:Font(fs, size, key, flags, colorKey)
    if not fs or type(fs.SetFont) ~= "function" then return fs end

    if not Marked(fs, "font") then
        Mark(fs, "font", true)
        local path, oldSize, oldFlags = fs:GetFont()
        if path then
            self:Record(function()
                if fs.SetFont then fs:SetFont(path, oldSize, oldFlags) end
                Mark(fs, "font", nil)
            end)
        end
    end

    -- Default flags come from Media.fontFlags ("OUTLINE, MONOCHROME"): 1px 描边 + 关抗锯齿。
    -- 暴雪字体对象也走这一条，所以全局统一字体时描边一致。
    pcall(Widget.SetFont, Widget, fs, size or 12, key or "pixel", flags)
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

    if not Marked(fs, "color") then
        Mark(fs, "color", true)
        local oldR, oldG, oldB, oldA = fs:GetTextColor()
        local oldSR, oldSG, oldSB, oldSA
        if fs.GetShadowColor then oldSR, oldSG, oldSB, oldSA = fs:GetShadowColor() end
        self:Record(function()
            if fs.SetTextColor then fs:SetTextColor(oldR, oldG, oldB, oldA) end
            if oldSR and fs.SetShadowColor then fs:SetShadowColor(oldSR, oldSG, oldSB, oldSA) end
            Mark(fs, "color", nil)
        end)
    end

    fs:SetTextColor(r, g, b, a or 1)
    if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0) end
    return fs
end

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

    local bg = Marked(frame, "skinBg")
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
        Mark(frame, "skinBg", bg)
        self:Track(bg)
    end

    bg:Show()
    return bg
end

--- A backplate for a control that already sits inside a panel, drawn *under* the control (buttons / drop-downs / edit boxes).
function Skin:ControlBg(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    local bg = Marked(frame, "controlBg")
    if not bg then
        bg = NewBackdropFrame(frame, -1)
        bg:SetAllPoints(frame)
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.9,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
        })
        Mark(frame, "controlBg", bg)
        self:Track(bg)
    end

    bg:Show()
    return bg
end

--- Hover feedback on a Blizzard control: tint its Monet border to the highlight colour.
--- **不再 HookScript**：那会往暴雪框体的脚本槽里写我们的函数，把它标脏。
--- 改用轮询（Widget:HoverWatch），不写字段、不铺遮挡层、也不吃点击。
function Skin:HoverHighlight(control, opts)
    if not control or type(control) ~= "table" then return end
    if Marked(control, "hover") then return end
    Mark(control, "hover", true)
    opts = opts or {}

    local function border(bg)
        return bg or Marked(control, "skinBg") or Marked(control, "controlBg")
    end

    Widget:HoverWatch(control, function()
        local bg = border()
        if bg and bg.SetBackdropBorderColor then
            local r, g, b = Color:GetHighlight()
            bg:SetBackdropBorderColor(r, g, b, opts.alpha or 1)
        end
    end, function()
        local bg = border()
        if bg then Widget:Refresh(bg) end
    end)
end

--- Give a restyled control its pressed and disabled states back.
-- Skin:Button fades the Pushed and Disabled art and puts nothing in their place, so pressing gives no
-- feedback and a disabled button is indistinguishable from an enabled one -- the player clicks things
-- that do nothing.  Both states are expressed on the plate we already own: press darkens it, disable
-- dims it.  HoverHighlight owns the hover look; apply() reproduces the highlight colour itself after a
-- press so releasing while still hovered does not drop the hover tint.
function Skin:ControlState(control, opts)
    if not control or type(control) ~= "table" then return end
    if Marked(control, "state") then return end
    Mark(control, "state", true)
    opts = opts or {}

    local pressed = false

    local function apply()
        local bg = Marked(control, "controlBg") or Marked(control, "skinBg")
        if not bg or type(bg.SetBackdropBorderColor) ~= "function" then return end

        local enabled = true
        if type(control.IsEnabled) == "function" then
            local ok, value = pcall(control.IsEnabled, control)
            if ok then enabled = value and true or false end
        end

        if not enabled then
            local r, g, b = Color:GetNeutral()
            bg:SetBackdropBorderColor(r, g, b, opts.disabledAlpha or 0.3)
            if bg.SetBackdropColor then pcall(bg.SetBackdropColor, bg, 0, 0, 0, opts.disabledBgAlpha or 0.25) end
            return
        end

        if pressed then
            local r, g, b = Color:GetBorder()
            bg:SetBackdropBorderColor(r, g, b, 0.35)
            if bg.SetBackdropColor then
                pcall(bg.SetBackdropColor, bg, 0, 0, 0, (opts.bgAlpha or 0.9) * 0.6)
            end
            return
        end

        -- Widget:IsMouseOver, not a bare IsMouseOver: this client can return a SECRET boolean from it
        -- (SecretWhenAnchoringSecret), and `value and true` on a secret raises.
        if Widget:IsMouseOver(control) then
            local r, g, b = Color:GetHighlight()
            bg:SetBackdropBorderColor(r, g, b, opts.alpha or 1)
            return
        end

        Widget:Refresh(bg)
    end

    -- **不再 HookScript / hooksecurefunc**：两个都会往暴雪框体的脚本/方法槽里写东西，
    -- 把框体标脏（法术书图标那条 OnIconEnter → ClearOnBarHighlightMarks 就是这么被污染的）。
    -- 改用轮询：hover/down/up 由 Widget:HoverWatch 提供，enabled 状态每 0.2 秒比一次。
    local lastEnabled = nil
    Widget:HoverWatch(control, apply, apply, function()
        pressed = true; apply()
    end, function()
        pressed = false; apply()
    end)
    Widget:PollWatch(control, function()
        local enabled = true
        if type(control.IsEnabled) == "function" then
            local ok, value = pcall(control.IsEnabled, control)
            if ok then enabled = value and true or false end
        end
        if enabled ~= lastEnabled then
            lastEnabled = enabled
            apply()
        end
    end)

    apply()
end

-- The control helpers below are *re-appliable*: fades are idempotent through the side-table mark "hidden" (cleared by Rollback) and created objects (backplate, tab underline, thumb fill) are cached on the frame and only toggled, so no helper short-circuits the whole visual pass.

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
    self:ControlState(button, { alpha = opts.borderAlpha or 1, bgAlpha = opts.bgAlpha or 0.9 })
    return button
end

--- Reflect the selection state on a tab's Monet underline.
-- Skin:Button -> Strip fades every texture region of the tab, SelectedTexture included, so the stock
-- "this tab is active" art is gone and the underline has to carry the state instead.  A panel swaps
-- tabs without any per-tab event we could subscribe to, so PanelTemplates_SelectTab/DeselectTab are
-- hooked once by HookTabState below; this function is also called on every re-apply.
function Skin:UpdateTabState(tab)
    local underline = tab and Marked(tab, "tabBar")
    if not underline then return end

    local selected = false
    if type(tab.IsSelected) == "function" then
        local ok, value = pcall(tab.IsSelected, tab)
        if ok then selected = value and true or false end
    elseif type(tab.Selected) == "table" and type(tab.Selected.GetAlpha) == "function" then
        -- No IsSelected on this template (SettingsPanel's own tabs, for one): fall back to the stock
        -- selected art, which Skin:Fade has already driven to alpha 0 -- so read what the tab wants,
        -- not what we left on screen.
        local ok, alpha = pcall(tab.Selected.GetAlpha, tab.Selected)
        if ok then selected = (alpha or 0) > 0 end
    end

    underline:SetAlpha(selected and 1 or 0.25)
    underline:Show()
end

--- 页签选中态的跟随：**不再 hooksecurefunc(PanelTemplates_SelectTab/DeselectTab)**。
--- 那是全局函数钩子 —— 任何面板切页签时都会在我们的代码里跑一段，整条调用链被记成
--- "tainted by MonetUI"（实机：进入编辑模式时 Blizzard 自己的小队框 setup 因此抛
--- "compare 'oldR' (secret ...)"）。改成 0.5 秒轮询所有装饰过的页签，重算选中态。
local tabWatch = setmetatable({}, { __mode = "k" })
local tabDriver

local function EnsureTabDriver(Skin)
    if tabDriver then return end
    tabDriver = CreateFrame("Frame")
    local acc = 0
    tabDriver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        for tab in pairs(tabWatch) do
            pcall(Skin.UpdateTabState, Skin, tab)
        end
    end)
end

local function WatchTab(Skin, tab)
    if not tab then return end
    tabWatch[tab] = true
    EnsureTabDriver(Skin)
end

--- Restyle a tab button (square, themed, accent underline that follows the selection state).
function Skin:Tab(tab, opts)
    if not tab then return tab end
    self:Button(tab, opts)

    if not Marked(tab, "tab") then
        Mark(tab, "tab", true)
        local underline = tab:CreateTexture(nil, "OVERLAY")
        -- Height and offsets go through SnapUnit.  At uiScale 0.71 a raw 2-unit underline is 1.42
        -- physical px and the raw 1-unit offset sits on a half pixel, so it goes soft while every flat
        -- border beside it stays exact -- the failure mode Media:SnapUnit exists to prevent.
        underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", Media:SnapUnit(4), Media:SnapUnit(1))
        underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -Media:SnapUnit(4), Media:SnapUnit(1))
        underline:SetHeight(Media:SnapUnit(2))
        underline:SetTexture(Media.texture["monet_hairline"])
        Mark(tab, "tabBar", underline)
        self:Track(underline)
        WatchTab(self, tab)        self:OnTheme(function()
            local r, g, b = Color:GetBorder()
            underline:SetVertexColor(r, g, b, 1)
            Skin:UpdateTabState(tab)
        end)
    end
    self:UpdateTabState(tab)
    return tab
end

--- Restyle a scroll bar (track + arrows + thumb).
function Skin:ScrollBar(scrollbar)
    if not scrollbar then return scrollbar end

    self:Strip(scrollbar, { regions = true })

    -- Vertical scroll bars (UIPanelScrollFrameTemplate): up/down arrows -> chevrons.
    -- Horizontal variants (seen on the auction browse sort bar): left/right -> arrow left/right.
    local arrowMap = {
        ScrollUpButton    = "monet_chevron_up",
        ScrollDownButton  = "monet_chevron_down",
        ScrollUp          = "monet_chevron_up",
        ScrollDown        = "monet_chevron_down",
        ScrollLeftButton  = "monet_arrow_left",
        ScrollRightButton = "monet_arrow_right",
        ScrollLeft        = "monet_arrow_left",
        ScrollRight       = "monet_arrow_right",
    }
    for member, key in pairs(arrowMap) do
        local button = scrollbar[member]
        if button then
            self:Strip(button, { regions = true })
            -- FadeButtonArt zeros every art; then SwapArt puts our glyph back.
            self:FadeButtonArt(button)
            local normal = self:SwapArt(button.GetNormalTexture and button:GetNormalTexture(), key)
            local pushed = self:SwapArt(button.GetPushedTexture and button:GetPushedTexture(), key)
            -- Run the same border tint cycle Skin:CloseButton uses -- the glyph sits on a
            -- strip of Monet plate, so it reads as a control belonging to this skin.
            if normal and normal.SetVertexColor then
                local r, g, b = Color:GetBorder()
                normal:SetVertexColor(r, g, b)
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(r, g, b) end
                if not Marked(button, "arrowTint") then
                    Mark(button, "arrowTint", true)
                    self:OnTheme(function()
                        local nr, ng, nb = Color:GetBorder()
                        if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
                        if pushed and pushed.SetVertexColor then pushed:SetVertexColor(nr, ng, nb) end
                    end)
                end
            end
        end
    end

    local thumb = scrollbar.Thumb
    if thumb then
        self:Strip(thumb, { regions = true })
        if not Marked(thumb, "thumbFill") then
            -- The handle gets the same barfill material as the action-bar buttons: a gradient in the theme hue, brightening under the cursor so the grip feels alive instead of a flat swatch.
            local fill = thumb:CreateTexture(nil, "ARTWORK")
            fill:SetAllPoints(thumb)
            fill:SetTexture(Media.texture["monet_barfill"])
            Widget:TopLight(fill)
            Mark(thumb, "thumbFill", fill)
            self:Track(fill)

            local function tint(k)
                local r, g, b = Color:GetBorder()
                fill:SetVertexColor(r * k, g * k, b * k, 0.95)
            end
            tint(1)
            self:OnTheme(function() tint(1) end)
            -- 轮询代替 HookScript（滑块手柄是暴雪的贴图，写脚本槽会污染）。
            Widget:HoverWatch(thumb, function() tint(1.35) end, function() tint(1) end)
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

--- Restyle a slider: a Monet plate under the trough and the same barfill material on the thumb the scroll bars use.
-- Only the documented Slider member is trusted (GetThumbTexture); child names differ across clients and this must never throw, so whatever is missing is simply skipped.
function Skin:Slider(slider)
    if not slider then return slider end

    -- Thumb FIRST, because Skin:Strip fades every texture region of the slider and the thumb is one of
    -- them.  UIPanelSliderTemplate draws its trough as Left/Middle/Right textures on the slider itself,
    -- so skipping Strip leaves the stock blue trough sitting right under the Monet plate.  This was the
    -- one control helper that never called Strip; Skin:EditBox fades the very same three explicitly.
    local thumb
    if type(slider.GetThumbTexture) == "function" then
        local ok, tex = pcall(slider.GetThumbTexture, slider)
        if ok and tex then thumb = tex end
    end
    if not thumb then thumb = slider.Slider or slider.Thumb end

    self:Strip(slider, { keepTexture = thumb })
    self:ControlBg(slider, { thickness = 1, bgAlpha = 0.7 })

    if thumb then
        if type(thumb.CreateTexture) == "function" then
            if not Marked(thumb, "thumbFill") then
                self:ControlBg(thumb, { thickness = 1, bgAlpha = 0.9 })
                local fill = thumb:CreateTexture(nil, "ARTWORK")
                fill:SetAllPoints(thumb)
                fill:SetTexture(Media.texture["monet_barfill"])
                Widget:TopLight(fill)
                Mark(thumb, "thumbFill", fill)
                self:Track(fill)
                local function tint()
                    local r, g, b = Color:GetBorder()
                    fill:SetVertexColor(r, g, b, 0.95)
                end
                tint()
                self:OnTheme(tint)
            end
        elseif thumb.SetTexture then
            -- Go through SwapArt, not a raw SetTexture: SwapArt records the old art and sets
            -- the side-table mark "art", so Rollback can put Blizzard's thumb back.  A bare SetTexture left our
            -- barfill welded on -- a half-rolled-back skin, which is the one thing the Record/Rollback
            -- design promises will not happen.
            self:SwapArt(thumb, "monet_barfill")
            Widget:TopLight(thumb)
            local function tint()
                local r, g, b = Color:GetBorder()
                pcall(thumb.SetVertexColor, thumb, r, g, b, 0.95)
            end
            tint()
            if not Marked(slider, "sliderTint") then
                Mark(slider, "sliderTint", true)
                self:OnTheme(tint)
            end
        end
    end

    -- Low / High / Value captions, when the template has them.
    for _, fs in ipairs({ slider.Low, slider.High, slider.Text }) do
        if type(fs) == "table" and fs.IsObjectType
            and fs:IsObjectType("FontString") then
            self:Font(fs, 12, "pixel", nil, "neutral")
        end
    end
    return slider
end

--- Restyle a check button: fade the box art, draw a Monet box, keep the check glyph but tint it with the theme border colour.
function Skin:CheckButton(check, opts)
    if not check then return check end

    -- Fade the box (Normal) and the pressed / disabled glows, but keep the check texture visible.
    if check.GetNormalTexture   then self:Fade(check:GetNormalTexture()) end
    if check.GetPushedTexture   then self:Fade(check:GetPushedTexture()) end
    if check.GetDisabledTexture then self:Fade(check:GetDisabledTexture()) end
    if check.GetHighlightTexture then self:Fade(check:GetHighlightTexture()) end

    self:ControlBg(check, { thickness = 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local checked = check.GetCheckedTexture and check:GetCheckedTexture()
    if checked then
        -- Our own checkmark art, tinted into the theme on top of it.
        checked = self:SwapArt(checked, "monet_check") or checked
        if checked.SetVertexColor then
            local r, g, b = Color:GetBorder()
            pcall(checked.SetVertexColor, checked, r, g, b)
            if not Marked(check, "checkTint") then
                Mark(check, "checkTint", true)
                self:OnTheme(function()
                    local nr, ng, nb = Color:GetBorder()
                    if checked.SetVertexColor then checked:SetVertexColor(nr, ng, nb) end
                end)
            end
        end
    end

    -- The stock highlight is gone, so hover feedback rides on the plate border.
    self:HoverHighlight(check, { alpha = (opts and opts.borderAlpha) or 1 })
    self:ControlState(check, { alpha = (opts and opts.borderAlpha) or 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local text = self:GetText(check) or check.Text
    if text then self:Font(text, (opts and opts.size) or 12, "pixel", nil, "neutral") end
    return check
end

--- Restyle a radio button.  Deliberately NOT a CheckButton alias: a radio's glyph is a dot, not a tick,
-- and M:Buttons/SkinButtonsIn dispatch on GetObjectType() so a CheckButton skin here gave every radio
-- button in the skinned windows a checkmark.  Structure mirrors Skin:CheckButton so the two read as
-- siblings -- same plate, same press/disabled behaviour, same hover, different art.
function Skin:RadioButton(radio, opts)
    if not radio then return radio end

    if radio.GetNormalTexture   then self:Fade(radio:GetNormalTexture()) end
    if radio.GetPushedTexture   then self:Fade(radio:GetPushedTexture()) end
    if radio.GetDisabledTexture then self:Fade(radio:GetDisabledTexture()) end
    if radio.GetHighlightTexture then self:Fade(radio:GetHighlightTexture()) end

    self:ControlBg(radio, { thickness = 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local checked = radio.GetCheckedTexture and radio:GetCheckedTexture()
    if checked then
        checked = self:SwapArt(checked, "monet_radio") or checked
        if checked.SetVertexColor then
            local r, g, b = Color:GetBorder()
            pcall(checked.SetVertexColor, checked, r, g, b)
            if not Marked(radio, "radioTint") then
                Mark(radio, "radioTint", true)
                self:OnTheme(function()
                    local nr, ng, nb = Color:GetBorder()
                    if checked.SetVertexColor then checked:SetVertexColor(nr, ng, nb) end
                end)
            end
        end
    end

    self:HoverHighlight(radio, { alpha = (opts and opts.borderAlpha) or 1 })
    self:ControlState(radio, { alpha = (opts and opts.borderAlpha) or 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local text = self:GetText(radio) or radio.Text
    if text then self:Font(text, (opts and opts.size) or 12, "pixel", nil, "neutral") end
    return radio
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

--- Swap a texture's art for one of ours and remember how to put the original back (atlas name or path, texcoords and alpha, all recorded for Skin:Rollback).
-- The texture carries the side-table mark "art" so Skin:Fade leaves it alone.  Idempotent: a texture already carrying our art is returned as is.  @return the same texture, or nil when it cannot be swapped
function Skin:SwapArt(tex, key)
    if not tex or type(tex.SetTexture) ~= "function" then return nil end
    if Marked(tex, "art") then return tex end

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
        Mark(tex, "art", nil)
    end)

    Mark(tex, "art", true)
    pcall(tex.SetTexture, tex, Media:Texture(key))
    if tex.SetTexCoord then pcall(tex.SetTexCoord, tex, 0, 1, 0, 1) end
    if tex.SetAlpha then pcall(tex.SetAlpha, tex, 1) end
    return tex
end

--- Restyle a standard close button into the theme, with our own art under it: normal = monet_close_normal, pushed = monet_close_push, highlight = monet_close_hover over the top (its blend mode is untouched, so hover only brightens the art).
-- The highlight is left white -- an additive tint would go invisible on the darker border colours.
function Skin:CloseButton(button)
    if not button then return button end

    local normal = self:SwapArt(button.GetNormalTexture and button:GetNormalTexture(),
        "monet_close_normal")
    local pushed = self:SwapArt(button.GetPushedTexture and button:GetPushedTexture(),
        "monet_close_push")
    self:SwapArt(button.GetHighlightTexture and button:GetHighlightTexture(),
        "monet_close_hover")

    if normal and normal.SetVertexColor then
        local r, g, b = Color:GetBorder()
        pcall(normal.SetVertexColor, normal, r, g, b)
        if pushed and pushed.SetVertexColor then
            pcall(pushed.SetVertexColor, pushed, r, g, b)
        end
        if not Marked(button, "closeTint") then
            Mark(button, "closeTint", true)
            self:OnTheme(function()
                local nr, ng, nb = Color:GetBorder()
                if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(nr, ng, nb) end
            end)
        end
    end
    return button
end

--- 给图标写裁剪（去掉暴雪图标自带的那一圈边框）。
-- 参数是 (x0, x1, y0, y1)：纹素坐标按 SetTexCoord(left, right, bottom, top) 落，横向一对、纵向一对。
--
-- 零售 12.x 的纹素坐标是"秘密值"，只有紧跟在 SetTexture 之后写进去才生效；顺序反了，客户端会把
-- 图标拉成一条竖缝（12.1.5 实测：先裁剪再换贴图 = 竖缝；先换贴图再裁剪 = 正常）。所以这里统一按
-- "换贴图 -> 写裁剪"的顺序落一次，并给图标挂一个钩子：以后每次换贴图都补一遍裁剪（动作条的图标
-- 每刷新一次就会换贴图，不补就会一直保持竖缝）。
--- 图标裁剪（0.08 一圈）。
--- **不再 hooksecurefunc(icon, "SetTexture")**：那是插在暴雪贴图更新链里的钩子 ——
--- 暴雪每次给图标换贴图都会跑一段我们的代码，整条链就被记成 "tainted by MonetUI"。
--- 实机后果（taint.log 原文）：
---   Tainted value written to global ON_BAR_HIGHLIGHT_MARKS by MonetUI
---     ActionButton.lua:66 ClearOnBarHighlightMarks()
---     ← SpellBookItem.lua:521 OnIconEnter()
--- 这个全局表一旦变脏，**所有动作按钮的施法高亮更新**都会被拒，
--- 连带 PetActionButton*:SetShown / PetActionBar:ClearAllPointsBase 刷屏。
--- 改成：只记下裁剪参数，由我们自己的驱动帧每 0.5 秒重压一遍 texcoord。
local cropped = setmetatable({}, { __mode = "k" })
local cropDriver, cropAcc

local function EnsureCropDriver()
    if cropDriver then return end
    cropDriver = CreateFrame("Frame")
    cropDriver:SetScript("OnUpdate", function(_, elapsed)
        cropAcc = (cropAcc or 0) + (elapsed or 0)
        if cropAcc < 0.5 then return end
        cropAcc = 0
        for icon, c in pairs(cropped) do
            if type(icon.SetTexCoord) == "function" then
                pcall(icon.SetTexCoord, icon, c[1], c[2], c[3], c[4])
            end
        end
    end)
end

function Skin:CropIcon(icon, x0, x1, y0, y1)
    if not icon or type(icon.SetTexCoord) ~= "function" then return icon end
    x0, x1 = x0 or 0, x1 or 1
    y0, y1 = y0 or 0, y1 or 1

    cropped[icon] = { x0, x1, y0, y1 }
    EnsureCropDriver()

    -- 先把贴图重写一遍，裁剪必须跟在它后面
    if type(icon.SetTexture) == "function" and type(icon.GetTexture) == "function" then
        local tex = icon:GetTexture()
        if tex then pcall(icon.SetTexture, icon, tex) end
    end
    pcall(icon.SetTexCoord, icon, x0, x1, y0, y1)
    return icon
end

--- Crop an icon to a square and give it a Monet border.
function Skin:Icon(icon, border)
    if not icon or Marked(icon, "icon") then return icon end
    Mark(icon, "icon", true)

    self:CropIcon(icon, 0.08, 0.92, 0.08, 0.92)
    if border and icon.GetObjectType and icon:GetObjectType() == "Texture" then
        local bg = NewBackdropFrame(icon:GetParent(), 1)
        bg:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bg:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        Widget:Theme(bg, { thickness = 1, bgAlpha = 0 })
        self:Track(bg)
    end
    return icon
end

--- Style a panel title bar: hide Blizzard's art and recolour the title text.
function Skin:TitleBar(frame, text, size)
    if not frame then return end
    local title = text or frame.TitleContainer and frame.TitleContainer.TitleText or frame.TitleText or frame.Title
    if title then
        self:Font(title, size or 12, "pixel", nil, "edge")
    end
end

--- A themed divider the caller anchors itself.  Uses monet_hairline (256×1 single opaque row);
--- height = whatever the caller gives via SetHeight, or 1 default.
function Skin:Divider(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(Media.texture["monet_hairline"])
    local r, g, b = Color:GetNeutral()
    line:SetVertexColor(r, g, b, 0.3)
    self:Track(line)
    self:OnTheme(function()
        local nr, ng, nb = Color:GetNeutral()
        line:SetVertexColor(nr, ng, nb, 0.3)
    end)
    return line
end
