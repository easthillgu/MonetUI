-- tools/tweaks-origin-probe.lua
-- 控制台优化的「原值账」状态机闸门。
--
-- 为什么必须单独测（2026-11-07 判例）：原值以前只存运行期局部表，/reload 之后
-- Apply 重新采样时读到的是**我们上个会话写进去的值**，于是"关掉开关"实际是把
-- 自己写的值再写一遍 —— 勾取消了、画面一点没变（"灰蒙蒙关不掉"）。
-- 这个是跨会话的行为，headless 里必须显式模拟两次加载才测得出来。
--
-- 用桩件加载**真实** Modules/Tools/Tweaks.lua，两个 chunk 实例共享同一份"存档"，
-- 验证：
--   1) 首次打开：记下玩家原值，写入目标值
--   2) reload 再 Apply：原值不被"自己写的值"覆盖（脚本最容易被写错的一步）
--   3) 关掉开关：真的还原成玩家原值，账清空
--   4) 玩家中途自己改过：关掉时不抢他的值，只清账
--   5) /mui tweaks restore：没记账的用客户端默认值兜底
--   6) /mui tweaks all 0：九条全关并还原
--
-- 跑法：lua tools/tweaks-origin-probe.lua    退出码 0 = 全绿
-- 依赖：lua 5.4（loadfile 三参 env）；无第三方库。

local env = setmetatable({}, { __index = _G })
env._G = env

-- value = 当前值，default = 客户端默认值（= 玩家从没动过时的原值）
local CVARS = {
    ResampleAlwaysSharpen = { value = "0", default = "0" },
    particleDensity       = { value = "100", default = "100" },
    volumefog             = { value = "1", default = "1" },
    ffxDeath              = { value = "1", default = "1" },
    weatherDensity        = { value = "2", default = "2" },
    cameraDistanceMaxZoomFactor = { value = "1", default = "1" },
    WorldTextScale_v2     = { value = "1", default = "1" },
    outlineModeShowLootEffectWhenDisabled = { value = "0", default = "0" },
    autoLootRange         = { value = "0", default = "0" },
}

local function Reset()
    for _, r in pairs(CVARS) do r.value = r.default end
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
        r.value = tostring(v)
        return true
    end,
}
env.GetMinRenderScale = function() return 0.33 end
env.GetMaxRenderScale = function() return 1.0 end

-- "存档"：两个 chunk 实例共享，模拟 /reload 前后同一份 SavedVariables
local DB = { tweaks = {}, atmosphere = { strength = 0.10 } }

