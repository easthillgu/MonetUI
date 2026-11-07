-- Modules/Tools/Tweaks.lua
-- 控制台优化（console tweaks）：把《无限》服流传的一批 `/console` 设置做成逐条开关。
-- 每条 = 一个 CVar + 目标值；打开就写入，关掉还原成玩家原来的值（第一次动它时先存一份原值）。
--
-- 写 CVar 走姓名板模块同一套安全姿势（Modules/Nameplates/Nameplates.lua:89-162）：
-- `C_CVar.GetCVarInfo` 先判 secure / readonly / locked，先读后写、写完复验，失败一次性警告 +
-- 逐条账本。名字在本客户端不存在或被拒写时，只会在账本里落一行 ✗，不报错、不静默空转。
--
-- 名单来自 2026-11-06 的常用优化截图。`nameplateMaxDistance`（姓名板可视距离）已由姓名板模块
-- 负责（Core.lua 的 viewDistance），这里不重复。**默认全关**：这些是画质 / 手感取向的改动，
-- 开哪条是玩家的选择，不是缺省。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets

local M = { name = "Tweaks" }
ns.Tweaks = M

-- key = 存进 db.tweaks 的开关名；cvar = 客户端控制台变量；value = 打开时写入的目标值（字符串，
-- 和 CVar 的存储形态一致）；label = 面板 / 探针上给玩家看的一句话。
local TWEAKS = {
    { key = "cameraZoom",  cvar = "cameraDistanceMaxZoomFactor",           value = "4", label = "拉远视距（镜头能拉得更高更远）" },
    { key = "lootRange",   cvar = "autoLootRange",                         value = "1", label = "加大自动拾取范围（站远也能拾取掉落）" },
    { key = "combatText",  cvar = "WorldTextScale_v2",                     value = "2", label = "放大伤害数字（打击感更明显）" },
    { key = "questGlow",   cvar = "outlineModeShowLootEffectWhenDisabled", value = "1", label = "任务物品发光（关掉高亮也发光）" },
    { key = "noDeathGray", cvar = "ffxDeath",                              value = "0", label = "复活不灰屏（死亡后屏幕不变灰）" },
    { key = "sharpen",     cvar = "ResampleAlwaysSharpen",                 value = "1", label = "画面锐化（更清晰锐利）" },
    { key = "noWeather",   cvar = "weatherDensity",                        value = "0", label = "关闭雨雪天气（画面干净、帧数更稳）" },
    { key = "fewParticles",cvar = "particleDensity",                       value = "0", label = "降低法术粒子" },
    { key = "noFog",       cvar = "volumefog",                             value = "0", label = "去体积雾（远景不蒙灰）" },
}

local function TweakByKey(key)
    for i = 1, #TWEAKS do
        if TWEAKS[i].key == key then return TWEAKS[i] end
    end
    return nil
end

-- saved[cvar]  = 第一次动这个 CVar 之前玩家的原值（关回去时用）
-- written[cvar]= 我们确实为它写过（决定关的时候要不要还原）
local saved   = {}
local written = {}

-- 每个 CVar 一行账，`/mui tweaks status` 读的就是它。
local cvarLedger = {}
local cvarWarned = {}

local function Text(value)
    -- 从游戏拿来的值要进字符串之前再过一次机密判断：`type()` 判不出来（AGENTS 字符串条）。
    if value == nil then return "-" end
    if Secrets.IsSecret(value) then return "机密" end
    return tostring(value)
end

local function CVarRecord(cvar)
    local rec = cvarLedger[cvar]
    if not rec then
        rec = {}
        cvarLedger[cvar] = rec
    end
    return rec
end

local function ReadCVar(cvar)
    local getter = _G.C_CVar and _G.C_CVar.GetCVar or _G.GetCVar
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter, cvar)
    if ok then return value end
    return nil
end

--- @return table|nil { value, default, locked, secure, readonly }；nil = 客户端没答
local function CVarInfo(cvar)
    if not (_G.C_CVar and type(_G.C_CVar.GetCVarInfo) == "function") then return nil end
    local ok, value, default, _, _, locked, secure, readonly = pcall(_G.C_CVar.GetCVarInfo, cvar)
    if not ok then return nil end
    return { value = value, default = default, locked = locked,
             secure = secure, readonly = readonly }
end

--- 同一个 CVar 只印一条（失败一次性警告，不刷屏）；细账在 status 里随时能重看。
local function CVarFlag(cvar, note)
    local rec = CVarRecord(cvar)
    rec.note = note
    if not cvarWarned[cvar] then
        cvarWarned[cvar] = true
        ns:Print(("|cffffa940控制台优化空转|r：%s —— %s（期望 %s）")
            :format(cvar, note, Text(rec.want)))
    end
end

