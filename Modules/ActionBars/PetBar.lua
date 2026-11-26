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
--           M.petbar.EnsurePetAdoption(bar) / ReleasePetBar(bar)（Apply / SetEnabled 脱战调用）、
--           M.petbar.SyncPetGlow(def, entry) / SyncPetGlowNow() / TeardownPetGlow()。

local ADDON_NAME, ns = ...
local Scheduler = ns.Scheduler

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
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData）；activeOverlay/iconCrop*（与主文件共享）仍走 Mark/Marked。
local FFD, GetFFD = ns:NewFrameData()

-- 宠物条按钮的**高度**是宽度的 75%（玩家 2026-10-30 要求，让这条比自绘动作条矮一档）。
-- 图标同时按同一比例做竖向裁切（取样区变扁），所以画面不会被压扁 —— 见
-- Modules/ActionBars/ActionBars.lua 的 EnsureAdoptedIcon 与 Mark(btn, "iconCropV")。
local PET_HEIGHT_RATIO = 0.75

-- 主文件导出的共享件。**名字保持一致**，搬过来的函数体因此可以一行都不改。
local ButtonSize        = M.ButtonSize
local Spacing           = M.Spacing
local PositionBar       = M.PositionBar
local SkinAdoptedButton = M.SkinAdoptedButton
local ReleaseAdoptedButton = M.ReleaseAdoptedButton
local ResolveContainer  = M.ResolveContainer
local bars              = M.bars
local adopted           = M.adopted
local PET_DEF           = M.PET_DEF
local RegisterStateDriver = _G.RegisterStateDriver
local UnregisterStateDriver = _G.UnregisterStateDriver
local Locked = M.ProtectedLocked

--- 宠物条的冷却：收养来的按钮，暴雪只在自己的事件里刷（切目标等），不主动更新 ——
--- 实机表现就是"切个目标才看到冷却时间"。给它一个 0.5 秒的轻量驱动，只调冷却刷新函数
--- （不调 PetActionBar:Update，那会连带 UpdateShownButtons → 那 10 条拦截）。
local petCooldownSubId
local function StopPetCooldownDriver()
    if not petCooldownSubId then return end
    Scheduler:Unregister(petCooldownSubId)
    petCooldownSubId = nil
end

local function EnsurePetCooldownDriver()
    if petCooldownSubId then return end
    petCooldownSubId = Scheduler:Every(500, function()
        if Locked() then return end
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
    end, "动作条:宠物冷却")
end

-- 原状态只进 per-module 弱旁表。父级 / 全部锚点 / 尺寸 / 缩放 / 显隐都要还，不能只把 parent 改回去。
local function ReadPoints(object)
    local okCount, count = pcall(object.GetNumPoints, object)
    if not okCount or type(count) ~= "number" then return nil end
    local points = {}
    for i = 1, count do
        local okPoint, point = pcall(function() return { object:GetPoint(i) } end)
        if not okPoint then return nil end
        points[i] = point
    end
    return points
end

