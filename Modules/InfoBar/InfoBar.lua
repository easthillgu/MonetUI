-- Modules/InfoBar/InfoBar.lua
-- Info bar (信息栏): a full-width strip pinned to the top (or bottom) edge of the screen, carrying small data blocks -- money, latency, durability, spec, currencies, friends.
-- The *shape* is the one Andromeda uses (container plus blocks accumulated alternately from each edge); nothing else is carried over -- this client's API differs from retail in several places, so every call is feature-detected and a failed one degrades to one hidden block (see `/mui infobar diagnose`).

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus
local Color    = ns.Color
local Media    = ns.Media

local M = { name = "InfoBar", blocks = {} }
ns.InfoBar = M

local blocks = M.blocks

-- 条身装饰（经验条这类不参与左右排队的元素）：建条时构建一次，布局 / 换肤时重算。
local decorations = {}

local GAP       = 2     -- gap between neighbouring blocks
local PADDING   = 16    -- horizontal breathing room inside a block
local MIN_WIDTH = 40    -- a block never shrinks below this
local FADE      = 4     -- backdrop / block alpha per second while fading
local PULSE     = 1.6   -- combat pulse cycles per second
local PULSE_A0  = 0.35  -- 脉冲最暗（正弦绝对值）
local PULSE_A1  = 1.00  -- 脉冲最亮

-- Live animation state: one OnUpdate drives fade and pulse together from these numbers.
local bar
local blockAlpha, targetBlockAlpha = 0, 0
local barAlpha,   targetBarAlpha   = 0, 0
local pulseColor                   -- nil = no pulse; {r,g,b} = pulsing edge
local pulseFrame, pulseEdges       -- 闪烁专用覆盖层（bar 的子框，压在 XP 线与其它子框之上）
local pulsePhase = 0
local hoverDepth = 0
local hiddenForPetBattle = false
-- 战斗状态不在这里维护：统一用 `ns:InCombat()`（Core 用 PLAYER_REGEN_* 事件维护）。
-- 本客户端在事件派发当拍 InCombatLockdown() 还是旧值（2026-10-27 实机：disabled 里读到 false），
-- 直接读它会让战斗脉冲一次都不亮 —— 这就是"闪烁效果看不到"的真正原因（不是被遮挡）。

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

--- 公开的取值入口：装饰件（Modules/InfoBar/XP.lua）要用同一套默认值回退。
function M:GetSetting(key)
    return Setting(key)
end

function M:BlockEnabled(key)
    local stored = self:Settings().blocks
    local value
    if type(stored) == "table" then value = stored[key] end
    if value == nil then value = ns.DEFAULTS.infobar.blocks[key] end
    return value and true or false
end

