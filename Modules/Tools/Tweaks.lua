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

--- `/mui tweaks status` —— 逐条读账本：开关、目标值、当前值、写没写成。
--- `/mui tweaks set <key> 1|0` —— 不开面板逐条换，方便对着截图点名。
function M:HandleCommand(rest)
    local arg, value = string.match(rest or "", "^(%a+)%s*(.*)$")

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