--- @return boolean 写进去了 / 本来就是那个值
local function WriteCVar(cvar, value)
    if value == nil then return false end
    local want = tostring(value)
    local info = CVarInfo(cvar)
    local cur = (info and info.value) or ReadCVar(cvar)
    local rec = CVarRecord(cvar)
    rec.want, rec.got = want, cur

    -- 两个 getter 都答 nil ⇒ 本客户端没这个 CVar（名字错 / 不存在）。不拦的话会一路走到
    -- SetCVar（不报错）+ 复验读回 nil（不是 string，旧判据放过）⇒ 假记"已写"。
    -- 实机判例 1.60：autoLootRange 不存在，旧版就把它记成了"已写"。
    if cur == nil and (not info or info.value == nil) then
        CVarFlag(cvar, "本客户端没有这个 CVar（名字不存在）")
        return false
    end

    -- 先读后写：常态下值没变就不该落一笔。
    if type(cur) == "string" and not Secrets.IsSecret(cur) and cur == want then
        rec.note = "已是"
        return true
    end

    if info and (info.secure or info.readonly or info.locked) then
        CVarFlag(cvar, info.secure and "客户端拒写（isSecure，插件无权改）"
                       or info.readonly and "只读（isReadOnly）"
                       or "玩家已锁定（isLockedFromUser）")
        return false
    end

    local setter = _G.C_CVar and _G.C_CVar.SetCVar or _G.SetCVar
    if type(setter) ~= "function" then return false end
    local ok, err = pcall(setter, cvar, want)
    if not ok then
        CVarFlag(cvar, "写入被拒：" .. Text(err))
        return false
    end

    -- 不报错不等于写进去了：secure / read-only 可能"静默收下、值不动"。复验一次。
    local after = ReadCVar(cvar)
    if after == nil then
        CVarFlag(cvar, "写了复验读不到（值没落地）")
        return false
    end
    if type(after) == "string" and not Secrets.IsSecret(after) and after ~= want then
        CVarFlag(cvar, "写了没生效（复验仍是 " .. Text(after) .. "）")
        return false
    end
    rec.note = "已写"
    return true
end

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.tweaks) ~= "table" then db.tweaks = {} end
    return db.tweaks
end

--- 给设置面板用：逐条清单（key / cvar / value / label）。
function M:Tweaks()
    return TWEAKS
end

function M:IsOn(key)
    return self:Settings()[key] and true or false
end

--- 逐条对齐：开的写入目标值（先存原值），关的若之前写过就还原成原值。
function M:Apply()
    for i = 1, #TWEAKS do
        local t = TWEAKS[i]
        if self:IsOn(t.key) then
            if saved[t.cvar] == nil then saved[t.cvar] = ReadCVar(t.cvar) end
            if WriteCVar(t.cvar, t.value) then
                written[t.cvar] = true
            end
        elseif written[t.cvar] then
            local back = saved[t.cvar]
            if back ~= nil then WriteCVar(t.cvar, back) end
            written[t.cvar] = nil
        end
    end
end

--- 关掉某条 / 整个模块时把动过的都还原回去。
function M:RestoreAll()
    for i = 1, #TWEAKS do
        local t = TWEAKS[i]
        if written[t.cvar] and saved[t.cvar] ~= nil then
            WriteCVar(t.cvar, saved[t.cvar])
            written[t.cvar] = nil
        end
    end
end

function M:Initialize()
    self:Apply()
end

function M:SetEnabled(value)
    if value then
        self:Apply()
    else
        self:RestoreAll()
    end
end

--- 「画面整体发灰 / 发白」这一类观感问题，能改它的 CVar 就这几个（2026-11-07 排查用）。
--- 只有前三条是本模块会写的；其余是玩家自己或在设置里可能被动过的，一起列出来才能对照。
--- `note` 写的是「偏离默认后往哪个方向变」，判读时不至于看数字猜。
local VISION = {
    { cvar = "ResampleAlwaysSharpen", key = "sharpen",      note = "强制锐化重采样：暗部被提亮、边缘出白边 → 整体发灰发脏" },
    { cvar = "particleDensity",       key = "fewParticles", note = "粒子密度：0 = 光效/尘埃/萤火全灭，画面发平" },
    { cvar = "volumefog",             key = "noFog",        note = "体积雾：关掉失去大气透视，远景发平" },
    { cvar = "ffxGlow",               key = nil,            note = "全屏泛光：开 = 整屏蒙一层白雾" },
    { cvar = "ffxDeath",              key = "noDeathGray",  note = "死亡灰度（0 = 复活不灰屏）" },
    { cvar = "weatherDensity",        key = "noWeather",    note = "天气密度（0 = 无雨雪）" },
    { cvar = "ResampleQuality",       key = nil,            note = "重采样质量：偏低 = 放大糊" },
}

