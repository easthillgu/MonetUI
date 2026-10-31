-- Modules/ActionBars/PetBar.lua
-- 宠物条（P5' 拆分，2026-10-26）：收养暴雪的 PetActionButton1..10，外加"自动施法"像素环。
--
-- 为什么是"收养"而不是自绘：本客户端没有通用安全按钮的 type="pet"，自建按钮属性全对、
-- 零拦截、点下去也没有任何反应 —— 客户端根本不处理这个 type。收养来的是原生按钮，
-- 施法 / 右键切自动施法 / 冷却 / 图标全走暴雪自己的路径。代价（已知、已接受）：外壳的
-- UpdateShownButtons 会对这 10 个搬过家的受保护按钮 SetShown，每次重载刷 10 条 BLOCKED，
-- 只进日志、不弹窗、功能正常。
--
-- 接口面：
--   * 输入：M.ButtonSize / Spacing / PositionBar / SkinAdoptedButton /
--           ResolveContainer / bars / adopted / PET_DEF（主文件在文件尾导出，同名别名接走）；
--   * 输出：M.petbar.BuildPetBar(bar, frame, def)（CreateBar 里宠物条那一支）、
--           M.petbar.SyncPetGlow(def, entry) / SyncPetGlowNow() / TeardownPetGlow()。

local ADDON_NAME, ns = ...

local M = ns:GetModule("ActionBars")
if not M then return end

local Widget  = ns.Widget
local Secrets = ns.Secrets
local Media   = ns.Media

-- 旁表标记的本地别名（和 ActionBars.lua 同一个口径）：PetBar 是从主文件搬出来的子文件，
-- 这里**没有**继承主文件的 local Mark/Marked —— 漏了这行调用点就会 `attempt to call a nil value`
-- （2026-10-30 实机：PetBar.lua:83，动作条整模块初始化失败）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

-- 宠物条按钮的**高度**是宽度的 75%（玩家 2026-10-30 要求，让这条比自绘动作条矮一档）。
-- 图标同时按同一比例做竖向裁切（取样区变扁），所以画面不会被压扁 —— 见
-- Modules/ActionBars/ActionBars.lua 的 EnsureAdoptedIcon 与 Mark(btn, "iconCropV")。
local PET_HEIGHT_RATIO = 0.75

-- 主文件导出的共享件。**名字保持一致**，搬过来的函数体因此可以一行都不改。
local ButtonSize        = M.ButtonSize
local Spacing           = M.Spacing
local PositionBar       = M.PositionBar
local SkinAdoptedButton = M.SkinAdoptedButton
local ResolveContainer  = M.ResolveContainer
local bars              = M.bars
local adopted           = M.adopted
local PET_DEF           = M.PET_DEF
local RegisterStateDriver = _G.RegisterStateDriver

--- 宠物条的冷却：收养来的按钮，暴雪只在自己的事件里刷（切目标等），不主动更新 ——
--- 实机表现就是"切个目标才看到冷却时间"。给它一个 0.5 秒的轻量驱动，只调冷却刷新函数
--- （不调 PetActionBar:Update，那会连带 UpdateShownButtons → 那 10 条拦截）。
local petCooldownDriver
local function EnsurePetCooldownDriver()
    if petCooldownDriver then return end
    petCooldownDriver = CreateFrame("Frame")
    local acc = 0
    petCooldownDriver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        local bar = bars and bars.BarPet
        if not bar or not bar.frame:IsShown() then return end
        -- 本客户端没有全局 PetActionBar_UpdateCooldowns（实测 nil），但有方法
        -- PetActionBar:UpdateCooldowns()。只刷冷却，不碰 Update（那会连带 UpdateShownButtons）。
        local shell = _G.PetActionBar
        if shell and type(shell.UpdateCooldowns) == "function" then
            pcall(shell.UpdateCooldowns, shell)
        elseif _G.PetActionBar_UpdateCooldowns then
            pcall(_G.PetActionBar_UpdateCooldowns)
        end
    end)
end