--- 闪烁专用覆盖层：bar 的子框，帧级压在 XP 进度线（bar 的另一个子框，画在底边）与其它子框之上。
-- 为什么不能只靠 SetBackdropBorderColor：
--   * 底边 2px 边框被 XP 线（子框，永远画在父框贴图之上）盖掉一半；
--   * 顶边正好贴在屏幕最上沿，只有 1px 露在可见区；
--   * 左右两条又细又贴屏幕边缘。
-- 结果就是"战斗脉冲实际看不见"（玩家 2026-10-27 报"看不见，是不是被遮盖了"）。
-- 覆盖层只画 4 条 2px 边、只负责闪烁这一件事，脉冲一停就整层隐藏。
local function EnsurePulseOverlay()
    if pulseFrame or not bar then return pulseFrame end
    pulseFrame = CreateFrame("Frame", nil, bar)
    pulseFrame:SetAllPoints(bar)
    pulseFrame:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
    pulseFrame:EnableMouse(false)

    local function mk()
        local t = pulseFrame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(Media.texture.blank)
        t:SetVertexColor(1, 1, 1, 0)
        return t
    end

    local top, bottom, left, right = mk(), mk(), mk(), mk()
    top:SetPoint("TOPLEFT", pulseFrame, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", pulseFrame, "TOPRIGHT", 0, 0)
    top:SetHeight(2)
    bottom:SetPoint("BOTTOMLEFT", pulseFrame, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", pulseFrame, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(2)
    left:SetPoint("TOPLEFT", pulseFrame, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", pulseFrame, "BOTTOMLEFT", 0, 0)
    left:SetWidth(2)
    right:SetPoint("TOPRIGHT", pulseFrame, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", pulseFrame, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(2)

    pulseEdges = { top, bottom, left, right }
    pulseFrame:Hide()
    return pulseFrame
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

    -- 闪烁画在覆盖层上（见 EnsurePulseOverlay）：永远压在 XP 线与所有子框之上
    if pulseColor then
        EnsurePulseOverlay()
        if pulseFrame then
            local a = PULSE_A0 + (PULSE_A1 - PULSE_A0) * math.abs(math.sin(pulsePhase * math.pi))
            for i = 1, #pulseEdges do
                pulseEdges[i]:SetVertexColor(pulseColor[1], pulseColor[2], pulseColor[3], a)
            end
            pulseFrame:Show()
        end
    elseif pulseFrame then
        pulseFrame:Hide()
    end
end

--- 信息栏的文字跟着主题的边框槽走（Color:GetBorderKey()）：highlight 洗色在每套主题里都接近
--- 白色，读数和条子自己的边框 / 分隔线看着像两套配色。换主题时 Widget:RefreshThemes 会按
--- 登记的颜色槽重涂；这里再显式刷一遍，免得依赖注册顺序。
local function PaintTexts()
    for i = 1, #blocks do
        local text = blocks[i].text
        if text then Widget:ColorText(text, "border") end
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

--- 条身上的装饰元素（经验条、进度线……）也要算作"鼠标在条上"，否则提示框还开着，条已经淡回去了。
function M:Hover(hovering)
    if hovering then OnEnter() else OnLeave() end
end

--- 提示框锚向：条贴顶就往下弹，贴底就往上弹。装饰件（经验线）复用同一套，免得两处各写一遍。
--- 想让提示框跟着鼠标走是全局开关（Modules/Tooltip.lua），这里只管"贴在条上"这种摆法。
function M:ShowTooltip(owner)
    local tip = _G.GameTooltip
    if not tip then return end
    local top = Setting("anchorTop")
    pcall(tip.SetOwner, tip, owner, top and "ANCHOR_BOTTOM" or "ANCHOR_TOP",
          0, top and -6 or 6)
end

function M:HideTooltip()
    local tip = _G.GameTooltip
    if tip then pcall(tip.Hide, tip) end
end

--- `M:OpenPanel(globalName, …)` —— **已删除**（11-05 开服 P0，日志 id 1441）。
--- 这条路径本身就是"在我们的 Lua 里调暴雪的 FrameXML 全局"（`ToggleCharacter` /
--- `ToggleTalentFrame` / `ToggleFriends` / `ToggleQuestLog`），栈会一路跑到
--- `TextStatusBar.lua:110` 的机密值比较并按 MonetUI 的名义记账。别再把它当"备用开关"加回来。
---
--- 11-07 更新：**格子现在可点**（`Blocks.lua` 的 `BlockClick`，动作单源在 `MicroMenu.lua` 的 `M.actions`）：
--- 要开暴雪面板的那几格走**先弹微菜单代点坞**（`MicroMenuSecure`）这条两击路线。
--- 信息栏本身**永远不能挂安全模板** —— 它是"内容驱动排版"的框，安全模板一进家族就全族被拒
--- （§8.37 实测、§8.64 判定；上面 `BuildBlockFrame` 那段注释里两条失败写法仍是活教训）。
--- 即将来的人：这条边界**不会**因为找到新写法而改变，别再试第三种。

--- Fit a block to its text; an empty block is hidden instead of left as a hollow gap, so a missing API costs one number, not a stripe of the bar.
function M:SetText(block, text)
    if not block or not block.frame then return end

    local value = text and text ~= "" and tostring(text) or nil
    -- 差异写入（#35）：文本没变就整段跳过 —— 不重设 SetText、不重测宽、不重排。
    -- Relayout 对每个可见块 ClearAllPoints/SetPoint，是这条链最贵的一步；信息栏多数块的值
    -- 一秒才变一次甚至更久，重写同样的字符串纯属浪费。首次 value=nil 与 lastText=nil 相等也安全：
    -- 块建出来就是空文本、hasText 初始 false，跳过不影响 UpdateShown 的隐藏判定。
    if value == block.lastText then return end
    block.lastText = value

    block.text:SetText(value or "")
    block.hasText = value ~= nil

    if value then
        local width = block.text:GetStringWidth() or 0
        block.frame:SetWidth(math.max(width, MIN_WIDTH) + PADDING)
    end

    self:Relayout()
end

--- Redistribute visible blocks: left-anchored grow rightwards, right-anchored leftwards, in registration order.
--- Every block except the first of its side carries a 1px divider in the 2px gap before it, so the
--- strip reads as separate read-outs rather than one run-on string.
function M:Relayout()
    if not bar then return end

    local left, right = 0, 0
    local seenLeft, seenRight = false, false
    local dr, dg, db = Color:GetBorder()

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

            local divider = frame.monetDivider
            if divider then
                divider:ClearAllPoints()
                divider:Hide()
                local draw = false
                if block.position == "RIGHT" then
                    if seenRight then
                        divider:SetPoint("LEFT", frame, "RIGHT", 1, 0)
                        draw = true
                    end
                    seenRight = true
                else
                    if seenLeft then
                        divider:SetPoint("RIGHT", frame, "LEFT", -1, 0)
                        draw = true
                    end
                    seenLeft = true
                end
                if draw then
                    divider:SetColorTexture(dr, dg, db, 0.55)
                    divider:Show()
                end
            end
        end
    end
end

local function UpdateShown(block)
    if not block.frame then return end
    local on = (M.active and M:BlockEnabled(block.key) and block.hasText ~= false) and true or false
    -- 差异写入（#35）：可见性没变就不 SetShown、也不重排（SetShown 本身会触发一次布局）。
    -- 首次 lastShown=nil 与 on 不等 → 照常走一遍，之后只有真变化才动。
    if on == block.lastShown then return end
    block.lastShown = on
    block.frame:SetShown(on)
    M:Relayout()
end

--- Record a block's spec; frames are built later in `M:Build` because blocks register at file load while the bar only exists at login.
-- @param spec { key, label, position="LEFT"|"RIGHT", update, tooltip, onClick, onUpdate }
--   `onClick` 只允许打开**我们自己的**面板（`Blocks.lua` 的 `ToggleStatsPanel` 那一类）；
--   暴雪面板没有合法开口，别再往这里加（见 `BuildBlockFrame` 上方的两段判例）。
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

--- 往条身上挂装饰元素（经验条、进度线……）。它们不进左右排队，自己锚在条体的边上。
-- build 只在条体建好时跑一次；apply 在每次重排 / 换肤 / 设置变化后跑，用来重算位置和颜色。
-- @param spec { key = string, build = function(bar), apply = function(bar) }
function M:AddDecoration(spec)
    if type(spec) ~= "table" or type(spec.build) ~= "function" then return nil end

    for i = 1, #decorations do
        if spec.key and decorations[i].key == spec.key then return decorations[i] end
    end

    decorations[#decorations + 1] = spec

    -- 模块晚于条体加载也没关系；条体已经在的话立刻补建。
    if bar then
        local ok, err = pcall(spec.build, bar)
        if not ok then
            spec.reported = true
            ns:Print("信息栏装饰 [" .. tostring(spec.key) .. "] 构建失败：" .. tostring(err))
        elseif type(spec.apply) == "function" then
            pcall(spec.apply, bar)
        end
    end
    return spec
end

function M:ApplyDecorations()
    if not bar then return end
    for i = 1, #decorations do
        local spec = decorations[i]
        if type(spec.apply) == "function" then
            -- 每个装饰各自兜底：一个坏了不能连累条本身；同一处错误只报一次，免得刷屏。
            local ok, err = pcall(spec.apply, bar)
            if not ok and not spec.reported then
                spec.reported = true
                ns:Print("信息栏装饰 [" .. tostring(spec.key) .. "] 刷新失败：" .. tostring(err))
            end
        end
    end
end

function M:RemoveDecorations()
    if not bar then return end
    for i = 1, #decorations do
        local spec = decorations[i]
        if type(spec.remove) == "function" then
            -- 同一个"各自兜底"的规矩：一个装饰还原失败不能连累其它装饰。
            local ok, err = pcall(spec.remove, bar)
            if not ok and not spec.removeReported then
                spec.removeReported = true
                ns:Print("信息栏装饰 [" .. tostring(spec.key) .. "] 还原失败：" .. tostring(err))
            end
        end
    end
end

--- **这一格永远不做"点开暴雪面板"（11-06 判定，别再回来试）**。两条试过都以拦截收尾（判据见下面两段），
--- 而第三条路（#43 的代点载体）也在今天被判定**与本框的机制互斥**，原因是一个数字就能看懂的事实：
--- 本模块是**内容驱动排版** —— `SetBlockText`（本文件 267-278 行）在每次值变化时都要
--- `GetStringWidth` → `block.frame:SetWidth(...)` → `Relayout()`（逐格 `ClearAllPoints/SetPoint`），
--- 而金钱 / 公会 / 威胁这些值**战斗中也在变** ⇒ 排版不能停。
--- §8.37 的雷正是：安全模板控件一旦与格子或 `bar` 建立锚定关系，整族被标成受保护，
--- 之后这些高频写入**全部被拒**（实测每 10 秒上百条 `ADDON_ACTION_BLOCKED`）。
--- ⇒ 判据（已写进 AGENTS）：**内容驱动排版的框，永远不能碰安全模板**；
---   要"点一格开面板"只能把信息栏改成固定宽度网格（损失"读数字"的性格，已否决）。
--- **入口不缺**：右键小地图的微型菜单（`MicroMenuSecure.lua`，#43 已转正）一行就开对应面板。
---
--- ⚠ 11-05 开服实机判例（日志 id 1441 有完整栈）：以前这里是 `M:OpenPanel("ToggleCharacter", …)`，
--- 也就是**在我们的 Lua 里调用暴雪的 FrameXML 全局**。栈一路走到
--- `CharacterFrame.lua:729 → TextStatusBar.lua:110` 的机密值比较，整段以 MonetUI 的名义执行，
--- 玩家点一下金钱数字就吃一条红 —— 和微菜单那条 P0 同型（AGENTS「绝不直调暴雪 Lua 全局」）。
--- `OpenPanel` 整个函数已删除，别再把它当"备用开关"加回来。
---
--- **也不要在这里放 `SecureActionButtonTemplate`**（两个版本都试过，都是我的错）：
---   ① 格子本体做成安全框 → `Relayout` 每拍的 `ClearAllPoints/SetPoint` 变成对安全框做受保护写入，
---      harness 当场 66 条红（`InfoBar.lua:287 ← 判据 文档 fl.pm（ScriptRegionResizing）`）；
---   ② 改成"格子上盖一层安全接住器、`SetAllPoints(frame)` 一次" → 1.60 实机（11-05）
---      **`MonetUIInfoBar:IsProtected()` 变成 true**：锚定家族把格子和整条信息栏一起标成受保护，
---      于是 `SetPoint/ClearAllPoints/SetWidth/SetShown` 全部被拒，实测每 10 秒上百条
---      `ADDON_ACTION_BLOCKED MonetUI Button:…`，而且 `当前受限：无 · InCombatLockdown=false`
---      照样拒（taint.log 对 ADDON_ACTION_BLOCKED 零记录，只能按"无名 Button + 这一组写入"归因）。
local function BuildBlockFrame(block)
    if block.frame or not bar then return end

    local frame = CreateFrame("Button", nil, bar, "BackdropTemplate")
    frame:SetHeight(bar:GetHeight())
    frame:EnableMouse(true)
    -- Borderless so the strip reads as one surface; Theme still registers it so a border-colour change follows.
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0, borderAlpha = 0 })

    frame:SetScript("OnEnter", function()
        -- Counted first: the fade must survive the hand-off between two blocks.
        OnEnter()
        local r, g, b = Color:GetAmbient()
        if frame.SetBackdropColor then
            frame:SetBackdropColor(r * 0.35, g * 0.35, b * 0.35, 0.25)
        end
        M:ShowTooltip(frame)
        if block.tooltip then pcall(block.tooltip, block) end
        local tip = _G.GameTooltip
        -- 可发现性：带点击动作的格子，在提示末尾补一行"点击：…"。
        -- 文案集中存在返回函数身上（`BlockClick` 返回的 fn.hint），免得 7 个提示函数各抄一句。
        if block.onClick and block.onClick.hint and tip and type(tip.AddLine) == "function" then
            local cr, cg, cb = Color:GetBorder()
            pcall(tip.AddLine, tip, "点击：" .. block.onClick.hint, cr, cg, cb)
        end
        if tip then pcall(tip.Show, tip) end
    end)

    frame:SetScript("OnLeave", function()
        OnLeave()
        if frame.SetBackdropColor then frame:SetBackdropColor(0, 0, 0, 0) end
        M:HideTooltip()
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

    local text = Widget:Font(frame, 12, "pixel", "border", "CENTER", nil, Media.outlineFlags)
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.text = text

    -- Divider between neighbouring blocks (shown by Relayout only for blocks that have a
    -- visible predecessor on their own side).  1 physical pixel wide, 8 tall, centred.
    local divider = frame:CreateTexture(nil, "OVERLAY")
    divider:SetSize(Media:Mult(), 8 * Media:Mult())
    divider:Hide()
    frame.monetDivider = divider

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
    -- 1 = 稳稳压在暗角层（Modules/Atmosphere.lua，同 BACKGROUND 档、层级 0）之上。
    -- 同档同层级时"谁盖谁"要看创建先后，写死层级才是确定的。
    bar:SetFrameLevel(1)
    -- 2 physical px: the info bar belongs to the panel tier of the border split (unit frames, auras
    -- and action buttons take 1px; the info bar, minimap and quest tracker take 2px).
    Widget:Theme(bar, { thickness = 2, bgAlpha = 0.25 })
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() OnEnter() end)
    bar:SetScript("OnLeave", function() OnLeave() end)

    AnchorBar()

    -- 装饰件（Modules/InfoBar/XP.lua 的经验线）在条体之后建：它们要读条的宽度和高度。
    for i = 1, #decorations do
        local spec = decorations[i]
        local ok, err = pcall(spec.build, bar)
        if not ok then
            spec.reported = true
            ns:Print("信息栏装饰 [" .. tostring(spec.key) .. "] 构建失败：" .. tostring(err))
        end
    end
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
        elseif ns:InCombat() then
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

    -- 事件就是脉冲的触发点（战斗状态本身由 Core 维护，见 ns:InCombat()）。
    EventBus:Register("PLAYER_REGEN_DISABLED", function() if M.active then RefreshPulse() end end)
    EventBus:Register("PLAYER_REGEN_ENABLED",  function() if M.active then RefreshPulse() end end)
    if _G.C_Calendar and _G.C_Calendar.GetNumPendingInvites then
        EventBus:Register("CALENDAR_UPDATE_PENDING_INVITES",
            function() if M.active then RefreshPulse() end end)
    end

    -- The theme engine already re-tinted registered widgets (it registered at file load, this at login), so re-apply the animated opacities after its blanket refresh.
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if M.active then
            ApplyColors()
            -- 读数用主题的边框槽，主题一换跟着重涂（不靠注册顺序）。
            PaintTexts()
            -- 装饰件自己上色（经验线用的是 resource 色），主题一换要重涂。
            M:ApplyDecorations()
        end
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
    -- 装饰件跟着条体的尺寸 / 贴边方向走（经验条就挂在底边那条衬线上）。
    self:ApplyDecorations()
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
        -- 装饰替我们接管的暴雪框（目前是经验条）要还回去，否则它们会一直停在 alpha 0。
        self:RemoveDecorations()
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

-- 每格的数据源 + 安全转发目标。缺名字是一份报告，不是错误 —— 数据源缺 ⇒ 那一格留空；
-- 转发目标缺 ⇒ 那一格点了没面板（**绝不会**退回"直接调暴雪 Lua 全局"，见 `SecureClickTarget`）。
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
    "UnitXP", "UnitXPMax", "GetXPExhaustion",
    "IsXPUserDisabled", "GetMaxLevelForPlayerExpansion", "BreakUpLargeNumbers",
}

function M:Diagnose()
    -- 逐条确认 + 打印走美化层那本公共账（`Skin:Verify`），这样 `/mui skins diagnose` 一处能看全：
    -- 哪个名字在本客户端不存在，不再各模块自己抄一份 ✓/✗ 循环。
    local _, missing = ns.Skin:Verify("infobar", PROBED, "信息栏对象自检（本客户端实测）：")
    if missing > 0 then
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