--- 画面观感诊断：当前值 vs 客户端默认值，偏离的标出来，并指出哪几条是本插件写的。
--- 只读，不改任何 CVar（报告命令不许有副作用）。
function M:Vision()
    ns:Print("|cffffd100画面观感诊断|r（当前值 vs 客户端默认值，只读）")

    local deviated, ours = 0, 0
    for i = 1, #VISION do
        local v = VISION[i]
        local info = CVarInfo(v.cvar)
        local cur = (info and info.value) or ReadCVar(v.cvar)
        if cur == nil then
            ns:Print(("  %-22s 本客户端没有这个 CVar"):format(v.cvar))
        else
            local mark, diff = "", ""
            if info and info.default ~= nil then
                local d = tostring(info.default)
                local c = tostring(cur)
                if c ~= d then
                    deviated = deviated + 1
                    mark = "|cffffa940偏离|r"
                    diff = "  默认 " .. d
                    if v.key and M:IsOn(v.key) then ours = ours + 1 end
                end
            end
            local owned = (v.key and M:IsOn(v.key)) and "|cff00ff00本插件写|r" or "|cff808080-|r"
            ns:Print(("  %-22s 当前 %-6s %s %s%s"):format(v.cvar, Text(cur), mark, owned, diff))
            if mark ~= "" then
                ns:Print("      └ " .. v.note)
            end
        end
    end

    -- 渲染比例：锐化重采样的影响完全取决于它。1:1 时锐化本该没有意义，低于 1 就是
    -- 「先缩小再锐化放大」，最容易看出灰和脏。
    local scale = ReadCVar("RenderScale")
    if scale ~= nil then
        local lo, hi = "?", "?"
        if type(_G.GetMinRenderScale) == "function" then
            local ok, a = pcall(_G.GetMinRenderScale)
            if ok then lo = tostring(a) end
        end
        if type(_G.GetMaxRenderScale) == "function" then
            local ok, b = pcall(_G.GetMaxRenderScale)
            if ok then hi = tostring(b) end
        end
        ns:Print(("  %-22s 当前 %-6s 范围 %s–%s"):format("RenderScale", Text(scale), lo, hi))
    end

    local atmo = ns:GetModule("Atmosphere")
    if atmo then
        local on = ns:IsModuleEnabled("Atmosphere")
        ns:Print(("  %-22s %s｜强度 %.2f｜只压四周，中心不压"):format(
            "氛围暗角", on and "|cff00ff00开|r" or "|cff808080关|r", atmo:Tier().alpha))
    end

    ns:Print(("判读：偏离默认 %d 条，其中本插件写的 %d 条。"):format(deviated, ours))
    if ours > 0 then
        ns:Print("  先关最像的那条看 10 秒（即时生效，不用 reload）：/mui tweaks set sharpen 0")
        ns:Print("  全关：/mui tweaks set <key> 0（key 见 /mui tweaks status）")
    end
    if deviated > ours then
        ns:Print("  其余偏离项不是本插件写的 —— 那是游戏设置/其他插件改的，去「选项 → 图形」看。")
    end
end

--- `/mui tweaks status` —— 逐条读账本：开关、目标值、当前值、写没写成。
--- `/mui tweaks set <key> 1|0` —— 不开面板逐条换，方便对着截图点名。
function M:HandleCommand(rest)
    local arg, value = string.match(rest or "", "^(%a+)%s*(.*)$")

    if arg == "vision" then
        self:Vision()
        return true
    end

    if not arg or arg == "status" then
        ns:Print("控制台优化（开=写入，关=还原你原来的值）：")
        for i = 1, #TWEAKS do
            local t = TWEAKS[i]
            local on = self:IsOn(t.key) and "|cff00ff00开|r" or "|cff808080关|r"
            local rec = cvarLedger[t.cvar] or {}
            ns:Print(("  %s %-12s %s｜当前 %s｜%s"):format(
                on, t.key, t.cvar, Text(rec.got), rec.note or "-"))
        end
        ns:Print("开关：/mui tweaks set <key> 1|0（如 /mui tweaks set noFog 1）")
        ns:Print("画面发灰/发白：/mui tweaks vision（当前值 vs 默认值，只读）")
        return true
    end

    if arg == "set" then
        local key, flag = string.match(value or "", "^(%S+)%s+(%S+)$")
        local t = key and TweakByKey(key)
        if not t then
            ns:Print("没有这一条：" .. tostring(key) .. "（用 /mui tweaks status 看清单）")
            return true
        end
        local on = (flag == "1" or flag == "on" or flag == "true")
        self:Settings()[t.key] = on
        self:Apply()
        ns:Print(("%s %s：%s"):format(t.label, on and "已开" or "已关", t.cvar))
        return true
    end

    return false
end

ns:Register("Tweaks", M)