-- 宠物条本体。
local function BuildPetBar(bar, frame, def)
    local size, spacing = ButtonSize(), Spacing()
    -- 高度 = 宽度 × 0.75（吸附到像素格）。宽度不动，所以每格是"扁的"，条整体矮一档。
    local height = Media:SnapUnit(size * PET_HEIGHT_RATIO)
    for i = 1, 10 do
        local btn = _G["PetActionButton" .. i]
        if not btn then break end
        pcall(btn.SetParent, btn, frame)
        pcall(btn.ClearAllPoints, btn)
        pcall(btn.SetSize, btn, size, height)
        pcall(btn.SetScale, btn, 1)
        pcall(btn.SetPoint, btn, "TOPLEFT", frame, "TOPLEFT", (i - 1) * (size + spacing), 0)
        -- 外壳事件被卸载后，没人再替我们把这 10 个按钮 Show 出来（它们可能停在
        -- 壳隐藏时的 SetShown(false) 状态）——直接显式显示一次。
        pcall(btn.Show, btn)
        -- 先登记竖向裁切比例与裁切范围，再换肤：EnsureAdoptedIcon 按它们取采样区。
        -- 范围照 Andromeda pet-bar.lua:33 的 `0.1, 0.9, 0.13, 0.87`；竖向再按条高（0.75）压一次。
        Mark(btn, "iconCropU0", 0.1)
        Mark(btn, "iconCropU1", 0.9)
        Mark(btn, "iconCropV0", 0.13)
        Mark(btn, "iconCropV1", 0.87)
        Mark(btn, "iconCropV", PET_HEIGHT_RATIO)
        SkinAdoptedButton(btn)
        bar.buttons[#bar.buttons + 1] = btn
    end
    if #bar.buttons == 0 then
        pcall(frame.Hide, frame)
        return nil
    end
    pcall(frame.SetSize, frame, #bar.buttons * size + math.max(#bar.buttons - 1, 0) * spacing, height)

    local shell = _G.PetActionBar
    if shell then
        -- 只压根框 alpha + 关鼠标（Widget:Mute 的 depth 0）；**事件不能卸载**：实测卸载之后
        -- 没人再更新这套按钮的图标/冷却（冷却圈直接不转），也没人再 Show 它们。
        -- 代价就是壳的 Update → UpdateShownButtons 会对这 10 个已经搬家的受保护按钮 SetShown，
        -- 日志里出现 10 条 BLOCKED（只进日志、不弹窗）。功能优先，接受这个代价。
        Widget:Mute(shell, { depth = 0, combat = "write" })
    end
    if RegisterStateDriver then
        pcall(RegisterStateDriver, frame, "visibility", "[pet] show; hide")
    end
    PositionBar(bar)
    bar.page = 1
    EnsurePetCooldownDriver()
    return bar
end

-- 宠物条的"自动施法"提示：本客户端暴雪用的是一圈旋转的蚂蚁（按钮的 AutoCastOverlay.Shine），
-- 角标（Corners，"这个技能可以自动施法"）是另一块，别动。这里把蚂蚁换成自绘的像素环：
-- 暴雪的动画摁掉，状态自己按 GetPetActionInfo 的第 6 个返回值（autoCastEnabled）跟。
-- 自绘动作条开着时环沿边框跑；关着时改成静态的一圈（宠物条交还暴雪，但提示不丢）。
-- 战斗中也照常跟：只是往按钮上加几个方块，不碰受保护的框体。

local GetPetActionInfo = _G.GetPetActionInfo

--- 摁掉暴雪的旋转蚂蚁。暴雪每次刷新按钮状态都会把它再点亮，所以这里把方法本身换掉，
-- 顺带把已经点亮的旧动画停掉。
--- 关掉暴雪的自动施法旋转蚂蚁。
--- **只调方法，不写字段。** 以前这里做的是
---   overlay.monetShineSuppressed = true
---   overlay.monetShineUpdate = overlay.UpdateShineAnim
---   overlay.UpdateShineAnim = function() end
--- —— 三行都是往暴雪的 AutoCastOverlay 上写字段。本客户端按"键"判污染：写过就脏，
--- 之后暴雪自己的 PetActionButton:UpdateShownButtons → SetShown 在战斗中全被拒
--- （taint.log: "blocked in combat because of taint from MonetUI - PetActionButton5:SetShown()"）， -- TAINT-OK: 同上，注释非代码
--- 连带 PetActionBar/MainActionBar 的整体重排也被拒。停动画 + 藏起来就够了，不需要改它的函数。
local function SuppressAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    if not overlay then return end
    local shine = overlay.Shine
    if shine then
        if shine.Anim then pcall(shine.Anim.Stop, shine.Anim) end
        pcall(shine.Hide, shine)
        pcall(shine.SetAlpha, shine, 0)
    end
end

--- 还原成暴雪原样（只在模块整个停用时走这条）。
local function RestoreAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    local shine = overlay and overlay.Shine
    if not shine then return end
    pcall(shine.SetAlpha, shine, 1)
    pcall(shine.Show, shine)
    if shine.Anim then pcall(shine.Anim.Play, shine.Anim) end
end

--- 槽位的三个状态（照 Andromeda pet-bar.lua:110 的取值顺序）：
--- name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID。
--- **注意位置**：isActive 是第 4 个、allowed 第 5、enabled 第 6。
--- 以前这里 pcall 后数了 6 个占位符，拿到的其实是 spellID —— 于是"有 spellID 就发光"，
--- 自动施法关掉的技能也会亮（2026-10-30 修正）。
local function PetActionState(index)
    if not GetPetActionInfo then return nil end
    local ok, _, _, _, isActive, allowed, enabled = pcall(GetPetActionInfo, index)
    if not ok then return nil end
    return isActive, allowed, enabled
end

--- 这个槽位开没开自动施法。
local function PetAutoCastEnabled(index)
    local _, _, enabled = PetActionState(index)
    return Secrets.Bool(enabled, false)
end

--- 「可自动施法」角标：照 Andromeda 的参数（12×12，右下角 +2/-2，贴图整幅不裁）。
--- 本客户端挂在 `AutoCastOverlay.Corners` 上；老结构的 `button.AutoCastable` 在这里不存在
--- （`/mui actionbars probe art` 实机确认），别再去找它。
--- 它回答的是"这个技能**可以**开自动施法"，和"已经开了"（像素环）是两件事。
local function StyleAutoCastCorner(button)
    local overlay = button.AutoCastOverlay
    local corner = overlay and overlay.Corners
    if not corner or type(corner.SetPoint) ~= "function" then return end
    pcall(corner.ClearAllPoints, corner)
    pcall(corner.SetPoint, corner, "BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    pcall(corner.SetSize, corner, 12, 12)
    pcall(corner.SetTexCoord, corner, 0, 1, 0, 1)
end

--- 「当前生效的宠物动作」= 金色蒙版（照 Andromeda button-style.lua:185 的
--- `checked:SetColorTexture(1, 0.8, 0, 0.35)`）。暴雪的勾选态贴图已经被
--- FadeAdoptedArt 压成 0，所以它现在的信号由我们自己这块盖上去。
--- 这不是"自动施法开"的提示（那由像素环负责），别混。
local ACTIVE_R, ACTIVE_G, ACTIVE_B, ACTIVE_A = 1, 0.8, 0, 0.35

local function SetActiveLook(button, active)
    if not button then return end
    local tex = Marked(button, "activeOverlay")
    if not tex then return end
    if Marked(button, "activeOn") == active then return end
    Mark(button, "activeOn", active)
    if active then
        pcall(tex.Show, tex)
    else
        pcall(tex.Hide, tex)
    end
end

--- 像素环的边长：跟着暴雪的自动施法遮罩走（那圈蚂蚁就画在这块遮罩里：45 - 8 = 37），
--- 遮罩不在就按按钮宽度推。取的是像素环该落在哪，不是图标本身的大小。
--- **宠物条现在是扁的（高 = 宽 × 0.75）**，而像素环只支持正方形：边长夹到按钮的短边，
--- 否则环会上下溢出按钮（姿态条仍是正方形，走不到这个夹取）。
local function PetGlowSide(button, entry)
    local side
    local overlay = button.AutoCastOverlay
    local mask = overlay and overlay.Mask
    if mask and mask.GetWidth then
        local ok, width = pcall(mask.GetWidth, mask)
        if ok then
            local size = Secrets.Number(width)
            if size and size > 4 then side = size end
        end
    end
    side = side or ((entry.base or 30) + 7)

    if button.GetWidth and button.GetHeight then
        local okW, w = pcall(button.GetWidth, button)
        local okH, h = pcall(button.GetHeight, button)
        local pw = okW and Secrets.Number(w) or nil
        local ph = okH and Secrets.Number(h) or nil
        if pw and ph and ph > 4 and ph < side then side = ph end
    end
    return side
end

--- 自动施法开启时的提示：**像素环**（照 Andromeda：自动施法只走 PixelGlow）。
--- 以前这里还把边框染成 highlight 色，参考插件并不这么做 —— 边框留给主题，
--- 状态信号只有两个：金色蒙版 = "当前生效的宠物动作"，像素环 = "这个技能已开自动施法"。
local function SetAutoCastLook(button, enabled)
    if not button then return end
    if Marked(button, "autoCastLook") == enabled then return end
    Mark(button, "autoCastLook", enabled)
end

--- 开着自动施法的按钮上跑一圈像素环，其余的干净。
-- 自绘动作条开着 → 环跟着跑；关着 → 宠物条还是暴雪自己的样子，环改成静态的一圈。
local function SyncPetGlow(def, entry)
    local isStatic = not M.own
    local scale = entry.scale or 1
    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end

        SuppressAutoCastShine(button)

        local isActive, _, enabled = PetActionState(index)
        -- 金色蒙版 = 当前生效的宠物动作（攻击/跟随/防御…），照 Andromeda 的参数
        SetActiveLook(button, Secrets.Bool(isActive, false))
        SetAutoCastLook(button, Secrets.Bool(enabled, false))
        StyleAutoCastCorner(button)

        if Secrets.Bool(enabled, false) then
            -- 玩家 2026-10-30 定稿的外观参数（改这几个数就行）：
            --   count 6 块、pixel 4 物理像素、spacing 4、period 1 秒一圈、颜色 0.35/1.0/0.45
            --   pitch/ringAlpha 是"关掉自绘动作条"时的静态环参数。
            Widget:PixelGlow(button, {
                side     = PetGlowSide(button, entry),
                scale    = scale,
                static   = isStatic,
                count    = 6,
                pixel    = 4,
                spacing  = 4,
                period   = 1,
                pitch    = 8,
                ringAlpha = 0.9,
                r = 0.35, g = 1.0, b = 0.45,
            })
        else
            Widget:StopPixelGlow(button)
        end
    end
end

--- 宠物条的像素环跟一遍当前状态。自绘动作条关着时这条条没被接管，得自己去拿容器。
local function SyncPetGlowNow()
    local def = PET_DEF
    if not def then return end

    local entry = adopted[def.key]
    if not entry or not entry.frame then
        local bar = ResolveContainer(def)
        if not bar then return end
        local first = _G[def.pattern:format(1)]
        local base
        if first and first.GetWidth then
            local ok, width = pcall(first.GetWidth, first)
            if ok then base = Secrets.Number(width) end
        end
        entry = { def = def, frame = bar, scale = 1, base = base }
    end

    SyncPetGlow(def, entry)
end

--- 模块整个关掉：环拆掉，暴雪的旋转蚂蚁还回去（不然玩家会永久失去原版提示）。
local function TeardownPetGlow()
    local def = PET_DEF
    if not def then return end
    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end
        Widget:StopPixelGlow(button)
        SetAutoCastLook(button, false)
        SetActiveLook(button, false)
        RestoreAutoCastShine(button)
    end
end

M.petbar = {
    BuildPetBar     = BuildPetBar,
    SyncPetGlow     = SyncPetGlow,
    SyncPetGlowNow  = SyncPetGlowNow,
    TeardownPetGlow = TeardownPetGlow,
}
