-- tools/tweaks-defaults-probe.lua
-- 「默认画面快照 + 登录自动对齐」的状态机闸门（2026-11-08）。
--
-- 为什么必须单独测：这套逻辑跨 /reload 才有意义，而且有两条容易写反的纪律 ——
--   ① 对齐必须在 Apply **之后**（否则开着的开关被顶掉，玩家拨开关没反应）；
--   ② 对齐必须**跳过开关开着的条目**（否则 noWeather 写 0、快照写 3，每次登录互相覆盖）；
--   ③ 对齐还必须在 stuck 检查**之后**，否则「开关关但值没还原」这个查灰屏的关键信号
--      会被快照自己抹掉。
-- 另外 Config.wtf 只是落盘值，出厂快照是 seed，实机重采由 /mui tweaks snapshot 负责。
--
-- 用桩件加载**真实** Modules/Tools/Tweaks.lua，多个 chunk 实例共享同一份「存档」模拟 reload。
-- 验证：
--   1) 新存档铺出厂开关组合；老存档只补 SEED_ADDITIONS 点名的**新增**键，玩家拨过的键一个不动
--   2) 出厂快照 seed 进 db.tweakDefaults，auto 默认开
--   3) Initialize 把非开关管辖的 CVar 拉回快照；开着的开关赢过快照
--   3b) 「战斗文字只留伤害」这一条写整批 CVar，含一个本客户端不存在的名字也不拖累其余
--   4) 零写入不刷屏
--   5) defaults off / on / apply（apply 无视 auto 强制对齐）
--   6) snapshot 实机重采：补齐未采样项、记开关状态、点名冲突、之后按新快照对齐
--   7) stuck 诊断不被对齐抹掉
--   8) 浮点 CVar 存成 "0.500000" 时不误报「写了没生效」（2026-11-13：新增的 0.5 目标值）
--   9) defaults / status / restore 命令不抛、提示齐全
--
-- 跑法：lua tools/tweaks-defaults-probe.lua    退出码 0 = 全绿
-- 依赖：lua 5.4（loadfile 三参 env）；无第三方库。

local env = setmetatable({}, { __index = _G })
env._G = env

local CVARS = {}
local FLOAT6 = {}   -- 名单里的 CVar 写入后存成 "0.500000" 形态（客户端差异，见 SetCVar 桩件）
local function C(name, initial, default)
    CVARS[name] = { value = initial, initial = initial, default = default or initial }
end

-- value = 当前值，default = 客户端默认值，initial = 每个用例的起点
C("gamma",                             "1", "1")
C("brightness",                        "50", "50")
C("contrast",                          "50", "50")
C("ResampleAlwaysSharpen",             "0", "0")
C("particleDensity",                   "100", "100")
C("volumefog",                         "1", "1")
C("ffxGlow",                           "1", "1")
C("ffxDeath",                          "1", "1")
C("weatherDensity",                    "2", "3")
C("ResampleQuality",                   "1", "1")
C("RenderScale",                       "1", "1")
C("cameraDistanceMaxZoomFactor",       "1", "1")
C("WorldTextScale_v2",                 "1", "1")
C("outlineModeShowLootEffectWhenDisabled", "0", "0")

-- 浮动战斗文字一族（2026-11-13「只留伤害数字」管辖），出厂全 1。
-- 故意**漏掉** floatingCombatTextReactives_v2 —— 模拟"本客户端没有这个 CVar"：
-- 一条开关里少一个名字时，其余 15 条必须照写（WriteCVar 的 nil 守卫，2026-11-13）。
local FCT = {
    "floatingCombatTextCombatHealing_v2",
    "floatingCombatTextCombatHealingAbsorbTarget_v2",
    "floatingCombatTextCombatHealingAbsorbSelf_v2",
    "floatingCombatTextFriendlyHealers_v2",
    "floatingCombatTextEnergyGains_v2",
    "floatingCombatTextPeriodicEnergyGains_v2",
    "floatingCombatTextAuras_v2",
    "floatingCombatTextRepChanges_v2",
    "floatingCombatTextHonorGains_v2",
    "floatingCombatTextCombatState_v2",
    "floatingCombatTextComboPoints_v2",
    "floatingCombatTextPetMeleeDamage_v2",
    "floatingCombatTextPetSpellDamage_v2",
    "floatingCombatTextCombatLogPeriodicSpells_v2",
    "floatingCombatTextLowManaHealth_v2",
}
for i = 1, #FCT do C(FCT[i], "1", "1") end
-- 保留项：作者拍板"战斗信息仍要看得见谁在打我"，这三个一个字节都不许动。
C("floatingCombatTextCombatDamage_v2",      "1", "1")
C("floatingCombatTextDodgeParryMiss_v2",    "1", "1")
C("floatingCombatTextDamageReduction_v2",   "1", "1")