local function SameNumber(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= 0.0001
end

local function SamePoints(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        local left, right = a[i], b[i]
        if not left or not right or #left ~= #right then return false end
        for j = 1, #left do
            if type(left[j]) == "number" and type(right[j]) == "number" then
                if not SameNumber(left[j], right[j]) then return false end
            elseif left[j] ~= right[j] then
                return false
            end
        end
    end
    return true
end

local function ReadGeometry(object)
    local okParent, parent = pcall(object.GetParent, object)
    local points = ReadPoints(object)
    local okWidth, width = pcall(object.GetWidth, object)
    local okHeight, height = pcall(object.GetHeight, object)
    local okScale, scale = pcall(object.GetScale, object)
    local okShown, shown = pcall(object.IsShown, object)
    if not okParent or not points or not okWidth or not okHeight or not okScale or not okShown
        or type(width) ~= "number" or type(height) ~= "number" or type(scale) ~= "number"
        or type(shown) ~= "boolean" then
        return nil
    end
    return { parent = parent, points = points, width = width, height = height, scale = scale, shown = shown }
end

local function SameGeometry(actual, expected)
    return actual ~= nil and actual.parent == expected.parent
        and SamePoints(actual.points, expected.points)
        and SameNumber(actual.width, expected.width)
        and SameNumber(actual.height, expected.height)
        and SameNumber(actual.scale, expected.scale)
        and actual.shown == expected.shown
end

local function RememberPetButton(btn)
    local data = GetFFD(btn)
    if data.petOriginal then return true end
    if Marked(btn, "petAdopted") then return false end
    local original = ReadGeometry(btn)
    if not original then return false end
    data.petOriginal = original
    return true
end

local function Attempt(ok, fn, ...)
    local success = pcall(fn, ...)
    return ok and success
end

local function RestorePetButton(btn)
    local data = GetFFD(btn)
    local original = data.petOriginal
    if not original then
        if Marked(btn, "petAdopted") then return false end
        Mark(btn, "iconCropU0", nil)
        Mark(btn, "iconCropU1", nil)
        Mark(btn, "iconCropV0", nil)
        Mark(btn, "iconCropV1", nil)
        Mark(btn, "iconCropV", nil)
        return true
    end

    local ok = true
    ok = Attempt(ok, btn.SetParent, btn, original.parent)
    ok = Attempt(ok, btn.ClearAllPoints, btn)
    for _, point in ipairs(original.points) do
        ok = Attempt(ok, btn.SetPoint, btn, unpack(point))
    end
    ok = Attempt(ok, btn.SetSize, btn, original.width, original.height)
    ok = Attempt(ok, btn.SetScale, btn, original.scale)
    if original.shown then
        ok = Attempt(ok, btn.Show, btn)
    else
        ok = Attempt(ok, btn.Hide, btn)
    end
    if not ok or not SameGeometry(ReadGeometry(btn), original) then return false end

    Mark(btn, "petAdopted", nil)
    Mark(btn, "iconCropU0", nil)
    Mark(btn, "iconCropU1", nil)
    Mark(btn, "iconCropV0", nil)
    Mark(btn, "iconCropV1", nil)
    Mark(btn, "iconCropV", nil)
    data.petOriginal = nil
    return true
end

local function AdoptPetButton(btn, frame, size, height, spacing, index)
    local ok = true
    ok = Attempt(ok, btn.SetParent, btn, frame)
    ok = Attempt(ok, btn.ClearAllPoints, btn)
    ok = Attempt(ok, btn.SetSize, btn, size, height)
    ok = Attempt(ok, btn.SetScale, btn, 1)
    ok = Attempt(ok, btn.SetPoint, btn, "TOPLEFT", frame, "TOPLEFT", (index - 1) * (size + spacing), 0)
    ok = Attempt(ok, btn.Show, btn)
    if not ok then return false end
    local expected = {
        parent = frame,
        points = { { "TOPLEFT", frame, "TOPLEFT", (index - 1) * (size + spacing), 0 } },
        width = size,
        height = height,
        scale = 1,
        shown = true,
    }
    return SameGeometry(ReadGeometry(btn), expected)
end

-- Build 只建容器；受保护按钮的收养、壳静音和排版全部留给脱战路径的 EnsurePetAdoption。
local function BuildPetBar(bar, frame, def)
    bar.page = 1
    return bar
end

local pendingPetBar
local pendingPetAction
local petRetrySubId
local EnsurePetAdoption, ReleasePetBar
local SetActiveLook, RestoreAutoCastShine
local RetryPetAdoption, QueuePetRetry

RetryPetAdoption = function()
    local bar, action = pendingPetBar, pendingPetAction
    pendingPetBar, pendingPetAction = nil, nil
    if not bar then return true end
    if action == "release" then return ReleasePetBar(bar) end
    if M.enabled == false or not M.own then return ReleasePetBar(bar) end
    return EnsurePetAdoption(bar)
end

QueuePetRetry = function(action, bar)
    pendingPetBar = bar or bars.BarPet
    pendingPetAction = action
    if petRetrySubId then return end
    petRetrySubId = Scheduler:Every(500, function()
        if Locked() then return end
        Scheduler:Unregister(petRetrySubId)
        petRetrySubId = nil
        return RetryPetAdoption()
    end, "动作条:宠物事务重试")
end

ReleasePetBar = function(bar)
    bar = bar or bars.BarPet
    if not bar then return true end
    if Locked() then
        QueuePetRetry("release", bar)
        return false
    end

    local buttons = bar.buttons or {}
    for _, btn in ipairs(buttons) do
        if not RestorePetButton(btn) then
            QueuePetRetry("release", bar)
            return false
        end
    end
    for _, btn in ipairs(buttons) do
        ReleaseAdoptedButton(btn)
        Widget:StopPixelGlow(btn)
        SetActiveLook(btn, false)
        RestoreAutoCastShine(btn)
    end
    bar.buttons = {}
    bar.petAdopted = nil
    adopted[bar.def and bar.def.key or "BarPet"] = nil
    if UnregisterStateDriver then pcall(UnregisterStateDriver, bar.frame, "visibility") end
    bar.hoverOnly = false
    bar.hoverReady = nil
    Widget:Unwatch(bar.frame)
    pcall(bar.frame.Hide, bar.frame)
    StopPetCooldownDriver()

    local shell = _G.PetActionBar
    if shell then Widget:Unmute(shell, { depth = 0 }) end
    return true
end

EnsurePetAdoption = function(bar)
    if not bar then return false end
    if M.enabled == false or not M.own then return ReleasePetBar(bar) end
    if Locked() then
        QueuePetRetry("adopt", bar)
        return false
    end

    local available = {}
    for i = 1, 10 do
        local btn = _G["PetActionButton" .. i]
        if not btn then break end
        available[#available + 1] = btn
    end
    if #available == 0 then
        if not ReleasePetBar(bar) then return false end
        pcall(bar.frame.Hide, bar.frame)
        return nil
    end
    local changed = #bar.buttons ~= #available
    if not changed then
        for i, btn in ipairs(available) do
            if bar.buttons[i] ~= btn then changed = true break end
        end
    end
    -- LoD / 池化可能连对象一起换掉；旧按钮不在清单里也必须整笔交还，不能留在隐藏容器里。
    if changed and not ReleasePetBar(bar) then return false end

    local frame, def = bar.frame, bar.def
    local size, spacing = ButtonSize(), Spacing()
    -- 高度 = 宽度 × 0.75（吸附到像素格）。宽度不动，所以每格是"扁的"，条整体矮一档。
    local height = Media:SnapUnit(size * PET_HEIGHT_RATIO)
    local attempted = {}
    local failed = false
    for i, btn in ipairs(available) do
        if not RememberPetButton(btn) then failed = true break end
        attempted[#attempted + 1] = btn
        if not AdoptPetButton(btn, frame, size, height, spacing, i) then failed = true break end
    end
    bar.buttons = attempted
    if failed or #attempted ~= #available then
        ReleasePetBar(bar)
        return false
    end

    for _, btn in ipairs(bar.buttons) do
        -- 关键几何全部写入并回读成功后才发布"已收养"；此前只保留可回滚快照。
        Mark(btn, "petAdopted", true)
        -- 先登记竖向裁切比例与裁切范围，再换肤：EnsureAdoptedIcon 按它们取采样区。
        -- 范围照 Andromeda pet-bar.lua:33 的 `0.1, 0.9, 0.13, 0.87`；竖向再按条高（0.75）压一次。
        Mark(btn, "iconCropU0", 0.1)
        Mark(btn, "iconCropU1", 0.9)
        Mark(btn, "iconCropV0", 0.13)
        Mark(btn, "iconCropV1", 0.87)
        Mark(btn, "iconCropV", PET_HEIGHT_RATIO)
        SkinAdoptedButton(btn)
    end
    bar.petAdopted = true
    pcall(frame.SetSize, frame, #bar.buttons * size + math.max(#bar.buttons - 1, 0) * spacing, height)

    local shell = _G.PetActionBar
    if shell then
        -- 只压根框 alpha + 关鼠标（Widget:Mute 的 depth 0）；**事件不能卸载**：实测卸载之后
        -- 没人再更新这套按钮的图标/冷却（冷却圈直接不转），也没人再 Show 它们。
        -- 代价就是壳的 Update → UpdateShownButtons 会对这 10 个已经搬家的受保护按钮 SetShown，
        -- 日志里出现 10 条 BLOCKED（只进日志、不弹窗）。功能优先，接受这个代价。
        Widget:Mute(shell, { depth = 0 })
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

--- 自动施法美术的原状态也只进旁表：几何 / 显隐 / alpha / 裁切全部要能交还。
local function RememberPetArtRegion(button, key, region)
    local data = GetFFD(button)
    if data[key] then return data[key] end
    local original = { region = region, points = {} }
    local okCount, count = pcall(region.GetNumPoints, region)
    if okCount and type(count) == "number" then
        for i = 1, count do
            local okPoint, point = pcall(function() return { region:GetPoint(i) } end)
            if okPoint then original.points[#original.points + 1] = point end
        end
    end
    local okWidth, width = pcall(region.GetWidth, region)
    local okHeight, height = pcall(region.GetHeight, region)
    if okWidth and okHeight then original.width, original.height = width, height end
    local okTex, u0, u1, v0, v1 = pcall(region.GetTexCoord, region)
    if okTex then original.u0, original.u1, original.v0, original.v1 = u0, u1, v0, v1 end
    local okAlpha, alpha = pcall(region.GetAlpha, region)
    if okAlpha then original.alpha = alpha end
    local okShown, shown = pcall(region.IsShown, region)
    if okShown then original.shown = shown end
    data[key] = original
    return original
end

local function RestorePetArtRegion(button, key)
    local data = GetFFD(button)
    local original = data[key]
    if not original then return end
    local region = original.region
    pcall(region.ClearAllPoints, region)
    for _, point in ipairs(original.points) do pcall(region.SetPoint, region, unpack(point)) end
    if original.width and original.height then pcall(region.SetSize, region, original.width, original.height) end
    if original.u0 then pcall(region.SetTexCoord, region, original.u0, original.u1, original.v0, original.v1) end
    if original.alpha ~= nil then pcall(region.SetAlpha, region, original.alpha) end
    if original.shown ~= nil then
        if original.shown then pcall(region.Show, region) else pcall(region.Hide, region) end
    end
    data[key] = nil
    return original
end

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
        local original = RememberPetArtRegion(button, "petShineOriginal", shine)
        original.anim = shine.Anim
        if original.anim and type(original.anim.IsPlaying) == "function" then
            local ok, playing = pcall(original.anim.IsPlaying, original.anim)
            if ok then original.playing = playing end
        end
        if shine.Anim then pcall(shine.Anim.Stop, shine.Anim) end
        pcall(shine.Hide, shine)
        pcall(shine.SetAlpha, shine, 0)
    end
end

--- 还原成暴雪原样（停用 / 交还时走这条）：蚂蚁与可自动施法角标都恢复，不硬编码原状态。
RestoreAutoCastShine = function(button)
    local shine = RestorePetArtRegion(button, "petShineOriginal")
    RestorePetArtRegion(button, "petCornerOriginal")
    if shine and shine.anim and shine.playing ~= nil then
        if shine.playing then pcall(shine.anim.Play, shine.anim)
        else pcall(shine.anim.Stop, shine.anim) end
    end
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
    RememberPetArtRegion(button, "petCornerOriginal", corner)
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

SetActiveLook = function(button, active)
    if not button then return end
    local tex = Marked(button, "activeOverlay")
    if not tex then return end
    if GetFFD(button).activeOn == active then return end
    GetFFD(button).activeOn = active
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
    if GetFFD(button).autoCastLook == enabled then return end
    GetFFD(button).autoCastLook = enabled
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
    if M.enabled == false or Locked() then return end
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
    BuildPetBar      = BuildPetBar,
    EnsurePetAdoption = EnsurePetAdoption,
    ReleasePetBar    = ReleasePetBar,
    SyncPetGlow      = SyncPetGlow,
    SyncPetGlowNow   = SyncPetGlowNow,
    TeardownPetGlow  = TeardownPetGlow,
}