local out = {}
local function MakeNS()
    local ns = {}
    ns.Secrets = { IsSecret = function() return false end }
    ns.Print = function(_, msg) out[#out + 1] = tostring(msg) end
    ns.DB = function() return DB end
    ns.Register = function() end
    ns.GetModule = function() return nil end
    ns.IsModuleEnabled = function() return false end
    return ns
end

--- 模拟一次 /reload：重新加载 chunk，得到全新的模块实例（运行期局部表全部作废）。
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

print("== 1) 首次打开：记原值 + 写目标值 ==")
Reset()
DB.tweaks = { sharpen = true }
DB.tweakOrigin = nil
local M = Load()
M:Initialize()
check("CVar 被写成目标值 1", CVARS.ResampleAlwaysSharpen.value == "1", CVARS.ResampleAlwaysSharpen.value)
check("原值 0 落进存档", DB.tweakOrigin and DB.tweakOrigin.ResampleAlwaysSharpen == "0",
    DB.tweakOrigin and tostring(DB.tweakOrigin.ResampleAlwaysSharpen))

print("== 2) reload 后原值不被自己写的值覆盖（核心回归）==")
local M2 = Load()
M2:Initialize()
check("CVar 仍是 1", CVARS.ResampleAlwaysSharpen.value == "1", CVARS.ResampleAlwaysSharpen.value)
check("原值仍是 0，没被 1 覆盖", DB.tweakOrigin.ResampleAlwaysSharpen == "0",
    tostring(DB.tweakOrigin.ResampleAlwaysSharpen))

print("== 3) 关掉开关：真的还原 ==")
DB.tweaks.sharpen = false
local M3 = Load()
M3:Apply()
check("CVar 还原成玩家原值 0", CVARS.ResampleAlwaysSharpen.value == "0", CVARS.ResampleAlwaysSharpen.value)
check("还原后账清空", DB.tweakOrigin.ResampleAlwaysSharpen == nil,
    tostring(DB.tweakOrigin.ResampleAlwaysSharpen))

print("== 4) 玩家中途自己改过：关掉时不抢他的值 ==")
Reset()
DB.tweaks = { fewParticles = true }
DB.tweakOrigin = nil
local M4 = Load()
M4:Initialize()
check("粒子被写成 0", CVARS.particleDensity.value == "0", CVARS.particleDensity.value)
CVARS.particleDensity.value = "55" -- 玩家自己动手改成 55
DB.tweaks.fewParticles = false
local M5 = Load()
M5:Apply()
check("玩家的 55 被保留，没被还原成 100", CVARS.particleDensity.value == "55", CVARS.particleDensity.value)
check("账仍然清空", DB.tweakOrigin.particleDensity == nil, tostring(DB.tweakOrigin.particleDensity))

print("== 5) restore：没记账时用客户端默认值兜底 ==")
Reset()
CVARS.volumefog.value = "0"        -- 旧版写的，账上没有
DB.tweaks = { noFog = false }
DB.tweakOrigin = {}
local M6 = Load()
out = {}
M6:Initialize()
check("启动时点名了「开关关但值还留着」", table.concat(out, "\n"):find("还留在打开时的状态", 1, true) ~= nil)
local n = M6:RestoreToDefault()
check("restore 写了至少 1 条", n >= 1, n)
check("volumefog 被推回默认 1", CVARS.volumefog.value == "1", CVARS.volumefog.value)

print("== 5b) RestoreAll 也要能救遗留（all 0 / 关模块走的就是它）==")
Reset()
CVARS.volumefog.value = "0"        -- 旧版写的，账上没有
DB.tweaks = { noFog = false }
DB.tweakOrigin = {}
local M6b = Load()
M6b:RestoreAll()
check("无账但值==目标值 → 用默认值兜底", CVARS.volumefog.value == "1", CVARS.volumefog.value)

print("== 5c) RestoreAll 不许误伤玩家自己设的值 ==")
Reset()
CVARS.particleDensity.value = "55" -- 既不是我们的目标 0，也不是默认 100
DB.tweaks = { fewParticles = false }
DB.tweakOrigin = {}
local M6c = Load()
M6c:RestoreAll()
check("玩家的 55 原封不动", CVARS.particleDensity.value == "55", CVARS.particleDensity.value)

print("== 6) all 0：九条全关并还原 ==")
Reset()
DB.tweaks = { sharpen = true, noFog = true }
DB.tweakOrigin = nil
local M7 = Load()
M7:Initialize()
check("sharpen 与 volumefog 都写成目标值",
    CVARS.ResampleAlwaysSharpen.value == "1" and CVARS.volumefog.value == "0",
    CVARS.ResampleAlwaysSharpen.value .. "/" .. CVARS.volumefog.value)
M7:HandleCommand("all 0")
check("all 0 之后开关全关", next(DB.tweaks) == nil or (not DB.tweaks.sharpen and not DB.tweaks.noFog))
check("all 0 之后值全还原",
    CVARS.ResampleAlwaysSharpen.value == "0" and CVARS.volumefog.value == "1",
    CVARS.ResampleAlwaysSharpen.value .. "/" .. CVARS.volumefog.value)

print("== 7) set <key> 0 也要能救遗留（账上没有、值还是目标值）==")
Reset()
CVARS.volumefog.value = "0"        -- 旧版写的，账上没有
DB.tweaks = { noFog = false }
DB.tweakOrigin = {}
local M8 = Load()
out = {}
M8:HandleCommand("set noFog 0")
check("set noFog 0 把遗留值推回默认 1", CVARS.volumefog.value == "1", CVARS.volumefog.value)
check("命令打出了「值 0 → 1」", table.concat(out, "\n"):find("值 0 → 1", 1, true) ~= nil,
    table.concat(out, " / "))

print("== 8) set <key> 0 不许误伤玩家自己设的值 ==")
Reset()
CVARS.particleDensity.value = "55" -- 既不是我们的目标 0，也不是默认 100
DB.tweaks = { fewParticles = false }
DB.tweakOrigin = {}
local M9 = Load()
out = {}
M9:HandleCommand("set fewParticles 0")
check("玩家的 55 原封不动", CVARS.particleDensity.value == "55", CVARS.particleDensity.value)
check("命令明确说「值没变」", table.concat(out, "\n"):find("值没变", 1, true) ~= nil,
    table.concat(out, " / "))

print(fail == 0 and "\n全部通过" or ("\n失败 " .. fail .. " 项"))
os.exit(fail == 0 and 0 or 1)