local function Reset()
    for _, r in pairs(CVARS) do
        r.value = r.initial
    end
end

env.C_CVar = {
    GetCVar = function(n) local r = CVARS[n]; return r and r.value or nil end,
    GetCVarInfo = function(n)
        local r = CVARS[n]
        if not r then return nil end
        return r.value, r.default, nil, nil, nil, false, false, false
    end,
    SetCVar = function(n, v)
        local r = CVARS[n]
        if not r then return false end
        -- FLOAT6：模拟把浮点 CVar 存成 "0.500000" 的客户端形态（本机 RenderScale 就是这样）。
        r.value = FLOAT6[n] and string.format("%.6f", tonumber(v) or 0) or tostring(v)
        return true
    end,
}
env.GetMinRenderScale = function() return 0.33 end
env.GetMaxRenderScale = function() return 1.0 end

-- 多个 chunk 实例共享同一份「存档」，模拟 /reload 前后同一份 SavedVariables
local DB = {}
local out = {}
local function MakeNS()
    local ns = {}
    ns.Secrets = { IsSecret = function() return false end }
    ns.Print = function(_, msg) out[#out + 1] = tostring(msg) end
    ns.DevPrint = function(_, msg) out[#out + 1] = tostring(msg) end   -- 同 Print，诊断文本也要被 Text() 捕获
    ns.DB = function() return DB end
    ns.Register = function() end
    ns.GetModule = function() return nil end
    ns.IsModuleEnabled = function() return false end
    return ns
end

local function Load()
    local ns = MakeNS()
    local chunk = assert(loadfile("Modules/Tools/Tweaks.lua", "t", env))
    chunk("MonetUI", ns)
    return assert(ns.Tweaks, "ns.Tweaks 未导出")
end

local fail = 0
local function check(name, cond, extra)
    if not cond then
        print("  ✗ " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
        fail = fail + 1
    else
        print("  ✓ " .. name)
    end
end
local function Text() return table.concat(out, "\n") end

-- 实盘里的开关组合（lootRange 已移除：autoLootRange 在 Forever 1.60 不存在）。
-- damageTextOnly 是 2026-11-13 新加的默认开条目（版本 2），老存档由 SEED_ADDITIONS 补。
local function LiveSwitches()
    return {
        cameraZoom = true, combatText = true, questGlow = true,
        noDeathGray = true, sharpen = false, noWeather = true,
        fewParticles = false, noFog = false, damageTextOnly = true,
    }
end

print("== 1) 新存档 seed，老存档只补新增键 ==")
Reset()
DB = {}
local M1 = Load()
local s1 = M1:Settings()
check("新存档铺了 6 条默认开关",
    s1.cameraZoom and s1.combatText and s1.questGlow and s1.noDeathGray
    and s1.noWeather and s1.damageTextOnly)
check("默认关的 3 条没写进存档",
    not s1.sharpen and not s1.fewParticles and not s1.noFog)
check("新存档记下种子版本", DB.tweakSeed == 2, tostring(DB.tweakSeed))

-- 老存档 = 本机制之前就在的那批。稀疏存里「键不存在」既可能是「关掉」也可能是「没见过」，
-- 所以只有 SEED_ADDITIONS 点过名的新键才允许补；玩家拨过的（combatText = false）绝不回滚。
DB = { tweaks = { sharpen = true, combatText = false } }
local M2 = Load()
local s2 = M2:Settings()
check("老存档不顶掉玩家拨过的键", s2.sharpen == true and s2.combatText == false,
    tostring(s2.sharpen) .. "/" .. tostring(s2.combatText))
check("老存档没见过的旧键不补（cameraZoom 仍是 nil）", s2.cameraZoom == nil, tostring(s2.cameraZoom))
check("老存档补上本版新增的 damageTextOnly", s2.damageTextOnly == true, tostring(s2.damageTextOnly))
check("老存档也记下种子版本", DB.tweakSeed == 2, tostring(DB.tweakSeed))

-- 种子标记已是最新时不许再补：否则玩家关掉它之后，每次登录都会被自己开回来。
s2.damageTextOnly = nil
local M2b = Load()
local s2b = M2b:Settings()
check("种子已最新时不再补（玩家关掉后不会自己开回来）", s2b.damageTextOnly == nil,
    tostring(s2b.damageTextOnly))

print("== 2) 出厂快照 seed + Initialize 自动对齐 ==")
Reset()
CVARS.brightness.value = "50"          -- 出厂 55
CVARS.contrast.value = "50"            -- 出厂 75
CVARS.ffxGlow.value = "1"              -- 出厂 0
CVARS.gamma.value = "1.4"              -- 出厂 1
CVARS.particleDensity.value = "100"    -- 出厂 80（fewParticles 关 → 归快照）
CVARS.volumefog.value = "0"            -- 出厂 1（noFog 关 → 归快照）
CVARS.ResampleAlwaysSharpen.value = "0" -- 出厂 1（sharpen 关 → 归快照）
CVARS.ffxDeath.value = "1"             -- noDeathGray 开 → 由开关写 0
CVARS.weatherDensity.value = "3"       -- noWeather 开 → 由开关写 0，快照 3 不许抢
DB = { tweaks = LiveSwitches() }
out = {}
local M3 = Load()
M3:Initialize()
check("brightness 拉回 55", CVARS.brightness.value == "55", CVARS.brightness.value)
check("contrast 拉回 75", CVARS.contrast.value == "75", CVARS.contrast.value)
check("ffxGlow 拉回 0", CVARS.ffxGlow.value == "0", CVARS.ffxGlow.value)
check("gamma 拉回 1", CVARS.gamma.value == "1", CVARS.gamma.value)
check("particleDensity 拉回 80（开关关）", CVARS.particleDensity.value == "80", CVARS.particleDensity.value)
check("volumefog 拉回 1（开关关）", CVARS.volumefog.value == "1", CVARS.volumefog.value)
check("ResampleAlwaysSharpen 拉回 1（开关关）", CVARS.ResampleAlwaysSharpen.value == "1",
    CVARS.ResampleAlwaysSharpen.value)
check("weatherDensity 由 noWeather 写成 0，没被快照的 3 抢走",
    CVARS.weatherDensity.value == "0", CVARS.weatherDensity.value)
check("ffxDeath 由 noDeathGray 写成 0", CVARS.ffxDeath.value == "0", CVARS.ffxDeath.value)

-- 2026-11-13 作者拍板的两条默认：伤害数字 ×0.5、「只留伤害数字」关掉整族战斗文字。
-- 一条开关写多个 CVar 时最怕「只写了主 cvar」或「一个名字不认就整条放弃」，这两项专测那个。
check("WorldTextScale_v2 写成 0.5（伤害数字缩小一半）", CVARS.WorldTextScale_v2.value == "0.5",
    CVARS.WorldTextScale_v2.value)
local allOff, stillOn = true, ""
for i = 1, #FCT do
    if CVARS[FCT[i]].value ~= "0" then
        allOff = false
        stillOn = stillOn .. FCT[i] .. " "
    end
end
check("15 条战斗文字分类全部关掉（治疗 / 吸收 / 能量 / 光环 …）", allOff, stillOn)
check("本客户端不存在的名字（Reactives）不拖累其余 15 条",
    CVARS.floatingCombatTextCombatHealing_v2.value == "0"
    and CVARS.floatingCombatTextLowManaHealth_v2.value == "0")
check("保留项一个字节没动：伤害 / 闪避招架 / 减伤",
    CVARS.floatingCombatTextCombatDamage_v2.value == "1"
    and CVARS.floatingCombatTextDodgeParryMiss_v2.value == "1"
    and CVARS.floatingCombatTextDamageReduction_v2.value == "1",
    CVARS.floatingCombatTextCombatDamage_v2.value .. "/"
    .. CVARS.floatingCombatTextDodgeParryMiss_v2.value .. "/"
    .. CVARS.floatingCombatTextDamageReduction_v2.value)
check("ResampleQuality 未采样 → 跳过，保持 1", CVARS.ResampleQuality.value == "1",
    CVARS.ResampleQuality.value)
check("出厂快照 seed 进 db.tweakDefaults",
    DB.tweakDefaults and DB.tweakDefaults.vision.brightness == "55")
check("auto 默认开（作者拍板）", DB.tweakDefaults.auto == true)
check("对齐汇总打印了一次", Text():find("默认画面对齐", 1, true) ~= nil)

print("== 3) 零写入不刷屏 ==")
out = {}
local M4 = Load()
M4:Initialize()
check("第二次登录零写入，不打印对齐汇总",
    Text():find("默认画面对齐", 1, true) == nil, Text():gsub("\n", " / "))

print("== 4) defaults off / apply / on ==")
CVARS.brightness.value = "42"
out = {}
local M5 = Load()
M5:HandleCommand("defaults off")
check("defaults off → auto=false", DB.tweakDefaults.auto == false)
out = {}
local M6 = Load()
M6:Initialize()
check("auto 关时登录不写任何 CVar", CVARS.brightness.value == "42", CVARS.brightness.value)
check("auto 关时不打印对齐汇总", Text():find("默认画面对齐", 1, true) == nil)
out = {}
M6:HandleCommand("defaults apply")
check("defaults apply 无视 auto 强制写回 55", CVARS.brightness.value == "55", CVARS.brightness.value)
check("apply 命令自己给了结果", Text():find("已按默认画面对齐", 1, true) ~= nil)
M6:HandleCommand("defaults on")
check("defaults on → auto=true", DB.tweakDefaults.auto == true)

print("== 5) snapshot 实机重采 ==")
CVARS.brightness.value = "60"
CVARS.contrast.value = "80"
CVARS.ffxGlow.value = "1"
CVARS.particleDensity.value = "90"
out = {}
local M7 = Load()
M7:HandleCommand("snapshot")
check("snapshot 把新的 brightness 记进快照", DB.tweakDefaults.vision.brightness == "60",
    tostring(DB.tweakDefaults.vision.brightness))
check("snapshot 补齐了出厂没采样的 ResampleQuality",
    DB.tweakDefaults.vision.ResampleQuality == "1", tostring(DB.tweakDefaults.vision.ResampleQuality))
check("snapshot 逐条打印「更新」", Text():find("更新", 1, true) ~= nil)
check("snapshot 记下当时的开关状态", DB.tweakDefaults.switches.noWeather == true)
check("snapshot 点名「由开着的开关接管」的冲突",
    Text():find("由开着的开关", 1, true) ~= nil, Text():gsub("\n", " / "))
check("snapshot 不擅自改 auto（尊重 defaults off）", DB.tweakDefaults.auto == true)

CVARS.brightness.value = "50"
out = {}
local M8 = Load()
M8:Initialize()
check("之后按新快照写回 60，不是出厂 55", CVARS.brightness.value == "60", CVARS.brightness.value)
check("新快照里的 particleDensity 90 也生效", CVARS.particleDensity.value == "90",
    CVARS.particleDensity.value)

print("== 6) stuck 诊断不被对齐抹掉 ==")
Reset()
CVARS.volumefog.value = "0"   -- == noFog 的目标值，开关关、无账 → 该报「值没还原」
DB = { tweaks = { noFog = false }, tweakOrigin = {},
       tweakDefaults = { vision = {}, auto = false } }
out = {}
local M9 = Load()
M9:Initialize()
check("仍报「开关关但值还留在打开时的状态」",
    Text():find("还留在打开时的状态", 1, true) ~= nil, Text():gsub("\n", " / "))

print("== 7) defaults / status 命令不抛、提示齐全 ==")
out = {}
local okD, errD = pcall(M9.HandleCommand, M9, "defaults")
check("defaults 不抛", okD, errD)
check("defaults 标出未采样项", Text():find("未采样", 1, true) ~= nil)
check("defaults 给了 on|off 用法", Text():find("defaults on|off", 1, true) ~= nil)
out = {}
local okS, errS = pcall(M9.HandleCommand, M9, "status")
check("status 不抛", okS, errS)
check("status 提示了 snapshot", Text():find("/mui tweaks snapshot", 1, true) ~= nil)
check("status 点名了本客户端没有的名字条数", Text():find("条本客户端没有", 1, true) ~= nil,
    Text():gsub("\n", " / "))
check("status 把多 CVar 条目合成一行（不铺 16 行）",
    Text():find("damageTextOnly", 1, true) ~= nil and Text():find("条 CVar", 1, true) ~= nil)

print("== 8) 浮点 CVar 存成 0.500000 也不误报「写了没生效」==")
Reset()
FLOAT6.WorldTextScale_v2 = true
CVARS.WorldTextScale_v2.value = "1.000000"
DB = { tweaks = LiveSwitches() }
out = {}
local M10 = Load()
M10:Initialize()
check("0.5 写进去了（按数字比，不是逐字节比）",
    tonumber(CVARS.WorldTextScale_v2.value) == 0.5, CVARS.WorldTextScale_v2.value)
check("没有误报「写了没生效」", Text():find("写了没生效", 1, true) == nil,
    Text():gsub("\n", " / "))
out = {}
M10:HandleCommand("status")
check("再看账本仍以数字形态展示", Text():find("damageTextOnly", 1, true) ~= nil)
FLOAT6.WorldTextScale_v2 = nil

print("== 9) restore 命令不抛、提示齐全 ==")
out = {}
local okR, errR = pcall(M9.HandleCommand, M9, "restore")
check("restore 不抛（多了自动对齐提示）", okR, errR)
check("restore 提醒 reload 会被快照写回", Text():find("defaults off", 1, true) ~= nil)

print(fail == 0 and "\n全部通过" or ("\n失败 " .. fail .. " 项"))
os.exit(fail == 0 and 0 or 1)
